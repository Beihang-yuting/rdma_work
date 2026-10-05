// 目录：核心执行层 core/rdma_qp_lifecycle_executor.sv。
// 职责：实现 rdma_qp_lifecycle_executor 在本层的职责和对外接口。
// 依赖：依赖本层公共 types/model/adapter 契约及其上游快照。
// 所有权与生命周期：对象只拥有显式创建的值快照；外部资源保存非拥有引用，生命周期由调用方管理。

// 中文说明：rdma_qp_lifecycle_executor.sv 属于核心执行层，负责队列、控制面、资源和恢复流程。
// 阅读提示：先看公开类型和接口，再看实现细节；失败路径应保持状态与资源所有权可追踪。

class rdma_qp_lifecycle_executor extends uvm_object;
  // 生命周期执行器统一负责 QP backing 的分配、发布、恢复和最终清理。
  `uvm_object_utils(rdma_qp_lifecycle_executor)

  protected rdma_resource_manager manager;
  protected rdma_cmq_port cmq;
  protected rdma_host_mem_api host_mem;
  protected rdma_context_backing_api context_backing;
  protected time command_timeout;
  protected rdma_hw_queue_pd_codec pd_codec;
  protected rdma_codec_registry qpc_codecs;

  // 功能：构造 rdma_qp_lifecycle_executor，调用 super.new 建立 UVM 对象，并把构造体直接写入的默认值设为：manager=null；cmq=null；host_mem=null；context_backing=null；command_timeout=0；pd_codec=rdma_hw_queue_pd_codec::type_id::create({name, "_pd"})；qpc_codecs=rdma_codec_registry::type_id::create({name, "_qpc"})。
  // 输入/输出及副作用：name（输入）；new 只写入构造体列出的默认字段并返回 void，外部依赖与资源所有权仍由上层管理。
  // 失败/边界：rdma_qp_lifecycle_executor 构造只建立本地初始状态，不接管外部 Host-memory、PCIe 或 manager；未完成后续 configure/build/activate 时，业务入口必须返回 INVALID_STATE。
  function new(string name = "rdma_qp_lifecycle_executor");
    super.new(name);
    manager = null;
    cmq = null;
    host_mem = null;
    context_backing = null;
    command_timeout = 0;
    pd_codec = rdma_hw_queue_pd_codec::type_id::create({name, "_pd"});
    qpc_codecs = rdma_codec_registry::type_id::create({name, "_qpc"});
  endfunction

  // 功能：在 rdma_qp_lifecycle_executor 中，invalid_argument 把错误消息、硬件码或注入故障封装为统一 rdma_status，保留原事务的诊断证据。
  // 输入/输出及副作用：message（输入）；invalid_argument 读取 message 并使用字段 rdma_status；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：invalid_argument 返回 RDMA_SC_INVALID_ARGUMENT；失败路径不提交部分状态或转移未声明资源。
  protected function rdma_status invalid_argument(string message);
    return rdma_status::make(RDMA_SC_INVALID_ARGUMENT, message);
  endfunction

  // 功能：在 rdma_qp_lifecycle_executor 中，invalid_state 把错误消息、硬件码或注入故障封装为统一 rdma_status，保留原事务的诊断证据。
  // 输入/输出及副作用：message（输入）；invalid_state 读取 message 并使用字段 rdma_status；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：invalid_state 返回 RDMA_SC_INVALID_STATE；失败路径不提交部分状态或转移未声明资源。
  protected function rdma_status invalid_state(string message);
    return rdma_status::make(RDMA_SC_INVALID_STATE, message);
  endfunction

  // 功能：在 rdma_qp_lifecycle_executor 中由 same_owner 逐字段比较输入值，返回结构、身份或序列化内容是否一致。
  // 输入/输出及副作用：lhs（输入）、rhs（输入）；比较对象/数组只读；返回 bit 或状态结果，不更新 runtime、账本或外部 adapter。
  // 失败/边界：same_owner 的任一比较对象为空或类型不符时返回确定的 false/不等结果，不抛出未处理异常。
  protected function bit same_owner(rdma_function_handle lhs,
                                    rdma_function_handle rhs);
    return lhs != null && rhs != null && lhs.same_instance(rhs);
  endfunction

  // 功能：在 rdma_qp_lifecycle_executor 中，normalize_status 把错误消息、硬件码或注入故障封装为统一 rdma_status，保留原事务的诊断证据。
  // 输入/输出及副作用：status（输入）、message（输入）；normalize_status 读取 status、message 并使用输入参数和固定枚举/常量；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：normalize_status 的结果直接由 return status == null ? invalid_state(message) : status 计算；输入不满足表达式条件时沿函数体的保守分支返回，不修改已发布账本。
  protected function rdma_status normalize_status(rdma_status status,
                                                   string message);
    return status == null ? invalid_state(message) : status;
  endfunction

  // 功能：make_result 使用公共 lifecycle result seed 建立 QP 操作的 detached 初始
  //   结果，统一 transaction id、未完成 status 和默认资源状态，供 create/modify/
  //   destroy/recover 四类入口继续追加各自业务字段。
  // 输入/输出及副作用：transaction_id、result_name、pending_message（输入）；返回
  //   新建的 rdma_control_result，写入 status、primary_status 和默认状态字段；不
  //   取得 manager、CMQ、QP backing 或 recovery ledger 所有权。
  // 失败/边界：seed 或 result 分配/初始化失败时返回带 INVALID_STATE 的结果对象；
  //   transaction_id 为 0 仍由各入口按原有顺序拒绝，本 helper 不提前改变错误优先级。
  protected function rdma_control_result make_result(
    longint unsigned transaction_id,
    string result_name,
    string pending_message
  );
    rdma_control_result result;
    rdma_lifecycle_result_seed seed;
    rdma_status seed_status;

    result = rdma_control_result::type_id::create(result_name);
    seed = rdma_lifecycle_result_seed::type_id::create(
      {result_name, "_seed"}
    );
    if (result == null || seed == null) begin
      if (result == null)
        return null;
      result.transaction_id = transaction_id;
      result.primary_status = invalid_state(
        "QP lifecycle result seed allocation failed"
      );
      result.status = rdma_cmq_clone_status_value(result.primary_status);
      return result;
    end
    seed.transaction_id = transaction_id;
    seed.domain = RDMA_LIFECYCLE_DOMAIN_QP;
    seed.pending_message = pending_message;
    seed_status = seed.initialize_result(result);
    if (seed_status == null || !seed_status.ok()) begin
      result.transaction_id = transaction_id;
      result.primary_status = invalid_state(
        "QP lifecycle result seed initialization failed"
      );
      result.status = rdma_cmq_clone_status_value(result.primary_status);
      result.final_resource_state = RDMA_RESOURCE_NEW;
      result.final_resource_state_known = 1'b0;
      result.recovery_required = 1'b0;
    end
    return result;
  endfunction

  // 功能：在 rdma_qp_lifecycle_executor 中，live_binding_fence 读取并校验 Function generation/reset epoch，拒绝旧 binding 或跨 Function 请求。
  // 输入/输出及副作用：binding（输入）、expected_owner（输入）；live_binding_fence 读取 binding、expected_owner 并使用字段 status；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：live_binding_fence 返回 RDMA_SC_STALE_GENERATION、RDMA_SC_INVALID_ARGUMENT；典型拒绝条件为“QP binding fence input is null”“QP binding generation is stale”；失败路径不提交部分状态或转移未声明资源。
  protected function rdma_status live_binding_fence(
    rdma_function_binding binding, rdma_function_handle expected_owner
  );
    rdma_status status;
    if (binding == null || expected_owner == null)
      return invalid_argument("QP binding fence input is null");
    status = normalize_status(binding.validate(), "QP binding fence returned null");
    if (!status.ok()) return status;
    if (binding.state != RDMA_BIND_ACTIVE ||
        !binding.make_handle().same_instance(expected_owner))
      return rdma_status::make(RDMA_SC_STALE_GENERATION,
                               "QP binding generation is stale");
    return rdma_status::success();
  endfunction

  // 功能：在 rdma_qp_lifecycle_executor 中，configure 校验依赖和 binding 后建立运行边界，只保存非拥有引用并拒绝重复配置。
  // 输入/输出及副作用：manager（输入）、cmq（输入）、host_mem（输入）、context_backing（输入）、command_timeout（输入）；configure 先依据 manager == null || cmq == null || host_mem == null || context_backing == null || command_timeout == 0；pd_codec == null || qpc_codecs == null；status == null || !status.ok( 校验 manager、cmq、host_mem、context_backing、command_timeout；成功时更新本对象配置/状态并保存非拥有引用，返回
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

    if (manager == null || cmq == null || host_mem == null ||
        context_backing == null || command_timeout == 0)
      return invalid_argument("QP executor configuration is incomplete");
    if (pd_codec == null || qpc_codecs == null)
      return invalid_state("QP executor codec construction failed");
    qpc_codecs.clear();
    status = rdma_register_qpc_codecs(qpc_codecs);
    if (status == null || !status.ok())
      return normalize_status(status, "QP codec registration returned null");
    this.manager = manager;
    this.cmq = cmq;
    this.host_mem = host_mem;
    this.context_backing = context_backing;
    this.command_timeout = command_timeout;
    return rdma_status::success();
  endfunction

  // 功能：make_dma_context 创建独立的 rdma_status；根据 binding、qp_h、role、request_context 设置字段 request_context、request_context.function_h、request_context.requester_bdf、request_context.pasid_valid、request_context.pasid、request_context.dma_domain_valid、request_context.dma_domain_id、request_context.route、request_context.reset_epoch、request_context.owner_h、request_context.queue_role_valid、request_context.queue_role，返回对象仅由调用方持有，不转移外部资源所有权。
  // 输入/输出及副作用：binding（输入）、qp_h（输入）、role（输入）、request_context（输出）；make_dma_context 读取 binding、qp_h、role、request_context 并使用字段 request_context、request_context.function_h、request_context.requester_bdf、request_context.pasid_valid、request_context.pasid、request_context.dma_domain_valid、request_context.dma_domain_id、request_context.owner_h，并写入 request_context；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：make_dma_context 返回 RDMA_SC_RESOURCE_EXHAUSTED、RDMA_SC_INVALID_ARGUMENT；典型拒绝条件为“QP DMA context input is null”“QP DMA context allocation failed”；失败路径不提交部分状态或转移未声明资源。
  protected function rdma_status make_dma_context(
    rdma_function_binding binding,
    rdma_handle qp_h,
    rdma_queue_backing_role_e role,
    output rdma_dma_request_context request_context
  );
    rdma_function_identity identity;

    request_context = null;
    if (binding == null || qp_h == null)
      return invalid_argument("QP DMA context input is null");
    request_context = rdma_dma_request_context::type_id::create(
      "qp_backing_request_context"
    );
    if (request_context == null)
      return rdma_status::make(RDMA_SC_RESOURCE_EXHAUSTED,
                               "QP DMA context allocation failed");
    request_context.function_h = binding.make_handle();
    if (request_context.function_h == null)
      return invalid_state("QP DMA Function handle construction failed");
    identity = binding.function_identity_snapshot();
    if (identity == null)
      return invalid_state("QP DMA Function identity snapshot failed");
    request_context.requester_bdf = binding.queue_dma.requester_bdf;
    request_context.pasid_valid = binding.queue_dma.pasid_valid;
    request_context.pasid = binding.queue_dma.pasid;
    request_context.dma_domain_valid = binding.queue_dma.dma_domain_valid;
    request_context.dma_domain_id = binding.queue_dma.dma_domain_id;
    // Host-memory router 校验 route/epoch；这些字段必须来自同一份
    // Function identity 快照，不能使用默认 route 或隐式 root0。
    request_context.route = identity.route_key();
    request_context.route_valid = 1'b1;
    request_context.reset_epoch = identity.reset_epoch;
    request_context.epoch_valid = 1'b1;
    request_context.owner_h = rdma_clone_handle_value(qp_h, "QP DMA owner");
    request_context.queue_role_valid = 1'b1;
    request_context.queue_role = int'(role);
    return normalize_status(request_context.validate(),
                            "QP DMA context validation returned null");
  endfunction

  // 功能：执行 retain_failed_allocation 指定的测试或恢复状态变更，更新受控账本并保留可回滚的故障证据。
  // 输入/输出及副作用：mapping（输入）、role（输入）、length（输入）、backing_ref（输出）；retain_failed_allocation 读取 mapping、role、length、backing_ref 并使用字段 backing_ref、backing_ref.role、backing_ref.mapping、backing_ref.ownership、backing_ref.mapping_offset、backing_ref.length、backing_ref.recovery_only，并写入 backing_ref；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：retain_failed_allocation 仅允许测试/恢复范围内的状态变更；代际或资源不匹配时拒绝并保留原账本。
  protected function rdma_status retain_failed_allocation(
    rdma_dma_mapping mapping,
    rdma_queue_backing_role_e role,
    longint unsigned length,
    output rdma_qp_backing_ref backing_ref
  );
    backing_ref = null;
    if (mapping == null)
      return rdma_status::success();
    backing_ref = rdma_qp_backing_ref::type_id::create(
      $sformatf("qp_failed_ref_%0d", role));
    if (backing_ref == null)
      return rdma_status::make(RDMA_SC_RESOURCE_EXHAUSTED,
                               "QP failed-allocation reference failed");
    backing_ref.role = role;
    backing_ref.mapping = mapping;
    backing_ref.ownership = RDMA_OWNERSHIP_CONTROL_PLANE;
    backing_ref.mapping_offset = 0;
    backing_ref.length = length;
    // 失败分配仍可能携带释放能力，因此转为 recovery-only authority 保存。
    // This capability is intentionally recovery-only.  The adapter's
    // non-null mapping remains the opaque release/query authority even when
    // its public geometry or authority snapshot hooks are malformed.  Strict
    // QP ring validation is deferred to normal plan publication and therefore
    // cannot be weakened by this path.
    backing_ref.recovery_only = 1'b1;
    return rdma_status::success();
  endfunction

  // 功能：在 rdma_qp_lifecycle_executor 中，allocate_ref_aligned 检查容量后预留资源并返回带 owner 证据的句柄/计划；失败时回滚已登记的局部状态。
  // 输入/输出及副作用：binding（输入）、expected_owner（输入）、qp_h（输入）、role（输入）、length（输入）、direction（输入）、alignment（输入）、backing_ref（输出）；输入请求/句柄定义资源属性；成功时更新账本并通过返回值或
  //   output 发布新句柄/映射。
  // 失败/边界：容量不足、范围非法、重复占用或身份过期时返回错误；失败不得泄漏半分配资源。
  protected function rdma_status allocate_ref_aligned(
    rdma_function_binding binding,
    rdma_function_handle expected_owner,
    rdma_handle qp_h,
    rdma_queue_backing_role_e role,
    longint unsigned length,
    rdma_dma_direction_e direction,
    int unsigned alignment,
    output rdma_qp_backing_ref backing_ref
  );
    rdma_dma_request_context request_context;
    rdma_dma_mapping mapping;
    rdma_dma_mapping authority;
    rdma_status status;
    rdma_status fence_status;

    backing_ref = null;
    if (length == 0 || length > 32'hffff_ffff || host_mem == null)
      return invalid_argument("QP backing allocation geometry is invalid");
    status = make_dma_context(binding, qp_h, role, request_context);
    if (!status.ok()) return status;
    mapping = null;
    status = live_binding_fence(binding, expected_owner);
    if (!status.ok()) return status;
    status = normalize_status(host_mem.allocate(request_context, int'(length),
      alignment, direction, mapping), "QP backing allocation returned null");
    fence_status = live_binding_fence(binding, expected_owner);
    if (!fence_status.ok()) begin
      if (mapping != null) begin
        rdma_status retain_status;
        retain_status = retain_failed_allocation(mapping, role, length,
                                                  backing_ref);
        if (!retain_status.ok()) return retain_status;
      end
      return fence_status;
    end
    if (!status.ok()) begin
      if (mapping != null) begin
        rdma_status retain_status;
        retain_status = retain_failed_allocation(mapping, role, length,
                                                  backing_ref);
        if (!retain_status.ok()) return retain_status;
      end
      return status;
    end
    if (mapping == null || mapping.size < length ||
        (mapping.iova.value % alignment) != 0 ||
        (mapping.backing_addr.value % alignment) != 0) begin
      status = retain_failed_allocation(mapping, role, length, backing_ref);
      if (!status.ok()) return status;
      return invalid_state("QP backing allocation geometry is invalid");
    end
    status = normalize_status(mapping.snapshot_release_authority(authority),
                              "QP backing authority snapshot returned null");
    if (!status.ok() || authority == null) begin
      rdma_status retain_status;
      // An OK status with a null snapshot is itself a malformed authority
      // hook result.  Keep the original non-null mapping recoverable before
      // reporting that malformed result, just as for an explicit hook error.
      retain_status = retain_failed_allocation(mapping, role, length,
                                                backing_ref);
      if (!retain_status.ok()) return retain_status;
      return !status.ok() ? status :
        invalid_state("QP backing authority snapshot is null");
    end
    status = normalize_status(mapping.release_authority_status(authority),
      "QP backing authority equivalence returned null");
    if (!status.ok()) begin
      rdma_status retain_status;
      retain_status = retain_failed_allocation(mapping, role, length,
                                                backing_ref);
      if (!retain_status.ok()) return retain_status;
      return status;
    end
    authority.copy(mapping);
    status = normalize_status(mapping.release_authority_status(authority),
      "QP copied backing authority equivalence returned null");
    if (!status.ok()) begin
      rdma_status retain_status;
      retain_status = retain_failed_allocation(mapping, role, length,
                                                backing_ref);
      if (!retain_status.ok()) return retain_status;
      return status;
    end
    backing_ref = rdma_qp_backing_ref::type_id::create(
      $sformatf("qp_ref_%0d", role)
    );
    if (backing_ref == null) begin
      rdma_status retain_status;
      retain_status = retain_failed_allocation(mapping, role, length,
                                                backing_ref);
      if (!retain_status.ok()) return retain_status;
      return rdma_status::make(RDMA_SC_RESOURCE_EXHAUSTED,
                               "QP backing reference allocation failed");
    end
    backing_ref.role = role;
    backing_ref.mapping = authority;
    backing_ref.ownership = RDMA_OWNERSHIP_CONTROL_PLANE;
    backing_ref.mapping_offset = 0;
    backing_ref.length = length;
    status = backing_ref.validate();
    if (!status.ok()) begin
      rdma_status retain_status;
      retain_status = retain_failed_allocation(mapping, role, length,
                                                backing_ref);
      if (!retain_status.ok()) return retain_status;
    end
    return status;
  endfunction

  // 功能：在 rdma_qp_lifecycle_executor 中，allocate_ref 检查容量后预留资源并返回带 owner 证据的句柄/计划；失败时回滚已登记的局部状态。
  // 输入/输出及副作用：binding（输入）、expected_owner（输入）、qp_h（输入）、role（输入）、length（输入）、direction（输入）、backing_ref（输出）；输入请求/句柄定义资源属性；成功时更新账本并通过返回值或
  //   output 发布新句柄/映射。
  // 失败/边界：容量不足、范围非法、重复占用或身份过期时返回错误；失败不得泄漏半分配资源。
  protected function rdma_status allocate_ref(
    rdma_function_binding binding,
    rdma_function_handle expected_owner,
    rdma_handle qp_h,
    rdma_queue_backing_role_e role,
    longint unsigned length,
    rdma_dma_direction_e direction,
    output rdma_qp_backing_ref backing_ref
  );
    return allocate_ref_aligned(binding, expected_owner, qp_h, role, length,
                                 direction, 4096, backing_ref);
  endfunction

  // 功能：将 rhs 中 rdma_qp_lifecycle_executor 的值字段复制到当前对象，建立与源对象隔离的快照。
  // 输入/输出及副作用：spec（输入）、qp_h（输入）、role（输入）、length（输入）、backing_ref（输出）；clone_borrowed_ref 读取 spec、qp_h、role、length、backing_ref 并使用字段 backing_ref、cloned、backing_ref.role、backing_ref.ownership、backing_ref.mapping_offset、backing_ref.length、covered、i，并写入 backing_ref；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：clone_borrowed_ref 返回 RDMA_SC_RESOURCE_EXHAUSTED、RDMA_SC_INVALID_ARGUMENT、RDMA_SC_INVALID_STATE；典型拒绝条件为“QP borrowed backing is empty”“QP borrowed reference allocation failed”；失败路径不提交部分状态或转移未声明资源。
  protected function rdma_status clone_borrowed_ref(
    rdma_queue_backing_spec spec,
    rdma_handle qp_h,
    rdma_queue_backing_role_e role,
    longint unsigned length,
    output rdma_qp_backing_ref backing_ref
  );
    uvm_object cloned;

    // 借用 backing 只复制 mapping 快照；caller 原对象的 owner 和 state 不可修改。
    backing_ref = null;
    if (spec == null || qp_h == null || spec.slices.size() == 0)
      return invalid_argument("QP borrowed backing is empty");
    backing_ref = rdma_qp_backing_ref::type_id::create("qp_borrowed_ref");
    if (backing_ref == null)
      return rdma_status::make(RDMA_SC_RESOURCE_EXHAUSTED,
                               "QP borrowed reference allocation failed");
    if (spec.slices[0] == null || spec.slices[0].mapping == null ||
        spec.slices[0].role != role || spec.slices[0].logical_queue_offset != 0)
      return invalid_argument("QP borrowed backing first slice is invalid");
    cloned = spec.slices[0].mapping.clone();
    if (cloned == null || !$cast(backing_ref.mapping, cloned) ||
        backing_ref.mapping == spec.slices[0].mapping)
      return invalid_state("QP borrowed mapping clone failed");
    backing_ref.role = role;
    backing_ref.ownership = RDMA_OWNERSHIP_BORROWED;
    backing_ref.mapping_offset = spec.slices[0].mapping_offset;
    backing_ref.length = spec.slices[0].length;
    begin
      longint unsigned covered;
      covered = backing_ref.length;
      for (int i = 1; i < spec.slices.size(); i++) begin
        rdma_queue_backing_segment segment;
        rdma_dma_mapping mapping_clone;
        if (spec.slices[i] == null || spec.slices[i].mapping == null ||
            spec.slices[i].role != role ||
            spec.slices[i].logical_queue_offset != covered)
          return invalid_argument("QP borrowed backing is not contiguous");
        cloned = spec.slices[i].mapping.clone();
        if (cloned == null || !$cast(mapping_clone, cloned) ||
            mapping_clone == spec.slices[i].mapping)
          return invalid_state("QP borrowed segment clone failed");
        segment = rdma_queue_backing_segment::type_id::create("qp_borrowed_segment");
        if (segment == null) return rdma_status::make(RDMA_SC_RESOURCE_EXHAUSTED,
          "QP borrowed segment allocation failed");
        segment.role = role; segment.mapping = mapping_clone;
        segment.ownership = RDMA_OWNERSHIP_BORROWED;
        segment.mapping_offset = spec.slices[i].mapping_offset;
        segment.length = spec.slices[i].length;
        segment.logical_queue_offset = covered;
        backing_ref.additional_segments.push_back(segment);
        covered += segment.length;
      end
      if (covered != length)
        return invalid_argument("QP borrowed backing does not cover ring");
    end
    return backing_ref.validate();
  endfunction

  // 功能：bind_borrowed_owner 校验 detached borrowed backing 的 Function authority，
  //       为主 mapping 与全部 additional_segments 生成同一 QP 的 owner 快照，
  //       并在所有检查通过后一次性发布 owner_h。
  // 输入/输出及副作用：backing_ref、qp_h（输入）；读取 backing_ref.mapping.function_h
  //       与 additional_segments[i].mapping，成功时只写入 detached backing 的
  //       owner_h，不接管或修改 caller 持有的原始 mapping。
  // 失败/边界：backing_ref/qp_h 为空、ownership 非 BORROWED、Function authority
  //       缺失或 segment 不属于同一 Function、owner clone 不完整时返回错误；
  //       任何失败都必须保持主 mapping 和全部 segment 的原 owner_h 不变。
  protected function rdma_status bind_borrowed_owner(
    rdma_qp_backing_ref backing_ref,
    rdma_handle qp_h
  );
    rdma_handle primary_owner;
    rdma_handle segment_owners[$];
    rdma_handle prior_primary_owner;
    rdma_handle prior_segment_owners[$];
    rdma_function_handle mapping_owner;
    rdma_status status;

    // 借用 backing 的 owner 绑定跨越主 mapping 与全部 segment。先把所有
    // 新 owner 快照和 Function authority 条件准备完，再一次性写入 owner_h；
    // 这样任一 segment 失败都不会留下“主 mapping 已换 owner、后续 segment
    // 仍是旧 owner”的半发布状态。
    if (backing_ref == null || backing_ref.mapping == null || qp_h == null ||
        backing_ref.ownership != RDMA_OWNERSHIP_BORROWED)
      return invalid_argument("QP borrowed owner binding is invalid");

    mapping_owner = backing_ref.mapping.function_h;
    if (mapping_owner == null || mapping_owner.kind != RDMA_RESOURCE_FUNCTION)
      return invalid_argument("QP borrowed mapping Function authority is invalid");
    prior_primary_owner = backing_ref.mapping.owner_h;
    primary_owner = rdma_clone_handle_value(qp_h, "QP borrowed owner");
    if (primary_owner == null || !primary_owner.same_instance(qp_h))
      return invalid_state("QP borrowed owner clone is null");

    foreach (backing_ref.additional_segments[i]) begin
      if (backing_ref.additional_segments[i] == null ||
          backing_ref.additional_segments[i].mapping == null)
        return invalid_state("QP borrowed segment authority is missing");
      if (backing_ref.additional_segments[i].mapping.function_h == null ||
          !backing_ref.additional_segments[i].mapping.function_h.same_instance(
            mapping_owner
          ))
        return invalid_state("QP borrowed segment Function authority is invalid");
      prior_segment_owners.push_back(
        backing_ref.additional_segments[i].mapping.owner_h
      );
      segment_owners.push_back(rdma_clone_handle_value(
        qp_h, "QP borrowed segment owner"
      ));
      if (segment_owners.size() == 0 ||
          segment_owners[segment_owners.size() - 1] == null ||
          !segment_owners[segment_owners.size() - 1].same_instance(qp_h))
        return invalid_state("QP borrowed segment owner clone is null");
    end

    // Above checks cover every condition that the final authority predicate
    // can reject after these assignments. Commit only after the complete
    // candidate owner set is available, then retain the canonical predicate
    // as a defensive postcondition check.
    backing_ref.mapping.owner_h = primary_owner;
    foreach (backing_ref.additional_segments[i])
      backing_ref.additional_segments[i].mapping.owner_h = segment_owners[i];
    status = rdma_qp_mapping_authority_status(
      backing_ref, mapping_owner, qp_h, "QP borrowed"
    );
    if (status == null || !status.ok()) begin
      // Canonical postcheck is intentionally retained after the publish point;
      // if a future predicate gains a condition not covered by the staging
      // checks above, restore every owner field before returning the failure.
      backing_ref.mapping.owner_h = prior_primary_owner;
      foreach (backing_ref.additional_segments[i])
        backing_ref.additional_segments[i].mapping.owner_h =
          prior_segment_owners[i];
    end
    return status;
  endfunction

  // 功能：make_ring 创建独立的 rdma_status；根据 role、depth、ring 设置字段 ring、logical_bytes、ring.role、ring.depth、ring.entry_size_bytes、ring.logical_bytes、ring.storage_bytes、ring.object_mode，返回对象仅由调用方持有，不转移外部资源所有权。
  // 输入/输出及副作用：role（输入）、depth（输入）、ring（输出）；make_ring 读取 role、depth、ring 并使用字段 ring、logical_bytes、ring.role、ring.depth、ring.entry_size_bytes、ring.logical_bytes、ring.storage_bytes、ring.object_mode，并写入 ring；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：make_ring 返回 RDMA_SC_RESOURCE_EXHAUSTED、RDMA_SC_INVALID_ARGUMENT；典型拒绝条件为“QP ring depth is invalid”“QP ring alignment overflows”；失败路径不提交部分状态或转移未声明资源。
  protected function rdma_status make_ring(
    rdma_queue_backing_role_e role,
    int unsigned depth,
    output rdma_qp_ring_layout ring
  );
    longint unsigned logical_bytes;

    ring = null;
    if (!rdma_qp_power_of_two(depth) || longint'(depth) >
        64'hffff_ffff_ffff_ffff / 64)
      return invalid_argument("QP ring depth is invalid");
    logical_bytes = longint'(depth) * 64;
    if (logical_bytes > 64'hffff_ffff_ffff_efff)
      return invalid_argument("QP ring alignment overflows");
    ring = rdma_qp_ring_layout::type_id::create("qp_ring");
    if (ring == null)
      return rdma_status::make(RDMA_SC_RESOURCE_EXHAUSTED,
                               "QP ring allocation failed");
    ring.role = role;
    ring.depth = depth;
    ring.entry_size_bytes = 64;
    ring.logical_bytes = logical_bytes;
    ring.storage_bytes = ((logical_bytes + 4095) / 4096) * 4096;
    ring.object_mode = RDMA_OBJECT_INDIRECT_4K;
    return ring.validate();
  endfunction

  // 功能：make_sq_sgb_ref 创建独立的 rdma_status；根据 binding、qp_h、depth、spec、ref_out 设置字段 status、ref_out，返回对象仅由调用方持有，不转移外部资源所有权。
  // 输入/输出及副作用：binding（输入）、qp_h（输入）、depth（输入）、spec（输入）、ref_out（输出）；make_sq_sgb_ref 读取 binding、qp_h、depth、spec、ref_out 并使用字段 status、ref_out，并写入 ref_out；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：make_sq_sgb_ref 返回 RDMA_SC_INVALID_ARGUMENT；典型拒绝条件为“SQ SGB backing spec is null”；失败路径不提交部分状态或转移未声明资源。
  protected function rdma_status make_sq_sgb_ref(
    rdma_function_binding binding,
    rdma_handle qp_h,
    int unsigned depth,
    rdma_queue_backing_spec spec,
    output rdma_qp_backing_ref ref_out
  );
    longint unsigned logical_bytes;
    longint unsigned storage_bytes;
    rdma_status status;
    // SQ-SGB 每个 slot 固定 512B，底层 storage 按 4KiB 向上取整。
    status = rdma_qp_sq_sgb_geometry(depth, logical_bytes, storage_bytes);
    ref_out = null;
    if (!status.ok()) return status;
    if (spec == null) return invalid_argument("SQ SGB backing spec is null");
    if (spec.mode == RDMA_QUEUE_BACKING_OWNED)
      return allocate_ref_aligned(binding, binding.make_handle(), qp_h,
        RDMA_QUEUE_ROLE_QP_SQ_SGB, storage_bytes, RDMA_DMA_DEVICE_READ,
        512, ref_out);
    return clone_borrowed_ref(spec, qp_h, RDMA_QUEUE_ROLE_QP_SQ_SGB,
                              storage_bytes, ref_out);
  endfunction

  // 功能：在 rdma_qp_lifecycle_executor 中，zero_sq_sgb_ref 清空 SQ SGB backing 引用，模拟缺失/已释放映射并验证后续清理路径。
  // 输入/输出及副作用：request_context（输入）、backing_ref（输入）、length（输入）；zero_sq_sgb_ref 读取 request_context、backing_ref、length 并使用字段 status、zeros、slot、m、off；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：zero_sq_sgb_ref 返回 RDMA_SC_INVALID_ARGUMENT；典型拒绝条件为“SQ SGB zero input is invalid”“SQ SGB segment boundary splits a slot”；失败路径不提交部分状态或转移未声明资源。
  protected function rdma_status zero_sq_sgb_ref(
    rdma_dma_request_context request_context,
    rdma_qp_backing_ref backing_ref,
    longint unsigned length
  );
    byte zeros[];
    rdma_status status;
    longint unsigned total;
    // 逐 slot 清零；若一个 slot 跨 segment，立即拒绝而不是拆分写入。
    if (request_context == null || backing_ref == null || backing_ref.mapping == null || length == 0)
      return invalid_argument("SQ SGB zero input is invalid");
    status = rdma_qp_backing_total_length(backing_ref, total);
    if (!status.ok() || total < length)
      return status.ok() ? invalid_argument("SQ SGB backing is too short") : status;
    zeros = new[512];
    foreach (zeros[i]) zeros[i] = 0;
    for (longint unsigned slot = 0; slot < length; slot += 512) begin
      rdma_dma_mapping m;
      longint unsigned off;
      m = null; off = 0;
      if (slot + 512 <= backing_ref.length) begin
        m = backing_ref.mapping; off = backing_ref.mapping_offset + slot;
      end else begin
        foreach (backing_ref.additional_segments[i]) begin
          if (backing_ref.additional_segments[i] != null &&
              slot >= backing_ref.additional_segments[i].logical_queue_offset &&
              slot + 512 <= backing_ref.additional_segments[i].logical_queue_offset +
                             backing_ref.additional_segments[i].length) begin
            m = backing_ref.additional_segments[i].mapping;
            off = backing_ref.additional_segments[i].mapping_offset + slot -
                  backing_ref.additional_segments[i].logical_queue_offset;
          end
        end
      end
      if (m == null)
        return invalid_argument("SQ SGB segment boundary splits a slot");
      status = normalize_status(host_mem.write(m, off, zeros),
                                "SQ SGB zero write returned null");
      if (!status.ok()) return status;
    end
    return rdma_status::success();
  endfunction

  // 功能：在 rdma_qp_lifecycle_executor 中，zero_and_encode_pd 按 profile 的字段布局和端序把语义模型编码为硬件镜像，并在发布前检查长度与对齐。
  // 输入/输出及副作用：binding（输入）、expected_owner（输入）、payload_ref（输入）、pd_ref（输入）；zero_and_encode_pd 读取 binding、expected_owner、payload_ref、pd_ref 并使用字段 payload_bytes、zeros、status、fence_status、offset、page_mapping、page_mapping_offset、page；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：zero_and_encode_pd 返回 RDMA_SC_RESOURCE_EXHAUSTED、RDMA_SC_INVALID_STATE；典型拒绝条件为“QP payload page coverage is incomplete”“QP page-directory page allocation failed”；失败路径不提交部分状态或转移未声明资源。
  protected function rdma_status zero_and_encode_pd(
    rdma_function_binding binding,
    rdma_function_handle expected_owner,
    rdma_qp_backing_ref payload_ref,
    rdma_qp_backing_ref pd_ref
  );
    byte zeros[];
    byte unsigned entries[];
    byte pd_bytes[];
    rdma_queue_dma_page_ref pages[$];
    rdma_queue_dma_page_ref page;
    rdma_status status;
    rdma_status fence_status;
    longint unsigned payload_bytes;

    payload_bytes = payload_ref.length;
    foreach (payload_ref.additional_segments[i])
      payload_bytes += payload_ref.additional_segments[i].length;
    // QP refs retain the first borrowed range directly and subsequent ranges
    // as detached segments. Resolve each 4 KiB logical page through that
    // canonical coverage instead of assuming a single mapping.

    zeros = new[int'(payload_ref.length)];
    foreach (zeros[i]) zeros[i] = 0;
    status = live_binding_fence(binding, expected_owner);
    if (status.ok()) begin
      status = normalize_status(host_mem.write(payload_ref.mapping,
        payload_ref.mapping_offset, zeros), "QP payload zero-write returned null");
      fence_status = live_binding_fence(binding, expected_owner);
      if (!fence_status.ok()) status = fence_status;
    end
    if (!status.ok()) return status;
    foreach (payload_ref.additional_segments[i]) begin
      zeros = new[int'(payload_ref.additional_segments[i].length)];
      foreach (zeros[j]) zeros[j] = 0;
      status = live_binding_fence(binding, expected_owner);
      if (status.ok()) begin
        status = normalize_status(host_mem.write(
          payload_ref.additional_segments[i].mapping,
          payload_ref.additional_segments[i].mapping_offset, zeros),
          "QP borrowed segment zero-write returned null");
        fence_status = live_binding_fence(binding, expected_owner);
        if (!fence_status.ok()) status = fence_status;
      end
      if (!status.ok()) return status;
    end
    for (longint unsigned offset = 0; offset < payload_bytes;
         offset += 4096) begin
      rdma_dma_mapping page_mapping;
      longint unsigned page_mapping_offset;
      page_mapping = null;
      page_mapping_offset = 0;
      if (offset < payload_ref.length) begin
        page_mapping = payload_ref.mapping;
        page_mapping_offset = payload_ref.mapping_offset + offset;
      end else foreach (payload_ref.additional_segments[i]) begin
        if (payload_ref.additional_segments[i] != null &&
            offset >= payload_ref.additional_segments[i].logical_queue_offset &&
            offset < payload_ref.additional_segments[i].logical_queue_offset +
                     payload_ref.additional_segments[i].length) begin
          page_mapping = payload_ref.additional_segments[i].mapping;
          page_mapping_offset = payload_ref.additional_segments[i].mapping_offset +
            offset - payload_ref.additional_segments[i].logical_queue_offset;
        end
      end
      if (page_mapping == null) return invalid_state("QP payload page coverage is incomplete");
      page = rdma_queue_dma_page_ref::type_id::create("qp_pd_page");
      if (page == null)
        return rdma_status::make(RDMA_SC_RESOURCE_EXHAUSTED,
                                 "QP page-directory page allocation failed");
      // Page-directory entries carry only page IOVAs.  The established page
      // reference validator predates QP-only roles, so use its neutral ring
      // discriminator while preserving QP role authority in the plan/ref.
      page.role = RDMA_QUEUE_ROLE_CQ_RING;
      page.mapping = page_mapping;
      page.mapping_offset = page_mapping_offset;
      page.logical_page_offset = offset;
      page.page_iova.value = page_mapping.iova.value + page_mapping_offset;
      status = page.validate();
      if (!status.ok()) return status;
      pages.push_back(page);
    end
    entries = new[0];
    status = normalize_status(pd_codec.encode_table(pages, binding.rdma_vf_id,
      entries), "QP page-directory codec returned null");
    if (!status.ok()) return status;
    if (entries.size() != 4096)
      return invalid_state("QP page directory is not one 4 KiB page");
    pd_bytes = new[entries.size()];
    foreach (entries[i]) pd_bytes[i] = entries[i];
    status = live_binding_fence(binding, expected_owner);
    if (status.ok()) begin
      status = normalize_status(host_mem.write(pd_ref.mapping,
        pd_ref.mapping_offset, pd_bytes),
        "QP page-directory write returned null");
      fence_status = live_binding_fence(binding, expected_owner);
      if (!fence_status.ok()) status = fence_status;
    end
    return status;
  endfunction

  // 功能：在 rdma_qp_lifecycle_executor 中，find_urc_ref 按完整 key/handle 查找唯一权威记录并返回 detached 快照，避免把内部可变引用泄露给调用方。
  // 输入/输出及副作用：plan（输入）、role（输入）；find_urc_ref 读取 plan、role 并使用字段 i；函数返回 rdma_qp_backing_ref，不取得调用方资源所有权。
  // 失败/边界：find_urc_ref 在 key/handle 缺失、记录不唯一或 generation/reset epoch 过期时返回明确错误，不回退到默认 authority。
  protected function rdma_qp_backing_ref find_urc_ref(
    rdma_qp_backing_plan plan, rdma_queue_backing_role_e role
  );
    foreach (plan.urc_refs[i])
      if (plan.urc_refs[i] != null && plan.urc_refs[i].role == role)
        return plan.urc_refs[i];
    return null;
  endfunction

  // 功能：materialize_plan 把已验证的 SQ/RQ/SGB/URC backing 规格落实为 Host-memory
  //   映射和 detached QP backing plan，并登记后续释放责任；URC 内部 backing 的
  //   role/length/order 由 typed factory 提供，避免执行器重复维护几何常量。
  // 输入/输出及副作用：binding、expected_owner、qp_snapshot、request（输入）定义
  //   Function/QP authority 和 transport；plan（输出）接收新建 ring、mapping、PD、
  //   SRQ link 与 URC refs。函数通过现有 adapter 分配非拥有映射，但不发布 manager
  //   resource 或修改 caller request。
  // 失败/边界：输入为空、QPN 超过 21 bit、queue capability/geometry 校验失败、任一
  //   owned/borrowed backing 或 URC allocation 失败时返回对应 status；失败只保留已
  //   追加到 plan 的 detached refs，交由上层 partial-plan rollback，不得留下半提交
  //   的 QP authority 或把非 URC transport 当作 URC backing。
  protected function rdma_status materialize_plan(
    rdma_function_binding binding,
    rdma_function_handle expected_owner,
    rdma_qp qp_snapshot,
    rdma_create_qp_req request,
    output rdma_qp_backing_plan plan
  );
    rdma_status status;
    rdma_qp_backing_ref ref_value;
    rdma_qp_urc_backing_spec_t urc_specs[$];

    plan = null;
    if (binding == null || qp_snapshot == null || request == null ||
        qp_snapshot.handle == null)
      return invalid_argument("QP plan materialization input is null");
    status = request.validate_queue_caps(binding.queue_caps);
    if (!status.ok()) return status;
    if (qp_snapshot.local_qp_id > 21'h1f_ffff)
      return invalid_argument("QP local QPN exceeds 21 bits");
    plan = rdma_qp_backing_plan::type_id::create("materialized_qp_plan");
    if (plan == null)
      return rdma_status::make(RDMA_SC_RESOURCE_EXHAUSTED,
                               "QP plan allocation failed");
    plan.transport = request.transport;
    plan.sq_depth = request.sq_depth;
    plan.rq_depth = request.rq_depth;
    status = make_ring(RDMA_QUEUE_ROLE_QP_SQ_RING, request.sq_depth,
                       plan.sq_ring);
    if (!status.ok()) return status;
    if (request.sq_backing.mode == RDMA_QUEUE_BACKING_OWNED)
      status = allocate_ref(binding, expected_owner, qp_snapshot.handle,
        RDMA_QUEUE_ROLE_QP_SQ_RING, plan.sq_ring.storage_bytes,
        RDMA_DMA_DEVICE_READ, plan.sq_ref);
    else
      status = clone_borrowed_ref(request.sq_backing, qp_snapshot.handle,
        RDMA_QUEUE_ROLE_QP_SQ_RING, plan.sq_ring.storage_bytes, plan.sq_ref);
    if (!status.ok()) return status;
    // SGB 物化必须先于 PD 编码，保证失败时能按 plan 顺序回滚。
    if (rdma_qp_needs_sq_sgb(request.transport, request.max_send_sge,
                             request.max_recv_sge)) begin
      status = make_sq_sgb_ref(binding, qp_snapshot.handle, request.sq_depth,
                               request.sq_sgb_backing, plan.sq_sgb_ref);
      if (!status.ok()) return status;
      begin
        rdma_dma_request_context sgb_context;
        longint unsigned sgb_logical_bytes;
        longint unsigned sgb_storage_bytes;
        status = rdma_qp_sq_sgb_geometry(request.sq_depth, sgb_logical_bytes,
                                         sgb_storage_bytes);
        status = make_dma_context(binding, qp_snapshot.handle,
                                  RDMA_QUEUE_ROLE_QP_SQ_SGB, sgb_context);
        if (status.ok())
          status = zero_sq_sgb_ref(sgb_context, plan.sq_sgb_ref,
                                   sgb_storage_bytes);
        if (status.ok() &&
            request.sq_sgb_backing.mode == RDMA_QUEUE_BACKING_BORROWED)
          status = bind_borrowed_owner(plan.sq_sgb_ref, qp_snapshot.handle);
        if (!status.ok()) return status;
      end
    end
    status = allocate_ref(binding, expected_owner, qp_snapshot.handle,
                          RDMA_QUEUE_ROLE_QP_SQ_PD, 4096,
                          RDMA_DMA_DEVICE_READ, plan.sq_pd_ref);
    if (!status.ok()) return status;
    status = zero_and_encode_pd(binding, expected_owner, plan.sq_ref,
                                plan.sq_pd_ref);
    if (!status.ok()) return status;
    if (request.sq_backing.mode == RDMA_QUEUE_BACKING_BORROWED) begin
      status = bind_borrowed_owner(plan.sq_ref, qp_snapshot.handle);
      if (!status.ok()) return status;
    end
    if (request.srq_h != null) begin
      rdma_resource source;
      rdma_srq srq;
      status = normalize_status(manager.lookup(request.srq_h, source),
        "QP SRQ lookup returned null");
      if (!status.ok() || !$cast(srq, source)) return status.ok() ?
        invalid_state("QP SRQ dependency is not an SRQ") : status;
      status = request.validate_srq_depth(srq.depth);
      if (!status.ok()) return status;
      // Retain the manager-projected handle object so the QP resource and
      // plan carry one identity authority through later publication copies.
      plan.rq_source_h = qp_snapshot.srq_h;
    end else begin
      status = make_ring(RDMA_QUEUE_ROLE_QP_RQ_RING, request.rq_depth,
                         plan.rq_ring);
      if (!status.ok()) return status;
      if (request.rq_backing.mode == RDMA_QUEUE_BACKING_OWNED)
        status = allocate_ref(binding, expected_owner, qp_snapshot.handle,
          RDMA_QUEUE_ROLE_QP_RQ_RING, plan.rq_ring.storage_bytes,
          RDMA_DMA_DEVICE_READ, plan.rq_ref);
      else
        status = clone_borrowed_ref(request.rq_backing, qp_snapshot.handle,
          RDMA_QUEUE_ROLE_QP_RQ_RING, plan.rq_ring.storage_bytes, plan.rq_ref);
      if (!status.ok()) return status;
      status = allocate_ref(binding, expected_owner, qp_snapshot.handle,
        RDMA_QUEUE_ROLE_QP_RQ_PD, 4096, RDMA_DMA_DEVICE_READ, plan.rq_pd_ref);
      if (!status.ok()) return status;
      status = zero_and_encode_pd(binding, expected_owner, plan.rq_ref,
                                  plan.rq_pd_ref);
      if (!status.ok()) return status;
      if (request.rq_backing.mode == RDMA_QUEUE_BACKING_BORROWED) begin
        status = bind_borrowed_owner(plan.rq_ref, qp_snapshot.handle);
        if (!status.ok()) return status;
      end
    end
    // 设计说明：URC 内部 backing 的 geometry/order 属于 detached policy 值；本循环
    //   只负责调用现有 allocate_ref，并在每次失败时把可能已产生的引用追加到 plan，
    //   让上层既有 partial-plan rollback 继续释放同一顺序中的所有成功分配。
    rdma_qp_urc_backing_policy::specs_for_transport(
      request.transport, urc_specs
    );
    foreach (urc_specs[i]) begin
      status = allocate_ref(binding, expected_owner, qp_snapshot.handle,
                            urc_specs[i].role, urc_specs[i].length,
                            RDMA_DMA_BIDIRECTIONAL, ref_value);
      if (ref_value != null)
        plan.urc_refs.push_back(ref_value);
      if (!status.ok())
        return status;
    end
    return rdma_status::success();
  endfunction

  // 功能：在 rdma_qp_lifecycle_executor 中，local_handle 构造或投影带完整 kind、Function UID、object ID 和 generation 的资源句柄。
  // 输入/输出及副作用：source（输入）、kind（输入）、local_id（输入）、label（输入）、projected（输出）；local_handle 读取 source、kind、local_id、label、projected 并使用字段 projected、projected.object_id，并写入 projected；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：local_handle 返回 RDMA_SC_INVALID_STATE；失败路径不提交部分状态或转移未声明资源。
  protected function rdma_status local_handle(
    rdma_handle source, rdma_resource_kind_e kind, int unsigned local_id,
    string label, output rdma_handle projected
  );
    projected = rdma_clone_handle_value(source, label);
    if (projected == null || projected.kind != kind)
      return invalid_state({label, " projection is invalid"});
    projected.object_id = local_id;
    return rdma_status::success();
  endfunction

  // 功能：在 rdma_qp_lifecycle_executor 中，capture_qpc_authority 从输入对象提取受控字段并返回 detached 投影，阻断调用方通过别名修改 authority。
  // 输入/输出及副作用：binding（输入）、qp_snapshot（输入）、plan（输入）、pd（输出）、send_cq（输出）、recv_cq（输出）、srq（输出）、qp_sequence_value（输出）；capture_qpc_authority 读取 binding、qp_snapshot、plan、pd、send_cq、recv_cq、srq、qp_sequence_value 并使用字段 pd、send_cq、recv_cq、srq、qp_sequence_value、status，并写入 pd、send_cq、recv_cq、srq、qp_sequence_value；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：capture_qpc_authority 返回 RDMA_SC_INVALID_ARGUMENT；典型拒绝条件为“QPC authority capture input is null”；失败路径不提交部分状态或转移未声明资源。
  protected function rdma_status capture_qpc_authority(
    rdma_function_binding binding,
    rdma_qp qp_snapshot,
    rdma_qp_backing_plan plan,
    output rdma_pd pd,
    output rdma_cq send_cq,
    output rdma_cq recv_cq,
    output rdma_srq srq,
    output bit [7:0] qp_sequence_value
  );
    rdma_resource dependency;
    rdma_status status;

    pd = null;
    send_cq = null;
    recv_cq = null;
    srq = null;
    qp_sequence_value = '0;
    if (binding == null || qp_snapshot == null || plan == null)
      return invalid_argument("QPC authority capture input is null");
    status = normalize_status(manager.lookup(qp_snapshot.pd_h, dependency),
                              "QPC PD lookup returned null");
    if (!status.ok() || !$cast(pd, dependency))
      return status.ok() ? invalid_state("QPC PD dependency is invalid") :
                           status;
    status = normalize_status(manager.lookup(qp_snapshot.send_cq_h, dependency),
                              "QPC send CQ lookup returned null");
    if (!status.ok() || !$cast(send_cq, dependency))
      return status.ok() ? invalid_state("QPC send CQ dependency is invalid") :
                           status;
    status = normalize_status(manager.lookup(qp_snapshot.recv_cq_h, dependency),
                              "QPC receive CQ lookup returned null");
    if (!status.ok() || !$cast(recv_cq, dependency))
      return status.ok() ? invalid_state("QPC receive CQ dependency is invalid") :
                           status;
    if (plan.rq_source_h != null) begin
      status = normalize_status(manager.lookup(plan.rq_source_h, dependency),
                                "QPC SRQ lookup returned null");
      if (!status.ok() || !$cast(srq, dependency) || srq.queue_plan == null)
        return status.ok() ? invalid_state("QPC SRQ plan is invalid") : status;
    end
    return normalize_status(manager.qp_sequence(
      binding.make_handle(), qp_snapshot.local_qp_id, qp_sequence_value
    ), "QPC sequence lookup returned null");
  endfunction

  // 功能：build_qpc_model 创建独立的 rdma_status；根据 binding、qp_snapshot、request、plan、pd、send_cq、recv_cq、srq、qp_sequence_value、model 设置字段 model、status、model.transport、model.state、model.host_id、model.vf_id、model.stat_index、model.qp_sequence、model.pkey、model.access，返回对象仅由调用方持有，不转移外部资源所有权。
  // 输入/输出及副作用：binding（输入）、qp_snapshot（输入）、request（输入）、plan（输入）、pd（输入）、send_cq（输入）、recv_cq（输入）、srq（输入）、qp_sequence_value（输入）、model（输出）；输入字段被复制到返回值或
  //   output；生成结果与输入隔离，不隐式修改调用方对象。
  // 失败/边界：build_qpc_model 返回 RDMA_SC_RESOURCE_EXHAUSTED、RDMA_SC_INVALID_ARGUMENT、RDMA_SC_INVALID_STATE；典型拒绝条件为“QPC builder input is null”“QPC local QPN exceeds 21 bits”；失败路径不提交部分状态或转移未声明资源。
  function rdma_status build_qpc_model(
    rdma_function_binding binding,
    rdma_qp qp_snapshot,
    rdma_create_qp_req request,
    rdma_qp_backing_plan plan,
    rdma_pd pd,
    rdma_cq send_cq,
    rdma_cq recv_cq,
    rdma_srq srq,
    bit [7:0] qp_sequence_value,
    output rdma_qpc_model model
  );
    rdma_status status;
    uvm_object cloned;
    rdma_qpc_urc_ext urc_ext;
    rdma_qp_backing_ref urc_ref;

    model = null;
    if (binding == null || qp_snapshot == null || request == null || plan == null ||
        qp_snapshot.handle == null || request.context_attrs == null ||
        pd == null || send_cq == null || recv_cq == null)
      return invalid_argument("QPC builder input is null");
    status = normalize_status(plan.validate(), "QP plan validation returned null");
    if (!status.ok()) return status;
    if (qp_snapshot.local_qp_id > 21'h1f_ffff)
      return invalid_argument("QPC local QPN exceeds 21 bits");
    model = rdma_qpc_model::type_id::create("semantic_qpc");
    if (model == null)
      return rdma_status::make(RDMA_SC_RESOURCE_EXHAUSTED,
                               "QPC model allocation failed");
    status = local_handle(qp_snapshot.handle, RDMA_RESOURCE_QP,
                          qp_snapshot.local_qp_id, "QPC QP", model.qp_h);
    if (status.ok()) status = local_handle(qp_snapshot.pd_h, RDMA_RESOURCE_PD,
      pd.local_pd_id, "QPC PD", model.pd_h);
    if (status.ok()) status = local_handle(qp_snapshot.send_cq_h,
      RDMA_RESOURCE_CQ, send_cq.local_cq_id, "QPC send CQ", model.send_cq_h);
    if (status.ok()) status = local_handle(qp_snapshot.recv_cq_h,
      RDMA_RESOURCE_CQ, recv_cq.local_cq_id, "QPC receive CQ", model.recv_cq_h);
    if (!status.ok()) return status;
    model.transport = request.transport;
    model.state = RDMA_QPS_RESET;
    model.host_id = binding.host_id;
    model.vf_id = binding.rdma_vf_id;
    model.stat_index = qp_snapshot.local_qp_id & 8'hff;
    model.qp_sequence = qp_sequence_value;
    model.pkey = request.context_attrs.pkey;
    model.access = request.context_attrs.access;
    model.path_mtu_bytes = request.context_attrs.path_mtu_bytes;
    model.sq_depth = plan.sq_depth;
    model.rq_depth = plan.rq_depth;
    model.sq_backing.value = plan.sq_pd_ref.mapping.iova.value +
                             plan.sq_pd_ref.mapping_offset;
    model.sq_mode = plan.sq_ring.object_mode;
    model.context_backing = plan.context_ref.shadow_pointer_base;
    model.signature_enable = request.context_attrs.signature_enable;
    model.tx_flow_control = request.context_attrs.tx_flow_control;
    model.rx_flow_control = request.context_attrs.rx_flow_control;
    cloned = request.context_attrs.address_vector.clone();
    if (cloned == null || !$cast(model.address_vector, cloned))
      return invalid_state("QPC address-vector clone failed");
    cloned = request.context_attrs.behavior.clone();
    if (cloned == null || !$cast(model.behavior, cloned))
      return invalid_state("QPC behavior clone failed");
    cloned = request.context_attrs.transport_ext.clone();
    if (cloned == null || !$cast(model.transport_ext, cloned))
      return invalid_state("QPC transport-extension clone failed");
    if (plan.rq_source_h != null) begin
      if (srq == null || srq.queue_plan == null)
        return invalid_state("QPC SRQ plan is invalid");
      status = local_handle(plan.rq_source_h, RDMA_RESOURCE_SRQ, srq.local_srq_id,
                            "QPC SRQ", model.srq_h);
      if (!status.ok()) return status;
      // The SRQ queue plan owns the receive page-directory hardware base.
      foreach (srq.queue_plan.refs[i])
        if (srq.queue_plan.refs[i] != null &&
            srq.queue_plan.refs[i].role == RDMA_QUEUE_ROLE_SRFQ_PD)
          model.rq_backing.value = srq.queue_plan.refs[i].mapping.iova.value +
                                   srq.queue_plan.refs[i].mapping_offset;
      model.rq_mode = RDMA_OBJECT_INDIRECT_4K;
    end else begin
      model.rq_backing.value = plan.rq_pd_ref.mapping.iova.value +
                               plan.rq_pd_ref.mapping_offset;
      model.rq_mode = plan.rq_ring.object_mode;
    end
    if (request.transport == RDMA_TRANSPORT_URC) begin
      if (!$cast(urc_ext, model.transport_ext))
        return invalid_state("QPC URC extension clone is invalid");
      urc_ref = find_urc_ref(plan, RDMA_QUEUE_ROLE_QP_URC_RSQ);
      if (urc_ref == null) return invalid_state("QPC URC RSQ ref is missing");
      urc_ext.queues.rsq_backing.value = urc_ref.mapping.iova.value +
                                          urc_ref.mapping_offset;
      urc_ref = find_urc_ref(plan, RDMA_QUEUE_ROLE_QP_URC_RDSQ);
      if (urc_ref == null) return invalid_state("QPC URC RDSQ ref is missing");
      urc_ext.queues.rdsq_backing.value = urc_ref.mapping.iova.value +
                                           urc_ref.mapping_offset;
      urc_ref = find_urc_ref(plan, RDMA_QUEUE_ROLE_QP_URC_DSQ);
      if (urc_ref == null) return invalid_state("QPC URC DSQ ref is missing");
      urc_ext.queues.dsq_backing.value = urc_ref.mapping.iova.value +
                                          urc_ref.mapping_offset;
    end
    return normalize_status(model.validate(), "semantic QPC validation returned null");
  endfunction

  // 功能：在 rdma_qp_lifecycle_executor 中，encode_qpc_staging 按硬件布局把输入模型编码到 image/缓冲区，并在写入前检查范围、重叠、端序和保留位。
  // 输入/输出及副作用：binding（输入）、model（输入）、authoritative_qp_h（输入）、expected_owner（输入）、staging（输出）、image（输出）；输入模型只读；成功时通过返回值或
  //   output 发布完整 image/bytes，不修改源模型。
  // 失败/边界：encode_qpc_staging 遇到 image/model 为空、长度/对齐/保留位非法或 codec 校验失败时不发布部分字段。
  function rdma_status encode_qpc_staging(
    rdma_function_binding binding,
    rdma_qpc_model model,
    rdma_handle authoritative_qp_h,
    rdma_function_handle expected_owner,
    output rdma_dma_mapping staging,
    output rdma_hw_image image
  );
    rdma_status status;
    rdma_status fence_status;
    rdma_codec_key key;
    rdma_codec_base codec;
    rdma_hw_model decoded;
    rdma_dma_request_context request_context;
    bit equal;
    string mismatch;
    byte data[];
    string variant;

    staging = null;
    image = null;
    if (binding == null || model == null || authoritative_qp_h == null ||
        expected_owner == null || host_mem == null || qpc_codecs == null)
      return invalid_argument("QPC staging input is null");
    status = model.validate();
    if (!status.ok()) return status;
    case (model.transport)
      RDMA_TRANSPORT_RC: variant = "rc";
      RDMA_TRANSPORT_UD: variant = "ud";
      RDMA_TRANSPORT_URC: variant = "urc";
      default: return invalid_argument("QPC transport has no codec variant");
    endcase
    key.hw_version = "rdma";
    key.image_kind = RDMA_IMAGE_QPC;
    key.object_type = "qpc";
    key.variant = variant;
    key.opcode = RDMA_OP_QPC_CREATE;
    status = qpc_codecs.lookup(key, codec);
    if (!status.ok()) return status;
    status = codec.encode(model, image);
    if (!status.ok()) return status;
    if (image == null || image.bytes.size() != 512 || image.length != 512 ||
        image.alignment != 512)
      return invalid_state("QPC codec did not emit a 512-byte image");
    status = codec.decode(image, decoded);
    if (!status.ok()) return status;
    status = codec.serialized_equal(model, decoded, equal, mismatch);
    if (!status.ok()) return status;
    if (!equal) return rdma_status::make(RDMA_SC_CODEC_ERROR,
                                         {"QPC round-trip mismatch: ", mismatch});
    status = make_dma_context(binding, authoritative_qp_h, RDMA_QUEUE_ROLE_QP_SQ_PD,
                              request_context);
    if (!status.ok()) return status;
    request_context.queue_role_valid = 1'b0;
    status = live_binding_fence(binding, expected_owner);
    if (!status.ok()) return status;
    status = normalize_status(host_mem.allocate(request_context, 512, 512,
      RDMA_DMA_DEVICE_READ, staging), "QPC staging allocation returned null");
    fence_status = live_binding_fence(binding, expected_owner);
    if (!fence_status.ok()) return fence_status;
    if (!status.ok()) return status;
    if (staging == null || staging.size < 512 ||
        (staging.iova.value & 64'h1ff) != 0 ||
        (staging.backing_addr.value & 64'h1ff) != 0)
      return invalid_state("QPC staging allocation is not 512-byte aligned");
    data = new[image.bytes.size()];
    foreach (data[i]) data[i] = image.bytes[i];
    status = live_binding_fence(binding, expected_owner);
    if (!status.ok()) return status;
    status = normalize_status(host_mem.write(staging, 0, data),
      "QPC staging write returned null");
    fence_status = live_binding_fence(binding, expected_owner);
    if (!fence_status.ok()) return fence_status;
    return status;
  endfunction

  // 功能：在 rdma_qp_lifecycle_executor 中，attach_create_programming 把 attach_create_programming 指定的资源或后端能力绑定到当前对象索引，并校验 Function、generation 和队列类型一致。
  // 输入/输出及副作用：candidate（输入）、request（输入）、plan（输入）、model（输入）；attach_create_programming 先依据 candidate == null || request == null || plan == null || model == null 校验 candidate、request、plan、model；成功时更新本对象配置/状态并保存非拥有引用，返回 rdma_status。
  // 失败/边界：资源不存在、类型不符、重复登记或跨 Function 串线时拒绝绑定并保持索引不变。
  protected function rdma_status attach_create_programming(
    rdma_qp candidate,
    rdma_create_qp_req request,
    rdma_qp_backing_plan plan,
    rdma_qpc_model model
  );
    if (candidate == null || request == null || plan == null || model == null)
      return invalid_argument("QP programming attachment input is null");
    candidate.transport = request.transport;
    candidate.qp_state = RDMA_QPS_RESET;
    candidate.sq_depth = request.sq_depth;
    candidate.rq_depth = request.rq_depth;
    candidate.sq_iova.value = plan.sq_ref.mapping.iova.value +
                              plan.sq_ref.mapping_offset;
    candidate.rq_iova.value = plan.rq_source_h == null ?
      plan.rq_ref.mapping.iova.value + plan.rq_ref.mapping_offset : 0;
    candidate.qp_plan = plan;
    candidate.programmed_qpc = model;
    return normalize_status(manager.attach_qp_programming(candidate),
                            "QP programming attachment returned null");
  endfunction

  // 功能：在 rdma_qp_lifecycle_executor 中，cmq_outcome_ambiguous 检查当前事务或测试证据是否满足指定布尔条件，供恢复分类和断言选择后续路径。
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
      1'b1,
      1'b0,
      1'b1
    );
  endfunction

  // 功能：在 rdma_qp_lifecycle_executor 中，execute_qp_legacy_command 收束 QP
  //   创建、修改、查询和回滚阶段共用的 legacy CMQ 原始 dispatch，避免各阶段
  //   重复维护输出初始化与一次 execute 调用。
  // 输入/输出及副作用：command（输入）；ticket、completion、status（输出）。任务
  //   清空本次调用的 ticket/completion/status，调用 cmq.execute 一次并保留后端原始
  //   status；不执行 generation fence、ambiguity 分类、completion 校验或资源状态
  //   提交，也不取得 command/CMQ 资源所有权。
  // 失败/边界：cmq 为空时返回 RDMA_SC_INVALID_STATE，command 为空时返回
  //   RDMA_SC_INVALID_ARGUMENT；后端返回 null status 时保留 null，由调用方按各阶段
  //   原有诊断和 recovery 优先级归一化。任务不重试、不代替调用方的 pre/post fence。
  protected task execute_qp_legacy_command(
    rdma_cmq_command_desc command,
    output rdma_cmq_ticket ticket,
    output rdma_cmq_completion completion,
    output rdma_status status
  );
    rdma_cmq_dispatch_legacy_raw(
      cmq,
      command,
      ticket,
      completion,
      status,
      "QP CMQ is unavailable",
      "QP CMQ command is null"
    );
  endtask

  // 功能：在 rdma_qp_lifecycle_executor 中由 same_qpc_snapshot 逐字段比较输入值，返回结构、身份或序列化内容是否一致。
  // 输入/输出及副作用：lhs（输入）、rhs（输入）；比较对象/数组只读；返回 bit 或状态结果，不更新 runtime、账本或外部 adapter。
  // 失败/边界：same_qpc_snapshot 的任一比较对象为空或类型不符时返回确定的 false/不等结果，不抛出未处理异常。
  protected function bit same_qpc_snapshot(rdma_qpc_model lhs,
                                            rdma_qpc_model rhs);
    rdma_codec_key key;
    rdma_codec_base codec;
    bit equal;
    string mismatch;
    rdma_status status;
    if (lhs == null || rhs == null || lhs.transport != rhs.transport ||
        qpc_codecs == null)
      return lhs == rhs;
    case (lhs.transport)
      RDMA_TRANSPORT_RC: key.variant = "rc";
      RDMA_TRANSPORT_UD: key.variant = "ud";
      RDMA_TRANSPORT_URC: key.variant = "urc";
      default: return 1'b0;
    endcase
    key.hw_version = "rdma";
    key.image_kind = RDMA_IMAGE_QPC;
    key.object_type = "qpc";
    key.opcode = RDMA_OP_QPC_CREATE;
    status = qpc_codecs.lookup(key, codec);
    if (status == null || !status.ok() || codec == null)
      return 1'b0;
    status = codec.serialized_equal(lhs, rhs, equal, mismatch);
    return status != null && status.ok() && equal;
  endfunction

  // Read and authenticate the complete 512-byte QPC image returned by the
  // device.  CMQ completion payloads are transport metadata only; they are
  // deliberately not accepted as a substitute for the DMA query image.
  // 功能：在 rdma_qp_lifecycle_executor 中，read_qpc_query_image 按完整 key/handle 查找唯一权威记录并返回 detached 快照，避免把内部可变引用泄露给调用方。
  // 输入/输出及副作用：expected_owner（输入）、query_mapping（输入）、reference_qpc（输入）、queried_qpc（输出）；输入 handle/key/cursor
  //   用于选择读取范围；返回值或 output 为 detached 快照，读取不取得外部资源所有权。
  // 失败/边界：read_qpc_query_image 在 key/handle 缺失、记录不唯一或 generation/reset epoch 过期时返回明确错误，不回退到默认 authority。
  protected function rdma_status read_qpc_query_image(
    rdma_function_handle expected_owner,
    rdma_dma_mapping query_mapping,
    rdma_qpc_model reference_qpc,
    output rdma_qpc_model queried_qpc
  );
    rdma_codec_key key;
    rdma_codec_base codec;
    rdma_hw_image image;
    rdma_hw_model decoded_model;
    rdma_status status;
    byte data[];
    string variant;

    queried_qpc = null;
    if (expected_owner == null || query_mapping == null ||
        reference_qpc == null || host_mem == null || qpc_codecs == null)
      return invalid_argument("QP query image authority is incomplete");
    if (query_mapping.size < 512 ||
        (query_mapping.iova.value & 64'h1ff) != 0 ||
        (query_mapping.backing_addr.value & 64'h1ff) != 0)
      return invalid_state("QP query mapping is not a 512-byte image");
    status = normalize_status(host_mem.read(query_mapping, 0, 512, data),
                              "QP query image read returned null");
    if (!status.ok())
      return status;
    if (data.size() != 512)
      return invalid_state("QP query image read length is not 512 bytes");
    case (reference_qpc.transport)
      RDMA_TRANSPORT_RC: variant = "rc";
      RDMA_TRANSPORT_UD: variant = "ud";
      RDMA_TRANSPORT_URC: variant = "urc";
      default: return invalid_argument("QP query transport is unsupported");
    endcase
    key.hw_version = "rdma";
    key.image_kind = RDMA_IMAGE_QPC;
    key.object_type = "qpc";
    key.variant = variant;
    key.opcode = RDMA_OP_QPC_CREATE;
    status = qpc_codecs.lookup(key, codec);
    if (!status.ok() || codec == null)
      return status.ok() ? invalid_state("QP query QPC codec is unavailable") : status;
    image = rdma_hw_image::type_id::create("qp_query_image");
    if (image == null)
      return rdma_status::make(RDMA_SC_RESOURCE_EXHAUSTED,
                               "QP query image allocation failed");
    foreach (data[i]) image.bytes.push_back(data[i]);
    image.length = 512;
    image.alignment = 512;
    image.endian = RDMA_ENDIAN_BIG;
    image.image_kind = RDMA_IMAGE_QPC;
    image.hardware_version = RDMA_HW_VERSION;
    image.function_generation = expected_owner.generation;
    image.write_target_kind = RDMA_HW_TARGET_NONE;
    status = normalize_status(codec.validate_image(image),
                              "QP query image validation returned null");
    if (!status.ok())
      return status;
    status = normalize_status(codec.decode(image, decoded_model),
                              "QP query image decode returned null");
    if (!status.ok() || decoded_model == null)
      return status.ok() ? invalid_state("QP query image decode is empty") : status;
    if (!$cast(queried_qpc, decoded_model) || queried_qpc == null)
      return invalid_state("QP query image is not a QPC model");
    // The rdma QPC image carries the local QPN and projected resource kind;
    // function UID/generation are transport metadata and are not serialized
    // in the image.  Compare exactly the identity fields the image owns.
    if (queried_qpc.qp_h == null || reference_qpc.qp_h == null ||
        queried_qpc.qp_h.kind != reference_qpc.qp_h.kind ||
        queried_qpc.qp_h.object_id != reference_qpc.qp_h.object_id)
      return invalid_state("QP query image QPN identity does not match");
    return normalize_status(queried_qpc.validate(),
                           "QP query decoded QPC validation returned null");
  endfunction

  // Guard an adapter side effect with the binding generation fence on both
  // sides.  The pre-fence prevents issuing the operation with stale
  // authority; the post-fence makes a concurrent rebind visible before the
  // caller persists any completion milestone.
  // 功能：在 rdma_qp_lifecycle_executor 中，release_mapping_fenced 按 owner、generation 和幂等规则释放/隔离记录，并同步删除其账本引用。
  // 输入/输出及副作用：binding（输入）、expected_owner（输入）、mapping（输入）、label（输入）、status（输出）、release_complete（输出）；输入
  //   handle/mapping/token 指定释放目标；成功时更新账本和生命周期，外部资源只按 adapter 契约释放。
  // 失败/边界：release_mapping_fenced 发现 owner/generation 不匹配、记录未知或重复释放时返回错误或幂等结果，不重新激活旧句柄。
  protected task release_mapping_fenced(
    rdma_function_binding binding,
    rdma_function_handle expected_owner,
    rdma_dma_mapping mapping,
    string label,
    output rdma_status status,
    output bit release_complete
  );
    rdma_status fence_status;

    release_complete = 1'b0;
    status = live_binding_fence(binding, expected_owner);
    if (status.ok()) begin
      status = release_mapping_opaque(mapping, label, release_complete);
      fence_status = live_binding_fence(binding, expected_owner);
      if (!fence_status.ok()) status = fence_status;
    end
  endtask

  // Issue a QPC_QUERY against a temporary or previously retained mapping and
  // classify only the authenticated DMA image.  A terminal command failure is
  // useful absence evidence; timeout/reset, malformed completion, or a codec
  // failure remains inconclusive.  The mapping is always released (through a
  // detached probe when it is durable authority); callers may retain it when
  // the opaque completion is still pending.
  // 功能：在 rdma_qp_lifecycle_executor 中，query_qpc_presence 按完整 key/handle 查找唯一权威记录并返回 detached 快照，避免把内部可变引用泄露给调用方。
  // 输入/输出及副作用：binding（输入）、expected_owner（输入）、reference_qpc（输入）、retained_mapping（输入）、query_mapping（输出）、presence（输出）、conclusive（输出）、release_complete（输出）、status（输出）；输入
  //   handle/key/cursor 用于选择读取范围；返回值或 output 为 detached 快照，读取不取得外部资源所有权。
  // 失败/边界：query_qpc_presence 在 key/handle 缺失、记录不唯一或 generation/reset epoch 过期时返回明确错误，不回退到默认 authority。
  protected task query_qpc_presence(
    rdma_function_binding binding,
    rdma_function_handle expected_owner,
    rdma_qpc_model reference_qpc,
    rdma_dma_mapping retained_mapping,
    output rdma_dma_mapping query_mapping,
    output rdma_hw_presence_e presence,
    output bit conclusive,
    output bit release_complete,
    output rdma_status status
  );
    rdma_dma_request_context query_context;
    rdma_hw_qpc_command_body body;
    rdma_cmq_command_desc query_command;
    rdma_cmq_ticket ticket;
    rdma_cmq_completion completion;
    rdma_qpc_model queried_qpc;
    rdma_dma_mapping release_probe;
    rdma_status fence_status;
    rdma_status release_status;
    bit fresh_mapping;
    bit ambiguous;
    uvm_object cloned;

    query_mapping = retained_mapping;
    presence = RDMA_HW_PRESENCE_UNKNOWN;
    conclusive = 1'b0;
    release_complete = 1'b0;
    status = rdma_status::success();
    fresh_mapping = retained_mapping == null;
    if (binding == null || expected_owner == null || reference_qpc == null ||
        host_mem == null || cmq == null) begin
      status = invalid_argument("QP presence query authority is incomplete");
    end
    if (status.ok() && fresh_mapping) begin
      status = make_dma_context(binding, reference_qpc.qp_h,
                                RDMA_QUEUE_ROLE_QP_SQ_PD, query_context);
      if (status.ok()) begin
        query_context.queue_role_valid = 1'b0;
        status = live_binding_fence(binding, expected_owner);
      end
      if (status.ok())
        status = normalize_status(host_mem.allocate(query_context, 512, 512,
          RDMA_DMA_DEVICE_WRITE, query_mapping),
          "QP presence query allocation returned null");
      fence_status = live_binding_fence(binding, expected_owner);
      if (status.ok() && !fence_status.ok()) status = fence_status;
      if (status.ok() && (query_mapping == null || query_mapping.size < 512 ||
          (query_mapping.iova.value & 64'h1ff) != 0 ||
          (query_mapping.backing_addr.value & 64'h1ff) != 0))
        status = invalid_state("QP presence query mapping is invalid");
    end
    if (status.ok() && query_mapping == null)
      status = invalid_state("QP presence query mapping is null");
    if (status.ok()) begin
      body = rdma_hw_qpc_command_body::type_id::create(
        "qp_presence_query_body");
      body.qp_h = rdma_clone_handle_value(reference_qpc.qp_h,
                                           "QP presence query QPN");
      body.qpc_buffer.value = query_mapping.iova.value;
      query_command = rdma_cmq_command_desc::type_id::create(
        "qp_presence_query_command");
      query_command.function_h = rdma_clone_function_handle_value(
        expected_owner, "QP presence query command");
      query_command.opcode_key = make_opcode_key(RDMA_OP_QPC_QUERY, "query");
      query_command.body = body;
      query_command.timeout = command_timeout;
      status = normalize_status(query_command.validate(),
                                "QP presence query validation returned null");
    end
    if (status.ok()) begin
      ticket = null;
      completion = null;
      status = live_binding_fence(binding, expected_owner);
      if (status.ok())
        execute_qp_legacy_command(
          query_command, ticket, completion, status
        );
      else begin
        ticket = null;
        completion = null;
      end
      ambiguous = cmq_outcome_ambiguous(status, ticket, completion);
      status = normalize_status(status, "QP presence query execution returned null");
      fence_status = live_binding_fence(binding, expected_owner);
      if (!fence_status.ok()) begin
        status = fence_status;
        ambiguous = 1'b1;
      end
      if (ambiguous) begin
        status = rdma_status::make(RDMA_SC_RECOVERY_REQUIRED,
                                   "QP presence query remains ambiguous");
      end
      else if (completion != null && completion.status != null &&
               completion.status.ok()) begin
        status = read_qpc_query_image(expected_owner, query_mapping,
                                      reference_qpc, queried_qpc);
        if (status.ok() && queried_qpc != null) begin
          presence = RDMA_HW_PRESENCE_PRESENT;
          conclusive = 1'b1;
        end
        else begin
          presence = RDMA_HW_PRESENCE_UNKNOWN;
          conclusive = 1'b0;
          // A successful QPC_QUERY command with an unreadable, malformed, or
          // undecodable image is not evidence of presence or absence.  Keep
          // the recovery contract stable and fail closed instead of exposing
          // a codec/read implementation detail to callers.
          if (status == null || status.code != RDMA_SC_STALE_GENERATION)
            status = rdma_status::make(
              RDMA_SC_RECOVERY_REQUIRED,
              "QP presence query image is inconclusive"
            );
        end
      end
      else if (completion != null && completion.status != null &&
               !(completion.status.code inside {RDMA_SC_TIMEOUT,
                                                 RDMA_SC_RESET_CANCELLED})) begin
        // A terminal non-OK QPC_QUERY result proves that no context matching
        // this QPN is present.  Keep the completion payload out of image
        // authentication; it is used only for this terminal status.
        presence = RDMA_HW_PRESENCE_ABSENT;
        conclusive = 1'b1;
        status = rdma_status::success();
      end
      else begin
        presence = RDMA_HW_PRESENCE_UNKNOWN;
        conclusive = 1'b0;
        if (status.ok()) status = rdma_status::make(
          RDMA_SC_RECOVERY_REQUIRED, "QP presence query is inconclusive");
      end
    end
    // Release even when command execution or image authentication failed.
    // If this was durable authority, preserve its public identity by using a
    // detached clone; the opaque completion seal remains shared.
    if (query_mapping != null) begin
      release_probe = null;
      if (fresh_mapping)
        release_mapping_fenced(binding, expected_owner, query_mapping,
                               "QP presence query", release_status,
                               release_complete);
      else begin
        cloned = query_mapping.clone();
        if (cloned == null || !$cast(release_probe, cloned)) begin
          release_status = invalid_state(
            "QP retained presence query release probe clone failed");
          release_complete = 1'b0;
        end
        else
          release_mapping_fenced(binding, expected_owner, release_probe,
                                 "QP presence query", release_status,
                                 release_complete);
      end
      if (!release_status.ok() || !release_complete) begin
        if (status.ok() || conclusive)
          status = rdma_status::make(
            RDMA_SC_RECOVERY_REQUIRED,
            "QP presence query mapping release remains incomplete");
        else if (status == null)
          status = release_status;
      end
      else if (fresh_mapping)
        query_mapping = null;
    end
  endtask

  // 功能：make_opcode_key 把 opcode、variant 与当前对象的身份/状态字段编码为稳定文本，供日志、查找或恢复索引使用。
  // 输入/输出及副作用：opcode（输入）、variant（输入）；make_opcode_key 读取 opcode、variant 并使用字段 key、key.profile_name、key.opcode、key.variant；函数返回 rdma_cmq_opcode_key，不取得调用方资源所有权。
// 失败/边界：make_opcode_key 只按函数体列出的身份、generation、kind、object_id 或 cursor 字段拼接键；调用方须先完成空句柄校验，函数本身不分配资源、不自动回退到 root0。
  protected function rdma_cmq_opcode_key make_opcode_key(
    bit [7:0] opcode, string variant
  );
    rdma_cmq_opcode_key key;
    key = rdma_cmq_opcode_key::type_id::create({"qp_", variant, "_opcode"});
    key.profile_name = "rdma";
    key.opcode = opcode;
    key.variant = variant;
    return key;
  endfunction

  // 功能：build_qpc_command 创建独立的 rdma_status；根据 owner、model、staging、image、opcode、command 设置字段 command、body、body.qp_h、body.send_cq_h、body.recv_cq_h、qpc_buffer.value、body.next_state、body.full_modify、body.wbe_template_count、command.function_h，返回对象仅由调用方持有，不转移外部资源所有权。
  // 输入/输出及副作用：owner（输入）、model（输入）、staging（输入）、image（输入）、opcode（输入）、command（输出）；输入字段被复制到返回值或
  //   output；生成结果与输入隔离，不隐式修改调用方对象。
  // 失败/边界：build_qpc_command 返回 RDMA_SC_INVALID_ARGUMENT；典型拒绝条件为“QP command authority is incomplete”“QPC_CREATE staging mapping is null”；失败路径不提交部分状态或转移未声明资源。
  protected virtual function rdma_status build_qpc_command(
    rdma_function_handle owner,
    rdma_qpc_model model,
    rdma_dma_mapping staging,
    rdma_hw_image image,
    bit [7:0] opcode,
    output rdma_cmq_command_desc command
  );
    rdma_hw_qpc_command_body body;

    command = null;
    if (owner == null || model == null || model.qp_h == null)
      return invalid_argument("QP command authority is incomplete");
    body = rdma_hw_qpc_command_body::type_id::create("qp_command_body");
    body.qp_h = rdma_clone_handle_value(model.qp_h, "QP command QPN");
    if (opcode inside {RDMA_OP_QPC_CREATE, RDMA_OP_QPC_MODIFY,
                       RDMA_OP_QPC_DELETE}) begin
      body.send_cq_h = rdma_clone_handle_value(model.send_cq_h,
                                               "QP command send CQN");
      body.recv_cq_h = rdma_clone_handle_value(model.recv_cq_h,
                                               "QP command receive CQN");
    end
    if (opcode == RDMA_OP_QPC_CREATE) begin
      if (staging == null)
        return invalid_argument("QPC_CREATE staging mapping is null");
      body.qpc_buffer.value = staging.iova.value;
      body.next_state = RDMA_QPS_RESET;
    end
    else if (opcode == RDMA_OP_QPC_MODIFY) begin
      body.next_state = model.state;
      if (staging != null) begin
        body.qpc_buffer.value = staging.iova.value;
        body.full_modify = 1'b1;
        case (model.transport)
          RDMA_TRANSPORT_RC,
          RDMA_TRANSPORT_UD: body.wbe_template_count = 0;
          RDMA_TRANSPORT_URC: body.wbe_template_count = 1;
          default: return invalid_argument("QP modify transport is unsupported");
        endcase
      end
    end
    command = rdma_cmq_command_desc::type_id::create("qp_command");
    command.function_h = rdma_clone_function_handle_value(owner,
                                                           "QP command");
    command.opcode_key = make_opcode_key(
      opcode, opcode == RDMA_OP_QPC_CREATE ? "create" :
              opcode == RDMA_OP_QPC_MODIFY ? "modify" : "delete"
    );
    command.body = body;
    command.qpc_signature_source =
      opcode inside {RDMA_OP_QPC_CREATE, RDMA_OP_QPC_MODIFY} &&
      staging != null ? image : null;
    command.timeout = command_timeout;
    return normalize_status(command.validate(),
                            "QP command validation returned null");
  endfunction

  // 功能：build_occ_command 为 QP 回滚或销毁构造 canonical OCC_FLUSH
  //   命令；QPN 路径选择 EIRQE/ORQE/UAQE，PD 路径只选择 PD backing。
  // 输入/输出及副作用：owner（输入）、local_qpn（输入）、pd_ref（输入）、command（输出）；build_occ_command 读取 owner、local_qpn、pd_ref、command 并使用字段 command、body、body.qpn、body.eirqe、body.orqe、body.uaqe、body.pd、pd_backing.value，并写入 command；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：owner 为空、local_qpn 超过 21 bit、PD mapping 为空或
  //   canonical body/command 校验失败时返回错误；QPN 0 是驱动保留的合法
  //   SMI QP 标识，不能借 subtype 绕过 profile exact-type 门禁。
  protected function rdma_status build_occ_command(
    rdma_function_handle owner,
    int unsigned local_qpn,
    rdma_qp_backing_ref pd_ref,
    output rdma_cmq_command_desc command
  );
    rdma_hw_occ_flush_body body;

    command = null;
    if (owner == null || local_qpn > 21'h1f_ffff)
      return invalid_argument("QP OCC authority is invalid");
    // profile 只快照 exact canonical body；QP 层不得再创建带自定义
    // validate() 的派生类型，否则 mock/production 共用的快照边界会拒绝命令。
    body = rdma_hw_occ_flush_body::type_id::create("qp_occ_body");
    body.qpn = local_qpn;
    if (pd_ref == null) begin
      body.eirqe = 1'b1;
      body.orqe = 1'b1;
      body.uaqe = 1'b1;
    end else begin
      if (pd_ref.mapping == null)
        return invalid_argument("QP OCC PD mapping is null");
      body.pd = 1'b1;
      body.pd_backing.value = pd_ref.mapping.iova.value +
                              pd_ref.mapping_offset;
    end
    command = rdma_cmq_command_desc::type_id::create("qp_occ_command");
    command.function_h = rdma_clone_function_handle_value(owner,
                                                           "QP OCC command");
    command.opcode_key = make_opcode_key(RDMA_OP_OCC_FLUSH, "occ_flush");
    command.body = body;
    command.timeout = command_timeout;
    return normalize_status(command.validate(),
                            "QP OCC command validation returned null");
  endfunction

  // 功能：append_rollback_status 校验 result、status 与当前对象状态的一致性，返回 void 供上层决定是否提交。
  // 输入/输出及副作用：result（输入）、status（输入）；append_rollback_status 可能更新本对象明确拥有的状态；函数返回 void，不取得调用方资源所有权。
  // 失败/边界：append_rollback_status 无返回值，仅执行 函数体中的顺序操作；调用方须保证前置依赖已经绑定，函数不自动重试或接管外部资源。
  protected function void append_rollback_status(
    rdma_control_result result, rdma_status status
  );
    if (result != null && status != null && !status.ok())
      result.rollback_statuses.push_back(rdma_cmq_clone_status_value(status));
  endfunction

  // 功能：在 rdma_qp_lifecycle_executor 中，release_mapping_opaque 按 owner、generation 和幂等规则释放/隔离记录，并同步删除其账本引用。
  // 输入/输出及副作用：mapping（输入）、label（输入）、release_complete（输出）；输入 handle/mapping/token 指定释放目标；成功时更新账本和生命周期，外部资源只按 adapter
  //   契约释放。
  // 失败/边界：release_mapping_opaque 发现 owner/generation 不匹配、记录未知或重复释放时返回错误或幂等结果，不重新激活旧句柄。
  protected function rdma_status release_mapping_opaque(
    rdma_dma_mapping mapping,
    string label,
    output bit release_complete
  );
    rdma_status status;
    rdma_status completion_status;

    release_complete = 1'b0;
    if (mapping == null)
      return invalid_argument({label, " mapping is null"});
    completion_status = normalize_status(
      mapping.release_completion_status(release_complete),
      {label, " pre-release completion query returned null"}
    );
    if (!completion_status.ok() || release_complete)
      return completion_status;
    status = normalize_status(host_mem.\release (mapping),
                              {label, " release returned null"});
    completion_status = normalize_status(
      mapping.release_completion_status(release_complete),
      {label, " completion query returned null"}
    );
    if (!completion_status.ok())
      return completion_status;
    if (release_complete)
      return rdma_status::success();
    if (!status.ok())
      return status;
    return rdma_status::make(RDMA_SC_RECOVERY_REQUIRED,
                             {label, " release is incomplete"});
  endfunction

  // 功能：在 rdma_qp_lifecycle_executor 中，release_context_opaque 按 owner、generation 和幂等规则释放/隔离记录，并同步删除其账本引用。
  // 输入/输出及副作用：context_ref（输入）、label（输入）、release_complete（输出）；输入 handle/mapping/token 指定释放目标；成功时更新账本和生命周期，外部资源只按
  //   adapter 契约释放。
  // 失败/边界：release_context_opaque 发现 owner/generation 不匹配、记录未知或重复释放时返回错误或幂等结果，不重新激活旧句柄。
  protected function rdma_status release_context_opaque(
    rdma_context_backing_ref context_ref,
    string label,
    output bit release_complete
  );
    rdma_status status;
    rdma_status completion_status;

    release_complete = 1'b0;
    if (context_ref == null)
      return invalid_argument({label, " context is null"});
    completion_status = normalize_status(
      context_backing.query_release_completion(context_ref, release_complete),
      {label, " pre-release completion query returned null"}
    );
    if (!completion_status.ok() || release_complete)
      return completion_status;
    status = normalize_status(context_backing.\release (context_ref),
                              {label, " release returned null"});
    completion_status = normalize_status(
      context_backing.query_release_completion(context_ref, release_complete),
      {label, " completion query returned null"}
    );
    if (!completion_status.ok())
      return completion_status;
    if (release_complete)
      return rdma_status::success();
    if (!status.ok())
      return status;
    return rdma_status::make(RDMA_SC_RECOVERY_REQUIRED,
                             {label, " release is incomplete"});
  endfunction

  // 功能：在 rdma_qp_lifecycle_executor 中，release_ref_local 按 owner、generation 和幂等规则释放/隔离记录，并同步删除其账本引用。
  // 输入/输出及副作用：backing_ref（输入）、result（输入）；输入 handle/mapping/token 指定释放目标；成功时更新账本和生命周期，外部资源只按 adapter 契约释放。
  // 失败/边界：release_ref_local 发现 owner/generation 不匹配、记录未知或重复释放时返回错误或幂等结果，不重新激活旧句柄。
  protected function rdma_status release_ref_local(
    rdma_qp_backing_ref backing_ref,
    rdma_control_result result
  );
    rdma_status status;
    bit release_complete;
    if (backing_ref == null ||
        backing_ref.ownership == RDMA_OWNERSHIP_BORROWED)
      return rdma_status::success();
    if (backing_ref.cleanup_complete)
      return rdma_status::success();
    if (backing_ref.mapping == null)
      return invalid_state("QP owned backing mapping is missing");
    status = release_mapping_opaque(backing_ref.mapping,
                                    "QP backing", release_complete);
    if (release_complete)
      backing_ref.cleanup_complete = 1'b1;
    append_rollback_status(result, status);
    return status;
  endfunction

  // 功能：在 rdma_qp_lifecycle_executor 中，release_partial_plan 按 owner、generation 和幂等规则释放/隔离记录，并同步删除其账本引用。
  // 输入/输出及副作用：plan（输入）、result（输入）；输入 handle/mapping/token 指定释放目标；成功时更新账本和生命周期，外部资源只按 adapter 契约释放。
  // 失败/边界：release_partial_plan 发现 owner/generation 不匹配、记录未知或重复释放时返回错误或幂等结果，不重新激活旧句柄。
  protected function rdma_status release_partial_plan(
    rdma_qp_backing_plan plan,
    rdma_control_result result
  );
    rdma_status status;
    rdma_status step_status;
    bit release_complete;

    status = rdma_status::success();
    if (plan == null)
      return status;
    if (plan.context_ref != null && !plan.context_ref.release_complete) begin
      step_status = release_context_opaque(plan.context_ref,
                                           "QP context", release_complete);
      if (release_complete)
        plan.context_ref.release_complete = 1'b1;
      append_rollback_status(result, step_status);
      if (status.ok() && !step_status.ok()) status = step_status;
      if (!step_status.ok()) return status;
    end
    for (int i = plan.urc_refs.size() - 1; i >= 0; i--) begin
      step_status = release_ref_local(plan.urc_refs[i], result);
      if (status.ok() && !step_status.ok()) status = step_status;
      if (!step_status.ok()) return status;
    end
    step_status = release_ref_local(plan.rq_pd_ref, result);
    if (status.ok() && !step_status.ok()) status = step_status;
    if (!step_status.ok()) return status;
    step_status = release_ref_local(plan.sq_pd_ref, result);
    if (status.ok() && !step_status.ok()) status = step_status;
    if (!step_status.ok()) return status;
    step_status = release_ref_local(plan.rq_ref, result);
    if (status.ok() && !step_status.ok()) status = step_status;
    if (!step_status.ok()) return status;
    step_status = release_ref_local(plan.sq_sgb_ref, result);
    if (status.ok() && !step_status.ok()) status = step_status;
    if (!step_status.ok()) return status;
    step_status = release_ref_local(plan.sq_ref, result);
    if (status.ok() && !step_status.ok()) status = step_status;
    return status;
  endfunction

  // 功能：在 rdma_qp_lifecycle_executor 中，publish_primary 提交当前事务阶段并发布 detached 结果，只有成功路径才推进游标或状态。
  // 输入/输出及副作用：result（输入）、primary（输入）；输入 request/image/cursor 决定写入内容；成功时更新 PI/CI、slot ledger 或 pending journal，并通过
  //   output 返回结果。
  // 失败/边界：队列未激活、credit 不足、请求身份过期或后端写入失败时返回错误；不得提前推进游标或重复提交。
  protected function void publish_primary(
    rdma_control_result result,
    rdma_status primary
  );
    rdma_status normalized;
    normalized = normalize_status(primary, "QP create primary status is null");
    result.primary_status = rdma_cmq_clone_status_value(normalized);
    result.status = rdma_cmq_clone_status_value(normalized);
  endfunction

  // 功能：make_create_recovery 组装 QP CREATE 的临时恢复证据，并设置 intent、
  //       ambiguity、QPC/staging、opcode key 和 ticket；qp_plan、context_ref 与
  //       candidate_qpc 在此阶段仍是输入对象的借用句柄，最终独立快照由
  //       manager.mark_qp_error 的 authority-aware projector 建立。
  // 输入/输出及副作用：plan、candidate_qpc、staging、ambiguous_operation、
  //       ambiguous_role、ticket（输入），recovery（输出）；函数只创建本地
  //       recovery shell，不释放或接管 backing/mapping/context/QPC，且在交给
  //       manager 前禁止调用方修改这些借用对象。
  // 失败/边界：恢复 shell 创建、opcode/ticket clone 或 recovery.validate 失败时
  //       返回相应 status；通用 plan.clone 不能替代 authority-aware projection，
  //       否则可能丢失 opaque mapping release authority。
  protected function rdma_status make_create_recovery(
    rdma_qp_backing_plan plan,
    rdma_qpc_model candidate_qpc,
    rdma_dma_mapping staging,
    rdma_qp_ambiguous_operation_e ambiguous_operation,
    rdma_queue_backing_role_e ambiguous_role,
    rdma_cmq_ticket ticket,
    output rdma_qp_recovery_state recovery
  );
    recovery = rdma_qp_recovery_state::type_id::create("qp_create_recovery");
    recovery.intent = RDMA_QP_RECOVER_CREATE_ROLLBACK;
    recovery.ambiguous_operation = ambiguous_operation;
    recovery.ambiguous_role = ambiguous_role;
    recovery.candidate_qpc = candidate_qpc;
    recovery.qp_plan = plan;
    recovery.context_ref = plan == null ? null : plan.context_ref;
    recovery.staging_mapping = staging;
    recovery.create_opcode = make_opcode_key(RDMA_OP_QPC_CREATE, "create");
    recovery.modify_opcode = make_opcode_key(RDMA_OP_QPC_MODIFY, "modify");
    recovery.delete_opcode = make_opcode_key(RDMA_OP_QPC_DELETE, "delete");
    recovery.query_opcode = make_opcode_key(RDMA_OP_QPC_QUERY, "query");
    recovery.occ_opcode = make_opcode_key(RDMA_OP_OCC_FLUSH, "occ_flush");
    recovery.ambiguous_ticket = rdma_cmq_clone_ticket_value(ticket,
                                                            "QP create recovery");
    return normalize_status(recovery.validate(),
                            "QP create recovery validation returned null");
  endfunction

  // 功能：make_modify_recovery 组合 QP MODIFY 的临时恢复 shell，记录 prior/
  //       candidate QPC、authoritative plan/context、staging/query mapping、
  //       query-only 标志和重放 opcode；shell 仅供随后 mark_qp_error 投影。
  // 输入/输出及副作用：authoritative、prior_qpc、candidate_qpc、staging、
  //       query_mapping、query_mapping_recovery_only、ticket（输入），recovery
  //       （输出）；qp_plan/context_ref/QPC/mapping 均暂借输入句柄，不取得外部
  //       资源所有权，也不在此阶段修改 authoritative resource。
  // 失败/边界：authoritative、plan/context、prior/candidate QPC 缺失时返回
  //       RDMA_SC_INVALID_ARGUMENT；ticket/clone/validate 失败时返回对应错误；
  //       在 manager authority-aware projection 完成前不得保留或并发修改 shell。
  protected function rdma_status make_modify_recovery(
    rdma_qp authoritative,
    rdma_qpc_model prior_qpc,
    rdma_qpc_model candidate_qpc,
    rdma_dma_mapping staging,
    rdma_dma_mapping query_mapping,
    bit query_mapping_recovery_only,
    rdma_cmq_ticket ticket,
    output rdma_qp_recovery_state recovery
  );
    recovery = rdma_qp_recovery_state::type_id::create("qp_modify_recovery");
    if (authoritative == null || authoritative.qp_plan == null ||
        authoritative.qp_plan.context_ref == null || prior_qpc == null ||
        candidate_qpc == null)
      return invalid_argument("QP modify recovery authority is incomplete");
    recovery.intent = RDMA_QP_RECOVER_MODIFY_RECONCILE;
    recovery.ambiguous_operation = RDMA_QP_AMBIG_MODIFY;
    recovery.ambiguous_role = RDMA_QUEUE_ROLE_QP_SQ_RING;
    recovery.prior_qpc = prior_qpc;
    recovery.candidate_qpc = candidate_qpc;
    recovery.qp_plan = authoritative.qp_plan;
    recovery.context_ref = authoritative.qp_plan.context_ref;
    recovery.staging_mapping = staging;
    recovery.query_mapping = query_mapping;
    recovery.query_mapping_recovery_only = query_mapping_recovery_only;
    recovery.create_opcode = make_opcode_key(RDMA_OP_QPC_CREATE, "create");
    recovery.modify_opcode = make_opcode_key(RDMA_OP_QPC_MODIFY, "modify");
    recovery.delete_opcode = make_opcode_key(RDMA_OP_QPC_DELETE, "delete");
    recovery.query_opcode = make_opcode_key(RDMA_OP_QPC_QUERY, "query");
    recovery.occ_opcode = make_opcode_key(RDMA_OP_OCC_FLUSH, "occ_flush");
    recovery.ambiguous_ticket = rdma_cmq_clone_ticket_value(
      ticket, "QP modify recovery"
    );
    if (ticket == null)
      recovery.has_pending_hardware_step = 1'b1;
    return normalize_status(recovery.validate(),
                            "QP modify recovery validation returned null");
  endfunction

  // 功能：执行 retain_modify_recovery 指定的测试或恢复状态变更，更新受控账本并保留可回滚的故障证据。
  // 输入/输出及副作用：authoritative（输入）、prior_qpc（输入）、candidate_qpc（输入）、staging（输入）、query_mapping（输入）、query_mapping_recovery_only（输入）、ticket（输入）、primary（输入）、result（输出）；retain_modify_recovery 驱动下游事务，并写入 result；函数返回 无直接返回值，不取得调用方资源所有权。
  // 失败/边界：retain_modify_recovery 仅允许测试/恢复范围内的状态变更；代际或资源不匹配时拒绝并保留原账本。
  protected task retain_modify_recovery(
    rdma_qp authoritative,
    rdma_qpc_model prior_qpc,
    rdma_qpc_model candidate_qpc,
    rdma_dma_mapping staging,
    rdma_dma_mapping query_mapping,
    bit query_mapping_recovery_only,
    rdma_cmq_ticket ticket,
    rdma_status primary,
    output rdma_control_result result
  );
    rdma_qp_recovery_state recovery;
    rdma_status status;
    rdma_status primary_copy;

    primary_copy = normalize_status(primary, "QP modify primary status is null");
    if (result == null)
      result = rdma_control_result::type_id::create("qp_modify_recovery_result");
    if (authoritative == null) begin
      publish_primary(result, invalid_state("QP modify recovery target is null"));
      return;
    end
    status = make_modify_recovery(authoritative, prior_qpc, candidate_qpc,
                                  staging, query_mapping,
                                  query_mapping_recovery_only, ticket,
                                  recovery);
    if (status.ok())
      status = normalize_status(manager.mark_qp_error(authoritative.handle,
                                                       recovery),
                                "QP modify ERROR publication returned null");
    result.resource_h = rdma_clone_handle_value(authoritative.handle,
                                                "QP modify recovery handle");
    result.final_resource_state = RDMA_RESOURCE_ERROR;
    result.final_resource_state_known = status.ok();
    result.recovery_required = status.ok();
    if (status.ok()) begin
      result.primary_status = rdma_cmq_clone_status_value(primary_copy);
      result.status = rdma_status::make(RDMA_SC_RECOVERY_REQUIRED,
                                        "QP modify outcome is ambiguous");
    end
    else begin
      append_rollback_status(result, status);
      publish_primary(result, primary_copy);
    end
  endtask

  // 功能：在 rdma_qp_lifecycle_executor 中，execute_terminal_command 执行受控事务并按后端提交证据推进状态机，同时保留失败阶段和 generation 证据。
  // 输入/输出及副作用：binding（输入）、expected_owner（输入）、command（输入）、status（输出）、ambiguous（输出）、recovery_ticket（输出）；execute_terminal_command 驱动下游事务，并写入 status、ambiguous、recovery_ticket；函数返回 无直接返回值，不取得调用方资源所有权。
  // 失败/边界：execute_terminal_command 遇到锁、超时、generation 变化或提交证据不完整时保持原状态，不推进游标。
  protected task execute_terminal_command(
    rdma_function_binding binding,
    rdma_function_handle expected_owner,
    rdma_cmq_command_desc command,
    output rdma_status status,
    output bit ambiguous,
    output rdma_cmq_ticket recovery_ticket
  );
    rdma_cmq_ticket ticket;
    rdma_cmq_completion completion;
    rdma_status fence_status;

    ambiguous = 1'b0;
    recovery_ticket = null;
    ticket = null;
    completion = null;
    status = live_binding_fence(binding, expected_owner);
    if (!status.ok())
      return;
    status = null;
    execute_qp_legacy_command(command, ticket, completion, status);
    ambiguous = cmq_outcome_ambiguous(status, ticket, completion);
    recovery_ticket = ticket;
    if (recovery_ticket == null && completion != null)
      recovery_ticket = completion.ticket;
    fence_status = live_binding_fence(binding, expected_owner);
    if (!fence_status.ok()) begin
      status = fence_status;
      ambiguous = 1'b1;
      return;
    end
    status = normalize_status(status, "QP rollback command returned null");
    if (status.ok() &&
        (ticket == null || completion == null || completion.status == null))
      status = invalid_state("QP rollback command completion is incomplete");
  endtask

  // 功能：在 rdma_qp_lifecycle_executor 中，cleanup_attached_qp 按 owner、generation 和幂等规则释放或清理资源，同时删除相关账本记录。
  // 输入/输出及副作用：binding（输入）、expected_owner（输入）、candidate（输入）、plan（输入）、model（输入）、hardware_present（输入）、primary（输入）、result（输入）、released（输出）；cleanup_attached_qp 驱动下游事务，并写入 released；函数返回 无直接返回值，不取得调用方资源所有权。
  // 失败/边界：cleanup_attached_qp 返回 RDMA_SC_RECOVERY_REQUIRED；典型拒绝条件为“QP OCC rollback requires recovery”“QP delete rollback requires recovery”；失败路径不提交部分状态或转移未声明资源。
  protected task cleanup_attached_qp(
    rdma_function_binding binding,
    rdma_function_handle expected_owner,
    rdma_qp candidate,
    rdma_qp_backing_plan plan,
    rdma_qpc_model model,
    bit hardware_present,
    rdma_status primary,
    rdma_control_result result,
    output bit released
  );
    rdma_qp_recovery_state recovery;
    rdma_cmq_command_desc command;
    rdma_status status;
    rdma_status step_status;
    rdma_status release_status;
    rdma_status fence_status;
    rdma_queue_backing_role_e roles[$];
    rdma_qp_backing_ref refs[$];
    rdma_cmq_ticket recovery_ticket;
    bit ambiguous;
    bit release_complete;

    released = 1'b0;
    status = make_create_recovery(plan, hardware_present ? model : null,
                                  null, RDMA_QP_AMBIG_NONE,
                                  RDMA_QUEUE_ROLE_QP_SQ_RING, null, recovery);
    if (status.ok())
      status = normalize_status(manager.mark_qp_error(candidate.handle, recovery),
                                "QP rollback ERROR publication returned null");
    if (!status.ok()) begin
      append_rollback_status(result, status);
      result.final_resource_state = RDMA_RESOURCE_PROGRAMMED;
      result.final_resource_state_known = 1'b1;
      return;
    end
    result.final_resource_state = RDMA_RESOURCE_ERROR;
    result.final_resource_state_known = 1'b1;

    roles.push_back(RDMA_QUEUE_ROLE_QP_SQ_RING);
    roles.push_back(RDMA_QUEUE_ROLE_QP_SQ_PD);
    if (plan.rq_source_h == null)
      roles.push_back(RDMA_QUEUE_ROLE_QP_RQ_PD);
    foreach (roles[i]) begin
      step_status = rdma_status::success();
      if (hardware_present) begin
        case (roles[i])
          RDMA_QUEUE_ROLE_QP_SQ_RING:
            step_status = build_occ_command(expected_owner,
              candidate.local_qp_id, null, command);
          RDMA_QUEUE_ROLE_QP_SQ_PD:
            step_status = build_occ_command(expected_owner,
              candidate.local_qp_id, plan.sq_pd_ref, command);
          default:
            step_status = build_occ_command(expected_owner,
              candidate.local_qp_id, plan.rq_pd_ref, command);
        endcase
        if (step_status.ok())
          execute_terminal_command(binding, expected_owner, command,
                                   step_status, ambiguous, recovery_ticket);
        if (ambiguous) begin
          recovery.ambiguous_operation = RDMA_QP_AMBIG_OCC_FLUSH;
          recovery.ambiguous_role = roles[i];
          recovery.ambiguous_ticket = rdma_cmq_clone_ticket_value(
            recovery_ticket, "QP OCC rollback recovery"
          );
          status = normalize_status(
            manager.mark_qp_error(candidate.handle, recovery),
            "QP OCC ambiguity publication returned null"
          );
          if (!status.ok())
            append_rollback_status(result, status);
          result.primary_status = rdma_cmq_clone_status_value(primary);
          result.status = rdma_status::make(
            RDMA_SC_RECOVERY_REQUIRED, "QP OCC rollback requires recovery"
          );
          result.recovery_required = 1'b1;
          return;
        end
      end
      if (step_status.ok())
        step_status = normalize_status(manager.record_qp_flush_complete(
          candidate.handle, roles[i]), "QP rollback flush progress returned null");
      if (!step_status.ok()) begin
        append_rollback_status(result, step_status);
        return;
      end
      recovery.role_complete[roles[i]] = 1'b1;
      case (roles[i])
        RDMA_QUEUE_ROLE_QP_SQ_RING:
          recovery.qp_plan.cleanup_complete = 1'b1;
        RDMA_QUEUE_ROLE_QP_SQ_PD:
          recovery.qp_plan.sq_pd_flush_complete = 1'b1;
        RDMA_QUEUE_ROLE_QP_RQ_PD:
          recovery.qp_plan.rq_pd_flush_complete = 1'b1;
        default:;
      endcase
    end
    if (hardware_present) begin
      step_status = build_qpc_command(expected_owner, model, null, null,
                                      RDMA_OP_QPC_DELETE, command);
      if (step_status.ok())
        execute_terminal_command(binding, expected_owner, command, step_status,
                                 ambiguous, recovery_ticket);
      if (ambiguous) begin
        recovery.ambiguous_operation = RDMA_QP_AMBIG_DELETE;
        recovery.ambiguous_role = RDMA_QUEUE_ROLE_QP_SQ_RING;
        recovery.ambiguous_ticket = rdma_cmq_clone_ticket_value(
          recovery_ticket, "QP delete rollback recovery"
        );
        status = normalize_status(
          manager.mark_qp_error(candidate.handle, recovery),
          "QP delete ambiguity publication returned null"
        );
        if (!status.ok())
          append_rollback_status(result, status);
        result.primary_status = rdma_cmq_clone_status_value(primary);
        result.status = rdma_status::make(
          RDMA_SC_RECOVERY_REQUIRED, "QP delete rollback requires recovery"
        );
        result.recovery_required = 1'b1;
        return;
      end
      if (!step_status.ok()) begin
        append_rollback_status(result, step_status);
        return;
      end
    end

    step_status = live_binding_fence(binding, expected_owner);
    if (step_status.ok()) begin
      release_status = release_context_opaque(
        plan.context_ref, "QP rollback context", release_complete
      );
      fence_status = live_binding_fence(binding, expected_owner);
      if (!fence_status.ok())
        step_status = fence_status;
      else if (!release_status.ok())
        step_status = release_status;
      else
        step_status = normalize_status(
          manager.record_qp_context_cleanup_complete(candidate.handle),
          "QP rollback context progress returned null"
        );
    end
    if (!step_status.ok()) begin
      append_rollback_status(result, step_status);
      return;
    end

    for (int i = plan.urc_refs.size() - 1; i >= 0; i--)
      refs.push_back(plan.urc_refs[i]);
    refs.push_back(plan.rq_pd_ref);
    refs.push_back(plan.sq_pd_ref);
    refs.push_back(plan.rq_ref);
    refs.push_back(plan.sq_ref);
    refs.push_back(plan.sq_sgb_ref);
    foreach (refs[i]) begin
      if (refs[i] == null || refs[i].ownership == RDMA_OWNERSHIP_BORROWED)
        continue;
      step_status = live_binding_fence(binding, expected_owner);
      if (step_status.ok()) begin
        release_status = release_mapping_opaque(
          refs[i].mapping, "QP rollback backing", release_complete
        );
        fence_status = live_binding_fence(binding, expected_owner);
        if (!fence_status.ok())
          step_status = fence_status;
        else if (!release_status.ok())
          step_status = release_status;
        else
          step_status = normalize_status(manager.record_qp_cleanup_complete(
            candidate.handle, refs[i].role),
            "QP rollback backing progress returned null");
      end
      if (!step_status.ok()) begin
        append_rollback_status(result, step_status);
        return;
      end
    end
    status = normalize_status(manager.finalize_qp_release(candidate.handle),
                              "QP rollback finalization returned null");
    if (!status.ok()) begin
      append_rollback_status(result, status);
      return;
    end
    result.final_resource_state = RDMA_RESOURCE_RELEASED;
    result.final_resource_state_known = 1'b1;
    released = 1'b1;
  endtask

  // 功能：在 rdma_qp_lifecycle_executor 中，rollback_unattached_qp 按 owner、generation 和幂等规则释放/隔离记录，并同步删除其账本引用。
  // 输入/输出及副作用：candidate（输入）、plan（输入）、staging（输入）、primary（输入）、result（输入）；输入 handle/mapping/token
  //   指定释放目标；成功时更新账本和生命周期，外部资源只按 adapter 契约释放。
  // 失败/边界：rollback_unattached_qp 发现 owner/generation 不匹配、记录未知或重复释放时返回错误或幂等结果，不重新激活旧句柄。
  protected task rollback_unattached_qp(
    rdma_qp candidate,
    rdma_qp_backing_plan plan,
    rdma_dma_mapping staging,
    rdma_status primary,
    rdma_control_result result
  );
    rdma_status cleanup_status;
    cleanup_status = release_partial_plan(plan, result);
    if (!cleanup_status.ok()) begin
      append_rollback_status(result, cleanup_status);
      retain_create_recovery(
        candidate, plan, null, staging, RDMA_QP_AMBIG_NONE,
        RDMA_QUEUE_ROLE_QP_SQ_RING, null, primary, result
      );
      return;
    end
    if (candidate != null && candidate.handle != null)
      cleanup_status = normalize_status(manager.finalize_qp_release(
        candidate.handle), "QP reservation finalization returned null");
    if (!cleanup_status.ok()) begin
      append_rollback_status(result, cleanup_status);
      publish_primary(result, primary);
      return;
    end
    if (candidate != null) begin
      result.final_resource_state = RDMA_RESOURCE_RELEASED;
      result.final_resource_state_known = 1'b1;
    end
    publish_primary(result, primary);
  endtask

  // 功能：执行 retain_create_recovery 指定的测试或恢复状态变更，更新受控账本并保留可回滚的故障证据。
  // 输入/输出及副作用：candidate（输入）、plan（输入）、model（输入）、staging（输入）、ambiguous_operation（输入）、ambiguous_role（输入）、ticket（输入）、primary（输入）、result（输入）；retain_create_recovery 驱动下游事务；函数返回 无直接返回值，不取得调用方资源所有权。
  // 失败/边界：retain_create_recovery 仅允许测试/恢复范围内的状态变更；代际或资源不匹配时拒绝并保留原账本。
  protected task retain_create_recovery(
    rdma_qp candidate,
    rdma_qp_backing_plan plan,
    rdma_qpc_model model,
    rdma_dma_mapping staging,
    rdma_qp_ambiguous_operation_e ambiguous_operation,
    rdma_queue_backing_role_e ambiguous_role,
    rdma_cmq_ticket ticket,
    rdma_status primary,
    rdma_control_result result
  );
    rdma_qp_recovery_state recovery;
    rdma_status status;

    status = make_create_recovery(plan, model, staging, ambiguous_operation,
                                  ambiguous_role, ticket, recovery);
    if (status.ok())
      status = normalize_status(manager.mark_qp_error(candidate.handle, recovery),
                                "QP create recovery publication returned null");
    if (!status.ok()) begin
      append_rollback_status(result, status);
      publish_primary(result, primary);
      return;
    end
    result.primary_status = rdma_cmq_clone_status_value(primary);
    result.status = rdma_status::make(RDMA_SC_RECOVERY_REQUIRED,
                                      "QP create requires recovery");
    result.final_resource_state = RDMA_RESOURCE_ERROR;
    result.final_resource_state_known = 1'b1;
    result.recovery_required = 1'b1;
  endtask

  // 功能：create_locked 创建独立的 无直接返回值；根据 binding、expected_owner、request、transaction_id、qp、result 设置字段 qp、result、result.transaction_id、result.primary_status、result.status、result.final_resource_state、result.final_resource_state_known、result.recovery_required、candidate、plan，返回对象仅由调用方持有，不转移外部资源所有权。
  // 输入/输出及副作用：binding（输入）、expected_owner（输入）、request（输入）、transaction_id（输入）、qp（输出）、result（输出）；输入请求/句柄定义资源属性；成功时更新账本并通过返回值或
  //   output 发布新句柄/映射。
  // 失败/边界：create_locked 返回 RDMA_SC_TIMEOUT、RDMA_SC_RESET_CANCELLED、RDMA_SC_STALE_GENERATION、RDMA_SC_RECOVERY_REQUIRED；具体拒绝条件包括 “QP unattached rollback requires recovery”；“QP command-build rollback requires recovery”；“QP definitive-create rollback requires recovery”；“QP activation rollback requires recovery”；失败路径不提交部分状态、不隐式重试，也不转移未声明资源。
  task create_locked(
    rdma_function_binding binding,
    rdma_function_handle expected_owner,
    rdma_create_qp_req request,
    longint unsigned transaction_id,
    output rdma_qp qp,
    output rdma_control_result result
  );
    rdma_status status;
    rdma_status primary;
    rdma_status fence_status;
    rdma_status release_status;
    rdma_qp candidate;
    rdma_qp_backing_plan plan;
    rdma_qpc_model model;
    rdma_function_binding binding_snapshot;
    rdma_pd qpc_pd;
    rdma_cq qpc_send_cq;
    rdma_cq qpc_recv_cq;
    rdma_srq qpc_srq;
    rdma_dma_mapping staging;
    rdma_hw_image image;
    rdma_resource published;
    uvm_object detached_object;
    uvm_object cloned_binding_object;
    rdma_cmq_command_desc command;
    rdma_cmq_ticket ticket;
    rdma_cmq_ticket recovery_ticket;
    rdma_cmq_completion completion;
    byte unsigned context_bytes[];
    bit ambiguous;
    bit attached;
    bit released;
    bit release_complete;
    bit [7:0] qpc_sequence_value;

    qp = null;
    result = make_result(
      transaction_id,
      "qp_create_result",
      "QP create did not complete"
    );
    candidate = null;
    plan = null;
    staging = null;
    image = null;
    command = null;
    binding_snapshot = null;
    qpc_pd = null;
    qpc_send_cq = null;
    qpc_recv_cq = null;
    qpc_srq = null;
    qpc_sequence_value = '0;
    attached = 1'b0;
    if (transaction_id == 0) begin
      publish_primary(result, invalid_argument("QP transaction ID is zero"));
      return;
    end
    if (binding == null || expected_owner == null || request == null ||
        manager == null || cmq == null || host_mem == null ||
        context_backing == null) begin
      result.status = invalid_state("QP executor is not configured");
      result.primary_status = invalid_state("QP executor is not configured");
      return;
    end
    status = live_binding_fence(binding, expected_owner);
    if (status.ok()) begin
      cloned_binding_object = binding.clone();
      if (cloned_binding_object == null ||
          !$cast(binding_snapshot, cloned_binding_object) ||
          binding_snapshot.make_handle() == null ||
          !binding_snapshot.make_handle().same_instance(expected_owner))
        status = invalid_state("QP binding snapshot is invalid");
    end
    if (status.ok() && (request.owner == null ||
        !request.owner.same_instance(expected_owner)))
      status = invalid_argument("QP request owner does not match binding");
    if (status.ok()) status = normalize_status(request.validate(),
      "QP request validation returned null");
    if (status.ok()) status = request.validate_queue_caps(binding.queue_caps);
    if (status.ok()) status = manager.create_qp(binding, request.pd_h,
      request.send_cq_h, request.recv_cq_h, request.srq_h, candidate);
    if (!status.ok()) begin publish_primary(result, status); return; end
    result.resource_h = rdma_clone_handle_value(candidate.handle,
                                                 "QP create result");
    result.final_resource_state = RDMA_RESOURCE_ALLOCATED;
    result.final_resource_state_known = 1'b1;
    result.completed_steps.push_back(RDMA_CTRL_STEP_RESOURCE_RESERVED);
    if (status.ok() && candidate.local_qp_id > 21'h1f_ffff)
      status = invalid_argument("QP local QPN exceeds 21 bits");
    if (status.ok())
      status = materialize_plan(binding, expected_owner, candidate, request,
                                plan);
    if (!status.ok()) begin
      rollback_unattached_qp(candidate, plan, null, status, result);
      return;
    end
    result.completed_steps.push_back(RDMA_CTRL_STEP_BACKING_ATTACHED);
    status = capture_qpc_authority(binding_snapshot, candidate, plan, qpc_pd,
                                    qpc_send_cq, qpc_recv_cq, qpc_srq,
                                    qpc_sequence_value);
    if (!status.ok()) begin
      rollback_unattached_qp(candidate, plan, null, status, result);
      return;
    end
    status = live_binding_fence(binding, expected_owner);
    if (status.ok()) begin
      status = normalize_status(context_backing.acquire(
        binding, RDMA_RESOURCE_QP, candidate.local_qp_id, plan.context_ref
      ), "QP context acquire returned null");
      fence_status = live_binding_fence(binding, expected_owner);
      if (!fence_status.ok())
        status = fence_status;
    end
    if (!status.ok()) begin
      primary = status;
      if (plan.context_ref != null &&
          primary.code inside {RDMA_SC_TIMEOUT, RDMA_SC_RESET_CANCELLED,
                               RDMA_SC_STALE_GENERATION}) begin
        status = normalize_status(plan.validate(),
                                  "QP plan validation returned null");
        if (status.ok())
          status = build_qpc_model(binding_snapshot, candidate, request, plan,
                                    qpc_pd, qpc_send_cq, qpc_recv_cq, qpc_srq,
                                    qpc_sequence_value, model);
        if (status.ok())
          status = attach_create_programming(candidate, request, plan, model);
        if (status.ok()) begin
          attached = 1'b1;
          result.final_resource_state = RDMA_RESOURCE_PROGRAMMED;
          retain_create_recovery(candidate, plan, null, null,
            RDMA_QP_AMBIG_NONE, RDMA_QUEUE_ROLE_QP_SQ_RING,
            null, primary, result);
          return;
        end
        append_rollback_status(result, status);
      end
      rollback_unattached_qp(candidate, plan, null, primary, result);
      return;
    end
    result.completed_steps.push_back(RDMA_CTRL_STEP_HMC_ATTACHED);
    status = normalize_status(plan.validate(), "QP plan validation returned null");
    if (status.ok())
      status = build_qpc_model(binding_snapshot, candidate, request, plan,
                                qpc_pd, qpc_send_cq, qpc_recv_cq, qpc_srq,
                                qpc_sequence_value, model);
    if (status.ok()) status = encode_qpc_staging(binding, model, candidate.handle,
                                                  expected_owner, staging, image);
    if (!status.ok()) begin
      primary = status;
      if (primary.code inside {RDMA_SC_TIMEOUT, RDMA_SC_RESET_CANCELLED}) begin
        status = attach_create_programming(candidate, request, plan, model);
        if (status.ok()) begin
          attached = 1'b1;
          result.final_resource_state = RDMA_RESOURCE_PROGRAMMED;
          retain_create_recovery(candidate, plan, null, staging,
            RDMA_QP_AMBIG_NONE, RDMA_QUEUE_ROLE_QP_SQ_RING,
            null, primary, result);
          return;
        end
        append_rollback_status(result, status);
      end
      if (staging != null) begin
        release_status = release_mapping_opaque(
          staging, "QP failed staging", release_complete
        );
        if (!release_status.ok() && model != null) begin
          append_rollback_status(result, release_status);
          status = attach_create_programming(candidate, request, plan, model);
          if (status.ok()) begin
            retain_create_recovery(candidate, plan, null, staging,
              RDMA_QP_AMBIG_NONE, RDMA_QUEUE_ROLE_QP_SQ_RING,
              null, primary, result);
            return;
          end
          append_rollback_status(result, status);
        end
        if (release_complete)
          staging = null;
      end
      rollback_unattached_qp(candidate, plan, staging, primary, result);
      return;
    end
    if (status.ok()) begin
      context_bytes = new[image.bytes.size()];
      foreach (context_bytes[i]) context_bytes[i] = image.bytes[i];
      status = live_binding_fence(binding, expected_owner);
      if (status.ok()) begin
        status = normalize_status(context_backing.write(plan.context_ref, 0,
          context_bytes), "QP context write returned null");
        fence_status = live_binding_fence(binding, expected_owner);
        if (!fence_status.ok())
          status = fence_status;
      end
    end
    if (!status.ok()) begin
      primary = status;
      if (primary.code inside {RDMA_SC_TIMEOUT, RDMA_SC_RESET_CANCELLED}) begin
        status = attach_create_programming(candidate, request, plan, model);
        if (status.ok()) begin
          attached = 1'b1;
          result.final_resource_state = RDMA_RESOURCE_PROGRAMMED;
          retain_create_recovery(candidate, plan, null, staging,
            RDMA_QP_AMBIG_NONE, RDMA_QUEUE_ROLE_QP_SQ_RING,
            null, primary, result);
          return;
        end
        append_rollback_status(result, status);
      end
      if (staging != null) begin
        release_status = release_mapping_opaque(
          staging, "QP failed staging", release_complete
        );
        if (!release_status.ok()) begin
          append_rollback_status(result, release_status);
          status = attach_create_programming(candidate, request, plan, model);
          if (status.ok()) begin
            retain_create_recovery(candidate, plan, null, staging,
              RDMA_QP_AMBIG_NONE, RDMA_QUEUE_ROLE_QP_SQ_RING,
              null, primary, result);
            return;
          end
          append_rollback_status(result, status);
        end
        if (release_complete)
          staging = null;
      end
      rollback_unattached_qp(candidate, plan, staging, primary, result);
      return;
    end
    status = attach_create_programming(candidate, request, plan, model);
    if (!status.ok()) begin
      primary = status;
      release_status = release_mapping_opaque(
        staging, "QP attach-failure staging", release_complete
      );
      if (release_complete)
        staging = null;
      status = attach_create_programming(candidate, request, plan, model);
      if (!status.ok()) begin
        append_rollback_status(result, status);
        rollback_unattached_qp(candidate, plan, staging, primary, result);
        return;
      end
      attached = 1'b1;
      result.final_resource_state = RDMA_RESOURCE_PROGRAMMED;
      if (!release_status.ok()) begin
        append_rollback_status(result, release_status);
        retain_create_recovery(candidate, plan, null, staging,
          RDMA_QP_AMBIG_NONE, RDMA_QUEUE_ROLE_QP_SQ_RING,
          null, primary, result);
        return;
      end
      cleanup_attached_qp(binding, expected_owner, candidate, plan, model,
                          1'b0, primary, result, released);
      if (released)
        publish_primary(result, primary);
      else begin
        result.primary_status = rdma_cmq_clone_status_value(primary);
        result.status = rdma_status::make(
          RDMA_SC_RECOVERY_REQUIRED,
          "QP unattached rollback requires recovery"
        );
        result.recovery_required = 1'b1;
      end
      return;
    end
    attached = 1'b1;
    result.final_resource_state = RDMA_RESOURCE_PROGRAMMED;
    status = build_qpc_command(expected_owner, model, staging, image,
                                RDMA_OP_QPC_CREATE, command);
    if (!status.ok()) begin
      primary = status;
      release_status = release_mapping_opaque(
        staging, "QP command-build staging", release_complete
      );
      if (!release_status.ok()) begin
        append_rollback_status(result, release_status);
        retain_create_recovery(candidate, plan, null, staging,
          RDMA_QP_AMBIG_NONE, RDMA_QUEUE_ROLE_QP_SQ_RING,
          null, primary, result);
        return;
      end
      staging = null;
      cleanup_attached_qp(binding, expected_owner, candidate, plan, model,
                          1'b0, primary, result, released);
      if (released)
        publish_primary(result, primary);
      else begin
        result.primary_status = rdma_cmq_clone_status_value(primary);
        result.status = rdma_status::make(
          RDMA_SC_RECOVERY_REQUIRED,
          "QP command-build rollback requires recovery"
        );
        result.recovery_required = 1'b1;
      end
      return;
    end
    status = live_binding_fence(binding, expected_owner);
    if (!status.ok()) begin
      primary = status;
      retain_create_recovery(candidate, plan, null, staging,
        RDMA_QP_AMBIG_NONE, RDMA_QUEUE_ROLE_QP_SQ_RING,
        null, primary, result);
      return;
    end
    ticket = null;
    completion = null;
    status = null;
    execute_qp_legacy_command(command, ticket, completion, status);
    ambiguous = cmq_outcome_ambiguous(status, ticket, completion);
    recovery_ticket = ticket;
    if (recovery_ticket == null && completion != null)
      recovery_ticket = completion.ticket;
    status = normalize_status(status, "QPC_CREATE result was lost");
    if (status.ok() && ticket == null)
      status = invalid_state("QPC_CREATE ticket was lost");
    if (status.ok() && (completion == null || completion.status == null))
      status = invalid_state("QPC_CREATE completion was lost");
    fence_status = live_binding_fence(binding, expected_owner);
    if (!fence_status.ok()) begin
      primary = fence_status;
      retain_create_recovery(candidate, plan, model, staging,
        RDMA_QP_AMBIG_CREATE, RDMA_QUEUE_ROLE_QP_SQ_RING,
        recovery_ticket, primary, result);
      return;
    end
    if (!status.ok()) begin
      primary = status;
      if (ambiguous) begin
        retain_create_recovery(candidate, plan, model, staging,
          RDMA_QP_AMBIG_CREATE, RDMA_QUEUE_ROLE_QP_SQ_RING,
          recovery_ticket, primary, result);
      end else begin
        release_status = release_mapping_opaque(
          staging, "QP failed-create staging", release_complete
        );
        if (!release_status.ok()) begin
          append_rollback_status(result, release_status);
          retain_create_recovery(candidate, plan, null, staging,
            RDMA_QP_AMBIG_NONE, RDMA_QUEUE_ROLE_QP_SQ_RING,
            null, primary, result);
          return;
        end
        staging = null;
        cleanup_attached_qp(binding, expected_owner, candidate, plan, model,
                            1'b0, primary, result, released);
        if (released)
          publish_primary(result, primary);
        else begin
          result.primary_status = rdma_cmq_clone_status_value(primary);
          result.status = rdma_status::make(
            RDMA_SC_RECOVERY_REQUIRED,
            "QP definitive-create rollback requires recovery"
          );
          result.recovery_required = 1'b1;
        end
      end
      return;
    end
    result.completed_steps.push_back(RDMA_CTRL_STEP_HW_CONTEXT_CREATED);
    result.completed_steps.push_back(RDMA_CTRL_STEP_REGISTRY_PROGRAMMED);
    status = live_binding_fence(binding, expected_owner);
    if (status.ok()) begin
      release_status = release_mapping_opaque(
        staging, "QP staging", release_complete
      );
      fence_status = live_binding_fence(binding, expected_owner);
      if (release_complete)
        staging = null;
      if (!fence_status.ok() || !release_status.ok()) begin
        primary = !fence_status.ok() ? fence_status :
          release_status;
        retain_create_recovery(candidate, plan, model, staging,
          RDMA_QP_AMBIG_NONE, RDMA_QUEUE_ROLE_QP_SQ_RING,
          null, primary, result);
        return;
      end
      status = fence_status;
    end
    if (!status.ok()) begin
      primary = status;
      retain_create_recovery(candidate, plan, model, null,
        RDMA_QP_AMBIG_NONE, RDMA_QUEUE_ROLE_QP_SQ_RING,
        null, primary, result);
      return;
    end
    status = live_binding_fence(binding, expected_owner);
    if (status.ok()) begin
      status = normalize_status(manager.activate(candidate.handle),
                                "QP activation returned null");
      fence_status = live_binding_fence(binding, expected_owner);
      if (!fence_status.ok()) begin
        primary = fence_status;
        retain_create_recovery(candidate, plan, model, null,
          RDMA_QP_AMBIG_NONE, RDMA_QUEUE_ROLE_QP_SQ_RING,
          null, primary, result);
        return;
      end
    end
    if (!status.ok()) begin
      primary = status;
      cleanup_attached_qp(binding, expected_owner, candidate, plan, model,
                          1'b1, primary, result, released);
      if (released)
        publish_primary(result, primary);
      else begin
        result.primary_status = rdma_cmq_clone_status_value(primary);
        result.status = rdma_status::make(RDMA_SC_RECOVERY_REQUIRED,
                                          "QP activation rollback requires recovery");
        result.recovery_required = 1'b1;
      end
      return;
    end
    result.completed_steps.push_back(RDMA_CTRL_STEP_REGISTRY_ACTIVE);
    result.final_resource_state = RDMA_RESOURCE_ACTIVE;
    status = normalize_status(manager.lookup(candidate.handle, published),
                              "ACTIVE QP lookup returned null");
    if (status.ok()) begin
      detached_object = published.clone();
      if (detached_object == null || !$cast(qp, detached_object) ||
          qp == published || qp.state != RDMA_RESOURCE_ACTIVE ||
          qp.qp_state != RDMA_QPS_RESET)
        status = invalid_state("ACTIVE QP result snapshot is invalid");
    end
    if (!status.ok()) begin
      qp = null;
      primary = status;
      cleanup_attached_qp(binding, expected_owner, candidate, plan, model,
                          1'b1, primary, result, released);
      publish_primary(result, primary);
      return;
    end
    result.resource_h = rdma_clone_handle_value(qp.handle, "ACTIVE QP result");
    result.primary_status = rdma_status::success();
    result.status = rdma_status::success();
    result.final_resource_state_known = 1'b1;
    result.recovery_required = 1'b0;
  endtask

  // 功能：modify_locked 在代际和状态机保护下修改 QP 上下文，先消费统一 transition
  //   policy 的 capability/迁移 decision，再提交硬件命令并发布新的软件状态。
  // 输入/输出及副作用：binding（输入）、expected_owner（输入）、request（输入）、transaction_id（输入）、qp（输出）、result（输出）；modify_locked 驱动下游事务，并写入 qp、result；函数返回 无直接返回值，不取得调用方资源所有权。
  // 失败/边界：modify_locked 返回 RDMA_SC_RESOURCE_BUSY、RDMA_SC_UNSUPPORTED_OPCODE；典型拒绝条件为“QP has outstanding operations”“QP SQD/SQE modify is unsupported”；失败路径不提交部分状态或转移未声明资源。
  task modify_locked(rdma_function_binding binding,
                     rdma_function_handle expected_owner,
                     rdma_modify_qp_req request,
                     longint unsigned transaction_id,
                     output rdma_qp qp,
                     output rdma_control_result result);
    rdma_status status;
    rdma_status fence_status;
    rdma_resource resource;
    rdma_qp authoritative;
    uvm_object cloned;
    rdma_qpc_model candidate_qpc;
    rdma_qpc_model prior_qpc;
    rdma_dma_mapping staging;
    rdma_dma_mapping query_mapping;
    rdma_hw_image image;
    rdma_cmq_command_desc command;
    rdma_cmq_ticket ticket;
    rdma_cmq_completion completion;
    bit ambiguous;
    rdma_status ambiguous_primary;
    bit release_complete;
    bit full_modify;
    bit state_only;
    bit query_mapping_valid;
    bit query_mapping_recovery_only;
    rdma_dma_request_context query_context;
    rdma_qp_transition_decision_t transition_decision;
    qp = null;
    result = make_result(
      transaction_id,
      "qp_modify_result",
      "QP modify did not complete"
    );
    if (transaction_id == 0) begin
      publish_primary(result, invalid_argument("QP transaction ID is zero")); return;
    end
    if (binding == null || expected_owner == null || request == null || manager == null) begin
      publish_primary(result, invalid_state("QP modify executor is not configured")); return;
    end
    status = live_binding_fence(binding, expected_owner);
    if (status.ok()) status = normalize_status(request.validate(),
                                               "QP modify request validation returned null");
    if (status.ok()) status = manager.lookup(request.qp_h, resource);
    if (status.ok() && (resource == null || !$cast(authoritative, resource)))
      status = invalid_argument("QP modify target is not a QP");
    if (status.ok() && authoritative.state != RDMA_RESOURCE_ACTIVE)
      status = invalid_state("QP modify requires ACTIVE QP");
    if (status.ok() && authoritative.programmed_qpc == null)
      status = invalid_state("QP programmed QPC is missing");
    if (status.ok() && authoritative.outstanding_ids.size() != 0)
      status = rdma_status::make(RDMA_SC_RESOURCE_BUSY, "QP has outstanding operations");
    if (status.ok() && (request.owner == null || !request.owner.same_instance(expected_owner)))
      status = invalid_argument("QP modify owner does not match binding");
    // 设计说明：transition policy 同时是 capability gate 和完整迁移矩阵的唯一值
    //   authority。这里先缓存 decision，只在 transport-specific request 校验前消费
    //   SQD/SQE unsupported 结果，以保持原错误优先级；后面不再复制同一状态条件。
    if (status.ok()) begin
      transition_decision = rdma_qp_transition_decide(
        authoritative.qp_state, request.new_state
      );
      if (transition_decision.reject_code == RDMA_SC_UNSUPPORTED_OPCODE)
        status = rdma_status::make(
          transition_decision.reject_code,
          transition_decision.reject_reason
        );
    end
    if (status.ok()) status = request.validate_for_transport(authoritative.transport);
    if (status.ok() && request.new_state == authoritative.qp_state)
      status = invalid_state("QP state transition is unchanged");
    full_modify = 1'b0;
    state_only = 1'b0;
    if (status.ok()) begin
      if (transition_decision.action == RDMA_QP_TRANSITION_INVALID)
        status = rdma_status::make(
          transition_decision.reject_code,
          transition_decision.reject_reason
        );
      else begin
        full_modify = transition_decision.action ==
                      RDMA_QP_TRANSITION_FULL_MODIFY;
        state_only = transition_decision.action ==
                     RDMA_QP_TRANSITION_SEMANTIC_ONLY;
      end
    end
    if (status.ok() && state_only &&
        authoritative.qp_state == RDMA_QPS_RESET && request.new_state == RDMA_QPS_INIT) begin
      status = manager.commit_qp_semantic_state(authoritative.handle, RDMA_QPS_INIT);
      if (status.ok()) begin
        status = manager.lookup(authoritative.handle, resource);
        if (status.ok()) begin
          cloned = resource.clone();
          if (cloned == null || !$cast(qp, cloned)) status = invalid_state("QP semantic result snapshot is invalid");
        end
      end
      if (!status.ok()) begin qp = null; publish_primary(result, status); return; end
      result.resource_h = rdma_clone_handle_value(qp.handle, "QP modify result");
      result.final_resource_state = RDMA_RESOURCE_ACTIVE;
      result.final_resource_state_known = 1'b1;
      publish_primary(result, rdma_status::success());
      return;
    end
    if (status.ok()) begin
      cloned = authoritative.programmed_qpc.clone();
      if (cloned == null || !$cast(prior_qpc, cloned))
        status = invalid_state("QP prior QPC clone failed");
    end
    if (status.ok()) begin
      cloned = prior_qpc.clone();
      if (cloned == null || !$cast(candidate_qpc, cloned))
        status = invalid_state("QP candidate QPC clone failed");
      else begin
        candidate_qpc.state = request.new_state;
        if (full_modify) begin
          case (authoritative.transport)
            RDMA_TRANSPORT_RC: begin
              rdma_qpc_rc_ext rc;
              if (!$cast(rc, candidate_qpc.transport_ext)) status = invalid_state("RC QPC extension is invalid");
              else begin
                if (request.destination_qpn_valid) rc.remote_qpn = request.destination_qpn;
                if (request.send_psn_valid) rc.send_psn = request.send_psn;
                if (request.recv_psn_valid) rc.recv_psn = request.recv_psn;
              end
            end
            RDMA_TRANSPORT_URC: begin
              rdma_qpc_urc_ext urc;
              if (!$cast(urc, candidate_qpc.transport_ext)) status = invalid_state("URC QPC extension is invalid");
              else begin
                if (request.destination_qpn_valid) urc.remote_qpn = request.destination_qpn;
                // URC PSN attributes map directly to the extension's
                // destination/source sequence numbers.
                if (request.send_psn_valid) urc.dpsn = request.send_psn;
                if (request.recv_psn_valid) urc.rpsn = request.recv_psn;
              end
            end
            default: ;
          endcase
        end
        if (status.ok()) status = candidate_qpc.validate();
      end
    end
    if (status.ok() && full_modify)
      status = encode_qpc_staging(binding, candidate_qpc, authoritative.handle,
                                  expected_owner, staging, image);
    if (status.ok())
      status = build_qpc_command(expected_owner, candidate_qpc,
                                 full_modify ? staging : null,
                                 full_modify ? image : null,
                                 RDMA_OP_QPC_MODIFY, command);
    if (status.ok()) begin
      ticket = null; completion = null; ambiguous = 1'b0; status = null;
      execute_qp_legacy_command(command, ticket, completion, status);
      // Some CMQ adapters expose the authoritative ticket only through the
      // completion.  Recover it before classifying the outcome so a
      // definitive completion remains definitive and an ambiguous one keeps
      // a usable reconciliation ticket.
      if (ticket == null && completion != null && completion.ticket != null)
        ticket = rdma_cmq_clone_ticket_value(
          completion.ticket, "QP modify completion ticket"
        );
      ambiguous = cmq_outcome_ambiguous(status, ticket, completion);
      fence_status = live_binding_fence(binding, expected_owner);
      if (!fence_status.ok()) begin status = fence_status; ambiguous = 1'b1; end
      else status = normalize_status(status, "QPC_MODIFY result was lost");
      ambiguous_primary = rdma_cmq_clone_status_value(status);
    end
    if (ambiguous) begin
      // Recovery owns a separate query buffer.  The mapping is intentionally
      // allocated before ERROR publication and remains live until recovery
      // proves the hardware image no longer references it.
      status = make_dma_context(binding, authoritative.handle,
                                RDMA_QUEUE_ROLE_QP_SQ_PD, query_context);
      query_mapping_valid = 1'b0;
      query_mapping_recovery_only = 1'b0;
      if (status.ok()) begin
        query_context.queue_role_valid = 1'b0;
        status = live_binding_fence(binding, expected_owner);
      end
      if (status.ok()) begin
        status = normalize_status(host_mem.allocate(query_context, 512, 512,
          RDMA_DMA_DEVICE_WRITE, query_mapping),
          "QP modify query allocation returned null");
        fence_status = live_binding_fence(binding, expected_owner);
        if (!fence_status.ok()) status = fence_status;
      end
      if (status.ok() && query_mapping != null && query_mapping.size == 512 &&
          (query_mapping.iova.value & 64'h1ff) == 0 &&
          (query_mapping.backing_addr.value & 64'h1ff) == 0)
        query_mapping_valid = 1'b1;
      if (query_mapping_valid) begin
        retain_modify_recovery(authoritative, prior_qpc, candidate_qpc,
                               staging, query_mapping, 1'b0, ticket,
                               ambiguous_primary, result);
        qp = null;
        return;
      end
      if (query_mapping != null) begin
        release_mapping_fenced(binding, expected_owner, query_mapping,
                               "QP failed query", status,
                               release_complete);
        if (release_complete)
          query_mapping = null;
        else
          query_mapping_recovery_only = 1'b1;
      end
      // A failed query allocation is itself unable to prove hardware state,
      // but the modify ambiguity must still become durable ERROR authority.
      // Recovery will report RECOVERY_REQUIRED until a query buffer is
      // available; it must never guess ACTIVE or discard the ticket/staging.
      if (query_mapping == null) begin
        retain_modify_recovery(authoritative, prior_qpc, candidate_qpc,
                               staging, null, 1'b0, ticket,
                               ambiguous_primary, result);
        qp = null;
        return;
      end
      if (query_mapping_recovery_only) begin
        retain_modify_recovery(authoritative, prior_qpc, candidate_qpc,
                               staging, query_mapping, 1'b1, ticket,
                               ambiguous_primary, result);
        qp = null;
        return;
      end
      qp = null;
      publish_primary(result, status);
      return;
    end
    if (!status.ok()) begin
      // A definitive command failure can still leave a staging mapping whose
      // opaque release is pending/failed.  Preserve it in durable recovery
      // authority whenever possible instead of dropping the capability.
      if (staging != null) begin
        rdma_status release_status;
        release_status = release_mapping_opaque(staging, "QP failed staging", release_complete);
        if (!release_status.ok() || !release_complete) begin
          retain_modify_recovery(authoritative, prior_qpc, candidate_qpc,
                                 staging, null, 1'b0, ticket, status, result);
          qp = null;
          if (result.recovery_required) return;
          append_rollback_status(result, release_status);
        end
      end
      qp = null;
      publish_primary(result, status);
      return;
    end
    if (staging != null) begin
      status = release_mapping_opaque(staging, "QP modify staging", release_complete);
      if (!status.ok() || !release_complete) begin
        // The command completed, but temporary authority did not.  Treat it
        // as an ambiguous modify so recovery can release it exactly once.
        retain_modify_recovery(authoritative, prior_qpc, candidate_qpc,
                               staging, null, 1'b0, ticket, status, result);
        qp = null;
        return;
      end
      staging = null;
    end
    begin
      rdma_qp candidate;
      cloned = authoritative.clone();
      if (cloned == null || !$cast(candidate, cloned)) status = invalid_state("QP candidate resource clone failed");
      else begin
        candidate.state = RDMA_RESOURCE_ACTIVE;
        candidate.qp_state = request.new_state;
        candidate.programmed_qpc = candidate_qpc;
        status = manager.commit_qp_programmed(candidate);
      end
    end
    if (status.ok()) begin
      status = manager.lookup(authoritative.handle, resource);
      if (status.ok()) begin
        cloned = resource.clone();
        if (cloned == null || !$cast(qp, cloned)) status = invalid_state("QP modify result snapshot invalid");
      end
    end
    if (!status.ok()) begin
      // Hardware has accepted MODIFY at this point; publication failure must
      // therefore become durable ERROR recovery authority rather than a plain
      // definitive error that forgets the candidate image.
      begin
        rdma_dma_mapping recovery_query;
        rdma_dma_request_context recovery_ctx;
        bit recovery_query_valid;
        bit recovery_query_only;
        bit recovery_release_complete;
        rdma_status publication_status;
        publication_status = rdma_cmq_clone_status_value(status);
        recovery_query = null;
        recovery_query_valid = 1'b0;
        recovery_query_only = 1'b0;
        if (make_dma_context(binding, authoritative.handle,
                             RDMA_QUEUE_ROLE_QP_SQ_PD, recovery_ctx).ok()) begin
          status = host_mem.allocate(recovery_ctx, 512, 512,
                                     RDMA_DMA_DEVICE_WRITE, recovery_query);
          if (status != null && status.ok() && recovery_query != null &&
              recovery_query.size == 512 &&
              (recovery_query.iova.value & 64'h1ff) == 0 &&
              (recovery_query.backing_addr.value & 64'h1ff) == 0)
            recovery_query_valid = 1'b1;
        end
        if (!recovery_query_valid && recovery_query != null) begin
          release_mapping_fenced(binding, expected_owner, recovery_query,
                                 "QP publication recovery query", status,
                                 recovery_release_complete);
          if (recovery_release_complete)
            recovery_query = null;
          else
            recovery_query_only = 1'b1;
        end
        retain_modify_recovery(authoritative, prior_qpc, candidate_qpc,
                               null, recovery_query, recovery_query_only, ticket,
                               publication_status, result);
      end
      qp = null;
      if (!result.recovery_required) publish_primary(result, status);
      return;
    end
    result.resource_h = rdma_clone_handle_value(qp.handle, "QP modify result");
    result.final_resource_state = RDMA_RESOURCE_ACTIVE;
    result.final_resource_state_known = 1'b1;
    publish_primary(result, rdma_status::success());
  endtask

  // 功能：destroy_locked 按 owner、generation 和幂等规则执行 QP ERROR/flush/
  //       delete/cleanup；失败时组装借用 qp_plan 的 transient recovery shell，
  //       再交给 manager.mark_qp_error 建立持久 authority。
  // 输入/输出及副作用：binding、expected_owner、request、transaction_id（输入），
  //       result（输出）；成功路径更新硬件/账本生命周期，失败路径只把
  //       qp.qp_plan/context_ref 作为非拥有引用传入恢复投影，不转移 mapping、
  //       HMC 或 QPC 所有权。
  // 失败/边界：owner/generation 不匹配、资源不存在、CMQ/flush/delete/cleanup
  //       失败或 manager authority projection 失败时返回错误并保留 recovery 证据；
  //       transient shell 在交给 manager 前不得被调用方修改，不能重新激活旧句柄。
  task destroy_locked(rdma_function_binding binding,
                      rdma_function_handle expected_owner,
                      rdma_destroy_resource_req request,
                      longint unsigned transaction_id,
                      output rdma_control_result result);
    rdma_status status, step_status, primary, fence_status, refresh_status;
    rdma_resource snapshot;
    rdma_qp qp;
    rdma_qp_recovery_state recovery;
    rdma_qpc_model prior_qpc, error_qpc;
    rdma_cmq_command_desc command;
    rdma_cmq_ticket ticket;
    rdma_qp_backing_ref refs[$];
    rdma_queue_backing_role_e roles[$];
    rdma_qp_ambiguous_operation_e ambiguous_operation;
    rdma_queue_backing_role_e ambiguous_role;
    bit ambiguous, hardware_absent, release_complete, error_modify_complete;
    bit side_effect_attempted;

    result = make_result(
      transaction_id,
      "qp_destroy_result",
      "QP destroy did not complete"
    );
    result.resource_h = request == null ? null :
      rdma_clone_handle_value(request.target_h, "QP destroy handle");
    status = (transaction_id == 0 || binding == null || expected_owner == null ||
              request == null || request.target_h == null || manager == null ||
              cmq == null) ? invalid_argument("QP destroy input is invalid") :
             live_binding_fence(binding, expected_owner);
    if (status.ok()) status = normalize_status(manager.lookup(request.target_h,
                                                               snapshot),
                                               "QP destroy lookup returned null");
    if (status.ok() && (snapshot == null || !$cast(qp, snapshot) ||
                        qp.resource_kind() != RDMA_RESOURCE_QP))
      status = invalid_argument("QP destroy target is not a QP");
    if (status.ok() && (qp.state != RDMA_RESOURCE_ACTIVE ||
                        !same_owner(qp.owner, expected_owner)))
      status = qp.state != RDMA_RESOURCE_ACTIVE ?
        invalid_state("QP destroy requires ACTIVE QP") :
        invalid_argument("QP destroy owner mismatch");
    if (status.ok()) status = normalize_status(manager.begin_quiesce(qp.handle),
                                               "QP begin quiesce returned null");
    if (!status.ok()) begin
      publish_primary(result, status);
      return;
    end
    prior_qpc = qp.programmed_qpc;
    ambiguous_operation = RDMA_QP_AMBIG_NONE;
    ambiguous_role = RDMA_QUEUE_ROLE_QP_SQ_RING;
    error_modify_complete = qp.qp_state == RDMA_QPS_ERROR;
    side_effect_attempted = 1'b0;
    hardware_absent = 1'b0;
    // Transition the device to ERROR before flushing queues unless already
    // in ERROR.  This is a state-only QPC_MODIFY.
    if (qp.qp_state != RDMA_QPS_ERROR) begin
      if (prior_qpc == null) status = invalid_state("QP programmed QPC is missing");
      else begin
        error_qpc = null;
        if (!$cast(error_qpc, prior_qpc.clone()) || error_qpc == null)
          status = invalid_state("QP ERROR QPC clone failed");
        else begin
          error_qpc.state = RDMA_QPS_ERROR;
          status = build_qpc_command(expected_owner, error_qpc, null, null,
                                     RDMA_OP_QPC_MODIFY, command);
          if (status.ok()) begin
            side_effect_attempted = 1'b1;
            execute_terminal_command(binding, expected_owner, command,
                                     step_status, ambiguous, ticket);
            if (ambiguous) begin
              ambiguous_operation = RDMA_QP_AMBIG_MODIFY;
              ambiguous_role = RDMA_QUEUE_ROLE_QP_SQ_RING;
            end
            status = normalize_status(step_status,
                                      "QP ERROR modify returned null");
          end
        end
      end
      if (status.ok())
        error_modify_complete = 1'b1;
    end
    // Flush QPN EIRQ/ORQ/UAQ, then SQ-PD and private RQ-PD (SRQ-backed QPs
    // intentionally omit the private RQ-PD operation).
    if (status.ok()) begin
      roles.push_back(RDMA_QUEUE_ROLE_QP_SQ_RING);
      roles.push_back(RDMA_QUEUE_ROLE_QP_SQ_PD);
      if (qp.qp_plan != null && qp.qp_plan.rq_source_h == null)
        roles.push_back(RDMA_QUEUE_ROLE_QP_RQ_PD);
      foreach (roles[i]) begin
        rdma_qp_backing_ref pd_ref;
        pd_ref = roles[i] == RDMA_QUEUE_ROLE_QP_SQ_PD ? qp.qp_plan.sq_pd_ref :
                 roles[i] == RDMA_QUEUE_ROLE_QP_RQ_PD ? qp.qp_plan.rq_pd_ref : null;
        status = build_occ_command(expected_owner, qp.local_qp_id, pd_ref, command);
        if (!status.ok()) break;
        side_effect_attempted = 1'b1;
        execute_terminal_command(binding, expected_owner, command,
                                 step_status, ambiguous, ticket);
        if (ambiguous) begin
          ambiguous_operation = RDMA_QP_AMBIG_OCC_FLUSH;
          ambiguous_role = roles[i];
        end
        status = normalize_status(step_status, "QP OCC flush returned null");
        if (status.ok()) status = normalize_status(
          manager.record_qp_flush_complete(qp.handle, roles[i]),
          "QP flush progress returned null");
        if (!status.ok()) break;
        result.completed_steps.push_back(RDMA_CTRL_STEP_HW_OCC_FLUSHED);
      end
    end
    if (status.ok()) begin
      status = build_qpc_command(expected_owner, prior_qpc, null, null,
                                 RDMA_OP_QPC_DELETE, command);
      if (status.ok()) begin
        side_effect_attempted = 1'b1;
        execute_terminal_command(binding, expected_owner, command,
                                 step_status, ambiguous, ticket);
        if (ambiguous) begin
          ambiguous_operation = RDMA_QP_AMBIG_DELETE;
          ambiguous_role = RDMA_QUEUE_ROLE_QP_SQ_RING;
        end
        status = normalize_status(step_status, "QP delete returned null");
        if (status.ok()) begin
          hardware_absent = 1'b1;
          result.completed_steps.push_back(RDMA_CTRL_STEP_HW_CONTEXT_DELETED);
        end
      end
    end
    if (status.ok() && qp.qp_plan != null && qp.qp_plan.context_ref != null) begin
      status = live_binding_fence(binding, expected_owner);
      if (status.ok()) begin
        side_effect_attempted = 1'b1;
        status = release_context_opaque(qp.qp_plan.context_ref,
                                        "QP destroy context",
                                        release_complete);
        fence_status = live_binding_fence(binding, expected_owner);
        if (!fence_status.ok()) status = fence_status;
      end
      if (status.ok()) status = normalize_status(
        manager.record_qp_context_cleanup_complete(qp.handle),
        "QP context progress returned null");
    end
    if (status.ok() && qp.qp_plan != null) begin
      if (qp.qp_plan.rq_source_h == null) refs.push_back(qp.qp_plan.rq_pd_ref);
      refs.push_back(qp.qp_plan.sq_pd_ref);
      refs.push_back(qp.qp_plan.rq_ref);
      refs.push_back(qp.qp_plan.sq_ref);
      foreach (qp.qp_plan.urc_refs[i]) refs.push_back(qp.qp_plan.urc_refs[i]);
      // URC refs are released in reverse planner order; the compact list
      // above is corrected by iterating the canonical order explicitly.
      refs.delete();
      for (int i = qp.qp_plan.urc_refs.size()-1; i >= 0; i--)
        refs.push_back(qp.qp_plan.urc_refs[i]);
      refs.push_back(qp.qp_plan.rq_pd_ref); refs.push_back(qp.qp_plan.sq_pd_ref);
      refs.push_back(qp.qp_plan.rq_ref); refs.push_back(qp.qp_plan.sq_ref);
      refs.push_back(qp.qp_plan.sq_sgb_ref);
      foreach (refs[i]) begin
        if (refs[i] == null || refs[i].ownership == RDMA_OWNERSHIP_BORROWED) continue;
        status = live_binding_fence(binding, expected_owner);
        if (status.ok()) begin
          side_effect_attempted = 1'b1;
          status = release_mapping_opaque(refs[i].mapping,
                                          "QP destroy backing",
                                          release_complete);
          fence_status = live_binding_fence(binding, expected_owner);
          if (!fence_status.ok()) status = fence_status;
        end
        if (status.ok()) status = normalize_status(
          manager.record_qp_cleanup_complete(qp.handle, refs[i].role),
          "QP backing progress returned null");
        if (!status.ok()) break;
      end
    end
    if (status.ok()) begin
      status = live_binding_fence(binding, expected_owner);
      if (status.ok()) begin
        status = normalize_status(manager.finalize_qp_release(qp.handle),
                                  "QP finalization returned null");
        fence_status = live_binding_fence(binding, expected_owner);
        // Finalization may have removed the old registry entry before a
        // generation rebind became visible.  Preserve the successful release
        // outcome while surfacing the stale boundary to the caller.
        if (status.ok() && !fence_status.ok()) begin
          result.final_resource_state = RDMA_RESOURCE_RELEASED;
          result.final_resource_state_known = 1'b1;
          publish_primary(result, fence_status);
          return;
        end
        if (!fence_status.ok()) status = fence_status;
      end
    end
    if (status.ok()) begin
      result.final_resource_state = RDMA_RESOURCE_RELEASED;
      result.final_resource_state_known = 1'b1;
      publish_primary(result, rdma_status::success());
      return;
    end
    // Refresh the manager-authoritative plan after any successfully recorded
    // flush/context progress; the lookup API deliberately returns a detached
    // projection, so the original pre-quiesce snapshot is stale here.
    refresh_status = normalize_status(manager.lookup(qp.handle, snapshot),
                                      "QP destroy progress refresh returned null");
    if (refresh_status.ok() && $cast(qp, snapshot)) begin
      prior_qpc = qp.programmed_qpc;
    end
    primary = rdma_cmq_clone_status_value(status);
    // Any hardware side effect leaves ERROR recovery authority; never restore
    // ACTIVE after an ERROR modify, flush, or delete was attempted.
    recovery = rdma_qp_recovery_state::type_id::create("qp_destroy_recovery");
    recovery.intent = RDMA_QP_RECOVER_NORMAL_DESTROY;
    recovery.ambiguous_operation = ambiguous_operation;
    recovery.ambiguous_role = ambiguous_role;
    recovery.prior_qpc = prior_qpc;
    recovery.qp_plan = qp.qp_plan;
    recovery.context_ref = qp.qp_plan == null ? null : qp.qp_plan.context_ref;
    recovery.create_opcode = make_opcode_key(RDMA_OP_QPC_CREATE, "create");
    recovery.modify_opcode = make_opcode_key(RDMA_OP_QPC_MODIFY, "modify");
    recovery.delete_opcode = make_opcode_key(RDMA_OP_QPC_DELETE, "delete");
    recovery.query_opcode = make_opcode_key(RDMA_OP_QPC_QUERY, "query");
    recovery.occ_opcode = make_opcode_key(RDMA_OP_OCC_FLUSH, "occ_flush");
    recovery.error_modify_complete = error_modify_complete;
    recovery.delete_complete = hardware_absent;
    recovery.ambiguous_ticket = ambiguous_operation != RDMA_QP_AMBIG_NONE ?
      rdma_cmq_clone_ticket_value(ticket,
      "QP destroy recovery") : null;
    if ((ambiguous_operation != RDMA_QP_AMBIG_NONE && ticket == null) ||
        (side_effect_attempted && status.code == RDMA_SC_STALE_GENERATION))
      recovery.has_pending_hardware_step = 1'b1;
    begin
      rdma_status publish_status;
      publish_status = normalize_status(
        manager.mark_qp_error(qp.handle, recovery),
        "QP destroy ERROR publication returned null");
      if (publish_status.ok()) begin
        result.final_resource_state = RDMA_RESOURCE_ERROR;
        result.final_resource_state_known = 1'b1;
        result.recovery_required = 1'b1;
        result.status = rdma_status::make(RDMA_SC_RECOVERY_REQUIRED,
                                          "QP destroy requires recovery");
      end else publish_primary(result, primary);
    end
  endtask

  // Resume a destroy that reached ERROR after at least one hardware or
  // adapter side effect.  Every milestone is persisted through the resource
  // manager before the next side effect, so a retry can safely continue from
  // the first incomplete operation.
  // 功能：在 rdma_qp_lifecycle_executor 中，recover_destroy_locked 执行受控事务并按后端提交证据推进状态机，同时保留失败阶段和 generation 证据。
  // 输入/输出及副作用：binding（输入）、expected_owner（输入）、resource_h（输入）、transaction_id（输入）、result（输出）、create_rollback（输入）、hardware_present（输入）；输入
  //   action/epoch/handle 决定迁移目标；成功时更新状态或恢复证据，外部资源仍由其拥有者管理。
  // 失败/边界：recover_destroy_locked 遇到锁、超时、generation 变化或提交证据不完整时保持原状态，不推进游标。
  protected task recover_destroy_locked(
    rdma_function_binding binding,
    rdma_function_handle expected_owner,
    rdma_handle resource_h,
    longint unsigned transaction_id,
    output rdma_control_result result,
    input bit create_rollback = 1'b0,
    input bit hardware_present = 1'b1
  );
    rdma_status status;
    rdma_status fence_status;
    rdma_resource resource;
    rdma_qp authoritative;
    rdma_recovery_record record;
    rdma_qp_recovery_state recovery;
    rdma_cmq_ticket ticket;
    rdma_cmq_completion completion;
    rdma_cmq_command_desc command;
    rdma_qpc_model error_qpc;
    rdma_qpc_model destroy_qpc;
    rdma_dma_mapping probe;
    rdma_dma_mapping staging_probe;
    rdma_qp_backing_ref refs[$];
    rdma_queue_backing_role_e roles[$];
    bit terminal_known;
    bit release_complete;
    bit ambiguous;
    bit query_conclusive;
    bit query_release_complete;
    rdma_hw_presence_e query_presence;
    rdma_dma_mapping query_mapping;
    rdma_qp_ambiguous_operation_e reconciled_operation;
    uvm_object cloned;

    result = rdma_control_result::type_id::create("qp_destroy_recover_result");
    result.transaction_id = transaction_id;
    result.resource_h = rdma_clone_handle_value(resource_h,
                                                "QP destroy recovery handle");
    result.primary_status = invalid_state("QP destroy recovery did not complete");
    result.status = result.primary_status;
    status = live_binding_fence(binding, expected_owner);
    if (status.ok()) status = normalize_status(
      manager.lookup(resource_h, resource),
      "QP destroy recovery lookup returned null");
    if (status.ok() && (resource == null || !$cast(authoritative, resource)))
      status = invalid_argument("QP destroy recovery target is not a QP");
    if (status.ok() && authoritative.state != RDMA_RESOURCE_ERROR)
      status = invalid_state("QP destroy recovery requires an ERROR QP");
    if (status.ok()) status = normalize_status(
      manager.lookup_recovery(resource_h, record),
      "QP destroy recovery record lookup returned null");
    if (status.ok() && (record == null || !record.qp_recovery_valid ||
                        record.qp_recovery == null))
      status = invalid_state("QP destroy recovery record is missing");
    if (status.ok()) begin
      cloned = record.qp_recovery.clone();
      if (cloned == null || !$cast(recovery, cloned))
        status = invalid_state("QP destroy recovery snapshot clone failed");
    end
    if (status.ok() &&
        recovery.intent != (create_rollback ?
          RDMA_QP_RECOVER_CREATE_ROLLBACK : RDMA_QP_RECOVER_NORMAL_DESTROY))
      status = create_rollback ?
        invalid_state("QP recovery intent is not create rollback") :
        invalid_state("QP recovery intent is not normal destroy");
    if (status.ok()) begin
      destroy_qpc = create_rollback ? recovery.candidate_qpc : recovery.prior_qpc;
      if (hardware_present && destroy_qpc == null)
        status = create_rollback ?
          invalid_state("QP create recovery lacks candidate QPC") :
          invalid_state("QP destroy recovery lacks prior QPC");
    end
    if (!status.ok()) begin
      result.recovery_required = 1'b1;
      result.final_resource_state = RDMA_RESOURCE_ERROR;
      result.final_resource_state_known = 1'b1;
      publish_primary(result, status);
      return;
    end

    // Reconcile exactly the operation named by the durable ticket.  A reset
    // cancellation or missing terminal result leaves the ticket untouched.
    if (recovery.ambiguous_operation != RDMA_QP_AMBIG_NONE) begin
      reconciled_operation = recovery.ambiguous_operation;
      if (recovery.ambiguous_ticket == null) begin
        // Ticketless ambiguity cannot be reconciled; remain fail-closed in
        // ERROR and let a subsequent recovery attempt obtain fresh proof.
        result.recovery_required = 1'b1;
        result.final_resource_state = RDMA_RESOURCE_ERROR;
        result.final_resource_state_known = 1'b1;
        publish_primary(result, rdma_status::make(
          RDMA_SC_RECOVERY_REQUIRED,
          "QP destroy ambiguity has no reconciliation ticket"));
        return;
      end
      // A previously authenticated QPC_QUERY image is durable evidence and
      // avoids repeating the query or the original side effect.
      if (recovery.query_presence_known &&
          (reconciled_operation inside {RDMA_QP_AMBIG_CREATE,
                                        RDMA_QP_AMBIG_DELETE})) begin
        if (recovery.query_mapping != null) begin
          rdma_dma_mapping retained_probe;
          retained_probe = null;
          cloned = recovery.query_mapping.clone();
          if (cloned == null || !$cast(retained_probe, cloned)) begin
            status = invalid_state(
              "QP persisted presence query release probe clone failed");
            query_release_complete = 1'b0;
          end
          else
            release_mapping_fenced(
              binding, expected_owner, retained_probe,
              "QP persisted presence query", status,
              query_release_complete);
          if (!status.ok() || !query_release_complete) begin
            if (status.ok()) status = rdma_status::make(
              RDMA_SC_RECOVERY_REQUIRED,
              "QP persisted presence query release remains incomplete");
            publish_primary(result, status);
            result.recovery_required = 1'b1;
            result.final_resource_state = RDMA_RESOURCE_ERROR;
            result.final_resource_state_known = 1'b1;
            return;
          end
        end
        hardware_present = recovery.query_presence == RDMA_HW_PRESENCE_PRESENT;
        if (reconciled_operation == RDMA_QP_AMBIG_DELETE && !hardware_present)
          recovery.delete_complete = 1'b1;
        recovery.ambiguous_operation = RDMA_QP_AMBIG_NONE;
        recovery.ambiguous_ticket = null;
        recovery.has_pending_hardware_step = 1'b0;
        status = normalize_status(
          manager.update_qp_recovery_progress(resource_h, recovery),
          "QP destroy persisted query presence returned null");
      end
      else begin
        terminal_known = 1'b0;
        completion = null;
        status = live_binding_fence(binding, expected_owner);
        if (status.ok()) begin
          cmq.reconcile(recovery.ambiguous_ticket, terminal_known, completion,
                        status);
          fence_status = live_binding_fence(binding, expected_owner);
          if (!fence_status.ok()) status = fence_status;
        end
        status = normalize_status(status,
                                   "QP destroy reconciliation returned null");
        if (status.ok() && !terminal_known) begin
          // CREATE/DELETE can be disambiguated by an authenticated QPC_QUERY
          // image.  Other destroy steps remain fail-closed without a ticket.
          if (!(reconciled_operation inside {RDMA_QP_AMBIG_CREATE,
                                             RDMA_QP_AMBIG_DELETE})) begin
            publish_primary(result, rdma_status::make(
              RDMA_SC_RECOVERY_REQUIRED,
              "QP destroy ambiguity has no terminal result"));
            return;
          end
          if (recovery.query_mapping_recovery_only &&
              recovery.query_mapping != null) begin
            rdma_dma_mapping malformed_probe;
            malformed_probe = null;
            cloned = recovery.query_mapping.clone();
            if (cloned == null || !$cast(malformed_probe, cloned)) begin
              status = invalid_state(
                "QP destroy malformed query release probe clone failed");
              query_release_complete = 1'b0;
            end
            else
              release_mapping_fenced(
                binding, expected_owner, malformed_probe,
                "QP destroy malformed query", status,
                query_release_complete);
            if (!status.ok() || !query_release_complete) begin
              if (status.ok()) status = rdma_status::make(
                RDMA_SC_RECOVERY_REQUIRED,
                "QP destroy malformed query release remains incomplete");
              publish_primary(result, status);
              result.recovery_required = 1'b1;
              result.final_resource_state = RDMA_RESOURCE_ERROR;
              result.final_resource_state_known = 1'b1;
              return;
            end
          end
          query_mapping = recovery.query_mapping_recovery_only ? null :
                          recovery.query_mapping;
          query_qpc_presence(binding, expected_owner, destroy_qpc,
                             query_mapping, query_mapping, query_presence,
                             query_conclusive, query_release_complete, status);
          if (!query_release_complete && query_mapping != null &&
              !query_conclusive) begin
            if (recovery.query_mapping == null) begin
              rdma_status retain_status;
              bit retain_query_only;
              retain_query_only = query_mapping.size != 512 ||
                (query_mapping.iova.value & 64'h1ff) != 0 ||
                (query_mapping.backing_addr.value & 64'h1ff) != 0;
              retain_status = manager.retain_qp_query_mapping(
                resource_h, query_mapping, retain_query_only);
              if (retain_status == null || !retain_status.ok())
                status = retain_status == null ?
                  invalid_state("QP destroy query retention returned null") :
                  retain_status;
            end
          end
          if (query_conclusive) begin
            recovery.query_presence_known = 1'b1;
            recovery.query_presence = query_presence;
            if (!query_release_complete && recovery.query_mapping == null) begin
              bit retain_query_only;
              retain_query_only = query_mapping.size != 512 ||
                (query_mapping.iova.value & 64'h1ff) != 0 ||
                (query_mapping.backing_addr.value & 64'h1ff) != 0;
              status = normalize_status(
                manager.retain_qp_query_mapping(
                  resource_h, query_mapping,
                  retain_query_only),
                "QP destroy query authority retention returned null");
              if (status.ok()) begin
                recovery.query_mapping = query_mapping;
                recovery.query_mapping_recovery_only = retain_query_only;
              end
            end
            if (!query_release_complete && recovery.query_mapping != null) begin
              rdma_status persist_presence_status;
              persist_presence_status = manager.update_qp_recovery_progress(
                resource_h, recovery);
              if (persist_presence_status == null ||
                  !persist_presence_status.ok())
                status = persist_presence_status == null ?
                  invalid_state("QP destroy query presence persistence returned null") :
                  persist_presence_status;
            end
          end
          if (status.ok() && query_conclusive && query_release_complete) begin
            hardware_present = query_presence == RDMA_HW_PRESENCE_PRESENT;
            if (reconciled_operation == RDMA_QP_AMBIG_DELETE && !hardware_present)
              recovery.delete_complete = 1'b1;
            recovery.ambiguous_operation = RDMA_QP_AMBIG_NONE;
            recovery.ambiguous_ticket = null;
            recovery.has_pending_hardware_step = 1'b0;
            status = normalize_status(
              manager.update_qp_recovery_progress(resource_h, recovery),
              "QP destroy query presence progress returned null");
          end
          else begin
            if (status.ok()) status = rdma_status::make(
              RDMA_SC_RECOVERY_REQUIRED,
              query_conclusive ?
                "QP destroy query mapping release remains incomplete" :
                "QP destroy ambiguity has no trustworthy presence result");
          end
        end
        if (status.ok() && recovery.ambiguous_operation != RDMA_QP_AMBIG_NONE &&
            (completion == null || completion.status == null))
          status = invalid_state("QP destroy reconciliation completion is incomplete");
        if (status.ok() && recovery.ambiguous_operation != RDMA_QP_AMBIG_NONE &&
            completion != null && completion.status != null &&
            completion.status.code inside {RDMA_SC_TIMEOUT,
                                           RDMA_SC_RESET_CANCELLED}) begin
          status = rdma_status::make(
            RDMA_SC_RECOVERY_REQUIRED,
            "QP destroy reconciliation remains ambiguous");
        end
        // Terminal completion failures are still authoritative evidence.  The
        // reconcile task may return the same non-OK status as its completion;
        // only timeout/reset remains ambiguous.
        if (status != null && recovery.ambiguous_operation != RDMA_QP_AMBIG_NONE &&
            completion != null && completion.status != null &&
            !(completion.status.code inside {RDMA_SC_TIMEOUT,
                                             RDMA_SC_RESET_CANCELLED}) &&
            (terminal_known || query_conclusive))
          status = rdma_status::success();
      end
      if (status.ok() &&
          recovery.ambiguous_operation != RDMA_QP_AMBIG_NONE) begin
        if (reconciled_operation == RDMA_QP_AMBIG_CREATE)
          hardware_present = completion.status.ok();
        else if (reconciled_operation == RDMA_QP_AMBIG_DELETE) begin
          hardware_present = !completion.status.ok();
          if (!hardware_present) recovery.delete_complete = 1'b1;
        end
        if (reconciled_operation inside {RDMA_QP_AMBIG_CREATE,
                                          RDMA_QP_AMBIG_DELETE}) begin
          recovery.query_presence_known = 1'b1;
          recovery.query_presence = hardware_present ?
            RDMA_HW_PRESENCE_PRESENT : RDMA_HW_PRESENCE_ABSENT;
        end
        if (reconciled_operation == RDMA_QP_AMBIG_MODIFY)
          recovery.error_modify_complete = completion.status.ok();
        else if (reconciled_operation == RDMA_QP_AMBIG_DELETE)
          recovery.delete_complete = completion.status.ok();
        // Clear the operation ticket before recording any operation-specific
        // progress.  The manager enforces this ambiguity transition order.
        recovery.ambiguous_operation = RDMA_QP_AMBIG_NONE;
        recovery.ambiguous_ticket = null;
        status = normalize_status(manager.mark_qp_error(resource_h, recovery),
                                  "QP destroy recovery ambiguity clear returned null");
        if (status.ok() && reconciled_operation == RDMA_QP_AMBIG_OCC_FLUSH &&
            recovery.ambiguous_role inside {
              RDMA_QUEUE_ROLE_QP_SQ_RING,
              RDMA_QUEUE_ROLE_QP_SQ_PD,
              RDMA_QUEUE_ROLE_QP_RQ_PD}) begin
          if (completion.status.ok() &&
              recovery.ambiguous_role != RDMA_QUEUE_ROLE_QP_SQ_RING)
            status = normalize_status(manager.record_qp_flush_complete(
              resource_h, recovery.ambiguous_role),
              "QP destroy recovery flush progress returned null");
          else if (completion.status.ok())
            status = normalize_status(manager.record_qp_flush_complete(
              resource_h, recovery.ambiguous_role),
              "QP destroy recovery flush progress returned null");
        end
        if (status.ok() && reconciled_operation == RDMA_QP_AMBIG_DELETE &&
            completion.status.ok())
          status = normalize_status(
            manager.update_qp_recovery_progress(resource_h, recovery),
            "QP destroy recovery progress update returned null");
        if (status.ok()) begin
          // Re-read the persisted snapshot after manager progress updates.
          status = normalize_status(manager.lookup_recovery(resource_h, record),
                                    "QP destroy recovery refresh returned null");
          if (status.ok() && record != null && record.qp_recovery != null) begin
            cloned = record.qp_recovery.clone();
            if (cloned == null || !$cast(recovery, cloned))
              status = invalid_state("QP destroy recovery refresh failed");
          end
        end
      end
      if (!status.ok()) begin
        publish_primary(result, status);
        result.recovery_required = 1'b1;
        result.final_resource_state = RDMA_RESOURCE_ERROR;
        result.final_resource_state_known = 1'b1;
        return;
      end
    end

    // CREATE staging is a temporary DMA authority, independent of the QP
    // context and backing recipe.  Release it once the CREATE ticket has
    // terminal evidence; a detached probe preserves the adapter's opaque
    // completion seal while leaving the persisted authority immutable.
    if (create_rollback && recovery.staging_mapping != null) begin
      staging_probe = null;
      cloned = recovery.staging_mapping.clone();
      if (cloned == null || !$cast(staging_probe, cloned)) begin
        status = invalid_state("QP create staging release probe clone failed");
        release_complete = 1'b0;
      end
      else
        release_mapping_fenced(binding, expected_owner, staging_probe,
                               "QP create recovery staging", status,
                               release_complete);
      if (!status.ok() || !release_complete) begin
        if (status.ok()) status = rdma_status::make(
          RDMA_SC_RECOVERY_REQUIRED,
          "QP create staging release remains incomplete");
        publish_primary(result, status);
        result.recovery_required = 1'b1;
        result.final_resource_state = RDMA_RESOURCE_ERROR;
        result.final_resource_state_known = 1'b1;
        return;
      end
    end

    // ERROR transition (if it was not completed before the failure).
    if (!hardware_present) begin
      // A terminal CREATE failure proves that no QP context was installed;
      // there is no legal ERROR transition or hardware flush to issue.
      recovery.error_modify_complete = 1'b1;
      recovery.delete_complete = 1'b1;
      status = normalize_status(
        manager.update_qp_recovery_progress(resource_h, recovery),
        "QP create absent progress update returned null");
    end
    else if (!recovery.error_modify_complete) begin
      status = live_binding_fence(binding, expected_owner);
      if (status.ok()) begin
        cloned = destroy_qpc.clone();
        if (cloned == null || !$cast(error_qpc, cloned))
          status = invalid_state("QP destroy ERROR QPC clone failed");
        else begin
          error_qpc.state = RDMA_QPS_ERROR;
          status = build_qpc_command(expected_owner, error_qpc, null, null,
                                     RDMA_OP_QPC_MODIFY, command);
          if (status.ok()) begin
            execute_terminal_command(binding, expected_owner, command,
                                     status, ambiguous, ticket);
            status = normalize_status(status,
                                       "QP destroy ERROR retry returned null");
            if (ambiguous) begin
              recovery.ambiguous_operation = RDMA_QP_AMBIG_MODIFY;
              recovery.ambiguous_role = RDMA_QUEUE_ROLE_QP_SQ_RING;
              recovery.ambiguous_ticket = rdma_cmq_clone_ticket_value(
                ticket, "QP destroy ERROR retry");
              recovery.has_pending_hardware_step = ticket == null;
              status = normalize_status(manager.mark_qp_error(resource_h,
                                                               recovery),
                                         "QP destroy ERROR ambiguity publication returned null");
              if (!status.ok()) begin
                publish_primary(result, status);
                result.recovery_required = 1'b1;
                result.final_resource_state = RDMA_RESOURCE_ERROR;
                result.final_resource_state_known = 1'b1;
                return;
              end
              publish_primary(result, rdma_status::make(
                RDMA_SC_RECOVERY_REQUIRED,
                "QP destroy ERROR transition remains ambiguous"));
              result.recovery_required = 1'b1;
              result.final_resource_state = RDMA_RESOURCE_ERROR;
              result.final_resource_state_known = 1'b1;
              return;
            end
            if (status.ok()) recovery.error_modify_complete = 1'b1;
          end
        end
      end
      if (status.ok()) status = normalize_status(
        manager.update_qp_recovery_progress(resource_h, recovery),
        "QP destroy ERROR progress update returned null");
      if (!status.ok()) begin
        publish_primary(result, status);
        result.recovery_required = 1'b1;
        result.final_resource_state = RDMA_RESOURCE_ERROR;
        result.final_resource_state_known = 1'b1;
        return;
      end
    end

    // Flush roles in canonical order, skipping roles already persisted.
    roles.push_back(RDMA_QUEUE_ROLE_QP_SQ_RING);
    roles.push_back(RDMA_QUEUE_ROLE_QP_SQ_PD);
    if (recovery.qp_plan.rq_source_h == null)
      roles.push_back(RDMA_QUEUE_ROLE_QP_RQ_PD);
    foreach (roles[i]) begin
      bit done;
      done = (roles[i] == RDMA_QUEUE_ROLE_QP_SQ_RING) ?
        recovery.qp_plan.cleanup_complete :
        roles[i] == RDMA_QUEUE_ROLE_QP_SQ_PD ?
        recovery.qp_plan.sq_pd_flush_complete :
        recovery.qp_plan.rq_pd_flush_complete;
      if (done) continue;
      if (!hardware_present) begin
        status = normalize_status(
          manager.record_qp_flush_complete(resource_h, roles[i]),
          "QP create absent flush progress returned null");
        if (!status.ok()) break;
        status = normalize_status(manager.lookup_recovery(resource_h, record),
                                  "QP create absent flush refresh returned null");
        if (status.ok() && record != null && record.qp_recovery != null) begin
          cloned = record.qp_recovery.clone();
          if (cloned == null || !$cast(recovery, cloned)) begin
            status = invalid_state("QP create absent flush refresh failed");
            break;
          end
        end
        continue;
      end
      status = live_binding_fence(binding, expected_owner);
      if (!status.ok()) break;
      status = build_occ_command(expected_owner, authoritative.local_qp_id,
                                 roles[i] == RDMA_QUEUE_ROLE_QP_SQ_PD ?
                                   recovery.qp_plan.sq_pd_ref :
                                 roles[i] == RDMA_QUEUE_ROLE_QP_RQ_PD ?
                                   recovery.qp_plan.rq_pd_ref : null,
                                 command);
      if (status.ok()) begin
        execute_terminal_command(binding, expected_owner, command,
                                 status, ambiguous, ticket);
        status = normalize_status(status, "QP destroy OCC retry returned null");
        if (ambiguous) begin
          recovery.ambiguous_operation = RDMA_QP_AMBIG_OCC_FLUSH;
          recovery.ambiguous_role = roles[i];
          recovery.ambiguous_ticket = rdma_cmq_clone_ticket_value(
            ticket, "QP destroy OCC retry");
          recovery.has_pending_hardware_step = ticket == null;
          status = normalize_status(manager.mark_qp_error(resource_h, recovery),
                                    "QP destroy OCC ambiguity publication returned null");
          if (status.ok()) status = rdma_status::make(
            RDMA_SC_RECOVERY_REQUIRED,
            "QP destroy OCC flush remains ambiguous");
        end
        else if (status.ok())
          status = normalize_status(
            manager.record_qp_flush_complete(resource_h, roles[i]),
            "QP destroy OCC progress returned null");
      end
      if (!status.ok()) break;
      status = manager.lookup_recovery(resource_h, record);
      if (status.ok() && record != null && record.qp_recovery != null) begin
        cloned = record.qp_recovery.clone();
        if (cloned == null || !$cast(recovery, cloned)) begin
          status = invalid_state("QP destroy recovery flush refresh failed");
          break;
        end
      end
    end
    if (!status.ok()) begin
      publish_primary(result, status);
      result.recovery_required = 1'b1;
      result.final_resource_state = RDMA_RESOURCE_ERROR;
      result.final_resource_state_known = 1'b1;
      return;
    end

    if (!recovery.delete_complete) begin
      if (!hardware_present) begin
        recovery.delete_complete = 1'b1;
        status = normalize_status(
          manager.update_qp_recovery_progress(resource_h, recovery),
          "QP create absent DELETE progress update returned null");
      end
      else begin
        status = live_binding_fence(binding, expected_owner);
        if (status.ok()) begin
          status = build_qpc_command(expected_owner, destroy_qpc,
                                     null, null, RDMA_OP_QPC_DELETE,
                                     command);
          if (status.ok()) begin
            execute_terminal_command(binding, expected_owner, command,
                                     status, ambiguous, ticket);
            status = normalize_status(status, "QP destroy delete retry returned null");
            if (ambiguous) begin
              recovery.ambiguous_operation = RDMA_QP_AMBIG_DELETE;
              recovery.ambiguous_role = RDMA_QUEUE_ROLE_QP_SQ_RING;
              recovery.ambiguous_ticket = rdma_cmq_clone_ticket_value(
                ticket, "QP destroy delete retry");
              recovery.has_pending_hardware_step = ticket == null;
              status = normalize_status(manager.mark_qp_error(resource_h, recovery),
                                        "QP delete ambiguity publication returned null");
              if (status.ok()) status = rdma_status::make(
                RDMA_SC_RECOVERY_REQUIRED, "QP delete remains ambiguous");
            end
            else if (status.ok()) recovery.delete_complete = 1'b1;
          end
        end
        if (status.ok()) status = normalize_status(
          manager.update_qp_recovery_progress(resource_h, recovery),
          "QP destroy DELETE progress update returned null");
      end
      if (!status.ok()) begin
        publish_primary(result, status);
        result.recovery_required = 1'b1;
        result.final_resource_state = RDMA_RESOURCE_ERROR;
        result.final_resource_state_known = 1'b1;
        return;
      end
    end

    // Context release precedes all owned backing releases.
    if (recovery.context_ref != null && !recovery.context_ref.release_complete) begin
      status = live_binding_fence(binding, expected_owner);
      if (status.ok()) begin
        status = release_context_opaque(recovery.context_ref,
                                        "QP destroy recovery context",
                                        release_complete);
        fence_status = live_binding_fence(binding, expected_owner);
        if (!fence_status.ok()) status = fence_status;
      end
      if (status.ok()) status = normalize_status(
        manager.record_qp_context_cleanup_complete(resource_h),
        "QP destroy context progress returned null");
      if (!status.ok() || !release_complete) begin
        if (status.ok()) status = rdma_status::make(
          RDMA_SC_RECOVERY_REQUIRED, "QP destroy context release remains incomplete");
        publish_primary(result, status);
        result.recovery_required = 1'b1;
        result.final_resource_state = RDMA_RESOURCE_ERROR;
        result.final_resource_state_known = 1'b1;
        return;
      end
      status = manager.lookup_recovery(resource_h, record);
      if (!status.ok()) begin
        publish_primary(result, status);
        result.recovery_required = 1'b1;
        result.final_resource_state = RDMA_RESOURCE_ERROR;
        result.final_resource_state_known = 1'b1;
        return;
      end
      if (record != null && record.qp_recovery != null) begin
        cloned = record.qp_recovery.clone();
        if (cloned == null || !$cast(recovery, cloned))
          status = invalid_state("QP destroy recovery context refresh failed");
      end
      if (!status.ok()) begin
        publish_primary(result, status);
        result.recovery_required = 1'b1;
        result.final_resource_state = RDMA_RESOURCE_ERROR;
        result.final_resource_state_known = 1'b1;
        return;
      end
    end

    refs.delete();
    for (int i = recovery.qp_plan.urc_refs.size()-1; i >= 0; i--)
      refs.push_back(recovery.qp_plan.urc_refs[i]);
    if (recovery.qp_plan.rq_source_h == null)
      refs.push_back(recovery.qp_plan.rq_pd_ref);
    refs.push_back(recovery.qp_plan.sq_pd_ref);
    if (recovery.qp_plan.rq_source_h == null)
      refs.push_back(recovery.qp_plan.rq_ref);
    refs.push_back(recovery.qp_plan.sq_ref);
    refs.push_back(recovery.qp_plan.sq_sgb_ref);
    foreach (refs[i]) begin
      if (refs[i] == null || refs[i].ownership == RDMA_OWNERSHIP_BORROWED ||
          refs[i].cleanup_complete)
        continue;
      status = live_binding_fence(binding, expected_owner);
      if (status.ok()) begin
        probe = null;
        cloned = refs[i].mapping.clone();
        if (cloned == null || !$cast(probe, cloned))
          status = invalid_state("QP destroy backing release probe clone failed");
        else
          release_mapping_fenced(binding, expected_owner, probe,
                                 "QP destroy recovery backing", status,
                                 release_complete);
        fence_status = live_binding_fence(binding, expected_owner);
        if (!fence_status.ok()) status = fence_status;
      end
      if (status.ok() && release_complete)
        status = normalize_status(
          manager.record_qp_cleanup_complete(resource_h, refs[i].role),
          "QP destroy backing progress returned null");
      if (!status.ok()) break;
      status = manager.lookup_recovery(resource_h, record);
      if (status.ok() && record != null && record.qp_recovery != null) begin
        cloned = record.qp_recovery.clone();
        if (cloned == null || !$cast(recovery, cloned)) begin
          status = invalid_state("QP destroy recovery backing refresh failed");
          break;
        end
      end
    end
    if (status.ok()) begin
      status = live_binding_fence(binding, expected_owner);
      if (status.ok()) begin
        status = normalize_status(manager.finalize_qp_release(resource_h),
                                  "QP destroy recovery finalization returned null");
        fence_status = live_binding_fence(binding, expected_owner);
        if (status.ok() && !fence_status.ok()) begin
          result.final_resource_state = RDMA_RESOURCE_RELEASED;
          result.final_resource_state_known = 1'b1;
          result.recovery_required = 1'b0;
          publish_primary(result, fence_status);
          return;
        end
        if (!fence_status.ok()) status = fence_status;
      end
    end
    if (!status.ok()) begin
      publish_primary(result, status);
      result.recovery_required = 1'b1;
      result.final_resource_state = RDMA_RESOURCE_ERROR;
      result.final_resource_state_known = 1'b1;
      return;
    end
    result.final_resource_state = RDMA_RESOURCE_RELEASED;
    result.final_resource_state_known = 1'b1;
    result.recovery_required = 1'b0;
    publish_primary(result, rdma_status::success());
  endtask

  // 功能：在 rdma_qp_lifecycle_executor 中，recover_locked 执行受控事务并按后端提交证据推进状态机，同时保留失败阶段和 generation 证据。
  // 输入/输出及副作用：binding（输入）、expected_owner（输入）、resource_h（输入）、transaction_id（输入）、result（输出）；输入 action/epoch/handle
  //   决定迁移目标；成功时更新状态或恢复证据，外部资源仍由其拥有者管理。
  // 失败/边界：recover_locked 遇到锁、超时、generation 变化或提交证据不完整时保持原状态，不推进游标。
  task recover_locked(rdma_function_binding binding,
                      rdma_function_handle expected_owner,
                      rdma_handle resource_h,
                      longint unsigned transaction_id,
                      output rdma_control_result result);
    rdma_status status;
    rdma_status fence_status;
    rdma_resource resource;
    rdma_qp authoritative;
    rdma_recovery_record record;
    rdma_qp_recovery_state recovery;
    rdma_cmq_completion completion;
    rdma_cmq_ticket ticket;
    rdma_qpc_model resolved_qpc;
    rdma_hw_qpc_command_body body;
    rdma_cmq_command_desc query_command;
    rdma_dma_mapping staging;
    rdma_dma_mapping query_mapping;
    rdma_dma_mapping query_release_probe;
    rdma_dma_mapping staging_release_probe;
    bit terminal_known;
    bit release_complete;
    bit candidate_selected;
    bit fresh_query_mapping;
    bit query_unresolved;
    bit query_release_complete;
    bit query_mapping_retained;
    uvm_object cloned;
    fresh_query_mapping = 1'b0;
    query_unresolved = 1'b0;

    result = make_result(
      transaction_id,
      "qp_recover_result",
      "QP recovery did not complete"
    );
    result.resource_h = rdma_clone_handle_value(resource_h,
                                                "QP recovery handle");
    if (transaction_id == 0 || binding == null || expected_owner == null ||
        resource_h == null || manager == null || cmq == null) begin
      publish_primary(result, invalid_argument("QP recovery input is invalid"));
      return;
    end
    status = live_binding_fence(binding, expected_owner);
    if (status.ok()) status = manager.lookup(resource_h, resource);
    if (status.ok() && (resource == null || !$cast(authoritative, resource)))
      status = invalid_argument("QP recovery target is not a QP");
    if (status.ok() && authoritative.state != RDMA_RESOURCE_ERROR)
      status = invalid_state("QP recovery requires an ERROR QP");
    if (status.ok()) status = manager.lookup_recovery(resource_h, record);
    if (status.ok() && (record == null || !record.qp_recovery_valid ||
                        record.qp_recovery == null))
      status = invalid_state("QP recovery record is missing");
    if (status.ok()) begin
      cloned = record.qp_recovery.clone();
      if (cloned == null || !$cast(recovery, cloned))
        status = invalid_state("QP recovery snapshot clone failed");
    end
    // Let the destroy-style recipe own CREATE ambiguity as well.  It can
    // reconcile the original ticket and, when that remains unknown, use the
    // authenticated QPC_QUERY presence fallback without issuing duplicate
    // CREATE side effects.
    if (status.ok() && recovery.intent == RDMA_QP_RECOVER_CREATE_ROLLBACK &&
        recovery.ambiguous_operation != RDMA_QP_AMBIG_NONE) begin
      recover_destroy_locked(binding, expected_owner, resource_h,
                             transaction_id, result, 1'b1, 1'b1);
      return;
    end
    if (status.ok() && !(recovery.intent inside {
          RDMA_QP_RECOVER_CREATE_ROLLBACK,
          RDMA_QP_RECOVER_MODIFY_RECONCILE,
          RDMA_QP_RECOVER_NORMAL_DESTROY}))
      status = invalid_state("QP recovery intent is unsupported");
    if (status.ok() && recovery.intent == RDMA_QP_RECOVER_CREATE_ROLLBACK) begin
      // CREATE recovery without an outstanding ticket is a pre-program or
      // already-reconciled record.  No QP hardware is authoritative in this
      // state, so continue through the local cleanup recipe.
      recover_destroy_locked(binding, expected_owner, resource_h,
                             transaction_id, result, 1'b1, 1'b0);
      return;
    end
    if (status.ok() && recovery.intent == RDMA_QP_RECOVER_NORMAL_DESTROY) begin
      recover_destroy_locked(binding, expected_owner, resource_h,
                             transaction_id, result);
      return;
    end
    if (status.ok() && recovery.ambiguous_operation == RDMA_QP_AMBIG_MODIFY) begin
      // A malformed query allocation is retained only as opaque release
      // authority.  It cannot safely feed QPC_QUERY, so finish its release
      // attempt before reconciling the modify ticket.  The mapping remains in
      // the recovery record (with its recovery-only bit) so the completion
      // proof and exactly-once release are durable across retries.
      if (recovery.query_mapping_recovery_only &&
          recovery.query_mapping != null) begin
        // Release through a detached probe so the recovery record keeps its
        // ACTIVE public mapping value for manager authority comparison.  The
        // probe shares the adapter's opaque completion seal with the retained
        // mapping, so completion remains durable while no public state is
        // mutated on the persisted recovery snapshot.
        query_release_probe = null;
        cloned = recovery.query_mapping.clone();
        if (cloned == null || !$cast(query_release_probe, cloned)) begin
          status = invalid_state(
            "QP recovery malformed query release probe clone failed"
          );
          release_complete = 1'b0;
        end
        else begin
          release_mapping_fenced(
            binding, expected_owner, query_release_probe,
            "QP recovery malformed query", status,
            release_complete
          );
        end
        if (!status.ok() || !release_complete) begin
          result.recovery_required = 1'b1;
          result.final_resource_state = RDMA_RESOURCE_ERROR;
          result.final_resource_state_known = 1'b1;
          publish_primary(result, rdma_status::make(
            RDMA_SC_RECOVERY_REQUIRED,
            "QP recovery query mapping release remains incomplete"
          ));
          return;
        end
      end
      if (recovery.ambiguous_ticket == null) begin
        // A ticketless record cannot be reconciled through CMQ.  Retained
        // staging means the candidate was not authoritative; no staging means
        // hardware accepted the candidate before publication failed.
        candidate_selected = recovery.staging_mapping == null;
        resolved_qpc = candidate_selected ? recovery.candidate_qpc :
                       recovery.prior_qpc;
        terminal_known = 1'b1;
      end
      else begin
        terminal_known = 1'b0;
        completion = null;
        cmq.reconcile(recovery.ambiguous_ticket, terminal_known, completion,
                      status);
      status = normalize_status(status, "QP modify reconciliation returned null");
      fence_status = live_binding_fence(binding, expected_owner);
      if (!fence_status.ok()) status = fence_status;
      if (status.ok() && terminal_known && completion != null &&
          completion.status != null) begin
        candidate_selected = completion.status.ok();
        resolved_qpc = candidate_selected ? recovery.candidate_qpc :
                       recovery.prior_qpc;
      end
      else if (status.ok()) begin
        // A ticket without a terminal completion is reconciled with a
        // dedicated QPC_QUERY image.  The query buffer is independent from
        // the modify staging image and remains part of durable authority.
        if (recovery.query_mapping == null ||
            recovery.query_mapping_recovery_only) begin
          rdma_dma_request_context fresh_query_context;
          status = make_dma_context(binding, authoritative.handle,
                                    RDMA_QUEUE_ROLE_QP_SQ_PD,
                                    fresh_query_context);
          if (status.ok()) begin
            fresh_query_context.queue_role_valid = 1'b0;
            status = live_binding_fence(binding, expected_owner);
            if (status.ok())
              status = normalize_status(host_mem.allocate(fresh_query_context,
                512, 512, RDMA_DMA_DEVICE_WRITE, query_mapping),
                "QP recovery fresh query allocation returned null");
            fence_status = live_binding_fence(binding, expected_owner);
            if (status.ok() && !fence_status.ok()) status = fence_status;
            if (status.ok() && (query_mapping == null || query_mapping.size < 512 ||
                (query_mapping.iova.value & 64'h1ff) != 0 ||
                (query_mapping.backing_addr.value & 64'h1ff) != 0))
              status = invalid_state("QP recovery fresh query mapping is invalid");
          end
          if (!status.ok()) begin
            // An adapter is allowed to return a non-null mapping together
            // with an allocation error.  If its release is not yet proven,
            // retain the capability as recovery-only before returning.
            if (query_mapping != null) begin
              query_release_complete = 1'b0;
              release_mapping_fenced(binding, expected_owner, query_mapping,
                                     "QP recovery failed query", status,
                                     query_release_complete);
              if (!query_release_complete) begin
                status = normalize_status(
                  manager.retain_qp_query_mapping(
                    resource_h, query_mapping, 1'b1),
                  "QP recovery failed query retention returned null");
                query_mapping_retained = status.ok();
              end
            end
            result.recovery_required = 1'b1;
            result.final_resource_state = RDMA_RESOURCE_ERROR;
            result.final_resource_state_known = 1'b1;
            publish_primary(result, rdma_status::make(
              RDMA_SC_RECOVERY_REQUIRED, "QP modify completion remains ambiguous"));
            return;
          end
          fresh_query_mapping = 1'b1;
        end
        body = rdma_hw_qpc_command_body::type_id::create("qp_query_body");
        body.qp_h = rdma_clone_handle_value(recovery.prior_qpc.qp_h,
                                             "QP query QPN");
        body.qpc_buffer.value = fresh_query_mapping ? query_mapping.iova.value :
                                recovery.query_mapping.iova.value;
        query_command = rdma_cmq_command_desc::type_id::create("qp_query_command");
        query_command.function_h = rdma_clone_function_handle_value(
          expected_owner, "QP query command");
        query_command.opcode_key = make_opcode_key(RDMA_OP_QPC_QUERY, "query");
        query_command.body = body;
        query_command.timeout = command_timeout;
        status = normalize_status(query_command.validate(),
                                  "QP query command validation returned null");
        if (status.ok()) begin
          ticket = null; completion = null;
          status = live_binding_fence(binding, expected_owner);
          if (status.ok())
            execute_qp_legacy_command(
              query_command, ticket, completion, status
            );
          else begin
            ticket = null;
            completion = null;
          end
          status = normalize_status(status, "QP query execution returned null");
          fence_status = live_binding_fence(binding, expected_owner);
          if (!fence_status.ok()) status = fence_status;
        end
        if (status.ok()) begin
          rdma_qpc_model queried_qpc;
          if (completion == null || completion.status == null ||
              !completion.status.ok()) begin
            if (status == null || status.code != RDMA_SC_STALE_GENERATION)
              status = rdma_status::make(
                RDMA_SC_RECOVERY_REQUIRED,
                "QP query completion is not successful");
          end
          else
            status = read_qpc_query_image(
              expected_owner,
              fresh_query_mapping ? query_mapping : recovery.query_mapping,
              recovery.candidate_qpc, queried_qpc);
          if (status.ok() && queried_qpc != null) begin
            if (same_qpc_snapshot(queried_qpc, recovery.candidate_qpc)) begin
              resolved_qpc = recovery.candidate_qpc;
              candidate_selected = 1'b1;
              terminal_known = 1'b1;
            end
            else if (same_qpc_snapshot(queried_qpc, recovery.prior_qpc)) begin
              resolved_qpc = recovery.prior_qpc;
              candidate_selected = 1'b0;
              terminal_known = 1'b1;
            end
            else begin
              status = rdma_status::make(RDMA_SC_RECOVERY_REQUIRED,
                                         "QP query image matches neither modify candidate");
            end
          end
        end
        // Any query execution/read/decode/classification failure is still a
        // temporary mapping ownership event.  Release it before publishing
        // RECOVERY_REQUIRED; if release is incomplete, retain it as opaque
        // recovery-only authority so a retry cannot leak or double-release.
        if (fresh_query_mapping && query_mapping != null &&
            (!status.ok() || !terminal_known)) begin
          query_release_complete = 1'b0;
          release_mapping_fenced(binding, expected_owner, query_mapping,
                                 "QP recovery failed query", status,
                                 query_release_complete);
          if (!query_release_complete) begin
            rdma_status retain_status;
            retain_status = manager.retain_qp_query_mapping(
              resource_h, query_mapping, 1'b1);
            if (retain_status == null || !retain_status.ok()) begin
              if (status.ok()) status = retain_status == null ?
                invalid_state("QP recovery failed query retention returned null") :
                retain_status;
            end
            else
              query_mapping_retained = 1'b1;
          end
          else
            query_mapping = null;
        end
        if (!terminal_known) begin
          query_unresolved = 1'b1;
          // A QPC_QUERY that cannot authenticate a complete image is
          // inconclusive regardless of whether the adapter reported a read,
          // decode, or terminal command error.  Normalize those details to
          // the recovery contract; preserve a stale-generation fence so the
          // caller can distinguish an invalidated authority boundary.
          if (status == null || status.code != RDMA_SC_STALE_GENERATION)
            status = rdma_status::make(
              RDMA_SC_RECOVERY_REQUIRED,
              "QP query did not prove a terminal image"
            );
        end
      end
      end
    end
    else if (status.ok()) begin
      // A previous invocation may already have reconciled the ticket.  In
      // that case the candidate is the only legal active replacement.
      resolved_qpc = recovery.candidate_qpc;
      candidate_selected = 1'b1;
    end
    if (status.ok() && resolved_qpc == null)
      status = invalid_state("QP recovery has no resolved QPC");

    // A query that did not prove candidate/prior still has to release its
    // temporary image before returning ERROR.  Preserve the mapping as
    // recovery-only authority if the release itself is not complete.
    if (query_unresolved && query_mapping != null) begin
      query_release_probe = null;
      if (fresh_query_mapping)
        release_mapping_fenced(binding, expected_owner, query_mapping,
                               "QP recovery query", status,
                               release_complete);
      else begin
        cloned = query_mapping.clone();
        if (cloned == null || !$cast(query_release_probe, cloned)) begin
          status = invalid_state("QP recovery query release probe clone failed");
          release_complete = 1'b0;
        end
        else
          release_mapping_fenced(binding, expected_owner, query_release_probe,
                                 "QP recovery query", status,
                                 release_complete);
      end
      if (!release_complete && query_mapping != null && fresh_query_mapping) begin
        rdma_status retain_status;
        retain_status = manager.retain_qp_query_mapping(
          resource_h, query_mapping, 1'b1);
        if (retain_status == null || !retain_status.ok())
          status = retain_status == null ?
            invalid_state("QP unresolved query retention returned null") :
            retain_status;
      end
      if (status.ok()) status = rdma_status::make(
        RDMA_SC_RECOVERY_REQUIRED, "QP query did not prove a terminal image");
    end
    if (status.ok()) begin
      staging = recovery.staging_mapping;
      if (!fresh_query_mapping)
        query_mapping = recovery.query_mapping;
      // Release through detached probes.  The persisted recovery mappings
      // remain byte-for-byte unchanged (and therefore continue to match the
      // manager's retained authority comparison), while the adapter's opaque
      // completion seal is shared by the probes and the retained mappings.
      if (staging != null) begin
        staging_release_probe = null;
        cloned = staging.clone();
        if (cloned == null || !$cast(staging_release_probe, cloned))
          status = invalid_state("QP recovery staging release probe clone failed");
        else
          release_mapping_fenced(binding, expected_owner,
                                 staging_release_probe,
                                 "QP recovery staging", status,
                                 release_complete);
      end
      if (status.ok() && query_mapping != null) begin
        if (fresh_query_mapping)
          release_mapping_fenced(binding, expected_owner, query_mapping,
                                 "QP recovery query", status,
                                 release_complete);
        else begin
          query_release_probe = null;
          cloned = query_mapping.clone();
          if (cloned == null || !$cast(query_release_probe, cloned))
            status = invalid_state("QP recovery query release probe clone failed");
          else
            release_mapping_fenced(binding, expected_owner,
                                   query_release_probe,
                                   "QP recovery query", status,
                                   release_complete);
        end
      end
    end
    if (status.ok() && recovery.ambiguous_operation == RDMA_QP_AMBIG_MODIFY) begin
      // Clear ambiguity only after all temporary authority releases have
      // completed.  TIMEOUT/RESET_CANCELLED therefore preserve the ticket.
      recovery.ambiguous_operation = RDMA_QP_AMBIG_NONE;
      recovery.ambiguous_ticket = null;
      status = manager.mark_qp_error(resource_h, recovery);
    end
    if (status.ok()) begin
      rdma_qp replacement;
      cloned = authoritative.clone();
      if (cloned == null || !$cast(replacement, cloned))
        status = invalid_state("QP recovery resource clone failed");
      else begin
        replacement.state = RDMA_RESOURCE_ACTIVE;
        replacement.programmed_qpc = resolved_qpc;
        replacement.qp_state = resolved_qpc.state;
        // RESET→INIT is intentionally semantic-only: if the prior hardware
        // image was RESET, restore the software INIT state when the prior
        // image wins reconciliation.
        if (!candidate_selected && resolved_qpc.state == RDMA_QPS_RESET)
          replacement.qp_state = RDMA_QPS_INIT;
        status = manager.commit_qp_programmed(replacement);
      end
    end
    if (status.ok()) begin
      result.final_resource_state = RDMA_RESOURCE_ACTIVE;
      result.final_resource_state_known = 1'b1;
      result.recovery_required = 1'b0;
      publish_primary(result, rdma_status::success());
    end
    else begin
      result.recovery_required = 1'b1;
      result.final_resource_state = RDMA_RESOURCE_ERROR;
      result.final_resource_state_known = 1'b1;
      publish_primary(result, status);
    end
  endtask
endclass
