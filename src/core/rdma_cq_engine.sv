// 目录：核心执行层 core/rdma_cq_engine.sv，位于队列数据路径的 CQ facade。
// 职责：提供 CQE poll/publish、CQ resize 与 shared-CQ shadow flush，把 queue-data
//   mutation 委托给共享 engine，并在 facade 边界统一 Function authority。
// 依赖：rdma_queue_data_engine、CQ completion/publish result、Function binding、
//   CQ shadow snapshot 及 CQ codec/adapter 契约。
// 所有权与生命周期：facade 借用 delegate/binding，不拥有 runtime、backing 或 doorbell；
//   自身拥有 configure 时冻结的标量、cloned shared handle 与 flush 缓存快照。

// 设计说明：独立 CQ facade 提供稳定 typed API，唯一 queue-data engine 保持 mutation
// 权威；单一非拥有 delegate 和冻结 Function 坐标阻断 reset/rebind 后的旧 facade。
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
  int unsigned shadow_flush_count;

  // 功能：把 CQ poll 调用转交给唯一 delegate，形成 facade 与共享 engine 的窄测试边界。
  // 输入/输出及副作用：cq_h、timeout 为输入，result/status 为输出；完成、TIMEOUT、
  //   recovery evidence 和所有 backing/cursor 副作用均来自 delegate.poll_cqe。
  // 失败/边界：调用方必须先确认 delegate 非空和 authority 有效；该 seam 没有独立
  //   cancel/resume 接口，hostile 子类可返回 null/failure，公开 poll_cqe 负责 fail-closed。
  protected virtual task call_delegate_poll_cqe(
    rdma_handle cq_h,
    time timeout,
    output rdma_queue_completion_result result,
    output rdma_status status
  );
    delegate.poll_cqe(cq_h, timeout, result, status);
  endtask

  // 功能：把 CQE publish 转交给唯一 delegate，保持 facade 不拥有 runtime/CQ backing。
  // 输入/输出及副作用：cq_h/model 为输入，result/status 为输出；delegate.publish_cqe
  //   可预留槽位、写 backing、提交 PI 或保存 recovery evidence。
  // 失败/边界：调用方必须先完成配置/authority 门禁；reservation 后的确定失败由
  //   delegate cancel，写入后的不确定失败进入 recovery；hostile null/failure status
  //   由公开 publish_cqe 归一化并丢弃不可信 result，facade 不提供额外取消入口。
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

  // 功能：创建普通入口和 shared-shadow 均未配置的 CQ facade，不分配 CQ backing。
  // 输入/输出及副作用：name 为输入；new 清空 delegate/authority、shared handle、shadow
  //   与 flush 缓存，将两个 configured flag 清零并把 transport 置为 RC；不接管外部资源。
  // 失败/边界：configure 前 poll/publish/resize 均返回 INVALID_STATE；configure_shared
  //   可独立启用 flush_shadow，但不能授权三个普通入口。
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
    shadow_flush_count = 0;
  endfunction

  // 功能：校验 CQ facade 冻结的 Function UID/generation/reset epoch 与借用 binding
  //   仍一致，且 binding 仍为 ACTIVE 并通过自身 validate()。
  // 输入/输出及副作用：label 仅用于诊断；函数只读配置、binding 和快照并返回
  //   rdma_status，不修改 delegate、shadow、runtime 或队列游标。
  // 失败/边界：未配置、delegate/binding 缺失或 binding 非 ACTIVE 返回 INVALID_STATE；
  //   UID/generation/reset epoch 漂移返回 STALE_GENERATION；validate() 的 null/失败
  //   分别归一化为 INVALID_STATE 或原样返回。
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

  // 功能：绕过 typed registry cast，按 requested_type 从 UVM raw factory 创建对象，
  //   供 CQ facade 把 null/错误动态类型 override 转换为普通 status。
  // 输入/输出及副作用：requested_type/name 为输入；返回 raw uvm_object，只读取全局
  //   factory override，不修改 CQ 配置、shadow、delegate 或外部资源。
  // 失败/边界：requested_type、factory 或 factory 返回值为空时返回 null；本 helper
  //   不判断动态类型，调用方必须显式 cast 后才能发布对象。
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

  // 功能：把 source 的 kind/Function UID/object ID/generation 复制到独立 handle，
  //   供 shared 配置和 shadow 快照在 hostile factory 下保持非致命失败。
  // 输入/输出及副作用：source/name 为输入，snapshot 为输出且入口先清空；成功只发布
  //   手工复制的值对象，不调用 source.clone/do_copy，也不修改 source 或 facade 状态。
  // 失败/边界：source=null 表示合法的可选句柄并返回 OK/null；raw factory 返回 null
  //   或不可 cast 类型时返回 RESOURCE_EXHAUSTED，snapshot 保持 null。
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

  // 功能：配置 shared CQ 的冻结 Function authority、可选 completion QP、transport
  //   和可恢复 shadow；URC 额外绑定 evidence engine。
  // 输入/输出及副作用：cq_h/completion_qp_h/transport/identity、SQ/RQ CI、arm、
  //   sequence 和 evidence_engine 为输入；成功保存 cloned handle、authority 标量、
  //   shadow 值与非拥有 delegate 引用，并清空旧 flush 缓存。
  // 失败/边界：CQ/非空 QP 的 kind 或 21-bit object ID 非法返回 INVALID_ARGUMENT，
  //   handle validator 为 null 返回 INVALID_STATE；非法 transport、URC 缺少 QP/evidence、
  //   Function authority 不完整/失配和重复 shared 配置均拒绝。普通 configure 已完成时，
  //   evidence_engine 为空或不同、live binding 失活/漂移或 UID/generation 不一致也拒绝；
  //   handle clone 失败返回 RESOURCE_EXHAUSTED 且保留旧配置。RC/UD 允许 completion_qp_h=null。
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

    // 中文设计：普通 configure 已经把 delegate 绑定到一个 Function incarnation；
    // shared shadow 只能补齐同一 UID/generation 的 CQ，不能借用旧 engine 发布另一
    // Function 的 authority。reset epoch 仍允许由 shared snapshot 独立携带，后续
    // flush 的 live-authority gate 会决定该 epoch 是否已经过期。
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
    // 中文设计：首次成功配置建立唯一的 active shadow，并清除构造期缓存；
    // 后续配置由上方 one-shot 门禁拒绝，不能重置已发布的 flush 结果。
    shadow_flushed = 1'b0;
    flushed_shadow = null;
    shadow_flush_count = 0;
    shared_configured = 1'b1;
    return rdma_status::success();
  endfunction

  // 设计说明：首次 flush 和后续 replay 都必须发布 detached value；不能把
  // flushed_shadow 直接交给 caller，否则 caller 修改 handle/游标会污染唯一缓存。

  // 功能：把 source CQ shadow 复制成独立值快照，供首次 cache 和 replay 共用。
  // 输入/输出及副作用：source/name 为输入，snapshot 为输出；成功时分配新 snapshot、
  //   单独 clone cq_h 并复制 Function authority、SQ/RQ CI、arm 和 sequence。
  // 失败/边界：source/cq_h 缺失返回 INVALID_STATE；snapshot 或 handle clone 失败返回
  //   RESOURCE_EXHAUSTED，snapshot 保持 null，source 与 facade 状态均不修改。
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

  // 功能：在当前 active Function/reset epoch 捕获并清除共享 CQ shadow；首次完成后，
  //   携带匹配非空 authority 的重复调用收到首个结果的 detached 缓存副本。
  // 输入/输出及副作用：shadow 为 inout authority/结果快照；首次允许 null 并写入 CQ
  //   authority、SQ/RQ CI、arm、sequence，缓存 detached value，把公开 count 置 1 并
  //   清零内部 active shadow；每次返回独立 success status，replay 不重复 evidence/mutation。
  // 失败/边界：未配置 shared CQ 返回 INVALID_STATE；普通 configure 已提供 binding 时，
  //   live authority 失活/漂移会先拒绝；shared-only 路径只能匹配冻结字段，不等同于
  //   live binding 认证。调用方 authority/kind/object 不匹配或 replay 缺少 authority
  //   返回 STALE_GENERATION；缓存 authority 或 URC evidence status 异常返回
  //   INVALID_STATE；snapshot/handle clone 失败返回 RESOURCE_EXHAUSTED 且不改
  //   caller/cache/count，URC evidence 非空失败在清除内部 shadow 前原样返回。
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
      // 没有调用方携带的当前 authority 快照时，不能把旧 epoch 的缓存
      // 重新发布为成功结果；恢复必须重新完成 authority 认证。
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

    // 中文设计：active_source 只是 direct-new 的局部字段视图，不会发布给 caller；
    // 两个可见快照都经 raw factory 独立物化。所有本地分配先于 URC evidence，
    // 因而第二份 cache 失败也不会留下外部 evidence 或消费 active shadow。
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

  // 功能：绑定共享 queue-data engine，校验 CQ 的 manager、binding、Host-memory、
  //   doorbell 和 codec 引用一致。
  // 输入/输出及副作用：resource_manager、function_binding、memory、scheduler、codecs、
  //   timeout/shared_engine 为输入；成功保存非拥有 delegate/binding、冻结 authority、
  //   timeout 和 configured 状态，并返回 rdma_status。
  // 失败/边界：任一依赖/shared_engine 为空、timeout 为零、engine 的 manager/binding/
  //   memory/scheduler/codecs 不一致返回 INVALID_ARGUMENT；binding validate 为 null、
  //   非 ACTIVE 或重复 configure 返回 INVALID_STATE，非空 validation 失败原样返回；
  //   configure_shared 已绑定另一 delegate 时返回 INVALID_ARGUMENT；admission 先于
  //   one-shot 门禁，所有失败均发生在 delegate/authority 写入前。
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

  // 设计说明：CQ poll、publish 与 resize 的 typed delegate seam 不同，但进入 seam
  // 之前共享同一配置/Function authority 顺序，返回后也共享 null-status 边界。
  // 这里仅提取无 I/O helper；flush_shadow 的 shared-config/replay 契约保持独立。

  // 功能：validate_operation_authority 按 CQ facade 原有顺序执行配置门禁和 live
  //   Function authority 校验，并保证三个普通业务入口获得非 null status。
  // 输入/输出及副作用：label 为 poll/publish/resize 的诊断前缀；函数只读
  //   configured、delegate 与冻结 authority，不修改 runtime、backing、cursor 或 shadow。
  // 失败/边界：未配置或 delegate 缺失返回固定 INVALID_STATE；binding 缺失/非 ACTIVE
  //   返回 INVALID_STATE，UID、generation 或 reset epoch 漂移返回 STALE_GENERATION，
  //   binding.validate() 的非空失败原样返回；authority 返回 null 时按 label 归一化。
  protected function rdma_status validate_operation_authority(string label);
    rdma_status status;

    if (!configured || delegate == null)
      return rdma_status::make(RDMA_SC_INVALID_STATE, "CQ facade is not configured");

    status = validate_live_authority(label);
    if (status == null)
      return rdma_status::make(RDMA_SC_INVALID_STATE,
                               {label, " authority validation returned null"});
    return status;
  endfunction

  // 功能：normalize_delegate_status 将 CQ delegate 的 null status 转换为带 seam 名的
  //   INVALID_STATE，同时保留任意非 null 成功或失败对象。
  // 输入/输出及副作用：candidate 为 delegate 输出，operation_name 为固定 seam 名；
  //   函数返回归一化 status，不修改 result、delegate、ring geometry 或 shadow 状态。
  // 失败/边界：candidate 为 null 时新建 INVALID_STATE；非 null 时保持同一对象、code
  //   和 message。poll/publish 的 result 清理由各 typed wrapper 显式负责。
  protected function rdma_status normalize_delegate_status(
    rdma_status candidate,
    string operation_name
  );
    if (candidate == null)
      return rdma_status::make(RDMA_SC_INVALID_STATE,
        {"CQ delegate ", operation_name, " returned null status"});
    return candidate;
  endfunction

  // 功能：轮询一个 CQE，并由共享 engine 完成读/解码/route、CI doorbell、
  //   consumer commit 和 WQE release。
  // 输入/输出及副作用：cq_h 为输入，result/status 为 output；task 把 handle/timeout
  //   交给 poll seam，成功发布 detached completion，不取得资源所有权。
  // 失败/边界：未配置、Function authority 失活/漂移、CQ 未登记、owner/identity
  //   错误或 CI 提交失败时不发布 completion；配置的非零 operation_timeout 到期返回
  //   TIMEOUT；delegate null status 归一化为 INVALID_STATE，其他失败原样保留，任一
  //   失败都清空 result。facade 不提供取消/恢复入口，delegate 留下的 recovery evidence
  //   由显式 queue recovery 流程处理。
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

  // 功能：publish_cqe 委托设备 CQE，使 facade 与直接 delegate 保持同一 authority、
  //   backing 和 recovery 语义。
  // 输入/输出及副作用：cq_h、model 为输入，result/status 为输出；facade 不 clone
  //   result/image、不写 backing、不保存 runtime，仅转发 delegate 的完成对象或错误。
  // 失败/边界：未配置、binding 缺失/非 ACTIVE 返回 INVALID_STATE；Function UID、
  //   generation 或 reset epoch 漂移返回 STALE_GENERATION；route、polarity、full、
  //   编码和 recovery 的非空失败原样保留；reservation 后确定失败由 delegate cancel，
  //   backing 写入后失败留下 recovery evidence；delegate null status 归一化为
  //   INVALID_STATE，任一失败都清空 result，facade 不另设 timeout/cancel/resume。
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

  // 功能：请求共享 queue-data engine 对 CQ ring 做 quiesce、重建和原子切换。
  // 输入/输出及副作用：cq_h/new_depth/new_cqe_bytes 为输入，返回 rdma_status；成功时
  //   delegate 更新共享 attachment geometry，facade 不取得新旧 backing 所有权。
  // 失败/边界：未配置、binding 缺失/非 ACTIVE 返回 INVALID_STATE；Function 坐标漂移
  //   返回 STALE_GENERATION，configure_shared-only facade 不能 resize。非法 depth/
  //   entry size、并发 busy、pending cleanup recovery、
  //   quiesce/分配/发布前激活失败均由 delegate 拒绝并保留旧 ring；发布后的旧资源
  //   清理失败返回 RECOVERY_REQUIRED，此时新 attachment 保持有效。null status 归一化
  //   为 INVALID_STATE，其他非空失败对象原样保留。
  function rdma_status resize(rdma_handle cq_h, int unsigned new_depth,
                              int unsigned new_cqe_bytes);
    rdma_status status = validate_operation_authority("CQ resize");
    if (!status.ok())
      return status;

    return normalize_delegate_status(call_delegate_resize_cq(
      cq_h, new_depth, new_cqe_bytes), "resize_cq");
  endfunction
endclass
