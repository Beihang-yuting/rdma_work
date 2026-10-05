// 目录：核心执行层 core/rdma_queue_lifecycle_policy.sv。
// 职责：实现 rdma_queue_lifecycle_policy 在本层的职责和对外接口。
// 依赖：依赖本层公共 types/model/adapter 契约及其上游快照。
// 所有权与生命周期：对象只拥有显式创建的值快照；外部资源保存非拥有引用，生命周期由调用方管理。

// 中文说明：rdma_queue_lifecycle_policy.sv 属于核心执行层，负责队列、控制面、资源和恢复流程。
// 阅读提示：先看公开类型和接口，再看实现细节；失败路径应保持状态与资源所有权可追踪。

virtual class rdma_queue_lifecycle_policy extends uvm_object;

  // 功能：构造 rdma_queue_lifecycle_policy，调用 super.new 建立 UVM 层级对象；外部依赖字段保持未绑定，后续由 configure/build/activate 明确注入。
  // 输入/输出及副作用：name（输入）；new 只写入构造体列出的默认字段并返回 void，外部依赖与资源所有权仍由上层管理。
  // 失败/边界：rdma_queue_lifecycle_policy 构造只建立本地初始状态，不接管外部 Host-memory、PCIe 或 manager；未完成后续 configure/build/activate 时，业务入口必须返回 INVALID_STATE。
  function new(string name = "rdma_queue_lifecycle_policy");
    super.new(name);
  endfunction

  // 功能：resource_kind 使用 当前对象字段 计算并返回 rdma_resource_kind_e 结果；不修改对象字段或外部资源。
  // 输入/输出及副作用：无显式参数；resource_kind 读取 对象字段：rdma_status、message 并使用字段 rdma_status、message；函数返回 rdma_resource_kind_e，不取得调用方资源所有权。
  // 失败/边界：resource_kind 返回 RDMA_SC_INVALID_ARGUMENT；失败路径不提交部分状态或转移未声明资源。
  pure virtual function rdma_resource_kind_e resource_kind();

  // 功能：基类 preflight 接口要求实现方校验 binding、request 和 manager，并将资源预检结果写入 result。
  // 输入/输出及副作用：binding（输入）、request（输入）、manager（输入）、result（输出）；preflight 校验 Function identity、请求 opcode 和 manager 容量并写入 result；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：必需对象/句柄/快照为空，或身份、范围、generation 和生命周期检查失败时返回非成功状态。
  pure virtual function rdma_status preflight(
    rdma_function_binding binding, rdma_semantic_request request,
    rdma_resource_manager manager, output rdma_queue_preflight result);

  // 功能：在 rdma_queue_lifecycle_policy 中，reserve_resource 检查容量后预留资源并返回带 owner 证据的句柄/计划；失败时回滚已登记的局部状态。
  // 输入/输出及副作用：manager（输入）、binding（输入）、request（输入）、resource（输出）；输入请求/句柄定义资源属性；成功时更新账本并通过返回值或 output 发布新句柄/映射。
  // 失败/边界：容量不足、范围非法、重复占用或身份过期时返回错误；失败不得泄漏半分配资源。
  pure virtual function rdma_status reserve_resource(
    rdma_resource_manager manager, rdma_function_binding binding,
    rdma_semantic_request request, output rdma_queue_resource resource);

  // 功能：build_create_context 根据 resource 和 plan 生成 context_model，并填充 context_slot_image、context_shadow_image 两份独立硬件镜像。
  // 输入/输出及副作用：resource（输入）、plan（输入）、context_model（输出）、context_slot_image（输出）、context_shadow_image（输出）；输入字段被复制到返回值或
  //   output；生成结果与输入隔离，不隐式修改调用方对象。
  // 失败/边界：build_create_context 返回 RDMA_SC_INVALID_ARGUMENT；失败路径不提交部分状态或转移未声明资源。
  pure virtual function rdma_status build_create_context(
    rdma_queue_resource resource, rdma_queue_backing_plan plan,
    output rdma_hw_model context_model,
    output byte unsigned context_slot_image[],
    output byte unsigned context_shadow_image[]);

  // 功能：build_create_command 将 owner、resource、context_model 和 timeout 编码为 command，供 CMQ create 阶段提交。
  // 输入/输出及副作用：owner（输入）、resource（输入）、context_model（输入）、timeout（输入）、command（输出）；输入字段被复制到返回值或
  //   output；生成结果与输入隔离，不隐式修改调用方对象。
  // 失败/边界：build_create_command 返回 RDMA_SC_INVALID_ARGUMENT；失败路径不提交部分状态或转移未声明资源。
  pure virtual function rdma_status build_create_command(
    rdma_function_handle owner, rdma_queue_resource resource,
    rdma_hw_model context_model, time timeout,
    output rdma_cmq_command_desc command);

  // 功能：build_object_command 按 opcode 选择资源命令格式，填充 owner、resource、timeout 和 command 的硬件字段，返回可提交的 CMQ 描述。
  // 输入/输出及副作用：opcode（输入）、owner（输入）、resource（输入）、timeout（输入）、command（输出）；build_object_command 校验 owner 与 resource 的 Function/Kind 一致性并写入 command；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：build_object_command 返回 RDMA_SC_INVALID_ARGUMENT；失败路径不提交部分状态或转移未声明资源。
  pure virtual function rdma_status build_object_command(
    bit [7:0] opcode, rdma_function_handle owner,
    rdma_queue_resource resource, time timeout,
    output rdma_cmq_command_desc command);

  // 功能：build_flush_command 将 owner、target 和 timeout 编码为硬件 flush 命令，写入 command 供队列清理阶段提交。
  // 输入/输出及副作用：owner（输入）、target（输入）、timeout（输入）、command（输出）；build_flush_command 校验 owner、target 的资源类型与 Function 归属并写入 command；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：build_flush_command 返回 RDMA_SC_INVALID_ARGUMENT；失败路径不提交部分状态或转移未声明资源。
  pure virtual function rdma_status build_flush_command(
    rdma_function_handle owner, rdma_queue_flush_target target,
    time timeout, output rdma_cmq_command_desc command);
  // 中文设计：terminal QUERY completion 只有在 payload 通过 profile typed
  // context codec 鉴权且明确指向本 queue local object ID 时，才是可信的 hardware
  // presence evidence；单独的成功 status 不足以定论。无法定论的响应保持输出为
  // UNKNOWN/0，并返回允许 recovery 继续推进的 status。
  // 功能：classify_query_completion 验证 QUERY completion 的 opcode、owner 和 payload，将硬件存在性写入 presence，并把证据是否充分写入 conclusive。
  // 输入/输出及副作用：resource（输入）、completion（输入）、presence（输出）、conclusive（输出）；函数读取 resource.handle、completion.status 和 completion.image，并写入 presence、conclusive；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：classify_query_completion 返回 RDMA_SC_INVALID_ARGUMENT；失败路径不提交部分状态或转移未声明资源。
  pure virtual function rdma_status classify_query_completion(
    rdma_queue_resource resource,
    rdma_cmq_completion completion,
    output rdma_hw_presence_e presence,
    output bit conclusive);

  // 功能：在 rdma_queue_lifecycle_policy 中，hardware_cleanup_roles 返回该资源策略要求的硬件 flush 与本地释放角色及其执行顺序。
  // 输入/输出及副作用：flush_roles（输出）、flush_phases（输出）、delete_before_flush（输出）；hardware_cleanup_roles 按资源类型写入 flush_roles、flush_phases 和 delete_before_flush 的清理顺序；函数返回 void，不取得调用方资源所有权。
  // 失败/边界：hardware_cleanup_roles 返回 RDMA_SC_INVALID_ARGUMENT；失败路径不提交部分状态或转移未声明资源。
  pure virtual function void hardware_cleanup_roles(
    output rdma_queue_backing_role_e flush_roles[$],
    output rdma_queue_flush_phase_e flush_phases[$],
    output bit delete_before_flush);

  // 功能：在 rdma_queue_lifecycle_policy 中，local_cleanup_roles 返回该资源策略要求的硬件 flush 与本地释放角色及其执行顺序。
  // 输入/输出及副作用：roles（输出）、release_context_first（输出）；local_cleanup_roles 写入本地 backing role 释放顺序以及 release_context_first 标志；函数返回 void，不取得调用方资源所有权。
  // 失败/边界：local_cleanup_roles 返回 RDMA_SC_INVALID_ARGUMENT；失败路径不提交部分状态或转移未声明资源。
  pure virtual function void local_cleanup_roles(
    output rdma_queue_backing_role_e roles[$],
    output bit release_context_first);

  // 功能：在 rdma_queue_lifecycle_policy 中，invalid_argument 把错误消息、硬件码或注入故障封装为统一 rdma_status，保留原事务的诊断证据。
  // 输入/输出及副作用：message（输入）；invalid_argument 将 message 封装为 RDMA_SC_INVALID_ARGUMENT 状态，不修改对象或资源；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：invalid_argument 返回 RDMA_SC_INVALID_ARGUMENT；失败路径不提交部分状态或转移未声明资源。
  protected function rdma_status invalid_argument(string message);
    return rdma_status::make(RDMA_SC_INVALID_ARGUMENT, message);
  endfunction

  // 功能：在 rdma_queue_lifecycle_policy 中，invalid_state 把错误消息、硬件码或注入故障封装为统一 rdma_status，保留原事务的诊断证据。
  // 输入/输出及副作用：message（输入）；invalid_state 读取 message 并使用字段 rdma_status；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：invalid_state 返回 RDMA_SC_INVALID_STATE；失败路径不提交部分状态或转移未声明资源。
  protected function rdma_status invalid_state(string message);
    return rdma_status::make(RDMA_SC_INVALID_STATE, message);
  endfunction

  // 功能：在 rdma_queue_lifecycle_policy 中，unsupported 把错误消息、硬件码或注入故障封装为统一 rdma_status，保留原事务的诊断证据。
  // 输入/输出及副作用：message（输入）；unsupported 读取 message 并使用字段 rdma_status；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：unsupported 返回 RDMA_SC_UNSUPPORTED_OPCODE；失败路径不提交部分状态或转移未声明资源。
  protected function rdma_status unsupported(string message);
    return rdma_status::make(RDMA_SC_UNSUPPORTED_OPCODE, message);
  endfunction

  // 功能：在 rdma_queue_lifecycle_policy 中比较两份 Function identity 的 Host/root、PF/VF、BDF 和 global_function_id，判断是否代表同一
  //   Function。
  // 输入/输出及副作用：lhs（输入）、rhs（输入）；lhs/rhs 只读，返回 bit，不更新 authority 或资源账本。
  // 失败/边界：same_function 的任一比较对象为空或类型不符时返回确定的 false/不等结果，不抛出未处理异常。
  protected function bit same_function(
    rdma_function_handle lhs,
    rdma_function_handle rhs
  );
    if (lhs == null || rhs == null)
      return 1'b0;
    return lhs.kind == RDMA_RESOURCE_FUNCTION &&
           rhs.kind == RDMA_RESOURCE_FUNCTION &&
           lhs.function_uid == rhs.function_uid &&
           lhs.object_id == rhs.object_id &&
           lhs.generation == rhs.generation;
  endfunction

  // 功能：queue_resource_owner_status 校验 resource、expected_kind 与当前对象状态的一致性，并显式处理“typed queue resource identity is incomplete”；“typed queue resource kind is invalid”等拒绝条件，返回 rdma_status 供上层决定是否提交。
  // 输入/输出及副作用：resource（输入）、expected_kind（输入）；queue_resource_owner_status 读取 resource、expected_kind 并使用字段 status；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：queue_resource_owner_status 返回 函数体规定的失败状态；具体拒绝条件包括 “typed queue resource identity is incomplete”；“typed queue resource kind is invalid”；失败路径不提交部分状态、不隐式重试，也不转移未声明资源。
  protected function rdma_status queue_resource_owner_status(
    rdma_queue_resource resource,
    rdma_resource_kind_e expected_kind
  );
    rdma_status status;

    if (resource == null || resource.owner == null || resource.handle == null)
      return invalid_argument("typed queue resource identity is incomplete");
    if (resource.resource_kind() != expected_kind ||
        resource.handle.kind != expected_kind)
      return invalid_argument("typed queue resource kind is invalid");
    status = rdma_cmq_function_status(resource.owner,
                                      "typed queue resource");
    if (!status.ok())
      return status;
    return rdma_handle_owner_status(resource.handle, resource.owner);
  endfunction

  // 功能：command_resource_owner_status 校验 owner、resource、expected_kind 与当前对象状态的一致性，并显式处理“queue command owner does not match resource”等拒绝条件，返回 rdma_status 供上层决定是否提交。
  // 输入/输出及副作用：owner（输入）、resource（输入）、expected_kind（输入）；command_resource_owner_status 读取 owner、resource、expected_kind 并使用字段 status；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：command_resource_owner_status 返回 函数体规定的失败状态；具体拒绝条件包括 “queue command owner does not match resource”；失败路径不提交部分状态、不隐式重试，也不转移未声明资源。
  protected function rdma_status command_resource_owner_status(
    rdma_function_handle owner,
    rdma_queue_resource resource,
    rdma_resource_kind_e expected_kind
  );
    rdma_status status;

    status = queue_resource_owner_status(resource, expected_kind);
    if (!status.ok())
      return status;
    if (!same_function(owner, resource.owner))
      return invalid_argument("queue command owner does not match resource");
    return rdma_status::success();
  endfunction

  // 功能：command_owner_status 校验 owner、resource、context_h、expected_kind 与当前对象状态的一致性，并显式处理“queue command context handle is invalid”等拒绝条件，返回 rdma_status 供上层决定是否提交。
  // 输入/输出及副作用：owner（输入）、resource（输入）、context_h（输入）、expected_kind（输入）；command_owner_status 读取 owner、resource、context_h、expected_kind 并使用字段 status；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：command_owner_status 返回 RDMA_SC_INVALID_ARGUMENT；典型拒绝条件为“queue command context handle is invalid”；失败路径不提交部分状态或转移未声明资源。
  protected function rdma_status command_owner_status(
    rdma_function_handle owner,
    rdma_queue_resource resource,
    rdma_handle context_h,
    rdma_resource_kind_e expected_kind
  );
    rdma_status status;

    status = command_resource_owner_status(owner, resource, expected_kind);
    if (!status.ok())
      return status;
    if (context_h == null || context_h.kind != expected_kind)
      return invalid_argument("queue command context handle is invalid");
    return rdma_handle_owner_status(context_h, owner);
  endfunction

  // 功能：backing_owner_status 校验 ref_value、owner 与当前对象状态的一致性，并显式处理“queue backing Function is missing”等拒绝条件，返回 rdma_status 供上层决定是否提交。
  // 输入/输出及副作用：ref_value（输入）、owner（输入）；backing_owner_status 读取 ref_value、owner 并使用字段 rdma_status、function_h；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：backing_owner_status 返回 RDMA_SC_INVALID_ARGUMENT；典型拒绝条件为“queue backing Function is missing”“queue backing belongs to another Function”；失败路径不提交部分状态或转移未声明资源。
  protected function rdma_status backing_owner_status(
    rdma_queue_backing_ref ref_value,
    rdma_function_handle owner
  );
    if (ref_value == null || ref_value.mapping == null ||
        ref_value.mapping.function_h == null)
      return invalid_argument("queue backing Function is missing");
    if (!same_function(ref_value.mapping.function_h, owner))
      return invalid_argument("queue backing belongs to another Function");
    return rdma_status::success();
  endfunction

  // 功能：common_preflight_status 校验 binding、request、manager、owner 与当前对象状态的一致性，并显式处理“queue policy preflight input is null”等拒绝条件，返回 rdma_status 供上层决定是否提交。
  // 输入/输出及副作用：binding（输入）、request（输入）、manager（输入）、owner（输出）；common_preflight_status 读取 binding、request、manager、owner 并使用字段 owner、status，并写入 owner；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：common_preflight_status 返回 函数体规定的失败状态；具体拒绝条件包括 “queue policy preflight input is null”；“queue policy requires an ACTIVE Function binding”；“queue request owner does not match binding”；失败路径不提交部分状态、不隐式重试，也不转移未声明资源。
  protected function rdma_status common_preflight_status(
    rdma_function_binding binding,
    rdma_semantic_request request,
    rdma_resource_manager manager,
    output rdma_function_handle owner
  );
    rdma_status status;
    rdma_function_handle binding_owner;

    owner = null;
    if (binding == null || request == null || manager == null)
      return invalid_argument("queue policy preflight input is null");
    status = rdma_status::nonnull(
      binding.validate(),
      "queue policy Function binding validation returned null"
    );
    if (!status.ok())
      return status;
    if (binding.state != RDMA_BIND_ACTIVE || binding.owner_h == null ||
        !$cast(binding_owner, binding.owner_h))
      return invalid_state("queue policy requires an ACTIVE Function binding");
    if (request.owner == null || !same_function(binding_owner,
                                                 request.owner))
      return invalid_argument("queue request owner does not match binding");
    status = rdma_status::nonnull(
      request.validate(),
      "queue policy request validation returned null"
    );
    if (!status.ok())
      return status;
    owner = binding_owner;
    return rdma_status::success();
  endfunction

  // 功能：dependency_status 校验 manager、owner、dependency、expected_kind、allow_null 与当前对象状态的一致性，并显式处理“required queue dependency is null”等拒绝条件，返回 rdma_status 供上层决定是否提交。
  // 输入/输出及副作用：manager（输入）、owner（输入）、dependency（输入）、expected_kind（输入）、allow_null（输入）；dependency_status 读取 manager、owner、dependency、expected_kind、allow_null 并使用字段 status；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：dependency_status 返回 RDMA_SC_INVALID_ARGUMENT、RDMA_SC_INVALID_STATE；典型拒绝条件为“required queue dependency is null”“queue dependency kind is invalid”；失败路径不提交部分状态或转移未声明资源。
  protected function rdma_status dependency_status(
    rdma_resource_manager manager,
    rdma_function_handle owner,
    rdma_handle dependency,
    rdma_resource_kind_e expected_kind,
    bit allow_null
  );
    rdma_resource dependency_resource;
    rdma_status status;

    if (dependency == null) begin
      if (allow_null)
        return rdma_status::success();
      return invalid_argument("required queue dependency is null");
    end
    if (dependency.kind != expected_kind)
      return invalid_argument("queue dependency kind is invalid");
    status = manager.lookup(dependency, dependency_resource);
    if (!status.ok())
      return status;
    if (dependency_resource == null || dependency_resource.owner == null)
      return invalid_state("queue dependency lookup returned no owner");
    if (!dependency_resource.owner.same_instance(owner))
      return invalid_argument("queue dependency belongs to another Function");
    if (dependency_resource.state inside {RDMA_RESOURCE_QUIESCING,
                                          RDMA_RESOURCE_ERROR})
      return invalid_state("closing queue dependency cannot admit create");
    return rdma_status::success();
  endfunction

  // 功能：在 rdma_queue_lifecycle_policy 中，clone_backing_spec 将 rhs 中 rdma_queue_lifecycle_policy 的值字段复制到当前对象，建立与源对象隔离的快照。
  // 输入/输出及副作用：source（输入）、result（输出）；clone_backing_spec 读取 source、result 并使用字段 result、cloned_object，并写入 result；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：source 为空或 clone 类型不是 rdma_queue_backing_spec 时返回错误，不产生部分有效快照。
  protected function rdma_status clone_backing_spec(
    rdma_queue_backing_spec source,
    output rdma_queue_backing_spec result
  );
    uvm_object cloned_object;

    result = null;
    if (source == null)
      return invalid_argument("queue backing specification is null");
    cloned_object = source.clone();
    if (cloned_object == null || !$cast(result, cloned_object) ||
        result == source) begin
      result = null;
      return invalid_state("queue backing specification clone failed");
    end
    return rdma_status::success();
  endfunction

  // 功能：checked_ring_layout 根据 name、role、depth、entry_size_bytes、initial_polarity、capability_limit、layout 执行 rdma_status 结果转换，具体更新字段 layout、logical_bytes、storage_bytes、candidate、candidate.role、candidate.entry_size_bytes、candidate.depth、candidate.logical_bytes；失败时返回 RDMA_SC_INVALID_ARGUMENT，保持已登记资源和输出不变。
  // 输入/输出及副作用：name（输入）、role（输入）、depth（输入）、entry_size_bytes（输入）、initial_polarity（输入）、capability_limit（输入）、layout（输出）；checked_ring_layout 读取 name、role、depth、entry_size_bytes、initial_polarity、capability_limit、layout 并使用字段 layout、logical_bytes、storage_bytes、candidate、candidate.role、candidate.entry_size_bytes、candidate.depth、candidate.logical_bytes，并写入 layout；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：checked_ring_layout 返回 RDMA_SC_INVALID_ARGUMENT；典型拒绝条件为“queue ring depth or entry size is zero”“queue ring logical size overflows”；失败路径不提交部分状态或转移未声明资源。
  protected function rdma_status checked_ring_layout(
    string name,
    rdma_queue_backing_role_e role,
    int unsigned depth,
    int unsigned entry_size_bytes,
    bit initial_polarity,
    longint unsigned capability_limit,
    output rdma_queue_ring_layout layout
  );
    longint unsigned logical_bytes;
    longint unsigned storage_bytes;
    rdma_queue_ring_layout candidate;
    rdma_status status;

    layout = null;
    if (depth == 0 || entry_size_bytes == 0)
      return invalid_argument("queue ring depth or entry size is zero");
    if ({32'b0, depth} >
        64'hffff_ffff_ffff_ffff / entry_size_bytes)
      return invalid_argument("queue ring logical size overflows");
    logical_bytes = longint'(depth) * entry_size_bytes;
    if (logical_bytes > 64'hffff_ffff_ffff_f000)
      return invalid_argument("queue ring alignment overflows");
    storage_bytes = (logical_bytes + 4095) & 64'hffff_ffff_ffff_f000;
    if (storage_bytes > capability_limit)
      return invalid_argument("queue ring exceeds Function capability");
    if (role == RDMA_QUEUE_ROLE_SRQ_SGB) begin
      if (storage_bytes > 32'hffff_ffff)
        return invalid_argument("queue SGB exceeds host allocation width");
    end else if (storage_bytes > 64'h0020_0000) begin
      return invalid_argument("queue ring exceeds one page directory");
    end

    candidate = rdma_queue_ring_layout::type_id::create(name);
    candidate.role = role;
    candidate.entry_size_bytes = entry_size_bytes;
    candidate.depth = depth;
    candidate.logical_bytes = logical_bytes;
    candidate.storage_bytes = storage_bytes;
    candidate.page_count = storage_bytes / 4096;
    candidate.initial_polarity = initial_polarity;
    status = candidate.validate_metadata();
    if (!status.ok())
      return status;
    layout = candidate;
    return rdma_status::success();
  endfunction

  // 功能：在 rdma_queue_lifecycle_policy 中，publish_preflight 提交当前事务阶段并发布 detached 结果，只有成功路径才推进游标或状态。
  // 输入/输出及副作用：candidate（输入）、result（输出）；输入 request/image/cursor 决定写入内容；成功时更新 PI/CI、slot ledger 或 pending journal，并通过
  //   output 返回结果。
  // 失败/边界：publish_preflight 返回 RDMA_SC_INVALID_STATE；典型拒绝条件为“queue preflight candidate is null”；失败路径不提交部分状态或转移未声明资源。
  protected function rdma_status publish_preflight(
    rdma_queue_preflight candidate,
    output rdma_queue_preflight result
  );
    rdma_status status;
    result = null;
    if (candidate == null)
      return invalid_state("queue preflight candidate is null");
    status = candidate.validate();
    if (!status.ok())
      return status;
    result = candidate;
    return rdma_status::success();
  endfunction

  // 功能：在 rdma_queue_lifecycle_policy 中，projected_handle 构造或投影带完整 kind、Function UID、object ID 和 generation 的资源句柄。
  // 输入/输出及副作用：name（输入）、lifecycle_source（输入）、kind（输入）、local_id（输入）、width（输入）、handle（输出）；projected_handle 读取 name、lifecycle_source、kind、local_id、width、handle 并使用字段 handle、limit、candidate、candidate.kind、candidate.function_uid、candidate.generation、candidate.object_id，并写入 handle；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：projected_handle 返回 RDMA_SC_INVALID_ARGUMENT；典型拒绝条件为“typed queue resource handle is invalid”“queue local ID exceeds context field width”；失败路径不提交部分状态或转移未声明资源。
  protected function rdma_status projected_handle(
    string name,
    rdma_handle lifecycle_source,
    rdma_resource_kind_e kind,
    int unsigned local_id,
    int unsigned width,
    output rdma_handle handle
  );
    longint unsigned limit;
    rdma_handle candidate;

    handle = null;
    if (lifecycle_source == null || lifecycle_source.kind != kind)
      return invalid_argument("typed queue resource handle is invalid");
    limit = 64'h1 << width;
    if ({32'b0, local_id} >= limit)
      return invalid_argument("queue local ID exceeds context field width");
    candidate = rdma_handle::type_id::create(name);
    candidate.kind = kind;
    candidate.function_uid = lifecycle_source.function_uid;
    candidate.generation = lifecycle_source.generation;
    candidate.object_id = local_id;
    handle = candidate;
    return rdma_status::success();
  endfunction

  // 功能：projected_dependency_status 校验 dependency、lifecycle_source、expected_kind、width、allow_null 与当前对象状态的一致性，并显式处理“projected context dependency is invalid”等拒绝条件，返回 rdma_status 供上层决定是否提交。
  // 输入/输出及副作用：dependency（输入）、lifecycle_source（输入）、expected_kind（输入）、width（输入）、allow_null（输入）；projected_dependency_status 读取 dependency、lifecycle_source、expected_kind、width、allow_null 并使用字段 limit；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：projected_dependency_status 返回 RDMA_SC_STALE_GENERATION；具体拒绝条件包括 “projected context dependency is invalid”；“projected dependency Function does not match”；“projected dependency ID exceeds field width”；“projected dependency generation does not match”；失败路径不提交部分状态、不隐式重试，也不转移未声明资源。
  protected function rdma_status projected_dependency_status(
    rdma_handle dependency,
    rdma_handle lifecycle_source,
    rdma_resource_kind_e expected_kind,
    int unsigned width,
    bit allow_null
  );
    longint unsigned limit;
    if (dependency == null && allow_null)
      return rdma_status::success();
    if (dependency == null || dependency.kind != expected_kind)
      return invalid_argument("projected context dependency is invalid");
    if (lifecycle_source == null ||
        dependency.function_uid != lifecycle_source.function_uid)
      return invalid_argument("projected dependency Function does not match");
    if (dependency.generation != lifecycle_source.generation)
      return rdma_status::make(
        RDMA_SC_STALE_GENERATION,
        "projected dependency generation does not match"
      );
    limit = 64'h1 << width;
    if ({32'b0, dependency.object_id} >= limit)
      return invalid_argument("projected dependency ID exceeds field width");
    return rdma_status::success();
  endfunction

  // 功能：在 rdma_queue_lifecycle_policy 中，find_ring 按完整 key/handle 查找唯一权威记录并返回 detached 快照，避免把内部可变引用泄露给调用方。
  // 输入/输出及副作用：plan（输入）、role（输入）、ring（输出）；find_ring 读取 plan、role、ring 并使用字段 ring、status，并写入 ring；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：find_ring 在 key/handle 缺失、记录不唯一或 generation/reset epoch 过期时返回明确错误，不回退到默认 authority。
  protected function rdma_status find_ring(
    rdma_queue_backing_plan plan,
    rdma_queue_backing_role_e role,
    output rdma_queue_ring_layout ring
  );
    rdma_status status;
    ring = null;
    if (plan == null)
      return invalid_argument("queue backing plan is null");
    foreach (plan.rings[i]) begin
      if (plan.rings[i] != null && plan.rings[i].role == role) begin
        if (ring != null)
          return invalid_state("queue backing plan repeats a ring role");
        ring = plan.rings[i];
      end
    end
    if (ring == null)
      return invalid_state("queue backing plan omits a ring role");
    status = ring.validate_metadata();
    if (!status.ok()) begin
      ring = null;
      return status;
    end
    return rdma_status::success();
  endfunction

  // 功能：在 rdma_queue_lifecycle_policy 中，find_backing_ref 按完整 key/handle 查找唯一权威记录并返回 detached 快照，避免把内部可变引用泄露给调用方。
  // 输入/输出及副作用：plan（输入）、role（输入）、ref_value（输出）；find_backing_ref 读取 plan、role、ref_value 并使用字段 ref_value、status，并写入 ref_value；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：find_backing_ref 在 key/handle 缺失、记录不唯一或 generation/reset epoch 过期时返回明确错误，不回退到默认 authority。
  protected function rdma_status find_backing_ref(
    rdma_queue_backing_plan plan,
    rdma_queue_backing_role_e role,
    output rdma_queue_backing_ref ref_value
  );
    rdma_status status;
    ref_value = null;
    if (plan == null)
      return invalid_argument("queue backing plan is null");
    foreach (plan.refs[i]) begin
      if (plan.refs[i] != null && plan.refs[i].role == role) begin
        if (ref_value != null)
          return invalid_state("queue backing plan repeats a backing role");
        ref_value = plan.refs[i];
      end
    end
    if (ref_value == null)
      return invalid_state("queue backing plan omits a backing role");
    status = ref_value.validate();
    if (!status.ok()) begin
      ref_value = null;
      return status;
    end
    return rdma_status::success();
  endfunction

  // 功能：backing_iova 根据 ref_value、address 执行 rdma_status 结果转换，具体更新字段 address、effective_iova.value；失败时返回 RDMA_SC_DMA_TRANSLATION、RDMA_SC_INVALID_ARGUMENT，保持已登记资源和输出不变。
  // 输入/输出及副作用：ref_value（输入）、address（输出）；backing_iova 读取 ref_value、address 并使用字段 address、effective_iova.value，并写入 address；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：backing_iova 返回 RDMA_SC_DMA_TRANSLATION、RDMA_SC_INVALID_ARGUMENT；典型拒绝条件为“queue backing IOVA source is null”“queue backing IOVA projection overflows”；失败路径不提交部分状态或转移未声明资源。
  protected function rdma_status backing_iova(
    rdma_queue_backing_ref ref_value,
    output rdma_backing_addr_t address
  );
    rdma_iova_t effective_iova;

    address = '0;
    if (ref_value == null || ref_value.mapping == null)
      return invalid_argument("queue backing IOVA source is null");
    if (ref_value.mapping.iova.value >
        64'hffff_ffff_ffff_ffff - ref_value.mapping_offset)
      return rdma_status::make(RDMA_SC_DMA_TRANSLATION,
                               "queue backing IOVA projection overflows");
    effective_iova.value = ref_value.mapping.iova.value + ref_value.mapping_offset;
    return rdma_queue_base_from_iova(effective_iova, address);
  endfunction

  // 功能：context_ref_status 校验 plan、owner、kind、local_id、view_offset 等参数 与当前对象状态的一致性，并显式处理“queue context backing reference is missing”等拒绝条件，返回 rdma_status 供上层决定是否提交。
  // 输入/输出及副作用：plan（输入）、owner（输入）、kind（输入）、local_id（输入）、view_offset（输入）、view_length（输入）、shadow_base（输出）；context_ref_status 读取 plan、owner、kind、local_id、view_offset、view_length、shadow_base 并使用字段 shadow_base、context_ref，并写入 shadow_base；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：context_ref_status 返回 RDMA_SC_INVALID_ARGUMENT、RDMA_SC_INVALID_STATE；典型拒绝条件为“queue context backing reference is missing”“queue context belongs to another Function”；失败路径不提交部分状态或转移未声明资源。
  protected function rdma_status context_ref_status(
    rdma_queue_backing_plan plan,
    rdma_function_handle owner,
    rdma_resource_kind_e kind,
    int unsigned local_id,
    longint unsigned view_offset,
    longint unsigned view_length,
    output rdma_backing_addr_t shadow_base
  );
    rdma_context_backing_ref context_ref;

    shadow_base = '0;
    if (plan == null || plan.context_ref == null)
      return invalid_state("queue context backing reference is missing");
    context_ref = plan.context_ref;
    if (!same_function(context_ref.owner, owner))
      return invalid_argument("queue context belongs to another Function");
    // 设计说明：同 validate 一致使用冻结 ABI stride，避免第二个 CQ 的 64B
    // shadow base 被误当 4KB page base 而在 lifecycle preflight 拒绝。
    if (context_ref.resource_kind != kind ||
        context_ref.local_id != local_id ||
        context_ref.slot_length != (kind == RDMA_RESOURCE_SRQ ? 32 : 64) ||
        context_ref.shadow_view_offset != view_offset ||
        context_ref.shadow_view_length != view_length ||
        context_ref.shadow_pointer_base.value == 0 ||
        !rdma_queue_aligned(context_ref.shadow_pointer_base.value,
                            kind == RDMA_RESOURCE_CQ ? 64 :
                            (kind == RDMA_RESOURCE_QP ? 512 : 4096)))
      return invalid_state("queue context backing geometry is invalid");
    shadow_base = context_ref.shadow_pointer_base;
    return rdma_status::success();
  endfunction

  // 功能：执行 set_indirect_layout 指定的测试或恢复状态变更，更新受控账本并保留可回滚的故障证据。
  // 输入/输出及副作用：layout（输入）、pd_address（输入）；调用方必须先完成输入对象的空值、authority 和 generation 校验；成功时更新本对象配置/状态并保存非拥有引用，返回 void。
  // 失败/边界：set_indirect_layout 仅允许测试/恢复范围内的状态变更；代际或资源不匹配时拒绝并保留原账本。
  protected function void set_indirect_layout(
    rdma_page_table_layout layout,
    rdma_backing_addr_t pd_address
  );
    layout.mode = RDMA_OBJECT_INDIRECT_4K;
    layout.sd_base = '0;
    layout.current_base = pd_address;
    layout.current_valid = 1'b1;
    layout.next_base = pd_address;
    layout.next_valid = 1'b1;
  endfunction

  // 功能：在 rdma_queue_lifecycle_policy 中，encode_context 按硬件布局把输入模型编码到 image/缓冲区，并在写入前检查范围、重叠、端序和保留位。
  // 输入/输出及副作用：model（输入）、image_kind（输入）、object_type（输入）、opcode（输入）、bytes（输出）；输入模型只读；成功时通过返回值或 output 发布完整
  //   image/bytes，不修改源模型。
  // 失败/边界：encode_context 遇到 image/model 为空、长度/对齐/保留位非法或 codec 校验失败时不发布部分字段。
  protected function rdma_status encode_context(
    rdma_hw_model model,
    rdma_image_kind_e image_kind,
    string object_type,
    bit [7:0] opcode,
    output byte unsigned bytes[]
  );
    rdma_codec_registry registry;
    rdma_codec_key key;
    rdma_codec_base codec;
    rdma_hw_image image;
    rdma_status status;
    byte unsigned candidate[];

    bytes = new[0];
    if (model == null)
      return invalid_argument("queue context model is null");
    registry = rdma_codec_registry::type_id::create(
      "queue_policy_context_registry");
    status = rdma_register_context_body_codecs(registry);
    if (!status.ok())
      return status;
    key.hw_version = "rdma";
    key.image_kind = image_kind;
    key.object_type = object_type;
    key.variant = "create";
    key.opcode = opcode;
    status = registry.lookup(key, codec);
    if (!status.ok())
      return status;
    status = codec.encode(model, image);
    if (!status.ok())
      return status;
    if (image == null || image.bytes.size() != 64 || image.length != 64)
      return invalid_state("context codec did not publish a canonical image");
    candidate = new[image.bytes.size()];
    foreach (candidate[i])
      candidate[i] = image.bytes[i];
    bytes = candidate;
    return rdma_status::success();
  endfunction

  // 功能：build_command_desc 创建独立的 rdma_status；根据 owner、opcode、variant、body、timeout、command 设置字段 command、status、key、key.profile_name、key.opcode、key.variant、candidate、candidate.function_h、candidate.opcode_key、candidate.body，返回对象仅由调用方持有，不转移外部资源所有权。
  // 输入/输出及副作用：owner（输入）、opcode（输入）、variant（输入）、body（输入）、timeout（输入）、command（输出）；输入字段被复制到返回值或
  //   output；生成结果与输入隔离，不隐式修改调用方对象。
  // 失败/边界：build_command_desc 返回 RDMA_SC_INVALID_ARGUMENT；典型拒绝条件为“queue command body or timeout is invalid”；失败路径不提交部分状态或转移未声明资源。
  protected function rdma_status build_command_desc(
    rdma_function_handle owner,
    bit [7:0] opcode,
    string variant,
    rdma_hw_model body,
    time timeout,
    output rdma_cmq_command_desc command
  );
    rdma_cmq_command_desc candidate;
    rdma_cmq_opcode_key key;
    rdma_status status;

    command = null;
    status = rdma_cmq_function_status(owner, "queue policy command");
    if (!status.ok())
      return status;
    if (body == null || timeout == 0)
      return invalid_argument("queue command body or timeout is invalid");
    key = rdma_cmq_opcode_key::type_id::create("queue_policy_opcode_key");
    key.profile_name = "rdma";
    key.opcode = opcode;
    key.variant = variant;
    candidate = rdma_cmq_command_desc::type_id::create(
      "queue_policy_command");
    candidate.function_h = rdma_clone_function_handle_value(
      owner, "queue policy command");
    candidate.opcode_key = key;
    candidate.body = rdma_cmq_clone_hw_model_value(body,
                                                    "queue policy command");
    candidate.timeout = timeout;
    status = candidate.validate();
    if (!status.ok())
      return status;
    command = candidate;
    return rdma_status::success();
  endfunction

  // 功能：build_object_desc 创建独立的 rdma_status；根据 opcode、delete_opcode、query_opcode、owner、lifecycle_handle、kind、local_id、width、timeout、command 设置字段 command、variant、status、body、body.object_h，返回对象仅由调用方持有，不转移外部资源所有权。
  // 输入/输出及副作用：opcode（输入）、delete_opcode（输入）、query_opcode（输入）、owner（输入）、lifecycle_handle（输入）、kind（输入）、local_id（输入）、width（输入）、timeout（输入）、command（输出）；输入字段被复制到返回值或
  //   output；生成结果与输入隔离，不隐式修改调用方对象。
  // 失败/边界：build_object_desc 下游操作失败时原样传播其 status/result，不伪造成功；该路径不隐式重试，也不转移未声明资源。
  protected function rdma_status build_object_desc(
    bit [7:0] opcode,
    bit [7:0] delete_opcode,
    bit [7:0] query_opcode,
    rdma_function_handle owner,
    rdma_handle lifecycle_handle,
    rdma_resource_kind_e kind,
    int unsigned local_id,
    int unsigned width,
    time timeout,
    output rdma_cmq_command_desc command
  );
    rdma_hw_object_id_command_body body;
    rdma_handle object_h;
    rdma_status status;
    string variant;

    command = null;
    if (opcode == delete_opcode)
      variant = "delete";
    else if (opcode == query_opcode)
      variant = "query";
    else
      return unsupported("queue object command opcode is not supported");
    status = projected_handle("queue_object_projection", lifecycle_handle,
                              kind, local_id, width, object_h);
    if (!status.ok())
      return status;
    status = rdma_handle_owner_status(object_h, owner);
    if (!status.ok())
      return status;
    body = rdma_hw_object_id_command_body::type_id::create(
      "queue_object_command_body");
    body.object_h = object_h;
    return build_command_desc(owner, opcode, variant, body, timeout, command);
  endfunction

  // 功能：build_pd_flush_desc 创建独立的 rdma_status；根据 owner、target、timeout、command 设置字段 command、status、body、body.pd、body.qpn、body.pd_backing，返回对象仅由调用方持有，不转移外部资源所有权。
  // 输入/输出及副作用：owner（输入）、target（输入）、timeout（输入）、command（输出）；build_pd_flush_desc 读取 owner、target、timeout、command 并使用字段 command、status、body、body.pd、body.qpn、body.pd_backing，并写入 command；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：build_pd_flush_desc 返回 RDMA_SC_INVALID_ARGUMENT；典型拒绝条件为“queue flush target is null”；失败路径不提交部分状态或转移未声明资源。
  protected function rdma_status build_pd_flush_desc(
    rdma_function_handle owner,
    rdma_queue_flush_target target,
    time timeout,
    output rdma_cmq_command_desc command
  );
    rdma_hw_occ_flush_body body;
    rdma_backing_addr_t pd_address;
    rdma_status status;

    command = null;
    if (target == null)
      return invalid_argument("queue flush target is null");
    status = target.validate();
    if (!status.ok())
      return status;
    status = backing_owner_status(target.pd_ref, owner);
    if (!status.ok())
      return status;
    status = backing_iova(target.pd_ref, pd_address);
    if (!status.ok())
      return status;
    body = rdma_hw_occ_flush_body::type_id::create(
      "queue_pd_occ_flush_body");
    body.pd = 1'b1;
    body.qpn = '0;
    body.pd_backing = pd_address;
    return build_command_desc(owner, RDMA_OP_OCC_FLUSH, "occ_flush",
                              body, timeout, command);
  endfunction

  // 中文设计：QUERY 解码所需的 context image 包含全部对象身份字段，但少数
  // create-context builder 还要求不属于 queue authoritative local-ID 投影的依赖
  // handle，例如 CQ 的 CEQ 或 SRQ 的 PD。这里为这些字段提供无害且范围合法的
  // placeholder；下方会先覆盖真实 query payload 再解码，placeholder 不可能成为
  // presence evidence。
  // 功能：在 rdma_queue_lifecycle_policy 中，query_builder_view 按完整 key/handle 查找唯一权威记录并返回 detached 快照，避免把内部可变引用泄露给调用方。
  // 输入/输出及副作用：resource（输入）、builder_resource（输出）；query_builder_view 读取 resource、builder_resource 并使用字段 builder_resource、cloned_object、cq.ceq_h、placeholder、placeholder.kind、placeholder.function_uid、placeholder.generation、placeholder.object_id，并写入 builder_resource；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：query_builder_view 在 key/handle 缺失、记录不唯一或 generation/reset epoch 过期时返回明确错误，不回退到默认 authority。
  protected function rdma_status query_builder_view(
    rdma_queue_resource resource,
    output rdma_queue_resource builder_resource
  );
    uvm_object cloned_object;
    rdma_cq cq;
    rdma_srq srq;
    rdma_handle placeholder;

    builder_resource = null;
    if (resource == null)
      return invalid_argument("query resource is null");
    cloned_object = resource.clone();
    if (cloned_object == null || !$cast(builder_resource, cloned_object) ||
        builder_resource == resource)
      return invalid_state("query builder resource clone failed");
    case (resource.resource_kind())
      RDMA_RESOURCE_CQ: begin
        if (!$cast(cq, builder_resource))
          return invalid_state("query CQ builder projection failed");
        // 中文设计：CQC 的 CEQN 来自返回 payload；CQC builder 明确支持 null
        // dependency，这可避免把 opaque registry incarnation ID 误当成 12-bit
        // local CEQ ID。
        cq.ceq_h = null;
      end
      RDMA_RESOURCE_SRQ: begin
        if (!$cast(srq, builder_resource) || srq.pd_h == null)
          return invalid_state("query SRQ builder projection failed");
        placeholder = rdma_handle::type_id::create("query_pd_placeholder");
        placeholder.kind = RDMA_RESOURCE_PD;
        placeholder.function_uid = srq.handle.function_uid;
        placeholder.generation = srq.handle.generation;
        placeholder.object_id = 0;
        srq.pd_h = placeholder;
      end
      default: begin
      end
    endcase
    return rdma_status::success();
  endfunction

  // 中文设计：CMQ engine 在轮询 raw CQE 时会鉴权 CQ owner/slot，再保存 decoded
  // payload 快照；recovery 可能收到 scripted 或 delayed completion 而非原 poll
  // 路径结果，因此本边界必须重复 immutable identity 检查。SQ wrap 属于 ticket
  // identity，CQ owner 则是 raw CQE 携带的 phase bit，不能从 SQ wrap 反推。
  // 功能：在 rdma_queue_lifecycle_policy 中，query_completion_identity_matches 按完整 key/handle 查找唯一权威记录并返回 detached 快照，避免把内部可变引用泄露给调用方。
  // 输入/输出及副作用：completion（输入）、payload（输入）；query_completion_identity_matches 读取 completion、payload 并使用字段 qword0、raw_owner、raw_wrap、raw_wqe_index、raw_opcode、raw_ecode；函数返回 bit，不取得调用方资源所有权。
  // 失败/边界：query_completion_identity_matches 在 key/handle 缺失、记录不唯一或 generation/reset epoch 过期时返回明确错误，不回退到默认 authority。
  protected function bit query_completion_identity_matches(
    rdma_cmq_completion completion,
    rdma_hw_cmq_completion payload
  );
    bit [63:0] qword0;
    bit raw_owner;
    bit [7:0] raw_opcode;
    bit [7:0] raw_ecode;
    bit [4:0] raw_wqe_index;
    bit raw_wrap;

    if (completion == null || completion.ticket == null ||
        completion.ticket.function_h == null || completion.ticket.cmq_h == null ||
        completion.ticket.opcode_key == null || completion.status == null ||
        payload == null || completion.raw_cqe == null)
      return 1'b0;
    if (completion.raw_cqe.length != 64 ||
        completion.raw_cqe.bytes.size() != 64 ||
        completion.raw_cqe.alignment != 64 ||
        completion.raw_cqe.endian != RDMA_ENDIAN_BIG ||
        completion.raw_cqe.image_kind != RDMA_IMAGE_CMQ_CQE ||
        completion.raw_cqe.hardware_version != RDMA_HW_VERSION ||
        completion.raw_cqe.write_target_kind != RDMA_HW_TARGET_NONE ||
        completion.raw_cqe.backing_target.value != 0 ||
        completion.raw_cqe.hmc_target.value != 0 ||
        completion.raw_cqe.bar_target.value != 0 ||
        completion.raw_cqe.function_generation !=
          completion.ticket.function_h.generation)
      return 1'b0;

    qword0 = '0;
    for (int unsigned i = 0; i < 8; i++)
      qword0 = {qword0[55:0], completion.raw_cqe.bytes[i]};
    raw_owner = qword0[63];
    raw_wrap = qword0[45];
    raw_wqe_index = qword0[44:40];
    raw_opcode = qword0[39:32];
    raw_ecode = qword0[31:24];

    if (completion.ticket.opcode_key.opcode != raw_opcode ||
        raw_owner != !completion.ticket.sq_wrap ||
        payload.opcode != raw_opcode || payload.command_ecode != raw_ecode ||
        payload.wqe_index != raw_wqe_index || payload.wrap != raw_wrap ||
        payload.owner != raw_owner ||
        payload.opcode != completion.ticket.opcode_key.opcode ||
        payload.wqe_index != completion.ticket.sq_index[4:0] ||
        payload.wrap != completion.ticket.sq_wrap)
      return 1'b0;
    if (completion.status.source_engine != RDMA_ENGINE_CMQ ||
        completion.status.function_uid !=
          completion.ticket.function_h.function_uid ||
        completion.status.generation != completion.ticket.function_h.generation ||
        completion.status.resource_id != completion.ticket.cmq_h.object_id ||
        completion.status.command_id != completion.ticket.command_id)
      return 1'b0;
    return 1'b1;
  endfunction

  // 功能：classify_query_common 根据 resource、completion、expected_query_opcode、expected_create_opcode、image_kind、object_type、payload_offset、payload_length、absent_ecode、absent_ecode_valid、presence、conclusive 执行 rdma_status 结果转换，具体更新字段 presence、conclusive、plan、status、query_image、query_image.length、query_image.alignment、query_image.endian；失败时返回 RDMA_SC_TIMEOUT、RDMA_SC_RESET_CANCELLED，保持已登记资源和输出不变。
  // 输入/输出及副作用：resource（输入）、completion（输入）、expected_query_opcode（输入）、expected_create_opcode（输入）、image_kind（输入）、object_type（输入）、payload_offset（输入）、payload_length（输入）、absent_ecode（输入）、absent_ecode_valid（输入）、presence（输出）、conclusive（输出）；classify_query_common 读取 resource、completion、expected_query_opcode、expected_create_opcode、image_kind、object_type、payload_offset、payload_length、absent_ecode、absent_ecode_valid、presence、conclusive 并使用字段 presence、conclusive、plan、status、query_image、query_image.length、query_image.alignment、query_image.endian，并写入 presence、conclusive；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：classify_query_common 返回 RDMA_SC_TIMEOUT、RDMA_SC_RESET_CANCELLED；具体拒绝条件包括 “query classification resource identity is incomplete”；“query CQC image kind is inconsistent”；“query SRQC image kind is inconsistent”；“query CEQC image kind is inconsistent”；“query AEQC image kind is inconsistent”；失败路径不提交部分状态、不隐式重试，也不转移未声明资源。
  protected function rdma_status classify_query_common(
    rdma_queue_resource resource,
    rdma_cmq_completion completion,
    bit [7:0] expected_query_opcode,
    bit [7:0] expected_create_opcode,
    rdma_image_kind_e image_kind,
    string object_type,
    int unsigned payload_offset,
    int unsigned payload_length,
    bit [7:0] absent_ecode,
    bit absent_ecode_valid,
    output rdma_hw_presence_e presence,
    output bit conclusive
  );
    rdma_hw_cmq_completion payload;
    rdma_queue_resource builder_resource;
    rdma_queue_backing_plan plan;
    rdma_hw_model canonical_model;
    byte unsigned canonical_bytes[];
    byte unsigned ignored_shadow[];
    rdma_hw_image query_image;
    rdma_codec_registry registry;
    rdma_codec_key key;
    rdma_codec_base codec;
    rdma_hw_model decoded_model;
    rdma_status status;
    bit typed_match;

    presence = RDMA_HW_PRESENCE_UNKNOWN;
    conclusive = 1'b0;

    if (resource == null || resource.handle == null || resource.owner == null)
      return invalid_argument("query classification resource identity is incomplete");
    if (resource.resource_kind() == RDMA_RESOURCE_CQ &&
        image_kind != RDMA_IMAGE_CQC)
      return invalid_state("query CQC image kind is inconsistent");
    if (resource.resource_kind() == RDMA_RESOURCE_SRQ &&
        image_kind != RDMA_IMAGE_SRQC)
      return invalid_state("query SRQC image kind is inconsistent");
    if (resource.resource_kind() == RDMA_RESOURCE_CEQ &&
        image_kind != RDMA_IMAGE_CEQC)
      return invalid_state("query CEQC image kind is inconsistent");
    if (resource.resource_kind() == RDMA_RESOURCE_AEQ &&
        image_kind != RDMA_IMAGE_AEQC)
      return invalid_state("query AEQC image kind is inconsistent");

    if (completion == null || completion.ticket == null ||
        completion.ticket.opcode_key == null || completion.status == null)
      return rdma_status::success();
    if (!completion.status.ok() &&
        completion.status.code inside {RDMA_SC_TIMEOUT,
                                      RDMA_SC_RESET_CANCELLED})
      return rdma_status::success();
    if (completion.ticket.opcode_key.opcode != expected_query_opcode)
      return rdma_status::success();
    if (!$cast(payload, completion.decoded_response) || payload == null)
      return rdma_status::success();
    if (!same_function(completion.ticket.function_h, resource.owner) ||
        !query_completion_identity_matches(completion, payload))
      return rdma_status::success();
    if (payload.opcode != expected_query_opcode ||
        payload.opcode != completion.ticket.opcode_key.opcode)
      return rdma_status::success();

    // 中文设计：error ecode 只有在精确鉴权到本 query opcode 后才有意义。带
    // absence whitelist 的 profile 通常不返回 object bytes，因此须在成功 payload
    // 长度检查前先应用 whitelist；whitelist 值与 OK status 配对属于畸形响应，
    // 其余非零 ecode 即使 bytes 恰好可解成合法 context 也仍然无法定论。
    if (absent_ecode_valid && payload.command_ecode == absent_ecode) begin
      if (!completion.status.ok() &&
          (!completion.status.hardware_code_valid ||
           completion.status.hardware_code[7:0] == payload.command_ecode)) begin
        presence = RDMA_HW_PRESENCE_ABSENT;
        conclusive = 1'b1;
      end
      return rdma_status::success();
    end
    if (payload.command_ecode != RDMA_CMQ_SUCCESS_ECODE)
      return rdma_status::success();
    if (!completion.status.ok() || payload.object_payload.size() !=
        payload_length)
      return rdma_status::success();
    if (completion.status.hardware_code_valid &&
        completion.status.hardware_code[7:0] != RDMA_CMQ_SUCCESS_ECODE)
      return rdma_status::success();
    if (payload_offset + payload_length > 64)
      return invalid_state("query payload bounds exceed context image");

    plan = resource.queue_plan;
    if (plan == null || plan.resource_kind != resource.resource_kind())
      return rdma_status::success();
    status = query_builder_view(resource, builder_resource);
    if (!status.ok())
      return status;
    status = build_create_context(builder_resource, plan, canonical_model,
                                  canonical_bytes, ignored_shadow);
    if (!status.ok() || canonical_model == null ||
        canonical_bytes.size() != 64)
      return status.ok() ? rdma_status::success() : status;

    query_image = rdma_hw_image::type_id::create("query_context_image");
    if (query_image == null)
      return invalid_state("query context image allocation failed");
    foreach (canonical_bytes[i]) query_image.bytes.push_back(canonical_bytes[i]);
    foreach (payload.object_payload[i])
      query_image.bytes[payload_offset + i] = payload.object_payload[i];
    query_image.length = 64;
    query_image.alignment = 64;
    query_image.endian = RDMA_ENDIAN_BIG;
    query_image.image_kind = image_kind;
    query_image.hardware_version = RDMA_HW_VERSION;
    query_image.function_generation = resource.owner.generation;
    query_image.write_target_kind = RDMA_HW_TARGET_NONE;
    query_image.backing_target = '0;
    query_image.hmc_target = '0;
    query_image.bar_target = '0;

    registry = rdma_codec_registry::type_id::create("query_context_registry");
    status = rdma_register_context_body_codecs(registry);
    if (!status.ok()) return status;
    key.hw_version = "rdma";
    key.image_kind = image_kind;
    key.object_type = object_type;
    key.variant = "create";
    key.opcode = expected_create_opcode;
    status = registry.lookup(key, codec);
    if (!status.ok()) return status;
    status = codec.decode(query_image, decoded_model);
    if (!status.ok() || decoded_model == null)
      return rdma_status::success();

    typed_match = 1'b0;
    case (resource.resource_kind())
      RDMA_RESOURCE_CQ: begin
        rdma_cq cq;
        rdma_cqc_model cqc;
        typed_match = $cast(cq, resource) && $cast(cqc, decoded_model) &&
                      cqc.cq_h != null && cqc.cq_h.kind == RDMA_RESOURCE_CQ &&
                      cqc.cq_h.object_id == cq.local_cq_id;
      end
      RDMA_RESOURCE_SRQ: begin
        rdma_srq srq;
        rdma_srqc_model srqc;
        typed_match = $cast(srq, resource) && $cast(srqc, decoded_model) &&
                      srqc.srq_h != null && srqc.srq_h.kind == RDMA_RESOURCE_SRQ &&
                      srqc.srq_h.object_id == srq.local_srq_id;
      end
      RDMA_RESOURCE_CEQ: begin
        rdma_ceq ceq;
        rdma_ceqc_model ceqc;
        typed_match = $cast(ceq, resource) && $cast(ceqc, decoded_model) &&
                      ceqc.ceq_h != null && ceqc.ceq_h.kind == RDMA_RESOURCE_CEQ &&
                      ceqc.ceq_h.object_id == ceq.local_ceq_id;
      end
      RDMA_RESOURCE_AEQ: begin
        rdma_aeq aeq;
        rdma_aeqc_model aeqc;
        typed_match = $cast(aeq, resource) && $cast(aeqc, decoded_model) &&
                      aeqc.aeq_h != null && aeqc.aeq_h.kind == RDMA_RESOURCE_AEQ &&
                      aeqc.aeq_h.object_id == aeq.local_aeq_id;
      end
      default: typed_match = 1'b0;
    endcase
    if (typed_match) begin
      presence = RDMA_HW_PRESENCE_PRESENT;
      conclusive = 1'b1;
    end
    return rdma_status::success();
  endfunction
endclass

class rdma_cq_lifecycle_policy extends rdma_queue_lifecycle_policy;
  `uvm_object_utils(rdma_cq_lifecycle_policy)

  // 功能：构造 rdma_cq_lifecycle_policy，调用 super.new 建立 UVM 层级对象；外部依赖字段保持未绑定，后续由 configure/build/activate 明确注入。
  // 输入/输出及副作用：name（输入）；new 只写入构造体列出的默认字段并返回 void，外部依赖与资源所有权仍由上层管理。
  // 失败/边界：rdma_cq_lifecycle_policy 构造只建立本地初始状态，不接管外部 Host-memory、PCIe 或 manager；未完成后续 configure/build/activate 时，业务入口必须返回 INVALID_STATE。
  function new(string name = "rdma_cq_lifecycle_policy");
    super.new(name);
  endfunction

  // 功能：resource_kind 使用 当前对象字段 计算并返回 rdma_resource_kind_e 结果；不修改对象字段或外部资源。
  // 输入/输出及副作用：无显式参数；resource_kind 读取固定返回值或局部计算结果，不使用对象成员字段；函数返回 rdma_resource_kind_e，不取得调用方资源所有权。
  // 失败/边界：resource_kind 的结果直接由 return RDMA_RESOURCE_CQ 计算；输入不满足表达式条件时沿函数体的保守分支返回，不修改已发布账本。
  virtual function rdma_resource_kind_e resource_kind();
    return RDMA_RESOURCE_CQ;
  endfunction

  // 功能：在 rdma_cq_lifecycle_policy 中，reserve_resource 检查容量后预留资源并返回带 owner 证据的句柄/计划；失败时回滚已登记的局部状态。
  // 输入/输出及副作用：manager（输入）、binding（输入）、request（输入）、resource（输出）；输入请求/句柄定义资源属性；成功时更新账本并通过返回值或 output 发布新句柄/映射。
  // 失败/边界：容量不足、范围非法、重复占用或身份过期时返回错误；失败不得泄漏半分配资源。
  virtual function rdma_status reserve_resource(
    rdma_resource_manager manager, rdma_function_binding binding,
    rdma_semantic_request request, output rdma_queue_resource resource);
    rdma_create_cq_req cq_request;
    rdma_cq cq;

    resource = null;
    if (manager == null || binding == null ||
        !$cast(cq_request, request))
      return invalid_argument("CQ reservation input is invalid");
    begin
      rdma_status status;
      status = manager.create_cq(binding, cq_request.ceq_h, cq);
      if (status != null && status.ok())
        resource = cq;
      return status;
    end
  endfunction

  // 功能：CQ preflight 校验 CQ depth、CQE 大小、CEQ 依赖和 Function 归属，并将规范化结果写入 result。
  // 输入/输出及副作用：binding（输入）、request（输入）、manager（输入）、result（输出）；preflight 读取 binding、request、manager、result 并使用字段 result、status、candidate、candidate.resource_kind、candidate.depth、candidate.cqe_size_bytes，并写入 result；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：必需对象/句柄/快照为空，或身份、范围、generation 和生命周期检查失败时返回非成功状态。
  virtual function rdma_status preflight(
    rdma_function_binding binding, rdma_semantic_request request,
    rdma_resource_manager manager, output rdma_queue_preflight result);
    rdma_create_cq_req cq_request;
    rdma_function_handle owner;
    rdma_queue_preflight candidate;
    rdma_queue_ring_layout ring;
    rdma_status status;

    result = null;
    if (!$cast(cq_request, request))
      return invalid_argument("CQ policy requires rdma_create_cq_req");
    status = common_preflight_status(binding, cq_request, manager, owner);
    if (!status.ok())
      return status;
    if (cq_request.depth < binding.queue_caps.min_cq_depth ||
        cq_request.depth > binding.queue_caps.max_cq_depth)
      return invalid_argument("CQ depth exceeds Function capability");
    status = dependency_status(manager, owner, cq_request.ceq_h,
                               RDMA_RESOURCE_CEQ, 1'b1);
    if (!status.ok())
      return status;
    if (cq_request.ring_backing.mode == RDMA_QUEUE_BACKING_BORROWED) begin
      status = rdma_queue_borrowed_role_policy::validate_single_role(
        cq_request.ring_backing, RDMA_QUEUE_ROLE_CQ_RING,
        "CQ borrowed backing has an invalid role",
        "CQ borrowed backing omits CQ_RING"
      );
      if (!status.ok()) return status;
    end
    status = checked_ring_layout("cq_preflight_ring",
      RDMA_QUEUE_ROLE_CQ_RING, cq_request.depth, cq_request.cqe_size_bytes,
      1'b1, binding.queue_caps.max_queue_ring_bytes, ring);
    if (!status.ok())
      return status;
    candidate = rdma_queue_preflight::type_id::create("cq_preflight");
    candidate.resource_kind = RDMA_RESOURCE_CQ;
    candidate.depth = cq_request.depth;
    candidate.cqe_size_bytes = cq_request.cqe_size_bytes;
    status = clone_backing_spec(cq_request.ring_backing,
                                candidate.backing_spec);
    if (!status.ok())
      return status;
    candidate.required_rings.push_back(ring);
    return publish_preflight(candidate, result);
  endfunction

  // 功能：build_create_context 创建独立的 rdma_status；根据 resource、plan、context_model、context_slot_image、context_shadow_image 设置字段 context_model、context_slot_image、context_shadow_image、status、candidate、candidate.cq_h、candidate.ceq_h、candidate.state、candidate.depth、candidate.cqe_size_bytes，返回对象仅由调用方持有，不转移外部资源所有权。
  // 输入/输出及副作用：resource（输入）、plan（输入）、context_model（输出）、context_slot_image（输出）、context_shadow_image（输出）；输入字段被复制到返回值或
  //   output；生成结果与输入隔离，不隐式修改调用方对象。
  // 失败/边界：build_create_context 返回 RDMA_SC_INVALID_ARGUMENT、RDMA_SC_INVALID_STATE；典型拒绝条件为“CQ context builder requires rdma_cq”“CQ context builder received the wrong plan”；失败路径不提交部分状态或转移未声明资源。
  virtual function rdma_status build_create_context(
    rdma_queue_resource resource, rdma_queue_backing_plan plan,
    output rdma_hw_model context_model,
    output byte unsigned context_slot_image[],
    output byte unsigned context_shadow_image[]);
    rdma_cq cq;
    rdma_queue_ring_layout ring;
    rdma_queue_backing_ref pd_ref;
    rdma_backing_addr_t pd_address;
    rdma_backing_addr_t shadow_base;
    rdma_handle cq_h;
    rdma_cqc_model candidate;
    byte unsigned slot_candidate[];
    byte unsigned shadow_candidate[];
    rdma_status status;

    context_model = null;
    context_slot_image = new[0];
    context_shadow_image = new[0];
    if (!$cast(cq, resource))
      return invalid_argument("CQ context builder requires rdma_cq");
    if (plan == null || plan.resource_kind != RDMA_RESOURCE_CQ)
      return invalid_argument("CQ context builder received the wrong plan");
    status = queue_resource_owner_status(cq, RDMA_RESOURCE_CQ);
    if (!status.ok()) return status;
    status = projected_handle("cqc_cq", cq.handle, RDMA_RESOURCE_CQ,
                              cq.local_cq_id, 21, cq_h);
    if (!status.ok()) return status;
    status = projected_dependency_status(cq.ceq_h, cq.handle,
                                         RDMA_RESOURCE_CEQ, 12, 1'b1);
    if (!status.ok()) return status;
    status = find_ring(plan, RDMA_QUEUE_ROLE_CQ_RING, ring);
    if (!status.ok()) return status;
    status = find_backing_ref(plan, RDMA_QUEUE_ROLE_CQ_PD, pd_ref);
    if (!status.ok()) return status;
    status = backing_owner_status(pd_ref, cq.owner);
    if (!status.ok()) return status;
    status = backing_iova(pd_ref, pd_address);
    if (!status.ok()) return status;
    status = context_ref_status(plan, cq.owner, RDMA_RESOURCE_CQ,
                                cq.local_cq_id,
                                48, 8, shadow_base);
    if (!status.ok()) return status;
    if (ring.depth != cq.depth || ring.entry_size_bytes != cq.cqe_size_bytes)
      return invalid_state("CQ resource and backing plan disagree");

    candidate = rdma_cqc_model::type_id::create("canonical_cqc");
    candidate.cq_h = cq_h;
    candidate.ceq_h = rdma_clone_handle_value(cq.ceq_h,
                                               "CQC projected CEQ");
    candidate.state = RDMA_CONTEXT_VALID;
    candidate.depth = cq.depth;
    candidate.cqe_size_bytes = cq.cqe_size_bytes;
    candidate.threshold = 2;
    set_indirect_layout(candidate.page_layout, pd_address);
    candidate.producer.index = 0;
    candidate.producer.wrap = 1'b0;
    candidate.consumer.index = 0;
    candidate.consumer.wrap = 1'b0;
    candidate.urc_enable = 1'b0;
    candidate.load_ci_done = 1'b1;
    candidate.last_arm_sequence = 1;
    candidate.arm_sequence = 0;
    candidate.arm_state = 0;
    candidate.shadow_backing = shadow_base;
    status = encode_context(candidate, RDMA_IMAGE_CQC, "cqc",
                            RDMA_OP_CQC_CREATE, slot_candidate);
    if (!status.ok()) return status;
    shadow_candidate = new[8];
    foreach (shadow_candidate[i]) shadow_candidate[i] = 0;
    context_model = candidate;
    context_slot_image = slot_candidate;
    context_shadow_image = shadow_candidate;
    return rdma_status::success();
  endfunction

  // 功能：build_create_command 创建独立的 rdma_status；根据 owner、resource、context_model、timeout、command 设置字段 command、status，返回对象仅由调用方持有，不转移外部资源所有权。
  // 输入/输出及副作用：owner（输入）、resource（输入）、context_model（输入）、timeout（输入）、command（输出）；输入字段被复制到返回值或
  //   output；生成结果与输入隔离，不隐式修改调用方对象。
  // 失败/边界：build_create_command 返回 RDMA_SC_INVALID_ARGUMENT；典型拒绝条件为“CQ create command requires CQ/CQC types”“CQC model does not match CQ local ID”；失败路径不提交部分状态或转移未声明资源。
  virtual function rdma_status build_create_command(
    rdma_function_handle owner, rdma_queue_resource resource,
    rdma_hw_model context_model, time timeout,
    output rdma_cmq_command_desc command);
    rdma_cq cq;
    rdma_cqc_model cqc;
    rdma_status status;
    command = null;
    if (!$cast(cq, resource) || !$cast(cqc, context_model))
      return invalid_argument("CQ create command requires CQ/CQC types");
    if (cqc.cq_h == null || cqc.cq_h.object_id != cq.local_cq_id)
      return invalid_argument("CQC model does not match CQ local ID");
    status = command_owner_status(owner, cq, cqc.cq_h, RDMA_RESOURCE_CQ);
    if (!status.ok()) return status;
    return build_command_desc(owner, RDMA_OP_CQC_CREATE, "create", cqc,
                              timeout, command);
  endfunction

  // 功能：build_object_command 创建独立的 rdma_status；根据 opcode、owner、resource、timeout、command 设置字段 command、status，返回对象仅由调用方持有，不转移外部资源所有权。
  // 输入/输出及副作用：opcode（输入）、owner（输入）、resource（输入）、timeout（输入）、command（输出）；build_object_command 读取 opcode、owner、resource、timeout、command 并使用字段 command、status，并写入 command；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：build_object_command 返回 RDMA_SC_INVALID_ARGUMENT；典型拒绝条件为“CQ object command requires rdma_cq”；失败路径不提交部分状态或转移未声明资源。
  virtual function rdma_status build_object_command(
    bit [7:0] opcode, rdma_function_handle owner,
    rdma_queue_resource resource, time timeout,
    output rdma_cmq_command_desc command);
    rdma_cq cq;
    rdma_hw_cqc_delete_body delete_body;
    rdma_cqc_model delete_context;
    rdma_status status;

    command = null;
    if (!$cast(cq, resource))
      return invalid_argument("CQ object command requires rdma_cq");
    status = command_resource_owner_status(owner, cq, RDMA_RESOURCE_CQ);
    if (!status.ok())
      return status;

    if (opcode == RDMA_OP_CQC_DELETE) begin
      if (cq.programmed_cqc == null)
        return invalid_state(
          "CQC delete requires the programmed CQC context snapshot"
        );

      delete_context = cq.programmed_cqc;
      if (delete_context.cq_h == null ||
          delete_context.cq_h.object_id != cq.local_cq_id)
        return invalid_state(
          "CQC delete context does not match CQ local ID"
        );
      status = rdma_handle_owner_status(delete_context.cq_h, owner);
      if (!status.ok())
        return status;

      if (!rdma_deep_copy#(rdma_cqc_model)::try_of(delete_context, delete_context) ||
          delete_context == cq.programmed_cqc)
        return invalid_state("CQC delete context clone failed");

      delete_body = rdma_hw_cqc_delete_body::type_id::create(
        "cq_delete_body");
      delete_body.cqc_context = delete_context;
      return build_command_desc(owner, opcode, "delete", delete_body,
                                timeout, command);
    end

    if (opcode != RDMA_OP_CQC_QUERY)
      return unsupported("CQ object command opcode is not supported");

    return build_object_desc(opcode, RDMA_OP_CQC_DELETE,
                             RDMA_OP_CQC_QUERY, owner, cq.handle,
                             RDMA_RESOURCE_CQ, cq.local_cq_id, 21, timeout,
                             command);
  endfunction

  // 功能：build_flush_command 创建独立的 rdma_status；根据 owner、target、timeout、command 设置字段 command，返回对象仅由调用方持有，不转移外部资源所有权。
  // 输入/输出及副作用：owner（输入）、target（输入）、timeout（输入）、command（输出）；build_flush_command 读取 owner、target、timeout、command 并使用字段 command，并写入 command；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：build_flush_command 返回 RDMA_SC_INVALID_ARGUMENT；典型拒绝条件为“CQ flush target is not CQ_PD/POST_DELETE”；失败路径不提交部分状态或转移未声明资源。
  virtual function rdma_status build_flush_command(
    rdma_function_handle owner, rdma_queue_flush_target target,
    time timeout, output rdma_cmq_command_desc command);
    command = null;
    if (target == null || target.role != RDMA_QUEUE_ROLE_CQ_PD ||
        target.phase != RDMA_QUEUE_FLUSH_POST_DELETE)
      return invalid_argument("CQ flush target is not CQ_PD/POST_DELETE");
    return build_pd_flush_desc(owner, target, timeout, command);
  endfunction

  // 功能：classify_query_completion 根据 resource、completion、presence、conclusive 执行 rdma_status 结果转换，具体更新字段 输出参数 presence、conclusive；失败分支保持已登记资源和输出不变，并将错误状态返回调用方。
  // 输入/输出及副作用：resource（输入）、completion（输入）、presence（输出）、conclusive（输出）；classify_query_completion 读取 resource、completion、presence、conclusive 并使用输入参数和固定枚举/常量，并写入 presence、conclusive；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：classify_query_completion 只读输入并返回 rdma_status；边界由函数体现有分支决定，不修改状态或转移资源。
  virtual function rdma_status classify_query_completion(
    rdma_queue_resource resource,
    rdma_cmq_completion completion,
    output rdma_hw_presence_e presence,
    output bit conclusive
  );
    return classify_query_common(resource, completion, RDMA_OP_CQC_QUERY,
      RDMA_OP_CQC_CREATE, RDMA_IMAGE_CQC, "cqc", 8, 56,
      RDMA_ECODE_EC_RCE_CQC_INVLD, 1'b1, presence, conclusive);
  endfunction

  // 功能：在 rdma_cq_lifecycle_policy 中，hardware_cleanup_roles 返回该资源策略要求的硬件 flush 与本地释放角色及其执行顺序。
  // 输入/输出及副作用：flush_roles（输出）、flush_phases（输出）、delete_before_flush（输出）；hardware_cleanup_roles 读取 flush_roles、flush_phases、delete_before_flush 并使用字段 delete_before_flush，并写入 flush_roles、flush_phases、delete_before_flush；函数返回 void，不取得调用方资源所有权。
  // 失败/边界：hardware_cleanup_roles 无返回值，仅执行 delete_before_flush=1'b1；调用方须保证前置依赖已经绑定，函数不自动重试或接管外部资源。
  virtual function void hardware_cleanup_roles(
    output rdma_queue_backing_role_e flush_roles[$],
    output rdma_queue_flush_phase_e flush_phases[$],
    output bit delete_before_flush
  );
    flush_roles.delete();
    flush_phases.delete();
    delete_before_flush = 1'b1;
    flush_roles.push_back(RDMA_QUEUE_ROLE_CQ_PD);
    flush_phases.push_back(RDMA_QUEUE_FLUSH_POST_DELETE);
  endfunction

  // 功能：在 rdma_cq_lifecycle_policy 中，local_cleanup_roles 返回该资源策略要求的硬件 flush 与本地释放角色及其执行顺序。
  // 输入/输出及副作用：roles（输出）、release_context_first（输出）；local_cleanup_roles 读取 roles、release_context_first 并使用字段 release_context_first，并写入 roles、release_context_first；函数返回 void，不取得调用方资源所有权。
  // 失败/边界：local_cleanup_roles 无返回值，仅执行 release_context_first=1'b1；调用方须保证前置依赖已经绑定，函数不自动重试或接管外部资源。
  virtual function void local_cleanup_roles(
    output rdma_queue_backing_role_e roles[$],
    output bit release_context_first
  );
    roles.delete();
    release_context_first = 1'b1;
    roles.push_back(RDMA_QUEUE_ROLE_CQ_PD);
    roles.push_back(RDMA_QUEUE_ROLE_CQ_RING);
  endfunction
endclass

class rdma_srq_lifecycle_policy extends rdma_queue_lifecycle_policy;
  `uvm_object_utils(rdma_srq_lifecycle_policy)

  // 功能：构造 rdma_srq_lifecycle_policy，调用 super.new 建立 UVM 层级对象；外部依赖字段保持未绑定，后续由 configure/build/activate 明确注入。
  // 输入/输出及副作用：name（输入）；new 只写入构造体列出的默认字段并返回 void，外部依赖与资源所有权仍由上层管理。
  // 失败/边界：rdma_srq_lifecycle_policy 构造只建立本地初始状态，不接管外部 Host-memory、PCIe 或 manager；未完成后续 configure/build/activate 时，业务入口必须返回 INVALID_STATE。
  function new(string name = "rdma_srq_lifecycle_policy");
    super.new(name);
  endfunction

  // 功能：resource_kind 使用 当前对象字段 计算并返回 rdma_resource_kind_e 结果；不修改对象字段或外部资源。
  // 输入/输出及副作用：无显式参数；resource_kind 读取固定返回值或局部计算结果，不使用对象成员字段；函数返回 rdma_resource_kind_e，不取得调用方资源所有权。
  // 失败/边界：resource_kind 的结果直接由 return RDMA_RESOURCE_SRQ 计算；输入不满足表达式条件时沿函数体的保守分支返回，不修改已发布账本。
  virtual function rdma_resource_kind_e resource_kind();
    return RDMA_RESOURCE_SRQ;
  endfunction

  // 功能：在 rdma_srq_lifecycle_policy 中，reserve_resource 检查容量后预留资源并返回带 owner 证据的句柄/计划；失败时回滚已登记的局部状态。
  // 输入/输出及副作用：manager（输入）、binding（输入）、request（输入）、resource（输出）；输入请求/句柄定义资源属性；成功时更新账本并通过返回值或 output 发布新句柄/映射。
  // 失败/边界：容量不足、范围非法、重复占用或身份过期时返回错误；失败不得泄漏半分配资源。
  virtual function rdma_status reserve_resource(
    rdma_resource_manager manager, rdma_function_binding binding,
    rdma_semantic_request request, output rdma_queue_resource resource);
    rdma_create_srq_req srq_request;
    rdma_srq srq;

    resource = null;
    if (manager == null || binding == null ||
        !$cast(srq_request, request))
      return invalid_argument("SRQ reservation input is invalid");
    begin
      rdma_status status;
      status = manager.create_srq(binding, srq_request.pd_h, srq);
      if (status != null && status.ok())
        resource = srq;
      return status;
    end
  endfunction

  // 功能：SRQ preflight 校验 SRQ depth、max_sge、阈值和 SGB backing 需求，并将规范化结果写入 result。
  // 输入/输出及副作用：binding（输入）、request（输入）、manager（输入）、result（输出）；preflight 读取 binding、request、manager、result 并使用字段 result、status、need_sgb、candidate、candidate.resource_kind、candidate.depth、candidate.max_sge、candidate.limit_threshold，并写入 result；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：必需对象/句柄/快照为空，或身份、范围、generation 和生命周期检查失败时返回非成功状态。
  virtual function rdma_status preflight(
    rdma_function_binding binding, rdma_semantic_request request,
    rdma_resource_manager manager, output rdma_queue_preflight result);
    rdma_create_srq_req srq_request;
    rdma_function_handle owner;
    rdma_queue_preflight candidate;
    rdma_queue_ring_layout ring;
    rdma_status status;
    bit need_sgb;

    result = null;
    if (!$cast(srq_request, request))
      return invalid_argument("SRQ policy requires rdma_create_srq_req");
    status = common_preflight_status(binding, srq_request, manager, owner);
    if (!status.ok()) return status;
    status = rdma_srq_preflight_value_policy::validate_limits(
      srq_request.depth,
      srq_request.max_sge,
      srq_request.limit_threshold,
      binding.queue_caps.min_srq_depth,
      binding.queue_caps.max_srq_depth,
      binding.queue_caps.max_wq_sge
    );
    if (!status.ok()) return status;
    status = dependency_status(manager, owner, srq_request.pd_h,
                               RDMA_RESOURCE_PD, 1'b0);
    if (!status.ok()) return status;
    need_sgb = rdma_srq_preflight_value_policy::requires_sgb(
      srq_request.max_sge
    );
    if (srq_request.payload_backing.mode == RDMA_QUEUE_BACKING_BORROWED) begin
      status = rdma_srq_preflight_value_policy::validate_borrowed_backing(
        srq_request.payload_backing, need_sgb
      );
      if (!status.ok()) return status;
    end
    candidate = rdma_queue_preflight::type_id::create("srq_preflight");
    candidate.resource_kind = RDMA_RESOURCE_SRQ;
    candidate.depth = srq_request.depth;
    candidate.max_sge = srq_request.max_sge;
    candidate.limit_threshold = srq_request.limit_threshold;
    status = clone_backing_spec(srq_request.payload_backing,
                                candidate.backing_spec);
    if (!status.ok()) return status;
    status = checked_ring_layout("srq_preflight_ring",
      RDMA_QUEUE_ROLE_SRQ_RING, srq_request.depth, 64, 1'b0,
      binding.queue_caps.max_queue_ring_bytes, ring);
    if (!status.ok()) return status;
    candidate.required_rings.push_back(ring);
    status = checked_ring_layout("srfq_preflight_ring",
      RDMA_QUEUE_ROLE_SRFQ_RING, srq_request.depth, 64, 1'b0,
      binding.queue_caps.max_queue_ring_bytes, ring);
    if (!status.ok()) return status;
    candidate.required_rings.push_back(ring);
    if (need_sgb) begin
      status = checked_ring_layout("srq_sgb_preflight",
        RDMA_QUEUE_ROLE_SRQ_SGB, srq_request.depth, 512, 1'b0,
        binding.queue_caps.max_sgb_bytes, ring);
      if (!status.ok()) return status;
      candidate.required_rings.push_back(ring);
    end
    return publish_preflight(candidate, result);
  endfunction

  // 功能：build_create_context 创建独立的 rdma_status；根据 resource、plan、context_model、context_slot_image、context_shadow_image 设置字段 context_model、context_slot_image、context_shadow_image、status、encoded_limit、candidate、candidate.srq_h、candidate.pd_h、candidate.state、candidate.depth，返回对象仅由调用方持有，不转移外部资源所有权。
  // 输入/输出及副作用：resource（输入）、plan（输入）、context_model（输出）、context_slot_image（输出）、context_shadow_image（输出）；输入字段被复制到返回值或
  //   output；生成结果与输入隔离，不隐式修改调用方对象。
  // 失败/边界：build_create_context 返回 函数体规定的失败状态；具体拒绝条件包括 “SRQ context builder requires rdma_srq”；“SRQ context builder received the wrong plan”；“SRQ limit threshold is invalid”；“SRQ encoded limit exceeds 14 bits”；“SRQ resource and backing plan disagree”；失败路径不提交部分状态、不隐式重试，也不转移未声明资源。
  virtual function rdma_status build_create_context(
    rdma_queue_resource resource, rdma_queue_backing_plan plan,
    output rdma_hw_model context_model,
    output byte unsigned context_slot_image[],
    output byte unsigned context_shadow_image[]);
    rdma_srq srq;
    rdma_queue_ring_layout ring;
    rdma_queue_backing_ref pd_ref;
    rdma_backing_addr_t pd_address;
    rdma_backing_addr_t shadow_base;
    rdma_handle srq_h;
    rdma_srqc_model candidate;
    byte unsigned slot_candidate[];
    byte unsigned shadow_candidate[];
    int unsigned encoded_limit;
    rdma_status status;

    context_model = null;
    context_slot_image = new[0];
    context_shadow_image = new[0];
    if (!$cast(srq, resource))
      return invalid_argument("SRQ context builder requires rdma_srq");
    if (plan == null || plan.resource_kind != RDMA_RESOURCE_SRQ)
      return invalid_argument("SRQ context builder received the wrong plan");
    status = queue_resource_owner_status(srq, RDMA_RESOURCE_SRQ);
    if (!status.ok()) return status;
    if (srq.limit_threshold < 16 || srq.limit_threshold > srq.depth ||
        srq.limit_threshold % 4 != 0)
      return invalid_argument("SRQ limit threshold is invalid");
    encoded_limit = srq.limit_threshold / 4;
    if (encoded_limit > 14'h3fff)
      return invalid_argument("SRQ encoded limit exceeds 14 bits");
    status = projected_handle("srqc_srq", srq.handle, RDMA_RESOURCE_SRQ,
                              srq.local_srq_id, 16, srq_h);
    if (!status.ok()) return status;
    status = projected_dependency_status(srq.pd_h, srq.handle,
                                         RDMA_RESOURCE_PD, 16, 1'b0);
    if (!status.ok()) return status;
    status = find_ring(plan, RDMA_QUEUE_ROLE_SRFQ_RING, ring);
    if (!status.ok()) return status;
    status = find_backing_ref(plan, RDMA_QUEUE_ROLE_SRFQ_PD, pd_ref);
    if (!status.ok()) return status;
    status = backing_owner_status(pd_ref, srq.owner);
    if (!status.ok()) return status;
    status = backing_iova(pd_ref, pd_address);
    if (!status.ok()) return status;
    status = context_ref_status(plan, srq.owner, RDMA_RESOURCE_SRQ,
                                srq.local_srq_id,
                                28, 4, shadow_base);
    if (!status.ok()) return status;
    if (ring.depth != srq.depth || ring.entry_size_bytes != 64)
      return invalid_state("SRQ resource and backing plan disagree");

    candidate = rdma_srqc_model::type_id::create("canonical_srqc");
    candidate.srq_h = srq_h;
    candidate.pd_h = rdma_clone_handle_value(srq.pd_h,
                                              "SRQC projected PD");
    candidate.state = RDMA_CONTEXT_VALID;
    candidate.depth = srq.depth;
    candidate.load_pi_threshold = 8;
    candidate.limit_threshold = encoded_limit;
    candidate.object_mode = RDMA_OBJECT_INDIRECT_4K;
    candidate.srfq_backing = pd_address;
    candidate.shadow_backing = shadow_base;
    candidate.producer.index = 0;
    candidate.producer.wrap = 1'b0;
    candidate.arm_sequence = 0;
    status = encode_context(candidate, RDMA_IMAGE_SRQC, "srqc",
                            RDMA_OP_SRFQC_CREATE, slot_candidate);
    if (!status.ok()) return status;
    shadow_candidate = new[4];
    shadow_candidate[0] = 8'h00;
    shadow_candidate[1] = 8'h00;
    shadow_candidate[2] = byte'((encoded_limit << 2) >> 8);
    shadow_candidate[3] = byte'(encoded_limit << 2);
    context_model = candidate;
    context_slot_image = slot_candidate;
    context_shadow_image = shadow_candidate;
    return rdma_status::success();
  endfunction

  // 功能：build_create_command 创建独立的 rdma_status；根据 owner、resource、context_model、timeout、command 设置字段 command、status，返回对象仅由调用方持有，不转移外部资源所有权。
  // 输入/输出及副作用：owner（输入）、resource（输入）、context_model（输入）、timeout（输入）、command（输出）；输入字段被复制到返回值或
  //   output；生成结果与输入隔离，不隐式修改调用方对象。
  // 失败/边界：build_create_command 返回 RDMA_SC_INVALID_ARGUMENT；典型拒绝条件为“SRQ create command requires SRQ/SRQC types”“SRQC model does not match SRQ local ID”；失败路径不提交部分状态或转移未声明资源。
  virtual function rdma_status build_create_command(
    rdma_function_handle owner, rdma_queue_resource resource,
    rdma_hw_model context_model, time timeout,
    output rdma_cmq_command_desc command);
    rdma_srq srq;
    rdma_srqc_model srqc;
    rdma_status status;
    command = null;
    if (!$cast(srq, resource) || !$cast(srqc, context_model))
      return invalid_argument("SRQ create command requires SRQ/SRQC types");
    if (srqc.srq_h == null || srqc.srq_h.object_id != srq.local_srq_id)
      return invalid_argument("SRQC model does not match SRQ local ID");
    status = command_owner_status(owner, srq, srqc.srq_h,
                                  RDMA_RESOURCE_SRQ);
    if (!status.ok()) return status;
    return build_command_desc(owner, RDMA_OP_SRFQC_CREATE, "create", srqc,
                              timeout, command);
  endfunction

  // 功能：build_object_command 创建独立的 rdma_status；根据 opcode、owner、resource、timeout、command 设置字段 command、status，返回对象仅由调用方持有，不转移外部资源所有权。
  // 输入/输出及副作用：opcode（输入）、owner（输入）、resource（输入）、timeout（输入）、command（输出）；build_object_command 读取 opcode、owner、resource、timeout、command 并使用字段 command、status，并写入 command；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：build_object_command 返回 RDMA_SC_INVALID_ARGUMENT；典型拒绝条件为“SRQ object command requires rdma_srq”；失败路径不提交部分状态或转移未声明资源。
  virtual function rdma_status build_object_command(
    bit [7:0] opcode, rdma_function_handle owner,
    rdma_queue_resource resource, time timeout,
    output rdma_cmq_command_desc command);
    rdma_srq srq;
    rdma_status status;
    command = null;
    if (!$cast(srq, resource))
      return invalid_argument("SRQ object command requires rdma_srq");
    status = command_resource_owner_status(owner, srq, RDMA_RESOURCE_SRQ);
    if (!status.ok()) return status;
    return build_object_desc(opcode, RDMA_OP_SRFQC_DELETE,
      RDMA_OP_SRFQC_QUERY, owner, srq.handle, RDMA_RESOURCE_SRQ,
      srq.local_srq_id, 16, timeout, command);
  endfunction

  // 功能：build_flush_command 创建独立的 rdma_status；根据 owner、target、timeout、command 设置字段 command，返回对象仅由调用方持有，不转移外部资源所有权。
  // 输入/输出及副作用：owner（输入）、target（输入）、timeout（输入）、command（输出）；build_flush_command 读取 owner、target、timeout、command 并使用字段 command，并写入 command；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：build_flush_command 返回 RDMA_SC_INVALID_ARGUMENT；典型拒绝条件为“SRQ flush target is not a pre-delete PD”；失败路径不提交部分状态或转移未声明资源。
  virtual function rdma_status build_flush_command(
    rdma_function_handle owner, rdma_queue_flush_target target,
    time timeout, output rdma_cmq_command_desc command);
    command = null;
    if (target == null ||
        !(target.role inside {RDMA_QUEUE_ROLE_SRFQ_PD,
                              RDMA_QUEUE_ROLE_SRQ_PD}) ||
        target.phase != RDMA_QUEUE_FLUSH_PRE_DELETE)
      return invalid_argument("SRQ flush target is not a pre-delete PD");
    return build_pd_flush_desc(owner, target, timeout, command);
  endfunction

  // 功能：classify_query_completion 根据 resource、completion、presence、conclusive 执行 rdma_status 结果转换，具体更新字段 输出参数 presence、conclusive；失败分支保持已登记资源和输出不变，并将错误状态返回调用方。
  // 输入/输出及副作用：resource（输入）、completion（输入）、presence（输出）、conclusive（输出）；classify_query_completion 读取 resource、completion、presence、conclusive 并使用字段 hff，并写入 presence、conclusive；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：classify_query_completion 只读输入并返回 rdma_status；边界由函数体现有分支决定，不修改状态或转移资源。
  virtual function rdma_status classify_query_completion(
    rdma_queue_resource resource,
    rdma_cmq_completion completion,
    output rdma_hw_presence_e presence,
    output bit conclusive
  );
    return classify_query_common(resource, completion, RDMA_OP_SRFQC_QUERY,
      RDMA_OP_SRFQC_CREATE, RDMA_IMAGE_SRQC, "srqc", 16, 32,
      8'hff, 1'b0, presence, conclusive);
  endfunction

  // 功能：在 rdma_srq_lifecycle_policy 中，hardware_cleanup_roles 返回该资源策略要求的硬件 flush 与本地释放角色及其执行顺序。
  // 输入/输出及副作用：flush_roles、flush_phases、delete_before_flush（输出）；
  //   hardware_cleanup_roles 从 detached SRQ value policy 复制 SRFQ_PD→SRQ_PD 的
  //   PRE_DELETE recipe，不修改 queue、QP dependency 或 manager 账本。
  // 失败/边界：hardware_cleanup_roles 无返回值且当前 policy 固定
  //   delete_before_flush=1'b0；调用方仍须在 CMQ completion 后记录 flush 进度，
  //   不能把 recipe 当作成功证据。
  virtual function void hardware_cleanup_roles(
    output rdma_queue_backing_role_e flush_roles[$],
    output rdma_queue_flush_phase_e flush_phases[$],
    output bit delete_before_flush
  );
    rdma_queue_backing_role_e local_roles[$];
    bit release_context_first;

    rdma_srq_destroy_value_policy(
      1'b1, flush_roles, flush_phases, delete_before_flush,
      local_roles, release_context_first);
  endfunction

  // 功能：在 rdma_srq_lifecycle_policy 中，local_cleanup_roles 返回该资源策略要求的硬件 flush 与本地释放角色及其执行顺序。
  // 输入/输出及副作用：roles、release_context_first（输出）；local_cleanup_roles
  //   从 detached SRQ value policy 复制 SRFQ_PD→SRQ_PD→可选 SRQ_SGB→SRFQ_RING
  //   →SRQ_RING 的逆向释放 recipe，不修改 queue、QP dependency 或 manager 账本。
  // 失败/边界：local_cleanup_roles 无返回值且 canonical policy 保留 SRQ_SGB
  //   作为可选 recipe entry；destroy executor 会按实际 plan.refs 豁免缺失的
  //   max_sge<=2 SGB，不能提前释放 borrowed backing。
  virtual function void local_cleanup_roles(
    output rdma_queue_backing_role_e roles[$],
    output bit release_context_first
  );
    rdma_queue_backing_role_e flush_roles[$];
    rdma_queue_flush_phase_e flush_phases[$];
    bit delete_before_flush;

    rdma_srq_destroy_value_policy(
      1'b1, flush_roles, flush_phases, delete_before_flush,
      roles, release_context_first);
  endfunction
endclass

class rdma_ceq_lifecycle_policy extends rdma_queue_lifecycle_policy;
  `uvm_object_utils(rdma_ceq_lifecycle_policy)

  // 功能：构造 rdma_ceq_lifecycle_policy，调用 super.new 建立 UVM 层级对象；外部依赖字段保持未绑定，后续由 configure/build/activate 明确注入。
  // 输入/输出及副作用：name（输入）；new 只写入构造体列出的默认字段并返回 void，外部依赖与资源所有权仍由上层管理。
  // 失败/边界：rdma_ceq_lifecycle_policy 构造只建立本地初始状态，不接管外部 Host-memory、PCIe 或 manager；未完成后续 configure/build/activate 时，业务入口必须返回 INVALID_STATE。
  function new(string name = "rdma_ceq_lifecycle_policy");
    super.new(name);
  endfunction

  // 功能：resource_kind 使用 当前对象字段 计算并返回 rdma_resource_kind_e 结果；不修改对象字段或外部资源。
  // 输入/输出及副作用：无显式参数；resource_kind 读取固定返回值或局部计算结果，不使用对象成员字段；函数返回 rdma_resource_kind_e，不取得调用方资源所有权。
  // 失败/边界：resource_kind 的结果直接由 return RDMA_RESOURCE_CEQ 计算；输入不满足表达式条件时沿函数体的保守分支返回，不修改已发布账本。
  virtual function rdma_resource_kind_e resource_kind();
    return RDMA_RESOURCE_CEQ;
  endfunction

  // 功能：在 rdma_ceq_lifecycle_policy 中，reserve_resource 检查容量后预留资源并返回带 owner 证据的句柄/计划；失败时回滚已登记的局部状态。
  // 输入/输出及副作用：manager（输入）、binding（输入）、request（输入）、resource（输出）；输入请求/句柄定义资源属性；成功时更新账本并通过返回值或 output 发布新句柄/映射。
  // 失败/边界：容量不足、范围非法、重复占用或身份过期时返回错误；失败不得泄漏半分配资源。
  virtual function rdma_status reserve_resource(
    rdma_resource_manager manager, rdma_function_binding binding,
    rdma_semantic_request request, output rdma_queue_resource resource);
    rdma_create_ceq_req ceq_request;
    rdma_ceq ceq;

    resource = null;
    if (manager == null || binding == null ||
        !$cast(ceq_request, request))
      return invalid_argument("CEQ reservation input is invalid");
    begin
      rdma_status status;
      status = manager.create_ceq(binding, ceq);
      if (status != null && status.ok())
        resource = ceq;
      return status;
    end
  endfunction

  // 功能：CEQ preflight 校验 CEQ depth、vector 绑定和环形 backing 需求，并将规范化结果写入 result。
  // 输入/输出及副作用：binding（输入）、request（输入）、manager（输入）、result（输出）；preflight 读取 binding、request、manager、result 并使用字段 result、status、found_vector、vector、candidate、candidate.resource_kind、candidate.depth、candidate.local_vector，并写入 result；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：必需对象/句柄/快照为空，或身份、范围、generation 和生命周期检查失败时返回非成功状态。
  virtual function rdma_status preflight(
    rdma_function_binding binding, rdma_semantic_request request,
    rdma_resource_manager manager, output rdma_queue_preflight result);
    rdma_create_ceq_req ceq_request;
    rdma_function_handle owner;
    rdma_queue_preflight candidate;
    rdma_queue_ring_layout ring;
    rdma_status status;
    bit found_vector;
    rdma_interrupt_vector_binding vector;

    result = null;
    if (!$cast(ceq_request, request))
      return invalid_argument("CEQ policy requires rdma_create_ceq_req");
    status = common_preflight_status(binding, ceq_request, manager, owner);
    if (!status.ok()) return status;
    if (ceq_request.depth > binding.queue_caps.max_ceq_depth)
      return invalid_argument("CEQ depth exceeds Function capability");
    found_vector = 1'b0;
    foreach (binding.interrupt_vectors[i]) begin
      if (binding.interrupt_vectors[i].function_local_vector ==
          ceq_request.vector_id) begin
        found_vector = 1'b1;
        vector = binding.interrupt_vectors[i];
      end
    end
    if (!found_vector)
      return invalid_argument("CEQ Function-local vector is not mapped");
    if (!vector.enabled)
      return invalid_state("CEQ interrupt vector is disabled");
    if (vector.hardware_eq_vector > 16'hffff)
      return invalid_argument("CEQ hardware vector exceeds 16 bits");
    if (ceq_request.ring_backing.mode == RDMA_QUEUE_BACKING_BORROWED) begin
      status = rdma_queue_borrowed_role_policy::validate_single_role(
        ceq_request.ring_backing, RDMA_QUEUE_ROLE_CEQ_RING,
        "CEQ borrowed backing has an invalid role",
        "CEQ borrowed backing omits CEQ_RING"
      );
      if (!status.ok()) return status;
    end
    status = checked_ring_layout("ceq_preflight_ring",
      RDMA_QUEUE_ROLE_CEQ_RING, ceq_request.depth, 16, 1'b1,
      binding.queue_caps.max_queue_ring_bytes, ring);
    if (!status.ok()) return status;
    candidate = rdma_queue_preflight::type_id::create("ceq_preflight");
    candidate.resource_kind = RDMA_RESOURCE_CEQ;
    candidate.depth = ceq_request.depth;
    candidate.local_vector = ceq_request.vector_id;
    candidate.hardware_vector = vector.hardware_eq_vector;
    candidate.msix_table_index = vector.msix_table_index;
    status = clone_backing_spec(ceq_request.ring_backing,
                                candidate.backing_spec);
    if (!status.ok()) return status;
    candidate.required_rings.push_back(ring);
    return publish_preflight(candidate, result);
  endfunction

  // 功能：build_create_context 创建独立的 rdma_status；根据 resource、plan、context_model、context_slot_image、context_shadow_image 设置字段 context_model、context_slot_image、context_shadow_image、status、candidate、candidate.ceq_h、candidate.state、candidate.depth、candidate.vector_id、producer.index，返回对象仅由调用方持有，不转移外部资源所有权。
  // 输入/输出及副作用：resource（输入）、plan（输入）、context_model（输出）、context_slot_image（输出）、context_shadow_image（输出）；输入字段被复制到返回值或
  //   output；生成结果与输入隔离，不隐式修改调用方对象。
  // 失败/边界：build_create_context 返回 函数体规定的失败状态；具体拒绝条件包括 “CEQ context builder requires rdma_ceq”；“CEQ context builder received the wrong plan”；“CEQ hardware vector exceeds 16 bits”；“CEQ resource and backing plan disagree”；失败路径不提交部分状态、不隐式重试，也不转移未声明资源。
  virtual function rdma_status build_create_context(
    rdma_queue_resource resource, rdma_queue_backing_plan plan,
    output rdma_hw_model context_model,
    output byte unsigned context_slot_image[],
    output byte unsigned context_shadow_image[]);
    rdma_ceq ceq;
    rdma_queue_ring_layout ring;
    rdma_queue_backing_ref pd_ref;
    rdma_backing_addr_t pd_address;
    rdma_handle ceq_h;
    rdma_ceqc_model candidate;
    byte unsigned slot_candidate[];
    rdma_status status;

    context_model = null;
    context_slot_image = new[0];
    context_shadow_image = new[0];
    if (!$cast(ceq, resource))
      return invalid_argument("CEQ context builder requires rdma_ceq");
    if (plan == null || plan.resource_kind != RDMA_RESOURCE_CEQ)
      return invalid_argument("CEQ context builder received the wrong plan");
    status = queue_resource_owner_status(ceq, RDMA_RESOURCE_CEQ);
    if (!status.ok()) return status;
    if (ceq.hardware_vector > 16'hffff)
      return invalid_argument("CEQ hardware vector exceeds 16 bits");
    status = projected_handle("ceqc_ceq", ceq.handle, RDMA_RESOURCE_CEQ,
                              ceq.local_ceq_id, 12, ceq_h);
    if (!status.ok()) return status;
    status = find_ring(plan, RDMA_QUEUE_ROLE_CEQ_RING, ring);
    if (!status.ok()) return status;
    status = find_backing_ref(plan, RDMA_QUEUE_ROLE_CEQ_PD, pd_ref);
    if (!status.ok()) return status;
    status = backing_owner_status(pd_ref, ceq.owner);
    if (!status.ok()) return status;
    status = backing_iova(pd_ref, pd_address);
    if (!status.ok()) return status;
    if (ring.depth != ceq.depth || ring.entry_size_bytes != 16)
      return invalid_state("CEQ resource and backing plan disagree");
    candidate = rdma_ceqc_model::type_id::create("canonical_ceqc");
    candidate.ceq_h = ceq_h;
    candidate.state = RDMA_CONTEXT_VALID;
    candidate.depth = ceq.depth;
    candidate.vector_id = ceq.hardware_vector;
    set_indirect_layout(candidate.page_layout, pd_address);
    candidate.producer.index = 0;
    candidate.producer.wrap = 1'b0;
    candidate.consumer.index = 0;
    candidate.consumer.wrap = 1'b0;
    status = encode_context(candidate, RDMA_IMAGE_CEQC, "ceqc",
                            RDMA_OP_CEQC_CREATE, slot_candidate);
    if (!status.ok()) return status;
    context_model = candidate;
    context_slot_image = slot_candidate;
    return rdma_status::success();
  endfunction

  // 功能：build_create_command 创建独立的 rdma_status；根据 owner、resource、context_model、timeout、command 设置字段 command、status，返回对象仅由调用方持有，不转移外部资源所有权。
  // 输入/输出及副作用：owner（输入）、resource（输入）、context_model（输入）、timeout（输入）、command（输出）；输入字段被复制到返回值或
  //   output；生成结果与输入隔离，不隐式修改调用方对象。
  // 失败/边界：build_create_command 返回 RDMA_SC_INVALID_ARGUMENT；典型拒绝条件为“CEQ create command requires CEQ/CEQC types”“CEQC model does not match CEQ local ID”；失败路径不提交部分状态或转移未声明资源。
  virtual function rdma_status build_create_command(
    rdma_function_handle owner, rdma_queue_resource resource,
    rdma_hw_model context_model, time timeout,
    output rdma_cmq_command_desc command);
    rdma_ceq ceq;
    rdma_ceqc_model ceqc;
    rdma_status status;
    command = null;
    if (!$cast(ceq, resource) || !$cast(ceqc, context_model))
      return invalid_argument("CEQ create command requires CEQ/CEQC types");
    if (ceqc.ceq_h == null || ceqc.ceq_h.object_id != ceq.local_ceq_id)
      return invalid_argument("CEQC model does not match CEQ local ID");
    status = command_owner_status(owner, ceq, ceqc.ceq_h,
                                  RDMA_RESOURCE_CEQ);
    if (!status.ok()) return status;
    return build_command_desc(owner, RDMA_OP_CEQC_CREATE, "create", ceqc,
                              timeout, command);
  endfunction

  // 功能：build_object_command 创建独立的 rdma_status；根据 opcode、owner、resource、timeout、command 设置字段 command、status，返回对象仅由调用方持有，不转移外部资源所有权。
  // 输入/输出及副作用：opcode（输入）、owner（输入）、resource（输入）、timeout（输入）、command（输出）；build_object_command 读取 opcode、owner、resource、timeout、command 并使用字段 command、status，并写入 command；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：build_object_command 返回 RDMA_SC_INVALID_ARGUMENT；典型拒绝条件为“CEQ object command requires rdma_ceq”；失败路径不提交部分状态或转移未声明资源。
  virtual function rdma_status build_object_command(
    bit [7:0] opcode, rdma_function_handle owner,
    rdma_queue_resource resource, time timeout,
    output rdma_cmq_command_desc command);
    rdma_ceq ceq;
    rdma_status status;
    command = null;
    if (!$cast(ceq, resource))
      return invalid_argument("CEQ object command requires rdma_ceq");
    status = command_resource_owner_status(owner, ceq, RDMA_RESOURCE_CEQ);
    if (!status.ok()) return status;
    return build_object_desc(opcode, RDMA_OP_CEQC_DELETE,
      RDMA_OP_CEQC_QUERY, owner, ceq.handle, RDMA_RESOURCE_CEQ,
      ceq.local_ceq_id, 12, timeout, command);
  endfunction

  // 功能：build_flush_command 创建独立的 rdma_status；根据 owner、target、timeout、command 设置字段 command，返回对象仅由调用方持有，不转移外部资源所有权。
  // 输入/输出及副作用：owner（输入）、target（输入）、timeout（输入）、command（输出）；build_flush_command 读取 owner、target、timeout、command 并使用字段 command，并写入 command；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：build_flush_command 的结果直接由 return unsupported("CEQ lifecycle has no OCC flush command") 计算；输入不满足表达式条件时沿函数体的保守分支返回，不修改已发布账本。
  virtual function rdma_status build_flush_command(
    rdma_function_handle owner, rdma_queue_flush_target target,
    time timeout, output rdma_cmq_command_desc command);
    command = null;
    return unsupported("CEQ lifecycle has no OCC flush command");
  endfunction

  // 功能：classify_query_completion 根据 resource、completion、presence、conclusive 执行 rdma_status 结果转换，具体更新字段 输出参数 presence、conclusive；失败分支保持已登记资源和输出不变，并将错误状态返回调用方。
  // 输入/输出及副作用：resource（输入）、completion（输入）、presence（输出）、conclusive（输出）；classify_query_completion 读取 resource、completion、presence、conclusive 并使用输入参数和固定枚举/常量，并写入 presence、conclusive；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：classify_query_completion 只读输入并返回 rdma_status；边界由函数体现有分支决定，不修改状态或转移资源。
  virtual function rdma_status classify_query_completion(
    rdma_queue_resource resource,
    rdma_cmq_completion completion,
    output rdma_hw_presence_e presence,
    output bit conclusive
  );
    return classify_query_common(resource, completion, RDMA_OP_CEQC_QUERY,
      RDMA_OP_CEQC_CREATE, RDMA_IMAGE_CEQC, "ceqc", 16, 32,
      RDMA_ECODE_EC_RCE_CEQC_INVLD, 1'b1, presence, conclusive);
  endfunction

  // 功能：在 rdma_ceq_lifecycle_policy 中，hardware_cleanup_roles 返回该资源策略要求的硬件 flush 与本地释放角色及其执行顺序。
  // 输入/输出及副作用：flush_roles（输出）、flush_phases（输出）、delete_before_flush（输出）；hardware_cleanup_roles 读取 flush_roles、flush_phases、delete_before_flush 并使用字段 delete_before_flush，并写入 flush_roles、flush_phases、delete_before_flush；函数返回 void，不取得调用方资源所有权。
  // 失败/边界：hardware_cleanup_roles 无返回值，仅执行 delete_before_flush=1'b1；调用方须保证前置依赖已经绑定，函数不自动重试或接管外部资源。
  virtual function void hardware_cleanup_roles(
    output rdma_queue_backing_role_e flush_roles[$],
    output rdma_queue_flush_phase_e flush_phases[$],
    output bit delete_before_flush
  );
    flush_roles.delete();
    flush_phases.delete();
    delete_before_flush = 1'b1;
  endfunction

  // 功能：在 rdma_ceq_lifecycle_policy 中，local_cleanup_roles 返回该资源策略要求的硬件 flush 与本地释放角色及其执行顺序。
  // 输入/输出及副作用：roles（输出）、release_context_first（输出）；local_cleanup_roles 读取 roles、release_context_first 并使用字段 release_context_first，并写入 roles、release_context_first；函数返回 void，不取得调用方资源所有权。
  // 失败/边界：local_cleanup_roles 无返回值，仅执行 release_context_first=1'b0；调用方须保证前置依赖已经绑定，函数不自动重试或接管外部资源。
  virtual function void local_cleanup_roles(
    output rdma_queue_backing_role_e roles[$],
    output bit release_context_first
  );
    roles.delete();
    release_context_first = 1'b0;
    roles.push_back(RDMA_QUEUE_ROLE_CEQ_PD);
    roles.push_back(RDMA_QUEUE_ROLE_CEQ_RING);
  endfunction
endclass

class rdma_aeq_lifecycle_policy extends rdma_queue_lifecycle_policy;
  `uvm_object_utils(rdma_aeq_lifecycle_policy)

  // 功能：构造 rdma_aeq_lifecycle_policy，调用 super.new 建立 UVM 层级对象；外部依赖字段保持未绑定，后续由 configure/build/activate 明确注入。
  // 输入/输出及副作用：name（输入）；new 只写入构造体列出的默认字段并返回 void，外部依赖与资源所有权仍由上层管理。
  // 失败/边界：rdma_aeq_lifecycle_policy 构造只建立本地初始状态，不接管外部 Host-memory、PCIe 或 manager；未完成后续 configure/build/activate 时，业务入口必须返回 INVALID_STATE。
  function new(string name = "rdma_aeq_lifecycle_policy");
    super.new(name);
  endfunction

  // 功能：resource_kind 使用 当前对象字段 计算并返回 rdma_resource_kind_e 结果；不修改对象字段或外部资源。
  // 输入/输出及副作用：无显式参数；resource_kind 读取固定返回值或局部计算结果，不使用对象成员字段；函数返回 rdma_resource_kind_e，不取得调用方资源所有权。
  // 失败/边界：resource_kind 的结果直接由 return RDMA_RESOURCE_AEQ 计算；输入不满足表达式条件时沿函数体的保守分支返回，不修改已发布账本。
  virtual function rdma_resource_kind_e resource_kind();
    return RDMA_RESOURCE_AEQ;
  endfunction

  // 功能：在 rdma_aeq_lifecycle_policy 中，reserve_resource 检查容量后预留资源并返回带 owner 证据的句柄/计划；失败时回滚已登记的局部状态。
  // 输入/输出及副作用：manager（输入）、binding（输入）、request（输入）、resource（输出）；输入请求/句柄定义资源属性；成功时更新账本并通过返回值或 output 发布新句柄/映射。
  // 失败/边界：容量不足、范围非法、重复占用或身份过期时返回错误；失败不得泄漏半分配资源。
  virtual function rdma_status reserve_resource(
    rdma_resource_manager manager, rdma_function_binding binding,
    rdma_semantic_request request, output rdma_queue_resource resource);
    rdma_create_aeq_req aeq_request;
    rdma_aeq aeq;

    resource = null;
    if (manager == null || binding == null ||
        !$cast(aeq_request, request))
      return invalid_argument("AEQ reservation input is invalid");
    begin
      rdma_status status;
      status = manager.create_aeq(binding, aeq);
      if (status != null && status.ok())
        resource = aeq;
      return status;
    end
  endfunction

  // 功能：AEQ preflight 校验 AEQ depth、vector 绑定和环形 backing 需求，并将规范化结果写入 result。
  // 输入/输出及副作用：binding（输入）、request（输入）、manager（输入）、result（输出）；preflight 读取 binding、request、manager、result 并使用字段 result、status、found_vector、vector、candidate、candidate.resource_kind、candidate.depth、candidate.local_vector，并写入 result；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：必需对象/句柄/快照为空，或身份、范围、generation 和生命周期检查失败时返回非成功状态。
  virtual function rdma_status preflight(
    rdma_function_binding binding, rdma_semantic_request request,
    rdma_resource_manager manager, output rdma_queue_preflight result);
    rdma_create_aeq_req aeq_request;
    rdma_function_handle owner;
    rdma_queue_preflight candidate;
    rdma_queue_ring_layout ring;
    rdma_status status;
    bit found_vector;
    rdma_interrupt_vector_binding vector;

    result = null;
    if (!$cast(aeq_request, request))
      return invalid_argument("AEQ policy requires rdma_create_aeq_req");
    status = common_preflight_status(binding, aeq_request, manager, owner);
    if (!status.ok()) return status;
    if (aeq_request.depth > binding.queue_caps.max_aeq_depth)
      return invalid_argument("AEQ depth exceeds Function capability");
    found_vector = 1'b0;
    foreach (binding.interrupt_vectors[i]) begin
      if (binding.interrupt_vectors[i].function_local_vector ==
          aeq_request.vector_id) begin
        found_vector = 1'b1;
        vector = binding.interrupt_vectors[i];
      end
    end
    if (!found_vector)
      return invalid_argument("AEQ Function-local vector is not mapped");
    if (!vector.enabled)
      return invalid_state("AEQ interrupt vector is disabled");
    if (vector.hardware_eq_vector > 16'hffff)
      return invalid_argument("AEQ hardware vector exceeds 16 bits");
    if (aeq_request.ring_backing.mode == RDMA_QUEUE_BACKING_BORROWED) begin
      status = rdma_queue_borrowed_role_policy::validate_single_role(
        aeq_request.ring_backing, RDMA_QUEUE_ROLE_AEQ_RING,
        "AEQ borrowed backing has an invalid role",
        "AEQ borrowed backing omits AEQ_RING"
      );
      if (!status.ok()) return status;
    end
    status = checked_ring_layout("aeq_preflight_ring",
      RDMA_QUEUE_ROLE_AEQ_RING, aeq_request.depth, 16, 1'b1,
      binding.queue_caps.max_queue_ring_bytes, ring);
    if (!status.ok()) return status;
    candidate = rdma_queue_preflight::type_id::create("aeq_preflight");
    candidate.resource_kind = RDMA_RESOURCE_AEQ;
    candidate.depth = aeq_request.depth;
    candidate.local_vector = aeq_request.vector_id;
    candidate.hardware_vector = vector.hardware_eq_vector;
    candidate.msix_table_index = vector.msix_table_index;
    status = clone_backing_spec(aeq_request.ring_backing,
                                candidate.backing_spec);
    if (!status.ok()) return status;
    candidate.required_rings.push_back(ring);
    return publish_preflight(candidate, result);
  endfunction

  // 功能：build_create_context 创建独立的 rdma_status；根据 resource、plan、context_model、context_slot_image、context_shadow_image 设置字段 context_model、context_slot_image、context_shadow_image、status、candidate、candidate.aeq_h、candidate.state、candidate.depth、candidate.vector_id、producer.index，返回对象仅由调用方持有，不转移外部资源所有权。
  // 输入/输出及副作用：resource（输入）、plan（输入）、context_model（输出）、context_slot_image（输出）、context_shadow_image（输出）；输入字段被复制到返回值或
  //   output；生成结果与输入隔离，不隐式修改调用方对象。
  // 失败/边界：build_create_context 返回 函数体规定的失败状态；具体拒绝条件包括 “AEQ context builder requires rdma_aeq”；“AEQ context builder received the wrong plan”；“AEQ hardware vector exceeds 16 bits”；“AEQ resource and backing plan disagree”；失败路径不提交部分状态、不隐式重试，也不转移未声明资源。
  virtual function rdma_status build_create_context(
    rdma_queue_resource resource, rdma_queue_backing_plan plan,
    output rdma_hw_model context_model,
    output byte unsigned context_slot_image[],
    output byte unsigned context_shadow_image[]);
    rdma_aeq aeq;
    rdma_queue_ring_layout ring;
    rdma_queue_backing_ref pd_ref;
    rdma_backing_addr_t pd_address;
    rdma_handle aeq_h;
    rdma_aeqc_model candidate;
    byte unsigned slot_candidate[];
    rdma_status status;

    context_model = null;
    context_slot_image = new[0];
    context_shadow_image = new[0];
    if (!$cast(aeq, resource))
      return invalid_argument("AEQ context builder requires rdma_aeq");
    if (plan == null || plan.resource_kind != RDMA_RESOURCE_AEQ)
      return invalid_argument("AEQ context builder received the wrong plan");
    status = queue_resource_owner_status(aeq, RDMA_RESOURCE_AEQ);
    if (!status.ok()) return status;
    if (aeq.hardware_vector > 16'hffff)
      return invalid_argument("AEQ hardware vector exceeds 16 bits");
    status = projected_handle("aeqc_aeq", aeq.handle, RDMA_RESOURCE_AEQ,
                              aeq.local_aeq_id, 12, aeq_h);
    if (!status.ok()) return status;
    status = find_ring(plan, RDMA_QUEUE_ROLE_AEQ_RING, ring);
    if (!status.ok()) return status;
    status = find_backing_ref(plan, RDMA_QUEUE_ROLE_AEQ_PD, pd_ref);
    if (!status.ok()) return status;
    status = backing_owner_status(pd_ref, aeq.owner);
    if (!status.ok()) return status;
    status = backing_iova(pd_ref, pd_address);
    if (!status.ok()) return status;
    if (ring.depth != aeq.depth || ring.entry_size_bytes != 16)
      return invalid_state("AEQ resource and backing plan disagree");
    candidate = rdma_aeqc_model::type_id::create("canonical_aeqc");
    candidate.aeq_h = aeq_h;
    candidate.state = RDMA_CONTEXT_VALID;
    candidate.depth = aeq.depth;
    candidate.vector_id = aeq.hardware_vector;
    set_indirect_layout(candidate.page_layout, pd_address);
    candidate.producer.index = 0;
    candidate.producer.wrap = 1'b0;
    candidate.consumer.index = 0;
    candidate.consumer.wrap = 1'b0;
    status = encode_context(candidate, RDMA_IMAGE_AEQC, "aeqc",
                            RDMA_OP_AEQC_CREATE, slot_candidate);
    if (!status.ok()) return status;
    context_model = candidate;
    context_slot_image = slot_candidate;
    return rdma_status::success();
  endfunction

  // 功能：build_create_command 创建独立的 rdma_status；根据 owner、resource、context_model、timeout、command 设置字段 command、status，返回对象仅由调用方持有，不转移外部资源所有权。
  // 输入/输出及副作用：owner（输入）、resource（输入）、context_model（输入）、timeout（输入）、command（输出）；输入字段被复制到返回值或
  //   output；生成结果与输入隔离，不隐式修改调用方对象。
  // 失败/边界：build_create_command 返回 RDMA_SC_INVALID_ARGUMENT；典型拒绝条件为“AEQ create command requires AEQ/AEQC types”“AEQC model does not match AEQ local ID”；失败路径不提交部分状态或转移未声明资源。
  virtual function rdma_status build_create_command(
    rdma_function_handle owner, rdma_queue_resource resource,
    rdma_hw_model context_model, time timeout,
    output rdma_cmq_command_desc command);
    rdma_aeq aeq;
    rdma_aeqc_model aeqc;
    rdma_status status;
    command = null;
    if (!$cast(aeq, resource) || !$cast(aeqc, context_model))
      return invalid_argument("AEQ create command requires AEQ/AEQC types");
    if (aeqc.aeq_h == null || aeqc.aeq_h.object_id != aeq.local_aeq_id)
      return invalid_argument("AEQC model does not match AEQ local ID");
    status = command_owner_status(owner, aeq, aeqc.aeq_h,
                                  RDMA_RESOURCE_AEQ);
    if (!status.ok()) return status;
    return build_command_desc(owner, RDMA_OP_AEQC_CREATE, "create", aeqc,
                              timeout, command);
  endfunction

  // 功能：build_object_command 创建独立的 rdma_status；根据 opcode、owner、resource、timeout、command 设置字段 command、status，返回对象仅由调用方持有，不转移外部资源所有权。
  // 输入/输出及副作用：opcode（输入）、owner（输入）、resource（输入）、timeout（输入）、command（输出）；build_object_command 读取 opcode、owner、resource、timeout、command 并使用字段 command、status，并写入 command；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：build_object_command 返回 RDMA_SC_INVALID_ARGUMENT；典型拒绝条件为“AEQ object command requires rdma_aeq”；失败路径不提交部分状态或转移未声明资源。
  virtual function rdma_status build_object_command(
    bit [7:0] opcode, rdma_function_handle owner,
    rdma_queue_resource resource, time timeout,
    output rdma_cmq_command_desc command);
    rdma_aeq aeq;
    rdma_status status;
    command = null;
    if (!$cast(aeq, resource))
      return invalid_argument("AEQ object command requires rdma_aeq");
    status = command_resource_owner_status(owner, aeq, RDMA_RESOURCE_AEQ);
    if (!status.ok()) return status;
    return build_object_desc(opcode, RDMA_OP_AEQC_DELETE,
      RDMA_OP_AEQC_QUERY, owner, aeq.handle, RDMA_RESOURCE_AEQ,
      aeq.local_aeq_id, 12, timeout, command);
  endfunction

  // 功能：build_flush_command 创建独立的 rdma_status；根据 owner、target、timeout、command 设置字段 command，返回对象仅由调用方持有，不转移外部资源所有权。
  // 输入/输出及副作用：owner（输入）、target（输入）、timeout（输入）、command（输出）；build_flush_command 读取 owner、target、timeout、command 并使用字段 command，并写入 command；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：build_flush_command 的结果直接由 return unsupported("AEQ lifecycle has no OCC flush command") 计算；输入不满足表达式条件时沿函数体的保守分支返回，不修改已发布账本。
  virtual function rdma_status build_flush_command(
    rdma_function_handle owner, rdma_queue_flush_target target,
    time timeout, output rdma_cmq_command_desc command);
    command = null;
    return unsupported("AEQ lifecycle has no OCC flush command");
  endfunction

  // 功能：classify_query_completion 根据 resource、completion、presence、conclusive 执行 rdma_status 结果转换，具体更新字段 输出参数 presence、conclusive；失败分支保持已登记资源和输出不变，并将错误状态返回调用方。
  // 输入/输出及副作用：resource（输入）、completion（输入）、presence（输出）、conclusive（输出）；classify_query_completion 读取 resource、completion、presence、conclusive 并使用输入参数和固定枚举/常量，并写入 presence、conclusive；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：classify_query_completion 只读输入并返回 rdma_status；边界由函数体现有分支决定，不修改状态或转移资源。
  virtual function rdma_status classify_query_completion(
    rdma_queue_resource resource,
    rdma_cmq_completion completion,
    output rdma_hw_presence_e presence,
    output bit conclusive
  );
    return classify_query_common(resource, completion, RDMA_OP_AEQC_QUERY,
      RDMA_OP_AEQC_CREATE, RDMA_IMAGE_AEQC, "aeqc", 16, 32,
      RDMA_ECODE_EC_RCE_AEQC_INVLD, 1'b1, presence, conclusive);
  endfunction

  // 功能：在 rdma_aeq_lifecycle_policy 中，hardware_cleanup_roles 返回该资源策略要求的硬件 flush 与本地释放角色及其执行顺序。
  // 输入/输出及副作用：flush_roles（输出）、flush_phases（输出）、delete_before_flush（输出）；hardware_cleanup_roles 读取 flush_roles、flush_phases、delete_before_flush 并使用字段 delete_before_flush，并写入 flush_roles、flush_phases、delete_before_flush；函数返回 void，不取得调用方资源所有权。
  // 失败/边界：hardware_cleanup_roles 无返回值，仅执行 delete_before_flush=1'b1；调用方须保证前置依赖已经绑定，函数不自动重试或接管外部资源。
  virtual function void hardware_cleanup_roles(
    output rdma_queue_backing_role_e flush_roles[$],
    output rdma_queue_flush_phase_e flush_phases[$],
    output bit delete_before_flush
  );
    flush_roles.delete();
    flush_phases.delete();
    delete_before_flush = 1'b1;
  endfunction

  // 功能：在 rdma_aeq_lifecycle_policy 中，local_cleanup_roles 返回该资源策略要求的硬件 flush 与本地释放角色及其执行顺序。
  // 输入/输出及副作用：roles（输出）、release_context_first（输出）；local_cleanup_roles 读取 roles、release_context_first 并使用字段 release_context_first，并写入 roles、release_context_first；函数返回 void，不取得调用方资源所有权。
  // 失败/边界：local_cleanup_roles 无返回值，仅执行 release_context_first=1'b0；调用方须保证前置依赖已经绑定，函数不自动重试或接管外部资源。
  virtual function void local_cleanup_roles(
    output rdma_queue_backing_role_e roles[$],
    output bit release_context_first
  );
    roles.delete();
    release_context_first = 1'b0;
    roles.push_back(RDMA_QUEUE_ROLE_AEQ_PD);
    roles.push_back(RDMA_QUEUE_ROLE_AEQ_RING);
  endfunction
endclass
