// 目录/层次：src/core，为 RDMA queue-data engine 提供单队列运行时账本。
// 文件职责：统一管理 SQ/RQ/SRQ host-producer ledger 以及 CQ/CEQ/AEQ
// device-producer 的 PI/CI、wrap、credit、reservation、quiesce/resize 和 recovery evidence。
// 主要依赖：依赖 rdma_queue_runtime_transaction_models.sv 提供的枚举、cursor、pending
// 和 slot 值模型，以及 rdma_types_pkg、rdma_model_pkg 与 UVM；本文件不访问
// Host-memory 或 PCIe。
// 所有权/生命周期：runtime 拥有 queue handle 值快照、host slot ledger、
// device reservation 和 pending recovery 证据；route/epoch 是从 dpu_common 权威快照锁存的值。
// 外部 backing、scheduler、QP/Function 资源由各自 lifecycle owner 管理，runtime 不释放它们。

// Queue value models are defined in rdma_queue_runtime_transaction_models.sv.
// This file keeps the mutable lock, ledger, attachment and publication owner.
// 设计说明：rdma_queue_runtime 是单 attachment 的并发状态 authority；所有
// reservation/pending/ledger/retry 变更都必须在同一把 lock 下完成。仅保留既有
// state/depth/PI/CI/used 标量兼容读取；identity、方向、polarity 与 route/epoch
// authority 必须保持 protected，并通过带锁 detached/value query 发布。
class rdma_queue_runtime extends uvm_object;
  `uvm_object_utils(rdma_queue_runtime)
  rdma_queue_runtime_state_e state;
  int unsigned depth;
  int unsigned producer_index;
  int unsigned consumer_index;
  bit producer_wrap;
  bit consumer_wrap;
  int unsigned used;
  // 中文设计：以下 attachment 配置共同决定 queue authority 与 ring 方向；它们
  // 只能由 configure/set_route_epoch/copy_ring_state 在 runtime lock 内发布。
  protected rdma_handle queue_h;
  protected rdma_queue_runtime_kind_e kind;
  protected bit initial_polarity;
  protected rdma_route_key_t route;
  protected bit route_valid;
  protected rdma_reset_epoch_t reset_epoch;
  protected bit epoch_valid;
  // 中文设计：device-produced ring 不使用 host WQE ledger，必须在同一把 runtime lock
  // 保护下保存单一 detached reservation，供写入/提交/恢复阶段共享且不泄露内部句柄。
  protected bit host_produced;
  protected bit device_reservation_valid;
  protected rdma_queue_cursor_snapshot device_reservation;
  protected rdma_queue_pending_operation pending_operation_state;
  protected rdma_queue_slot_ledger_entry slots[];
  protected semaphore lock;
  protected bit recovery_commit_allowed;
  // 中文设计：consumer_release_gate_active 只在 CQ consumer 已提交后、对应 WQE
  // release 尚未开始时置位；置位期间 runtime lock token 由 begin API 持有并只能由
  // finish API 归还。唯一合法的跨 runtime 嵌套锁序是 CQ runtime -> routed WQ
  // runtime，任何实现都禁止在持有 WQ runtime lock 时反向进入 CQ runtime。
  protected bit consumer_release_gate_active;
  // 中文设计：NO_SUBMIT 只证明上一轮没有进入 MMIO，不能自动授权下一轮。
  // caller confirmation 与一次 evidence 转移绑定并在使用后清除，避免跨 retry 重放。
  protected bit recovery_retry_confirmed;

  // 功能：factory_create_object_nonfatal 绕过 registry::create() 的 FCTTYP fatal，
  //   从 UVM factory 获取原始对象，由各值副本边界显式执行类型转换。
  // 输入/输出及副作用：requested_type/name（输入）；返回 factory 创建的
  //   uvm_object，不修改 runtime 或转移其它对象的所有权。
  // 失败/边界：requested_type 或全局 factory 为 null、factory 返回 null 时，本
  //   helper 不报 fatal；动态类型转换由调用方显式检查，失败必须归一化为非成功状态。
  protected function uvm_object factory_create_object_nonfatal(
    uvm_object_wrapper requested_type,
    string name
  );
    uvm_factory factory;

    if (requested_type == null) return null;
    factory = uvm_factory::get();
    if (factory == null) return null;
    return factory.create_object_by_type(requested_type, "", name);
  endfunction

  // 功能：acquire_lock 尝试获取 runtime 唯一 semaphore token，保护
  //   PI/CI、occupancy、reservation 和 recovery evidence 的同步访问。
  // 输入/输出及副作用：无显式参数；成功时消耗一个 lock token 并
  //   返回 OK，调用方必须在所有分支调用 lock.put(1)。
  // 失败/边界：lock 未构造或 token 正被占用时返回 RESOURCE_BUSY；
  //   该失败不读写任何 runtime 业务字段。
  protected function rdma_status acquire_lock();
    if (lock == null || !lock.try_get(1))
      return make_runtime_status(RDMA_SC_RESOURCE_BUSY,
                                 "queue runtime is busy");
    return make_runtime_status(RDMA_SC_OK, "");
  endfunction

  // 功能：make_runtime_status 统一构造 runtime 对外状态；UVM factory
  //   被注入 null/错误类型时，改用直接构造的非空 fallback。
  // 输入/输出及副作用：code、message（输入）；返回独立 rdma_status 值，
  //   不修改 runtime 账本或外部资源。
  // 失败/边界：factory 创建失败时仍返回同一 code/message；fallback 只初始化
  //   诊断字段，不会把错误码伪造成成功。
  protected function rdma_status make_runtime_status(
    rdma_status_code_e code, string message = ""
  );
    rdma_status result;
    uvm_object raw_result;

    // 不调用 rdma_status::make()/type_id::create：两者都会在 null 或
    // 错误 factory 类型上先报 FCTTYP fatal，使调用方无法获得错误码。
    raw_result = factory_create_object_nonfatal(rdma_status::get_type(),
                                                 "runtime_status");
    if (raw_result == null || !$cast(result, raw_result)) begin
      result = new("runtime_status_fallback");
    end
    result.category = rdma_status::category_for(code);
    result.code = code;
    result.hardware_code = '0;
    result.hardware_code_valid = 1'b0;
    result.source_engine = RDMA_ENGINE_NONE;
    result.function_uid = '0;
    result.generation = '0;
    result.resource_id = '0;
    result.command_id = '0;
    result.wr_id = '0;
    result.severity = (code == RDMA_SC_OK) ? RDMA_SEVERITY_INFO
                                           : RDMA_SEVERITY_ERROR;
    result.retryable = 1'b0;
    result.message = message;
    return result;
  endfunction

  // 功能：set_runtime_status_noalloc 在 caller 已拥有的 status slot 中写入一个
  //   完整 runtime 结果，供 scheduler/continuation barrier 后的零分配路径复用。
  // 输入/输出及副作用：slot、code、message 为输入；slot 非空时覆盖全部诊断字段
  //   并返回 1，不创建对象，也不修改 queue cursor、ledger 或 pending evidence。
  // 失败/边界：slot=null 时返回 0 且无任何副作用；message 只记录当前失败原因，
  //   不从兼容位推导 authority，也不把非 OK code 伪装成成功。
  protected function bit set_runtime_status_noalloc(
    rdma_status slot,
    rdma_status_code_e code,
    string message = ""
  );
    if (slot == null) return 1'b0;
    slot.category = rdma_status::category_for(code);
    slot.code = code;
    slot.hardware_code = '0;
    slot.hardware_code_valid = 1'b0;
    slot.source_engine = RDMA_ENGINE_NONE;
    slot.function_uid = '0;
    slot.generation = '0;
    slot.resource_id = '0;
    slot.command_id = '0;
    slot.wr_id = '0;
    slot.severity = (code == RDMA_SC_OK) ? RDMA_SEVERITY_INFO :
                                           RDMA_SEVERITY_ERROR;
    slot.retryable = 1'b0;
    slot.message = message;
    return 1'b1;
  endfunction

  // 功能：status_is_ok 对可能为空的下游状态执行安全成功判断，避免 recovery/clone 异常路径解引用 null handle。
  // 输入/输出及副作用：value（输入）；仅读取 value.code 并返回布尔结果，不修改任何状态。
  // 失败/边界：value 为 null 时返回 0；只有明确的 RDMA_SC_OK 才视为成功。
  protected function bit status_is_ok(rdma_status value);
    return value != null && value.ok();
  endfunction

  // 功能：is_device_ring_kind 统一判断 queue kind 是否由 device 生产并由 runtime
  // 维护 committed producer occupancy，供 reservation、consumer 和 recovery 共用。
  // 输入/输出及副作用：value（输入）；仅读取枚举并返回 bit，不修改 runtime 或外部资源。
  // 失败/边界：未知枚举值返回 0；只有 CQ/CEQ/AEQ 属于 device-produced ring。
  protected function bit is_device_ring_kind(rdma_queue_runtime_kind_e value);
    return value inside {RDMA_QUEUE_RUNTIME_CQ,
                         RDMA_QUEUE_RUNTIME_CEQ,
                         RDMA_QUEUE_RUNTIME_AEQ};
  endfunction

  // 功能：mutable_work_present_locked 统一判断 runtime 在持锁阶段是否仍有未提交的
  //   pending operation、device reservation 或 used slot，供 quiesce、restore 和 detach
  //   的冻结屏障共用同一可变证据判据。
  // 输入/输出及副作用：无显式输入；函数只读取 pending_operation_state、
  //   device_reservation_valid 和 used，返回 bit，不修改 runtime、锁、cursor、ledger 或外部资源。
  // 失败/边界：调用方必须已经持有 runtime lock；字段为 null/0 时返回 0，任一字段表示仍有
  //   可变工作时返回 1；函数不决定错误码、错误文本或调用方的状态迁移。
  protected function bit mutable_work_present_locked();
    return pending_operation_state != null || device_reservation_valid || used != 0;
  endfunction

  // 功能：available_slot_value 依据 ring 几何、已占用 credit、生产方向和
  //   reservation 标志计算调用方当前可用的 producer 槽位，统一 query 与兼容读取的纯值算术。
  // 输入/输出及副作用：depth_value、used_value、host_produced_value、
  //   reservation_valid_value（输入）；返回扣除未提交 device reservation 后的槽位值，
  //   只读取参数，不修改 runtime、游标、reservation 或 slot ledger。
  // 失败/边界：used_value 大于 depth_value 时返回 0 作为无 status 兼容入口的保守值；
  //   depth_value 为 0 时同样返回 0，reservation 仅在尚有槽位且方向为 device-produced 时扣除一次。
  protected function int unsigned available_slot_value(
    int unsigned depth_value,
    int unsigned used_value,
    bit host_produced_value,
    bit reservation_valid_value
  );
    int unsigned value;

    if (used_value > depth_value) begin
      return 0;
    end
    value = depth_value - used_value;
    if (!host_produced_value && reservation_valid_value && value > 0)
      value--;
    return value;
  endfunction

  // 功能：derive_next_cursor 从给定 ring cursor 计算一个提交后的 detached cursor，
  // 统一处理 index 到 depth 边界的回卷和 wrap 翻转。
  // 输入/输出及副作用：source（输入）、result（输出）；result 先置 null，成功时
  // 发布独立快照；不读取或修改 caller-owned source。
  // 失败/边界：source 为空、runtime depth 为零或 source.index 越界时返回
  // INVALID_ARGUMENT/INVALID_STATE，失败不发布半成品快照。
  protected function rdma_status derive_next_cursor(
    rdma_queue_cursor_snapshot source,
    output rdma_queue_cursor_snapshot result
  );
    rdma_queue_cursor_snapshot candidate;
    uvm_object raw_candidate;

    result = null;
    if (source == null)
      return make_runtime_status(RDMA_SC_INVALID_ARGUMENT,
                                 "cursor source is null");
    if (depth == 0 || source.index >= depth)
      return make_runtime_status(RDMA_SC_INVALID_STATE,
                                 "cursor source is outside depth");
    raw_candidate = factory_create_object_nonfatal(
      rdma_queue_cursor_snapshot::get_type(), "derived_next_cursor");
    if (raw_candidate == null || !$cast(candidate, raw_candidate))
      return make_runtime_status(RDMA_SC_RESOURCE_EXHAUSTED,
                                 "next cursor allocation failed");
    candidate.index = source.index;
    candidate.wrap = source.wrap;
    cursor_advance(candidate.index, candidate.wrap);
    result = candidate;
    return make_runtime_status(RDMA_SC_OK, "");
  endfunction

  // 功能：pending_identity_matches_locked 在持锁阶段比较 pending 与当前 runtime 的
  // queue/kind 身份，阻止跨 Function、object 或 generation 的 recovery 操作；句柄四元组
  // 委托 canonical handle_value_equal，避免与 prepared recovery 使用不同的值比较实现。
  // 输入/输出及副作用：pending（输入）；仅读取 pending、queue_h 和 kind，不修改任一
  // 对象、pending 状态或锁；返回 bit 供调用方决定是否继续提交。
  // 失败/边界：pending、pending.queue_h 或当前 queue_h 为空，pending.kind 不同，或
  // handle_value_equal 判定 kind/function_uid/object_id/generation 任一不等时返回 0；
  // helper 不执行 freshness、route/epoch 或 authority 校验，这些仍由 caller 负责。
  protected function bit pending_identity_matches_locked(
    rdma_queue_pending_operation pending
  );
    if (pending == null || pending.queue_h == null || queue_h == null)
      return 1'b0;
    return pending.kind == kind && handle_value_equal(pending.queue_h, queue_h);
  endfunction

  // 功能：pending_cursor_geometry_valid 统一验证 pending 的 cursor/next_cursor
  //   与当前 runtime ring geometry 及 entry offset 是否组成可寻址的值形状。
  // 输入/输出及副作用：pending（输入）；仅读取 pending 的 cursor、next_cursor、
  //   entry_size、entry_offset 和 runtime.depth，返回 bit，不修改 pending、runtime、
  //   游标、ledger 或 status；next_cursor 是否恰为一步后位置由调用方继续判断。
  // 失败/边界：pending/cursor/next_cursor 为空、depth 为零、任一 index 越界、
  //   entry_size 为零、index*entry_size 溢出 64 位或 entry_offset 不相等时返回 0。
  protected function bit pending_cursor_geometry_valid(
    rdma_queue_pending_operation pending
  );
    longint unsigned expected_offset;

    if (pending == null || pending.cursor == null ||
        pending.next_cursor == null || depth == 0 ||
        pending.cursor.index >= depth || pending.next_cursor.index >= depth ||
        pending.entry_size == 0)
      return 1'b0;
    if (pending.cursor.index >
        64'hffff_ffff_ffff_ffff / pending.entry_size)
      return 1'b0;
    expected_offset = longint'(pending.cursor.index) * pending.entry_size;
    return pending.entry_offset == expected_offset;
  endfunction

  // 功能：pending_cursor_shape_valid 校验 pending 的消费/生产 cursor 与 entry
  // geometry 是否能描述当前 ring 中的唯一 slot，并验证 next_cursor 是 cursor 的
  // 一步后值。
  // 输入/输出及副作用：pending（输入）；仅读取 pending 和 runtime geometry，不写入
  // 状态；返回 bit 供 recovery admission/commit 使用。
  // 失败/边界：cursor/next 缺失、越界、entry_size 为零、offset 溢出或 next 不连续时返回 0。
  protected function bit pending_cursor_shape_valid(
    rdma_queue_pending_operation pending
  );
    int unsigned expected_next_index;
    bit expected_next_wrap;

    if (!pending_cursor_geometry_valid(pending))
      return 1'b0;
    expected_next_index = pending.cursor.index;
    expected_next_wrap = pending.cursor.wrap;
    cursor_advance(expected_next_index, expected_next_wrap);
    return cursor_equal(expected_next_index, expected_next_wrap,
                        pending.next_cursor.index, pending.next_cursor.wrap);
  endfunction

  // 功能：consumer_shadow_phase_valid 判断 pending 是否代表冻结的 CQC shadow
  //   publication；普通 RC/UD 使用 23-bit CQ CI，URC 使用 15-bit SQ/RQ packed
  //   cursors，二者都不是 CEQ/AEQ 的 MMIO consumer transaction。
  // 输入/输出及副作用：pending 为输入；函数只读取 kind、shadow geometry、MMIO
  //   evidence 和阶段位，不修改 runtime 或 pending，返回是否满足冻结 ABI。
  // 失败/边界：非 CQ、长度/偏移/layout 宽度错误、shadow 尚未要求或误带 MMIO
  //   success/doorbell marker 时返回 0；该 helper 不把 shadow 写入伪装成 MMIO。
  protected function bit consumer_shadow_phase_valid(
    rdma_queue_pending_operation pending,
    bit require_published
  );
    if (pending == null || pending.kind != RDMA_QUEUE_RUNTIME_CQ ||
        !pending.consumer_shadow_required ||
        pending.consumer_shadow_offset != RDMA_CQC_RUNTIME_SHADOW_BYTE_OFFSET ||
        pending.consumer_shadow_length != RDMA_CQC_RUNTIME_SHADOW_BYTE_LENGTH ||
        (!pending.consumer_shadow_urc &&
         pending.consumer_shadow_value[31:24] != 8'h00) ||
        (!require_published &&
         !(pending.mmio_evidence inside {RDMA_QUEUE_MMIO_NONE,
                                         RDMA_QUEUE_MMIO_NO_SUBMIT})) ||
        (require_published &&
         pending.mmio_evidence != RDMA_QUEUE_MMIO_NO_SUBMIT) ||
        pending.consumer_doorbell_succeeded || pending.mmio_maybe_submitted)
      return 1'b0;
    if (require_published &&
        (!pending.consumer_shadow_attempted ||
         !pending.consumer_shadow_published))
      return 1'b0;
    if (!require_published && pending.consumer_shadow_published)
      return 1'b0;
    return 1'b1;
  endfunction

  // 功能：consumer_publication_committed_ready_locked 判断 consumer CI commit
  //   前已具备的唯一外部发布证明，统一覆盖 MMIO doorbell 与 CQC shadow 两条 ABI。
  // 输入/输出及副作用：pending 为输入；只读 evidence/phase markers 并返回 bit，
  //   不修改 runtime 或 caller 状态。
  // 失败/边界：shadow 路径必须已 attempted+published 且保持 NO_SUBMIT；传统路径
  //   必须是 MMIO SUCCESS 且 doorbell marker 成功；AMBIGUOUS/NONE 一律拒绝。
  protected function bit consumer_publication_committed_ready_locked(
    rdma_queue_pending_operation pending
  );
    if (pending == null)
      return 1'b0;
    if (pending.consumer_shadow_required)
      return consumer_shadow_phase_valid(pending, 1'b1);
    return pending.mmio_evidence == RDMA_QUEUE_MMIO_SUCCESS &&
           pending.consumer_doorbell_succeeded;
  endfunction

  // 功能：consumer_recovery_invariant_locked 在 runtime lock 内统一验证
  //   device-consumer recovery 的 CI 与 committed 阶段，供 admission、merge、
  //   marker、commit 和 complete 共用同一判据。
  // 输入/输出及副作用：pending、evidence、consumer_committed 和
  //   committed_cursor（输入）描述待发布状态；函数只读 runtime CI/geometry，
  //   返回 bit，不修改 pending、游标、occupancy 或外部资源。
  // 失败/边界：非 device consumer、cursor 几何无效、未提交时 CI 不等于 cursor
  //   或仍带 committed_cursor，以及已提交时 evidence 非 SUCCESS 或
  //   CI/committed_cursor/next_cursor 不全等时返回 0。
  protected function bit consumer_recovery_invariant_locked(
    rdma_queue_pending_operation pending,
    rdma_queue_mmio_evidence_e evidence,
    bit consumer_committed,
    rdma_queue_cursor_snapshot committed_cursor
  );
    if (pending == null || host_produced || !is_device_ring_kind(kind) ||
        pending.producer || pending.device_producer || pending.kind != kind ||
        !pending_cursor_shape_valid(pending))
      return 1'b0;

    if (!consumer_committed) begin
      if (pending.consumer_shadow_required)
        return consumer_shadow_phase_valid(pending, 1'b0) &&
               !pending.consumer_shadow_published &&
               committed_cursor == null &&
               cursor_equal(consumer_index, consumer_wrap,
                            pending.cursor.index, pending.cursor.wrap);
      return committed_cursor == null &&
             cursor_equal(consumer_index, consumer_wrap,
                          pending.cursor.index, pending.cursor.wrap);
    end

    if (pending.consumer_shadow_required)
      return consumer_shadow_phase_valid(pending, 1'b1) &&
             committed_cursor != null &&
             cursor_equal(committed_cursor.index, committed_cursor.wrap,
                          pending.next_cursor.index, pending.next_cursor.wrap) &&
             cursor_equal(consumer_index, consumer_wrap,
                          pending.next_cursor.index, pending.next_cursor.wrap);

    return evidence == RDMA_QUEUE_MMIO_SUCCESS &&
           committed_cursor != null &&
           cursor_equal(committed_cursor.index, committed_cursor.wrap,
                        pending.next_cursor.index, pending.next_cursor.wrap) &&
           cursor_equal(consumer_index, consumer_wrap,
                        pending.next_cursor.index, pending.next_cursor.wrap);
  endfunction

  // 功能：clone_handle_value_nonfatal 按字段复制 queue/function handle，避免 UVM clone 在异常路径触发 fatal。
  // 输入/输出及副作用：source（输入）、copy（输出）；copy 先置 null，成功时发布独立 handle 值副本，不接管 source 所有权。
  // 失败/边界：source 为空视为合法空引用；对象工厂分配失败返回 RESOURCE_EXHAUSTED，任何失败均不发布半成品。
  protected function rdma_status clone_handle_value_nonfatal(
    rdma_handle source, output rdma_handle copy
  );
    rdma_handle candidate;
    uvm_object raw_candidate;

    copy = null;
    if (source == null) return make_runtime_status(RDMA_SC_OK, "");
    raw_candidate = factory_create_object_nonfatal(
      rdma_handle::get_type(), "nonfatal_handle_copy");
    if (raw_candidate == null || !$cast(candidate, raw_candidate))
      return make_runtime_status(RDMA_SC_RESOURCE_EXHAUSTED,
                                 "handle copy allocation failed");
    candidate.kind = source.kind;
    candidate.function_uid = source.function_uid;
    candidate.object_id = source.object_id;
    candidate.generation = source.generation;
    copy = candidate;
    return make_runtime_status(RDMA_SC_OK, "");
  endfunction

  // 功能：clone_cursor_value_nonfatal 复制 producer/consumer cursor 的 index/wrap 值。
  // 输入/输出及副作用：source（输入）、copy（输出）先置 null；成功时 copy 是与 source 隔离的新快照。
  // 失败/边界：source 为空返回成功空值；快照分配失败返回 RESOURCE_EXHAUSTED 且不保留部分字段。
  protected function rdma_status clone_cursor_value_nonfatal(
    rdma_queue_cursor_snapshot source,
    output rdma_queue_cursor_snapshot copy
  );
    rdma_queue_cursor_snapshot candidate;
    uvm_object raw_candidate;

    copy = null;
    if (source == null) return make_runtime_status(RDMA_SC_OK, "");
    raw_candidate = factory_create_object_nonfatal(
      rdma_queue_cursor_snapshot::get_type(), "nonfatal_cursor_copy");
    if (raw_candidate == null || !$cast(candidate, raw_candidate))
      return make_runtime_status(RDMA_SC_RESOURCE_EXHAUSTED,
                                 "cursor copy allocation failed");
    candidate.index = source.index;
    candidate.wrap = source.wrap;
    copy = candidate;
    return make_runtime_status(RDMA_SC_OK, "");
  endfunction

  // 功能：clone_image_value_nonfatal 深复制硬件镜像 metadata、bytes 和 field_summary，保证 recovery 可重放原始内容。
  // 输入/输出及副作用：source（输入）、copy（输出）先置 null；成功时发布独立 image，不引用 source 的动态数组。
  // 失败/边界：source 为空返回成功空值；image 或动态数组元素分配失败返回 RESOURCE_EXHAUSTED，调用方不得使用未完成 copy。
  protected function rdma_status clone_image_value_nonfatal(
    rdma_hw_image source, output rdma_hw_image copy
  );
    rdma_hw_image candidate;
    uvm_object raw_candidate;

    copy = null;
    if (source == null) return make_runtime_status(RDMA_SC_OK, "");
    raw_candidate = factory_create_object_nonfatal(
      rdma_hw_image::get_type(), "nonfatal_image_copy");
    if (raw_candidate == null || !$cast(candidate, raw_candidate))
      return make_runtime_status(RDMA_SC_RESOURCE_EXHAUSTED,
                                 "image copy allocation failed");
    candidate.length = source.length;
    candidate.alignment = source.alignment;
    candidate.endian = source.endian;
    candidate.image_kind = source.image_kind;
    candidate.hardware_version = source.hardware_version;
    candidate.function_generation = source.function_generation;
    candidate.write_target_kind = source.write_target_kind;
    candidate.backing_target = source.backing_target;
    candidate.hmc_target = source.hmc_target;
    candidate.bar_target = source.bar_target;
    candidate.bytes.delete();
    foreach (source.bytes[i]) candidate.bytes.push_back(source.bytes[i]);
    candidate.field_summary.delete();
    foreach (source.field_summary[i]) candidate.field_summary.push_back(source.field_summary[i]);
    copy = candidate;
    return make_runtime_status(RDMA_SC_OK, "");
  endfunction

  // 功能：clone_status_value_nonfatal 复制 rdma_status 的完整诊断字段，保留错误码、硬件上下文和 retry 语义。
  // 输入/输出及副作用：source（输入）、copy（输出）先置 null；成功时返回独立 status 快照，不调用 source.clone/do_copy。
  // 失败/边界：source 为空返回成功空值；status 对象分配失败返回 RESOURCE_EXHAUSTED，失败不伪造 OK 状态。
  protected function rdma_status clone_status_value_nonfatal(
    rdma_status source, output rdma_status copy
  );
    rdma_status candidate;
    uvm_object raw_candidate;

    copy = null;
    if (source == null) return make_runtime_status(RDMA_SC_OK, "");
    raw_candidate = factory_create_object_nonfatal(
      rdma_status::get_type(), "nonfatal_status_copy");
    if (raw_candidate == null || !$cast(candidate, raw_candidate))
      return make_runtime_status(RDMA_SC_RESOURCE_EXHAUSTED,
                                 "status copy allocation failed");
    candidate.category = source.category;
    candidate.code = source.code;
    candidate.hardware_code = source.hardware_code;
    candidate.hardware_code_valid = source.hardware_code_valid;
    candidate.source_engine = source.source_engine;
    candidate.function_uid = source.function_uid;
    candidate.generation = source.generation;
    candidate.resource_id = source.resource_id;
    candidate.command_id = source.command_id;
    candidate.wr_id = source.wr_id;
    candidate.severity = source.severity;
    candidate.retryable = source.retryable;
    candidate.message = source.message;
    copy = candidate;
    return make_runtime_status(RDMA_SC_OK, "");
  endfunction

  // 功能：clone_slot_value_nonfatal 为一个已校验的 host WQE ledger entry 建立
  //   完整 detached 值副本，供 CQ poll 在任何 consumer 副作用前预物化结果。
  // 输入/输出及副作用：source 为输入、copy 为输出并先置 null；复制 slot 标量、
  //   request_snapshot、image 与 completion_status，不修改 runtime-owned source。
  // 失败/边界：source 为空、raw factory 返回 null/错误类型，或任一 nested value
  //   复制失败时返回非成功且 copy=null；调用方必须丢弃整个 range candidate。
  protected function rdma_status clone_slot_value_nonfatal(
    rdma_queue_slot_ledger_entry source,
    output rdma_queue_slot_ledger_entry copy
  );
    rdma_queue_slot_ledger_entry candidate;
    rdma_status status;
    uvm_object raw_candidate;

    copy = null;
    if (source == null)
      return make_runtime_status(RDMA_SC_INVALID_STATE,
                                 "release range contains a null slot");
    raw_candidate = factory_create_object_nonfatal(
      rdma_queue_slot_ledger_entry::get_type(), "release_range_slot_copy");
    if (raw_candidate == null || !$cast(candidate, raw_candidate))
      return make_runtime_status(RDMA_SC_RESOURCE_EXHAUSTED,
                                 "release range slot allocation failed");
    status = clone_request_value_nonfatal(source.request_snapshot,
                                          candidate.request_snapshot);
    if (!status_is_ok(status))
      return status == null ?
        make_runtime_status(RDMA_SC_RESOURCE_EXHAUSTED,
                            "release range request copy returned null status") :
        status;
    status = clone_image_value_nonfatal(source.image, candidate.image);
    if (!status_is_ok(status))
      return status == null ?
        make_runtime_status(RDMA_SC_RESOURCE_EXHAUSTED,
                            "release range image copy returned null status") :
        status;
    status = clone_status_value_nonfatal(source.completion_status,
                                         candidate.completion_status);
    if (!status_is_ok(status))
      return status == null ?
        make_runtime_status(RDMA_SC_RESOURCE_EXHAUSTED,
                            "release range status copy returned null status") :
        status;
    candidate.posted = source.posted;
    candidate.consumed = source.consumed;
    candidate.signaled = source.signaled;
    candidate.wr_id = source.wr_id;
    candidate.index = source.index;
    candidate.wrap = source.wrap;
    copy = candidate;
    return make_runtime_status(RDMA_SC_OK, "");
  endfunction

  // 功能：clone_address_vector_value_nonfatal 复制 UD address-vector 的固定数组和所有路由字段，形成 detached 值快照。
  // 输入/输出及副作用：source（输入）、copy（输出）先置 null；成功时 copy 与 source 完全隔离，调用方继续拥有 source。
  // 失败/边界：source 为空返回空成功；对象工厂分配失败返回 RESOURCE_EXHAUSTED，失败时不发布半成品 address vector。
  protected function rdma_status clone_address_vector_value_nonfatal(
    rdma_address_vector source, output rdma_address_vector copy
  );
    rdma_address_vector candidate;
    uvm_object raw_candidate;

    copy = null;
    if (source == null) return make_runtime_status(RDMA_SC_OK, "");
    raw_candidate = factory_create_object_nonfatal(
      rdma_address_vector::get_type(), "nonfatal_address_vector_copy");
    if (raw_candidate == null || !$cast(candidate, raw_candidate))
      return make_runtime_status(RDMA_SC_RESOURCE_EXHAUSTED,
                                 "address vector copy allocation failed");
    candidate.source_address_index = source.source_address_index;
    candidate.source_vport = source.source_vport;
    candidate.destination_vport = source.destination_vport;
    candidate.destination_port = source.destination_port;
    candidate.destination_mac = source.destination_mac;
    foreach (candidate.destination_ip[i])
      candidate.destination_ip[i] = source.destination_ip[i];
    candidate.ipv6 = source.ipv6;
    candidate.vlan_enable = source.vlan_enable;
    candidate.cfi = source.cfi;
    candidate.lag_enable = source.lag_enable;
    candidate.tunnel_enable = source.tunnel_enable;
    candidate.forwarding_enable = source.forwarding_enable;
    candidate.vlan_id = source.vlan_id;
    candidate.traffic_class = source.traffic_class;
    candidate.flow_label = source.flow_label;
    candidate.hop_limit = source.hop_limit;
    candidate.udp_source_port = source.udp_source_port;
    candidate.\priority = source.\priority ;
    candidate.multicast = source.multicast;
    candidate.forwarding_mode = source.forwarding_mode;
    copy = candidate;
    return make_runtime_status(RDMA_SC_OK, "");
  endfunction

  // 功能：clone_request_value_nonfatal 复制 semantic/post-send request 的标量、owner、目标句柄、地址向量和 SGE 值。
  // 输入/输出及副作用：source（输入）、copy（输出）先置 null；成功时 copy 为 detached request snapshot，源请求及其 nested SGE 不被修改。
  // 失败/边界：source 为空返回成功空值；不支持的 request subclass、nested 对象或任一分配失败返回 RESOURCE_EXHAUSTED，严禁发布半拷贝请求。
  protected function rdma_status clone_request_value_nonfatal(
    rdma_semantic_request source, output rdma_semantic_request copy
  );
    rdma_semantic_request candidate;
    rdma_post_send_req post_source;
    rdma_post_recv_req recv_source;
    rdma_post_send_req post_candidate;
    rdma_post_recv_req recv_candidate;
    rdma_handle handle_copy;
    rdma_function_handle owner_copy;
    rdma_address_vector address_vector_copy;
    rdma_sge sge_copy;
    rdma_status status;
    uvm_object raw_candidate;

    copy = null;
    if (source == null) return make_runtime_status(RDMA_SC_OK, "");

    if ($cast(post_source, source)) begin
      raw_candidate = factory_create_object_nonfatal(
        rdma_post_send_req::get_type(), "nonfatal_post_request_copy");
      if (raw_candidate == null || !$cast(post_candidate, raw_candidate))
        return make_runtime_status(RDMA_SC_RESOURCE_EXHAUSTED,
                                   "post request copy allocation failed");
      candidate = post_candidate;
    end
    else if ($cast(recv_source, source)) begin
      raw_candidate = factory_create_object_nonfatal(
        rdma_post_recv_req::get_type(), "nonfatal_recv_request_copy");
      if (raw_candidate == null || !$cast(recv_candidate, raw_candidate))
        return make_runtime_status(RDMA_SC_RESOURCE_EXHAUSTED,
                                   "receive request copy allocation failed");
      candidate = recv_candidate;
    end else begin
      return make_runtime_status(RDMA_SC_INVALID_ARGUMENT,
                                 "unsupported semantic request subclass");
    end

    candidate.request_id = source.request_id;
    candidate.correlation_id = source.correlation_id;
    candidate.expected_status_code = source.expected_status_code;
    candidate.timeout_policy = source.timeout_policy;
    candidate.timeout_value = source.timeout_value;
    if (source.owner != null) begin
      raw_candidate = factory_create_object_nonfatal(
        rdma_function_handle::get_type(), "nonfatal_owner_copy");
      if (raw_candidate == null || !$cast(owner_copy, raw_candidate))
        return make_runtime_status(RDMA_SC_RESOURCE_EXHAUSTED,
                                   "request owner copy allocation failed");
      owner_copy.kind = source.owner.kind;
      owner_copy.function_uid = source.owner.function_uid;
      owner_copy.object_id = source.owner.object_id;
      owner_copy.generation = source.owner.generation;
      candidate.owner = owner_copy;
    end

    if (post_source != null) begin
      status = clone_handle_value_nonfatal(post_source.qp_h, handle_copy);
      if (!status_is_ok(status))
        return (status == null) ?
          make_runtime_status(RDMA_SC_RESOURCE_EXHAUSTED,
                              "post QP handle copy returned null status") : status;
      post_candidate.qp_h = handle_copy;
      post_candidate.wr_id = post_source.wr_id;
      post_candidate.transport = post_source.transport;
      post_candidate.opcode = post_source.opcode;
      post_candidate.inline_data = post_source.inline_data;
      post_candidate.payload = post_source.payload;
      post_candidate.signaled = post_source.signaled;
      post_candidate.solicited = post_source.solicited;
      post_candidate.immediate_data = post_source.immediate_data;
      post_candidate.remote_addr = post_source.remote_addr;
      post_candidate.rkey = post_source.rkey;
      post_candidate.remote_access_valid = post_source.remote_access_valid;
      post_candidate.rkey_valid = post_source.rkey_valid;
      post_candidate.destination_qpn = post_source.destination_qpn;
      post_candidate.qkey = post_source.qkey;
      post_candidate.invalidate_rkey = post_source.invalidate_rkey;
      status = clone_handle_value_nonfatal(post_source.completion_qp_h,
                                           handle_copy);
      if (!status_is_ok(status))
        return (status == null) ?
          make_runtime_status(RDMA_SC_RESOURCE_EXHAUSTED,
                              "completion QP copy returned null status") : status;
      post_candidate.completion_qp_h = handle_copy;
      status = clone_handle_value_nonfatal(post_source.mr_h, handle_copy);
      if (!status_is_ok(status))
        return (status == null) ?
          make_runtime_status(RDMA_SC_RESOURCE_EXHAUSTED,
                              "MR handle copy returned null status") : status;
      post_candidate.mr_h = handle_copy;
      status = clone_handle_value_nonfatal(post_source.mw_h, handle_copy);
      if (!status_is_ok(status))
        return (status == null) ?
          make_runtime_status(RDMA_SC_RESOURCE_EXHAUSTED,
                              "MW handle copy returned null status") : status;
      post_candidate.mw_h = handle_copy;
      status = clone_handle_value_nonfatal(post_source.authority_h, handle_copy);
      if (!status_is_ok(status))
        return (status == null) ?
          make_runtime_status(RDMA_SC_RESOURCE_EXHAUSTED,
                              "authority handle copy returned null status") : status;
      post_candidate.authority_h = handle_copy;
      status = clone_address_vector_value_nonfatal(post_source.address_vector,
                                                   address_vector_copy);
      if (!status_is_ok(status))
        return (status == null) ?
          make_runtime_status(RDMA_SC_RESOURCE_EXHAUSTED,
                              "address vector copy returned null status") : status;
      post_candidate.address_vector = address_vector_copy;
      post_candidate.fence = post_source.fence;
      post_candidate.address_vector_id = post_source.address_vector_id;
      post_candidate.address_vector_valid = post_source.address_vector_valid;
      post_candidate.sgb_iova = post_source.sgb_iova;
      post_candidate.compare_value = post_source.compare_value;
      post_candidate.swap_add_value = post_source.swap_add_value;
      post_candidate.sges.delete();
      foreach (post_source.sges[i]) begin
        if (post_source.sges[i] == null) begin post_candidate.sges.push_back(null); end
        else begin
          raw_candidate = factory_create_object_nonfatal(
            rdma_sge::get_type(), $sformatf("nonfatal_sge_%0d", i));
          if (raw_candidate == null || !$cast(sge_copy, raw_candidate))
            return make_runtime_status(RDMA_SC_RESOURCE_EXHAUSTED,
                                       "SGE copy allocation failed");
          sge_copy.iova = post_source.sges[i].iova;
          sge_copy.length = post_source.sges[i].length;
          sge_copy.lkey = post_source.sges[i].lkey;
          post_candidate.sges.push_back(sge_copy);
        end
      end
    end
    else if (recv_source != null) begin
      status = clone_handle_value_nonfatal(recv_source.target_h, handle_copy);
      if (!status_is_ok(status))
        return (status == null) ?
          make_runtime_status(RDMA_SC_RESOURCE_EXHAUSTED,
                              "receive target copy returned null status") : status;
      recv_candidate.target_h = handle_copy;
      status = clone_handle_value_nonfatal(recv_source.completion_qp_h,
                                           handle_copy);
      if (!status_is_ok(status))
        return (status == null) ?
          make_runtime_status(RDMA_SC_RESOURCE_EXHAUSTED,
                              "receive completion QP copy returned null status") : status;
      recv_candidate.completion_qp_h = handle_copy;
      recv_candidate.wr_id = recv_source.wr_id;
      recv_candidate.sges.delete();
      foreach (recv_source.sges[i]) begin
        if (recv_source.sges[i] == null) begin
          recv_candidate.sges.push_back(null);
        end else begin
          raw_candidate = factory_create_object_nonfatal(
            rdma_sge::get_type(), $sformatf("nonfatal_recv_sge_%0d", i));
          if (raw_candidate == null || !$cast(sge_copy, raw_candidate))
            return make_runtime_status(RDMA_SC_RESOURCE_EXHAUSTED,
                                       "receive SGE copy allocation failed");
          sge_copy.iova = recv_source.sges[i].iova;
          sge_copy.length = recv_source.sges[i].length;
          sge_copy.lkey = recv_source.sges[i].lkey;
          recv_candidate.sges.push_back(sge_copy);
        end
      end
    end
    copy = candidate;
    return make_runtime_status(RDMA_SC_OK, "");
  endfunction

  // 功能：handle_value_equal 对两个 nullable handle 执行完整 identity 值比较，
  //   供 prepared recovery 区分同一对象与跨 kind/Function/generation 的证据。
  // 输入/输出及副作用：lhs/rhs（输入）；只读四个 identity 字段并返回 bit，
  //   不 clone、修改或接管任一 handle。
  // 失败/边界：两个 null 视为相等；仅一侧 null 或任一 identity 字段不等时返回 0。
  protected function bit handle_value_equal(rdma_handle lhs, rdma_handle rhs);
    if (lhs == null || rhs == null)
      return lhs == null && rhs == null;
    return lhs.kind == rhs.kind &&
           lhs.function_uid == rhs.function_uid &&
           lhs.object_id == rhs.object_id &&
           lhs.generation == rhs.generation;
  endfunction

  // 功能：handle_value_matches_snapshot 将 target handle 与 copy_ring_state 在
  // source lock 内冻结的四元 identity 值比较，复用与普通 handle 比较相同的字段语义。
  // 输入/输出及副作用：candidate（输入）为当前 target 的非拥有句柄；expected_kind、
  // expected_function_uid、expected_object_id、expected_generation（输入）是 source
  // 的 detached scalar snapshot；函数只读参数并返回 bit，不修改任何对象或 runtime。
  // 失败/边界：candidate 为空时返回 0；调用方必须先拒绝 source 为空并保证 snapshot
  // 已由 source 的有效 queue_h 填充；kind、Function UID、object ID 或 generation
  // 任一不等都返回 0，避免在释放 source lock 后重新读取可变对象。
  protected function bit handle_value_matches_snapshot(
    rdma_handle candidate,
    rdma_resource_kind_e expected_kind,
    longint unsigned expected_function_uid,
    int unsigned expected_object_id,
    int unsigned expected_generation
  );
    if (candidate == null)
      return 1'b0;
    return candidate.kind == expected_kind &&
           candidate.function_uid == expected_function_uid &&
           candidate.object_id == expected_object_id &&
           candidate.generation == expected_generation;
  endfunction

  // 功能：same_route_epoch_value 比较两个已由调用方取得的 route/epoch 值快照，
  //   为 ring copy 与 prepared recovery 复用同一组值字段相等语义。
  // 输入/输出及副作用：lhs_route/lhs_epoch 与 rhs_route/rhs_epoch（输入）是
  //   两组 packed route key 和 reset epoch；函数只读这些值并返回 bit，不修改
  //   runtime、valid-bit、锁或任何外部 authority。
  // 失败/边界：任一路由 key 或 reset epoch 不等即返回 0；本 helper 不检查
  //   route/epoch valid-bit、route key 格式或 reset freshness，相关拒绝条件仍由
  //   copy_ring_state 与 enter_recovery_prepared 的调用方先行处理。
  protected function bit same_route_epoch_value(
    rdma_route_key_t lhs_route,
    rdma_reset_epoch_t lhs_epoch,
    rdma_route_key_t rhs_route,
    rdma_reset_epoch_t rhs_epoch
  );
    return lhs_route == rhs_route && lhs_epoch == rhs_epoch;
  endfunction

  // 功能：image_value_equal 比较 recovery image 的全部 metadata、目标地址、
  //   原始 bytes 与 field_summary，防止不同硬件事务共享同一 cursor 后合并阶段。
  // 输入/输出及副作用：lhs/rhs（输入）；逐值只读并返回 bit，不修改动态队列。
  // 失败/边界：两个 null 视为相等；长度、任一 metadata/byte/summary 不同均返回 0。
  protected function bit image_value_equal(rdma_hw_image lhs, rdma_hw_image rhs);
    if (lhs == null || rhs == null)
      return lhs == null && rhs == null;
    if (lhs.length != rhs.length || lhs.alignment != rhs.alignment ||
        lhs.endian != rhs.endian || lhs.image_kind != rhs.image_kind ||
        lhs.hardware_version != rhs.hardware_version ||
        lhs.function_generation != rhs.function_generation ||
        lhs.write_target_kind != rhs.write_target_kind ||
        lhs.backing_target != rhs.backing_target ||
        lhs.hmc_target != rhs.hmc_target || lhs.bar_target != rhs.bar_target ||
        lhs.bytes.size() != rhs.bytes.size() ||
        lhs.field_summary.size() != rhs.field_summary.size())
      return 1'b0;
    foreach (lhs.bytes[i])
      if (lhs.bytes[i] != rhs.bytes[i]) return 1'b0;
    foreach (lhs.field_summary[i])
      if (lhs.field_summary[i] != rhs.field_summary[i]) return 1'b0;
    return 1'b1;
  endfunction

  // 功能：status_value_equal 比较原始 failure_status 的错误分类、硬件上下文、
  //   transaction identity、严重度、retry 属性与诊断文本。
  // 输入/输出及副作用：lhs/rhs（输入）；只读 status 并返回 bit，不改写错误快照。
  // 失败/边界：两个 null 视为相等；仅一侧 null 或任一诊断字段不等时返回 0。
  protected function bit status_value_equal(rdma_status lhs, rdma_status rhs);
    if (lhs == null || rhs == null)
      return lhs == null && rhs == null;
    return lhs.category == rhs.category && lhs.code == rhs.code &&
           lhs.hardware_code == rhs.hardware_code &&
           lhs.hardware_code_valid == rhs.hardware_code_valid &&
           lhs.source_engine == rhs.source_engine &&
           lhs.function_uid == rhs.function_uid &&
           lhs.generation == rhs.generation &&
           lhs.resource_id == rhs.resource_id &&
           lhs.command_id == rhs.command_id && lhs.wr_id == rhs.wr_id &&
           lhs.severity == rhs.severity && lhs.retryable == rhs.retryable &&
           lhs.message == rhs.message;
  endfunction

  // 功能：address_vector_value_equal 比较 post-send request 内完整 UD
  //   address-vector，包括固定 destination_ip 数组和全部转发/封装属性。
  // 输入/输出及副作用：lhs/rhs（输入）；逐字段只读并返回 bit，不修改 AV。
  // 失败/边界：两个 null 视为相等；仅一侧 null 或任一路由字段不等时返回 0。
  protected function bit address_vector_value_equal(
    rdma_address_vector lhs, rdma_address_vector rhs
  );
    if (lhs == null || rhs == null)
      return lhs == null && rhs == null;
    if (lhs.source_address_index != rhs.source_address_index ||
        lhs.source_vport != rhs.source_vport ||
        lhs.destination_vport != rhs.destination_vport ||
        lhs.destination_port != rhs.destination_port ||
        lhs.destination_mac != rhs.destination_mac || lhs.ipv6 != rhs.ipv6 ||
        lhs.vlan_enable != rhs.vlan_enable || lhs.cfi != rhs.cfi ||
        lhs.lag_enable != rhs.lag_enable ||
        lhs.tunnel_enable != rhs.tunnel_enable ||
        lhs.forwarding_enable != rhs.forwarding_enable ||
        lhs.vlan_id != rhs.vlan_id ||
        lhs.traffic_class != rhs.traffic_class ||
        lhs.flow_label != rhs.flow_label || lhs.hop_limit != rhs.hop_limit ||
        lhs.udp_source_port != rhs.udp_source_port ||
        lhs.\priority  != rhs.\priority  ||
        lhs.multicast != rhs.multicast ||
        lhs.forwarding_mode != rhs.forwarding_mode)
      return 1'b0;
    foreach (lhs.destination_ip[i])
      if (lhs.destination_ip[i] != rhs.destination_ip[i]) return 1'b0;
    return 1'b1;
  endfunction

  // 功能：request_value_equal 按实际 post-send/post-recv subclass 比较 semantic
  //   base、owner、nested handles/address-vector、payload 与每个 nullable SGE。
  // 输入/输出及副作用：lhs/rhs（输入）；只读完整 request object graph 并返回 bit，
  //   不 clone 或改变 caller/runtime 持有的 request。
  // 失败/边界：两个 null 视为相等；subclass 不同、不支持的 subclass、任一 nested
  //   null 形态或值字段不同均返回 0。
  protected function bit request_value_equal(
    rdma_semantic_request lhs, rdma_semantic_request rhs
  );
    rdma_post_send_req lhs_send;
    rdma_post_send_req rhs_send;
    rdma_post_recv_req lhs_recv;
    rdma_post_recv_req rhs_recv;

    if (lhs == null || rhs == null)
      return lhs == null && rhs == null;
    if (lhs.request_id != rhs.request_id ||
        lhs.correlation_id != rhs.correlation_id ||
        !handle_value_equal(lhs.owner, rhs.owner) ||
        lhs.expected_status_code != rhs.expected_status_code ||
        lhs.timeout_policy != rhs.timeout_policy ||
        lhs.timeout_value != rhs.timeout_value)
      return 1'b0;

    if ($cast(lhs_send, lhs)) begin
      if (!$cast(rhs_send, rhs)) return 1'b0;
      if (!handle_value_equal(lhs_send.qp_h, rhs_send.qp_h) ||
          lhs_send.wr_id != rhs_send.wr_id ||
          lhs_send.transport != rhs_send.transport ||
          lhs_send.opcode != rhs_send.opcode ||
          lhs_send.inline_data != rhs_send.inline_data ||
          lhs_send.payload.size() != rhs_send.payload.size() ||
          lhs_send.signaled != rhs_send.signaled ||
          lhs_send.solicited != rhs_send.solicited ||
          lhs_send.immediate_data != rhs_send.immediate_data ||
          lhs_send.remote_addr != rhs_send.remote_addr ||
          lhs_send.rkey != rhs_send.rkey ||
          lhs_send.remote_access_valid != rhs_send.remote_access_valid ||
          lhs_send.rkey_valid != rhs_send.rkey_valid ||
          lhs_send.destination_qpn != rhs_send.destination_qpn ||
          lhs_send.qkey != rhs_send.qkey ||
          lhs_send.invalidate_rkey != rhs_send.invalidate_rkey ||
          !handle_value_equal(lhs_send.completion_qp_h,
                              rhs_send.completion_qp_h) ||
          !handle_value_equal(lhs_send.mr_h, rhs_send.mr_h) ||
          !handle_value_equal(lhs_send.mw_h, rhs_send.mw_h) ||
          !handle_value_equal(lhs_send.authority_h, rhs_send.authority_h) ||
          lhs_send.address_vector_id != rhs_send.address_vector_id ||
          !address_vector_value_equal(lhs_send.address_vector,
                                      rhs_send.address_vector) ||
          lhs_send.fence != rhs_send.fence ||
          lhs_send.address_vector_valid != rhs_send.address_vector_valid ||
          lhs_send.sgb_iova != rhs_send.sgb_iova ||
          lhs_send.compare_value != rhs_send.compare_value ||
          lhs_send.swap_add_value != rhs_send.swap_add_value ||
          lhs_send.sges.size() != rhs_send.sges.size())
        return 1'b0;
      foreach (lhs_send.payload[i])
        if (lhs_send.payload[i] != rhs_send.payload[i]) return 1'b0;
      foreach (lhs_send.sges[i]) begin
        if (lhs_send.sges[i] == null || rhs_send.sges[i] == null) begin
          if (!(lhs_send.sges[i] == null && rhs_send.sges[i] == null))
            return 1'b0;
        end else if (lhs_send.sges[i].iova != rhs_send.sges[i].iova ||
                     lhs_send.sges[i].length != rhs_send.sges[i].length ||
                     lhs_send.sges[i].lkey != rhs_send.sges[i].lkey) begin
          return 1'b0;
        end
      end
      return 1'b1;
    end

    if ($cast(lhs_recv, lhs)) begin
      if (!$cast(rhs_recv, rhs)) return 1'b0;
      if (!handle_value_equal(lhs_recv.target_h, rhs_recv.target_h) ||
          !handle_value_equal(lhs_recv.completion_qp_h,
                              rhs_recv.completion_qp_h) ||
          lhs_recv.wr_id != rhs_recv.wr_id ||
          lhs_recv.sges.size() != rhs_recv.sges.size())
        return 1'b0;
      foreach (lhs_recv.sges[i]) begin
        if (lhs_recv.sges[i] == null || rhs_recv.sges[i] == null) begin
          if (!(lhs_recv.sges[i] == null && rhs_recv.sges[i] == null))
            return 1'b0;
        end else if (lhs_recv.sges[i].iova != rhs_recv.sges[i].iova ||
                     lhs_recv.sges[i].length != rhs_recv.sges[i].length ||
                     lhs_recv.sges[i].lkey != rhs_recv.sges[i].lkey) begin
          return 1'b0;
        end
      end
      return 1'b1;
    end
    return 1'b0;
  endfunction

  // 功能：pending_immutable_evidence_equal 比较 prepared 重入不可借用的完整
  //   transaction evidence；MMIO enum 与阶段位由后续单调 merge 规则单独处理。
  // 输入/输出及副作用：lhs/rhs（输入）；只读 pending 及嵌套值对象并返回 bit，
  //   不投影 MMIO、不分配对象、不改变当前 pending。
  // 失败/边界：任一 pending/null nested immutable、identity/cursor/image/status/
  //   request/WR/completion/routed-QP/route-epoch 值不等时返回 0。
  protected function bit pending_immutable_evidence_equal(
    rdma_queue_pending_operation lhs,
    rdma_queue_pending_operation rhs
  );
    if (lhs == null || rhs == null) return 1'b0;
    return handle_value_equal(lhs.queue_h, rhs.queue_h) &&
           lhs.kind == rhs.kind && lhs.producer == rhs.producer &&
           lhs.device_producer == rhs.device_producer &&
           lhs.entry_offset == rhs.entry_offset &&
           lhs.entry_size == rhs.entry_size &&
           lhs.cursor != null && rhs.cursor != null &&
           cursor_equal(lhs.cursor.index, lhs.cursor.wrap,
                        rhs.cursor.index, rhs.cursor.wrap) &&
           lhs.next_cursor != null && rhs.next_cursor != null &&
           cursor_equal(lhs.next_cursor.index, lhs.next_cursor.wrap,
                        rhs.next_cursor.index, rhs.next_cursor.wrap) &&
           image_value_equal(lhs.image, rhs.image) &&
           status_value_equal(lhs.failure_status, rhs.failure_status) &&
           request_value_equal(lhs.request_snapshot, rhs.request_snapshot) &&
           lhs.wr_id == rhs.wr_id && lhs.signaled == rhs.signaled &&
           lhs.completion_index == rhs.completion_index &&
           lhs.completion_wrap == rhs.completion_wrap &&
           lhs.completion_target_valid == rhs.completion_target_valid &&
           lhs.completion_wq_kind == rhs.completion_wq_kind &&
           handle_value_equal(lhs.routed_qp_h, rhs.routed_qp_h) &&
           lhs.consumer_shadow_required == rhs.consumer_shadow_required &&
           lhs.consumer_shadow_urc == rhs.consumer_shadow_urc &&
           lhs.consumer_shadow_offset == rhs.consumer_shadow_offset &&
           lhs.consumer_shadow_length == rhs.consumer_shadow_length &&
           lhs.consumer_shadow_value == rhs.consumer_shadow_value &&
           lhs.route == rhs.route && lhs.route_valid == rhs.route_valid &&
           lhs.reset_epoch == rhs.reset_epoch &&
           lhs.epoch_valid == rhs.epoch_valid;
  endfunction

  // 功能：clone_pending_value 原子建立完整 pending evidence，串联所有 non-fatal value-copy helper。
  // 输入/输出及副作用：source（输入）、copy（输出）先置 null；成功时 copy 包含所有嵌套快照与阶段位，source 不被修改。
  // 失败/边界：source 为空返回 INVALID_ARGUMENT；任一 helper 失败均丢弃 candidate、返回 RESOURCE_EXHAUSTED，runtime 不发布半状态。
  protected function rdma_status clone_pending_value(
    rdma_queue_pending_operation source,
    output rdma_queue_pending_operation copy
  );
    rdma_queue_pending_operation candidate;
    rdma_status status;
    uvm_object raw_candidate;

    copy = null;
    if (source == null)
      return make_runtime_status(RDMA_SC_INVALID_ARGUMENT,
                                 "pending source is null");
    if (source.device_producer &&
        (source.queue_h == null || source.cursor == null ||
         source.next_cursor == null || source.image == null))
      return make_runtime_status(RDMA_SC_INVALID_ARGUMENT,
                                 "device pending lacks required evidence");
    raw_candidate = factory_create_object_nonfatal(
      rdma_queue_pending_operation::get_type(), "nonfatal_pending_copy");
    if (raw_candidate == null || !$cast(candidate, raw_candidate))
      return make_runtime_status(RDMA_SC_RESOURCE_EXHAUSTED,
                                 "pending copy allocation failed");

    status = clone_handle_value_nonfatal(source.queue_h, candidate.queue_h);
    if (!status_is_ok(status))
      return (status == null) ?
        make_runtime_status(RDMA_SC_RESOURCE_EXHAUSTED,
                            "pending queue copy returned null status") : status;
    status = clone_cursor_value_nonfatal(source.cursor, candidate.cursor);
    if (!status_is_ok(status))
      return (status == null) ?
        make_runtime_status(RDMA_SC_RESOURCE_EXHAUSTED,
                            "pending cursor copy returned null status") : status;
    status = clone_cursor_value_nonfatal(source.next_cursor, candidate.next_cursor);
    if (!status_is_ok(status))
      return (status == null) ?
        make_runtime_status(RDMA_SC_RESOURCE_EXHAUSTED,
                            "pending next cursor copy returned null status") : status;
    status = clone_cursor_value_nonfatal(source.committed_consumer_cursor,
                                         candidate.committed_consumer_cursor);
    if (!status_is_ok(status))
      return (status == null) ?
        make_runtime_status(RDMA_SC_RESOURCE_EXHAUSTED,
                            "pending committed cursor copy returned null status") : status;
    status = clone_image_value_nonfatal(source.image, candidate.image);
    if (!status_is_ok(status))
      return (status == null) ?
        make_runtime_status(RDMA_SC_RESOURCE_EXHAUSTED,
                            "pending image copy returned null status") : status;
    status = clone_status_value_nonfatal(source.failure_status,
                                         candidate.failure_status);
    if (!status_is_ok(status))
      return (status == null) ?
        make_runtime_status(RDMA_SC_RESOURCE_EXHAUSTED,
                            "pending failure status copy returned null status") : status;
    status = clone_request_value_nonfatal(source.request_snapshot,
                                          candidate.request_snapshot);
    if (!status_is_ok(status))
      return (status == null) ?
        make_runtime_status(RDMA_SC_RESOURCE_EXHAUSTED,
                            "pending request copy returned null status") : status;
    status = clone_handle_value_nonfatal(source.routed_qp_h,
                                         candidate.routed_qp_h);
    if (!status_is_ok(status))
      return (status == null) ?
        make_runtime_status(RDMA_SC_RESOURCE_EXHAUSTED,
                            "pending routed QP copy returned null status") : status;
    candidate.kind = source.kind;
    candidate.producer = source.producer;
    candidate.device_producer = source.device_producer;
    candidate.device_write_attempted = source.device_write_attempted;
    candidate.consumer_committed = source.consumer_committed;
    candidate.cq_consumer_committed = source.cq_consumer_committed;
    candidate.completion_released = source.completion_released;
    candidate.consumer_doorbell_succeeded = source.consumer_doorbell_succeeded;
    candidate.consumer_shadow_required = source.consumer_shadow_required;
    candidate.consumer_shadow_urc = source.consumer_shadow_urc;
    candidate.consumer_shadow_attempted = source.consumer_shadow_attempted;
    candidate.consumer_shadow_published = source.consumer_shadow_published;
    candidate.consumer_shadow_offset = source.consumer_shadow_offset;
    candidate.consumer_shadow_length = source.consumer_shadow_length;
    candidate.consumer_shadow_value = source.consumer_shadow_value;
    candidate.entry_offset = source.entry_offset;
    candidate.wr_id = source.wr_id;
    candidate.signaled = source.signaled;
    candidate.completion_index = source.completion_index;
    candidate.completion_wrap = source.completion_wrap;
    candidate.completion_target_valid = source.completion_target_valid;
    candidate.completion_wq_kind = source.completion_wq_kind;
    candidate.mmio_maybe_submitted = source.mmio_maybe_submitted;
    candidate.known_no_mmio = source.known_no_mmio;
    candidate.mmio_evidence = source.mmio_evidence;
    candidate.entry_size = source.entry_size;
    candidate.route = source.route;
    candidate.route_valid = source.route_valid;
    candidate.reset_epoch = source.reset_epoch;
    candidate.epoch_valid = source.epoch_valid;
    copy = candidate;
    return make_runtime_status(RDMA_SC_OK, "");
  endfunction

  // 功能：构造 DETACHED、未配置的 runtime，并创建容量为 1 的状态互斥锁。
  // 输入/输出及副作用：name（输入）设置 UVM 名称；清零 geometry/authority/
  //   occupancy，置空 queue、reservation、pending 和 recovery 授权。
  // 失败/边界：构造后除 configure/query_state 外的事务入口都应拒绝未配置
  //   runtime；对象不创建或接管 Host-memory、PCIe 或 lifecycle resource。
  function new(string name = "rdma_queue_runtime");
    super.new(name);
    queue_h = null;
    kind = RDMA_QUEUE_RUNTIME_SQ;
    state = RDMA_QUEUE_RUNTIME_DETACHED;
    depth = 0;
    producer_index = 0;
    consumer_index = 0;
    producer_wrap = 0;
    consumer_wrap = 0;
    initial_polarity = 0;
    route = '0;
    route_valid = 0;
    reset_epoch = 0;
    epoch_valid = 0;
    used = 0;
    pending_operation_state = null;
    host_produced = 0;
    device_reservation_valid = 0;
    device_reservation = null;
    lock = new(1);
    recovery_commit_allowed = 0;
    consumer_release_gate_active = 0;
    recovery_retry_confirmed = 0;
  endfunction

  // 功能：configure 校验 ring 方向、几何与初始游标，构造临时句柄/账本并一次性发布 ATTACHED runtime 配置。
  // 输入/输出及副作用：qh、k、d、pi、pw、ci、cw、host_produced_cfg、initial_owner_polarity（输入）；成功时锁存游标、方向、occupancy 与 detached handle，并清空 recovery/release gate；外部资源仍由调用方拥有。
  // 失败/边界：空句柄、重复配置、深度非二次幂、游标越界/组合非法、方向与 queue kind 不匹配或临时对象分配失败时返回错误，并保留旧状态。
  function rdma_status configure(rdma_handle qh, rdma_queue_runtime_kind_e k,
                                 int unsigned d, int unsigned pi, bit pw,
                                 int unsigned ci, bit cw, bit host_produced_cfg,
                                 bit initial_owner_polarity = 1'b0);
    rdma_status lock_status;
    rdma_handle queue_snapshot;
    rdma_queue_slot_ledger_entry staged_slots[];
    rdma_status copy_status;
    int unsigned staged_used;
    bit device_kind;
    bit expected_host_direction;
    rdma_resource_kind_e expected_resource_kind;
    uvm_object raw_slot;

    lock_status = acquire_lock();
    if (!status_is_ok(lock_status)) return lock_status;
    if (state != RDMA_QUEUE_RUNTIME_DETACHED) begin
      lock.put(1);
      return make_runtime_status(RDMA_SC_INVALID_STATE,
                                 "queue runtime is already configured");
    end
    if (qh == null) begin
      lock.put(1);
      return make_runtime_status(RDMA_SC_INVALID_ARGUMENT,
                                 "queue handle is null");
    end
    if (d == 0 || (d & (d - 1)) != 0) begin
      lock.put(1);
      return make_runtime_status(RDMA_SC_INVALID_ARGUMENT,
                                 "queue depth is not a power of two");
    end
    if (pi >= d || ci >= d) begin
      lock.put(1);
      return make_runtime_status(RDMA_SC_INVALID_ARGUMENT,
                                 "queue cursor is outside depth");
    end
    if (!(k inside {RDMA_QUEUE_RUNTIME_SQ, RDMA_QUEUE_RUNTIME_RQ,
                    RDMA_QUEUE_RUNTIME_SRQ, RDMA_QUEUE_RUNTIME_CQ,
                    RDMA_QUEUE_RUNTIME_CEQ, RDMA_QUEUE_RUNTIME_AEQ})) begin
      lock.put(1);
      return make_runtime_status(RDMA_SC_INVALID_ARGUMENT,
                                 "queue runtime kind is invalid");
    end
    device_kind = k inside {RDMA_QUEUE_RUNTIME_CQ,
                            RDMA_QUEUE_RUNTIME_CEQ,
                            RDMA_QUEUE_RUNTIME_AEQ};
    expected_host_direction = !device_kind;
    case (k)
      RDMA_QUEUE_RUNTIME_CQ: expected_resource_kind = RDMA_RESOURCE_CQ;
      RDMA_QUEUE_RUNTIME_CEQ: expected_resource_kind = RDMA_RESOURCE_CEQ;
      RDMA_QUEUE_RUNTIME_AEQ: expected_resource_kind = RDMA_RESOURCE_AEQ;
      RDMA_QUEUE_RUNTIME_SRQ: expected_resource_kind = RDMA_RESOURCE_SRQ;
      default: expected_resource_kind = RDMA_RESOURCE_QP;
    endcase
    if (qh.kind != expected_resource_kind) begin
      lock.put(1);
      return make_runtime_status(RDMA_SC_INVALID_ARGUMENT,
                                 "queue handle kind does not match runtime kind");
    end
    if (host_produced_cfg != expected_host_direction) begin
      lock.put(1);
      return make_runtime_status(RDMA_SC_INVALID_ARGUMENT,
                                 "producer direction does not match queue kind");
    end
    // 设计说明：host ring 的 WQE occupancy 由 slots ledger 唯一表示，而 configure
    // 只会建立空 ledger；因此非空 PI/CI 距离不能在这里被静默解释为零 used。
    // resize 的冻结 ledger 由 copy_ring_state 导入，不经过这一空状态入口。
    if (!device_kind && (pi != ci || pw != cw)) begin
      lock.put(1);
      return make_runtime_status(
        RDMA_SC_INVALID_ARGUMENT,
        "host ring cursors require an empty configure ledger");
    end
    if (device_kind) begin
      if (pw == cw) begin
        if (pi < ci) begin
          lock.put(1);
          return make_runtime_status(RDMA_SC_INVALID_ARGUMENT,
                                     "same-wrap cursors are reversed");
        end
        staged_used = pi - ci;
      end else if (pi == ci) staged_used = d;
      else staged_used = d - ci + pi;
      if (staged_used > d) begin
        lock.put(1);
        return make_runtime_status(RDMA_SC_INVALID_ARGUMENT,
                                   "initial occupancy exceeds depth");
      end
    end else staged_used = 0;
    // 中文设计：lifecycle resource 仍是身份权威，但 runtime 必须保存独立值快照；
    // 调用方后续修改传给 configure 的 handle，不能绕过这里锁存的 generation fence。
    copy_status = clone_handle_value_nonfatal(qh, queue_snapshot);
    if (!status_is_ok(copy_status) || queue_snapshot == null) begin
      lock.put(1);
      return (copy_status != null && !copy_status.ok()) ? copy_status :
        make_runtime_status(RDMA_SC_RESOURCE_EXHAUSTED,
                            "queue runtime handle snapshot failed");
    end
    if (!device_kind) begin
      staged_slots = new[d];
      foreach (staged_slots[i]) begin
        raw_slot = factory_create_object_nonfatal(
          rdma_queue_slot_ledger_entry::get_type(),
          $sformatf("slot_%0d", i));
        if (raw_slot == null || !$cast(staged_slots[i], raw_slot)) begin
          lock.put(1);
          return make_runtime_status(RDMA_SC_RESOURCE_EXHAUSTED,
                                     "slot ledger allocation failed");
        end
      end
    end else staged_slots = new[0];
    // 中文设计：所有可失败的 identity/ledger staging 已完成；从此处开始
    // 一次性发布配置，避免 factory 失败留下半配置 runtime。
    queue_h = queue_snapshot;
    kind = k;
    depth = d;
    producer_index = pi;
    producer_wrap = pw;
    consumer_index = ci;
    consumer_wrap = cw;
    initial_polarity = initial_owner_polarity;
    host_produced = host_produced_cfg;
    used = staged_used;
    slots = staged_slots;
    pending_operation_state = null;
    device_reservation_valid = 0;
    device_reservation = null;
    route = '0;
    route_valid = 0;
    reset_epoch = 0;
    epoch_valid = 0;
    recovery_commit_allowed = 0;
    consumer_release_gate_active = 0;
    recovery_retry_confirmed = 0;
    state = RDMA_QUEUE_RUNTIME_ATTACHED;
    lock.put(1);
    return make_runtime_status(RDMA_SC_OK, "");
  endfunction

  // 功能：query_attachment_config 返回 configure 锁存的 queue identity、runtime
  //   kind、producer 方向与 initial polarity，替代外部直接读取 authority 字段。
  // 输入/输出及副作用：queue_snapshot/kind_snapshot/host_produced_snapshot/
  //   initial_polarity_snapshot（输出）先置安全默认值；成功时 queue 为 detached clone，
  //   其余为持锁值快照，不修改 runtime。
  // 失败/边界：未配置或已 DETACHED、queue handle 缺失、锁忙或 clone 分配失败时
  //   返回非成功，所有 output 保持 null/SQ/0/0，caller 不得使用默认值作 authority。
  function rdma_status query_attachment_config(
    output rdma_handle queue_snapshot,
    output rdma_queue_runtime_kind_e kind_snapshot,
    output bit host_produced_snapshot,
    output bit initial_polarity_snapshot
  );
    rdma_status lock_status;
    rdma_status copy_status;

    queue_snapshot = null;
    kind_snapshot = RDMA_QUEUE_RUNTIME_SQ;
    host_produced_snapshot = 1'b0;
    initial_polarity_snapshot = 1'b0;
    lock_status = acquire_lock();
    if (!status_is_ok(lock_status)) return lock_status;
    if (state == RDMA_QUEUE_RUNTIME_DETACHED || depth == 0 || queue_h == null) begin
      lock.put(1);
      return make_runtime_status(RDMA_SC_INVALID_STATE,
                                 "runtime attachment config is unavailable");
    end
    copy_status = clone_handle_value_nonfatal(queue_h, queue_snapshot);
    if (!status_is_ok(copy_status) || queue_snapshot == null) begin
      queue_snapshot = null;
      lock.put(1);
      return copy_status != null ? copy_status : make_runtime_status(
        RDMA_SC_RESOURCE_EXHAUSTED,
        "runtime attachment handle clone returned null status");
    end
    kind_snapshot = kind;
    host_produced_snapshot = host_produced;
    initial_polarity_snapshot = initial_polarity;
    lock.put(1);
    return make_runtime_status(RDMA_SC_OK, "");
  endfunction

  // 功能：set_route_epoch 在 activate 前锁存 queue 的完整 PCIe route 与 reset epoch authority，供 publish/recovery 查询。
  // 输入/输出及副作用：route_value、epoch_value（输入）；仅在 ATTACHED 状态写入值字段，不接管外部 identity 对象所有权。
  // 失败/边界：未配置、非 ATTACHED、route 校验失败或 epoch 已被锁存时返回 INVALID_STATE/INVALID_ARGUMENT，旧快照保持不变。
  function rdma_status set_route_epoch(
    rdma_route_key_t route_value,
    rdma_reset_epoch_t epoch_value
  );
    rdma_status lock_status;
    lock_status = acquire_lock();
    if (!status_is_ok(lock_status)) return lock_status;
    if (state != RDMA_QUEUE_RUNTIME_ATTACHED || route_valid || epoch_valid) begin
      lock.put(1);
      return make_runtime_status(RDMA_SC_INVALID_STATE,
                                 "route authority is not writable");
    end
    if (!rdma_route_key_valid(route_value)) begin
      lock.put(1);
      return make_runtime_status(RDMA_SC_INVALID_ARGUMENT,
                                 "route authority is invalid");
    end
    route = route_value;
    reset_epoch = epoch_value;
    route_valid = 1'b1;
    epoch_valid = 1'b1;
    lock.put(1);
    return make_runtime_status(RDMA_SC_OK, "");
  endfunction

  // 功能：activate 只把已 configure 的 runtime 从 ATTACHED 切换为 ACTIVE；
  //   route/reset epoch authority 由 publish、prepared recovery 和 copy 边界校验。
  // 输入/输出及副作用：无显式参数；成功仅更新 state，queue_h、可选 route/epoch、
  //   PI/CI 和 ledger 保持不变，因此直接 runtime fixture 可在 authority 前激活。
  // 失败/边界：非 ATTACHED 或锁忙时返回 INVALID_STATE/RESOURCE_BUSY；本函数不把
  //   缺失 authority 伪造成有效值，query_route_epoch 仍会 fail-closed。
  function rdma_status activate();
    rdma_status lock_status;
    lock_status = acquire_lock();
    if (!status_is_ok(lock_status)) return lock_status;
    if (state != RDMA_QUEUE_RUNTIME_ATTACHED) begin
      lock.put(1);
      return make_runtime_status(RDMA_SC_INVALID_STATE,
                                 "queue runtime is not attached");
    end
    state = RDMA_QUEUE_RUNTIME_ACTIVE;
    lock.put(1);
    return make_runtime_status(RDMA_SC_OK, "");
  endfunction

  // 功能：begin_quiesce 为 resize/删除建立冻结屏障，将无 outstanding work 的
  //   ACTIVE runtime 切换为 QUIESCING。
  // 输入/输出及副作用：无显式参数；成功仅更新 state，保留 identity、
  //   route/epoch、PI/CI 与空 ledger，供 copy_ring_state 读取。
  // 失败/边界：非 ACTIVE 返回 INVALID_STATE；pending、device reservation 或 used
  //   任一存在返回 RESOURCE_BUSY；失败不改变 state/账本。
  virtual function rdma_status begin_quiesce();
    rdma_status lock_status;
    lock_status = acquire_lock();
    if (!status_is_ok(lock_status)) return lock_status;
    if (state != RDMA_QUEUE_RUNTIME_ACTIVE) begin
      lock.put(1);
      return make_runtime_status(RDMA_SC_INVALID_STATE,
                                 "queue runtime is not active");
    end
    if (mutable_work_present_locked()) begin
      lock.put(1);
      return make_runtime_status(RDMA_SC_RESOURCE_BUSY,
                                 pending_operation_state != null ?
                                 "queue runtime has a pending operation" :
                                 (device_reservation_valid ?
                                  "queue runtime has a device reservation" :
                                  "queue runtime has outstanding slots"));
    end
    state = RDMA_QUEUE_RUNTIME_QUIESCING;
    lock.put(1);
    return make_runtime_status(RDMA_SC_OK, "");
  endfunction

  // 功能：restore_active 在 replacement 未提交时撤销 quiesce 屏障，恢复旧 runtime。
  // 输入/输出及副作用：无显式参数；成功把 state 从 QUIESCING 改为 ACTIVE，
  //   不改变 cursor、authority 或外部 backing 所有权。
  // 失败/边界：非 QUIESCING 返回 INVALID_STATE；冻结期意外出现 pending/
  //   reservation/used 返回 RESOURCE_BUSY；失败保持原 state。
  virtual function rdma_status restore_active();
    rdma_status lock_status;
    lock_status = acquire_lock();
    if (!status_is_ok(lock_status)) return lock_status;
    if (state != RDMA_QUEUE_RUNTIME_QUIESCING) begin
      lock.put(1);
      return make_runtime_status(RDMA_SC_INVALID_STATE,
                                 "queue runtime is not quiescing");
    end
    if (mutable_work_present_locked()) begin
      lock.put(1);
      return make_runtime_status(RDMA_SC_RESOURCE_BUSY,
                                 "quiesced runtime has mutable work");
    end
    state = RDMA_QUEUE_RUNTIME_ACTIVE;
    lock.put(1);
    return make_runtime_status(RDMA_SC_OK, "");
  endfunction

  // 功能：detach_quiesced 在 replacement/backing 切换完成后将旧 runtime 永久隔离。
  // 输入/输出及副作用：无显式参数；成功把 state 从 QUIESCING 改为 DETACHED，
  //   不释放由 data engine/lifecycle owner 持有的 mapping 或 queue resource。
  // 失败/边界：非 QUIESCING 或存在 pending/reservation/used 时拒绝；重复 detach
  //   返回 INVALID_STATE，不会重新激活或修改账本。
  virtual function rdma_status detach_quiesced();
    rdma_status lock_status;
    lock_status = acquire_lock();
    if (!status_is_ok(lock_status)) return lock_status;
    if (state != RDMA_QUEUE_RUNTIME_QUIESCING) begin
      lock.put(1);
      return make_runtime_status(RDMA_SC_INVALID_STATE,
                                 "queue runtime is not quiescing");
    end
    if (mutable_work_present_locked()) begin
      lock.put(1);
      return make_runtime_status(RDMA_SC_RESOURCE_BUSY,
                                 "quiesced runtime has mutable work");
    end
    state = RDMA_QUEUE_RUNTIME_DETACHED;
    lock.put(1);
    return make_runtime_status(RDMA_SC_OK, "");
  endfunction

  // 功能：copy_ring_state 为 resize 冻结 source 的 identity、游标、polarity、
  //   route/epoch 和 host ledger，再向空 ATTACHED target 一次性发布完整 ring 状态。
  // 输入/输出及副作用：source（输入）保持 QUIESCING；成功时当前 runtime 继承
  //   source authority 与 cursor，host ring 接管 staging 出的 detached ledger，
  //   device ring 保持零长度 ledger。
  // 失败/边界：source 未冻结/authority 非成对有效、target 不空/半有效/identity
  //   不同、任一侧仍持有 recovery retry confirmation、目标深度容不下 PI/CI、
  //   缩容丢弃未消费 slot 或任一 staging 分配失败时返回错误；所有 target 字段
  //   在完整校验和分配成功前保持不变。
  function rdma_status copy_ring_state(rdma_queue_runtime source);
    int unsigned i, limit;
    rdma_queue_slot_ledger_entry staged_slots[];
    rdma_queue_slot_ledger_entry published_slots[];
    rdma_queue_slot_ledger_entry staged_slot;
    rdma_status source_status, target_status, copy_status;
    bit source_host_produced;
    bit source_route_valid, source_epoch_valid, source_initial_polarity;
    rdma_route_key_t source_route;
    rdma_reset_epoch_t source_epoch;
    rdma_queue_runtime_kind_e source_kind;
    int unsigned source_depth, source_pi, source_ci, source_used;
    bit source_pw, source_cw;
    rdma_handle source_queue_h;
    rdma_resource_kind_e source_queue_kind;
    longint unsigned source_function_uid;
    int unsigned source_object_id, source_generation;
    uvm_object raw_slot;

    // 中文设计：source 先以 QUIESCING 快照冻结，完整 staging 成功后才获取
    // target 锁发布；source==this 直接拒绝，避免同一 semaphore 双重获取死锁。
    if (source == null || source == this)
      return make_runtime_status(RDMA_SC_INVALID_ARGUMENT,
                                 "source runtime is null or identical");

    source_status = source.acquire_lock();
    if (!status_is_ok(source_status))
      return (source_status != null) ? source_status :
        make_runtime_status(RDMA_SC_RESOURCE_BUSY,
                            "source runtime lock status is unavailable");
    if (source.state != RDMA_QUEUE_RUNTIME_QUIESCING ||
        source.pending_operation_state != null || source.device_reservation_valid ||
        source.used != 0 || source.recovery_commit_allowed ||
        source.recovery_retry_confirmed) begin
      source.lock.put(1);
      return make_runtime_status(RDMA_SC_RESOURCE_BUSY,
                                 "source runtime has mutable evidence");
    end

    source_kind = source.kind;
    source_host_produced = source.host_produced;
    source_depth = source.depth;
    source_pi = source.producer_index;
    source_pw = source.producer_wrap;
    source_ci = source.consumer_index;
    source_cw = source.consumer_wrap;
    source_used = source.used;
    source_queue_h = source.queue_h;
    source_route = source.route;
    source_route_valid = source.route_valid;
    source_epoch = source.reset_epoch;
    source_epoch_valid = source.epoch_valid;
    source_initial_polarity = source.initial_polarity;
    if (source_queue_h != null) begin
      source_queue_kind = source_queue_h.kind;
      source_function_uid = source_queue_h.function_uid;
      source_object_id = source_queue_h.object_id;
      source_generation = source_queue_h.generation;
    end

    if (source_depth == 0 || source_queue_h == null) begin
      source.lock.put(1);
      return make_runtime_status(RDMA_SC_INVALID_STATE,
                                 "source runtime is unconfigured");
    end
    if (source_pi >= source_depth || source_ci >= source_depth) begin
      source.lock.put(1);
      return make_runtime_status(RDMA_SC_INVALID_ARGUMENT,
                                 "source cursor is outside depth");
    end
    if (source_used != 0) begin
      source.lock.put(1);
      return make_runtime_status(RDMA_SC_RESOURCE_BUSY,
                                 "source runtime has outstanding slots");
    end
    if (!source_route_valid || !source_epoch_valid ||
        !rdma_route_key_valid(source_route)) begin
      source.lock.put(1);
      return make_runtime_status(RDMA_SC_INVALID_STATE,
                                 "source route and reset epoch are unavailable");
    end
    if (source_host_produced) begin
      if (source.slots.size() != source_depth) begin
        source.lock.put(1);
        return make_runtime_status(RDMA_SC_INVALID_STATE,
                                   "source runtime has no host ledger");
      end
      // 中文设计：先按 source depth 完整复制 ledger，不能在 source lock 下读取
      // 尚未持锁的 target depth；缩容筛选和扩容空 slot 分配延后到 target lock，
      // 但仍在任何 target 字段写入之前完成。
      staged_slots = new[source_depth];
      foreach (staged_slots[i]) begin
        raw_slot = factory_create_object_nonfatal(
          rdma_queue_slot_ledger_entry::get_type(),
          $sformatf("staged_slot_%0d", i));
        if (raw_slot == null || !$cast(staged_slots[i], raw_slot)) begin
          source.lock.put(1);
          return make_runtime_status(RDMA_SC_RESOURCE_EXHAUSTED,
                                     "slot staging allocation failed");
        end
      end
      for (i = 0; i < source_depth; i++) begin
        if (source.slots[i] == null) begin
          source.lock.put(1);
          return make_runtime_status(RDMA_SC_INVALID_STATE,
                                     "source runtime has a null slot");
        end
        staged_slot = staged_slots[i];
        staged_slot.posted = source.slots[i].posted;
        staged_slot.consumed = source.slots[i].consumed;
        staged_slot.signaled = source.slots[i].signaled;
        staged_slot.wr_id = source.slots[i].wr_id;
        staged_slot.index = source.slots[i].index;
        staged_slot.wrap = source.slots[i].wrap;
        copy_status = clone_request_value_nonfatal(
          source.slots[i].request_snapshot, staged_slot.request_snapshot);
        if (!status_is_ok(copy_status)) begin
          source.lock.put(1);
          return (copy_status != null) ? copy_status :
            make_runtime_status(RDMA_SC_RESOURCE_EXHAUSTED,
                                "slot request clone failed");
        end
        copy_status = clone_image_value_nonfatal(
          source.slots[i].image, staged_slot.image);
        if (!status_is_ok(copy_status)) begin
          source.lock.put(1);
          return (copy_status != null) ? copy_status :
            make_runtime_status(RDMA_SC_RESOURCE_EXHAUSTED,
                                "slot image clone failed");
        end
        copy_status = clone_status_value_nonfatal(
          source.slots[i].completion_status, staged_slot.completion_status);
        if (!status_is_ok(copy_status)) begin
          source.lock.put(1);
          return (copy_status != null) ? copy_status :
            make_runtime_status(RDMA_SC_RESOURCE_EXHAUSTED,
                                "slot status clone failed");
        end
      end
    end
    else
      staged_slots = new[0];
    source.lock.put(1);

    target_status = acquire_lock();
    if (!status_is_ok(target_status))
      return (target_status != null) ? target_status :
        make_runtime_status(RDMA_SC_RESOURCE_BUSY,
                            "target runtime lock status is unavailable");
    if (state != RDMA_QUEUE_RUNTIME_ATTACHED || pending_operation_state != null ||
        device_reservation_valid || used != 0 || recovery_commit_allowed ||
        recovery_retry_confirmed ||
        kind != source_kind ||
        host_produced != source_host_produced || depth == 0 ||
        queue_h == null ||
        !handle_value_matches_snapshot(queue_h, source_queue_kind,
                                       source_function_uid, source_object_id,
                                       source_generation)) begin
      lock.put(1);
      return make_runtime_status(RDMA_SC_INVALID_STATE,
                                 "target runtime is not an empty compatible attachment");
    end
    if (source_pi >= depth || source_ci >= depth) begin
      lock.put(1);
      return make_runtime_status(RDMA_SC_INVALID_ARGUMENT,
                                 "source cursor is outside target depth");
    end
    if (source_host_produced && slots.size() != depth) begin
      lock.put(1);
      return make_runtime_status(RDMA_SC_INVALID_STATE,
                                 "target runtime has no host ledger");
    end
    if (!source_host_produced && slots.size() != 0) begin
      lock.put(1);
      return make_runtime_status(RDMA_SC_INVALID_STATE,
                                 "device runtime unexpectedly owns host ledger");
    end
    if (route_valid != epoch_valid) begin
      lock.put(1);
      return make_runtime_status(RDMA_SC_INVALID_STATE,
                                 "target route and reset epoch are half valid");
    end
    if (route_valid &&
        !same_route_epoch_value(source_route, source_epoch,
                                route, reset_epoch)) begin
      lock.put(1);
      return make_runtime_status(RDMA_SC_INVALID_ARGUMENT,
                                 "route or reset epoch differs between rings");
    end

    if (source_host_produced) begin
      // 缩容只有在被裁掉的 source slot 均无 outstanding WQE 时才安全；
      // source.used==0 仍不足以证明损坏 ledger 中没有遗漏，因此逐项复核。
      if (source_depth > depth) begin
        for (i = depth; i < source_depth; i++) begin
          if (staged_slots[i] != null && staged_slots[i].posted &&
              !staged_slots[i].consumed) begin
            lock.put(1);
            return make_runtime_status(
              RDMA_SC_RESOURCE_BUSY,
              "source runtime has slots outside resized depth");
          end
        end
      end
      published_slots = new[depth];
      limit = (source_depth < depth) ? source_depth : depth;
      for (i = 0; i < limit; i++)
        published_slots[i] = staged_slots[i];
      for (i = limit; i < depth; i++) begin
        raw_slot = factory_create_object_nonfatal(
          rdma_queue_slot_ledger_entry::get_type(),
          $sformatf("resized_slot_%0d", i));
        if (raw_slot == null || !$cast(published_slots[i], raw_slot)) begin
          lock.put(1);
          return make_runtime_status(RDMA_SC_RESOURCE_EXHAUSTED,
                                     "resized slot allocation failed");
        end
      end
    end
    else
      published_slots = new[0];

    // 中文设计：从这里开始不再执行会失败的操作；ledger、cursor、polarity 与
    // authority 在同一 target lock 临界区整体发布，保证调用方看不到混合代际。
    slots = published_slots;
    producer_index = source_pi;
    producer_wrap = source_pw;
    consumer_index = source_ci;
    consumer_wrap = source_cw;
    used = source_used;
    initial_polarity = source_initial_polarity;
    route = source_route;
    route_valid = 1'b1;
    reset_epoch = source_epoch;
    epoch_valid = 1'b1;
    lock.put(1);
    return make_runtime_status(RDMA_SC_OK, "");
  endfunction

  // 功能：query_available 在 runtime lock 内返回可再提交的 producer credit，并扣除尚未 commit 的 device reservation。
  // 输入/输出及副作用：value（输出）先置零，成功时写入 depth-used-1（有
  //   device reservation）或 depth-used；不修改游标、reservation 或 slot ledger。
  // 失败/边界：depth=0、used>depth 或锁忙时返回非成功状态；结果不发生
  //   unsigned 下溢，失败时 value 保持零。
  function rdma_status query_available(output int unsigned value);
    rdma_status lock_status;
    value = 0;
    lock_status = acquire_lock();
    if (!lock_status.ok()) return lock_status;
    if (depth == 0) begin
      lock.put(1);
      return make_runtime_status(RDMA_SC_INVALID_STATE,
                                 "runtime is unconfigured");
    end
    if (used > depth) begin
      lock.put(1);
      return make_runtime_status(RDMA_SC_INVALID_STATE,
                                 "runtime occupancy exceeds depth");
    end
    value = available_slot_value(depth, used, host_produced,
                                device_reservation_valid);
    lock.put(1);
    return make_runtime_status(RDMA_SC_OK, "");
  endfunction

  // 功能：available_slots 为兼容调用方返回当前 producer credit，并对未提交的
  //   device reservation 预扣一个槽位。
  // 输入/输出及副作用：无显式输入；只读 depth、used、方向和 reservation 位，
  //   返回 int unsigned，不推进 PI/CI 或改变 ledger。
  // 失败/边界：该无 status 兼容入口在 used>depth 或未配置时保守返回 0；
  //   需要区分损坏与真正 full 的调用方必须使用 query_available。
  function int unsigned available_slots();
    return available_slot_value(depth, used, host_produced,
                                device_reservation_valid);
  endfunction

  // 功能：peek_consumer 返回当前 CI 的 detached cursor；device ring 只有在
  //   used>0 时才允许调用方观察该项。
  // 输入/输出及副作用：snapshot（输出）先置 null；成功时复制 consumer_index/
  //   consumer_wrap，不推进 CI、不释放 credit，也不泄露内部可变对象。
  // 失败/边界：非 ACTIVE 返回 INVALID_STATE，空 device ring 返回 QUEUE_EMPTY，
  //   factory 返回 null/错误类型时返回 RESOURCE_EXHAUSTED 且 output 保持 null。
  function rdma_status peek_consumer(output rdma_queue_cursor_snapshot snapshot);
    rdma_status lock_status;
    uvm_object raw_snapshot;

    snapshot = null;
    lock_status = acquire_lock();
    if (!lock_status.ok()) return lock_status;
    if (state != RDMA_QUEUE_RUNTIME_ACTIVE) begin
      lock.put(1);
      return make_runtime_status(RDMA_SC_INVALID_STATE,
                                 "queue runtime is not active");
    end
    if (!host_produced && used == 0) begin
      lock.put(1);
      return make_runtime_status(RDMA_SC_QUEUE_EMPTY,
                                 "device ring has no committed entries");
    end
    raw_snapshot = factory_create_object_nonfatal(
      rdma_queue_cursor_snapshot::get_type(), "consumer_snapshot");
    if (raw_snapshot == null || !$cast(snapshot, raw_snapshot)) begin
      snapshot = null;
      lock.put(1);
      return make_runtime_status(RDMA_SC_RESOURCE_EXHAUSTED,
                                 "consumer snapshot allocation failed");
    end
    snapshot.index = consumer_index;
    snapshot.wrap = consumer_wrap;
    lock.put(1);
    return make_runtime_status(RDMA_SC_OK, "");
  endfunction

  // 功能：commit_consumer 消费 CQ/CEQ/AEQ 当前 CI credit；recovery 路径在同一
  //   临界区推进 CI、递减 used 并发布 committed_consumer_cursor/阶段位。
  // 输入/输出及副作用：reservation（输入）必须匹配当前 CI 或 recovery cursor；
  //   普通成功推进 CI/used，恢复成功还关闭 recovery_commit_allowed。
  // 失败/边界：host ring、空 ring、stale cursor、未授权 recovery、非 SUCCESS
  //   evidence 或 consumer invariant 损坏时返回错误；失败不得部分推进 CI/used。
  function rdma_status commit_consumer(rdma_queue_cursor_snapshot reservation);
    rdma_status lock_status;
    rdma_queue_cursor_snapshot committed_copy;
    bit recovery_path;
    bit ci_at_pending;
    bit ci_at_next;

    if (reservation == null)
      return make_runtime_status(RDMA_SC_INVALID_ARGUMENT,
                                 "consumer reservation is null");
    lock_status = acquire_lock();
    if (!status_is_ok(lock_status)) return lock_status;

    // 中文设计：只有 device-produced CQ/CEQ/AEQ 的 consumer credit 由本
    // runtime 直接维护；host SQ/RQ/SRQ 的完成通过 match_and_release 释放 ledger。
    if (host_produced || !is_device_ring_kind(kind)) begin
      lock.put(1);
      return make_runtime_status(RDMA_SC_INVALID_STATE,
                                 "consumer commit is invalid for this ring");
    end
    if (depth == 0 || reservation.index >= depth) begin
      lock.put(1);
      return make_runtime_status(RDMA_SC_INVALID_ARGUMENT,
                                 "consumer reservation is outside depth");
    end

    recovery_path = (state == RDMA_QUEUE_RUNTIME_RECOVERY_REQUIRED);
    if (!recovery_path) begin
      if (state != RDMA_QUEUE_RUNTIME_ACTIVE || pending_operation_state != null ||
          recovery_commit_allowed) begin
        lock.put(1);
        return make_runtime_status(RDMA_SC_INVALID_STATE,
                                   "queue runtime is not active");
      end
      if (!cursor_equal(reservation.index, reservation.wrap,
                        consumer_index, consumer_wrap)) begin
        lock.put(1);
        return make_runtime_status(RDMA_SC_INVALID_STATE,
                                   "consumer reservation is stale");
      end
      if (used == 0) begin
        lock.put(1);
        return make_runtime_status(
          RDMA_SC_INVALID_STATE,
          "consumer commit has no reserved device entry");
      end
      if (used > depth) begin
        lock.put(1);
        return make_runtime_status(RDMA_SC_INVALID_STATE,
                                   "device ring occupancy exceeds depth");
      end
      // 中文设计：credit 递减与 CI 推进必须在同一临界区发布，避免观察到
      // “CI 已前进但 occupancy 未释放”的中间状态。
      used--;
      cursor_advance(consumer_index, consumer_wrap);
      lock.put(1);
      return make_runtime_status(RDMA_SC_OK, "");
    end

    if (!recovery_commit_allowed || pending_operation_state == null) begin
      lock.put(1);
      return make_runtime_status(RDMA_SC_INVALID_STATE,
                                 "consumer recovery commit is not authorized");
    end
    if (pending_operation_state.device_producer || pending_operation_state.producer ||
        !pending_identity_matches_locked(pending_operation_state) ||
        pending_operation_state.kind != kind || pending_operation_state.cursor == null ||
        pending_operation_state.next_cursor == null ||
        !consumer_publication_committed_ready_locked(
          pending_operation_state)) begin
      lock.put(1);
      return make_runtime_status(RDMA_SC_INVALID_STATE,
                                 "consumer recovery evidence is invalid");
    end
    if (!pending_cursor_shape_valid(pending_operation_state)) begin
      lock.put(1);
      return make_runtime_status(RDMA_SC_INVALID_ARGUMENT,
                                 "consumer recovery cursor evidence is invalid");
    end
    if (!consumer_recovery_invariant_locked(
          pending_operation_state, pending_operation_state.mmio_evidence,
          pending_operation_state.consumer_committed,
          pending_operation_state.committed_consumer_cursor)) begin
      lock.put(1);
      return make_runtime_status(RDMA_SC_INVALID_STATE,
                                 "consumer recovery phase invariant is invalid");
    end
    if (!cursor_equal(reservation.index, reservation.wrap,
                      pending_operation_state.cursor.index,
                      pending_operation_state.cursor.wrap)) begin
      lock.put(1);
      return make_runtime_status(RDMA_SC_INVALID_STATE,
                                 "consumer recovery reservation is stale");
    end
    ci_at_pending = cursor_equal(consumer_index, consumer_wrap,
                                 pending_operation_state.cursor.index,
                                 pending_operation_state.cursor.wrap);
    ci_at_next = cursor_equal(consumer_index, consumer_wrap,
                              pending_operation_state.next_cursor.index,
                              pending_operation_state.next_cursor.wrap);
    if (!ci_at_pending && !ci_at_next) begin
      lock.put(1);
      return make_runtime_status(RDMA_SC_INVALID_STATE,
                                 "runtime CI is outside consumer recovery transaction");
    end

    if (pending_operation_state.committed_consumer_cursor != null &&
        !cursor_equal(pending_operation_state.committed_consumer_cursor.index,
                      pending_operation_state.committed_consumer_cursor.wrap,
                      pending_operation_state.next_cursor.index,
                      pending_operation_state.next_cursor.wrap)) begin
      lock.put(1);
      return make_runtime_status(RDMA_SC_INVALID_STATE,
                                 "committed consumer cursor is inconsistent");
    end
    if (pending_operation_state.committed_consumer_cursor == null) begin
      // next_cursor 在 prepared admission 前已作为 runtime-owned detached
      // 值完成物化；commit 只发布该不可变证据的别名，避免 doorbell 后再分配。
      committed_copy = pending_operation_state.next_cursor;
    end

    // CI 与 used 先在锁内形成候选提交状态，再用共享 invariant 验证；若内部
    // advance 与 next_cursor 不一致则恢复旧 CI/credit，禁止发布伪 committed 阶段。
    if (ci_at_pending) begin
      if (used == 0) begin
        lock.put(1);
        return make_runtime_status(RDMA_SC_QUEUE_EMPTY,
                                   "device ring has no committed entries");
      end
      if (used > depth) begin
        lock.put(1);
        return make_runtime_status(RDMA_SC_INVALID_STATE,
                                   "device ring occupancy exceeds depth");
      end
      used--;
      cursor_advance(consumer_index, consumer_wrap);
      if (!cursor_equal(consumer_index, consumer_wrap,
                        pending_operation_state.next_cursor.index,
                        pending_operation_state.next_cursor.wrap)) begin
        used++;
        consumer_index = pending_operation_state.cursor.index;
        consumer_wrap = pending_operation_state.cursor.wrap;
        lock.put(1);
        return make_runtime_status(RDMA_SC_INVALID_STATE,
                                   "consumer recovery CI advance mismatched evidence");
      end
    end

    if (!consumer_recovery_invariant_locked(
          pending_operation_state, pending_operation_state.mmio_evidence, 1'b1,
          pending_operation_state.committed_consumer_cursor == null ?
            committed_copy : pending_operation_state.committed_consumer_cursor)) begin
      if (ci_at_pending) begin
        used++;
        consumer_index = pending_operation_state.cursor.index;
        consumer_wrap = pending_operation_state.cursor.wrap;
      end
      lock.put(1);
      return make_runtime_status(RDMA_SC_INVALID_STATE,
                                 "consumer recovery commit violates phase invariant");
    end

    if (pending_operation_state.committed_consumer_cursor == null) begin
      pending_operation_state.committed_consumer_cursor = committed_copy;
    end
    pending_operation_state.consumer_committed = 1'b1;
    recovery_commit_allowed = 1'b0;
    lock.put(1);
    return make_runtime_status(RDMA_SC_OK, "");
  endfunction

  // 功能：commit_consumer_recovery_noalloc 在 consumer doorbell 已确定成功后，
  //   以 admission 冻结的 old cursor 原子提交 CQ/CEQ/AEQ CI，并同步发布 commit marker。
  // 输入/输出及副作用：reservation_index/reservation_wrap 是冻结 cursor 标量，
  //   status_slot 由 caller 预先创建；成功消费 recovery_commit_allowed、递减 used、
  //   推进 CI，把 pending.next_cursor 发布为 committed_consumer_cursor，CQ 同时置
  //   cq_consumer_committed，并保持 release gate 为关闭状态。
  // 失败/边界：status_slot/null lock、未授权 commit、非 consumer recovery、非
  //   SUCCESS、stale cursor、空/损坏 occupancy 或阶段已提交时返回 0；所有拒绝
  //   分支在修改 CI/pending 或消费 authorization 前完成。
  function bit commit_consumer_recovery_noalloc(
    int unsigned reservation_index,
    bit reservation_wrap,
    rdma_status status_slot
  );
    int unsigned expected_next_index;
    bit expected_next_wrap;
    rdma_status_code_e failure_code;
    string failure_message;

    if (status_slot == null) return 1'b0;
    if (lock == null || !lock.try_get(1)) begin
      void'(set_runtime_status_noalloc(
        status_slot, RDMA_SC_RESOURCE_BUSY, "queue runtime is busy"));
      return 1'b0;
    end

    failure_code = RDMA_SC_INVALID_STATE;
    failure_message = "consumer recovery evidence is invalid";
    if (state != RDMA_QUEUE_RUNTIME_RECOVERY_REQUIRED ||
        pending_operation_state == null || host_produced ||
        !is_device_ring_kind(kind) || pending_operation_state.producer ||
        pending_operation_state.device_producer ||
        !recovery_commit_allowed ||
        !pending_identity_matches_locked(pending_operation_state) ||
        pending_operation_state.kind != kind ||
        !consumer_publication_committed_ready_locked(
          pending_operation_state) ||
        pending_operation_state.consumer_committed ||
        !pending_cursor_shape_valid(pending_operation_state) ||
        pending_operation_state.cursor == null ||
        pending_operation_state.next_cursor == null ||
        !cursor_equal(reservation_index, reservation_wrap,
                      pending_operation_state.cursor.index,
                      pending_operation_state.cursor.wrap) ||
        !cursor_equal(consumer_index, consumer_wrap,
                      pending_operation_state.cursor.index,
                      pending_operation_state.cursor.wrap) ||
        (pending_operation_state.committed_consumer_cursor != null &&
         !cursor_equal(
           pending_operation_state.committed_consumer_cursor.index,
           pending_operation_state.committed_consumer_cursor.wrap,
           pending_operation_state.next_cursor.index,
           pending_operation_state.next_cursor.wrap))) begin
      lock.put(1);
      void'(set_runtime_status_noalloc(status_slot, failure_code,
                                       failure_message));
      return 1'b0;
    end
    if (used == 0) begin
      lock.put(1);
      void'(set_runtime_status_noalloc(
        status_slot, RDMA_SC_QUEUE_EMPTY,
        "device ring has no committed entries"));
      return 1'b0;
    end
    if (used > depth) begin
      lock.put(1);
      void'(set_runtime_status_noalloc(
        status_slot, RDMA_SC_INVALID_STATE,
        "device ring occupancy exceeds depth"));
      return 1'b0;
    end

    expected_next_index = consumer_index;
    expected_next_wrap = consumer_wrap;
    cursor_advance(expected_next_index, expected_next_wrap);
    if (!cursor_equal(expected_next_index, expected_next_wrap,
                      pending_operation_state.next_cursor.index,
                      pending_operation_state.next_cursor.wrap)) begin
      lock.put(1);
      void'(set_runtime_status_noalloc(
        status_slot, RDMA_SC_INVALID_STATE,
        "consumer recovery CI advance mismatched evidence"));
      return 1'b0;
    end

    // 中文设计：以上校验只读所有 authority；从这里开始在同一临界区一次性发布
    // credit、CI 和 marker，任何 caller 都看不到部分 committed 状态。
    used--;
    consumer_index = expected_next_index;
    consumer_wrap = expected_next_wrap;
    if (pending_operation_state.committed_consumer_cursor == null)
      pending_operation_state.committed_consumer_cursor =
        pending_operation_state.next_cursor;
    pending_operation_state.consumer_committed = 1'b1;
    if (kind == RDMA_QUEUE_RUNTIME_CQ)
      pending_operation_state.cq_consumer_committed = 1'b1;
    recovery_commit_allowed = 1'b0;
    consumer_release_gate_active = 1'b0;
    recovery_retry_confirmed = 1'b0;
    lock.put(1);
    void'(set_runtime_status_noalloc(status_slot, RDMA_SC_OK, ""));
    return 1'b1;
  endfunction

  // 功能：begin_consumer_release_noalloc 在 CQ consumer CI 已原子提交后验证唯一
  //   pending release authority，并持有 CQ runtime lock 形成 WQE release/marker 屏障。
  // 输入/输出及副作用：status_slot 为 caller 预建状态槽；成功置
  //   consumer_release_gate_active 并带锁返回，调用方随后只能按 CQ->WQ 顺序执行
  //   release，且每条退出路径都必须调用 finish_consumer_release_noalloc。
  // 失败/边界：slot/lock 无效、gate 已活动、非 CQ SUCCESS consumer pending、CI/
  //   marker/target 不完整或 target 已释放时返回 0；失败均在 WQ mutation 前归还锁，
  //   pending、CQ cursor/credit 与 release marker 保持不变。
  function bit begin_consumer_release_noalloc(rdma_status status_slot);
    if (status_slot == null) return 1'b0;
    if (lock == null || !lock.try_get(1)) begin
      void'(set_runtime_status_noalloc(
        status_slot, RDMA_SC_RESOURCE_BUSY, "queue runtime is busy"));
      return 1'b0;
    end
    if (consumer_release_gate_active) begin
      lock.put(1);
      void'(set_runtime_status_noalloc(
        status_slot, RDMA_SC_RESOURCE_BUSY,
        "consumer release gate is already active"));
      return 1'b0;
    end
    if (state != RDMA_QUEUE_RUNTIME_RECOVERY_REQUIRED ||
        pending_operation_state == null || host_produced ||
        kind != RDMA_QUEUE_RUNTIME_CQ ||
        pending_operation_state.producer ||
        pending_operation_state.device_producer ||
        !pending_identity_matches_locked(pending_operation_state) ||
        pending_operation_state.kind != RDMA_QUEUE_RUNTIME_CQ ||
        !consumer_publication_committed_ready_locked(
          pending_operation_state) ||
        !pending_operation_state.consumer_committed ||
        !pending_operation_state.cq_consumer_committed ||
        pending_operation_state.committed_consumer_cursor == null ||
        !pending_operation_state.completion_target_valid ||
        pending_operation_state.completion_released ||
        !rdma_queue_release_order_policy::allows_consumer_release(
            kind, pending_operation_state.completion_wq_kind) ||
        pending_operation_state.routed_qp_h == null ||
        pending_operation_state.routed_qp_h.kind != RDMA_RESOURCE_QP ||
        !consumer_recovery_invariant_locked(
          pending_operation_state, pending_operation_state.mmio_evidence,
          pending_operation_state.consumer_committed,
          pending_operation_state.committed_consumer_cursor) ||
        !cursor_equal(
          consumer_index, consumer_wrap,
          pending_operation_state.committed_consumer_cursor.index,
          pending_operation_state.committed_consumer_cursor.wrap)) begin
      lock.put(1);
      void'(set_runtime_status_noalloc(
        status_slot, RDMA_SC_INVALID_STATE,
        "consumer release authority is invalid"));
      return 1'b0;
    end

    consumer_release_gate_active = 1'b1;
    void'(set_runtime_status_noalloc(status_slot, RDMA_SC_OK, ""));
    return 1'b1;
  endfunction

  // 功能：finish_consumer_release_noalloc 结束 begin 持有的 CQ release 屏障；成功
  //   release 时在归还 lock 前立即发布 completion_released，失败时只撤销 gate。
  // 输入/输出及副作用：release_succeeded 表示 routed WQ mutation 的实际结果，
  //   status_slot 是 caller 状态槽；函数清除 consumer_release_gate_active 并归还
  //   begin 持有的 token，成功 release 同时把 slot 置 OK。
  // 失败/边界：gate 未活动时返回 0 且绝不误归还 lock；一旦 gate 活动，本函数不再
  //   校验可变 authority、不得失败，release_succeeded=0 时完整保留 caller 的失败
  //   status 与 pending marker，确保所有 begin-success 路径都能无条件解锁。
  function bit finish_consumer_release_noalloc(
    bit release_succeeded,
    rdma_status status_slot
  );
    if (!consumer_release_gate_active) begin
      if (status_slot != null)
        void'(set_runtime_status_noalloc(
          status_slot, RDMA_SC_INVALID_STATE,
          "consumer release gate is not active"));
      return 1'b0;
    end

    if (release_succeeded) begin
      pending_operation_state.completion_released = 1'b1;
      if (status_slot != null)
        void'(set_runtime_status_noalloc(status_slot, RDMA_SC_OK, ""));
    end
    consumer_release_gate_active = 1'b0;
    lock.put(1);
    return 1'b1;
  endfunction

  // 功能：reserve_device_producer 为 CQ/CEQ/AEQ 锁定当前 producer cursor，返回与 runtime 内部隔离的 detached 快照。
  // 输入/输出及副作用：reservation（输出）先置 null；成功时只登记 device_reservation/device_reservation_valid，不推进 committed PI 或 used。
  // 失败/边界：未配置/非 ACTIVE、host-produced 方向、SQ/RQ/SRQ kind、pending recovery、已有 reservation、ring full 或快照分配失败时返回明确错误且 output 保持 null。
  function rdma_status reserve_device_producer(
    output rdma_queue_cursor_snapshot reservation
  );
    rdma_status lock_status;
    rdma_queue_cursor_snapshot staged_reservation;
    rdma_queue_cursor_snapshot published_reservation;
    uvm_object raw_staged_reservation;
    uvm_object raw_published_reservation;

    reservation = null;
    lock_status = acquire_lock();
    if (!lock_status.ok()) return lock_status;
    if (host_produced || !(kind inside {RDMA_QUEUE_RUNTIME_CQ,
                                        RDMA_QUEUE_RUNTIME_CEQ,
                                        RDMA_QUEUE_RUNTIME_AEQ})) begin
      lock.put(1);
      return make_runtime_status(RDMA_SC_INVALID_STATE,
                                 "device producer is invalid for this ring");
    end
    if (state != RDMA_QUEUE_RUNTIME_ACTIVE || pending_operation_state != null) begin
      lock.put(1);
      return make_runtime_status(RDMA_SC_INVALID_STATE,
                                 "queue runtime is not ready for reservation");
    end
    if (device_reservation_valid) begin
      lock.put(1);
      return make_runtime_status(RDMA_SC_RESOURCE_BUSY,
                                 "device reservation is busy");
    end
    if (used >= depth) begin
      lock.put(1);
      return make_runtime_status(RDMA_SC_QUEUE_FULL,
                                 "device ring is full");
    end
    raw_staged_reservation = factory_create_object_nonfatal(
      rdma_queue_cursor_snapshot::get_type(), "device_producer_reservation");
    raw_published_reservation = factory_create_object_nonfatal(
      rdma_queue_cursor_snapshot::get_type(), "device_producer_reservation_out");
    if (raw_staged_reservation == null ||
        !$cast(staged_reservation, raw_staged_reservation) ||
        raw_published_reservation == null ||
        !$cast(published_reservation, raw_published_reservation)) begin
      lock.put(1);
      return make_runtime_status(RDMA_SC_RESOURCE_EXHAUSTED,
                                 "device reservation allocation failed");
    end
    staged_reservation.index = producer_index;
    staged_reservation.wrap = producer_wrap;
    published_reservation.index = producer_index;
    published_reservation.wrap = producer_wrap;
    device_reservation = staged_reservation;
    device_reservation_valid = 1'b1;
    reservation = published_reservation;
    lock.put(1);
    return make_runtime_status(RDMA_SC_OK, "");
  endfunction

  // 功能：commit_device_producer 将匹配的 device reservation 原子推进到 committed producer cursor，并增加 occupancy。
  // 输入/输出及副作用：reservation（输入）必须是 reserve_device_producer 返回的值副本；成功时只更新 PI/wrap、used 并清除 reservation，不访问 WQE slots。
  // 失败/边界：reservation 为空/失配、runtime 非 ACTIVE（且未显式 recovery commit）、pending evidence、内部计数越界或方向错误时返回错误并保留 reservation。
  function rdma_status commit_device_producer(
    rdma_queue_cursor_snapshot reservation
  );
    rdma_status lock_status;
    rdma_status next_status;
    rdma_queue_cursor_snapshot expected_next;
    bit recovery_path;

    if (reservation == null)
      return make_runtime_status(RDMA_SC_INVALID_ARGUMENT,
                                 "device reservation is null");
    lock_status = acquire_lock();
    if (!status_is_ok(lock_status)) return lock_status;
    if (host_produced || !is_device_ring_kind(kind)) begin
      lock.put(1);
      return make_runtime_status(RDMA_SC_INVALID_STATE,
                                 "device producer is invalid for this ring");
    end
    if (depth == 0 || reservation.index >= depth) begin
      lock.put(1);
      return make_runtime_status(RDMA_SC_INVALID_STATE,
                                 "device reservation is outside depth");
    end
    if (!device_reservation_valid || device_reservation == null ||
        !cursor_equal(reservation.index, reservation.wrap,
                      device_reservation.index, device_reservation.wrap) ||
        !cursor_equal(reservation.index, reservation.wrap,
                      producer_index, producer_wrap)) begin
      lock.put(1);
      return make_runtime_status(RDMA_SC_INVALID_STATE,
                                 "device reservation is stale");
    end
    if (used > depth) begin
      lock.put(1);
      return make_runtime_status(RDMA_SC_INVALID_STATE,
                                 "device ring occupancy exceeds depth");
    end

    recovery_path = (state == RDMA_QUEUE_RUNTIME_RECOVERY_REQUIRED);
    if (!recovery_path) begin
      if (state != RDMA_QUEUE_RUNTIME_ACTIVE || pending_operation_state != null ||
          recovery_commit_allowed) begin
        lock.put(1);
        return make_runtime_status(RDMA_SC_INVALID_STATE,
                                   "queue runtime is not active");
      end
    end else begin
      if (!recovery_commit_allowed || pending_operation_state == null ||
          !pending_operation_state.device_producer || pending_operation_state.producer ||
          !pending_identity_matches_locked(pending_operation_state) ||
          pending_operation_state.kind != kind ||
          !pending_operation_state.device_write_attempted ||
          !(pending_operation_state.mmio_evidence inside {
              RDMA_QUEUE_MMIO_NONE, RDMA_QUEUE_MMIO_NOT_APPLICABLE,
              RDMA_QUEUE_MMIO_NO_SUBMIT})) begin
        lock.put(1);
        return make_runtime_status(RDMA_SC_INVALID_STATE,
                                   "device recovery commit evidence is invalid");
      end
      if (!pending_cursor_shape_valid(pending_operation_state)) begin
        lock.put(1);
        return make_runtime_status(RDMA_SC_INVALID_ARGUMENT,
                                   "device recovery cursor evidence is invalid");
      end
      if (!cursor_equal(reservation.index, reservation.wrap,
                        pending_operation_state.cursor.index,
                        pending_operation_state.cursor.wrap)) begin
        lock.put(1);
        return make_runtime_status(RDMA_SC_INVALID_STATE,
                                   "device recovery reservation is stale");
      end
      next_status = derive_next_cursor(pending_operation_state.cursor,
                                       expected_next);
      if (!status_is_ok(next_status) || expected_next == null ||
          !cursor_equal(expected_next.index, expected_next.wrap,
                        pending_operation_state.next_cursor.index,
                        pending_operation_state.next_cursor.wrap)) begin
        lock.put(1);
        return (next_status != null && !next_status.ok()) ? next_status :
          make_runtime_status(RDMA_SC_INVALID_STATE,
                              "device recovery next cursor is invalid");
      end
    end
    if (used >= depth) begin
      lock.put(1);
      return make_runtime_status(RDMA_SC_QUEUE_FULL,
                                 "device ring is full");
    end

    cursor_advance(producer_index, producer_wrap);
    if (recovery_path &&
        !cursor_equal(producer_index, producer_wrap,
                      pending_operation_state.next_cursor.index,
                      pending_operation_state.next_cursor.wrap)) begin
      producer_index = reservation.index;
      producer_wrap = reservation.wrap;
      lock.put(1);
      return make_runtime_status(RDMA_SC_INVALID_STATE,
                                 "device producer advance mismatched recovery evidence");
    end
    used++;
    device_reservation_valid = 1'b0;
    device_reservation = null;
    if (recovery_path)
      recovery_commit_allowed = 1'b0;
    lock.put(1);
    return make_runtime_status(RDMA_SC_OK, "");
  endfunction

  // 功能：cancel_device_producer 清除尚未产生写入副作用的 device reservation，不改变 committed cursor 或 occupancy。
  // 输入/输出及副作用：reservation（输入）必须匹配内部快照；成功时清除 reservation 状态，调用方继续拥有传入值副本。
  // 失败/边界：空/失配快照、非 ACTIVE、无 reservation 或 pending 标记写入尝试时返回 INVALID_STATE/RECOVERY_REQUIRED，并保留内部 reservation。
  function rdma_status cancel_device_producer(
    rdma_queue_cursor_snapshot reservation
  );
    rdma_status lock_status;
    lock_status = acquire_lock();
    if (!lock_status.ok()) return lock_status;
    if (reservation == null || !device_reservation_valid ||
        device_reservation == null ||
        reservation.index != device_reservation.index ||
        reservation.wrap != device_reservation.wrap) begin
      lock.put(1);
      return make_runtime_status(RDMA_SC_INVALID_STATE,
                                 "device reservation is stale");
    end
    // 设计说明：write-attempt 是 cancel 的首要不可逆边界。prepared admission 会
    // 先把 state 切到 RECOVERY_REQUIRED，因此必须在一般 state gate 之前读取该
    // authority；device producer 不使用 consumer 的 mmio_maybe_submitted 位。
    if (pending_operation_state != null && pending_operation_state.device_producer &&
        pending_operation_state.device_write_attempted) begin
      lock.put(1);
      return make_runtime_status(RDMA_SC_RECOVERY_REQUIRED,
                                 "device reservation has write evidence");
    end
    if (state != RDMA_QUEUE_RUNTIME_ACTIVE) begin
      lock.put(1);
      return make_runtime_status(RDMA_SC_INVALID_STATE,
                                 "queue runtime is not active");
    end
    device_reservation_valid = 1'b0;
    device_reservation = null;
    lock.put(1);
    return make_runtime_status(RDMA_SC_OK, "");
  endfunction

  // 功能：expected_producer_polarity 依据 initial_polarity 与 reservation（或当前 producer wrap）纯计算 device producer owner 位。
  // 输入/输出及副作用：reservation（可选输入）；函数只读取快照并返回 bit，不修改 runtime 或外部资源。
  // 失败/边界：null reservation 使用当前 producer_wrap；该 helper 不验证 runtime 状态，状态化校验必须调用 query_expected_producer_polarity。
  function bit expected_producer_polarity(
    rdma_queue_cursor_snapshot reservation = null
  );
    return initial_polarity ^ (reservation == null ? producer_wrap : reservation.wrap);
  endfunction

  // 功能：query_occupancy 在 runtime lock 内返回已 commit 的 producer-consumer 距离。
  // 输入/输出及副作用：value（输出）先置零，成功时写入 used；不修改游标、reservation 或 ledger。
  // 失败/边界：未配置、used 超过 depth 或锁忙时返回非成功状态并保持安全输出零。
  function rdma_status query_occupancy(output int unsigned value);
    rdma_status lock_status;
    value = 0;
    lock_status = acquire_lock();
    if (!lock_status.ok()) return lock_status;
    if (depth == 0) begin
      lock.put(1);
      return make_runtime_status(RDMA_SC_INVALID_STATE,
                                 "runtime is unconfigured");
    end
    if (used > depth) begin
      lock.put(1);
      return make_runtime_status(RDMA_SC_INVALID_STATE,
                                 "runtime occupancy exceeds depth");
    end
    value = used;
    lock.put(1);
    return make_runtime_status(RDMA_SC_OK, "");
  endfunction

  // 功能：query_cursors 在同一 runtime lock 内返回 PI/CI 的 index/wrap 值，
  //   让测试与上层诊断不直接读取正在迁移的内部 ring 字段。
  // 输入/输出及副作用：producer_index_value、producer_wrap_value、
  //   consumer_index_value、consumer_wrap_value（输出）先置安全默认值；成功只复制值。
  // 失败/边界：未配置、PI/CI 越界或锁忙时返回错误并保持全零输出，不修改游标。
  function rdma_status query_cursors(
    output int unsigned producer_index_value,
    output bit producer_wrap_value,
    output int unsigned consumer_index_value,
    output bit consumer_wrap_value
  );
    rdma_status lock_status;

    producer_index_value = 0;
    producer_wrap_value = 1'b0;
    consumer_index_value = 0;
    consumer_wrap_value = 1'b0;
    lock_status = acquire_lock();
    if (!status_is_ok(lock_status)) return lock_status;
    if (depth == 0 || producer_index >= depth || consumer_index >= depth) begin
      lock.put(1);
      return make_runtime_status(RDMA_SC_INVALID_STATE,
                                 "runtime cursors are unavailable");
    end
    producer_index_value = producer_index;
    producer_wrap_value = producer_wrap;
    consumer_index_value = consumer_index;
    consumer_wrap_value = consumer_wrap;
    lock.put(1);
    return make_runtime_status(RDMA_SC_OK, "");
  endfunction

  // 功能：pending_operation 为尚未迁移到 query_has_pending 的 production caller
  //   提供只读兼容 accessor；返回 detached pending，而不暴露 runtime-owned handle。
  // 输入/输出及副作用：无显式输入；有 pending 时深复制并返回新对象，不修改证据；
  //   无 pending 时返回 null。该无参函数允许旧的 `.pending_operation` 语法继续编译。
  // 失败/边界：lock 或深复制失败时返回非空哨兵，使旧布尔调用 fail-closed 地认为
  //   存在 pending；哨兵不含可提交 authority，完整读取必须调用 query_pending。
  function rdma_queue_pending_operation pending_operation();
    rdma_queue_pending_operation snapshot;
    rdma_queue_pending_operation fallback;
    rdma_status lock_status;
    rdma_status copy_status;

    snapshot = null;
    lock_status = acquire_lock();
    if (!status_is_ok(lock_status)) begin
      fallback = new("pending_presence_busy");
      return fallback;
    end
    if (pending_operation_state == null) begin
      lock.put(1);
      return null;
    end
    copy_status = clone_pending_value(pending_operation_state, snapshot);
    lock.put(1);
    if (!status_is_ok(copy_status) || snapshot == null) begin
      fallback = new("pending_presence_copy_failed");
      return fallback;
    end
    return snapshot;
  endfunction

  // 功能：query_device_reservation 返回内部 device reservation 的 detached value copy，供诊断与恢复读取。
  // 输入/输出及副作用：valid、reservation（输出）先分别置 0/null；成功时复制 reservation，调用方不得修改 runtime 内部对象。
  // 失败/边界：未配置、非 device ring、内部 reservation 句柄缺失或 clone 分配失败时返回非成功状态且保留安全输出。
  function rdma_status query_device_reservation(
    output bit valid,
    output rdma_queue_cursor_snapshot reservation
  );
    rdma_status lock_status;
    uvm_object raw_reservation;

    valid = 1'b0;
    reservation = null;
    lock_status = acquire_lock();
    if (!lock_status.ok()) return lock_status;
    if (depth == 0 || host_produced) begin
      lock.put(1);
      return make_runtime_status(RDMA_SC_INVALID_STATE,
                                 "runtime is not a device ring");
    end
    if (!device_reservation_valid) begin
      lock.put(1);
      return make_runtime_status(RDMA_SC_OK, "");
    end
    if (device_reservation == null) begin
      lock.put(1);
      return make_runtime_status(RDMA_SC_INVALID_STATE,
                                 "device reservation state is corrupt");
    end
    raw_reservation = factory_create_object_nonfatal(
      rdma_queue_cursor_snapshot::get_type(), "device_reservation_query");
    if (raw_reservation == null || !$cast(reservation, raw_reservation)) begin
      reservation = null;
      lock.put(1);
      return make_runtime_status(RDMA_SC_RESOURCE_EXHAUSTED,
                                 "device reservation snapshot allocation failed");
    end
    reservation.index = device_reservation.index;
    reservation.wrap = device_reservation.wrap;
    valid = 1'b1;
    lock.put(1);
    return make_runtime_status(RDMA_SC_OK, "");
  endfunction

  // 功能：query_expected_producer_polarity 对 device runtime 执行状态化 owner/polarity 查询。
  // 输入/输出及副作用：polarity（输出）先置零，成功时写入 initial_polarity XOR producer_wrap；不修改 runtime 状态。
  // 失败/边界：未配置、host-produced ring、游标/occupancy 越界或锁忙时返回非成功状态，输出保持零。
  function rdma_status query_expected_producer_polarity(output bit polarity);
    rdma_status lock_status;
    polarity = 1'b0;
    lock_status = acquire_lock();
    if (!lock_status.ok()) return lock_status;
    if (depth == 0 || host_produced || producer_index >= depth || used > depth) begin
      lock.put(1);
      return make_runtime_status(RDMA_SC_INVALID_STATE,
                                 "producer polarity is unavailable");
    end
    polarity = initial_polarity ^ producer_wrap;
    lock.put(1);
    return make_runtime_status(RDMA_SC_OK, "");
  endfunction

  // 功能：expected_owner_polarity 计算 consumer 当前期待看到的 owner/polarity，
  //   与 device producer 使用的 producer_wrap 版本保持方向隔离。
  // 输入/输出及副作用：无显式输入；返回 initial_polarity XOR consumer_wrap，
  //   仅读取值字段，不修改 runtime。
  // 失败/边界：该兼容纯函数不返回 status，也不验证 configure 状态；未配置对象
  //   只会得到构造默认值，状态化调用方应使用对应 query 接口。
  function bit expected_owner_polarity();
    return initial_polarity ^ consumer_wrap;
  endfunction

  // 功能：validate_queue_handle 比较 caller handle 与 configure 时冻结的 queue
  //   identity，区分身份错误和 stale generation。
  // 输入/输出及副作用：qh（输入）为非拥有引用；仅读取 kind/function_uid/
  //   object_id/generation 并返回 rdma_status，不修改任一 handle。
  // 失败/边界：任一句柄为空或前三个 identity 字段不等返回 INVALID_ARGUMENT；
  //   generation 不等返回 STALE_GENERATION；本函数不替代 state/route/epoch 校验。
  function rdma_status validate_queue_handle(rdma_handle qh);
    if (queue_h == null || qh == null)
      return make_runtime_status(RDMA_SC_INVALID_ARGUMENT,
                                 "queue handle is null");
    if (qh.kind != queue_h.kind ||
        qh.function_uid != queue_h.function_uid ||
        qh.object_id != queue_h.object_id)
      return make_runtime_status(RDMA_SC_INVALID_ARGUMENT,
                                 "queue handle identity mismatch");
    if (qh.generation != queue_h.generation)
      return make_runtime_status(RDMA_SC_STALE_GENERATION,
                                 "queue handle generation is stale");
    return make_runtime_status(RDMA_SC_OK, "");
  endfunction

  // 功能：reserve_producer 为 SQ/RQ/SRQ host producer 返回当前 PI/wrap 的
  //   detached reservation；真正的 ledger/PI 变更留给 commit_producer。
  // 输入/输出及副作用：reservation（输出）先置 null；成功仅发布独立 cursor，
  //   不增加 used、不占用 slot，也不改变 producer_index/wrap。
  // 失败/边界：device ring、非 ACTIVE、used>=depth 或 factory null/错误类型分别
  //   返回 INVALID_STATE/QUEUE_FULL/RESOURCE_EXHAUSTED，失败 output 保持 null。
  function rdma_status reserve_producer(output rdma_queue_cursor_snapshot reservation);
    rdma_status lock_status;
    uvm_object raw_reservation;

    reservation=null;
    lock_status = acquire_lock();
    if (!lock_status.ok()) return lock_status;
    if (!host_produced) begin
      lock.put(1);
      return make_runtime_status(RDMA_SC_INVALID_STATE,
                                 "host producer is invalid for this ring");
    end
    if (state!=RDMA_QUEUE_RUNTIME_ACTIVE) begin
      lock.put(1);
      return make_runtime_status(RDMA_SC_INVALID_STATE,
                                 "queue runtime is not active");
    end
    if (used>=depth) begin
      lock.put(1);
      return make_runtime_status(RDMA_SC_QUEUE_FULL,
                                 "queue producer ring is full");
    end
    raw_reservation = factory_create_object_nonfatal(
      rdma_queue_cursor_snapshot::get_type(), "producer_reservation");
    if (raw_reservation == null || !$cast(reservation, raw_reservation)) begin
      reservation = null;
      lock.put(1);
      return make_runtime_status(RDMA_SC_RESOURCE_EXHAUSTED,
                                 "producer reservation allocation failed");
    end
    reservation.index=producer_index;
    reservation.wrap=producer_wrap;
    lock.put(1);
    return make_runtime_status(RDMA_SC_OK, "");
  endfunction

  // 功能：commit_producer 将匹配当前 PI 的 host WQE 写入 slot ledger，并原子
  //   推进 PI/used；recovery 路径还校验 pending cursor 并消费一次 commit gate。
  // 输入/输出及副作用：reservation/request/wr_id/signaled/image（输入）；成功时
  //   保存 request/image detached 副本、发布 posted slot，并更新 producer cursor。
  // 失败/边界：方向/state/cursor/ledger/occupancy/recovery evidence 不匹配，或
  //   request/image factory 复制失败时返回错误；失败恢复 slot、PI 和 used 原值。
  function rdma_status commit_producer(rdma_queue_cursor_snapshot reservation,
                                       rdma_semantic_request request,
                                       longint unsigned wr_id,
                                       bit signaled,
                                       rdma_hw_image image);
    rdma_queue_slot_ledger_entry slot;
    rdma_semantic_request request_copy;
    rdma_hw_image image_copy;
    rdma_status copy_status;
    rdma_status lock_status;
    rdma_status next_status;
    rdma_queue_cursor_snapshot expected_next;
    bit recovery_path;
    bit old_posted;
    bit old_consumed;
    bit old_signaled;
    bit [63:0] old_wr_id;
    int unsigned old_slot_index;
    bit old_slot_wrap;
    rdma_semantic_request old_request_snapshot;
    rdma_hw_image old_image;
    rdma_status old_completion_status;
    int unsigned old_producer_index;
    bit old_producer_wrap;

    if (reservation == null)
      return make_runtime_status(RDMA_SC_INVALID_ARGUMENT,
                                 "producer reservation is null");
    lock_status = acquire_lock();
    if (!status_is_ok(lock_status)) return lock_status;
    if (!host_produced) begin
      lock.put(1);
      return make_runtime_status(RDMA_SC_INVALID_STATE,
                                 "host producer is invalid for this ring");
    end
    if (depth == 0 || reservation.index >= depth) begin
      lock.put(1);
      return make_runtime_status(RDMA_SC_INVALID_ARGUMENT,
                                 "producer reservation is outside depth");
    end
    if (slots.size() < depth) begin
      lock.put(1);
      return make_runtime_status(RDMA_SC_INVALID_STATE,
                                 "host producer ledger is incomplete");
    end
    slot = slots[reservation.index];
    if (slot == null) begin
      lock.put(1);
      return make_runtime_status(RDMA_SC_INVALID_STATE,
                                 "host producer slot is null");
    end

    recovery_path = (state == RDMA_QUEUE_RUNTIME_RECOVERY_REQUIRED);
    if (!recovery_path) begin
      if (state != RDMA_QUEUE_RUNTIME_ACTIVE || pending_operation_state != null ||
          recovery_commit_allowed) begin
        lock.put(1);
        return make_runtime_status(RDMA_SC_INVALID_STATE,
                                   "queue runtime is not active");
      end
      if (!cursor_equal(reservation.index, reservation.wrap,
                        producer_index, producer_wrap)) begin
        lock.put(1);
        return make_runtime_status(RDMA_SC_INVALID_STATE,
                                   "producer reservation is stale");
      end
    end else begin
      if (!recovery_commit_allowed || pending_operation_state == null ||
          !pending_operation_state.producer || pending_operation_state.device_producer ||
          !pending_identity_matches_locked(pending_operation_state) ||
          pending_operation_state.kind != kind || pending_operation_state.cursor == null ||
          pending_operation_state.next_cursor == null) begin
        lock.put(1);
        return make_runtime_status(RDMA_SC_INVALID_STATE,
                                   "producer recovery evidence is invalid");
      end
      if (!pending_cursor_shape_valid(pending_operation_state)) begin
        lock.put(1);
        return make_runtime_status(RDMA_SC_INVALID_ARGUMENT,
                                   "producer recovery cursor evidence is invalid");
      end
      if (!cursor_equal(reservation.index, reservation.wrap,
                        pending_operation_state.cursor.index,
                        pending_operation_state.cursor.wrap)) begin
        lock.put(1);
        return make_runtime_status(RDMA_SC_INVALID_STATE,
                                   "producer recovery reservation is stale");
      end
      // 中文设计：PI 已等于 next_cursor 代表这笔 recovery transaction 已经
      // 提交；即使 caller 重放同一 reservation，也不能再次增加 used。
      if (cursor_equal(producer_index, producer_wrap,
                       pending_operation_state.next_cursor.index,
                       pending_operation_state.next_cursor.wrap)) begin
        lock.put(1);
        return make_runtime_status(RDMA_SC_INVALID_STATE,
                                   "producer recovery transaction is already committed");
      end
      if (!cursor_equal(producer_index, producer_wrap,
                        pending_operation_state.cursor.index,
                        pending_operation_state.cursor.wrap)) begin
        lock.put(1);
        return make_runtime_status(RDMA_SC_INVALID_STATE,
                                   "producer recovery PI is stale");
      end
      next_status = derive_next_cursor(pending_operation_state.cursor, expected_next);
      if (!status_is_ok(next_status) || expected_next == null ||
          !cursor_equal(expected_next.index, expected_next.wrap,
                        pending_operation_state.next_cursor.index,
                        pending_operation_state.next_cursor.wrap)) begin
        lock.put(1);
        return (next_status != null && !next_status.ok()) ? next_status :
          make_runtime_status(RDMA_SC_INVALID_STATE,
                              "producer recovery next cursor is invalid");
      end
    end
    if (used > depth || used >= depth) begin
      lock.put(1);
      return used > depth ?
        make_runtime_status(RDMA_SC_INVALID_STATE,
                            "host producer occupancy exceeds depth") :
        make_runtime_status(RDMA_SC_QUEUE_FULL,
                            "queue producer ring is full");
    end
    if (slot.posted && !slot.consumed) begin
      lock.put(1);
      return make_runtime_status(RDMA_SC_INVALID_STATE,
                                 "producer slot is still posted");
    end

    // 中文设计：先完成全部 caller 值快照，再触碰 slot/PI/used；factory 故障或
    // 不支持的 request subtype 因此不会留下半提交 ledger。
    copy_status = clone_request_value_nonfatal(request, request_copy);
    if (!status_is_ok(copy_status)) begin
      lock.put(1);
      return (copy_status != null) ? copy_status :
        make_runtime_status(RDMA_SC_RESOURCE_EXHAUSTED,
                            "producer request snapshot clone failed");
    end
    copy_status = clone_image_value_nonfatal(image, image_copy);
    if (!status_is_ok(copy_status)) begin
      lock.put(1);
      return (copy_status != null) ? copy_status :
        make_runtime_status(RDMA_SC_RESOURCE_EXHAUSTED,
                            "producer image snapshot clone failed");
    end

    // 中文设计：防御性 post-advance 校验可能失败，因此保存完整旧 slot（包括
    // consumed slot 的 completion metadata）。提交前不修改这些嵌套对象，保存
    // 其句柄即可准确恢复原 ledger。
    old_posted = slot.posted;
    old_consumed = slot.consumed;
    old_signaled = slot.signaled;
    old_wr_id = slot.wr_id;
    old_slot_index = slot.index;
    old_slot_wrap = slot.wrap;
    old_request_snapshot = slot.request_snapshot;
    old_image = slot.image;
    old_completion_status = slot.completion_status;
    old_producer_index = producer_index;
    old_producer_wrap = producer_wrap;
    slot.posted = 1'b1;
    slot.consumed = 1'b0;
    slot.signaled = signaled;
    slot.wr_id = wr_id;
    slot.index = reservation.index;
    slot.wrap = reservation.wrap;
    slot.request_snapshot = request_copy;
    slot.image = image_copy;
    slot.completion_status = null;
    cursor_advance(producer_index, producer_wrap);
    if (recovery_path &&
        !cursor_equal(producer_index, producer_wrap,
                      pending_operation_state.next_cursor.index,
                      pending_operation_state.next_cursor.wrap)) begin
      // 中文设计：先恢复提交前 PI 与完整 slot，再报告内部 next_cursor 不一致。
      producer_index = old_producer_index;
      producer_wrap = old_producer_wrap;
      slot.posted = old_posted;
      slot.consumed = old_consumed;
      slot.signaled = old_signaled;
      slot.wr_id = old_wr_id;
      slot.index = old_slot_index;
      slot.wrap = old_slot_wrap;
      slot.request_snapshot = old_request_snapshot;
      slot.image = old_image;
      slot.completion_status = old_completion_status;
      lock.put(1);
      return make_runtime_status(RDMA_SC_INVALID_STATE,
                                 "producer recovery PI advance mismatched evidence");
    end
    used++;
    if (recovery_path)
      recovery_commit_allowed = 1'b0;
    lock.put(1);
    return make_runtime_status(RDMA_SC_OK, "");
  endfunction

  // 功能：cursor_equal 将两组 index/wrap 作为完整 ring cursor 比较。
  // 输入/输出及副作用：a/aw 与 b/bw（输入）；两字段均相等时返回 1，纯读取且
  //   不修改 runtime、ledger 或调用方变量。
  // 失败/边界：任一 index 或 wrap 不等即返回 0；本 helper 不验证 index<depth。
  function bit cursor_equal(
    int unsigned a,
    bit aw,
    int unsigned b,
    bit bw
  );
    return a == b && aw == bw;
  endfunction

  // 功能：release_range_slot_shape_valid 校验释放范围当前位置的 ledger slot 是否符合
  //       cursor 对应的已发布、未消费条目形状，供四个 range API 共用。
  // 输入/输出及副作用：slot、expected_index、expected_wrap（输入）；只读 slot 的 posted、
  //       consumed、index、wrap 字段并返回 bit，不修改 runtime、ledger、cursor 或 status。
  // 失败/边界：slot 为空、未 posted、已 consumed 或 index/wrap 不匹配时返回 0；helper 不检查
  //       depth、used、target 可达性，也不改变调用方的错误优先级、锁生命周期或状态副作用。
  protected function bit release_range_slot_shape_valid(
    rdma_queue_slot_ledger_entry slot,
    int unsigned expected_index,
    bit expected_wrap
  );
    if (slot == null)
      return 1'b0;
    return slot.posted && !slot.consumed &&
           slot.index == expected_index && slot.wrap == expected_wrap;
  endfunction

  // 功能：cursor_advance 为 queue runtime 保留兼容 wrapper，把当前 ring successor
  //   计算转发给共享 detached cursor policy，并原地更新 runtime caller 的 i/w。
  // 输入/输出及副作用：i/w（输入/输出）被更新；只读 runtime.depth，不修改 occupancy、
  //   reservation 或 slot ledger；policy 本身不访问 runtime 或外部资源。
  // 失败/边界：该内部 wrapper 假定 caller 已完成 depth>0 且 i<depth 校验，不返回错误；
  //   对外拒绝条件仍由各 runtime admission 分支负责，不能把 successor 当作 commit。
  function void cursor_advance(inout int unsigned i, inout bit w);
    rdma_queue_cursor_policy::advance(depth, i, w, i, w);
  endfunction

  // 功能：release_range_target_reachable 从当前 host consumer cursor 沿 ring
  //   successor 逐步寻找 completion target，统一判断 target 是否仍落在一个
  //   最多 depth 步的可寻址窗口内。
  // 输入/输出及副作用：target_index、target_wrap 为待匹配的目标 cursor；函数只
  //   读 runtime 的 consumer_index、consumer_wrap 和 depth，在局部变量中模拟 cursor
  //   前进并返回 bit，不修改 CI、used、slot ledger、锁或 status。
  // 失败/边界：target 在当前 cursor 或恰好 depth 步后到达时返回 1；超过 depth
  //   仍未命中返回 0。函数不检查 target 越界、slot 内容或 used，调用方必须
  //   保留自己的 geometry、occupancy、slot-shape、锁和错误文本门禁。
  protected function bit release_range_target_reachable(
    int unsigned target_index,
    bit target_wrap
  );
    int unsigned i;
    bit w;
    int unsigned count;

    i = consumer_index;
    w = consumer_wrap;
    count = 0;
    while (!cursor_equal(i, w, target_index, target_wrap) && count <= depth) begin
      cursor_advance(i, w);
      count++;
    end
    return !(count >= depth &&
             !cursor_equal(i, w, target_index, target_wrap));
  endfunction

  // 功能：match_and_release 从当前 host consumer cursor 连续校验到 completion
  //   target，随后一次性释放这段已 posted WQE，并推进 CI/减少 used。
  // 输入/输出及副作用：target_index/target_wrap（输入）指定完成项；released（输出）
  //   先清空，成功时按消费顺序返回 runtime-owned slot 的非拥有引用队列。
  // 失败/边界：非 ACTIVE/未授权 recovery、target 越界或不在一个 ring 窗口内，
  //   以及范围内存在 null/unposted/consumed/stale slot 时返回错误且不释放任何项。
  function rdma_status match_and_release(
    int unsigned target_index,
    bit target_wrap,
    output rdma_queue_slot_ledger_entry released[$]
  );
    int unsigned i;
    bit w;
    int unsigned count;
    bit reached_target;
    rdma_queue_slot_ledger_entry slot;
    rdma_queue_slot_ledger_entry check_slot;
    rdma_status lock_status;

    released.delete();
    lock_status = acquire_lock();
    if (!lock_status.ok()) return lock_status;
    if (state != RDMA_QUEUE_RUNTIME_ACTIVE &&
        !(recovery_commit_allowed &&
          state == RDMA_QUEUE_RUNTIME_RECOVERY_REQUIRED)) begin
      lock.put(1);
      return make_runtime_status(RDMA_SC_INVALID_STATE,
                                 "queue runtime is not active");
    end
    if (target_index >= depth) begin
      lock.put(1);
      return make_runtime_status(RDMA_SC_INVALID_ARGUMENT,
                                 "completion index is outside depth");
    end
    if (!release_range_target_reachable(target_index, target_wrap)) begin
      lock.put(1);
      return make_runtime_status(RDMA_SC_INVALID_STATE,
                                 "completion cursor is not outstanding");
    end
    // 中文设计：先完整校验释放区间，再修改任一 slot；畸形 completion 因而
    // 不会只推进一部分 CI 或只释放一部分 credit。
    count = 0;
    i = consumer_index;
    w = consumer_wrap;
    do begin
      check_slot = slots[i];
      if (!release_range_slot_shape_valid(check_slot, i, w)) begin
        lock.put(1);
        released.delete();
        return make_runtime_status(RDMA_SC_INVALID_STATE,
                                   "completion skips an unposted slot");
      end
      reached_target = cursor_equal(i, w, target_index, target_wrap);
      cursor_advance(i, w);
      count++;
      if (reached_target) break;
    end while (count <= depth);
    count = 0;
    i = consumer_index;
    w = consumer_wrap;
    do begin
      slot = slots[i];
      reached_target = cursor_equal(i, w, target_index, target_wrap);
      slot.consumed = 1'b1;
      slot.posted = 1'b0;
      released.push_back(slot);
      if (used > 0) used--;
      cursor_advance(i, w);
      count++;
      if (reached_target) break;
    end while (count <= depth);
    consumer_index = i;
    consumer_wrap = w;
    lock.put(1);
    return make_runtime_status(RDMA_SC_OK, "");
  endfunction

  // 功能：match_and_release_noalloc 以冻结 completion cursor 原子释放 host
  //   SQ/RQ/SRQ ledger range，供 CQ scheduler barrier 后不构造 returned slot 队列。
  // 输入/输出及副作用：target_index/target_wrap 指定最后一项，status_slot 由 caller
  //   预建；成功把连续 slot 标为 consumed、推进 host CI 并按项递减 used。
  // 失败/边界：status slot/null lock、非 host ring、状态/target、
  //   slots 容量或 used occupancy 不一致时返回 0；函数先校验完整
  //   区间再修改任一 slot，拒绝路径保持 CI、used 和 ledger 原样。
  function bit match_and_release_noalloc(
    int unsigned target_index,
    bit target_wrap,
    rdma_status status_slot
  );
    int unsigned i;
    bit w;
    int unsigned count;
    bit reached_target;
    rdma_queue_slot_ledger_entry slot;

    if (status_slot == null) return 1'b0;
    if (lock == null || !lock.try_get(1)) begin
      void'(set_runtime_status_noalloc(
        status_slot, RDMA_SC_RESOURCE_BUSY, "queue runtime is busy"));
      return 1'b0;
    end
    if (!host_produced ||
        !(kind inside {RDMA_QUEUE_RUNTIME_SQ, RDMA_QUEUE_RUNTIME_RQ,
                       RDMA_QUEUE_RUNTIME_SRQ}) ||
        (state != RDMA_QUEUE_RUNTIME_ACTIVE &&
         !(recovery_commit_allowed &&
           state == RDMA_QUEUE_RUNTIME_RECOVERY_REQUIRED))) begin
      lock.put(1);
      void'(set_runtime_status_noalloc(
        status_slot, RDMA_SC_INVALID_STATE,
        "queue runtime is not an active host WQ"));
      return 1'b0;
    end
    if (depth == 0 || target_index >= depth) begin
      lock.put(1);
      void'(set_runtime_status_noalloc(
        status_slot, RDMA_SC_INVALID_ARGUMENT,
        "completion index is outside depth"));
      return 1'b0;
    end
    if (consumer_index >= depth || slots.size() < depth || used == 0 ||
        used > depth) begin
      lock.put(1);
      void'(set_runtime_status_noalloc(
        status_slot, RDMA_SC_INVALID_STATE,
        "completion ledger geometry or occupancy is invalid"));
      return 1'b0;
    end

    // 中文设计：先从当前 CI 到 target 逐项验证完整 outstanding ledger；任何
    // null/unposted/consumed/stale 项都在 mutation 前拒绝，避免只释放半段 credit。
    i = consumer_index;
    w = consumer_wrap;
    count = 0;
    do begin
      if (count >= depth || count >= used) begin
        lock.put(1);
        void'(set_runtime_status_noalloc(
          status_slot, RDMA_SC_INVALID_STATE,
          "completion cursor is not outstanding"));
        return 1'b0;
      end
      slot = slots[i];
      if (!release_range_slot_shape_valid(slot, i, w)) begin
        lock.put(1);
        void'(set_runtime_status_noalloc(
          status_slot, RDMA_SC_INVALID_STATE,
          "completion skips an unposted slot"));
        return 1'b0;
      end
      reached_target = cursor_equal(i, w, target_index, target_wrap);
      cursor_advance(i, w);
      count++;
      if (reached_target) break;
    end while (count <= depth);
    if (!reached_target) begin
      lock.put(1);
      void'(set_runtime_status_noalloc(
        status_slot, RDMA_SC_INVALID_STATE,
        "completion cursor is not outstanding"));
      return 1'b0;
    end

    i = consumer_index;
    w = consumer_wrap;
    count = 0;
    do begin
      slot = slots[i];
      reached_target = cursor_equal(i, w, target_index, target_wrap);
      slot.consumed = 1'b1;
      slot.posted = 1'b0;
      used--;
      cursor_advance(i, w);
      count++;
      if (reached_target) break;
    end while (count <= depth);
    consumer_index = i;
    consumer_wrap = w;
    lock.put(1);
    void'(set_runtime_status_noalloc(status_slot, RDMA_SC_OK, ""));
    return 1'b1;
  endfunction

  // 功能：snapshot_release_range 在 runtime lock 内校验从当前 host consumer CI
  //   到 target_index/target_wrap 的完整 outstanding WQE range，并深复制每一项。
  // 输入/输出及副作用：target cursor 为输入，snapshots 为输出并先清空；成功按
  //   消费顺序返回 detached slot/request/image/status 值，不推进 CI、不减少 used。
  // 失败/边界：非 ACTIVE host ring、空/越界/非 outstanding target、畸形 ledger，
  //   或任一 raw factory/nested copy 失败时清空全部输出且 ledger/游标/credit 不变。
  function rdma_status snapshot_release_range(
    int unsigned target_index,
    bit target_wrap,
    output rdma_queue_slot_ledger_entry snapshots[$]
  );
    int unsigned i;
    bit w;
    int unsigned count;
    bit reached_target;
    rdma_queue_slot_ledger_entry slot;
    rdma_queue_slot_ledger_entry slot_copy;
    rdma_queue_slot_ledger_entry staged[$];
    rdma_status lock_status;
    rdma_status copy_status;

    snapshots.delete();
    staged.delete();
    lock_status = acquire_lock();
    if (!status_is_ok(lock_status)) return lock_status;
    if (state != RDMA_QUEUE_RUNTIME_ACTIVE || !host_produced ||
        is_device_ring_kind(kind) || depth == 0 || slots.size() < depth) begin
      lock.put(1);
      return make_runtime_status(RDMA_SC_INVALID_STATE,
                                 "release range runtime is not active host WQ");
    end
    if (target_index >= depth) begin
      lock.put(1);
      return make_runtime_status(RDMA_SC_INVALID_ARGUMENT,
                                 "completion index is outside depth");
    end
    if (used == 0 || used > depth) begin
      lock.put(1);
      return make_runtime_status(RDMA_SC_INVALID_STATE,
                                 "release range has invalid occupancy");
    end

    i = consumer_index;
    w = consumer_wrap;
    count = 0;
    do begin
      if (count >= used || count >= depth) begin
        lock.put(1);
        snapshots.delete();
        return make_runtime_status(RDMA_SC_INVALID_STATE,
                                   "completion cursor is not outstanding");
      end
      slot = slots[i];
      if (!release_range_slot_shape_valid(slot, i, w)) begin
        lock.put(1);
        snapshots.delete();
        return make_runtime_status(RDMA_SC_INVALID_STATE,
                                   "completion skips an unposted slot");
      end
      copy_status = clone_slot_value_nonfatal(slot, slot_copy);
      if (!status_is_ok(copy_status) || slot_copy == null) begin
        lock.put(1);
        snapshots.delete();
        return copy_status == null ?
          make_runtime_status(RDMA_SC_RESOURCE_EXHAUSTED,
                              "release range clone returned null status") :
          copy_status;
      end
      staged.push_back(slot_copy);
      reached_target = cursor_equal(i, w, target_index, target_wrap);
      cursor_advance(i, w);
      count++;
      if (reached_target) break;
    end while (count <= depth);

    foreach (staged[j]) snapshots.push_back(staged[j]);
    lock.put(1);
    return make_runtime_status(RDMA_SC_OK, "");
  endfunction

  // 功能：validate_release_range 在发送 CQ consumer doorbell 前只读验证从当前
  //   CI 到 completion target 的连续 posted WQE 区间。
  // 输入/输出及副作用：target_index/target_wrap（输入）；只读 cursor 与 slot ledger，
  //   返回 rdma_status，不消费 slot、不推进 CI、不释放 credit。
  // 失败/边界：非 ACTIVE、target 越界/不在一个 ring 窗口内，或区间含 null、
  //   unposted、consumed、index/wrap 不一致项时返回错误，ledger 保持不变。
  function rdma_status validate_release_range(
    int unsigned target_index, bit target_wrap
  );
    int unsigned i;
    bit w;
    int unsigned count;
    bit reached_target;
    rdma_queue_slot_ledger_entry slot;
    rdma_status lock_status;
    lock_status = acquire_lock();
    if (!lock_status.ok()) return lock_status;
    if (state != RDMA_QUEUE_RUNTIME_ACTIVE) begin
      lock.put(1);
      return make_runtime_status(RDMA_SC_INVALID_STATE,
                                 "queue runtime is not active");
    end
    if (target_index >= depth) begin
      lock.put(1);
      return make_runtime_status(RDMA_SC_INVALID_ARGUMENT,
                                 "completion index is outside depth");
    end
    if (!release_range_target_reachable(target_index, target_wrap)) begin
      lock.put(1);
      return make_runtime_status(RDMA_SC_INVALID_STATE,
                                 "completion cursor is not outstanding");
    end
    count = 0;
    i = consumer_index;
    w = consumer_wrap;
    do begin
      slot = slots[i];
      if (!release_range_slot_shape_valid(slot, i, w)) begin
        lock.put(1);
        return make_runtime_status(RDMA_SC_INVALID_STATE,
                                   "completion skips an unposted slot");
      end
      reached_target = cursor_equal(i, w, target_index, target_wrap);
      cursor_advance(i, w);
      count++;
      if (reached_target) break;
    end while (count <= depth);
    lock.put(1);
    return make_runtime_status(RDMA_SC_OK, "");
  endfunction

  // 功能：enter_recovery 为 SQ/RQ/SRQ host producer 保留 legacy bit 入口，将
  //   caller operation 深复制为 runtime-owned pending 并投影 NO_SUBMIT/AMBIGUOUS。
  // 输入/输出及副作用：operation、mmio_maybe_submitted（输入）；成功切换为
  //   RECOVERY_REQUIRED 并保存 detached pending、清空 commit/retry/release gate，
  //   不接管 caller 原对象或外部 backing。
  // 失败/边界：非 ACTIVE、非 host-produced producer、CQ/CEQ/AEQ、identity/cursor
  //   冲突或复制分配失败时返回错误；device producer/consumer 必须使用 prepared 入口。
  function rdma_status enter_recovery(rdma_queue_pending_operation operation, bit mmio_maybe_submitted);
    rdma_status lock_status;
    rdma_status copy_status;
    rdma_status next_status;
    rdma_status project_status;
    rdma_queue_pending_operation copy;
    rdma_queue_cursor_snapshot derived_next;
    rdma_handle queue_copy;
    rdma_queue_mmio_evidence_e evidence;
    uvm_object raw_cursor;

    lock_status = acquire_lock();
    if (!status_is_ok(lock_status)) return lock_status;
    if (state != RDMA_QUEUE_RUNTIME_ACTIVE || operation == null) begin
      lock.put(1);
      return make_runtime_status(RDMA_SC_INVALID_STATE,
                                 "queue runtime cannot enter legacy recovery");
    end
    // 设计说明：legacy bit 无法表达 device publish/consumer 所需的 route、epoch、
    // image 与阶段 authority；在复制或字段补全前先按显式 producer 方向拒绝，
    // 避免默认值被反向推断为一笔可重放 device transaction。
    if (!host_produced || operation.device_producer || !operation.producer ||
        !(kind inside {RDMA_QUEUE_RUNTIME_SQ, RDMA_QUEUE_RUNTIME_RQ,
                       RDMA_QUEUE_RUNTIME_SRQ})) begin
      lock.put(1);
      return make_runtime_status(RDMA_SC_INVALID_STATE,
                                 "legacy recovery requires host producer");
    end
    copy_status = clone_pending_value(operation, copy);
    if (!status_is_ok(copy_status) || copy == null) begin
      lock.put(1);
      return (copy_status != null) ? copy_status :
        make_runtime_status(RDMA_SC_RESOURCE_EXHAUSTED,
                            "pending operation value copy failed");
    end

    // 中文设计：legacy caller 可能省略 queue_h，或把 kind 留在构造默认 SQ；
    // 这里只从当前 immutable runtime 补齐缺失身份，caller 显式给出的不一致值
    // 仍由下方校验拒绝，不能借兼容逻辑覆盖。
    if (copy.queue_h == null) begin
      copy_status = clone_handle_value_nonfatal(queue_h, queue_copy);
      if (!status_is_ok(copy_status) || queue_copy == null) begin
        lock.put(1);
        return (copy_status != null) ? copy_status :
          make_runtime_status(RDMA_SC_RESOURCE_EXHAUSTED,
                              "legacy recovery queue snapshot failed");
      end
      copy.queue_h = queue_copy;
      if (copy.kind != kind && copy.kind == RDMA_QUEUE_RUNTIME_SQ)
        copy.kind = kind;
    end
    if (copy.queue_h == null || queue_h == null ||
        !handle_value_equal(copy.queue_h, queue_h) || copy.kind != kind) begin
      lock.put(1);
      return make_runtime_status(RDMA_SC_INVALID_ARGUMENT,
                                 "legacy recovery identity mismatch");
    end
    if (!copy.producer || copy.device_producer || !host_produced ||
        !(kind inside {RDMA_QUEUE_RUNTIME_SQ, RDMA_QUEUE_RUNTIME_RQ,
                       RDMA_QUEUE_RUNTIME_SRQ})) begin
      lock.put(1);
      return make_runtime_status(RDMA_SC_INVALID_STATE,
                                 "legacy producer direction mismatch");
    end

    if (copy.cursor == null) begin
      raw_cursor = factory_create_object_nonfatal(
        rdma_queue_cursor_snapshot::get_type(), "legacy_recovery_cursor");
      if (raw_cursor == null || !$cast(copy.cursor, raw_cursor)) begin
        copy.cursor = null;
        lock.put(1);
        return make_runtime_status(RDMA_SC_RESOURCE_EXHAUSTED,
                                   "legacy recovery cursor allocation failed");
      end
      if (copy.producer) begin
        copy.cursor.index = producer_index;
        copy.cursor.wrap = producer_wrap;
      end else begin
        copy.cursor.index = consumer_index;
        copy.cursor.wrap = consumer_wrap;
      end
    end
    if (depth == 0 || copy.cursor.index >= depth) begin
      lock.put(1);
      return make_runtime_status(RDMA_SC_INVALID_ARGUMENT,
                                 "legacy recovery cursor is outside depth");
    end
    // 中文设计：在当前 runtime lock 保护的 geometry 下推导并保存提交后 cursor；
    // recovery 不依赖可变 caller cursor，也不在未来重新查询可能已变的 geometry。
    if (copy.next_cursor == null) begin
      next_status = derive_next_cursor(copy.cursor, derived_next);
      if (!status_is_ok(next_status) || derived_next == null) begin
        lock.put(1);
        return (next_status != null) ? next_status :
          make_runtime_status(RDMA_SC_RESOURCE_EXHAUSTED,
                              "legacy recovery next cursor allocation failed");
      end
      copy.next_cursor = derived_next;
    end
    next_status = derive_next_cursor(copy.cursor, derived_next);
    if (!status_is_ok(next_status) || derived_next == null ||
        copy.next_cursor.index >= depth ||
        !cursor_equal(derived_next.index, derived_next.wrap,
                      copy.next_cursor.index, copy.next_cursor.wrap)) begin
      lock.put(1);
      return make_runtime_status(RDMA_SC_INVALID_ARGUMENT,
                                 "legacy recovery next cursor is invalid");
    end
    if (copy.entry_size == 0 && copy.image != null &&
        copy.image.length != 0)
      copy.entry_size = copy.image.length;
    if (copy.entry_offset == 0 && copy.entry_size != 0 &&
        copy.cursor.index != 0)
      copy.entry_offset = longint'(copy.cursor.index) * copy.entry_size;

    evidence = mmio_maybe_submitted ? RDMA_QUEUE_MMIO_AMBIGUOUS :
                                      RDMA_QUEUE_MMIO_NO_SUBMIT;
    copy.mmio_evidence = evidence;
    copy.mmio_maybe_submitted = (evidence == RDMA_QUEUE_MMIO_AMBIGUOUS);
    copy.known_no_mmio = (evidence == RDMA_QUEUE_MMIO_NO_SUBMIT);
    copy.consumer_doorbell_succeeded = 1'b0;
    pending_operation_state = copy;
    state = RDMA_QUEUE_RUNTIME_RECOVERY_REQUIRED;
    project_status = project_mmio_evidence_locked(evidence);
    if (!status_is_ok(project_status)) begin
      pending_operation_state = null;
      state = RDMA_QUEUE_RUNTIME_ACTIVE;
      lock.put(1);
      return (project_status != null) ? project_status :
        make_runtime_status(RDMA_SC_RESOURCE_EXHAUSTED,
                            "legacy MMIO evidence projection failed");
    end
    recovery_commit_allowed = 1'b0;
    consumer_release_gate_active = 1'b0;
    recovery_retry_confirmed = 1'b0;
    lock.put(1);
    return make_runtime_status(RDMA_SC_OK, "");
  endfunction

  // 功能：enter_recovery_prepared 接管调用方已完成 detached 的 pending；首次
  //   admission 安装 recovery evidence，重复 admission 只单调合并同一事务阶段。
  // 输入/输出及副作用：prepared（输入）在首次成功后由 runtime 接管，状态切换为
  //   RECOVERY_REQUIRED；重复成功只合并 MMIO/commit 阶段并重置本轮 commit/retry/
  //   release gate，reservation 保持原快照。
  // 失败/边界：null、非 ACTIVE、identity/direction/geometry/image/status/route/epoch
  //   不完整或 reservation 冲突均原子拒绝；重复事务若 immutable evidence、cursor、
  //   MMIO 转换或阶段顺序冲突也拒绝，不发布部分 merge。
  function rdma_status enter_recovery_prepared(rdma_queue_pending_operation prepared);
    rdma_status lock_status;
    rdma_status copy_status;
    rdma_status project_status;
    rdma_status next_status;
    rdma_queue_cursor_snapshot expected_next;
    rdma_queue_cursor_snapshot staged_committed_cursor;
    bit device_direction;
    bit consumer_direction;
    bit merged_device_write_attempted;
    bit merged_consumer_committed;
    bit merged_cq_consumer_committed;
    bit merged_completion_released;
    rdma_queue_cursor_snapshot merged_committed_cursor;

    lock_status = acquire_lock();
    if (!status_is_ok(lock_status)) return lock_status;
    if (prepared == null) begin
      lock.put(1);
      return make_runtime_status(RDMA_SC_INVALID_ARGUMENT,
                                 "prepared recovery is null");
    end

    // 中文设计：重复 admission 先按值比较完整 immutable object graph；只有
    // queue/cursor/image/status/request/WR/completion/route 全部属于同一 transaction，
    // 才允许后续 MMIO 投影和阶段位单调合并。
    if (state == RDMA_QUEUE_RUNTIME_RECOVERY_REQUIRED &&
        pending_operation_state != null) begin
      if (!pending_immutable_evidence_equal(prepared,
                                            pending_operation_state)) begin
        lock.put(1);
        return make_runtime_status(RDMA_SC_INVALID_STATE,
                                   "prepared recovery immutable evidence conflicts");
      end
      if (pending_operation_state.consumer_shadow_required &&
          (prepared.consumer_shadow_attempted !=
             pending_operation_state.consumer_shadow_attempted ||
           prepared.consumer_shadow_published !=
             pending_operation_state.consumer_shadow_published)) begin
        lock.put(1);
        return make_runtime_status(
          RDMA_SC_INVALID_STATE,
          "prepared CQC shadow phase conflicts with pending");
      end
      if (!(prepared.mmio_evidence inside {RDMA_QUEUE_MMIO_NONE,
                                           RDMA_QUEUE_MMIO_NOT_APPLICABLE,
                                           RDMA_QUEUE_MMIO_NO_SUBMIT,
                                           RDMA_QUEUE_MMIO_SUCCESS,
                                           RDMA_QUEUE_MMIO_AMBIGUOUS})) begin
        lock.put(1);
        return make_runtime_status(RDMA_SC_INVALID_ARGUMENT,
                                   "prepared MMIO evidence is invalid");
      end

      // 中文设计：immutable 比较与其余阶段校验全部完成后才投影 evidence；否则
      // committed cursor 冲突可能在 enum/兼容位已改变后才返回错误。
      if (prepared.committed_consumer_cursor != null &&
          (!cursor_equal(prepared.committed_consumer_cursor.index,
                         prepared.committed_consumer_cursor.wrap,
                         pending_operation_state.next_cursor.index,
                         pending_operation_state.next_cursor.wrap) ||
           (pending_operation_state.committed_consumer_cursor != null &&
            !cursor_equal(prepared.committed_consumer_cursor.index,
                          prepared.committed_consumer_cursor.wrap,
                          pending_operation_state.committed_consumer_cursor.index,
                          pending_operation_state.committed_consumer_cursor.wrap)))) begin
        lock.put(1);
        return make_runtime_status(RDMA_SC_INVALID_STATE,
                                   "prepared committed cursor conflicts with pending");
      end

      merged_device_write_attempted =
        pending_operation_state.device_write_attempted ||
        prepared.device_write_attempted;
      merged_consumer_committed = pending_operation_state.consumer_committed ||
                                  prepared.consumer_committed;
      merged_cq_consumer_committed =
        pending_operation_state.cq_consumer_committed ||
        prepared.cq_consumer_committed;
      merged_completion_released = pending_operation_state.completion_released ||
                                   prepared.completion_released;
      merged_committed_cursor = pending_operation_state.committed_consumer_cursor;
      if (merged_committed_cursor == null)
        merged_committed_cursor = prepared.committed_consumer_cursor;
      device_direction = pending_operation_state.device_producer;
      consumer_direction = (!pending_operation_state.producer &&
                            !pending_operation_state.device_producer);
      if ((!device_direction && merged_device_write_attempted) ||
          (!consumer_direction &&
           (merged_consumer_committed || merged_cq_consumer_committed ||
            merged_completion_released)) ||
          (merged_consumer_committed &&
           !((pending_operation_state.consumer_shadow_required &&
              prepared.consumer_shadow_published &&
              prepared.mmio_evidence == RDMA_QUEUE_MMIO_NO_SUBMIT) ||
             (!pending_operation_state.consumer_shadow_required &&
              prepared.mmio_evidence == RDMA_QUEUE_MMIO_SUCCESS))) ||
          (merged_cq_consumer_committed &&
           (!merged_consumer_committed || kind != RDMA_QUEUE_RUNTIME_CQ)) ||
          (merged_completion_released &&
           (!merged_consumer_committed || kind != RDMA_QUEUE_RUNTIME_CQ ||
            !pending_operation_state.completion_target_valid)) ||
          (merged_consumer_committed &&
           pending_operation_state.committed_consumer_cursor == null &&
           prepared.committed_consumer_cursor == null)) begin
        lock.put(1);
        return make_runtime_status(RDMA_SC_INVALID_STATE,
                                   "prepared recovery phase merge is invalid");
      end
      if (consumer_direction &&
          !consumer_recovery_invariant_locked(
            pending_operation_state, prepared.mmio_evidence,
            merged_consumer_committed, merged_committed_cursor)) begin
        lock.put(1);
        return make_runtime_status(
          RDMA_SC_INVALID_STATE,
          "prepared consumer merge violates commit invariant");
      end
      staged_committed_cursor = null;
      if (prepared.committed_consumer_cursor != null &&
          pending_operation_state.committed_consumer_cursor == null) begin
        copy_status = clone_cursor_value_nonfatal(
          prepared.committed_consumer_cursor, staged_committed_cursor);
        if (!status_is_ok(copy_status) || staged_committed_cursor == null) begin
          lock.put(1);
          return (copy_status != null) ? copy_status : make_runtime_status(
            RDMA_SC_RESOURCE_EXHAUSTED,
            "prepared committed cursor copy failed");
        end
      end
      project_status = project_mmio_evidence_locked(prepared.mmio_evidence);
      if (!status_is_ok(project_status)) begin
        lock.put(1);
        return project_status != null ? project_status :
          make_runtime_status(RDMA_SC_INVALID_STATE,
                              "prepared MMIO evidence merge failed");
      end
      if (prepared.device_write_attempted)
        pending_operation_state.device_write_attempted = 1'b1;
      if (prepared.consumer_committed)
        pending_operation_state.consumer_committed = 1'b1;
      if (prepared.cq_consumer_committed)
        pending_operation_state.cq_consumer_committed = 1'b1;
      if (prepared.completion_released)
        pending_operation_state.completion_released = 1'b1;
      if (staged_committed_cursor != null)
        pending_operation_state.committed_consumer_cursor = staged_committed_cursor;
      recovery_commit_allowed = 1'b0;
      consumer_release_gate_active = 1'b0;
      recovery_retry_confirmed = 1'b0;
      lock.put(1);
      return make_runtime_status(RDMA_SC_OK, "");
    end

    if (state != RDMA_QUEUE_RUNTIME_ACTIVE || pending_operation_state != null) begin
      lock.put(1);
      return make_runtime_status(RDMA_SC_INVALID_STATE,
                                 "runtime cannot install prepared recovery");
    end
    if (prepared.queue_h == null || queue_h == null ||
        !handle_value_equal(prepared.queue_h, queue_h)) begin
      lock.put(1);
      return make_runtime_status(RDMA_SC_INVALID_ARGUMENT,
                                 "prepared recovery identity mismatch");
    end
    device_direction = prepared.device_producer;
    consumer_direction = (!prepared.producer && !prepared.device_producer);
    if (prepared.kind != kind ||
        (device_direction &&
         (host_produced || !is_device_ring_kind(kind) || prepared.producer)) ||
        (prepared.producer &&
         (!host_produced || is_device_ring_kind(kind))) ||
        (consumer_direction &&
         (host_produced || !is_device_ring_kind(kind)))) begin
      lock.put(1);
      return make_runtime_status(RDMA_SC_INVALID_STATE,
                                 "prepared recovery direction mismatch");
    end
    if (!pending_cursor_geometry_valid(prepared)) begin
      lock.put(1);
      return make_runtime_status(RDMA_SC_INVALID_ARGUMENT,
                                 "prepared recovery geometry is invalid");
    end
    next_status = derive_next_cursor(prepared.cursor, expected_next);
    if (!status_is_ok(next_status) || expected_next == null ||
        !cursor_equal(expected_next.index, expected_next.wrap,
                      prepared.next_cursor.index, prepared.next_cursor.wrap)) begin
      lock.put(1);
      return (next_status != null && !next_status.ok()) ? next_status :
        make_runtime_status(RDMA_SC_INVALID_ARGUMENT,
                            "prepared recovery next cursor is invalid");
    end
    if (prepared.image == null || prepared.image.length != prepared.entry_size ||
        prepared.image.bytes.size() != prepared.image.length ||
        prepared.failure_status == null) begin
      lock.put(1);
      return make_runtime_status(RDMA_SC_INVALID_ARGUMENT,
                                 "prepared recovery image/status evidence is incomplete");
    end
    if (!route_valid || !epoch_valid || !prepared.route_valid ||
        !prepared.epoch_valid || !rdma_route_key_valid(prepared.route) ||
        !same_route_epoch_value(prepared.route, prepared.reset_epoch,
                                route, reset_epoch)) begin
      lock.put(1);
      return make_runtime_status(RDMA_SC_INVALID_ARGUMENT,
                                 "prepared recovery route epoch mismatch");
    end
    if (device_direction &&
        (!device_reservation_valid || !reservation_matches(prepared.cursor))) begin
      lock.put(1);
      return make_runtime_status(RDMA_SC_INVALID_STATE,
                                 "device reservation does not match pending");
    end
    if (consumer_direction && device_reservation_valid) begin
      lock.put(1);
      return make_runtime_status(RDMA_SC_RESOURCE_BUSY,
                                 "consumer recovery conflicts with device reservation");
    end
    if (!(prepared.mmio_evidence inside {RDMA_QUEUE_MMIO_NONE,
                                         RDMA_QUEUE_MMIO_NOT_APPLICABLE,
                                         RDMA_QUEUE_MMIO_NO_SUBMIT,
                                         RDMA_QUEUE_MMIO_SUCCESS,
                                         RDMA_QUEUE_MMIO_AMBIGUOUS})) begin
      lock.put(1);
      return make_runtime_status(RDMA_SC_INVALID_ARGUMENT,
                                 "prepared MMIO evidence is invalid");
    end
    if ((device_direction &&
         !(prepared.mmio_evidence inside {RDMA_QUEUE_MMIO_NONE,
                                          RDMA_QUEUE_MMIO_NOT_APPLICABLE,
                                          RDMA_QUEUE_MMIO_NO_SUBMIT})) ||
        (!device_direction &&
         prepared.mmio_evidence == RDMA_QUEUE_MMIO_NOT_APPLICABLE)) begin
      lock.put(1);
      return make_runtime_status(RDMA_SC_INVALID_STATE,
                                 "prepared MMIO evidence direction mismatch");
    end
    if (prepared.consumer_shadow_required &&
        (!consumer_direction || prepared.kind != RDMA_QUEUE_RUNTIME_CQ ||
         prepared.consumer_shadow_offset != RDMA_CQC_RUNTIME_SHADOW_BYTE_OFFSET ||
         prepared.consumer_shadow_length != RDMA_CQC_RUNTIME_SHADOW_BYTE_LENGTH ||
         (!prepared.consumer_shadow_urc &&
          prepared.consumer_shadow_value[31:24] != 8'h00) ||
         prepared.consumer_doorbell_succeeded ||
         prepared.mmio_maybe_submitted ||
         (prepared.consumer_shadow_published &&
          (!prepared.consumer_shadow_attempted ||
           prepared.mmio_evidence != RDMA_QUEUE_MMIO_NO_SUBMIT)) ||
         (!prepared.consumer_shadow_published &&
          prepared.consumer_shadow_attempted &&
          !(prepared.mmio_evidence inside {RDMA_QUEUE_MMIO_NONE,
                                           RDMA_QUEUE_MMIO_NO_SUBMIT})))) begin
      lock.put(1);
      return make_runtime_status(
        RDMA_SC_INVALID_STATE,
        "prepared CQC shadow evidence is invalid");
    end
    if ((!consumer_direction && prepared.consumer_committed) ||
        (!consumer_direction && prepared.cq_consumer_committed) ||
        (!consumer_direction && prepared.completion_released) ||
        (prepared.cq_consumer_committed && !prepared.consumer_committed) ||
        (prepared.completion_released &&
         (!prepared.completion_target_valid || !prepared.consumer_committed)) ||
        (prepared.consumer_committed &&
         prepared.committed_consumer_cursor == null)) begin
      lock.put(1);
      return make_runtime_status(RDMA_SC_INVALID_STATE,
                                 "prepared recovery phase ordering is invalid");
    end
    if (consumer_direction &&
        !consumer_recovery_invariant_locked(
          prepared, prepared.mmio_evidence, prepared.consumer_committed,
          prepared.committed_consumer_cursor)) begin
      lock.put(1);
      return make_runtime_status(
        RDMA_SC_INVALID_STATE,
        "prepared consumer recovery violates commit invariant");
    end
    pending_operation_state = prepared;
    state = RDMA_QUEUE_RUNTIME_RECOVERY_REQUIRED;
    project_status = project_mmio_evidence_locked(prepared.mmio_evidence);
    if (!status_is_ok(project_status)) begin
      pending_operation_state = null;
      state = RDMA_QUEUE_RUNTIME_ACTIVE;
      lock.put(1);
      return (project_status != null) ? project_status : make_runtime_status(
        RDMA_SC_RESOURCE_EXHAUSTED,"prepared MMIO evidence projection failed");
    end
    recovery_commit_allowed = 1'b0;
    consumer_release_gate_active = 1'b0;
    recovery_retry_confirmed = 1'b0;
    lock.put(1);
    return make_runtime_status(RDMA_SC_OK, "");
  endfunction

  // 功能：query_pending 返回当前 recovery pending 的 detached clone。
  // 输入/输出及副作用：snapshot（输出）先置 null；成功时复制 pending，调用方不得修改 runtime 内部对象。
  // 失败/边界：没有 pending、runtime 非 RECOVERY_REQUIRED 或 clone 失败时返回非成功状态并保持 null。
  function rdma_status query_pending(output rdma_queue_pending_operation snapshot);
    snapshot = null;
    return snapshot_pending(snapshot);
  endfunction

  // 功能：query_has_pending 查询 runtime 是否持有 pending evidence。
  // 输入/输出及副作用：present（输出）先置零，成功时写入 pending_operation_state != null；不修改 runtime。
  // 失败/边界：未配置 runtime 或锁忙时返回错误并保持安全输出。
  function rdma_status query_has_pending(output bit present);
    rdma_status lock_status;
    present = 1'b0;
    lock_status = acquire_lock();
    if (!lock_status.ok()) return lock_status;
    if (depth == 0) begin
      lock.put(1);
      return make_runtime_status(RDMA_SC_INVALID_STATE,
                                 "runtime is unconfigured");
    end
    present = (pending_operation_state != null);
    lock.put(1);
    return make_runtime_status(RDMA_SC_OK, "");
  endfunction

  // 功能：query_state 返回 runtime 当前状态快照。
  // 输入/输出及副作用：runtime_state（输出）先置 DETACHED，成功时写入 state；不改变状态机。
  // 失败/边界：锁忙时返回 RESOURCE_BUSY，输出保持 DETACHED。
  function rdma_status query_state(output rdma_queue_runtime_state_e runtime_state);
    rdma_status lock_status;
    runtime_state = RDMA_QUEUE_RUNTIME_DETACHED;
    lock_status = acquire_lock();
    if (!lock_status.ok()) return lock_status;
    runtime_state = state;
    lock.put(1);
    return make_runtime_status(RDMA_SC_OK, "");
  endfunction

  // 功能：query_route_epoch 返回 set_route_epoch 或 copy_ring_state 锁存的
  //   route/reset epoch authority 快照。
  // 输入/输出及副作用：四个 output 先清零；成功时写入 route/epoch 及其有效位，
  //   不改变 runtime authority。
  // 失败/边界：未配置、route/epoch 无效或锁忙时返回非成功状态，四个 output
  //   保持安全默认值；configure 本身不建立 authority。
  function rdma_status query_route_epoch(
    output rdma_route_key_t route_snapshot,
    output bit route_snapshot_valid,
    output rdma_reset_epoch_t epoch_snapshot,
    output bit epoch_snapshot_valid
  );
    rdma_status lock_status;
    route_snapshot = '0;
    route_snapshot_valid = 1'b0;
    epoch_snapshot = '0;
    epoch_snapshot_valid = 1'b0;
    lock_status = acquire_lock();
    if (!lock_status.ok()) return lock_status;
    if (depth == 0 || !route_valid || !epoch_valid) begin
      lock.put(1);
      return make_runtime_status(RDMA_SC_INVALID_STATE,
                                 "route or reset epoch is unavailable");
    end
    route_snapshot = route;
    route_snapshot_valid = 1'b1;
    epoch_snapshot = reset_epoch;
    epoch_snapshot_valid = 1'b1;
    lock.put(1);
    return make_runtime_status(RDMA_SC_OK, "");
  endfunction

  // 功能：reservation_matches 判断输入 cursor 是否与当前 device reservation 完全相等。
  // 输入/输出及副作用：cursor（输入）；仅读取 reservation 与 cursor，不修改 runtime。
  // 失败/边界：无有效 reservation、输入为空或 runtime 非 device ring 时返回 0。
  function bit reservation_matches(rdma_queue_cursor_snapshot cursor);
    if (cursor == null || !device_reservation_valid || device_reservation == null)
      return 1'b0;
    return cursor_equal(cursor.index, cursor.wrap,
                        device_reservation.index, device_reservation.wrap);
  endfunction

  // 功能：mark_pending_device_write_attempted 标记 device-producer pending 已进入
  //   write backend，并保留此前已经取得的 MMIO evidence；设备 producer 不发送
  //   consumer doorbell，因此 write-attempt 不能被错误编码成 AMBIGUOUS。
  // 输入/输出及副作用：无显式输入；在 runtime lock 内置位
  //   pending_operation_state.device_write_attempted，并用当前 evidence 归一化兼容投影，
  //   不推进 producer cursor/used，也不清除 reservation。
  // 失败/边界：无 recovery pending、pending 不是 device producer、runtime 不在
  //   RECOVERY_REQUIRED，或已有不适用于 device producer 的 SUCCESS/AMBIGUOUS
  //   evidence 时返回错误；投影失败时恢复原 bit，避免发布半成品阶段。
  function rdma_status mark_pending_device_write_attempted();
    rdma_status lock_status;
    rdma_status project_status;
    rdma_queue_mmio_evidence_e prior_evidence;
    bit prior_attempted;

    lock_status = acquire_lock();
    if (!lock_status.ok()) return lock_status;
    if (pending_operation_state == null || !pending_operation_state.device_producer) begin
      lock.put(1);
      return make_runtime_status(RDMA_SC_INVALID_STATE,
                                 "device pending is unavailable");
    end
    if (state != RDMA_QUEUE_RUNTIME_RECOVERY_REQUIRED) begin
      lock.put(1);
      return make_runtime_status(RDMA_SC_INVALID_STATE,
                                 "runtime is not in recovery");
    end

    // 中文设计：evidence enum 是唯一权威。device producer 只能携带 NONE、
    // NOT_APPLICABLE 或 NO_SUBMIT；SUCCESS/AMBIGUOUS 描述 consumer doorbell
    // 结果，本 write-backend marker 不能伪造这两种值。
    prior_evidence = pending_operation_state.mmio_evidence;
    if (!(prior_evidence inside {RDMA_QUEUE_MMIO_NONE,
                                 RDMA_QUEUE_MMIO_NOT_APPLICABLE,
                                 RDMA_QUEUE_MMIO_NO_SUBMIT})) begin
      lock.put(1);
      return make_runtime_status(RDMA_SC_INVALID_STATE,
                                 "device write evidence is not retryable");
    end
    prior_attempted = pending_operation_state.device_write_attempted;
    pending_operation_state.device_write_attempted = 1'b1;
    // 中文设计：重复投影同一 enum 仅用于同步 legacy 兼容位；它保留
    // NOT_APPLICABLE/NO_SUBMIT，并让 retry 仍可进入（mmio_maybe_submitted=0）。
    project_status = project_mmio_evidence_locked(prior_evidence);
    if (project_status == null || !project_status.ok()) begin
      pending_operation_state.device_write_attempted = prior_attempted;
      lock.put(1);
      return (project_status == null) ? make_runtime_status(
        RDMA_SC_RESOURCE_EXHAUSTED,"MMIO evidence projection failed") : project_status;
    end
    lock.put(1);
    return make_runtime_status(RDMA_SC_OK, "");
  endfunction

  // 功能：mark_pending_consumer_doorbell_succeeded 校验当前 enum 已经记录
  //   consumer doorbell 成功，并确认三个兼容位仍是 SUCCESS 的派生投影。
  // 输入/输出及副作用：无显式输入；只读取 pending 的 mmio_evidence、
  //   known_no_mmio、mmio_maybe_submitted 与 consumer_doorbell_succeeded，不写证据。
  // 失败/边界：无 consumer pending、enum 不是 SUCCESS 或兼容投影不一致时返回
  //   INVALID_STATE；该 marker 不能把 NONE/NO_SUBMIT/AMBIGUOUS 提升成 SUCCESS。
  function rdma_status mark_pending_consumer_doorbell_succeeded();
    rdma_status lock_status;

    lock_status = acquire_lock();
    if (!status_is_ok(lock_status)) return lock_status;
    if (pending_operation_state == null || state != RDMA_QUEUE_RUNTIME_RECOVERY_REQUIRED ||
        pending_operation_state.device_producer || pending_operation_state.producer ||
        !is_device_ring_kind(kind)) begin
      lock.put(1);
      return make_runtime_status(RDMA_SC_INVALID_STATE,
                                 "consumer doorbell evidence is unavailable");
    end
    if (pending_operation_state.mmio_evidence != RDMA_QUEUE_MMIO_SUCCESS ||
        pending_operation_state.known_no_mmio ||
        pending_operation_state.mmio_maybe_submitted ||
        !pending_operation_state.consumer_doorbell_succeeded) begin
      lock.put(1);
      return make_runtime_status(RDMA_SC_INVALID_STATE,
                                 "consumer doorbell success evidence is absent");
    end
    lock.put(1);
    return make_runtime_status(RDMA_SC_OK, "");
  endfunction

  // 功能：mark_pending_consumer_shadow_attempted_noalloc 在 CQ shadow write 进入
  //   外部 context adapter 前冻结“已尝试”阶段，保留真实 NO_SUBMIT MMIO 证据。
  // 输入/输出及副作用：status_slot 为调用方预分配的输出槽；成功只更新 pending
  //   的 attempted 位，不推进 CI/used、不写 MMIO，也不创建对象。
  // 失败/边界：非 RECOVERY_REQUIRED、非 CQ shadow pending、重复尝试、已发布、
  //   CI 已提交或 evidence 不是 NO_SUBMIT 时返回 0，并保持所有阶段位不变。
  function bit mark_pending_consumer_shadow_attempted_noalloc(
    rdma_status status_slot
  );
    if (status_slot == null) begin
      return 1'b0;
    end
    if (lock == null || !lock.try_get(1)) begin
      void'(set_runtime_status_noalloc(
        status_slot, RDMA_SC_RESOURCE_BUSY, "queue runtime is busy"));
      return 1'b0;
    end
    if (state != RDMA_QUEUE_RUNTIME_RECOVERY_REQUIRED ||
        pending_operation_state == null ||
        !consumer_shadow_phase_valid(pending_operation_state, 1'b0) ||
        pending_operation_state.consumer_shadow_attempted ||
        pending_operation_state.consumer_committed ||
        pending_operation_state.committed_consumer_cursor != null ||
        !consumer_recovery_invariant_locked(
          pending_operation_state, pending_operation_state.mmio_evidence,
          pending_operation_state.consumer_committed,
          pending_operation_state.committed_consumer_cursor)) begin
      lock.put(1);
      void'(set_runtime_status_noalloc(
        status_slot, RDMA_SC_INVALID_STATE,
        "CQ shadow write attempt evidence is invalid"));
      return 1'b0;
    end
    pending_operation_state.consumer_shadow_attempted = 1'b1;
    pending_operation_state.mmio_evidence = RDMA_QUEUE_MMIO_NO_SUBMIT;
    pending_operation_state.known_no_mmio = 1'b1;
    pending_operation_state.mmio_maybe_submitted = 1'b0;
    pending_operation_state.consumer_doorbell_succeeded = 1'b0;
    lock.put(1);
    void'(set_runtime_status_noalloc(status_slot, RDMA_SC_OK, ""));
    return 1'b1;
  endfunction

  // 功能：mark_pending_consumer_shadow_published_noalloc 记录 context adapter 已
  //   成功写入冻结的 CQC CI/wrap payload，仍保持 MMIO evidence=NO_SUBMIT。
  // 输入/输出及副作用：status_slot 为预分配状态槽；成功只置 published marker，
  //   不推进 runtime CI/used、不发 consumer doorbell。
  // 失败/边界：shadow 未要求/未尝试、写后 pending 已提交、geometry/evidence 不符
  //   或 runtime identity 无效时返回 0；失败不伪造发布成功。
  function bit mark_pending_consumer_shadow_published_noalloc(
    rdma_status status_slot
  );
    if (status_slot == null) begin
      return 1'b0;
    end
    if (lock == null || !lock.try_get(1)) begin
      void'(set_runtime_status_noalloc(
        status_slot, RDMA_SC_RESOURCE_BUSY, "queue runtime is busy"));
      return 1'b0;
    end
    if (state != RDMA_QUEUE_RUNTIME_RECOVERY_REQUIRED ||
        pending_operation_state == null ||
        !consumer_shadow_phase_valid(pending_operation_state, 1'b0) ||
        !pending_operation_state.consumer_shadow_attempted ||
        pending_operation_state.consumer_shadow_published ||
        pending_operation_state.consumer_committed ||
        !pending_identity_matches_locked(pending_operation_state) ||
        !consumer_recovery_invariant_locked(
          pending_operation_state, pending_operation_state.mmio_evidence,
          pending_operation_state.consumer_committed,
          pending_operation_state.committed_consumer_cursor)) begin
      lock.put(1);
      void'(set_runtime_status_noalloc(
        status_slot, RDMA_SC_INVALID_STATE,
        "CQ shadow publication evidence is invalid"));
      return 1'b0;
    end
    pending_operation_state.consumer_shadow_published = 1'b1;
    lock.put(1);
    void'(set_runtime_status_noalloc(status_slot, RDMA_SC_OK, ""));
    return 1'b1;
  endfunction

  // 功能：mark_pending_consumer_committed 仅确认由外部路径已经完成的 consumer
  //   CI commit，并把 next_cursor 保存为 committed_consumer_cursor；它不代替提交动作。
  // 输入/输出及副作用：无显式输入；仅当 runtime CI 已等于 next_cursor 时发布
  //   consumer_committed/committed_consumer_cursor，不修改 CI 或 used。
  // 失败/边界：无 consumer pending、非 SUCCESS、CI 仍在旧 cursor、cursor 分配
  //   失败或共享 invariant 不成立时返回错误，禁止 marker 自行声称提交成功。
  function rdma_status mark_pending_consumer_committed();
    rdma_status lock_status;
    rdma_queue_cursor_snapshot staged_cursor;
    uvm_object raw_staged_cursor;

    lock_status = acquire_lock();
    if (!status_is_ok(lock_status)) return lock_status;
    if (pending_operation_state == null || state != RDMA_QUEUE_RUNTIME_RECOVERY_REQUIRED ||
        pending_operation_state.device_producer || pending_operation_state.producer ||
        !is_device_ring_kind(kind) ||
        !consumer_publication_committed_ready_locked(
          pending_operation_state)) begin
      lock.put(1);
      return make_runtime_status(RDMA_SC_INVALID_STATE,
                                 "consumer commit ordering is invalid");
    end
    if (pending_operation_state.cursor == null || pending_operation_state.next_cursor == null ||
        !pending_cursor_shape_valid(pending_operation_state)) begin
      lock.put(1);
      return make_runtime_status(RDMA_SC_INVALID_ARGUMENT,
                                 "consumer cursor evidence is incomplete");
    end

    if (pending_operation_state.committed_consumer_cursor != null &&
        !cursor_equal(pending_operation_state.committed_consumer_cursor.index,
                      pending_operation_state.committed_consumer_cursor.wrap,
                      pending_operation_state.next_cursor.index,
                      pending_operation_state.next_cursor.wrap)) begin
      lock.put(1);
      return make_runtime_status(RDMA_SC_INVALID_STATE,
                                 "committed consumer cursor is inconsistent");
    end
    if (pending_operation_state.committed_consumer_cursor == null) begin
      raw_staged_cursor = factory_create_object_nonfatal(
        rdma_queue_cursor_snapshot::get_type(), "committed_consumer_cursor");
      if (raw_staged_cursor == null ||
          !$cast(staged_cursor, raw_staged_cursor)) begin
        lock.put(1);
        return make_runtime_status(RDMA_SC_RESOURCE_EXHAUSTED,
                                   "committed cursor allocation failed");
      end
      staged_cursor.index = pending_operation_state.next_cursor.index;
      staged_cursor.wrap = pending_operation_state.next_cursor.wrap;
    end
    if (!consumer_recovery_invariant_locked(
          pending_operation_state, pending_operation_state.mmio_evidence, 1'b1,
          pending_operation_state.committed_consumer_cursor == null ?
            staged_cursor : pending_operation_state.committed_consumer_cursor)) begin
      lock.put(1);
      return make_runtime_status(RDMA_SC_INVALID_STATE,
                                 "runtime CI has not committed consumer next cursor");
    end
    if (pending_operation_state.committed_consumer_cursor == null)
      pending_operation_state.committed_consumer_cursor = staged_cursor;
    pending_operation_state.consumer_committed = 1'b1;
    recovery_commit_allowed = 1'b0;
    lock.put(1);
    return make_runtime_status(RDMA_SC_OK, "");
  endfunction

  // 功能：mark_pending_cq_consumer_committed 记录 CQ consumer CI 已完成的兼容别名阶段。
  // 输入/输出及副作用：无显式输入；仅在 consumer_committed 已置位时更新 cq_consumer_committed。
  // 失败/边界：无 pending 或 consumer_committed 为零时返回 INVALID_STATE，不改变阶段位。
  function rdma_status mark_pending_cq_consumer_committed();
    rdma_status lock_status;

    lock_status = acquire_lock();
    if (!status_is_ok(lock_status)) return lock_status;
    if (pending_operation_state == null || state != RDMA_QUEUE_RUNTIME_RECOVERY_REQUIRED ||
        pending_operation_state.device_producer ||
        pending_operation_state.kind != RDMA_QUEUE_RUNTIME_CQ ||
        !pending_operation_state.consumer_committed) begin
      lock.put(1);
      return make_runtime_status(RDMA_SC_INVALID_STATE,
                                 "CQ consumer commit ordering is invalid");
    end
    if (pending_operation_state.committed_consumer_cursor == null ||
        !consumer_recovery_invariant_locked(
          pending_operation_state, pending_operation_state.mmio_evidence,
          pending_operation_state.consumer_committed,
          pending_operation_state.committed_consumer_cursor) ||
        !cursor_equal(consumer_index, consumer_wrap,
                      pending_operation_state.committed_consumer_cursor.index,
                      pending_operation_state.committed_consumer_cursor.wrap)) begin
      lock.put(1);
      return make_runtime_status(
        RDMA_SC_INVALID_STATE,
        "runtime CI does not match committed CQ cursor");
    end
    pending_operation_state.cq_consumer_committed = 1'b1;
    lock.put(1);
    return make_runtime_status(RDMA_SC_OK, "");
  endfunction

  // 功能：mark_pending_completion_released 标记 CQ 对应 WQE 已释放，保证恢复路径幂等。
  // 输入/输出及副作用：无显式输入；更新 completion_released。
  // 失败/边界：无 pending、CI 未提交或目标不是有效 CQ completion 时返回 INVALID_STATE。
  function rdma_status mark_pending_completion_released();
    rdma_status lock_status;

    lock_status = acquire_lock();
    if (!status_is_ok(lock_status)) return lock_status;
    if (pending_operation_state == null || state != RDMA_QUEUE_RUNTIME_RECOVERY_REQUIRED ||
        pending_operation_state.kind != RDMA_QUEUE_RUNTIME_CQ ||
        !pending_operation_state.consumer_committed ||
        !pending_operation_state.completion_target_valid ||
        pending_operation_state.committed_consumer_cursor == null ||
        !consumer_recovery_invariant_locked(
          pending_operation_state, pending_operation_state.mmio_evidence,
          pending_operation_state.consumer_committed,
          pending_operation_state.committed_consumer_cursor) ||
        !cursor_equal(consumer_index, consumer_wrap,
                      pending_operation_state.committed_consumer_cursor.index,
                      pending_operation_state.committed_consumer_cursor.wrap)) begin
      lock.put(1);
      return make_runtime_status(RDMA_SC_INVALID_STATE,
                                 "completion release ordering is invalid");
    end
    pending_operation_state.completion_released = 1'b1;
    lock.put(1);
    return make_runtime_status(RDMA_SC_OK, "");
  endfunction

  // 功能：complete_recovery_retry 在 data engine 已完成 replay 的各外部阶段后，
  //   按 producer/consumer 方向验证最终证据并清除 pending、恢复 ACTIVE。
  // 输入/输出及副作用：无显式输入；成功清除 pending/reservation、commit/retry/
  //   release gate 并更新 state，PI/CI/used 必须已由对应 commit API 完成，本函数
  //   不重复推进。
  // 失败/边界：无 pending、identity stale、device PI 未到 next_cursor、host slot
  //   未 posted，或 consumer doorbell/CI/CQ release 阶段不全时返回错误并保留证据。
  function rdma_status complete_recovery_retry();
    rdma_status lock_status;
    rdma_queue_slot_ledger_entry slot;

    lock_status = acquire_lock();
    if (!status_is_ok(lock_status)) return lock_status;
    if (state != RDMA_QUEUE_RUNTIME_RECOVERY_REQUIRED ||
        pending_operation_state == null) begin
      lock.put(1);
      return make_runtime_status(RDMA_SC_INVALID_STATE,
                                 "queue runtime has no pending recovery");
    end
    if (!pending_identity_matches_locked(pending_operation_state)) begin
      lock.put(1);
      return make_runtime_status(RDMA_SC_STALE_GENERATION,
                                 "pending recovery identity is stale");
    end
    if (pending_operation_state.device_producer) begin
      // 中文设计：device CQ/CEQ/AEQ publish 不含 consumer-doorbell/WQE-release
      // 阶段；写入/读回和 producer commit 完成后，next PI 即是最终提交证明。
      if (pending_operation_state.producer || !is_device_ring_kind(kind) ||
          !pending_operation_state.device_write_attempted ||
          pending_operation_state.mmio_evidence inside {
            RDMA_QUEUE_MMIO_SUCCESS, RDMA_QUEUE_MMIO_AMBIGUOUS}) begin
        lock.put(1);
        return make_runtime_status(RDMA_SC_INVALID_STATE,
                                   "device recovery evidence is invalid");
      end
      if (!pending_cursor_shape_valid(pending_operation_state)) begin
        lock.put(1);
        return make_runtime_status(RDMA_SC_INVALID_ARGUMENT,
                                   "device recovery cursor evidence is invalid");
      end
      if (device_reservation_valid ||
          !cursor_equal(producer_index, producer_wrap,
                        pending_operation_state.next_cursor.index,
                        pending_operation_state.next_cursor.wrap)) begin
        lock.put(1);
        return make_runtime_status(RDMA_SC_INVALID_STATE,
                                   "device recovery producer commit is incomplete");
      end
    end else if (pending_operation_state.producer) begin
      if (!host_produced || is_device_ring_kind(kind) ||
          pending_operation_state.next_cursor == null ||
          pending_operation_state.mmio_evidence inside {
            RDMA_QUEUE_MMIO_NONE, RDMA_QUEUE_MMIO_AMBIGUOUS} ||
          !cursor_equal(producer_index, producer_wrap,
                        pending_operation_state.next_cursor.index,
                        pending_operation_state.next_cursor.wrap) ||
          slots.size() < depth || pending_operation_state.cursor == null) begin
        lock.put(1);
        return make_runtime_status(RDMA_SC_INVALID_STATE,
                                   "host producer recovery stages are incomplete");
      end
      slot = slots[pending_operation_state.cursor.index];
      if (slot == null || !slot.posted || slot.consumed ||
          slot.index != pending_operation_state.cursor.index ||
          slot.wrap != pending_operation_state.cursor.wrap) begin
        lock.put(1);
        return make_runtime_status(RDMA_SC_INVALID_STATE,
                                   "host producer recovery slot is not committed");
      end
    end else begin
      // 中文设计：consumer recovery 不拥有 device producer reservation；它必须
      // 有确定 doorbell SUCCESS、一次 CI commit，以及 CQ 有 target 时的 WQE release。
      if (host_produced || !is_device_ring_kind(kind) ||
          !consumer_publication_committed_ready_locked(
            pending_operation_state) ||
          !pending_operation_state.consumer_committed ||
          pending_operation_state.committed_consumer_cursor == null ||
          !consumer_recovery_invariant_locked(
            pending_operation_state, pending_operation_state.mmio_evidence,
            pending_operation_state.consumer_committed,
            pending_operation_state.committed_consumer_cursor) ||
          !cursor_equal(consumer_index, consumer_wrap,
                        pending_operation_state.committed_consumer_cursor.index,
                        pending_operation_state.committed_consumer_cursor.wrap)) begin
        lock.put(1);
        return make_runtime_status(RDMA_SC_INVALID_STATE,
                                   "consumer recovery stages are incomplete");
      end
      if (kind == RDMA_QUEUE_RUNTIME_CQ &&
          pending_operation_state.completion_target_valid &&
          !pending_operation_state.completion_released) begin
        lock.put(1);
        return make_runtime_status(RDMA_SC_INVALID_STATE,
                                   "CQ completion release is incomplete");
      end
    end
    pending_operation_state = null;
    device_reservation_valid = 1'b0;
    device_reservation = null;
    recovery_commit_allowed = 1'b0;
    consumer_release_gate_active = 1'b0;
    recovery_retry_confirmed = 1'b0;
    state = RDMA_QUEUE_RUNTIME_ACTIVE;
    lock.put(1);
    return make_runtime_status(RDMA_SC_OK, "");
  endfunction

  // 功能：project_mmio_evidence_locked 在已持锁时执行唯一 MMIO authority 的
  //   单调转换表，并从新 enum 原子派生全部兼容位。
  // 输入/输出及副作用：evidence（输入）是 backend 本次观测；成功时更新当前
  //   pending 的 enum/兼容位，需要授权的 NO_SUBMIT 转移会一次性消费
  //   recovery_retry_confirmed。
  // 失败/边界：非法 enum、方向不适用、降级、AMBIGUOUS 消解，或缺少 retry
  //   confirmation/device_write_attempted 时返回错误；失败保持 enum、兼容位和授权不变。
  protected function rdma_status project_mmio_evidence_locked(
    rdma_queue_mmio_evidence_e evidence
  );
    bit consume_confirmation;

    if (pending_operation_state == null || state != RDMA_QUEUE_RUNTIME_RECOVERY_REQUIRED)
      return make_runtime_status(RDMA_SC_INVALID_STATE,
                                 "queue runtime has no pending recovery");
    if (!(evidence inside {RDMA_QUEUE_MMIO_NONE, RDMA_QUEUE_MMIO_NOT_APPLICABLE,
                           RDMA_QUEUE_MMIO_NO_SUBMIT, RDMA_QUEUE_MMIO_SUCCESS,
                           RDMA_QUEUE_MMIO_AMBIGUOUS}))
      return make_runtime_status(RDMA_SC_INVALID_ARGUMENT,
                                 "MMIO evidence is invalid");
    if (!rdma_queue_mmio_transition_policy::decide(
          pending_operation_state.mmio_evidence, evidence,
          pending_operation_state.device_producer,
          pending_operation_state.device_write_attempted,
          recovery_retry_confirmed, consume_confirmation))
      return make_runtime_status(RDMA_SC_INVALID_STATE,
                                 "MMIO evidence transition is unauthorized");

    pending_operation_state.mmio_evidence = evidence;
    pending_operation_state.known_no_mmio =
      (evidence inside {RDMA_QUEUE_MMIO_NOT_APPLICABLE,
                        RDMA_QUEUE_MMIO_NO_SUBMIT});
    pending_operation_state.mmio_maybe_submitted = (evidence == RDMA_QUEUE_MMIO_AMBIGUOUS);
    pending_operation_state.consumer_doorbell_succeeded = (evidence == RDMA_QUEUE_MMIO_SUCCESS);
    if (consume_confirmation)
      recovery_retry_confirmed = 1'b0;
    return make_runtime_status(RDMA_SC_OK, "");
  endfunction

  // 功能：project_mmio_evidence 对外提供带锁的 MMIO evidence 投影入口。
  // 输入/输出及副作用：evidence（输入）；成功时更新当前 pending 的唯一 evidence authority 及兼容位。
  // 失败/边界：无 pending、runtime 非 recovery、非法枚举或方向不匹配返回非成功状态，且输出阶段保持原值。
  protected function rdma_status project_mmio_evidence(
    rdma_queue_mmio_evidence_e evidence
  );
    rdma_status lock_status;
    rdma_status status;

    lock_status = acquire_lock();
    if (!lock_status.ok()) return lock_status;

    status = project_mmio_evidence_locked(evidence);
    lock.put(1);
    return status;
  endfunction

  // 功能：abort_recovery 放弃当前 pending 并把 attachment 隔离为 DETACHED，
  //   防止不确定 transaction 继续对旧 queue 可见。
  // 输入/输出及副作用：无显式输入；成功清除 pending、device reservation、
  //   commit/retry/release gate 并更新 state；不回滚已经成功的 CI，也不释放外部 mapping。
  // 失败/边界：仅 RECOVERY_REQUIRED 且 pending 非空时允许；其它状态返回
  //   INVALID_STATE，失败不改变 recovery evidence。
  function rdma_status abort_recovery();
    rdma_status lock_status;
    lock_status = acquire_lock();
    if (!status_is_ok(lock_status)) return lock_status;
    if (state != RDMA_QUEUE_RUNTIME_RECOVERY_REQUIRED ||
        pending_operation_state == null) begin
      lock.put(1);
      return make_runtime_status(RDMA_SC_INVALID_STATE,
                                 "queue runtime has no pending recovery");
    end
    pending_operation_state = null;
    device_reservation_valid = 1'b0;
    device_reservation = null;
    recovery_commit_allowed = 1'b0;
    consumer_release_gate_active = 1'b0;
    recovery_retry_confirmed = 1'b0;
    state = RDMA_QUEUE_RUNTIME_DETACHED;
    lock.put(1);
    return make_runtime_status(RDMA_SC_OK, "");
  endfunction

  // 功能：enable_recovery_commit 在 MMIO 结果确定后打开一次 producer/consumer
  //   cursor commit gate；未改变的 no-submit 证据必须绑定本轮 retry confirmation。
  // 输入/输出及副作用：无显式输入；成功置 recovery_commit_allowed；当前证据为
  //   NO_SUBMIT/NOT_APPLICABLE 时同时消费 recovery_retry_confirmed，SUCCESS 不重复消费。
  // 失败/边界：无 pending、NONE/AMBIGUOUS，或 no-submit 证据没有 caller
  //   confirmation 时返回 RECOVERY_REQUIRED/INVALID_STATE，且 commit gate 保持关闭。
  function rdma_status enable_recovery_commit();
    rdma_status lock_status;
    lock_status = acquire_lock();
    if (!status_is_ok(lock_status)) return lock_status;
    if (state != RDMA_QUEUE_RUNTIME_RECOVERY_REQUIRED ||
        pending_operation_state == null) begin
      lock.put(1);
      return make_runtime_status(RDMA_SC_INVALID_STATE,
                                 "queue runtime has no pending recovery");
    end
    if (pending_operation_state.consumer_shadow_required &&
        pending_operation_state.consumer_shadow_published) begin
      if (!consumer_shadow_phase_valid(pending_operation_state, 1'b1)) begin
        lock.put(1);
        return make_runtime_status(RDMA_SC_INVALID_STATE,
                                   "CQ shadow publication is incomplete");
      end
    end
    else if (pending_operation_state.mmio_evidence inside {
          RDMA_QUEUE_MMIO_NONE, RDMA_QUEUE_MMIO_AMBIGUOUS}) begin
      lock.put(1);
      return make_runtime_status(RDMA_SC_RECOVERY_REQUIRED,
                                 "recovery commit lacks definitive MMIO evidence");
    end
    if (!(pending_operation_state.consumer_shadow_required &&
          pending_operation_state.consumer_shadow_published) &&
        pending_operation_state.mmio_evidence inside {
          RDMA_QUEUE_MMIO_NO_SUBMIT,
          RDMA_QUEUE_MMIO_NOT_APPLICABLE}) begin
      if (!recovery_retry_confirmed) begin
        lock.put(1);
        return make_runtime_status(RDMA_SC_INVALID_STATE,
                                   "recovery commit lacks retry confirmation");
      end
      recovery_retry_confirmed = 1'b0;
    end
    recovery_commit_allowed = 1'b1;
    lock.put(1);
    return make_runtime_status(RDMA_SC_OK, "");
  endfunction

  // 功能：enable_recovery_commit_noalloc 使用 caller 预建 status 打开一次 consumer
  //   CI commit gate，使 scheduler/continuation barrier 后无需创建返回对象。
  // 输入/输出及副作用：status_slot 为 caller-owned 输入；成功置
  //   recovery_commit_allowed，并在 NO_SUBMIT/NOT_APPLICABLE 时消费本轮 confirmation。
  // 失败/边界：slot/null lock、无 pending、NONE/AMBIGUOUS 或确定未提交却无
  //   confirmation 时返回 0；拒绝不打开 gate、不消费既有 recovery authority。
  function bit enable_recovery_commit_noalloc(rdma_status status_slot);
    if (status_slot == null) return 1'b0;
    if (lock == null || !lock.try_get(1)) begin
      void'(set_runtime_status_noalloc(
        status_slot, RDMA_SC_RESOURCE_BUSY, "queue runtime is busy"));
      return 1'b0;
    end
    if (state != RDMA_QUEUE_RUNTIME_RECOVERY_REQUIRED ||
        pending_operation_state == null) begin
      lock.put(1);
      void'(set_runtime_status_noalloc(
        status_slot, RDMA_SC_INVALID_STATE,
        "queue runtime has no pending recovery"));
      return 1'b0;
    end
    if (pending_operation_state.consumer_shadow_required &&
        pending_operation_state.consumer_shadow_published) begin
      if (!consumer_shadow_phase_valid(pending_operation_state, 1'b1)) begin
        lock.put(1);
        void'(set_runtime_status_noalloc(
          status_slot, RDMA_SC_INVALID_STATE,
          "CQ shadow publication is incomplete"));
        return 1'b0;
      end
    end
    else if (pending_operation_state.mmio_evidence inside {
          RDMA_QUEUE_MMIO_NONE, RDMA_QUEUE_MMIO_AMBIGUOUS}) begin
      lock.put(1);
      void'(set_runtime_status_noalloc(
        status_slot, RDMA_SC_RECOVERY_REQUIRED,
        "recovery commit lacks definitive MMIO evidence"));
      return 1'b0;
    end
    if (!(pending_operation_state.consumer_shadow_required &&
          pending_operation_state.consumer_shadow_published) &&
        pending_operation_state.mmio_evidence inside {
          RDMA_QUEUE_MMIO_NO_SUBMIT,
          RDMA_QUEUE_MMIO_NOT_APPLICABLE}) begin
      if (!recovery_retry_confirmed) begin
        lock.put(1);
        void'(set_runtime_status_noalloc(
          status_slot, RDMA_SC_INVALID_STATE,
          "recovery commit lacks retry confirmation"));
        return 1'b0;
      end
      recovery_retry_confirmed = 1'b0;
    end
    recovery_commit_allowed = 1'b1;
    lock.put(1);
    void'(set_runtime_status_noalloc(status_slot, RDMA_SC_OK, ""));
    return 1'b1;
  endfunction

  // 功能：snapshot_pending 为 legacy caller 返回当前 pending transaction 的
  //   完整 detached 值副本，避免暴露 runtime 内部可变 evidence。
  // 输入/输出及副作用：snapshot（输出）先置 null；成功时深复制 handle、cursor、
  //   image、request、status、route/epoch 与所有阶段位，不修改原 pending。
  // 失败/边界：非 RECOVERY_REQUIRED、无 pending 或任一 non-fatal factory 复制失败
  //   时返回错误且 snapshot 保持 null，runtime 原 evidence 不变。
  function rdma_status snapshot_pending(
    output rdma_queue_pending_operation snapshot
  );
    rdma_status lock_status;
    rdma_status copy_status;
    snapshot = null;
    lock_status = acquire_lock();
    if (!status_is_ok(lock_status)) return lock_status;
    if (state != RDMA_QUEUE_RUNTIME_RECOVERY_REQUIRED ||
        pending_operation_state == null) begin
      lock.put(1);
      return make_runtime_status(RDMA_SC_INVALID_STATE,
                                 "queue runtime has no pending recovery");
    end
    copy_status = clone_pending_value(pending_operation_state, snapshot);
    if (!status_is_ok(copy_status)) begin
      lock.put(1);
      return (copy_status == null) ?
        make_runtime_status(RDMA_SC_RESOURCE_EXHAUSTED,
                          "pending recovery snapshot clone failed") : copy_status;
    end
    lock.put(1);
    return make_runtime_status(RDMA_SC_OK, "");
  endfunction

  // 功能：recover 处理 retry/abort 控制动作；RETRY_PENDING 为 no-submit 重放或
  //   SUCCESS 后仅本地续做记录一次 caller confirmation，实际阶段由 data engine 完成。
  // 输入/输出及副作用：action、caller_confirmed_no_submit（输入）；授权成功仅置
  //   recovery_retry_confirmed 并保持 RECOVERY_REQUIRED/pending，abort 清除 pending
  //   及 commit/retry/release gate 等全部恢复状态。
  // 失败/边界：无 pending、NONE/AMBIGUOUS、未确认或 action 非法时返回对应错误；
  //   AMBIGUOUS 始终不可 retry，SUCCESS 授权也不得重新提交 MMIO。
  function rdma_status recover(rdma_queue_recovery_action_e action, bit caller_confirmed_no_submit=1'b0);
    rdma_status lock_status;
    rdma_queue_mmio_evidence_e evidence;

    lock_status = acquire_lock();
    if (!status_is_ok(lock_status)) return lock_status;
    if (state != RDMA_QUEUE_RUNTIME_RECOVERY_REQUIRED ||
        pending_operation_state == null) begin
      lock.put(1);
      return make_runtime_status(RDMA_SC_INVALID_STATE,
                                 "queue runtime has no pending recovery");
    end
    if (action == RDMA_QUEUE_RECOVERY_RETRY_PENDING) begin
      evidence = pending_operation_state.mmio_evidence;
      if (evidence == RDMA_QUEUE_MMIO_AMBIGUOUS) begin
        lock.put(1);
        return make_runtime_status(RDMA_SC_RECOVERY_REQUIRED,
                                   "pending MMIO outcome is ambiguous");
      end
      if (!(evidence inside {RDMA_QUEUE_MMIO_NOT_APPLICABLE,
                             RDMA_QUEUE_MMIO_NO_SUBMIT,
                             RDMA_QUEUE_MMIO_SUCCESS})) begin
        lock.put(1);
        return make_runtime_status(RDMA_SC_INVALID_STATE,
                                   "pending recovery evidence is not retryable");
      end
      if (!caller_confirmed_no_submit) begin
        lock.put(1);
        return make_runtime_status(RDMA_SC_INVALID_ARGUMENT,
                                   "retry requires caller confirmation");
      end
      // 中文设计：caller confirmation 只记录本轮允许 retry；SUCCESS 表示 MMIO
      // 已完成，data engine 只能续做 release/CI/complete，不能再提交 doorbell。
      recovery_retry_confirmed = 1'b1;
      lock.put(1);
      return make_runtime_status(RDMA_SC_OK, "");
    end
    if (action == RDMA_QUEUE_RECOVERY_ABORT_AND_DETACH) begin
      pending_operation_state = null;
      device_reservation_valid = 1'b0;
      device_reservation = null;
      recovery_commit_allowed = 1'b0;
      consumer_release_gate_active = 1'b0;
      recovery_retry_confirmed = 1'b0;
      state = RDMA_QUEUE_RUNTIME_DETACHED;
      lock.put(1);
      return make_runtime_status(RDMA_SC_OK, "");
    end
    lock.put(1);
    return make_runtime_status(RDMA_SC_INVALID_ARGUMENT,
                               "recovery action is invalid");
  endfunction

  // 功能：copy_recovery_failure_status_locked 把 backend 返回的真实错误字段复制到
  //   当前 pending 的 caller-owned failure_status，供 status/noalloc 两条 recovery
  //   入口共享，避免一条路径漏复制 authority 字段。
  // 输入/输出及副作用：actual_failure（输入）与 pending_operation_state.failure_status
  //   为当前锁保护的对象；成功时按值覆盖 category、code、hardware、source、identity、
  //   resource、command、wr、severity、retryable 和 message，不创建新 status。
  // 失败/边界：actual_failure、pending 或 failure_status 为空，或 actual_failure 为
  //   OK 时返回 0 且不写入；调用方必须先完成 evidence/成功码校验。
  protected function bit copy_recovery_failure_status_locked(
      rdma_status actual_failure
  );
    if (actual_failure == null || pending_operation_state == null ||
        pending_operation_state.failure_status == null || actual_failure.ok())
      return 1'b0;
    pending_operation_state.failure_status.category = actual_failure.category;
    pending_operation_state.failure_status.code = actual_failure.code;
    pending_operation_state.failure_status.hardware_code = actual_failure.hardware_code;
    pending_operation_state.failure_status.hardware_code_valid =
      actual_failure.hardware_code_valid;
    pending_operation_state.failure_status.source_engine = actual_failure.source_engine;
    pending_operation_state.failure_status.function_uid = actual_failure.function_uid;
    pending_operation_state.failure_status.generation = actual_failure.generation;
    pending_operation_state.failure_status.resource_id = actual_failure.resource_id;
    pending_operation_state.failure_status.command_id = actual_failure.command_id;
    pending_operation_state.failure_status.wr_id = actual_failure.wr_id;
    pending_operation_state.failure_status.severity = actual_failure.severity;
    pending_operation_state.failure_status.retryable = actual_failure.retryable;
    pending_operation_state.failure_status.message = actual_failure.message;
    return 1'b1;
  endfunction

  // 功能：record_recovery_failure 原样记录 backend MMIO enum，并可把本次真实
  //   doorbell/commit/release 错误写入 admission 前预分配的 failure_status。
  // 输入/输出及副作用：evidence 与可选 actual_failure 为输入；成功时在同一锁内
  //   更新 enum/兼容投影、诊断字段并关闭旧 commit/retry gate，不推进任何游标。
  // 失败/边界：无 pending、非法/降级 enum、actual_failure 为成功或目标 status
  //   缺失时原子拒绝；actual_failure=null 表示只更新阶段，不以 sentinel 覆盖真错误。
  function rdma_status record_recovery_failure(
    rdma_queue_mmio_evidence_e evidence,
    rdma_status actual_failure = null
  );
    rdma_status lock_status;
    rdma_status project_status;
    lock_status = acquire_lock();
    if (!status_is_ok(lock_status)) return lock_status;
    if (pending_operation_state == null || state != RDMA_QUEUE_RUNTIME_RECOVERY_REQUIRED) begin
      lock.put(1);
      return make_runtime_status(RDMA_SC_INVALID_STATE,
                                 "queue runtime has no pending recovery");
    end
    if (!(evidence inside {RDMA_QUEUE_MMIO_NONE, RDMA_QUEUE_MMIO_NOT_APPLICABLE,
                           RDMA_QUEUE_MMIO_NO_SUBMIT, RDMA_QUEUE_MMIO_SUCCESS,
                           RDMA_QUEUE_MMIO_AMBIGUOUS})) begin
      lock.put(1);
      return make_runtime_status(RDMA_SC_INVALID_ARGUMENT,
                                 "MMIO evidence is invalid");
    end
    if (actual_failure != null &&
        (actual_failure.ok() || pending_operation_state.failure_status == null)) begin
      lock.put(1);
      return make_runtime_status(RDMA_SC_INVALID_ARGUMENT,
                                 "recovery failure status is invalid");
    end
    project_status = project_mmio_evidence_locked(evidence);
    if (status_is_ok(project_status)) begin
      if (actual_failure != null)
        void'(copy_recovery_failure_status_locked(actual_failure));
      recovery_retry_confirmed = 1'b0;
      recovery_commit_allowed = 1'b0;
    end
    lock.put(1);
    return project_status != null ? project_status :
      make_runtime_status(RDMA_SC_RESOURCE_EXHAUSTED,
                          "MMIO evidence projection failed");
  endfunction

  // 功能：record_recovery_failure_noalloc 在 consumer scheduler 返回后，把本次
  //   MMIO enum 与真实阶段错误原子写入既有 pending，不创建 status 或 evidence。
  // 输入/输出及副作用：evidence/actual_failure 为输入，status_slot 是 caller 预建
  //   的错误槽；成功单调更新 enum/兼容位并按值覆盖 pending.failure_status。
  // 失败/边界：slot/null lock、无 pending、非法/降级转换、成功 actual_failure 或
  //   缺诊断目标时返回 0；拒绝不会消费 confirmation、改变 enum、gate 或诊断。
  function bit record_recovery_failure_noalloc(
    rdma_queue_mmio_evidence_e evidence,
    rdma_status actual_failure,
    rdma_status status_slot
  );
    bit consume_confirmation;

    if (status_slot == null) return 1'b0;
    if (lock == null || !lock.try_get(1)) begin
      void'(set_runtime_status_noalloc(
        status_slot, RDMA_SC_RESOURCE_BUSY, "queue runtime is busy"));
      return 1'b0;
    end
    if (state != RDMA_QUEUE_RUNTIME_RECOVERY_REQUIRED ||
        pending_operation_state == null) begin
      lock.put(1);
      void'(set_runtime_status_noalloc(
        status_slot, RDMA_SC_INVALID_STATE,
        "queue runtime has no pending recovery"));
      return 1'b0;
    end
    if (!(evidence inside {RDMA_QUEUE_MMIO_NONE,
                           RDMA_QUEUE_MMIO_NOT_APPLICABLE,
                           RDMA_QUEUE_MMIO_NO_SUBMIT,
                           RDMA_QUEUE_MMIO_SUCCESS,
                           RDMA_QUEUE_MMIO_AMBIGUOUS})) begin
      lock.put(1);
      void'(set_runtime_status_noalloc(
        status_slot, RDMA_SC_INVALID_ARGUMENT,
        "MMIO evidence is invalid"));
      return 1'b0;
    end
    if (actual_failure != null &&
        (actual_failure.ok() || pending_operation_state.failure_status == null)) begin
      lock.put(1);
      void'(set_runtime_status_noalloc(
        status_slot, RDMA_SC_INVALID_ARGUMENT,
        "recovery failure status is invalid"));
      return 1'b0;
    end

    if (!rdma_queue_mmio_transition_policy::decide(
          pending_operation_state.mmio_evidence, evidence,
          pending_operation_state.device_producer,
          pending_operation_state.device_write_attempted,
          recovery_retry_confirmed, consume_confirmation)) begin
      lock.put(1);
      void'(set_runtime_status_noalloc(
        status_slot, RDMA_SC_INVALID_STATE,
        "MMIO evidence transition is unauthorized"));
      return 1'b0;
    end

    // 中文设计：转换、诊断目标和 caller confirmation 均已验证；以下更新作为
    // 一个锁内发布点完成，SUCCESS 同时产生唯一 doorbell-success 派生 marker。
    pending_operation_state.mmio_evidence = evidence;
    pending_operation_state.known_no_mmio =
      evidence inside {RDMA_QUEUE_MMIO_NOT_APPLICABLE,
                       RDMA_QUEUE_MMIO_NO_SUBMIT};
    pending_operation_state.mmio_maybe_submitted =
      (evidence == RDMA_QUEUE_MMIO_AMBIGUOUS);
    pending_operation_state.consumer_doorbell_succeeded =
      (evidence == RDMA_QUEUE_MMIO_SUCCESS);
    if (actual_failure != null)
      void'(copy_recovery_failure_status_locked(actual_failure));
    if (consume_confirmation)
      recovery_retry_confirmed = 1'b0;
    recovery_commit_allowed = 1'b0;
    lock.put(1);
    // 成功时保留 caller slot 当前内容；若 actual_failure 与 slot 是同一对象，
    // 调用方仍可原样返回真实阶段错误，而不是被辅助 API 的 OK 覆盖。
    return 1'b1;
  endfunction

  // 功能：complete_consumer_recovery_noalloc 在 consumer commit 和可选 CQ WQE
  //   release 均完成后，单调合并 release marker 并一次性恢复 ACTIVE。
  // 输入/输出及副作用：completion_released_now 表示本次外部 release 已成功，
  //   status_slot 由 caller 预建；成功清除 pending/reservation 及 commit/retry/
  //   release gate 并更新 state。
  // 失败/边界：slot/null lock、identity/CI/doorbell/commit marker 不完整、event 携带
  //   CQ release 或 CQ target 未释放时返回 0；拒绝保持 pending 和所有阶段位原样。
  function bit complete_consumer_recovery_noalloc(
    bit completion_released_now,
    rdma_status status_slot
  );
    bit release_complete;

    if (status_slot == null) return 1'b0;
    if (lock == null || !lock.try_get(1)) begin
      void'(set_runtime_status_noalloc(
        status_slot, RDMA_SC_RESOURCE_BUSY, "queue runtime is busy"));
      return 1'b0;
    end
    if (state != RDMA_QUEUE_RUNTIME_RECOVERY_REQUIRED ||
        pending_operation_state == null || host_produced ||
        !is_device_ring_kind(kind) || pending_operation_state.producer ||
        pending_operation_state.device_producer ||
        !pending_identity_matches_locked(pending_operation_state) ||
        pending_operation_state.kind != kind ||
        !consumer_publication_committed_ready_locked(
          pending_operation_state) ||
        !pending_operation_state.consumer_committed ||
        pending_operation_state.committed_consumer_cursor == null ||
        !consumer_recovery_invariant_locked(
          pending_operation_state, pending_operation_state.mmio_evidence,
          pending_operation_state.consumer_committed,
          pending_operation_state.committed_consumer_cursor) ||
        !cursor_equal(
          consumer_index, consumer_wrap,
          pending_operation_state.committed_consumer_cursor.index,
          pending_operation_state.committed_consumer_cursor.wrap)) begin
      lock.put(1);
      void'(set_runtime_status_noalloc(
        status_slot, RDMA_SC_INVALID_STATE,
        "consumer recovery stages are incomplete"));
      return 1'b0;
    end

    release_complete = pending_operation_state.completion_released ||
                       completion_released_now;
    if (kind == RDMA_QUEUE_RUNTIME_CQ) begin
      if (!pending_operation_state.cq_consumer_committed ||
          (pending_operation_state.completion_target_valid &&
           !release_complete)) begin
        lock.put(1);
        void'(set_runtime_status_noalloc(
          status_slot, RDMA_SC_INVALID_STATE,
          "CQ completion release is incomplete"));
        return 1'b0;
      end
    end
    else if (completion_released_now ||
             pending_operation_state.completion_target_valid ||
             pending_operation_state.completion_released) begin
      lock.put(1);
      void'(set_runtime_status_noalloc(
        status_slot, RDMA_SC_INVALID_STATE,
        "event recovery cannot publish a CQ release stage"));
      return 1'b0;
    end

    if (kind == RDMA_QUEUE_RUNTIME_CQ &&
        pending_operation_state.completion_target_valid && release_complete)
      pending_operation_state.completion_released = 1'b1;
    pending_operation_state = null;
    device_reservation_valid = 1'b0;
    device_reservation = null;
    recovery_commit_allowed = 1'b0;
    consumer_release_gate_active = 1'b0;
    recovery_retry_confirmed = 1'b0;
    state = RDMA_QUEUE_RUNTIME_ACTIVE;
    lock.put(1);
    void'(set_runtime_status_noalloc(status_slot, RDMA_SC_OK, ""));
    return 1'b1;
  endfunction
endclass
