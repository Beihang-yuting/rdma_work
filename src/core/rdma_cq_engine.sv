// 目录：核心执行层 core/rdma_cq_engine.sv，位于队列数据路径的 CQ facade。
// 职责：提供 CQE 消费入口，把解码、route、CI 提交和 WQE release 委托给共享 queue-data engine。
// 依赖：rdma_queue_data_engine、rdma_queue_completion_result 及 CQ codec/adapter 契约。
// 所有权与生命周期：facade 不拥有 CQ runtime、backing mapping 或 doorbell；这些由上层管理。

class rdma_cq_engine extends uvm_object;
  `uvm_object_utils(rdma_cq_engine)

  protected rdma_queue_data_engine delegate;
  protected time operation_timeout;
  protected bit configured;
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
  protected rdma_status shadow_flush_result;
  int unsigned shadow_flush_count;

  // 功能：创建未配置的 CQ facade，不读取或修改任何 CQ backing。
  // 输入/输出及副作用：name（输入）；new 只写入构造体列出的默认字段并返回 void，外部依赖与资源所有权仍由上层管理。
  // 失败/边界：未 configure 的 facade 调用 poll_cqe 必须返回 INVALID_STATE 且 result 为空。
  function new(string name = "rdma_cq_engine");
    super.new(name);
    delegate = null;
    operation_timeout = 0;
    configured = 1'b0;
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
    shadow_flush_result = null;
    shadow_flush_count = 0;
  endfunction

  // 功能：配置共享 CQ 的 Function authority、URC completion QP 和可恢复 shadow 游标。
  // 输入/输出及副作用：cq_h/completion_qp_h/transport/identity、SQ/RQ CI、arm、sequence 和 URC evidence_engine 为输入；成功时保存句柄快照与 authority 标量，不接管外部资源。
  // 失败边界：CQ/QP 句柄为空或类型错误、URC 缺少 completion QP/evidence_engine、Function UID/generation/reset epoch 为零或句柄代际不匹配时返回错误且保留旧配置。
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
    if (cq_h == null || cq_h.kind != RDMA_RESOURCE_CQ)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "shared CQ handle is invalid");
    handle_status = rdma_context_handle_status(cq_h, RDMA_RESOURCE_CQ, 21,
                                                "shared CQ handle");
    if (!handle_status.ok()) return handle_status;
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
      handle_status = rdma_context_handle_status(completion_qp_h,
                                                 RDMA_RESOURCE_QP, 21,
                                                 "shared CQ completion QP");
      if (!handle_status.ok()) return handle_status;
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
    cq_snapshot = rdma_clone_handle_value(cq_h, "shared CQ handle");
    qp_snapshot = rdma_clone_handle_value(completion_qp_h,
                                          "shared CQ completion QP");
    if (cq_snapshot == null || (completion_qp_h != null && qp_snapshot == null))
      return rdma_status::make(RDMA_SC_RESOURCE_EXHAUSTED,
                               "shared CQ authority snapshot failed");
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
    // Reconfigure starts a fresh active shadow state, even when the epoch is
    // unchanged; this avoids returning an old snapshot for newly supplied CI.
    shadow_flushed = 1'b0;
    flushed_shadow = null;
    shadow_flush_result = null;
    shadow_flush_count = 0;
    shared_configured = 1'b1;
    return rdma_status::success();
  endfunction

  // 功能：在当前 active Function/reset epoch 捕获并清除共享 CQ shadow；重复调用返回首个结果而不重复清除。
  // 输入/输出及副作用：shadow 为 inout 快照；首次成功调用写入 CQ authority、SQ/RQ CI、arm、sequence 并清零内部 shadow，后续调用保持原快照。
  // 失败边界：未配置 shared CQ、快照 authority 与当前 Function/generation/reset epoch/CQ kind/object 不匹配时返回 STALE_GENERATION；URC evidence capture 失败时原子拒绝且不清除内部 shadow。
  function rdma_status flush_shadow(inout rdma_cq_shadow_snapshot shadow);
    rdma_cq_shadow_snapshot captured;
    rdma_status evidence_status;
    if (!shared_configured)
      return rdma_status::make(RDMA_SC_INVALID_STATE,
                               "shared CQ is not configured");
    if (shadow != null) begin
      if (shadow.cq_h == null || shadow.cq_h.kind != RDMA_RESOURCE_CQ ||
          shadow.function_uid != shared_function_uid ||
          shadow.generation != shared_generation ||
          shadow.reset_epoch != shared_reset_epoch ||
          shadow.cq_h.function_uid != shared_function_uid ||
          shadow.cq_h.generation != shared_generation ||
          shadow.cq_h.object_id != shared_cq_h.object_id)
        return rdma_status::make(RDMA_SC_STALE_GENERATION,
                                 "CQ shadow authority is stale");
    end
    if (shadow_flushed) begin
      if (shadow == null) begin
        shadow = rdma_cq_shadow_snapshot::type_id::create("replayed_cq_shadow");
        shadow.copy(flushed_shadow);
      end
      return shadow_flush_result;
    end
    captured = rdma_cq_shadow_snapshot::type_id::create("flushed_cq_shadow");
    captured.cq_h = rdma_clone_handle_value(shared_cq_h, "flushed CQ handle");
    captured.function_uid = shared_function_uid;
    captured.generation = shared_generation;
    captured.reset_epoch = shared_reset_epoch;
    captured.sq_ci = shadow_sq_ci;
    captured.rq_ci = shadow_rq_ci;
    captured.arm_state = shadow_arm_state;
    captured.\sequence = shadow_sequence;
    if (captured.cq_h == null)
      return rdma_status::make(RDMA_SC_RESOURCE_EXHAUSTED,
                               "flushed CQ handle snapshot failed");
    if (shared_transport == RDMA_TRANSPORT_URC) begin
      evidence_status = delegate.capture_urc_shadow_evidence(captured);
      if (evidence_status == null || !evidence_status.ok())
        return evidence_status == null ?
          rdma_status::make(RDMA_SC_INVALID_STATE,
                            "URC shadow evidence capture returned null") :
          evidence_status;
    end
    shadow = captured;
    flushed_shadow = rdma_cq_shadow_snapshot::type_id::create("cached_cq_shadow");
    flushed_shadow.copy(captured);
    shadow_sq_ci = 0;
    shadow_rq_ci = 0;
    shadow_arm_state = '0;
    shadow_sequence = 0;
    shadow_flushed = 1'b1;
    shadow_flush_count = 1;
    shadow_flush_result = rdma_status::success();
    return shadow_flush_result;
  endfunction

  // 功能：绑定共享 queue-data engine，校验 CQ 使用的资源、binding、Host-memory、doorbell 和 codec 引用一致。
  // 输入/输出及副作用：resource_manager（输入）、function_binding（输入）、memory（输入）、scheduler（输入）、codecs（输入）、timeout（输入）、shared_engine（输入）；调用方必须先完成输入对象的空值、authority 和 generation 校验；成功时更新本对象配置/状态并保存非拥有引用，返回
  //   rdma_status。
  // 失败/边界：实现中的空依赖、重复登记、状态或 generation/authority 校验失败时返回错误；失败时保留旧配置。
  function rdma_status configure(
    rdma_resource_manager resource_manager,
    rdma_function_binding function_binding,
    rdma_host_mem_api memory,
    rdma_doorbell_scheduler scheduler,
    rdma_codec_registry codecs,
    time timeout,
    rdma_queue_data_engine shared_engine = null
  );
    rdma_status status;
    if (resource_manager == null || function_binding == null || memory == null ||
        scheduler == null || codecs == null || timeout == 0 || shared_engine == null)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "CQ facade configuration dependency is null/zero");
    if (shared_engine.manager != resource_manager ||
        shared_engine.binding != function_binding ||
        shared_engine.host_mem != memory ||
        shared_engine.doorbells != scheduler ||
        shared_engine.registry != codecs)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "CQ facade dependencies do not match shared engine");
    status = function_binding.validate();
    if (status == null || !status.ok() || function_binding.state != RDMA_BIND_ACTIVE)
      return status == null ?
        rdma_status::make(RDMA_SC_INVALID_STATE, "CQ Function binding validation returned null") :
        status;
    delegate = shared_engine;
    operation_timeout = timeout;
    configured = 1'b1;
    return rdma_status::success();
  endfunction

  // 功能：轮询一个 CQE，并由共享 engine 完成读/解码/route、CI doorbell、consumer commit 和 WQE release。
  // 输入/输出及副作用：cq_h（输入）、result（输出）、status（输出）；poll_cqe 驱动下游事务，并写入 result、status；函数返回 无直接返回值，不取得调用方资源所有权。
  // 失败/边界：未配置、CQ 未登记、owner/identity 错误或 CI 提交失败时不发布 completion；空环返回 QUEUE_EMPTY。
  task poll_cqe(
    rdma_handle cq_h,
    output rdma_queue_completion_result result,
    output rdma_status status
  );
    result = null;
    status = null;
    if (!configured || delegate == null) begin
      status = rdma_status::make(RDMA_SC_INVALID_STATE,
                                 "CQ facade is not configured");
      return;
    end
    delegate.poll_cqe(cq_h, operation_timeout, result, status);
  endtask

  // 功能：publish_cqe 将设备生成的 CQE 透明委托给共享 queue-data engine，
  //   使 facade 与直接 delegate 保持同一 authority、backing 和 recovery 语义。
  // 输入/输出及副作用：cq_h、model 为输入，result/status 为输出；facade 不 clone
  //   result/image、不写 backing、不保存 runtime，仅转发 delegate 的输出对象。
  // 失败边界：未 configure 或 delegate 为空返回 INVALID_STATE 且 result 为 null；
  //   其余 route、polarity、full、编码和 recovery 拒绝由 delegate 原样传播。
  task publish_cqe(
    rdma_handle cq_h,
    rdma_hw_cqe_model model,
    output rdma_queue_device_publish_result result,
    output rdma_status status
  );
    result = null;
    status = null;
    if (!configured || delegate == null) begin
      status = rdma_status::make(RDMA_SC_INVALID_STATE,
                                 "CQ facade is not configured");
      return;
    end
    delegate.publish_cqe(cq_h, model, result, status);
  endtask

  // 功能：请求共享 queue-data engine 对 CQ ring 做 quiesce、重建和原子切换。
  // 输入输出及副作用：cq_h/new_depth/new_cqe_bytes 为输入；成功时更新共享 attachment geometry。
  // 失败边界：facade 未配置或 delegate 拒绝 quiesce/分配/激活时返回错误且旧 ring 保持有效。
  function rdma_status resize(rdma_handle cq_h, int unsigned new_depth,
                              int unsigned new_cqe_bytes);
    if (!configured || delegate == null)
      return rdma_status::make(RDMA_SC_INVALID_STATE, "CQ facade is not configured");
    return delegate.resize_cq(cq_h, new_depth, new_cqe_bytes);
  endfunction
endclass
