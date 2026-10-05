// 目录：核心执行层 core/rdma_queue_lifecycle_executor.sv。
// 职责：实现 rdma_queue_lifecycle_executor 在本层的职责和对外接口。
// 依赖：依赖本层公共 types/model/adapter 契约及其上游快照。
// 所有权与生命周期：对象只拥有显式创建的值快照；外部资源保存非拥有引用，生命周期由调用方管理。

// 中文说明：rdma_queue_lifecycle_executor.sv 属于核心执行层，负责队列、控制面、资源和恢复流程。
// 阅读提示：先看公开类型和接口，再看实现细节；失败路径应保持状态与资源所有权可追踪。

class rdma_queue_lifecycle_executor extends uvm_object;
  `uvm_object_utils(rdma_queue_lifecycle_executor)

  protected rdma_resource_manager manager;
  protected rdma_cmq_port cmq;
  protected rdma_host_mem_api host_mem;
  protected rdma_context_backing_api context_backing;
  protected time command_timeout;
  protected rdma_cq_lifecycle_policy cq_policy;
  protected rdma_srq_lifecycle_policy srq_policy;
  protected rdma_ceq_lifecycle_policy ceq_policy;
  protected rdma_aeq_lifecycle_policy aeq_policy;
  protected rdma_queue_backing_planner planner;
  protected rdma_hw_queue_pd_codec pd_codec;

  // 功能：构造 rdma_queue_lifecycle_executor，调用 super.new 建立 UVM 对象，并把构造体直接写入的默认值设为：manager=null；cmq=null；host_mem=null；context_backing=null；command_timeout=0；cq_policy=rdma_cq_lifecycle_policy::type_id::create({name, "_cq"})；srq_policy=rdma_srq_lifecycle_policy::type_id::create({name, "_srq"})；ceq_policy=rdma_ceq_lifecycle_policy::type_id::create({name, "_ceq"})；其余字段按实现默认值初始化。
  // 输入/输出及副作用：name（输入）；new 只写入构造体列出的默认字段并返回 void，外部依赖与资源所有权仍由上层管理。
  // 失败/边界：rdma_queue_lifecycle_executor 构造只建立本地初始状态，不接管外部 Host-memory、PCIe 或 manager；未完成后续 configure/build/activate 时，业务入口必须返回 INVALID_STATE。
  function new(string name = "rdma_queue_lifecycle_executor");
    super.new(name);
    manager = null;
    cmq = null;
    host_mem = null;
    context_backing = null;
    command_timeout = 0;
    cq_policy = rdma_cq_lifecycle_policy::type_id::create({name, "_cq"});
    srq_policy = rdma_srq_lifecycle_policy::type_id::create({name, "_srq"});
    ceq_policy = rdma_ceq_lifecycle_policy::type_id::create({name, "_ceq"});
    aeq_policy = rdma_aeq_lifecycle_policy::type_id::create({name, "_aeq"});
    planner = rdma_queue_backing_planner::type_id::create({name, "_planner"});
    pd_codec = rdma_hw_queue_pd_codec::type_id::create({name, "_pd"});
  endfunction

  // 功能：在 rdma_queue_lifecycle_executor 中，invalid_argument 把错误消息、硬件码或注入故障封装为统一 rdma_status，保留原事务的诊断证据。
  // 输入/输出及副作用：message（输入）；invalid_argument 读取 message 并使用字段 rdma_status；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：invalid_argument 返回 RDMA_SC_INVALID_ARGUMENT；失败路径不提交部分状态或转移未声明资源。
  protected function rdma_status invalid_argument(string message);
    return rdma_status::make(RDMA_SC_INVALID_ARGUMENT, message);
  endfunction

  // 功能：在 rdma_queue_lifecycle_executor 中，invalid_state 把错误消息、硬件码或注入故障封装为统一 rdma_status，保留原事务的诊断证据。
  // 输入/输出及副作用：message（输入）；invalid_state 读取 message 并使用字段 rdma_status；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：invalid_state 返回 RDMA_SC_INVALID_STATE；失败路径不提交部分状态或转移未声明资源。
  protected function rdma_status invalid_state(string message);
    return rdma_status::make(RDMA_SC_INVALID_STATE, message);
  endfunction

  // 功能：在 rdma_queue_lifecycle_executor 中，normalize_status 把错误消息、硬件码或注入故障封装为统一 rdma_status，保留原事务的诊断证据。
  // 输入/输出及副作用：status（输入）、null_message（输入）；normalize_status 读取 status、null_message 并使用输入参数和固定枚举/常量；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：normalize_status 返回 RDMA_SC_INVALID_STATE；失败路径不提交部分状态或转移未声明资源。
  protected function rdma_status normalize_status(
    rdma_status status, string null_message
  );
    if (status == null)
      return invalid_state(null_message);
    return status;
  endfunction

  // 功能：在 rdma_queue_lifecycle_executor 中，cmq_outcome_ambiguous 检查当前事务或测试证据是否满足指定布尔条件，供恢复分类和断言选择后续路径。
  // 输入/输出及副作用：status（输入）、ticket（输入）、completion（输入）；cmq_outcome_ambiguous 读取 status、ticket、completion 并使用字段 code；函数返回 bit，不取得调用方资源所有权。
  // 失败/边界：cmq_outcome_ambiguous 比较或前置条件不满足时返回 0/false；该路径不隐式重试，也不转移未声明资源。
  protected function bit cmq_outcome_ambiguous(
    rdma_status status,
    rdma_cmq_ticket ticket,
    rdma_cmq_completion completion
  );
    return rdma_cmq_ambiguity_policy::is_ambiguous(
      status,
      ticket,
      completion,
      cmq != null && cmq.last_execute_definitive_no_submit(),
      1'b0,
      1'b1,
      1'b0
    );
  endfunction

  // 功能：在 rdma_queue_lifecycle_executor 中，configure 校验依赖和 binding 后建立运行边界，只保存非拥有引用并拒绝重复配置。
  // 输入/输出及副作用：manager（输入）、cmq（输入）、host_mem（输入）、context_backing（输入）、command_timeout（输入）；configure 先依据 manager == null || cmq == null || command_timeout == 0；cq_policy == null || srq_policy == null || ceq_policy == null || aeq_policy == null || planner == null || pd_codec == null；host_mem != null 校验 manager、cmq、host_mem、context_backing、command_timeout；成功时更新本对象配置/状态并保存非拥有引用，返回
  //   rdma_status。
  // 失败/边界：实现中的空依赖、重复登记、状态或 generation/authority 校验失败时返回错误；失败时保留旧配置。
  function rdma_status configure(
    rdma_resource_manager manager,
    rdma_cmq_port cmq,
    rdma_host_mem_api host_mem,
    rdma_context_backing_api context_backing,
    time command_timeout
  );
    rdma_status status;

    if (manager == null || cmq == null || command_timeout == 0)
      return invalid_argument("queue executor configuration is incomplete");
    if (cq_policy == null || srq_policy == null || ceq_policy == null ||
        aeq_policy == null || planner == null || pd_codec == null)
      return invalid_state("queue executor policy construction failed");
    if (host_mem != null) begin
      status = normalize_status(planner.configure(host_mem),
                                "queue planner configure returned null");
      if (!status.ok())
        return status;
    end
    this.manager = manager;
    this.cmq = cmq;
    this.host_mem = host_mem;
    this.context_backing = context_backing;
    this.command_timeout = command_timeout;
    return rdma_status::success();
  endfunction

  // 功能：make_result 通过 queue 域 lifecycle result seed 建立 detached 的未完成
  //   rdma_control_result，统一 transaction_id、初始资源状态和失败诊断，再交给
  //   queue create/destroy/recovery 逻辑追加各自阶段结果。
  // 输入/输出及副作用：transaction_id（输入）；返回写入 transaction_id、status、
  //   primary_status 和默认资源状态的 result，不读取 manager、CMQ 或 queue ledger，
  //   也不取得调用方资源所有权。
  // 失败/边界：result/seed 分配失败时返回空或不完整结果，调用入口必须沿既有 guard
  //   拒绝继续；seed 初始化失败不改变原错误优先级、不隐式重试、不发布半事务状态。
  protected function rdma_control_result make_result(
    longint unsigned transaction_id
  );
    rdma_control_result result;
    rdma_lifecycle_result_seed seed;
    rdma_status seed_status;

    result = rdma_control_result::type_id::create("queue_create_result");
    seed = rdma_lifecycle_result_seed::type_id::create(
      "queue_create_result_seed"
    );
    if (result == null || seed == null)
      return result;
    seed.transaction_id = transaction_id;
    seed.domain = RDMA_LIFECYCLE_DOMAIN_QUEUE;
    seed.pending_message = "queue create did not complete";
    seed_status = seed.initialize_result(result);
    if (seed_status == null || !seed_status.ok()) begin
      result.transaction_id = transaction_id;
      result.primary_status = invalid_state(
        "queue lifecycle result seed initialization failed"
      );
      result.status = rdma_cmq_clone_status_value(result.primary_status);
      result.final_resource_state = RDMA_RESOURCE_NEW;
      result.final_resource_state_known = 1'b0;
      result.recovery_required = 1'b0;
    end
    return result;
  endfunction

  // 功能：capture_cq_context 将 CQ create 阶段生成的 canonical CQC context
  //       复制到资源快照，作为后续 CQC_DELETE 的唯一 typed-body authority。
  // 输入/输出及副作用：resource 与 context_model 为输入；成功时只更新目标
  //       rdma_cq.programmed_cqc 的 detached clone，不接管原 context 或外部 backing。
  // 失败/边界：资源不是 CQ、context 不是 exact rdma_cqc_model、clone 失败或
  //       context 校验失败时返回错误，调用方不得继续提交 create descriptor。
  protected function rdma_status capture_cq_context(
    rdma_queue_resource resource,
    rdma_hw_model context_model
  );
    rdma_cq cq;
    rdma_cqc_model cqc;
    rdma_cqc_model cloned_cqc;
    rdma_status status;

    if (!$cast(cq, resource) || !$cast(cqc, context_model))
      return invalid_state("CQ context snapshot type is invalid");

    status = cqc.validate();
    if (status == null || !status.ok())
      return normalize_status(status, "CQ context snapshot validation failed");

    if (!rdma_deep_copy#(rdma_cqc_model)::try_of(cqc, cloned_cqc))
      return invalid_state("CQ context snapshot clone failed");

    cq.programmed_cqc = cloned_cqc;
    return rdma_status::success();
  endfunction

  // 功能：在 rdma_queue_lifecycle_executor 中由 same_owner 逐字段比较输入值，返回结构、身份或序列化内容是否一致。
  // 输入/输出及副作用：lhs（输入）、rhs（输入）；比较对象/数组只读；返回 bit 或状态结果，不更新 runtime、账本或外部 adapter。
  // 失败/边界：same_owner 的任一比较对象为空或类型不符时返回确定的 false/不等结果，不抛出未处理异常。
  protected function bit same_owner(
    rdma_function_handle lhs, rdma_function_handle rhs
  );
    return lhs != null && rhs != null && lhs.same_instance(rhs);
  endfunction

  // 功能：在 rdma_queue_lifecycle_executor 中，select_policy 把输入枚举或资源类型映射成对应的状态类别、执行引擎、opcode 或生命周期策略。
  // 输入/输出及副作用：request（输入）、policy（输出）；select_policy 读取 request、policy 并使用字段 policy，并写入 policy；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：select_policy 返回 RDMA_SC_UNSUPPORTED_OPCODE；典型拒绝条件为“queue create request type is unsupported”；失败路径不提交部分状态或转移未声明资源。
  protected function rdma_status select_policy(
    rdma_semantic_request request,
    output rdma_queue_lifecycle_policy policy
  );
    rdma_create_cq_req cq_request;
    rdma_create_srq_req srq_request;
    rdma_create_ceq_req ceq_request;
    rdma_create_aeq_req aeq_request;

    policy = null;
    if ($cast(cq_request, request))
      policy = cq_policy;
    else if ($cast(srq_request, request))
      policy = srq_policy;
    else if ($cast(ceq_request, request))
      policy = ceq_policy;
    else if ($cast(aeq_request, request))
      policy = aeq_policy;
    else
      return rdma_status::make(RDMA_SC_UNSUPPORTED_OPCODE,
                               "queue create request type is unsupported");
    return rdma_status::success();
  endfunction

  // 功能：generation_status 校验 binding、expected_owner 与当前对象状态的一致性，并显式处理“queue generation fence input is null”等拒绝条件，返回 rdma_status 供上层决定是否提交。
  // 输入/输出及副作用：binding（输入）、expected_owner（输入）；generation_status 读取 binding、expected_owner 并使用字段 status、live_owner；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：generation_status 返回 RDMA_SC_STALE_GENERATION、RDMA_SC_INVALID_ARGUMENT、RDMA_SC_INVALID_STATE；典型拒绝条件为“queue generation fence input is null”“queue create requires an ACTIVE binding”；失败路径不提交部分状态或转移未声明资源。
  protected virtual function rdma_status generation_status(
    rdma_function_binding binding,
    rdma_function_handle expected_owner
  );
    rdma_status status;
    rdma_function_handle live_owner;

    if (binding == null || expected_owner == null)
      return invalid_argument("queue generation fence input is null");
    status = normalize_status(binding.validate(),
                              "Function binding validation returned null");
    if (!status.ok())
      return status;
    if (binding.state != RDMA_BIND_ACTIVE)
      return invalid_state("queue create requires an ACTIVE binding");
    live_owner = binding.make_handle();
    if (!same_owner(live_owner, expected_owner))
      return rdma_status::make(RDMA_SC_STALE_GENERATION,
                               "Function generation changed during create");
    return rdma_status::success();
  endfunction

  // Named checkpoint used by lifecycle paths at lock/terminal boundaries.
  // Keeping it virtual lets tests inject a rebind while a CMQ gate is held
  // without mutating transaction-local authority.
  // 功能：在 rdma_queue_lifecycle_executor 中，live_binding_fence 读取并校验 Function generation/reset epoch，拒绝旧 binding 或跨 Function 请求。
  // 输入/输出及副作用：binding（输入）、expected_owner（输入）；live_binding_fence 读取 binding、expected_owner 并使用输入参数和固定枚举/常量；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：live_binding_fence 的结果直接由 return generation_status(binding, expected_owner) 计算；输入不满足表达式条件时沿函数体的保守分支返回，不修改已发布账本。
  protected virtual function rdma_status live_binding_fence(
    rdma_function_binding binding,
    rdma_function_handle expected_owner
  );
    return generation_status(binding, expected_owner);
  endfunction

  // 功能：在 rdma_queue_lifecycle_executor 中，populate_resource 把已验证的 backing 规格落实为 Host-memory 映射/队列计划，并登记释放责任。
  // 输入/输出及副作用：resource（输入）、preflight（输入）；populate_resource 读取 resource、preflight 并使用字段 resource.depth、resource.producer_index、resource.consumer_index、resource.producer_wrap、resource.consumer_wrap、cq.cqe_size_bytes、srq.max_sge、srq.limit_threshold；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：populate_resource 返回 RDMA_SC_UNSUPPORTED_OPCODE、RDMA_SC_INVALID_STATE；典型拒绝条件为“reserved queue does not match preflight”“CQ reservation local ID exceeds 21 bits”；失败路径不提交部分状态或转移未声明资源。
  protected function rdma_status populate_resource(
    rdma_queue_resource resource,
    rdma_queue_preflight preflight
  );
    rdma_cq cq;
    rdma_srq srq;
    rdma_ceq ceq;
    rdma_aeq aeq;

    if (resource == null || preflight == null || resource.handle == null ||
        resource.resource_kind() != preflight.resource_kind)
      return invalid_state("reserved queue does not match preflight");
    resource.depth = preflight.depth;
    resource.producer_index = 0;
    resource.consumer_index = 0;
    resource.producer_wrap = 1'b0;
    resource.consumer_wrap = 1'b0;
    case (resource.resource_kind())
      RDMA_RESOURCE_CQ: begin
        if (!$cast(cq, resource) || cq.local_cq_id > 21'h1f_ffff)
          return invalid_state("CQ reservation local ID exceeds 21 bits");
        cq.cqe_size_bytes = preflight.cqe_size_bytes;
      end
      RDMA_RESOURCE_SRQ: begin
        if (!$cast(srq, resource) || srq.local_srq_id > 16'hffff)
          return invalid_state("SRQ reservation local ID exceeds 16 bits");
        srq.max_sge = preflight.max_sge;
        srq.limit_threshold = preflight.limit_threshold;
      end
      RDMA_RESOURCE_CEQ: begin
        if (!$cast(ceq, resource) || ceq.local_ceq_id > 12'hfff)
          return invalid_state("CEQ reservation local ID exceeds 12 bits");
        ceq.function_local_vector = preflight.local_vector;
        ceq.hardware_vector = preflight.hardware_vector;
        ceq.msix_table_index = preflight.msix_table_index;
      end
      RDMA_RESOURCE_AEQ: begin
        if (!$cast(aeq, resource) || aeq.local_aeq_id > 12'hfff)
          return invalid_state("AEQ reservation local ID exceeds 12 bits");
        aeq.function_local_vector = preflight.local_vector;
        aeq.hardware_vector = preflight.hardware_vector;
        aeq.msix_table_index = preflight.msix_table_index;
      end
      default:
        return rdma_status::make(RDMA_SC_UNSUPPORTED_OPCODE,
                                 "queue resource type is unsupported");
    endcase
    return rdma_status::success();
  endfunction

  // 功能：在 rdma_queue_lifecycle_executor 中，cq_builder_view 把输入枚举或资源类型映射成对应的状态类别、执行引擎、opcode 或生命周期策略。
  // 输入/输出及副作用：authoritative（输入）、builder_resource（输出）；cq_builder_view 读取 authoritative、builder_resource 并使用字段 builder_resource、cloned_object、status、projected_ceq、projected_ceq.object_id、builder_cq.ceq_h，并写入 builder_resource；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：cq_builder_view 返回 RDMA_SC_INVALID_ARGUMENT、RDMA_SC_INVALID_STATE；典型拒绝条件为“CQ builder projection requires a CQ”“CQ builder projection clone failed”；失败路径不提交部分状态或转移未声明资源。
  protected function rdma_status cq_builder_view(
    rdma_queue_resource authoritative,
    output rdma_queue_resource builder_resource
  );
    rdma_cq cq;
    rdma_cq builder_cq;
    rdma_resource dependency_resource;
    rdma_ceq ceq;
    rdma_handle projected_ceq;
    rdma_status status;

    builder_resource = null;
    if (!$cast(cq, authoritative))
      return invalid_argument("CQ builder projection requires a CQ");
    if (!rdma_deep_copy#(rdma_cq)::try_of(cq, builder_cq))
      return invalid_state("CQ builder projection clone failed");
    if (cq.ceq_h != null) begin
      status = normalize_status(manager.lookup(cq.ceq_h, dependency_resource),
                                "CQ CEQ lookup returned null");
      if (!status.ok())
        return status;
      if (!$cast(ceq, dependency_resource) || ceq.local_ceq_id > 12'hfff)
        return invalid_state("CQ CEQ projection is invalid");
      projected_ceq = rdma_clone_handle_value(cq.ceq_h,
                                               "CQ local CEQ projection");
      if (projected_ceq == null)
        return invalid_state("CQ local CEQ projection clone failed");
      projected_ceq.object_id = ceq.local_ceq_id;
      builder_cq.ceq_h = projected_ceq;
    end
    builder_resource = builder_cq;
    return rdma_status::success();
  endfunction

  // 功能：在 rdma_queue_lifecycle_executor 中，srq_builder_view 把输入枚举或资源类型映射成对应的状态类别、执行引擎、opcode 或生命周期策略。
  // 输入/输出及副作用：authoritative（输入）、builder_resource（输出）；srq_builder_view 读取 authoritative、builder_resource 并使用字段 builder_resource、cloned_object、status、projected_pd、projected_pd.object_id、builder_srq.pd_h，并写入 builder_resource；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：srq_builder_view 返回 RDMA_SC_INVALID_ARGUMENT、RDMA_SC_INVALID_STATE；典型拒绝条件为“SRQ builder projection requires SRQ PD”“SRQ builder projection clone failed”；失败路径不提交部分状态或转移未声明资源。
  protected function rdma_status srq_builder_view(
    rdma_queue_resource authoritative,
    output rdma_queue_resource builder_resource
  );
    rdma_srq srq;
    rdma_srq builder_srq;
    rdma_resource dependency_resource;
    rdma_pd pd;
    rdma_handle projected_pd;
    rdma_status status;

    builder_resource = null;
    if (!$cast(srq, authoritative) || srq.pd_h == null)
      return invalid_argument("SRQ builder projection requires SRQ PD");
    if (!rdma_deep_copy#(rdma_srq)::try_of(srq, builder_srq))
      return invalid_state("SRQ builder projection clone failed");
    status = normalize_status(manager.lookup(srq.pd_h, dependency_resource),
                              "SRQ PD lookup returned null");
    if (!status.ok())
      return status;
    if (!$cast(pd, dependency_resource) || pd.local_pd_id > 16'hffff)
      return invalid_state("SRQ PD projection is invalid");
    projected_pd = rdma_clone_handle_value(srq.pd_h,
                                           "SRQ local PD projection");
    if (projected_pd == null)
      return invalid_state("SRQ local PD projection clone failed");
    projected_pd.object_id = pd.local_pd_id;
    builder_srq.pd_h = projected_pd;
    builder_resource = builder_srq;
    return rdma_status::success();
  endfunction

  // 功能：initialize_plan 为 planner 构造不含 context_ref 的临时初始化视图，并
  //       让 planner 对该视图执行 payload 清零和 PD 写入；视图的 rings、refs、
  //       flush_targets 只复制队列容器，元素仍暂借 authoritative_plan 的句柄。
  // 输入/输出及副作用：binding、authoritative_plan（输入）；函数只创建局部
  //       initialization_view 并调用 planner.initialize_payload_and_pd，写入的是
  //       外部 Host-memory 内容，不向调用方转移 plan、mapping 或 context 所有权；
  //       planner 返回的 status（可能为 null）经 normalize_status 作为结果输出。
  // 失败/边界：authoritative_plan 或视图创建失败、planner 返回 null/错误时立即
  //       返回且不登记新账本；不能在这里使用通用 deep clone，因为 mapping 的
  //       opaque release authority 必须由后续 authority-aware projector 维护。
  protected function rdma_status initialize_plan(
    rdma_function_binding binding,
    rdma_queue_backing_plan authoritative_plan
  );
    rdma_queue_backing_plan initialization_view;
    rdma_status status;

    if (authoritative_plan == null)
      return invalid_argument("queue initialization plan is null");
    initialization_view = rdma_queue_backing_plan::type_id::create(
      "queue_initialization_view"
    );
    if (initialization_view == null)
      return invalid_state("queue initialization plan creation failed");
    // The planner owns payload/PD initialization and intentionally accepts
    // only its context-free local view.  The transaction plan remains
    // context-attached and authoritative in the registry throughout.
    initialization_view.resource_kind = authoritative_plan.resource_kind;
    initialization_view.rings = authoritative_plan.rings;
    initialization_view.refs = authoritative_plan.refs;
    initialization_view.flush_targets = authoritative_plan.flush_targets;
    initialization_view.context_ref = null;
    status = planner.initialize_payload_and_pd(binding, initialization_view,
                                                pd_codec);
    return normalize_status(status,
                            "queue payload/PD initialization returned null");
  endfunction

  // 功能：在 rdma_queue_lifecycle_executor 中，delete_opcode delete_opcode 解除指定资源绑定并隔离 runtime/映射，避免旧句柄在删除后访问后端。
  // 输入/输出及副作用：kind（输入）；输入 handle/mapping/token 指定释放目标；成功时更新账本和生命周期，外部资源只按 adapter 契约释放。
  // 失败/边界：delete_opcode 发现 owner/generation 不匹配、记录未知或重复释放时返回错误或幂等结果，不重新激活旧句柄。
  protected function bit [7:0] delete_opcode(rdma_resource_kind_e kind);
    return rdma_queue_lifecycle_opcode_policy::delete_opcode(kind);
  endfunction

  // 功能：create_opcode 按资源 kind 返回对应的 CQC/SRFQC/CEQC/AEQC create opcode，未知 kind 返回 8'h00。
  // 输入/输出及副作用：kind（输入）；输入请求/句柄定义资源属性；成功时更新账本并通过返回值或 output 发布新句柄/映射。
  // 失败/边界：create_opcode 按 case(kind) 的固定映射计算 bit [7:0]（RDMA_RESOURCE_CQ→RDMA_OP_CQC_CREATE；RDMA_RESOURCE_SRQ→RDMA_OP_SRFQC_CREATE；RDMA_RESOURCE_CEQ→RDMA_OP_CEQC_CREATE；RDMA_RESOURCE_AEQ→RDMA_OP_AEQC_CREATE；default→8'h00）；未列出的输入走 default，不修改运行时账本。
  protected function bit [7:0] create_opcode(rdma_resource_kind_e kind);
    return rdma_queue_lifecycle_opcode_policy::create_opcode(kind);
  endfunction

  // 功能：在 rdma_queue_lifecycle_executor 中，query_opcode 按完整 key/handle 查找唯一权威记录并返回 detached 快照，避免把内部可变引用泄露给调用方。
  // 输入/输出及副作用：kind（输入）；query_opcode 读取 kind 并使用输入参数和固定枚举/常量；函数返回 bit [7:0]，不取得调用方资源所有权。
  // 失败/边界：query_opcode 在 key/handle 缺失、记录不唯一或 generation/reset epoch 过期时返回明确错误，不回退到默认 authority。
  protected function bit [7:0] query_opcode(rdma_resource_kind_e kind);
    return rdma_queue_lifecycle_opcode_policy::query_opcode(kind);
  endfunction

  // 功能：在 rdma_queue_lifecycle_executor 中，append_rollback 将输入对象登记或挂接到当前集合/依赖图，并同步维护对应账本和生命周期引用。
  // 输入/输出及副作用：result（输入）、status（输入）；append_rollback 可能更新本对象明确拥有的状态；函数返回 void，不取得调用方资源所有权。
  // 失败/边界：append_rollback 无返回值，仅执行 函数体中的顺序操作；调用方须保证前置依赖已经绑定，函数不自动重试或接管外部资源。
  protected function void append_rollback(
    rdma_control_result result, rdma_status status
  );
    if (result != null && status != null)
      result.rollback_statuses.push_back(
        rdma_cmq_clone_status_value(status)
      );
  endfunction

  // 功能：在 rdma_queue_lifecycle_executor 中，cleanup_local 按 owner、generation 和幂等规则释放或清理资源，同时删除相关账本记录。
  // 输入/输出及副作用：plan（输入）、result（输入）、record_progress（输入）、resource_h（输入）、null（输入）、null（输入）；cleanup_local 读取 plan、result、record_progress、resource_h、binding、expected_owner 并使用字段 first_failure、released_any、status、context_complete、complete；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：cleanup_local 下游操作失败时原样传播其 status/result，不伪造成功；该路径不隐式重试，也不转移未声明资源。
  protected function rdma_status cleanup_local(
    rdma_queue_backing_plan plan,
    rdma_control_result result,
    bit record_progress,
    rdma_handle resource_h,
    input rdma_function_binding binding = null,
    input rdma_function_handle expected_owner = null
  );
    rdma_status status;
    rdma_status first_failure;
    bit complete;
    bit released_any;

    first_failure = null;
    released_any = 1'b0;
    if (plan == null)
      return rdma_status::success();
    // A stale transaction may not publish cleanup progress into a newer
    // generation's registry entry.  Physical cleanup is resumable through
    // the durable plan, so stop before touching manager authority.
    if (binding != null && expected_owner != null) begin
      status = live_binding_fence(binding, expected_owner);
      if (!status.ok()) return status;
    end
    if (plan.context_ref != null && !plan.context_ref.release_complete) begin
      bit context_complete;

      context_complete = 1'b0;
      if (context_backing == null) begin
        status = invalid_state("queue context backing adapter is unavailable");
      end
      else begin
        // A context release can complete remotely while the process is
        // between the adapter call and its durable progress update.  Always
        // consult the opaque completion authority first so a retry never
        // invokes release twice.
        status = normalize_status(
          context_backing.query_release_completion(
            plan.context_ref, context_complete
          ), "queue context completion query returned null"
        );
        if (status.ok() && !context_complete)
          status = normalize_status(
            context_backing.\release (plan.context_ref),
            "queue context release returned null"
          );
        if (status.ok()) begin
          context_complete = 1'b0;
          status = normalize_status(
            context_backing.query_release_completion(
              plan.context_ref, context_complete
            ), "queue context completion recheck returned null"
          );
          if (status.ok() && !context_complete)
            status = invalid_state("queue context release did not complete");
        end
      end
      if (!status.ok()) begin
        append_rollback(result, status);
        if (first_failure == null) first_failure = status;
      end
      else begin
        released_any = 1'b1;
        if (record_progress) begin
          if (binding != null && expected_owner != null) begin
            status = live_binding_fence(binding, expected_owner);
            if (!status.ok()) begin
              append_rollback(result, status);
              if (first_failure == null) first_failure = status;
            end
          end
          if (status.ok()) begin
            // Persist the context completion immediately after its physical
            // release.  This leaves an authoritative proof in the manager
            // even if a later backing role fails and recovery must resume.
            status = normalize_status(
              manager.record_queue_context_cleanup_complete(resource_h),
              "queue context progress returned null"
            );
            if (!status.ok()) begin
              append_rollback(result, status);
              if (first_failure == null) first_failure = status;
            end
          end
        end
      end
    end
    for (int i = int'(plan.refs.size()) - 1; i >= 0; i--) begin
      if (plan.refs[i] == null || plan.refs[i].cleanup_complete)
        continue;
      complete = 1'b0;
      status = normalize_status(planner.cleanup_local_role(plan.refs[i],
                                                            complete),
                                "queue local cleanup returned null");
      if (!status.ok() || !complete) begin
        if (status.ok()) status = invalid_state("queue cleanup was incomplete");
        append_rollback(result, status);
        if (first_failure == null) first_failure = status;
      end
      else if (plan.refs[i].ownership == RDMA_OWNERSHIP_CONTROL_PLANE) begin
        released_any = 1'b1;
        if (record_progress) begin
          if (binding != null && expected_owner != null) begin
            status = live_binding_fence(binding, expected_owner);
            if (!status.ok()) begin
              append_rollback(result, status);
              if (first_failure == null) first_failure = status;
              continue;
            end
          end
          status = normalize_status(manager.record_queue_cleanup_complete(
            resource_h, plan.refs[i].role
          ), "queue cleanup progress returned null");
          if (!status.ok()) begin
            append_rollback(result, status);
            if (first_failure == null) first_failure = status;
          end
        end
      end
    end
    if (released_any)
      result.completed_steps.push_back(RDMA_CTRL_STEP_BACKING_RELEASED);
    return first_failure == null ? rdma_status::success() : first_failure;
  endfunction

  // 功能：build_recovery 组合 queue recovery 的临时证据（resource handle、完成/
  //       待办步骤、status/ticket、opcode key 和 queue_plan view），供紧随其后的
  //       manager.mark_error 投影；queue_plan 的 rings、refs、flush_targets 及
  //       context_ref 是 transient shallow view，并非最终账本的独立对象。
  // 输入/输出及副作用：policy、resource、plan、create_command、primary、result、
  //       presence、ambiguous_operation、ticket、pending_delete、pending_local_cleanup、
  //       intent（输入），recovery（输出）；enum 步骤按值复制，rollback_statuses
  //       的 status handle 与 plan 内 nested handle 暂时借用输入对象，不取得或
  //       转移 mapping/context 所有权；manager.mark_error 才负责 authority-aware
  //       detached projection。
  // 失败/边界：build_recovery 返回 RDMA_SC_INVALID_ARGUMENT、RDMA_SC_INVALID_STATE；
  //       典型拒绝条件为输入不完整、需要真实 CQC_DELETE 却没有 programmed
  //       CQC snapshot，或 queue recovery plan view 创建失败；仅在硬件确实
  //       absent 且无删除待办的 CQ pre-context 路径使用 opcode key，不伪造 body；
  //       recovery 在交给 manager 前不得被调用方修改或跨线程保存。
  protected function rdma_status build_recovery(
    rdma_queue_lifecycle_policy policy,
    rdma_queue_resource resource,
    rdma_queue_backing_plan plan,
    rdma_cmq_command_desc create_command,
    rdma_status primary,
    rdma_control_result result,
    rdma_hw_presence_e presence,
    rdma_queue_ambiguous_operation_e ambiguous_operation,
    rdma_cmq_ticket ticket,
    bit pending_delete,
    bit pending_local_cleanup,
    rdma_queue_recovery_intent_e intent,
    output rdma_recovery_record recovery
  );
    rdma_cmq_command_desc delete_command;
    rdma_cmq_command_desc query_command;
    rdma_status status;
    bit build_delete_descriptor;

    recovery = null;
    if (policy == null || resource == null || plan == null ||
        primary == null || result == null)
      return invalid_argument("queue recovery input is incomplete");
    // 设计说明：pre-context create 失败只拥有 ALLOCATED/staged 资源，硬件
    // context 从未提交，因而恢复记录不应强行构造 CQC_DELETE。CQC_DELETE
    // 的真实发送路径仍必须经过 policy 的 typed-body 校验；这里只在确有
    // 删除待办、硬件存在性未知/存在或已有歧义操作时调用该路径。
    build_delete_descriptor =
      resource.resource_kind() != RDMA_RESOURCE_CQ ||
      pending_delete ||
      presence != RDMA_HW_PRESENCE_ABSENT ||
      ambiguous_operation != RDMA_QUEUE_AMBIG_NONE;
    if (build_delete_descriptor) begin
      status = normalize_status(policy.build_object_command(
        delete_opcode(resource.resource_kind()), resource.owner, resource,
        command_timeout, delete_command
      ), "queue recovery delete descriptor returned null");
      if (!status.ok()) return status;
    end
    status = normalize_status(policy.build_object_command(
      query_opcode(resource.resource_kind()), resource.owner, resource,
      command_timeout, query_command
    ), "queue recovery query descriptor returned null");
    if (!status.ok()) return status;
    recovery = rdma_recovery_record::type_id::create("queue_create_recovery");
    recovery.resource_h = rdma_clone_handle_value(resource.handle,
                                                   "queue recovery");
    recovery.hardware_presence = presence;
    recovery.completed_steps = result.completed_steps;
    if (pending_delete)
      recovery.pending_steps.push_back(RDMA_CTRL_STEP_HW_CONTEXT_DELETED);
    if (pending_local_cleanup)
      recovery.pending_steps.push_back(RDMA_CTRL_STEP_BACKING_RELEASED);
    // A ticket is retained only when the adapter reported an ambiguous
    // outcome.  Definitive failures still return a ticket in many CMQ
    // adapters, but that ticket is not evidence awaiting reconciliation; if
    // it were persisted here, recovery would stop waiting for a terminal
    // result and never retry the failed operation.
    recovery.ambiguous_ticket = ambiguous_operation == RDMA_QUEUE_AMBIG_NONE ?
      null : rdma_cmq_clone_ticket_value(ticket, "queue recovery");
    recovery.primary_status = rdma_cmq_clone_status_value(primary);
    recovery.rollback_statuses = result.rollback_statuses;
    recovery.queue_recovery_valid = 1'b1;
    recovery.queue_intent = intent;
    recovery.ambiguous_queue_operation = ambiguous_operation;
    if (ambiguous_operation == RDMA_QUEUE_AMBIG_OCC_FLUSH) begin
      recovery.ambiguous_role = RDMA_QUEUE_ROLE_CQ_RING;
      foreach (plan.flush_targets[i]) begin
        if (plan.flush_targets[i] != null &&
            !plan.flush_targets[i].flush_complete) begin
          recovery.ambiguous_role = plan.flush_targets[i].role;
          break;
        end
      end
    end
    else
      recovery.ambiguous_role = plan.refs.size() == 0 ?
        RDMA_QUEUE_ROLE_CQ_RING : plan.refs[0].role;
    if (create_command != null && create_command.opcode_key != null) begin
      recovery.queue_create_opcode = rdma_cmq_clone_opcode_key_value(
        create_command.opcode_key, "queue recovery create"
      );
    end
    else begin
      recovery.queue_create_opcode = rdma_cmq_opcode_key::type_id::create(
        "queue_recovery_create_opcode"
      );
      recovery.queue_create_opcode.profile_name = "rdma";
      recovery.queue_create_opcode.opcode =
        create_opcode(resource.resource_kind());
      recovery.queue_create_opcode.variant = "create";
    end
    if (delete_command != null && delete_command.opcode_key != null) begin
      recovery.queue_delete_opcode = rdma_cmq_clone_opcode_key_value(
        delete_command.opcode_key, "queue recovery delete"
      );
    end
    else begin
      recovery.queue_delete_opcode = rdma_cmq_opcode_key::type_id::create(
        "queue_recovery_delete_opcode"
      );
      if (recovery.queue_delete_opcode == null)
        return invalid_state(
          "queue recovery delete opcode key allocation failed"
        );
      recovery.queue_delete_opcode.profile_name = "rdma";
      recovery.queue_delete_opcode.opcode =
        delete_opcode(resource.resource_kind());
      recovery.queue_delete_opcode.variant = "delete";
    end
    recovery.queue_query_opcode = rdma_cmq_clone_opcode_key_value(
      query_command.opcode_key, "queue recovery query"
    );
    // This is a transient, read-only carrier.  mark_error() projects it into
    // manager-owned storage before publication.  Avoid UVM's generic nested
    // clone here: the mapping contract carries opaque release authority that
    // must be copied by the resource manager's authority-aware projector.
    recovery.queue_plan = rdma_queue_backing_plan::type_id::create(
      "queue_recovery_plan_view"
    );
    if (recovery.queue_plan == null) begin
      recovery = null;
      return invalid_state("queue recovery plan view creation failed");
    end
    recovery.queue_plan.resource_kind = plan.resource_kind;
    recovery.queue_plan.rings = plan.rings;
    recovery.queue_plan.refs = plan.refs;
    recovery.queue_plan.context_ref = plan.context_ref;
    recovery.queue_plan.flush_targets = plan.flush_targets;
    status = normalize_status(recovery.validate(),
                              "queue recovery validation returned null");
    if (!status.ok()) recovery = null;
    return status;
  endfunction

  // 功能：在 rdma_queue_lifecycle_executor 中，publish_failure 提交当前事务阶段并发布 detached 结果，只有成功路径才推进游标或状态。
  // 输入/输出及副作用：primary（输入）、result（输入）、final_state（输入）、final_known（输入）、recovery_required（输入）；输入 request/image/cursor
  //   决定写入内容；成功时更新 PI/CI、slot ledger 或 pending journal，并通过 output 返回结果。
  // 失败/边界：队列未激活、credit 不足、请求身份过期或后端写入失败时返回错误；不得提前推进游标或重复提交。
  protected function void publish_failure(
    rdma_status primary,
    rdma_control_result result,
    rdma_resource_state_e final_state,
    bit final_known,
    bit recovery_required
  );
    rdma_status normalized;

    normalized = normalize_status(primary,
                                  "queue create failure status was null");
    result.primary_status = rdma_cmq_clone_status_value(normalized);
    result.final_resource_state = final_known ? final_state : RDMA_RESOURCE_NEW;
    result.final_resource_state_known = final_known;
    result.recovery_required = recovery_required;
    result.status = recovery_required ? rdma_status::make(
      RDMA_SC_RECOVERY_REQUIRED, "queue state requires recovery"
    ) : rdma_cmq_clone_status_value(normalized);
  endfunction

  // 功能：执行 retain_recovery_int 指定的测试或恢复状态变更，更新受控账本并保留可回滚的故障证据。
  // 输入/输出及副作用：policy（输入）、resource（输入）、plan（输入）、create_command（输入）、primary（输入）、result（输入）、presence（输入）、ambiguous_operation（输入）、ticket（输入）、pending_delete（输入）、pending_local_cleanup（输入）、intent（输入）、queue（输出）；retain_recovery_int 读取 policy、resource、plan、create_command、primary、result、presence、ambiguous_operation、ticket、pending_delete、pending_local_cleanup、intent、queue 并使用字段 queue、status，并写入 queue；函数返回 void，不取得调用方资源所有权。
  // 失败/边界：retain_recovery_int 仅允许测试/恢复范围内的状态变更；代际或资源不匹配时拒绝并保留原账本。
  protected function void retain_recovery_int(
    rdma_queue_lifecycle_policy policy,
    rdma_queue_resource resource,
    rdma_queue_backing_plan plan,
    rdma_cmq_command_desc create_command,
    rdma_status primary,
    rdma_control_result result,
    rdma_hw_presence_e presence,
    rdma_queue_ambiguous_operation_e ambiguous_operation,
    rdma_cmq_ticket ticket,
    bit pending_delete,
    bit pending_local_cleanup,
    rdma_queue_recovery_intent_e intent,
    output rdma_queue_resource queue
  );
    rdma_recovery_record recovery;
    rdma_resource snapshot;
    rdma_status status;

    queue = null;
    status = build_recovery(policy, resource, plan, create_command, primary,
                            result, presence, ambiguous_operation, ticket,
                            pending_delete, pending_local_cleanup, intent, recovery);
    status = normalize_status(status, "queue recovery build returned null");
    if (status.ok())
      status = normalize_status(manager.mark_error(resource.handle, recovery),
                                "queue mark ERROR returned null");
    if (!status.ok()) begin
      append_rollback(result, status);
    end
    else begin
      status = normalize_status(manager.lookup(resource.handle, snapshot),
                                "queue ERROR lookup returned null");
      if (status.ok() && !$cast(queue, snapshot))
        status = invalid_state("queue ERROR snapshot type mismatch");
      if (!status.ok()) append_rollback(result, status);
    end
    publish_failure(primary, result, RDMA_RESOURCE_ERROR, status.ok(), 1'b1);
  endfunction

  // 功能：执行 retain_recovery 指定的测试或恢复状态变更，更新受控账本并保留可回滚的故障证据。
  // 输入/输出及副作用：policy（输入）、resource（输入）、plan（输入）、create_command（输入）、primary（输入）、result（输入）、presence（输入）、ambiguous_operation（输入）、ticket（输入）、pending_delete（输入）、pending_local_cleanup（输入）、queue（输出）；retain_recovery 读取 policy、resource、plan、create_command、primary、result、presence、ambiguous_operation、ticket、pending_delete、pending_local_cleanup、queue 并使用输入参数和固定枚举/常量，并写入 queue；函数返回 void，不取得调用方资源所有权。
  // 失败/边界：retain_recovery 仅允许测试/恢复范围内的状态变更；代际或资源不匹配时拒绝并保留原账本。
  protected function void retain_recovery(
    rdma_queue_lifecycle_policy policy, rdma_queue_resource resource,
    rdma_queue_backing_plan plan, rdma_cmq_command_desc create_command,
    rdma_status primary, rdma_control_result result, rdma_hw_presence_e presence,
    rdma_queue_ambiguous_operation_e ambiguous_operation, rdma_cmq_ticket ticket,
    bit pending_delete, bit pending_local_cleanup, output rdma_queue_resource queue
  );
    retain_recovery_int(policy, resource, plan, create_command, primary, result,
                        presence, ambiguous_operation, ticket,
                        pending_delete, pending_local_cleanup,
                        RDMA_QUEUE_RECOVER_CREATE_ROLLBACK, queue);
  endfunction

  // 功能：执行 retain_reservation_release_recovery 指定的测试或恢复状态变更，更新受控账本并保留可回滚的故障证据。
  // 输入/输出及副作用：policy（输入）、resource（输入）、plan（输入）、create_command（输入）、primary（输入）、result（输入）、queue（输出）；retain_reservation_release_recovery 读取 policy、resource、plan、create_command、primary、result、queue 并使用字段 queue、status，并写入 queue；函数返回 void，不取得调用方资源所有权。
  // 失败/边界：retain_reservation_release_recovery 仅允许测试/恢复范围内的状态变更；代际或资源不匹配时拒绝并保留原账本。
  protected function void retain_reservation_release_recovery(
    rdma_queue_lifecycle_policy policy,
    rdma_queue_resource resource,
    rdma_queue_backing_plan plan,
    rdma_cmq_command_desc create_command,
    rdma_status primary,
    rdma_control_result result,
    output rdma_queue_resource queue
  );
    rdma_recovery_record recovery;
    rdma_resource snapshot;
    rdma_status status;

    queue = null;
    status = build_recovery(
      policy, resource, plan, create_command, primary, result,
      RDMA_HW_PRESENCE_ABSENT, RDMA_QUEUE_AMBIG_NONE, null,
      1'b0, 1'b0, RDMA_QUEUE_RECOVER_CREATE_ROLLBACK, recovery
    );
    status = normalize_status(
      status, "queue reservation recovery build returned null"
    );
    if (status.ok()) begin
      recovery.pending_steps.push_back(RDMA_CTRL_STEP_RESOURCE_RELEASED);
      status = normalize_status(
        recovery.validate(), "queue reservation recovery validation returned null"
      );
    end
    if (status.ok())
      status = normalize_status(manager.mark_error(resource.handle, recovery),
                                "queue reservation mark ERROR returned null");
    if (!status.ok()) begin
      append_rollback(result, status);
    end
    else begin
      status = normalize_status(manager.lookup(resource.handle, snapshot),
                                "queue reservation ERROR lookup returned null");
      if (status.ok() && !$cast(queue, snapshot))
        status = invalid_state("queue reservation ERROR snapshot type mismatch");
      if (!status.ok()) append_rollback(result, status);
    end
    publish_failure(primary, result, RDMA_RESOURCE_ERROR, status.ok(), 1'b1);
  endfunction

  // 功能：queue_policy_for_kind 根据 kind、policy 执行 rdma_status 结果转换，具体更新字段 policy；失败时返回 RDMA_SC_UNSUPPORTED_OPCODE、RDMA_SC_INVALID_STATE，保持已登记资源和输出不变。
  // 输入/输出及副作用：kind（输入）、policy（输出）；queue_policy_for_kind 读取 kind、policy 并使用字段 policy，并写入 policy；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：queue_policy_for_kind 返回 RDMA_SC_UNSUPPORTED_OPCODE、RDMA_SC_INVALID_STATE；典型拒绝条件为“queue recovery kind is unsupported”“queue recovery policy is unavailable”；失败路径不提交部分状态或转移未声明资源。
  protected function rdma_status queue_policy_for_kind(
    rdma_resource_kind_e kind,
    output rdma_queue_lifecycle_policy policy
  );
    policy = null;
    case (kind)
      RDMA_RESOURCE_CQ:  policy = cq_policy;
      RDMA_RESOURCE_SRQ: policy = srq_policy;
      RDMA_RESOURCE_CEQ: policy = ceq_policy;
      RDMA_RESOURCE_AEQ: policy = aeq_policy;
      default:
        return rdma_status::make(RDMA_SC_UNSUPPORTED_OPCODE,
                                 "queue recovery kind is unsupported");
    endcase
    if (policy == null)
      return invalid_state("queue recovery policy is unavailable");
    return rdma_status::success();
  endfunction

  // 功能：在 rdma_queue_lifecycle_executor 中，persist_queue_recovery 记录或执行队列恢复步骤，依据提交证据选择重试、提交或回滚并保持操作幂等。
  // 输入/输出及副作用：resource_h（输入）、recovery（输入）、null（输入）、null（输入）；persist_queue_recovery 读取 resource_h、recovery、binding、expected_owner 并使用字段 status；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：persist_queue_recovery 返回 函数体规定的失败状态；具体拒绝条件包括 “queue recovery persistence input is incomplete”；“queue recovery persistence returned null”；失败路径不提交部分状态、不隐式重试，也不转移未声明资源。
  protected function rdma_status persist_queue_recovery(
    rdma_handle resource_h,
    rdma_recovery_record recovery,
    rdma_function_binding binding = null,
    rdma_function_handle expected_owner = null
  );
    rdma_status status;

    if (manager == null || resource_h == null || recovery == null)
      return invalid_argument("queue recovery persistence input is incomplete");
    if (binding != null && expected_owner != null) begin
      status = live_binding_fence(binding, expected_owner);
      if (!status.ok()) return status;
    end
    status = manager.mark_error(resource_h, recovery);
    return normalize_status(status, "queue recovery persistence returned null");
  endfunction

  // 功能：queue_flushes_complete 比较 plan 与当前 authority/状态字段，返回布尔结果供上层执行精确分支。
  // 输入/输出及副作用：plan（输入）；queue_flushes_complete 读取 plan 并使用字段 i、flush_complete；函数返回 bit，不取得调用方资源所有权。
  // 失败/边界：queue_flushes_complete 比较或前置条件不满足时返回 0/false；该路径不隐式重试，也不转移未声明资源。
  protected function bit queue_flushes_complete(
    rdma_queue_backing_plan plan
  );
    if (plan == null)
      return 1'b0;
    foreach (plan.flush_targets[i]) begin
      if (plan.flush_targets[i] == null ||
          !plan.flush_targets[i].flush_complete)
        return 1'b0;
    end
    return 1'b1;
  endfunction

  // 功能：queue_local_cleanup_complete 比较 plan 与当前 authority/状态字段，返回布尔结果供上层执行精确分支。
  // 输入/输出及副作用：plan（输入）；queue_local_cleanup_complete 读取 plan 并使用字段 release_complete、ownership、cleanup_complete；函数返回 bit，不取得调用方资源所有权。
  // 失败/边界：queue_local_cleanup_complete 比较或前置条件不满足时返回 0/false；该路径不隐式重试，也不转移未声明资源。
  protected function bit queue_local_cleanup_complete(
    rdma_queue_backing_plan plan
  );
    if (plan == null)
      return 1'b0;
    if (plan.context_ref != null && !plan.context_ref.release_complete)
      return 1'b0;
    foreach (plan.refs[i]) begin
      if (plan.refs[i] == null)
        return 1'b0;
      // Borrowed mappings are detached, not released, and therefore retain
      // cleanup_complete=0 by contract.
      if (plan.refs[i].ownership == RDMA_OWNERSHIP_CONTROL_PLANE &&
          !plan.refs[i].cleanup_complete)
        return 1'b0;
    end
    return 1'b1;
  endfunction

  // 功能：在 rdma_queue_lifecycle_executor 中，execute_queue_command 统一消费一次
  // legacy CMQ execute，归一化 ticket、completion 和状态，并计算提交证据是否不可判定。
  // 输入/输出及副作用：command（输入）、ticket/completion/status/ambiguous（输出）、
  // binding/expected_owner（可选输入）、null_status_message/completion_lost_message（输入）；
  // 任务只调用一次 cmq.execute，不取得 command、ticket 或外部资源所有权。binding 与
  // expected_owner 同时非空时执行一次 post-execute generation fence；两者为空时由调用方
  // 保留 fence checkpoint。
  // 失败/边界：cmq 或 command 为空时返回 INVALID_ARGUMENT；legacy execute 返回 null
  // status、缺失 completion、timeout/reset 或 fence 失败时保持 fail-closed 结果，不推进
  // 队列游标；调用方提供的诊断消息只用于对应 null 结果分支。
  protected task execute_queue_command(
    rdma_cmq_command_desc command,
    output rdma_cmq_ticket ticket,
    output rdma_cmq_completion completion,
    output rdma_status status,
    output bit ambiguous,
    input rdma_function_binding binding = null,
    input rdma_function_handle expected_owner = null,
    input string null_status_message = "queue CMQ execution returned null",
    input string completion_lost_message = "queue CMQ completion was lost"
  );
    rdma_status execute_status;

    if (cmq == null || command == null) begin
      ticket = null;
      completion = null;
      ambiguous = 1'b0;
      status = invalid_argument("queue CMQ command is incomplete");
      return;
    end
    ambiguous = 1'b0;
    rdma_cmq_dispatch_legacy_raw(
      cmq,
      command,
      ticket,
      completion,
      execute_status,
      "queue CMQ is unavailable",
      "queue CMQ command is incomplete"
    );
    if (binding != null && expected_owner != null) begin
      rdma_status fence_status;
      fence_status = live_binding_fence(binding, expected_owner);
      if (!fence_status.ok()) begin
        status = fence_status;
        return;
      end
    end
    ambiguous = cmq_outcome_ambiguous(execute_status, ticket, completion);
    status = normalize_status(execute_status, null_status_message);
    if (status.ok() && (completion == null || completion.status == null))
      status = invalid_state(completion_lost_message);
  endtask

  // 功能：在 rdma_queue_lifecycle_executor 中，rollback_created 按 owner、generation 和幂等规则释放/隔离记录，并同步删除其账本引用。
  // 输入/输出及副作用：binding（输入）、expected_owner（输入）、policy（输入）、resource（输入）、plan（输入）、create_command（输入）、primary（输入）、result（输入）、registry_programmed（输入）、queue（输出）；输入
  //   handle/mapping/token 指定释放目标；成功时更新账本和生命周期，外部资源只按 adapter 契约释放。
  // 失败/边界：rollback_created 发现 owner/generation 不匹配、记录未知或重复释放时返回错误或幂等结果，不重新激活旧句柄。
  protected task rollback_created(
    rdma_function_binding binding,
    rdma_function_handle expected_owner,
    rdma_queue_lifecycle_policy policy,
    rdma_queue_resource resource,
    rdma_queue_backing_plan plan,
    rdma_cmq_command_desc create_command,
    rdma_status primary,
    rdma_control_result result,
    bit registry_programmed,
    output rdma_queue_resource queue
  );
    rdma_cmq_command_desc command;
    rdma_cmq_ticket ticket;
    rdma_cmq_completion completion;
    rdma_status status;
    rdma_status fence_status;
    rdma_hw_presence_e presence;
    bit ambiguous;

    queue = null;
    status = live_binding_fence(binding, expected_owner);
    if (!status.ok()) return;
    foreach (plan.flush_targets[i]) begin
      if (plan.flush_targets[i] == null ||
          plan.flush_targets[i].phase != RDMA_QUEUE_FLUSH_PRE_DELETE ||
          plan.flush_targets[i].flush_complete)
        continue;
      status = normalize_status(policy.build_flush_command(
        resource.owner, plan.flush_targets[i], command_timeout, command
      ), "queue rollback pre-delete flush descriptor returned null");
      if (status.ok()) begin
        // 设计说明：rollback_created 保留 fence checkpoint 的原位置和“失败即返回”
        // 语义，因此故意让 helper 不接管 binding/owner；helper 只负责 legacy CMQ
        // 输出、ambiguity 与 null-result 归一化。
        execute_queue_command(
          command, ticket, completion, status, ambiguous, null, null,
          "queue rollback pre-delete flush result was lost",
          "queue rollback pre-delete flush completion was lost"
        );
        fence_status = live_binding_fence(binding, expected_owner);
        if (!fence_status.ok()) return;
      end
      else ambiguous = 1'b0;
      if (!status.ok()) begin
        fence_status = live_binding_fence(binding, expected_owner);
        if (!fence_status.ok()) return;
        append_rollback(result, status);
        retain_recovery(policy, resource, plan, create_command, primary, result,
                        RDMA_HW_PRESENCE_PRESENT,
                        ambiguous ? RDMA_QUEUE_AMBIG_OCC_FLUSH :
                                    RDMA_QUEUE_AMBIG_NONE,
                        ambiguous ? ticket : null, 1'b1, 1'b1, queue);
        return;
      end
      plan.flush_targets[i].flush_complete = 1'b1;
      result.completed_steps.push_back(RDMA_CTRL_STEP_HW_OCC_FLUSHED);
    end
    status = normalize_status(policy.build_object_command(
      delete_opcode(resource.resource_kind()), resource.owner, resource,
      command_timeout, command
    ), "queue rollback delete descriptor returned null");
    if (!status.ok()) begin
      fence_status = live_binding_fence(binding, expected_owner);
      if (!fence_status.ok()) return;
      append_rollback(result, status);
      retain_recovery(policy, resource, plan, create_command, primary, result,
                      RDMA_HW_PRESENCE_PRESENT, RDMA_QUEUE_AMBIG_NONE, null,
                      1'b1, 1'b1, queue);
      return;
    end
    execute_queue_command(
      command, ticket, completion, status, ambiguous, null, null,
      "queue rollback delete result was lost",
      "queue rollback delete completion was lost"
    );
    fence_status = live_binding_fence(binding, expected_owner);
    if (!fence_status.ok()) return;
    if (!status.ok()) begin
      fence_status = live_binding_fence(binding, expected_owner);
      if (!fence_status.ok()) return;
      append_rollback(result, status);
      presence = ambiguous ? RDMA_HW_PRESENCE_UNKNOWN : RDMA_HW_PRESENCE_PRESENT;
      retain_recovery(policy, resource, plan, create_command, primary, result,
                      presence,
                      ambiguous ? RDMA_QUEUE_AMBIG_DELETE : RDMA_QUEUE_AMBIG_NONE,
                      ambiguous ? ticket : null, 1'b1, 1'b1, queue);
      return;
    end
    result.completed_steps.push_back(RDMA_CTRL_STEP_HW_CONTEXT_DELETED);
    foreach (plan.flush_targets[i]) begin
      if (plan.flush_targets[i] == null ||
          plan.flush_targets[i].phase != RDMA_QUEUE_FLUSH_POST_DELETE ||
          plan.flush_targets[i].flush_complete)
        continue;
      status = normalize_status(policy.build_flush_command(
        resource.owner, plan.flush_targets[i], command_timeout, command
      ), "queue rollback post-delete flush descriptor returned null");
      if (status.ok()) begin
        execute_queue_command(
          command, ticket, completion, status, ambiguous, null, null,
          "queue rollback post-delete flush result was lost",
          "queue rollback post-delete flush completion was lost"
        );
        fence_status = live_binding_fence(binding, expected_owner);
        if (!fence_status.ok()) return;
      end
      else ambiguous = 1'b0;
      if (!status.ok()) begin
        fence_status = live_binding_fence(binding, expected_owner);
        if (!fence_status.ok()) return;
        append_rollback(result, status);
        retain_recovery(policy, resource, plan, create_command, primary, result,
                        RDMA_HW_PRESENCE_ABSENT,
                        ambiguous ? RDMA_QUEUE_AMBIG_OCC_FLUSH :
                                    RDMA_QUEUE_AMBIG_NONE,
                        ambiguous ? ticket : null, 1'b0, 1'b1, queue);
        return;
      end
      plan.flush_targets[i].flush_complete = 1'b1;
      result.completed_steps.push_back(RDMA_CTRL_STEP_HW_OCC_FLUSHED);
    end

    if (registry_programmed) begin
      rdma_recovery_record recovery;
      status = build_recovery(policy, resource, plan, create_command, primary,
                              result, RDMA_HW_PRESENCE_ABSENT,
                              RDMA_QUEUE_AMBIG_NONE, null, 1'b0, 1'b0,
                              RDMA_QUEUE_RECOVER_CREATE_ROLLBACK, recovery);
      if (status.ok())
        status = live_binding_fence(binding, expected_owner);
      if (status.ok())
        status = normalize_status(manager.mark_error(resource.handle, recovery),
                                  "programmed queue mark ERROR returned null");
      if (!status.ok()) begin
        append_rollback(result, status);
        publish_failure(primary, result, RDMA_RESOURCE_ERROR, 1'b0, 1'b1);
        return;
      end
    end
    status = live_binding_fence(binding, expected_owner);
    if (!status.ok()) return;
    status = cleanup_local(plan, result, registry_programmed,
                           resource.handle, binding, expected_owner);
    if (!status.ok()) begin
      if (status.code == RDMA_SC_STALE_GENERATION) return;
      retain_recovery(policy, resource, plan, create_command, primary, result,
                      RDMA_HW_PRESENCE_ABSENT, RDMA_QUEUE_AMBIG_NONE, null,
                      1'b0, 1'b1, queue);
      return;
    end
    status = live_binding_fence(binding, expected_owner);
    if (!status.ok()) return;
    status = registry_programmed ? manager.finalize_release(resource.handle) :
                                   manager.release_reserved(resource.handle);
    status = normalize_status(status, "queue reservation release returned null");
    if (!status.ok()) begin
      append_rollback(result, status);
      if (!registry_programmed)
        retain_reservation_release_recovery(
          policy, resource, plan, create_command, primary, result, queue
        );
      else
        publish_failure(primary, result, RDMA_RESOURCE_ERROR, 1'b1, 1'b1);
      return;
    end
    result.completed_steps.push_back(RDMA_CTRL_STEP_RESOURCE_RELEASED);
    publish_failure(primary, result, RDMA_RESOURCE_RELEASED, 1'b1, 1'b0);
  endtask

  // 功能：在 rdma_queue_lifecycle_executor 中，rollback_local 按 owner、generation 和幂等规则释放/隔离记录，并同步删除其账本引用。
  // 输入/输出及副作用：binding（输入）、expected_owner（输入）、policy（输入）、resource（输入）、plan（输入）、create_command（输入）、primary（输入）、result（输入）、queue（输出）；输入
  //   handle/mapping/token 指定释放目标；成功时更新账本和生命周期，外部资源只按 adapter 契约释放。
  // 失败/边界：rollback_local 发现 owner/generation 不匹配、记录未知或重复释放时返回错误或幂等结果，不重新激活旧句柄。
  protected function void rollback_local(
    rdma_function_binding binding,
    rdma_function_handle expected_owner,
    rdma_queue_lifecycle_policy policy,
    rdma_queue_resource resource,
    rdma_queue_backing_plan plan,
    rdma_cmq_command_desc create_command,
    rdma_status primary,
    rdma_control_result result,
    output rdma_queue_resource queue
  );
    rdma_status status;

    queue = null;
    status = live_binding_fence(binding, expected_owner);
    if (!status.ok()) begin
      publish_failure(status, result,
        resource == null ? RDMA_RESOURCE_NEW : RDMA_RESOURCE_ALLOCATED,
        resource != null, 1'b0);
      return;
    end
    status = cleanup_local(plan, result, 1'b0,
                           resource == null ? null : resource.handle,
                           binding, expected_owner);
    if (!status.ok() && resource != null && plan != null) begin
      if (status.code == RDMA_SC_STALE_GENERATION) begin
        publish_failure(status, result, RDMA_RESOURCE_ALLOCATED, 1'b1, 1'b0);
        return;
      end
      retain_recovery(policy, resource, plan, create_command, primary, result,
                      RDMA_HW_PRESENCE_ABSENT, RDMA_QUEUE_AMBIG_NONE, null,
                      1'b0, 1'b1, queue);
      return;
    end
    if (resource != null) begin
      status = live_binding_fence(binding, expected_owner);
      if (status.ok()) status = normalize_status(manager.release_reserved(resource.handle),
                                "queue reservation release returned null");
      if (!status.ok()) begin
        append_rollback(result, status);
        if (plan != null) begin
          retain_reservation_release_recovery(
            policy, resource, plan, create_command, primary, result, queue
          );
          return;
        end
      end
      else result.completed_steps.push_back(RDMA_CTRL_STEP_RESOURCE_RELEASED);
    end
    publish_failure(primary, result,
      resource == null ? RDMA_RESOURCE_NEW :
      (status.ok() ? RDMA_RESOURCE_RELEASED : RDMA_RESOURCE_ALLOCATED),
      resource != null, !status.ok());
  endfunction

  // 设计说明：ERROR queue recovery 的 pre-delete 与 post-delete OCC 重试都必须在
  // 同一个 detached target 上执行一次 CMQ、完成 generation fence，再由 manager 记录
  // role progress；两条 caller 仍分别决定 barrier、ambiguity、持久化和下一状态。
  // 该 task 不读取 recovery ledger，也不修改 queue_plan.flush_complete，避免把恢复账本
  // 的提交权从 recover_locked 转移到公共 helper。
  // 功能：execute_recovery_flush_step 构造并执行一个 recovery OCC flush，返回 CMQ 证据
  //   和 manager progress 状态，供 recover_locked 选择重试、持久化或终止恢复。
  // 输入/输出及副作用：binding、expected_owner、policy、target、resource_h 和两条诊断
  //   文案为输入；status、ticket、completion、ambiguous 为输出。成功时写入指定 resource
  //   的 target.role progress，但不修改 target 的 flush_complete 标志；execute_failed 与
  //   progress_failed 额外指出 CMQ/fence 或 manager 阶段失败，供 caller 保留原诊断分支。
  // 失败/边界：authority/target/manager/CMQ 缺失、descriptor 构造失败、CMQ/fence 失败或
  //   manager 返回 null/失败时不写 role progress；timeout/reset、缺失 completion 或
  //   no-submit 证明保留 execute_queue_command 的 ambiguous 结果，由 caller 建立持久
  //   recovery evidence。descriptor/progress 文案只影响诊断，不改变错误码或重试顺序。
  protected task execute_recovery_flush_step(
    rdma_function_binding binding,
    rdma_function_handle expected_owner,
    rdma_queue_lifecycle_policy policy,
    rdma_queue_flush_target target,
    rdma_handle resource_h,
    input string descriptor_null_message,
    input string progress_null_message,
    output rdma_status status,
    output rdma_cmq_ticket ticket,
    output rdma_cmq_completion completion,
    output bit ambiguous,
    output bit execute_failed,
    output bit progress_failed
  );
    rdma_cmq_command_desc command;
    rdma_status fence_status;

    status = rdma_status::success();
    ticket = null;
    completion = null;
    ambiguous = 1'b0;
    execute_failed = 1'b0;
    progress_failed = 1'b0;
    if (binding == null || expected_owner == null || policy == null ||
        target == null || resource_h == null || manager == null || cmq == null) begin
      status = invalid_argument("queue recovery flush authority is incomplete");
      return;
    end
    command = null;
    status = normalize_status(policy.build_flush_command(
      expected_owner, target, command_timeout, command
    ), descriptor_null_message);
    if (!status.ok())
      return;
    execute_queue_command(command, ticket, completion, status, ambiguous,
                          binding, expected_owner);
    if (!status.ok()) begin
      execute_failed = 1'b1;
      return;
    end
    fence_status = live_binding_fence(binding, expected_owner);
    if (!fence_status.ok()) begin
      status = fence_status;
      execute_failed = 1'b1;
      return;
    end
    status = normalize_status(
      manager.record_queue_flush_complete(resource_h, target.role),
      progress_null_message
    );
    if (!status.ok())
      progress_failed = 1'b1;
  endtask

  // Recover an ERROR queue while the caller owns the per-Function lifecycle
  // semaphore.  Transaction-ID allocation and locking deliberately remain in
  // the control-plane facade; this task only advances the durable queue
  // recipe and never publishes an ACTIVE object itself.
  // 功能：在 rdma_queue_lifecycle_executor 中，recover_locked 执行受控事务并按后端提交证据推进状态机，同时保留失败阶段和 generation 证据。
  // 输入/输出及副作用：binding（输入）、expected_owner（输入）、resource_h（输入）、transaction_id（输入）、result（输出）；输入 action/epoch/handle
  //   决定迁移目标；成功时更新状态或恢复证据，外部资源仍由其拥有者管理。
  // 失败/边界：recover_locked 遇到锁、超时、generation 变化或提交证据不完整时保持原状态，不推进游标。
  task recover_locked(
    rdma_function_binding binding,
    rdma_function_handle expected_owner,
    rdma_handle resource_h,
    longint unsigned transaction_id,
    output rdma_control_result result
  );
    rdma_resource snapshot;
    rdma_queue_resource queue;
    rdma_queue_lifecycle_policy policy;
    rdma_recovery_record recovery;
    rdma_recovery_record refreshed;
    rdma_cmq_command_desc command;
    rdma_cmq_ticket ticket;
    rdma_cmq_completion completion;
    rdma_status status;
    rdma_status completion_status;
    rdma_status classify_status;
    rdma_status persist_status;
    rdma_status reconcile_status;
    rdma_hw_presence_e query_presence;
    bit query_conclusive;
    bit terminal_known;
    bit ambiguous;
    bit done;
    bit creation_origin;
    bit local_done;
    bit predelete_target;
    bit execute_failed;
    bit progress_failed;
    int target_index;
    int unsigned i;
    rdma_queue_backing_role_e target_role;
    rdma_queue_flush_phase_e target_phase;

    result = make_result(transaction_id);
    done = 1'b0;
    status = rdma_status::success();

    do begin
      if (transaction_id == 0) begin
        status = invalid_argument("queue recovery transaction ID is zero");
        break;
      end
      if (manager == null || cmq == null || command_timeout == 0) begin
        status = invalid_state("queue recovery executor is not configured");
        break;
      end
      if (binding == null || expected_owner == null || resource_h == null) begin
        status = invalid_argument("queue recovery authority is incomplete");
        break;
      end
      status = live_binding_fence(binding, expected_owner);
      if (!status.ok()) break;
      status = queue_policy_for_kind(resource_h.kind, policy);
      if (!status.ok()) break;

      status = normalize_status(manager.lookup(resource_h, snapshot),
                                "queue recovery lookup returned null");
      if (!status.ok()) break;
      if (!$cast(queue, snapshot) || queue == null ||
          queue.state != RDMA_RESOURCE_ERROR) begin
        status = invalid_state("queue recovery requires an ERROR queue");
        break;
      end
      if (!same_owner(queue.owner, expected_owner)) begin
        status = invalid_argument("queue recovery owner mismatch");
        break;
      end
      result.resource_h = rdma_clone_handle_value(queue.handle,
                                                   "queue recovery result");
      status = normalize_status(manager.lookup_recovery(resource_h, recovery),
                                "queue recovery record lookup returned null");
      if (!status.ok()) break;
      if (recovery == null || !recovery.queue_recovery_valid ||
          recovery.queue_plan == null || recovery.primary_status == null) begin
        status = invalid_state("queue recovery record is incomplete");
        break;
      end
      if (recovery.resource_h == null ||
          !recovery.resource_h.same_instance(queue.handle) ||
          recovery.queue_plan.resource_kind != queue.resource_kind()) begin
        status = invalid_state("queue recovery record identity is inconsistent");
        break;
      end
      status = normalize_status(recovery.validate(),
                                "queue recovery record validation returned null");
      if (!status.ok()) break;
      creation_origin = recovery.queue_intent == RDMA_QUEUE_RECOVER_CREATE_ROLLBACK;
      rdma_recovery_project_history(recovery, result);

      // Reconcile any earlier ambiguous command before issuing another CMQ
      // command for this queue.
      if (recovery.ambiguous_ticket != null) begin
        ticket = recovery.ambiguous_ticket;
        terminal_known = 1'b0;
        completion = null;
        reconcile_status = null;
        cmq.reconcile(ticket, terminal_known, completion, reconcile_status);
        status = live_binding_fence(binding, expected_owner);
        if (!status.ok()) begin
          rdma_recovery_publish_required(recovery, result,
            "queue reconciliation fenced by stale generation");
          done = 1'b1;
          break;
        end
        reconcile_status = normalize_status(reconcile_status,
          "queue CMQ reconciliation returned null");
        if (!terminal_known) begin
          rdma_recovery_publish_required(recovery, result,
            "ambiguous queue command has no terminal result");
          if (!reconcile_status.ok())
            result.rollback_statuses.push_back(
              rdma_cmq_clone_status_value(reconcile_status));
          done = 1'b1;
          break;
        end
        if (completion == null || completion.status == null) begin
          recovery.rollback_statuses.push_back(
            invalid_state("queue reconciliation completion is incomplete"));
          void'(persist_queue_recovery(resource_h, recovery, binding, expected_owner));
          rdma_recovery_publish_required(recovery, result,
            "queue reconciliation still requires recovery");
          done = 1'b1;
          break;
        end
        completion_status = normalize_status(completion.status,
          "queue reconciliation status returned null");
        if (completion_status.code inside {RDMA_SC_TIMEOUT,
                                          RDMA_SC_RESET_CANCELLED}) begin
          rdma_recovery_publish_required(recovery, result,
            "queue reconciliation has no trustworthy terminal evidence");
          done = 1'b1;
          break;
        end
        if (ticket.opcode_key == null) begin
          recovery.rollback_statuses.push_back(
            invalid_state("queue reconciliation ticket has no opcode"));
          void'(persist_queue_recovery(resource_h, recovery, binding, expected_owner));
          rdma_recovery_publish_required(recovery, result,
            "queue reconciliation ticket is invalid");
          done = 1'b1;
          break;
        end

        // A QUERY can itself be ambiguous.  Its terminal result is handled
        // through the same ticket field, but is classified rather than
        // projected as a create/delete completion.
        if (ticket.opcode_key.opcode == query_opcode(queue.resource_kind())) begin
          query_presence = RDMA_HW_PRESENCE_UNKNOWN;
          query_conclusive = 1'b0;
          classify_status = policy.classify_query_completion(
            queue, completion, query_presence, query_conclusive);
          classify_status = normalize_status(classify_status,
            "queue QUERY classification returned null");
          recovery.ambiguous_ticket = null;
          recovery.ambiguous_queue_operation = RDMA_QUEUE_AMBIG_NONE;
          if (classify_status.ok() && query_conclusive) begin
            recovery.hardware_presence = query_presence;
            if (query_presence == RDMA_HW_PRESENCE_ABSENT)
              rdma_recovery_remove_pending(recovery, RDMA_CTRL_STEP_HW_CONTEXT_DELETED);
            else
              rdma_recovery_queue_step(recovery, RDMA_CTRL_STEP_HW_CONTEXT_DELETED);
            persist_status = persist_queue_recovery(resource_h, recovery, binding, expected_owner);
            if (!persist_status.ok()) begin
              rdma_recovery_publish_required(recovery, result,
                "reconciled queue QUERY progress could not be persisted");
              done = 1'b1;
              break;
            end
          end
          else begin
            if (!classify_status.ok())
              recovery.rollback_statuses.push_back(
                rdma_cmq_clone_status_value(classify_status));
            recovery.hardware_presence = RDMA_HW_PRESENCE_UNKNOWN;
            persist_status = persist_queue_recovery(resource_h, recovery, binding, expected_owner);
            rdma_recovery_publish_required(recovery, result,
              "reconciled queue QUERY was inconclusive");
            if (!persist_status.ok())
              result.rollback_statuses.push_back(
                rdma_cmq_clone_status_value(persist_status));
            done = 1'b1;
            break;
          end
        end
        else if (ticket.opcode_key.opcode == create_opcode(queue.resource_kind())) begin
          recovery.ambiguous_ticket = null;
          recovery.ambiguous_queue_operation = RDMA_QUEUE_AMBIG_NONE;
          if (completion_status.ok()) begin
            recovery.hardware_presence = RDMA_HW_PRESENCE_PRESENT;
            rdma_recovery_complete_step(recovery, RDMA_CTRL_STEP_HW_CONTEXT_CREATED);
            rdma_recovery_queue_step(recovery, RDMA_CTRL_STEP_HW_CONTEXT_DELETED);
          end
          else begin
            // Definitive create failure proves no queue object was installed.
            recovery.hardware_presence = RDMA_HW_PRESENCE_ABSENT;
            rdma_recovery_remove_pending(recovery, RDMA_CTRL_STEP_HW_CONTEXT_DELETED);
            recovery.rollback_statuses.push_back(
              rdma_cmq_clone_status_value(completion_status));
          end
            persist_status = persist_queue_recovery(resource_h, recovery, binding, expected_owner);
          if (!persist_status.ok()) begin
            rdma_recovery_publish_required(recovery, result,
              "reconciled queue create progress could not be persisted");
            done = 1'b1;
            break;
          end
        end
        else if (ticket.opcode_key.opcode == delete_opcode(queue.resource_kind())) begin
          recovery.ambiguous_ticket = null;
          recovery.ambiguous_queue_operation = RDMA_QUEUE_AMBIG_NONE;
          if (completion_status.ok()) begin
            recovery.hardware_presence = RDMA_HW_PRESENCE_ABSENT;
            rdma_recovery_complete_step(recovery, RDMA_CTRL_STEP_HW_CONTEXT_DELETED);
          end
          else begin
            recovery.hardware_presence = RDMA_HW_PRESENCE_PRESENT;
            rdma_recovery_queue_step(recovery, RDMA_CTRL_STEP_HW_CONTEXT_DELETED);
            recovery.rollback_statuses.push_back(
              rdma_cmq_clone_status_value(completion_status));
          end
            persist_status = persist_queue_recovery(resource_h, recovery, binding, expected_owner);
          if (!persist_status.ok()) begin
            rdma_recovery_publish_required(recovery, result,
              "reconciled queue delete progress could not be persisted");
            done = 1'b1;
            break;
          end
          if (!completion_status.ok()) begin
            // A normal destroy has not started any local cleanup at this
            // point.  A definitive terminal delete failure therefore proves
            // that the queue is still PRESENT and is safe to restore to its
            // pre-destroy ACTIVE publication.  Keep create-rollback recovery
            // on the destructive retry path: a failed create must still be
            // unwound, never resurrected.
            if (!creation_origin && recovery.hardware_presence ==
                  RDMA_HW_PRESENCE_PRESENT) begin
              status = live_binding_fence(binding, expected_owner);
              if (status.ok()) status = normalize_status(manager.restore_active(resource_h),
                "queue delete failure restore ACTIVE returned null");
              if (status.ok()) begin
                rdma_recovery_project_history(recovery, result);
                // The terminal failure is the operation's observable result;
                // the durable primary timeout remains in the recovery history
                // and rollback list for callers that inspect it.
                result.status = rdma_cmq_clone_status_value(completion_status);
                result.final_resource_state = RDMA_RESOURCE_ACTIVE;
                result.final_resource_state_known = 1'b1;
                result.recovery_required = 1'b0;
                done = 1'b1;
                break;
              end
              recovery.rollback_statuses.push_back(
                rdma_cmq_clone_status_value(status));
            persist_status = persist_queue_recovery(resource_h, recovery, binding, expected_owner);
              rdma_recovery_publish_required(recovery, result,
                "queue delete failure ACTIVE restore still requires recovery");
              if (!persist_status.ok())
                result.rollback_statuses.push_back(
                  rdma_cmq_clone_status_value(persist_status));
              done = 1'b1;
              break;
            end
            rdma_recovery_publish_required(recovery, result,
              "queue delete terminal failure requires a retry");
            done = 1'b1;
            break;
          end
        end
        else if (ticket.opcode_key.opcode == RDMA_OP_OCC_FLUSH) begin
          recovery.ambiguous_ticket = null;
          recovery.ambiguous_queue_operation = RDMA_QUEUE_AMBIG_NONE;
          predelete_target = 1'b0;
          foreach (recovery.queue_plan.flush_targets[i]) begin
            if (recovery.queue_plan.flush_targets[i] != null &&
                recovery.queue_plan.flush_targets[i].role ==
                  recovery.ambiguous_role &&
                recovery.queue_plan.flush_targets[i].phase ==
                  RDMA_QUEUE_FLUSH_PRE_DELETE)
              predelete_target = 1'b1;
          end
          if (completion_status.ok()) begin
            target_index = -1;
            foreach (recovery.queue_plan.flush_targets[i]) begin
              if (recovery.queue_plan.flush_targets[i] != null &&
                  recovery.queue_plan.flush_targets[i].role ==
                    recovery.ambiguous_role) begin
                target_index = int'(i);
                break;
              end
            end
            if (target_index < 0) begin
              recovery.rollback_statuses.push_back(
                invalid_state("reconciled OCC target is missing"));
          void'(persist_queue_recovery(resource_h, recovery, binding, expected_owner));
              rdma_recovery_publish_required(recovery, result,
                "queue OCC target cannot be identified");
              done = 1'b1;
              break;
            end
            if (!recovery.queue_plan.flush_targets[target_index].flush_complete) begin
              status = live_binding_fence(binding, expected_owner);
              if (status.ok()) status = normalize_status(
                manager.record_queue_flush_complete(
                  resource_h, recovery.ambiguous_role),
                "reconciled queue OCC progress returned null");
              if (!status.ok()) begin
                recovery.rollback_statuses.push_back(
                  rdma_cmq_clone_status_value(status));
          void'(persist_queue_recovery(resource_h, recovery, binding, expected_owner));
                rdma_recovery_publish_required(recovery, result,
                  "reconciled queue OCC progress failed");
                done = 1'b1;
                break;
              end
            end
            recovery.queue_plan.flush_targets[target_index].flush_complete = 1'b1;
            rdma_recovery_complete_step(recovery, RDMA_CTRL_STEP_HW_OCC_FLUSHED);
          end
          else begin
            // Keep this role incomplete and stop at the barrier.  A later
            // recovery invocation may retry the exact target.
            if (!creation_origin && predelete_target)
              recovery.hardware_presence = RDMA_HW_PRESENCE_PRESENT;
            recovery.rollback_statuses.push_back(
              rdma_cmq_clone_status_value(completion_status));
            if (!creation_origin && predelete_target) begin
            persist_status = persist_queue_recovery(resource_h, recovery, binding, expected_owner);
              if (persist_status.ok()) begin
                status = live_binding_fence(binding, expected_owner);
                if (status.ok()) status = normalize_status(manager.restore_active(resource_h),
                  "queue OCC failure restore ACTIVE returned null");
                if (status.ok()) begin
                  rdma_recovery_project_history(recovery, result);
                  result.status = rdma_cmq_clone_status_value(
                    completion_status);
                  result.final_resource_state = RDMA_RESOURCE_ACTIVE;
                  result.final_resource_state_known = 1'b1;
                  result.recovery_required = 1'b0;
                  done = 1'b1;
                  break;
                end
                recovery.rollback_statuses.push_back(
                  rdma_cmq_clone_status_value(status));
              end
              else
                recovery.rollback_statuses.push_back(
                  rdma_cmq_clone_status_value(persist_status));
              // If either persistence or the atomic restore failed, retain
              // the PRESENT recovery record for a later retry.
            persist_status = persist_queue_recovery(resource_h, recovery, binding, expected_owner);
              rdma_recovery_publish_required(recovery, result,
                "queue OCC failure ACTIVE restore still requires recovery");
              if (!persist_status.ok())
                result.rollback_statuses.push_back(
                  rdma_cmq_clone_status_value(persist_status));
              done = 1'b1;
              break;
            end
            persist_status = persist_queue_recovery(resource_h, recovery, binding, expected_owner);
            rdma_recovery_publish_required(recovery, result,
              "queue OCC target still requires recovery");
            if (!persist_status.ok())
              result.rollback_statuses.push_back(
                rdma_cmq_clone_status_value(persist_status));
            done = 1'b1;
            break;
          end
            persist_status = persist_queue_recovery(resource_h, recovery, binding, expected_owner);
          if (!persist_status.ok()) begin
            rdma_recovery_publish_required(recovery, result,
              "reconciled queue OCC progress could not be persisted");
            done = 1'b1;
            break;
          end
        end
        else begin
          recovery.rollback_statuses.push_back(
            rdma_status::make(RDMA_SC_UNSUPPORTED_OPCODE,
                              "queue recovery ticket opcode is unsupported"));
          void'(persist_queue_recovery(resource_h, recovery, binding, expected_owner));
          rdma_recovery_publish_required(recovery, result,
            "queue recovery ticket opcode is unsupported");
          done = 1'b1;
          break;
        end
      end

      // If presence remains unknown, issue exactly one typed QUERY.  QUERY
      // establishes only object presence, never OCC completion.
      if (recovery.hardware_presence == RDMA_HW_PRESENCE_UNKNOWN &&
          recovery.ambiguous_ticket == null) begin
        status = normalize_status(policy.build_object_command(
          query_opcode(queue.resource_kind()), expected_owner, queue,
          command_timeout, command),
          "queue recovery QUERY descriptor returned null");
        if (!status.ok()) begin
          recovery.rollback_statuses.push_back(
            rdma_cmq_clone_status_value(status));
          void'(persist_queue_recovery(resource_h, recovery, binding, expected_owner));
          rdma_recovery_publish_required(recovery, result,
            "queue QUERY descriptor could not be built");
          done = 1'b1;
          break;
        end
        execute_queue_command(command, ticket, completion, status, ambiguous,
                              binding, expected_owner);
        if (ambiguous) begin
          recovery.ambiguous_ticket = rdma_cmq_clone_ticket_value(
            ticket, "queue QUERY recovery");
          recovery.ambiguous_queue_operation =
            (creation_origin && !rdma_recovery_step_completed(
              recovery, RDMA_CTRL_STEP_HW_CONTEXT_CREATED)) ?
              RDMA_QUEUE_AMBIG_CREATE : RDMA_QUEUE_AMBIG_DELETE;
            persist_status = persist_queue_recovery(resource_h, recovery, binding, expected_owner);
          rdma_recovery_publish_required(recovery, result,
            "queue QUERY has no terminal result");
          if (!persist_status.ok())
            result.rollback_statuses.push_back(
              rdma_cmq_clone_status_value(persist_status));
          done = 1'b1;
          break;
        end
        if (!status.ok() || completion == null || completion.status == null) begin
          if (status == null) status = invalid_state("queue QUERY result is null");
          recovery.rollback_statuses.push_back(
            rdma_cmq_clone_status_value(status));
          void'(persist_queue_recovery(resource_h, recovery, binding, expected_owner));
          rdma_recovery_publish_required(recovery, result,
            "queue QUERY failed to establish presence");
          done = 1'b1;
          break;
        end
        query_presence = RDMA_HW_PRESENCE_UNKNOWN;
        query_conclusive = 1'b0;
        classify_status = policy.classify_query_completion(
          queue, completion, query_presence, query_conclusive);
        classify_status = normalize_status(classify_status,
          "queue QUERY classification returned null");
        if (!classify_status.ok() || !query_conclusive) begin
          if (!classify_status.ok())
            recovery.rollback_statuses.push_back(
              rdma_cmq_clone_status_value(classify_status));
          void'(persist_queue_recovery(resource_h, recovery, binding, expected_owner));
          rdma_recovery_publish_required(recovery, result,
            "queue QUERY response is inconclusive");
          done = 1'b1;
          break;
        end
        recovery.hardware_presence = query_presence;
        if (query_presence == RDMA_HW_PRESENCE_ABSENT)
          rdma_recovery_remove_pending(recovery, RDMA_CTRL_STEP_HW_CONTEXT_DELETED);
        else
          rdma_recovery_queue_step(recovery, RDMA_CTRL_STEP_HW_CONTEXT_DELETED);
            persist_status = persist_queue_recovery(resource_h, recovery, binding, expected_owner);
        if (!persist_status.ok()) begin
          rdma_recovery_publish_required(recovery, result,
            "queue QUERY progress could not be persisted");
          done = 1'b1;
          break;
        end
      end

      if (recovery.hardware_presence == RDMA_HW_PRESENCE_UNKNOWN) begin
        rdma_recovery_publish_required(recovery, result,
          "queue hardware presence remains unknown");
        done = 1'b1;
        break;
      end

      // Execute persisted OCC targets in order.  This enforces the SRQ
      // pre-delete barrier and defers CQ post-delete flushes until absence.
      for (i = 0; i < recovery.queue_plan.flush_targets.size(); i++) begin
        if (recovery.queue_plan.flush_targets[i] == null) begin
          recovery.rollback_statuses.push_back(
            invalid_state("queue recovery flush target is null"));
          void'(persist_queue_recovery(resource_h, recovery, binding, expected_owner));
          rdma_recovery_publish_required(recovery, result,
            "queue OCC recipe is invalid");
          done = 1'b1;
          break;
        end
        if (recovery.queue_plan.flush_targets[i].flush_complete)
          continue;
        target_phase = recovery.queue_plan.flush_targets[i].phase;
        if (target_phase == RDMA_QUEUE_FLUSH_POST_DELETE &&
            recovery.hardware_presence != RDMA_HW_PRESENCE_ABSENT)
          continue;
        target_role = recovery.queue_plan.flush_targets[i].role;
        execute_recovery_flush_step(
          binding, expected_owner, policy,
          recovery.queue_plan.flush_targets[i], resource_h,
          "queue recovery OCC descriptor returned null",
          "queue OCC progress returned null",
          status, ticket, completion, ambiguous, execute_failed,
          progress_failed
        );
        if (!status.ok() && !execute_failed && !progress_failed) begin
          recovery.rollback_statuses.push_back(
            rdma_cmq_clone_status_value(status));
          void'(persist_queue_recovery(resource_h, recovery, binding, expected_owner));
          rdma_recovery_publish_required(recovery, result,
            "queue OCC descriptor could not be built");
          done = 1'b1;
          break;
        end
        if (ambiguous) begin
          recovery.ambiguous_ticket = rdma_cmq_clone_ticket_value(
            ticket, "queue OCC recovery");
          recovery.ambiguous_queue_operation = RDMA_QUEUE_AMBIG_OCC_FLUSH;
          recovery.ambiguous_role = target_role;
            persist_status = persist_queue_recovery(resource_h, recovery, binding, expected_owner);
          rdma_recovery_publish_required(recovery, result,
            "queue OCC target has no terminal result");
          if (!persist_status.ok())
            result.rollback_statuses.push_back(
              rdma_cmq_clone_status_value(persist_status));
          done = 1'b1;
          break;
        end
        if (!status.ok()) begin
          recovery.rollback_statuses.push_back(
            rdma_cmq_clone_status_value(status));
            persist_status = persist_queue_recovery(resource_h, recovery, binding, expected_owner);
          rdma_recovery_publish_required(recovery, result,
            progress_failed ?
              "queue OCC progress could not be persisted" :
              "queue OCC target failed");
          if (!persist_status.ok())
            result.rollback_statuses.push_back(
              rdma_cmq_clone_status_value(persist_status));
          done = 1'b1;
          break;
        end
        recovery.queue_plan.flush_targets[i].flush_complete = 1'b1;
        rdma_recovery_complete_step(recovery, RDMA_CTRL_STEP_HW_OCC_FLUSHED);
            persist_status = persist_queue_recovery(resource_h, recovery, binding, expected_owner);
        if (!persist_status.ok()) begin
          rdma_recovery_publish_required(recovery, result,
            "queue OCC progress could not be persisted");
          done = 1'b1;
          break;
        end
      end
      if (done) break;

      // A PRESENT queue still needs delete.  For SRQ this is reached only
      // after all pre-delete OCC targets above are complete.
      if (recovery.hardware_presence == RDMA_HW_PRESENCE_PRESENT &&
          !rdma_recovery_step_completed(recovery, RDMA_CTRL_STEP_HW_CONTEXT_DELETED)) begin
        for (i = 0; i < recovery.queue_plan.flush_targets.size(); i++) begin
          if (recovery.queue_plan.flush_targets[i] != null &&
              recovery.queue_plan.flush_targets[i].phase ==
                RDMA_QUEUE_FLUSH_PRE_DELETE &&
              !recovery.queue_plan.flush_targets[i].flush_complete) begin
            rdma_recovery_publish_required(recovery, result,
              "queue pre-delete OCC barrier is incomplete");
            done = 1'b1;
            break;
          end
        end
        if (done) break;
        status = normalize_status(policy.build_object_command(
          delete_opcode(queue.resource_kind()), expected_owner, queue,
          command_timeout, command),
          "queue recovery delete descriptor returned null");
        if (!status.ok()) begin
          recovery.rollback_statuses.push_back(
            rdma_cmq_clone_status_value(status));
          void'(persist_queue_recovery(resource_h, recovery, binding, expected_owner));
          rdma_recovery_publish_required(recovery, result,
            "queue delete descriptor could not be built");
          done = 1'b1;
          break;
        end
        execute_queue_command(command, ticket, completion, status, ambiguous,
                              binding, expected_owner);
        if (ambiguous) begin
          recovery.ambiguous_ticket = rdma_cmq_clone_ticket_value(
            ticket, "queue delete recovery");
          recovery.ambiguous_queue_operation = RDMA_QUEUE_AMBIG_DELETE;
          recovery.ambiguous_role = recovery.queue_plan.refs.size() == 0 ?
            RDMA_QUEUE_ROLE_CQ_RING : recovery.queue_plan.refs[0].role;
          recovery.hardware_presence = RDMA_HW_PRESENCE_UNKNOWN;
            persist_status = persist_queue_recovery(resource_h, recovery, binding, expected_owner);
          rdma_recovery_publish_required(recovery, result,
            "queue delete has no terminal result");
          if (!persist_status.ok())
            result.rollback_statuses.push_back(
              rdma_cmq_clone_status_value(persist_status));
          done = 1'b1;
          break;
        end
        if (!status.ok()) begin
          recovery.hardware_presence = RDMA_HW_PRESENCE_PRESENT;
          rdma_recovery_queue_step(recovery, RDMA_CTRL_STEP_HW_CONTEXT_DELETED);
          recovery.rollback_statuses.push_back(
            rdma_cmq_clone_status_value(status));
            persist_status = persist_queue_recovery(resource_h, recovery, binding, expected_owner);
          rdma_recovery_publish_required(recovery, result,
            "queue delete failed");
          if (!persist_status.ok())
            result.rollback_statuses.push_back(
              rdma_cmq_clone_status_value(persist_status));
          done = 1'b1;
          break;
        end
        recovery.hardware_presence = RDMA_HW_PRESENCE_ABSENT;
        rdma_recovery_complete_step(recovery, RDMA_CTRL_STEP_HW_CONTEXT_DELETED);
            persist_status = persist_queue_recovery(resource_h, recovery, binding, expected_owner);
        if (!persist_status.ok()) begin
          rdma_recovery_publish_required(recovery, result,
            "queue delete progress could not be persisted");
          done = 1'b1;
          break;
        end
      end

      if (recovery.hardware_presence != RDMA_HW_PRESENCE_ABSENT) begin
        rdma_recovery_publish_required(recovery, result,
          "queue hardware absence is not proven");
        done = 1'b1;
        break;
      end

      // The first OCC loop intentionally skipped post-delete targets while
      // PRESENT.  Revisit those targets after delete/QUERY absence.
      for (i = 0; i < recovery.queue_plan.flush_targets.size(); i++) begin
        if (recovery.queue_plan.flush_targets[i] == null ||
            recovery.queue_plan.flush_targets[i].flush_complete ||
            recovery.queue_plan.flush_targets[i].phase !=
              RDMA_QUEUE_FLUSH_POST_DELETE)
          continue;
        target_role = recovery.queue_plan.flush_targets[i].role;
        execute_recovery_flush_step(
          binding, expected_owner, policy,
          recovery.queue_plan.flush_targets[i], resource_h,
          "queue post-delete OCC descriptor returned null",
          "queue post-delete OCC progress returned null",
          status, ticket, completion, ambiguous, execute_failed,
          progress_failed
        );
        if (!status.ok() && !execute_failed && !progress_failed) begin
          recovery.rollback_statuses.push_back(
            rdma_cmq_clone_status_value(status));
          void'(persist_queue_recovery(resource_h, recovery, binding, expected_owner));
          rdma_recovery_publish_required(recovery, result,
            "queue post-delete OCC descriptor failed");
          done = 1'b1;
          break;
        end
        if (ambiguous) begin
          recovery.ambiguous_ticket = rdma_cmq_clone_ticket_value(
            ticket, "queue post-delete OCC recovery");
          recovery.ambiguous_queue_operation = RDMA_QUEUE_AMBIG_OCC_FLUSH;
          recovery.ambiguous_role = target_role;
            persist_status = persist_queue_recovery(resource_h, recovery, binding, expected_owner);
          rdma_recovery_publish_required(recovery, result,
            "queue post-delete OCC has no terminal result");
          if (!persist_status.ok())
            result.rollback_statuses.push_back(
              rdma_cmq_clone_status_value(persist_status));
          done = 1'b1;
          break;
        end
        if (!status.ok()) begin
          recovery.rollback_statuses.push_back(
            rdma_cmq_clone_status_value(status));
            persist_status = persist_queue_recovery(resource_h, recovery, binding, expected_owner);
          rdma_recovery_publish_required(recovery, result,
            progress_failed ?
              "queue post-delete OCC progress failed" :
              "queue post-delete OCC failed");
          if (!persist_status.ok())
            result.rollback_statuses.push_back(
              rdma_cmq_clone_status_value(persist_status));
          done = 1'b1;
          break;
        end
        recovery.queue_plan.flush_targets[i].flush_complete = 1'b1;
        rdma_recovery_complete_step(recovery, RDMA_CTRL_STEP_HW_OCC_FLUSHED);
            persist_status = persist_queue_recovery(resource_h, recovery, binding, expected_owner);
        if (!persist_status.ok()) begin
          rdma_recovery_publish_required(recovery, result,
            "queue post-delete OCC progress failed");
          done = 1'b1;
          break;
        end
      end
      if (done) break;
      if (!queue_flushes_complete(recovery.queue_plan)) begin
        rdma_recovery_publish_required(recovery, result,
          "queue OCC recipe remains incomplete");
        done = 1'b1;
        break;
      end

      local_done = queue_local_cleanup_complete(recovery.queue_plan);
      if (!local_done) begin
        status = live_binding_fence(binding, expected_owner);
        if (status.ok())
          status = cleanup_local(recovery.queue_plan, result, 1'b1, resource_h,
                                 binding, expected_owner);
        status = normalize_status(status,
          "queue local recovery cleanup returned null");
        refreshed = null;
        persist_status = manager.lookup_recovery(resource_h, refreshed);
        persist_status = normalize_status(persist_status,
          "queue local recovery refresh returned null");
        if (persist_status.ok() && refreshed != null)
          recovery = refreshed;
        if (!status.ok()) begin
          recovery.rollback_statuses.push_back(
            rdma_cmq_clone_status_value(status));
          void'(persist_queue_recovery(resource_h, recovery, binding, expected_owner));
          rdma_recovery_publish_required(recovery, result,
            "queue local cleanup still requires recovery");
          done = 1'b1;
          break;
        end
        if (!persist_status.ok()) begin
          recovery.rollback_statuses.push_back(
            rdma_cmq_clone_status_value(persist_status));
          rdma_recovery_publish_required(recovery, result,
            "queue local cleanup progress is unavailable");
          done = 1'b1;
          break;
        end
      end
      local_done = queue_local_cleanup_complete(recovery.queue_plan);
      if (!local_done) begin
        rdma_recovery_publish_required(recovery, result,
          "queue local cleanup remains incomplete");
        done = 1'b1;
        break;
      end

      rdma_recovery_complete_step(recovery, RDMA_CTRL_STEP_BACKING_RELEASED);
      // A normal destroy is an unstaged, already-published queue.  Its ERROR
      // recovery schema must not advertise RESOURCE_RELEASED while the
      // registry entry is still present: manager.mark_error() reserves that
      // pending step for the canonical create-rollback reservation shape.
      // Create-rollback recovery is the one exception; release_reserved()
      // consumes that canonical pending step after the recovery is persisted.
      if (creation_origin)
        rdma_recovery_queue_step(recovery, RDMA_CTRL_STEP_RESOURCE_RELEASED);
            persist_status = persist_queue_recovery(resource_h, recovery, binding, expected_owner);
      if (!persist_status.ok()) begin
        rdma_recovery_publish_required(recovery, result,
          "queue backing progress could not be persisted");
        done = 1'b1;
        break;
      end

      // The recovery intent, not the partial step history, selects the
      // registry transition.  A normal destroy starts with an ACTIVE queue
      // whose recovery result deliberately contains only destroy progress;
      // using the absence of create steps here would misclassify it as an
      // ALLOCATED reservation and route it through release_reserved().
      if (creation_origin)
        status = live_binding_fence(binding, expected_owner);
      else
        status = live_binding_fence(binding, expected_owner);
      if (status.ok() && creation_origin)
        status = manager.release_reserved(resource_h);
      else if (status.ok())
        status = manager.finalize_release(resource_h);
      status = normalize_status(status,
        "queue recovery final release returned null");
      if (!status.ok()) begin
        recovery.rollback_statuses.push_back(
          rdma_cmq_clone_status_value(status));
          void'(persist_queue_recovery(resource_h, recovery, binding, expected_owner));
        rdma_recovery_publish_required(recovery, result,
          "queue resource finalization still requires recovery");
        done = 1'b1;
        break;
      end
      rdma_recovery_complete_step(recovery, RDMA_CTRL_STEP_RESOURCE_RELEASED);
      rdma_recovery_project_history(recovery, result);
      result.status = rdma_status::success();
      result.final_resource_state = RDMA_RESOURCE_RELEASED;
      result.final_resource_state_known = 1'b1;
      result.recovery_required = 1'b0;
      done = 1'b1;
    end while (1'b0);

    if (!done) begin
      if (status == null)
        status = invalid_state("queue recovery returned null");
      publish_failure(status, result, RDMA_RESOURCE_NEW, 1'b0, 1'b0);
    end
  endtask

  // 功能：create_locked 创建独立的 无直接返回值；根据 binding、expected_owner、request、transaction_id、queue、result 设置字段 queue、result、preflight、reserved、plan、context_ref、create_command、status、result.resource_h、result.final_resource_state，返回对象仅由调用方持有，不转移外部资源所有权。
  // 输入/输出及副作用：binding（输入）、expected_owner（输入）、request（输入）、transaction_id（输入）、queue（输出）、result（输出）；输入请求/句柄定义资源属性；成功时更新账本并通过返回值或
  //   output 发布新句柄/映射。
  // 失败/边界：create_locked 失败或超时通过 queue、result 明确发布；该路径不隐式重试，也不转移未声明资源。
  task create_locked(
    rdma_function_binding binding,
    rdma_function_handle expected_owner,
    rdma_semantic_request request,
    longint unsigned transaction_id,
    output rdma_queue_resource queue,
    output rdma_control_result result
  );
    rdma_queue_lifecycle_policy policy;
    rdma_queue_preflight preflight;
    rdma_queue_resource reserved;
    rdma_queue_resource builder_resource;
    rdma_cq reserved_cq;
    rdma_queue_backing_plan plan;
    rdma_context_backing_ref context_ref;
    rdma_hw_model context_model;
    byte unsigned slot_image[];
    byte unsigned authorized_slot_image[];
    byte unsigned shadow_image[];
    rdma_cmq_command_desc create_command;
    rdma_cmq_ticket ticket;
    rdma_cmq_completion completion;
    rdma_resource active_snapshot;
    rdma_status status;
    rdma_status primary;
    rdma_status fence_status;
    bit cmq_ambiguous;

    queue = null;
    result = make_result(transaction_id);
    preflight = null;
    reserved = null;
    plan = null;
    context_ref = null;
    create_command = null;
    status = rdma_status::success();

    do begin
      if (transaction_id == 0) begin
        status = invalid_argument("queue transaction ID is zero");
        break;
      end
      if (manager == null || cmq == null || host_mem == null ||
          command_timeout == 0) begin
        status = invalid_state("queue executor is not configured");
        break;
      end
      status = live_binding_fence(binding, expected_owner);
      if (!status.ok()) break;
      if (request == null || request.owner == null ||
          !same_owner(request.owner, expected_owner)) begin
        status = invalid_argument("queue request owner does not match binding");
        break;
      end
      status = normalize_status(request.validate(),
                                "queue request validation returned null");
      if (!status.ok()) break;
      status = select_policy(request, policy);
      if (!status.ok()) break;
      if ((policy == cq_policy || policy == srq_policy) &&
          context_backing == null) begin
        status = invalid_state(
          "CQ/SRQ queue create requires a context-backing adapter"
        );
        break;
      end
      status = normalize_status(policy.preflight(binding, request, manager,
                                                  preflight),
                                "queue policy preflight returned null");
      if (!status.ok()) break;
      status = normalize_status(planner.validate_spec(binding, preflight),
                                "queue planner validation returned null");
      if (!status.ok()) break;
      status = normalize_status(policy.reserve_resource(manager, binding,
                                                        request, reserved),
                                "queue reservation returned null");
      if (!status.ok()) break;
      if (reserved == null || reserved.handle == null ||
          reserved.state != RDMA_RESOURCE_ALLOCATED) begin
        status = invalid_state("queue reservation output is invalid");
        break;
      end
      result.resource_h = rdma_clone_handle_value(reserved.handle,
                                                   "queue create result");
      result.final_resource_state = RDMA_RESOURCE_ALLOCATED;
      result.final_resource_state_known = 1'b1;
      result.completed_steps.push_back(RDMA_CTRL_STEP_RESOURCE_RESERVED);
      status = populate_resource(reserved, preflight);
      if (status.ok())
        status = normalize_status(planner.materialize(
          binding, preflight, reserved.handle, plan
        ), "queue planner materialize returned null");
      if (!status.ok()) begin
        rollback_local(binding, expected_owner, policy, reserved, null, create_command, status, result,
                       queue);
        return;
      end
      result.completed_steps.push_back(RDMA_CTRL_STEP_BACKING_ATTACHED);
      if (reserved.resource_kind() inside {RDMA_RESOURCE_CQ,
                                           RDMA_RESOURCE_SRQ}) begin
        int unsigned local_id;
        if (reserved.resource_kind() == RDMA_RESOURCE_CQ) begin
          rdma_cq cq;
          if (!$cast(cq, reserved)) begin
            status = invalid_state("reserved CQ type was lost");
            rollback_local(binding, expected_owner, policy, reserved, plan, create_command, status,
                           result, queue);
            return;
          end
          local_id = cq.local_cq_id;
        end
        else begin
          rdma_srq srq;
          if (!$cast(srq, reserved)) begin
            status = invalid_state("reserved SRQ type was lost");
            rollback_local(binding, expected_owner, policy, reserved, plan, create_command, status,
                           result, queue);
            return;
          end
          local_id = srq.local_srq_id;
        end
        status = normalize_status(context_backing.acquire(
          binding, reserved.resource_kind(), local_id, context_ref
        ), "queue context acquire returned null");
        if (!status.ok() || context_ref == null) begin
          if (status.ok()) status = invalid_state("queue context acquire is null");
          rollback_local(binding, expected_owner, policy, reserved, plan, create_command, status,
                         result, queue);
          return;
        end
        plan.context_ref = context_ref;
        result.completed_steps.push_back(RDMA_CTRL_STEP_HMC_ATTACHED);
      end
      reserved.queue_plan = plan;
      status = live_binding_fence(binding, expected_owner);
      if (status.ok()) status = normalize_status(manager.stage_allocated(reserved),
                                "queue stage allocated returned null");
      if (status.ok())
        status = initialize_plan(binding, plan);
      if (!status.ok()) begin
        rollback_local(binding, expected_owner, policy, reserved, plan, create_command, status, result,
                       queue);
        return;
      end
      builder_resource = reserved;
      if (reserved.resource_kind() == RDMA_RESOURCE_CQ) begin
        status = cq_builder_view(reserved, builder_resource);
        if (!status.ok()) begin
          rollback_local(binding, expected_owner, policy, reserved, plan, create_command, status,
                         result, queue);
          return;
        end
      end
      else if (reserved.resource_kind() == RDMA_RESOURCE_SRQ) begin
        status = srq_builder_view(reserved, builder_resource);
        if (!status.ok()) begin
          rollback_local(binding, expected_owner, policy, reserved, plan, create_command, status,
                         result, queue);
          return;
        end
      end
      status = normalize_status(policy.build_create_context(
        builder_resource, plan, context_model, slot_image, shadow_image
      ), "queue context builder returned null");
      if (!status.ok()) begin
        rollback_local(binding, expected_owner, policy, reserved, plan, create_command, status, result,
                       queue);
        return;
      end
      if (reserved.resource_kind() inside {RDMA_RESOURCE_CQ,
                                           RDMA_RESOURCE_SRQ}) begin
        if (plan.context_ref == null ||
            slot_image.size() < plan.context_ref.slot_length) begin
          status = invalid_state("queue context image is smaller than slot");
          rollback_local(binding, expected_owner, policy, reserved, plan, create_command, status,
                         result, queue);
          return;
        end
        authorized_slot_image = new[plan.context_ref.slot_length];
        foreach (authorized_slot_image[i])
          authorized_slot_image[i] = slot_image[i];
        status = normalize_status(context_backing.write(
          plan.context_ref, 0, authorized_slot_image
        ), "queue context slot write returned null");
        if (status.ok())
          status = normalize_status(context_backing.write(
            plan.context_ref, plan.context_ref.shadow_view_offset,
            shadow_image
          ), "queue context shadow write returned null");
        if (!status.ok()) begin
          rollback_local(binding, expected_owner, policy, reserved, plan, create_command, status,
                         result, queue);
          return;
        end
      end
      status = normalize_status(policy.build_create_command(
        expected_owner, reserved, context_model, command_timeout,
        create_command
      ), "queue create descriptor returned null");
      if (!status.ok()) begin
        rollback_local(binding, expected_owner, policy, reserved, plan, create_command, status, result,
                       queue);
        return;
      end
      if (reserved.resource_kind() == RDMA_RESOURCE_CQ) begin
        // 设计说明：programmed_cqc 是硬件 create 已可提交时才成立的
        // typed-body authority。context slot/shadow 写入或 create descriptor
        // 构造失败时，资源仍处于 pre-context 阶段，不能留下“已编程”快照。
        // 这里位于 descriptor 成功之后、CMQ execute 之前，既覆盖成功提交和
        // ambiguous submit 的恢复路径，也不会把 pre-submit 失败误标为 PRESENT。
        status = capture_cq_context(reserved, context_model);
        if (!status.ok()) begin
          rollback_local(binding, expected_owner, policy, reserved, plan,
                         create_command, status, result, queue);
          return;
        end
        if (!$cast(reserved_cq, reserved)) begin
          status = invalid_state("reserved CQ authority was lost");
          rollback_local(binding, expected_owner, policy, reserved, plan,
                         create_command, status, result, queue);
          return;
        end
        status = normalize_status(
          manager.attach_cq_programming(reserved_cq),
          "CQ programming attachment returned null"
        );
        if (!status.ok()) begin
          rollback_local(binding, expected_owner, policy, reserved, plan,
                         create_command, status, result, queue);
          return;
        end
      end
      ticket = null;
      completion = null;
      // 设计说明：create_locked 保留 fence checkpoint 在 helper 之后，和原始
      // 提交顺序一致；helper 只收束 legacy 输出归一化，不改变 create 失败时
      // 进入 retain_recovery/rollback_local 的判定。
      execute_queue_command(
        create_command, ticket, completion, status, cmq_ambiguous,
        null, null, "queue create result was lost",
        "queue create completion was lost"
      );
      fence_status = live_binding_fence(binding, expected_owner);
      if (!fence_status.ok()) begin
        publish_failure(fence_status, result, RDMA_RESOURCE_ALLOCATED,
                       1'b1, 1'b0);
        return;
      end
      if (!status.ok()) begin
        primary = rdma_cmq_clone_status_value(status);
        if (cmq_ambiguous) begin
          retain_recovery(policy, reserved, plan, create_command, primary,
                          result, RDMA_HW_PRESENCE_UNKNOWN,
                          RDMA_QUEUE_AMBIG_CREATE, ticket, 1'b1, 1'b1, queue);
        end
        else begin
          rollback_local(binding, expected_owner, policy, reserved, plan, create_command, primary,
                         result, queue);
        end
        return;
      end
      result.completed_steps.push_back(RDMA_CTRL_STEP_HW_CONTEXT_CREATED);
      status = live_binding_fence(binding, expected_owner);
      if (status.ok())
        status = normalize_status(manager.commit_programmed(reserved),
                                  "queue commit programmed returned null");
      if (!status.ok()) begin
        rollback_created(binding, expected_owner, policy, reserved, plan, create_command, status,
                         result, 1'b0, queue);
        return;
      end
      result.completed_steps.push_back(RDMA_CTRL_STEP_REGISTRY_PROGRAMMED);
      result.final_resource_state = RDMA_RESOURCE_PROGRAMMED;
      status = live_binding_fence(binding, expected_owner);
      if (status.ok()) status = normalize_status(manager.activate(reserved.handle),
                                "queue activate returned null");
      if (!status.ok()) begin
        rollback_created(binding, expected_owner, policy, reserved, plan, create_command, status,
                         result, 1'b1, queue);
        return;
      end
      result.completed_steps.push_back(RDMA_CTRL_STEP_REGISTRY_ACTIVE);
      result.final_resource_state = RDMA_RESOURCE_ACTIVE;
      status = normalize_status(manager.lookup(reserved.handle,
                                               active_snapshot),
                                "ACTIVE queue lookup returned null");
      if (!status.ok() || !$cast(queue, active_snapshot) || queue == null ||
          queue.state != RDMA_RESOURCE_ACTIVE) begin
        if (status.ok()) status = invalid_state("ACTIVE queue snapshot invalid");
        queue = null;
        rollback_created(binding, expected_owner, policy, reserved, plan, create_command, status,
                         result, 1'b1, queue);
        return;
      end
      result.resource_h = rdma_clone_handle_value(queue.handle,
                                                   "ACTIVE queue result");
      result.primary_status = rdma_status::success();
      result.status = rdma_status::success();
      result.final_resource_state_known = 1'b1;
      result.recovery_required = 1'b0;
      return;
    end while (1'b0);

    publish_failure(status, result, RDMA_RESOURCE_NEW, 1'b0, 1'b0);
  endtask

  // 设计说明：destroy_locked 的 SRQ 前置 flush 与 CQ/CEQ/AEQ 删除后的 flush
  //   共享同一条“构造 descriptor→一次 CMQ execute→generation fence→记录 role
  //   progress”事务边界。该 task 只消费已经通过 recipe/cardinality 校验的 detached
  //   flush target 和 queue handle，不持有 plan、registry、recovery ledger 或 backing。
  // 功能：execute_destroy_flush_step 执行一个 queue backing role 的 OCC flush，并把
  //   ticket、completion、AMBIGUOUS 证据和 manager progress 返回给 destroy caller。
  // 输入/输出及副作用：binding、expected_owner、policy、target、queue_h 为输入；status、
  //   ticket、completion、ambiguous、completed 为输出。成功且 completion.status 为 OK 时
  //   调用 manager.record_queue_flush_complete(queue_h,target.role)，completed 置 1。
  // 失败/边界：输入缺失、descriptor/CMQ/fence/manager 返回 null 或失败时不提交 role
  //   progress；legacy execute 缺失 ticket/completion 或 timeout/reset 会保留原有
  //   ambiguous 标记供 destroy_locked 建立不可判定恢复记录。completion.status 非空且失败
  //   时保持既有语义：execute status 仍可为 OK，但 completed 保持 0，调用方继续按原顺序判断。
  protected task execute_destroy_flush_step(
    rdma_function_binding binding,
    rdma_function_handle expected_owner,
    rdma_queue_lifecycle_policy policy,
    rdma_queue_flush_target target,
    rdma_handle queue_h,
    output rdma_status status,
    output rdma_cmq_ticket ticket,
    output rdma_cmq_completion completion,
    output bit ambiguous,
    output bit completed
  );
    rdma_cmq_command_desc command;
    rdma_status step_status;
    rdma_status fence_status;

    status = rdma_status::success();
    ticket = null;
    completion = null;
    ambiguous = 1'b0;
    completed = 1'b0;
    if (binding == null || expected_owner == null || policy == null ||
        target == null || queue_h == null || manager == null || cmq == null) begin
      status = invalid_argument("queue destroy flush authority is incomplete");
      return;
    end
    command = null;
    status = normalize_status(policy.build_flush_command(
      expected_owner, target, command_timeout, command
    ), "flush descriptor returned null");
    if (status.ok()) begin
      execute_queue_command(
        command, ticket, completion, step_status, ambiguous,
        null, null, "flush result was lost", "flush completion was lost"
      );
      fence_status = live_binding_fence(binding, expected_owner);
      if (!fence_status.ok())
        status = fence_status;
      else
        status = step_status;
    end
    if (status.ok() && completion != null && completion.status != null &&
        completion.status.ok()) begin
      status = live_binding_fence(binding, expected_owner);
      if (status.ok())
        status = normalize_status(
          manager.record_queue_flush_complete(queue_h, target.role),
          "flush progress returned null");
      if (status.ok())
        completed = 1'b1;
    end
  endtask

  // 功能：在 rdma_queue_lifecycle_executor 中，destroy_locked 按 owner、generation 和幂等规则释放/隔离记录，并同步删除其账本引用。
  // 输入/输出及副作用：binding（输入）、expected_owner（输入）、request（输入）、transaction_id（输入）、result（输出）；输入 handle/mapping/token
  //   指定释放目标；成功时更新账本和生命周期，外部资源只按 adapter 契约释放。
  // 失败/边界：destroy_locked 发现 owner/generation 不匹配、记录未知或重复释放时返回错误或幂等结果，不重新激活旧句柄。
  task destroy_locked(
    rdma_function_binding binding,
    rdma_function_handle expected_owner,
    rdma_destroy_resource_req request,
    longint unsigned transaction_id,
    output rdma_control_result result
  );
    rdma_status status, primary, step_status, fence_status;
    rdma_resource snapshot;
    rdma_queue_resource queue;
    rdma_queue_backing_plan plan;
    rdma_queue_lifecycle_policy policy;
    rdma_queue_backing_role_e flush_roles[$], local_roles[$];
    rdma_queue_flush_phase_e flush_phases[$];
    rdma_cmq_command_desc command;
    rdma_cmq_ticket ticket;
    rdma_cmq_completion completion;
    bit delete_before_flush, release_context_first, ambiguous, hardware_absent;
    bit flush_completed;
    rdma_queue_ambiguous_operation_e ambiguous_op;
    int unsigned i, j;

    result = make_result(transaction_id);
    status = rdma_status::success();
    ambiguous_op = RDMA_QUEUE_AMBIG_NONE;

    if (transaction_id == 0) begin
      status = invalid_argument("queue transaction ID is zero");
    end
    else if (manager == null || cmq == null || binding == null ||
             expected_owner == null || request == null ||
             request.target_h == null) begin
      status = invalid_argument("queue destroy authority is incomplete");
    end
    if (status.ok()) status = live_binding_fence(binding, expected_owner);
    if (status.ok()) begin
      result.resource_h = rdma_clone_handle_value(
        request.target_h, "queue destroy result");
      status = normalize_status(
        manager.lookup(request.target_h, snapshot),
        "queue destroy lookup returned null");
      if (status.ok() &&
          (snapshot == null || snapshot.state != RDMA_RESOURCE_ACTIVE ||
           !$cast(queue, snapshot))) begin
        status = (snapshot != null &&
                  snapshot.state != RDMA_RESOURCE_ACTIVE) ?
          rdma_status::make(RDMA_SC_INVALID_STATE, "queue is not ACTIVE") :
          invalid_state("queue destroy resource snapshot invalid");
      end
    end
    if (status.ok() && !same_owner(queue.owner, expected_owner))
      status = invalid_argument("queue destroy owner mismatch");
    if (status.ok()) begin
      case (queue.resource_kind())
        RDMA_RESOURCE_CQ: policy = cq_policy;
        RDMA_RESOURCE_SRQ: policy = srq_policy;
        RDMA_RESOURCE_CEQ: policy = ceq_policy;
        RDMA_RESOURCE_AEQ: policy = aeq_policy;
        default: status = invalid_argument("unsupported queue kind");
      endcase
    end
    if (status.ok()) begin
      plan = queue.queue_plan;
      status = (plan == null) ?
        invalid_state("queue backing plan is missing") :
        normalize_status(
          plan.validate(), "queue backing plan validation returned null");
    end
    if (status.ok()) begin
      policy.hardware_cleanup_roles(flush_roles, flush_phases, delete_before_flush);
      policy.local_cleanup_roles(local_roles, release_context_first);
      status = rdma_queue_cleanup_recipe_policy::validate(
        queue.resource_kind(), plan, flush_roles, flush_phases,
        release_context_first, local_roles
      );
    end
    if (status.ok()) status = live_binding_fence(binding, expected_owner);
    if (status.ok()) status = normalize_status(manager.begin_quiesce(queue.handle), "queue begin quiesce returned null");
    if (status.ok()) begin
      hardware_absent = 1'b0;
      // SRQ flushes precede delete; CQ/EQ delete precedes optional flush.
      if (!delete_before_flush) begin
        for (i = 0; i < flush_roles.size(); i++) begin
          foreach (plan.flush_targets[j]) begin
            if (plan.flush_targets[j].role == flush_roles[i]) begin
              execute_destroy_flush_step(
                binding, expected_owner, policy, plan.flush_targets[j],
                queue.handle, status, ticket, completion, ambiguous,
                flush_completed
              );
              if (ambiguous)
                ambiguous_op = RDMA_QUEUE_AMBIG_OCC_FLUSH;
              if (flush_completed)
                result.completed_steps.push_back(RDMA_CTRL_STEP_HW_OCC_FLUSHED);
              if (!status.ok())
                break;
            end
          end
          if (!status.ok()) break;
        end
      end
      if (status.ok()) begin
        ticket = null;
        completion = null;
        command = null;
        status = normalize_status(policy.build_object_command(
          delete_opcode(queue.resource_kind()), expected_owner, queue,
          command_timeout, command
        ), "delete descriptor returned null");
        ambiguous = 1'b0;
        if (status.ok()) begin
          ticket = null;
          completion = null;
          step_status = null;
          execute_queue_command(
            command, ticket, completion, step_status, ambiguous,
            null, null, "delete result was lost",
            "delete completion was lost"
          );
          fence_status = live_binding_fence(binding, expected_owner);
          if (!fence_status.ok()) status = fence_status;
          if (status.ok()) begin
            status = step_status;
          end
          if (ambiguous)
            ambiguous_op = RDMA_QUEUE_AMBIG_DELETE;
        end
        if (status.ok() && completion != null &&
            completion.status != null && completion.status.ok()) begin
          hardware_absent = 1'b1;
          result.completed_steps.push_back(RDMA_CTRL_STEP_HW_CONTEXT_DELETED);
        end
      end
      if (status.ok() && delete_before_flush) begin
        for (i = 0; i < flush_roles.size(); i++) begin
          foreach (plan.flush_targets[j]) begin
            if (plan.flush_targets[j].role == flush_roles[i]) begin
              execute_destroy_flush_step(
                binding, expected_owner, policy, plan.flush_targets[j],
                queue.handle, status, ticket, completion, ambiguous,
                flush_completed
              );
              if (ambiguous)
                ambiguous_op = RDMA_QUEUE_AMBIG_OCC_FLUSH;
              if (flush_completed)
                result.completed_steps.push_back(RDMA_CTRL_STEP_HW_OCC_FLUSHED);
              if (!status.ok())
                break;
            end
          end
          if (!status.ok()) break;
        end
      end
      if (status.ok())
        status = live_binding_fence(binding, expected_owner);
      if (status.ok()) begin
        status = cleanup_local(plan, result, 1'b1, queue.handle,
                               binding, expected_owner);
        if (status.ok())
          status = live_binding_fence(binding, expected_owner);
        if (status.ok())
          status = normalize_status(
            manager.finalize_release(queue.handle),
            "queue finalize release returned null");
      end
      if (!status.ok()) begin
        primary = rdma_cmq_clone_status_value(status);
        if (!hardware_absent && !ambiguous && ticket == null &&
            status.code inside {
              RDMA_SC_INVALID_ARGUMENT,
              RDMA_SC_INVALID_STATE,
              RDMA_SC_RESOURCE_BUSY
            }) begin
          rdma_status restore_status;
          restore_status = live_binding_fence(binding, expected_owner);
          if (restore_status.ok())
            restore_status = manager.restore_active(queue.handle);
          if (restore_status == null || !restore_status.ok()) begin
            retain_recovery_int(
              policy, queue, plan, null, primary, result,
              RDMA_HW_PRESENCE_UNKNOWN, ambiguous_op, ticket,
              1'b1, 1'b1, RDMA_QUEUE_RECOVER_NORMAL_DESTROY, queue);
            return;
          end
          publish_failure(primary, result, RDMA_RESOURCE_ACTIVE, 1'b1, 1'b0);
          return;
        end
        retain_recovery_int(
          policy, queue, plan, null, primary, result,
          hardware_absent ? RDMA_HW_PRESENCE_ABSENT :
            RDMA_HW_PRESENCE_UNKNOWN,
          ambiguous ? ambiguous_op : RDMA_QUEUE_AMBIG_NONE,
          ticket, !hardware_absent, 1'b1,
          RDMA_QUEUE_RECOVER_NORMAL_DESTROY, queue);
        return;
      end
      publish_failure(rdma_status::success(), result, RDMA_RESOURCE_RELEASED, 1'b1, 1'b0);
      return;
    end
    publish_failure(status, result, RDMA_RESOURCE_NEW, 1'b0, 1'b0);
  endtask
endclass
