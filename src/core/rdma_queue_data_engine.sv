// 目录：核心执行层 core/rdma_queue_data_engine.sv。
// 职责：实现 queue-data facade，协调 SQ/RQ/SRQ post、CQ/CEQ/AEQ device publish、
// poll、CQ resize 与 recovery，并在每个边界校验 Function、route、generation 和 epoch。
// 依赖：依赖 rdma_queue_runtime 的冻结队列状态、codec/model、resource manager、
// Host-memory/backing access、可选 context shadow reader 与 doorbell scheduler 契约；
// 全局 topology authority 只读自 binding。
// 所有权与生命周期：engine 拥有本地 attachment 索引、detached 结果和未接管 recovery
// evidence 与 detached CQ→CEQ dependency 快照；runtime、backing capability、mapping
// 与 QP route 均为非拥有引用，
// 其生命周期由 lifecycle/resource manager 或外部环境管理，detach/abort 不越权释放 mapping。
// 值边界：身份比较与 consumer 结果物化集中到 rdma_queue_data_projector；字段 helper 无分配，
//   业务 wrapper 自己决定返回 status 分配；scheduler 后仍禁止新建对象或虚拟 clone/copy。
// 消费提交：live CQ、event 与 replay 共享 doorbell evidence/CI commit 步骤；各 caller
//   仍决定 admission、shadow、幂等跳步、WQE release 和最终交付，runtime 是唯一账本 owner。
// 设备发布：写入后的四类失败共用 evidence/recovery 收尾；写前取消和 replay 各自保留边界。
//   准备阶段只生成本次调用的值记录，I/O task 统一处理准备失败取消；记录不成为第二账本。
// Resize 提交：发布前失败共享一个 rollback 出口；发布后只保留新 authority 与旧资源
//   cleanup evidence，不回滚 manager swap，也不新增候选 owner 或延迟字段快照。

// 设计说明：本层是 host 侧 queue-data facade。queue 的生命周期仍归 lifecycle
// resource 所有；engine 仅在 attachment 存活期间保存 detached runtime cursor 和
// 借用的 backing-access capability，不能反向接管外部 mapping 或队列资源。

// queue-data result models are defined in rdma_queue_data_transaction_models.sv so that
// SQ/RQ/CQ/EQ facades share detached result types without pulling runtime implementation here.

// 设计说明：queue-data engine 是 lifecycle 资源与 runtime/backing/scheduler 之间的
// 编排层。它拥有 attachment/link/recovery 索引和 detached 结果，不拥有 manager、
// binding、Host-memory、PCIe scheduler 或 mapping，并以 configure/detach 限定引用寿命。
class rdma_queue_data_engine extends uvm_object;
  `uvm_object_utils(rdma_queue_data_engine)

  // 值操作集中到无状态 projector；别名只缩短调用限定，不创建对象或改变任何 owner。
  typedef rdma_queue_data_projector value_ops;

  // 仅选择既有固定诊断文本，不推导 queue kind、route、shadow 模式或 replay authority。
  typedef enum bit [1:0] {
    CONSUMER_DIAG_CQ, CONSUMER_DIAG_EVENT, CONSUMER_DIAG_REPLAY
  } consumer_diagnostic_e;

  // 设备发布准备值只活到本次 task 结束：聚合原有局部对象/bytes，不经过 factory，
  // 不保存 runtime/access，不提前填充 candidate 的成功字段；cancel_context 为空表示
  // 准备失败时不可取消，非空时 pending 再区分 reservation-only 与完整证据两种取消。
  typedef struct {
    rdma_queue_pending_operation pending;
    rdma_queue_device_publish_result candidate;
    rdma_hw_image detached_image;
    rdma_handle detached_queue;
    byte data[];
    string cancel_context;
  } device_publish_prepared_t;

  rdma_resource_manager manager;
  rdma_function_binding binding;
  rdma_host_mem_api host_mem;
  rdma_doorbell_scheduler doorbells;
  rdma_codec_registry registry;
  // Optional read/write capability for hardware-owned context shadow
  // observations. CQC shadow publication is enabled whenever this authority
  // is present; it is independent from the SQ credit gate below.
  rdma_context_backing_api context_backing;
  // The QPC HW_DROP_DB_CNT gate is a separate hardware capability. Keeping it
  // explicit prevents a CQC-only adapter from changing SQ producer semantics.
  bit qpc_shadow_gate_enabled;
  time operation_timeout;
  // 设计说明：planner 只拥有临时分配账本；替换成功后的 mapping 仍由 lifecycle
  // queue plan 所有，engine 不得把借用的 backing 当作可释放资源。
  protected rdma_queue_backing_planner backing_planner;
  protected semaphore resize_lock;

  protected rdma_queue_data_attachment attachments[string];
  protected rdma_queue_data_qp_link qp_links[string];
  // 以不含 generation 的稳定 CQ identity 索引发布后尚未完成的旧 backing
  // 清理记录，使 Function reset 后仍能找到旧代际的 release authority。
  protected rdma_cq_resize_recovery cq_resize_recoveries[string];
  // 设计说明：device publish 的 recovery 可能在 runtime 接管前就遇到并发状态
  // 迁移失败。此时必须成对保留 detached evidence 与借用 attachment，直到调用方
  // 显式 retry 或 abort；任一项被静默丢弃都会失去 reservation 的释放 authority。
  protected rdma_queue_pending_operation unclaimed_device_recoveries[string];
  protected rdma_queue_data_attachment unclaimed_recovery_attachments[string];
  protected bit configured;
  // 最新 detached URC shadow evidence，供 recovery 检查但不转移原始对象所有权。
  rdma_queue_txn_evidence last_urc_evidence;

  // 功能：构造未配置的 queue-data engine，建立 backing planner 与单 token resize 锁，
  //   并清空 attachment、QP link、CQ resize 和 unclaimed device recovery 索引。
  // 输入/输出及副作用：name 为 UVM 对象名和 planner 名称前缀；manager/binding/
  //   memory/scheduler/codec 保持 null，configured=0，不触碰任何外部资源。
  // 失败/边界：planner factory 返回 null 时对象仍保持未配置，后续 configure 会尝试
  //   重建；未成功 configure 前所有业务入口必须拒绝，析构不释放外部 mapping。
  function new(string name = "rdma_queue_data_engine");
    super.new(name);
    manager = null;
    binding = null;
    host_mem = null;
    doorbells = null;
    registry = null;
    context_backing = null;
    qpc_shadow_gate_enabled = 1'b0;
    operation_timeout = 0;
    backing_planner = rdma_queue_backing_planner::type_id::create(
      {name, "_backing_planner"});
    resize_lock = new(1);
    attachments.delete();
    qp_links.delete();
    cq_resize_recoveries.delete();
    unclaimed_device_recoveries.delete();
    unclaimed_recovery_attachments.delete();
    last_urc_evidence = null;
    configured = 1'b0;
  endfunction

  // 功能：把 CQ flush 产生的 URC shadow 捕获为 queue-data engine 的可恢复事务证据，
  //   通过 raw factory 把 evidence 的 null/错误动态类型降级为普通状态。
  // 输入/输出及副作用：shadow 为输入；成功时新建并保存 last_urc_evidence 的 detached
  //   快照，不释放或修改外部 runtime；candidate 在发布前始终只存在于局部变量。
  // 失败/边界：shadow 为空、evidence factory 返回 null/不可 cast、capture 返回 null
  //   或失败时返回确定错误，既有 last_urc_evidence 保持不变且不触发 typed-factory fatal。
  function rdma_status capture_urc_shadow_evidence(rdma_cq_shadow_snapshot shadow);
    rdma_queue_txn_evidence candidate;
    uvm_object raw_candidate;
    rdma_status status;
    if (shadow == null)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "URC CQ shadow evidence is null");
    raw_candidate = value_ops::factory_create_object_nonfatal(
      rdma_queue_txn_evidence::get_type(), "urc_shadow_evidence");
    if (raw_candidate == null || !$cast(candidate, raw_candidate))
      return rdma_status::make_direct(
        RDMA_SC_RESOURCE_EXHAUSTED,
        "URC CQ shadow evidence allocation returned null or an incompatible type");
    status = candidate.capture_urc_shadow(shadow);
    if (status == null)
      return rdma_status::make_direct(
        RDMA_SC_INVALID_STATE,
        "URC CQ shadow evidence capture returned null status");
    if (!status.ok())
      return status;
    last_urc_evidence = candidate;
    return rdma_status::make_direct(RDMA_SC_OK);
  endfunction

  // 功能：bad 把调用方指定的错误码与诊断文本封装为新的 rdma_status。
  // 输入/输出及副作用：message、code 为输入；返回独立 status，不修改 engine、
  //   runtime、backing 或 recovery evidence，也不取得 message 来源对象的所有权。
  // 失败/边界：code 缺省为 INVALID_ARGUMENT；本 helper 不做重试或错误码推断，
  //   factory 分配语义沿用 rdma_status::make，关键 non-fatal 路径使用专用 helper。
  protected function rdma_status bad(
    string message,
    rdma_status_code_e code = RDMA_SC_INVALID_ARGUMENT
  );
    return rdma_status::make(code, message);
  endfunction

  // 功能：lookup_codec_checked 在统一 registry 边界查找完整 codec key，并保证
  //   成功返回时 status 与 codec 都非空，供 host producer 与三类 consumer 共用。
  // 输入/输出及副作用：key/operation_context 为输入，codec 输出先置 null；只读取 registry，
  //   不修改 codec 注册、runtime、backing、cursor 或 recovery evidence。
  // 失败/边界：registry 缺失、lookup 返回 null status，或成功但 codec=null 时
  //   均返回确定性的 CODEC_ERROR；registry 的非成功非空 status 原样传播。
  protected function rdma_status lookup_codec_checked(
    rdma_codec_key key,
    string operation_context,
    output rdma_codec_base codec
  );
    rdma_status status;

    codec = null;
    if (registry == null)
      return bad({operation_context, " codec registry is unavailable"},
                 RDMA_SC_CODEC_ERROR);
    status = registry.lookup(key, codec);
    if (status == null)
      return bad({operation_context, " codec lookup returned null status"},
                 RDMA_SC_CODEC_ERROR);
    if (!status.ok()) return status;
    if (codec == null)
      return bad({operation_context, " codec lookup returned null codec"},
                 RDMA_SC_CODEC_ERROR);
    return status;
  endfunction

  // 功能：advance_queue_cursor_value 为 queue-data engine 保留兼容 wrapper，把
  //   producer/consumer 下一槽位计算转发给 detached cursor policy。
  // 输入/输出及副作用：depth/source_index/source_wrap 为输入；next_index/next_wrap
  //   为输出；wrapper 不读取或修改 runtime、pending、backing、ledger 和 scheduler。
  // 失败/边界：depth=0 或 source_index 越界仍由 policy 给出原算术结果，geometry
  //   拒绝必须由 caller 自己完成；该输出不代表已授权 reservation 或 commit。
  protected function void advance_queue_cursor_value(
    int unsigned depth,
    int unsigned source_index,
    bit source_wrap,
    output int unsigned next_index,
    output bit next_wrap
  );
    rdma_queue_cursor_policy::advance(
      depth, source_index, source_wrap, next_index, next_wrap);
  endfunction

  // 功能：make_next_poll_cursor_nonfatal 根据 runtime 的 ring depth 和已冻结的
  //   consumer cursor 计算下一槽位，并复用 make_poll_cursor_nonfatal 物化 CQ/CEQ/AEQ
  //   poll 使用的 detached cursor 快照，集中维护环回与 wrap 翻转规则。
  // 输入/输出及副作用：runtime、cursor、label 为输入，copy 先置 null；函数只读取
  //   runtime.depth、cursor.index 和 cursor.wrap，成功时透传底层 cursor factory 的
  //   status，不修改 runtime、pending、backing、ledger 或 scheduler。
  // 失败/边界：runtime/cursor 为空、depth 为零或 cursor.index 越界时返回
  //   INVALID_ARGUMENT；index 到达 depth 边界时 next index 归零并翻转 wrap，其余
  //   情况递增 index；底层 raw factory 返回 null/错误类型时原样返回其
  //   RESOURCE_EXHAUSTED 语义且 copy 保持 null。
  protected function rdma_status make_next_poll_cursor_nonfatal(
    rdma_queue_runtime runtime,
    rdma_queue_cursor_snapshot cursor,
    string label,
    output rdma_queue_cursor_snapshot copy
  );
    int unsigned next_index;
    bit next_wrap;

    copy = null;
    if (runtime == null || cursor == null)
      return value_ops::make_status_nonfatal(
        RDMA_SC_INVALID_ARGUMENT,
        {label, " runtime or cursor is null"});
    if (runtime.depth == 0 || cursor.index >= runtime.depth)
      return value_ops::make_status_nonfatal(
        RDMA_SC_INVALID_ARGUMENT,
        {label, " cursor geometry is invalid"});

    advance_queue_cursor_value(runtime.depth, cursor.index, cursor.wrap,
                               next_index, next_wrap);
    return value_ops::make_poll_cursor_nonfatal(next_index, next_wrap, label, copy);
  endfunction

  // 功能：prepare_consumer_pending 在 consumer scheduler 前构造可由 runtime 直接
  //   接管的完整 detached evidence，冻结 queue/cursor/image/route/epoch 与 CQ target。
  // 输入/输出及副作用：attachment、cursor、next、entry image/offset、completion
  //   target、completion_wq_kind、routed_qp_h 为输入，pending 先置 null；只分配本地值并只读 runtime authority。
  // 失败/边界：identity、geometry、route/epoch 或任一 pending/nested raw allocation
  //   不完整时返回非成功；不 admission、不调用 scheduler，也不修改 backing/CI/ledger。
  protected function rdma_status prepare_consumer_pending(
    rdma_queue_data_attachment attachment,
    rdma_queue_cursor_snapshot cursor,
    rdma_queue_cursor_snapshot next,
    longint unsigned entry_offset,
    rdma_hw_image entry_image,
    int unsigned completion_index,
    bit completion_wrap,
    bit completion_target_valid,
    rdma_queue_runtime_kind_e completion_wq_kind,
    rdma_handle routed_qp_h,
    output rdma_queue_pending_operation pending
  );
    rdma_queue_pending_operation candidate;
    rdma_handle queue_copy;
    rdma_handle routed_qp_copy;
    rdma_queue_cursor_snapshot cursor_copy;
    rdma_queue_cursor_snapshot next_copy;
    rdma_hw_image image_copy;
    rdma_status sentinel_source;
    rdma_status sentinel_copy;
    rdma_status local_status;
    rdma_route_key_t route;
    rdma_reset_epoch_t epoch;
    bit route_valid;
    bit epoch_valid;
    uvm_object raw_candidate;

    pending = null;
    if (attachment == null || attachment.runtime == null ||
        attachment.queue_h == null || cursor == null || next == null ||
        entry_image == null || attachment.entry_size == 0 ||
        cursor.index >= attachment.runtime.depth ||
        next.index >= attachment.runtime.depth ||
        entry_offset != longint'(cursor.index) * attachment.entry_size)
      return value_ops::make_status_nonfatal(
        RDMA_SC_INVALID_ARGUMENT, "consumer pending input is incomplete");
    if (completion_target_valid &&
        (!(completion_wq_kind inside {RDMA_QUEUE_RUNTIME_SQ,
                                      RDMA_QUEUE_RUNTIME_RQ,
                                      RDMA_QUEUE_RUNTIME_SRQ}) ||
         routed_qp_h == null || routed_qp_h.kind != RDMA_RESOURCE_QP))
      return value_ops::make_status_nonfatal(
        RDMA_SC_INVALID_ARGUMENT,
        "CQ completion target route or WQ kind is invalid");

    raw_candidate = value_ops::factory_create_object_nonfatal(
      rdma_queue_pending_operation::get_type(), "prepared_consumer_pending");
    if (raw_candidate == null || !$cast(candidate, raw_candidate))
      return value_ops::make_status_nonfatal(
        RDMA_SC_RESOURCE_EXHAUSTED, "consumer pending allocation failed");
    local_status = value_ops::clone_poll_handle_nonfatal(
      attachment.queue_h, "consumer pending queue", queue_copy);
    if (local_status == null || !local_status.ok()) return local_status;
    local_status = value_ops::make_poll_cursor_nonfatal(
      cursor.index, cursor.wrap, "consumer pending old", cursor_copy);
    if (local_status == null || !local_status.ok()) return local_status;
    local_status = value_ops::make_poll_cursor_nonfatal(
      next.index, next.wrap, "consumer pending next", next_copy);
    if (local_status == null || !local_status.ok()) return local_status;
    local_status = value_ops::clone_poll_image_nonfatal(entry_image, image_copy);
    if (local_status == null || !local_status.ok()) return local_status;
    routed_qp_copy = null;
    if (routed_qp_h != null) begin
      local_status = value_ops::clone_poll_handle_nonfatal(
        routed_qp_h, "consumer pending routed QP", routed_qp_copy);
      if (local_status == null || !local_status.ok()) return local_status;
    end
    sentinel_source = value_ops::make_status_nonfatal(
      RDMA_SC_INVALID_STATE, "consumer transaction has not completed");
    local_status = value_ops::allocate_poll_status_nonfatal(
      sentinel_source, "consumer pending failure", sentinel_copy);
    if (local_status == null || !local_status.ok()) return local_status;
    route = '0;
    route_valid = 1'b0;
    epoch = '0;
    epoch_valid = 1'b0;
    local_status = attachment.runtime.query_route_epoch(
      route, route_valid, epoch, epoch_valid);
    if (local_status == null || !local_status.ok() || !route_valid ||
        !epoch_valid || !rdma_route_key_valid(route))
      return local_status == null || local_status.ok() ?
        value_ops::make_status_nonfatal(
          RDMA_SC_INVALID_STATE, "consumer pending route/epoch is unavailable") :
        local_status;

    candidate.queue_h = queue_copy;
    candidate.kind = attachment.kind;
    candidate.producer = 1'b0;
    candidate.device_producer = 1'b0;
    candidate.device_write_attempted = 1'b0;
    candidate.consumer_committed = 1'b0;
    candidate.cq_consumer_committed = 1'b0;
    candidate.completion_released = 1'b0;
    candidate.consumer_doorbell_succeeded = 1'b0;
    candidate.consumer_shadow_required = 1'b0;
    candidate.consumer_shadow_urc = 1'b0;
    candidate.consumer_shadow_attempted = 1'b0;
    candidate.consumer_shadow_published = 1'b0;
    candidate.consumer_shadow_offset = 0;
    candidate.consumer_shadow_length = 0;
    candidate.consumer_shadow_value = 0;
    candidate.entry_offset = entry_offset;
    candidate.cursor = cursor_copy;
    candidate.next_cursor = next_copy;
    candidate.committed_consumer_cursor = null;
    candidate.image = image_copy;
    candidate.request_snapshot = null;
    candidate.wr_id = 0;
    candidate.signaled = 1'b0;
    candidate.completion_index = completion_index;
    candidate.completion_wrap = completion_wrap;
    candidate.completion_target_valid = completion_target_valid;
    candidate.completion_wq_kind = completion_wq_kind;
    candidate.routed_qp_h = routed_qp_copy;
    candidate.mmio_maybe_submitted = 1'b0;
    candidate.known_no_mmio = 1'b0;
    candidate.mmio_evidence = RDMA_QUEUE_MMIO_NONE;
    candidate.failure_status = sentinel_copy;
    candidate.entry_size = attachment.entry_size;
    candidate.route = route;
    candidate.route_valid = 1'b1;
    candidate.reset_epoch = epoch;
    candidate.epoch_valid = 1'b1;
    pending = candidate;
    return value_ops::make_status_nonfatal(RDMA_SC_OK, "");
  endfunction

  // 功能：collect_reservation_only_candidates 按当前 queue 的完整 incarnation 从
  //   engine attachment 索引收集 reservation-only recovery 的候选 runtime，供
  //   recover_queue 逐个执行原有 reservation evidence 查询。
  // 输入/输出及副作用：queue_h 为只读目标句柄，candidates 为输出队列；函数按
  //   attachments 的 foreach 顺序保存通过 attachment_matches_queue_identity 且
  //   runtime 非空的非拥有 attachment 引用，不查询 runtime 状态或 reservation，
  //   不修改 attachment、runtime、索引、cursor、ledger 或外部资源生命周期。
  // 失败/边界：queue_h 为空或没有匹配项时输出空队列并静默返回；identity 不匹配、
  //   candidate 为空或 candidate.runtime 为空均跳过。函数不判定候选是否真的持有
  //   reservation、不报告多候选、不改变候选顺序，调用方必须保留后续 query/action/
  //   detach 的首错优先级和 reservation evidence 生命周期。
  protected function void collect_reservation_only_candidates(
    rdma_handle queue_h,
    output rdma_queue_data_attachment candidates[$]
  );
    rdma_queue_data_attachment candidate;
    string scan_key;

    candidates.delete();
    if (queue_h == null)
      return;

    foreach (attachments[scan_key]) begin
      candidate = attachments[scan_key];
      if (!value_ops::attachment_matches_queue_identity(candidate, queue_h) ||
          candidate == null || candidate.runtime == null)
        continue;
      candidates.push_back(candidate);
    end
  endfunction

  // 功能：find_claimed_recovery_attachment 在 engine-owned attachment 索引中查找
  //   与 recover_queue 目标 queue 完整 identity 相同、且 runtime 已声明
  //   RECOVERY_REQUIRED 的 claimed recovery；它只负责收集候选，不执行恢复动作。
  // 输入/输出及副作用：queue_h 为只读目标句柄，found 输出唯一命中的 attachment；
  //   返回 status 表示扫描或多 runtime 判定结果。函数只读取 attachments、candidate
  //   的 queue_h/runtime/state，不查询 pending/reservation，不修改 runtime、索引、账本，
  //   也不访问 Host-memory、MMIO 或外部 mapping。
  // 失败/边界：queue_h 为空时返回 INVALID_ARGUMENT；identity 不匹配、candidate 或
  //   runtime 为空、runtime 非 RECOVERY_REQUIRED 均跳过；没有命中返回成功且 found=null，
  //   由 caller 继续 reservation-only 扫描；同一完整 identity 命中不同 runtime 时返回
  //   INVALID_STATE，调用方必须保留 unclaimed handoff 的原有 authority 和错误优先级。
  protected function rdma_status find_claimed_recovery_attachment(
    rdma_handle queue_h,
    output rdma_queue_data_attachment found
  );
    rdma_queue_data_attachment candidate;
    string scan_key;

    found = null;
    if (queue_h == null)
      return bad("claimed recovery queue handle is missing",
                 RDMA_SC_INVALID_ARGUMENT);

    foreach (attachments[scan_key]) begin
      candidate = attachments[scan_key];
      if (!value_ops::attachment_matches_queue_identity(candidate, queue_h) ||
          candidate == null || candidate.runtime == null ||
          candidate.runtime.state != RDMA_QUEUE_RUNTIME_RECOVERY_REQUIRED)
        continue;
      if (found != null && found != candidate)
        return bad("queue has multiple pending recovery runtimes",
                   RDMA_SC_INVALID_STATE);
      found = candidate;
    end
    return rdma_status::success();
  endfunction

  // 功能：record_candidate_cleanup_recovery 登记发布前候选 backing 的
  //       opaque release authority，供后续 retry 清理而不覆盖当前 CQ。
  // 输入/输出及副作用：cq_h/new_ref/original_status 为输入；成功时新增
  //       engine-owned recovery record，不修改 manager、attachment 或 runtime。
  // 失败/边界：句柄、binding、ref 或 Function identity 缺失、记录键冲突或
  //       recovery 对象创建失败时返回 RECOVERY_REQUIRED，绝不静默丢弃 ref。
  protected function rdma_status record_candidate_cleanup_recovery(
    rdma_handle cq_h,
    rdma_queue_backing_ref new_ref,
    rdma_status original_status
  );
    rdma_cq_resize_recovery recovery;
    string key;

    if (cq_h == null || new_ref == null || binding == null)
      return bad("CQ candidate cleanup recovery inputs are incomplete",
                 RDMA_SC_RECOVERY_REQUIRED);
    key = value_ops::cq_recovery_key(cq_h);
    if (key == "")
      return bad("CQ candidate cleanup recovery key is invalid",
                 RDMA_SC_RECOVERY_REQUIRED);
    if (cq_resize_recoveries.exists(key))
      return bad("CQ candidate cleanup recovery key is already present",
                 RDMA_SC_RECOVERY_REQUIRED);
    recovery = rdma_cq_resize_recovery::type_id::create(
      "cq_candidate_cleanup_recovery");
    if (recovery == null)
      return bad("CQ candidate cleanup recovery allocation failed",
                 RDMA_SC_RECOVERY_REQUIRED);
    recovery.cq_h = rdma_clone_handle_value(
      cq_h, "CQ candidate cleanup recovery CQ");
    if (recovery.cq_h == null)
      return bad("CQ candidate cleanup recovery handle snapshot failed",
                 RDMA_SC_RECOVERY_REQUIRED);
    recovery.function_identity = binding.function_identity_snapshot();
    if (recovery.function_identity == null)
      return bad("CQ candidate cleanup Function identity snapshot failed",
                 RDMA_SC_RECOVERY_REQUIRED);
    recovery.pending_ref = new_ref;
    recovery.published = 1'b0;
    recovery.prepublish_restore_pending = 1'b0;
    recovery.manager_restore_pending = 1'b0;
    recovery.cq_restore_pending = 1'b0;
    if (new_ref.mapping == null || !new_ref.mapping.epoch_valid) begin
      return bad("CQ candidate cleanup mapping epoch is missing",
                 RDMA_SC_RECOVERY_REQUIRED);
    end
    if (new_ref.ownership != RDMA_OWNERSHIP_CONTROL_PLANE ||
        new_ref.cleanup_complete) begin
      return bad("CQ candidate cleanup ownership/state is invalid",
                 RDMA_SC_RECOVERY_REQUIRED);
    end
    recovery.backing_role = new_ref.role;
    recovery.backing_mapping_offset = new_ref.mapping_offset;
    recovery.backing_length = new_ref.length;
    recovery.backing_logical_queue_offset = new_ref.logical_queue_offset;
    recovery.backing_geometry_valid = 1'b1;
    recovery.backing_reset_epoch = new_ref.mapping.reset_epoch;
    recovery.backing_epoch_valid = 1'b1;
    recovery.last_status = original_status;
    cq_resize_recoveries[key] = recovery;
    return rdma_status::success();
  endfunction

  // 功能：record_prepublish_recovery 保存 manager/CQ 屏障及 dependent
  //       runtime 的未完成恢复，必要时合并到已有候选 cleanup 记录。
  // 输入/输出及副作用：cq_h/old_runtime/dependents/restore flags/original_status
  //       为输入；成功时写入 engine-owned recovery 表，不释放或替换任何资源。
  // 失败/边界：Function identity、CQ identity 或 recovery key 不完整时返回
  //       RECOVERY_REQUIRED；已有 published 记录不会被覆盖，避免跨阶段串账。
  protected function rdma_status record_prepublish_recovery(
    rdma_handle cq_h,
    rdma_queue_runtime old_runtime,
    rdma_queue_runtime dependents[$],
    bit manager_restore_pending,
    bit cq_restore_pending,
    rdma_status original_status
  );
    rdma_cq_resize_recovery recovery;
    string key;
    bit dependent_pending;

    dependent_pending = 1'b0;
    foreach (dependents[i]) begin
      if (dependents[i] != null &&
          dependents[i].state == RDMA_QUEUE_RUNTIME_QUIESCING)
        dependent_pending = 1'b1;
    end
    if (!manager_restore_pending && !cq_restore_pending &&
        !dependent_pending)
      return rdma_status::success();
    if (cq_h == null || binding == null)
      return bad("CQ pre-publish recovery inputs are incomplete",
                 RDMA_SC_RECOVERY_REQUIRED);
    key = value_ops::cq_recovery_key(cq_h);
    if (key == "")
      return bad("CQ pre-publish recovery key is invalid",
                 RDMA_SC_RECOVERY_REQUIRED);
    if (cq_resize_recoveries.exists(key)) begin
      recovery = cq_resize_recoveries[key];
      if (recovery == null || recovery.published)
        return bad("CQ pre-publish recovery stage is inconsistent",
                   RDMA_SC_RECOVERY_REQUIRED);
    end
    else begin
      recovery = rdma_cq_resize_recovery::type_id::create(
        "cq_prepublish_recovery");
      if (recovery == null)
        return bad("CQ pre-publish recovery allocation failed",
                   RDMA_SC_RECOVERY_REQUIRED);
      recovery.cq_h = rdma_clone_handle_value(
        cq_h, "CQ pre-publish recovery CQ");
      if (recovery.cq_h == null)
        return bad("CQ pre-publish recovery handle snapshot failed",
                   RDMA_SC_RECOVERY_REQUIRED);
      recovery.function_identity = binding.function_identity_snapshot();
      if (recovery.function_identity == null)
        return bad("CQ pre-publish Function identity snapshot failed",
                   RDMA_SC_RECOVERY_REQUIRED);
      recovery.published = 1'b0;
      recovery.pending_ref = null;
    end
    recovery.old_runtime = old_runtime;
    recovery.manager_restore_pending = manager_restore_pending;
    recovery.cq_restore_pending = cq_restore_pending;
    recovery.prepublish_restore_pending = 1'b1;
    recovery.dependents.delete();
    foreach (dependents[i])
      if (dependents[i] != null)
        recovery.dependents.push_back(dependents[i]);
    recovery.last_status = original_status;
    cq_resize_recoveries[key] = recovery;
    return rdma_status::success();
  endfunction

  // 功能：recovery_backing_matches 校验 recovery ref 的 opaque identity、
  //       Function/CQ owner、完整 route 和原始 mapping epoch。
  // 输入/输出及副作用：ref_value/recovery 为输入；只读检查，不修改 ref、
  //       manager 或 Host-memory；返回 bit 供 retry 决定是否允许释放。
  // 失败/边界：任一 authority 字段缺失、被篡改、route 不一致或 epoch 改变时返回 0，
  //       防止 identity 重用时释放错误 backing。
  protected function bit recovery_backing_matches(
    rdma_queue_backing_ref ref_value,
    rdma_cq_resize_recovery recovery
  );
    rdma_dma_mapping mapping;
    rdma_route_key_t expected_route;

    if (ref_value == null || recovery == null ||
        recovery.function_identity == null ||
        recovery.cq_h == null || ref_value.mapping == null ||
        !recovery.backing_epoch_valid || !recovery.backing_geometry_valid)
      return 1'b0;
    if (ref_value.ownership != RDMA_OWNERSHIP_CONTROL_PLANE ||
        ref_value.cleanup_complete ||
        ref_value.role != recovery.backing_role ||
        ref_value.mapping_offset != recovery.backing_mapping_offset ||
        ref_value.length != recovery.backing_length ||
        ref_value.logical_queue_offset !=
          recovery.backing_logical_queue_offset)
      return 1'b0;
    mapping = ref_value.mapping;
    expected_route = recovery.function_identity.route_key();
    if (!mapping.route_valid || !rdma_route_key_valid(mapping.route) ||
        !value_ops::same_route(mapping.route, expected_route) ||
        !mapping.epoch_valid ||
        mapping.reset_epoch != recovery.backing_reset_epoch ||
        mapping.function_h == null ||
        mapping.function_h.kind != RDMA_RESOURCE_FUNCTION ||
        mapping.function_h.function_uid !=
          recovery.function_identity.function_uid ||
        mapping.function_h.object_id !=
          recovery.function_identity.global_function_id ||
        mapping.owner_h == null ||
        !value_ops::same_cq_recovery_identity(mapping.owner_h, recovery.cq_h))
      return 1'b0;
    return 1'b1;
  endfunction

  // 功能：find_cq_recovery_attachment 在 attachment 表中按稳定 CQ identity
  // 找到当前已发布的新 attachment，避免 reset 改变 generation 后直接拼接旧 key。
  // 输入/输出及副作用：recovery 为输入，attachment/attachment_key_value 为输出；
  // 函数只读 engine 索引，不改变 runtime、manager 或 Host-memory 所有权。
  // 失败/边界：找不到 attachment 或发现多个同身份 attachment 时返回 RECOVERY_REQUIRED，
  // 防止 retry 在 authority 不明确时释放错误 backing。
  protected function rdma_status find_cq_recovery_attachment(
    rdma_cq_resize_recovery recovery,
    output rdma_queue_data_attachment attachment,
    output string attachment_key_value
  );
    rdma_queue_data_attachment candidate;
    string scan_key;

    attachment = null;
    attachment_key_value = "";
    if (recovery == null || recovery.cq_h == null)
      return bad("CQ resize recovery CQ identity is missing",
                 RDMA_SC_RECOVERY_REQUIRED);
    foreach (attachments[scan_key]) begin
      candidate = attachments[scan_key];
      if (candidate == null || candidate.queue_h == null ||
          !value_ops::same_cq_recovery_identity(candidate.queue_h, recovery.cq_h))
        continue;
      if (attachment != null)
        return bad("CQ resize recovery attachment identity is ambiguous",
                   RDMA_SC_RECOVERY_REQUIRED);
      attachment = candidate;
      attachment_key_value = scan_key;
    end
    if (attachment == null)
      return bad("CQ resize recovery attachment is missing",
                 RDMA_SC_RECOVERY_REQUIRED);
    return rdma_status::success();
  endfunction

  // 功能：ensure_handle 校验业务 handle 属于当前已配置 Function/generation 且
  //   resource kind 与调用入口要求一致。
  // 输入/输出及副作用：handle、expected_kind 为输入；只读 configured/binding 和
  //   handle 身份，返回 status，不创建、投影或保存 handle。
  // 失败/边界：engine 未配置/binding 缺失返回 INVALID_STATE，null 或 kind/Function
  //   不符返回 INVALID_ARGUMENT，generation 不同返回 STALE_GENERATION；状态均不变。
  protected function rdma_status ensure_handle(
    rdma_handle handle, rdma_resource_kind_e expected_kind
  );
    if (!configured)
      return bad("queue data engine is not configured", RDMA_SC_INVALID_STATE);
    if (handle == null || handle.kind != expected_kind)
      return bad("queue handle kind is invalid");
    if (binding == null)
      return bad("queue data engine has no Function binding",
                 RDMA_SC_INVALID_STATE);
    if (handle.function_uid != binding.function_uid ||
        handle.generation != binding.generation)
      return bad("queue handle Function or generation is stale",
                 handle.generation == binding.generation ?
                 RDMA_SC_INVALID_ARGUMENT : RDMA_SC_STALE_GENERATION);
    return rdma_status::success();
  endfunction

  // 功能：lookup_attachment 按完整 handle/kind key 返回 engine 索引的借用
  //   attachment，供同一 engine 内的 publish/poll/recovery 使用。
  // 输入/输出及副作用：handle、kind 为输入，attachment 为输出；成功时输出仅是
  //   非拥有引用，不复制 runtime/access，也不验证 route、reset epoch 或 backing。
  // 失败/边界：handle 校验、索引缺失、runtime/access 不完整时返回非成功 status；
  //   调用方须在需要时另行执行冻结 route/epoch 与具体 backing authority 校验。
  protected function rdma_status lookup_attachment(
    rdma_handle handle, rdma_queue_runtime_kind_e kind,
    output rdma_queue_data_attachment attachment
  );
    rdma_status status;
    attachment = null;
    status = ensure_handle(handle, handle == null ? RDMA_RESOURCE_QP :
                           handle.kind);
    if (!status.ok()) return status;
    if (!attachments.exists(value_ops::attachment_key(handle, kind)) ||
        attachments[value_ops::attachment_key(handle, kind)] == null)
      return bad("queue is not attached", RDMA_SC_INVALID_STATE);
    attachment = attachments[value_ops::attachment_key(handle, kind)];
    if (attachment.runtime == null || attachment.access == null)
      return bad("queue attachment is incomplete", RDMA_SC_INVALID_STATE);
    return rdma_status::success();
  endfunction

  // 功能：snapshot_attachment_route_epoch 读取 attachment runtime 锁存的 route/epoch，
  //   并与当前 binding 的 detached identity 比较后，把通过校验的旧 authority 输出
  //   给 producer admission 用作 recovery evidence。
  // 输入/输出及副作用：attachment 为非拥有输入；route、epoch、valid 位为输出；
  //   函数只读取 binding/runtime 快照，不预留 cursor、不访问 backing 或修改 ownership。
  // 失败/边界：attachment/binding/identity 缺失、query 返回 null、route/epoch 无效或
  //   与当前 identity 不同返回明确非成功 status；失败时输出清零，调用方不得把
  //   部分快照交给 pending 或队列副作用阶段。
  protected function rdma_status snapshot_attachment_route_epoch(
    rdma_queue_data_attachment attachment,
    output rdma_route_key_t route,
    output rdma_reset_epoch_t epoch,
    output bit route_valid,
    output bit epoch_valid
  );
    rdma_function_identity identity;
    rdma_status status;

    route = '0;
    epoch = '0;
    route_valid = 1'b0;
    epoch_valid = 1'b0;
    if (attachment == null || attachment.runtime == null || binding == null)
      return bad("attachment route authority is incomplete", RDMA_SC_INVALID_STATE);
    identity = binding.function_identity_snapshot();
    if (identity == null)
      return bad("attachment Function identity snapshot is unavailable",
                 RDMA_SC_INVALID_STATE);
    status = identity.validate();
    if (status == null || !status.ok())
      return status == null ?
        bad("attachment Function identity validation returned null status",
            RDMA_SC_INVALID_STATE) : status;
    status = attachment.runtime.query_route_epoch(route, route_valid, epoch,
                                                  epoch_valid);
    if (status == null || !status.ok())
      return status == null ?
        bad("attachment runtime route query returned null status",
            RDMA_SC_INVALID_STATE) : status;
    if (!route_valid || !epoch_valid ||
        !value_ops::same_route(route, identity.route_key()) ||
        epoch != identity.reset_epoch)
      return bad("attachment route or reset epoch is stale",
                 RDMA_SC_STALE_GENERATION);
    return rdma_status::success();
  endfunction

  // 功能：validate_attachment_route_epoch 对比 attachment runtime 冻结的 route/epoch
  //   与当前 binding detached identity，阻止复位或换路后的旧 attachment 继续读写队列。
  // 输入/输出及副作用：attachment 为输入；函数只读取 runtime、binding snapshot 和
  //   临时 authority 输出，不预留 cursor、不访问 backing、不修改任何 ownership。
  // 失败/边界：attachment/binding/identity 缺失、query 返回 null、route/epoch 无效
  //   或 same_route/epoch 比较失败时返回明确非成功 status，调用方必须在首次队列
  //   副作用前停止；same_route 只比较 route 字段，不替代 valid 位与身份校验。
  protected function rdma_status validate_attachment_route_epoch(
    rdma_queue_data_attachment attachment
  );
    rdma_route_key_t route;
    rdma_reset_epoch_t epoch;
    bit route_valid;
    bit epoch_valid;

    return snapshot_attachment_route_epoch(
      attachment, route, epoch, route_valid, epoch_valid);
  endfunction

  // 设计说明：SQ、私有 RQ 与共享 SRQ 都必须在第一次 producer 副作用前重新确认
  //   attachment 冻结的 Function route/reset epoch；这项 admission 与后续
  //   reserve_producer 的 runtime 锁边界相邻，但不应散落在各 posting caller 中。
  //   将两步收束在这里，保证发送和接收都不会在 stale binding 上先拿到可写 cursor。
  // 功能：reserve_host_producer_cursor 先校验 attachment 的 route/epoch，再从其
  //   host-producer runtime 取得 detached producer cursor，供 WQE 编码与完成尾段使用。
  // 输入/输出及副作用：attachment 为 engine-owned 的非拥有引用；cursor 为输出，成功
  //   时保存当前 producer index/wrap 的独立快照。函数只读取 binding/runtime authority
  //   并调用一次 reserve_producer，不访问 Host-memory、doorbell、ledger 或 pending。
  // 失败/边界：attachment/runtime 缺失、route/epoch 查询或比较失败、runtime 非 ACTIVE、
  //   device ring、ring 满、锁忙或 reservation factory 失败时返回对应非成功 status，
  //   cursor 保持 null；validate_attachment_route_epoch 的 stale 结果优先于任何
  //   reservation 失败，确保 caller 在首个副作用前 fail-closed。
  protected function rdma_status reserve_host_producer_cursor(
    rdma_queue_data_attachment attachment,
    output rdma_queue_cursor_snapshot cursor,
    output rdma_route_key_t reservation_route,
    output rdma_reset_epoch_t reservation_epoch,
    output bit reservation_route_valid,
    output bit reservation_epoch_valid
  );
    rdma_status status;

    cursor = null;
    reservation_route = '0;
    reservation_epoch = '0;
    reservation_route_valid = 1'b0;
    reservation_epoch_valid = 1'b0;
    if (attachment == null || attachment.runtime == null)
      return bad("host producer reservation attachment is incomplete",
                 RDMA_SC_INVALID_STATE);

    status = snapshot_attachment_route_epoch(
      attachment, reservation_route, reservation_epoch,
      reservation_route_valid, reservation_epoch_valid);
    if (status == null || !status.ok())
      return status == null ?
        bad("host producer route/epoch validation returned null status",
            RDMA_SC_INVALID_STATE) : status;

    status = attachment.runtime.reserve_producer(cursor);
    if (status == null) begin
      cursor = null;
      return bad("host producer reservation returned null status",
                 RDMA_SC_INVALID_STATE);
    end
    if (!status.ok())
      cursor = null;
    return status;
  endfunction

  // 设计说明：reserve_producer 只返回 detached cursor，并不把 binding 的
  // route/reset epoch 与 runtime reservation 绑定成一个跨对象事务；因此在
  // reservation 返回后、任何 model 编码或 Host-memory 副作用之前仍需重新读取
  // 当前 Function authority。该 virtual seam 让派生测试/集成层可以在这一窄窗口
  // 注入一次 reset/换路，再复用同一 fail-closed 校验，而不伪造跨组件全局锁。
  // 功能：validate_host_producer_reservation_window 复核已取得 cursor 的 attachment
  //   route/reset epoch，确认 reservation 仍可进入纯编码和后续写回阶段。
  // 输入/输出及副作用：attachment、cursor 为 caller 保持的非拥有输入；函数只读取
  //   binding/runtime authority 并返回独立 status，不访问 backing、doorbell、ledger
  //   或 pending，也不取得 queue/mapping 生命周期所有权。
  // 失败/边界：attachment/runtime/cursor 缺失、binding identity 无效、route/epoch
  //   已变化或校验返回 null 时返回对应非成功 status；调用方必须清空本地 cursor 并
  //   在首次外部副作用前停止，不能把该失败转成 QUEUE_FULL 或创建 recovery pending。
  protected virtual function rdma_status validate_host_producer_reservation_window(
    rdma_queue_data_attachment attachment,
    rdma_queue_cursor_snapshot cursor
  );
    rdma_status status;

    if (attachment == null || attachment.runtime == null || cursor == null)
      return bad("host producer reservation window is incomplete",
                 RDMA_SC_INVALID_STATE);
    status = validate_attachment_route_epoch(attachment);
    if (status == null)
      return bad("host producer reservation window validation returned null status",
                 RDMA_SC_INVALID_STATE);
    return status;
  endfunction

  // 设计说明：host producer 的 WQE/doorbell 阶段由 queue-data engine 负责，
  //   ledger commit 则由 attachment.runtime 负责；若两个调用点各自直接调用
  //   runtime.commit_producer，null status 归一化和测试故障注入会出现两套边界。
  //   此 seam 只收束调用与 status ownership，不把 runtime ledger 的锁或状态迁移
  //   复制到 engine，也不宣称跨组件原子性。
  // 功能：commit_host_producer_ledger 将冻结的 producer reservation、request 和
  //   image 交给 runtime 提交一次 host-producer ledger，并统一规范 backend 返回。
  // 输入/输出及副作用：attachment、cursor、request、wr_id、signaled、image 为
  //   caller 冻结输入；函数只调用 attachment.runtime.commit_producer，成功时由
  //   runtime 推进 PI/used 并保存 slot snapshot，函数本身不修改 engine attachment。
  // 失败/边界：attachment/runtime/cursor 缺失返回 INVALID_STATE；runtime 返回
  //   null 时转换为 INVALID_STATE；非成功 status 原样返回且不安装 recovery，
  //   caller 必须按当前阶段决定是否保存 AMBIGUOUS/NO_SUBMIT evidence。
  protected virtual function rdma_status commit_host_producer_ledger(
    rdma_queue_data_attachment attachment,
    rdma_queue_cursor_snapshot cursor,
    rdma_semantic_request request,
    longint unsigned wr_id,
    bit signaled,
    rdma_hw_image image
  );
    rdma_status status;

    if (attachment == null || attachment.runtime == null || cursor == null)
      return bad("host producer ledger commit input is incomplete",
                 RDMA_SC_INVALID_STATE);
    status = attachment.runtime.commit_producer(
      cursor, request, wr_id, signaled, image);
    if (status == null)
      return bad("host producer ledger commit returned null status",
                 RDMA_SC_INVALID_STATE);
    return status;
  endfunction

  // 功能：query_runtime_state 返回指定队列 attachment 的只读运行状态，供
  // 复位/resize 回归检查依赖 runtime 是否已恢复 ACTIVE。
  // 输入/输出及副作用：handle、kind 为输入，state 为输出；函数只读取
  // attachment 索引，不修改 runtime、authority 或 backing 所有权。
  // 失败/边界：队列未配置、句柄代际失效或 attachment 缺失时返回错误，state
  // 置为 DETACHED，调用方不得把失败结果当作活动状态。
  function rdma_status query_runtime_state(
    rdma_handle handle, rdma_queue_runtime_kind_e kind,
    output rdma_queue_runtime_state_e state
  );
    rdma_queue_data_attachment attachment;
    rdma_status status;
    state = RDMA_QUEUE_RUNTIME_DETACHED;
    status = lookup_attachment(handle, kind, attachment);
    if (!status.ok()) return status;
    if (attachment.runtime == null)
      return bad("queue runtime is missing", RDMA_SC_INVALID_STATE);
    state = attachment.runtime.state;
    return rdma_status::success();
  endfunction

  // 功能：query_runtime_occupancy 返回指定 SQ/RQ/CQ 等 runtime 的当前
  //   credit 使用量以及是否存在待恢复事务，供端到端 scoreboard 验证
  //   completion 后的 outstanding 账本已经清零。
  // 输入/输出及副作用：handle、kind（输入）；used、pending（输出）；函数
  //   只读取 attachment/runtime 快照，不推进 PI/CI，不提交 doorbell，也不
  //   转移队列或 Host-memory 所有权。
  // 失败/边界：句柄代际失效、attachment 缺失或 runtime 未配置时返回明确
  //   错误，并把 used/pending 保持为安全默认值 0/0，调用方不得把失败当作
  //   “队列为空”的证据。
  function rdma_status query_runtime_occupancy(
    rdma_handle handle, rdma_queue_runtime_kind_e kind,
    output int unsigned used, output bit pending
  );
    rdma_queue_data_attachment attachment;
    rdma_status status;

    used = 0;
    pending = 1'b0;
    status = lookup_attachment(handle, kind, attachment);
    if (status == null || !status.ok())
      return status == null ?
        bad("runtime occupancy lookup returned null status",
            RDMA_SC_INVALID_STATE) : status;
    if (attachment == null || attachment.runtime == null)
      return bad("runtime occupancy attachment is incomplete",
                 RDMA_SC_INVALID_STATE);
    used = attachment.runtime.used;
    pending = attachment.runtime.pending_operation != null;
    return rdma_status::success();
  endfunction

  // 功能：query_runtime_cursors 返回指定 runtime 的 producer/consumer
  //   index 与 wrap 快照，用于验证 PI/CI doorbell 及 ring 回卷语义。
  // 输入/输出及副作用：handle、kind（输入）；producer_index、producer_wrap、
  //   consumer_index、consumer_wrap（输出）；函数只读 runtime，不提交任何
  //   MMIO 或修改队列状态。
  // 失败/边界：句柄、代际或 attachment 无效时返回错误，所有输出置零；
  //   调用方必须先检查返回状态，不能使用失败路径的默认游标作有效证据。
  function rdma_status query_runtime_cursors(
    rdma_handle handle, rdma_queue_runtime_kind_e kind,
    output int unsigned producer_index, output bit producer_wrap,
    output int unsigned consumer_index, output bit consumer_wrap
  );
    rdma_queue_data_attachment attachment;
    rdma_status status;

    producer_index = 0;
    producer_wrap = 1'b0;
    consumer_index = 0;
    consumer_wrap = 1'b0;
    status = lookup_attachment(handle, kind, attachment);
    if (status == null || !status.ok())
      return status == null ?
        bad("runtime cursor lookup returned null status",
            RDMA_SC_INVALID_STATE) : status;
    if (attachment == null || attachment.runtime == null)
      return bad("runtime cursor attachment is incomplete",
                 RDMA_SC_INVALID_STATE);
    producer_index = attachment.runtime.producer_index;
    producer_wrap = attachment.runtime.producer_wrap;
    consumer_index = attachment.runtime.consumer_index;
    consumer_wrap = attachment.runtime.consumer_wrap;
    return rdma_status::success();
  endfunction

  // 功能：query_runtime_device_reservation 返回尚未清除的 device producer
  //   reservation，供 cancel 返回 RECOVERY_REQUIRED 时定位同一 queue/cursor
  //   evidence，而不依赖 lifecycle 的外部 shadow。
  // 输入/输出及副作用：queue_h、kind 为输入，valid/reservation 为输出并先置安全
  //   默认值；函数只读取 runtime，不提交、取消或接管 reservation。
  // 失败/边界：attachment/runtime 缺失或 runtime 查询返回 null status 时返回
  //   INVALID_STATE；没有 reservation 时 valid=0、reservation=null 仍为成功查询。
  function rdma_status query_runtime_device_reservation(
    rdma_handle queue_h,
    rdma_queue_runtime_kind_e kind,
    output bit valid,
    output rdma_queue_cursor_snapshot reservation
  );
    rdma_queue_data_attachment attachment;
    rdma_status status;

    valid = 1'b0;
    reservation = null;
    status = lookup_attachment(queue_h, kind, attachment);
    if (status == null || !status.ok())
      return status == null ?
        bad("device reservation lookup returned null status",
            RDMA_SC_INVALID_STATE) : status;
    if (attachment == null || attachment.runtime == null)
      return bad("device reservation attachment is incomplete",
                 RDMA_SC_INVALID_STATE);
    status = attachment.runtime.query_device_reservation(valid, reservation);
    return status == null ?
      bad("device reservation query returned null status",
          RDMA_SC_INVALID_STATE) : status;
  endfunction

  // 功能：snapshot_attachment_recovery_state 在不取得 engine 锁的前提下，按
  //   runtime state、pending evidence、device reservation 的固定顺序采集一个
  //   attachment 的恢复前置快照，供 configure/detach 在 mutation 前共用。
  // 输入/输出及副作用：attachment 为输入；runtime_state、has_pending、
  //   reservation_valid、reservation、pending_queried 和 reservation_queried 为
  //   输出并先置安全默认值；函数只读 attachment/runtime，不改变 state、pending、
  //   reservation、索引或 backing 所有权，底层 query 的非成功 status 原样返回。
  // 失败/边界：attachment/runtime 为空或任一 query 返回 null status 时返回
  //   INVALID_STATE；runtime 已为 RECOVERY_REQUIRED 或已有 pending 时保留已采集
  //   输出并提前返回对应 query 的成功 status，让调用者继续决定业务错误文本；
  //   两个 queried 标记让调用者在 state/pending/reservation 查询失败时保留原失败
  //   优先级和错误文本；只有无 recovery marker 的 CQ/CEQ/AEQ 才查询 reservation，
  //   SQ/RQ/SRQ 不伪造 reservation 结果，也不在 helper 内获取/释放 resize_lock。
  protected function rdma_status snapshot_attachment_recovery_state(
    rdma_queue_data_attachment attachment,
    output rdma_queue_runtime_state_e runtime_state,
    output bit has_pending,
    output bit reservation_valid,
    output rdma_queue_cursor_snapshot reservation,
    output bit pending_queried,
    output bit reservation_queried
  );
    rdma_status status;

    runtime_state = RDMA_QUEUE_RUNTIME_DETACHED;
    has_pending = 1'b0;
    reservation_valid = 1'b0;
    reservation = null;
    pending_queried = 1'b0;
    reservation_queried = 1'b0;
    if (attachment == null || attachment.runtime == null)
      return bad("attachment recovery state is incomplete",
                 RDMA_SC_INVALID_STATE);

    status = attachment.runtime.query_state(runtime_state);
    if (status == null)
      return bad("attachment runtime state query returned null status",
                 RDMA_SC_INVALID_STATE);
    if (!status.ok() || runtime_state == RDMA_QUEUE_RUNTIME_RECOVERY_REQUIRED)
      return status;

    pending_queried = 1'b1;
    status = attachment.runtime.query_has_pending(has_pending);
    if (status == null)
      return bad("attachment pending query returned null status",
                 RDMA_SC_INVALID_STATE);
    if (!status.ok() || has_pending)
      return status;

    if (attachment.kind inside {RDMA_QUEUE_RUNTIME_CQ,
                                RDMA_QUEUE_RUNTIME_CEQ,
                                RDMA_QUEUE_RUNTIME_AEQ}) begin
      reservation_queried = 1'b1;
      status = attachment.runtime.query_device_reservation(
        reservation_valid, reservation);
      if (status == null)
        return bad("attachment reservation query returned null status",
                   RDMA_SC_INVALID_STATE);
    end
    return status;
  endfunction

  // 功能：clone_publish_handle 为设备发布事务复制 queue/route handle 的全部
  //   身份字段，形成不会随调用方修改而变化的 detached 快照。
  // 输入/输出及副作用：source、label 为输入，copy 为输出；函数只分配并写入
  //   一个本地 handle，不访问 backing、runtime 或 manager，也不取得 source 所有权。
  // 失败/边界：source 为空、工厂分配失败或输出无法建立时返回明确错误，copy 保持
  //   null；任何失败都不能把半成品句柄交给 recovery 或 result。
  protected function rdma_status clone_publish_handle(
    rdma_handle source, string label, output rdma_handle copy
  );
    rdma_handle candidate;

    copy = null;
    if (source == null)
      return bad({label, " source handle is null"});
    candidate = rdma_handle::type_id::create({label, "_copy"});
    if (candidate == null)
      return bad({label, " handle allocation failed"},
                 RDMA_SC_RESOURCE_EXHAUSTED);
    candidate.kind = source.kind;
    candidate.function_uid = source.function_uid;
    candidate.object_id = source.object_id;
    candidate.generation = source.generation;
    copy = candidate;
    return rdma_status::success();
  endfunction

  // 功能：clone_publish_image 深复制设备发布所需的镜像 metadata、payload 和
  //   field_summary，保证写后失败时仍能按原始槽位重放。
  // 输入/输出及副作用：source 为输入，copy 为输出；只创建 detached image，源
  //   image、runtime 和 backing 均保持不变。
  // 失败/边界：source 为空、image 工厂分配失败或复制中止时返回错误且 copy=null；
  //   调用方不得使用不完整镜像继续写入或提交。
  protected function rdma_status clone_publish_image(
    rdma_hw_image source, output rdma_hw_image copy
  );
    rdma_hw_image candidate;

    copy = null;
    if (source == null)
      return bad("publish image source is null");
    candidate = rdma_hw_image::type_id::create("publish_image_copy");
    if (candidate == null)
      return bad("publish image allocation failed", RDMA_SC_RESOURCE_EXHAUSTED);
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
    foreach (source.field_summary[i])
      candidate.field_summary.push_back(source.field_summary[i]);
    copy = candidate;
    return rdma_status::success();
  endfunction

  // 功能：clone_unclaimed_device_pending 为 engine-owned 的 device recovery
  //   evidence 创建完整 detached 查询快照，避免 query API 泄露可写内部对象。
  // 输入/输出及副作用：source 为输入、copy 为输出；函数只分配和复制 handle、
  //   cursor、image、status、completion target/kind 与设备发布阶段字段，
  //   不修改 unclaimed 表或 runtime，routed QP 也不借用 source 引用。
  // 失败/边界：source 不是完整 device pending、任一对象分配或复制失败时返回非空
  //   status 且 copy=null；调用方必须保留原 evidence，不能因查询失败删除表项。
  protected function rdma_status clone_unclaimed_device_pending(
    rdma_queue_pending_operation source,
    output rdma_queue_pending_operation copy
  );
    rdma_queue_pending_operation candidate;
    rdma_status status;

    copy = null;
    if (source == null || !source.device_producer || source.producer ||
        source.request_snapshot != null || source.queue_h == null ||
        source.cursor == null || source.next_cursor == null ||
        source.image == null || source.failure_status == null)
      return bad("unclaimed device pending is incomplete", RDMA_SC_INVALID_STATE);
    candidate = rdma_queue_pending_operation::type_id::create(
      "unclaimed_device_pending_snapshot");
    if (candidate == null)
      return bad("unclaimed device pending allocation failed",
                 RDMA_SC_RESOURCE_EXHAUSTED);
    status = clone_publish_handle(source.queue_h, "unclaimed device queue",
                                  candidate.queue_h);
    if (status == null || !status.ok() || candidate.queue_h == null)
      return status == null ?
        bad("unclaimed device queue clone returned null status",
            RDMA_SC_RESOURCE_EXHAUSTED) : status;
    candidate.cursor = rdma_queue_cursor_snapshot::type_id::create(
      "unclaimed_device_cursor_snapshot");
    candidate.next_cursor = rdma_queue_cursor_snapshot::type_id::create(
      "unclaimed_device_next_cursor_snapshot");
    if (candidate.cursor == null || candidate.next_cursor == null)
      return bad("unclaimed device cursor snapshot allocation failed",
                 RDMA_SC_RESOURCE_EXHAUSTED);
    candidate.cursor.index = source.cursor.index;
    candidate.cursor.wrap = source.cursor.wrap;
    candidate.next_cursor.index = source.next_cursor.index;
    candidate.next_cursor.wrap = source.next_cursor.wrap;
    if (source.committed_consumer_cursor != null) begin
      candidate.committed_consumer_cursor =
        rdma_queue_cursor_snapshot::type_id::create(
          "unclaimed_device_committed_cursor_snapshot");
      if (candidate.committed_consumer_cursor == null)
        return bad("unclaimed device committed cursor allocation failed",
                   RDMA_SC_RESOURCE_EXHAUSTED);
      candidate.committed_consumer_cursor.index =
        source.committed_consumer_cursor.index;
      candidate.committed_consumer_cursor.wrap =
        source.committed_consumer_cursor.wrap;
    end
    status = clone_publish_image(source.image, candidate.image);
    if (status == null || !status.ok() || candidate.image == null)
      return status == null ?
        bad("unclaimed device image clone returned null status",
            RDMA_SC_RESOURCE_EXHAUSTED) : status;
    candidate.failure_status = rdma_status::type_id::create(
      "unclaimed_device_failure_status_snapshot");
    if (candidate.failure_status == null)
      return bad("unclaimed device failure status allocation failed",
                 RDMA_SC_RESOURCE_EXHAUSTED);
    status = copy_publish_status_into(source.failure_status,
                                      candidate.failure_status);
    if (status == null || !status.ok())
      return status == null ?
        bad("unclaimed device failure status copy returned null status",
            RDMA_SC_RESOURCE_EXHAUSTED) : status;
    if (source.routed_qp_h != null) begin
      status = clone_publish_handle(source.routed_qp_h,
                                    "unclaimed device routed QP",
                                    candidate.routed_qp_h);
      if (status == null || !status.ok() || candidate.routed_qp_h == null)
        return status == null ?
          bad("unclaimed device routed QP clone returned null status",
              RDMA_SC_RESOURCE_EXHAUSTED) : status;
    end
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
    return rdma_status::success();
  endfunction

  // 功能：copy_publish_status_into 复用无分配字段复制更新 publish pending 的原始
  //   失败证据，再创建业务返回 status；保留“字段写完后才执行 status factory”的顺序。
  // 输入/输出及副作用：source、destination 为输入；destination 的受控状态字段
  //   会被覆盖，source、queue cursor 和 backing 不受影响。
  // 失败/边界：任一状态为空返回 INVALID_ARGUMENT 且不写 destination；自复制合法。
  //   字段复制不执行虚拟 hook，但返回 status 仍经过 factory，本 wrapper 不是无分配接口。
  protected function rdma_status copy_publish_status_into(
    rdma_status source, rdma_status destination
  );
    if (!value_ops::copy_status_fields(source, destination))
      return bad("publish status copy input is null");
    return rdma_status::success();
  endfunction

  // 功能：copy_image_bytes 将 image 的 queue payload 复制到连续 byte 数组，供
  //   write_device 和 readback 比较使用；源镜像保持只读。
  // 输入/输出及副作用：source 为输入，data 为输出并先清空；函数不访问外部
  //   mapping，也不推进任何 runtime cursor。
  // 失败/边界：source 为空、length 与 bytes 数量不一致或长度为零时返回错误，data
  //   保持空数组，调用方必须在 backend 调用前停止事务。
  protected function rdma_status copy_image_bytes(
    rdma_hw_image source, output byte data[]
  );
    data = new[0];
    if (source == null)
      return bad("publish image source is null");
    if (source.length == 0 || source.length != source.bytes.size())
      return bad("publish image metadata length is inconsistent",
                 RDMA_SC_CODEC_ERROR);
    data = new[source.bytes.size()];
    foreach (data[i]) data[i] = byte'(source.bytes[i]);
    return rdma_status::success();
  endfunction

  // 功能：prepare_device_pending 在设备写入前建立完整的 detached recovery
  //   evidence（queue、旧/新 cursor、entry offset、image、route/epoch 和失败状态）。
  // 输入/输出及副作用：attachment、reservation、next、image、device_write_attempted
  //   为输入，pending 为输出；只分配本地 evidence，不写 backing、不修改 runtime。
  // 失败/边界：任一 authority/geometry/clone/route 查询失败时返回非成功状态且
  //   pending=null；半成品 evidence 不得挂入 runtime recovery。
  protected function rdma_status prepare_device_pending(
    rdma_queue_data_attachment attachment,
    rdma_queue_cursor_snapshot reservation,
    rdma_queue_cursor_snapshot next,
    rdma_hw_image image,
    bit device_write_attempted,
    output rdma_queue_pending_operation pending
  );
    rdma_status status;
    rdma_handle queue_copy;
    rdma_hw_image image_copy;
    rdma_queue_cursor_snapshot cursor_copy;
    rdma_queue_cursor_snapshot next_copy;

    pending = null;
    if (attachment == null || attachment.queue_h == null ||
        attachment.runtime == null || reservation == null || next == null ||
        image == null || attachment.entry_size == 0)
      return bad("device pending input is incomplete");
    if (reservation.index >= attachment.runtime.depth ||
        next.index >= attachment.runtime.depth)
      return bad("device pending cursor is outside depth");

    pending = rdma_queue_pending_operation::type_id::create(
      "device_publish_pending");
    if (pending == null) begin
      pending = null;
      return bad("device pending allocation failed", RDMA_SC_RESOURCE_EXHAUSTED);
    end
    status = clone_publish_handle(attachment.queue_h, "device pending queue",
                                  queue_copy);
    if (status == null || !status.ok() || queue_copy == null) begin
      pending = null;
      return status == null ?
        bad("device pending queue clone returned null status",
            RDMA_SC_RESOURCE_EXHAUSTED) : status;
    end
    status = clone_publish_image(image, image_copy);
    if (status == null || !status.ok() || image_copy == null) begin
      pending = null;
      return status == null ?
        bad("device pending image clone returned null status",
            RDMA_SC_RESOURCE_EXHAUSTED) : status;
    end
    cursor_copy = rdma_queue_cursor_snapshot::type_id::create(
      "device_pending_cursor");
    next_copy = rdma_queue_cursor_snapshot::type_id::create(
      "device_pending_next_cursor");
    if (cursor_copy == null || next_copy == null) begin
      pending = null;
      return bad("device pending cursor allocation failed",
                 RDMA_SC_RESOURCE_EXHAUSTED);
    end
    cursor_copy.index = reservation.index;
    cursor_copy.wrap = reservation.wrap;
    next_copy.index = next.index;
    next_copy.wrap = next.wrap;

    pending.queue_h = queue_copy;
    pending.kind = attachment.kind;
    pending.producer = 1'b0;
    pending.device_producer = 1'b1;
    pending.device_write_attempted = device_write_attempted;
    pending.entry_size = attachment.entry_size;
    pending.entry_offset = longint'(reservation.index) *
                           longint'(attachment.entry_size);
    pending.cursor = cursor_copy;
    pending.next_cursor = next_copy;
    pending.image = image_copy;
    pending.mmio_evidence = RDMA_QUEUE_MMIO_NOT_APPLICABLE;
    pending.mmio_maybe_submitted = 1'b0;
    pending.known_no_mmio = 1'b1;
    pending.consumer_doorbell_succeeded = 1'b0;
    pending.consumer_committed = 1'b0;
    pending.cq_consumer_committed = 1'b0;
    pending.completion_released = 1'b0;
    pending.failure_status = rdma_status::make(
      RDMA_SC_RECOVERY_REQUIRED, "device publish failure not yet recorded");
    if (pending.failure_status == null) begin
      pending = null;
      return bad("device pending failure status allocation failed",
                 RDMA_SC_RESOURCE_EXHAUSTED);
    end
    status = attachment.runtime.query_route_epoch(
      pending.route, pending.route_valid, pending.reset_epoch,
      pending.epoch_valid);
    if (status == null || !status.ok() || !pending.route_valid ||
        !pending.epoch_valid) begin
      pending = null;
      return status == null ?
        bad("device pending route/epoch query returned null",
            RDMA_SC_INVALID_STATE) :
        (status.ok() ? bad("device pending route/epoch evidence is invalid",
                           RDMA_SC_INVALID_STATE) : status);
    end
    return rdma_status::success();
  endfunction

  // 功能：enter_device_publish_recovery 把写后失败的 detached evidence 安装到
  //   runtime recovery 状态，并在 runtime 无法接管时保存到 engine-owned unclaimed 表。
  // 输入/输出及副作用：attachment、prepared_pending、original_status、evidence 为
  //   输入，final_status 为输出；成功安装会切换 runtime 状态，失败仅更新 engine 表。
  // 失败/边界：任何阶段均返回非空 RECOVERY_REQUIRED；不得调用 cancel 清除已进入
  //   backend 的 reservation，也不得覆盖已有不同 identity 的 evidence。
  protected task enter_device_publish_recovery(
    rdma_queue_data_attachment attachment,
    rdma_queue_pending_operation prepared_pending,
    rdma_status original_status,
    rdma_queue_mmio_evidence_e evidence,
    output rdma_status final_status
  );
    rdma_status status;
    rdma_status copy_status;
    string key;

    final_status = null;
    if (attachment == null || attachment.runtime == null ||
        prepared_pending == null || prepared_pending.queue_h == null) begin
      final_status = bad("device recovery evidence is incomplete",
                         RDMA_SC_RECOVERY_REQUIRED);
      return;
    end
    if (original_status == null)
      original_status = bad("device publish returned null status");
    copy_status = copy_publish_status_into(original_status,
                                            prepared_pending.failure_status);
    if (copy_status == null || !copy_status.ok()) begin
      if (prepared_pending.failure_status != null) begin
        prepared_pending.failure_status.code = RDMA_SC_RECOVERY_REQUIRED;
        prepared_pending.failure_status.message =
          "original device publish failure could not be detached";
      end
    end
    prepared_pending.mmio_evidence = evidence;
    prepared_pending.known_no_mmio = evidence inside {
      RDMA_QUEUE_MMIO_NOT_APPLICABLE, RDMA_QUEUE_MMIO_NO_SUBMIT};
    prepared_pending.mmio_maybe_submitted =
      evidence == RDMA_QUEUE_MMIO_AMBIGUOUS;
    prepared_pending.consumer_doorbell_succeeded =
      evidence == RDMA_QUEUE_MMIO_SUCCESS;
    status = admit_device_publish_recovery(attachment, prepared_pending);
    if (status != null && status.ok()) begin
      status = attachment.runtime.record_recovery_failure(evidence);
      final_status = bad("device publish entered recovery",
                         RDMA_SC_RECOVERY_REQUIRED);
      if (status == null || !status.ok())
        final_status.message = "device recovery evidence projection failed";
      return;
    end

    key = value_ops::identity_key(prepared_pending.queue_h);
    if (key == "") begin
      final_status = bad("device recovery evidence has no stable identity",
                         RDMA_SC_RECOVERY_REQUIRED);
      return;
    end
    if (unclaimed_device_recoveries.exists(key) &&
        unclaimed_device_recoveries[key] != null) begin
      final_status = bad("device recovery identity is already retained",
                         RDMA_SC_RECOVERY_REQUIRED);
      return;
    end
    unclaimed_device_recoveries[key] = prepared_pending;
    unclaimed_recovery_attachments[key] = attachment;
    final_status = bad("device recovery admission failed; evidence retained",
                       RDMA_SC_RECOVERY_REQUIRED);
  endtask

  // 设计说明：device publish 的 runtime admission 是写后恢复证据进入状态机的
  //   唯一边界。保留此 virtual 分派使故障注入能在不公开 attachment/backing 的
  //   前提下验证 engine-owned unclaimed evidence 的保留与回收路径。
  // 功能：admit_device_publish_recovery 将完整的 device pending 交给 attachment
  //   runtime 接管，默认保持 runtime 的真实 state/identity 校验。
  // 输入/输出及副作用：attachment、prepared_pending 为输入；成功时 runtime 接管
  //   pending 并进入 recovery，函数不修改 Host-memory、backing 或 engine 表。
  // 失败/边界：attachment/runtime/pending 缺失返回 INVALID_STATE；runtime 拒绝、
  //   返回 null 或状态迁移失败原样交给调用方决定保留 unclaimed evidence。
  protected virtual function rdma_status admit_device_publish_recovery(
    rdma_queue_data_attachment attachment,
    rdma_queue_pending_operation prepared_pending
  );
    if (attachment == null || attachment.runtime == null ||
        prepared_pending == null)
      return bad("device recovery admission input is incomplete",
                 RDMA_SC_INVALID_STATE);
    return attachment.runtime.enter_recovery_prepared(prepared_pending);
  endfunction

  // 功能：finish_device_producer_cancel 将 reservation 的安全取消收敛为可观察
  //   的原始失败或 RECOVERY_REQUIRED；若已有 detached pending，则在取消失败时
  //   把它交给 runtime/engine recovery 保存，避免遗失槽位与镜像证据。
  // 输入/输出及副作用：attachment、reservation、pending、original_status、cancel_context
  //   为输入，final_status 为输出；成功取消不修改 committed cursor，失败时可能
  //   切换 runtime recovery 或写入 engine 的 unclaimed recovery 表。
  // 失败/边界：runtime 返回 null、非 OK 或 attachment 不完整时 final_status 始终
  //   为非空 RECOVERY_REQUIRED；pending 为空的纯 preflight 路径保留 runtime
  //   reservation，调用方不得将它误判为已经清理。
  protected task finish_device_producer_cancel(
    rdma_queue_data_attachment attachment,
    rdma_queue_cursor_snapshot reservation,
    rdma_queue_pending_operation pending,
    rdma_status original_status,
    string cancel_context,
    output rdma_status final_status
  );
    rdma_status cancel_status;

    final_status = null;
    if (original_status == null)
      original_status = bad({cancel_context, " original status is null"},
                            RDMA_SC_INVALID_STATE);
    if (attachment == null || attachment.runtime == null ||
        reservation == null) begin
      final_status = bad({cancel_context, " cancel evidence is incomplete"},
                         RDMA_SC_RECOVERY_REQUIRED);
      return;
    end
    cancel_status = cancel_device_publish_reservation(attachment, reservation);
    if (cancel_status != null && cancel_status.ok()) begin
      final_status = original_status;
      return;
    end
    if (pending != null) begin
      pending.device_write_attempted = 1'b0;
      enter_device_publish_recovery(attachment, pending, cancel_status,
                                    RDMA_QUEUE_MMIO_NO_SUBMIT,
                                    final_status);
      if (final_status != null &&
          final_status.code == RDMA_SC_RECOVERY_REQUIRED)
        return;
    end
    final_status = bad({cancel_context,
                        " cancel did not clear the device reservation"},
                       RDMA_SC_RECOVERY_REQUIRED);
  endtask

  // 设计说明：preflight cancel 与写后 recovery 的边界不同：前者只能在尚未进入
  //   backend 时撤销 reservation。virtual 分派把确定性取消失败限制在该边界，避免
  //   测试取得或改写 lifecycle-owned runtime/backing。
  // 功能：cancel_device_publish_reservation 请求 attachment runtime 取消指定的
  //   device producer reservation，默认执行真实 runtime 校验和状态变更。
  // 输入/输出及副作用：attachment、reservation 为输入；成功时清除 runtime 内的
  //   reservation，不推进 producer cursor、不访问 Host-memory 或修改 queue plan。
  // 失败/边界：attachment/runtime/reservation 缺失返回 INVALID_STATE；runtime 的
  //   stale、非 ACTIVE 或已有写入证据拒绝结果原样返回，调用方必须保留恢复证据。
  protected virtual function rdma_status cancel_device_publish_reservation(
    rdma_queue_data_attachment attachment,
    rdma_queue_cursor_snapshot reservation
  );
    if (attachment == null || attachment.runtime == null || reservation == null)
      return bad("device reservation cancel input is incomplete",
                 RDMA_SC_INVALID_STATE);
    return attachment.runtime.cancel_device_producer(reservation);
  endfunction

  // 功能：prepare_device_publish 校验已取得的 reservation，并按原顺序准备恢复证据、
  //   返回候选、payload 和 detached image/queue；不执行 write、cancel 或 commit。
  // 输入/输出及副作用：attachment/reservation/image 输入；prepared 输出本次调用的值记录，
  //   status 输出原有状态，返回 1 表示可进入 I/O；只创建原有对象，不提前填充成功 result。
  // 失败/边界：attachment/geometry/reservation 拒绝时 cancel_context 为空，不取消他人槽位；
  //   后续失败填入原取消上下文并返回 0，next/pending 准备失败强制 pending=null，
  //   其余失败保留完整 pending，供 caller 处理取消失败；返回 0 不等于 status 必为非 OK。
  protected function bit prepare_device_publish(
    rdma_queue_data_attachment attachment,
    rdma_queue_cursor_snapshot reservation,
    rdma_hw_image image,
    output device_publish_prepared_t prepared,
    output rdma_status status
  );
    rdma_queue_cursor_snapshot current_reservation;
    rdma_queue_cursor_snapshot next;
    bit reservation_valid;
    uvm_object raw_next;

    status = null;
    prepared.cancel_context = "";
    current_reservation = null;
    next = null;
    prepared.pending = null;
    prepared.candidate = null;
    prepared.detached_image = null;
    prepared.detached_queue = null;
    prepared.data = new[0];

    if (attachment == null || attachment.queue_h == null ||
        attachment.runtime == null || attachment.access == null ||
        reservation == null || image == null) begin
      status = bad("device publish attachment/evidence is incomplete",
                   RDMA_SC_INVALID_STATE);
      return 1'b0;
    end
    if (!(attachment.kind inside {RDMA_QUEUE_RUNTIME_CQ,
                                  RDMA_QUEUE_RUNTIME_CEQ,
                                  RDMA_QUEUE_RUNTIME_AEQ}) ||
        attachment.entry_size == 0 || (attachment.entry_size & 64'h7) != 0) begin
      status = bad("device publish kind/geometry is invalid",
                   RDMA_SC_INVALID_STATE);
      return 1'b0;
    end
    reservation_valid = 1'b0;
    status = attachment.runtime.query_device_reservation(
      reservation_valid, current_reservation);
    if (status == null || !status.ok()) begin
      status = status == null ?
        bad("device reservation query returned null status",
            RDMA_SC_INVALID_STATE) : status;
      return 1'b0;
    end
    if (!reservation_valid || current_reservation == null ||
        !value_ops::same_cursor_value(current_reservation, reservation)) begin
      status = bad("device reservation is stale or not owned");
      return 1'b0;
    end
    // 设计说明：后续 image/result 预检之前先准备完整 pending；next/pending
    // 自身准备失败仍只允许 reservation-only 取消。其余取消失败时，runtime 可接管
    // 同一 queue/cursor/image evidence，调用方可查询或显式 abort，而不是只
    // 留下无法处理的 reservation。
    raw_next = value_ops::factory_create_object_nonfatal(
      rdma_queue_cursor_snapshot::get_type(), "device_publish_next");
    if (raw_next == null || !$cast(next, raw_next)) begin
      next = null;
      status = bad("device publish next cursor allocation failed",
                            RDMA_SC_RESOURCE_EXHAUSTED);
      prepared.pending = null;
      prepared.cancel_context = "device publish next cursor";
      return 1'b0;
    end
    next.index = reservation.index;
    next.wrap = reservation.wrap;
    advance_queue_cursor_value(attachment.runtime.depth,
                               reservation.index, reservation.wrap,
                               next.index, next.wrap);
    status = prepare_device_pending(attachment, reservation, next, image,
                                    1'b0, prepared.pending);
    if (status == null || !status.ok() || prepared.pending == null) begin
      if (status == null)
        status = bad("device publish recovery evidence allocation failed",
                     RDMA_SC_RESOURCE_EXHAUSTED);
      prepared.pending = null;
      prepared.cancel_context = "device publish pending preparation";
      return 1'b0;
    end
    if (reservation.index >= attachment.runtime.depth ||
        reservation.index > 64'hffff_ffff_ffff_ffff /
                           longint'(attachment.entry_size)) begin
      status = bad("device publish slot offset is out of range",
                            RDMA_SC_DMA_TRANSLATION);
      prepared.cancel_context = "device publish offset";
      return 1'b0;
    end
    if (image.length != attachment.entry_size ||
        image.bytes.size() != attachment.entry_size ||
        image.alignment != attachment.entry_size ||
        image.endian != RDMA_ENDIAN_BIG) begin
      status = bad("device publish image length/alignment mismatch",
                            RDMA_SC_CODEC_ERROR);
      prepared.cancel_context = "device publish image";
      return 1'b0;
    end

    prepared.candidate = rdma_queue_device_publish_result::type_id::create(
      "device_publish_result");
    if (prepared.candidate == null) begin
      status = bad("device publish result allocation failed",
                            RDMA_SC_RESOURCE_EXHAUSTED);
      prepared.cancel_context = "device publish result";
      return 1'b0;
    end
    // prepared.candidate.status 在 backend write 前完成分配。commit 成功后只原位
    // 更新这份状态，避免已提交槽位因结果状态工厂失败而没有 result/evidence。
    prepared.candidate.status = rdma_status::success(
      "device publish candidate; commit not yet acknowledged");
    if (prepared.candidate.status == null) begin
      status = bad("device publish result status allocation failed",
                            RDMA_SC_RESOURCE_EXHAUSTED);
      prepared.cancel_context = "device publish result status";
      return 1'b0;
    end
    status = copy_image_bytes(image, prepared.data);
    if (status == null || !status.ok()) begin
      if (status == null)
        status = bad("device publish image copy returned null status",
                     RDMA_SC_CODEC_ERROR);
      prepared.cancel_context = "device publish byte copy";
      return 1'b0;
    end
    status = clone_publish_image(image, prepared.detached_image);
    if (status == null || !status.ok() || prepared.detached_image == null) begin
      if (status == null)
        status = bad("device publish image clone returned null status",
                     RDMA_SC_RESOURCE_EXHAUSTED);
      prepared.cancel_context = "device publish image clone";
      return 1'b0;
    end
    status = clone_publish_handle(attachment.queue_h, "publish result queue",
                                  prepared.detached_queue);
    if (status == null || !status.ok() || prepared.detached_queue == null) begin
      if (status == null)
        status = bad("device publish queue clone returned null status",
                     RDMA_SC_RESOURCE_EXHAUSTED);
      prepared.cancel_context = "device publish queue clone";
      return 1'b0;
    end
    return 1'b1;
  endfunction

  // 功能：write_commit_device_entry 编排 CQ/CEQ/AEQ 的准备、DEVICE_WRITE、回读、
  //   producer commit 和结果交付；准备失败在唯一入口按证据完整性取消预留。
  // 输入/输出及副作用：attachment/reservation/image 输入，result/status 输出；成功写 backing
  //   并推进 occupancy，不发送 producer doorbell、不建立 host WQE ledger；prepared 仅本次调用持有。
  // 失败/边界：准备阶段的输入/过期 reservation 拒绝不取消；已确认预留后的失败尝试取消，
  //   取消失败保留 reservation/pending；写后四类失败共用恢复出口，绝不回滚或发布半成品。
  protected task write_commit_device_entry(
    rdma_queue_data_attachment attachment,
    rdma_queue_cursor_snapshot reservation,
    rdma_hw_image image,
    output rdma_queue_device_publish_result result,
    output rdma_status status
  );
    device_publish_prepared_t prepared;
    rdma_status local_status;
    rdma_status original_status;
    rdma_status recovery_status;
    byte readback[];
    bit backend_write_started;
    int unsigned occupancy;
    longint unsigned offset;
    string failure_copy_message;

    result = null;
    status = null;
    readback = new[0];
    occupancy = 0;
    if (!prepare_device_publish(attachment, reservation, image, prepared, status)) begin
      if (prepared.cancel_context != "") begin
        original_status = status;
        finish_device_producer_cancel(attachment, reservation, prepared.pending,
                                      original_status, prepared.cancel_context, status);
      end
      return;
    end
    prepared.pending.device_write_attempted = 1'b1;
    offset = longint'(reservation.index) * longint'(attachment.entry_size);
    readback = new[attachment.entry_size];
    backend_write_started = 1'b0;
    failure_copy_message = "";
    // 单次循环只收束本次调用的写后失败，不能用跨 activation 的命名块 disable。
    // 写前拒绝、backend 未开始的异常成功与最终成功直接返回；四类写后失败才到尾段。
    // 字节比较先退出 foreach，再按已选诊断退出 I/O 阶段，不比较或处理首个错误之后的字节。
    do begin : device_publish_io
      status = attachment.access.write_device(offset, prepared.data,
                                              backend_write_started);
      if (status == null || !status.ok()) begin
        original_status = status;
        if (original_status == null)
          original_status = bad("device write returned null status");
        if (!backend_write_started) begin
          finish_device_producer_cancel(attachment, reservation, prepared.pending,
                                        original_status,
                                        "device publish write preflight", status);
          return;
        end
        failure_copy_message = "device write failure status copy failed";
        break;
      end
      if (!backend_write_started) begin
        original_status = bad("device write did not enter backend");
        enter_device_publish_recovery(attachment, prepared.pending, original_status,
                                      RDMA_QUEUE_MMIO_NOT_APPLICABLE,
                                      recovery_status);
        status = recovery_status;
        return;
      end
      status = attachment.access.read(offset, attachment.entry_size, readback);
      if (status == null || !status.ok() || readback.size() != prepared.data.size()) begin
        if (status == null)
          status = bad("device publish readback returned null status",
                       RDMA_SC_DMA_TRANSLATION);
        else if (status.ok())
          status = bad("device publish readback length differs",
                       RDMA_SC_DMA_TRANSLATION);
        original_status = status;
        failure_copy_message = "device readback failure status copy failed";
        break;
      end
      foreach (readback[i]) begin
        if (readback[i] !== prepared.data[i]) begin
          original_status = bad("device publish readback bytes differ",
                               RDMA_SC_DMA_TRANSLATION);
          failure_copy_message = "device readback mismatch status copy failed";
          break;
        end
      end
      if (failure_copy_message != "")
        break;
      status = attachment.runtime.commit_device_producer(reservation);
      if (status == null || !status.ok()) begin
        if (status == null)
          status = bad("device producer commit returned null status",
                       RDMA_SC_INVALID_STATE);
        original_status = status;
        failure_copy_message = "device producer commit failure status copy failed";
        break;
      end
      prepared.candidate.queue_h = prepared.detached_queue;
      prepared.candidate.index = reservation.index;
      prepared.candidate.wrap = reservation.wrap;
      prepared.candidate.image = prepared.detached_image;
      prepared.candidate.occupancy_valid = 1'b0;
      local_status = attachment.runtime.query_occupancy(occupancy);
      if (local_status != null && local_status.ok()) begin
        prepared.candidate.occupancy_valid = 1'b1;
        prepared.candidate.occupancy = occupancy;
      end
      else prepared.candidate.occupancy = 0;
      prepared.candidate.status.code = RDMA_SC_OK;
      prepared.candidate.status.message = "device publish committed";
      result = prepared.candidate;
      status = rdma_status::success();
      return;
    end while (1'b0);

    // 两次字段复制之间原有 status factory 回调窗口必须保留；不可视为重复赋值删除。
    // pending.failure_status 与 attachment.runtime 仍在各调用点读取，不提前冻结成员。
    local_status = copy_publish_status_into(original_status, prepared.pending.failure_status);
    if (local_status == null || !local_status.ok()) begin
      prepared.pending.failure_status.code = RDMA_SC_RECOVERY_REQUIRED;
      prepared.pending.failure_status.message = failure_copy_message;
    end
    enter_device_publish_recovery(attachment, prepared.pending, original_status,
                                  RDMA_QUEUE_MMIO_NOT_APPLICABLE, recovery_status);
    status = recovery_status;
  endtask

  // 功能：query_runtime_producer_polarity 查询设备生产 ring 当前 producer owner 位。
  // 输入/输出及副作用：queue_h、kind 为输入，polarity 为输出；仅读取 runtime 快照，不推进游标或写入后端。
  // 失败/边界：句柄、attachment 或 runtime 不完整，或 runtime 非设备生产 ring 时返回明确错误并保持 polarity=0。
  function rdma_status query_runtime_producer_polarity(
    rdma_handle queue_h, rdma_queue_runtime_kind_e kind,
    output bit polarity
  );
    rdma_queue_data_attachment attachment;
    rdma_status status;

    polarity = 1'b0;
    status = lookup_attachment(queue_h, kind, attachment);
    if (status == null || !status.ok())
      return status == null ?
        bad("producer polarity lookup returned null status",
            RDMA_SC_INVALID_STATE) : status;
    if (attachment == null || attachment.runtime == null)
      return bad("producer polarity attachment is incomplete",
                 RDMA_SC_INVALID_STATE);
    status = attachment.runtime.query_expected_producer_polarity(polarity);
    return status == null ?
      bad("producer polarity query returned null status",
          RDMA_SC_INVALID_STATE) : status;
  endfunction

  // 功能：query_runtime_pending 返回 runtime 或 engine-owned unclaimed 表中的
  //   detached recovery evidence，使调用方可审计而不能改写内部恢复对象。
  // 输入/输出及副作用：queue_h、kind 为输入，pending 为输出；函数只复制 evidence，
  //   不改变 runtime、unclaimed 表、reservation 或任何 backing ownership。
  // 失败/边界：句柄或请求 kind 无效、unclaimed 配对不完整、快照复制失败、runtime
  //   不存在或无 pending 时返回非成功 status 且 pending 保持 null，原 evidence
  //   不会被删除或通过错误 kind 泄露。
  function rdma_status query_runtime_pending(
    rdma_handle queue_h, rdma_queue_runtime_kind_e kind,
    output rdma_queue_pending_operation pending
  );
    rdma_queue_data_attachment attachment;
    rdma_status status;
    string key;

    pending = null;
    if (queue_h == null)
      return bad("pending query queue handle is null", RDMA_SC_INVALID_ARGUMENT);
    status = lookup_attachment(queue_h, kind, attachment);
    if (status == null || !status.ok())
      return status == null ?
        bad("pending attachment lookup returned null status",
            RDMA_SC_INVALID_STATE) : status;
    key = value_ops::identity_key(queue_h);
    if (key != "" && (unclaimed_device_recoveries.exists(key) ||
                       unclaimed_recovery_attachments.exists(key))) begin
      if (!unclaimed_device_recoveries.exists(key) ||
          unclaimed_device_recoveries[key] == null ||
          !unclaimed_recovery_attachments.exists(key) ||
          unclaimed_recovery_attachments[key] == null)
        return bad("unclaimed pending evidence pair is incomplete",
                   RDMA_SC_RECOVERY_REQUIRED);
      status = clone_unclaimed_device_pending(unclaimed_device_recoveries[key],
                                              pending);
      return status == null ?
        bad("unclaimed pending snapshot returned null status",
            RDMA_SC_RESOURCE_EXHAUSTED) : status;
    end
    if (attachment == null || attachment.runtime == null)
      return bad("pending attachment is incomplete", RDMA_SC_INVALID_STATE);
    status = attachment.runtime.query_pending(pending);
    return status == null ?
      bad("pending query returned null status", RDMA_SC_INVALID_STATE) : status;
  endfunction

  // 功能：resolve_cqe_variant_for_route 根据冻结 QP link transport、CQE 的 receive
  //   与 SRFQ 标志计算唯一 overlay variant，集中执行 publish/decode 共用的
  //   transport authority gate。
  // 输入/输出及副作用：rq_cqe、srfq、transport 为输入；variant 为输出；函数只读
  //   route 标志，不修改 model、link、CQ runtime、codec registry、cursor 或 backing
  //   ownership，也不建立 recovery evidence。
  // 失败/边界：rq_cqe/srfq 含 X/Z、send CQE 设置 srfq、transport 不是 RC/UD/URC
  //   时返回 INVALID_ARGUMENT 或 INVALID_STATE；receive CQE 一律要求 RQ/SRFQ
  //   variant，send CQE 的 UD/RC/URC 分别要求 UD/RC overlay；QP 是否实际挂接
  //   SRQ 由紧邻的 route-consistency helper 继续校验。
  protected function rdma_status resolve_cqe_variant_for_route(
    input logic rq_cqe,
    input logic srfq,
    input rdma_transport_e transport,
    output rdma_cqe_variant_e variant
  );
    variant = RDMA_CQE_VARIANT_RC;

    if (rq_cqe !== 1'b0 && rq_cqe !== 1'b1)
      return bad("CQE receive flag is unknown", RDMA_SC_INVALID_ARGUMENT);
    if (srfq !== 1'b0 && srfq !== 1'b1)
      return bad("CQE SRFQ flag is unknown", RDMA_SC_INVALID_ARGUMENT);

    // 设计说明：receive CQE 的 overlay 虽然不依赖 RC/UD/URC 的 send
    // union，但其 QP route 仍必须来自受支持的 transport。先做 route
    // authority 校验，再允许 RQ/SRFQ overlay，避免 CUSTOM/RESERVED link
    // 借 receive 标志绕过 transport gate。
    case (transport)
      RDMA_TRANSPORT_RC,
      RDMA_TRANSPORT_UD,
      RDMA_TRANSPORT_URC: begin end
      default:
        return bad("CQE route transport is invalid", RDMA_SC_INVALID_STATE);
    endcase

    if (rq_cqe) begin
      variant = RDMA_CQE_VARIANT_RQ_SRFQ;
      return rdma_status::success();
    end
    if (srfq)
      return bad("CQE send cannot set SRFQ", RDMA_SC_INVALID_ARGUMENT);

    case (transport)
      RDMA_TRANSPORT_UD:
        variant = RDMA_CQE_VARIANT_UD;
      RDMA_TRANSPORT_RC,
      RDMA_TRANSPORT_URC:
        variant = RDMA_CQE_VARIANT_RC;
      default:
        return bad("CQE route transport is invalid", RDMA_SC_INVALID_STATE);
    endcase
    return rdma_status::success();
  endfunction

  // 功能：validate_cqe_srfq_route_consistency 将 CQE 的 receive/SRFQ wire 标志与
  //   冻结 QP link 的 SRQ 拓扑对齐，阻止同一 QPN 被错误地导向私有 RQ 或 shared
  //   SRQ ledger。
  // 输入/输出及副作用：rq_cqe、srfq、link 为只读输入；函数返回独立
  //   rdma_status，不修改 model、link、attachment、runtime、cursor、backing 或
  //   recovery evidence，也不查询或创建任何资源。
  // 失败/边界：link/QP handle 为空、标志含 X/Z、send CQE 携带 srfq，或 receive
  //   CQE 的 srfq 与 `link.srq_h != null` 不相等时返回 INVALID_STATE 或
  //   INVALID_ARGUMENT；成功只证明 wire route 与 SRQ presence 一致，仍需由调用方
  //   继续完成 QP identity、attachment、WQE ledger 和 polarity 校验。
  protected function rdma_status validate_cqe_srfq_route_consistency(
    input logic rq_cqe,
    input logic srfq,
    input rdma_queue_data_qp_link link
  );
    bit route_uses_srq;

    if (link == null || link.qp_h == null ||
        link.qp_h.kind !== RDMA_RESOURCE_QP)
      return bad("CQE SRFQ route authority is incomplete",
                 RDMA_SC_INVALID_STATE);
    if (link.srq_h != null && link.srq_h.kind !== RDMA_RESOURCE_SRQ)
      return bad("CQE SRFQ route SRQ handle kind is invalid",
                 RDMA_SC_INVALID_STATE);
    if (rq_cqe !== 1'b0 && rq_cqe !== 1'b1)
      return bad("CQE receive flag is unknown", RDMA_SC_INVALID_ARGUMENT);
    if (srfq !== 1'b0 && srfq !== 1'b1)
      return bad("CQE SRFQ flag is unknown", RDMA_SC_INVALID_ARGUMENT);
    if (!rq_cqe) begin
      if (srfq)
        return bad("CQE send cannot set SRFQ", RDMA_SC_INVALID_ARGUMENT);
      return rdma_status::success();
    end

    route_uses_srq = (link.srq_h != null);
    if (srfq !== route_uses_srq)
      return bad("CQE SRFQ flag disagrees with QP receive route",
                 RDMA_SC_INVALID_ARGUMENT);
    return rdma_status::success();
  endfunction

  // 功能：validate_cqe_variant_consistency 比较 CQE model 的显式 variant 与已冻结
  //   QP link authority，阻止错误 overlay 在 producer reservation 前进入编码阶段。
  // 输入/输出及副作用：model、link 为只读输入；返回独立 rdma_status，不修改
  //   model、link、attachment、runtime、cursor、backing 或 recovery ownership。
  // 失败/边界：model/link 为空、receive/SRFQ 标志或 route transport 未知、send CQE
  //   带 srfq、SRFQ 与 QP 的 SRQ presence 不一致，或显式 variant 与期望的
  //   RQ_SRFQ/UD/RC 不一致时返回错误；成功只表示 authority 一致，不代表 WQE
  //   ledger 或 CQ polarity 已经通过后续校验。
  protected function rdma_status validate_cqe_variant_consistency(
    input rdma_hw_cqe_model model,
    input rdma_queue_data_qp_link link
  );
    rdma_cqe_variant_e expected_variant;
    rdma_status status;

    if (model == null || link == null)
      return bad("CQE variant authority is incomplete", RDMA_SC_INVALID_STATE);
    status = resolve_cqe_variant_for_route(
      model.rq_cqe, model.srfq, link.transport, expected_variant);
    if (status == null || !status.ok())
      return status == null ?
        bad("CQE variant route resolver returned null status",
            RDMA_SC_INVALID_STATE) : status;
    status = validate_cqe_srfq_route_consistency(
      model.rq_cqe, model.srfq, link);
    if (status == null || !status.ok())
      return status == null ?
        bad("CQE SRFQ route validation returned null status",
            RDMA_SC_INVALID_STATE) : status;
    if (model.variant !== expected_variant)
      return bad($sformatf(
        "CQE variant does not match QP transport (expected=%0d actual=%0d)",
        expected_variant, model.variant), RDMA_SC_INVALID_ARGUMENT);
    return rdma_status::success();
  endfunction

  // 设计说明：CQE 的 qword2/qword3 是物理 union，不能由 CQ attachment 上保存的
  //   transport 猜测 overlay；必须先锁定携带完整 QP authority 的 qp_link，再以该
  //   link 的 transport 和 CQE receive/SRFQ 标志共同决定 variant。publish 与 poll
  //   decode 共用同一只读解析 helper，避免共享 CQ 上 RC/UD/URC QP 交错时出现不同
  //   解释。该阶段只做 admission，reservation、codec、backing write 及 recovery
  //   commit 继续由 task 独占，避免校验阶段产生不可回滚的 runtime mutation。
  // 功能：按既有失败顺序校验 CQ handle/attachment/route、CQE model Function 与
  //   generation、QP link、QPN wire 范围、transport-aware CQE variant 以及 routed
  //   SQ/RQ/SRQ 的 WQE release range，成功返回后续 publish 所需的三个 canonical
  //   authority 引用。
  // 输入/输出及副作用：cq_h、model 为只读输入；attachment、wqe_attachment、link
  //   先清空，成功时分别返回 CQ、WQE 和 QP route 的非拥有引用；函数只查询 registry、
  //   binding 与 runtime 校验，不 reserve producer、编码/写入 CQE、不推进 cursor，
  //   不取得或转移 backing、QP、CQ 或 WQE 生命周期所有权。
  // 失败/边界：null status 会被归一化为原有 INVALID_STATE/各阶段错误；handle、
  //   attachment/route/epoch、model/status、Function UID/generation、link identity
  //   （由 same_handle_instance 比较）、QPN 表示范围、variant/transport 一致性、
  //   WQE attachment 或 release range 任一拒绝时返回首个具体错误，
  //   输出引用保持 null，调用方不得进入 reservation 或 encode/write 阶段。
  protected function rdma_status validate_cqe_publish_authority(
    input rdma_handle cq_h,
    input rdma_hw_cqe_model model,
    output rdma_queue_data_attachment attachment,
    output rdma_queue_data_attachment wqe_attachment,
    output rdma_queue_data_qp_link link
  );
    rdma_status status;

    attachment = null;
    wqe_attachment = null;
    link = null;
    status = ensure_handle(cq_h, RDMA_RESOURCE_CQ);
    if (status == null || !status.ok()) begin
      if (status == null)
        status = bad("CQ handle validation returned null status",
                     RDMA_SC_INVALID_STATE);
      return status;
    end
    status = lookup_attachment(cq_h, RDMA_QUEUE_RUNTIME_CQ, attachment);
    if (status == null || !status.ok()) begin
      status = status == null ?
        bad("CQ publish attachment lookup returned null status",
            RDMA_SC_INVALID_STATE) : status;
      return status;
    end
    if (attachment == null || attachment.runtime == null ||
        attachment.access == null || attachment.entry_size == 0)
      return bad("CQ publish attachment is incomplete", RDMA_SC_INVALID_STATE);
    status = validate_attachment_route_epoch(attachment);
    if (status == null || !status.ok()) begin
      status = status == null ?
        bad("CQ publish route validation returned null status",
            RDMA_SC_INVALID_STATE) : status;
      return status;
    end
    if (model == null || model.qp_h == null || model.status == null)
      return bad("CQE model authority/status is incomplete");
    status = model.validate();
    if (status == null || !status.ok()) begin
      if (status == null)
        status = bad("CQE model validation returned null status",
                     RDMA_SC_INVALID_STATE);
      return status;
    end
    if (binding == null || model.qp_h.function_uid != binding.function_uid)
      return bad("CQE QP Function UID does not match CQ attachment");
    if (model.qp_h.generation != binding.generation)
      return bad("CQE QP generation is stale", RDMA_SC_STALE_GENERATION);
    status = find_qp_link_for_cq(cq_h, model.qpn, model.rq_cqe, link);
    if (status == null || !status.ok()) begin
      status = status == null ?
        bad("CQE QP route lookup returned null status", RDMA_SC_INVALID_STATE) :
        status;
      return status;
    end
    if (link == null || link.qp_h == null ||
        !value_ops::same_handle_instance(link.qp_h, model.qp_h))
      return bad("CQE QP authority does not match CQ route",
                 RDMA_SC_INVALID_STATE);
    if (link.local_qp_id > 18'h3ffff)
      return bad("CQE QPN cannot represent attached QP",
                 RDMA_SC_INVALID_ARGUMENT);
    status = validate_cqe_variant_consistency(model, link);
    if (status == null || !status.ok()) begin
      status = status == null ?
        bad("CQE variant consistency validation returned null status",
            RDMA_SC_INVALID_STATE) : status;
      return status;
    end
    if (model.rq_cqe) begin
      if (link.srq_h != null)
        status = lookup_attachment(link.srq_h, RDMA_QUEUE_RUNTIME_SRQ,
                                   wqe_attachment);
      else
        status = lookup_attachment(link.qp_h, RDMA_QUEUE_RUNTIME_RQ,
                                   wqe_attachment);
    end
    else begin
      status = lookup_attachment(link.qp_h, RDMA_QUEUE_RUNTIME_SQ,
                                 wqe_attachment);
    end
    if (status == null || !status.ok()) begin
      status = status == null ?
        bad("CQE WQE attachment lookup returned null status",
            RDMA_SC_INVALID_STATE) : status;
      return status;
    end
    if (wqe_attachment == null || wqe_attachment.runtime == null)
      return bad("CQE WQE attachment is incomplete", RDMA_SC_INVALID_STATE);
    status = wqe_attachment.runtime.validate_release_range(
      model.wqe_index, model.wqe_wrap);
    if (status == null || !status.ok()) begin
      status = status == null ?
        bad("CQE WQE release validation returned null status",
            RDMA_SC_INVALID_STATE) : status;
      return status;
    end
    return rdma_status::success();
  endfunction

  // 功能：reserve_device_publish_checked 统一 CQE、CEQE 与 AEQE 的设备 producer
  //   reservation admission，在进入各自 authority/编码阶段前取得唯一 runtime
  //   cursor，并把 reserve 的 null/失败结果收敛为可观察 status。
  // 输入/输出及副作用：attachment、reservation_label 为输入；reservation/status
  //   为输出并先清空。成功时 reservation 是 runtime 内部保留 reservation 的
  //   detached cursor 快照；task 不编码、不写 backing、不推进 committed cursor，
  //   也不取得外部资源所有权。
  // 失败/边界：attachment/runtime 缺失、reserve 返回 null/非成功或成功却没有
  //   cursor 时返回非空 INVALID_STATE（保留 runtime 的非成功码），并清零
  //   reservation；调用方不得在该 task 失败后进入 codec、Host-memory 或 commit。
  protected task reserve_device_publish_checked(
    input rdma_queue_data_attachment attachment,
    input string reservation_label,
    output rdma_queue_cursor_snapshot reservation,
    output rdma_status status
  );
    reservation = null;
    status = null;
    if (attachment == null || attachment.runtime == null) begin
      status = rdma_status::make_direct(
        RDMA_SC_INVALID_STATE,
        {reservation_label, " attachment/runtime is incomplete"});
      return;
    end

    status = attachment.runtime.reserve_device_producer(reservation);
    if (status == null || !status.ok()) begin
      if (status == null)
        status = rdma_status::make_direct(
          RDMA_SC_INVALID_STATE,
          {reservation_label, " returned null status"});
      reservation = null;
      return;
    end
    if (reservation == null) begin
      status = rdma_status::make_direct(
        RDMA_SC_INVALID_STATE,
        {reservation_label, " returned no reservation"});
      return;
    end
  endtask

  // 功能：check_device_publish_polarity 比较 caller image 的 owner/polarity 与已
  //   取得 reservation 的 expected producer polarity；不把 CQE/CEQE/AEQE 的
  //   authority、wire encode 或 AEQE route/epoch 复核混入共享 admission。
  // 输入/输出及副作用：attachment、reservation、actual_polarity、错误文本为输入；
  //   status 为输出并先清空，reservation 是 inout：匹配时保持原值供 caller
  //   继续编码；不匹配或输入不完整时清零。匹配不改变 runtime；不匹配时调用
  //   既有 finish_device_producer_cancel，成功取消不推进 committed cursor，失败
  //   则保留 runtime/engine recovery evidence。
  // 失败/边界：attachment/runtime/reservation 缺失返回 INVALID_STATE；actual
  //   polarity 与 expected 值不一致时返回原 polarity 错误或 RECOVERY_REQUIRED，
  //   并清零 reservation；finish/cancel 返回 null 也归一化为非空恢复状态，caller
  //   不得把清零后的句柄继续用于 write_commit_device_entry。
  protected task check_device_publish_polarity(
    input rdma_queue_data_attachment attachment,
    inout rdma_queue_cursor_snapshot reservation,
    input bit actual_polarity,
    input string polarity_error_label,
    input string cancel_context,
    output rdma_status status
  );
    rdma_status original_status;
    bit expected_polarity;

    status = null;
    if (attachment == null || attachment.runtime == null ||
        reservation == null) begin
      status = rdma_status::make_direct(
        RDMA_SC_INVALID_STATE,
        {cancel_context, " polarity validation input is incomplete"});
      reservation = null;
      return;
    end
    expected_polarity = attachment.runtime.expected_producer_polarity(
      reservation);
    if (actual_polarity !== expected_polarity) begin
      original_status = rdma_status::make_direct(
        RDMA_SC_INVALID_ARGUMENT, polarity_error_label);
      finish_device_producer_cancel(
        attachment, reservation, null, original_status, cancel_context, status);
      if (status == null)
        status = rdma_status::make_direct(
          RDMA_SC_RECOVERY_REQUIRED,
          {cancel_context, " returned null status"});
      reservation = null;
      return;
    end
    status = rdma_status::make_direct(RDMA_SC_OK);
  endtask

  // 功能：publish_cqe 校验 CQE 的 Function/QP/WQE authority，随后经公共设备生产
  //   pipeline 写入 CQ backing 并提交 producer cursor。
  // 输入/输出及副作用：cq_h、model 为只读输入，result/status 为输出；成功时仅
  //   写入 CQ host-memory 并更新 CQ occupancy，不修改 model、不发 producer doorbell。
  // 失败/边界：任一身份、路由、polarity、编码或事务失败均不发布 result；reservation
  //   后的纯失败尝试 cancel，写入 backend 后的失败必须进入 recovery。
  task publish_cqe(
    rdma_handle cq_h, rdma_hw_cqe_model model,
    output rdma_queue_device_publish_result result,
    output rdma_status status
  );
    rdma_queue_data_attachment attachment;
    rdma_queue_data_attachment wqe_attachment;
    rdma_queue_data_qp_link link;
    rdma_queue_cursor_snapshot reservation;
    rdma_codec_key key;
    rdma_codec_base base_codec;
    rdma_hw_cqe_codec cqe_codec;
    rdma_hw_image image;
    rdma_status original_status;

    result = null;
    status = null;
    reservation = null;
    link = null;
    wqe_attachment = null;
    image = null;

    status = validate_cqe_publish_authority(
      cq_h, model, attachment, wqe_attachment, link
    );
    if (status == null || !status.ok()) begin
      if (status == null)
        status = bad("CQE publish authority validation returned null status",
                     RDMA_SC_INVALID_STATE);
      return;
    end

    reserve_device_publish_checked(
      attachment, "CQ device reservation", reservation, status);
    if (status == null || !status.ok()) begin
      if (status == null)
        status = rdma_status::make_direct(
          RDMA_SC_INVALID_STATE,
          "CQE device reservation helper returned null status");
      return;
    end
    check_device_publish_polarity(
      attachment, reservation, model.polarity,
      "CQE producer polarity does not match reservation",
      "CQE polarity", status);
    if (status == null || !status.ok()) begin
      if (status == null)
        status = rdma_status::make_direct(
          RDMA_SC_INVALID_STATE,
          "CQE polarity helper returned null status");
      return;
    end
    key = '{hw_version:"rdma", image_kind:RDMA_IMAGE_CQE,
      object_type:"cqe", variant:"default", opcode:8'h00};
    status = registry.lookup(key, base_codec);
    if (status == null || !status.ok()) begin
      if (status == null)
        status = bad("CQE codec lookup returned null status",
                     RDMA_SC_CODEC_ERROR);
      original_status = status;
      finish_device_producer_cancel(attachment, reservation, null,
                                    original_status, "CQE codec lookup", status);
      return;
    end
    if (!$cast(cqe_codec, base_codec) || cqe_codec == null) begin
      original_status = bad("CQ registry codec type mismatch",
                            RDMA_SC_CODEC_ERROR);
      finish_device_producer_cancel(attachment, reservation, null,
                                    original_status, "CQE codec cast", status);
      return;
    end
    // 使用局部 image 接收无状态编码结果，避免在 commit 前把半成品写入 result。
    // 编码器只读取 entry_size，本次调用不会修改 registry 中共享的 active_bytes。
    status = cqe_codec.encode_with_entry_bytes(model, attachment.entry_size,
                                               image);
    if (status == null || !status.ok()) begin
      if (status == null)
        status = bad("CQE encode returned null status", RDMA_SC_CODEC_ERROR);
      original_status = status;
      finish_device_producer_cancel(attachment, reservation, null,
                                    original_status, "CQE encode", status);
      return;
    end
    if (image == null) begin
      original_status = bad("CQE encoder returned no image",
                            RDMA_SC_CODEC_ERROR);
      finish_device_producer_cancel(attachment, reservation, null,
                                    original_status, "CQE image", status);
      return;
    end
    write_commit_device_entry(attachment, reservation, image, result, status);
  endtask

  // 设计说明：CEQE 只有在 CEQ、来源 CQ、可选 QP route 和 profile authority
  //   全部冻结后才能申请 producer reservation。该 helper 把 admission 与后续
  //   transaction 分开，调用方拿到的 attachment 与 encode_model 都是本次 task
  //   可继续使用的非拥有引用/值副本，不能借此改写 lifecycle 或 runtime 所有权。
  // 功能：按既有失败顺序校验 CEQ handle/attachment、CQ route 与 generation、
  //   CEQ→CQ dependency、可选 QP link、已提交 CQ cursor 以及 RC/URC profile，
  //   并克隆一个绑定 CQ transport authority 的编码模型。
  // 输入/输出及副作用：ceq_h、model 为只读输入；attachment、encode_model 先清空，
  //   成功时分别返回 CEQ 的 engine-owned 非拥有 attachment 和 detached model；函数
  //   只查询 registry/binding/runtime 并复制 model，不 reserve、编码、写 backing、
  //   推进 cursor、cancel/commit/recovery 或取得任何外部资源所有权。
  // 失败/边界：handle、CEQ/CQ route/epoch、model authority、Function UID/generation、
  //   QP route、CQ producer PI 宽度或 RC cursor 一致性任一失败时返回首个具体错误；
  //   same_handle_instance 只比较完整 handle incarnation，null status 仍归一化为
  //   原有 INVALID_STATE/各阶段错误，输出保持 null，调用方不得
  //   进入 reservation 或 codec 阶段。
  protected function rdma_status validate_ceqe_publish_authority(
    input rdma_handle ceq_h,
    input rdma_hw_ceqe_model model,
    output rdma_queue_data_attachment attachment,
    output rdma_hw_ceqe_model encode_model
  );
    rdma_queue_data_attachment ceq_attachment;
    rdma_queue_data_attachment cq_attachment;
    rdma_queue_data_qp_link link;
    rdma_handle routed_cq_h;
    uvm_object raw_encode_model;
    rdma_status status;
    int unsigned producer_index;
    int unsigned consumer_index;
    bit producer_wrap;
    bit consumer_wrap;

    attachment = null;
    ceq_attachment = null;
    encode_model = null;
    cq_attachment = null;
    link = null;
    routed_cq_h = null;
    raw_encode_model = null;
    producer_index = 0;
    consumer_index = 0;
    producer_wrap = 1'b0;
    consumer_wrap = 1'b0;

    status = ensure_handle(ceq_h, RDMA_RESOURCE_CEQ);
    if (status == null || !status.ok()) begin
      if (status == null)
        status = bad("CEQE handle validation returned null status",
                     RDMA_SC_INVALID_STATE);
      return status;
    end
    status = lookup_attachment(ceq_h, RDMA_QUEUE_RUNTIME_CEQ, ceq_attachment);
    if (status == null || !status.ok()) begin
      status = status == null ? bad("CEQE attachment lookup returned null status",
                                    RDMA_SC_INVALID_STATE) : status;
      return status;
    end
    status = validate_attachment_route_epoch(ceq_attachment);
    if (status == null || !status.ok()) begin
      status = status == null ? bad("CEQE route validation returned null status",
                                    RDMA_SC_INVALID_STATE) : status;
      return status;
    end
    if (model == null || model.cq_h == null) begin
      status = bad("CEQE model CQ authority is incomplete");
      return status;
    end
    status = model.validate();
    if (status == null || !status.ok()) begin
      status = status == null ? bad("CEQE model validation returned null status",
                                    RDMA_SC_INVALID_STATE) : status;
      return status;
    end
    if (binding == null || model.cq_h.function_uid != binding.function_uid ||
        model.cq_h.generation != binding.generation) begin
      status = bad("CEQE CQ Function/generation authority is stale",
                   model.cq_h != null && binding != null &&
                   model.cq_h.generation != binding.generation ?
                   RDMA_SC_STALE_GENERATION : RDMA_SC_INVALID_ARGUMENT);
      return status;
    end
    status = find_cq_handle_for_local_id(model.cqn, routed_cq_h);
    if (status == null || !status.ok()) begin
      status = status == null ? bad("CEQE CQ route lookup returned null status",
                                    RDMA_SC_INVALID_STATE) : status;
      return status;
    end
    if (routed_cq_h == null ||
        !value_ops::same_handle_instance(routed_cq_h, model.cq_h)) begin
      status = bad("CEQE CQ authority does not match attached route",
                   RDMA_SC_INVALID_STATE);
      return status;
    end
    status = lookup_attachment(routed_cq_h, RDMA_QUEUE_RUNTIME_CQ,
                               cq_attachment);
    if (status == null || !status.ok()) begin
      status = status == null ? bad("CEQE routed CQ attachment is null",
                                    RDMA_SC_INVALID_STATE) : status;
      return status;
    end
    status = validate_attachment_route_epoch(cq_attachment);
    if (status == null || !status.ok()) begin
      status = status == null ? bad("CEQE CQ route validation returned null status",
                                    RDMA_SC_INVALID_STATE) : status;
      return status;
    end

    // CEQE canonical authoring uses the live CQ attachment as the sole profile
    // authority. Clone the caller's value before freezing that authority so the
    // publish cannot mutate a model that may still be reused by a test or producer.
    raw_encode_model = model.clone();
    if (raw_encode_model == null || !$cast(encode_model, raw_encode_model)) begin
      encode_model = null;
      status = bad("CEQE encode model clone failed", RDMA_SC_RESOURCE_EXHAUSTED);
      return status;
    end
    status = encode_model.set_profile_transport_authority(
      cq_attachment.transport);
    if (status == null || !status.ok()) begin
      encode_model = null;
      status = status == null ?
        bad("CEQE profile authority setup returned null status",
            RDMA_SC_INVALID_STATE) : status;
      return status;
    end
    // 设计说明：CEQ route 不由调用参数或 qpn 推断。attach_cq 已从 authoritative
    // CQ 冻结 ceq_h 值快照；必须在 reserve 前对比完整 instance，才能让 qpn=0
    // 的通用 CQ 通知也无法越过 CQ 创建时选择的 event queue/vector。
    if (cq_attachment.ceq_h == null ||
        !value_ops::same_handle_instance(cq_attachment.ceq_h, ceq_h)) begin
      encode_model = null;
      status = bad("CEQE target CEQ does not match CQ dependency",
                   RDMA_SC_INVALID_STATE);
      return status;
    end
    // 设计说明：CEQE 的核心 route authority 是 cqn/cq_h；qpn=0 表示通知不绑定
    // 某个 QP，属于协议允许的通用 CQ 通知。只有调用方显式给出非零 qpn 时才要求
    // 它命中当前 Function 已 attach 的唯一 QP link，不能把 0 当成隐式 QP；send/
    // recv CQ route 的空值与完整 identity 由 qp_link_cq_route_matches 统一判断。
    if (model.qpn != 0) begin
      status = find_qp_link_for_local_id(model.qpn, link);
      if (status == null || !status.ok()) begin
        status = status == null ? bad("CEQE QP route lookup returned null status",
                                      RDMA_SC_INVALID_STATE) : status;
        encode_model = null;
        return status;
      end
      if (link == null ||
          (!value_ops::qp_link_cq_route_matches(link, routed_cq_h, 1'b0) &&
           !value_ops::qp_link_cq_route_matches(link, routed_cq_h, 1'b1))) begin
        encode_model = null;
        status = bad("CEQE QPN is not associated with routed CQ",
                     RDMA_SC_INVALID_STATE);
        return status;
      end
    end
    status = query_runtime_cursors(routed_cq_h, RDMA_QUEUE_RUNTIME_CQ,
                                   producer_index, producer_wrap,
                                   consumer_index, consumer_wrap);
    if (status == null || !status.ok()) begin
      status = status == null ? bad("CEQE CQ cursor query returned null status",
                                    RDMA_SC_INVALID_STATE) : status;
      encode_model = null;
      return status;
    end
    if (producer_index > 16'hffff) begin
      encode_model = null;
      status = bad("CEQE CQ producer index cannot fit in 16 bits",
                   RDMA_SC_INVALID_ARGUMENT);
      return status;
    end
    // 设计说明：驱动 defs.h 将 CEQE qword1 复用为两种互斥布局。RC CEQE
    // 发布 CQ consumer index，必须匹配已提交 CQ producer；URC CEQE 的同一
    // qword1 改为 abnormal/WQE/SQ/RQ completion，不应被 RC cursor 规则拦截。
    // 输入/输出及副作用：model.urc_flag 只决定校验分支；RC 分支只读
    // producer_index/producer_wrap，URC 分支不修改任何 CQ runtime 状态。
    // 失败/边界：仅 RC 的 cq_pi/cq_pi_wrap 不匹配返回 INVALID_ARGUMENT；URC
    // 字段的位宽、互斥与保留位仍由 CEQE codec 逐位校验。
    if (!encode_model.urc_flag &&
        (encode_model.cq_pi != producer_index[15:0] ||
         encode_model.cq_pi_wrap != producer_wrap)) begin
      encode_model = null;
      status = bad("CEQE CQ producer cursor is not committed cursor",
                   RDMA_SC_INVALID_ARGUMENT);
      return status;
    end
    attachment = ceq_attachment;
    return rdma_status::success();
  endfunction

  // 功能：publish_ceqe 在 CEQ backing 发布一个已经由 CQ producer 提交的通知，
  //   使 CEQ poll 只负责 route CQ 而不会替 CQ 生成或消费 completion。
  // 输入/输出及副作用：ceq_h、model 为只读输入，result/status 为输出；成功时写入
  //   16B CEQ ring 并推进 CEQ producer，不修改 CQ cursor、model 或 WQE ledger。
  // 失败/边界：CEQ/CQ/QP authority、generation、RC CEQE 的已提交 PI/16 位 PI、
  //   polarity、full ring 或 codec 失败时 result 保持 null；预写失败取消 reservation，
  //   写后失败保留 pending/recovery evidence，不能改变 backing、cursor 或 committed
  //   occupancy。
  virtual task publish_ceqe(
    rdma_handle ceq_h,
    rdma_hw_ceqe_model model,
    output rdma_queue_device_publish_result result,
    output rdma_status status
  );
    rdma_queue_data_attachment attachment;
    rdma_queue_cursor_snapshot reservation;
    rdma_codec_key key;
    rdma_codec_base base_codec;
    rdma_hw_ceqe_codec ceqe_codec;
    rdma_hw_ceqe_model encode_model;
    rdma_hw_image image;
    rdma_status original_status;

    result = null;
    status = null;
    attachment = null;
    reservation = null;
    encode_model = null;
    image = null;
    status = validate_ceqe_publish_authority(
      ceq_h, model, attachment, encode_model
    );
    if (status == null || !status.ok()) begin
      if (status == null)
        status = bad("CEQE authority validation returned null status",
                     RDMA_SC_INVALID_STATE);
      return;
    end
    reserve_device_publish_checked(
      attachment, "CEQE device reservation", reservation, status);
    if (status == null || !status.ok()) begin
      if (status == null)
        status = rdma_status::make_direct(
          RDMA_SC_INVALID_STATE,
          "CEQE reservation helper returned null status");
      return;
    end
    check_device_publish_polarity(
      attachment, reservation, model.valid,
      "CEQE producer polarity does not match reservation",
      "CEQE polarity", status);
    if (status == null || !status.ok()) begin
      if (status == null)
        status = rdma_status::make_direct(
          RDMA_SC_INVALID_STATE,
          "CEQE polarity helper returned null status");
      return;
    end
    key = '{hw_version:"rdma", image_kind:RDMA_IMAGE_CEQE,
      object_type:"ceqe", variant:"default", opcode:8'h00};
    status = registry.lookup(key, base_codec);
    if (status == null || !status.ok()) begin
      original_status = status == null ?
        bad("CEQE codec lookup returned null status", RDMA_SC_CODEC_ERROR) : status;
      finish_device_producer_cancel(attachment, reservation, null,
                                    original_status, "CEQE codec lookup", status);
      return;
    end
    if (!$cast(ceqe_codec, base_codec) || ceqe_codec == null) begin
      original_status = bad("CEQE registry codec type mismatch", RDMA_SC_CODEC_ERROR);
      finish_device_producer_cancel(attachment, reservation, null,
                                    original_status, "CEQE codec cast", status);
      return;
    end
    status = ceqe_codec.encode(encode_model, image);
    if (status == null || !status.ok() || image == null ||
        image.length != 16 || image.bytes.size() != 16) begin
      original_status = status == null ?
        bad("CEQE encode returned null status", RDMA_SC_CODEC_ERROR) :
        (!status.ok() ? status : bad("CEQE codec did not return fixed 16B image",
                                     RDMA_SC_CODEC_ERROR));
      finish_device_producer_cancel(attachment, reservation, null,
                                    original_status, "CEQE encode", status);
      return;
    end
    write_commit_device_entry(attachment, reservation, image, result, status);
  endtask

  // 设计说明：publish_aeqe 的 admission 只冻结 AEQ attachment、wire class 以及
  //   ecode 派生的 primary/secondary route；codec 所需的 model clone、profile
  //   authority 和 backing transaction 仍由调用 task 独占，避免校验层提前产生
  //   reservation 或不可回滚的设备副作用。
  // 功能：按既有失败顺序校验 AEQ handle/attachment/epoch、AEQE wire 字段和
  //   Function binding，并解析普通事件或 CQ flush 的完整 caller authority，返回
  //   后续编码与发布阶段所需的 route 快照和 CQ-flush 判定。
  // 输入/输出及副作用：aeq_h、model、secondary_target_h 为只读输入；attachment、
  //   event_class、primary_route_h、secondary_route_h、found bits 与 is_cq_flush
  //   先清空，成功时返回 engine-owned attachment 引用和 detached route 快照。函数
  //   只读取 manager/binding、校验 route epoch 并克隆句柄值，不修改 model、
  //   runtime、cursor、backing 或外部资源生命周期，也不 reserve/编码/write/commit。
  // 失败/边界：handle、attachment/epoch、model/wire、binding、route lookup、CQ flush
  //   双 caller kind/instance/Function/generation，或普通事件 secondary/target 一致性
  //   任一拒绝均返回原有首个具体状态；null status 归一化为 INVALID_STATE，输出保留
  //   清空值，调用方不得进入 clone、codec 或 reservation 阶段。
  protected function rdma_status validate_aeqe_publish_authority(
    input rdma_handle aeq_h,
    input rdma_hw_aeqe_model model,
    input rdma_handle secondary_target_h,
    output rdma_queue_data_attachment attachment,
    output rdma_aeqe_event_class_e event_class,
    output rdma_handle primary_route_h,
    output rdma_handle secondary_route_h,
    output bit primary_found,
    output bit secondary_found,
    output bit is_cq_flush
  );
    rdma_status status;
    rdma_queue_data_attachment candidate_attachment;
    rdma_aeqe_event_class_e candidate_event_class;
    rdma_handle candidate_primary_route_h;
    rdma_handle candidate_secondary_route_h;
    bit candidate_primary_found;
    bit candidate_secondary_found;
    bit candidate_is_cq_flush;

    attachment = null;
    event_class = RDMA_AEQE_EVENT_QP;
    primary_route_h = null;
    secondary_route_h = null;
    primary_found = 1'b0;
    secondary_found = 1'b0;
    is_cq_flush = 1'b0;
    candidate_attachment = null;
    candidate_event_class = RDMA_AEQE_EVENT_QP;
    candidate_primary_route_h = null;
    candidate_secondary_route_h = null;
    candidate_primary_found = 1'b0;
    candidate_secondary_found = 1'b0;
    candidate_is_cq_flush = 1'b0;

    status = ensure_handle(aeq_h, RDMA_RESOURCE_AEQ);
    if (status == null || !status.ok()) begin
      if (status == null)
        status = bad("AEQE handle validation returned null status",
                     RDMA_SC_INVALID_STATE);
      return status;
    end
    status = lookup_attachment(
      aeq_h, RDMA_QUEUE_RUNTIME_AEQ, candidate_attachment);
    if (status == null || !status.ok()) begin
      status = status == null ? bad("AEQE attachment lookup returned null status",
                                    RDMA_SC_INVALID_STATE) : status;
      return status;
    end
    status = validate_attachment_route_epoch(candidate_attachment);
    if (status == null || !status.ok()) begin
      status = status == null ? bad("AEQE route validation returned null status",
                                    RDMA_SC_INVALID_STATE) : status;
      return status;
    end
    if (model == null)
      return bad("AEQE model is null", RDMA_SC_INVALID_ARGUMENT);

    // 设计说明：wire 字段与 owner route 是两类不同 authority。先检查不依赖
    // target_h 的 qp_state/severity 等物理约束，再让 event.c 对 ecode 的分派
    // 决定 primary owner；这样 SRQ/CQ/EQ/Function 事件不必伪造 QP handle。
    status = model.validate_wire_fields();
    if (status == null || !status.ok()) begin
      status = status == null ? bad("AEQE wire validation returned null status",
                                    RDMA_SC_INVALID_STATE) : status;
      return status;
    end
    if (binding == null)
      return bad("AEQE Function binding is unavailable", RDMA_SC_INVALID_STATE);

    // 设计说明：route 是唯一的 owner authority。resolve_aeqe_routes 只读取
    // ecode、QPN/SRFQN/CQN/EQN wire 坐标和当前 Function manager，不读取
    // srfq_en，也不把 caller 的 target_h 当作分类器。
    status = resolve_aeqe_routes(
      model, candidate_event_class, candidate_primary_route_h,
      candidate_secondary_route_h, candidate_primary_found,
      candidate_secondary_found
    );
    if (status == null || !status.ok()) begin
      if (status == null)
        status = bad("AEQE route resolver returned null status",
                     RDMA_SC_INVALID_STATE);
      return status;
    end
    candidate_is_cq_flush = candidate_event_class == RDMA_AEQE_EVENT_CQ &&
                            model.packet_opcode[4:0] == 5'h1d;

    // 设计说明：CQ flush 的 split CQN 与 QPN 是并列 wire authority，sibling caller
    // 必须显式提供 CQ/QP 两个 live handle。双路由与双 caller 的 kind、实例、
    // 当前 Function UID/generation 在 clone/codec/reserve 前校验；instance 比较在
    // 这些非空/代际门禁后通过 same_handle_instance 完成，任何不一致都不能退化为
    // 单 owner publish，普通事件保留 primary 错误码与 null-target 兼容。
    if (candidate_is_cq_flush) begin
      if (model.target_h == null || secondary_target_h == null) begin
        return bad("AEQE CQ flush requires primary and secondary caller authority",
                   RDMA_SC_INVALID_ARGUMENT);
      end
      if (!candidate_primary_found || !candidate_secondary_found ||
          candidate_primary_route_h == null ||
          candidate_secondary_route_h == null ||
          model.target_h.kind != RDMA_RESOURCE_CQ ||
          secondary_target_h.kind != RDMA_RESOURCE_QP ||
          candidate_primary_route_h.function_uid != binding.function_uid ||
          candidate_secondary_route_h.function_uid != binding.function_uid ||
          model.target_h.function_uid != binding.function_uid ||
          secondary_target_h.function_uid != binding.function_uid ||
          candidate_primary_route_h.generation != binding.generation ||
          candidate_secondary_route_h.generation != binding.generation ||
          model.target_h.generation != binding.generation ||
          secondary_target_h.generation != binding.generation ||
          !value_ops::same_handle_instance(candidate_primary_route_h, model.target_h) ||
          !value_ops::same_handle_instance(candidate_secondary_route_h,
                                secondary_target_h)) begin
        return bad("AEQE CQ flush caller authority does not match live routes",
                   RDMA_SC_INVALID_STATE);
      end
    end
    else begin
      if (secondary_target_h != null)
        return bad("AEQE non-flush event cannot carry secondary caller authority",
                   RDMA_SC_INVALID_ARGUMENT);
      if (!candidate_primary_found || candidate_primary_route_h == null)
        return bad("AEQE owner route is not present", RDMA_SC_INVALID_STATE);
      if (candidate_primary_route_h.function_uid != binding.function_uid)
        return bad("AEQE resolved owner Function UID is stale",
                   RDMA_SC_INVALID_ARGUMENT);
      if (candidate_primary_route_h.generation != binding.generation)
        return bad("AEQE resolved owner generation is stale",
                   RDMA_SC_STALE_GENERATION);

      // caller 的 target_h 只作额外一致性证据，不能替代 route lookup。
      // 这保留旧 API 的 stale/foreign 检查，同时允许真实驱动的非 QP ecode
      // 以 null target 进入 publish。
      if (model.target_h != null) begin
        if (model.target_h.function_uid != binding.function_uid)
          return bad("AEQE target Function UID does not match AEQ attachment",
                     RDMA_SC_INVALID_ARGUMENT);
        if (model.target_h.generation != binding.generation)
          return bad("AEQE target generation is stale",
                     RDMA_SC_STALE_GENERATION);
        if (!value_ops::same_handle_instance(candidate_primary_route_h, model.target_h))
          return bad("AEQE target authority does not match ecode route",
                     RDMA_SC_INVALID_STATE);
      end
    end

    attachment = candidate_attachment;
    event_class = candidate_event_class;
    primary_route_h = candidate_primary_route_h;
    secondary_route_h = candidate_secondary_route_h;
    primary_found = candidate_primary_found;
    secondary_found = candidate_secondary_found;
    is_cq_flush = candidate_is_cq_flush;
    return rdma_status::success();
  endfunction

  // 功能：publish_aeqe 保留四参数 legacy ABI，并把无 secondary caller
  //   authority 的请求交给共享实现；普通事件兼容，CQ flush 明确拒绝缺权。
  // 输入/输出及副作用：aeq_h/model 为只读输入，result/status 由共享实现写出；
  //   本 wrapper 不自行访问 backing、申请 reservation 或持有 target handle。
  // 失败/边界：CQ flush 因固定传入 null secondary 而返回 INVALID_ARGUMENT；其余
  //   route/codec/full/epoch/polarity 状态沿用共享实现，旧四参数签名不得改变。
  virtual task publish_aeqe(
    rdma_handle aeq_h,
    rdma_hw_aeqe_model model,
    output rdma_queue_device_publish_result result,
    output rdma_status status
  );
    publish_aeqe_common(aeq_h, model, null, result, status);
  endtask

  // 功能：publish_aeqe_with_secondary 为 CQ flush 接收显式 QP caller authority，
  //   使 CQ 与 QP 两个 wire route 都能在 reserve 前与调用方句柄逐实例认证。
  // 输入/输出及副作用：aeq_h/model/secondary_target_h 为只读输入，result/status
  //   为输出；成功经共享实现写入固定 16B AEQ ring 并推进 producer。
  // 失败/边界：secondary 为空的 CQ flush、携带 secondary 的非 flush、任一路由或
  //   Function/generation 不匹配均在 reserve 前拒绝；wrapper 不取得句柄所有权。
  virtual task publish_aeqe_with_secondary(
    rdma_handle aeq_h,
    rdma_hw_aeqe_model model,
    rdma_handle secondary_target_h,
    output rdma_queue_device_publish_result result,
    output rdma_status status
  );
    publish_aeqe_common(
      aeq_h, model, secondary_target_h, result, status);
  endtask

  // 功能：在 rdma_queue_data_engine 中，prepare_aeqe_publish_image 将已解析的
  //   AEQE route authority 物化为独立 encode model，并在任何 producer reservation
  //   之前完成 registry lookup、typed codec dispatch 与固定 16B image staging。
  // 输入/输出及副作用：model、primary_route_h、event_class 为只读输入；encode_model
  //   与 image 为输出，成功时分别持有 primary route 的 detached clone 和完整 AEQE
  //   hardware image；函数只访问 codec registry/factory，不写 attachment、runtime、
  //   cursor、backing、pending 或外部资源生命周期。
  // 失败/边界：输入缺失、clone/cast、target snapshot、profile authority、registry
  //   lookup/type、codec null status/失败或非 16B image 均返回具体错误，并保持两个
  //   输出为 null；函数不 reserve、不写 Host-memory/MMIO，也不把失败 image 交给 caller。
  protected function rdma_status prepare_aeqe_publish_image(
    input rdma_hw_aeqe_model model,
    input rdma_handle primary_route_h,
    input rdma_aeqe_event_class_e event_class,
    output rdma_hw_aeqe_model encode_model,
    output rdma_hw_image image
  );
    rdma_codec_key key;
    rdma_codec_base base_codec;
    rdma_hw_aeqe_codec aeqe_codec;
    uvm_object raw_encode_model;
    rdma_handle encoded_target_h;
    rdma_status status;

    encode_model = null;
    image = null;
    if (model == null || primary_route_h == null)
      return bad("AEQE encode authority is incomplete",
                 RDMA_SC_INVALID_ARGUMENT);

    raw_encode_model = model.clone();
    if (raw_encode_model == null || !$cast(encode_model, raw_encode_model)) begin
      encode_model = null;
      return bad("AEQE encode model clone failed",
                 RDMA_SC_RESOURCE_EXHAUSTED);
    end
    encoded_target_h = rdma_clone_handle_value(
      primary_route_h, "AEQE encode target");
    if (encoded_target_h == null) begin
      encode_model = null;
      return bad("AEQE encode target snapshot allocation failed",
                 RDMA_SC_RESOURCE_EXHAUSTED);
    end
    encode_model.target_h = encoded_target_h;
    status = encode_model.set_profile_owner_authority(
      event_class, primary_route_h.kind);
    if (status == null || !status.ok()) begin
      encode_model = null;
      return status == null ?
        bad("AEQE profile authority setup returned null status",
            RDMA_SC_INVALID_STATE) : status;
    end
    key = '{hw_version:"rdma", image_kind:RDMA_IMAGE_AEQE,
      object_type:"aeqe", variant:"default", opcode:8'h00};
    status = registry.lookup(key, base_codec);
    if (status == null || !status.ok()) begin
      encode_model = null;
      return status == null ?
        bad("AEQE codec lookup returned null status", RDMA_SC_CODEC_ERROR) : status;
    end
    if (!$cast(aeqe_codec, base_codec) || aeqe_codec == null) begin
      encode_model = null;
      return bad("AEQE registry codec type mismatch", RDMA_SC_CODEC_ERROR);
    end
    status = aeqe_codec.encode(encode_model, image);
    if (status == null || !status.ok() || image == null ||
        image.length != 16 || image.bytes.size() != 16) begin
      encode_model = null;
      image = null;
      return status == null ?
        bad("AEQE encode returned null status", RDMA_SC_CODEC_ERROR) :
        (!status.ok() ? status : bad("AEQE codec did not return fixed 16B image",
                                     RDMA_SC_CODEC_ERROR));
    end
    return status;
  endfunction

  // 功能：publish_aeqe_common 统一执行 AEQE wire/双路由 authority preflight、完整
  //   16B encode、device reservation 与 backing commit，供 legacy/sibling API 共用。
  // 输入/输出及副作用：aeq_h/model/secondary_target_h 为只读输入；成功返回
  //   publish result、写 AEQ backing 并推进 PI，route/caller handle 都只按值克隆。
  // 失败/边界：CQ flush 必须同时命中 CQ/QP 且匹配两个 caller；普通事件只允许
  //   primary。preflight/encode 失败不 reserve，reserve 后 epoch/polarity 失败保持
  //   既有 cancel/recovery 语义，不发布半条 entry。
  protected task publish_aeqe_common(
    rdma_handle aeq_h,
    rdma_hw_aeqe_model model,
    rdma_handle secondary_target_h,
    output rdma_queue_device_publish_result result,
    output rdma_status status
  );
    rdma_queue_data_attachment attachment;
    rdma_queue_cursor_snapshot reservation;
    rdma_hw_image image;
    rdma_status original_status;
    rdma_hw_aeqe_model encode_model;
    rdma_aeqe_event_class_e event_class;
    rdma_handle primary_route_h;
    rdma_handle secondary_route_h;
    bit primary_found;
    bit secondary_found;
    bit is_cq_flush;

    result = null;
    status = null;
    attachment = null;
    reservation = null;
    image = null;
    status = validate_aeqe_publish_authority(
      aeq_h, model, secondary_target_h, attachment, event_class,
      primary_route_h, secondary_route_h, primary_found, secondary_found,
      is_cq_flush
    );
    if (status == null || !status.ok()) begin
      if (status == null)
        status = bad("AEQE publish authority validation returned null status",
                     RDMA_SC_INVALID_STATE);
      return;
    end

    status = prepare_aeqe_publish_image(
      model, primary_route_h, event_class, encode_model, image
    );
    if (status == null || !status.ok()) begin
      if (status == null)
        status = bad("AEQE publish image preparation returned null status",
                     RDMA_SC_INVALID_STATE);
      return;
    end

    reserve_device_publish_checked(
      attachment, "AEQE device reservation", reservation, status);
    if (status == null || !status.ok()) begin
      if (status == null)
        status = rdma_status::make_direct(
          RDMA_SC_INVALID_STATE,
          "AEQE reservation helper returned null status");
      return;
    end
    // 设计说明：preflight 与 reserve 之间 route/reset epoch 仍可能变化；取得
    // reservation 后必须重新验证冻结 attachment，再依据该 reservation 计算
    // polarity。此后的拒绝均通过 cancel/recovery 收口，预编码 image 只读复用。
    status = validate_attachment_route_epoch(attachment);
    if (status == null || !status.ok()) begin
      original_status = status == null ?
        bad("AEQE post-reservation route validation returned null status",
            RDMA_SC_INVALID_STATE) : status;
      finish_device_producer_cancel(attachment, reservation, null,
                                    original_status, "AEQE route epoch", status);
      return;
    end
    check_device_publish_polarity(
      attachment, reservation, encode_model.valid,
      "AEQE producer polarity does not match reservation",
      "AEQE polarity", status);
    if (status == null || !status.ok()) begin
      if (status == null)
        status = rdma_status::make_direct(
          RDMA_SC_INVALID_STATE,
          "AEQE polarity helper returned null status");
      return;
    end
    write_commit_device_entry(attachment, reservation, image, result, status);
  endtask

  // 功能：has_pending_cq_resize 查询指定 CQ 是否存在已发布但尚未完成的旧 backing 清理。
  // 输入/输出及副作用：cq_h 为输入；函数只读取 engine recovery 表，不改变 runtime、manager 或 Host-memory。
  // 失败/边界：空句柄、未配置或不存在记录均返回 0；调用方不得把 0 当作“CQ 一定可 resize”之外的证据。
  function bit has_pending_cq_resize(rdma_handle cq_h);
    string key;
    if (!configured || cq_h == null || cq_h.kind != RDMA_RESOURCE_CQ)
      return 1'b0;
    key = value_ops::cq_recovery_key(cq_h);
    return key != "" && cq_resize_recoveries.exists(key) &&
           cq_resize_recoveries[key] != null;
  endfunction

  // 功能：retry_cq_resize_cleanup 重试已发布 CQ resize 的依赖恢复、旧 runtime
  //   detach 和旧 backing release。
  // 输入/输出及副作用：cq_h 为输入；成功时删除 engine-owned recovery record，
  //   失败时更新 last_status 并保留全部重试 authority。
  // 失败/边界：当前 CQ 不存在 recovery、代际失效、依赖仍无法恢复、旧 runtime
  //   状态异常或 Host-memory release 未完成时返回 RECOVERY_REQUIRED。
  function rdma_status retry_cq_resize_cleanup(rdma_handle cq_h);
    rdma_cq_resize_recovery recovery;
    rdma_queue_data_attachment current_attachment;
    string current_attachment_key;
    rdma_status status;
    bit cleanup_complete;
    rdma_function_identity current_identity;
    string key;
    bit attachment_is_old;

    if (!configured)
      return bad("queue data engine is not configured", RDMA_SC_INVALID_STATE);
    if (cq_h == null || cq_h.kind != RDMA_RESOURCE_CQ)
      return bad("CQ resize recovery handle is invalid");
    if (resize_lock == null || !resize_lock.try_get(1))
      return bad("CQ resize recovery is busy", RDMA_SC_RESOURCE_BUSY);
    key = value_ops::cq_recovery_key(cq_h);
    if (key == "" || !cq_resize_recoveries.exists(key) ||
        cq_resize_recoveries[key] == null) begin
      resize_lock.put(1);
      return bad("CQ resize has no pending recovery", RDMA_SC_INVALID_STATE);
    end
    recovery = cq_resize_recoveries[key];
    // 设计说明：Function reset 改变 binding.generation 后，recovery 仍允许完成
    // 已记录的旧代际事务；caller 必须提供记录中的 identity，并携带旧代际或当前代际。
    // 该例外只授权清理遗留事务，不能据此对 stale CQ 执行普通数据面操作。
    if (!value_ops::same_cq_recovery_identity(recovery.cq_h, cq_h) ||
        (cq_h.generation != recovery.cq_h.generation &&
         (binding == null || cq_h.generation != binding.generation))) begin
      status = bad("CQ resize recovery handle does not match record",
                   RDMA_SC_RECOVERY_REQUIRED);
      recovery.last_status = status;
      resize_lock.put(1);
      return status;
    end
    if (binding == null || recovery.function_identity == null) begin
      status = bad("CQ resize recovery Function identity is missing",
                   RDMA_SC_RECOVERY_REQUIRED);
      recovery.last_status = status;
      resize_lock.put(1);
      return status;
    end
    current_identity = binding.function_identity_snapshot();
    if (current_identity == null ||
        current_identity.function_uid != recovery.function_identity.function_uid ||
        !current_identity.same_function(recovery.function_identity)) begin
      status = bad("CQ resize recovery Function route identity changed",
                   RDMA_SC_RECOVERY_REQUIRED);
      recovery.last_status = status;
      resize_lock.put(1);
      return status;
    end
    status = find_cq_recovery_attachment(recovery, current_attachment,
                                         current_attachment_key);
    if (status == null || !status.ok() || current_attachment == null ||
        current_attachment.runtime == null ||
        current_attachment.access == null) begin
      status = bad("CQ resize recovery attachment authority is inconsistent",
                   RDMA_SC_RECOVERY_REQUIRED);
      recovery.last_status = status;
      resize_lock.put(1);
      return status;
    end
    attachment_is_old = current_attachment.runtime === recovery.old_runtime;
    if ((recovery.published && attachment_is_old) ||
        (!recovery.published && recovery.old_runtime != null &&
         !attachment_is_old)) begin
      status = bad("CQ resize recovery attachment stage is inconsistent",
                   RDMA_SC_RECOVERY_REQUIRED);
      recovery.last_status = status;
      resize_lock.put(1);
      return status;
    end
    // 设计说明：释放 retained backing 前必须重验 opaque allocation identity 以及
    // 不可变的 Function/CQ route evidence。检查刻意放在每次 retry 中执行，因为
    // recovery record 是 engine 拥有的可变存储，并可能跨越 reset 边界继续存活。
    if ((!recovery.published && recovery.pending_ref != null &&
         !recovery_backing_matches(recovery.pending_ref, recovery)) ||
        (recovery.published &&
         !recovery_backing_matches(recovery.old_ref, recovery))) begin
      status = bad("CQ resize recovery backing identity changed",
                   RDMA_SC_RECOVERY_REQUIRED);
      recovery.last_status = status;
      resize_lock.put(1);
      return status;
    end
    // 发布前失败可能同时保留候选 backing 和尚未恢复的 quiesce 屏障。
    // 先恢复原 CQ/dependents/manager，再处理候选 cleanup，避免在旧
    // attachment 仍被阻塞时丢失可用的恢复入口。
    if (!recovery.published) begin
      if (recovery.prepublish_restore_pending) begin
        if (recovery.old_runtime == null) begin
          status = bad("CQ pre-publish old runtime authority is missing",
                       RDMA_SC_RECOVERY_REQUIRED);
          recovery.last_status = status;
          resize_lock.put(1);
          return status;
        end
        if (recovery.cq_restore_pending) begin
          if (recovery.old_runtime.state == RDMA_QUEUE_RUNTIME_QUIESCING) begin
            status = recovery.old_runtime.restore_active();
            if (status == null || !status.ok()) begin
              status = status == null ?
                bad("CQ pre-publish old runtime restore returned null",
                    RDMA_SC_RECOVERY_REQUIRED) :
                rdma_status::make(RDMA_SC_RECOVERY_REQUIRED,
                  {"CQ pre-publish old runtime restore failed: ",
                   status.message});
              recovery.last_status = status;
              resize_lock.put(1);
              return status;
            end
          end
          else if (recovery.old_runtime.state !=
                   RDMA_QUEUE_RUNTIME_ACTIVE) begin
            status = bad("CQ pre-publish old runtime state is unexpected",
                         RDMA_SC_RECOVERY_REQUIRED);
            recovery.last_status = status;
            resize_lock.put(1);
            return status;
          end
          recovery.cq_restore_pending = 1'b0;
        end
        status = restore_cq_dependents(recovery.dependents);
        if (status == null || !status.ok()) begin
          status = status == null ?
            bad("CQ pre-publish dependent restore returned null",
                RDMA_SC_RECOVERY_REQUIRED) :
            rdma_status::make(RDMA_SC_RECOVERY_REQUIRED,
              {"CQ pre-publish dependent restore failed: ", status.message});
          recovery.last_status = status;
          resize_lock.put(1);
          return status;
        end
        if (recovery.manager_restore_pending) begin
          status = manager.restore_active(recovery.cq_h);
          if (status == null || !status.ok()) begin
            status = status == null ?
              bad("CQ pre-publish manager restore returned null",
                  RDMA_SC_RECOVERY_REQUIRED) :
              rdma_status::make(RDMA_SC_RECOVERY_REQUIRED,
                {"CQ pre-publish manager restore failed: ", status.message});
            recovery.last_status = status;
            resize_lock.put(1);
            return status;
          end
          recovery.manager_restore_pending = 1'b0;
        end
        recovery.prepublish_restore_pending = 1'b0;
      end
      if (recovery.pending_ref != null) begin
        status = backing_planner.cleanup_local_role(
          recovery.pending_ref, cleanup_complete);
        if (status == null || !status.ok() || !cleanup_complete) begin
          if (status == null)
            status = bad("CQ candidate cleanup retry returned null",
                         RDMA_SC_RECOVERY_REQUIRED);
          else if (!status.ok())
            status = rdma_status::make(
              RDMA_SC_RECOVERY_REQUIRED,
              {"CQ candidate cleanup retry failed: ", status.message});
          else
            status = bad("CQ candidate cleanup remains incomplete",
                         RDMA_SC_RECOVERY_REQUIRED);
          recovery.last_status = status;
          resize_lock.put(1);
          return status;
        end
      end
      cq_resize_recoveries.delete(key);
      resize_lock.put(1);
      return rdma_status::success();
    end
    if (recovery.old_runtime == null || recovery.old_ref == null ||
        recovery.old_ref.mapping == null) begin
      status = bad("CQ resize recovery authority is incomplete",
                   RDMA_SC_RECOVERY_REQUIRED);
      recovery.last_status = status;
      resize_lock.put(1);
      return status;
    end

    // 依赖恢复可能在上一轮只完成了部分 runtime；restore helper 对已经
    // ACTIVE 的 runtime 幂等跳过，保证本入口可以安全重复调用。
    status = restore_cq_dependents(recovery.dependents);
    if (status == null || !status.ok()) begin
      if (status == null)
        status = bad("CQ resize dependent recovery returned null",
                     RDMA_SC_RECOVERY_REQUIRED);
      else
        status = rdma_status::make(
          RDMA_SC_RECOVERY_REQUIRED,
          {"CQ resize dependent recovery retry failed: ", status.message});
      recovery.last_status = status;
      resize_lock.put(1);
      return status;
    end

    if (recovery.old_runtime.state == RDMA_QUEUE_RUNTIME_QUIESCING) begin
      status = recovery.old_runtime.detach_quiesced();
      if (status == null || !status.ok()) begin
        if (status == null)
          status = bad("CQ resize old runtime detach returned null",
                       RDMA_SC_RECOVERY_REQUIRED);
        else
          status = rdma_status::make(
            RDMA_SC_RECOVERY_REQUIRED,
            {"CQ resize old runtime detach retry failed: ", status.message});
        recovery.last_status = status;
        resize_lock.put(1);
        return status;
      end
    end
    else if (recovery.old_runtime.state != RDMA_QUEUE_RUNTIME_DETACHED) begin
      status = bad("CQ resize old runtime has unexpected state",
                   RDMA_SC_RECOVERY_REQUIRED);
      recovery.last_status = status;
      resize_lock.put(1);
      return status;
    end

    status = backing_planner.cleanup_local_role(recovery.old_ref,
                                                cleanup_complete);
    if (status == null || !status.ok() || !cleanup_complete) begin
      if (status == null)
        status = bad("CQ resize old backing cleanup returned null",
                     RDMA_SC_RECOVERY_REQUIRED);
      else if (!status.ok())
        status = rdma_status::make(
          RDMA_SC_RECOVERY_REQUIRED,
          {"CQ resize old backing cleanup retry failed: ", status.message});
      else
        status = bad("CQ resize old backing cleanup is incomplete",
                     RDMA_SC_RECOVERY_REQUIRED);
      recovery.last_status = status;
      resize_lock.put(1);
      return status;
    end

    cq_resize_recoveries.delete(key);
    resize_lock.put(1);
    return rdma_status::success();
  endfunction

  // 功能：configure 验证当前 Function binding 与外部依赖，配置本地 backing
  //   planner，并发布 queue-data engine 的单一运行环境；context_api 提供
  //   CQC shadow 读写 authority，qpc_shadow_gate 仅在明确声明硬件具备
  //   HW_DROP_DB_CNT 流控时启用 SQ gate。
  // 输入/输出及副作用：resource_manager、function_binding、memory、scheduler、
  //   codecs、timeout、context_api、qpc_shadow_gate 为输入；成功仅保存非拥有
  //   引用、capability 和 timeout；CQ poll 在缺少 context backing 时始终拒绝，
  //   不退回非驱动的 MMIO consumer notify。
  // 失败/边界：空/零依赖、resize 锁忙、未清理 CQ/unclaimed recovery、仍有
  //   attachment/QP link、binding 非 ACTIVE/零 generation 或 planner configure
  //   失败时保留旧配置；不完整 unclaimed pair 也不得跨越配置生命周期。
  function rdma_status configure(
    rdma_resource_manager resource_manager,
    rdma_function_binding function_binding,
    rdma_host_mem_api memory,
    rdma_doorbell_scheduler scheduler,
    rdma_codec_registry codecs,
    time timeout,
    rdma_context_backing_api context_api = null,
    bit qpc_shadow_gate = 1'b0
  );
    rdma_status status;
    rdma_queue_data_attachment attachment;
    rdma_queue_runtime_state_e runtime_state;
    rdma_queue_cursor_snapshot reservation;
    string attachment_index;
    bit has_pending;
    bit reservation_valid;
    bit pending_queried;
    bit reservation_queried;

    if (resource_manager == null || function_binding == null || memory == null ||
        scheduler == null || codecs == null || timeout == 0)
      return bad("queue data engine configuration has a null/zero dependency");
    if (resize_lock == null || !resize_lock.try_get(1))
      return bad("queue data engine configuration is busy",
                 RDMA_SC_RESOURCE_BUSY);
    if (cq_resize_recoveries.num() != 0) begin
      resize_lock.put(1);
      return bad("queue data engine has pending CQ cleanup recovery",
                 RDMA_SC_RECOVERY_REQUIRED);
    end
    // 中文设计：unclaimed evidence 与 attachment 是成对恢复 authority，但任一
    // 表项残留或 pair 不完整都代表旧配置仍有不可丢弃状态。此检查必须先于普通
    // attachment busy gate，才能返回可操作的 RECOVERY_REQUIRED 而不是掩盖为 busy。
    if (unclaimed_device_recoveries.num() != 0 ||
        unclaimed_recovery_attachments.num() != 0) begin
      resize_lock.put(1);
      return bad("queue data engine has unclaimed recovery evidence",
                 RDMA_SC_RECOVERY_REQUIRED);
    end
    // 中文设计：reservation-only evidence 不进入 unclaimed 表，claimed pending
    // 也只存在 runtime 内；因此必须在普通 attachment busy 判断前只读审计全部
    // runtime。任一 recovery 状态、pending、reservation 或查询异常都阻止换配置。
    foreach (attachments[attachment_index]) begin
      attachment = attachments[attachment_index];
      if (attachment == null || attachment.runtime == null) begin
        resize_lock.put(1);
        return bad("queue data engine attachment recovery state is corrupt",
                   RDMA_SC_RECOVERY_REQUIRED);
      end
      status = snapshot_attachment_recovery_state(
        attachment, runtime_state, has_pending, reservation_valid, reservation,
        pending_queried, reservation_queried
      );
      if (status == null || !status.ok()) begin
        resize_lock.put(1);
        if (reservation_queried)
          return bad("queue data engine runtime has a device reservation",
                     RDMA_SC_RECOVERY_REQUIRED);
        if (pending_queried)
          return bad("queue data engine runtime has pending recovery",
                     RDMA_SC_RECOVERY_REQUIRED);
        return bad("queue data engine runtime requires recovery",
                   RDMA_SC_RECOVERY_REQUIRED);
      end
      if (runtime_state == RDMA_QUEUE_RUNTIME_RECOVERY_REQUIRED) begin
        resize_lock.put(1);
        return bad("queue data engine runtime requires recovery",
                   RDMA_SC_RECOVERY_REQUIRED);
      end
      if (has_pending) begin
        resize_lock.put(1);
        return bad("queue data engine runtime has pending recovery",
                   RDMA_SC_RECOVERY_REQUIRED);
      end
      if (attachment.kind inside {RDMA_QUEUE_RUNTIME_CQ,
                                  RDMA_QUEUE_RUNTIME_CEQ,
                                  RDMA_QUEUE_RUNTIME_AEQ}) begin
        if (reservation_valid || reservation != null) begin
          resize_lock.put(1);
          return bad("queue data engine runtime has a device reservation",
                     RDMA_SC_RECOVERY_REQUIRED);
        end
      end
    end
    // attachment/qp_links 是当前队列 backing 和依赖拓扑的唯一索引。
    // 重配置前若直接清空它们会丢失 release authority，留下 manager-active
    // resource；调用方必须先显式 detach 完整拓扑。
    if (attachments.num() != 0 || qp_links.num() != 0) begin
      resize_lock.put(1);
      return bad("active queue attachments prevent reconfigure",
                 RDMA_SC_RESOURCE_BUSY);
    end
    status = function_binding.validate();
    if (status == null || !status.ok()) begin
      resize_lock.put(1);
      return status == null ? bad("Function binding validation returned null",
                                  RDMA_SC_INVALID_STATE) : status;
    end
    if (function_binding.state != RDMA_BIND_ACTIVE ||
        function_binding.generation == 0) begin
      resize_lock.put(1);
      return bad("Function binding is not active", RDMA_SC_INVALID_STATE);
    end
    if (backing_planner == null)
      backing_planner = rdma_queue_backing_planner::type_id::create(
        "queue_data_backing_planner");
    status = backing_planner.configure(memory);
    if (status == null || !status.ok()) begin
      resize_lock.put(1);
      return status == null ? bad("queue backing planner configuration returned null",
                                  RDMA_SC_INVALID_STATE) : status;
    end
    manager = resource_manager;
    binding = function_binding;
    host_mem = memory;
    doorbells = scheduler;
    registry = codecs;
    context_backing = context_api;
    qpc_shadow_gate_enabled = qpc_shadow_gate;
    operation_timeout = timeout;
    attachments.delete();
    qp_links.delete();
    configured = 1'b1;
    resize_lock.put(1);
    return rdma_status::success();
  endfunction

  // 功能：find_queue_ref 在 lifecycle 已冻结的 queue backing plan 中查找首个指定
  //   role 的 backing capability。
  // 输入/输出及副作用：plan、role 为输入，result 先置 null；成功返回 plan-owned
  //   rdma_queue_backing_ref 的非拥有引用，不复制或释放 mapping。
  // 失败/边界：plan=null 或没有匹配 role 时返回 INVALID_STATE；若 plan 含重复 role，
  //   本函数按 lifecycle contract 取首项，不自行合并 segment 或伪造默认 backing。
  protected function rdma_status find_queue_ref(
    rdma_queue_backing_plan plan,
    rdma_queue_backing_role_e role,
    output rdma_queue_backing_ref result
  );
    result = null;
    if (plan == null)
      return bad("queue backing plan is null", RDMA_SC_INVALID_STATE);
    foreach (plan.refs[i]) begin
      if (plan.refs[i] != null && plan.refs[i].role == role) begin
        result = plan.refs[i];
        return rdma_status::success();
      end
    end
    return bad("queue backing role is missing", RDMA_SC_INVALID_STATE);
  endfunction

  // 功能：create_attachment 为一个 queue runtime 建立借用的 backing access、冻结
  //   route/epoch 并激活 attachment，使后续 post/poll/publish 只消费同一 authority。
  // 输入/输出及副作用：queue_h、kind、role、queue_ref/qp_ref、cursor、geometry 和
  //   transport 为输入；成功时向 attachments 插入新记录，但不取得外部 backing 所有权。
  // 失败/边界：重复 key、几何/依赖不完整、access/runtime 配置、route/epoch 校验或
  //   activate 失败时返回非成功 status，attachments 不发布半成品记录；CQ 必须
  //   同时冻结 authoritative ceq_h 的 detached 值快照。
  protected function rdma_status create_attachment(
    rdma_handle queue_h,
    rdma_queue_runtime_kind_e kind,
    rdma_queue_backing_role_e role,
    rdma_queue_backing_ref queue_ref,
    rdma_qp_backing_ref qp_ref,
    int unsigned depth,
    int unsigned producer_index,
    bit producer_wrap,
    int unsigned consumer_index,
    bit consumer_wrap,
    bit host_produced,
    int unsigned local_id,
    rdma_transport_e transport,
    int unsigned entry_size = 64,
    bit initial_polarity = 1'b0,
    rdma_handle ceq_h = null,
    rdma_context_backing_ref context_ref = null
  );
    rdma_queue_data_attachment attachment;
    rdma_queue_backing_access access;
    rdma_queue_runtime runtime;
    rdma_function_identity identity;
    rdma_handle ceq_snapshot;
    rdma_status status;
    string key;

    ceq_snapshot = null;
    if (queue_h == null || depth == 0)
      return bad("queue attachment geometry is invalid");
    if (kind == RDMA_QUEUE_RUNTIME_CQ) begin
      status = ensure_handle(ceq_h, RDMA_RESOURCE_CEQ);
      if (status == null || !status.ok())
        return status == null ?
          bad("CQ attachment CEQ validation returned null status",
              RDMA_SC_INVALID_STATE) : status;
      status = clone_publish_handle(ceq_h, "CQ attachment CEQ", ceq_snapshot);
      if (status == null || !status.ok() || ceq_snapshot == null)
        return status == null || status.ok() ?
          bad("CQ attachment CEQ snapshot is unavailable",
          RDMA_SC_RESOURCE_EXHAUSTED) : status;

      // A configured context adapter opts the CQ into the real CQC shadow ABI.
      // Validate the complete authority and geometry at attachment time so a
      // later poll cannot silently fall back to a guessed or relative offset.
      if (context_backing != null) begin
        if (context_ref == null)
          return bad("CQ context authority is required for shadow publication",
                     RDMA_SC_INVALID_STATE);
        status = context_ref.validate();
        if (status == null || !status.ok())
          return status == null ?
            bad("CQ context authority validation returned null",
                RDMA_SC_INVALID_STATE) : status;
        if (!value_ops::cqc_shadow_context_geometry_valid(context_ref, local_id))
          return bad("CQ context authority geometry is not CQC ABI compatible",
                     RDMA_SC_INVALID_STATE);
      end
    end
    key = value_ops::attachment_key(queue_h, kind);
    if (attachments.exists(key))
      return bad("queue is already attached", RDMA_SC_INVALID_STATE);
    if (binding == null || host_mem == null)
      return bad("queue attachment dependencies are incomplete",
                 RDMA_SC_INVALID_STATE);
    access = rdma_queue_backing_access::type_id::create(
      $sformatf("queue_access_%0d", attachments.num()));
    status = access.configure(binding.make_handle(), host_mem);
    if (status == null || !status.ok())
      return status == null ? bad("queue backing access configure returned null",
                                  RDMA_SC_INVALID_STATE) : status;
    if (qp_ref != null)
      status = access.attach_qp(qp_ref);
    else
      status = access.attach_queue(queue_ref);
    if (status == null || !status.ok())
      return status == null ? bad("queue backing access attach returned null",
                                  RDMA_SC_INVALID_STATE) : status;
    runtime = rdma_queue_runtime::type_id::create(
      $sformatf("queue_runtime_%0d", attachments.num()));
    status = runtime.configure(queue_h, kind, depth, producer_index,
                               producer_wrap, consumer_index, consumer_wrap,
                               host_produced, initial_polarity);
    if (status == null || !status.ok())
      return status == null ? bad("queue runtime configure returned null",
                                  RDMA_SC_INVALID_STATE) : status;
    // runtime 必须在激活前锁存完整 Function route/epoch；后续 publish 与
    // recovery 只读取这个快照，不能依赖可变 binding 或默认 route。
    identity = binding.function_identity_snapshot();
    if (identity == null)
      return bad("queue attachment Function identity is unavailable",
                 RDMA_SC_INVALID_STATE);
    status = identity.validate();
    if (status == null || !status.ok())
      return status == null ? bad("queue attachment identity validation returned null",
                                  RDMA_SC_INVALID_STATE) : status;
    status = runtime.set_route_epoch(identity.route_key(), identity.reset_epoch);
    if (status == null || !status.ok())
      return status == null ? bad("queue runtime route/epoch setup returned null",
                                  RDMA_SC_INVALID_STATE) : status;
    status = runtime.activate();
    if (status == null || !status.ok())
      return status == null ? bad("queue runtime activate returned null",
                                  RDMA_SC_INVALID_STATE) : status;
    attachment = rdma_queue_data_attachment::type_id::create(
      $sformatf("queue_attachment_%0d", attachments.num()));
    if (attachment == null)
      return bad("queue attachment allocation failed",
                 RDMA_SC_RESOURCE_EXHAUSTED);
    attachment.queue_h = rdma_clone_handle_value(queue_h,
                                                  "queue attachment handle");
    if (attachment.queue_h == null)
      attachment.queue_h = queue_h;
    attachment.ceq_h = ceq_snapshot;
    attachment.kind = kind;
    attachment.runtime = runtime;
    attachment.access = access;
    attachment.role = role;
    attachment.entry_size = entry_size;
    attachment.context_ref = context_ref;
    attachment.local_id = local_id;
    attachment.transport = transport;
    attachments[key] = attachment;
    return rdma_status::success();
  endfunction

  // 功能：delete_attachment 删除指定 handle/kind 的 engine 本地 attachment，并把
  //   其 runtime 标为 DETACHED，供 attach_qp 失败回滚已建 SQ。
  // 输入/输出及副作用：queue_h、kind 为输入；仅修改 attachments 和 runtime.state，
  //   不 detach backing access、不释放 lifecycle mapping，也无返回值。
  // 失败/边界：key 不存在时幂等无动作；attachment/runtime 为空时仍删除索引，
  //   调用方必须确保尚未发布外部事务，不能用本 helper 替代完整 detach/recovery。
  protected function void delete_attachment(
    rdma_handle queue_h, rdma_queue_runtime_kind_e kind
  );
    string key;
    key = value_ops::attachment_key(queue_h, kind);
    if (attachments.exists(key)) begin
      if (attachments[key] != null && attachments[key].runtime != null)
        attachments[key].runtime.state = RDMA_QUEUE_RUNTIME_DETACHED;
      attachments.delete(key);
    end
  endfunction

  // 功能：attach_srq_for_qp 为 QP 引用的活动 SRQ 建立或复用 host-produced SRQ
  //   runtime/backing attachment，并从 ring plan 读取 initial polarity。
  // 输入/输出及副作用：srq_h 为输入；成功时可能向 attachments 新增一个借用
  //   queue backing 的 SRQ 记录，重复同一完整 identity 时幂等返回 OK。
  // 失败/边界：handle/manager lookup、resource type/state、queue plan/role 或
  //   create_attachment 失败时不发布半成品；不会把不同 generation 当作同一 SRQ。
  protected function rdma_status attach_srq_for_qp(
    rdma_handle srq_h
  );
    rdma_resource resource;
    rdma_srq srq;
    rdma_queue_backing_ref queue_backing;
    rdma_status status;
    bit initial_polarity;

    status = ensure_handle(srq_h, RDMA_RESOURCE_SRQ);
    if (!status.ok()) return status;
    if (attachments.exists(value_ops::attachment_key(srq_h, RDMA_QUEUE_RUNTIME_SRQ)))
      return rdma_status::success();
    status = manager.lookup(srq_h, resource);
    if (!status.ok()) return status;
    if (!$cast(srq, resource) || srq == null ||
        srq.state != RDMA_RESOURCE_ACTIVE || srq.queue_plan == null)
      return bad("SRQ lookup/backing plan is invalid", RDMA_SC_INVALID_STATE);
    status = find_queue_ref(srq.queue_plan, RDMA_QUEUE_ROLE_SRQ_RING, queue_backing);
    if (!status.ok()) return status;
    initial_polarity = 1'b0;
    foreach (srq.queue_plan.rings[i]) begin
      if (srq.queue_plan.rings[i] != null &&
          srq.queue_plan.rings[i].role == RDMA_QUEUE_ROLE_SRQ_RING)
        initial_polarity = srq.queue_plan.rings[i].initial_polarity;
    end
    return create_attachment(srq_h, RDMA_QUEUE_RUNTIME_SRQ,
      RDMA_QUEUE_ROLE_SRQ_RING, queue_backing, null, srq.depth,
      srq.producer_index, srq.producer_wrap, srq.consumer_index,
      srq.consumer_wrap, 1'b1, srq.local_srq_id, RDMA_TRANSPORT_RC,
      64, initial_polarity);
  endfunction

  // 功能：attach_qp 从 manager 的活动 QP/qp_plan 建立 SQ 与 RQ 或共享 SRQ
  //   attachment，并登记 QP→send/recv CQ 的冻结路由、可选 SQ SGB access 和
  //   QPC runtime-shadow authority。
  // 输入/输出及副作用：qp_h 为输入；成功写入 attachments 与 qp_links，handle
  //   尽量按值复制，runtime/access/context_ref 只借用 lifecycle backing，不取得
  //   mapping 或 context authority 所有权。
  // 失败/边界：stale/重复 QP、plan/resource 无效、shadow reader 已注入但
  //   context_ref 缺失、任一 ring 或 SGB attach 失败时返回原错误；RQ/SRQ 建立
  //   失败会删除刚建 SQ，QP link 只在全部步骤成功后发布。
  function rdma_status attach_qp(rdma_handle qp_h);
    rdma_resource resource;
    rdma_qp qp;
    rdma_status status;
    rdma_queue_backing_ref unused_ref;
    rdma_queue_data_qp_link link;
    bit sq_attached;

    status = ensure_handle(qp_h, RDMA_RESOURCE_QP);
    if (!status.ok()) return status;
    status = manager.lookup(qp_h, resource);
    if (!status.ok()) return status;
    if (!$cast(qp, resource) || qp == null ||
        qp.state != RDMA_RESOURCE_ACTIVE || qp.qp_plan == null)
      return bad("QP lookup/backing plan is invalid", RDMA_SC_INVALID_STATE);
    if (attachments.exists(value_ops::attachment_key(qp_h, RDMA_QUEUE_RUNTIME_SQ)))
      return bad("QP is already attached", RDMA_SC_INVALID_STATE);
    if (qpc_shadow_gate_enabled && qp.qp_plan.context_ref == null)
      return bad("QPC context authority is required for shadow-gated SQ",
                 RDMA_SC_INVALID_STATE);
    status = create_attachment(qp_h, RDMA_QUEUE_RUNTIME_SQ,
      RDMA_QUEUE_ROLE_QP_SQ_RING, unused_ref, qp.qp_plan.sq_ref,
      qp.sq_depth, qp.sq_producer_index, qp.sq_wrap,
      qp.sq_consumer_index, qp.sq_consumer_wrap, 1'b1,
      qp.local_qp_id, qp.transport);
    if (!status.ok()) return status;
    sq_attached = 1'b1;
    if (qp.srq_h == null) begin
      status = create_attachment(qp_h, RDMA_QUEUE_RUNTIME_RQ,
        RDMA_QUEUE_ROLE_QP_RQ_RING, unused_ref, qp.qp_plan.rq_ref,
        qp.rq_depth, qp.rq_producer_index, qp.rq_wrap,
        qp.rq_consumer_index, qp.rq_consumer_wrap, 1'b1,
        qp.local_qp_id, qp.transport);
    end
    else begin
      status = attach_srq_for_qp(qp.srq_h);
    end
    if (!status.ok()) begin
      if (sq_attached) delete_attachment(qp_h, RDMA_QUEUE_RUNTIME_SQ);
      return status;
    end
    link = rdma_queue_data_qp_link::type_id::create(
      $sformatf("qp_link_%0d", qp_links.num()));
    link.qp_h = rdma_clone_handle_value(qp_h, "QP link handle");
    if (link.qp_h == null) link.qp_h = qp_h;
    link.srq_h = rdma_clone_handle_value(qp.srq_h, "QP link SRQ");
    if (link.srq_h == null && qp.srq_h != null) link.srq_h = qp.srq_h;
    link.send_cq_h = rdma_clone_handle_value(qp.send_cq_h, "QP link send CQ");
    if (link.send_cq_h == null && qp.send_cq_h != null)
      link.send_cq_h = qp.send_cq_h;
    link.recv_cq_h = rdma_clone_handle_value(qp.recv_cq_h, "QP link receive CQ");
    if (link.recv_cq_h == null && qp.recv_cq_h != null)
      link.recv_cq_h = qp.recv_cq_h;
    link.local_qp_id = qp.local_qp_id;
    link.transport = qp.transport;
    // The plan owns this authority.  The link only freezes a non-owning
    // reference so a later reset/release remains visible to the backing API.
    link.context_ref = qp.qp_plan.context_ref;
    if (qp.programmed_qpc != null &&
        qp.programmed_qpc.transport == qp.transport)
      link.path_mtu_bytes = qp.programmed_qpc.path_mtu_bytes;
    else
      link.path_mtu_bytes = 0;
    link.sw_ring_db_count = 7'd0;
    link.sw_ring_db_count_valid = 1'b1;
    if (qp.qp_plan.sq_sgb_ref != null) begin
      link.sq_sgb_access = rdma_queue_backing_access::type_id::create("sq_sgb_access");
      link.sq_sgb_ref = qp.qp_plan.sq_sgb_ref;
      status = link.sq_sgb_access.configure(binding.make_handle(), host_mem);
      if (!status.ok()) return status;
      status = link.sq_sgb_access.attach_qp(qp.qp_plan.sq_sgb_ref);
      if (!status.ok()) return status;
    end
    qp_links[value_ops::identity_key(qp_h)] = link;
    return rdma_status::success();
  endfunction

  // 功能：attach_cq 从 manager 读取 authoritative CQ，建立 ring attachment，并把
  //   CQ→CEQ dependency 冻结为 detached handle 快照供 CEQE route 校验。
  // 输入/输出及副作用：cq_h、transport_variant 为输入；成功时新增 CQ runtime、
  //   backing access 和 ceq_h 值快照，不取得 CQ、CEQ 或 manager 资源所有权。
  // 失败/边界：CQ/CEQ handle、Function/generation、transport、backing、snapshot
  //   分配或重复 attachment 无效时拒绝，attachments 索引不得发布半成品。
  function rdma_status attach_cq(
    rdma_handle cq_h, rdma_transport_e transport_variant
  );
    rdma_resource resource;
    rdma_cq cq;
    rdma_queue_backing_ref queue_backing;
    bit initial_polarity;
    rdma_status status;
    status = ensure_handle(cq_h, RDMA_RESOURCE_CQ);
    if (!status.ok()) return status;
    if (!(transport_variant inside {RDMA_TRANSPORT_RC,
                                    RDMA_TRANSPORT_UD,
                                    RDMA_TRANSPORT_URC}))
      return bad("CQ transport variant is invalid");
    status = manager.lookup(cq_h, resource);
    if (!status.ok()) return status;
    if (!$cast(cq, resource) || cq == null ||
        cq.state != RDMA_RESOURCE_ACTIVE || cq.queue_plan == null)
      return bad("CQ lookup/backing plan is invalid", RDMA_SC_INVALID_STATE);
    if (!(cq.cqe_size_bytes inside {32, 64, 128}))
      return bad("CQE size profile is unsupported", RDMA_SC_UNSUPPORTED_OPCODE);
    status = find_queue_ref(cq.queue_plan, RDMA_QUEUE_ROLE_CQ_RING, queue_backing);
    if (!status.ok()) return status;
    initial_polarity = 1'b0;
    foreach (cq.queue_plan.rings[i]) begin
      if (cq.queue_plan.rings[i] != null &&
          cq.queue_plan.rings[i].role == RDMA_QUEUE_ROLE_CQ_RING)
        initial_polarity = cq.queue_plan.rings[i].initial_polarity;
    end
    return create_attachment(cq_h, RDMA_QUEUE_RUNTIME_CQ,
      RDMA_QUEUE_ROLE_CQ_RING, queue_backing, null, cq.depth,
      cq.producer_index, cq.producer_wrap, cq.consumer_index,
      cq.consumer_wrap, 1'b0, cq.local_cq_id, transport_variant,
      cq.cqe_size_bytes, initial_polarity, cq.ceq_h,
      cq.queue_plan.context_ref);
  endfunction

  // 功能：attach_event_queue 为 CEQ/AEQ 读取活动 queue resource、backing role、
  //   local event ID 和 initial polarity，并建立 16-byte device-produced attachment。
  // 输入/输出及副作用：queue_h、expected resource kind、runtime kind、backing role
  //   为输入；成功向 attachments 增加借用 access/runtime，不修改 manager resource。
  // 失败/边界：handle/lookup/type/state/plan/role 不符或 create_attachment 失败时
  //   返回非成功；CEQ/AEQ local ID 只从对应强类型资源读取，不能跨类型回退。
  protected function rdma_status attach_event_queue(
    rdma_handle queue_h, rdma_resource_kind_e expected,
    rdma_queue_runtime_kind_e kind, rdma_queue_backing_role_e role
  );
    rdma_resource resource;
    rdma_queue_resource queue;
    rdma_queue_backing_ref queue_backing;
    rdma_status status;
    int unsigned local_id;
    bit initial_polarity;

    status = ensure_handle(queue_h, expected);
    if (!status.ok()) return status;
    status = manager.lookup(queue_h, resource);
    if (!status.ok()) return status;
    if (!$cast(queue, resource) || queue == null ||
        queue.state != RDMA_RESOURCE_ACTIVE || queue.queue_plan == null)
      return bad("event queue lookup/backing plan is invalid",
                 RDMA_SC_INVALID_STATE);
    status = find_queue_ref(queue.queue_plan, role, queue_backing);
    if (!status.ok()) return status;
    initial_polarity = 1'b0;
    foreach (queue.queue_plan.rings[i]) begin
      if (queue.queue_plan.rings[i] != null &&
          queue.queue_plan.rings[i].role == role)
        initial_polarity = queue.queue_plan.rings[i].initial_polarity;
    end
    local_id = queue_h.object_id;
    if (expected == RDMA_RESOURCE_CEQ) begin
      rdma_ceq ceq;
      if ($cast(ceq, queue)) local_id = ceq.local_ceq_id;
    end
    else begin
      rdma_aeq aeq;
      if ($cast(aeq, queue)) local_id = aeq.local_aeq_id;
    end
    return create_attachment(queue_h, kind, role, queue_backing, null, queue.depth,
      queue.producer_index, queue.producer_wrap, queue.consumer_index,
      queue.consumer_wrap, 1'b0, local_id, RDMA_TRANSPORT_RC,
      (kind == RDMA_QUEUE_RUNTIME_CEQ || kind == RDMA_QUEUE_RUNTIME_AEQ) ? 16 : 64,
      initial_polarity);
  endfunction

  // 功能：attach_ceq 以 CEQ resource/runtime/backing role 调用共享 event attach，
  //   建立 host consumer 可 poll 的 device-produced completion-event ring。
  // 输入/输出及副作用：ceq_h 为输入；成功副作用完全由 attach_event_queue 发布，
  //   本 wrapper 不额外保存 handle 或取得 backing 所有权。
  // 失败/边界：所有 Function/generation、active resource、backing 与重复 attachment
  //   错误原样返回，不允许把 AEQ/CQ handle 当作 CEQ。
  function rdma_status attach_ceq(rdma_handle ceq_h);
    return attach_event_queue(ceq_h, RDMA_RESOURCE_CEQ,
                              RDMA_QUEUE_RUNTIME_CEQ,
                              RDMA_QUEUE_ROLE_CEQ_RING);
  endfunction

  // 功能：attach_aeq 以 AEQ resource/runtime/backing role 调用共享 event attach，
  //   建立 host consumer 可 poll 的 device-produced async-event ring。
  // 输入/输出及副作用：aeq_h 为输入；成功副作用完全由 attach_event_queue 发布，
  //   本 wrapper 不额外保存 handle 或取得 backing 所有权。
  // 失败/边界：所有 Function/generation、active resource、backing 与重复 attachment
  //   错误原样返回，不允许把 CEQ/CQ handle 当作 AEQ。
  function rdma_status attach_aeq(rdma_handle aeq_h);
    return attach_event_queue(aeq_h, RDMA_RESOURCE_AEQ,
                              RDMA_QUEUE_RUNTIME_AEQ,
                              RDMA_QUEUE_ROLE_AEQ_RING);
  endfunction

  // 功能：detach 在 engine resize 锁内先审计指定资源全部 ring 的 recovery
  //   authority，再隔离无恢复证据的 attachment；QP 场景同时删除对应 route
  //   link，attachment handle 身份由 attachment_matches_queue_identity 统一门禁，
  //   helper 内部继续委托 canonical same_handle_instance 比较。
  // 输入/输出及副作用：queue_h 为输入；成功把匹配 runtime 标为 DETACHED 并删除
  //   本地非拥有索引，不释放 manager resource、mapping 或 Host-memory。
  // 失败/边界：handle/stale generation、锁忙、CQ cleanup、claimed pending、device
  //   reservation、unclaimed evidence、runtime 查询不一致或没有 attachment 时返回
  //   错误；所有检查在首次 mutation 前完成，重复 detach 非幂等。
  function rdma_status detach(rdma_handle queue_h);
    rdma_status status;
    string key;
    string matching_keys[$];
    rdma_queue_data_attachment attachment;
    rdma_queue_cursor_snapshot reservation;
    rdma_queue_runtime_state_e runtime_state;
    bit has_pending;
    bit reservation_valid;
    bit pending_queried;
    bit reservation_queried;
    bit found;
    found = 1'b0;
    status = ensure_handle(queue_h, queue_h == null ? RDMA_RESOURCE_QP :
                           queue_h.kind);
    if (!status.ok()) return status;
    if (resize_lock == null || !resize_lock.try_get(1))
      return bad("queue detach is busy", RDMA_SC_RESOURCE_BUSY);
    if (queue_h.kind == RDMA_RESOURCE_CQ &&
        cq_resize_recoveries.exists(value_ops::cq_recovery_key(queue_h))) begin
      resize_lock.put(1);
      return bad("queue detach requires CQ cleanup recovery",
                 RDMA_SC_RECOVERY_REQUIRED);
    end
    key = value_ops::identity_key(queue_h);
    if (key != "" && (unclaimed_device_recoveries.exists(key) ||
                       unclaimed_recovery_attachments.exists(key))) begin
      resize_lock.put(1);
      return bad("queue detach requires unclaimed recovery resolution",
                 RDMA_SC_RECOVERY_REQUIRED);
    end

    // 中文设计：同一 QP 可对应多个 ring attachment。先收集并查询每个 runtime，
    // 任一 pending/reservation/RECOVERY_REQUIRED 或查询异常都整体拒绝；只有完整
    // preflight 通过后才写 state/delete，避免前一个 ring 已删除而后一个 ring 拒绝。
    foreach (attachments[key]) begin
      if (value_ops::attachment_matches_queue_identity(attachments[key], queue_h)) begin
        attachment = attachments[key];
        matching_keys.push_back(key);
        if (attachment.runtime == null) begin
          resize_lock.put(1);
          return bad("queue detach runtime is unavailable",
                     RDMA_SC_RECOVERY_REQUIRED);
        end
        status = snapshot_attachment_recovery_state(
          attachment, runtime_state, has_pending, reservation_valid, reservation,
          pending_queried, reservation_queried
        );
        if (status == null || !status.ok()) begin
          resize_lock.put(1);
          if (reservation_queried)
            return bad("queue detach requires device reservation resolution",
                       RDMA_SC_RECOVERY_REQUIRED);
          if (pending_queried)
            return bad("queue detach requires pending recovery resolution",
                       RDMA_SC_RECOVERY_REQUIRED);
          return bad("queue detach requires runtime recovery resolution",
                     RDMA_SC_RECOVERY_REQUIRED);
        end
        if (runtime_state == RDMA_QUEUE_RUNTIME_RECOVERY_REQUIRED) begin
          resize_lock.put(1);
          return bad("queue detach requires runtime recovery resolution",
                     RDMA_SC_RECOVERY_REQUIRED);
        end
        if (has_pending) begin
          resize_lock.put(1);
          return bad("queue detach requires pending recovery resolution",
                     RDMA_SC_RECOVERY_REQUIRED);
        end
        if (attachment.kind inside {RDMA_QUEUE_RUNTIME_CQ,
                                    RDMA_QUEUE_RUNTIME_CEQ,
                                    RDMA_QUEUE_RUNTIME_AEQ}) begin
          if (reservation_valid || reservation != null) begin
            resize_lock.put(1);
            return bad("queue detach requires device reservation resolution",
                       RDMA_SC_RECOVERY_REQUIRED);
          end
        end
      end
    end
    foreach (matching_keys[i]) begin
      attachment = attachments[matching_keys[i]];
      attachment.runtime.state = RDMA_QUEUE_RUNTIME_DETACHED;
      attachments.delete(matching_keys[i]);
      found = 1'b1;
    end
    if (queue_h.kind == RDMA_RESOURCE_QP)
      qp_links.delete(value_ops::identity_key(queue_h));
    if (!found)
      begin
        resize_lock.put(1);
        return bad("queue is not attached", RDMA_SC_INVALID_STATE);
      end
    resize_lock.put(1);
    return rdma_status::success();
  endfunction

  // 设计说明：recovery abort 同时跨越 runtime pending/reservation 与 engine
  // attachment 两个状态域。必须先取得 detach 所需的 resize_lock 并验证目标仍在
  // attachments 中，再执行不可回滚的 runtime abort/cancel；锁内删除本地借用引用
  // 不再调用可能失败的外部后端，因此不会留下“runtime 已清空、attachment 仍存在”
  // 或“reservation 已取消、unclaimed evidence 仍存在”的分裂状态。
  // 功能：detach_recovery_transaction 原子完成 claimed pending 的 abort 或
  // unclaimed/reservation-only device reservation 的 cancel，并隔离同一 handle 的
  // 全部 attachment；它是 recover_queue 的内部提交边界，不替代普通 detach API。
  // 输入/输出及副作用：queue_h、expected_attachment 为输入；cancel_reservation 为空
  // 时调用 expected runtime 的 abort_recovery，非空时调用 cancel_device_producer；
  // 成功后删除同 handle attachments/QP link，但不释放或修改 lifecycle mapping。
  // 失败/边界：锁忙、CQ resize recovery 存在、expected attachment 已消失/换代，或
  // runtime abort/cancel 拒绝时返回原错误且不删除 attachment；两处 attachment
  // incarnation 检查在各自 null/runtime 门禁后通过
  // attachment_matches_queue_identity（内部 canonical same_handle_instance）完成，
  // 所有 engine 可失败条件都在 runtime 状态迁移前检查，故调用方可用同一 evidence
  // 安全重试。
  protected function rdma_status detach_recovery_transaction(
    rdma_handle queue_h,
    rdma_queue_data_attachment expected_attachment,
    rdma_queue_cursor_snapshot cancel_reservation = null
  );
    rdma_status status;
    string key;
    string matching_keys[$];
    bit expected_found;

    if (queue_h == null || expected_attachment == null ||
        expected_attachment.queue_h == null ||
        expected_attachment.runtime == null ||
        !value_ops::attachment_matches_queue_identity(expected_attachment, queue_h))
      return bad("recovery detach attachment is invalid",
                 RDMA_SC_INVALID_STATE);
    if (resize_lock == null || !resize_lock.try_get(1))
      return bad("queue detach is busy", RDMA_SC_RESOURCE_BUSY);
    if (queue_h.kind == RDMA_RESOURCE_CQ &&
        cq_resize_recoveries.exists(value_ops::cq_recovery_key(queue_h))) begin
      resize_lock.put(1);
      return bad("queue detach requires CQ cleanup recovery",
                 RDMA_SC_RECOVERY_REQUIRED);
    end

    expected_found = 1'b0;
    foreach (attachments[key]) begin
      if (value_ops::attachment_matches_queue_identity(attachments[key], queue_h)) begin
        matching_keys.push_back(key);
        if (attachments[key] == expected_attachment)
          expected_found = 1'b1;
      end
    end
    if (!expected_found || matching_keys.size() == 0) begin
      resize_lock.put(1);
      return bad("recovery detach attachment is stale",
                 RDMA_SC_INVALID_STATE);
    end

    if (cancel_reservation == null)
      status = expected_attachment.runtime.abort_recovery();
    else
      status = expected_attachment.runtime.cancel_device_producer(
        cancel_reservation);
    if (status == null || !status.ok()) begin
      resize_lock.put(1);
      return status == null ?
        bad("recovery detach runtime transition returned null status",
            RDMA_SC_RECOVERY_REQUIRED) : status;
    end

    foreach (matching_keys[i]) begin
      if (attachments.exists(matching_keys[i]) &&
          attachments[matching_keys[i]] != null &&
          attachments[matching_keys[i]].runtime != null)
        attachments[matching_keys[i]].runtime.state =
          RDMA_QUEUE_RUNTIME_DETACHED;
      attachments.delete(matching_keys[i]);
    end
    if (queue_h.kind == RDMA_RESOURCE_QP)
      qp_links.delete(value_ops::identity_key(queue_h));
    resize_lock.put(1);
    return rdma_status::success();
  endfunction

  // 功能：sqe_authority_status 对发送请求的
  // QP、URC completion QP、MR/MW 和 FLUSH authority 做运行时身份及 attach
  // 校验，确保已通过语义模型的请求仍绑定到当前 queue-data route。
  // 输入/输出及副作用：request、link 为输入；函数只读取 request 快照、QP
  // link 和 qp_links 索引，返回 rdma_status，不预留槽位、不修改账本或外部资源。
  // 失败/边界：request/link/快照为空、QP route 不一致、owner/UID/generation
  // 失配、URC completion QP 未 attach、control authority kind 错误或 FLUSH
  // authority 非 posting QP 时返回对应错误码；失败路径保持 producer 游标不变。
  protected function rdma_status sqe_authority_status(
    rdma_post_send_req request,
    rdma_queue_data_qp_link link
  );
    rdma_status status;
    rdma_handle reference;
    rdma_queue_data_qp_link completion_link;
    string completion_key;

    if (request == null || link == null || link.qp_h == null)
      return bad("SQE authority request or QP link is null",
                 RDMA_SC_INVALID_STATE);
    status = ensure_handle(request.qp_h, RDMA_RESOURCE_QP);
    if (!status.ok()) return status;
    // 设计说明：入口先拒绝空句柄、kind、Function UID 和 generation 失配；此处
    // 只复用 null-safe instance seam，保留 QP route mismatch 的 INVALID_STATE
    // 优先级，不把 owner、transport 或 attachment 状态混入同一身份比较。
    if (!value_ops::same_handle_instance(link.qp_h, request.qp_h))
      return bad("SQE posting QP route identity does not match request",
                 RDMA_SC_INVALID_STATE);
    // QP 的 transport 是 CMQ 创建阶段冻结的 wire/profile authority；请求
    // 中的 transport 只能复述该值，不能借同一 SQ 句柄切换到另一协议。若
    // 允许继续，会在 codec 阶段把 RC ring 误编码成 UD/URC，造成网络头和
    // QP context 不一致，因此必须在 reservation 之前 fail-closed。
    if (request.transport != link.transport)
      return bad("SQE request transport does not match bound QP",
                 RDMA_SC_INVALID_STATE);

    reference = request.owner == null ? request.qp_h : request.owner;
    if (request.owner != null) begin
      status = rdma_handle_owner_status(request.qp_h, request.owner);
      if (!status.ok()) return status;
    end

    case (request.opcode)
      RDMA_WR_REG_MR: begin
        status = rdma_handle_authority_status(
          request.mr_h, RDMA_RESOURCE_MR, reference, "REG_MR authority");
        if (!status.ok()) return status;
      end
      RDMA_WR_BIND_MW: begin
        status = rdma_handle_authority_status(
          request.mr_h, RDMA_RESOURCE_MR, reference,
          "BIND_MW MR authority");
        if (!status.ok()) return status;
        status = rdma_handle_authority_status(
          request.mw_h, RDMA_RESOURCE_MW, reference,
          "BIND_MW MW authority");
        if (!status.ok()) return status;
      end
      RDMA_WR_FLUSH: begin
        status = rdma_handle_authority_status(
          request.authority_h, RDMA_RESOURCE_QP, reference,
          "FLUSH authority");
        if (!status.ok()) return status;
        if (!value_ops::same_handle_instance(request.authority_h, link.qp_h))
          return bad("FLUSH authority is detached from the posting QP",
                     RDMA_SC_INVALID_STATE);
      end
      default: begin end
    endcase

    if (request.transport == RDMA_TRANSPORT_URC) begin
      status = rdma_handle_authority_status(
        request.completion_qp_h, RDMA_RESOURCE_QP, reference,
        "URC completion QP");
      if (!status.ok()) return status;
      completion_key = value_ops::identity_key(request.completion_qp_h);
      if (!qp_links.exists(completion_key) ||
          qp_links[completion_key] == null)
        return bad("URC completion QP is not attached", RDMA_SC_INVALID_STATE);
      completion_link = qp_links[completion_key];
      if (completion_link.qp_h == null ||
          !value_ops::same_handle_instance(completion_link.qp_h,
                                request.completion_qp_h))
        return bad("URC completion QP route identity is stale",
                   RDMA_SC_INVALID_STATE);
      if (completion_link.transport != RDMA_TRANSPORT_URC)
        return bad("URC completion QP transport does not match request",
                   RDMA_SC_INVALID_STATE);
    end
    else if (request.completion_qp_h != null) begin
      return bad("completion QP is only valid for URC send");
    end
    return rdma_status::success();
  endfunction

  // 功能：make_sqe 将发送请求投影为 detached 硬件 SQE 模型，深复制 SGE，
  //   补齐 transport extension 与 reservation 坐标，并在 payload/SGE 快照完成后
  //   调用共享 derivation 发布 canonical sge_num，覆盖 inline ceil、过滤后 SGE
  //   数量、empty 零值及 atomic fixed-one，避免 facade 与 codec 各自计数。
  // 输入/输出及副作用：request 提供 qp_h、mr_h、mw_h、authority_h、payload、
  //   SGE、compare_value、swap_add_value、sgb_iova 等冻结语义；link/cursor 提供
  //   QP route 与 index/wrap；model 输出新建候选对象，不写 backing、不推进 PI，
  //   也不取得 request、handle 或外部 route 的所有权。
  // 失败/边界：request、link 或 cursor 为空，authority/transport 不匹配，SGE
  //   含 null，URC 缺少合法 completion_qp_h，或 canonical count、payload shape、
  //   字段宽度未通过 model.validate 时返回非 OK；model 可能保留未提交候选对象，
  //   调用方必须按 status 丢弃，失败对象不得编码或持久化。
  protected function rdma_status make_sqe(
    rdma_post_send_req request,
    rdma_queue_data_qp_link link,
    rdma_queue_cursor_snapshot cursor,
    output rdma_hw_sqe_model model
  );
    rdma_sqe_rc_ext rc;
    rdma_sqe_ud_ext ud;
    rdma_sqe_urc_ext urc;
    rdma_sge cloned_sge;
    rdma_status status;

    model = null;
    if (request == null || link == null || cursor == null)
      return bad("SQE request, QP link, or reservation is null");
    status = sqe_authority_status(request, link);
    if (!status.ok())
      return status;
    model = rdma_hw_sqe_model::type_id::create("queue_sqe");
    model.transport = request.transport;
    model.qp_h = request.qp_h;
    model.wr_id = request.wr_id;
    model.opcode = request.opcode;
    model.inline_data = request.inline_data;
    model.payload = request.payload;
    model.immediate_data = request.immediate_data;
    model.remote_va = request.remote_addr;
    model.rkey = request.rkey;
    model.signaled = request.signaled;
    model.solicited = request.solicited;
    model.fence = '0;
    model.qpn = link.local_qp_id;
    model.qp_sn = 0;
    model.icos = 0;
    model.dst_port = 0;
    model.index = cursor.index;
    model.wrap = cursor.wrap;
    model.sign_en = request.signaled;
    model.se = request.solicited;
    model.ce = request.signaled ? 2'b01 : 2'b00;
    model.valid = 1'b1;
    model.hw_opcode = request.opcode;
    model.invalidate_key = request.invalidate_rkey;
    model.destination_qpn = request.destination_qpn;
    model.qkey = request.qkey;
    model.sgb_iova = request.sgb_iova;
    // PMTU is copied only from the frozen QP link.  A request cannot invent a
    // packetization authority, so a missing value remains zero and the URC
    // codec rejects external-SGB READ before publishing a WQE.
    model.path_mtu_bytes = link.path_mtu_bytes;
    // 硬件模型只保存 MR/MW 的 profile object-ID；完整句柄（含 kind、
    // Function UID 和 generation）仍由 request snapshot 保留，供 ledger/
    // recovery 做 authority 校验，不能用截断 ID 代替生命周期证据。
    model.mr_handle_id = request.mr_h == null ? 0 : request.mr_h.object_id;
    model.mw_handle_id = request.mw_h == null ? 0 : request.mw_h.object_id;
    foreach (request.sges[i]) begin
      if (request.sges[i] == null)
        return bad("SQE request has a null SGE");
      cloned_sge = rdma_sge::type_id::create("sqe_sge");
      cloned_sge.copy(request.sges[i]);
      model.sges.push_back(cloned_sge);
    end
    // hardware model 是 SGE_NUM 的唯一 wire-facing authority。必须等 payload 与
    // SGE detached snapshot 都完成后再派生，使 inline ceil、empty、过滤后的
    // direct/external descriptor 以及 atomic fixed-one 与三个 writer 使用同一路径。
    model.sge_num = model.derive_sge_num();

    if (request.opcode inside {RDMA_WR_ATOMIC_CMP_SWAP,
                               RDMA_WR_ATOMIC_FETCH_ADD}) begin
      // 原子 fixed body 的 local IOVA/lkey 来自唯一 local SGE，而
      // compare/swap 值来自请求语义；四个字段必须一起投影，避免 codec
      // 看到默认零值后误编码一个可提交但语义错误的 WQE。
      model.atomic_local_iova = model.sges[0].iova;
      model.atomic_local_lkey = model.sges[0].lkey;
      model.atomic_compare = request.compare_value;
      model.atomic_value = request.swap_add_value;
    end
    case (request.transport)
      RDMA_TRANSPORT_RC: begin
        rc = rdma_sqe_rc_ext::type_id::create("sqe_rc");
        rc.remote_addr = request.remote_addr;
        rc.rkey = request.rkey;
        rc.remote_access_valid = request.remote_access_valid;
        rc.rkey_valid = request.rkey_valid;
        rc.compare_value = request.compare_value;
        rc.swap_add_value = request.swap_add_value;
        model.transport_ext = rc;
        model.rkey = request.rkey;
        model.remote_va = request.remote_addr;
      end
      RDMA_TRANSPORT_UD: begin
        ud = rdma_sqe_ud_ext::type_id::create("sqe_ud");
        ud.destination_qpn = request.destination_qpn;
        ud.qkey = request.qkey;
        ud.address_vector_id = request.address_vector_id;
        // AV 是 UD SQE 校验所需的完整 authority 对象；仅复制 ID 会让
        // request.validate() 通过但在硬件模型校验阶段丢失 AV 证据。
        ud.address_vector = request.address_vector;
        ud.address_vector_valid = request.address_vector_valid;
        model.transport_ext = ud;
      end
      RDMA_TRANSPORT_URC: begin
        urc = rdma_sqe_urc_ext::type_id::create("sqe_urc");
        urc.destination_qpn = request.destination_qpn;
        urc.remote_addr = request.remote_addr;
        urc.rkey = request.rkey;
        urc.remote_access_valid = request.remote_access_valid;
        urc.rkey_valid = request.rkey_valid;
        model.transport_ext = urc;
        if (request.completion_qp_h == null ||
            request.completion_qp_h.kind != RDMA_RESOURCE_QP)
          return bad("URC completion QP authority is missing");
        urc.completion_qp_h = request.completion_qp_h;
      end
      default:
        return bad("SQE transport is unsupported",
                   RDMA_SC_UNSUPPORTED_OPCODE);
    endcase
    status = model.validate();
    return status;
  endfunction

  // 功能：make_rqe 把 receive request 与 QP route/cursor 投影为可编码 RQE，
  //   深复制每个 SGE，并通过 rdma_hw_rqe_model 的 canonical authority helper
  //   统一派生有效 SGE 数与 32-bit payload length。
  // 输入/输出及副作用：request、link、cursor 为输入，model 先置 null；成功返回
  //   detached RQE model，不写 backing、不提交 PI 或取得 request/SGE 所有权。
  // 失败/边界：输入为空、SGE 为 null、raw 列表超过 32 项、reserved bit31 长度
  //   或有效 payload 超过 2GiB 时返回错误；零长度 SGE 会保留在 detached 列表中
  //   但从 payload_len/SGE_NUM 统计中滤除；任一失败都不发布半成品 model。
  protected function rdma_status make_rqe(
    rdma_post_recv_req request,
    rdma_queue_data_qp_link link,
    rdma_queue_cursor_snapshot cursor,
    output rdma_hw_rqe_model model
  );
    rdma_sge cloned_sge;
    rdma_hw_rqe_model candidate;
    rdma_status status;
    int unsigned valid_sge_count;
    longint unsigned valid_payload_len;

    model = null;

    if (request == null || link == null || cursor == null)
      return bad("RQE request, QP link, or reservation is null");

    candidate = rdma_hw_rqe_model::type_id::create("queue_rqe");
    if (candidate == null)
      return bad("RQE model allocation failed", RDMA_SC_INVALID_STATE);

    candidate.target_h = request.target_h;
    candidate.wr_id = request.wr_id;
    candidate.qpn = link.local_qp_id;
    candidate.qp_sn = 0;
    // wr.h:179 defines XTRDMA_OP_TYPE_RQ_WQE as 0x9; this is a fixed
    // receive-WQE hardware opcode, not a queue-data implementation choice.
    candidate.hw_opcode = 4'h9;
    candidate.index = cursor.index;
    candidate.wrap = cursor.wrap;
    candidate.valid = 1'b1;
    candidate.sge_num = 0;

    foreach (request.sges[i]) begin
      if (request.sges[i] == null)
        return bad("RQE request contains a null SGE");

      cloned_sge = rdma_sge::type_id::create("rqe_sge");
      if (cloned_sge == null)
        return bad("RQE SGE allocation failed", RDMA_SC_INVALID_STATE);
      cloned_sge.copy(request.sges[i]);
      candidate.sges.push_back(cloned_sge);
    end

    status = candidate.derive_typed_sge_authority(
        valid_sge_count, valid_payload_len);
    if (status == null || !status.ok())
      return status == null ?
        bad("RQE canonical SGE authority returned null status",
            RDMA_SC_INVALID_STATE) :
        status;
    candidate.sge_num = valid_sge_count;
    candidate.payload_len = valid_payload_len[31:0];
    status = candidate.validate();
    if (status == null || !status.ok())
      return status == null ?
        bad("RQE model validation returned null status", RDMA_SC_INVALID_STATE) :
        status;

    model = candidate;
    return rdma_status::success();
  endfunction

  // 功能：encode_queue_model 按 image kind/object/variant 查找共享 codec，并把
  //   SQE/RQE 或其他 queue model 编码成完整 hardware image。
  // 输入/输出及副作用：model、image_kind、object_type、variant 为输入，image 为
  //   输出；只读 model，成功结果由 codec 创建，函数不写 backing 或推进 cursor。
  // 失败/边界：registry 未命中或 codec 拒绝模型/布局时原样返回错误，image 保持
  //   codec 的失败输出；调用方不得在非成功 status 下提交部分 bytes。
  protected function rdma_status encode_queue_model(
    rdma_hw_model model, rdma_image_kind_e image_kind, string object_type,
    string variant, output rdma_hw_image image
  );
    rdma_codec_key codec_key;
    rdma_codec_base codec;
    rdma_status status;
    image = null;
    codec_key = '{hw_version:"rdma", image_kind:image_kind,
      object_type:object_type, variant:variant, opcode:8'h00};
    status = lookup_codec_checked(codec_key, "queue encode", codec);
    if (status == null || !status.ok())
      return status == null ?
        bad("queue codec lookup normalization failed", RDMA_SC_CODEC_ERROR) :
        status;
    status = codec.encode(model, image);
    if (status == null) begin
      image = null;
      return bad("queue codec encode returned null status",
                 RDMA_SC_CODEC_ERROR);
    end
    if (!status.ok()) begin
      image = null;
      return status;
    end
    if (image == null || image.length == 0 ||
        image.bytes.size() != image.length) begin
      image = null;
      return bad("queue codec returned an incomplete image",
                 RDMA_SC_CODEC_ERROR);
    end
    return status;
  endfunction

  // 功能：write_and_verify 把 host-produced WQE image 写到 attachment 相对 offset，
  //   再按相同 DMA 方向读回并逐字节校验。
  // 输入/输出及副作用：attachment、offset、image 为输入；可能写 Host-memory，
  //   但不修改 runtime PI/CI/ledger，调用方只在返回 OK 后继续提交。
  // 失败/边界：attachment/access/image 缺失、write/readback 失败、长度不等或 byte
  //   mismatch 时返回 INVALID_STATE/DMA 错误；不自动重试或回滚可能已写 bytes。
  protected function rdma_status write_and_verify(
      rdma_queue_data_attachment attachment,
      longint unsigned offset,
      rdma_hw_image image
  );
    byte data[];
    byte readback[];
    rdma_status status;
    if (attachment == null || attachment.access == null || image == null)
      return bad("queue write attachment/image is null",
                 RDMA_SC_INVALID_STATE);
    data = new[image.bytes.size()];
    foreach (data[i]) data[i] = image.bytes[i];
    status = attachment.access.write(offset, data);
    if (status == null || !status.ok())
      return status == null ?
        bad("queue write returned null status", RDMA_SC_DMA_TRANSLATION) :
        status;
    status = attachment.access.readback(offset, data.size(), readback);
    if (status == null || !status.ok())
      return status == null ?
        bad("queue readback returned null status", RDMA_SC_DMA_TRANSLATION) :
        status;
    if (readback.size() != data.size())
      return bad("queue write readback is short", RDMA_SC_DMA_TRANSLATION);
    foreach (readback[i]) begin
      if (readback[i] !== data[i])
        return bad("queue write readback mismatch", RDMA_SC_DMA_TRANSLATION);
    end
    return rdma_status::success();
  endfunction

  // 功能：write_sgb_and_verify 为 SQE 的外置 SGB 构造 512-byte 大端槽位，并
  //   完成 host-memory 写入/回读校验；写入前重新解析共享 payload authority，
  //   以 canonical mode/count 拦截 encode 后的 model mutation；inline payload
  //   的字节源与 codec 签名共用 rdma_hw_sqe_model 的 authority resolver，避免
  //   image 与 backing 分叉。
  // 输入/输出及副作用：link/model/cursor/image 为输入；image 是同一 model
  //   已编码并签名的 64-byte SQE 快照；link.sq_sgb_access 指向借用的 QP SGB
  //   backing，函数只写入该 backing，并把 inline 快照或原始 SGE 列表中的有效
  //   描述符压紧到连续槽位，不取得 model、SGE、image 或 mapping 的所有权。
  // 失败/边界：inline_bytes 与 payload 冲突、model 不是 external-SGB mode、
  //   canonical mode/count 与 model.sge_num 不一致、压紧后的 descriptor_index
  //   未覆盖全部 canonical SGE、缺少 SGB authority、原始 SGE 数超过 32、IOVA
  //   未按 512 对齐或超出 mapping 范围、后端写入/回读失败时返回对应
  //   INVALID_ARGUMENT/DMA/INVALID_STATE；image 缺失或其既有 signature 与构造出的
  //   512-byte data 不一致时也在首个 Host-memory write 前拒绝，调用方不得推进 PI。
  //   本 gate 不重新解析所有 opcode/remote/control header 字段，也不接受“重写
  //   header 后自行重算 signature”作为新的 authority；写入中途失败仍按既有
  //   recovery 证据处理。
  protected function rdma_status write_sgb_and_verify(
      rdma_queue_data_qp_link link, rdma_hw_sqe_model model,
      rdma_queue_cursor_snapshot cursor, rdma_hw_image image);
    byte data[];
    byte readback[];
    byte unsigned inline_payload[];
    byte unsigned signature_sgb[$];
    rdma_status status;
    rdma_sq_payload_mode_e payload_mode;
    rdma_sq_payload_mode_e canonical_mode;
    int unsigned valid_sge_count;
    int unsigned inline_payload_bytes;
    int unsigned canonical_sge_num;
    bit inline_bytes_are_authority;
    bit [31:0] len;
    bit [31:0] key;
    bit [63:0] va;
    longint unsigned sgb_offset;
    longint unsigned canonical_sge_payload_len;
    int unsigned descriptor_index;
    if (link == null || model == null || cursor == null || image == null ||
        link.sq_sgb_access == null)
      return bad("SQE SGB backing authority is unavailable", RDMA_SC_INVALID_STATE);

    status = model.validate_inline_payload_authority();
    if (status == null || !status.ok())
      return status == null ?
        bad("SQE inline payload authority returned null status",
            RDMA_SC_INVALID_STATE) :
        status;
    // Encode 与 SGB writer 必须复用同一 authority derivation。这里不信任
    // caller 在 encode 后可能改写的 sge_num，也不让 writer 按自身遍历结果
    // 静默重算 wire count；任何漂移都在首次 Host-memory write 前 fail-closed。
    model.derive_payload_authority(canonical_mode, valid_sge_count,
                                   inline_payload_bytes,
                                   inline_bytes_are_authority,
                                   canonical_sge_num);
    payload_mode = canonical_mode;
    if (canonical_sge_num > 8'hff || model.sge_num != canonical_sge_num)
      return bad("SQE SGB canonical payload count changed before write",
                 RDMA_SC_INVALID_STATE);
    if (!(payload_mode inside {RDMA_SQ_PAYLOAD_INLINE_SGB,
                               RDMA_SQ_PAYLOAD_SGE_SGB}))
      return bad("SQE SGB writer received a non-external payload mode",
                 RDMA_SC_INVALID_ARGUMENT);
    if (model.sgb_iova.value == 0 ||
        (model.sgb_iova.value & 64'h1ff) != 0)
      return bad("SQE SGB IOVA is not 512-byte aligned",
                 RDMA_SC_DMA_TRANSLATION);
    if (link.sq_sgb_ref == null || link.sq_sgb_ref.mapping == null)
      return bad("SQE SGB IOVA is outside backing authority",
                 RDMA_SC_DMA_TRANSLATION);
    data = new[512];
    foreach (data[i])
      data[i] = 0;
    begin
      longint unsigned logical_offset, covered, effective_iova;
      bit resolved;
      logical_offset = cursor.index * 512;
      covered = link.sq_sgb_ref.length;
      resolved = 1'b0;
      if (logical_offset + 512 > covered) begin
        foreach (link.sq_sgb_ref.additional_segments[k])
          covered += link.sq_sgb_ref.additional_segments[k].length;
      end
      if (logical_offset + 512 > covered)
        return bad("SQE SGB slot exceeds logical coverage",
                   RDMA_SC_DMA_TRANSLATION);
      if (logical_offset < link.sq_sgb_ref.length)
        effective_iova = link.sq_sgb_ref.mapping.iova.value +
                        link.sq_sgb_ref.mapping_offset + logical_offset;
      else begin
        longint unsigned base;
        base = link.sq_sgb_ref.length;
        foreach (link.sq_sgb_ref.additional_segments[k]) begin
          if (!resolved && logical_offset >= base &&
              logical_offset < base +
                link.sq_sgb_ref.additional_segments[k].length) begin
            effective_iova =
              link.sq_sgb_ref.additional_segments[k].mapping.iova.value +
              link.sq_sgb_ref.additional_segments[k].mapping_offset +
              (logical_offset - base);
            resolved = 1'b1;
          end
          base += link.sq_sgb_ref.additional_segments[k].length;
        end
      end
      if (!resolved && logical_offset < link.sq_sgb_ref.length)
        resolved = 1'b1;
      if (!resolved || model.sgb_iova.value != effective_iova)
        return bad("SQE SGB IOVA does not resolve to backing slot",
                   RDMA_SC_DMA_TRANSLATION);
    end
    if (payload_mode == RDMA_SQ_PAYLOAD_INLINE_SGB) begin
      status = model.resolve_inline_payload_authority(inline_payload);
      if (status == null || !status.ok())
        return status == null ?
          bad("SQE inline payload resolver returned null status",
              RDMA_SC_INVALID_STATE) :
          status;
      if (inline_payload.size() > 512)
        return bad("SQE inline SGB exceeds 512 bytes");
      foreach (inline_payload[i])
        data[i] = inline_payload[i];
    end else begin
      // 驱动先依据原始 wr->num_sge 做上限检查，再跳过 length==0 的
      // 条目；descriptor_index 只在有效条目上递增，保证后续 SGE
      // 紧接着写入前一个有效 descriptor，而不是保留空洞。
      if (model.sges.size() > RDMA_MAX_WQ_SGE)
        return bad("SQE SGB descriptor count exceeds 32");

      status = rdma_sge_authority::derive_send(
          model.sges, valid_sge_count, canonical_sge_payload_len);
      if (status == null || !status.ok())
        return status == null ?
          bad("SQE SGB SGE authority returned null status",
              RDMA_SC_INVALID_STATE) :
          status;
      if (valid_sge_count != canonical_sge_num)
        return bad("SQE SGB descriptor count is not canonical",
                   RDMA_SC_INVALID_STATE);

      descriptor_index = 0;
      foreach (model.sges[i]) begin
        if (model.sges[i].length == 0)
          continue;

        len = model.sges[i].length == 32'h8000_0000 ?
              32'b0 : model.sges[i].length;
        key = model.sges[i].lkey;
        va = model.sges[i].iova.value;

        for (int j = 0; j < 4; j++)
          data[descriptor_index * 16 + j] = len[31 - j * 8 -: 8];
        for (int j = 0; j < 4; j++)
          data[descriptor_index * 16 + 4 + j] = key[31 - j * 8 -: 8];
        for (int j = 0; j < 8; j++)
          data[descriptor_index * 16 + 8 + j] = va[63 - j * 8 -: 8];

        descriptor_index++;
      end
      if (descriptor_index != canonical_sge_num)
        return bad("SQE SGB descriptor packing count is not canonical",
                   RDMA_SC_INVALID_STATE);
    end

    // 设计：SQE signature 覆盖 detached SGB 字节。首次 backing write 前必须把
    // 待写 data 与已编码 image 重新比对；即使 descriptor 数量不变，length/lkey/
    // IOVA 或 inline 字节被篡改，也不能生成另一份自洽但签名不同的 SGB slot。
    begin
      bit signature_valid;
      signature_sgb.delete();
      foreach (data[i])
        signature_sgb.push_back(data[i]);
      status = validate_sq_signature(image, signature_sgb, signature_valid);
      if (status == null || !status.ok())
        return status == null ?
          bad("SQE SGB signature validation returned null status",
              RDMA_SC_INVALID_STATE) :
          status;
      if (!signature_valid)
        return bad("SQE SGB data does not match encoded SQE signature",
                   RDMA_SC_INVALID_STATE);
    end
    sgb_offset = cursor.index * 512;
    status = link.sq_sgb_access.write(sgb_offset, data);
    if (status == null || !status.ok())
      return status == null ?
        bad("SQE SGB write returned null status", RDMA_SC_DMA_TRANSLATION) :
        status;

    status = link.sq_sgb_access.readback(sgb_offset, 512, readback);
    if (status == null || !status.ok())
      return status == null ?
        bad("SQE SGB readback returned null status", RDMA_SC_DMA_TRANSLATION) :
        status;
    if (readback.size() != 512)
      return bad("SQE SGB readback is short", RDMA_SC_DMA_TRANSLATION);

    foreach (data[i]) begin
      if (readback[i] !== data[i])
        return bad("SQE SGB readback mismatch", RDMA_SC_DMA_TRANSLATION);
    end
    return rdma_status::success();
  endfunction

  // 功能：make_pending 为 legacy host producer/post 失败构造 recovery evidence，
  //   保存 queue/cursor、image、request、WR 与可选 completion route 字段，并尽量
  //   锁存 attachment 当前的 route/reset epoch，供 recovery 重放前再次核对。
  // 输入/输出及副作用：cursor 和其余事务字段为输入；成功返回 detached pending，
  //   handle/cursor/request/image/routed QP 均按值复制；source_attachment 只读查询
  //   runtime route/epoch，不修改源对象或 runtime，也不取得外部生命周期所有权。
  // 失败/边界：该兼容 factory 入口无 status；任一 nested clone 返回 null 或错误
  //   类型时返回 null，禁止把 request/image 缺失的半成品交给 enter_recovery；若
  //   route/epoch 查询失败则保留 route_valid/epoch_valid=0，使 replay 明确拒绝
  //   旧 evidence，而不是猜测当前 authority。
  protected function rdma_queue_pending_operation make_pending(
    rdma_queue_cursor_snapshot cursor,
    rdma_handle queue_h = null,
    rdma_queue_runtime_kind_e kind = RDMA_QUEUE_RUNTIME_SQ,
    bit producer = 1'b0,
    longint unsigned entry_offset = 0,
    rdma_hw_image image = null,
    rdma_semantic_request request_snapshot = null,
    bit signaled = 1'b0,
    int unsigned completion_index = 0,
    bit completion_wrap = 1'b0,
    bit completion_target_valid = 1'b0,
    bit completion_released = 1'b0,
    rdma_handle routed_qp_h = null,
    rdma_queue_data_attachment source_attachment = null
  );
    rdma_queue_pending_operation pending;
    rdma_status route_status;
    uvm_object cloned;
    rdma_post_send_req source_send;
    rdma_post_recv_req source_recv;
    rdma_post_send_req cloned_send;
    rdma_post_recv_req cloned_recv;

    pending = rdma_queue_pending_operation::type_id::create("queue_pending");
    if (pending == null)
      return null;

    // legacy 调用允许 queue_h/routed_qp_h 省略，由 runtime 在 admission 时从
    // 当前 attachment 补齐；但只要调用方提供了句柄，就必须保留完整 detached
    // identity，任何 clone/cast 失败都不能继续发布 recovery evidence。
    if (queue_h != null) begin
      if (!clone_pending_handle_value(queue_h, "pending queue",
                                      pending.queue_h)) begin
        pending = null;
        return null;
      end
    end
    pending.kind = kind;
    pending.producer = producer;
    pending.entry_offset = entry_offset;
    if (request_snapshot != null) begin
      if (!$cast(source_send, request_snapshot) &&
          !$cast(source_recv, request_snapshot)) begin
        pending = null;
        return null;
      end
    end
    if (!clone_pending_cursor_value(cursor, pending.cursor)) begin
      pending = null;
      return null;
    end
    pending.signaled = signaled;
    pending.completion_index = completion_index;
    pending.completion_wrap = completion_wrap;
    pending.completion_target_valid = completion_target_valid;
    pending.completion_released = completion_released;
    if (routed_qp_h != null &&
        !clone_pending_handle_value(routed_qp_h, "pending routed QP",
                                    pending.routed_qp_h)) begin
      pending = null;
      return null;
    end
    if (request_snapshot != null) begin
      cloned = request_snapshot.clone();
      if (cloned == null ||
          ($cast(source_send, request_snapshot) &&
           !$cast(cloned_send, cloned)) ||
          ($cast(source_recv, request_snapshot) &&
           !$cast(cloned_recv, cloned))) begin
        pending = null;
        return null;
      end
      if ($cast(source_send, request_snapshot)) begin
        pending.request_snapshot = cloned_send;
        pending.wr_id = cloned_send.wr_id;
      end
      else begin
        pending.request_snapshot = cloned_recv;
        pending.wr_id = cloned_recv.wr_id;
      end
    end
    if (image != null) begin
      cloned = image.clone();
      if (cloned == null || !$cast(pending.image, cloned)) begin
        pending = null;
        return null;
      end
    end
    if (source_attachment != null && source_attachment.runtime != null) begin
      route_status = source_attachment.runtime.query_route_epoch(
        pending.route, pending.route_valid, pending.reset_epoch,
        pending.epoch_valid);
      if (route_status == null || !route_status.ok() ||
          !pending.route_valid || !pending.epoch_valid ||
          !rdma_route_key_valid(pending.route)) begin
        pending.route = '0;
        pending.route_valid = 1'b0;
        pending.reset_epoch = '0;
        pending.epoch_valid = 1'b0;
      end
    end
    return pending;
  endfunction

  // 功能：clone_pending_handle_value 为 legacy pending 复制可选 queue/route handle，
  //   并显式检查多态 clone 的返回类型。
  // 输入/输出及副作用：source、label 为输入，copy 为输出；source 为空表示兼容的
  //   缺省句柄并返回成功，非空 source 成功时 copy 持有独立 identity 快照。
  // 失败/边界：clone 返回 null、错误类型或 copy 无法建立时返回 0 且 copy=null；
  //   不触发 UVM fatal，不把半成品句柄交给 pending/runtime。
  protected function bit clone_pending_handle_value(
    rdma_handle source,
    string label,
    output rdma_handle copy
  );
    uvm_object candidate;

    copy = null;
    if (source == null)
      return 1'b1;
    candidate = source.clone();
    if (candidate == null || !$cast(copy, candidate)) begin
      copy = null;
      return 1'b0;
    end
    return 1'b1;
  endfunction

  // 功能：clone_pending_cursor_value 深复制 pending 的当前 cursor，保证
  //   recovery evidence 不引用可变 caller 游标。
  // 输入/输出及副作用：source 为输入，copy 为输出；source 为空时 fail closed，
  //   成功时 copy 保存独立 index/wrap 快照，不修改 runtime 或 source。
  // 失败/边界：cursor clone 返回 null/错误类型时返回 0；该入口不为缺失 cursor
  //   猜测 producer/consumer 位置，也不创建默认游标。
  protected function bit clone_pending_cursor_value(
    rdma_queue_cursor_snapshot source,
    output rdma_queue_cursor_snapshot copy
  );
    uvm_object candidate;

    copy = null;
    if (source == null)
      return 1'b0;
    candidate = source.clone();
    if (candidate == null || !$cast(copy, candidate)) begin
      copy = null;
      return 1'b0;
    end
    return 1'b1;
  endfunction

  // 功能：pending_build_failure 把 legacy recovery evidence 无法构造的边界统一
  //   转换为调用方可观察的资源耗尽状态。
  // 输入/输出及副作用：context 为失败阶段描述；返回新的非成功 status，不修改
  //   runtime、reservation、Host-memory 或原始 request/image。
  // 失败/边界：该状态表示原始事务已经失败且无法保留可重放证据；调用方不得继续
  //   enter_recovery 或伪造成功，必须由更上层执行其既定隔离/复位策略。
  protected function rdma_status pending_build_failure(string ctx_snapshot);
    return bad({ctx_snapshot, " recovery evidence clone failed"},
               RDMA_SC_RESOURCE_EXHAUSTED);
  endfunction

  // 功能：projected_id_handle 复制 source 的 kind/Function/generation，并把 object ID
  //   替换为硬件 doorbell 使用的 local ID。
  // 输入/输出及副作用：source、local_id 为输入；返回 detached handle，不修改
  //   source、manager identity 或 engine route。
  // 失败/边界：source=null 或 clone/fallback 分配都失败时返回 null；投影只供已校验
  //   doorbell model，不能作为 global manager handle 或绕过完整 authority 校验。
  protected function rdma_handle projected_id_handle(
    rdma_handle source, int unsigned local_id
  );
    rdma_handle result;
    result = rdma_clone_handle_value(source, "doorbell model target");
    if (result == null)
      result = rdma_handle::type_id::create("doorbell_model_target_fallback");
    if (result == null || source == null)
      return null;
    result.kind = source.kind;
    result.function_uid = source.function_uid;
    result.generation = source.generation;
    result.object_id = local_id;
    return result;
  endfunction

  // 功能：query_sq_shadow_gate 从 QPC runtime shadow 读取硬件丢弃计数，并按
  //   驱动 wr.c 的 7-bit modulo 差值规则决定本次 SQ doorbell 是否可见。
  // 输入/输出及副作用：qp_h 为输入；gate_enabled、gate_allowed 和
  //   hw_drop_db_count 为输出；函数只读 context_backing 和 link 的冻结状态，
  //   不写 WQE、不推进 SQ cursor，也不调用 PCIe scheduler。
  // 失败/边界：context_backing=null 返回 legacy 的 enabled=0/allowed=1；读能力、
  //   QP link/context authority、返回 status 或 8-byte geometry 无效时 fail-closed，
  //   输出 allowed=0 并返回明确错误；硬件计数差值 bit6=1 时只抑制通知而不报错。
  protected function rdma_status query_sq_shadow_gate(
    rdma_handle qp_h,
    output bit gate_enabled,
    output bit gate_allowed,
    output bit [6:0] hw_drop_db_count
  );
    rdma_queue_data_qp_link link;
    rdma_status status;
    byte unsigned data[];
    longint unsigned shadow_qword;
    bit [6:0] delta;
    string key;

    gate_enabled = 1'b0;
    gate_allowed = 1'b1;
    hw_drop_db_count = '0;

    if (!qpc_shadow_gate_enabled)
      return rdma_status::success();

    gate_enabled = 1'b1;
    gate_allowed = 1'b0;
    if (context_backing == null)
      return bad("SQ shadow gate requires a context backing reader",
                 RDMA_SC_UNSUPPORTED_OPCODE);
    if (qp_h == null)
      return bad("SQ shadow gate QP handle is null", RDMA_SC_INVALID_ARGUMENT);

    key = value_ops::identity_key(qp_h);
    if (!qp_links.exists(key) || qp_links[key] == null)
      return bad("SQ shadow gate QP link is unavailable", RDMA_SC_INVALID_STATE);
    link = qp_links[key];
    if (link.context_ref == null)
      return bad("SQ shadow gate QPC context authority is unavailable",
                 RDMA_SC_INVALID_STATE);
    if (!link.sw_ring_db_count_valid) begin
      // A link created by an older factory override may not initialize the
      // optional counter.  The driver initializes its local count to zero;
      // establish the same value before the first observable read.
      link.sw_ring_db_count = 7'd0;
      link.sw_ring_db_count_valid = 1'b1;
    end

    data = new[0];
    status = context_backing.read(
      link.context_ref,
      RDMA_QPC_RUNTIME_SHADOW_BYTE_OFFSET,
      8,
      data
    );
    if (status == null)
      return bad("QPC runtime shadow read returned null status",
                 RDMA_SC_INVALID_STATE);
    if (!status.ok())
      return status;
    if (data.size() != 8)
      return bad("QPC runtime shadow read returned invalid byte count",
                 RDMA_SC_DMA_TRANSLATION);

    // Context backing exposes bytes in the hardware image's big-endian order.
    // Build the logical qword explicitly instead of indexing the serialized
    // byte array as though bit zero were at data[0].
    shadow_qword = 64'b0;
    foreach (data[i])
      shadow_qword = (shadow_qword << 8) | data[i];
    hw_drop_db_count = shadow_qword[54:48];

    // Both operands are deliberately seven bits: subtraction therefore wraps
    // modulo 128 exactly like the driver's __u8 arithmetic.  Bit six is the
    // driver's sign/credit discriminator.
    delta = hw_drop_db_count - link.sw_ring_db_count;
    gate_allowed = !delta[6];
    return rdma_status::success();
  endfunction

  // 功能：submit_producer_doorbell 为 SQ/RQ/SRQ 构造对应 doorbell model/image/desc，
  //   对 SQ 先按 QPC runtime shadow credit gate 决定是否通知，再经共享 scheduler
  //   提交已写 WQE 的 producer 通知。
  // 输入/输出及副作用：target_h、kind、reservation、next、SQE header、local_id 为
  //   输入，result/status 为输出；shadow gate=false 时 result=null 但 status=OK，
  //   不调用 scheduler；允许路径的 scheduler 调用产生 PCIe/MMIO 副作用。
  // 失败/边界：target/next 缺失、kind 非 posting ring、SQ header 不足、model/
  //   descriptor/authority 分配失败、shadow read 失败、codec null/失败或 scheduler
  //   返回不完整结果时不发布成功 result；本 helper 不提交 runtime PI/ledger。
  protected task submit_producer_doorbell(
    rdma_handle target_h, rdma_queue_runtime_kind_e kind,
    rdma_queue_cursor_snapshot reservation, rdma_queue_cursor_snapshot next,
    rdma_hw_image sqe_image, int unsigned local_id,
    output rdma_doorbell_result result,
    output rdma_status status
  );
    rdma_hw_sq_doorbell_model sq;
    rdma_hw_rq_doorbell_model rq;
    rdma_hw_srq_doorbell_model srq;
    rdma_hw_model model;
    rdma_hw_image image;
    rdma_codec_key codec_key;
    rdma_codec_base codec;
    rdma_doorbell_desc desc;
    string variant;
    longint unsigned relative_offset;
    uvm_object raw_model;
    uvm_object raw_desc;
    bit sq_gate_enabled;
    bit sq_gate_allowed;
    bit [6:0] sq_hw_drop_db_count;
    rdma_queue_data_qp_link sq_gate_link;

    result = null;
    model = null;
    image = null;
    status = null;
    sq_gate_enabled = 1'b0;
    sq_gate_allowed = 1'b1;
    sq_hw_drop_db_count = '0;
    sq_gate_link = null;
    if (target_h == null || next == null) begin
      status = bad("producer doorbell target/cursor is null");
      return;
    end
    case (kind)
      RDMA_QUEUE_RUNTIME_SQ: begin
        variant = "sq"; relative_offset = RDMA_DB_SQ_OFFSET;
        status = query_sq_shadow_gate(target_h, sq_gate_enabled,
                                      sq_gate_allowed, sq_hw_drop_db_count);
        if (status == null)
          status = bad("SQ shadow gate returned null status",
                       RDMA_SC_INVALID_STATE);
        if (!status.ok()) begin
          result = null;
          return;
        end
        if (sq_gate_enabled && !sq_gate_allowed) begin
          // The WQE has already been persisted by post_send.  A blocked
          // notify is a successful local producer commit, not queue full and
          // not an ambiguous scheduler transaction.
          status = rdma_status::success();
          result = null;
          return;
        end
        if (sq_gate_enabled) begin
          if (!qp_links.exists(value_ops::identity_key(target_h)) ||
              qp_links[value_ops::identity_key(target_h)] == null) begin
            status = bad("SQ shadow gate QP link disappeared",
                         RDMA_SC_INVALID_STATE);
            return;
          end
          sq_gate_link = qp_links[value_ops::identity_key(target_h)];
        end
        raw_model = value_ops::factory_create_object_nonfatal(
          rdma_hw_sq_doorbell_model::get_type(), "sq_db_model");
        if (raw_model == null || !$cast(sq, raw_model)) begin
          status = bad("SQ doorbell model allocation failed",
                       RDMA_SC_RESOURCE_EXHAUSTED);
          return;
        end
        sq.target_h = rdma_clone_handle_value(target_h, "SQ DB target");
        if (sq.target_h == null) begin
          status = bad("SQ doorbell target snapshot allocation failed",
                       RDMA_SC_RESOURCE_EXHAUSTED);
          return;
        end
        if (sqe_image == null || sqe_image.bytes.size() < RDMA_DB_BYTES) begin
          status = bad("SQ doorbell lacks the encoded SQE header");
          return;
        end
        foreach (sqe_image.bytes[i]) begin
          if (i >= RDMA_DB_BYTES) break;
          sq.sqe_header.push_back(sqe_image.bytes[i]);
        end
        model = sq;
      end
      RDMA_QUEUE_RUNTIME_RQ: begin
        variant = "rq"; relative_offset = RDMA_DB_RQ_OFFSET;
        raw_model = value_ops::factory_create_object_nonfatal(
          rdma_hw_rq_doorbell_model::get_type(), "rq_db_model");
        if (raw_model == null || !$cast(rq, raw_model)) begin
          status = bad("RQ doorbell model allocation failed",
                       RDMA_SC_RESOURCE_EXHAUSTED);
          return;
        end
        rq.target_h = projected_id_handle(target_h, local_id);
        if (rq.target_h == null) begin
          status = bad("RQ doorbell target snapshot allocation failed",
                       RDMA_SC_RESOURCE_EXHAUSTED);
          return;
        end
        rq.qpn = local_id; rq.icos = 0; rq.pi = next.index; rq.wrap = next.wrap;
        model = rq;
      end
      RDMA_QUEUE_RUNTIME_SRQ: begin
        variant = "srq_pi"; relative_offset = RDMA_DB_SRFQ_OFFSET;
        raw_model = value_ops::factory_create_object_nonfatal(
          rdma_hw_srq_doorbell_model::get_type(), "srq_db_model");
        if (raw_model == null || !$cast(srq, raw_model)) begin
          status = bad("SRQ doorbell model allocation failed",
                       RDMA_SC_RESOURCE_EXHAUSTED);
          return;
        end
        srq.target_h = projected_id_handle(target_h, local_id);
        if (srq.target_h == null) begin
          status = bad("SRQ doorbell target snapshot allocation failed",
                       RDMA_SC_RESOURCE_EXHAUSTED);
          return;
        end
        srq.variant = RDMA_SRQ_DB_PI; srq.srqn = local_id;
        srq.pi = next.index; srq.wrap = next.wrap; model = srq;
      end
      default: begin
        status = bad("producer runtime kind is not a posting ring");
        return;
      end
    endcase
    codec_key = '{hw_version:"rdma", image_kind:RDMA_IMAGE_DOORBELL,
      object_type:"doorbell", variant:variant, opcode:8'h00};
    status = lookup_codec_checked(codec_key, "producer doorbell", codec);
    if (status == null || !status.ok()) begin
      if (status == null)
        status = bad("producer doorbell lookup normalization failed",
                     RDMA_SC_CODEC_ERROR);
      return;
    end
    status = codec.encode(model, image);
    if (status == null) begin
      status = bad("producer doorbell encode returned null status",
                   RDMA_SC_CODEC_ERROR);
      return;
    end
    if (!status.ok())
      return;
    if (image == null || image.length != RDMA_DB_BYTES ||
        image.bytes.size() != RDMA_DB_BYTES) begin
      status = bad("producer doorbell codec returned an invalid image",
                   RDMA_SC_CODEC_ERROR);
      return;
    end
    raw_desc = value_ops::factory_create_object_nonfatal(
      rdma_doorbell_desc::get_type(), "producer_db_desc");
    if (raw_desc == null || !$cast(desc, raw_desc)) begin
      status = bad("producer doorbell descriptor allocation failed",
                   RDMA_SC_RESOURCE_EXHAUSTED);
      return;
    end
    desc.kind = (kind == RDMA_QUEUE_RUNTIME_SQ) ? RDMA_DOORBELL_SQ :
                (kind == RDMA_QUEUE_RUNTIME_RQ) ? RDMA_DOORBELL_RQ :
                                                   RDMA_DOORBELL_SRQ;
    desc.function_h = binding.make_handle();
    desc.target_h = rdma_clone_handle_value(target_h, "producer DB target");
    if (desc.function_h == null || desc.target_h == null) begin
      status = bad("producer doorbell authority snapshot allocation failed",
                   RDMA_SC_RESOURCE_EXHAUSTED);
      return;
    end
    desc.notify_bar_id = binding.notify_bar_id; desc.relative_offset = relative_offset;
    desc.width = RDMA_DB_BYTES; desc.endian = RDMA_ENDIAN_BIG;
    desc.payload_image = image; desc.barrier_policy = RDMA_DB_BARRIER_DMA_MMIO;
    desc.write_combining_policy = RDMA_DB_WRITE_NON_COMBINING;
    desc.allow_merge = 1'b0; desc.merge_requested = 1'b0;
    desc.timeout = operation_timeout; desc.readback_policy = RDMA_DB_READBACK_NONE;
    doorbells.submit(binding, desc, result, status);
    if (status == null) begin
      result = null;
      status = bad("producer doorbell scheduler returned null status",
                   RDMA_SC_INVALID_STATE);
    end
    else if (status.ok() && result == null)
      status = bad("producer doorbell scheduler returned no result",
                   RDMA_SC_INVALID_STATE);
    if (status != null && status.ok() && sq_gate_enabled &&
        sq_gate_link != null) begin
      // Keep the software count local to the link, exactly as the driver keeps
      // sw_ring_db_cnt outside the hardware shadow.  Explicitly wrap at 128;
      // the shadow field is seven bits even though the serialized qword is 64.
      sq_gate_link.sw_ring_db_count =
        (sq_hw_drop_db_count == 7'h7f) ? 7'd0 :
                                         sq_hw_drop_db_count + 7'd1;
      sq_gate_link.sw_ring_db_count_valid = 1'b1;
    end
  endtask

  // 功能：make_entry_image 把从 queue backing 读取的固定长度 bytes 包装为待解码的
  //   CQE/CEQE/AEQE hardware image，并填入当前 Function generation 与大端元数据。
  // 输入/输出及副作用：data、kind、entry_size 为输入，image 先置 null；成功创建
  //   detached image，只复制 bytes，不修改 backing 或 consumer cursor。
  // 失败/边界：entry_size=0 或 byte count 不等时返回 DMA_TRANSLATION；raw factory
  //   返回 null/错误类型时非致命返回 RESOURCE_EXHAUSTED，成功后才允许进入 codec。
  protected function rdma_status make_entry_image(
    byte data[], rdma_image_kind_e kind, int unsigned entry_size,
    output rdma_hw_image image
  );
    uvm_object raw_image;

    image = null;
    if (entry_size == 0 || data.size() != entry_size)
      return bad("queue entry byte count does not match attachment geometry",
                 RDMA_SC_DMA_TRANSLATION);
    raw_image = value_ops::factory_create_object_nonfatal(
      rdma_hw_image::get_type(), "queue_entry_image");
    if (raw_image == null || !$cast(image, raw_image)) begin
      image = null;
      return bad("queue entry image allocation failed",
                 RDMA_SC_RESOURCE_EXHAUSTED);
    end
    foreach (data[i]) image.bytes.push_back(data[i]);
    image.length = entry_size;
    image.alignment = entry_size;
    image.endian = RDMA_ENDIAN_BIG;
    image.image_kind = kind;
    image.hardware_version = RDMA_HW_VERSION;
    image.function_generation = binding.generation;
    image.write_target_kind = RDMA_HW_TARGET_NONE;
    image.backing_target = '0;
    image.hmc_target = '0;
    image.bar_target = '0;
    return rdma_status::success();
  endfunction

  // 功能：resolve_cqe_header_offset_for_image 根据 CQE image 的冻结 profile 长度
  //   解析驱动规定的公共 header 起始字节，供 owner、QPN 和 variant 读取共用。
  // 输入/输出及副作用：entry_image 为输入，header_offset 为输出；只检查 image
  //   长度与已有 byte 数量，不修改 image、runtime、route 或 codec 状态。
  // 失败/边界：32/64B header offset 为 0，128B header offset 为 64；长度不是
  //   32/64/128 或 image 不足 header 公共 qword 时返回 CODEC_ERROR/参数错误。
  protected function rdma_status resolve_cqe_header_offset_for_image(
    rdma_hw_image entry_image,
    output int unsigned header_offset
  );
    header_offset = 0;
    if (entry_image == null)
      return bad("CQE header image is null", RDMA_SC_INVALID_ARGUMENT);
    case (entry_image.length)
      32, 64: header_offset = 0;
      128: header_offset = 64;
      default:
        return bad("CQE header profile length is invalid",
                   RDMA_SC_CODEC_ERROR);
    endcase
    if (entry_image.bytes.size() < header_offset + 8)
      return bad("CQE image is shorter than its header window",
                 RDMA_SC_CODEC_ERROR);
    return rdma_status::success();
  endfunction

  // 功能：resolve_cqe_variant_for_image 从 CQE 公共 qword0 提取 qpn、RQ_CQE 和
  //       SRFQ 标志，先解析当前 CQ 对应的 QP route，再选择该次 decode 唯一的
  //       RC、UD 或 RQ/SRFQ overlay authority。
  // 输入/输出及副作用：cq_h、entry_image 和 header_offset 为输入；variant、link
  //       为输出的非拥有 route/variant 快照；函数只读 CQE bytes 与 qp_links，不修改
  //       runtime、codec registry 或 backing ownership。
  // 失败/边界：image 为空、header 窗口越界、qpn/CQ route 不唯一、route 缺失、
  //       send CQE 携带 srfq、receive CQE 的 SRFQ 位与 QP 的 SRQ presence 不一致，
  //       或 transport 非法时返回错误；没有 route 时禁止猜测 RC/UD variant，以免
  //       真实 UD qword3 被错误地按 reserved 位拒收或把 RQ overlay 解释成 send CQE。
  protected function rdma_status resolve_cqe_variant_for_image(
    rdma_handle cq_h,
    rdma_hw_image entry_image,
    int unsigned header_offset,
    output rdma_cqe_variant_e variant,
    output rdma_queue_data_qp_link link
  );
    longint unsigned qword0;
    int unsigned qpn;
    bit rq_cqe;
    bit srfq;
    rdma_status status;

    variant = RDMA_CQE_VARIANT_RC;
    link = null;
    qword0 = 64'b0;

    if (cq_h == null || entry_image == null ||
        entry_image.bytes.size() < header_offset + 8)
      return bad("CQE variant authority image is incomplete",
                 RDMA_SC_INVALID_ARGUMENT);

    for (int unsigned byte_index = 0; byte_index < 8; byte_index++)
      qword0 = (qword0 << 8) |
               entry_image.bytes[header_offset + byte_index];

    qpn = qword0[17:0];
    rq_cqe = qword0[59];
    srfq = qword0[58];
    status = find_qp_link_for_cq(cq_h, qpn, rq_cqe, link);
    if (status == null || !status.ok())
      return status == null ? bad("CQE variant route lookup returned null status",
                                  RDMA_SC_INVALID_STATE) : status;
    if (link == null)
      return bad("CQE variant route lookup returned no link", RDMA_SC_INVALID_STATE);

    status = resolve_cqe_variant_for_route(
      rq_cqe, srfq, link.transport, variant);
    if (status == null || !status.ok())
      return status == null ?
        bad("CQE image variant route resolver returned null status",
            RDMA_SC_INVALID_STATE) : status;
    status = validate_cqe_srfq_route_consistency(rq_cqe, srfq, link);
    return status == null ?
      bad("CQE image SRFQ route validation returned null status",
          RDMA_SC_INVALID_STATE) : status;
  endfunction

  // 功能：find_qp_link_for_cq 按 CQE qpn 与 send/receive 标志，在 qp_links 中选择
  //   唯一绑定当前 CQ 的 QP route；超宽 QPN 仅用于后续 width 拒绝诊断。
  // 输入/输出及副作用：cq_h、qpn、rq_cqe 为输入，link 先置 null；成功返回
  //   engine-owned link 的非拥有引用，不复制或修改 attachment。
  // 失败/边界：无匹配或同一 qpn/CQ 命中多个 QP 时返回 INVALID_STATE；send/recv
  //   CQ 不可互换，身份由 null 门禁后的 same_handle_instance 比较确认；低 18-bit
  //   投影也不能把超宽 local ID 变成合法 wire authority。
  protected function rdma_status find_qp_link_for_cq(
    rdma_handle cq_h, int unsigned qpn, bit rq_cqe,
    output rdma_queue_data_qp_link link
  );
    rdma_queue_data_qp_link candidate;
    link = null;
    foreach (qp_links[key]) begin
      candidate = qp_links[key];
      if (candidate == null || candidate.local_qp_id != qpn)
        continue;
      // 设计说明：同一 CQ 可以由 QP 的 send/receive 路径共享，同一 QP 也可为两条
      // 路径配置不同 CQ；因此必须按 CQE 的 receive bit 选择 route。接受相反方向的
      // CQ handle 会释放错误的 WQE ledger，不能仅凭 QPN 命中。
      if (value_ops::qp_link_cq_route_matches(candidate, cq_h, rq_cqe)) begin
        if (link != null)
          return bad("CQE QPN routes to multiple attached QPs",
                     RDMA_SC_INVALID_STATE);
        link = candidate;
      end
    end
    // 设计说明：resource manager 的 QP local ID 可宽于 CQE 的 18-bit qpn。
    // 精确 route 不存在时才识别低位投影相同的超宽 authority，让调用方在 encode
    // 前以完整 local_qp_id 返回 width 错误；绝不把该投影当作可发布的合法 QPN。
    if (link == null) begin
      foreach (qp_links[key]) begin
        candidate = qp_links[key];
        if (candidate == null || candidate.local_qp_id <= 18'h3ffff ||
            candidate.local_qp_id[17:0] != qpn)
          continue;
        if (value_ops::qp_link_cq_route_matches(candidate, cq_h, rq_cqe)) begin
          if (link != null)
            return bad("CQE projected QPN routes to multiple wide QPs",
                       RDMA_SC_INVALID_STATE);
          link = candidate;
        end
      end
    end
    if (link == null)
      return bad("CQE QPN has no attached QP route", RDMA_SC_INVALID_STATE);
    return rdma_status::success();
  endfunction

  // 功能：scan_qp_link_by_local_id 在 queue-data engine 的 QP link 索引中按完整
  //   local QPN 收集命中数量，并保留首个匹配 link 供调用方继续做 authority 判断。
  // 输入/输出及副作用：qpn 为输入；link 与 match_count 为输出，函数只读取
  //   engine-owned qp_links 并返回其中的非拥有 link 引用和命中计数，不修改索引、
  //   attachment、runtime、route/epoch 或任何资源生命周期状态。
  // 失败/边界：无匹配时 link=null、match_count=0；多个匹配时保留首个 link 并完整
  //   计数，函数本身不生成 status 或决定 route-miss/ambiguous 语义，零/多命中拒绝
  //   及错误消息必须由各调用者按原有阶段契约处理。
  protected function void scan_qp_link_by_local_id(
    int unsigned qpn,
    output rdma_queue_data_qp_link link,
    output int unsigned match_count
  );
    rdma_queue_data_qp_link candidate;

    link = null;
    match_count = 0;
    foreach (qp_links[key]) begin
      candidate = qp_links[key];
      if (candidate == null || candidate.local_qp_id != qpn)
        continue;
      if (link == null)
        link = candidate;
      match_count++;
    end
  endfunction

  // 功能：find_qp_link_for_local_id 按完整 local QPN 查找 CEQ/AEQ 或 recovery
  //   使用的唯一 QP route。
  // 输入/输出及副作用：qpn 为输入，link 先置 null；成功返回 engine-owned link 的
  //   非拥有引用，只读 qp_links。
  // 失败/边界：无匹配或命中多个 link 返回 INVALID_STATE；函数不做截断投影、
  //   Function/generation 修复或默认 QP 回退。
  protected function rdma_status find_qp_link_for_local_id(
    int unsigned qpn, output rdma_queue_data_qp_link link
  );
    int unsigned match_count;

    scan_qp_link_by_local_id(qpn, link, match_count);
    if (match_count > 1)
      return bad("event QPN routes to multiple attached QPs",
                 RDMA_SC_INVALID_STATE);
    if (match_count == 0)
      return bad("event QPN has no attached QP route", RDMA_SC_INVALID_STATE);
    return rdma_status::success();
  endfunction

  // 功能：scan_cq_attachment_by_local_id 在 queue-data engine 的 attachment 索引中
  //   按 CQ local ID 收集命中数量，并保留首个 CQ attachment 供调用者完成 handle
  //   clone 或 route-miss 处理。
  // 输入/输出及副作用：cqn 为输入；attachment 与 match_count 为输出；函数只读
  //   engine-owned attachments，返回其中的非拥有 attachment 引用和完整命中计数，
  //   不修改 attachment、runtime、CQ cursor、backing 或任何资源生命周期状态。
  // 失败/边界：仅统计非空且 kind 为 CQ、local_id 等于 cqn 的项；无命中输出 null/0，
  //   多命中保留首个并继续计数。函数不决定 clone 失败、零 route 或多 route 的
  //   status，调用者必须保留原错误消息、fallback 和 route_found 语义。
  protected function void scan_cq_attachment_by_local_id(
    int unsigned cqn,
    output rdma_queue_data_attachment attachment,
    output int unsigned match_count
  );
    rdma_queue_data_attachment candidate;

    attachment = null;
    match_count = 0;
    foreach (attachments[key]) begin
      candidate = attachments[key];
      if (candidate == null || candidate.kind != RDMA_QUEUE_RUNTIME_CQ ||
          candidate.local_id != cqn)
        continue;
      if (attachment == null)
        attachment = candidate;
      match_count++;
    end
  endfunction

  // 功能：lookup_event_qp_route_for_poll 在 AEQ poll 阶段按 wire QPN 查找当前
  //   Function 的 QP route，并把“没有对应对象”与“拓扑不唯一”分开报告。
  // 输入/输出及副作用：qpn 为 CEQ/AEQ image 解码出的 18-bit local ID；link 与
  //   route_found 为输出，成功唯一命中时返回 engine-owned link 非拥有引用，零命中
  //   时保持 link=null、route_found=0；函数只读 qp_links，不修改 runtime 或资源。
  // 失败/边界：同一 QPN 命中多个 attached link 返回 INVALID_STATE 且不允许消费；
  //   零命中是驱动允许的 stale/unknown event，返回 OK 让 caller 继续 CI/doorbell；
  //   函数不做低位投影、默认 QP 回退或跨 Function 猜测。
  protected function rdma_status lookup_event_qp_route_for_poll(
    int unsigned qpn,
    output rdma_queue_data_qp_link link,
    output bit route_found
  );
    int unsigned match_count;

    scan_qp_link_by_local_id(qpn, link, match_count);
    route_found = match_count != 0;
    if (match_count > 1)
      return bad("event QPN routes to multiple attached QPs",
                 RDMA_SC_INVALID_STATE);

    return rdma_status::success();
  endfunction

  // 功能：find_cq_handle_for_local_id 按 CEQE CQN 在 CQ attachments 中选择唯一
  //   route，并尽量返回 detached CQ handle 值。
  // 输入/输出及副作用：cqn 为输入，cq_h 先置 null；只读 attachments，成功结果
  //   由调用方使用，不取得 CQ runtime/backing 所有权。
  // 失败/边界：无匹配或多匹配返回 INVALID_STATE；handle clone 失败时兼容返回
  //   attachment 的非拥有引用，后续 prepared result 必须再次完成 non-fatal 值复制。
  protected function rdma_status find_cq_handle_for_local_id(
    int unsigned cqn, output rdma_handle cq_h
  );
    rdma_queue_data_attachment attachment;
    int unsigned match_count;

    cq_h = null;
    scan_cq_attachment_by_local_id(cqn, attachment, match_count);
    if (match_count > 1)
      return bad("CEQE CQN routes to multiple attached CQs",
                 RDMA_SC_INVALID_STATE);
    if (match_count == 0 || attachment == null)
      return bad("CEQE CQN has no attached CQ route", RDMA_SC_INVALID_STATE);
    cq_h = rdma_clone_handle_value(attachment.queue_h, "CEQE routed CQ");
    if (cq_h == null)
      cq_h = attachment.queue_h;
    if (cq_h == null)
      return bad("CEQE CQN has no attached CQ route", RDMA_SC_INVALID_STATE);
    return rdma_status::success();
  endfunction

  // 功能：lookup_event_cq_route_for_poll 在 CEQ poll 阶段按 wire CQN 查找当前
  //   Function 的 CQ attachment，并把 route miss 作为可消费的正常结果返回。
  // 输入/输出及副作用：cqn 为 CEQE qword0 的 local ID；cq_h 与 route_found 为输出，
  //   唯一命中时返回 CQ handle 值快照/非拥有兼容引用，零命中时保持 cq_h=null、
  //   route_found=0；函数只读 attachments，不改变 CQ runtime、CI 或 backing。
  // 失败/边界：多个 attachment 使用同一 CQN 返回 INVALID_STATE 且 caller 不得 ack；
  //   零命中返回 OK，caller 必须丢弃 payload 但仍完成 CEQ consumer transaction；
  //   clone 失败沿用现有兼容 fallback，后续 candidate preparation 仍会执行最终值复制。
  protected function rdma_status lookup_event_cq_route_for_poll(
    int unsigned cqn,
    output rdma_handle cq_h,
    output bit route_found
  );
    rdma_queue_data_attachment attachment;
    int unsigned match_count;

    cq_h = null;
    scan_cq_attachment_by_local_id(cqn, attachment, match_count);
    route_found = match_count != 0;
    if (match_count > 1)
      return bad("CEQE CQN routes to multiple attached CQs",
                 RDMA_SC_INVALID_STATE);
    if (match_count == 0 || attachment == null)
      return rdma_status::success();
    cq_h = rdma_clone_handle_value(attachment.queue_h,
                                   "CEQE poll routed CQ");
    if (cq_h == null)
      cq_h = attachment.queue_h;

    return rdma_status::success();
  endfunction

  // 功能：resolve_aeqe_routes 按驱动 ecode class 解析 AEQE 的 primary owner，
  //   并在 CQ flush packet 上附带可选的 QP secondary owner。
  // 输入/输出及副作用：aeqe_event 为已完成 reserved 校验的 AEQE；primary_h、
  //   secondary_h、event_class、primary_found/secondary_found 为输出；函数只读取
  //   当前 Function 的 resource manager authority，不修改 model、runtime 或 CI。
  // 失败/边界：SRQ/CQ/EQ 使用 ecode 规定的 wire ID，SRQ 不检查 srfq_en，CQ/EQ
  //   split ID 统一通过 AEQE 模型的 logical_cqn_eqn() 计算；只有
  //   INVALID_ARGUMENT/STALE_GENERATION 是独立 route miss，
  //   null status、成功但无 resource 或其他 manager 错误均 fail-closed。
  protected function rdma_status resolve_aeqe_routes(
    rdma_hw_aeqe_model aeqe_event,
    output rdma_aeqe_event_class_e event_class,
    output rdma_handle primary_h,
    output rdma_handle secondary_h,
    output bit primary_found,
    output bit secondary_found
  );
    rdma_resource primary_resource;
    rdma_resource secondary_resource;
    rdma_function_handle owner;
    rdma_status status;
    rdma_status primary_status;
    rdma_status secondary_status;
    int unsigned logical_id;
    bit primary_miss = 1'b0;
    bit secondary_miss = 1'b0;

    event_class = RDMA_AEQE_EVENT_QP;
    primary_h = null;
    secondary_h = null;
    primary_found = 1'b0;
    secondary_found = 1'b0;

    if (aeqe_event == null || binding == null || manager == null)
      return bad("AEQE route authority is incomplete", RDMA_SC_INVALID_STATE);
    if (!$cast(owner, binding.owner_h) || owner == null)
      return bad("AEQE Function owner handle is invalid",
                 RDMA_SC_INVALID_STATE);
    event_class = rdma_aeqe_event_class_from_ecode(aeqe_event.ecode);

    case (event_class)
      RDMA_AEQE_EVENT_QP: begin
        status = manager.lookup_local_resource(
          owner, RDMA_RESOURCE_QP, aeqe_event.qpn, primary_resource
        );
      end

      RDMA_AEQE_EVENT_SRQ: begin
        status = manager.lookup_local_resource(
          owner, RDMA_RESOURCE_SRQ, aeqe_event.srfqn, primary_resource
        );
      end

      RDMA_AEQE_EVENT_CQ: begin
        logical_id = aeqe_event.logical_cqn_eqn();
        primary_status = manager.lookup_local_resource(
          owner, RDMA_RESOURCE_CQ, logical_id, primary_resource
        );
        status = primary_status;
        if (aeqe_event.packet_opcode[4:0] == 5'h1d) begin
          secondary_status = manager.lookup_local_resource(
            owner, RDMA_RESOURCE_QP, aeqe_event.qpn, secondary_resource
          );
          if (secondary_status == null)
            return bad("AEQE CQ flush secondary route returned null status",
                       RDMA_SC_INVALID_STATE);
          if (!secondary_status.ok() &&
              !(secondary_status.code inside {RDMA_SC_INVALID_ARGUMENT,
                                               RDMA_SC_STALE_GENERATION}))
            return secondary_status;
          if (!secondary_status.ok())
            secondary_miss = 1'b1;
          else if (secondary_resource == null)
            return bad("AEQE CQ flush secondary route returned no resource",
                       RDMA_SC_INVALID_STATE);
        end
      end

      RDMA_AEQE_EVENT_EQ: begin
        logical_id = aeqe_event.logical_cqn_eqn();
        status = manager.lookup_local_resource(
          owner,
          aeqe_event.ecode == 8'hfb ? RDMA_RESOURCE_AEQ : RDMA_RESOURCE_CEQ,
          logical_id,
          primary_resource
        );
      end

      RDMA_AEQE_EVENT_DIAGNOSTIC: begin
        primary_h = rdma_clone_handle_value(
          owner, "AEQE diagnostic Function route"
        );
        primary_found = primary_h != null;
        return primary_found ? rdma_status::success() :
          bad("AEQE diagnostic Function route is unavailable",
              RDMA_SC_RESOURCE_EXHAUSTED);
      end

      RDMA_AEQE_EVENT_FLUSH: begin
        if (aeqe_event.ecode == 8'h08) begin
          status = manager.lookup_local_resource(
            owner, RDMA_RESOURCE_QP, aeqe_event.qpn, primary_resource
          );
        end
        else begin
          primary_h = rdma_clone_handle_value(
            owner, "AEQE TX flush Function route"
          );
          primary_found = primary_h != null;
          return primary_found ? rdma_status::success() :
            bad("AEQE TX flush Function route is unavailable",
                RDMA_SC_RESOURCE_EXHAUSTED);
        end
      end

      default:
        return bad("AEQE event class is invalid", RDMA_SC_INVALID_STATE);
    endcase

    if (status == null)
      return bad("AEQE primary route lookup returned null status",
                 RDMA_SC_INVALID_STATE);
    if (!status.ok()) begin
      if (!(status.code inside {RDMA_SC_INVALID_ARGUMENT,
                                RDMA_SC_STALE_GENERATION}))
        return status;
      primary_miss = 1'b1;
    end
    if (!primary_miss && primary_resource == null)
      return bad("AEQE primary route returned no resource",
                 RDMA_SC_INVALID_STATE);
    if (!primary_miss) begin
      primary_h = rdma_clone_handle_value(
        primary_resource.handle, "AEQE primary route"
      );
      if (primary_h == null)
        return bad("AEQE primary route snapshot allocation failed",
                   RDMA_SC_RESOURCE_EXHAUSTED);
      primary_found = 1'b1;
    end

    if (!secondary_miss && secondary_resource != null) begin
      secondary_h = rdma_clone_handle_value(
        secondary_resource.handle, "AEQE secondary route"
      );
      if (secondary_h == null)
        return bad("AEQE secondary route snapshot allocation failed",
                   RDMA_SC_RESOURCE_EXHAUSTED);
      secondary_found = 1'b1;
    end

    // CQ flush 的两个 found bit 独立冻结；publish 要求二者同时为真，poll 则可用
    // OR 交付 partial result。任一路 miss 都不能覆盖另一条 live route 的存在性。
    return rdma_status::success();
  endfunction

  // 功能：clone_slot_result 为 legacy 调用方复制一个 released WQE slot 的标量、
  //   request/image 和 completion status。
  // 输入/输出及副作用：source 为输入，result 先置 null；成功返回 detached slot，
  //   不修改 source 或 runtime ledger，也不取得 source nested 对象所有权。
  // 失败/边界：source=null 或 request/image clone 类型错误时返回错误并清空 result；
  //   CQ prepared poll 不使用此 fatal-prone 兼容 helper，而使用 runtime non-fatal range snapshot。
  protected function rdma_status clone_slot_result(
    rdma_queue_slot_ledger_entry source,
    output rdma_queue_slot_ledger_entry result
  );
    uvm_object cloned;
    result = null;
    if (source == null)
      return bad("released slot ledger entry is null", RDMA_SC_INVALID_STATE);
    result = rdma_queue_slot_ledger_entry::type_id::create("released_slot");
    result.posted = source.posted;
    result.consumed = source.consumed;
    result.signaled = source.signaled;
    result.wr_id = source.wr_id;
    result.index = source.index;
    result.wrap = source.wrap;
    if (source.request_snapshot != null) begin
      cloned = source.request_snapshot.clone();
      if (cloned == null || !$cast(result.request_snapshot, cloned)) begin
        result = null;
        return bad("released request snapshot clone failed",
                   RDMA_SC_RESOURCE_EXHAUSTED);
      end
    end
    if (source.image != null) begin
      cloned = source.image.clone();
      if (cloned == null || !$cast(result.image, cloned)) begin
        result = null;
        return bad("released image snapshot clone failed",
                   RDMA_SC_RESOURCE_EXHAUSTED);
      end
    end
    result.completion_status = rdma_clone_status_value(source.completion_status);
    return rdma_status::success();
  endfunction

  // 功能：completion_status_from_ecode 用 error codec 把 CQE/CEQE/AEQE 的 ecode
  //   与观测 engine 投影为业务 completion/event status。
  // 输入/输出及副作用：ecode、observed_engine 为输入，completion_status 先置 null；
  //   返回 codec 状态，成功输出新 rdma_status，不修改 model、runtime 或 backing。
  // 失败/边界：error codec 创建或 decode_status 失败时返回非成功且不得消费 queue；
  //   caller 必须同时检查返回 status 与 completion_status 非空，函数不自动重试。
  protected function rdma_status completion_status_from_ecode(
      bit [7:0] ecode, rdma_engine_kind_e observed_engine,
      output rdma_status completion_status
  );
    rdma_hw_error_codec error_codec;
    completion_status = null;
    error_codec = rdma_hw_error_codec::type_id::create("queue_error_codec");
    return error_codec.decode_status(ecode, observed_engine,
                                     completion_status);
  endfunction

  // 功能：prepare_cqc_shadow_publication 根据 CQ attachment 的冻结 context
  //   authority 和 CQ layout 构造驱动 CQC shadow 的 4-byte payload；普通 RC/UD
  //   写 CQ CI/wrap，URC 写 packed SQ/RQ consumer cursor。
  // 输入/输出及副作用：attachment、next 以及可选 routed_link/completion attachment
  //   为输入；offset、length、value、payload 为输出；函数只读取 owner/runtime
  //   authority 并物化 detached big-endian bytes，不写 context、CI、ledger 或 MMIO。
  // 失败/边界：context adapter 未配置、CQ authority/owner/geometry 不符、普通 CI
  //   超过 23-bit、URC route/cursor/15-bit index 不完整或 payload 分配失败时返回
  //   明确错误；没有完整 URC route 时禁止把普通 CQ CI 猜成 SQ/RQ cursor。
  protected function rdma_status prepare_cqc_shadow_publication(
    rdma_queue_data_attachment attachment,
    rdma_queue_cursor_snapshot next,
    output longint unsigned offset,
    output int unsigned length,
    output int unsigned value,
    output byte unsigned payload[],
    input rdma_queue_data_qp_link routed_link = null,
    input rdma_queue_data_attachment completion_attachment = null,
    input int unsigned completion_index = 0,
    input bit completion_wrap = 1'b0,
    input bit completion_target_valid = 1'b0,
    input bit completion_is_receive = 1'b0
  );
    rdma_function_handle function_h;
    rdma_queue_data_attachment other_attachment;
    rdma_queue_cursor_snapshot sq_cursor;
    rdma_queue_cursor_snapshot rq_cursor;
    rdma_status cursor_status;
    int unsigned post_index;
    bit post_wrap;
    int unsigned peer_producer_index;
    bit peer_producer_wrap;
    int unsigned peer_consumer_index;
    bit peer_consumer_wrap;
    int unsigned completion_producer_index;
    bit completion_producer_wrap;
    int unsigned completion_consumer_index;
    bit completion_consumer_wrap;
    bit urc_layout;

    offset = 0;
    length = 0;
    value = 0;
    payload = new[0];
    if (context_backing == null)
      return bad("CQC shadow adapter is not configured", RDMA_SC_UNSUPPORTED_OPCODE);
    if (attachment == null || attachment.kind != RDMA_QUEUE_RUNTIME_CQ ||
        attachment.context_ref == null || next == null)
      return bad("CQC shadow publication authority is incomplete",
                 RDMA_SC_INVALID_STATE);
    urc_layout = attachment.transport == RDMA_TRANSPORT_URC;
    if ((!urc_layout &&
         next.index >= (1 << RDMA_CQC_RUNTIME_SHADOW_CI_WIDTH)))
      return bad("CQC shadow CI exceeds driver width", RDMA_SC_INVALID_ARGUMENT);
    if (!value_ops::cqc_shadow_context_geometry_valid(attachment.context_ref,
                                           attachment.local_id))
      return bad("CQC shadow context geometry is not driver compatible",
                 RDMA_SC_INVALID_STATE);
    function_h = binding == null ? null : binding.make_handle();
    if (function_h == null || attachment.context_ref.owner == null ||
        !value_ops::cqc_shadow_context_owner_matches(attachment.context_ref, function_h))
      return bad("CQC shadow context owner is stale", RDMA_SC_STALE_GENERATION);

    offset = RDMA_CQC_RUNTIME_SHADOW_BYTE_OFFSET;
    length = RDMA_CQC_RUNTIME_SHADOW_BYTE_LENGTH;

    if (urc_layout) begin
      if (routed_link == null || routed_link.transport != RDMA_TRANSPORT_URC ||
          completion_attachment == null || !completion_target_valid ||
          completion_attachment.runtime == null ||
          !(completion_attachment.kind inside {RDMA_QUEUE_RUNTIME_SQ,
                                               RDMA_QUEUE_RUNTIME_RQ,
                                               RDMA_QUEUE_RUNTIME_SRQ}) ||
          completion_index >= completion_attachment.runtime.depth)
        return bad("URC CQC shadow completion route is incomplete",
                   RDMA_SC_INVALID_STATE);

      if (completion_is_receive) begin
        cursor_status = lookup_attachment(routed_link.qp_h,
                                           RDMA_QUEUE_RUNTIME_SQ,
                                           other_attachment);
      end
      else if (routed_link.srq_h != null) begin
        cursor_status = lookup_attachment(routed_link.srq_h,
                                           RDMA_QUEUE_RUNTIME_SRQ,
                                           other_attachment);
      end
      else begin
        cursor_status = lookup_attachment(routed_link.qp_h,
                                           RDMA_QUEUE_RUNTIME_RQ,
                                           other_attachment);
      end
      if (cursor_status == null || !cursor_status.ok() ||
          other_attachment == null || other_attachment.runtime == null)
        return cursor_status == null ?
          bad("URC CQC shadow peer cursor lookup returned null status",
              RDMA_SC_INVALID_STATE) : cursor_status;

      // query_cursors reads CI even when the peer WQ is empty.  peek_consumer
      // intentionally rejects an empty device ring, which is correct for a
      // CQ poll but incorrect for the packed URC shadow's untouched peer field.
      cursor_status = completion_attachment.runtime.query_cursors(
        completion_producer_index, completion_producer_wrap,
        completion_consumer_index, completion_consumer_wrap);
      if (cursor_status == null || !cursor_status.ok())
        return cursor_status == null ?
          bad("URC CQC shadow completion cursor is unavailable",
              RDMA_SC_INVALID_STATE) : cursor_status;
      cursor_status = other_attachment.runtime.query_cursors(
        peer_producer_index, peer_producer_wrap,
        peer_consumer_index, peer_consumer_wrap);
      if (cursor_status == null || !cursor_status.ok())
        return cursor_status == null ?
          bad("URC CQC shadow peer cursor is unavailable",
              RDMA_SC_INVALID_STATE) : cursor_status;
      if (completion_is_receive)
        cursor_status = value_ops::make_poll_cursor_nonfatal(
          peer_consumer_index, peer_consumer_wrap,
          "URC SQ peer", sq_cursor);
      else
        cursor_status = value_ops::make_poll_cursor_nonfatal(
          peer_consumer_index, peer_consumer_wrap,
          "URC RQ peer", rq_cursor);
      if (cursor_status == null || !cursor_status.ok())
        return cursor_status == null ?
          bad("URC CQC shadow peer cursor snapshot failed",
              RDMA_SC_RESOURCE_EXHAUSTED) : cursor_status;

      post_index = completion_index;
      post_wrap = completion_wrap;
      advance_queue_cursor_value(completion_attachment.runtime.depth,
                                 completion_index, completion_wrap,
                                 post_index, post_wrap);
      if (post_index > 15'h7fff)
        return bad("URC CQC shadow consumer index exceeds driver width",
                   RDMA_SC_INVALID_ARGUMENT);

      if (completion_is_receive) begin
        cursor_status = value_ops::make_poll_cursor_nonfatal(
          post_index, post_wrap, "URC RQ completion", rq_cursor);
      end
      else begin
        cursor_status = value_ops::make_poll_cursor_nonfatal(
          post_index, post_wrap, "URC SQ completion", sq_cursor);
      end
      if (cursor_status == null || !cursor_status.ok())
        return cursor_status == null ?
          bad("URC CQC shadow completion cursor snapshot failed",
              RDMA_SC_RESOURCE_EXHAUSTED) : cursor_status;
      if (sq_cursor.index > 15'h7fff || rq_cursor.index > 15'h7fff)
        return bad("URC CQC shadow peer index exceeds driver width",
                   RDMA_SC_INVALID_ARGUMENT);
      value = (sq_cursor.wrap << 31) |
              (sq_cursor.index << 16) |
              (rq_cursor.wrap << 15) |
              rq_cursor.index;
    end
    else begin
      value = (next.wrap << RDMA_CQC_RUNTIME_SHADOW_WRAP_BIT) | next.index;
    end
    payload = new[length];
    payload[0] = value[31:24];
    payload[1] = value[23:16];
    payload[2] = value[15:8];
    payload[3] = value[7:0];
    return rdma_status::success();
  endfunction

  // 功能：publish_cqc_shadow 在已 admission 的 CQ pending 上执行一次驱动 CQC
  //   shadow CI/wrap host-memory 写，并把 attempted/published 阶段发布给 runtime。
  // 输入/输出及副作用：attachment、pending 为输入，status 为输出；函数只写冻结
  //   context_ref 的绝对 shadow offset，不调用 doorbell scheduler、不推进 CI 或 WQE
  //   ledger，成功时 runtime 保持 MMIO evidence=NO_SUBMIT。
  // 失败/边界：authority/geometry/cursor 变化、重复或非法阶段、context write 返回
  //   null/失败、阶段 marker 失败时返回 RECOVERY_REQUIRED 或原始错误；写失败保留
  //   attempted 证据但不置 published，调用方不得继续 commit consumer。
  // 该 task 保持 virtual 只为 test-only scheduler seam 提供受控观测点；生产
  // 实例始终使用下方真实 CQC context shadow 实现，不存在 legacy MMIO fallback。
  protected virtual task publish_cqc_shadow(
    rdma_queue_data_attachment attachment,
    rdma_queue_pending_operation pending,
    output rdma_status status
  );
    rdma_status shadow_status;
    rdma_status noalloc_status;
    rdma_function_handle function_h;
    longint unsigned offset;
    int unsigned length;
    int unsigned value;
    byte unsigned payload[];

    status = null;
    if (attachment == null || attachment.runtime == null || pending == null ||
        !pending.consumer_shadow_required ||
        pending.kind != RDMA_QUEUE_RUNTIME_CQ) begin
      status = bad("CQC shadow pending authority is incomplete",
                   RDMA_SC_INVALID_STATE);
      return;
    end

    if (context_backing == null || attachment.context_ref == null ||
        !value_ops::cqc_shadow_context_geometry_valid(attachment.context_ref,
                                           attachment.local_id) ||
        pending.consumer_shadow_urc !=
          (attachment.transport == RDMA_TRANSPORT_URC)) begin
      status = bad("CQC shadow replay authority is stale",
                   RDMA_SC_STALE_GENERATION);
      return;
    end
    function_h = binding == null ? null : binding.make_handle();
    if (function_h == null || attachment.context_ref.owner == null ||
        !value_ops::cqc_shadow_context_owner_matches(attachment.context_ref, function_h)) begin
      status = bad("CQC shadow replay context owner is stale",
                   RDMA_SC_STALE_GENERATION);
      return;
    end
    offset = pending.consumer_shadow_offset;
    length = pending.consumer_shadow_length;
    value = pending.consumer_shadow_value;
    if (offset != RDMA_CQC_RUNTIME_SHADOW_BYTE_OFFSET ||
        length != RDMA_CQC_RUNTIME_SHADOW_BYTE_LENGTH ||
        (!pending.consumer_shadow_urc && value[31:24] != 8'h00)) begin
      status = bad("CQC shadow pending target is invalid",
                   RDMA_SC_STALE_GENERATION);
      return;
    end
    // Recovery must replay the exact bytes admitted on the first attempt.  It
    // is intentionally forbidden to derive a new value from mutable QP route
    // state or the current cursor geometry.
    payload = new[length];
    payload[0] = value[31:24];
    payload[1] = value[23:16];
    payload[2] = value[15:8];
    payload[3] = value[7:0];

    noalloc_status = pending.failure_status;
    if (noalloc_status == null) begin
      status = bad("CQC shadow pending status slot is unavailable",
                   RDMA_SC_RECOVERY_REQUIRED);
      return;
    end

    if (!pending.consumer_shadow_attempted) begin
      if (!attachment.runtime.record_recovery_failure_noalloc(
            RDMA_QUEUE_MMIO_NO_SUBMIT, null, noalloc_status)) begin
        status = noalloc_status;
        return;
      end
      if (!attachment.runtime.mark_pending_consumer_shadow_attempted_noalloc(
            noalloc_status)) begin
        status = noalloc_status;
        return;
      end
    end

    if (pending.consumer_shadow_published) begin
      void'(value_ops::set_status_noalloc(noalloc_status, RDMA_SC_OK, ""));
      status = noalloc_status;
      return;
    end

    shadow_status = context_backing.write(
      attachment.context_ref, offset, payload);
    if (shadow_status == null) begin
      void'(value_ops::set_status_noalloc(
        noalloc_status, RDMA_SC_RECOVERY_REQUIRED,
        "CQC shadow context write returned null status"));
      status = noalloc_status;
      return;
    end
    if (!shadow_status.ok()) begin
      if (!attachment.runtime.record_recovery_failure_noalloc(
            RDMA_QUEUE_MMIO_NO_SUBMIT, shadow_status, noalloc_status)) begin
        void'(value_ops::set_status_noalloc(
          noalloc_status, RDMA_SC_RECOVERY_REQUIRED,
          "CQC shadow write failure evidence could not be retained"));
        status = noalloc_status;
      end
      else begin
        status = shadow_status;
      end
      return;
    end

    if (!attachment.runtime.mark_pending_consumer_shadow_published_noalloc(
          noalloc_status)) begin
      status = noalloc_status;
      return;
    end
    status = noalloc_status;
  endtask

  // 功能：prepare_consumer_doorbell 在 recovery admission 前完成 CQ/CEQ/AEQ
  //   doorbell model、codec image、descriptor 与 post-scheduler status slot 物化。
  // 输入/输出及副作用：attachment/next/routed_link 为输入，prepared_desc 与
  //   noalloc_status 为输出；只读 frozen route/WQ cursor，不调用 scheduler 或改 ledger。
  // 失败/边界：依赖/null/wrong-type model/handle/descriptor、registry/null status/null
  //   codec、encode error/null image 均返回非成功，输出不发布且 MMIO evidence 未建立。
  protected function rdma_status prepare_consumer_doorbell(
    rdma_queue_data_attachment attachment,
    rdma_queue_cursor_snapshot next,
    rdma_queue_data_qp_link routed_link,
    output rdma_doorbell_desc prepared_desc,
    output rdma_status noalloc_status
  );
    rdma_hw_ceq_doorbell_model ceq;
    rdma_hw_aeq_doorbell_model aeq;
    rdma_hw_model model;
    rdma_hw_image image;
    rdma_codec_key codec_key;
    rdma_codec_base codec;
    rdma_doorbell_desc desc;
    rdma_status status;
    rdma_function_handle function_h;
    rdma_handle model_target_h;
    rdma_handle descriptor_target_h;
    rdma_doorbell_desc desc_candidate;
    uvm_object raw_model;
    uvm_object raw_desc;
    uvm_object raw_function_h;
    uvm_object raw_status;
    string variant;
    longint unsigned relative_offset;

    prepared_desc = null;
    noalloc_status = null;
    if (attachment == null || attachment.queue_h == null ||
        attachment.runtime == null || next == null || binding == null ||
        registry == null || doorbells == null)
      return value_ops::make_status_nonfatal(
        RDMA_SC_INVALID_ARGUMENT,
        "consumer doorbell preparation input is incomplete");

    // 驱动 0.1.34 的 CQ consumer CI 只由 CQC context shadow offset +4 发布，
    // 不存在对应的 CQ consumer MMIO doorbell。CQ poll 在有 context backing 时
    // 走 shadow publication；没有 backing 时在入口拒绝，因此这里的 CQ 分支
    // 只能服务历史 recovery seam，必须 fail-closed，不能重新物化错误 descriptor。
    if (attachment.kind == RDMA_QUEUE_RUNTIME_CQ)
      return rdma_status::make(
        RDMA_SC_UNSUPPORTED_OPCODE,
        "CQ consumer CI uses CQC context shadow, not MMIO doorbell");

    status = value_ops::clone_poll_handle_nonfatal(
      attachment.queue_h, "consumer doorbell model", model_target_h);
    if (status == null || !status.ok() || model_target_h == null)
      return status == null || status.ok() ? value_ops::make_status_nonfatal(
        RDMA_SC_RESOURCE_EXHAUSTED,
        "consumer doorbell model target allocation failed") : status;
    model_target_h.object_id = attachment.local_id;

    case (attachment.kind)
      RDMA_QUEUE_RUNTIME_CEQ: begin
        variant = "ceq";
        relative_offset = RDMA_DB_CEQ_OFFSET;
        raw_model = value_ops::factory_create_object_nonfatal(
          rdma_hw_ceq_doorbell_model::get_type(), "ceq_ci_db_model");
        if (raw_model == null || !$cast(ceq, raw_model))
          return value_ops::make_status_nonfatal(
            RDMA_SC_RESOURCE_EXHAUSTED,
            "CEQ consumer doorbell model allocation failed");
        ceq.target_h = model_target_h;
        ceq.ceqn = attachment.local_id;
        ceq.ci = next.index;
        ceq.wrap = next.wrap;
        model = ceq;
      end
      RDMA_QUEUE_RUNTIME_AEQ: begin
        variant = "aeq";
        relative_offset = RDMA_DB_AEQ_OFFSET;
        raw_model = value_ops::factory_create_object_nonfatal(
          rdma_hw_aeq_doorbell_model::get_type(), "aeq_ci_db_model");
        if (raw_model == null || !$cast(aeq, raw_model))
          return value_ops::make_status_nonfatal(
            RDMA_SC_RESOURCE_EXHAUSTED,
            "AEQ consumer doorbell model allocation failed");
        aeq.target_h = model_target_h;
        aeq.aeqn = attachment.local_id;
        aeq.ci = next.index;
        aeq.wrap = next.wrap;
        model = aeq;
      end
      default:
        return value_ops::make_status_nonfatal(
          RDMA_SC_INVALID_ARGUMENT,
          "consumer doorbell runtime kind is invalid");
    endcase
    codec_key = '{hw_version:"rdma", image_kind:RDMA_IMAGE_DOORBELL,
      object_type:"doorbell", variant:variant, opcode:8'h00};
    status = registry.lookup(codec_key, codec);
    if (status == null)
      return value_ops::make_status_nonfatal(
        RDMA_SC_INVALID_STATE,
        "consumer doorbell registry returned null status");
    if (!status.ok()) return status;
    if (codec == null)
      return value_ops::make_status_nonfatal(
        RDMA_SC_RESOURCE_EXHAUSTED,
        "consumer doorbell registry returned null codec");
    status = codec.encode(model, image);
    if (status == null)
      return value_ops::make_status_nonfatal(
        RDMA_SC_INVALID_STATE,
        "consumer doorbell codec returned null status");
    if (!status.ok()) return status;
    if (image == null || image.length == 0 ||
        image.bytes.size() != image.length)
      return value_ops::make_status_nonfatal(
        RDMA_SC_CODEC_ERROR,
        "consumer doorbell codec returned an invalid image");

    raw_desc = value_ops::factory_create_object_nonfatal(
      rdma_doorbell_desc::get_type(), "consumer_db_desc");
    if (raw_desc == null || !$cast(desc_candidate, raw_desc))
      return value_ops::make_status_nonfatal(
        RDMA_SC_RESOURCE_EXHAUSTED,
        "consumer doorbell descriptor allocation failed");
    raw_function_h = value_ops::factory_create_object_nonfatal(
      rdma_function_handle::get_type(), "consumer_db_function_handle");
    if (raw_function_h == null || !$cast(function_h, raw_function_h))
      return value_ops::make_status_nonfatal(
        RDMA_SC_RESOURCE_EXHAUSTED,
        "consumer doorbell Function handle allocation failed");
    function_h.kind = RDMA_RESOURCE_FUNCTION;
    function_h.function_uid = binding.function_uid;
    function_h.object_id = binding.global_function_id;
    function_h.generation = binding.generation;
    if (!binding.accepts(function_h))
      return value_ops::make_status_nonfatal(
        RDMA_SC_STALE_GENERATION,
        "consumer doorbell Function authority is stale");
    status = value_ops::clone_poll_handle_nonfatal(
      attachment.queue_h, "consumer doorbell descriptor",
      descriptor_target_h);
    if (status == null || !status.ok() || descriptor_target_h == null)
      return status == null || status.ok() ? value_ops::make_status_nonfatal(
        RDMA_SC_RESOURCE_EXHAUSTED,
        "consumer doorbell descriptor target allocation failed") : status;

    case (attachment.kind)
      RDMA_QUEUE_RUNTIME_CEQ: desc_candidate.kind = RDMA_DOORBELL_CEQ;
      RDMA_QUEUE_RUNTIME_AEQ: desc_candidate.kind = RDMA_DOORBELL_AEQ;
      default:
        return value_ops::make_status_nonfatal(
          RDMA_SC_INVALID_ARGUMENT,
          "consumer doorbell descriptor kind is invalid");
    endcase
    desc_candidate.function_h = function_h;
    desc_candidate.target_h = descriptor_target_h;
    desc_candidate.notify_bar_id = binding.notify_bar_id;
    desc_candidate.relative_offset = relative_offset;
    desc_candidate.width = RDMA_DB_BYTES;
    desc_candidate.endian = RDMA_ENDIAN_BIG;
    desc_candidate.payload_image = image;
    desc_candidate.barrier_policy = RDMA_DB_BARRIER_MMIO;
    desc_candidate.write_combining_policy = RDMA_DB_WRITE_NON_COMBINING;
    desc_candidate.allow_merge = 1'b0;
    desc_candidate.merge_requested = 1'b0;
    desc_candidate.timeout = operation_timeout;
    desc_candidate.readback_policy = RDMA_DB_READBACK_NONE;

    raw_status = value_ops::factory_create_object_nonfatal(
      rdma_status::get_type(), "consumer_noalloc_status");
    if (raw_status == null || !$cast(noalloc_status, raw_status)) begin
      noalloc_status = null;
      return value_ops::make_status_nonfatal(
        RDMA_SC_RESOURCE_EXHAUSTED,
        "consumer no-allocation status slot allocation failed");
    end
    void'(value_ops::set_status_noalloc(noalloc_status, RDMA_SC_OK, ""));
    prepared_desc = desc_candidate;
    return noalloc_status;
  endfunction

  // 功能：submit_consumer_doorbell 通过既有 virtual seam 提交 admission 前预建的
  //   descriptor；legacy caller 未提供时仍先在 scheduler 外完成同一准备。
  // 输入/输出及副作用：attachment/next/routed_link 与可选 prepared_desc/
  //   prepared_status 为输入，result/status/evidence 为输出；仅 submit 可能产生 MMIO。
  // 失败/边界：准备失败保持 NO_SUBMIT；submit 前一刻置 AMBIGUOUS；scheduler 的
  //   null/incomplete success 使用预建 slot 归一化，barrier 后不 factory/new/codec。
  protected virtual task submit_consumer_doorbell(
    rdma_queue_data_attachment attachment,
    rdma_queue_cursor_snapshot next,
    output rdma_doorbell_result result,
    output rdma_status status,
    output rdma_queue_mmio_evidence_e evidence,
    input rdma_queue_data_qp_link routed_link,
    input rdma_doorbell_desc prepared_desc = null,
    input rdma_status prepared_status = null
  );
    rdma_doorbell_desc desc;

    result = null;
    status = null;
    evidence = RDMA_QUEUE_MMIO_NO_SUBMIT;
    desc = prepared_desc;
    if (desc == null) begin
      status = prepare_consumer_doorbell(
        attachment, next, routed_link, desc, prepared_status);
      if (status == null || !status.ok() || desc == null ||
          prepared_status == null)
        return;
    end
    if (prepared_status == null || doorbells == null) return;

    // 中文设计：只有所有 caller-local preparation 已成功才跨 scheduler barrier；
    // 从 AMBIGUOUS 发布到 task 返回期间只读取既有对象并写标量 evidence/status。
    evidence = RDMA_QUEUE_MMIO_AMBIGUOUS;
    doorbells.submit(binding, desc, result, status);
    if (status != null && status.ok() && result != null)
      evidence = RDMA_QUEUE_MMIO_SUCCESS;
    else if (status == null) begin
      void'(value_ops::set_status_noalloc(
        prepared_status, RDMA_SC_INVALID_STATE,
        "consumer doorbell scheduler returned null status"));
      status = prepared_status;
    end
    else if (status.ok() && result == null) begin
      void'(value_ops::set_status_noalloc(
        prepared_status, RDMA_SC_INVALID_STATE,
        "consumer doorbell scheduler returned null result"));
      status = prepared_status;
    end
  endtask

  // 功能：select_cq_poll_wq_target_contract 根据冻结 CQE 的 receive 标志和 QP
  //   link，唯一确定本次 completion 应使用的目标 handle、runtime kind 与 backing
  //   role；它把 SQ、私有 RQ、共享 SRQ 的方向分支收束为后续 validator 可复用的
  //   只读 contract。
  // 输入/输出及副作用：cqe、link 为已冻结的 CQE/route 输入；target_h、
  //   expected_wq_kind、expected_role 为输出的非拥有 handle 和枚举快照。函数只
  //   读取输入字段，不查询 attachment/runtime，不推进 cursor，不创建 pending，
  //   不修改 ledger、Host-memory、MMIO 或任何生命周期所有权。
  // 失败/边界：cqe/link/QP handle 为空、QP/SRQ kind 不匹配或 SRQ target 缺失时
  //   返回 INVALID_ARGUMENT/INVALID_STATE，并把输出保持为安全默认值；send CQE
  //   忽略未被选中的 link.srq_h，receive CQE 则严格区分私有 RQ 与共享 SRQ。该
  //   selector 不验证 attachment 的 geometry/handle incarnation，调用方必须随后
  //   调用 validate_cq_poll_wq_attachment；cqe.qp_h 不作为第二条 authority，因
  //   poll caller 已在 resolve_cqe_variant_for_image/find_qp_link_for_cq 中依据 wire
  //   QPN 与 CQ route 冻结 link，避免可变 model handle 绕过 canonical route。它也
  //   不替代 CQ route/epoch admission。
  protected function rdma_status select_cq_poll_wq_target_contract(
    rdma_hw_cqe_model cqe,
    rdma_queue_data_qp_link link,
    output rdma_handle target_h,
    output rdma_queue_runtime_kind_e expected_wq_kind,
    output rdma_queue_backing_role_e expected_role
  );
    rdma_queue_wq_target_contract_t target_contract;

    target_h = null;
    expected_wq_kind = RDMA_QUEUE_RUNTIME_SQ;
    expected_role = RDMA_QUEUE_ROLE_QP_SQ_RING;

    if (cqe == null || link == null || link.qp_h == null ||
        link.qp_h.kind != RDMA_RESOURCE_QP)
      return bad("CQ poll completion target input is incomplete",
                 RDMA_SC_INVALID_ARGUMENT);

    // 中文设计：wire route 到 runtime kind/role 的映射只由 detached policy 计算；
    // handle kind、SRQ incarnation 和 attachment geometry 仍在本 caller 后续阶段
    // 校验，避免 policy 取得或复制 queue ownership。
    if (link.srq_h != null && link.srq_h.kind != RDMA_RESOURCE_SRQ)
      return bad("CQ poll completion SRQ handle kind is invalid",
                 RDMA_SC_INVALID_ARGUMENT);
    if (!rdma_queue_wq_target_policy::for_cqe(
          cqe.rq_cqe, cqe.rq_cqe ? (link.srq_h != null) : 1'b0,
          target_contract))
      return bad("CQ poll completion target policy input is unknown",
                 RDMA_SC_INVALID_ARGUMENT);

    expected_wq_kind = target_contract.runtime_kind;
    expected_role = target_contract.backing_role;

    if (cqe.rq_cqe) begin
      if (link.srq_h != null) begin
        target_h = link.srq_h;
      end
      else begin
        target_h = link.qp_h;
      end
    end
    else begin
      target_h = link.qp_h;
    end

    if (target_h == null)
      return bad("CQ poll completion target handle is unavailable",
                 RDMA_SC_INVALID_STATE);
    return rdma_status::success();
  endfunction

  // 功能：validate_cq_poll_wq_attachment 对由冻结 CQE/link 推导出的 target
  //   contract 执行 CQ→WQ release 前的只读 attachment authority 校验，集中检查
  //   runtime 可用性、WQE ring geometry、runtime kind、backing role 与完整 handle
  //   incarnation，避免首次 resolver 与 admission 前 canonical relookup 使用两套
  //   不一致的门禁。
  // 输入/输出及副作用：wqe_attachment、target_h、expected_wq_kind、expected_role
  //   为 selector 产生的只读输入；函数只返回 status，不复制或修改 attachment、
  //   runtime、ledger、cursor、Host-memory、MMIO 或外部生命周期所有权。
  // 失败/边界：target contract 为空或 kind/role 与 target resource kind 不相容时
  //   返回 INVALID_ARGUMENT；attachment/runtime/access 为空、depth=0、entry_size
  //   非 RDMA_WQE_BYTES、kind/role 不匹配时返回 INVALID_STATE；queue_h incarnation
  //   不一致或缺失时返回 STALE_GENERATION。该 helper 不 snapshot/release ledger，
  //   不信任 pending.completion_wq_kind，调用方必须由同一冻结 cqe/link 先生成
  //   expected 值并维持 authority-first 顺序。
  protected function rdma_status validate_cq_poll_wq_attachment(
    rdma_queue_data_attachment wqe_attachment,
    rdma_handle target_h,
    rdma_queue_runtime_kind_e expected_wq_kind,
    rdma_queue_backing_role_e expected_role
  );
    bit target_is_srq;
    bit role_matches_kind;

    target_is_srq = (expected_wq_kind == RDMA_QUEUE_RUNTIME_SRQ);
    role_matches_kind =
      (target_is_srq && expected_role == RDMA_QUEUE_ROLE_SRQ_RING) ||
      (!target_is_srq && expected_wq_kind == RDMA_QUEUE_RUNTIME_SQ &&
       expected_role == RDMA_QUEUE_ROLE_QP_SQ_RING) ||
      (!target_is_srq && expected_wq_kind == RDMA_QUEUE_RUNTIME_RQ &&
       expected_role == RDMA_QUEUE_ROLE_QP_RQ_RING);
    if (target_h == null ||
        !(expected_wq_kind inside {RDMA_QUEUE_RUNTIME_SQ,
                                   RDMA_QUEUE_RUNTIME_RQ,
                                   RDMA_QUEUE_RUNTIME_SRQ}) ||
        !role_matches_kind ||
        ((target_is_srq && target_h.kind != RDMA_RESOURCE_SRQ) ||
         (!target_is_srq && target_h.kind != RDMA_RESOURCE_QP)))
      return bad("CQ poll completion target contract is incomplete",
                 RDMA_SC_INVALID_ARGUMENT);
    if (wqe_attachment == null || wqe_attachment.runtime == null ||
        wqe_attachment.access == null || wqe_attachment.runtime.depth == 0 ||
        wqe_attachment.entry_size != RDMA_WQE_BYTES ||
        wqe_attachment.kind != expected_wq_kind ||
        wqe_attachment.role != expected_role)
      return bad("CQ poll completion target attachment is incomplete",
                 RDMA_SC_INVALID_STATE);
    if (!value_ops::same_handle_instance(wqe_attachment.queue_h, target_h))
      return bad("CQ poll completion target handle incarnation is stale",
                 RDMA_SC_STALE_GENERATION);
    return rdma_status::success();
  endfunction

  // 功能：resolve_cq_poll_wq_target 根据已解码 CQE 的 receive 标志和冻结的 QP
  //   link，选择本次 completion 对应的 SQ、私有 RQ 或共享 SRQ attachment，并
  //   委托共享 validator 校验后输出可供 release 阶段消费的只读路由结果。
  // 输入/输出及副作用：cqe、link 为已冻结的 CQE/route 输入；wqe_attachment 与
  //   expected_wq_kind 为输出的非拥有 attachment 引用和目标 runtime kind。函数只
  //   读取 engine attachment/binding authority 索引，不读取/推进 cursor，不创建
  //   pending，不修改 ledger、Host-memory、MMIO 或任何生命周期所有权。
  // 失败/边界：selector 输入缺失、attachment lookup 返回 null/失败、validator
  //   拒绝 runtime/access/depth/entry geometry/kind/role/handle incarnation 时
  //   fail-closed；目标 authority/geometry 门禁故意先于 release-range snapshot，
  //   因此 target 冲突与 snapshot 错误同时出现时仍以 target 错误为首错。该 helper
  //   不验证 CQ route/epoch，也不执行 simulator 兼容的二次 relookup。
  protected function rdma_status resolve_cq_poll_wq_target(
    rdma_hw_cqe_model cqe,
    rdma_queue_data_qp_link link,
    output rdma_queue_data_attachment wqe_attachment,
    output rdma_queue_runtime_kind_e expected_wq_kind
  );
    rdma_handle target_h;
    rdma_handle selector_target_h;
    rdma_queue_backing_role_e expected_role;
    rdma_status status;

    wqe_attachment = null;
    expected_wq_kind = RDMA_QUEUE_RUNTIME_SQ;
    target_h = null;
    selector_target_h = null;
    expected_role = RDMA_QUEUE_ROLE_QP_SQ_RING;

    status = select_cq_poll_wq_target_contract(
      cqe, link, selector_target_h, expected_wq_kind, expected_role);
    if (status == null || !status.ok())
      return status == null ?
        bad("CQ poll completion target selector returned null status",
            RDMA_SC_INVALID_STATE) : status;
    // 中文设计：冻结 link 才是 target authority；某些 simulator 可能在 function
    // 边界丢失 output class handle，或把错误 incarnation 复制到 output。先在当前
    // frame 用相同 kind/role 对 selector 候选做完整 identity 比较，失败时直接从
    // link 重建 canonical 引用，再进入 attachment lookup，避免把 output 当作第二
    // 条 authority，也避免合法 route 因 simulator 的引用传递差异被误拒。
    if (expected_wq_kind == RDMA_QUEUE_RUNTIME_SRQ) begin
      if (selector_target_h == null ||
          !value_ops::same_handle_instance(selector_target_h, link.srq_h))
        selector_target_h = link.srq_h;
    end
    else begin
      if (selector_target_h == null ||
          !value_ops::same_handle_instance(selector_target_h, link.qp_h))
        selector_target_h = link.qp_h;
    end
    target_h = selector_target_h;
    if (target_h == null)
      return bad("CQ poll completion target handle is unavailable",
                 RDMA_SC_INVALID_STATE);
    status = lookup_attachment(target_h, expected_wq_kind, wqe_attachment);
    if (status == null || !status.ok())
      return status == null ?
        bad("CQ poll completion target lookup returned null status",
            RDMA_SC_INVALID_STATE) : status;
    return validate_cq_poll_wq_attachment(
      wqe_attachment, target_h, expected_wq_kind, expected_role);
  endfunction

  // 功能：canonicalize_cq_poll_wq_attachment 将 poll staging 产生的 WQ 引用重新
  //   绑定到冻结 CQE/link 所决定的 canonical target，并在首次 runtime mutation
  //   之前完成 pending kind、attachment geometry、backing role 与完整 incarnation
  //   的统一校验；它把 selector、simulator output 修正和二次 registry lookup 收束
  //   成一个可复用的 admission 前阶段。
  // 输入/输出及副作用：cqe、link、pending 和 staged_wqe_attachment 是只读输入；
  //   canonical_wqe_attachment 是唯一输出的非拥有引用，target handle/kind/role
  //   contract 仅在函数内部存活。函数只读取 attachment registry 与 runtime 元数据，
  //   不推进 cursor，不建立 pending，不写 ledger、Host-memory、MMIO，也不取得外部
  //   queue/backing 生命周期所有权。
  // 失败/边界：输入缺失、selector 返回 null/失败、canonical target 不可用、pending
  //   kind 与冻结 target 不一致、staged attachment 不满足 validator，或二次 lookup/
  //   validator 失败时均 fail-closed；staged 引用校验失败只允许按相同 target 做一
  //   次 canonical lookup，lookup 失败不会保留旧引用。该 helper 不验证 CQ route/
  //   epoch，调用方必须先冻结 link 并在成功后才进入 enter_recovery_prepared()。
  protected function rdma_status canonicalize_cq_poll_wq_attachment(
    rdma_hw_cqe_model cqe,
    rdma_queue_data_qp_link link,
    rdma_queue_pending_operation pending,
    input rdma_queue_data_attachment staged_wqe_attachment,
    output rdma_queue_data_attachment canonical_wqe_attachment
  );
    rdma_handle selector_target_h;
    rdma_handle target_h;
    rdma_queue_runtime_kind_e expected_wq_kind;
    rdma_queue_backing_role_e expected_role;
    rdma_status status;
    rdma_status validation_status;

    canonical_wqe_attachment = null;
    target_h = null;
    expected_wq_kind = RDMA_QUEUE_RUNTIME_SQ;
    expected_role = RDMA_QUEUE_ROLE_QP_SQ_RING;
    selector_target_h = null;
    validation_status = null;

    status = select_cq_poll_wq_target_contract(
      cqe, link, selector_target_h, expected_wq_kind, expected_role);
    if (status == null || !status.ok()) begin
      if (status == null)
        return value_ops::make_status_nonfatal(
          RDMA_SC_INVALID_STATE,
          "CQ staged WQ target selector returned null status");
      return status;
    end

    // 中文设计：冻结 link 才是 target authority。selector 的 class-handle output
    // 只作候选；若 simulator 在 function 边界丢失引用或带出错误 incarnation，
    // 必须从同一 link 重建 canonical handle，再执行 attachment lookup，不能让
    // output 成为第二条可变 authority。
    if (expected_wq_kind == RDMA_QUEUE_RUNTIME_SRQ) begin
      if (selector_target_h == null ||
          !value_ops::same_handle_instance(selector_target_h, link.srq_h))
        selector_target_h = link.srq_h;
    end
    else begin
      if (selector_target_h == null ||
          !value_ops::same_handle_instance(selector_target_h, link.qp_h))
        selector_target_h = link.qp_h;
    end
    target_h = selector_target_h;
    if (target_h == null)
      return value_ops::make_status_nonfatal(
        RDMA_SC_INVALID_STATE,
        "CQ staged WQ canonical target handle is unavailable");

    if (pending == null || pending.completion_wq_kind != expected_wq_kind)
      return value_ops::make_status_nonfatal(
        RDMA_SC_INVALID_STATE,
        "CQ staged WQ completion kind disagrees with frozen target");

    validation_status = validate_cq_poll_wq_attachment(
      staged_wqe_attachment, target_h, expected_wq_kind, expected_role);
    if (validation_status != null && validation_status.ok()) begin
      canonical_wqe_attachment = staged_wqe_attachment;
      return validation_status;
    end

    // 中文设计：staging 结果可能只是 simulator 跨 function 边界失真的借用引用，
    // 因而仅在 validator 拒绝时按同一 frozen target 做一次 registry relookup；
    // relookup 后仍必须走同一 validator，禁止用 lookup 成功替代 geometry/role/
    // incarnation 校验。
    canonical_wqe_attachment = null;
    status = lookup_attachment(
      target_h, expected_wq_kind, canonical_wqe_attachment);
    if (status == null || !status.ok()) begin
      if (status == null)
        return value_ops::make_status_nonfatal(
          RDMA_SC_INVALID_STATE,
          "CQ staged WQ attachment recovery lookup returned null status");
      return status;
    end
    validation_status = validate_cq_poll_wq_attachment(
      canonical_wqe_attachment, target_h, expected_wq_kind, expected_role);
    if (validation_status == null || !validation_status.ok()) begin
      if (validation_status == null)
        return value_ops::make_status_nonfatal(
          RDMA_SC_INVALID_STATE,
          "CQ staged WQ attachment validator returned null status");
      return validation_status;
    end
    return validation_status;
  endfunction

  // 功能：commit_cq_consumer 为 CQ/CEQ/AEQ poll/recovery 提供唯一可覆写 CI
  //   commit seam；名称保留 CQ 兼容契约，可选 slot 选择零分配 recovery 原子提交。
  // 输入/输出及副作用：cq_attachment/cursor 与可选 prepared_status 为输入；有 slot
  //   时按 frozen cursor 推进 CI/used 并同步 pending marker，否则保持 legacy 委托。
  // 失败/边界：null 输入或 stale recovery 由 caller-owned slot 返回错误且零 mutation；
  //   未传 slot 的旧调用仍返回 runtime.commit_consumer 的独立状态。
  protected virtual function rdma_status commit_cq_consumer(
    rdma_queue_data_attachment cq_attachment,
    rdma_queue_cursor_snapshot cursor,
    rdma_status prepared_status = null
  );
    if (prepared_status != null) begin
      if (cq_attachment == null || cq_attachment.runtime == null ||
          cursor == null) begin
        void'(value_ops::set_status_noalloc(
          prepared_status, RDMA_SC_INVALID_ARGUMENT,
          "consumer commit input is incomplete"));
        return prepared_status;
      end
      void'(cq_attachment.runtime.commit_consumer_recovery_noalloc(
        cursor.index, cursor.wrap, prepared_status));
      return prepared_status;
    end
    return cq_attachment.runtime.commit_consumer(cursor);
  endfunction

  // 设计说明：三条 consumer 流程共享通知和本地提交机制，但不共享业务准入和幂等策略。
  //   本 task 只执行一次 prepared doorbell 并保存 evidence；caller 负责证明当前阶段需要
  //   MMIO。不能用它代替 CQ shadow，也不能让 SUCCESS/AMBIGUOUS replay 再发一次通知。
  // 功能：submit_consumer_doorbell_recorded 统一调用 consumer doorbell seam，拒绝 null
  //   status 或缺少 result/SUCCESS evidence 的假成功，并把本次结果写入既有 recovery。
  // 输入/输出及副作用：attachment/next/link/descriptor/noalloc_status 为已准入且非空的
  //   caller-owned continuation（event 的 link 可空）；diagnostic 仅选择固定文本；status
  //   原样保留真实错误或指向预建错误槽，completed 仅在成功通知证据保存后为 1。可能执行
  //   一次 MMIO 并更新 runtime pending；seam 返回后不分配对象、不拼接字符串，不推进 CI/WQE。
  // 失败/边界：caller 必须已校验 runtime、next、descriptor/status 并安装 pending；本层不
  //   重做 admission。null/不完整成功归一化 INVALID_STATE，证据保存失败升级 RECOVERY_REQUIRED；
  //   任一失败 completed=0，不重发、不继续 commit，也不改变原始 NO_SUBMIT/AMBIGUOUS 语义。
  protected task submit_consumer_doorbell_recorded(
    rdma_queue_data_attachment attachment,
    rdma_queue_cursor_snapshot next,
    rdma_queue_data_qp_link link,
    rdma_doorbell_desc descriptor,
    rdma_status noalloc_status,
    consumer_diagnostic_e diagnostic,
    output bit completed,
    output rdma_status status
  );
    rdma_doorbell_result db_result;
    rdma_queue_mmio_evidence_e evidence;

    completed = 1'b0;
    db_result = null;
    evidence = RDMA_QUEUE_MMIO_NO_SUBMIT;
    submit_consumer_doorbell(
      attachment, next, db_result, status, evidence, link, descriptor,
      noalloc_status);
    if (status == null) begin
      void'(value_ops::set_status_noalloc(
        noalloc_status, RDMA_SC_INVALID_STATE,
        diagnostic == CONSUMER_DIAG_CQ ? "CQ consumer doorbell returned null status" :
        diagnostic == CONSUMER_DIAG_EVENT ? "event consumer doorbell returned null status" :
        "consumer recovery doorbell returned null status"));
      status = noalloc_status;
    end
    else if (status.ok() &&
             (db_result == null || evidence != RDMA_QUEUE_MMIO_SUCCESS)) begin
      void'(value_ops::set_status_noalloc(
        noalloc_status, RDMA_SC_INVALID_STATE,
        diagnostic == CONSUMER_DIAG_CQ ?
          "CQ consumer doorbell returned incomplete success evidence" :
        diagnostic == CONSUMER_DIAG_EVENT ?
          "event consumer doorbell returned incomplete success evidence" :
        "consumer recovery doorbell returned incomplete success evidence"));
      status = noalloc_status;
    end
    if (!status.ok()) begin
      if (!attachment.runtime.record_recovery_failure_noalloc(
            evidence, status, noalloc_status)) begin
        void'(value_ops::set_status_noalloc(
          noalloc_status, RDMA_SC_RECOVERY_REQUIRED,
          diagnostic == CONSUMER_DIAG_CQ ? "CQ doorbell failure evidence could not be retained" :
          diagnostic == CONSUMER_DIAG_EVENT ?
            "event doorbell failure evidence could not be retained" :
          "consumer recovery doorbell failure could not be retained"));
        status = noalloc_status;
      end
      return;
    end
    if (!attachment.runtime.record_recovery_failure_noalloc(
          RDMA_QUEUE_MMIO_SUCCESS, null, noalloc_status)) begin
      void'(value_ops::set_status_noalloc(
        noalloc_status, RDMA_SC_RECOVERY_REQUIRED,
        diagnostic == CONSUMER_DIAG_CQ ? "CQ doorbell success evidence could not be retained" :
        diagnostic == CONSUMER_DIAG_EVENT ?
          "event doorbell success evidence could not be retained" :
        "consumer recovery doorbell success could not be retained"));
      status = noalloc_status;
      return;
    end
    completed = 1'b1;
  endtask

  // 功能：commit_consumer_cursor_recorded 打开 runtime recovery commit gate，调用唯一
  //   可覆写 CI seam，并在拒绝时保存当前通知方式对应的失败证据，供 live/replay 共用。
  // 输入/输出及副作用：attachment/cursor/noalloc_status 为 caller 已校验的 continuation，
  //   failure_evidence 由 caller 按 shadow/MMIO 选择，diagnostic 仅选固定文本；status 返回
  //   seam 状态或预建错误槽，返回 1 表示 CI 提交成功。可能推进 CI/used/pending marker，
  //   不分配对象、不执行 MMIO/shadow、WQE release 或 recovery completion。
  // 失败/边界：caller 保证 runtime/cursor/status 非空，replay 仅在尚未 committed 时调用；
  //   gate 拒绝返回 0 并保留其错误；null seam 归一化 INVALID_STATE；commit 失败保存原错误，
  //   证据保存失败升级 RECOVERY_REQUIRED。失败不自动补做、重试或回滚已发生的外部通知。
  protected function bit commit_consumer_cursor_recorded(
    rdma_queue_data_attachment attachment,
    rdma_queue_cursor_snapshot cursor,
    rdma_status noalloc_status,
    rdma_queue_mmio_evidence_e failure_evidence,
    consumer_diagnostic_e diagnostic,
    output rdma_status status
  );
    if (!attachment.runtime.enable_recovery_commit_noalloc(noalloc_status)) begin
      status = noalloc_status;
      return 1'b0;
    end
    status = commit_cq_consumer(attachment, cursor, noalloc_status);
    if (status == null) begin
      void'(value_ops::set_status_noalloc(
        noalloc_status, RDMA_SC_INVALID_STATE,
        diagnostic == CONSUMER_DIAG_CQ ? "CQ consumer commit returned null status" :
        diagnostic == CONSUMER_DIAG_EVENT ? "event consumer commit returned null status" :
        "consumer recovery commit returned null status"));
      status = noalloc_status;
    end
    if (!status.ok()) begin
      if (!attachment.runtime.record_recovery_failure_noalloc(
            failure_evidence, status, noalloc_status)) begin
        void'(value_ops::set_status_noalloc(
          noalloc_status, RDMA_SC_RECOVERY_REQUIRED,
          diagnostic == CONSUMER_DIAG_CQ ? "CQ consumer commit failure could not be retained" :
          diagnostic == CONSUMER_DIAG_EVENT ?
            "event consumer commit failure could not be retained" :
          "consumer recovery commit failure could not be retained"));
        status = noalloc_status;
      end
      return 1'b0;
    end
    return 1'b1;
  endfunction

  // 设计说明：CEQ 与 AEQ 在 decode、route 和 result 物化之后都必须先准备完整的
  //   consumer pending/doorbell evidence，才能进入 commit_event_poll_candidate 的
  //   首个 runtime mutation。两条入口的 prepared continuation 过去各自维护同一段
  //   顺序，容易让一侧新增的 null-status 或 noalloc 保护漏到另一侧；这里仅收束
  //   这段无副作用 staging，不把 event route、result delivery 或 recovery commit
  //   伪装成通用逻辑。
  // 功能：prepare_event_poll_continuation 为 CEQ/AEQ poll 构造 detached consumer
  //   pending、doorbell descriptor 和 post-scheduler noalloc status，供唯一的 event
  //   commit task 接管；它保持调用方已经冻结的 cursor、image 与 attachment。
  // 输入/输出及副作用：event_name、attachment、cursor、next、entry_offset 和
  //   entry_image 为只读输入；pending、prepared_db_desc、noalloc_status 先清空并由
  //   成功路径输出。函数只分配/复制 staging 对象并读取 runtime/registry，不调用
  //   scheduler、写 Host-memory/MMIO、推进 CI/used、建立 recovery 或取得资源所有权。
  // 失败/边界：attachment/cursor/next/image 输入不完整、prepare_consumer_pending
  //   返回 null/失败、doorbell descriptor 或 noalloc status 缺失时返回确定的
  //   non-fatal 错误；保留底层非成功 status 与原有阶段优先级，失败输出会清空，
  //   caller 不得进入
  //   enter_recovery_prepared。event_name 仅用于诊断，不改变 CEQ/AEQ route-miss 语义。
  protected function rdma_status prepare_event_poll_continuation(
    string event_name,
    rdma_queue_data_attachment attachment,
    rdma_queue_cursor_snapshot cursor,
    rdma_queue_cursor_snapshot next,
    longint unsigned entry_offset,
    rdma_hw_image entry_image,
    output rdma_queue_pending_operation pending,
    output rdma_doorbell_desc prepared_db_desc,
    output rdma_status noalloc_status
  );
    rdma_queue_data_qp_link no_route;
    rdma_status status;

    pending = null;
    prepared_db_desc = null;
    noalloc_status = null;
    no_route = null;

    status = prepare_consumer_pending(
      attachment, cursor, next, entry_offset, entry_image,
      0, 1'b0, 1'b0, RDMA_QUEUE_RUNTIME_SQ, null, pending);
    if (status == null || !status.ok() || pending == null) begin
      if (status == null || status.ok())
        status = value_ops::make_status_nonfatal(
          RDMA_SC_RESOURCE_EXHAUSTED,
          {event_name, " prepared pending is incomplete"});
      pending = null;
      return status;
    end

    status = prepare_consumer_doorbell(
      attachment, next, no_route, prepared_db_desc, noalloc_status);
    if (status == null || !status.ok() || prepared_db_desc == null ||
        noalloc_status == null) begin
      if (status == null || status.ok())
        status = value_ops::make_status_nonfatal(
          RDMA_SC_RESOURCE_EXHAUSTED,
          {event_name, " consumer doorbell preparation is incomplete"});
      pending = null;
      prepared_db_desc = null;
      noalloc_status = null;
      return status;
    end
    return status;
  endfunction

  // 设计说明：CEQ 与 AEQ 的 poll 入口各自负责 image 解码、route 解析和
  // detached event candidate 构造，但从 pending admission 开始共享同一条
  // consumer-only 副作用链。将这段链路集中到一个 task，能够让两种事件队列
  // 使用相同的 MMIO evidence、失败续接和 CI 提交顺序，同时明确它不拥有 CQ
  // completion target，也不会触碰 CQ→WQ release gate。
  // doorbell evidence 与 CI gate/commit 通过共用步骤执行；result 交付仍由本 event 流程决定。
  // 功能：commit_event_poll_candidate 接管已完成准备的 CEQ/AEQ candidate，进入
  // prepared recovery，提交 consumer doorbell，记录 MMIO evidence，推进事件队列
  // consumer cursor，并在 recovery 完成后按 route 命中与否发布 detached result。
  // 输入/输出及副作用：event_name、attachment、cursor、next、pending、prepared
  //   descriptor/status、result_candidate、final_success 与 deliver_found 为 caller
  //   冻结输入；result/status 为输出。task 可能写 doorbell、runtime pending、CI/used
  //   和 recovery evidence，但不取得 queue、backing、route handle 或 event model 的
  //   生命周期所有权；deliver_found=0 时只确认事件而丢弃 payload。
  // 失败/边界：输入缺失、admission、doorbell、MMIO evidence、consumer commit 或
  //   recovery completion 任一阶段失败时 result 保持 null；scheduler 返回 null 或
  //   不完整 success 会写入预建 noalloc slot。失败 evidence 保留后立即停止，不重发
  //   已提交 doorbell、不重复 CI，也不把 route miss 误报为 malformed；CEQ/AEQ caller
  //   必须在本 task 外完成各自的 decode/route/result preparation。
  protected task commit_event_poll_candidate(
    string event_name,
    rdma_queue_data_attachment attachment,
    rdma_queue_cursor_snapshot cursor,
    rdma_queue_cursor_snapshot next,
    rdma_queue_pending_operation pending,
    rdma_doorbell_desc prepared_db_desc,
    rdma_status prepared_noalloc_status,
    rdma_queue_event_result result_candidate,
    rdma_status final_success,
    bit deliver_found,
    output rdma_queue_event_result result,
    output rdma_status status
  );
    bit doorbell_completed;
    rdma_queue_data_qp_link no_route;
    rdma_status noalloc_status;

    result = null;
    status = null;
    no_route = null;
    noalloc_status = prepared_noalloc_status;

    if (attachment == null || attachment.runtime == null || cursor == null ||
        next == null || pending == null || pending.failure_status == null ||
        prepared_db_desc == null || noalloc_status == null ||
        final_success == null ||
        (deliver_found &&
         (result_candidate == null || result_candidate.event_model == null ||
          result_candidate.event_status == null))) begin
      status = value_ops::make_status_nonfatal(
        RDMA_SC_INVALID_STATE,
        {event_name, " poll commit candidate input is incomplete"});
      return;
    end

    // 中文设计：admission 是 CEQ/AEQ live poll 的第一个 runtime mutation；
    // 后续阶段只能沿同一 pending/failure_status continuation 前进，不能由
    // caller 在失败后重建 descriptor 或重复进入 recovery。
    status = attachment.runtime.enter_recovery_prepared(pending);
    if (status == null || !status.ok()) begin
      if (status == null)
        status = value_ops::make_status_nonfatal(
          RDMA_SC_INVALID_STATE,
          {event_name, " prepared pending admission returned null"});
      return;
    end

    submit_consumer_doorbell_recorded(
      attachment, next, no_route, prepared_db_desc, noalloc_status,
      CONSUMER_DIAG_EVENT, doorbell_completed, status);
    if (!doorbell_completed)
      return;
    if (!commit_consumer_cursor_recorded(
          attachment, cursor, noalloc_status, RDMA_QUEUE_MMIO_SUCCESS,
          CONSUMER_DIAG_EVENT, status))
      return;
    if (!attachment.runtime.complete_consumer_recovery_noalloc(
          1'b0, noalloc_status)) begin
      status = noalloc_status;
      return;
    end
    result = deliver_found ? result_candidate : null;
    status = final_success;
  endtask

  // 功能：release_cq_wqe 为 CQ poll/recovery 提供唯一可覆写 WQE release seam，
  //   默认按可选 caller slot 选择 noalloc release，或保持 legacy match_and_release。
  // 输入/输出及副作用：wqe_attachment/cqe、prepared_status 与仅供 cqe=null recovery
  //   使用的 frozen target 标量为输入；released 先清空，成功推进 routed WQ CI/used。
  // 失败/边界：noalloc 模式缺 attachment/target 时写入 slot 且零 mutation；有 cqe 时
  //   禁止 frozen 标量覆盖其 target，未传 slot 的旧调用保持原返回/队列语义。
  protected virtual function rdma_status release_cq_wqe(
    rdma_queue_data_attachment wqe_attachment,
    rdma_hw_cqe_model cqe,
    output rdma_queue_slot_ledger_entry released[$],
    input rdma_status prepared_status = null,
    input bit frozen_target_valid = 1'b0,
    input int unsigned frozen_target_index = 0,
    input bit frozen_target_wrap = 1'b0
  );
    int unsigned target_index;
    bit target_wrap;

    released.delete();
    if (prepared_status != null) begin
      if (wqe_attachment == null || wqe_attachment.runtime == null) begin
        void'(value_ops::set_status_noalloc(
          prepared_status, RDMA_SC_INVALID_ARGUMENT,
          "CQ WQE release attachment is incomplete"));
        return prepared_status;
      end
      if (cqe != null) begin
        target_index = cqe.wqe_index;
        target_wrap = cqe.wqe_wrap;
      end
      else if (frozen_target_valid) begin
        target_index = frozen_target_index;
        target_wrap = frozen_target_wrap;
      end
      else begin
        void'(value_ops::set_status_noalloc(
          prepared_status, RDMA_SC_INVALID_ARGUMENT,
          "CQ WQE release target is unavailable"));
        return prepared_status;
      end
      void'(wqe_attachment.runtime.match_and_release_noalloc(
        target_index, target_wrap, prepared_status));
      return prepared_status;
    end
    return wqe_attachment.runtime.match_and_release(
      cqe.wqe_index, cqe.wqe_wrap, released);
  endfunction

  // 功能：execute_consumer_wqe_release 统一 live CQ poll 与 consumer recovery 的
  //   CQ→WQ release 事务：取得 CQ release gate、按 CQE 或冻结坐标释放 routed WQ，
  //   完成 gate，并在失败时把 MMIO evidence/status 留回 CQ runtime。
  // 输入/输出及副作用：attachment、pending、wqe_attachment、cqe、冻结 target 和
  //   failure_evidence 为 caller 已冻结输入；context 只用于保持既有诊断前缀；status
  //   为输出。函数可能推进 WQ runtime ledger 或记录 recovery evidence，但不取得
  //   queue、handle、WQ attachment 或 Host-memory backing 的生命周期所有权。
  // 失败/边界：任一 runtime/attachment/pending/failure_status 缺失、begin gate 拒绝、
  //   release target 不完整、finish 失败或 release 失败证据无法保存时返回非 OK；
  //   recovery 模式必须提供 frozen_target_valid 和 pending completion 坐标，live
  //   模式必须提供非空 cqe；失败不会调用 complete_consumer_recovery。
  protected task execute_consumer_wqe_release(
    rdma_queue_data_attachment attachment,
    rdma_queue_pending_operation pending,
    rdma_queue_data_attachment wqe_attachment,
    rdma_hw_cqe_model cqe,
    input bit frozen_target_valid,
    input int unsigned frozen_target_index,
    input bit frozen_target_wrap,
    input rdma_queue_mmio_evidence_e failure_evidence,
    input string diagnostic_context,
    output rdma_status status
  );
    rdma_queue_slot_ledger_entry released[$];
    rdma_status noalloc_status;
    bit release_succeeded;

    status = null;
    if (attachment == null || pending == null || wqe_attachment == null ||
        attachment.runtime == null || wqe_attachment.runtime == null ||
        pending.failure_status == null ||
        (cqe == null && !frozen_target_valid) ||
        (cqe != null && frozen_target_valid)) begin
      status = value_ops::make_status_nonfatal(
        RDMA_SC_INVALID_STATE,
        {diagnostic_context, " consumer WQE release input is incomplete"});
      return;
    end
    if (frozen_target_valid &&
        (pending.completion_index != frozen_target_index ||
         pending.completion_wrap != frozen_target_wrap)) begin
      status = value_ops::make_status_nonfatal(
        RDMA_SC_INVALID_STATE,
        {diagnostic_context, " consumer WQE release target is inconsistent"});
      return;
    end

    noalloc_status = pending.failure_status;
    if (!attachment.runtime.begin_consumer_release_noalloc(noalloc_status)) begin
      status = noalloc_status;
      return;
    end
    released.delete();
    status = release_cq_wqe(
      wqe_attachment, cqe, released, noalloc_status,
      frozen_target_valid, frozen_target_index, frozen_target_wrap);
    if (status == null) begin
      void'(value_ops::set_status_noalloc(
        noalloc_status, RDMA_SC_INVALID_STATE,
        {diagnostic_context, " WQE release returned null status"}));
      status = noalloc_status;
    end
    release_succeeded = status.ok();
    if (!attachment.runtime.finish_consumer_release_noalloc(
          release_succeeded, status)) begin
      if (status == null || status.ok()) begin
        void'(value_ops::set_status_noalloc(
          noalloc_status, RDMA_SC_INVALID_STATE,
          {diagnostic_context, " release gate finalization failed"}));
        status = noalloc_status;
      end
      return;
    end
    if (!release_succeeded) begin
      if (!attachment.runtime.record_recovery_failure_noalloc(
            failure_evidence, status, noalloc_status)) begin
        void'(value_ops::set_status_noalloc(
          noalloc_status, RDMA_SC_RECOVERY_REQUIRED,
          {diagnostic_context, " WQE release failure could not be retained"}));
        status = noalloc_status;
      end
      return;
    end
    status = noalloc_status;
  endtask

  // 功能：stage_cq_poll_candidate 在 CQ poll 首次 runtime mutation 之前冻结
  //   routed WQ、release range、下一 CQ cursor、detached completion/pending，以及
  //   CQC shadow 或 legacy doorbell 的 caller-local payload；它把 poll 的复杂准备
  //   阶段集中在一个可审查的只读 seam，使 enter_recovery_prepared 成为后续首个
  //   改变 runtime pending 状态的边界。
  // 输入/输出及副作用：cq_h/cq_attachment/cursor/entry_offset/entry_image/cqe/link
  //   是本次消费的冻结输入；next、wqe_attachment、result_candidate、final_success、
  //   pending、cq_shadow_required、prepared_db_desc 和 noalloc_status 是输出。函数只
  //   通过 runtime 的 snapshot/query 接口读取 live authority，并创建由 caller 接管
  //   生命周期的 detached 对象；wqe_attachment 是非拥有借用输出，caller 必须按
  //   link/kind/完整 incarnation 再验证，不推进 CQ/WQ cursor、不写 ledger、不 admission
  //   pending，也不执行 MMIO。
  // 失败/边界：CQ/WQ/route/CQE 输入不完整、release snapshot、completion status、
  //   cursor/result/pending、shadow payload 或 doorbell descriptor 任一阶段返回 null/
  //   非成功时原样返回（null status 会被转换为对应的确定性 non-fatal 错误），所有
  //   输出保持安全空值；lookup 返回空 attachment 或空 snapshot 也 fail-closed；成功
  //   但 context_backing 缺失时只准备 legacy descriptor，CQ caller 的入口门禁仍会在
  //   更早阶段拒绝该情况。
  protected function rdma_status stage_cq_poll_candidate(
    rdma_handle cq_h,
    rdma_queue_data_attachment cq_attachment,
    rdma_queue_cursor_snapshot cursor,
    longint unsigned entry_offset,
    rdma_hw_image entry_image,
    rdma_hw_cqe_model cqe,
    rdma_queue_data_qp_link link,
    output rdma_queue_cursor_snapshot next,
    output rdma_queue_data_attachment wqe_attachment,
    output rdma_queue_completion_result result_candidate,
    output rdma_status final_success,
    output rdma_queue_pending_operation pending,
    output bit cq_shadow_required,
    output rdma_doorbell_desc prepared_db_desc,
    output rdma_status noalloc_status
  );
    rdma_queue_slot_ledger_entry release_snapshots[$];
    rdma_handle result_qp_h;
    rdma_status status;
    rdma_status completion_status;
    rdma_queue_runtime_kind_e expected_wq_kind;
    longint unsigned shadow_offset;
    int unsigned shadow_length;
    int unsigned shadow_value;
    byte unsigned shadow_payload[];

    next = null;
    result_candidate = null;
    final_success = null;
    pending = null;
    cq_shadow_required = 1'b0;
    prepared_db_desc = null;
    noalloc_status = null;
    release_snapshots.delete();
    result_qp_h = null;
    wqe_attachment = null;
    completion_status = null;
    shadow_offset = 0;
    shadow_length = 0;
    shadow_value = 0;
    shadow_payload = new[0];
    expected_wq_kind = RDMA_QUEUE_RUNTIME_SQ;

    if (cq_h == null || cq_attachment == null || cq_attachment.runtime == null ||
        cursor == null || entry_image == null || cqe == null || link == null ||
        link.qp_h == null)
      return value_ops::make_status_nonfatal(
        RDMA_SC_INVALID_ARGUMENT, "CQ poll candidate input is incomplete");

    // 设计说明：route handle 在所有 detached preparation 前冻结；WQ attachment
    // 只借用 engine registry 中的 live 引用，release_snapshots/result/pending 则
    // 由各自 helper 深复制，避免后续 admission 或 recovery 依赖可变 CQE 对象。
    result_qp_h = link.qp_h;
    status = resolve_cq_poll_wq_target(cqe, link, wqe_attachment,
                                       expected_wq_kind);
    if (status == null || !status.ok())
      return status == null ? value_ops::make_status_nonfatal(
        RDMA_SC_INVALID_STATE,
        "CQ completion target resolver returned null status") : status;

    status = wqe_attachment.runtime.snapshot_release_range(
      cqe.wqe_index, cqe.wqe_wrap, release_snapshots);
    if (status == null || !status.ok()) begin
      if (status == null)
        status = value_ops::make_status_nonfatal(
          RDMA_SC_INVALID_STATE, "CQ release snapshot returned null status");
      return status;
    end
    if (release_snapshots.size() == 0 ||
        release_snapshots[release_snapshots.size()-1] == null)
      return value_ops::make_status_nonfatal(
        RDMA_SC_INVALID_STATE, "CQ release snapshot is empty");
    status = completion_status_from_ecode(cqe.ecode,
      cqe.rq_cqe ? RDMA_ENGINE_RQ : RDMA_ENGINE_SQ, completion_status);
    if (status == null || !status.ok() || completion_status == null) begin
      if (status == null || status.ok())
        status = value_ops::make_status_nonfatal(
          RDMA_SC_RESOURCE_EXHAUSTED,
          "CQ completion status materialization failed");
      return status;
    end
    status = make_next_poll_cursor_nonfatal(
      cq_attachment.runtime, cursor, "next CQ", next);
    if (status == null || !status.ok()) return status;
    status = value_ops::prepare_cq_completion_candidate(
      cq_h, cqe, result_qp_h, completion_status, release_snapshots,
      result_candidate, final_success);
    if (status == null || !status.ok() || result_candidate == null ||
        final_success == null) begin
      if (status == null || status.ok())
        status = value_ops::make_status_nonfatal(
          RDMA_SC_RESOURCE_EXHAUSTED, "CQ completion candidate is incomplete");
      return status;
    end
    status = prepare_consumer_pending(
      cq_attachment, cursor, next, entry_offset, entry_image,
      cqe.wqe_index, cqe.wqe_wrap, 1'b1, wqe_attachment.kind,
      result_qp_h, pending);
    if (status == null || !status.ok() || pending == null) begin
      if (status == null || status.ok())
        status = value_ops::make_status_nonfatal(
          RDMA_SC_RESOURCE_EXHAUSTED, "CQ prepared pending is incomplete");
      return status;
    end
    pending.wr_id = result_candidate.cqe.wr_id;
    pending.signaled = release_snapshots[release_snapshots.size()-1].signaled;
    cq_shadow_required = (context_backing != null);
    if (cq_shadow_required) begin
      status = prepare_cqc_shadow_publication(
        cq_attachment, next, shadow_offset, shadow_length,
        shadow_value, shadow_payload, link, wqe_attachment,
        cqe.wqe_index, cqe.wqe_wrap, 1'b1, cqe.rq_cqe);
      if (status == null || !status.ok() ||
          shadow_payload.size() != shadow_length) begin
        if (status == null || status.ok())
          status = value_ops::make_status_nonfatal(
            RDMA_SC_RECOVERY_REQUIRED,
            "CQ CQC shadow preparation is incomplete");
        return status;
      end
      pending.consumer_shadow_required = 1'b1;
      pending.consumer_shadow_urc =
        (cq_attachment.transport == RDMA_TRANSPORT_URC);
      pending.consumer_shadow_offset = shadow_offset;
      pending.consumer_shadow_length = shadow_length;
      pending.consumer_shadow_value = shadow_value;
    end
    else begin
      status = prepare_consumer_doorbell(
        cq_attachment, next, link, prepared_db_desc, noalloc_status);
      if (status == null || !status.ok() || prepared_db_desc == null ||
          noalloc_status == null) begin
        if (status == null || status.ok())
          status = value_ops::make_status_nonfatal(
            RDMA_SC_RESOURCE_EXHAUSTED,
            "CQ consumer doorbell preparation is incomplete");
        return status;
      end
    end
    return status;
  endfunction

  // 设计说明：CQ poll 的 prepared candidate 一旦 admission，shadow/doorbell、CQ
  //   consumer commit 与 CQ→WQ release 必须成为一个单向、可恢复的副作用序列；把
  //   该阶段集中在独立 task 可让 caller 保持 read/decode/route/staging 的纯准备边界，
  //   也避免 recovery retry 重新解析可变 CQE 或 route。该 task 不与 frozen recovery
  //   的 release_consumer_pending_wqe 合并，因为这里仍拥有本次 live poll 的 CQE。
  //   doorbell evidence/CI commit 复用公共步骤；shadow 与 WQE release 的选择和顺序留在这里。
  // 功能：commit_cq_poll_candidate 接管已通过 staging 和 WQ identity relookup 的
  //   CQ candidate，先进入 prepared recovery，再按 shadow 或 doorbell 发布、开启并
  //   提交 CQ consumer，最后按 CQ→WQ 顺序释放 completion target 并完成 runtime recovery；
  //   全链成功时发布 detached completion result。
  // 输入/输出及副作用：cq_attachment/cursor/next/link/wqe_attachment/cqe/pending、
  //   result_candidate/final_success 与 publication 参数均为 caller 冻结输入；result
  //   与 status 为输出。task 可能写 context shadow、提交 consumer doorbell、推进 CQ
  //   cursor/credit、释放 routed WQ ledger，并更新 runtime pending/evidence，但不取得
  //   attachment、queue、backing 或 handle 的生命周期所有权。
  // 失败/边界：输入缺失、admission、doorbell、commit、CQ→WQ begin/release/finish
  //   或 complete 任一阶段失败时 result 保持 null；doorbell/commit/release 的具体
  //   错误写入预建 noalloc slot，shadow publication 若返回 null status 则原样交给
  //   外层 poll wrapper 归一化。已发生的 MMIO/commit 只通过 runtime recovery evidence
  //   保留，绝不重复提交、提前释放或在不确定 evidence 下伪造成功；target release
  //   失败会完成 bilateral finish 后停止，caller 不得在本 task 外补做阶段。
  protected task commit_cq_poll_candidate(
    rdma_queue_data_attachment cq_attachment,
    rdma_queue_cursor_snapshot cursor,
    rdma_queue_cursor_snapshot next,
    rdma_queue_data_qp_link link,
    rdma_queue_data_attachment wqe_attachment,
    rdma_hw_cqe_model cqe,
    rdma_queue_pending_operation pending,
    bit cq_shadow_required,
    rdma_doorbell_desc prepared_db_desc,
    rdma_status prepared_noalloc_status,
    rdma_queue_completion_result result_candidate,
    rdma_status final_success,
    output rdma_queue_completion_result result,
    output rdma_status status
  );
    bit doorbell_completed;
    rdma_status noalloc_status;

    result = null;
    status = null;
    noalloc_status = prepared_noalloc_status;

    if (cq_attachment == null || cq_attachment.runtime == null ||
        cursor == null || next == null || link == null || cqe == null ||
        wqe_attachment == null || wqe_attachment.runtime == null ||
        pending == null || pending.failure_status == null ||
        result_candidate == null || result_candidate.cqe == null ||
        result_candidate.completion_status == null || final_success == null ||
        (cq_shadow_required ? 1'b0 :
         (prepared_db_desc == null || noalloc_status == null))) begin
      status = value_ops::make_status_nonfatal(
        RDMA_SC_INVALID_STATE,
        "CQ poll commit candidate input is incomplete");
      return;
    end

    // 中文设计：admission 是 live poll 第一个 runtime mutation；之后的每个阶段
    // 都只能沿同一 pending/failure_status continuation 前进，不能回到 caller 重建。
    status = cq_attachment.runtime.enter_recovery_prepared(pending);
    if (status == null || !status.ok()) begin
      if (status == null)
        status = value_ops::make_status_nonfatal(
          RDMA_SC_INVALID_STATE, "CQ prepared pending admission returned null");
      return;
    end

    if (cq_shadow_required) begin
      publish_cqc_shadow(cq_attachment, pending, status);
      if (status == null || !status.ok())
        return;
      noalloc_status = pending.failure_status;
      if (noalloc_status == null) begin
        status = value_ops::make_status_nonfatal(
          RDMA_SC_RECOVERY_REQUIRED,
          "CQ shadow continuation status is unavailable");
        return;
      end
    end
    else begin
      submit_consumer_doorbell_recorded(
        cq_attachment, next, link, prepared_db_desc, noalloc_status,
        CONSUMER_DIAG_CQ, doorbell_completed, status);
      if (!doorbell_completed)
        return;
    end

    if (!commit_consumer_cursor_recorded(
          cq_attachment, cursor, noalloc_status,
          cq_shadow_required ? RDMA_QUEUE_MMIO_NO_SUBMIT : RDMA_QUEUE_MMIO_SUCCESS,
          CONSUMER_DIAG_CQ, status))
      return;

    // 中文设计：CQ runtime 持有 marker 后才允许进入 routed WQ；统一 helper
    // 覆盖 live poll 和 recovery retry 的 begin/release/finish 及失败证据，避免
    // 两条 caller 路径在跨 runtime 锁序或 gate 清理上再次分叉。
    execute_consumer_wqe_release(
      cq_attachment, pending, wqe_attachment, cqe, 1'b0, 0, 1'b0,
      cq_shadow_required ? RDMA_QUEUE_MMIO_NO_SUBMIT :
                           RDMA_QUEUE_MMIO_SUCCESS,
      "CQ", status);
    if (status == null || !status.ok()) begin
      if (status == null)
        status = noalloc_status;
      return;
    end
    if (!cq_attachment.runtime.complete_consumer_recovery_noalloc(
          1'b0, noalloc_status)) begin
      status = noalloc_status;
      return;
    end
    result = result_candidate;
    status = final_success;
  endtask

  // 设计说明：poll_cqe_once 负责 occupancy/read/decode/route、detached staging 和
  // admission 前的 WQ identity relookup；首次 runtime mutation 之后统一委托
  // commit_cq_poll_candidate，避免 caller 与 live-CQE recovery 顺序分叉。
  // 功能：poll_cqe_once 先冻结 CQ entry、route、WQE release range、最终 result 与
  //   prepared pending，再严格按 doorbell→CQ CI commit→WQE release 完成一次消费。
  // 输入/输出及副作用：cq_h 为输入，result/status 为输出；成功推进 CQ CI/used、
  //   释放 routed SQ/RQ/SRQ ledger 并发布预建 detached completion。
  // 失败/边界：read/decode/owner/route/snapshot/preallocation/admission 失败无副作用；
  //   doorbell 后失败保留单调 pending 阶段，绝不重复或提前 release，也不发布 result。
  protected task poll_cqe_once(
    rdma_handle cq_h,
    output rdma_queue_completion_result result,
    output rdma_status status
  );
    rdma_queue_data_attachment cq_attachment;
    rdma_queue_cursor_snapshot cursor;
    rdma_queue_cursor_snapshot next;
    rdma_queue_data_qp_link link;
    rdma_queue_data_attachment wqe_attachment;
    rdma_codec_key codec_key;
    rdma_codec_base codec;
    rdma_hw_image entry_image;
    rdma_hw_model decoded_model;
    rdma_hw_cqe_model cqe;
    rdma_cqe_variant_e cqe_variant;
    rdma_queue_pending_operation pending;
    rdma_doorbell_desc prepared_db_desc;
    rdma_status noalloc_status;
    rdma_status final_success;
    rdma_queue_completion_result result_candidate;
    rdma_queue_data_attachment canonical_wqe_attachment;
    int unsigned cq_occupancy;
    bit cq_shadow_required;
    int unsigned owner_byte_offset;
    byte data[];
    longint unsigned offset;
    string route_key;

    result = null;
    status = null;
    canonical_wqe_attachment = null;
    status = lookup_attachment(cq_h, RDMA_QUEUE_RUNTIME_CQ, cq_attachment);
    if (!status.ok()) return;
    // 0.1.34 的 xtrdma_normal_poll_cq 在每次成功消费后都调用
    // xtrdma_kernel_update_cq_shadow_ci()，通过 CQC shadow offset +4 的 32-bit
    // host-memory 写发布 CI/wrap；驱动没有对应的 CQ consumer MMIO 提交路径。
    // 因此 context backing 是 CQ poll 的硬性 authority。必须在 occupancy/read/
    // pending/admission 之前拒绝 null，保证 legacy adapter 不会伪造成功，也不
    // 会读槽、推进 cursor、建立 recovery evidence 或产生任何 PCIe 写入。
    if (context_backing == null) begin
      status = rdma_status::make(
        RDMA_SC_UNSUPPORTED_OPCODE,
        "CQ poll requires CQC context shadow backing");
      return;
    end
    // Check committed occupancy before decoding the slot.  An empty CQ may
    // contain an all-zero image whose polarity happens to match the initial
    // owner bit; route lookup must never turn that normal QUEUE_EMPTY case into
    // an INVALID_STATE error about a missing QP.
    status = cq_attachment.runtime.query_occupancy(cq_occupancy);
    if (status == null || !status.ok())
      return;
    if (cq_occupancy == 0) begin
      status = rdma_status::make(
        RDMA_SC_QUEUE_EMPTY, "CQ has no committed entries");
      return;
    end
    status = cq_attachment.runtime.peek_consumer(cursor);
    if (!status.ok()) return;
    offset = longint'(cursor.index) * cq_attachment.entry_size;
    status = cq_attachment.access.read(offset, cq_attachment.entry_size, data);
    if (!status.ok()) return;
    status = make_entry_image(data, RDMA_IMAGE_CQE,
                              cq_attachment.entry_size, entry_image);
    if (!status.ok()) return;
    status = resolve_cqe_header_offset_for_image(
      entry_image, owner_byte_offset);
    if (status == null || !status.ok())
      return;
    // The owner bit is common to every CQE header variant, but a 128-byte CQE
    // reserves the first 64 bytes for the opaque prefix.  The driver and the
    // codec therefore place the header at byte 64 for that profile; reading
    // byte zero would turn every valid 128-byte entry into QUEUE_EMPTY.
    if (entry_image.bytes.size() <= owner_byte_offset ||
        entry_image.bytes[owner_byte_offset][7] !=
          cq_attachment.runtime.expected_owner_polarity()) begin
      status = rdma_status::make(
        RDMA_SC_QUEUE_EMPTY,
        "CQE owner polarity does not match CQ consumer cursor");
      return;
    end
    status = resolve_cqe_variant_for_image(cq_h, entry_image,
                                           owner_byte_offset,
                                           cqe_variant, link);
    if (status == null || !status.ok())
      return;
    codec_key = '{hw_version:"rdma", image_kind:RDMA_IMAGE_CQE,
      object_type:"cqe", variant:"default", opcode:8'h00};
    status = lookup_codec_checked(codec_key, "CQE poll", codec);
    if (status == null || !status.ok()) begin
      if (status == null)
        status = bad("CQE codec lookup normalization failed",
                     RDMA_SC_CODEC_ERROR);
      return;
    end
    begin
      rdma_hw_cqe_codec variable_cqe_codec;
      if (!$cast(variable_cqe_codec, codec)) begin
        status = bad("CQ registry codec cannot select a variable profile",
                     RDMA_SC_CODEC_ERROR);
        return;
      end
      // 设计说明：entry size 属于本次 attachment/read，必须显式传给 decode，不能
      // 修改 registry 共享 codec 的 active profile 而污染其他并发 transaction。
      // 设计说明：CQE qword2/qword3 是物理 union，variant 必须由已冻结的
      // CQ→QP route 和 qword0 公共标志共同决定；不得通过 registry codec 的
      // active_variant 共享状态在交错 poll 间隐式切换。
      status = variable_cqe_codec.decode_with_entry_bytes_variant(
        entry_image, cq_attachment.entry_size, cqe_variant, decoded_model);
    end
    if (status == null) begin
      status = bad("CQE decode returned null status", RDMA_SC_CODEC_ERROR);
      return;
    end
    if (!status.ok()) return;
    if (!$cast(cqe, decoded_model) || cqe == null)
      begin status = bad("CQE codec returned the wrong model type", RDMA_SC_CODEC_ERROR); return; end
    if (cqe.polarity != cq_attachment.runtime.expected_owner_polarity()) begin
      status = rdma_status::make(RDMA_SC_QUEUE_EMPTY,
                                 "CQE owner polarity does not match CI");
      return;
    end
    status = find_qp_link_for_cq(cq_h, cqe.qpn, cqe.rq_cqe, link);
    if (!status.ok()) return;
    // 设计说明：部分 simulator 会在 function 边界丢失由 associative array 遍历
    // 赋给 output 的 class handle。这里在 transaction 现场按相同 identity 与
    // send/receive-CQ predicate 防御性重查；两侧 CQ handle 通过 null 门禁后的
    // same_handle_instance 比较确认，不能放宽 route 条件。
    if (link == null) begin
      foreach (qp_links[route_key]) begin
        if (qp_links[route_key] == null ||
            qp_links[route_key].local_qp_id != cqe.qpn)
          continue;
        if (value_ops::qp_link_cq_route_matches(qp_links[route_key], cq_h,
                                     cqe.rq_cqe)) begin
          link = qp_links[route_key];
          break;
        end
      end
    end
    if (link == null) begin
      status = bad("CQE route has no QP link", RDMA_SC_INVALID_STATE);
      return;
    end
    // 设计说明：route handle 已在 decode/relookup 后冻结并作为 staging 输入；
    // candidate function 返回的 live WQ 引用若被 simulator 丢失，caller 只在此处
    // 按同一 link/kind 重新查询，避免跨边界的 class-handle aliasing 变成错误提交。
    status = stage_cq_poll_candidate(
      cq_h, cq_attachment, cursor, offset, entry_image, cqe, link,
      next, wqe_attachment, result_candidate, final_success, pending,
      cq_shadow_required, prepared_db_desc, noalloc_status);
    if (status == null || !status.ok()) return;
    if (next == null || result_candidate == null ||
        result_candidate.cqe == null ||
        result_candidate.completion_status == null || final_success == null ||
        pending == null) begin
      status = value_ops::make_status_nonfatal(
        RDMA_SC_RESOURCE_EXHAUSTED,
        "CQ staged candidate output is incomplete");
      return;
    end
    if (cq_shadow_required != (context_backing != null) ||
        (cq_shadow_required && !pending.consumer_shadow_required) ||
        (!cq_shadow_required &&
         (prepared_db_desc == null || noalloc_status == null))) begin
      status = value_ops::make_status_nonfatal(
        RDMA_SC_RECOVERY_REQUIRED,
        "CQ staged consumer publication output is incomplete");
      return;
    end
    // 中文设计：staged output 的 target 必须重新由冻结 cqe/link 推导，不能把
    // 可变 pending.completion_wq_kind 当作 authority；helper 在首次
    // enter_recovery_prepared() 之前完成 selector、kind 检查、二次 relookup 和
    // validator，故 malformed attachment 不会建立 pending 或产生副作用。
    status = canonicalize_cq_poll_wq_attachment(
      cqe, link, pending, wqe_attachment, canonical_wqe_attachment);
    if (status == null || !status.ok()) begin
      if (status == null)
        status = value_ops::make_status_nonfatal(
          RDMA_SC_INVALID_STATE,
          "CQ staged WQ canonicalization returned null status");
      return;
    end
    wqe_attachment = canonical_wqe_attachment;

    commit_cq_poll_candidate(
      cq_attachment, cursor, next, link, wqe_attachment, cqe, pending,
      cq_shadow_required, prepared_db_desc, noalloc_status, result_candidate,
      final_success, result, status);
    return;
  endtask

  // 功能：poll_cqe 以 cq_h 轮询一条 CQE；每次调用 poll_cqe_once 完成 prepared
  //   admission 与 doorbell→CI commit→WQE release，只有全链成功才发布 completion。
  // 输入/输出及副作用：timeout=0 时只尝试一次，非零时按 1ns 间隔重试
  //   QUEUE_EMPTY 至 deadline；result/status 为输出。成功推进 CQ CI/used 并释放目标
  //   SQ/RQ/SRQ ledger，result 是不拥有 queue/QP/backing 的 detached 快照。
  // 失败/边界：deadline 溢出、内部返回 null status、超时或非 QUEUE_EMPTY 错误
  //   立即返回；阶段失败保持 poll_cqe_once 留下的 recovery evidence，result 保持 null，
  //   不在 wrapper 中自动重发不确定 doorbell 或补做本地阶段。
  task poll_cqe(
    rdma_handle cq_h, time timeout,
    output rdma_queue_completion_result result,
    output rdma_status status
  );
    time deadline;
    rdma_queue_completion_result candidate;
    rdma_status attempt;
    result = null;
    status = null;
    if (timeout != 0) begin
      deadline = $time + timeout;
      if (deadline < $time) begin
        status = bad("CQ poll deadline overflows simulation time");
        return;
      end
    end
    do begin
      candidate = null;
      attempt = null;
      poll_cqe_once(cq_h, candidate, attempt);
      if (attempt == null) begin
        status = bad("CQ poll returned null status", RDMA_SC_INVALID_STATE);
        return;
      end
      if (attempt.code != RDMA_SC_QUEUE_EMPTY || timeout == 0) begin
        status = attempt;
        if (attempt.ok()) result = candidate;
        return;
      end
      if ($time >= deadline) begin
        status = rdma_status::make(RDMA_SC_TIMEOUT,
                                   "CQ poll deadline expired");
        return;
      end
      #1ns;
    end while (1);
  endtask

  // 功能：finish_resize 统一释放 engine 级 resize semaphore 并返回事务结果，确保所有退出分支都不会遗留锁。
  // 输入/输出及副作用：status 为输入；finish_resize 释放本对象持有的 resize_lock token，不修改 CQ authority。
  // 失败/边界：status 为空时仍返回 INVALID_STATE；未持有 lock 的调用方不得调用本函数，否则会破坏并发屏障。
  protected function rdma_status finish_resize(rdma_status status);
    if (status == null)
      status = bad("CQ resize returned null status", RDMA_SC_INVALID_STATE);
    if (resize_lock != null)
      resize_lock.put(1);
    return status;
  endfunction

  // 功能：quiesce_cq_dependents 找出引用 CQ 的 QP/SRQ runtime，并在 resize 前逐一切到 QUIESCING，阻止依赖队列产生新事务。
  // 输入/输出及副作用：cq_h 为输入；runtimes 为输出；成功时更新相关 runtime 状态并返回其快照列表。
  // 失败/边界：关联 runtime 非 ACTIVE、存在 pending/used、句柄拓扑不完整或任一
  // begin_quiesce 失败时回滚已切换 runtime 并返回错误；send/recv CQ route 在
  // cq_h/link null 门禁后由 qp_link_cq_route_matches 按方向确认完整 identity，
  // SRQ 拓扑、attachment 缺失与状态迁移仍由本函数保留。
  protected function rdma_status quiesce_cq_dependents(
    rdma_handle cq_h,
    output rdma_queue_runtime runtimes[$]
  );
    rdma_queue_data_qp_link link;
    rdma_queue_data_attachment attachment;
    rdma_status status;
    string link_key;
    string attachment_key_value;
    rdma_queue_runtime candidate_runtime;
    rdma_queue_runtime_kind_e kinds[$];
    bit already_seen;

    runtimes.delete();
    if (cq_h == null)
      return bad("CQ dependent quiesce handle is null");
    kinds.push_back(RDMA_QUEUE_RUNTIME_SQ);
    kinds.push_back(RDMA_QUEUE_RUNTIME_RQ);
    kinds.push_back(RDMA_QUEUE_RUNTIME_SRQ);
    foreach (qp_links[link_key]) begin
      link = qp_links[link_key];
      if (link == null)
        continue;
      if (!value_ops::qp_link_cq_route_matches(link, cq_h, 1'b0) &&
          !value_ops::qp_link_cq_route_matches(link, cq_h, 1'b1))
        continue;
      foreach (kinds[i]) begin
        attachment_key_value = value_ops::attachment_key(
          kinds[i] == RDMA_QUEUE_RUNTIME_SRQ ? link.srq_h : link.qp_h,
          kinds[i]);
        if (attachment_key_value == "" ||
            !attachments.exists(attachment_key_value))
          continue;
        attachment = attachments[attachment_key_value];
        if (attachment == null || attachment.runtime == null)
          return bad("CQ dependent attachment is incomplete",
                     RDMA_SC_INVALID_STATE);
        candidate_runtime = attachment.runtime;
        // 设计说明：同一 shared SRQ 可经多个 QP link 到达；一次 resize transaction
        // 对每个 runtime 只允许执行一次状态迁移，避免重复 quiesce。
        already_seen = 1'b0;
        foreach (runtimes[j])
          if (runtimes[j] === candidate_runtime) already_seen = 1'b1;
        if (already_seen)
          continue;
        status = candidate_runtime.begin_quiesce();
        if (status == null || !status.ok()) begin
          // 设计说明：保留已经成功 quiesce 的完整 runtime 列表；若暂态 backend/lock
          // 故障阻止立即 rollback，abort_cq_resize 必须依赖该精确列表重试 restore_active。
          if (status == null)
            status = bad("CQ dependent begin quiesce returned null",
                         RDMA_SC_RECOVERY_REQUIRED);
          foreach (runtimes[j]) begin
            rdma_status restore_status;
            restore_status = runtimes[j].restore_active();
            if (restore_status == null || !restore_status.ok())
              status = rdma_status::make(
                RDMA_SC_RECOVERY_REQUIRED,
                {"CQ dependent begin failed: ", status.message,
                 "; rollback restore failed: ",
                 restore_status == null ? "null status" :
                 restore_status.message});
          end
          return status;
        end
        runtimes.push_back(candidate_runtime);
      end
    end
    return rdma_status::success();
  endfunction

  // 功能：restore_cq_dependents 把 resize 事务中暂时 QUIESCING 的依赖 runtime 恢复为 ACTIVE。
  // 输入/输出及副作用：runtimes 为输入；成功时更新每个 runtime.state，不触碰 manager registry。
  // 失败/边界：任一 runtime 恢复失败时返回该错误；调用方必须保留诊断并进入恢复路径。
  protected function rdma_status restore_cq_dependents(
    rdma_queue_runtime runtimes[$]
  );
    rdma_status status;
    foreach (runtimes[i]) begin
      if (runtimes[i] == null)
        continue;
      // 依赖恢复可能已经在上一轮完成一部分；ACTIVE runtime 直接跳过，
      // 让失败路径可以重复调用而不会把幂等恢复误报成错误。
      if (runtimes[i].state == RDMA_QUEUE_RUNTIME_ACTIVE)
        continue;
      if (runtimes[i].state != RDMA_QUEUE_RUNTIME_QUIESCING)
        return bad("CQ dependent runtime has unexpected state",
                   RDMA_SC_RECOVERY_REQUIRED);
      status = runtimes[i].restore_active();
      if (status == null)
        return bad("CQ dependent runtime restore returned null",
                   RDMA_SC_RECOVERY_REQUIRED);
      if (!status.ok()) return status;
    end
    return rdma_status::success();
  endfunction

  // 功能：abort_cq_resize 撤销尚未发布的 CQ resize 阶段，按“新 backing cleanup、
  //   runtime restore、manager restore”顺序恢复旧 authority。
  // 输入/输出及副作用：cq_h/old_runtime/dependents/new_ref/manager_quiesced/
  //   cq_quiesced/original_status 为输入；函数可能释放候选 mapping、恢复 runtime
  //   和 manager 状态。
  // 失败/边界：任一回滚动作失败时返回 RECOVERY_REQUIRED 或底层错误，并把原始
  //   失败消息附加到结果；已提交的新 authority 不应调用本函数。
  protected function rdma_status abort_cq_resize(
    rdma_handle cq_h,
    rdma_queue_runtime old_runtime,
    rdma_queue_runtime dependents[$],
    rdma_queue_backing_ref new_ref,
    bit manager_quiesced,
    bit cq_quiesced,
    rdma_status original_status
  );
    rdma_status rollback_status;
    rdma_status first_failure;
    rdma_status recovery_status;
    bit complete;
    bit manager_restore_pending;
    bit cq_restore_pending;

    first_failure = null;
    manager_restore_pending = manager_quiesced;
    cq_restore_pending = cq_quiesced;
    if (new_ref != null) begin
      rollback_status = backing_planner.cleanup_local_role(new_ref,
                                                            complete);
      if (rollback_status == null || !rollback_status.ok() || !complete) begin
        if (rollback_status == null)
          rollback_status = bad("CQ resize candidate cleanup returned null",
                                RDMA_SC_RECOVERY_REQUIRED);
        first_failure = rollback_status;
        // 候选 authority 尚未发布，不能复用 published recovery 记录；仍要
        // 把它登记为 pending_ref，保证本次回滚失败后有唯一重试入口。
        recovery_status = record_candidate_cleanup_recovery(
          cq_h, new_ref, rollback_status);
        if (recovery_status == null || !recovery_status.ok()) begin
          if (recovery_status == null)
            recovery_status = bad(
              "CQ candidate cleanup recovery registration returned null",
              RDMA_SC_RECOVERY_REQUIRED);
          first_failure = rdma_status::make(
            RDMA_SC_RECOVERY_REQUIRED,
            {"CQ candidate cleanup recovery registration failed: ",
             recovery_status.message, "; cleanup failure: ",
             rollback_status.message});
        end
      end
    end
    if (cq_quiesced && old_runtime != null) begin
      rollback_status = old_runtime.restore_active();
      if (rollback_status == null || !rollback_status.ok()) begin
        if (rollback_status == null)
          rollback_status = bad("CQ resize runtime restore returned null",
                                RDMA_SC_RECOVERY_REQUIRED);
        if (first_failure == null) first_failure = rollback_status;
      end
      else
        cq_restore_pending = 1'b0;
    end
    rollback_status = restore_cq_dependents(dependents);
    if (rollback_status == null || !rollback_status.ok()) begin
      if (rollback_status == null)
        rollback_status = bad("CQ resize dependent restore returned null",
                              RDMA_SC_RECOVERY_REQUIRED);
      if (first_failure == null) first_failure = rollback_status;
    end
    if (manager_quiesced) begin
      rollback_status = manager.restore_active(cq_h);
      if (rollback_status == null || !rollback_status.ok()) begin
        if (rollback_status == null)
          rollback_status = bad("CQ resize manager restore returned null",
                                RDMA_SC_RECOVERY_REQUIRED);
        if (first_failure == null) first_failure = rollback_status;
      end
      else
        manager_restore_pending = 1'b0;
    end
    if (first_failure != null) begin
      // 设计说明：rollback 失败时必须保留每个仍处于 QUIESCING 的 runtime；否则后续
      // retry 只能看到旧 CQ handle，无法安全恢复已从列表丢失的 dependent。
      recovery_status = record_prepublish_recovery(
        cq_h, old_runtime, dependents, manager_restore_pending,
        cq_restore_pending, first_failure);
      if (recovery_status == null || !recovery_status.ok()) begin
        if (recovery_status == null)
          recovery_status = bad(
            "CQ pre-publish recovery registration returned null",
            RDMA_SC_RECOVERY_REQUIRED);
        first_failure = rdma_status::make(
          RDMA_SC_RECOVERY_REQUIRED,
          {"CQ pre-publish recovery registration failed: ",
           recovery_status.message, "; rollback failure: ",
           first_failure.message});
      end
      return rdma_status::make(RDMA_SC_RECOVERY_REQUIRED,
        {"CQ resize rollback failed: ", first_failure.message,
         "; original failure: ", original_status == null ? "" :
         original_status.message});
    end
    return original_status == null ?
      bad("CQ resize rollback has no original status",
          RDMA_SC_RECOVERY_REQUIRED) : original_status;
  endfunction

  // 功能：调整已附着 CQ 的 runtime ring，先确认 quiesce 条件，再分配新
  //       backing/runtime、复制 owner/CI 游标并原子替换 attachment；发布后
  //       若旧 runtime 或 backing 清理失败，登记可重试的 recovery record。
  // 输入/输出及副作用：cq_h/new_depth/new_cqe_bytes 为输入；成功时更新 CQ attachment 的 runtime 与 entry geometry。
  //   resize_transaction 单次循环内的发布前失败跳至同一 abort 出口；发布成功后直接
  //   finish_resize，回滚和正常/恢复返回均恰好释放一次 resize_lock。
  // 失败/边界：未配置、CQ 不存在、存在 pending 操作、深度/size 非法或候选
  //       runtime 激活失败时保留旧 ring；发布后的清理故障返回
  //       RDMA_SC_RECOVERY_REQUIRED 并保留新 attachment 与旧 authority。
  function rdma_status resize_cq(rdma_handle cq_h, int unsigned new_depth,
                                 int unsigned new_cqe_bytes);
    rdma_queue_data_attachment old_attachment;
    rdma_queue_data_attachment replacement;
    rdma_queue_runtime candidate_runtime;
    rdma_queue_backing_access candidate_access;
    rdma_queue_ring_layout candidate_ring;
    rdma_queue_backing_ref candidate_ref;
    rdma_queue_backing_ref old_ref;
    rdma_cq authoritative_cq;
    rdma_cq candidate_cq;
    rdma_resource authoritative_resource;
    rdma_queue_backing_plan candidate_plan;
    rdma_status status;
    rdma_queue_runtime dependents[$];
    rdma_cq_resize_recovery recovery;
    rdma_handle runtime_queue_h;
    rdma_handle replacement_ceq_h;
    rdma_queue_runtime_kind_e runtime_kind;
    string key;
    string recovery_key;
    bit runtime_host_produced;
    bit runtime_initial_polarity;
    bit manager_quiesced;
    bit cq_quiesced;
    bit cleanup_complete;

    // 设计：geometry 校验不产生副作用，因此先于信号量获取执行；其余
    // 所有会改变状态的步骤均由 resize_lock 串行化，避免并发调用观察到半事务。
    if (!(new_cqe_bytes inside {32,64,128}) || new_depth == 0 ||
        (new_depth & (new_depth-1)) != 0)
      return bad("CQ resize geometry is invalid");
    if (!configured)
      return bad("queue data engine is not configured", RDMA_SC_INVALID_STATE);
    if (resize_lock == null || !resize_lock.try_get(1))
      return bad("CQ resize is busy", RDMA_SC_RESOURCE_BUSY);

    status = lookup_attachment(cq_h, RDMA_QUEUE_RUNTIME_CQ, old_attachment);
    if (!status.ok()) return finish_resize(status);
    key = value_ops::attachment_key(cq_h, RDMA_QUEUE_RUNTIME_CQ);
    recovery_key = value_ops::cq_recovery_key(cq_h);
    if (key == "" || recovery_key == "" ||
        cq_resize_recoveries.exists(recovery_key))
      return finish_resize(bad("CQ resize has pending cleanup recovery",
                               RDMA_SC_RECOVERY_REQUIRED));
    if (old_attachment.runtime == null || old_attachment.access == null)
      return finish_resize(bad("CQ attachment runtime/access is missing",
                               RDMA_SC_INVALID_STATE));

    // 驱动 xtrdma_ib_resize_cq 仅接受扩大用户可见深度；URC CQ 明确不支持
    // resize，且 CQC_RESIZE 没有 CQE width 字段。先在任何 quiesce、分配或
    // manager mutation 之前拒绝这些 ABI 不可表达的请求，保证旧 authority 不变。
    if (old_attachment.transport == RDMA_TRANSPORT_URC)
      return finish_resize(bad("URC CQ resize is unsupported",
                               RDMA_SC_UNSUPPORTED_OPCODE));
    if (new_cqe_bytes != old_attachment.entry_size)
      return finish_resize(bad("CQE width cannot change during resize"));
    if (new_depth == old_attachment.runtime.depth)
      return finish_resize(rdma_status::success());
    if (new_depth < old_attachment.runtime.depth)
      return finish_resize(bad("CQ depth reduction is unsupported"));

    status = old_attachment.runtime.query_attachment_config(
      runtime_queue_h, runtime_kind, runtime_host_produced,
      runtime_initial_polarity);
    // 设计：query_attachment_config 返回的 runtime_queue_h 是旧 runtime 的
    // authority；status 与两个 handle 的空值门禁必须先于 identity helper。
    // attachment_matches_queue_identity 只复用 canonical 完整 incarnation 比较，
    // runtime kind/producer direction 仍由本 caller 审计；若旧 authority 不匹配，
    // 仍通过 finish_resize 释放 resize_lock 并返回原错误。
    if (status == null || !status.ok() || runtime_queue_h == null ||
        old_attachment.queue_h == null ||
        !value_ops::attachment_matches_queue_identity(old_attachment, runtime_queue_h) ||
        runtime_kind != RDMA_QUEUE_RUNTIME_CQ || runtime_host_produced) begin
      if (status == null || status.ok())
        status = bad("CQ runtime attachment config is inconsistent",
                     RDMA_SC_INVALID_STATE);
      return finish_resize(status);
    end
    status = manager.begin_cq_resize(cq_h);
    if (!status.ok()) return finish_resize(status);
    manager_quiesced = 1'b1;
    // 设计：单次循环保留原有阶段与字段读取时机；发布前 break 只退出当前调用，
    // 到唯一回滚出口按当前进度撤销候选，不额外分配或冻结 status。不能改用命名块
    // disable：factory 可嵌套调用另一 engine，VCS 会同时退出外层同名块。
    // manager swap 后所有路径直接 finish_resize，保留新 authority，不落入回滚。
    do begin : resize_transaction
      status = old_attachment.runtime.begin_quiesce();
      if (!status.ok()) begin
        break;
      end
      cq_quiesced = 1'b1;
      status = quiesce_cq_dependents(cq_h, dependents);
      if (!status.ok()) begin
        break;
      end

      // 设计：manager 屏障建立后再读取 QUIESCING authority；该 detached CQ
      // 快照提供 ring 替换必须保留的 PD/CEQ/context 不可变依赖拓扑。
      status = manager.lookup(cq_h, authoritative_resource);
      if (!status.ok() || !$cast(authoritative_cq, authoritative_resource) ||
          authoritative_cq == null || authoritative_cq.queue_plan == null) begin
        if (status.ok()) status = bad("CQ resize authority lookup failed",
                                     RDMA_SC_INVALID_STATE);
        break;
      end
      if (old_attachment.runtime.consumer_index >= new_depth ||
          old_attachment.runtime.producer_index >= new_depth) begin
        status = bad("CQ resize cannot preserve cursor state");
        break;
      end

      status = backing_planner.allocate_owned_cq_resize_ring(
        binding, cq_h, new_depth, new_cqe_bytes, candidate_ring, candidate_ref,
        runtime_initial_polarity);
      if (!status.ok()) begin
        break;
      end

      candidate_runtime = rdma_queue_runtime::type_id::create("cq_resize_runtime");
      if (candidate_runtime == null) begin
        status = bad("CQ resize runtime allocation failed",
                     RDMA_SC_RESOURCE_EXHAUSTED);
        break;
      end
      status = candidate_runtime.configure(old_attachment.queue_h,
        RDMA_QUEUE_RUNTIME_CQ, new_depth,
        old_attachment.runtime.producer_index, old_attachment.runtime.producer_wrap,
        old_attachment.runtime.consumer_index, old_attachment.runtime.consumer_wrap,
        1'b0, runtime_initial_polarity);
      if (!status.ok()) begin
        break;
      end
      status = candidate_runtime.copy_ring_state(old_attachment.runtime);
      if (status.ok()) status = candidate_runtime.activate();
      if (!status.ok()) begin
        break;
      end

      candidate_access = rdma_queue_backing_access::type_id::create(
        "cq_resize_backing_access");
      if (candidate_access == null) begin
        status = bad("CQ resize backing access allocation failed",
                     RDMA_SC_RESOURCE_EXHAUSTED);
        break;
      end
      status = candidate_access.configure(binding.make_handle(), host_mem);
      if (status.ok()) status = candidate_access.attach_queue(candidate_ref);
      if (!status.ok()) begin
        break;
      end

      candidate_plan = rdma_queue_backing_plan::type_id::create(
        "cq_resize_plan");
      if (candidate_plan == null) begin
        status = bad("CQ resize queue plan allocation failed",
                     RDMA_SC_RESOURCE_EXHAUSTED);
        break;
      end
      candidate_plan.copy(authoritative_cq.queue_plan);
      foreach (candidate_plan.rings[i]) begin
        if (candidate_plan.rings[i] != null &&
            candidate_plan.rings[i].role == RDMA_QUEUE_ROLE_CQ_RING)
          candidate_plan.rings[i] = candidate_ring;
      end
      foreach (candidate_plan.refs[i]) begin
        if (candidate_plan.refs[i] != null &&
            candidate_plan.refs[i].role == RDMA_QUEUE_ROLE_CQ_RING)
          candidate_plan.refs[i] = candidate_ref;
      end

      candidate_cq = rdma_cq::type_id::create("cq_resize_candidate");
      if (candidate_cq == null) begin
        status = bad("CQ resize candidate allocation failed",
                     RDMA_SC_RESOURCE_EXHAUSTED);
        break;
      end
      candidate_cq.copy(authoritative_cq);
      candidate_cq.state = RDMA_RESOURCE_ACTIVE;
      candidate_cq.depth = new_depth;
      candidate_cq.cqe_size_bytes = new_cqe_bytes;
      candidate_cq.producer_index = candidate_runtime.producer_index;
      candidate_cq.consumer_index = candidate_runtime.consumer_index;
      candidate_cq.producer_wrap = candidate_runtime.producer_wrap;
      candidate_cq.consumer_wrap = candidate_runtime.consumer_wrap;
      candidate_cq.queue_iova = candidate_ref.mapping.iova;
      candidate_cq.queue_plan = candidate_plan;

      // 设计：旧 authority 仍可读时预先解析发布后所需字段，并完成
      // replacement attachment 构造，使原子 manager swap 之后不再发生分配/类型失败。
      status = find_queue_ref(authoritative_cq.queue_plan,
                              RDMA_QUEUE_ROLE_CQ_RING, old_ref);
      if (!status.ok()) begin
        break;
      end
      // 在 manager/attachment 原子发布前准备 engine-owned recovery record，
      // 确保发布后任一 detach/release 故障都有持久重试入口。
      recovery = rdma_cq_resize_recovery::type_id::create(
        "cq_resize_recovery");
      if (recovery == null) begin
        status = bad("CQ resize recovery record allocation failed",
                     RDMA_SC_RESOURCE_EXHAUSTED);
        break;
      end
      recovery.cq_h = rdma_clone_handle_value(cq_h, "CQ resize recovery CQ");
      if (recovery.cq_h == null)
        recovery.cq_h = cq_h;
      recovery.function_identity = binding.function_identity_snapshot();
      if (recovery.function_identity == null) begin
        status = bad("CQ resize recovery Function identity snapshot failed",
                     RDMA_SC_RESOURCE_EXHAUSTED);
        break;
      end
      recovery.old_runtime = old_attachment.runtime;
      recovery.old_ref = old_ref;
      if (old_ref == null || old_ref.mapping == null ||
          !old_ref.mapping.epoch_valid) begin
        status = bad("CQ resize recovery old backing epoch is missing",
                     RDMA_SC_RECOVERY_REQUIRED);
        break;
      end
      if (old_ref.ownership != RDMA_OWNERSHIP_CONTROL_PLANE ||
          old_ref.cleanup_complete) begin
        status = bad("CQ resize recovery old backing ownership/state is invalid",
                     RDMA_SC_RECOVERY_REQUIRED);
        break;
      end
      recovery.backing_role = old_ref.role;
      recovery.backing_mapping_offset = old_ref.mapping_offset;
      recovery.backing_length = old_ref.length;
      recovery.backing_logical_queue_offset = old_ref.logical_queue_offset;
      recovery.backing_geometry_valid = 1'b1;
      // 设计说明：published recovery 的 immutable epoch 必须绑定 old backing；
      // candidate mapping epoch 属于新 attachment，不能证明 retained old mapping
      // 仍可安全释放。
      recovery.backing_reset_epoch = old_ref.mapping.reset_epoch;
      recovery.backing_epoch_valid = 1'b1;
      foreach (dependents[i])
        recovery.dependents.push_back(dependents[i]);
      replacement = rdma_queue_data_attachment::type_id::create(
        "cq_resize_attachment");
      if (replacement == null) begin
        status = bad("CQ resize attachment allocation failed",
                     RDMA_SC_RESOURCE_EXHAUSTED);
        break;
      end
      status = clone_publish_handle(old_attachment.ceq_h,
                                    "CQ resize attachment CEQ",
                                    replacement_ceq_h);
      if (status == null || !status.ok() || replacement_ceq_h == null) begin
        if (status == null || status.ok())
          status = bad("CQ resize CEQ snapshot is unavailable",
                       RDMA_SC_RESOURCE_EXHAUSTED);
        break;
      end
      replacement.queue_h = old_attachment.queue_h;
      replacement.ceq_h = replacement_ceq_h;
      replacement.kind = old_attachment.kind;
      replacement.runtime = candidate_runtime;
      replacement.access = candidate_access;
      replacement.role = old_attachment.role;
      replacement.context_ref = candidate_plan.context_ref;
      replacement.entry_size = new_cqe_bytes;
      replacement.local_id = old_attachment.local_id;
      replacement.transport = old_attachment.transport;

      status = manager.replace_active_cq(candidate_cq);
      if (!status.ok()) begin
        break;
      end

      // 设计：发布成功后立即切换 attachment，使后续恢复报告指向新 authority；
      // 随后 detach 旧 runtime 并释放 control-plane-owned 的旧 mapping。
      // manager replacement 已经提交，recovery record 从此进入 published
      // 阶段；retry 必须把当前 attachment 视为新 runtime，并只清理 old_ref。
      recovery.published = 1'b1;
      attachments[key] = replacement;
      cq_resize_recoveries[recovery_key] = recovery;
      status = restore_cq_dependents(dependents);
      if (status == null || !status.ok()) begin
        if (status == null)
          status = bad("CQ resize dependent runtime restore returned null",
                       RDMA_SC_RECOVERY_REQUIRED);
        recovery.last_status = status;
        return finish_resize(rdma_status::make(
          RDMA_SC_RECOVERY_REQUIRED,
          {"CQ resize published but dependent runtime restore failed: ",
           status.message}));
      end
      status = old_attachment.runtime.detach_quiesced();
      if (status == null || !status.ok()) begin
        if (status == null)
          status = bad("CQ resize old runtime detach returned null",
                       RDMA_SC_RECOVERY_REQUIRED);
        recovery.last_status = status;
        return finish_resize(rdma_status::make(
          RDMA_SC_RECOVERY_REQUIRED,
          {"CQ resize published but old runtime detach failed: ",
           status.message}));
      end
      status = backing_planner.cleanup_local_role(old_ref, cleanup_complete);
      if (status == null || !status.ok() || !cleanup_complete) begin
        if (status == null)
          status = bad("CQ resize old backing cleanup returned null",
                       RDMA_SC_RECOVERY_REQUIRED);
        recovery.last_status = status;
        return finish_resize(rdma_status::make(
          RDMA_SC_RECOVERY_REQUIRED,
          {"CQ resize published but old backing cleanup failed: ",
           status.message,
           "; dependent restore: ",
           "dependents already restored"}));
      end
      cq_resize_recoveries.delete(recovery_key);
      return finish_resize(rdma_status::success());
    end while (1'b0);

    // 只有发布前的 break 能到达这里；回滚仍读取失败点之后的 runtime/ref，
    // 并由 finish_resize 恰好归还一次 token，保持原错误与 cleanup/restore 顺序。
    status = abort_cq_resize(cq_h, old_attachment.runtime, dependents,
                             candidate_ref, manager_quiesced, cq_quiesced,
                             status);
    return finish_resize(status);
  endfunction

  // 功能：decode_event_image 按事件 image kind 查找对应 codec 并完成一次 detached
  //   image 解码，把 CEQE/AEQE 共用的 metadata、registry 和 null-status 处理收束到
  //   一个只读阶段，供两个 event poll caller 继续执行各自 route policy。
  // 输入/输出及副作用：entry_image、image_kind 和 label 为输入；decoded_model/status
  //   为输出。函数只读取 codec registry 并创建 detached model，不推进 event cursor、
  //   不写 Host-memory/MMIO，也不建立 recovery pending。
  // 失败/边界：空 image、未知 image kind、registry 缺失、codec 类型/解码失败或返回
  //   null status 均返回非成功状态；失败发生在任何 consumer mutation 之前，caller
  //   必须保留 ring entry 供显式修复后重试，不能把 malformed image 当作 route miss ack。
  protected task decode_event_image(
    rdma_hw_image entry_image,
    rdma_image_kind_e image_kind,
    string label,
    output rdma_hw_model decoded_model,
    output rdma_status status
  );
    rdma_codec_key codec_key;
    rdma_codec_base codec;
    string object_type;

    decoded_model = null;
    status = null;
    if (entry_image == null) begin
      status = bad({label, " image is null"}, RDMA_SC_CODEC_ERROR);
      return;
    end
    case (image_kind)
      RDMA_IMAGE_CEQE: object_type = "ceqe";
      RDMA_IMAGE_AEQE: object_type = "aeqe";
      default: begin
        status = bad({label, " image kind is unsupported"},
                     RDMA_SC_CODEC_ERROR);
        return;
      end
    endcase
    codec_key = '{hw_version:"rdma", image_kind:image_kind,
      object_type:object_type, variant:"default", opcode:8'h00};
    status = lookup_codec_checked(codec_key, {label, " poll"}, codec);
    if (status == null || !status.ok()) begin
      if (status == null)
        status = bad({label, " codec lookup normalization failed"},
                     RDMA_SC_CODEC_ERROR);
      return;
    end
    status = codec.decode(entry_image, decoded_model);
    if (status == null) begin
      status = bad({label, " decode returned null status"},
                   RDMA_SC_CODEC_ERROR);
      return;
    end
    if (!status.ok())
      return;
    if (decoded_model == null) begin
      status = bad({label, " codec returned a null model"},
                   RDMA_SC_CODEC_ERROR);
      return;
    end
  endtask

  // 功能：poll_ceqe_once 在 scheduler 前冻结 CEQE、可选 CQ route 与 prepared
  //   pending，再按 doorbell→consumer commit→result 消费一条 CEQ event。
  // 输入/输出及副作用：ceq_h 为输入，result/status 为输出；合法 image 命中 CQ
  //   时发布 detached CEQ/CQ/model/status，合法但 route miss 时丢弃 payload；两者
  //   都推进 CEQ CI/used 并发送 consumer doorbell，不取得 CQ 或 backing 所有权。
  // 失败/边界：read/decode/owner/多重 route/result/pending admission 失败不 ack；
  //   单纯零匹配 route 是驱动允许的 stale/unknown 事件，必须继续消费；doorbell 或
  //   commit 失败保留单调 recovery evidence，不访问 CQ 专用 WQE release 位。
  protected task poll_ceqe_once(
    rdma_handle ceq_h,
    output rdma_queue_event_result result,
    output rdma_status status
  );
    rdma_queue_data_attachment attachment;
    rdma_queue_cursor_snapshot cursor;
    rdma_queue_cursor_snapshot next;
    rdma_hw_image entry_image;
    rdma_hw_model decoded_model;
    rdma_hw_ceqe_model ceqe;
    rdma_handle routed_cq_h;
    rdma_queue_pending_operation pending;
    rdma_queue_event_result result_candidate;
    rdma_doorbell_desc prepared_db_desc;
    rdma_status event_status;
    rdma_status final_success;
    rdma_status noalloc_status;
    bit route_found;
    byte data[];
    longint unsigned offset;

    result = null;
    status = null;
    status = lookup_attachment(ceq_h, RDMA_QUEUE_RUNTIME_CEQ, attachment);
    if (!status.ok()) return;
    status = attachment.runtime.peek_consumer(cursor);
    if (!status.ok()) return;
    offset = longint'(cursor.index) * attachment.entry_size;
    status = attachment.access.read(offset, attachment.entry_size, data);
    if (!status.ok()) return;
    status = make_entry_image(data, RDMA_IMAGE_CEQE, attachment.entry_size,
                              entry_image);
    if (!status.ok()) return;
    decode_event_image(entry_image, RDMA_IMAGE_CEQE, "CEQE",
                       decoded_model, status);
    if (status == null || !status.ok()) return;
    if (!$cast(ceqe, decoded_model) || ceqe == null) begin
      status = bad("CEQE codec returned the wrong model type", RDMA_SC_CODEC_ERROR);
      return;
    end
    if (ceqe.valid != attachment.runtime.expected_owner_polarity()) begin
      status = rdma_status::make(RDMA_SC_QUEUE_EMPTY,
                                 "CEQE owner bit does not match CI");
      return;
    end
    status = lookup_event_cq_route_for_poll(
      ceqe.cqn, routed_cq_h, route_found);
    if (status == null || !status.ok()) return;
    status = make_next_poll_cursor_nonfatal(
      attachment.runtime, cursor, "next CEQ", next);
    if (status == null || !status.ok()) return;
    if (route_found) begin
      // 驱动 event.c 在 image 合法且 CQN 命中时才向上层交付 payload；ecode
      // 映射或 detached result 的准备失败都必须保留 ring entry，不能把真实错误
      // 混入 stale-route 的“成功消费、丢 payload”路径。
      status = completion_status_from_ecode(
        ceqe.ecode, RDMA_ENGINE_CEQ, event_status);
      if (status == null || !status.ok() || event_status == null) begin
        if (status == null || status.ok())
          status = value_ops::make_status_nonfatal(
            RDMA_SC_RESOURCE_EXHAUSTED,
            "CEQ event status materialization failed");
        return;
      end
      status = value_ops::prepare_event_result_candidate(
        ceq_h, ceqe, routed_cq_h, event_status,
        result_candidate, final_success);
      if (status == null || !status.ok() || result_candidate == null ||
          final_success == null) begin
        if (status == null || status.ok())
          status = value_ops::make_status_nonfatal(
            RDMA_SC_RESOURCE_EXHAUSTED, "CEQ event candidate is incomplete");
        return;
      end
    end
    else begin
      // 零 route 不是 malformed image：codec 已经完成 reserved/owner 校验，真实
      // 驱动会推进 CEQ CI 并 ack。此处预先物化最终 OK，确保 scheduler barrier
      // 之后不再分配状态对象；result 保持 null 代表 payload 被有意丢弃。
      final_success = value_ops::make_status_nonfatal(RDMA_SC_OK, "");
      if (final_success == null)
        return;
    end
    status = prepare_event_poll_continuation(
      "CEQ", attachment, cursor, next, offset, entry_image,
      pending, prepared_db_desc, noalloc_status);
    if (status == null || !status.ok()) return;
    commit_event_poll_candidate(
      "CEQ", attachment, cursor, next, pending, prepared_db_desc,
      noalloc_status, result_candidate, final_success, route_found,
      result, status);
  endtask

  // 功能：poll_event_with_timeout 统一 CEQ/AEQ wrapper 的 deadline、QUEUE_EMPTY
  //   重试和结果发布外壳，再把单次尝试委托给对应的 `*_once` task。
  // 输入/输出及副作用：event_h、timeout、is_aeq 和 label 为输入，result/status 为
  //   输出；timeout=0 只尝试一次，非零时每 1ns 重试 QUEUE_EMPTY，成功时发布 detached
  //   event 快照。helper 不修改 runtime、ledger、backing 或外部 resource ownership。
  // 失败/边界：deadline 溢出、单次 task 返回 null status、非 QUEUE_EMPTY 失败以及
  //   timeout 到期均直接返回并保持 result=null；is_aeq 只选择 CEQ/AEQ 单次入口，
  //   不改变各自 decode/route/pending/doorbell/commit/recovery 语义。
  protected task poll_event_with_timeout(
    rdma_handle event_h,
    time timeout,
    bit is_aeq,
    string label,
    output rdma_queue_event_result result,
    output rdma_status status
  );
    time deadline;
    rdma_queue_event_result candidate;
    rdma_status attempt;

    result = null;
    status = null;
    if (timeout != 0) begin
      deadline = $time + timeout;
      if (deadline < $time) begin
        status = bad({label, " poll deadline overflows simulation time"});
        return;
      end
    end
    do begin
      candidate = null;
      attempt = null;
      if (is_aeq)
        poll_aeqe_once(event_h, candidate, attempt);
      else
        poll_ceqe_once(event_h, candidate, attempt);
      if (attempt == null) begin
        status = bad({label, " poll returned null status"}, RDMA_SC_INVALID_STATE);
        return;
      end
      if (attempt.code != RDMA_SC_QUEUE_EMPTY || timeout == 0) begin
        status = attempt;
        if (attempt.ok())
          result = candidate;
        return;
      end
      if ($time >= deadline) begin
        status = rdma_status::make(
          RDMA_SC_TIMEOUT, {label, " poll deadline expired"});
        return;
      end
      #1ns;
    end while (1);
  endtask

  // 功能：poll_ceqe 以 ceq_h 轮询一条 CEQE；poll_ceqe_once 在 prepared
  //   admission 后按 doorbell→consumer commit 消费 event，wrapper 只发布完整结果。
  // 输入/输出及副作用：timeout=0 时单次尝试，非零时每 1ns 重试 QUEUE_EMPTY
  //   直到 deadline；result/status 为输出。成功推进 CEQ CI/used，返回的 event/QP/CQ
  //   均为 detached 值快照，不取得 resource-manager 或 backing 所有权。
  // 失败/边界：deadline 溢出、null status、超时或 owner/route/MMIO/commit 错误
  //   均保持 result=null；内部阶段失败形成的 pending 由公开 recovery 显式处理，
  //   本 task 不重发 doorbell，也不访问 CQ 专用 WQE release ledger。
  virtual task poll_ceqe(
    rdma_handle ceq_h, time timeout,
    output rdma_queue_event_result result,
    output rdma_status status
  );
    poll_event_with_timeout(ceq_h, timeout, 1'b0, "CEQ", result, status);
  endtask

  // 功能：poll_aeqe_once 在 scheduler 前冻结 AEQE、按 ecode class 解析 owner route
  //   与 prepared pending，再按 doorbell→consumer commit→result 消费一条 AEQ event。
  // 输入/输出及副作用：aeq_h 为输入，result/status 为输出；合法 image 命中 QP、
  //   SRQ、CQ、EQ 或 Function route 时发布 detached AEQ/model/status；CQ flush 任一
  //   CQ/QP route 命中即可发布 partial result，其余零 route 丢弃 payload；两者都
  //   推进 AEQ CI/used 并发送 consumer doorbell，不取得 QP 或 backing 所有权。
  // 失败/边界：attachment route/reset epoch 过期以及 read/decode/owner/多重
  //   route/result/pending admission 失败均不 ack；epoch gate 在 peek/read 前失败，
  //   因而不改变 PI、CI、used、pending、backing access count 或 consumer MMIO；
  //   单纯零匹配 route 是驱动允许的 stale/unknown 事件，必须继续消费；doorbell 或
  //   commit 失败保留单调 recovery evidence，不访问 CQ 专用 WQE release 位。
  protected task poll_aeqe_once(
    rdma_handle aeq_h,
    output rdma_queue_event_result result,
    output rdma_status status
  );
    rdma_queue_data_attachment attachment;
    rdma_queue_cursor_snapshot cursor;
    rdma_queue_cursor_snapshot next;
    rdma_hw_image entry_image;
    rdma_hw_model decoded_model;
    rdma_hw_aeqe_model aeqe;
    rdma_queue_pending_operation pending;
    rdma_queue_event_result result_candidate;
    rdma_doorbell_desc prepared_db_desc;
    rdma_status event_status;
    rdma_status final_success;
    rdma_status noalloc_status;
    rdma_aeqe_event_class_e event_class;
    rdma_handle primary_route_h;
    rdma_handle secondary_route_h;
    bit primary_found;
    bit secondary_found;
    bit is_cq_flush;
    bit deliver_found;
    byte data[];
    longint unsigned offset;

    result = null;
    status = null;
    status = lookup_attachment(aeq_h, RDMA_QUEUE_RUNTIME_AEQ, attachment);
    if (!status.ok()) return;
    // 设计说明：AEQ attachment 冻结的是 attach 时的 Function route/reset epoch。
    // 必须在 peek_consumer 与 backing read 前对比当前 binding；这样旧 Function
    // 事件不会经新 binding 解析后被错误确认，而存活 carrier 下的 stale owner
    // route 仍由后续 resolve 作为可确认的普通 route miss 处理。
    status = validate_attachment_route_epoch(attachment);
    if (!status.ok()) return;
    status = attachment.runtime.peek_consumer(cursor);
    if (!status.ok()) return;
    offset = longint'(cursor.index) * attachment.entry_size;
    status = attachment.access.read(offset, attachment.entry_size, data);
    if (!status.ok()) return;
    status = make_entry_image(data, RDMA_IMAGE_AEQE, attachment.entry_size,
                              entry_image);
    if (!status.ok()) return;
    decode_event_image(entry_image, RDMA_IMAGE_AEQE, "AEQE",
                       decoded_model, status);
    if (status == null || !status.ok()) return;
    if (!$cast(aeqe, decoded_model) || aeqe == null) begin
      status = bad("AEQE codec returned the wrong model type", RDMA_SC_CODEC_ERROR);
      return;
    end
    if (aeqe.valid != attachment.runtime.expected_owner_polarity()) begin
      status = rdma_status::make(RDMA_SC_QUEUE_EMPTY,
                                 "AEQE owner bit does not match CI");
      return;
    end
    status = resolve_aeqe_routes(
      aeqe, event_class, primary_route_h, secondary_route_h,
      primary_found, secondary_found
    );
    if (status == null || !status.ok()) return;
    is_cq_flush = event_class == RDMA_AEQE_EVENT_CQ &&
                  aeqe.packet_opcode[4:0] == 5'h1d;
    deliver_found = is_cq_flush ? (primary_found || secondary_found) :
                                  primary_found;
    status = make_next_poll_cursor_nonfatal(
      attachment.runtime, cursor, "next AEQ", next);
    if (status == null || !status.ok()) return;
    if (deliver_found) begin
      // 普通事件按 primary 命中交付；CQ flush 按两路 found 的 OR 交付，允许
      // CQ-only 或 QP-only candidate。任何物化失败都发生在 pending admission 前，
      // 必须保留 AEQ entry，不得越过既有 doorbell→evidence→CI commit 顺序。
      status = completion_status_from_ecode(
        aeqe.ecode, RDMA_ENGINE_AEQ, event_status);
      if (status == null || !status.ok() || event_status == null) begin
        if (status == null || status.ok())
          status = value_ops::make_status_nonfatal(
            RDMA_SC_RESOURCE_EXHAUSTED,
            "AEQ event status materialization failed");
        return;
      end
      status = value_ops::prepare_event_result_candidate_ex(
        aeq_h, aeqe, primary_route_h, event_status,
        result_candidate, final_success, secondary_route_h);
      if (status == null || !status.ok() || result_candidate == null ||
          final_success == null) begin
        if (status == null || status.ok())
          status = value_ops::make_status_nonfatal(
            RDMA_SC_RESOURCE_EXHAUSTED, "AEQ event candidate is incomplete");
        return;
      end
    end
    else begin
      // image 已通过 codec 的 reserved/owner 检查，零 route 仅表示驱动侧对象已
      //   过期或未知。预先物化 OK 供 barrier 后返回，result=null 明确表示丢弃 payload。
      final_success = value_ops::make_status_nonfatal(RDMA_SC_OK, "");
      if (final_success == null)
        return;
    end
    status = prepare_event_poll_continuation(
      "AEQ", attachment, cursor, next, offset, entry_image,
      pending, prepared_db_desc, noalloc_status);
    if (status == null || !status.ok()) return;
    commit_event_poll_candidate(
      "AEQ", attachment, cursor, next, pending, prepared_db_desc,
      noalloc_status, result_candidate, final_success, deliver_found,
      result, status);
  endtask

  // 功能：poll_aeqe 以 aeq_h 轮询一条 AEQE；poll_aeqe_once 在 prepared
  //   admission 后按 doorbell→consumer commit 消费 async event，wrapper 只发布完整结果。
  // 输入/输出及副作用：timeout=0 时单次尝试，非零时每 1ns 重试 QUEUE_EMPTY
  //   直到 deadline；result/status 为输出。成功推进 AEQ CI/used，返回 detached
  //   AEQ/QP/status 快照，不取得 resource-manager 或 backing 所有权。
  // 失败/边界：deadline 溢出、null status、超时或 owner/route/MMIO/commit 错误
  //   均保持 result=null；内部 pending 只允许显式 recovery 继续，且 AEQ 路径不访问
  //   CQ 专用 completion target/release 阶段。
  virtual task poll_aeqe(
    rdma_handle aeq_h, time timeout,
    output rdma_queue_event_result result,
    output rdma_status status
  );
    poll_event_with_timeout(aeq_h, timeout, 1'b1, "AEQ", result, status);
  endtask

  // 功能：admit_host_producer_recovery 将 host-producer 失败证据交给对应 runtime，
  //   并把 runtime 的 null 返回归一化为 RECOVERY_REQUIRED，供发送/接收尾段共享。
  // 输入/输出及副作用：attachment、pending 和 mmio_maybe_submitted 为输入；成功时
  //   runtime 接管 pending 并切换 recovery 状态，函数不修改 caller 的 request/image
  //   或外部 backing 所有权。
  // 失败/边界：attachment/runtime/pending 缺失、runtime 拒绝或返回 null 时返回非空
  //   非成功状态；调用方必须保留原始阶段失败并禁止伪造 post result。
  protected virtual function rdma_status admit_host_producer_recovery(
    rdma_queue_data_attachment attachment,
    rdma_queue_pending_operation pending,
    bit mmio_maybe_submitted
  );
    rdma_status admission;

    if (attachment == null || attachment.runtime == null || pending == null)
      return bad("host producer recovery admission input is incomplete",
                 RDMA_SC_RECOVERY_REQUIRED);
    admission = attachment.runtime.enter_recovery(
      pending, mmio_maybe_submitted);
    if (admission == null)
      return bad("host producer recovery admission returned null status",
                 RDMA_SC_RECOVERY_REQUIRED);
    return admission;
  endfunction

  // 功能：install_host_producer_recovery 为已经发生 Host-memory 写入的 SQ/RQ/SRQ
  //   事务构造同一 detached pending，覆盖 make_pending 的兼容 route 查询并完成
  //   NO_SUBMIT/AMBIGUOUS recovery admission。
  // 输入/输出及副作用：attachment、queue_h、kind、cursor、offset、image、snapshot、
  //   signaled、reservation route/epoch、MMIO 阶段和 failure_label 为输入；status 为
  //   inout，成功 admission 时保持原始阶段错误，pending 构造或 admission 失败时改
  //   为可观察的资源/恢复错误；可能切换 runtime recovery，但不取得外部资源所有权。
  // 失败/边界：pending clone、route/epoch 覆盖、runtime admission 任一失败都返回
  //   非空 status 且不发布 result；route/epoch valid 位不全时拒绝旧 evidence，不能
  //   退化为读取当前 runtime authority。
  protected task install_host_producer_recovery(
    rdma_queue_data_attachment attachment,
    rdma_handle queue_h,
    rdma_queue_runtime_kind_e kind,
    rdma_queue_cursor_snapshot cursor,
    longint unsigned offset,
    rdma_hw_image image,
    rdma_semantic_request snapshot,
    bit signaled,
    rdma_route_key_t reservation_route,
    rdma_reset_epoch_t reservation_epoch,
    bit reservation_route_valid,
    bit reservation_epoch_valid,
    bit mmio_maybe_submitted,
    string failure_label,
    inout rdma_status status
  );
    rdma_queue_pending_operation pending;
    rdma_status admission;

    pending = make_pending(
      cursor, queue_h, kind, 1'b1, offset, image, snapshot, signaled,
      0, 1'b0, 1'b0, 1'b0, null, attachment);
    if (pending == null ||
        !value_ops::apply_host_producer_pending_route_epoch(
          pending, reservation_route, reservation_epoch,
          reservation_route_valid, reservation_epoch_valid)) begin
      status = pending_build_failure(failure_label);
      return;
    end
    admission = admit_host_producer_recovery(
      attachment, pending, mmio_maybe_submitted);
    if (admission == null || !admission.ok()) begin
      status = admission == null ?
        bad("host producer recovery admission returned null status",
            RDMA_SC_RECOVERY_REQUIRED) : admission;
    end
  endtask

  // 设计说明：SQ、私有 RQ 与 shared SRQ 在 request/authority/model 阶段不同，
  //   但 reservation 成功后的 host-producer 尾段必须保持同一顺序：先把固定 WQE
  //   image 写回并验证，再用冻结 cursor 计算 next、提交 doorbell，最后才进入
  //   producer ledger commit。将这段顺序集中到一个 task，避免某个 posting ring
  //   在 write、MMIO evidence 或 recovery pending 上出现漂移；SQ 专属 SGB 写入
  //   仍由 post_send 在本 task 之前独占处理。本 task 在第一笔 WQE write 前再做
  //   一次 route/epoch gate，覆盖 model encode 期间发生的 reset；该 gate 不宣称
  //   binding、runtime 与 backing 的跨组件原子锁，实际 backend write 的并发复位
  //   仍由既有 pending/recovery 证据处理。
  // 功能：complete_host_producer_tail 完成已预留 SQ/RQ/SRQ producer cursor 的 WQE
  //   write/readback、doorbell continuation、producer commit 和 detached post result
  //   构造；失败时按阶段保存同一 cursor/request/image 的 recovery evidence。
  // 输入/输出及副作用：attachment、queue_h、kind、cursor、offset、image、snapshot、
  //   wr_id、signaled、doorbell_sqe_image 和 local_id 为 caller 冻结输入；caller 必须
  //   先完成对应 posting ring 的 authority 检查，并证明 queue_h、attachment/
  //   runtime kind 与同一 reserve_producer cursor 相配；task 自身会在首次 WQE
  //   write 前复核 attachment route/epoch，且 SQ 以外的
  //   doorbell_sqe_image 必须为空；result/status 为输出。
  //   task 可能访问 Host-memory、发送一次 producer doorbell、推进 runtime PI/used/ledger
  //   或安装 pending，但不取得 queue、backing、request 或 handle 的外部生命周期所有权。
  // 失败/边界：WQE 写回/读回失败尝试安装 NO_SUBMIT pending；doorbell 失败或
  //   producer commit 失败尝试安装既有 AMBIGUOUS evidence；WQE 已写后 result
  //   factory/cast 或 queue clone 失败也安装 NO_SUBMIT pending；next cursor factory
  //   失败按同一规则保存 WQE evidence。pending clone 失败返回 RESOURCE_EXHAUSTED，
  //   且不伪造 result。SQ shadow gate 合法地返回 status=OK、
  //   doorbell_result=null 时仍继续 commit；正常 recovery admission 保留原始阶段
  //   status，admission 拒绝或返回 null 时升级为 RECOVERY_REQUIRED，避免调用方把
  //   未接管的 evidence 当作可安全重试。若调用方已完成 SQ SGB 的 Host-memory 写入，
  //   尾段 gate 失败也必须安装同一 cursor/image 的 NO_SUBMIT pending，不能把已发生
  //   的 SGB 副作用伪装成无事务返回。
  protected task complete_host_producer_tail(
    rdma_queue_data_attachment attachment,
    rdma_handle queue_h,
    rdma_queue_runtime_kind_e kind,
    rdma_queue_cursor_snapshot cursor,
    longint unsigned offset,
    rdma_hw_image image,
    rdma_semantic_request snapshot,
    longint unsigned wr_id,
    bit signaled,
    rdma_hw_image doorbell_sqe_image,
    int unsigned local_id,
    string next_name,
    string write_failure_label,
    string doorbell_failure_label,
    string commit_failure_label,
    string result_name,
    string result_handle_label,
    output rdma_queue_post_result result,
    output rdma_status status,
    input rdma_route_key_t reservation_route = '0,
    input rdma_reset_epoch_t reservation_epoch = '0,
    input bit reservation_route_valid = 1'b0,
    input bit reservation_epoch_valid = 1'b0,
    input bit prior_host_write = 1'b0
  );
    rdma_queue_cursor_snapshot next;
    rdma_queue_post_result result_candidate;
    rdma_doorbell_result doorbell_result;
    rdma_status next_status;
    uvm_object raw_result;

    result = null;
    status = null;
    next = null;
    result_candidate = null;

    // reservation 返回的是 detached cursor；在 WQE 首次写回前再次确认当前
    // Function route/epoch，避免编码期间发生 reset 后仍把旧 attachment 当作可写。
    status = validate_host_producer_reservation_window(attachment, cursor);
    if (status == null || !status.ok()) begin
      if (status == null)
        status = bad("host producer reservation window returned null status",
                     RDMA_SC_INVALID_STATE);
      if (prior_host_write) begin
        install_host_producer_recovery(
          attachment, queue_h, kind, cursor, offset, image, snapshot, signaled,
          reservation_route, reservation_epoch, reservation_route_valid,
          reservation_epoch_valid, 1'b0, write_failure_label, status);
      end
      return;
    end

    status = write_and_verify(attachment, offset, image);
    if (status == null || !status.ok()) begin
      if (status == null)
        status = bad("host producer entry write returned null status",
                     RDMA_SC_DMA_TRANSLATION);
      install_host_producer_recovery(
        attachment, queue_h, kind, cursor, offset, image, snapshot, signaled,
        reservation_route, reservation_epoch, reservation_route_valid,
        reservation_epoch_valid, 1'b0, write_failure_label, status);
      return;
    end

    // WQE 已成功写回；先以 nonfatal raw factory 物化 result，避免 hostile
    // override 在已提交后触发 FCTTYP fatal 或把空 queue handle 伪装成成功。
    raw_result = value_ops::factory_create_object_nonfatal(
      rdma_queue_post_result::get_type(), result_name);
    if (raw_result == null || !$cast(result_candidate, raw_result) ||
        result_candidate == null) begin
      result_candidate = null;
      status = bad("host producer result allocation or cast failed",
                   RDMA_SC_RESOURCE_EXHAUSTED);
      install_host_producer_recovery(
        attachment, queue_h, kind, cursor, offset, image, snapshot, signaled,
        reservation_route, reservation_epoch, reservation_route_valid,
        reservation_epoch_valid, 1'b0, result_name, status);
      return;
    end
    if (!clone_pending_handle_value(
          queue_h, result_handle_label, result_candidate.queue_h) ||
        result_candidate.queue_h == null) begin
      result_candidate = null;
      status = bad("host producer result queue snapshot allocation failed",
                   RDMA_SC_RESOURCE_EXHAUSTED);
      install_host_producer_recovery(
        attachment, queue_h, kind, cursor, offset, image, snapshot, signaled,
        reservation_route, reservation_epoch, reservation_route_valid,
        reservation_epoch_valid, 1'b0, result_name, status);
      return;
    end

    next_status = make_next_poll_cursor_nonfatal(
      attachment.runtime, cursor, next_name, next);
    if (next_status == null || !next_status.ok() || next == null) begin
      status = next_status == null ?
        bad("host producer next cursor factory returned null status",
            RDMA_SC_RESOURCE_EXHAUSTED) :
        (!next_status.ok() ? next_status :
         bad("host producer next cursor factory returned null cursor",
             RDMA_SC_RESOURCE_EXHAUSTED));
      install_host_producer_recovery(
        attachment, queue_h, kind, cursor, offset, image, snapshot, signaled,
        reservation_route, reservation_epoch, reservation_route_valid,
        reservation_epoch_valid, 1'b0, next_name, status);
      return;
    end
    submit_producer_doorbell(
      queue_h, kind, cursor, next, doorbell_sqe_image, local_id,
      doorbell_result, status);
    if (status == null || !status.ok()) begin
      if (status == null)
        status = bad("host producer doorbell returned null status",
                     RDMA_SC_INVALID_STATE);
      install_host_producer_recovery(
        attachment, queue_h, kind, cursor, offset, image, snapshot, signaled,
        reservation_route, reservation_epoch, reservation_route_valid,
        reservation_epoch_valid, 1'b1, doorbell_failure_label, status);
      return;
    end

    status = commit_host_producer_ledger(
      attachment, cursor, snapshot, wr_id, signaled, image);
    if (status == null || !status.ok()) begin
      if (status == null)
        status = bad("host producer ledger commit returned null status",
                     RDMA_SC_INVALID_STATE);
      install_host_producer_recovery(
        attachment, queue_h, kind, cursor, offset, image, snapshot, signaled,
        reservation_route, reservation_epoch, reservation_route_valid,
        reservation_epoch_valid, 1'b1, commit_failure_label, status);
      return;
    end

    // ledger commit 已完成；candidate 已在 doorbell 前完成 factory/cast/handle
    // 检查，因此这里只填充已提交值并使用 direct status，避免结果 status factory
    // 失败把已提交事务降格成空 result。
    result_candidate.wr_id = wr_id;
    result_candidate.index = cursor.index;
    result_candidate.wrap = cursor.wrap;
    result_candidate.image = image;
    result_candidate.status = rdma_status::make_direct(RDMA_SC_OK);
    if (result_candidate.status == null) begin
      result_candidate = null;
      status = bad("host producer committed result status allocation failed",
                   RDMA_SC_RECOVERY_REQUIRED);
      return;
    end
    result = result_candidate;
    status = result_candidate.status;
  endtask

  // 功能：post_send 冻结并校验 request/QP authority，预留 SQ cursor，编码可选
  //   SGB 与 SQE，完成 Host-memory write/readback、producer doorbell 和 ledger commit。
  // 输入/输出及副作用：request 为输入，result/status 为输出；成功推进 SQ PI/used，
  //   保存 wr_id/signaled/image ledger 并返回 detached queue/result。写入或 doorbell/commit
  //   失败会把同一 cursor、request 和 image 安装为 runtime recovery pending；在
  //   caller-specific QP/SQE authority 通过后，发送路径还会在 reservation 前复核
  //   attachment route/reset epoch，并在 detached cursor 返回后再次复核，避免
  //   reservation 窗口中的 stale binding 进入 model/write 阶段；尾段在首个 WQE
  //   write 前仍保留最后一道 gate，external-SGB 分支还会在 512-byte SGB writer
  //   前单独复核；这些局部 gate 不等同于跨 binding/runtime/backing 的全局原子锁。
  // 失败/边界：null request、不支持的 transport/opcode、请求/route/authority/SGE
  //   非法、队列无 credit 或 codec/backing 失败均不发布 result；validate() 返回
  //   null 时归一化为 INVALID_STATE；MMIO 进入后失败按 ambiguous evidence 保留，
  //   不能由本 task 自动重发，外部资源所有权始终不转移。
  virtual task post_send(
    rdma_post_send_req request,
    output rdma_queue_post_result result,
    output rdma_status status
  );
    rdma_post_send_req snapshot;
    rdma_queue_data_attachment attachment;
    rdma_queue_data_qp_link link;
    rdma_queue_cursor_snapshot cursor;
    rdma_hw_sqe_model model;
    rdma_hw_image image;
    rdma_queue_pending_operation pending;
    rdma_status recovery_status;
    rdma_route_key_t reservation_route;
    rdma_reset_epoch_t reservation_epoch;
    bit reservation_route_valid;
    bit reservation_epoch_valid;
    longint unsigned offset;

    result = null;
    status = null;

    if (request == null) begin
      status = bad("send request is null");
      return;
    end

    snapshot = rdma_post_send_req::type_id::create("send_snapshot");
    snapshot.copy(request);
    // 功能：在进入通用 request.validate() 前把 transport/opcode 能力拒绝归类为
    //   UNSUPPORTED_OPCODE，确保调用方可以区分“组合不支持”和“字段形状错误”。
    // 输入/输出及副作用：snapshot.transport、snapshot.opcode（输入）；返回新的
    //   rdma_status，不修改队列 runtime、Host-memory、doorbell 或 pending ledger。
    // 失败/边界：未知 transport 或该 transport 不允许的 work opcode 均在此返回；
    //   合法组合继续执行后续 authority/SGE/资源校验。
    if (!rdma_send_opcode_valid_for_transport(snapshot.transport,
                                              snapshot.opcode)) begin
      status = rdma_status::make(RDMA_SC_UNSUPPORTED_OPCODE,
                                 "work opcode is unsupported for transport");
      return;
    end
    status = snapshot.validate();
    if (status == null) begin
      status = bad("send request validation returned null status",
                   RDMA_SC_INVALID_STATE);
      return;
    end
    if (!status.ok())
      return;

    status = lookup_attachment(snapshot.qp_h, RDMA_QUEUE_RUNTIME_SQ,
                               attachment);
    if (status == null || !status.ok())
      return;
    if (!qp_links.exists(value_ops::identity_key(snapshot.qp_h)) ||
        qp_links[value_ops::identity_key(snapshot.qp_h)] == null) begin
      status = bad("QP is not attached", RDMA_SC_INVALID_STATE);
      return;
    end
    link = qp_links[value_ops::identity_key(snapshot.qp_h)];
    status = sqe_authority_status(snapshot, link);
    if (!status.ok())
      return;
    status = reserve_host_producer_cursor(
      attachment, cursor, reservation_route, reservation_epoch,
      reservation_route_valid, reservation_epoch_valid);
    if (!status.ok())
      return;
    status = validate_host_producer_reservation_window(attachment, cursor);
    if (status == null || !status.ok()) begin
      if (status == null)
        status = bad("send reservation window validation returned null status",
                     RDMA_SC_INVALID_STATE);
      cursor = null;
      return;
    end
    status = make_sqe(snapshot, link, cursor, model);
    if (!status.ok())
      return;
    status = encode_queue_model(
      model, RDMA_IMAGE_SQE, "sqe",
      snapshot.transport == RDMA_TRANSPORT_RC ? "rc" :
        snapshot.transport == RDMA_TRANSPORT_UD ? "ud" : "urc",
      image);
    if (!status.ok())
      return;
    if (snapshot.sgb_iova.value != 0) begin
      // SQ external-SGB 在公共 WQE 尾段之前有独立的 Host-memory 写入，因此必须
      // 在专用 writer 前立即关闭 reservation→encode→SGB 窗口；公共尾段还会在
      // 64-byte WQE 首次写入前再次复核，覆盖 SGB 写入之后发生的 reset。
      status = validate_host_producer_reservation_window(attachment, cursor);
      if (status == null || !status.ok()) begin
        if (status == null)
          status = bad("SQ SGB reservation window validation returned null status",
                       RDMA_SC_INVALID_STATE);
        cursor = null;
        return;
      end
      status = write_sgb_and_verify(link, model, cursor, image);
      if (!status.ok()) begin
        // SGB 已进入独立 Host-memory writer；即使 writer 失败时 runtime 的
        // 当前 route 已变化，pending 仍必须携带 reservation admission 冻结的
        // route/epoch，不能让 make_pending 的兼容查询把新 authority 当成旧证据。
        install_host_producer_recovery(
          attachment, snapshot.qp_h, RDMA_QUEUE_RUNTIME_SQ, cursor,
          longint'(cursor.index) * 64, image, snapshot, snapshot.signaled,
          reservation_route, reservation_epoch, reservation_route_valid,
          reservation_epoch_valid, 1'b0, "SQ SGB write", status);
        return;
      end
    end
    offset = longint'(cursor.index) * 64;
    complete_host_producer_tail(
      attachment, snapshot.qp_h, RDMA_QUEUE_RUNTIME_SQ, cursor, offset, image,
      snapshot, snapshot.wr_id, snapshot.signaled, image, link.local_qp_id,
      "next_sq_cursor", "SQ entry write", "SQ producer doorbell",
      "SQ ledger commit", "send_result", "send result QP", result, status,
      reservation_route, reservation_epoch, reservation_route_valid,
      reservation_epoch_valid, snapshot.sgb_iova.value != 0);
  endtask

  // 设计说明：RQ 与 SRQ 的 receive target resolution 只冻结 completion-QP
  // 路由、SRQ link identity 和目标 ring attachment；它不能把 owner/route epoch
  // 校验或 producer reservation 混入 lookup 层，否则 post_recv 的失败优先级和
  // 生命周期边界会随 posting pipeline 变化。该 helper 只读取 engine 索引，向
  // 后续阶段交付同一组非拥有引用。
  // 功能：resolve_receive_target 根据已验证的 receive request 选择 completion QP，
  //   检查 QP link 及 SRQ 完整 handle identity，并解析 RQ/SRQ 对应 attachment 与
  //   runtime kind，形成 post_recv 后续阶段使用的 canonical target。
  // 输入/输出及副作用：snapshot 为 snapshot.validate() 已成功的只读请求；link、
  //   attachment 先置空，成功时输出 engine 索引中的非拥有引用，runtime_kind 输出
  //   RDMA_QUEUE_RUNTIME_RQ 或 RDMA_QUEUE_RUNTIME_SRQ；函数只读 qp_links/attachments，
  //   不 reserve、修改 cursor、访问 backing/doorbell 或取得 QP/SRQ 生命周期所有权。
  // 失败/边界：snapshot/target 缺失、completion QP 未 attach、SRQ link 为空或与
  //   target handle incarnation 不一致、attachment lookup 返回 null/非成功状态时，
  //   返回对应的 INVALID_ARGUMENT/INVALID_STATE 或 lookup 错误；输出引用保持空，
  //   调用方不得进入 owner、route/epoch、write 或 commit 阶段。
  protected function rdma_status resolve_receive_target(
    rdma_post_recv_req snapshot,
    output rdma_queue_data_qp_link link,
    output rdma_queue_data_attachment attachment,
    output rdma_queue_runtime_kind_e runtime_kind
  );
    rdma_handle completion_qp_h;
    rdma_queue_wq_target_contract_t target_contract;
    rdma_status status;

    link = null;
    attachment = null;
    runtime_kind = RDMA_QUEUE_RUNTIME_RQ;
    if (snapshot == null || snapshot.target_h == null)
      return bad("receive target snapshot is incomplete",
                 RDMA_SC_INVALID_ARGUMENT);

    if (!rdma_queue_wq_target_policy::for_receive_target(
          snapshot.target_h.kind, target_contract))
      return bad("receive target resource kind is unsupported",
                 RDMA_SC_INVALID_ARGUMENT);
    runtime_kind = target_contract.runtime_kind;
    completion_qp_h = snapshot.target_h.kind == RDMA_RESOURCE_SRQ ?
                      snapshot.completion_qp_h : snapshot.target_h;
    if (completion_qp_h == null ||
        !qp_links.exists(value_ops::identity_key(completion_qp_h)) ||
        qp_links[value_ops::identity_key(completion_qp_h)] == null)
      return bad("receive completion QP is not attached", RDMA_SC_INVALID_STATE);

    link = qp_links[value_ops::identity_key(completion_qp_h)];
    if (link == null)
      return bad("receive completion QP link is incomplete", RDMA_SC_INVALID_STATE);
    if (runtime_kind == RDMA_QUEUE_RUNTIME_SRQ) begin
      // 设计：SRQ completion QP 的 link 必须仍指向 request 冻结的同一 SRQ
      // incarnation；只比较 object_id 会让 reset 后旧 SRQ 借新 generation 重用。
      if (link.srq_h == null ||
          !value_ops::same_handle_instance(link.srq_h, snapshot.target_h)) begin
        link = null;
        return bad("receive completion QP is not attached to the target SRQ");
      end
    end

    status = lookup_attachment(snapshot.target_h, runtime_kind, attachment);
    if (status == null) begin
      link = null;
      attachment = null;
      return bad("receive target attachment lookup returned null status",
                 RDMA_SC_INVALID_STATE);
    end
    if (!status.ok()) begin
      link = null;
      attachment = null;
      return status;
    end
    if (attachment == null || attachment.runtime == null ||
        attachment.access == null || attachment.entry_size == 0) begin
      link = null;
      attachment = null;
      return bad("receive target attachment is incomplete",
                 RDMA_SC_INVALID_STATE);
    end
    return rdma_status::success();
  endfunction

  // 功能：post_recv 冻结并校验 request，按 target_h 选择 QP RQ 或共享 SRQ，
  //   编码/写回 RQE 后提交 producer doorbell 与对应 WQE ledger。
  // 输入/输出及副作用：request 为输入，result/status 为输出；target resolution 使用
  //   completion_qp_h 提供 SRQ completion route。成功推进目标 RQ/SRQ PI/used 并发布
  //   detached result；
  //   write、doorbell 或 commit 失败保存同一 cursor/request/image pending 供 recovery。
  // 失败/边界：null/非法 request、foreign owner、completion QP 未 attach、SRQ
  //   绑定不一致、attachment route/reset epoch 在 reservation 前或 reservation 后
  //   复核时过期、队列无 credit、codec/backing
  //   或 MMIO/commit 失败时 result 保持 null；request.validate() 返回 null 时统一
  //   为 INVALID_STATE；ambiguous doorbell 不自动重发，task 不取得 QP/SRQ、mapping
  //   或 Host-memory 生命周期所有权。
  virtual task post_recv(
    rdma_post_recv_req request,
    output rdma_queue_post_result result,
    output rdma_status status
  );
    rdma_post_recv_req snapshot;
    rdma_queue_data_attachment attachment;
    rdma_queue_data_qp_link link;
    rdma_queue_cursor_snapshot cursor;
    rdma_hw_rqe_model model;
    rdma_hw_image image;
    rdma_queue_runtime_kind_e runtime_kind;
    rdma_route_key_t reservation_route;
    rdma_reset_epoch_t reservation_epoch;
    bit reservation_route_valid;
    bit reservation_epoch_valid;
    longint unsigned offset;

    result = null;
    status = null;

    if (request == null) begin
      status = bad("receive request is null");
      return;
    end

    snapshot = rdma_post_recv_req::type_id::create("recv_snapshot");
    snapshot.copy(request);

    status = snapshot.validate();
    if (status == null) begin
      status = bad("receive request validation returned null status",
                   RDMA_SC_INVALID_STATE);
      return;
    end
    if (!status.ok())
      return;

    status = resolve_receive_target(snapshot, link, attachment, runtime_kind);
    if (status == null || !status.ok()) begin
      if (status == null)
        status = bad("receive target resolution returned null status",
                     RDMA_SC_INVALID_STATE);
      return;
    end

    // receive request 的 owner 是 Function authority 证据，不能只依赖 target_h
    // 已出现在 attachment 索引中；同时在 reserve 前复核 binding 的 route/epoch，
    // 防止复位后旧 attachment 继续发布 RQE。
    if (snapshot.owner != null) begin
      status = rdma_handle_owner_status(snapshot.target_h, snapshot.owner);
      if (!status.ok())
        return;
    end

    status = reserve_host_producer_cursor(
      attachment, cursor, reservation_route, reservation_epoch,
      reservation_route_valid, reservation_epoch_valid);
    if (!status.ok())
      return;
    status = validate_host_producer_reservation_window(attachment, cursor);
    if (status == null || !status.ok()) begin
      if (status == null)
        status = bad("receive reservation window validation returned null status",
                     RDMA_SC_INVALID_STATE);
      cursor = null;
      return;
    end
    status = make_rqe(snapshot, link, cursor, model);
    if (!status.ok())
      return;
    status = encode_queue_model(model, RDMA_IMAGE_RQE, "rqe", "default", image);
    if (!status.ok())
      return;
    offset = longint'(cursor.index) * 64;
    complete_host_producer_tail(
      attachment, snapshot.target_h, runtime_kind, cursor, offset, image,
      snapshot, snapshot.wr_id, 1'b1, null,
      runtime_kind == RDMA_QUEUE_RUNTIME_SRQ ?
        attachment.local_id : link.local_qp_id,
      "next_rq_cursor", "RQ entry write", "RQ producer doorbell",
      "RQ ledger commit", "recv_result", "receive result queue", result,
      status, reservation_route, reservation_epoch, reservation_route_valid,
      reservation_epoch_valid, 1'b0);
  endtask

  // 功能：pending_next_cursor 校验 pending 中 admission 前冻结的 old/next cursor，
  //   并返回该 detached next evidence，禁止 recovery 按当前环境重新分配或推导快照。
  // 输入/输出及副作用：attachment/pending 为输入、next 先置 null；成功令 next 引用
  //   caller-owned pending.next_cursor，只读 depth/cursor，不修改 runtime 或 pending。
  // 失败/边界：对象缺失、index 越界或 next 不等于 old cursor 的单步环回结果时返回
  //   INVALID_STATE；不分配 cursor，也不允许 stale geometry 进入 doorbell/commit。
  protected function rdma_status pending_next_cursor(
    rdma_queue_data_attachment attachment,
    rdma_queue_pending_operation pending,
    output rdma_queue_cursor_snapshot next
  );
    int unsigned expected_index;
    bit expected_wrap;

    next = null;
    if (attachment == null || attachment.runtime == null || pending == null ||
        pending.cursor == null || pending.next_cursor == null ||
        attachment.runtime.depth == 0 ||
        pending.cursor.index >= attachment.runtime.depth ||
        pending.next_cursor.index >= attachment.runtime.depth)
      return bad("pending recovery cursor is invalid", RDMA_SC_INVALID_STATE);
    advance_queue_cursor_value(attachment.runtime.depth,
                               pending.cursor.index, pending.cursor.wrap,
                               expected_index, expected_wrap);
    if (pending.next_cursor.index != expected_index ||
        pending.next_cursor.wrap != expected_wrap)
      return bad("pending recovery next cursor is inconsistent",
                 RDMA_SC_INVALID_STATE);
    next = pending.next_cursor;
    return rdma_status::success();
  endfunction

  // 设计说明：host producer recovery 只重放 admission 时冻结的 SGB/WQE image，
  //   不重新 reserve cursor，也不从当前 request/queue state 推导新的 payload；
  //   device producer 与 consumer recovery 保持在 replay_pending() 的独立分支，
  //   防止 DMA 方向、doorbell evidence 和 ledger commit 互相串用。
  // 功能：validate_host_producer_pending_route_epoch 在 host-producer recovery
  //   首次重放前比较 pending 锁存的 attachment route/reset epoch 与 runtime 当前
  //   authority，阻止 reset 或换路后把旧 WQE/SGB image 写回新 incarnation。
  // 输入/输出及副作用：attachment、pending 为只读借用输入；函数只查询 runtime
  //   route/epoch 并返回 status，不访问 Host-memory、PCIe、ledger、cursor 或 pending。
  // 失败/边界：pending 缺 route/epoch、runtime 查询失败、route 不同或 epoch 变化时
  //   返回 RECOVERY_REQUIRED/STALE_GENERATION，调用方必须保留 evidence 并等待显式
  //   abort；成功只表示 authority 仍匹配，不代表后续 SGB/WQE 或 MMIO 可提交。
  protected function rdma_status validate_host_producer_pending_route_epoch(
    rdma_queue_data_attachment attachment,
    rdma_queue_pending_operation pending
  );
    rdma_route_key_t current_route;
    rdma_reset_epoch_t current_epoch;
    bit current_route_valid;
    bit current_epoch_valid;
    rdma_status status;

    current_route = '0;
    current_epoch = '0;
    current_route_valid = 1'b0;
    current_epoch_valid = 1'b0;
    if (attachment == null || attachment.runtime == null || pending == null)
      return bad("host producer pending route input is incomplete",
                 RDMA_SC_RECOVERY_REQUIRED);
    if (!pending.route_valid || !pending.epoch_valid ||
        !rdma_route_key_valid(pending.route))
      return bad("host producer pending route evidence is unavailable",
                 RDMA_SC_RECOVERY_REQUIRED);
    status = validate_attachment_route_epoch(attachment);
    if (status == null || !status.ok())
      return status == null ?
        bad("host producer pending attachment route validation returned null status",
            RDMA_SC_RECOVERY_REQUIRED) : status;
    status = attachment.runtime.query_route_epoch(
      current_route, current_route_valid, current_epoch, current_epoch_valid);
    if (status == null || !status.ok() || !current_route_valid ||
        !current_epoch_valid)
      return status == null ?
        bad("host producer pending route query returned null status",
            RDMA_SC_RECOVERY_REQUIRED) :
        (status.ok() ? bad("host producer pending route query is incomplete",
                           RDMA_SC_RECOVERY_REQUIRED) : status);
    if (!value_ops::same_route(current_route, pending.route) ||
        current_epoch != pending.reset_epoch)
      return bad("host producer pending route or reset epoch is stale",
                 RDMA_SC_STALE_GENERATION);
    return rdma_status::success();
  endfunction

  // 功能：replay_host_producer_pending 按 pending 的 SQ/RQ host-producer 证据重放
  //   可选 SGB、固定 WQE image、producer doorbell 与 runtime producer commit，并在
  //   每个失败点记录原 recovery evidence。
  // 输入/输出及副作用：attachment、pending、next 为已通过 authority/cursor 校验的
  //   非拥有输入；status 为输出；成功时访问 Host-memory、发送一次 doorbell、提交同一
  //   producer cursor 并完成 recovery，失败时保留 runtime pending，不取得 queue/backing
  //   所有权。
  // 失败/边界：pending image 缺失、SQ SGB route/link 无法解析、SGB/WQE 写回、
  //   doorbell、recovery commit 或完成阶段返回错误时立即停止；模型构造失败不触碰
  //   backing，SGB/WQE 写失败记录 NO_SUBMIT，doorbell 失败记录 AMBIGUOUS，commit
  //   失败记录 SUCCESS，不能自动重发 ambiguous MMIO 或推进新的 cursor。该 task 只
  //   接受 host producer pending，不处理 device-producer/consumer evidence。
  protected task replay_host_producer_pending(
    rdma_queue_data_attachment attachment,
    rdma_queue_pending_operation pending,
    rdma_queue_cursor_snapshot next,
    output rdma_status status
  );
    rdma_queue_data_qp_link link;
    rdma_hw_sqe_model sgb_model;
    rdma_post_send_req pending_send;
    rdma_doorbell_result db_result;

    status = null;
    if (attachment == null || attachment.runtime == null ||
        pending == null || next == null) begin
      status = bad("host producer recovery input is incomplete",
                   RDMA_SC_RECOVERY_REQUIRED);
      return;
    end
    if (!pending.producer) begin
      status = bad("host producer recovery evidence is not producer-owned",
                   RDMA_SC_INVALID_STATE);
      return;
    end
    if (pending.image == null || pending.image.bytes.size() == 0) begin
      status = bad("producer recovery image is missing", RDMA_SC_INVALID_STATE);
      return;
    end
    status = validate_host_producer_pending_route_epoch(attachment, pending);
    if (status == null || !status.ok()) begin
      if (status == null)
        status = bad("host producer pending route validation returned null status",
                     RDMA_SC_RECOVERY_REQUIRED);
      return;
    end

    // 设计：SGB bytes 不属于 pending.image；只有 SQ request snapshot 仍可证明
    //   原始 SGB route 时才重建并写回 512-byte SGB，否则直接拒绝而不触碰 WQE。
    if (pending.kind == RDMA_QUEUE_RUNTIME_SQ &&
        pending.request_snapshot != null &&
        $cast(pending_send, pending.request_snapshot) &&
        pending_send.sgb_iova.value != 0) begin
      link = null;
      if (pending.queue_h != null &&
          qp_links.exists(value_ops::identity_key(pending.queue_h)))
        link = qp_links[value_ops::identity_key(pending.queue_h)];
      if (link == null) begin
        status = bad("SQ SGB recovery QP route is unavailable",
                     RDMA_SC_INVALID_STATE);
        return;
      end
      status = make_sqe(pending_send, link, pending.cursor, sgb_model);
      if (status == null) begin
        status = bad("SQ SGB recovery model construction returned null status",
                     RDMA_SC_RECOVERY_REQUIRED);
        return;
      end
      if (!status.ok()) return;
      status = write_sgb_and_verify(link, sgb_model, pending.cursor,
                                    pending.image);
      if (status == null)
        status = bad("SQ SGB recovery write returned null status",
                     RDMA_SC_RECOVERY_REQUIRED);
      if (!status.ok()) begin
        void'(attachment.runtime.record_recovery_failure(
          RDMA_QUEUE_MMIO_NO_SUBMIT));
        return;
      end
    end
    status = write_and_verify(attachment, pending.entry_offset,
                              pending.image);
    if (status == null)
      status = bad("host producer recovery write returned null status",
                   RDMA_SC_RECOVERY_REQUIRED);
    if (!status.ok()) begin
      void'(attachment.runtime.record_recovery_failure(
        RDMA_QUEUE_MMIO_NO_SUBMIT));
      return;
    end
    submit_producer_doorbell(pending.queue_h, pending.kind, pending.cursor,
                             next,
                             pending.kind == RDMA_QUEUE_RUNTIME_SQ ?
                             pending.image : null,
                             attachment.local_id, db_result, status);
    if (status == null)
      status = bad("host producer recovery doorbell returned null status",
                   RDMA_SC_RECOVERY_REQUIRED);
    if (!status.ok()) begin
      void'(attachment.runtime.record_recovery_failure(
        RDMA_QUEUE_MMIO_AMBIGUOUS));
      return;
    end
    status = attachment.runtime.enable_recovery_commit();
    if (status == null)
      status = bad("host producer recovery commit gate returned null status",
                   RDMA_SC_RECOVERY_REQUIRED);
    if (!status.ok()) return;
    status = commit_host_producer_ledger(
      attachment, pending.cursor, pending.request_snapshot, pending.wr_id,
      pending.signaled, pending.image);
    if (status == null)
      status = bad("host producer recovery commit returned null status",
                   RDMA_SC_RECOVERY_REQUIRED);
    if (!status.ok()) begin
      void'(attachment.runtime.record_recovery_failure(
        RDMA_QUEUE_MMIO_SUCCESS));
      return;
    end
    status = attachment.runtime.complete_recovery_retry();
    if (status == null)
      status = bad("host producer recovery completion returned null status",
                   RDMA_SC_RECOVERY_REQUIRED);
  endtask

  // 设计说明：device-producer recovery 的 DMA 方向、reservation authority、readback
  // 和 producer commit 与 host-producer/consumer recovery 不共享副作用阶段；单独的
  // task 让 device image 只能通过 DEVICE_WRITE 重放，并把 reservation/route/epoch
  // 快照校验保持在同一 recovery owner 内。
  // 功能：replay_device_producer_pending 校验 detached device-producer evidence，向
  //   device backing 重放冻结 image，回读验证后提交原 cursor 并完成 recovery retry。
  // 输入/输出及副作用：attachment、pending 为只读借用输入，status 为输出；成功时
  //   访问 device backing、更新 pending write-attempt marker、提交 runtime device
  //   reservation 并结束 recovery，task 不取得 attachment、mapping 或 backing 所有权。
  // 失败/边界：pending/runtime/route/epoch/reservation/identity/geometry 不完整、
  //   image copy、device write/readback、commit gate、producer commit 或 completion
  //   返回 null/非成功时立即停止；写入、回读或 commit 失败均保留对应
  //   `NO_SUBMIT`/`NOT_APPLICABLE` recovery evidence，不能推进新 cursor 或静默改用
  //   host-write 方向。
  protected task replay_device_producer_pending(
    rdma_queue_data_attachment attachment,
    rdma_queue_pending_operation pending,
    output rdma_status status
  );
    rdma_queue_pending_operation device_pending;
    rdma_queue_cursor_snapshot current_device_reservation;
    rdma_route_key_t runtime_route;
    rdma_reset_epoch_t runtime_epoch;
    bit runtime_route_valid;
    bit runtime_epoch_valid;
    bit reservation_valid;
    bit backend_write_started;
    byte data[];
    byte readback[];
    rdma_status local_status;

    status = null;
    if (attachment == null || pending == null) begin
      status = bad("device producer recovery attachment/evidence is null",
                   RDMA_SC_INVALID_STATE);
      return;
    end

    device_pending = null;
    current_device_reservation = null;
    reservation_valid = 1'b0;
    runtime_route = '0;
    runtime_route_valid = 1'b0;
    runtime_epoch = '0;
    runtime_epoch_valid = 1'b0;
    status = attachment.runtime.query_pending(device_pending);
    if (status == null || !status.ok() || device_pending == null) begin
      status = status == null ?
        bad("device pending query returned null status",
            RDMA_SC_RECOVERY_REQUIRED) : status;
      return;
    end
    status = attachment.runtime.query_route_epoch(
      runtime_route, runtime_route_valid, runtime_epoch,
      runtime_epoch_valid);
    if (status == null || !status.ok() || !runtime_route_valid ||
        !runtime_epoch_valid) begin
      status = status == null ?
        bad("device recovery route/epoch query failed",
            RDMA_SC_RECOVERY_REQUIRED) : status;
      return;
    end
    status = attachment.runtime.query_device_reservation(
      reservation_valid, current_device_reservation);
    if (status == null || !status.ok()) begin
      status = status == null ?
        bad("device recovery reservation query failed",
            RDMA_SC_RECOVERY_REQUIRED) : status;
      return;
    end
    // 设计：pending 与 attachment 的 queue handle 是 device reservation 的双方
    // authority；reservation/status/null 门禁先完成，再由完整 incarnation 比较和
    // route/epoch 校验决定能否触碰 device backing，身份失配继续保留 recovery evidence。
    if (!reservation_valid || current_device_reservation == null ||
        device_pending.queue_h == null || attachment.queue_h == null ||
        !value_ops::pending_queue_handle_matches_attachment(device_pending, attachment) ||
        device_pending.kind != attachment.kind ||
        !device_pending.device_producer || device_pending.cursor == null ||
        device_pending.next_cursor == null || device_pending.image == null ||
        device_pending.entry_size != attachment.entry_size ||
        device_pending.entry_size == 0 ||
        !value_ops::pending_route_epoch_matches(
          device_pending, runtime_route, runtime_route_valid,
          runtime_epoch, runtime_epoch_valid) ||
        !attachment.runtime.reservation_matches(device_pending.cursor) ||
        !value_ops::same_cursor_value(current_device_reservation,
                           device_pending.cursor) ||
        device_pending.entry_offset !=
          longint'(device_pending.cursor.index) * device_pending.entry_size) begin
      status = bad("device pending authority or reservation is stale",
                   RDMA_SC_RECOVERY_REQUIRED);
      return;
    end
    status = copy_image_bytes(device_pending.image, data);
    if (status == null || !status.ok()) begin
      status = status == null ?
        bad("device recovery image copy returned null status",
            RDMA_SC_RECOVERY_REQUIRED) : status;
      return;
    end
    readback = new[0];
    backend_write_started = 1'b0;
    status = attachment.access.write_device(
      device_pending.entry_offset, data, backend_write_started);
    if (status == null || !status.ok() || !backend_write_started) begin
      if (status == null)
        status = bad("device recovery write returned null status",
                     RDMA_SC_RECOVERY_REQUIRED);
      local_status = attachment.runtime.record_recovery_failure(
        backend_write_started ? RDMA_QUEUE_MMIO_NOT_APPLICABLE :
                                RDMA_QUEUE_MMIO_NO_SUBMIT);
      if (local_status == null || !local_status.ok())
        status = bad("device recovery write evidence could not be retained",
                     RDMA_SC_RECOVERY_REQUIRED);
      return;
    end
    // 设计：preflight/cancel fallback 生成的 pending 可能尚未带有 attempted-write
    // 位；只有 write_device 明确报告已进入 backend 后才标记，避免 retry 把未尝试
    // 的 device write 误判成可提交。
    if (!device_pending.device_write_attempted) begin
      local_status = attachment.runtime.mark_pending_device_write_attempted();
      if (local_status == null || !local_status.ok()) begin
        status = local_status == null ?
          bad("device recovery write-attempt evidence failed",
              RDMA_SC_RECOVERY_REQUIRED) : local_status;
        return;
      end
    end
    status = attachment.access.read(device_pending.entry_offset,
                                    device_pending.image.length, readback);
    if (status == null || !status.ok() ||
        readback.size() != data.size()) begin
      if (status == null)
        status = bad("device recovery read returned null status",
                     RDMA_SC_RECOVERY_REQUIRED);
      else if (status.ok())
        status = bad("device recovery readback length differs",
                     RDMA_SC_RECOVERY_REQUIRED);
      local_status = attachment.runtime.record_recovery_failure(
        RDMA_QUEUE_MMIO_NOT_APPLICABLE);
      if (local_status == null || !local_status.ok())
        status = bad("device recovery read failure evidence could not be retained",
                     RDMA_SC_RECOVERY_REQUIRED);
      return;
    end
    foreach (data[i]) begin
      if (readback[i] !== data[i]) begin
        status = bad("device recovery readback mismatch",
                     RDMA_SC_RECOVERY_REQUIRED);
        local_status = attachment.runtime.record_recovery_failure(
          RDMA_QUEUE_MMIO_NOT_APPLICABLE);
        if (local_status == null || !local_status.ok())
          status = bad("device recovery mismatch evidence could not be retained",
                       RDMA_SC_RECOVERY_REQUIRED);
        return;
      end
    end
    status = attachment.runtime.enable_recovery_commit();
    if (status == null || !status.ok()) begin
      status = status == null ?
        bad("device recovery commit gate returned null status",
            RDMA_SC_RECOVERY_REQUIRED) : status;
      return;
    end
    status = attachment.runtime.commit_device_producer(
      device_pending.cursor);
    if (status == null || !status.ok()) begin
      if (status == null)
        status = bad("device recovery producer commit returned null status",
                     RDMA_SC_RECOVERY_REQUIRED);
      local_status = attachment.runtime.record_recovery_failure(
        RDMA_QUEUE_MMIO_NOT_APPLICABLE);
      if (local_status == null || !local_status.ok())
        status = bad("device recovery commit evidence could not be retained",
                     RDMA_SC_RECOVERY_REQUIRED);
      return;
    end
    status = attachment.runtime.complete_recovery_retry();
    if (status == null)
      status = bad("device recovery completion returned null status",
                   RDMA_SC_RECOVERY_REQUIRED);
  endtask

  // 设计说明：consumer recovery 的 route、reset epoch、completion target 和 WQ
  // attachment 是后续 shadow/doorbell、CQ commit 与 WQE release 的共同 authority。
  // 这些只读查询必须先于任何 backing、MMIO 或 runtime ledger mutation 完成；因此
  // 把它们集中在 preflight helper 中，并让 caller 继续持有冻结的 next cursor。
  // 功能：validate_consumer_recovery_authority 校验 consumer pending 的 queue kind、
  //   cursor/image geometry、route/epoch 与 CQ completion target；CQ 路径解析完整
  //   routed QP、SQ/RQ/SRQ route、WQ attachment 和未完成 release range，事件路径
  //   拒绝携带 CQ-only evidence，成功时返回后续 recovery 所需的 engine-owned 借用引用。
  // 输入/输出及副作用：attachment、pending 为 caller 已取得的只读借用输入；link、
  //   wqe_attachment 先置空，成功时分别输出 QP route 与 WQ attachment 的非拥有引用。
  //   函数只查询 runtime route/epoch、qp_links 与 attachments，并在未完成 CQ→WQ release
  //   时调用 validate_release_range()；不修改 pending、runtime、cursor、ledger、backing
  //   或 MMIO，也不取得外部对象生命周期所有权。
  // 失败/边界：attachment/runtime、entry geometry、pending evidence 不完整返回
  //   INVALID_STATE；route/epoch 查询失败或 stale 返回原 status 或 STALE_GENERATION；
  //   CQ completion target、QP incarnation、SQ/RQ/SRQ route、WQ attachment 或
  //   validate_release_range() 返回 null/非成功时返回既有错误码；CEQ/AEQ 携带 CQ-only
  //   evidence 同样拒绝。helper 不调用 pending_next_cursor，调用方必须在 branch
  //   dispatch 前保留 next-cursor 连续性和 null attachment/pending/next 门禁。
  protected function rdma_status validate_consumer_recovery_authority(
    rdma_queue_data_attachment attachment,
    rdma_queue_pending_operation pending,
    output rdma_queue_data_qp_link link,
    output rdma_queue_data_attachment wqe_attachment
  );
    rdma_status status;
    rdma_route_key_t runtime_route;
    rdma_reset_epoch_t runtime_epoch;
    bit runtime_route_valid;
    bit runtime_epoch_valid;
    string qp_key;

    link = null;
    wqe_attachment = null;

    if (attachment == null || pending == null)
      return value_ops::make_status_nonfatal(
        RDMA_SC_INVALID_STATE,
        "consumer recovery attachment/evidence is null");
    if (attachment.runtime == null || attachment.entry_size == 0 ||
        pending.entry_size == 0 || pending.cursor == null ||
        pending.next_cursor == null)
      return value_ops::make_status_nonfatal(
        RDMA_SC_INVALID_STATE,
        "consumer recovery runtime or cursor geometry is incomplete");
    if (attachment.runtime.depth == 0 ||
        pending.cursor.index >= attachment.runtime.depth ||
        pending.next_cursor.index >= attachment.runtime.depth ||
        pending.cursor.index >
          64'hffff_ffff_ffff_ffff / pending.entry_size)
      return value_ops::make_status_nonfatal(
        RDMA_SC_INVALID_STATE,
        "consumer recovery cursor geometry is invalid");

    // 中文设计：consumer pending 在 admission 时已冻结完整 identity、route/epoch
    // 和 completion target。recovery 只核对这些值并选择现有 attachment，禁止重新
    // decode CQE 或从当前 codec 推导 WQ 方向；证据不完整时不执行 route/release 副作用。
    if (!(attachment.kind inside {RDMA_QUEUE_RUNTIME_CQ,
                                  RDMA_QUEUE_RUNTIME_CEQ,
                                  RDMA_QUEUE_RUNTIME_AEQ}) ||
        pending.kind != attachment.kind || pending.producer ||
        pending.device_producer || attachment.queue_h == null ||
        pending.queue_h == null ||
        !value_ops::pending_queue_handle_matches_attachment(pending, attachment) ||
        pending.image == null || pending.failure_status == null ||
        pending.entry_size != attachment.entry_size ||
        pending.image.length != pending.entry_size ||
        pending.image.bytes.size() != pending.image.length ||
        pending.entry_offset !=
          longint'(pending.cursor.index) * pending.entry_size) begin
      return value_ops::make_status_nonfatal(
        RDMA_SC_INVALID_STATE,
        "consumer recovery pending evidence is incomplete");
    end
    runtime_route = '0;
    runtime_route_valid = 1'b0;
    runtime_epoch = '0;
    runtime_epoch_valid = 1'b0;
    status = attachment.runtime.query_route_epoch(
      runtime_route, runtime_route_valid, runtime_epoch, runtime_epoch_valid);
    if (status == null || !status.ok() ||
        !value_ops::pending_route_epoch_matches(
          pending, runtime_route, runtime_route_valid,
          runtime_epoch, runtime_epoch_valid)) begin
      if (status == null || status.ok())
        status = value_ops::make_status_nonfatal(
          RDMA_SC_STALE_GENERATION,
          "consumer recovery route or reset epoch is stale");
      return status;
    end

    if (attachment.kind == RDMA_QUEUE_RUNTIME_CQ) begin
      if (!pending.completion_target_valid ||
          !(pending.completion_wq_kind inside {RDMA_QUEUE_RUNTIME_SQ,
                                               RDMA_QUEUE_RUNTIME_RQ,
                                               RDMA_QUEUE_RUNTIME_SRQ}) ||
          pending.routed_qp_h == null ||
          pending.routed_qp_h.kind != RDMA_RESOURCE_QP) begin
        return value_ops::make_status_nonfatal(
          RDMA_SC_INVALID_STATE,
          "CQ recovery completion target is incomplete");
      end
      qp_key = value_ops::identity_key(pending.routed_qp_h);
      // 设计：CQ recovery 的 routed_qp_h 是 completion target authority；key、link、
      // qp_h 的空值门禁先于完整 identity 比较，失配继续保留 STALE_GENERATION，
      // 不能进入后续 WQ route 或 release 副作用。
      if (qp_key == "" || !qp_links.exists(qp_key) ||
          qp_links[qp_key] == null || qp_links[qp_key].qp_h == null ||
          !value_ops::same_handle_instance(qp_links[qp_key].qp_h,
                                pending.routed_qp_h)) begin
        return value_ops::make_status_nonfatal(
          RDMA_SC_STALE_GENERATION,
          "CQ recovery routed QP identity is stale");
      end
      link = qp_links[qp_key];
      // 设计：pending.queue_h 已确认非空；SQ/RQ/SRQ 分支按 qp_link 的发送/接收方向
      // 选择对应 WQ attachment，并保留 SRQ presence 门禁。身份失配只走原错误路径，
      // 不改变 lookup_attachment、release 或 completion 顺序。
      if (pending.completion_wq_kind == RDMA_QUEUE_RUNTIME_SQ) begin
        if (!value_ops::qp_link_cq_route_matches(link, pending.queue_h, 1'b0)) begin
          return value_ops::make_status_nonfatal(
            RDMA_SC_INVALID_STATE,
            "CQ recovery SQ route does not target the pending CQ");
        end
        status = lookup_attachment(
          link.qp_h, RDMA_QUEUE_RUNTIME_SQ, wqe_attachment);
      end
      else if (pending.completion_wq_kind == RDMA_QUEUE_RUNTIME_RQ) begin
        if (!value_ops::qp_link_cq_route_matches(link, pending.queue_h, 1'b1) ||
            link.srq_h != null) begin
          return value_ops::make_status_nonfatal(
            RDMA_SC_INVALID_STATE,
            "CQ recovery RQ route does not target the pending CQ");
        end
        status = lookup_attachment(
          link.qp_h, RDMA_QUEUE_RUNTIME_RQ, wqe_attachment);
      end
      else begin
        if (!value_ops::qp_link_cq_route_matches(link, pending.queue_h, 1'b1) ||
            link.srq_h == null) begin
          return value_ops::make_status_nonfatal(
            RDMA_SC_INVALID_STATE,
            "CQ recovery SRQ route does not target the pending CQ");
        end
        status = lookup_attachment(
          link.srq_h, RDMA_QUEUE_RUNTIME_SRQ, wqe_attachment);
      end
      if (status == null || !status.ok() || wqe_attachment == null ||
          wqe_attachment.runtime == null ||
          wqe_attachment.kind != pending.completion_wq_kind) begin
        if (status == null || status.ok())
          status = value_ops::make_status_nonfatal(
            RDMA_SC_INVALID_STATE,
            "CQ recovery WQ attachment is unavailable");
        return status;
      end
      if (!pending.completion_released) begin
        status = wqe_attachment.runtime.validate_release_range(
          pending.completion_index, pending.completion_wrap);
        if (status == null || !status.ok()) begin
          if (status == null)
            status = value_ops::make_status_nonfatal(
              RDMA_SC_INVALID_STATE,
              "CQ recovery release validation returned null status");
          return status;
        end
      end
    end
    else if (pending.completion_target_valid || pending.routed_qp_h != null ||
             pending.cq_consumer_committed || pending.completion_released) begin
      return value_ops::make_status_nonfatal(
        RDMA_SC_INVALID_STATE,
        "event recovery carries CQ-only completion evidence");
    end

    return status;
  endfunction

  // 设计说明：consumer recovery 的 CQ→WQ release 必须在 CQ runtime 持有
  // begin marker 后按单向 CQ→WQ 锁序执行；release 完成前不能让 recovery task
  // 继续推进 completion，也不能让失败路径遗留活动 gate。将 begin/release/finish
  // 和失败 evidence 放在同一 task，避免 retry caller 漏掉 bilateral finish。
  // 功能：release_consumer_pending_wqe 使用 pending 冻结的 completion index/wrap，
  //   在已完成 CQ consumer commit 后释放 routed WQ 的连续 ledger range，并把失败
  //   的 MMIO evidence/status 留在 recovery runtime；成功时只返回可继续 completion
  //   的 status，不重新解析 CQE 或推导 WQ 方向。
  // 输入/输出及副作用：attachment、pending、wqe_attachment 是 caller 已完成
  //   authority 校验的非拥有借用；status 为输出，pending.failure_status 作为预建
  //   noalloc continuation slot。成功可能标记 runtime.completion_released 并推进
  //   WQ CI/used；失败保持 pending evidence，不取得 CQ/WQ/runtime 生命周期所有权。
  // 失败/边界：null runtime/attachment/pending 或缺失 failure_status 返回
  //   INVALID_STATE；begin gate 拒绝时原样返回其 status；release 或 finish 任一步失败
  //   都停止，finish 失败时仍以 noalloc status 收束；WQ release 失败记录 NO_SUBMIT
  //   （shadow）或 SUCCESS（doorbell）对应的 recovery evidence，绝不重复释放同一 range。
  protected task release_consumer_pending_wqe(
    rdma_queue_data_attachment attachment,
    rdma_queue_pending_operation pending,
    rdma_queue_data_attachment wqe_attachment,
    output rdma_status status
  );
    execute_consumer_wqe_release(
      attachment, pending, wqe_attachment, null, 1'b1,
      pending == null ? 0 : pending.completion_index,
      pending == null ? 1'b0 : pending.completion_wrap,
      pending != null && pending.consumer_shadow_required ?
        RDMA_QUEUE_MMIO_NO_SUBMIT : RDMA_QUEUE_MMIO_SUCCESS,
      "CQ recovery", status);
  endtask

  // 设计说明：consumer recovery 同时包含 CQ route 解析、CQC shadow/doorbell 续做、
  // CQ consumer commit 和可选 WQE release；这些阶段共享 completion authority 与锁序，
  // 不能与 producer DMA recovery 混用。helper 保留 caller 冻结的 next cursor 和
  // pending evidence，集中维护 CQ→WQ 的副作用顺序。
  // doorbell evidence/CI commit 复用 live 的公共步骤，但是否跳过已完成阶段仍只在这里判断。
  // 功能：replay_consumer_pending 校验 consumer pending 的 queue/route/epoch/completion
  //   authority，按 MMIO evidence 续做 shadow 或 consumer doorbell，提交 CQ cursor，
  //   释放 CQ 对应 WQE，并完成 consumer recovery。
  // 输入/输出及副作用：attachment、pending、next 为已通过 caller cursor 校验的借用
  //   输入，status 为输出；成功时可能访问 context/backing、scheduler、runtime ledger
  //   和 WQ release，但不取得 attachment、QP、SRQ 或 Host-memory 生命周期所有权。
  // 失败/边界：consumer evidence、route/epoch、completion target、WQ attachment、
  //   shadow/doorbell、commit、release 或 completion 任一查询返回 null/非成功时立即
  //   停止并保留 pending；AMBIGUOUS 或不安全 MMIO evidence 不重放，release gate 失败
  //   不重复释放同一 WQE range。
  protected task replay_consumer_pending(
    rdma_queue_data_attachment attachment,
    rdma_queue_pending_operation pending,
    rdma_queue_cursor_snapshot next,
    output rdma_status status
  );
    bit doorbell_completed;
    rdma_queue_data_qp_link link;
    rdma_queue_data_attachment wqe_attachment;
    rdma_doorbell_desc prepared_db_desc;
    rdma_status noalloc_status;

    status = null;
    if (attachment == null || pending == null || next == null) begin
      status = bad("consumer recovery attachment/evidence/cursor is null",
                   RDMA_SC_INVALID_STATE);
      return;
    end

    status = validate_consumer_recovery_authority(
      attachment, pending, link, wqe_attachment);
    if (status == null || !status.ok())
      return;

    // 中文设计：legacy NO_SUBMIT 在 scheduler 入口前预建 descriptor/status；CQC
    // shadow NO_SUBMIT 只写冻结的 context host-memory，不创建 doorbell descriptor；
    // SUCCESS 复用 detached pending 的 caller-owned failure_status continuation slot。
    prepared_db_desc = null;
    noalloc_status = null;
    if (pending.consumer_shadow_required) begin
      if (pending.mmio_evidence != RDMA_QUEUE_MMIO_NO_SUBMIT ||
          pending.kind != RDMA_QUEUE_RUNTIME_CQ) begin
        status = value_ops::make_status_nonfatal(
          RDMA_SC_RECOVERY_REQUIRED,
          "CQC shadow recovery evidence is not safely replayable");
        return;
      end
      noalloc_status = pending.failure_status;
      if (!pending.consumer_shadow_published) begin
        // 只有尚未完成的 shadow 阶段允许再次进入 publication seam。已发布的 shadow
        // 是 detached pending 的不可变事实；重放时直接恢复 continuation status，避免
        // 重复触碰 context backing 或让测试/适配 seam 误以为又发生一次硬件写入。
        publish_cqc_shadow(attachment, pending, status);
        if (status == null || !status.ok())
          return;
      end
      else if (!value_ops::set_status_noalloc(noalloc_status, RDMA_SC_OK, "")) begin
        status = value_ops::make_status_nonfatal(
          RDMA_SC_RESOURCE_EXHAUSTED,
          "published CQC shadow continuation status is unavailable");
        return;
      end
      status = noalloc_status;
    end
    else if (pending.mmio_evidence == RDMA_QUEUE_MMIO_NO_SUBMIT) begin
      status = prepare_consumer_doorbell(
        attachment, next, link, prepared_db_desc, noalloc_status);
      if (status == null || !status.ok() || prepared_db_desc == null ||
          noalloc_status == null) begin
        if (status == null || status.ok())
          status = value_ops::make_status_nonfatal(
            RDMA_SC_RESOURCE_EXHAUSTED,
            "consumer recovery doorbell preparation is incomplete");
        return;
      end
      submit_consumer_doorbell_recorded(
        attachment, next, link, prepared_db_desc, noalloc_status,
        CONSUMER_DIAG_REPLAY, doorbell_completed, status);
      if (!doorbell_completed)
        return;
      status = noalloc_status;
    end
    else if (pending.mmio_evidence == RDMA_QUEUE_MMIO_SUCCESS) begin
      noalloc_status = pending.failure_status;
      if (!value_ops::set_status_noalloc(noalloc_status, RDMA_SC_OK, "")) begin
        status = value_ops::make_status_nonfatal(
          RDMA_SC_RESOURCE_EXHAUSTED,
          "consumer recovery continuation status is unavailable");
        return;
      end
      status = noalloc_status;
    end
    else begin
      status = value_ops::make_status_nonfatal(
        RDMA_SC_RECOVERY_REQUIRED,
        "consumer recovery doorbell evidence is not safely replayable");
      return;
    end

    if (!pending.consumer_committed) begin
      if (!commit_consumer_cursor_recorded(
            attachment, pending.cursor, noalloc_status,
            pending.consumer_shadow_required ? RDMA_QUEUE_MMIO_NO_SUBMIT :
                                               RDMA_QUEUE_MMIO_SUCCESS,
            CONSUMER_DIAG_REPLAY, status))
        return;
    end

    if (attachment.kind == RDMA_QUEUE_RUNTIME_CQ &&
        !pending.completion_released) begin
      release_consumer_pending_wqe(
        attachment, pending, wqe_attachment, status);
      if (status == null || !status.ok())
        return;
    end
    if (!attachment.runtime.complete_consumer_recovery_noalloc(
          1'b0, noalloc_status)) begin
      status = noalloc_status;
      return;
    end
    status = noalloc_status;
  endtask

  // 设计说明：仅当原事务确定没有到达 MMIO，或调用方已经明确确认可重放时才执行
  // detached transaction。所有副作用和 ledger transition 完成前，runtime 保持
  // RECOVERY_REQUIRED，防止同一 reservation 被并发消费。
  // 功能：replay_pending 按 pending 的 producer/device-producer/consumer 阶段重放
  //   必要写入、doorbell 或 cursor commit，并保持已完成阶段的幂等性。
  // 输入/输出及副作用：attachment、pending 为输入，status 为输出；可能访问 backing
  //   与 runtime recovery 状态，但不接管 attachment、mapping 或 pending 的所有权。
  // 失败/边界：authority、cursor、route/epoch、readback 或下游提交不一致时返回明确
  //   非成功 status 并保留 pending；没有 caller confirmation 时不得重放 ambiguous MMIO。
  protected task replay_pending(
    rdma_queue_data_attachment attachment,
    rdma_queue_pending_operation pending,
    output rdma_status status
  );
    rdma_queue_cursor_snapshot next;

    status = null;
    if (attachment == null || pending == null) begin
      status = bad("pending recovery attachment/evidence is null",
                   RDMA_SC_INVALID_STATE);
      return;
    end
    status = pending_next_cursor(attachment, pending, next);
    if (!status.ok()) return;

    // 设计说明：device-produced CQ/CEQ/AEQ recovery 必须先于 host producer/
    // consumer 分支处理；专用 helper 保留 reservation、route/epoch、DEVICE_WRITE
    // 和 readback 的完整阶段，caller 只负责按 evidence 类型选择 recovery owner。
    if (pending.device_producer) begin
      replay_device_producer_pending(attachment, pending, status);
      return;
    end

    if (pending.producer) begin
      replay_host_producer_pending(attachment, pending, next, status);
      return;
    end

    replay_consumer_pending(attachment, pending, next, status);
    return;
  endtask

  // 设计说明：reservation-only recovery 没有可重放的 image，因而不能沿用
  // claimed pending 的 retry 流程。该阶段必须先对所有 matching attachment
  // 查询 reservation，再按 cardinality 决定是否允许唯一的 abort；把查询、
  // 多匹配判定和 detach 边界集中在这里，避免 recover_queue 在“无 pending”分支
  // 中混入 runtime 状态迁移或提前删除 attachment 索引。
  // 功能：resolve_reservation_only_recovery 扫描目标 queue 的 reservation-only
  //   candidate，确认唯一 reservation 后按 action 执行 abort/detach，并报告调用方
  //   是否已经处理了一个 reservation-only recovery。
  // 输入/输出及副作用：queue_h、action 为输入；handled 先置零，发现唯一
  //   reservation 时置一；status 为输出。函数只借用 engine attachment/runtime，
  //   成功 abort 可能调用 detach_recovery_transaction 删除 matching attachment，
  //   不释放外部 mapping、backing 或 lifecycle 所有权。
  // 失败/边界：candidate query 返回 null/非成功、多个 valid reservation、retry
  //   action 缺少 image、detach 返回 null/失败或 queue/action 不完整时返回明确的
  //   RECOVERY_REQUIRED/INVALID_STATE；任何失败都不删除 candidate。没有任何
  //   reservation 时返回成功且 handled=0，由 recover_queue 保留“无 pending”首错。
  protected task resolve_reservation_only_recovery(
    rdma_handle queue_h,
    rdma_queue_recovery_action_e action,
    output bit handled,
    output rdma_status status
  );
    rdma_queue_data_attachment candidates[$];
    rdma_queue_data_attachment candidate;
    rdma_queue_data_attachment reservation_found;
    rdma_queue_cursor_snapshot reservation;
    rdma_queue_cursor_snapshot reservation_match;
    bit reservation_valid;
    int unsigned reservation_matches;

    handled = 1'b0;
    status = null;
    reservation = null;
    reservation_match = null;
    reservation_found = null;
    reservation_matches = 0;

    if (queue_h == null)
      begin
        status = bad("reservation-only recovery queue handle is null",
                     RDMA_SC_INVALID_STATE);
        return;
      end
    if (!(action inside {RDMA_QUEUE_RECOVERY_RETRY_PENDING,
                         RDMA_QUEUE_RECOVERY_ABORT_AND_DETACH})) begin
      status = bad("reservation-only recovery action is invalid",
                   RDMA_SC_INVALID_STATE);
      return;
    end

    collect_reservation_only_candidates(queue_h, candidates);
    foreach (candidates[i]) begin
      candidate = candidates[i];
      if (candidate == null || candidate.runtime == null)
        continue;
      reservation_valid = 1'b0;
      reservation = null;
      status = candidate.runtime.query_device_reservation(
        reservation_valid, reservation);
      if (status == null || !status.ok()) begin
        status = status == null ?
          bad("reservation-only recovery query returned null status",
              RDMA_SC_RECOVERY_REQUIRED) : status;
        return;
      end
      if (reservation_valid && reservation != null) begin
        reservation_matches++;
        if (reservation_found == null) begin
          reservation_found = candidate;
          reservation_match = reservation;
        end
      end
    end

    if (reservation_matches > 1) begin
      status = bad("queue has multiple pending reservations",
                   RDMA_SC_INVALID_STATE);
      return;
    end
    if (reservation_found == null) begin
      // no-reservation 是 caller 继续执行“无 pending”首错的正常分支；使用
      // non-fatal status 避免一次 hostile factory 注入改变该分支的诊断顺序。
      status = rdma_status::make_direct(RDMA_SC_OK);
      return;
    end

    handled = 1'b1;
    if (action != RDMA_QUEUE_RECOVERY_ABORT_AND_DETACH) begin
      status = bad("reservation-only recovery cannot retry without image",
                   RDMA_SC_RECOVERY_REQUIRED);
      return;
    end
    status = detach_recovery_transaction(
      queue_h, reservation_found, reservation_match);
    if (status == null) begin
      status = bad("reservation-only recovery abort could not cancel",
                   RDMA_SC_RECOVERY_REQUIRED);
      return;
    end
    if (!status.ok())
      return;
  endtask

  // 功能：recover_queue 定位 queue 的 claimed/unclaimed recovery，执行 abort，
  //   或把 caller-confirmed retry 先交给 runtime 授权，再重放尚未完成的事务阶段。
  // 输入/输出及副作用：queue_h、action、caller_confirmed_no_submit（输入）选择
  //   recovery 对象与动作，status（输出）返回最终阶段结果；retry 可能访问 backing、
  //   doorbell 和 runtime ledger，abort 可能删除 attachment，但不接管外部 mapping。
  // 失败/边界：句柄/证据不完整、非法 action、未确认 retry、reservation-only 多匹配、
  //   无 image 的 reservation-only retry、AMBIGUOUS MMIO、runtime 的 reservation/state/
  //   pending 查询或一次性授权返回 null/非成功，以及 replay 任一阶段失败时保留可恢复
  //   evidence；所有 reservation candidate query 完成前不得 detach，只有 runtime enum
  //   gate 可以记录一次性 confirmation。
  task recover_queue(
    rdma_handle queue_h,
    rdma_queue_recovery_action_e action,
    bit caller_confirmed_no_submit,
    output rdma_status status
  );
    rdma_queue_data_attachment candidate;
    rdma_queue_data_attachment claimed_found;
    rdma_queue_data_attachment found;
    rdma_queue_pending_operation unclaimed_pending;
    rdma_queue_cursor_snapshot reservation;
    rdma_queue_runtime_state_e runtime_state;
    bit reservation_valid;
    bit reservation_only_handled;
    string key;
    status = ensure_handle(queue_h, queue_h == null ? RDMA_RESOURCE_QP :
                           queue_h.kind);
    if (status == null || !status.ok()) begin
      status = status == null ?
        bad("recovery queue handle validation returned null status",
            RDMA_SC_INVALID_STATE) : status;
      return;
    end
    // 设计说明：action 与 caller confirmation 是 recover_queue 的纯控制面前置条件。
    // 必须在 unclaimed evidence admission、reservation 查询和 runtime handoff 之前
    // 结束判定，避免一个非法动作或未确认 retry 先把 engine-owned evidence 迁移到
    // runtime，随后才返回错误。abort 不需要 caller confirmation；retry 的确认位
    // 只表达本次调用允许继续 recovery，不改变 queue/runtime 的生命周期所有权。
    if (!(action inside {RDMA_QUEUE_RECOVERY_RETRY_PENDING,
                         RDMA_QUEUE_RECOVERY_ABORT_AND_DETACH})) begin
      status = bad("recovery action is invalid");
      return;
    end
    if (action == RDMA_QUEUE_RECOVERY_RETRY_PENDING &&
        !caller_confirmed_no_submit) begin
      status = bad("retry requires caller confirmation");
      return;
    end
    found = null;
    claimed_found = null;
    unclaimed_pending = null;
    reservation = null;
    reservation_valid = 1'b0;
    reservation_only_handled = 1'b0;
    runtime_state = RDMA_QUEUE_RUNTIME_DETACHED;
    key = value_ops::identity_key(queue_h);
    // 设计说明：runtime admission 失败时 evidence 由 engine 的 unclaimed 表保留。
    // retry/abort 必须先尝试把同一 detached pending 安装回原 attachment runtime；
    // 安装成功后 runtime 接管生命周期，表项才可成对删除，安装失败则保持证据不丢失。
    if (key != "" && (unclaimed_device_recoveries.exists(key) ||
                       unclaimed_recovery_attachments.exists(key))) begin
      if (!unclaimed_device_recoveries.exists(key) ||
          unclaimed_device_recoveries[key] == null ||
          !unclaimed_recovery_attachments.exists(key) ||
          unclaimed_recovery_attachments[key] == null) begin
        status = bad("unclaimed recovery evidence pair is incomplete",
                     RDMA_SC_RECOVERY_REQUIRED);
        return;
      end
      found = unclaimed_recovery_attachments[key];
      unclaimed_pending = unclaimed_device_recoveries[key];
      // 设计：unclaimed attachment 是 engine-owned recovery authority；map
      // pair 与 found 的 runtime/handle 空值门禁先完成，身份失配必须硬失败
      // 为 RECOVERY_REQUIRED，保留 evidence，不能继续 admission 或 detach。
      if (found.runtime == null ||
          !value_ops::attachment_matches_queue_identity(found, queue_h)) begin
        status = bad("unclaimed recovery attachment is stale",
                     RDMA_SC_RECOVERY_REQUIRED);
        return;
      end
      status = admit_device_publish_recovery(found, unclaimed_pending);
      if (status == null || !status.ok()) begin
        // admission 仍失败时，retry 必须保留 engine-owned evidence。abort 可以
        // 仅在 runtime 仍 ACTIVE 且 reservation 与该 evidence 完全匹配时取消
        // reservation，然后 detach；这样不会遗留一个不可见的活动 attachment。
        if (action == RDMA_QUEUE_RECOVERY_ABORT_AND_DETACH) begin
          status = found.runtime.query_device_reservation(reservation_valid,
                                                           reservation);
          if (status == null || !status.ok()) begin
            status = status == null ?
              bad("unclaimed recovery reservation query returned null status",
                  RDMA_SC_RECOVERY_REQUIRED) : status;
            return;
          end
          status = found.runtime.query_state(runtime_state);
          if (status == null || !status.ok()) begin
            status = status == null ?
              bad("unclaimed recovery state query returned null status",
                  RDMA_SC_RECOVERY_REQUIRED) : status;
            return;
          end
          if (reservation_valid && reservation != null &&
              runtime_state == RDMA_QUEUE_RUNTIME_ACTIVE &&
              unclaimed_pending.cursor != null &&
              value_ops::same_cursor_value(reservation, unclaimed_pending.cursor)) begin
            status = detach_recovery_transaction(
              queue_h, found, reservation);
            if (status == null) begin
              status = bad("unclaimed recovery abort returned null status",
                           RDMA_SC_RECOVERY_REQUIRED);
              return;
            end
            if (!status.ok()) return;
            unclaimed_device_recoveries.delete(key);
            unclaimed_recovery_attachments.delete(key);
            return;
          end
        end
        status = bad("unclaimed recovery admission is still unavailable",
                     RDMA_SC_RECOVERY_REQUIRED);
        return;
      end
      unclaimed_device_recoveries.delete(key);
      unclaimed_recovery_attachments.delete(key);
    end
    // 设计：unclaimed admission 成功后仍以 engine-owned found 作为第一 authority；
    // helper 只收集 claimed attachment，再由 caller 比较对象身份。这样同一 attachment
    // 的 handoff 只接管一次，而另一个 matching runtime 仍明确返回 INVALID_STATE。
    status = find_claimed_recovery_attachment(queue_h, claimed_found);
    if (status == null || !status.ok()) begin
      status = status == null ?
        bad("claimed recovery attachment scan returned null status",
            RDMA_SC_INVALID_STATE) : status;
      return;
    end
    if (claimed_found != null) begin
      if (found != null && found != claimed_found) begin
        status = bad("queue has multiple pending recovery runtimes",
                     RDMA_SC_INVALID_STATE);
        return;
      end
      found = claimed_found;
    end
    if (found == null) begin
      // cancel 前置路径在还没有完整 pending 时也可能返回 RECOVERY_REQUIRED。
      // 它只能显式 abort：再次 cancel 成功后 detach；retry 没有可重放 image，
      // 必须保持 fail-closed，而不是伪造一笔 publish。
      resolve_reservation_only_recovery(
        queue_h, action, reservation_only_handled, status);
      if (status == null || !status.ok()) begin
        status = status == null ?
          bad("reservation-only recovery resolution returned null status",
              RDMA_SC_RECOVERY_REQUIRED) : status;
        return;
      end
      if (reservation_only_handled)
        return;
      status = bad("queue has no pending recovery", RDMA_SC_INVALID_STATE);
      return;
    end
    if (action == RDMA_QUEUE_RECOVERY_ABORT_AND_DETACH) begin
      status = detach_recovery_transaction(queue_h, found);
      if (status == null || !status.ok()) begin
        status = status == null ?
          bad("recovery abort/detach returned null status",
              RDMA_SC_RECOVERY_REQUIRED) : status;
        return;
      end
      return;
    end
    if (action != RDMA_QUEUE_RECOVERY_RETRY_PENDING) begin
      status = bad("recovery action is invalid");
      return;
    end
    begin
      rdma_queue_pending_operation pending;

      // 中文设计：先取得 detached pending snapshot，再向 runtime 记录一次性
      // confirmation。snapshot/query 可能因 factory、锁或 evidence 缺失失败；把
      // 它放在 recover() 之前可保证这些失败不会留下可被后续路径消费的 retry
      // authorization。runtime.recover() 仍以其锁内的唯一 MMIO enum 做最终
      // 状态校验，随后 replay 只消费已经成功取得的值快照。
      status = found.runtime.query_pending(pending);
      if (status == null || !status.ok()) begin
        status = status == null ?
          bad("runtime recovery pending query returned null status",
              RDMA_SC_RECOVERY_REQUIRED) : status;
        return;
      end
      if (pending == null) begin
        status = bad("runtime recovery pending query returned null evidence",
                     RDMA_SC_RECOVERY_REQUIRED);
        return;
      end
      if (pending.mmio_evidence == RDMA_QUEUE_MMIO_AMBIGUOUS) begin
        status = bad("pending MMIO outcome is ambiguous",
                     RDMA_SC_RECOVERY_REQUIRED);
        return;
      end
      status = found.runtime.recover(
        RDMA_QUEUE_RECOVERY_RETRY_PENDING, caller_confirmed_no_submit);
      if (status == null || !status.ok()) begin
        status = status == null ?
          bad("runtime recovery confirmation returned null status",
              RDMA_SC_RECOVERY_REQUIRED) : status;
        return;
      end
      replay_pending(found, pending, status);
      return;
    end
  endtask

endclass
