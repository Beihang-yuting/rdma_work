// 目录：核心执行层 core/rdma_cq_engine.sv，位于队列数据路径的 CQ facade。
// 职责：提供 CQE poll/publish、CQ resize 与 shared-CQ shadow flush，把 queue-data
//   mutation 委托给共享 engine，并在 facade 边界统一 Function authority。
// 依赖：rdma_queue_data_engine、CQ completion/publish result、Function binding、
//   CQ shadow snapshot 及 CQ codec/adapter 契约。
// 所有权与生命周期：facade 借用 delegate/binding，不拥有 runtime、backing 或 doorbell；
//   自身拥有 configure 时冻结的标量、cloned shared handle 与 flush 缓存快照。

// 设计说明：facade 提供 typed API，mutation 权威仍在唯一 queue-data engine；
// 非拥有 delegate 与冻结的 Function 坐标阻断 reset/rebind 后的旧 facade。
class rdma_cq_engine extends rdma_queue_facade;
  `uvm_object_utils(rdma_cq_engine)

  protected bit shared_configured;
  protected rdma_handle shared_cq_h;
  protected rdma_handle shared_completion_qp_h;
  protected rdma_transport_e shared_transport;
  protected longint unsigned shared_function_uid;
  protected int unsigned shared_generation;
  protected rdma_reset_epoch_t shared_reset_epoch;
  protected int unsigned shadow_sq_ci;
  protected int unsigned shadow_rq_ci;
  protected bit [1:0] shadow_arm_state;
  protected longint unsigned shadow_sequence;
  protected bit shadow_flushed;
  protected rdma_cq_shadow_snapshot flushed_shadow;
  int unsigned shadow_flush_count;

  // 功能：把 CQ poll 转交给唯一 delegate，作为 facade 与共享 engine 的测试 seam。
  // 输入/输出及副作用：cq_h、timeout 输入；result/status 输出，均来自 delegate.poll_cqe。
  // 失败/边界：调用方须先确认 delegate 非空且 authority 有效；null/failure 由公开 poll_cqe 归一化。
  protected virtual task call_delegate_poll_cqe(
    rdma_handle cq_h,
    time timeout,
    output rdma_queue_completion_result result,
    output rdma_status status
  );
    delegate.poll_cqe(cq_h, timeout, result, status);
  endtask

  // 功能：把 CQE publish 转交给唯一 delegate，facade 不拥有 runtime/CQ backing。
  // 输入/输出及副作用：cq_h/model 输入；result/status 输出；预留、写 backing、提交 PI 均在 delegate。
  // 失败/边界：须先通过配置/authority 门禁；null/failure 由公开 publish_cqe 归一化并丢弃 result。
  protected virtual task call_delegate_publish_cqe(
    rdma_handle cq_h,
    rdma_hw_cqe_model model,
    output rdma_queue_device_publish_result result,
    output rdma_status status
  );
    delegate.publish_cqe(cq_h, model, result, status);
  endtask

  // 功能：把 CQ resize 转交给唯一 delegate。
  // 输入/输出及副作用：cq_h/new_depth/new_cqe_bytes 输入；返回 delegate 状态，副作用均在 delegate。
  // 失败/边界：须先完成 configure；delegate 返回 null 由公开 resize 归一化为 INVALID_STATE。
  protected virtual function rdma_status call_delegate_resize_cq(
    rdma_handle cq_h,
    int unsigned new_depth,
    int unsigned new_cqe_bytes
  );
    return delegate.resize_cq(cq_h, new_depth, new_cqe_bytes);
  endfunction

  // 功能：创建未配置的 CQ facade（普通入口与 shared-shadow 均未配置），不分配 CQ backing。
  // 输入/输出及副作用：name 输入；清空 shared handle、shadow 与 flush 缓存，transport 置为 RC。
  // 失败/边界：configure 前 poll/publish/resize 返回 INVALID_STATE；configure_shared 只启用 flush_shadow。
  function new(string name = "rdma_cq_engine");
    super.new(name, "CQ");
    shared_configured = 1'b0;
    shared_cq_h = null;
    shared_completion_qp_h = null;
    shared_transport = RDMA_TRANSPORT_RC;
    shared_function_uid = 0;
    shared_generation = 0;
    shared_reset_epoch = 0;
    shadow_sq_ci = 0;
    shadow_rq_ci = 0;
    shadow_arm_state = '0;
    shadow_sequence = 0;
    shadow_flushed = 1'b0;
    flushed_shadow = null;
    shadow_flush_count = 0;
  endfunction

  // 功能：按 requested_type 从 UVM raw factory 创建对象，避免 override 错误触发 fatal。
  // 输入/输出及副作用：requested_type/name 输入；返回 raw uvm_object，只读 factory，无其他副作用。
  // 失败/边界：requested_type/factory/返回值为空时返回 null；不检查动态类型，调用方须自行 cast。
  protected function uvm_object factory_create_object_nonfatal(
    uvm_object_wrapper requested_type,
    string name
  );
    uvm_factory factory;

    if (requested_type == null)
      return null;
    factory = uvm_factory::get();
    if (factory == null)
      return null;
    return factory.create_object_by_type(requested_type, "", name);
  endfunction

  // 功能：手工复制 source 的 kind/function_uid/object_id/generation 为独立 handle。
  // 输入/输出及副作用：source/name 输入；snapshot 输出（入口先清空）；不调用 clone/do_copy。
  // 失败/边界：source=null 视为合法可选句柄，返回 OK/null；factory 失败或类型不符返回 RESOURCE_EXHAUSTED。
  protected function rdma_status clone_handle_value_nonfatal(
    rdma_handle source,
    string name,
    output rdma_handle snapshot
  );
    rdma_handle candidate;
    uvm_object raw_candidate;

    snapshot = null;
    if (source == null)
      return rdma_status::make_direct(RDMA_SC_OK);

    raw_candidate = factory_create_object_nonfatal(rdma_handle::get_type(), name);
    if (raw_candidate == null || !$cast(candidate, raw_candidate))
      return rdma_status::make_direct(
        RDMA_SC_RESOURCE_EXHAUSTED,
        {name, " allocation returned null or an incompatible type"}
      );

    candidate.kind = source.kind;
    candidate.function_uid = source.function_uid;
    candidate.object_id = source.object_id;
    candidate.generation = source.generation;
    snapshot = candidate;
    return rdma_status::make_direct(RDMA_SC_OK);
  endfunction

  // 功能：配置 shared CQ 的冻结 Function authority、可选 completion QP、transport 与 shadow。
  // 输入/输出及副作用：成功保存 cloned handle、authority 标量、shadow 值与 evidence_engine
  //   （作为 delegate），并清空旧 flush 缓存；URC 额外要求 completion QP 与 evidence engine。
  // 失败/边界：handle 非法/transport 非法/URC 缺 QP 或 evidence/authority 不完整返回
  //   INVALID_ARGUMENT，失配返回 STALE_GENERATION，重复配置返回 INVALID_STATE；普通 configure
  //   已完成时 engine/UID/generation 须一致且 live binding 有效；clone 失败返回 RESOURCE_EXHAUSTED。
  function rdma_status configure_shared(
    rdma_handle cq_h,
    rdma_handle completion_qp_h,
    rdma_transport_e transport,
    rdma_function_identity identity,
    int unsigned sq_ci = 0,
    int unsigned rq_ci = 0,
    bit [1:0] arm_state = '0,
    longint unsigned seq = 0,
    rdma_queue_data_engine evidence_engine = null
  );
    rdma_handle cq_snapshot;
    rdma_handle qp_snapshot;
    rdma_status handle_status;
    rdma_status authority_status;
    if (cq_h == null || cq_h.kind != RDMA_RESOURCE_CQ)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "shared CQ handle is invalid");
    handle_status = rdma_status::nonnull(
      rdma_context_handle_status(cq_h, RDMA_RESOURCE_CQ, 21,
        "shared CQ handle"),
      "shared CQ handle validation returned null"
    );
    if (!handle_status.ok())
      return handle_status;
    if (!(transport inside {RDMA_TRANSPORT_RC, RDMA_TRANSPORT_UD,
                            RDMA_TRANSPORT_URC}))
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "shared CQ transport is invalid");
    if (transport == RDMA_TRANSPORT_URC &&
        (completion_qp_h == null || completion_qp_h.kind != RDMA_RESOURCE_QP))
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "URC shared CQ requires completion QP");
    if (transport == RDMA_TRANSPORT_URC && evidence_engine == null)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "URC shared CQ requires evidence engine");
    if (completion_qp_h != null) begin
      handle_status = rdma_status::nonnull(
        rdma_context_handle_status(completion_qp_h,
          RDMA_RESOURCE_QP, 21,
          "shared CQ completion QP"),
        "shared CQ completion QP validation returned null"
      );
      if (!handle_status.ok())
        return handle_status;
    end
    if (transport != RDMA_TRANSPORT_URC && completion_qp_h != null &&
        completion_qp_h.kind != RDMA_RESOURCE_QP)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "shared CQ completion QP kind is invalid");
    if (identity == null || identity.function_uid == 0 || identity.generation == 0 ||
        identity.reset_epoch == 0)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "shared CQ Function authority is incomplete");
    if (cq_h.function_uid != identity.function_uid ||
        cq_h.generation != identity.generation)
      return rdma_status::make(RDMA_SC_STALE_GENERATION,
                               "shared CQ Function authority does not match CQ");
    if (completion_qp_h != null &&
        (completion_qp_h.function_uid != identity.function_uid ||
         completion_qp_h.generation != identity.generation))
      return rdma_status::make(RDMA_SC_STALE_GENERATION,
                               "shared CQ completion QP authority is stale");
    // 先校验参数与 authority，再做 one-shot 门禁，使非法重配置仍返回具体错误。
    if (shared_configured)
      return rdma_status::make(RDMA_SC_INVALID_STATE,
                               "shared CQ is already configured");

    // configure 已绑定 delegate 时，shared shadow 只能复用该 delegate。
    if (configured &&
        (evidence_engine == null || evidence_engine != delegate))
      return rdma_status::make(
        RDMA_SC_INVALID_ARGUMENT,
        "shared CQ evidence engine differs from configured delegate");

    // 普通 configure 已绑定一个 Function incarnation，shared 只能补齐同 UID/generation 的 CQ；
    // reset epoch 由 shared snapshot 携带，是否过期留给 flush 的 live-authority 门禁。
    if (configured &&
        (identity.function_uid != authority_function_uid ||
         identity.generation != authority_generation))
      return rdma_status::make(
        RDMA_SC_STALE_GENERATION,
        "shared CQ Function authority differs from configured binding");

    if (configured) begin
      authority_status = validate_live_authority("CQ shared configure");
      if (authority_status == null)
        return rdma_status::make_direct(
          RDMA_SC_INVALID_STATE,
          "CQ shared configure authority validation returned null");
      if (!authority_status.ok())
        return authority_status;
    end

    handle_status = clone_handle_value_nonfatal(
      cq_h, "shared_cq_handle", cq_snapshot);
    if (handle_status == null || !handle_status.ok())
      return handle_status == null ? rdma_status::make_direct(
        RDMA_SC_INVALID_STATE,
        "shared CQ handle clone returned null status"
      ) : handle_status;
    handle_status = clone_handle_value_nonfatal(
      completion_qp_h, "shared_completion_qp_handle", qp_snapshot);
    if (handle_status == null || !handle_status.ok())
      return handle_status == null ? rdma_status::make_direct(
        RDMA_SC_INVALID_STATE,
        "shared CQ completion QP clone returned null status"
      ) : handle_status;
    shared_cq_h = cq_snapshot;
    shared_completion_qp_h = qp_snapshot;
    if (evidence_engine != null)
      delegate = evidence_engine;
    shared_transport = transport;
    shared_function_uid = identity.function_uid;
    shared_generation = identity.generation;
    shared_reset_epoch = identity.reset_epoch;
    shadow_sq_ci = sq_ci;
    shadow_rq_ci = rq_ci;
    shadow_arm_state = arm_state;
    shadow_sequence = seq;
    // 首次成功配置建立唯一 active shadow；后续配置被 one-shot 门禁拒绝。
    shadow_flushed = 1'b0;
    flushed_shadow = null;
    shadow_flush_count = 0;
    shared_configured = 1'b1;
    return rdma_status::success();
  endfunction

  // 设计说明：flush 与 replay 都发布 detached value，避免 caller 修改污染 flushed_shadow 缓存。

  // 功能：把 source CQ shadow 复制成独立值快照，供首次缓存和 replay 共用。
  // 输入/输出及副作用：source/name 输入；snapshot 输出；单独 clone cq_h 并复制 authority、CI、arm、sequence。
  // 失败/边界：source/cq_h 缺失返回 INVALID_STATE；分配或 clone 失败返回 RESOURCE_EXHAUSTED。
  protected function rdma_status clone_shadow_snapshot_value(
    rdma_cq_shadow_snapshot source,
    string name,
    output rdma_cq_shadow_snapshot snapshot
  );
    rdma_cq_shadow_snapshot candidate;
    rdma_handle cq_snapshot;
    rdma_status handle_status;
    uvm_object raw_candidate;

    snapshot = null;
    if (source == null || source.cq_h == null)
      return rdma_status::make_direct(
        RDMA_SC_INVALID_STATE,
        "CQ shadow snapshot source is incomplete"
      );

    raw_candidate = factory_create_object_nonfatal(
      rdma_cq_shadow_snapshot::get_type(), name);
    if (raw_candidate == null || !$cast(candidate, raw_candidate))
      return rdma_status::make_direct(
        RDMA_SC_RESOURCE_EXHAUSTED,
        {name, " allocation returned null or an incompatible type"}
      );
    handle_status = clone_handle_value_nonfatal(
      source.cq_h, {name, "_handle"}, cq_snapshot);
    if (handle_status == null || !handle_status.ok())
      return handle_status == null ? rdma_status::make_direct(
        RDMA_SC_INVALID_STATE,
        "CQ shadow handle clone returned null status"
      ) : handle_status;

    candidate.cq_h = cq_snapshot;
    candidate.function_uid = source.function_uid;
    candidate.generation = source.generation;
    candidate.reset_epoch = source.reset_epoch;
    candidate.sq_ci = source.sq_ci;
    candidate.rq_ci = source.rq_ci;
    candidate.arm_state = source.arm_state;
    candidate.\sequence = source.\sequence ;
    snapshot = candidate;
    return rdma_status::make_direct(RDMA_SC_OK);
  endfunction

  // 功能：捕获并清除共享 CQ shadow；首次之后重复调用返回首个结果的 detached 缓存副本。
  // 输入/输出及副作用：shadow 为 inout；首次可为 null，输出 authority/CI/arm/sequence 快照，
  //   缓存副本、count 置 1 并清零内部 shadow；URC 先捕获 evidence；replay 不重复 mutation。
  // 失败/边界：未配置返回 INVALID_STATE；live authority 失活/漂移先拒绝；shadow authority 不匹配
  //   或 replay 缺少 authority 返回 STALE_GENERATION；缓存异常/null status 返回 INVALID_STATE；
  //   clone 失败返回 RESOURCE_EXHAUSTED；URC evidence 失败原样返回且不清除 shadow。
  function rdma_status flush_shadow(inout rdma_cq_shadow_snapshot shadow);
    rdma_cq_shadow_snapshot active_source;
    rdma_cq_shadow_snapshot captured;
    rdma_cq_shadow_snapshot cached;
    rdma_cq_shadow_snapshot replayed;
    rdma_status evidence_status;
    rdma_status authority_status;
    rdma_status prepared_success;
    rdma_status snapshot_status;
    if (!shared_configured)
      return rdma_status::make(RDMA_SC_INVALID_STATE,
                               "shared CQ is not configured");
    if (authority_binding != null) begin
      authority_status = rdma_status::nonnull(
        validate_live_authority("CQ shadow flush"),
        "CQ shadow flush authority validation returned null"
      );
      if (!authority_status.ok())
        return authority_status;
    end
    if (shadow != null) begin
      authority_status = rdma_cq_shadow_replay_policy::validate(
        shadow, shared_cq_h, shared_function_uid, shared_generation,
        shared_reset_epoch, "CQ shadow authority is stale");
      if (!authority_status.ok())
        return authority_status;
    end
    if (shadow_flushed) begin
      // 无调用方 authority 快照时，不能把旧 epoch 缓存重新发布为成功。
      if (shadow == null)
        return rdma_status::make(RDMA_SC_STALE_GENERATION,
                                 "CQ shadow replay authority is missing");

      authority_status = rdma_cq_shadow_replay_policy::validate(
        flushed_shadow, shared_cq_h, shared_function_uid, shared_generation,
        shared_reset_epoch, "CQ shadow replay cache authority is invalid",
        RDMA_SC_INVALID_STATE);
      if (!authority_status.ok())
        return authority_status;
      snapshot_status = rdma_status::nonnull(
        clone_shadow_snapshot_value(
          flushed_shadow, "replayed_cq_shadow", replayed),
        "CQ shadow replay snapshot returned null status"
      );
      if (!snapshot_status.ok())
        return snapshot_status;

      shadow = replayed;
      return rdma_status::make_direct(RDMA_SC_OK);
    end

    // active_source 仅为局部视图；两份快照经 raw factory 独立物化，且先于 URC evidence 分配，
    // 因此 cache 分配失败不会留下 evidence 或消耗 active shadow。
    active_source = new("active_cq_shadow_source");
    active_source.cq_h = shared_cq_h;
    active_source.function_uid = shared_function_uid;
    active_source.generation = shared_generation;
    active_source.reset_epoch = shared_reset_epoch;
    active_source.sq_ci = shadow_sq_ci;
    active_source.rq_ci = shadow_rq_ci;
    active_source.arm_state = shadow_arm_state;
    active_source.\sequence = shadow_sequence;
    snapshot_status = clone_shadow_snapshot_value(
      active_source, "flushed_cq_shadow", captured);
    if (snapshot_status == null)
      return rdma_status::make_direct(
        RDMA_SC_INVALID_STATE,
        "CQ shadow output snapshot returned null status"
      );
    if (!snapshot_status.ok())
      return snapshot_status;
    snapshot_status = clone_shadow_snapshot_value(
      active_source, "cached_cq_shadow", cached);
    if (snapshot_status == null)
      return rdma_status::make_direct(
        RDMA_SC_INVALID_STATE,
        "CQ shadow cache snapshot returned null status"
      );
    if (!snapshot_status.ok())
      return snapshot_status;
    prepared_success = rdma_status::make_direct(RDMA_SC_OK);

    if (shared_transport == RDMA_TRANSPORT_URC) begin
      evidence_status = rdma_status::nonnull(
        delegate.capture_urc_shadow_evidence(captured),
        "URC shadow evidence capture returned null"
      );
      if (!evidence_status.ok())
        return evidence_status;
    end

    shadow = captured;
    flushed_shadow = cached;
    shadow_sq_ci = 0;
    shadow_rq_ci = 0;
    shadow_arm_state = '0;
    shadow_sequence = 0;
    shadow_flushed = 1'b1;
    shadow_flush_count = 1;
    return prepared_success;
  endfunction

  // 功能：CQ 配置准入：shared-shadow 已绑定 delegate 时，普通 configure 须使用同一 engine。
  // 输入/输出及副作用：shared_engine 为待保存 delegate；只读 shared_configured/delegate。
  // 失败/边界：delegate 不一致返回 INVALID_ARGUMENT。
  protected virtual function rdma_status configure_admission(
    rdma_queue_data_engine shared_engine
  );
    if (shared_configured && delegate != null && delegate != shared_engine)
      return rdma_status::make(
        RDMA_SC_INVALID_ARGUMENT,
        "CQ facade delegate differs from shared evidence engine");
    return rdma_status::success();
  endfunction

  // 功能：轮询一个 CQE，读/解码/route、CI doorbell 与 WQE release 由共享 engine 完成。
  // 输入/输出及副作用：cq_h 输入；result/status 输出；经 poll seam 调用 delegate，成功发布 detached completion。
  // 失败/边界：authority 失败、delegate 失败、operation_timeout 到期（TIMEOUT）均清空 result；
  //   null status 归一化为 INVALID_STATE；facade 不提供取消/恢复入口。
  task poll_cqe(
    rdma_handle cq_h,
    output rdma_queue_completion_result result,
    output rdma_status status
  );
    result = null;
    status = validate_operation_authority("CQ poll");
    if (!status.ok())
      return;

    call_delegate_poll_cqe(cq_h, operation_timeout, result, status);
    status = normalize_delegate_status(status, "poll_cqe");
    if (!status.ok())
      result = null;
  endtask

  // 功能：把设备 CQE 发布委托给 delegate，保持与直接调用一致的 authority/recovery 语义。
  // 输入/输出及副作用：cq_h、model 输入；result/status 输出；facade 只转发，不写 backing。
  // 失败/边界：authority 失败返回 INVALID_STATE/STALE_GENERATION；delegate 失败原样保留，null 归一化
  //   为 INVALID_STATE；任一失败清空 result；reservation 后失败的取消/recovery 由 delegate 负责。
  task publish_cqe(
    rdma_handle cq_h,
    rdma_hw_cqe_model model,
    output rdma_queue_device_publish_result result,
    output rdma_status status
  );
    result = null;
    status = validate_operation_authority("CQ publish");
    if (!status.ok())
      return;

    call_delegate_publish_cqe(cq_h, model, result, status);
    status = normalize_delegate_status(status, "publish_cqe");
    if (!status.ok())
      result = null;
  endtask

  // 功能：请求共享 engine 对 CQ ring 做 quiesce、重建与原子切换。
  // 输入/输出及副作用：cq_h/new_depth/new_cqe_bytes 输入；返回状态；成功时 delegate 更新 attachment。
  // 失败/边界：未配置/binding 非 ACTIVE 返回 INVALID_STATE，Function 漂移返回 STALE_GENERATION；
  //   shared-only facade 不能 resize；发布后旧资源清理失败返回 RECOVERY_REQUIRED（新 attachment 有效）。
  function rdma_status resize(rdma_handle cq_h, int unsigned new_depth,
                              int unsigned new_cqe_bytes);
    rdma_status status = validate_operation_authority("CQ resize");
    if (!status.ok())
      return status;

    return normalize_delegate_status(call_delegate_resize_cq(
      cq_h, new_depth, new_cqe_bytes), "resize_cq");
  endfunction
endclass
