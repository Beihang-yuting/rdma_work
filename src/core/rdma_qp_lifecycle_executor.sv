// 目录：核心执行层 core/rdma_qp_lifecycle_executor.sv。
// 职责：实现 rdma_qp_lifecycle_executor 在本层的职责和对外接口。
// 依赖：依赖本层公共 types/model/adapter 契约及其上游快照。
// 所有权与生命周期：对象只拥有显式创建的值快照；外部资源保存非拥有引用，生命周期由调用方管理。

class rdma_qp_lifecycle_executor extends uvm_object;
  // 生命周期执行器统一负责 QP backing 的分配、发布、恢复和最终清理。
  `uvm_object_utils(rdma_qp_lifecycle_executor)

  protected rdma_resource_manager manager;
  protected rdma_cmq_port cmq;
  // 最近一次经 rdma_cmq_dispatch 执行的命令是否被证明在提交前即被拒绝；仅供紧随其后的
  //   cmq_outcome_ambiguous 分类使用。
  protected bit last_cmq_no_submit;
  protected rdma_host_mem_api host_mem;
  protected rdma_context_backing_api context_backing;
  protected time command_timeout;
  protected rdma_hw_queue_pd_codec pd_codec;
  protected rdma_codec_registry qpc_codecs;

  // 功能：构造 rdma_qp_lifecycle_executor。
  // 输入/输出及副作用：name 为 UVM 对象名；字段置为默认值。
  // 失败/边界：无。
  function new(string name = "rdma_qp_lifecycle_executor");
    super.new(name);
    last_cmq_no_submit = 1'b0;
    manager = null;
    cmq = null;
    host_mem = null;
    context_backing = null;
    command_timeout = 0;
    pd_codec = rdma_hw_queue_pd_codec::type_id::create({name, "_pd"});
    qpc_codecs = rdma_codec_registry::type_id::create({name, "_qpc"});
  endfunction

  // 功能：构造 INVALID_ARGUMENT 状态。
  // 输入/输出及副作用：message 为诊断文本；返回新 status。
  // 失败/边界：无。
  protected function rdma_status invalid_argument(string message);
    return rdma_status::make(RDMA_SC_INVALID_ARGUMENT, message);
  endfunction

  // 功能：构造 INVALID_STATE 状态。
  // 输入/输出及副作用：message 为诊断文本；返回新 status。
  // 失败/边界：无。
  protected function rdma_status invalid_state(string message);
    return rdma_status::make(RDMA_SC_INVALID_STATE, message);
  endfunction

  // 功能：判断两个 Function handle 是否为同一实例。
  // 输入/输出及副作用：lhs/rhs 只读；返回 bit。
  // 失败/边界：任一为空返回 0。
  protected function bit same_owner(rdma_function_handle lhs,
                                    rdma_function_handle rhs);
    return lhs != null && rhs != null && lhs.same_instance(rhs);
  endfunction

  // 功能：把 null status 规范化为 INVALID_STATE。
  // 输入/输出及副作用：status 非空则原样返回，否则用 message 构造。
  // 失败/边界：无。
  protected function rdma_status normalize_status(rdma_status status,
                                                   string message);
    return status == null ? invalid_state(message) : status;
  endfunction

  // 功能：用 lifecycle result seed 创建 QP 操作的初始 control result。
  // 输入/输出及副作用：返回新 result，写入 transaction_id、pending status 与默认资源状态。
  // 失败/边界：result 分配失败返回 null；seed 分配/初始化失败返回带 INVALID_STATE 的结果；不检查 transaction_id。
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

  // 功能：确认 binding 仍 ACTIVE 且与 expected_owner 为同一 Function 实例。
  // 输入/输出及副作用：binding/expected_owner 只读；返回 status。
  // 失败/边界：入参为空返回 INVALID_ARGUMENT；binding 校验失败原样返回；状态/代际不符返回 STALE_GENERATION。
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

  // 功能：校验依赖后保存 manager/cmq/host_mem/context_backing 的非拥有引用并注册 QPC codec。
  // 输入/输出及副作用：入参只读；成功时写入成员引用与 command_timeout，并清空重建 qpc_codecs。
  // 失败/边界：任一依赖为空或 timeout 为 0 返回 INVALID_ARGUMENT；codec 未构造返回 INVALID_STATE；注册失败原样返回。
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

  // 功能：按 binding 与 Function identity 快照构造 QP backing 的 DMA 请求上下文。
  // 输入/输出及副作用：binding/qp_h 只读；request_context 输出新对象，路由与 epoch 取自同一份 identity 快照。
  // 失败/边界：入参为空返回 INVALID_ARGUMENT；分配失败返回 RESOURCE_EXHAUSTED；handle/identity 取不到或上下文校验失败返回错误。
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

  // 功能：把分配失败后仍持有的 mapping 包装成 recovery-only 的 backing_ref。
  // 输入/输出及副作用：mapping 作为不透明释放凭证保存，ownership 为 CONTROL_PLANE；backing_ref 输出。
  // 失败/边界：mapping 为空时成功且 backing_ref 为 null；ref 创建失败返回 RESOURCE_EXHAUSTED。
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
    // 该能力有意只用于恢复：即使 adapter 的公开几何/authority 快照 hook 畸形，
    // 非空 mapping 仍是不透明的释放/查询凭证；严格的 ring 校验留待正常 plan 发布时进行。
    backing_ref.recovery_only = 1'b1;
    return rdma_status::success();
  endfunction

  // 功能：经 host_mem 分配按 alignment 对齐的 QP backing，并校验几何与释放凭证。
  // 输入/输出及副作用：binding/owner/qp_h 输入；backing_ref 输出；分配前后各做一次 binding fence。
  // 失败/边界：长度为 0、超 32 位或 host_mem 为空返回 INVALID_ARGUMENT；任一步失败时已得到的 mapping 经
  //   retain_failed_allocation 保留以便恢复。
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
      // status 为 OK 但快照为 null 同样是畸形的 authority hook 结果；
      // 先保留原 mapping 以便恢复，再报告该错误。
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

  // 功能：以 4096 字节对齐分配 QP backing。
  // 输入/输出及副作用：转调 allocate_ref_aligned。
  // 失败/边界：同 allocate_ref_aligned。
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

  // 功能：把借用的 queue backing spec 克隆为 detached 的 backing_ref。
  // 输入/输出及副作用：spec 只读，仅克隆 mapping 快照，不改调用方对象的 owner/state；backing_ref 输出。
  // 失败/边界：spec 为空、首 slice 与 role 不符或 slice 不连续返回 INVALID_ARGUMENT；克隆失败返回 INVALID_STATE。
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
        if (!rdma_deep_copy#(rdma_dma_mapping)::try_of(spec.slices[i].mapping, mapping_clone))
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

  // 功能：为借用 backing 的主 mapping 与全部 segment 统一绑定 QP owner。
  // 输入/输出及副作用：先备齐所有 owner 快照与 Function authority 检查，再一次性写入 owner_h。
  // 失败/边界：入参无效、Function authority 缺失或 segment 不同属一个 Function、owner 克隆失败时返回错误，原 owner_h 全部不变。
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

    // 上面的检查已覆盖最终 authority 谓词可能拒绝的全部条件；候选 owner 集合齐备后才提交，
    // 并保留 canonical 谓词作为防御性后置检查。
    backing_ref.mapping.owner_h = primary_owner;
    foreach (backing_ref.additional_segments[i])
      backing_ref.additional_segments[i].mapping.owner_h = segment_owners[i];
    status = rdma_qp_mapping_authority_status(
      backing_ref, mapping_owner, qp_h, "QP borrowed"
    );
    if (status == null || !status.ok()) begin
      // 发布点之后仍保留 canonical 后置检查：若谓词将来增加未覆盖的条件，
      // 返回失败前须恢复全部 owner 字段。
      backing_ref.mapping.owner_h = prior_primary_owner;
      foreach (backing_ref.additional_segments[i])
        backing_ref.additional_segments[i].mapping.owner_h =
          prior_segment_owners[i];
    end
    return status;
  endfunction

  // 功能：按 role 与 depth 创建 QP ring 布局（64B 项，存储按 4KiB 取整）。
  // 输入/输出及副作用：ring 输出新 layout；logical/storage 字节数与 INDIRECT_4K 模式由 depth 推出。
  // 失败/边界：depth 非 2 的幂或字节数溢出返回 INVALID_ARGUMENT；创建失败返回 RESOURCE_EXHAUSTED。
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

  // 功能：为 SQ SGB 队列准备 backing_ref（每 slot 512B，存储按 4KiB 取整）。
  // 输入/输出及副作用：owned 模式经 allocate_ref_aligned 分配，否则 clone_borrowed_ref 克隆；ref_out 输出。
  // 失败/边界：几何计算失败原样返回；spec 为空返回 INVALID_ARGUMENT。
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

  // 功能：逐 slot（512B）把 SQ SGB backing 写零。
  // 输入/输出及副作用：request_context/backing_ref 只读；经 host_mem 写 mapping，可跨 segment 定位 slot。
  // 失败/边界：入参无效或 backing 过短返回 INVALID_ARGUMENT；某个 slot 跨 segment 边界时立即拒绝，不拆分写入。
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

  // 功能：把 payload backing 写零，并把各 4KiB 页编码进 page directory 后写入 pd_ref。
  // 输入/输出及副作用：经 host_mem 写 payload 各 segment 与 pd_ref；用 pd_codec 编码页表。
  // 失败/边界：payload 页覆盖不完整或编码结果不是一页返回 INVALID_STATE；页对象创建失败返回 RESOURCE_EXHAUSTED；写入/编码失败原样返回。
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
    // QP ref 直接保留首段借用范围，其余范围为 detached segment；
    // 按该规范覆盖关系解析每个 4KiB 逻辑页，不假设单一 mapping。

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
      // 页目录项只携带页 IOVA；既有 page ref 校验器早于 QP 专用 role，
      // 故使用其中性 ring 判别值，QP role authority 仍保存在 plan/ref 中。
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

  // 功能：在 plan.urc_refs 中按 role 查找 backing_ref。
  // 输入/输出及副作用：plan 只读；返回命中的引用（非拷贝）。
  // 失败/边界：未命中返回 null。
  protected function rdma_qp_backing_ref find_urc_ref(
    rdma_qp_backing_plan plan, rdma_queue_backing_role_e role
  );
    foreach (plan.urc_refs[i])
      if (plan.urc_refs[i] != null && plan.urc_refs[i].role == role)
        return plan.urc_refs[i];
    return null;
  endfunction

  // 功能：把已验证的 SQ/RQ/SGB/URC backing 规格落实为映射，生成 detached 的 QP backing plan。
  // 输入/输出及副作用：binding/owner/qp_snapshot/request 只读；plan 输出新 ring、mapping、PD、SRQ link 与 URC refs；
  //   不发布 manager 资源。
  // 失败/边界：入参为空、QPN 超 21 位、queue 能力/几何校验或任一 backing/URC 分配失败返回对应 status；已追加到 plan 的 refs 交由上层回滚。
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
      // 保留 manager 投影出的 handle 对象，使 QP 资源与 plan 在后续发布副本中共用同一身份 authority。
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

  // 功能：由 source 克隆并改写 object_id，投影出本地资源 handle。
  // 输入/输出及副作用：projected 输出新 handle，object_id 设为 local_id。
  // 失败/边界：克隆失败或 kind 不符返回 INVALID_STATE。
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

  // 功能：从 manager 取回 QPC 依赖的 PD、send/recv CQ、SRQ 与序列号快照。
  // 输入/输出及副作用：只读查询；pd/send_cq/recv_cq/srq/qp_sequence_value 输出 detached 对象。
  // 失败/边界：入参为空返回 INVALID_ARGUMENT；任一依赖查询返回 null/无效返回 INVALID_STATE 或原错误。
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

  // 功能：按 request、plan 与依赖快照构造语义 QPC model。
  // 输入/输出及副作用：model 输出新对象；对 AV、behavior、transport 扩展等做克隆，与输入隔离。
  // 失败/边界：入参为空或 QPN 超 21 位返回 INVALID_ARGUMENT；分配/克隆失败或 SRQ plan 无效返回
  //   RESOURCE_EXHAUSTED/INVALID_STATE。
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
      // 接收页目录的硬件基址由 SRQ queue plan 持有。
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

  // 功能：按 transport 选择 codec 编码 QPC 为 512 字节 image，并写入 staging 缓冲。
  // 输入/输出及副作用：staging 输出新 mapping（512B 对齐），image 输出编码镜像；编码后做往返校验。
  // 失败/边界：入参为空、transport 无 codec 返回 INVALID_ARGUMENT；image 非 512B、往返不符或 staging 未对齐返回
  //   INVALID_STATE。
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

  // 功能：把 create 请求、plan 与 QPC model 写入 candidate，并交 manager 登记编程信息。
  // 输入/输出及副作用：candidate 被写入 transport/depth/iova/qp_plan/programmed_qpc，初始状态 RESET。
  // 失败/边界：入参为空返回 INVALID_ARGUMENT；manager 返回 null 规范化为 INVALID_STATE。
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

  // 功能：判断一次 CMQ 执行结果是否无法确定是否已生效。
  // 输入/输出及副作用：status/ticket/completion 只读；委托 rdma_cmq_ambiguity_policy。
  // 失败/边界：无。
  protected function bit cmq_outcome_ambiguous(
    rdma_status status,
    rdma_cmq_ticket ticket,
    rdma_cmq_completion completion
  );
    return rdma_cmq_ambiguity_policy::is_ambiguous(
      status,
      ticket,
      completion,
      last_cmq_no_submit,
      1'b1,
      1'b0,
      1'b1
    );
  endfunction

  // 功能：QP 各阶段共用的 CMQ 调用，经 rdma_cmq_dispatch 执行一次 execute_observed。
  // 输入/输出及副作用：输出 ticket/completion/status（后端 status 原样，可为 null）并更新
  //   last_cmq_no_submit；不做 fence、歧义分类或状态提交。
  // 失败/边界：cmq 为空返回 INVALID_STATE；command 为空返回 INVALID_ARGUMENT；不重试。
  protected task execute_qp_command(
    rdma_cmq_command_desc command,
    output rdma_cmq_ticket ticket,
    output rdma_cmq_completion completion,
    output rdma_status status
  );
    rdma_cmq_dispatch(
      cmq,
      command,
      ticket,
      completion,
      status,
      last_cmq_no_submit,
      "QP CMQ is unavailable",
      "QP CMQ command is null"
    );
  endtask

  // 功能：判断两个 QPC model 的序列化内容是否一致。
  // 输入/输出及副作用：lhs/rhs 只读；按 transport 查 qpc codec 并调用 serialized_equal。
  // 失败/边界：任一为空或 transport 不同时退化为对象相等比较；transport 不支持或 codec 缺失返回 0。
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

  // 读取并认证设备返回的完整 512 字节 QPC 镜像；CMQ completion payload 只是传输元数据，
  // 不能替代 DMA 查询镜像。
  // 功能：读取并解码设备经 DMA 返回的完整 512 字节 QPC 查询镜像。
  // 输入/输出及副作用：query_mapping 经 host_mem 读取；queried_qpc 输出解码结果。
  // 失败/边界：入参不全或 transport 不支持返回 INVALID_ARGUMENT；映射非 512B、读长不符或 codec 缺失返回 INVALID_STATE。
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
    // QPC 镜像只携带本地 QPN 与投影后的资源 kind；function UID/generation 属传输元数据，
    // 不在镜像中序列化，因此只比较镜像自身拥有的身份字段。
    if (queried_qpc.qp_h == null || reference_qpc.qp_h == null ||
        queried_qpc.qp_h.kind != reference_qpc.qp_h.kind ||
        queried_qpc.qp_h.object_id != reference_qpc.qp_h.object_id)
      return invalid_state("QP query image QPN identity does not match");
    return normalize_status(queried_qpc.validate(),
                           "QP query decoded QPC validation returned null");
  endfunction

  // 用 binding generation fence 前后包住 adapter 副作用：前置 fence 防止用过期 authority 发起操作，
  // 后置 fence 让并发 rebind 在调用方持久化完成里程碑之前可见。
  // 功能：在 binding fence 前后包住一次 mapping 释放。
  // 输入/输出及副作用：status 输出释放结果，release_complete 标记是否释放完成。
  // 失败/边界：前置 fence 失败则不释放；后置 fence 失败会覆盖 status。
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

  // 对临时或保留的 mapping 发 QPC_QUERY，只据已认证的 DMA 镜像分类。终态命令失败可作为
  // 不存在的证据；超时/复位、completion 畸形或 codec 失败均不确定。mapping 总会被释放
  // （作为持久 authority 时经 detached probe）；opaque completion 未完成时调用方可保留它。
  // 功能：对临时或保留的 mapping 发 QPC_QUERY，只依据已认证的 DMA 镜像判定 QPC 是否存在。
  // 输入/输出及副作用：presence/conclusive/status 输出判定；query_mapping 总会被释放，release_complete 标记结果。
  // 失败/边界：终态命令失败可作为不存在的证据；超时/复位、completion 畸形或 codec 失败均视为不确定。
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
        execute_qp_command(
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
          // QPC_QUERY 命令成功但镜像不可读/畸形/无法解码，既不能证明存在也不能证明不存在；
          // 保持恢复契约稳定并 fail-closed，不向调用方暴露 codec/读取细节。
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
        // 终态非 OK 的 QPC_QUERY 结果证明不存在匹配该 QPN 的 context；
        // completion payload 不参与镜像认证，仅用于这个终态 status。
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
    // 即使命令执行或镜像认证失败也要释放；若为持久 authority，用 detached clone 保持其公开身份，
    // opaque completion seal 仍共享。
    if (query_mapping != null) begin
      release_probe = null;
      if (fresh_mapping)
        release_mapping_fenced(binding, expected_owner, query_mapping,
                               "QP presence query", release_status,
                               release_complete);
      else begin
        if (!rdma_deep_copy#(rdma_dma_mapping)::try_of(query_mapping, release_probe)) begin
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

  // 功能：构造 QP 命令 codec 的 opcode 键。
  // 输入/输出及副作用：opcode/variant 输入；返回新 key。
  // 失败/边界：无。
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

  // 功能：构造 QPC 类 CMQ 命令（body 与 staging 缓冲）。
  // 输入/输出及副作用：command 输出；克隆 model 中的 QP/CQ handle，不修改输入。
  // 失败/边界：owner/model/qp_h 缺失返回 INVALID_ARGUMENT；staging 为空等校验失败返回对应错误。
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

  // 功能：为 QP 回滚或销毁构造 canonical OCC_FLUSH 命令。
  // 输入/输出及副作用：command 输出；pd_ref 为空时走 QPN 路径（EIRQE/ORQE/UAQE），否则只选 PD backing。
  // 失败/边界：owner 为空、local_qpn 超 21 位、PD mapping 为空或 body/command 校验失败返回错误；QPN 0 合法。
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

  // 功能：把失败的回滚 status 克隆追加到 result.rollback_statuses。
  // 输入/输出及副作用：result 被追加；status 为空或成功时不追加。
  // 失败/边界：result 为空时无操作。
  protected function void append_rollback_status(
    rdma_control_result result, rdma_status status
  );
    if (result != null && status != null && !status.ok())
      result.rollback_statuses.push_back(rdma_cmq_clone_status_value(status));
  endfunction

  // 功能：经 host_mem 释放 mapping，并以 adapter 的释放完成状态为准。
  // 输入/输出及副作用：release_complete 输出是否已完成；释放前后各查询一次完成状态。
  // 失败/边界：mapping 为空返回 INVALID_ARGUMENT；释放后仍未完成返回 RECOVERY_REQUIRED（或释放错误）。
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

  // 功能：经 context_backing 释放 context_ref，并以 adapter 的释放完成状态为准。
  // 输入/输出及副作用：release_complete 输出是否已完成；释放前后各查询一次完成状态。
  // 失败/边界：context_ref 为空返回 INVALID_ARGUMENT；释放后仍未完成返回 RECOVERY_REQUIRED（或释放错误）。
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

  // 功能：释放 owned 的 backing_ref，borrowed 或已清理的直接视为成功。
  // 输入/输出及副作用：成功完成时置 cleanup_complete；失败 status 追加到 result 回滚记录。
  // 失败/边界：owned ref 缺少 mapping 返回 INVALID_STATE；释放失败原样返回。
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

  // 功能：按逆序释放部分建立的 plan：context、URC、PD、RQ、SGB、SQ。
  // 输入/输出及副作用：逐项置完成标志并记录回滚 status。
  // 失败/边界：遇到第一个失败即停止并返回该 status。
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

  // 功能：把规范化后的 primary status 写入 result.primary_status 与 status。
  // 输入/输出及副作用：result 被写入；primary 为 null 时规范化为 INVALID_STATE。
  // 失败/边界：无。
  protected function void publish_primary(
    rdma_control_result result,
    rdma_status primary
  );
    rdma_status normalized;
    normalized = normalize_status(primary, "QP create primary status is null");
    result.primary_status = rdma_cmq_clone_status_value(normalized);
    result.status = rdma_cmq_clone_status_value(normalized);
  endfunction

  // 功能：组装 QP CREATE 的临时恢复 shell。
  // 输入/输出及副作用：recovery 输出；plan/context/QPC/staging 仅借用，最终快照由 manager.mark_qp_error 的
  //   authority-aware projector 建立。
  // 失败/边界：shell 创建、opcode/ticket 克隆或 recovery.validate 失败返回对应 status；不得用 plan.clone 代替 projector。
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

  // 功能：组装 QP MODIFY 的临时恢复 shell，记录 prior/candidate QPC、mapping 与重放 opcode。
  // 输入/输出及副作用：recovery 输出；各对象仅借用，shell 只供随后的 mark_qp_error 投影。
  // 失败/边界：authoritative、plan/context 或 prior/candidate QPC 缺失返回 INVALID_ARGUMENT；
  //   ticket/克隆/校验失败返回对应错误。
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

  // 功能：MODIFY 结果不确定或失败时，组装恢复 shell 并交 manager 建立持久 ERROR authority。
  // 输入/输出及副作用：primary/ticket/staging/query_mapping 等借用输入；result 输出带恢复证据的结果。
  // 失败/边界：恢复 shell 组装或 manager 发布失败时，在 result 中保留对应 status，不重新激活旧状态。
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

  // 功能：执行一次终态 CMQ 命令（回滚/删除类），并分类结果是否歧义。
  // 输入/输出及副作用：status/ambiguous 输出结论；recovery_ticket 输出可对账的 ticket。
  // 失败/边界：执行结果无法确定是否生效时 ambiguous=1，并尽量保留 ticket 供恢复。
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
    execute_qp_command(command, ticket, completion, status);
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

  // 功能：回滚已 attach 的 QP：按需发 OCC_FLUSH 与 QPC delete，再按序释放 context 与 backing。
  // 输入/输出及副作用：released 输出是否已全部释放；回滚进度写入 result，失败时发布 ERROR 恢复证据。
  // 失败/边界：OCC/delete 结果歧义时返回 RECOVERY_REQUIRED 并保留恢复信息；各释放步骤失败时停止。
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

  // 功能：回滚尚未 attach 的 QP：释放部分建立的 plan 与 staging mapping。
  // 输入/输出及副作用：candidate/plan/staging 只读借用；清理状态写入 result。
  // 失败/边界：释放失败时保留 create 恢复证据（retain_create_recovery）并返回，不继续释放。
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

  // 功能：CREATE 失败或歧义时，组装恢复 shell 并交 manager 建立持久 ERROR authority。
  // 输入/输出及副作用：plan/model/staging/ticket 借用输入；结果写入 result。
  // 失败/边界：shell 组装或发布失败时在 result 中保留对应 status。
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

  // 功能：在锁内完成 QP 创建：fence、manager.create_qp、materialize_plan、QPC 编码与 CMQ 下发、attach、activate。
  // 输入/输出及副作用：qp/result 输出；每个阶段前后复核 binding fence，失败时按阶段走回滚或恢复证据。
  // 失败/边界：超时、reset 取消、generation 过期或回滚需恢复时返回
  //   TIMEOUT/RESET_CANCELLED/STALE_GENERATION/RECOVERY_REQUIRED，并给出恢复证据。
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
      if (!rdma_deep_copy#(rdma_function_binding)::try_of(binding, binding_snapshot) ||
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
    execute_qp_command(command, ticket, completion, status);
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

  // 功能：在锁内完成 QP 状态修改：先取 transition policy 的 decision，再下发 QPC_MODIFY 并发布新状态。
  // 输入/输出及副作用：qp/result 输出；成功后提交 programmed QPC 与语义状态；失败/歧义时持久化 ERROR 恢复证据。
  // 失败/边界：transaction_id 为 0、未配置、目标非 ACTIVE QP、有未完成操作返回 BUSY、SQD/SQE 不支持返回 UNSUPPORTED_OPCODE。
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
      if (!rdma_deep_copy#(rdma_qpc_model)::try_of(authoritative.programmed_qpc, prior_qpc))
        status = invalid_state("QP prior QPC clone failed");
    end
    if (status.ok()) begin
      if (!rdma_deep_copy#(rdma_qpc_model)::try_of(prior_qpc, candidate_qpc))
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
                // URC 的 PSN 属性直接映射到扩展中的 destination/source 序号。
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
      execute_qp_command(command, ticket, completion, status);
      // 部分 CMQ adapter 只通过 completion 暴露权威 ticket；先取回再分类，
      // 使确定的 completion 保持确定，歧义的仍保留可对账 ticket。
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
      // 恢复持有独立的查询缓冲：该 mapping 在发布 ERROR 前分配，
      // 直到恢复证明硬件镜像不再引用它之前保持存活。
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
      // 查询缓冲分配失败本身无法证明硬件状态，但 modify 歧义仍须成为持久 ERROR authority；
      // 恢复在缓冲可用前报告 RECOVERY_REQUIRED，绝不猜测 ACTIVE 或丢弃 ticket/staging。
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
      // 确定的命令失败仍可能留下释放未完成的 staging mapping；
      // 应尽量保存在持久恢复 authority 中，而不是丢弃该能力。
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
        // 命令已完成但临时 authority 未释放完：按歧义 modify 处理，让恢复恰好释放一次。
        retain_modify_recovery(authoritative, prior_qpc, candidate_qpc,
                               staging, null, 1'b0, ticket, status, result);
        qp = null;
        return;
      end
      staging = null;
    end
    begin
      rdma_qp candidate;
      if (!rdma_deep_copy#(rdma_qp)::try_of(authoritative, candidate))
        status = invalid_state("QP candidate resource clone failed");
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
      // 此时硬件已接受 MODIFY；发布失败必须成为持久 ERROR 恢复 authority，
      // 而不是忘记候选镜像的普通确定性错误。
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

  // 功能：在锁内完成 QP 销毁：ERROR/flush/delete/cleanup。
  // 输入/输出及副作用：result 输出；失败时用借用的 qp_plan 组装恢复 shell，交 manager.mark_qp_error 建立持久 authority。
  // 失败/边界：owner/generation 不符、资源不存在或任一阶段失败时返回错误并保留 recovery 证据；不转移 mapping/HMC/QPC 所有权。
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
    // flush 队列前先把设备迁到 ERROR（已是 ERROR 则跳过），这是仅改状态的 QPC_MODIFY。
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
    // 依次 flush QPN 的 EIRQ/ORQ/UAQ、SQ-PD 与私有 RQ-PD（SRQ 支持的 QP 省略私有 RQ-PD）。
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
      // URC ref 按 planner 的逆序释放；上面的紧凑列表通过显式按规范顺序迭代来修正。
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
        // finalize 可能在 generation rebind 可见前已删除旧登记项；
        // 保留成功的释放结果，同时把过期边界报告给调用方。
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
    // 在成功记录 flush/context 进度后刷新 manager 权威 plan；lookup 只返回 detached 投影，
    // 因此此前的 quiesce 前快照已过期。
    refresh_status = normalize_status(manager.lookup(qp.handle, snapshot),
                                      "QP destroy progress refresh returned null");
    if (refresh_status.ok() && $cast(qp, snapshot)) begin
      prior_qpc = qp.programmed_qpc;
    end
    primary = rdma_cmq_clone_status_value(status);
    // 任何硬件副作用都会留下 ERROR 恢复 authority；尝试过 ERROR modify、flush 或 delete 后
    // 绝不恢复为 ACTIVE。
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

  // 续做已进入 ERROR 且已产生硬件/adapter 副作用的 destroy；每个里程碑在下一副作用前
  // 经 resource manager 持久化，重试可从第一个未完成操作继续。
  // 功能：续做已进入 ERROR 的 destroy/create-rollback：按持久 recovery 记录从第一个未完成步骤继续。
  // 输入/输出及副作用：result 输出；每个里程碑先经 resource manager 持久化再做下一个副作用；歧义时按 ticket 对账或回退到 QPC_QUERY。
  // 失败/边界：目标非 ERROR QP、recovery 记录缺失/intent 不符/缺 QPC 返回 INVALID_*；无 ticket 或无法证明状态时保持 fail-closed。
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
      if (!rdma_deep_copy#(rdma_qp_recovery_state)::try_of(record.qp_recovery, recovery))
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

    // 只对账持久 ticket 所指的操作；reset 取消或缺少终态结果时保持 ticket 不动。
    if (recovery.ambiguous_operation != RDMA_QP_AMBIG_NONE) begin
      reconciled_operation = recovery.ambiguous_operation;
      if (recovery.ambiguous_ticket == null) begin
        // 无 ticket 的歧义无法对账：保持 ERROR fail-closed，待后续恢复获得新证据。
        result.recovery_required = 1'b1;
        result.final_resource_state = RDMA_RESOURCE_ERROR;
        result.final_resource_state_known = 1'b1;
        publish_primary(result, rdma_status::make(
          RDMA_SC_RECOVERY_REQUIRED,
          "QP destroy ambiguity has no reconciliation ticket"));
        return;
      end
      // 此前已认证的 QPC_QUERY 镜像是持久证据，可避免重复查询或重复原副作用。
      if (recovery.query_presence_known &&
          (reconciled_operation inside {RDMA_QP_AMBIG_CREATE,
                                        RDMA_QP_AMBIG_DELETE})) begin
        if (recovery.query_mapping != null) begin
          rdma_dma_mapping retained_probe;
          retained_probe = null;
          if (!rdma_deep_copy#(rdma_dma_mapping)::try_of(
                recovery.query_mapping, retained_probe)) begin
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
          // CREATE/DELETE 可由已认证的 QPC_QUERY 镜像消歧；其它 destroy 步骤无 ticket 时保持 fail-closed。
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
            if (!rdma_deep_copy#(rdma_dma_mapping)::try_of(
                  recovery.query_mapping, malformed_probe)) begin
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
        // 终态 completion 失败仍是权威证据；reconcile 可能返回与 completion 相同的非 OK status，
        // 只有超时/复位仍视为歧义。
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
        // 先清除操作 ticket 再记录操作相关进度；manager 强制该歧义迁移顺序。
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
          // manager 更新进度后重新读取持久快照。
          status = normalize_status(manager.lookup_recovery(resource_h, record),
                                    "QP destroy recovery refresh returned null");
          if (status.ok() && record != null && record.qp_recovery != null) begin
            if (!rdma_deep_copy#(rdma_qp_recovery_state)::try_of(record.qp_recovery, recovery))
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

    // CREATE staging 是独立于 QP context 与 backing recipe 的临时 DMA authority；
    // CREATE ticket 有终态证据后释放，detached probe 保留 adapter 的 opaque completion seal 且不改持久 authority。
    if (create_rollback && recovery.staging_mapping != null) begin
      staging_probe = null;
      if (!rdma_deep_copy#(rdma_dma_mapping)::try_of(
            recovery.staging_mapping, staging_probe)) begin
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

    // 若失败前尚未完成，则执行 ERROR 迁移。
    if (!hardware_present) begin
      // 终态 CREATE 失败证明未安装 QP context，没有合法的 ERROR 迁移或硬件 flush 可发。
      recovery.error_modify_complete = 1'b1;
      recovery.delete_complete = 1'b1;
      status = normalize_status(
        manager.update_qp_recovery_progress(resource_h, recovery),
        "QP create absent progress update returned null");
    end
    else if (!recovery.error_modify_complete) begin
      status = live_binding_fence(binding, expected_owner);
      if (status.ok()) begin
        if (!rdma_deep_copy#(rdma_qpc_model)::try_of(destroy_qpc, error_qpc))
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

    // 按规范顺序 flush 各 role，跳过已持久化的。
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
          if (!rdma_deep_copy#(rdma_qp_recovery_state)::try_of(
                record.qp_recovery, recovery)) begin
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
        if (!rdma_deep_copy#(rdma_qp_recovery_state)::try_of(
              record.qp_recovery, recovery)) begin
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

    // context 的释放先于全部 owned backing。
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
        if (!rdma_deep_copy#(rdma_qp_recovery_state)::try_of(record.qp_recovery, recovery))
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
        if (!rdma_deep_copy#(rdma_dma_mapping)::try_of(refs[i].mapping, probe))
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
        if (!rdma_deep_copy#(rdma_qp_recovery_state)::try_of(
              record.qp_recovery, recovery)) begin
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

  // 功能：对 ERROR 状态的 QP 做恢复：按 recovery intent 对账 create/modify/destroy 的歧义操作。
  // 输入/输出及副作用：result 输出；对账 ticket、必要时用 QPC_QUERY 判定硬件状态，并持久化进度。
  // 失败/边界：入参无效、目标非 ERROR QP、recovery 记录缺失或 intent 不支持返回错误；无法判定时返回 RECOVERY_REQUIRED，不猜测状态。
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
      if (!rdma_deep_copy#(rdma_qp_recovery_state)::try_of(record.qp_recovery, recovery))
        status = invalid_state("QP recovery snapshot clone failed");
    end
    // CREATE 歧义同样交给 destroy 风格的 recipe：可对账原 ticket，仍未知时用已认证的 QPC_QUERY 兜底，
    // 不会重复发起 CREATE 副作用。
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
      // 无未决 ticket 的 CREATE 恢复属于 program 之前或已对账的记录，此时没有权威 QP 硬件，走本地清理 recipe。
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
      // 畸形的查询分配只保留为不透明释放凭证，不能用于 QPC_QUERY；先完成其释放再对账 modify ticket。
      // mapping 以 recovery-only 位留在恢复记录中，使完成证明与恰好一次释放在重试间持久。
      if (recovery.query_mapping_recovery_only &&
          recovery.query_mapping != null) begin
        // 经 detached probe 释放，使恢复记录保持 ACTIVE 的公开 mapping 值以便与 manager authority 比较；
        // probe 与保留的 mapping 共享 opaque completion seal，完成状态持久且不改持久快照。
        query_release_probe = null;
        if (!rdma_deep_copy#(rdma_dma_mapping)::try_of(
              recovery.query_mapping, query_release_probe)) begin
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
        // 无 ticket 记录无法经 CMQ 对账：保留了 staging 说明候选不权威；无 staging 说明硬件在发布失败前已接受候选。
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
        // 有 ticket 但无终态 completion 时，用专用 QPC_QUERY 镜像对账；查询缓冲独立于 modify staging，属持久 authority。
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
            // adapter 可能在返回分配错误的同时给出非空 mapping；若其释放尚未被证明，返回前先保留为 recovery-only 能力。
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
            execute_qp_command(
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
        // 查询的执行/读取/解码/分类失败仍是临时 mapping 的所有权事件：发布 RECOVERY_REQUIRED 前先释放，
        // 释放未完成则保留为 opaque recovery-only authority，避免重试时泄漏或重复释放。
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
          // 无法认证完整镜像的 QPC_QUERY 不确定，无论 adapter 报告读取、解码还是终态命令错误；
          // 统一归一为恢复契约，仅保留 stale-generation fence 以便调用方识别 authority 边界失效。
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
      // 前一次调用可能已完成 ticket 对账，此时候选是唯一合法的 active 替代。
      resolved_qpc = recovery.candidate_qpc;
      candidate_selected = 1'b1;
    end
    if (status.ok() && resolved_qpc == null)
      status = invalid_state("QP recovery has no resolved QPC");

    // 未能证明候选/先前状态的查询，返回 ERROR 前仍须释放其临时镜像；释放未完成则保留为 recovery-only authority。
    if (query_unresolved && query_mapping != null) begin
      query_release_probe = null;
      if (fresh_query_mapping)
        release_mapping_fenced(binding, expected_owner, query_mapping,
                               "QP recovery query", status,
                               release_complete);
      else begin
        if (!rdma_deep_copy#(rdma_dma_mapping)::try_of(
              query_mapping, query_release_probe)) begin
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
      // 经 detached probe 释放：持久恢复 mapping 逐字节不变（继续与 manager 保留的 authority 比较一致），
      // probe 与保留 mapping 共享 adapter 的 opaque completion seal。
      if (staging != null) begin
        staging_release_probe = null;
        if (!rdma_deep_copy#(rdma_dma_mapping)::try_of(staging, staging_release_probe))
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
          if (!rdma_deep_copy#(rdma_dma_mapping)::try_of(query_mapping, query_release_probe))
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
      // 所有临时 authority 释放完成后才清除歧义；TIMEOUT/RESET_CANCELLED 因此保留 ticket。
      recovery.ambiguous_operation = RDMA_QP_AMBIG_NONE;
      recovery.ambiguous_ticket = null;
      status = manager.mark_qp_error(resource_h, recovery);
    end
    if (status.ok()) begin
      rdma_qp replacement;
      if (!rdma_deep_copy#(rdma_qp)::try_of(authoritative, replacement))
        status = invalid_state("QP recovery resource clone failed");
      else begin
        replacement.state = RDMA_RESOURCE_ACTIVE;
        replacement.programmed_qpc = resolved_qpc;
        replacement.qp_state = resolved_qpc.state;
        // RESET→INIT 有意仅改语义状态：若先前硬件镜像为 RESET 且其在对账中胜出，则恢复软件 INIT 状态。
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
