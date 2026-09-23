// 目录：核心执行层 core/rdma_cq_engine.sv，位于队列数据路径的 CQ facade。
// 职责：提供 CQE 消费入口，把解码、route、CI 提交和 WQE release 委托给共享 queue-data engine。
// 依赖：rdma_queue_data_engine、rdma_queue_completion_result 及 CQ codec/adapter 契约。
// 所有权与生命周期：facade 不拥有 CQ runtime、backing mapping 或 doorbell；这些由上层管理。

class rdma_cq_engine extends uvm_object;
  `uvm_object_utils(rdma_cq_engine)

  protected rdma_queue_data_engine delegate;
  protected rdma_function_binding authority_binding;
  protected longint unsigned authority_function_uid;
  protected int unsigned authority_generation;
  protected rdma_reset_epoch_t authority_reset_epoch;
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

  // 功能：把 CQ poll 调用转交给当前唯一 delegate，作为 facade 与共享 engine
  //   之间可替换的窄测试边界。
  // 输入/输出及副作用：cq_h、timeout 为输入，result/status 为输出；默认实现
  //   直接调用 delegate.poll_cqe，所有 backing/cursor/recovery 副作用仍归 delegate。
  // 失败/边界：调用方必须先确认 delegate 非空和 authority 有效；该边界允许
  //   hostile 子类返回 null/failure status，公开 poll_cqe 负责 fail-closed。
  protected virtual task call_delegate_poll_cqe(
    rdma_handle cq_h,
    time timeout,
    output rdma_queue_completion_result result,
    output rdma_status status
  );
    delegate.poll_cqe(cq_h, timeout, result, status);
  endtask

  // 功能：把 CQE publish 调用转交给当前唯一 delegate，保持 facade 不拥有
  //   producer runtime 或 CQ backing。
  // 输入/输出及副作用：cq_h/model 为输入，result/status 为输出；默认实现调用
  //   delegate.publish_cqe，可能由 delegate 预留槽位、写 backing 并提交 PI。
  // 失败/边界：调用方必须先完成配置/authority 门禁；hostile 子类可返回
  //   null/failure status，公开 publish_cqe 必须丢弃失败结果。
  protected virtual task call_delegate_publish_cqe(
    rdma_handle cq_h,
    rdma_hw_cqe_model model,
    output rdma_queue_device_publish_result result,
    output rdma_status status
  );
    delegate.publish_cqe(cq_h, model, result, status);
  endtask

  // 功能：把 CQ resize 请求转交给当前唯一 delegate，隔离 facade 的 authority
  //   门禁与 queue-data engine 的 quiesce/切换实现。
  // 输入/输出及副作用：cq_h/new_depth/new_cqe_bytes 为输入；返回 delegate 状态，
  //   成功时 attachment/backing/runtime 副作用完全由 delegate 管理。
  // 失败/边界：调用方必须先确认完整 configure；hostile 子类可返回 null，公开
  //   resize 负责归一化为 INVALID_STATE。
  protected virtual function rdma_status call_delegate_resize_cq(
    rdma_handle cq_h,
    int unsigned new_depth,
    int unsigned new_cqe_bytes
  );
    return delegate.resize_cq(cq_h, new_depth, new_cqe_bytes);
  endfunction

  // 功能：创建未配置的 CQ facade，不读取或修改任何 CQ backing。
  // 输入/输出及副作用：name（输入）；new 只写入构造体列出的默认字段并返回
  //   void，外部依赖与资源所有权仍由上层管理。
  // 失败/边界：未 configure 的 facade 调用 poll_cqe 必须返回 INVALID_STATE，
  //   且 result 为空。
  function new(string name = "rdma_cq_engine");
    super.new(name);
    delegate = null;
    authority_binding = null;
    authority_function_uid = 0;
    authority_generation = 0;
    authority_reset_epoch = 0;
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

  // 功能：校验 CQ facade 保存的 Function binding 仍处于原 generation/reset epoch。
  // 输入/输出及副作用：label 仅用于诊断；读取 binding 快照并返回状态，不修改
  //   delegate 或队列游标。
  // 失败/边界：未配置、delegate 缺失、binding 校验失败或 UID/generation/reset epoch
  //   漂移时返回错误，调用方不得继续访问 CQ。
  protected function rdma_status validate_live_authority(string label);
    return rdma_validate_live_authority(
      configured,
      delegate != null,
      authority_binding,
      authority_function_uid,
      authority_generation,
      authority_reset_epoch,
      label);
  endfunction

  // 功能：配置共享 CQ 的 Function authority、URC completion QP 和可恢复
  //   shadow 游标。
  // 输入/输出及副作用：cq_h/completion_qp_h/transport/identity、SQ/RQ CI、
  //   arm、sequence 和 URC evidence_engine 为输入；成功时保存句柄快照与
  //   authority 标量，不接管外部资源。
  // 失败/边界：CQ/QP 句柄为空或类型错误、URC 缺少 completion QP/evidence_engine、
  // Function UID/generation/reset epoch 为零或句柄代际不匹配时返回错误且保留旧
  // 配置；configure 已绑定另一 delegate 时返回 INVALID_ARGUMENT；shared 配置本身
  // 已完成时返回 INVALID_STATE。两个入口始终共享唯一 delegate authority。
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
    if (handle_status == null)
      return rdma_status::make(
        RDMA_SC_INVALID_STATE,
        "shared CQ handle validation returned null");
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
      handle_status = rdma_context_handle_status(completion_qp_h,
                                                 RDMA_RESOURCE_QP, 21,
                                                 "shared CQ completion QP");
      if (handle_status == null)
        return rdma_status::make(
          RDMA_SC_INVALID_STATE,
          "shared CQ completion QP validation returned null");
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
    // 中文设计：先完成参数与 authority 校验，再执行 one-shot 门禁，保证非法
    // 重配置仍返回其具体错误；合法重配置不得覆盖活动 authority 或
    // shadow 缓存。
    if (shared_configured)
      return rdma_status::make(RDMA_SC_INVALID_STATE,
                               "shared CQ is already configured");

    // configure 与 configure_shared 是两个独立 one-shot 入口，但它们描述的是
    // 同一个 CQ facade；configure 已先绑定 delegate 时，shared shadow 只能复用
    // 该 delegate，不能把 authority 切换到另一个 queue-data engine。
    if (configured &&
        (evidence_engine == null || evidence_engine != delegate))
      return rdma_status::make(
        RDMA_SC_INVALID_ARGUMENT,
        "shared CQ evidence engine differs from configured delegate");

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
    // 中文设计：首次成功配置建立唯一的 active shadow，并清除构造期缓存；
    // 后续配置由上方 one-shot 门禁拒绝，不能重置已发布的 flush 结果。
    shadow_flushed = 1'b0;
    flushed_shadow = null;
    shadow_flush_result = null;
    shadow_flush_count = 0;
    shared_configured = 1'b1;
    return rdma_status::success();
  endfunction

  // 功能：在当前 active Function/reset epoch 捕获并清除共享 CQ shadow；重复
  //   调用返回首个结果而不重复清除。
  // 输入/输出及副作用：shadow 为 inout 快照；首次成功调用写入 CQ authority、
  //   SQ/RQ CI、arm、sequence 并清零内部 shadow，后续调用保持原快照。
  // 失败/边界：未配置 shared CQ、快照 authority 与当前 Function/generation/
  // reset epoch/CQ kind/object 不匹配时返回 STALE_GENERATION；URC evidence
  // capture 失败时原子拒绝且不清除内部 shadow。
  function rdma_status flush_shadow(inout rdma_cq_shadow_snapshot shadow);
    rdma_cq_shadow_snapshot captured;
    rdma_status evidence_status;
    rdma_status authority_status;
    if (!shared_configured)
      return rdma_status::make(RDMA_SC_INVALID_STATE,
                               "shared CQ is not configured");
    if (authority_binding != null) begin
      authority_status = validate_live_authority("CQ shadow flush");

      if (authority_status == null)
        return rdma_status::make(
          RDMA_SC_INVALID_STATE,
          "CQ shadow flush authority validation returned null");

      if (!authority_status.ok())
        return authority_status;
    end
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
      // 没有调用方携带的当前 authority 快照时，不能把旧 epoch 的缓存
      // 重新发布为成功结果；恢复必须重新完成 authority 认证。
      if (shadow == null)
        return rdma_status::make(RDMA_SC_STALE_GENERATION,
                                 "CQ shadow replay authority is missing");

      if (shadow_flush_result == null)
        return rdma_status::make(
          RDMA_SC_INVALID_STATE,
          "CQ shadow replay cached a null status");

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

      if (evidence_status == null)
        return rdma_status::make(
          RDMA_SC_INVALID_STATE,
          "URC shadow evidence capture returned null");

      if (!evidence_status.ok())
        return evidence_status;
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

  // 功能：绑定共享 queue-data engine，校验 CQ 使用的资源、binding、Host-memory、
  //   doorbell 和 codec 引用一致。
  // 输入/输出及副作用：resource_manager、function_binding、memory、scheduler、
  //   codecs、timeout 和 shared_engine 为输入；函数先通过共用 admission helper
  //   完成依赖、authority 和 ACTIVE 校验，成功时更新本对象配置/状态并保存非拥有引用，
  //   返回 rdma_status。
  // 失败/边界：空依赖、重复登记、状态或 generation/authority 校验失败时返回
  //   错误；configure_shared 已绑定另一 delegate 时返回 INVALID_ARGUMENT；本入口
  //   已配置时返回 INVALID_STATE。失败发生在任何 delegate/authority 写入之前。
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
    status = rdma_validate_queue_facade_configuration(
      resource_manager,
      function_binding,
      memory,
      scheduler,
      codecs,
      timeout,
      shared_engine,
      "CQ");
    if (status == null || !status.ok())
      return status;
    // 配置成功后 facade 的 delegate 与 authority 是不可替换的；否则第二次
    // configure 会覆盖冻结坐标，使正在执行的 poll/resize 失去生命周期边界。
    if (configured)
      return rdma_status::make(
        RDMA_SC_INVALID_STATE,
        "CQ facade is already configured");

    if (shared_configured && delegate != null && delegate != shared_engine)
      return rdma_status::make(
        RDMA_SC_INVALID_ARGUMENT,
        "CQ facade delegate differs from shared evidence engine");

    delegate = shared_engine;
    authority_binding = function_binding;
    authority_function_uid = function_binding.function_uid;
    authority_generation = function_binding.generation;
    authority_reset_epoch = function_binding.function_reset_epoch();
    operation_timeout = timeout;
    configured = 1'b1;
    return rdma_status::success();
  endfunction

  // 功能：轮询一个 CQE，并由共享 engine 完成读/解码/route、CI doorbell、
  //   consumer commit 和 WQE release。
  // 输入/输出及副作用：cq_h（输入）、result/status（输出）；poll_cqe 驱动
  //   下游事务，并写入 result/status；函数无直接返回值，不取得调用方资源所有权。
  // 失败/边界：未配置、CQ 未登记、owner/identity 错误或 CI 提交失败时不发布
  //   completion；空环返回 QUEUE_EMPTY；delegate 返回 null status 时统一返回
  //   INVALID_STATE，非空失败状态保留原 code/message；任一失败都清空 result。
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
    status = validate_live_authority("CQ poll");

    if (status == null) begin
      status = rdma_status::make(
        RDMA_SC_INVALID_STATE,
        "CQ poll authority validation returned null");
      return;
    end

    if (!status.ok())
      return;

    call_delegate_poll_cqe(cq_h, operation_timeout, result, status);

    if (status == null) begin
      result = null;
      status = rdma_status::make(
        RDMA_SC_INVALID_STATE,
        "CQ delegate poll_cqe returned null status");
    end
    else if (!status.ok()) begin
      result = null;
    end
  endtask

  // 功能：publish_cqe 将设备生成的 CQE 透明委托给共享 queue-data engine，
  //   使 facade 与直接 delegate 保持同一 authority、backing 和 recovery 语义。
  // 输入/输出及副作用：cq_h、model 为输入，result/status 为输出；facade 不 clone
  //   result/image、不写 backing、不保存 runtime，仅转发 delegate 的输出对象。
  // 失败/边界：未 configure 或 delegate 为空返回 INVALID_STATE 且 result 为 null；
  //   route、polarity、full、编码和 recovery 的非空失败状态原样传播；delegate
  //   返回 null status 时统一返回 INVALID_STATE；任一失败都清空 result。
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
    status = validate_live_authority("CQ publish");

    if (status == null) begin
      status = rdma_status::make(
        RDMA_SC_INVALID_STATE,
        "CQ publish authority validation returned null");
      return;
    end

    if (!status.ok())
      return;

    call_delegate_publish_cqe(cq_h, model, result, status);

    if (status == null) begin
      result = null;
      status = rdma_status::make(
        RDMA_SC_INVALID_STATE,
        "CQ delegate publish_cqe returned null status");
    end
    else if (!status.ok()) begin
      result = null;
    end
  endtask

  // 功能：请求共享 queue-data engine 对 CQ ring 做 quiesce、重建和原子切换。
  // 输入/输出及副作用：cq_h/new_depth/new_cqe_bytes 为输入；成功时更新共享
  //   attachment geometry。
  // 失败/边界：facade 未完成 configure 或 authority 已漂移时不调用 delegate；
  // configure_shared-only facade 不能 resize；delegate 拒绝 quiesce/分配/激活时
  // 返回错误且旧 ring 保持有效，null status 统一为 INVALID_STATE。
  function rdma_status resize(rdma_handle cq_h, int unsigned new_depth,
                              int unsigned new_cqe_bytes);
    rdma_status authority_status;
    rdma_status resize_status;

    if (!configured || delegate == null)
      return rdma_status::make(RDMA_SC_INVALID_STATE, "CQ facade is not configured");

    // configured 只能由 configure() 置位，因此其成功态必然带 authority_binding；
    // configure_shared-only 仍停在上方 INVALID_STATE 门禁，不存在 legacy 直通分支。
    authority_status = validate_live_authority("CQ resize");
    if (authority_status == null)
      return rdma_status::make(RDMA_SC_INVALID_STATE,
                               "CQ resize authority validation returned null");
    if (!authority_status.ok())
      return authority_status;

    resize_status = call_delegate_resize_cq(
      cq_h, new_depth, new_cqe_bytes);

    if (resize_status == null)
      return rdma_status::make(
        RDMA_SC_INVALID_STATE,
        "CQ delegate resize_cq returned null status");

    return resize_status;
  endfunction
endclass
