// 目录/层次：src/core，为 RDMA queue-data engine 提供单队列运行时账本。
// 文件职责：统一管理 SQ/RQ/SRQ host-producer ledger 与 CQ/CEQ/AEQ device-producer 的
//   PI/CI、wrap、credit、reservation、quiesce/resize 和 recovery evidence。
// 主要依赖：rdma_queue_runtime_transaction_models.sv 的枚举/cursor/pending/slot 值模型，
//   rdma_types_pkg、rdma_model_pkg 与 UVM；不访问 Host-memory 或 PCIe。
// 所有权/生命周期：runtime 拥有 queue handle 快照、host slot ledger、device reservation 与
//   pending recovery 证据；route/epoch 为从 dpu_common 快照锁存的值；外部 backing、scheduler、
//   QP/Function 资源由各自 lifecycle owner 管理，runtime 不释放。
// 值快照：深拷贝与比较由无状态 projector 承担，保留原锁窗口、factory 重入与无分配提交边界。
// 恢复：授权与结束的规则在普通/noalloc 入口间共用；锁、status 交付与最终状态仍由入口决定。

// Queue value models are defined in rdma_queue_runtime_transaction_models.sv.
// This file keeps the mutable lock, ledger, attachment and publication owner.
// 设计说明：rdma_queue_runtime 是单 attachment 的并发状态 authority；所有
// reservation/pending/ledger/retry 变更都必须在同一把 lock 下完成。仅保留既有
// state/depth/PI/CI/used 标量兼容读取；identity、方向、polarity 与 route/epoch
// authority 必须保持 protected，并通过带锁 detached/value query 发布。
class rdma_queue_runtime extends uvm_object;
  `uvm_object_utils(rdma_queue_runtime)

  // 类型别名不构造 provider；值投影不持有 runtime，锁和账本仍只属于本对象。
  typedef rdma_queue_runtime_projector value_ops;
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

  // 功能：尝试获取 runtime 唯一 semaphore token，保护游标、occupancy、reservation 与 recovery 证据。
  // 输入/输出及副作用：成功消耗一个 token 并返回 OK，调用方须在所有分支 lock.put(1)。
  // 失败/边界：lock 未构造或已被占用返回 RESOURCE_BUSY，不读写业务字段。
  protected function rdma_status acquire_lock();
    if (lock == null || !lock.try_get(1))
      return value_ops::make_runtime_status(RDMA_SC_RESOURCE_BUSY,
                                 "queue runtime is busy");
    return value_ops::make_runtime_status(RDMA_SC_OK, "");
  endfunction

  // 功能：判断 queue kind 是否为 device 生产的 ring（CQ/CEQ/AEQ）。
  // 输入/输出及副作用：value 输入；纯函数。
  // 失败/边界：未知枚举返回 0。
  protected function bit is_device_ring_kind(rdma_queue_runtime_kind_e value);
    return value inside {RDMA_QUEUE_RUNTIME_CQ,
                         RDMA_QUEUE_RUNTIME_CEQ,
                         RDMA_QUEUE_RUNTIME_AEQ};
  endfunction

  // 功能：判断持锁时是否仍有未提交 pending、device reservation 或 used slot（冻结屏障的共用判据）。
  // 输入/输出及副作用：只读 pending_operation_state、device_reservation_valid、used；不改状态。
  // 失败/边界：调用方须已持锁；不决定错误码或状态迁移。
  protected function bit mutable_work_present_locked();
    return pending_operation_state != null || device_reservation_valid || used != 0;
  endfunction

  // 功能：由 depth、used、方向与 reservation 标志计算可用 producer 槽位。
  // 输入/输出及副作用：纯函数；device 生产且有 reservation 时扣除一个槽位。
  // 失败/边界：used 大于 depth 或 depth 为 0 返回 0（无 status 兼容读取的保守值）。
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

  // 功能：从给定 cursor 计算提交后的下一 cursor，处理 index 回卷与 wrap 翻转。
  // 输入/输出及副作用：result 先置 null，成功时发布独立快照；不改 source。
  // 失败/边界：source 为空、depth 为零或 index 越界返回 INVALID_ARGUMENT/INVALID_STATE，不发布半成品。
  protected function rdma_status derive_next_cursor(
    rdma_queue_cursor_snapshot source,
    output rdma_queue_cursor_snapshot result
  );
    rdma_queue_cursor_snapshot candidate;
    uvm_object raw_candidate;

    result = null;
    if (source == null)
      return value_ops::make_runtime_status(RDMA_SC_INVALID_ARGUMENT,
                                 "cursor source is null");
    if (depth == 0 || source.index >= depth)
      return value_ops::make_runtime_status(RDMA_SC_INVALID_STATE,
                                 "cursor source is outside depth");
    raw_candidate = value_ops::factory_create_object_nonfatal(
      rdma_queue_cursor_snapshot::get_type(), "derived_next_cursor");
    if (raw_candidate == null || !$cast(candidate, raw_candidate))
      return value_ops::make_runtime_status(RDMA_SC_RESOURCE_EXHAUSTED,
                                 "next cursor allocation failed");
    candidate.index = source.index;
    candidate.wrap = source.wrap;
    cursor_advance(candidate.index, candidate.wrap);
    result = candidate;
    return value_ops::make_runtime_status(RDMA_SC_OK, "");
  endfunction

  // 功能：持锁时比较 pending 与当前 runtime 的 queue/kind 身份，阻止跨 Function/object/generation 恢复。
  // 输入/输出及副作用：只读 pending、queue_h、kind；句柄比较委托 canonical handle_value_equal。
  // 失败/边界：任一句柄为空、kind 不同或句柄值不等返回 0；不做 freshness、route/epoch 校验。
  protected function bit pending_identity_matches_locked(
    rdma_queue_pending_operation pending
  );
    if (pending == null || pending.queue_h == null || queue_h == null)
      return 1'b0;
    return pending.kind == kind && value_ops::handle_value_equal(pending.queue_h, queue_h);
  endfunction

  // 功能：校验 pending 的 cursor/next_cursor 与 ring 几何、entry_offset 能组成可寻址的值形状。
  // 输入/输出及副作用：只读 pending 与 depth；next_cursor 是否恰为下一步由调用方判断。
  // 失败/边界：cursor 缺失、depth 为零、index 越界、entry_size 为零、index*entry_size 溢出或 offset 不等返回 0。
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

  // 功能：在几何有效的基础上，校验 next_cursor 恰为 cursor 的下一步。
  // 输入/输出及副作用：只读；返回 bit，供 recovery admission/commit 使用。
  // 失败/边界：几何无效或 next 不连续返回 0。
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

  // 功能：判断 pending 是否为冻结的 CQC shadow 发布（RC/UD 用 23 位 CQ CI，URC 用 15 位 packed cursor）。
  // 输入/输出及副作用：require_published 指定是否要求已发布；只读 kind、shadow 几何与 MMIO 证据。
  // 失败/边界：非 CQ、长度/偏移/宽度错误、误带 MMIO success/doorbell 标记或 attempted/published 阶段不符返回 0。
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

  // 功能：判断 consumer CI commit 前是否已有唯一的外部发布证明（MMIO doorbell 或 CQC shadow）。
  // 输入/输出及副作用：只读 evidence 与阶段标记；返回 bit。
  // 失败/边界：shadow 路径须已 attempted+published 且保持 NO_SUBMIT；MMIO 路径须 SUCCESS 且 doorbell 成功；
  //   AMBIGUOUS/NONE 拒绝。
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

  // 功能：持锁校验 device-consumer recovery 的 CI 与 committed 阶段，供 admission/merge/marker/commit/complete
  //   共用。
  // 输入/输出及副作用：pending、evidence、consumer_committed、committed_cursor 描述待发布状态；只读。
  // 失败/边界：非 device consumer、几何无效、未提交时 CI 不等于 cursor 或带 committed_cursor、已提交时发布证明不足或
  //   CI/committed/next 不全等返回 0。
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

  // 功能：构造 DETACHED、未配置的 runtime，并创建容量为 1 的互斥锁。
  // 输入/输出及副作用：name 为对象名；清零几何/authority/occupancy，置空 queue、reservation、pending。
  // 失败/边界：除 configure/query_state 外的入口应拒绝未配置 runtime；不接管外部资源。
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

  // 功能：校验 ring 方向、几何与初始游标，暂存句柄/账本后一次性发布 ATTACHED 配置。
  // 输入/输出及副作用：成功锁存游标、方向、polarity 与 detached queue 句柄，清空 recovery/release gate。
  // 失败/边界：重复配置、空句柄、深度非 2 的幂、游标越界或组合非法、方向与 kind 不符、分配失败返回错误并保留旧状态。
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
    if (!value_ops::status_is_ok(lock_status)) return lock_status;
    if (state != RDMA_QUEUE_RUNTIME_DETACHED) begin
      lock.put(1);
      return value_ops::make_runtime_status(RDMA_SC_INVALID_STATE,
                                 "queue runtime is already configured");
    end
    if (qh == null) begin
      lock.put(1);
      return value_ops::make_runtime_status(RDMA_SC_INVALID_ARGUMENT,
                                 "queue handle is null");
    end
    if (d == 0 || (d & (d - 1)) != 0) begin
      lock.put(1);
      return value_ops::make_runtime_status(RDMA_SC_INVALID_ARGUMENT,
                                 "queue depth is not a power of two");
    end
    if (pi >= d || ci >= d) begin
      lock.put(1);
      return value_ops::make_runtime_status(RDMA_SC_INVALID_ARGUMENT,
                                 "queue cursor is outside depth");
    end
    if (!(k inside {RDMA_QUEUE_RUNTIME_SQ, RDMA_QUEUE_RUNTIME_RQ,
                    RDMA_QUEUE_RUNTIME_SRQ, RDMA_QUEUE_RUNTIME_CQ,
                    RDMA_QUEUE_RUNTIME_CEQ, RDMA_QUEUE_RUNTIME_AEQ})) begin
      lock.put(1);
      return value_ops::make_runtime_status(RDMA_SC_INVALID_ARGUMENT,
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
      return value_ops::make_runtime_status(RDMA_SC_INVALID_ARGUMENT,
                                 "queue handle kind does not match runtime kind");
    end
    if (host_produced_cfg != expected_host_direction) begin
      lock.put(1);
      return value_ops::make_runtime_status(RDMA_SC_INVALID_ARGUMENT,
                                 "producer direction does not match queue kind");
    end
    // 设计说明：host ring 的 WQE occupancy 由 slots ledger 唯一表示，而 configure
    // 只会建立空 ledger；因此非空 PI/CI 距离不能在这里被静默解释为零 used。
    // resize 的冻结 ledger 由 copy_ring_state 导入，不经过这一空状态入口。
    if (!device_kind && (pi != ci || pw != cw)) begin
      lock.put(1);
      return value_ops::make_runtime_status(
        RDMA_SC_INVALID_ARGUMENT,
        "host ring cursors require an empty configure ledger");
    end
    if (device_kind) begin
      if (pw == cw) begin
        if (pi < ci) begin
          lock.put(1);
          return value_ops::make_runtime_status(RDMA_SC_INVALID_ARGUMENT,
                                     "same-wrap cursors are reversed");
        end
        staged_used = pi - ci;
      end else if (pi == ci) staged_used = d;
      else staged_used = d - ci + pi;
      if (staged_used > d) begin
        lock.put(1);
        return value_ops::make_runtime_status(RDMA_SC_INVALID_ARGUMENT,
                                   "initial occupancy exceeds depth");
      end
    end else staged_used = 0;
    // 中文设计：lifecycle resource 仍是身份权威，但 runtime 必须保存独立值快照；
    // 调用方后续修改传给 configure 的 handle，不能绕过这里锁存的 generation fence。
    copy_status = value_ops::clone_handle_value_nonfatal(qh, queue_snapshot);
    if (!value_ops::status_is_ok(copy_status) || queue_snapshot == null) begin
      lock.put(1);
      return (copy_status != null && !copy_status.ok()) ? copy_status :
        value_ops::make_runtime_status(RDMA_SC_RESOURCE_EXHAUSTED,
                            "queue runtime handle snapshot failed");
    end
    if (!device_kind) begin
      staged_slots = new[d];
      foreach (staged_slots[i]) begin
        raw_slot = value_ops::factory_create_object_nonfatal(
          rdma_queue_slot_ledger_entry::get_type(),
          $sformatf("slot_%0d", i));
        if (raw_slot == null || !$cast(staged_slots[i], raw_slot)) begin
          lock.put(1);
          return value_ops::make_runtime_status(RDMA_SC_RESOURCE_EXHAUSTED,
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
    return value_ops::make_runtime_status(RDMA_SC_OK, "");
  endfunction

  // 功能：返回 configure 锁存的 queue identity、kind、producer 方向与 initial polarity。
  // 输入/输出及副作用：输出先置安全默认值；成功时 queue 为 detached clone，其余为持锁值快照。
  // 失败/边界：未配置/已 DETACHED、句柄缺失、锁忙或 clone 失败返回非成功，输出保持默认，caller 不得当作 authority。
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
    if (!value_ops::status_is_ok(lock_status)) return lock_status;
    if (state == RDMA_QUEUE_RUNTIME_DETACHED || depth == 0 || queue_h == null) begin
      lock.put(1);
      return value_ops::make_runtime_status(RDMA_SC_INVALID_STATE,
                                 "runtime attachment config is unavailable");
    end
    copy_status = value_ops::clone_handle_value_nonfatal(queue_h, queue_snapshot);
    if (!value_ops::status_is_ok(copy_status) || queue_snapshot == null) begin
      queue_snapshot = null;
      lock.put(1);
      return copy_status != null ? copy_status : value_ops::make_runtime_status(
        RDMA_SC_RESOURCE_EXHAUSTED,
        "runtime attachment handle clone returned null status");
    end
    kind_snapshot = kind;
    host_produced_snapshot = host_produced;
    initial_polarity_snapshot = initial_polarity;
    lock.put(1);
    return value_ops::make_runtime_status(RDMA_SC_OK, "");
  endfunction

  // 功能：在 activate 前锁存完整 PCIe route 与 reset epoch authority。
  // 输入/输出及副作用：route_value/epoch_value 输入；仅 ATTACHED 状态写入值字段。
  // 失败/边界：未配置/非 ATTACHED、route 校验失败或 epoch 已锁存返回 INVALID_STATE/INVALID_ARGUMENT，旧值不变。
  function rdma_status set_route_epoch(
    rdma_route_key_t route_value,
    rdma_reset_epoch_t epoch_value
  );
    rdma_status lock_status;
    lock_status = acquire_lock();
    if (!value_ops::status_is_ok(lock_status)) return lock_status;
    if (state != RDMA_QUEUE_RUNTIME_ATTACHED || route_valid || epoch_valid) begin
      lock.put(1);
      return value_ops::make_runtime_status(RDMA_SC_INVALID_STATE,
                                 "route authority is not writable");
    end
    if (!rdma_route_key_valid(route_value)) begin
      lock.put(1);
      return value_ops::make_runtime_status(RDMA_SC_INVALID_ARGUMENT,
                                 "route authority is invalid");
    end
    route = route_value;
    reset_epoch = epoch_value;
    route_valid = 1'b1;
    epoch_valid = 1'b1;
    lock.put(1);
    return value_ops::make_runtime_status(RDMA_SC_OK, "");
  endfunction

  // 功能：把已 configure 的 runtime 从 ATTACHED 切为 ACTIVE。
  // 输入/输出及副作用：只更新 state；route/epoch 校验留给 publish、recovery 与 copy 边界。
  // 失败/边界：非 ATTACHED 或锁忙返回 INVALID_STATE/RESOURCE_BUSY；不伪造缺失的 route/epoch。
  function rdma_status activate();
    rdma_status lock_status;
    lock_status = acquire_lock();
    if (!value_ops::status_is_ok(lock_status)) return lock_status;
    if (state != RDMA_QUEUE_RUNTIME_ATTACHED) begin
      lock.put(1);
      return value_ops::make_runtime_status(RDMA_SC_INVALID_STATE,
                                 "queue runtime is not attached");
    end
    state = RDMA_QUEUE_RUNTIME_ACTIVE;
    lock.put(1);
    return value_ops::make_runtime_status(RDMA_SC_OK, "");
  endfunction

  // 功能：为 resize/删除建立冻结屏障，把无 outstanding work 的 ACTIVE 切为 QUIESCING。
  // 输入/输出及副作用：只更新 state，保留 identity、route/epoch、PI/CI，供 copy_ring_state 读取。
  // 失败/边界：非 ACTIVE 返回 INVALID_STATE；有 pending/reservation/used 返回 RESOURCE_BUSY；失败不改状态。
  virtual function rdma_status begin_quiesce();
    rdma_status lock_status;
    lock_status = acquire_lock();
    if (!value_ops::status_is_ok(lock_status)) return lock_status;
    if (state != RDMA_QUEUE_RUNTIME_ACTIVE) begin
      lock.put(1);
      return value_ops::make_runtime_status(RDMA_SC_INVALID_STATE,
                                 "queue runtime is not active");
    end
    if (mutable_work_present_locked()) begin
      lock.put(1);
      return value_ops::make_runtime_status(RDMA_SC_RESOURCE_BUSY,
                                 pending_operation_state != null ?
                                 "queue runtime has a pending operation" :
                                 (device_reservation_valid ?
                                  "queue runtime has a device reservation" :
                                  "queue runtime has outstanding slots"));
    end
    state = RDMA_QUEUE_RUNTIME_QUIESCING;
    lock.put(1);
    return value_ops::make_runtime_status(RDMA_SC_OK, "");
  endfunction

  // 功能：replacement 未提交时撤销 quiesce 屏障，恢复旧 runtime 为 ACTIVE。
  // 输入/输出及副作用：只改 state，不动游标/authority/backing。
  // 失败/边界：非 QUIESCING 返回 INVALID_STATE；冻结期出现 pending/reservation/used 返回 RESOURCE_BUSY。
  virtual function rdma_status restore_active();
    rdma_status lock_status;
    lock_status = acquire_lock();
    if (!value_ops::status_is_ok(lock_status)) return lock_status;
    if (state != RDMA_QUEUE_RUNTIME_QUIESCING) begin
      lock.put(1);
      return value_ops::make_runtime_status(RDMA_SC_INVALID_STATE,
                                 "queue runtime is not quiescing");
    end
    if (mutable_work_present_locked()) begin
      lock.put(1);
      return value_ops::make_runtime_status(RDMA_SC_RESOURCE_BUSY,
                                 "quiesced runtime has mutable work");
    end
    state = RDMA_QUEUE_RUNTIME_ACTIVE;
    lock.put(1);
    return value_ops::make_runtime_status(RDMA_SC_OK, "");
  endfunction

  // 功能：replacement 切换完成后把旧 runtime 从 QUIESCING 永久置为 DETACHED。
  // 输入/输出及副作用：只改 state，不释放 mapping/queue resource。
  // 失败/边界：非 QUIESCING 或有 pending/reservation/used 拒绝；重复 detach 返回 INVALID_STATE。
  virtual function rdma_status detach_quiesced();
    rdma_status lock_status;
    lock_status = acquire_lock();
    if (!value_ops::status_is_ok(lock_status)) return lock_status;
    if (state != RDMA_QUEUE_RUNTIME_QUIESCING) begin
      lock.put(1);
      return value_ops::make_runtime_status(RDMA_SC_INVALID_STATE,
                                 "queue runtime is not quiescing");
    end
    if (mutable_work_present_locked()) begin
      lock.put(1);
      return value_ops::make_runtime_status(RDMA_SC_RESOURCE_BUSY,
                                 "quiesced runtime has mutable work");
    end
    state = RDMA_QUEUE_RUNTIME_DETACHED;
    lock.put(1);
    return value_ops::make_runtime_status(RDMA_SC_OK, "");
  endfunction

  // 功能：resize 时冻结 source 的 identity、游标、polarity、route/epoch 与 host ledger，一次性发布到空 ATTACHED target。
  // 输入/输出及副作用：source 保持 QUIESCING；host ring 接管 staging 的 detached ledger，device ring 为零长度 ledger。
  // 失败/边界：source 未冻结/authority 不全、target 非空/identity 不同、任一侧有 retry confirmation、深度容不下 PI/CI、
  //   缩容丢弃未消费 slot 或分配失败时返回错误，target 不变。
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
      return value_ops::make_runtime_status(RDMA_SC_INVALID_ARGUMENT,
                                 "source runtime is null or identical");

    source_status = source.acquire_lock();
    if (!value_ops::status_is_ok(source_status))
      return (source_status != null) ? source_status :
        value_ops::make_runtime_status(RDMA_SC_RESOURCE_BUSY,
                            "source runtime lock status is unavailable");
    if (source.state != RDMA_QUEUE_RUNTIME_QUIESCING ||
        source.pending_operation_state != null || source.device_reservation_valid ||
        source.used != 0 || source.recovery_commit_allowed ||
        source.recovery_retry_confirmed) begin
      source.lock.put(1);
      return value_ops::make_runtime_status(RDMA_SC_RESOURCE_BUSY,
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
      return value_ops::make_runtime_status(RDMA_SC_INVALID_STATE,
                                 "source runtime is unconfigured");
    end
    if (source_pi >= source_depth || source_ci >= source_depth) begin
      source.lock.put(1);
      return value_ops::make_runtime_status(RDMA_SC_INVALID_ARGUMENT,
                                 "source cursor is outside depth");
    end
    if (source_used != 0) begin
      source.lock.put(1);
      return value_ops::make_runtime_status(RDMA_SC_RESOURCE_BUSY,
                                 "source runtime has outstanding slots");
    end
    if (!source_route_valid || !source_epoch_valid ||
        !rdma_route_key_valid(source_route)) begin
      source.lock.put(1);
      return value_ops::make_runtime_status(RDMA_SC_INVALID_STATE,
                                 "source route and reset epoch are unavailable");
    end
    if (source_host_produced) begin
      if (source.slots.size() != source_depth) begin
        source.lock.put(1);
        return value_ops::make_runtime_status(RDMA_SC_INVALID_STATE,
                                   "source runtime has no host ledger");
      end
      // 中文设计：先按 source depth 完整复制 ledger，不能在 source lock 下读取
      // 尚未持锁的 target depth；缩容筛选和扩容空 slot 分配延后到 target lock，
      // 但仍在任何 target 字段写入之前完成。
      staged_slots = new[source_depth];
      foreach (staged_slots[i]) begin
        raw_slot = value_ops::factory_create_object_nonfatal(
          rdma_queue_slot_ledger_entry::get_type(),
          $sformatf("staged_slot_%0d", i));
        if (raw_slot == null || !$cast(staged_slots[i], raw_slot)) begin
          source.lock.put(1);
          return value_ops::make_runtime_status(RDMA_SC_RESOURCE_EXHAUSTED,
                                     "slot staging allocation failed");
        end
      end
      for (i = 0; i < source_depth; i++) begin
        if (source.slots[i] == null) begin
          source.lock.put(1);
          return value_ops::make_runtime_status(RDMA_SC_INVALID_STATE,
                                     "source runtime has a null slot");
        end
        staged_slot = staged_slots[i];
        staged_slot.posted = source.slots[i].posted;
        staged_slot.consumed = source.slots[i].consumed;
        staged_slot.signaled = source.slots[i].signaled;
        staged_slot.wr_id = source.slots[i].wr_id;
        staged_slot.index = source.slots[i].index;
        staged_slot.wrap = source.slots[i].wrap;
        copy_status = value_ops::clone_request_value_nonfatal(
          source.slots[i].request_snapshot, staged_slot.request_snapshot);
        if (!value_ops::status_is_ok(copy_status)) begin
          source.lock.put(1);
          return (copy_status != null) ? copy_status :
            value_ops::make_runtime_status(RDMA_SC_RESOURCE_EXHAUSTED,
                                "slot request clone failed");
        end
        copy_status = value_ops::clone_image_value_nonfatal(
          source.slots[i].image, staged_slot.image);
        if (!value_ops::status_is_ok(copy_status)) begin
          source.lock.put(1);
          return (copy_status != null) ? copy_status :
            value_ops::make_runtime_status(RDMA_SC_RESOURCE_EXHAUSTED,
                                "slot image clone failed");
        end
        copy_status = value_ops::clone_status_value_nonfatal(
          source.slots[i].completion_status, staged_slot.completion_status);
        if (!value_ops::status_is_ok(copy_status)) begin
          source.lock.put(1);
          return (copy_status != null) ? copy_status :
            value_ops::make_runtime_status(RDMA_SC_RESOURCE_EXHAUSTED,
                                "slot status clone failed");
        end
      end
    end
    else
      staged_slots = new[0];
    source.lock.put(1);

    target_status = acquire_lock();
    if (!value_ops::status_is_ok(target_status))
      return (target_status != null) ? target_status :
        value_ops::make_runtime_status(RDMA_SC_RESOURCE_BUSY,
                            "target runtime lock status is unavailable");
    if (state != RDMA_QUEUE_RUNTIME_ATTACHED || pending_operation_state != null ||
        device_reservation_valid || used != 0 || recovery_commit_allowed ||
        recovery_retry_confirmed ||
        kind != source_kind ||
        host_produced != source_host_produced || depth == 0 ||
        queue_h == null ||
        !value_ops::handle_value_matches_snapshot(queue_h, source_queue_kind,
                                       source_function_uid, source_object_id,
                                       source_generation)) begin
      lock.put(1);
      return value_ops::make_runtime_status(RDMA_SC_INVALID_STATE,
                                 "target runtime is not an empty compatible attachment");
    end
    if (source_pi >= depth || source_ci >= depth) begin
      lock.put(1);
      return value_ops::make_runtime_status(RDMA_SC_INVALID_ARGUMENT,
                                 "source cursor is outside target depth");
    end
    if (source_host_produced && slots.size() != depth) begin
      lock.put(1);
      return value_ops::make_runtime_status(RDMA_SC_INVALID_STATE,
                                 "target runtime has no host ledger");
    end
    if (!source_host_produced && slots.size() != 0) begin
      lock.put(1);
      return value_ops::make_runtime_status(RDMA_SC_INVALID_STATE,
                                 "device runtime unexpectedly owns host ledger");
    end
    if (route_valid != epoch_valid) begin
      lock.put(1);
      return value_ops::make_runtime_status(RDMA_SC_INVALID_STATE,
                                 "target route and reset epoch are half valid");
    end
    if (route_valid &&
        !value_ops::same_route_epoch_value(source_route, source_epoch,
                                route, reset_epoch)) begin
      lock.put(1);
      return value_ops::make_runtime_status(RDMA_SC_INVALID_ARGUMENT,
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
            return value_ops::make_runtime_status(
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
        raw_slot = value_ops::factory_create_object_nonfatal(
          rdma_queue_slot_ledger_entry::get_type(),
          $sformatf("resized_slot_%0d", i));
        if (raw_slot == null || !$cast(published_slots[i], raw_slot)) begin
          lock.put(1);
          return value_ops::make_runtime_status(RDMA_SC_RESOURCE_EXHAUSTED,
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
    return value_ops::make_runtime_status(RDMA_SC_OK, "");
  endfunction

  // 功能：持锁返回可再提交的 producer credit，并扣除未 commit 的 device reservation。
  // 输入/输出及副作用：value 先清零，成功写 depth-used（有 reservation 再减 1）；不改游标/ledger。
  // 失败/边界：depth 为 0、used>depth 或锁忙返回非成功，value 保持 0。
  function rdma_status query_available(output int unsigned value);
    rdma_status lock_status;
    value = 0;
    lock_status = acquire_lock();
    if (!lock_status.ok()) return lock_status;
    if (depth == 0) begin
      lock.put(1);
      return value_ops::make_runtime_status(RDMA_SC_INVALID_STATE,
                                 "runtime is unconfigured");
    end
    if (used > depth) begin
      lock.put(1);
      return value_ops::make_runtime_status(RDMA_SC_INVALID_STATE,
                                 "runtime occupancy exceeds depth");
    end
    value = available_slot_value(depth, used, host_produced,
                                device_reservation_valid);
    lock.put(1);
    return value_ops::make_runtime_status(RDMA_SC_OK, "");
  endfunction

  // 功能：兼容入口：返回当前 producer credit（预扣未提交 device reservation）。
  // 输入/输出及副作用：只读；无 status。
  // 失败/边界：used>depth 或未配置时保守返回 0；需区分损坏与 full 的调用方应用 query_available。
  function int unsigned available_slots();
    return available_slot_value(depth, used, host_produced,
                                device_reservation_valid);
  endfunction

  // 功能：返回当前 CI 的 detached cursor；device ring 仅在 used>0 时可观察。
  // 输入/输出及副作用：snapshot 先置 null；成功复制 CI/wrap，不推进 CI、不释放 credit。
  // 失败/边界：非 ACTIVE 返回 INVALID_STATE；device ring 为空返回 QUEUE_EMPTY；factory 失败返回 RESOURCE_EXHAUSTED。
  function rdma_status peek_consumer(output rdma_queue_cursor_snapshot snapshot);
    rdma_status lock_status;
    uvm_object raw_snapshot;

    snapshot = null;
    lock_status = acquire_lock();
    if (!lock_status.ok()) return lock_status;
    if (state != RDMA_QUEUE_RUNTIME_ACTIVE) begin
      lock.put(1);
      return value_ops::make_runtime_status(RDMA_SC_INVALID_STATE,
                                 "queue runtime is not active");
    end
    if (!host_produced && used == 0) begin
      lock.put(1);
      return value_ops::make_runtime_status(RDMA_SC_QUEUE_EMPTY,
                                 "device ring has no committed entries");
    end
    raw_snapshot = value_ops::factory_create_object_nonfatal(
      rdma_queue_cursor_snapshot::get_type(), "consumer_snapshot");
    if (raw_snapshot == null || !$cast(snapshot, raw_snapshot)) begin
      snapshot = null;
      lock.put(1);
      return value_ops::make_runtime_status(RDMA_SC_RESOURCE_EXHAUSTED,
                                 "consumer snapshot allocation failed");
    end
    snapshot.index = consumer_index;
    snapshot.wrap = consumer_wrap;
    lock.put(1);
    return value_ops::make_runtime_status(RDMA_SC_OK, "");
  endfunction

  // 功能：消费 CQ/CEQ/AEQ 当前 CI credit；recovery 路径在同一临界区推进 CI、递减 used 并发布 committed 标记。
  // 输入/输出及副作用：reservation 须匹配当前 CI 或 recovery cursor；普通成功推进 CI/used，恢复成功还关闭
  //   recovery_commit_allowed。
  // 失败/边界：host ring、空 ring、stale cursor、未授权 recovery、缺 MMIO SUCCESS/shadow 发布证据或 invariant 损坏返回错误，
  //   不部分推进。
  function rdma_status commit_consumer(rdma_queue_cursor_snapshot reservation);
    rdma_status lock_status;
    rdma_queue_cursor_snapshot committed_copy;
    bit recovery_path;
    bit ci_at_pending;
    bit ci_at_next;

    if (reservation == null)
      return value_ops::make_runtime_status(RDMA_SC_INVALID_ARGUMENT,
                                 "consumer reservation is null");
    lock_status = acquire_lock();
    if (!value_ops::status_is_ok(lock_status)) return lock_status;

    // 中文设计：只有 device-produced CQ/CEQ/AEQ 的 consumer credit 由本
    // runtime 直接维护；host SQ/RQ/SRQ 的完成通过 match_and_release 释放 ledger。
    if (host_produced || !is_device_ring_kind(kind)) begin
      lock.put(1);
      return value_ops::make_runtime_status(RDMA_SC_INVALID_STATE,
                                 "consumer commit is invalid for this ring");
    end
    if (depth == 0 || reservation.index >= depth) begin
      lock.put(1);
      return value_ops::make_runtime_status(RDMA_SC_INVALID_ARGUMENT,
                                 "consumer reservation is outside depth");
    end

    recovery_path = (state == RDMA_QUEUE_RUNTIME_RECOVERY_REQUIRED);
    if (!recovery_path) begin
      if (state != RDMA_QUEUE_RUNTIME_ACTIVE || pending_operation_state != null ||
          recovery_commit_allowed) begin
        lock.put(1);
        return value_ops::make_runtime_status(RDMA_SC_INVALID_STATE,
                                   "queue runtime is not active");
      end
      if (!cursor_equal(reservation.index, reservation.wrap,
                        consumer_index, consumer_wrap)) begin
        lock.put(1);
        return value_ops::make_runtime_status(RDMA_SC_INVALID_STATE,
                                   "consumer reservation is stale");
      end
      if (used == 0) begin
        lock.put(1);
        return value_ops::make_runtime_status(
          RDMA_SC_INVALID_STATE,
          "consumer commit has no reserved device entry");
      end
      if (used > depth) begin
        lock.put(1);
        return value_ops::make_runtime_status(RDMA_SC_INVALID_STATE,
                                   "device ring occupancy exceeds depth");
      end
      // 中文设计：credit 递减与 CI 推进必须在同一临界区发布，避免观察到
      // “CI 已前进但 occupancy 未释放”的中间状态。
      used--;
      cursor_advance(consumer_index, consumer_wrap);
      lock.put(1);
      return value_ops::make_runtime_status(RDMA_SC_OK, "");
    end

    if (!recovery_commit_allowed || pending_operation_state == null) begin
      lock.put(1);
      return value_ops::make_runtime_status(RDMA_SC_INVALID_STATE,
                                 "consumer recovery commit is not authorized");
    end
    if (pending_operation_state.device_producer || pending_operation_state.producer ||
        !pending_identity_matches_locked(pending_operation_state) ||
        pending_operation_state.kind != kind || pending_operation_state.cursor == null ||
        pending_operation_state.next_cursor == null ||
        !consumer_publication_committed_ready_locked(
          pending_operation_state)) begin
      lock.put(1);
      return value_ops::make_runtime_status(RDMA_SC_INVALID_STATE,
                                 "consumer recovery evidence is invalid");
    end
    if (!pending_cursor_shape_valid(pending_operation_state)) begin
      lock.put(1);
      return value_ops::make_runtime_status(RDMA_SC_INVALID_ARGUMENT,
                                 "consumer recovery cursor evidence is invalid");
    end
    if (!consumer_recovery_invariant_locked(
          pending_operation_state, pending_operation_state.mmio_evidence,
          pending_operation_state.consumer_committed,
          pending_operation_state.committed_consumer_cursor)) begin
      lock.put(1);
      return value_ops::make_runtime_status(RDMA_SC_INVALID_STATE,
                                 "consumer recovery phase invariant is invalid");
    end
    if (!cursor_equal(reservation.index, reservation.wrap,
                      pending_operation_state.cursor.index,
                      pending_operation_state.cursor.wrap)) begin
      lock.put(1);
      return value_ops::make_runtime_status(RDMA_SC_INVALID_STATE,
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
      return value_ops::make_runtime_status(RDMA_SC_INVALID_STATE,
                                 "runtime CI is outside consumer recovery transaction");
    end

    if (pending_operation_state.committed_consumer_cursor != null &&
        !cursor_equal(pending_operation_state.committed_consumer_cursor.index,
                      pending_operation_state.committed_consumer_cursor.wrap,
                      pending_operation_state.next_cursor.index,
                      pending_operation_state.next_cursor.wrap)) begin
      lock.put(1);
      return value_ops::make_runtime_status(RDMA_SC_INVALID_STATE,
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
        return value_ops::make_runtime_status(RDMA_SC_QUEUE_EMPTY,
                                   "device ring has no committed entries");
      end
      if (used > depth) begin
        lock.put(1);
        return value_ops::make_runtime_status(RDMA_SC_INVALID_STATE,
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
        return value_ops::make_runtime_status(RDMA_SC_INVALID_STATE,
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
      return value_ops::make_runtime_status(RDMA_SC_INVALID_STATE,
                                 "consumer recovery commit violates phase invariant");
    end

    if (pending_operation_state.committed_consumer_cursor == null) begin
      pending_operation_state.committed_consumer_cursor = committed_copy;
    end
    pending_operation_state.consumer_committed = 1'b1;
    recovery_commit_allowed = 1'b0;
    lock.put(1);
    return value_ops::make_runtime_status(RDMA_SC_OK, "");
  endfunction

  // 功能：consumer doorbell 确定成功后，以 admission 冻结的旧 cursor 原子提交 CI 并发布 commit marker（无分配）。
  // 输入/输出及副作用：status_slot 由 caller 预建；成功消费 recovery_commit_allowed、递减 used、推进 CI，发布
  //   committed_consumer_cursor，CQ 置 cq_consumer_committed，release gate 保持关闭。
  // 失败/边界：slot/lock 无效、未授权、非 consumer recovery、非 SUCCESS、stale cursor、occupancy 异常或阶段已提交返回 0；
  //   拒绝先于任何修改。
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
      void'(rdma_status::set_fields_noalloc(
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
      void'(rdma_status::set_fields_noalloc(status_slot, failure_code,
                                       failure_message));
      return 1'b0;
    end
    if (used == 0) begin
      lock.put(1);
      void'(rdma_status::set_fields_noalloc(
        status_slot, RDMA_SC_QUEUE_EMPTY,
        "device ring has no committed entries"));
      return 1'b0;
    end
    if (used > depth) begin
      lock.put(1);
      void'(rdma_status::set_fields_noalloc(
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
      void'(rdma_status::set_fields_noalloc(
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
    void'(rdma_status::set_fields_noalloc(status_slot, RDMA_SC_OK, ""));
    return 1'b1;
  endfunction

  // 功能：CQ consumer CI 提交后验证唯一 pending release authority，持 CQ runtime lock 形成 WQE release 屏障（无分配）。
  // 输入/输出及副作用：成功置 consumer_release_gate_active 并带锁返回；调用方按 CQ->WQ 顺序 release，所有退出路径须调用
  //   finish_consumer_release_noalloc。
  // 失败/边界：slot/lock 无效、gate 已活动、非 CQ SUCCESS consumer pending、CI/marker/target 不完整或已释放返回 0，并在 WQ
  //   修改前归还锁。
  function bit begin_consumer_release_noalloc(rdma_status status_slot);
    if (status_slot == null) return 1'b0;
    if (lock == null || !lock.try_get(1)) begin
      void'(rdma_status::set_fields_noalloc(
        status_slot, RDMA_SC_RESOURCE_BUSY, "queue runtime is busy"));
      return 1'b0;
    end
    if (consumer_release_gate_active) begin
      lock.put(1);
      void'(rdma_status::set_fields_noalloc(
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
      void'(rdma_status::set_fields_noalloc(
        status_slot, RDMA_SC_INVALID_STATE,
        "consumer release authority is invalid"));
      return 1'b0;
    end

    consumer_release_gate_active = 1'b1;
    void'(rdma_status::set_fields_noalloc(status_slot, RDMA_SC_OK, ""));
    return 1'b1;
  endfunction

  // 功能：结束 begin 持有的 CQ release 屏障；成功 release 时先发布 completion_released 再归还锁。
  // 输入/输出及副作用：release_succeeded 为 routed WQ 的实际结果；清除 gate、归还 token，成功时 slot 置 OK。
  // 失败/边界：gate 未活动返回 0 且不误归还锁；gate 活动后不得失败，release_succeeded=0 时保留 caller 的失败 status 与 pending
  //   marker。
  function bit finish_consumer_release_noalloc(
    bit release_succeeded,
    rdma_status status_slot
  );
    if (!consumer_release_gate_active) begin
      if (status_slot != null)
        void'(rdma_status::set_fields_noalloc(
          status_slot, RDMA_SC_INVALID_STATE,
          "consumer release gate is not active"));
      return 1'b0;
    end

    if (release_succeeded) begin
      pending_operation_state.completion_released = 1'b1;
      if (status_slot != null)
        void'(rdma_status::set_fields_noalloc(status_slot, RDMA_SC_OK, ""));
    end
    consumer_release_gate_active = 1'b0;
    lock.put(1);
    return 1'b1;
  endfunction

  // 功能：为 CQ/CEQ/AEQ 锁定当前 producer cursor，返回与内部隔离的 detached reservation。
  // 输入/输出及副作用：reservation 先置 null；成功只登记 device_reservation，不推进 committed PI/used。
  // 失败/边界：未配置/非 ACTIVE、host 方向、SQ/RQ/SRQ kind、pending recovery、已有 reservation、ring full 或分配失败返回错误。
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
      return value_ops::make_runtime_status(RDMA_SC_INVALID_STATE,
                                 "device producer is invalid for this ring");
    end
    if (state != RDMA_QUEUE_RUNTIME_ACTIVE || pending_operation_state != null) begin
      lock.put(1);
      return value_ops::make_runtime_status(RDMA_SC_INVALID_STATE,
                                 "queue runtime is not ready for reservation");
    end
    if (device_reservation_valid) begin
      lock.put(1);
      return value_ops::make_runtime_status(RDMA_SC_RESOURCE_BUSY,
                                 "device reservation is busy");
    end
    if (used >= depth) begin
      lock.put(1);
      return value_ops::make_runtime_status(RDMA_SC_QUEUE_FULL,
                                 "device ring is full");
    end
    raw_staged_reservation = value_ops::factory_create_object_nonfatal(
      rdma_queue_cursor_snapshot::get_type(), "device_producer_reservation");
    raw_published_reservation = value_ops::factory_create_object_nonfatal(
      rdma_queue_cursor_snapshot::get_type(), "device_producer_reservation_out");
    if (raw_staged_reservation == null ||
        !$cast(staged_reservation, raw_staged_reservation) ||
        raw_published_reservation == null ||
        !$cast(published_reservation, raw_published_reservation)) begin
      lock.put(1);
      return value_ops::make_runtime_status(RDMA_SC_RESOURCE_EXHAUSTED,
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
    return value_ops::make_runtime_status(RDMA_SC_OK, "");
  endfunction

  // 功能：把匹配的 device reservation 原子推进为 committed producer cursor 并增加 occupancy。
  // 输入/输出及副作用：reservation 须为 reserve_device_producer 返回的值副本；成功更新 PI/wrap、used 并清除 reservation。
  // 失败/边界：reservation 空/失配、非 ACTIVE（且未显式 recovery commit）、有 pending 证据、计数越界或方向错误返回错误。
  function rdma_status commit_device_producer(
    rdma_queue_cursor_snapshot reservation
  );
    rdma_status lock_status;
    rdma_status next_status;
    rdma_queue_cursor_snapshot expected_next;
    bit recovery_path;

    if (reservation == null)
      return value_ops::make_runtime_status(RDMA_SC_INVALID_ARGUMENT,
                                 "device reservation is null");
    lock_status = acquire_lock();
    if (!value_ops::status_is_ok(lock_status)) return lock_status;
    if (host_produced || !is_device_ring_kind(kind)) begin
      lock.put(1);
      return value_ops::make_runtime_status(RDMA_SC_INVALID_STATE,
                                 "device producer is invalid for this ring");
    end
    if (depth == 0 || reservation.index >= depth) begin
      lock.put(1);
      return value_ops::make_runtime_status(RDMA_SC_INVALID_STATE,
                                 "device reservation is outside depth");
    end
    if (!device_reservation_valid || device_reservation == null ||
        !cursor_equal(reservation.index, reservation.wrap,
                      device_reservation.index, device_reservation.wrap) ||
        !cursor_equal(reservation.index, reservation.wrap,
                      producer_index, producer_wrap)) begin
      lock.put(1);
      return value_ops::make_runtime_status(RDMA_SC_INVALID_STATE,
                                 "device reservation is stale");
    end
    if (used > depth) begin
      lock.put(1);
      return value_ops::make_runtime_status(RDMA_SC_INVALID_STATE,
                                 "device ring occupancy exceeds depth");
    end

    recovery_path = (state == RDMA_QUEUE_RUNTIME_RECOVERY_REQUIRED);
    if (!recovery_path) begin
      if (state != RDMA_QUEUE_RUNTIME_ACTIVE || pending_operation_state != null ||
          recovery_commit_allowed) begin
        lock.put(1);
        return value_ops::make_runtime_status(RDMA_SC_INVALID_STATE,
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
        return value_ops::make_runtime_status(RDMA_SC_INVALID_STATE,
                                   "device recovery commit evidence is invalid");
      end
      if (!pending_cursor_shape_valid(pending_operation_state)) begin
        lock.put(1);
        return value_ops::make_runtime_status(RDMA_SC_INVALID_ARGUMENT,
                                   "device recovery cursor evidence is invalid");
      end
      if (!cursor_equal(reservation.index, reservation.wrap,
                        pending_operation_state.cursor.index,
                        pending_operation_state.cursor.wrap)) begin
        lock.put(1);
        return value_ops::make_runtime_status(RDMA_SC_INVALID_STATE,
                                   "device recovery reservation is stale");
      end
      next_status = derive_next_cursor(pending_operation_state.cursor,
                                       expected_next);
      if (!value_ops::status_is_ok(next_status) || expected_next == null ||
          !cursor_equal(expected_next.index, expected_next.wrap,
                        pending_operation_state.next_cursor.index,
                        pending_operation_state.next_cursor.wrap)) begin
        lock.put(1);
        return (next_status != null && !next_status.ok()) ? next_status :
          value_ops::make_runtime_status(RDMA_SC_INVALID_STATE,
                              "device recovery next cursor is invalid");
      end
    end
    if (used >= depth) begin
      lock.put(1);
      return value_ops::make_runtime_status(RDMA_SC_QUEUE_FULL,
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
      return value_ops::make_runtime_status(RDMA_SC_INVALID_STATE,
                                 "device producer advance mismatched recovery evidence");
    end
    used++;
    device_reservation_valid = 1'b0;
    device_reservation = null;
    if (recovery_path)
      recovery_commit_allowed = 1'b0;
    lock.put(1);
    return value_ops::make_runtime_status(RDMA_SC_OK, "");
  endfunction

  // 功能：清除尚未产生写入副作用的 device reservation，不改 committed cursor 与 occupancy。
  // 输入/输出及副作用：reservation 须匹配内部快照；成功清除 reservation 状态。
  // 失败/边界：空/失配、非 ACTIVE、无 reservation 或已标记写入尝试返回 INVALID_STATE/RECOVERY_REQUIRED，保留 reservation。
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
      return value_ops::make_runtime_status(RDMA_SC_INVALID_STATE,
                                 "device reservation is stale");
    end
    // 设计说明：write-attempt 是 cancel 的首要不可逆边界。prepared admission 会
    // 先把 state 切到 RECOVERY_REQUIRED，因此必须在一般 state gate 之前读取该
    // authority；device producer 不使用 consumer 的 mmio_maybe_submitted 位。
    if (pending_operation_state != null && pending_operation_state.device_producer &&
        pending_operation_state.device_write_attempted) begin
      lock.put(1);
      return value_ops::make_runtime_status(RDMA_SC_RECOVERY_REQUIRED,
                                 "device reservation has write evidence");
    end
    if (state != RDMA_QUEUE_RUNTIME_ACTIVE) begin
      lock.put(1);
      return value_ops::make_runtime_status(RDMA_SC_INVALID_STATE,
                                 "queue runtime is not active");
    end
    device_reservation_valid = 1'b0;
    device_reservation = null;
    lock.put(1);
    return value_ops::make_runtime_status(RDMA_SC_OK, "");
  endfunction

  // 功能：由 initial_polarity 与 reservation（或当前 producer_wrap）纯计算 device producer 的 owner 位。
  // 输入/输出及副作用：reservation 可选；只读，不改 runtime。
  // 失败/边界：null reservation 用当前 producer_wrap；不校验状态，状态化校验用 query_expected_producer_polarity。
  function bit expected_producer_polarity(
    rdma_queue_cursor_snapshot reservation = null
  );
    return initial_polarity ^ (reservation == null ? producer_wrap : reservation.wrap);
  endfunction

  // 功能：持锁返回已 commit 的 producer-consumer 距离（used）。
  // 输入/输出及副作用：value 先清零，成功写 used。
  // 失败/边界：未配置、used>depth 或锁忙返回非成功，输出为 0。
  function rdma_status query_occupancy(output int unsigned value);
    rdma_status lock_status;
    value = 0;
    lock_status = acquire_lock();
    if (!lock_status.ok()) return lock_status;
    if (depth == 0) begin
      lock.put(1);
      return value_ops::make_runtime_status(RDMA_SC_INVALID_STATE,
                                 "runtime is unconfigured");
    end
    if (used > depth) begin
      lock.put(1);
      return value_ops::make_runtime_status(RDMA_SC_INVALID_STATE,
                                 "runtime occupancy exceeds depth");
    end
    value = used;
    lock.put(1);
    return value_ops::make_runtime_status(RDMA_SC_OK, "");
  endfunction

  // 功能：同一锁内返回 PI/CI 的 index/wrap 值，供测试与诊断读取。
  // 输入/输出及副作用：输出先置默认值，成功只复制值。
  // 失败/边界：未配置、PI/CI 越界或锁忙返回错误，输出全零。
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
    if (!value_ops::status_is_ok(lock_status)) return lock_status;
    if (depth == 0 || producer_index >= depth || consumer_index >= depth) begin
      lock.put(1);
      return value_ops::make_runtime_status(RDMA_SC_INVALID_STATE,
                                 "runtime cursors are unavailable");
    end
    producer_index_value = producer_index;
    producer_wrap_value = producer_wrap;
    consumer_index_value = consumer_index;
    consumer_wrap_value = consumer_wrap;
    lock.put(1);
    return value_ops::make_runtime_status(RDMA_SC_OK, "");
  endfunction

  // 功能：兼容 accessor：返回 detached pending 副本，无 pending 返回 null。
  // 输入/输出及副作用：有 pending 时深复制；不改证据。
  // 失败/边界：lock 或深复制失败时返回非空哨兵使旧调用 fail-closed；完整读取用 query_pending。
  function rdma_queue_pending_operation pending_operation();
    rdma_queue_pending_operation snapshot;
    rdma_queue_pending_operation fallback;
    rdma_status lock_status;
    rdma_status copy_status;

    snapshot = null;
    lock_status = acquire_lock();
    if (!value_ops::status_is_ok(lock_status)) begin
      fallback = new("pending_presence_busy");
      return fallback;
    end
    if (pending_operation_state == null) begin
      lock.put(1);
      return null;
    end
    copy_status = value_ops::clone_pending_value(pending_operation_state, snapshot);
    lock.put(1);
    if (!value_ops::status_is_ok(copy_status) || snapshot == null) begin
      fallback = new("pending_presence_copy_failed");
      return fallback;
    end
    return snapshot;
  endfunction

  // 功能：返回内部 device reservation 的 detached 副本，供诊断与恢复读取。
  // 输入/输出及副作用：valid/reservation 先置 0/null；成功复制。
  // 失败/边界：未配置、非 device ring、内部句柄缺失或 clone 失败返回非成功，输出保持默认。
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
      return value_ops::make_runtime_status(RDMA_SC_INVALID_STATE,
                                 "runtime is not a device ring");
    end
    if (!device_reservation_valid) begin
      lock.put(1);
      return value_ops::make_runtime_status(RDMA_SC_OK, "");
    end
    if (device_reservation == null) begin
      lock.put(1);
      return value_ops::make_runtime_status(RDMA_SC_INVALID_STATE,
                                 "device reservation state is corrupt");
    end
    raw_reservation = value_ops::factory_create_object_nonfatal(
      rdma_queue_cursor_snapshot::get_type(), "device_reservation_query");
    if (raw_reservation == null || !$cast(reservation, raw_reservation)) begin
      reservation = null;
      lock.put(1);
      return value_ops::make_runtime_status(RDMA_SC_RESOURCE_EXHAUSTED,
                                 "device reservation snapshot allocation failed");
    end
    reservation.index = device_reservation.index;
    reservation.wrap = device_reservation.wrap;
    valid = 1'b1;
    lock.put(1);
    return value_ops::make_runtime_status(RDMA_SC_OK, "");
  endfunction

  // 功能：对 device runtime 状态化查询期望的 producer owner polarity。
  // 输入/输出及副作用：polarity 先清零，成功写 initial_polarity XOR producer_wrap。
  // 失败/边界：未配置、host ring、游标/occupancy 越界或锁忙返回非成功，输出为 0。
  function rdma_status query_expected_producer_polarity(output bit polarity);
    rdma_status lock_status;
    polarity = 1'b0;
    lock_status = acquire_lock();
    if (!lock_status.ok()) return lock_status;
    if (depth == 0 || host_produced || producer_index >= depth || used > depth) begin
      lock.put(1);
      return value_ops::make_runtime_status(RDMA_SC_INVALID_STATE,
                                 "producer polarity is unavailable");
    end
    polarity = initial_polarity ^ producer_wrap;
    lock.put(1);
    return value_ops::make_runtime_status(RDMA_SC_OK, "");
  endfunction

  // 功能：返回 consumer 期望的 owner/polarity（initial_polarity XOR consumer_wrap）。
  // 输入/输出及副作用：只读；无 status。
  // 失败/边界：不校验配置状态，未配置时得到构造默认值。
  function bit expected_owner_polarity();
    return initial_polarity ^ consumer_wrap;
  endfunction

  // 功能：比较 caller handle 与 configure 冻结的 queue identity，区分身份错误与 stale generation。
  // 输入/输出及副作用：qh 为非拥有引用；只读。
  // 失败/边界：空或 kind/UID/object_id 不等返回 INVALID_ARGUMENT；generation 不等返回 STALE_GENERATION；不替代
  //   state/route/epoch 校验。
  function rdma_status validate_queue_handle(rdma_handle qh);
    if (queue_h == null || qh == null)
      return value_ops::make_runtime_status(RDMA_SC_INVALID_ARGUMENT,
                                 "queue handle is null");
    if (qh.kind != queue_h.kind ||
        qh.function_uid != queue_h.function_uid ||
        qh.object_id != queue_h.object_id)
      return value_ops::make_runtime_status(RDMA_SC_INVALID_ARGUMENT,
                                 "queue handle identity mismatch");
    if (qh.generation != queue_h.generation)
      return value_ops::make_runtime_status(RDMA_SC_STALE_GENERATION,
                                 "queue handle generation is stale");
    return value_ops::make_runtime_status(RDMA_SC_OK, "");
  endfunction

  // 功能：为 SQ/RQ/SRQ host producer 返回当前 PI/wrap 的 detached reservation。
  // 输入/输出及副作用：reservation 先置 null；成功仅发布独立 cursor，不增加 used、不占 slot。
  // 失败/边界：device ring、非 ACTIVE 返回 INVALID_STATE；used>=depth 返回 QUEUE_FULL；分配失败返回
  //   RESOURCE_EXHAUSTED。
  function rdma_status reserve_producer(output rdma_queue_cursor_snapshot reservation);
    rdma_status lock_status;
    uvm_object raw_reservation;

    reservation=null;
    lock_status = acquire_lock();
    if (!lock_status.ok()) return lock_status;
    if (!host_produced) begin
      lock.put(1);
      return value_ops::make_runtime_status(RDMA_SC_INVALID_STATE,
                                 "host producer is invalid for this ring");
    end
    if (state!=RDMA_QUEUE_RUNTIME_ACTIVE) begin
      lock.put(1);
      return value_ops::make_runtime_status(RDMA_SC_INVALID_STATE,
                                 "queue runtime is not active");
    end
    if (used>=depth) begin
      lock.put(1);
      return value_ops::make_runtime_status(RDMA_SC_QUEUE_FULL,
                                 "queue producer ring is full");
    end
    raw_reservation = value_ops::factory_create_object_nonfatal(
      rdma_queue_cursor_snapshot::get_type(), "producer_reservation");
    if (raw_reservation == null || !$cast(reservation, raw_reservation)) begin
      reservation = null;
      lock.put(1);
      return value_ops::make_runtime_status(RDMA_SC_RESOURCE_EXHAUSTED,
                                 "producer reservation allocation failed");
    end
    reservation.index=producer_index;
    reservation.wrap=producer_wrap;
    lock.put(1);
    return value_ops::make_runtime_status(RDMA_SC_OK, "");
  endfunction

  // 功能：把匹配当前 PI 的 host WQE 写入 slot ledger 并原子推进 PI/used；recovery 路径还校验 pending cursor 并消费一次 commit
  //   gate。
  // 输入/输出及副作用：成功保存 request/image 的 detached 副本、发布 posted slot、更新 PI。
  // 失败/边界：方向/状态/cursor/ledger/occupancy/recovery 证据不符或副本分配失败返回错误；失败恢复 slot、PI、used 原值。
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
      return value_ops::make_runtime_status(RDMA_SC_INVALID_ARGUMENT,
                                 "producer reservation is null");
    lock_status = acquire_lock();
    if (!value_ops::status_is_ok(lock_status)) return lock_status;
    if (!host_produced) begin
      lock.put(1);
      return value_ops::make_runtime_status(RDMA_SC_INVALID_STATE,
                                 "host producer is invalid for this ring");
    end
    if (depth == 0 || reservation.index >= depth) begin
      lock.put(1);
      return value_ops::make_runtime_status(RDMA_SC_INVALID_ARGUMENT,
                                 "producer reservation is outside depth");
    end
    if (slots.size() < depth) begin
      lock.put(1);
      return value_ops::make_runtime_status(RDMA_SC_INVALID_STATE,
                                 "host producer ledger is incomplete");
    end
    slot = slots[reservation.index];
    if (slot == null) begin
      lock.put(1);
      return value_ops::make_runtime_status(RDMA_SC_INVALID_STATE,
                                 "host producer slot is null");
    end

    recovery_path = (state == RDMA_QUEUE_RUNTIME_RECOVERY_REQUIRED);
    if (!recovery_path) begin
      if (state != RDMA_QUEUE_RUNTIME_ACTIVE || pending_operation_state != null ||
          recovery_commit_allowed) begin
        lock.put(1);
        return value_ops::make_runtime_status(RDMA_SC_INVALID_STATE,
                                   "queue runtime is not active");
      end
      if (!cursor_equal(reservation.index, reservation.wrap,
                        producer_index, producer_wrap)) begin
        lock.put(1);
        return value_ops::make_runtime_status(RDMA_SC_INVALID_STATE,
                                   "producer reservation is stale");
      end
    end else begin
      if (!recovery_commit_allowed || pending_operation_state == null ||
          !pending_operation_state.producer || pending_operation_state.device_producer ||
          !pending_identity_matches_locked(pending_operation_state) ||
          pending_operation_state.kind != kind || pending_operation_state.cursor == null ||
          pending_operation_state.next_cursor == null) begin
        lock.put(1);
        return value_ops::make_runtime_status(RDMA_SC_INVALID_STATE,
                                   "producer recovery evidence is invalid");
      end
      if (!pending_cursor_shape_valid(pending_operation_state)) begin
        lock.put(1);
        return value_ops::make_runtime_status(RDMA_SC_INVALID_ARGUMENT,
                                   "producer recovery cursor evidence is invalid");
      end
      if (!cursor_equal(reservation.index, reservation.wrap,
                        pending_operation_state.cursor.index,
                        pending_operation_state.cursor.wrap)) begin
        lock.put(1);
        return value_ops::make_runtime_status(RDMA_SC_INVALID_STATE,
                                   "producer recovery reservation is stale");
      end
      // 中文设计：PI 已等于 next_cursor 代表这笔 recovery transaction 已经
      // 提交；即使 caller 重放同一 reservation，也不能再次增加 used。
      if (cursor_equal(producer_index, producer_wrap,
                       pending_operation_state.next_cursor.index,
                       pending_operation_state.next_cursor.wrap)) begin
        lock.put(1);
        return value_ops::make_runtime_status(RDMA_SC_INVALID_STATE,
                                   "producer recovery transaction is already committed");
      end
      if (!cursor_equal(producer_index, producer_wrap,
                        pending_operation_state.cursor.index,
                        pending_operation_state.cursor.wrap)) begin
        lock.put(1);
        return value_ops::make_runtime_status(RDMA_SC_INVALID_STATE,
                                   "producer recovery PI is stale");
      end
      next_status = derive_next_cursor(pending_operation_state.cursor, expected_next);
      if (!value_ops::status_is_ok(next_status) || expected_next == null ||
          !cursor_equal(expected_next.index, expected_next.wrap,
                        pending_operation_state.next_cursor.index,
                        pending_operation_state.next_cursor.wrap)) begin
        lock.put(1);
        return (next_status != null && !next_status.ok()) ? next_status :
          value_ops::make_runtime_status(RDMA_SC_INVALID_STATE,
                              "producer recovery next cursor is invalid");
      end
    end
    if (used > depth || used >= depth) begin
      lock.put(1);
      return used > depth ?
        value_ops::make_runtime_status(RDMA_SC_INVALID_STATE,
                            "host producer occupancy exceeds depth") :
        value_ops::make_runtime_status(RDMA_SC_QUEUE_FULL,
                            "queue producer ring is full");
    end
    if (slot.posted && !slot.consumed) begin
      lock.put(1);
      return value_ops::make_runtime_status(RDMA_SC_INVALID_STATE,
                                 "producer slot is still posted");
    end

    // 中文设计：先完成全部 caller 值快照，再触碰 slot/PI/used；factory 故障或
    // 不支持的 request subtype 因此不会留下半提交 ledger。
    copy_status = value_ops::clone_request_value_nonfatal(request, request_copy);
    if (!value_ops::status_is_ok(copy_status)) begin
      lock.put(1);
      return (copy_status != null) ? copy_status :
        value_ops::make_runtime_status(RDMA_SC_RESOURCE_EXHAUSTED,
                            "producer request snapshot clone failed");
    end
    copy_status = value_ops::clone_image_value_nonfatal(image, image_copy);
    if (!value_ops::status_is_ok(copy_status)) begin
      lock.put(1);
      return (copy_status != null) ? copy_status :
        value_ops::make_runtime_status(RDMA_SC_RESOURCE_EXHAUSTED,
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
      return value_ops::make_runtime_status(RDMA_SC_INVALID_STATE,
                                 "producer recovery PI advance mismatched evidence");
    end
    used++;
    if (recovery_path)
      recovery_commit_allowed = 1'b0;
    lock.put(1);
    return value_ops::make_runtime_status(RDMA_SC_OK, "");
  endfunction

  // 功能：兼容入口：比较两个 cursor 的 index/wrap（委托 projector）。
  // 输入/输出及副作用：纯函数。
  // 失败/边界：任一不等返回 0；不校验 index<depth。
  function bit cursor_equal(
    int unsigned a,
    bit aw,
    int unsigned b,
    bit bw
  );
    return value_ops::cursor_equal(a, aw, b, bw);
  endfunction

  // 功能：校验释放范围当前位置的 ledger slot 是已发布、未消费且 index/wrap 匹配的条目。
  // 输入/输出及副作用：只读 slot；供四个 range API 共用。
  // 失败/边界：slot 为空、未 posted、已 consumed 或 index/wrap 不匹配返回 0；不检查 depth/used/可达性。
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

  // 功能：兼容 wrapper：就地计算 ring 的下一个 index/wrap（委托共享 cursor policy）。
  // 输入/输出及副作用：i/w 为 inout，只读 depth。
  // 失败/边界：假定调用方已保证 depth>0 且 i<depth；不返回错误，也不等于 commit。
  function void cursor_advance(inout int unsigned i, inout bit w);
    rdma_queue_cursor_policy::advance(depth, i, w, i, w);
  endfunction

  // 功能：从当前 host CI 沿 ring 向前最多 depth 步，判断 completion target 是否可达。
  // 输入/输出及副作用：只读 CI/wrap/depth，在局部变量中模拟前进。
  // 失败/边界：在当前 cursor 或恰好 depth 步后命中返回 1，否则 0；不检查越界/slot/used。
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

  // 功能：从当前 host CI 连续校验到 completion target，一次性释放该段已 posted WQE，推进 CI 并减少 used。
  // 输入/输出及副作用：released 先清空，成功时按序返回 slot 的非拥有引用。
  // 失败/边界：非 ACTIVE/未授权 recovery、target 越界或不在窗口内、范围内有 null/unposted/consumed/stale slot 返回错误，不释放任何项。
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
      return value_ops::make_runtime_status(RDMA_SC_INVALID_STATE,
                                 "queue runtime is not active");
    end
    if (target_index >= depth) begin
      lock.put(1);
      return value_ops::make_runtime_status(RDMA_SC_INVALID_ARGUMENT,
                                 "completion index is outside depth");
    end
    if (!release_range_target_reachable(target_index, target_wrap)) begin
      lock.put(1);
      return value_ops::make_runtime_status(RDMA_SC_INVALID_STATE,
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
        return value_ops::make_runtime_status(RDMA_SC_INVALID_STATE,
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
    return value_ops::make_runtime_status(RDMA_SC_OK, "");
  endfunction

  // 功能：以冻结的 completion cursor 原子释放 host ledger 区间（不构造 returned slot 队列）。
  // 输入/输出及副作用：status_slot 由 caller 预建；成功把连续 slot 标为 consumed、推进 CI、按项递减 used。
  // 失败/边界：slot/lock 无效、非 host ring、状态/target/容量/used 不一致返回 0；先校验整段再修改，拒绝时不变。
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
      void'(rdma_status::set_fields_noalloc(
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
      void'(rdma_status::set_fields_noalloc(
        status_slot, RDMA_SC_INVALID_STATE,
        "queue runtime is not an active host WQ"));
      return 1'b0;
    end
    if (depth == 0 || target_index >= depth) begin
      lock.put(1);
      void'(rdma_status::set_fields_noalloc(
        status_slot, RDMA_SC_INVALID_ARGUMENT,
        "completion index is outside depth"));
      return 1'b0;
    end
    if (consumer_index >= depth || slots.size() < depth || used == 0 ||
        used > depth) begin
      lock.put(1);
      void'(rdma_status::set_fields_noalloc(
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
        void'(rdma_status::set_fields_noalloc(
          status_slot, RDMA_SC_INVALID_STATE,
          "completion cursor is not outstanding"));
        return 1'b0;
      end
      slot = slots[i];
      if (!release_range_slot_shape_valid(slot, i, w)) begin
        lock.put(1);
        void'(rdma_status::set_fields_noalloc(
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
      void'(rdma_status::set_fields_noalloc(
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
    void'(rdma_status::set_fields_noalloc(status_slot, RDMA_SC_OK, ""));
    return 1'b1;
  endfunction

  // 功能：持锁校验从当前 host CI 到 target 的完整 outstanding WQE 区间，并深复制每一项。
  // 输入/输出及副作用：snapshots 先清空，成功按消费顺序返回 detached slot/request/image/status；不推进 CI、不减 used。
  // 失败/边界：非 ACTIVE host ring、空/越界/非 outstanding target、畸形 ledger 或任一复制失败时清空输出，ledger/游标/credit 不变。
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
    if (!value_ops::status_is_ok(lock_status)) return lock_status;
    if (state != RDMA_QUEUE_RUNTIME_ACTIVE || !host_produced ||
        is_device_ring_kind(kind) || depth == 0 || slots.size() < depth) begin
      lock.put(1);
      return value_ops::make_runtime_status(RDMA_SC_INVALID_STATE,
                                 "release range runtime is not active host WQ");
    end
    if (target_index >= depth) begin
      lock.put(1);
      return value_ops::make_runtime_status(RDMA_SC_INVALID_ARGUMENT,
                                 "completion index is outside depth");
    end
    if (used == 0 || used > depth) begin
      lock.put(1);
      return value_ops::make_runtime_status(RDMA_SC_INVALID_STATE,
                                 "release range has invalid occupancy");
    end

    i = consumer_index;
    w = consumer_wrap;
    count = 0;
    do begin
      if (count >= used || count >= depth) begin
        lock.put(1);
        snapshots.delete();
        return value_ops::make_runtime_status(RDMA_SC_INVALID_STATE,
                                   "completion cursor is not outstanding");
      end
      slot = slots[i];
      if (!release_range_slot_shape_valid(slot, i, w)) begin
        lock.put(1);
        snapshots.delete();
        return value_ops::make_runtime_status(RDMA_SC_INVALID_STATE,
                                   "completion skips an unposted slot");
      end
      copy_status = value_ops::clone_slot_value_nonfatal(slot, slot_copy);
      if (!value_ops::status_is_ok(copy_status) || slot_copy == null) begin
        lock.put(1);
        snapshots.delete();
        return copy_status == null ?
          value_ops::make_runtime_status(RDMA_SC_RESOURCE_EXHAUSTED,
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
    return value_ops::make_runtime_status(RDMA_SC_OK, "");
  endfunction

  // 功能：发送 CQ consumer doorbell 前，只读验证从当前 CI 到 completion target 的连续 posted WQE 区间。
  // 输入/输出及副作用：只读 cursor 与 slot ledger，不消费 slot、不推进 CI。
  // 失败/边界：非 ACTIVE、target 越界/不在窗口内或区间含 null/unposted/consumed/不一致项返回错误，ledger 不变。
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
      return value_ops::make_runtime_status(RDMA_SC_INVALID_STATE,
                                 "queue runtime is not active");
    end
    if (target_index >= depth) begin
      lock.put(1);
      return value_ops::make_runtime_status(RDMA_SC_INVALID_ARGUMENT,
                                 "completion index is outside depth");
    end
    if (!release_range_target_reachable(target_index, target_wrap)) begin
      lock.put(1);
      return value_ops::make_runtime_status(RDMA_SC_INVALID_STATE,
                                 "completion cursor is not outstanding");
    end
    count = 0;
    i = consumer_index;
    w = consumer_wrap;
    do begin
      slot = slots[i];
      if (!release_range_slot_shape_valid(slot, i, w)) begin
        lock.put(1);
        return value_ops::make_runtime_status(RDMA_SC_INVALID_STATE,
                                   "completion skips an unposted slot");
      end
      reached_target = cursor_equal(i, w, target_index, target_wrap);
      cursor_advance(i, w);
      count++;
      if (reached_target) break;
    end while (count <= depth);
    lock.put(1);
    return value_ops::make_runtime_status(RDMA_SC_OK, "");
  endfunction

  // 功能：host producer 的 legacy bit 入口：把 caller operation 深复制为 runtime 持有的 pending，并投影
  //   NO_SUBMIT/AMBIGUOUS。
  // 输入/输出及副作用：成功切到 RECOVERY_REQUIRED，保存 detached pending，清空 commit/retry/release gate；不接管 caller
  //   原对象。
  // 失败/边界：非 ACTIVE、非 host producer、CQ/CEQ/AEQ、identity/cursor 冲突或分配失败返回错误；device 路径须用 prepared 入口。
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
    if (!value_ops::status_is_ok(lock_status)) return lock_status;
    if (state != RDMA_QUEUE_RUNTIME_ACTIVE || operation == null) begin
      lock.put(1);
      return value_ops::make_runtime_status(RDMA_SC_INVALID_STATE,
                                 "queue runtime cannot enter legacy recovery");
    end
    // 设计说明：legacy bit 无法表达 device publish/consumer 所需的 route、epoch、
    // image 与阶段 authority；在复制或字段补全前先按显式 producer 方向拒绝，
    // 避免默认值被反向推断为一笔可重放 device transaction。
    if (!host_produced || operation.device_producer || !operation.producer ||
        !(kind inside {RDMA_QUEUE_RUNTIME_SQ, RDMA_QUEUE_RUNTIME_RQ,
                       RDMA_QUEUE_RUNTIME_SRQ})) begin
      lock.put(1);
      return value_ops::make_runtime_status(RDMA_SC_INVALID_STATE,
                                 "legacy recovery requires host producer");
    end
    copy_status = value_ops::clone_pending_value(operation, copy);
    if (!value_ops::status_is_ok(copy_status) || copy == null) begin
      lock.put(1);
      return (copy_status != null) ? copy_status :
        value_ops::make_runtime_status(RDMA_SC_RESOURCE_EXHAUSTED,
                            "pending operation value copy failed");
    end

    // 中文设计：legacy caller 可能省略 queue_h，或把 kind 留在构造默认 SQ；
    // 这里只从当前 immutable runtime 补齐缺失身份，caller 显式给出的不一致值
    // 仍由下方校验拒绝，不能借兼容逻辑覆盖。
    if (copy.queue_h == null) begin
      copy_status = value_ops::clone_handle_value_nonfatal(queue_h, queue_copy);
      if (!value_ops::status_is_ok(copy_status) || queue_copy == null) begin
        lock.put(1);
        return (copy_status != null) ? copy_status :
          value_ops::make_runtime_status(RDMA_SC_RESOURCE_EXHAUSTED,
                              "legacy recovery queue snapshot failed");
      end
      copy.queue_h = queue_copy;
      if (copy.kind != kind && copy.kind == RDMA_QUEUE_RUNTIME_SQ)
        copy.kind = kind;
    end
    if (copy.queue_h == null || queue_h == null ||
        !value_ops::handle_value_equal(copy.queue_h, queue_h) || copy.kind != kind) begin
      lock.put(1);
      return value_ops::make_runtime_status(RDMA_SC_INVALID_ARGUMENT,
                                 "legacy recovery identity mismatch");
    end
    if (!copy.producer || copy.device_producer || !host_produced ||
        !(kind inside {RDMA_QUEUE_RUNTIME_SQ, RDMA_QUEUE_RUNTIME_RQ,
                       RDMA_QUEUE_RUNTIME_SRQ})) begin
      lock.put(1);
      return value_ops::make_runtime_status(RDMA_SC_INVALID_STATE,
                                 "legacy producer direction mismatch");
    end

    if (copy.cursor == null) begin
      raw_cursor = value_ops::factory_create_object_nonfatal(
        rdma_queue_cursor_snapshot::get_type(), "legacy_recovery_cursor");
      if (raw_cursor == null || !$cast(copy.cursor, raw_cursor)) begin
        copy.cursor = null;
        lock.put(1);
        return value_ops::make_runtime_status(RDMA_SC_RESOURCE_EXHAUSTED,
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
      return value_ops::make_runtime_status(RDMA_SC_INVALID_ARGUMENT,
                                 "legacy recovery cursor is outside depth");
    end
    // 中文设计：在当前 runtime lock 保护的 geometry 下推导并保存提交后 cursor；
    // recovery 不依赖可变 caller cursor，也不在未来重新查询可能已变的 geometry。
    if (copy.next_cursor == null) begin
      next_status = derive_next_cursor(copy.cursor, derived_next);
      if (!value_ops::status_is_ok(next_status) || derived_next == null) begin
        lock.put(1);
        return (next_status != null) ? next_status :
          value_ops::make_runtime_status(RDMA_SC_RESOURCE_EXHAUSTED,
                              "legacy recovery next cursor allocation failed");
      end
      copy.next_cursor = derived_next;
    end
    next_status = derive_next_cursor(copy.cursor, derived_next);
    if (!value_ops::status_is_ok(next_status) || derived_next == null ||
        copy.next_cursor.index >= depth ||
        !cursor_equal(derived_next.index, derived_next.wrap,
                      copy.next_cursor.index, copy.next_cursor.wrap)) begin
      lock.put(1);
      return value_ops::make_runtime_status(RDMA_SC_INVALID_ARGUMENT,
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
    if (!value_ops::status_is_ok(project_status)) begin
      pending_operation_state = null;
      state = RDMA_QUEUE_RUNTIME_ACTIVE;
      lock.put(1);
      return (project_status != null) ? project_status :
        value_ops::make_runtime_status(RDMA_SC_RESOURCE_EXHAUSTED,
                            "legacy MMIO evidence projection failed");
    end
    recovery_commit_allowed = 1'b0;
    consumer_release_gate_active = 1'b0;
    recovery_retry_confirmed = 1'b0;
    lock.put(1);
    return value_ops::make_runtime_status(RDMA_SC_OK, "");
  endfunction

  // 功能：接管调用方已 detached 的 pending；首次 admission 安装 recovery evidence，重复 admission 单调合并同一事务阶段。
  // 输入/输出及副作用：首次成功后由 runtime 接管并切到 RECOVERY_REQUIRED；重复成功只合并 MMIO/commit 阶段并重置本轮 gate，reservation
  //   保持原快照。
  // 失败/边界：null、非 ACTIVE、identity/direction/geometry/image/status/route/epoch 不完整或 reservation
  //   冲突原子拒绝；重复事务的 immutable 证据/cursor/MMIO 转换/阶段顺序冲突也拒绝。
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
    if (!value_ops::status_is_ok(lock_status)) return lock_status;
    if (prepared == null) begin
      lock.put(1);
      return value_ops::make_runtime_status(RDMA_SC_INVALID_ARGUMENT,
                                 "prepared recovery is null");
    end

    // 中文设计：重复 admission 先按值比较完整 immutable object graph；只有
    // queue/cursor/image/status/request/WR/completion/route 全部属于同一 transaction，
    // 才允许后续 MMIO 投影和阶段位单调合并。
    if (state == RDMA_QUEUE_RUNTIME_RECOVERY_REQUIRED &&
        pending_operation_state != null) begin
      if (!value_ops::pending_immutable_evidence_equal(prepared,
                                            pending_operation_state)) begin
        lock.put(1);
        return value_ops::make_runtime_status(RDMA_SC_INVALID_STATE,
                                   "prepared recovery immutable evidence conflicts");
      end
      if (pending_operation_state.consumer_shadow_required &&
          (prepared.consumer_shadow_attempted !=
             pending_operation_state.consumer_shadow_attempted ||
           prepared.consumer_shadow_published !=
             pending_operation_state.consumer_shadow_published)) begin
        lock.put(1);
        return value_ops::make_runtime_status(
          RDMA_SC_INVALID_STATE,
          "prepared CQC shadow phase conflicts with pending");
      end
      if (!(prepared.mmio_evidence inside {RDMA_QUEUE_MMIO_NONE,
                                           RDMA_QUEUE_MMIO_NOT_APPLICABLE,
                                           RDMA_QUEUE_MMIO_NO_SUBMIT,
                                           RDMA_QUEUE_MMIO_SUCCESS,
                                           RDMA_QUEUE_MMIO_AMBIGUOUS})) begin
        lock.put(1);
        return value_ops::make_runtime_status(RDMA_SC_INVALID_ARGUMENT,
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
        return value_ops::make_runtime_status(RDMA_SC_INVALID_STATE,
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
        return value_ops::make_runtime_status(RDMA_SC_INVALID_STATE,
                                   "prepared recovery phase merge is invalid");
      end
      if (consumer_direction &&
          !consumer_recovery_invariant_locked(
            pending_operation_state, prepared.mmio_evidence,
            merged_consumer_committed, merged_committed_cursor)) begin
        lock.put(1);
        return value_ops::make_runtime_status(
          RDMA_SC_INVALID_STATE,
          "prepared consumer merge violates commit invariant");
      end
      staged_committed_cursor = null;
      if (prepared.committed_consumer_cursor != null &&
          pending_operation_state.committed_consumer_cursor == null) begin
        copy_status = value_ops::clone_cursor_value_nonfatal(
          prepared.committed_consumer_cursor, staged_committed_cursor);
        if (!value_ops::status_is_ok(copy_status) || staged_committed_cursor == null) begin
          lock.put(1);
          return (copy_status != null) ? copy_status : value_ops::make_runtime_status(
            RDMA_SC_RESOURCE_EXHAUSTED,
            "prepared committed cursor copy failed");
        end
      end
      project_status = project_mmio_evidence_locked(prepared.mmio_evidence);
      if (!value_ops::status_is_ok(project_status)) begin
        lock.put(1);
        return project_status != null ? project_status :
          value_ops::make_runtime_status(RDMA_SC_INVALID_STATE,
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
      return value_ops::make_runtime_status(RDMA_SC_OK, "");
    end

    if (state != RDMA_QUEUE_RUNTIME_ACTIVE || pending_operation_state != null) begin
      lock.put(1);
      return value_ops::make_runtime_status(RDMA_SC_INVALID_STATE,
                                 "runtime cannot install prepared recovery");
    end
    if (prepared.queue_h == null || queue_h == null ||
        !value_ops::handle_value_equal(prepared.queue_h, queue_h)) begin
      lock.put(1);
      return value_ops::make_runtime_status(RDMA_SC_INVALID_ARGUMENT,
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
      return value_ops::make_runtime_status(RDMA_SC_INVALID_STATE,
                                 "prepared recovery direction mismatch");
    end
    if (!pending_cursor_geometry_valid(prepared)) begin
      lock.put(1);
      return value_ops::make_runtime_status(RDMA_SC_INVALID_ARGUMENT,
                                 "prepared recovery geometry is invalid");
    end
    next_status = derive_next_cursor(prepared.cursor, expected_next);
    if (!value_ops::status_is_ok(next_status) || expected_next == null ||
        !cursor_equal(expected_next.index, expected_next.wrap,
                      prepared.next_cursor.index, prepared.next_cursor.wrap)) begin
      lock.put(1);
      return (next_status != null && !next_status.ok()) ? next_status :
        value_ops::make_runtime_status(RDMA_SC_INVALID_ARGUMENT,
                            "prepared recovery next cursor is invalid");
    end
    if (prepared.image == null || prepared.image.length != prepared.entry_size ||
        prepared.image.bytes.size() != prepared.image.length ||
        prepared.failure_status == null) begin
      lock.put(1);
      return value_ops::make_runtime_status(RDMA_SC_INVALID_ARGUMENT,
                                 "prepared recovery image/status evidence is incomplete");
    end
    if (!route_valid || !epoch_valid || !prepared.route_valid ||
        !prepared.epoch_valid || !rdma_route_key_valid(prepared.route) ||
        !value_ops::same_route_epoch_value(prepared.route, prepared.reset_epoch,
                                route, reset_epoch)) begin
      lock.put(1);
      return value_ops::make_runtime_status(RDMA_SC_INVALID_ARGUMENT,
                                 "prepared recovery route epoch mismatch");
    end
    if (device_direction &&
        (!device_reservation_valid || !reservation_matches(prepared.cursor))) begin
      lock.put(1);
      return value_ops::make_runtime_status(RDMA_SC_INVALID_STATE,
                                 "device reservation does not match pending");
    end
    if (consumer_direction && device_reservation_valid) begin
      lock.put(1);
      return value_ops::make_runtime_status(RDMA_SC_RESOURCE_BUSY,
                                 "consumer recovery conflicts with device reservation");
    end
    if (!(prepared.mmio_evidence inside {RDMA_QUEUE_MMIO_NONE,
                                         RDMA_QUEUE_MMIO_NOT_APPLICABLE,
                                         RDMA_QUEUE_MMIO_NO_SUBMIT,
                                         RDMA_QUEUE_MMIO_SUCCESS,
                                         RDMA_QUEUE_MMIO_AMBIGUOUS})) begin
      lock.put(1);
      return value_ops::make_runtime_status(RDMA_SC_INVALID_ARGUMENT,
                                 "prepared MMIO evidence is invalid");
    end
    if ((device_direction &&
         !(prepared.mmio_evidence inside {RDMA_QUEUE_MMIO_NONE,
                                          RDMA_QUEUE_MMIO_NOT_APPLICABLE,
                                          RDMA_QUEUE_MMIO_NO_SUBMIT})) ||
        (!device_direction &&
         prepared.mmio_evidence == RDMA_QUEUE_MMIO_NOT_APPLICABLE)) begin
      lock.put(1);
      return value_ops::make_runtime_status(RDMA_SC_INVALID_STATE,
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
      return value_ops::make_runtime_status(
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
      return value_ops::make_runtime_status(RDMA_SC_INVALID_STATE,
                                 "prepared recovery phase ordering is invalid");
    end
    if (consumer_direction &&
        !consumer_recovery_invariant_locked(
          prepared, prepared.mmio_evidence, prepared.consumer_committed,
          prepared.committed_consumer_cursor)) begin
      lock.put(1);
      return value_ops::make_runtime_status(
        RDMA_SC_INVALID_STATE,
        "prepared consumer recovery violates commit invariant");
    end
    pending_operation_state = prepared;
    state = RDMA_QUEUE_RUNTIME_RECOVERY_REQUIRED;
    project_status = project_mmio_evidence_locked(prepared.mmio_evidence);
    if (!value_ops::status_is_ok(project_status)) begin
      pending_operation_state = null;
      state = RDMA_QUEUE_RUNTIME_ACTIVE;
      lock.put(1);
      return (project_status != null) ? project_status : value_ops::make_runtime_status(
        RDMA_SC_RESOURCE_EXHAUSTED,"prepared MMIO evidence projection failed");
    end
    recovery_commit_allowed = 1'b0;
    consumer_release_gate_active = 1'b0;
    recovery_retry_confirmed = 1'b0;
    lock.put(1);
    return value_ops::make_runtime_status(RDMA_SC_OK, "");
  endfunction

  // 功能：返回当前 recovery pending 的 detached clone。
  // 输入/输出及副作用：snapshot 先置 null，成功时复制。
  // 失败/边界：无 pending、非 RECOVERY_REQUIRED 或 clone 失败返回非成功，保持 null。
  function rdma_status query_pending(output rdma_queue_pending_operation snapshot);
    snapshot = null;
    return snapshot_pending(snapshot);
  endfunction

  // 功能：查询 runtime 是否持有 pending evidence。
  // 输入/输出及副作用：present 先清零，成功写 pending_operation_state != null。
  // 失败/边界：未配置或锁忙返回错误。
  function rdma_status query_has_pending(output bit present);
    rdma_status lock_status;
    present = 1'b0;
    lock_status = acquire_lock();
    if (!lock_status.ok()) return lock_status;
    if (depth == 0) begin
      lock.put(1);
      return value_ops::make_runtime_status(RDMA_SC_INVALID_STATE,
                                 "runtime is unconfigured");
    end
    present = (pending_operation_state != null);
    lock.put(1);
    return value_ops::make_runtime_status(RDMA_SC_OK, "");
  endfunction

  // 功能：返回 runtime 当前状态快照。
  // 输入/输出及副作用：runtime_state 先置 DETACHED，成功写 state。
  // 失败/边界：锁忙返回 RESOURCE_BUSY，输出保持 DETACHED。
  function rdma_status query_state(output rdma_queue_runtime_state_e runtime_state);
    rdma_status lock_status;
    runtime_state = RDMA_QUEUE_RUNTIME_DETACHED;
    lock_status = acquire_lock();
    if (!lock_status.ok()) return lock_status;
    runtime_state = state;
    lock.put(1);
    return value_ops::make_runtime_status(RDMA_SC_OK, "");
  endfunction

  // 功能：返回 set_route_epoch/copy_ring_state 锁存的 route 与 reset epoch authority 快照。
  // 输入/输出及副作用：四个输出先清零，成功写入值及有效位。
  // 失败/边界：未配置、route/epoch 无效或锁忙返回非成功；configure 本身不建立 authority。
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
      return value_ops::make_runtime_status(RDMA_SC_INVALID_STATE,
                                 "route or reset epoch is unavailable");
    end
    route_snapshot = route;
    route_snapshot_valid = 1'b1;
    epoch_snapshot = reset_epoch;
    epoch_snapshot_valid = 1'b1;
    lock.put(1);
    return value_ops::make_runtime_status(RDMA_SC_OK, "");
  endfunction

  // 功能：判断 cursor 是否与当前 device reservation 完全相等。
  // 输入/输出及副作用：只读。
  // 失败/边界：无有效 reservation、cursor 为空或 index/wrap 不等返回 0；不校验方向。
  function bit reservation_matches(rdma_queue_cursor_snapshot cursor);
    if (cursor == null || !device_reservation_valid || device_reservation == null)
      return 1'b0;
    return cursor_equal(cursor.index, cursor.wrap,
                        device_reservation.index, device_reservation.wrap);
  endfunction

  // 功能：标记 device-producer pending 已进入 write backend，保留已有 MMIO 证据。
  // 输入/输出及副作用：持锁置 device_write_attempted 并归一化兼容投影；device producer 不发 consumer doorbell，故不编码为
  //   AMBIGUOUS；不推进 PI/used、不清 reservation。
  // 失败/边界：无 pending、非 device producer、非 RECOVERY_REQUIRED 或已有 SUCCESS/AMBIGUOUS 证据返回错误；投影失败时恢复原
  //   bit。
  function rdma_status mark_pending_device_write_attempted();
    rdma_status lock_status;
    rdma_status project_status;
    rdma_queue_mmio_evidence_e prior_evidence;
    bit prior_attempted;

    lock_status = acquire_lock();
    if (!lock_status.ok()) return lock_status;
    if (pending_operation_state == null || !pending_operation_state.device_producer) begin
      lock.put(1);
      return value_ops::make_runtime_status(RDMA_SC_INVALID_STATE,
                                 "device pending is unavailable");
    end
    if (state != RDMA_QUEUE_RUNTIME_RECOVERY_REQUIRED) begin
      lock.put(1);
      return value_ops::make_runtime_status(RDMA_SC_INVALID_STATE,
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
      return value_ops::make_runtime_status(RDMA_SC_INVALID_STATE,
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
      return (project_status == null) ? value_ops::make_runtime_status(
        RDMA_SC_RESOURCE_EXHAUSTED,"MMIO evidence projection failed") : project_status;
    end
    lock.put(1);
    return value_ops::make_runtime_status(RDMA_SC_OK, "");
  endfunction

  // 功能：确认 enum 已记录 consumer doorbell 成功，且三个兼容位是 SUCCESS 的派生投影。
  // 输入/输出及副作用：只读 pending 的 mmio_evidence 与兼容位，不写证据。
  // 失败/边界：无 consumer pending、enum 非 SUCCESS 或投影不一致返回 INVALID_STATE；不能把 NONE/NO_SUBMIT/AMBIGUOUS
  //   提升为 SUCCESS。
  function rdma_status mark_pending_consumer_doorbell_succeeded();
    rdma_status lock_status;

    lock_status = acquire_lock();
    if (!value_ops::status_is_ok(lock_status)) return lock_status;
    if (pending_operation_state == null || state != RDMA_QUEUE_RUNTIME_RECOVERY_REQUIRED ||
        pending_operation_state.device_producer || pending_operation_state.producer ||
        !is_device_ring_kind(kind)) begin
      lock.put(1);
      return value_ops::make_runtime_status(RDMA_SC_INVALID_STATE,
                                 "consumer doorbell evidence is unavailable");
    end
    if (pending_operation_state.mmio_evidence != RDMA_QUEUE_MMIO_SUCCESS ||
        pending_operation_state.known_no_mmio ||
        pending_operation_state.mmio_maybe_submitted ||
        !pending_operation_state.consumer_doorbell_succeeded) begin
      lock.put(1);
      return value_ops::make_runtime_status(RDMA_SC_INVALID_STATE,
                                 "consumer doorbell success evidence is absent");
    end
    lock.put(1);
    return value_ops::make_runtime_status(RDMA_SC_OK, "");
  endfunction

  // 功能：CQ shadow write 进入外部 context adapter 前冻结“已尝试”阶段，保留 NO_SUBMIT 证据（无分配）。
  // 输入/输出及副作用：status_slot 为预分配输出槽；成功只置 attempted 位，不推进 CI/used、不写 MMIO。
  // 失败/边界：非 RECOVERY_REQUIRED、非 CQ shadow pending、重复尝试、已发布、CI 已提交或 evidence 非 NO_SUBMIT 返回 0，阶段位不变。
  function bit mark_pending_consumer_shadow_attempted_noalloc(
    rdma_status status_slot
  );
    if (status_slot == null) begin
      return 1'b0;
    end
    if (lock == null || !lock.try_get(1)) begin
      void'(rdma_status::set_fields_noalloc(
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
      void'(rdma_status::set_fields_noalloc(
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
    void'(rdma_status::set_fields_noalloc(status_slot, RDMA_SC_OK, ""));
    return 1'b1;
  endfunction

  // 功能：记录 context adapter 已写入冻结的 CQC CI/wrap payload，MMIO 证据仍为 NO_SUBMIT（无分配）。
  // 输入/输出及副作用：status_slot 为预分配槽；成功只置 published 标记，不推进 CI/used、不发 doorbell。
  // 失败/边界：shadow 未要求/未尝试、写后 pending 已提交、geometry/evidence 不符或 identity 无效返回 0。
  function bit mark_pending_consumer_shadow_published_noalloc(
    rdma_status status_slot
  );
    if (status_slot == null) begin
      return 1'b0;
    end
    if (lock == null || !lock.try_get(1)) begin
      void'(rdma_status::set_fields_noalloc(
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
      void'(rdma_status::set_fields_noalloc(
        status_slot, RDMA_SC_INVALID_STATE,
        "CQ shadow publication evidence is invalid"));
      return 1'b0;
    end
    pending_operation_state.consumer_shadow_published = 1'b1;
    lock.put(1);
    void'(rdma_status::set_fields_noalloc(status_slot, RDMA_SC_OK, ""));
    return 1'b1;
  endfunction

  // 功能：确认外部路径已完成 consumer CI commit，并保存 next_cursor 为 committed_consumer_cursor。
  // 输入/输出及副作用：仅当 runtime CI 已等于 next_cursor 时发布 consumer_committed；不改 CI/used，不代替提交。
  // 失败/边界：无 consumer pending、发布证据未完成、CI 仍在旧 cursor、分配失败或 invariant 不成立返回错误。
  function rdma_status mark_pending_consumer_committed();
    rdma_status lock_status;
    rdma_queue_cursor_snapshot staged_cursor;
    uvm_object raw_staged_cursor;

    lock_status = acquire_lock();
    if (!value_ops::status_is_ok(lock_status)) return lock_status;
    if (pending_operation_state == null || state != RDMA_QUEUE_RUNTIME_RECOVERY_REQUIRED ||
        pending_operation_state.device_producer || pending_operation_state.producer ||
        !is_device_ring_kind(kind) ||
        !consumer_publication_committed_ready_locked(
          pending_operation_state)) begin
      lock.put(1);
      return value_ops::make_runtime_status(RDMA_SC_INVALID_STATE,
                                 "consumer commit ordering is invalid");
    end
    if (pending_operation_state.cursor == null || pending_operation_state.next_cursor == null ||
        !pending_cursor_shape_valid(pending_operation_state)) begin
      lock.put(1);
      return value_ops::make_runtime_status(RDMA_SC_INVALID_ARGUMENT,
                                 "consumer cursor evidence is incomplete");
    end

    if (pending_operation_state.committed_consumer_cursor != null &&
        !cursor_equal(pending_operation_state.committed_consumer_cursor.index,
                      pending_operation_state.committed_consumer_cursor.wrap,
                      pending_operation_state.next_cursor.index,
                      pending_operation_state.next_cursor.wrap)) begin
      lock.put(1);
      return value_ops::make_runtime_status(RDMA_SC_INVALID_STATE,
                                 "committed consumer cursor is inconsistent");
    end
    if (pending_operation_state.committed_consumer_cursor == null) begin
      raw_staged_cursor = value_ops::factory_create_object_nonfatal(
        rdma_queue_cursor_snapshot::get_type(), "committed_consumer_cursor");
      if (raw_staged_cursor == null ||
          !$cast(staged_cursor, raw_staged_cursor)) begin
        lock.put(1);
        return value_ops::make_runtime_status(RDMA_SC_RESOURCE_EXHAUSTED,
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
      return value_ops::make_runtime_status(RDMA_SC_INVALID_STATE,
                                 "runtime CI has not committed consumer next cursor");
    end
    if (pending_operation_state.committed_consumer_cursor == null)
      pending_operation_state.committed_consumer_cursor = staged_cursor;
    pending_operation_state.consumer_committed = 1'b1;
    recovery_commit_allowed = 1'b0;
    lock.put(1);
    return value_ops::make_runtime_status(RDMA_SC_OK, "");
  endfunction

  // 功能：在 consumer_committed 已置位后，更新兼容别名 cq_consumer_committed。
  // 输入/输出及副作用：只改该阶段位。
  // 失败/边界：无 pending 或 consumer_committed 为零返回 INVALID_STATE，阶段位不变。
  function rdma_status mark_pending_cq_consumer_committed();
    rdma_status lock_status;

    lock_status = acquire_lock();
    if (!value_ops::status_is_ok(lock_status)) return lock_status;
    if (pending_operation_state == null || state != RDMA_QUEUE_RUNTIME_RECOVERY_REQUIRED ||
        pending_operation_state.device_producer ||
        pending_operation_state.kind != RDMA_QUEUE_RUNTIME_CQ ||
        !pending_operation_state.consumer_committed) begin
      lock.put(1);
      return value_ops::make_runtime_status(RDMA_SC_INVALID_STATE,
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
      return value_ops::make_runtime_status(
        RDMA_SC_INVALID_STATE,
        "runtime CI does not match committed CQ cursor");
    end
    pending_operation_state.cq_consumer_committed = 1'b1;
    lock.put(1);
    return value_ops::make_runtime_status(RDMA_SC_OK, "");
  endfunction

  // 设计说明：完成与中止的准入不同，但结束后都不能残留可重放的 pending、reservation
  // 或授权位；集中清理这组状态，避免某一入口遗留旧授权。不能复用 configure/admission
  // 的初始化或回滚：这些路径尚未结束一笔恢复，且需要保留不同的 reservation/authority。
  // 功能：结束已获准的恢复（完成或中止），清除 pending/reservation 与三个 gate 并发布最终 state。
  // 输入/输出及副作用：final_state 由入口选 ACTIVE 或 DETACHED；无分配；不改旧 pending 对象、游标、ledger、authority。
  // 失败/边界：调用方须已持锁并完成全部校验；本函数不拒绝、不解锁、不构造 status、不回滚已提交 CI；CQ 末次 release marker 须先发布。
  protected function void retire_recovery_locked(rdma_queue_runtime_state_e final_state);
    pending_operation_state = null;
    device_reservation_valid = 1'b0;
    device_reservation = null;
    recovery_commit_allowed = 1'b0;
    consumer_release_gate_active = 1'b0;
    recovery_retry_confirmed = 1'b0;
    state = final_state;
  endfunction

  // 功能：data engine 完成 replay 的外部阶段后，按 producer/consumer 方向验证最终证据，清除 pending 并恢复 ACTIVE。
  // 输入/输出及副作用：PI/CI/used 须已由对应 commit API 完成，此处不重复推进；校验通过后才委托无分配清理，解锁后构造 status。
  // 失败/边界：无 pending、identity stale、device PI 未到 next_cursor、host slot 未 posted 或 doorbell/CI/CQ
  //   release 阶段不全返回错误并保留证据。
  function rdma_status complete_recovery_retry();
    rdma_status lock_status;
    rdma_queue_slot_ledger_entry slot;

    lock_status = acquire_lock();
    if (!value_ops::status_is_ok(lock_status)) return lock_status;
    if (state != RDMA_QUEUE_RUNTIME_RECOVERY_REQUIRED ||
        pending_operation_state == null) begin
      lock.put(1);
      return value_ops::make_runtime_status(RDMA_SC_INVALID_STATE,
                                 "queue runtime has no pending recovery");
    end
    if (!pending_identity_matches_locked(pending_operation_state)) begin
      lock.put(1);
      return value_ops::make_runtime_status(RDMA_SC_STALE_GENERATION,
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
        return value_ops::make_runtime_status(RDMA_SC_INVALID_STATE,
                                   "device recovery evidence is invalid");
      end
      if (!pending_cursor_shape_valid(pending_operation_state)) begin
        lock.put(1);
        return value_ops::make_runtime_status(RDMA_SC_INVALID_ARGUMENT,
                                   "device recovery cursor evidence is invalid");
      end
      if (device_reservation_valid ||
          !cursor_equal(producer_index, producer_wrap,
                        pending_operation_state.next_cursor.index,
                        pending_operation_state.next_cursor.wrap)) begin
        lock.put(1);
        return value_ops::make_runtime_status(RDMA_SC_INVALID_STATE,
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
        return value_ops::make_runtime_status(RDMA_SC_INVALID_STATE,
                                   "host producer recovery stages are incomplete");
      end
      slot = slots[pending_operation_state.cursor.index];
      if (slot == null || !slot.posted || slot.consumed ||
          slot.index != pending_operation_state.cursor.index ||
          slot.wrap != pending_operation_state.cursor.wrap) begin
        lock.put(1);
        return value_ops::make_runtime_status(RDMA_SC_INVALID_STATE,
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
        return value_ops::make_runtime_status(RDMA_SC_INVALID_STATE,
                                   "consumer recovery stages are incomplete");
      end
      if (kind == RDMA_QUEUE_RUNTIME_CQ &&
          pending_operation_state.completion_target_valid &&
          !pending_operation_state.completion_released) begin
        lock.put(1);
        return value_ops::make_runtime_status(RDMA_SC_INVALID_STATE,
                                   "CQ completion release is incomplete");
      end
    end
    retire_recovery_locked(RDMA_QUEUE_RUNTIME_ACTIVE);
    lock.put(1);
    return value_ops::make_runtime_status(RDMA_SC_OK, "");
  endfunction

  // 功能：持锁执行唯一 MMIO authority 的单调转换表，并从新 enum 派生全部兼容位。
  // 输入/输出及副作用：evidence 为 backend 本次观测；成功更新 pending 的 enum/兼容位，需授权的 NO_SUBMIT 转移一次性消费
  //   recovery_retry_confirmed。
  // 失败/边界：非法 enum、方向不适用、降级、AMBIGUOUS 消解，或缺 confirmation/device_write_attempted 返回错误，状态与授权不变。
  protected function rdma_status project_mmio_evidence_locked(
    rdma_queue_mmio_evidence_e evidence
  );
    bit consume_confirmation;

    if (pending_operation_state == null || state != RDMA_QUEUE_RUNTIME_RECOVERY_REQUIRED)
      return value_ops::make_runtime_status(RDMA_SC_INVALID_STATE,
                                 "queue runtime has no pending recovery");
    if (!(evidence inside {RDMA_QUEUE_MMIO_NONE, RDMA_QUEUE_MMIO_NOT_APPLICABLE,
                           RDMA_QUEUE_MMIO_NO_SUBMIT, RDMA_QUEUE_MMIO_SUCCESS,
                           RDMA_QUEUE_MMIO_AMBIGUOUS}))
      return value_ops::make_runtime_status(RDMA_SC_INVALID_ARGUMENT,
                                 "MMIO evidence is invalid");
    if (!rdma_queue_mmio_transition_policy::decide(
          pending_operation_state.mmio_evidence, evidence,
          pending_operation_state.device_producer,
          pending_operation_state.device_write_attempted,
          recovery_retry_confirmed, consume_confirmation))
      return value_ops::make_runtime_status(RDMA_SC_INVALID_STATE,
                                 "MMIO evidence transition is unauthorized");

    pending_operation_state.mmio_evidence = evidence;
    pending_operation_state.known_no_mmio =
      (evidence inside {RDMA_QUEUE_MMIO_NOT_APPLICABLE,
                        RDMA_QUEUE_MMIO_NO_SUBMIT});
    pending_operation_state.mmio_maybe_submitted = (evidence == RDMA_QUEUE_MMIO_AMBIGUOUS);
    pending_operation_state.consumer_doorbell_succeeded = (evidence == RDMA_QUEUE_MMIO_SUCCESS);
    if (consume_confirmation)
      recovery_retry_confirmed = 1'b0;
    return value_ops::make_runtime_status(RDMA_SC_OK, "");
  endfunction

  // 功能：放弃当前 pending，把 attachment 隔离为 DETACHED，防止不确定事务对旧 queue 继续可见。
  // 输入/输出及副作用：清除 pending、device reservation、各 gate 并更新 state；委托无分配清理后解锁并构造 status；不回滚已成功 CI，不释放
  //   mapping。
  // 失败/边界：仅 RECOVERY_REQUIRED 且 pending 非空时允许，否则返回 INVALID_STATE，证据不变。
  function rdma_status abort_recovery();
    rdma_status lock_status;
    lock_status = acquire_lock();
    if (!value_ops::status_is_ok(lock_status)) return lock_status;
    if (state != RDMA_QUEUE_RUNTIME_RECOVERY_REQUIRED ||
        pending_operation_state == null) begin
      lock.put(1);
      return value_ops::make_runtime_status(RDMA_SC_INVALID_STATE,
                                 "queue runtime has no pending recovery");
    end
    retire_recovery_locked(RDMA_QUEUE_RUNTIME_DETACHED);
    lock.put(1);
    return value_ops::make_runtime_status(RDMA_SC_OK, "");
  endfunction

  // 设计说明：普通与 noalloc 入口必须在同一 runtime 锁内使用同一份恢复证据，
  //   但不能互相调用：普通 acquire 的 factory 回调在持锁时发生，最终 status 在
  //   解锁后构造；noalloc 全程不得创建对象。因此只共享证据判定和授权写入。
  // 功能：校验 MMIO 或已发布 CQC shadow 证据，打开 cursor commit gate，仅在未发布 shadow 的 no-submit 路径消费 retry 授权。
  // 输入/输出及副作用：调用方已持锁；message 输出原诊断，返回 status code；成功置 recovery_commit_allowed，必要时清
  //   recovery_retry_confirmed。
  // 失败/边界：非 recovery/无 pending、已发布 shadow 无效、NONE/AMBIGUOUS 或 NO_SUBMIT/NOT_APPLICABLE 缺
  //   confirmation 依序拒绝，授权位不变；合法 shadow 与 SUCCESS 不消费 confirmation。
  protected function rdma_status_code_e enable_recovery_commit_locked(
    output string message
  );
    if (state != RDMA_QUEUE_RUNTIME_RECOVERY_REQUIRED ||
        pending_operation_state == null) begin
      message = "queue runtime has no pending recovery";
      return RDMA_SC_INVALID_STATE;
    end
    if (pending_operation_state.consumer_shadow_required &&
        pending_operation_state.consumer_shadow_published) begin
      if (!consumer_shadow_phase_valid(pending_operation_state, 1'b1)) begin
        message = "CQ shadow publication is incomplete";
        return RDMA_SC_INVALID_STATE;
      end
    end
    else if (pending_operation_state.mmio_evidence inside {
          RDMA_QUEUE_MMIO_NONE, RDMA_QUEUE_MMIO_AMBIGUOUS}) begin
      message = "recovery commit lacks definitive MMIO evidence";
      return RDMA_SC_RECOVERY_REQUIRED;
    end
    if (!(pending_operation_state.consumer_shadow_required &&
          pending_operation_state.consumer_shadow_published) &&
        pending_operation_state.mmio_evidence inside {
          RDMA_QUEUE_MMIO_NO_SUBMIT,
          RDMA_QUEUE_MMIO_NOT_APPLICABLE}) begin
      if (!recovery_retry_confirmed) begin
        message = "recovery commit lacks retry confirmation";
        return RDMA_SC_INVALID_STATE;
      end
      recovery_retry_confirmed = 1'b0;
    end
    recovery_commit_allowed = 1'b1;
    message = "";
    return RDMA_SC_OK;
  endfunction

  // 功能：在 runtime 锁内授权后续 cursor commit，并为普通 caller 构造独立 status 对象。
  // 输入/输出及副作用：持锁调用共同规则更新 commit/retry 位，解锁后按 code/message 构造 status。
  // 失败/边界：锁忙返回 acquire 状态；证据拒绝保留既有授权位（不强制关闭已开的 gate）。
  function rdma_status enable_recovery_commit();
    rdma_status lock_status;
    rdma_status_code_e code;
    string message;

    lock_status = acquire_lock();
    if (!value_ops::status_is_ok(lock_status)) return lock_status;
    code = enable_recovery_commit_locked(message);
    lock.put(1);
    return value_ops::make_runtime_status(code, message);
  endfunction

  // 功能：用 caller 预建 status 打开一次 consumer CI commit gate（无分配）。
  // 输入/输出及副作用：status_slot 为 caller 持有；成功置 recovery_commit_allowed，未发布 shadow 的
  //   NO_SUBMIT/NOT_APPLICABLE 消费本轮 confirmation；解锁后原位写 status_slot。
  // 失败/边界：slot/lock 无效、无 pending、已发布 shadow 无效、NONE/AMBIGUOUS 或确定未提交却无 confirmation 返回 0；拒绝时
  //   gate/confirmation 不变。
  function bit enable_recovery_commit_noalloc(rdma_status status_slot);
    rdma_status_code_e code;
    string message;

    if (status_slot == null) return 1'b0;
    if (lock == null || !lock.try_get(1)) begin
      void'(rdma_status::set_fields_noalloc(
        status_slot, RDMA_SC_RESOURCE_BUSY, "queue runtime is busy"));
      return 1'b0;
    end
    code = enable_recovery_commit_locked(message);
    lock.put(1);
    void'(rdma_status::set_fields_noalloc(status_slot, code, message));
    return code == RDMA_SC_OK;
  endfunction

  // 功能：为 legacy caller 返回当前 pending 的完整 detached 值副本。
  // 输入/输出及副作用：snapshot 先置 null，成功深复制 handle、cursor、image、request、status、route/epoch 与阶段位；不改原
  //   pending。
  // 失败/边界：非 RECOVERY_REQUIRED、无 pending 或任一复制失败返回错误，snapshot 保持 null。
  function rdma_status snapshot_pending(
    output rdma_queue_pending_operation snapshot
  );
    rdma_status lock_status;
    rdma_status copy_status;
    snapshot = null;
    lock_status = acquire_lock();
    if (!value_ops::status_is_ok(lock_status)) return lock_status;
    if (state != RDMA_QUEUE_RUNTIME_RECOVERY_REQUIRED ||
        pending_operation_state == null) begin
      lock.put(1);
      return value_ops::make_runtime_status(RDMA_SC_INVALID_STATE,
                                 "queue runtime has no pending recovery");
    end
    copy_status = value_ops::clone_pending_value(pending_operation_state, snapshot);
    if (!value_ops::status_is_ok(copy_status)) begin
      lock.put(1);
      return (copy_status == null) ?
        value_ops::make_runtime_status(RDMA_SC_RESOURCE_EXHAUSTED,
                          "pending recovery snapshot clone failed") : copy_status;
    end
    lock.put(1);
    return value_ops::make_runtime_status(RDMA_SC_OK, "");
  endfunction

  // 功能：处理 retry/abort 控制动作；RETRY_PENDING 仅记录一次 caller confirmation，实际阶段由 data engine 完成。
  // 输入/输出及副作用：授权成功只置 recovery_retry_confirmed 并保持 RECOVERY_REQUIRED；abort 清除 pending 与全部 gate，与
  //   abort_recovery 共用持锁清理。
  // 失败/边界：无 pending、NONE/AMBIGUOUS、未确认或 action 非法返回对应错误；AMBIGUOUS 不可 retry，SUCCESS 授权也不得重新提交 MMIO。
  function rdma_status recover(rdma_queue_recovery_action_e action, bit caller_confirmed_no_submit=1'b0);
    rdma_status lock_status;
    rdma_queue_mmio_evidence_e evidence;

    lock_status = acquire_lock();
    if (!value_ops::status_is_ok(lock_status)) return lock_status;
    if (state != RDMA_QUEUE_RUNTIME_RECOVERY_REQUIRED ||
        pending_operation_state == null) begin
      lock.put(1);
      return value_ops::make_runtime_status(RDMA_SC_INVALID_STATE,
                                 "queue runtime has no pending recovery");
    end
    if (action == RDMA_QUEUE_RECOVERY_RETRY_PENDING) begin
      evidence = pending_operation_state.mmio_evidence;
      if (evidence == RDMA_QUEUE_MMIO_AMBIGUOUS) begin
        lock.put(1);
        return value_ops::make_runtime_status(RDMA_SC_RECOVERY_REQUIRED,
                                   "pending MMIO outcome is ambiguous");
      end
      if (!(evidence inside {RDMA_QUEUE_MMIO_NOT_APPLICABLE,
                             RDMA_QUEUE_MMIO_NO_SUBMIT,
                             RDMA_QUEUE_MMIO_SUCCESS})) begin
        lock.put(1);
        return value_ops::make_runtime_status(RDMA_SC_INVALID_STATE,
                                   "pending recovery evidence is not retryable");
      end
      if (!caller_confirmed_no_submit) begin
        lock.put(1);
        return value_ops::make_runtime_status(RDMA_SC_INVALID_ARGUMENT,
                                   "retry requires caller confirmation");
      end
      // 中文设计：caller confirmation 只记录本轮允许 retry；SUCCESS 表示 MMIO
      // 已完成，data engine 只能续做 release/CI/complete，不能再提交 doorbell。
      recovery_retry_confirmed = 1'b1;
      lock.put(1);
      return value_ops::make_runtime_status(RDMA_SC_OK, "");
    end
    if (action == RDMA_QUEUE_RECOVERY_ABORT_AND_DETACH) begin
      retire_recovery_locked(RDMA_QUEUE_RUNTIME_DETACHED);
      lock.put(1);
      return value_ops::make_runtime_status(RDMA_SC_OK, "");
    end
    lock.put(1);
    return value_ops::make_runtime_status(RDMA_SC_INVALID_ARGUMENT,
                               "recovery action is invalid");
  endfunction

  // 功能：把 backend 的真实错误字段复制到当前 pending 的 failure_status，供 status/noalloc 两条入口共用。
  // 输入/输出及副作用：成功时按值覆盖 category、code、hardware、source、identity、resource、command、wr、severity、
  //   retryable、message；不创建新 status。
  // 失败/边界：actual_failure/pending/failure_status 为空或 actual_failure 为 OK 返回 0 且不写入；调用方须先完成证据校验。
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

  // 功能：原样记录 backend MMIO enum，并可把真实 doorbell/commit/release 错误写入预分配的 failure_status。
  // 输入/输出及副作用：成功时同一锁内更新 enum/兼容投影与诊断字段，关闭旧 commit/retry gate；不推进游标。
  // 失败/边界：无 pending、非法/降级 enum、actual_failure 为成功或目标 status 缺失原子拒绝；actual_failure=null 只更新阶段。
  function rdma_status record_recovery_failure(
    rdma_queue_mmio_evidence_e evidence,
    rdma_status actual_failure = null
  );
    rdma_status lock_status;
    rdma_status project_status;
    lock_status = acquire_lock();
    if (!value_ops::status_is_ok(lock_status)) return lock_status;
    if (pending_operation_state == null || state != RDMA_QUEUE_RUNTIME_RECOVERY_REQUIRED) begin
      lock.put(1);
      return value_ops::make_runtime_status(RDMA_SC_INVALID_STATE,
                                 "queue runtime has no pending recovery");
    end
    if (!(evidence inside {RDMA_QUEUE_MMIO_NONE, RDMA_QUEUE_MMIO_NOT_APPLICABLE,
                           RDMA_QUEUE_MMIO_NO_SUBMIT, RDMA_QUEUE_MMIO_SUCCESS,
                           RDMA_QUEUE_MMIO_AMBIGUOUS})) begin
      lock.put(1);
      return value_ops::make_runtime_status(RDMA_SC_INVALID_ARGUMENT,
                                 "MMIO evidence is invalid");
    end
    if (actual_failure != null &&
        (actual_failure.ok() || pending_operation_state.failure_status == null)) begin
      lock.put(1);
      return value_ops::make_runtime_status(RDMA_SC_INVALID_ARGUMENT,
                                 "recovery failure status is invalid");
    end
    project_status = project_mmio_evidence_locked(evidence);
    if (value_ops::status_is_ok(project_status)) begin
      if (actual_failure != null)
        void'(copy_recovery_failure_status_locked(actual_failure));
      recovery_retry_confirmed = 1'b0;
      recovery_commit_allowed = 1'b0;
    end
    lock.put(1);
    return project_status != null ? project_status :
      value_ops::make_runtime_status(RDMA_SC_RESOURCE_EXHAUSTED,
                          "MMIO evidence projection failed");
  endfunction

  // 功能：consumer scheduler 返回后，把 MMIO enum 与真实阶段错误写入既有 pending（无分配）。
  // 输入/输出及副作用：status_slot 为 caller 预建错误槽；成功单调更新 enum/兼容位并覆盖 pending.failure_status。
  // 失败/边界：slot/lock 无效、无 pending、非法/降级转换、成功的 actual_failure 或缺诊断目标返回 0；拒绝不消费 confirmation、不改
  //   enum/gate。
  function bit record_recovery_failure_noalloc(
    rdma_queue_mmio_evidence_e evidence,
    rdma_status actual_failure,
    rdma_status status_slot
  );
    bit consume_confirmation;

    if (status_slot == null) return 1'b0;
    if (lock == null || !lock.try_get(1)) begin
      void'(rdma_status::set_fields_noalloc(
        status_slot, RDMA_SC_RESOURCE_BUSY, "queue runtime is busy"));
      return 1'b0;
    end
    if (state != RDMA_QUEUE_RUNTIME_RECOVERY_REQUIRED ||
        pending_operation_state == null) begin
      lock.put(1);
      void'(rdma_status::set_fields_noalloc(
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
      void'(rdma_status::set_fields_noalloc(
        status_slot, RDMA_SC_INVALID_ARGUMENT,
        "MMIO evidence is invalid"));
      return 1'b0;
    end
    if (actual_failure != null &&
        (actual_failure.ok() || pending_operation_state.failure_status == null)) begin
      lock.put(1);
      void'(rdma_status::set_fields_noalloc(
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
      void'(rdma_status::set_fields_noalloc(
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

  // 功能：consumer commit 与可选 CQ WQE release 均完成后，合并 release marker 并恢复 ACTIVE（无分配）。
  // 输入/输出及副作用：completion_released_now 表示本次外部 release 已成功；status_slot 为预建槽；成功清除
  //   pending/reservation/gate 并更新 state，解锁后原位写 status_slot。
  // 失败/边界：slot/lock 无效、identity/CI/doorbell/commit marker 不全、event 携带 CQ release 或 CQ target 未释放返回
  //   0，pending 与阶段位不变。
  function bit complete_consumer_recovery_noalloc(
    bit completion_released_now,
    rdma_status status_slot
  );
    bit release_complete;

    if (status_slot == null) return 1'b0;
    if (lock == null || !lock.try_get(1)) begin
      void'(rdma_status::set_fields_noalloc(
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
      void'(rdma_status::set_fields_noalloc(
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
        void'(rdma_status::set_fields_noalloc(
          status_slot, RDMA_SC_INVALID_STATE,
          "CQ completion release is incomplete"));
        return 1'b0;
      end
    end
    else if (completion_released_now ||
             pending_operation_state.completion_target_valid ||
             pending_operation_state.completion_released) begin
      lock.put(1);
      void'(rdma_status::set_fields_noalloc(
        status_slot, RDMA_SC_INVALID_STATE,
        "event recovery cannot publish a CQ release stage"));
      return 1'b0;
    end

    if (kind == RDMA_QUEUE_RUNTIME_CQ &&
        pending_operation_state.completion_target_valid && release_complete)
      pending_operation_state.completion_released = 1'b1;
    retire_recovery_locked(RDMA_QUEUE_RUNTIME_ACTIVE);
    lock.put(1);
    void'(rdma_status::set_fields_noalloc(status_slot, RDMA_SC_OK, ""));
    return 1'b1;
  endfunction
endclass
