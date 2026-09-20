// 目录：协议与资源模型层 model/rdma_resources.sv。
// 职责：实现 rdma_resources 在本层的职责和对外接口。
// 依赖：依赖本层公共 types/model/adapter 契约及其上游快照。
// 所有权与生命周期：对象只拥有显式创建的值快照；外部资源保存非拥有引用，生命周期由调用方管理。

// 中文说明：rdma_resources.sv 属于模型层，描述语义请求、资源快照、DMA 映射及生命周期数据。
// 阅读提示：先看公开类型和接口，再看实现细节；失败路径应保持状态与资源所有权可追踪。

typedef class rdma_qpc_model;
typedef class rdma_cqc_model;

// 功能：rdma_clone_handle_value 复制 source、copy_label 的受控字段并生成独立快照，供查询、编码或恢复使用；源对象保持不变。
// 输入/输出及副作用：source（输入）、copy_label（输入）；rdma_clone_handle_value 读取 source、copy_label 并使用字段 cloned_object；函数返回 rdma_handle，不取得调用方资源所有权。
// 失败/边界：rdma_clone_handle_value 在源对象为空、clone/cast 失败或类型不匹配时触发 UVM fatal，不保留部分有效快照。
function automatic rdma_handle rdma_clone_handle_value(
  rdma_handle source,
  string copy_label
);
  uvm_object cloned_object;
  rdma_handle cloned_handle;

  if (source == null)
    return null;
  cloned_object = source.clone();
  if (cloned_object == null || !$cast(cloned_handle, cloned_object))
    `uvm_fatal("RDMA_COPY_TYPE", {copy_label, " handle clone type mismatch"})
  return cloned_handle;
endfunction

// 功能：rdma_clone_function_handle_value 复制 source、copy_label 的受控字段并生成独立快照，供查询、编码或恢复使用；源对象保持不变。
// 输入/输出及副作用：source（输入）、copy_label（输入）；rdma_clone_function_handle_value 读取 source、copy_label 并使用字段 cloned_object；函数返回 rdma_function_handle，不取得调用方资源所有权。
// 失败/边界：rdma_clone_function_handle_value 在源对象为空、clone/cast 失败或类型不匹配时触发 UVM fatal，不保留部分有效快照。
function automatic rdma_function_handle rdma_clone_function_handle_value(
  rdma_function_handle source,
  string copy_label
);
  uvm_object cloned_object;
  rdma_function_handle cloned_handle;

  if (source == null)
    return null;
  cloned_object = source.clone();
  if (cloned_object == null || !$cast(cloned_handle, cloned_object))
    `uvm_fatal("RDMA_COPY_TYPE", {copy_label, " function handle mismatch"})
  return cloned_handle;
endfunction

// 功能：rdma_ring_state_valid 比较 producer_index、producer_wrap、consumer_index、consumer_wrap 与当前 authority/状态字段，返回布尔结果供上层执行精确分支。
// 输入/输出及副作用：producer_index（输入）、producer_wrap（输入）、consumer_index（输入）、consumer_wrap（输入）；rdma_ring_state_valid 读取 producer_index、producer_wrap、consumer_index、consumer_wrap 并使用输入参数和固定枚举/常量；函数返回 bit，不取得调用方资源所有权。
// 失败/边界：rdma_ring_state_valid 先检查 producer_wrap == consumer_wrap，再返回 producer_index >= consumer_index；producer_index <= consumer_index；拒绝分支不提交部分状态，也不隐式重试。
function automatic bit rdma_ring_state_valid(
  int unsigned producer_index,
  bit producer_wrap,
  int unsigned consumer_index,
  bit consumer_wrap
);
  if (producer_wrap == consumer_wrap)
    return producer_index >= consumer_index;
  return producer_index <= consumer_index;
endfunction

// 功能：rdma_qp_projected_handle_status 校验 projected_h、dependency_h、owner、expected_kind、label 与当前对象状态的一致性，并显式处理“handle kind is invalid”等拒绝条件，返回 rdma_status 供上层决定是否提交。
// 输入/输出及副作用：projected_h（输入）、dependency_h（输入）、owner（输入）、expected_kind（输入）、label（输入）；rdma_qp_projected_handle_status 读取 projected_h、dependency_h、owner、expected_kind、label 并使用字段 status；函数返回 rdma_status，不取得调用方资源所有权。
// 失败/边界：rdma_qp_projected_handle_status 返回 RDMA_SC_INVALID_ARGUMENT；失败路径不提交部分状态或转移未声明资源。
function automatic rdma_status rdma_qp_projected_handle_status(
  rdma_handle projected_h,
  rdma_handle dependency_h,
  rdma_function_handle owner,
  rdma_resource_kind_e expected_kind,
  string label
);
  rdma_status status;

  if (projected_h == null || dependency_h == null ||
      projected_h.kind != expected_kind || dependency_h.kind != expected_kind)
    return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                             {label, " handle kind is invalid"});
  status = rdma_handle_owner_status(dependency_h, owner);
  if (!status.ok())
    return status;
  status = rdma_handle_owner_status(projected_h, owner);
  if (!status.ok())
    return status;
  return rdma_status::success();
endfunction

// 功能：rdma_qp_mapping_authority_status 校验 backing_ref、owner、qp_h、label 与当前对象状态的一致性，并显式处理“mapping authority is missing”等拒绝条件，返回 rdma_status 供上层决定是否提交。
// 输入/输出及副作用：backing_ref（输入）、owner（输入）、qp_h（输入）、label（输入）；rdma_qp_mapping_authority_status 读取 backing_ref、owner、qp_h、label 并使用字段 rdma_status、function_h、owner_h、mapping、mapping.function_h；函数返回 rdma_status，不取得调用方资源所有权。
// 失败/边界：rdma_qp_mapping_authority_status 返回 RDMA_SC_INVALID_STATE、RDMA_SC_INVALID_ARGUMENT；失败路径不提交部分状态或转移未声明资源。
function automatic rdma_status rdma_qp_mapping_authority_status(
  rdma_qp_backing_ref backing_ref,
  rdma_function_handle owner,
  rdma_handle qp_h,
  string label
);
  // 所有 segment 都必须属于同一 Function，并绑定到当前 QP handle。
  if (backing_ref == null || backing_ref.mapping == null)
    return rdma_status::make(RDMA_SC_INVALID_STATE,
                             {label, " mapping authority is missing"});
  if (backing_ref.mapping.function_h == null ||
      !backing_ref.mapping.function_h.same_instance(owner))
    return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                             {label, " mapping Function does not match"});
  if (backing_ref.mapping.owner_h == null ||
      !backing_ref.mapping.owner_h.same_instance(qp_h))
    return rdma_status::make(RDMA_SC_INVALID_STATE,
                               {label, " mapping QP owner does not match"});
  foreach (backing_ref.additional_segments[i]) begin
    if (backing_ref.additional_segments[i] == null ||
        backing_ref.additional_segments[i].mapping == null ||
        backing_ref.additional_segments[i].mapping.function_h == null ||
        !backing_ref.additional_segments[i].mapping.function_h.same_instance(owner) ||
        backing_ref.additional_segments[i].mapping.owner_h == null ||
        !backing_ref.additional_segments[i].mapping.owner_h.same_instance(qp_h))
      return rdma_status::make(RDMA_SC_INVALID_STATE,
                               {label, " segment mapping authority is invalid"});
  end
  return rdma_status::success();
endfunction

// A failed allocation can carry an adapter-owned release capability even when
// its public ring geometry is malformed.  Recovery-only references validate
// only the identity needed to route cleanup plus the opaque completion query;
// normal QP plans continue to use the strict geometry validator below.
// 功能：rdma_qp_recovery_opaque_mapping_status 校验 mapping、owner、qp_h、label 与当前对象状态的一致性，并显式处理“mapping authority is missing”等拒绝条件，返回 rdma_status 供上层决定是否提交。
// 输入/输出及副作用：mapping（输入）、owner（输入）、qp_h（输入）、label（输入）；rdma_qp_recovery_opaque_mapping_status 读取 mapping、owner、qp_h、label 并使用字段 release_complete、status；函数返回 rdma_status，不取得调用方资源所有权。
// 失败/边界：rdma_qp_recovery_opaque_mapping_status 返回 RDMA_SC_INVALID_STATE、RDMA_SC_INVALID_ARGUMENT；失败路径不提交部分状态或转移未声明资源。
function automatic rdma_status rdma_qp_recovery_opaque_mapping_status(
  rdma_dma_mapping mapping,
  rdma_function_handle owner,
  rdma_handle qp_h,
  string label
);
  rdma_status status;
  bit release_complete;

  release_complete = 1'b0;
  if (mapping == null)
    return rdma_status::make(RDMA_SC_INVALID_STATE,
                             {label, " mapping authority is missing"});
  if (mapping.function_h == null ||
      mapping.function_h.kind != RDMA_RESOURCE_FUNCTION ||
      owner == null || !mapping.function_h.same_instance(owner))
    return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                             {label, " mapping Function does not match"});
  if (mapping.owner_h == null || mapping.owner_h.kind != RDMA_RESOURCE_QP ||
      qp_h == null || !mapping.owner_h.same_instance(qp_h))
    return rdma_status::make(RDMA_SC_INVALID_STATE,
                             {label, " mapping QP owner does not match"});
  status = mapping.release_completion_status(release_complete);
  if (status == null || !status.ok())
    return status == null ? rdma_status::make(
      RDMA_SC_INVALID_STATE, {label, " completion authority query returned null"}
    ) : status;
  return rdma_status::success();
endfunction

// 功能：rdma_qp_partial_ref_status 校验 backing_ref、expected_role、owner、qp_h、label 与当前对象状态的一致性，并显式处理“clone failed”等拒绝条件，返回 rdma_status 供上层决定是否提交。
// 输入/输出及副作用：backing_ref（输入）、expected_role（输入）、owner（输入）、qp_h（输入）、label（输入）；rdma_qp_partial_ref_status 读取 backing_ref、expected_role、owner、qp_h、label 并使用字段 cloned_object、mapping.state、status；函数返回 rdma_status，不取得调用方资源所有权。
// 失败/边界：rdma_qp_partial_ref_status 返回 RDMA_SC_INVALID_STATE、RDMA_SC_INVALID_ARGUMENT；失败路径不提交部分状态或转移未声明资源。
function automatic rdma_status rdma_qp_partial_ref_status(
  rdma_qp_backing_ref backing_ref,
  rdma_queue_backing_role_e expected_role,
  rdma_function_handle owner,
  rdma_handle qp_h,
  string label
);
  rdma_qp_backing_ref validation_ref;
  uvm_object cloned_object;
  rdma_status status;

  if (backing_ref == null)
    return rdma_status::success();
  cloned_object = backing_ref.clone();
  if (cloned_object == null || !$cast(validation_ref, cloned_object))
    return rdma_status::make(RDMA_SC_INVALID_STATE,
                             {label, " clone failed"});
  if (validation_ref.cleanup_complete) begin
    if (validation_ref.ownership != RDMA_OWNERSHIP_CONTROL_PLANE)
      return rdma_status::make(RDMA_SC_INVALID_STATE,
                               {label, " borrowed cleanup is invalid"});
    if (validation_ref.mapping != null &&
        validation_ref.mapping.state == RDMA_MAPPING_RELEASED)
      validation_ref.mapping.state = RDMA_MAPPING_ACTIVE;
    foreach (validation_ref.additional_segments[i])
      if (validation_ref.additional_segments[i] != null &&
          validation_ref.additional_segments[i].mapping != null &&
          validation_ref.additional_segments[i].mapping.state ==
            RDMA_MAPPING_RELEASED)
        validation_ref.additional_segments[i].mapping.state =
          RDMA_MAPPING_ACTIVE;
  end
  if (validation_ref.recovery_only) begin
    if (validation_ref.ownership != RDMA_OWNERSHIP_CONTROL_PLANE ||
        validation_ref.additional_segments.size() != 0)
      return rdma_status::make(
        RDMA_SC_INVALID_STATE,
        {label, " recovery-only backing ownership/segments are invalid"}
      );
    status = rdma_qp_recovery_opaque_mapping_status(
      validation_ref.mapping, owner, qp_h, label
    );
  end else
    status = validation_ref.validate();

  if (status == null)
    return rdma_status::make(
      RDMA_SC_INVALID_STATE,
      {label, " backing validation returned null status"}
    );

  if (!status.ok())
    return status;
  if (validation_ref.role != expected_role)
    return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                             {label, " role is invalid"});
  return rdma_qp_mapping_authority_status(backing_ref, owner, qp_h, label);
endfunction

// 功能：rdma_qp_partial_plan_status 校验 plan、owner、qp_h 与当前对象状态的一致性，并显式处理“partial QP plan authority is null”等拒绝条件，返回 rdma_status 供上层决定是否提交。
// 输入/输出及副作用：plan（输入）、owner（输入）、qp_h（输入）；rdma_qp_partial_plan_status 读取 plan、owner、qp_h 并使用字段 status；函数返回 rdma_status，不取得调用方资源所有权。
// 失败/边界：rdma_qp_partial_plan_status 返回 RDMA_SC_INVALID_ARGUMENT、RDMA_SC_INVALID_STATE；典型拒绝条件为“partial QP plan authority is null”“partial QP plan metadata is invalid”；失败路径不提交部分状态或转移未声明资源。
function automatic rdma_status rdma_qp_partial_plan_status(
  rdma_qp_backing_plan plan,
  rdma_function_handle owner,
  rdma_handle qp_h
);
  rdma_status status;
  bit seen_urc[3];
  longint unsigned total_length;

  foreach (seen_urc[i]) seen_urc[i] = 1'b0;
  if (plan == null || owner == null || qp_h == null)
    return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                             "partial QP plan authority is null");
  if (!(plan.transport inside {RDMA_TRANSPORT_RC, RDMA_TRANSPORT_UD,
                                RDMA_TRANSPORT_URC}) ||
      !rdma_qp_power_of_two(plan.sq_depth) ||
      !rdma_qp_power_of_two(plan.rq_depth) ||
      plan.sq_ring == null ||
      (plan.sq_pd_flush_complete && !plan.cleanup_complete) ||
      (plan.rq_pd_flush_complete &&
       (!plan.sq_pd_flush_complete || plan.rq_source_h != null)))
    return rdma_status::make(RDMA_SC_INVALID_STATE,
                             "partial QP plan metadata is invalid");
  status = plan.sq_ring.validate();

  if (status == null)
    return rdma_status::make(
      RDMA_SC_INVALID_STATE,
      "partial QP SQ ring validation returned null status"
    );

  if (!status.ok())
    return status;
  if (plan.sq_ring.role != RDMA_QUEUE_ROLE_QP_SQ_RING ||
      plan.sq_ring.depth != plan.sq_depth)
    return rdma_status::make(RDMA_SC_INVALID_STATE,
                             "partial QP SQ ring is invalid");
  // partial recovery 也必须检查可选 SQ-SGB 的 rounded geometry，不能绕过正常 plan 校验。
  status = rdma_qp_partial_ref_status(
    plan.sq_ref, RDMA_QUEUE_ROLE_QP_SQ_RING, owner, qp_h, "partial QP SQ"
  );
  if (!status.ok()) return status;
  status = rdma_qp_partial_ref_status(
    plan.sq_sgb_ref, RDMA_QUEUE_ROLE_QP_SQ_SGB, owner, qp_h,
    "partial QP SQ SGB"
  );
  if (!status.ok()) return status;
  // SQ-SGB is optional for RC/URC, but when retained it is still a
  // published authority. Validate its rounded depth*512 geometry here as
  // well as in the fully materialized-plan validator so pre-program recovery
  // cannot carry a forged or truncated optional SGB.
  if (plan.sq_sgb_ref != null) begin
    status = rdma_qp_backing_total_length(plan.sq_sgb_ref, total_length);
    if (!status.ok()) return status;
    if (plan.sq_sgb_ref.role != RDMA_QUEUE_ROLE_QP_SQ_SGB ||
        total_length != ((longint'(plan.sq_depth) * 512 + 4095) / 4096) * 4096)
      return rdma_status::make(
        RDMA_SC_INVALID_ARGUMENT,
        "partial QP SQ SGB geometry is invalid"
      );
  end
  status = rdma_qp_partial_ref_status(
    plan.sq_pd_ref, RDMA_QUEUE_ROLE_QP_SQ_PD, owner, qp_h,
    "partial QP SQ PD"
  );
  if (!status.ok()) return status;
  if (plan.sq_pd_ref != null && plan.sq_ref == null)
    return rdma_status::make(RDMA_SC_INVALID_STATE,
                             "partial QP SQ PD lacks payload authority");
  if (plan.sq_ref != null && !plan.sq_ref.recovery_only) begin
    status = rdma_qp_backing_total_length(plan.sq_ref, total_length);
    if (!status.ok() || total_length != plan.sq_ring.storage_bytes)
      return status.ok() ? rdma_status::make(
        RDMA_SC_INVALID_STATE, "partial QP SQ geometry is invalid"
      ) : status;
  end
  if (plan.rq_source_h != null) begin
    status = rdma_handle_owner_status(plan.rq_source_h, owner);
    if (!status.ok()) return status;
    if (plan.transport != RDMA_TRANSPORT_RC || plan.rq_ring != null ||
        plan.rq_ref != null || plan.rq_pd_ref != null)
      return rdma_status::make(RDMA_SC_INVALID_STATE,
                               "partial QP SRQ authority is invalid");
  end else begin
    if (plan.rq_ring != null) begin
      status = plan.rq_ring.validate();

      if (status == null)
        return rdma_status::make(
          RDMA_SC_INVALID_STATE,
          "partial QP RQ ring validation returned null status"
        );

      if (!status.ok())
        return status;
      if (plan.rq_ring.role != RDMA_QUEUE_ROLE_QP_RQ_RING ||
          plan.rq_ring.depth != plan.rq_depth)
        return rdma_status::make(RDMA_SC_INVALID_STATE,
                                 "partial QP RQ ring is invalid");
    end
    status = rdma_qp_partial_ref_status(
      plan.rq_ref, RDMA_QUEUE_ROLE_QP_RQ_RING, owner, qp_h, "partial QP RQ"
    );
    if (!status.ok()) return status;
    status = rdma_qp_partial_ref_status(
      plan.rq_pd_ref, RDMA_QUEUE_ROLE_QP_RQ_PD, owner, qp_h,
      "partial QP RQ PD"
    );
    if (!status.ok()) return status;
    if (((plan.rq_ref != null || plan.rq_pd_ref != null) &&
         plan.rq_ring == null) ||
        (plan.rq_pd_ref != null && plan.rq_ref == null))
      return rdma_status::make(RDMA_SC_INVALID_STATE,
                               "partial QP RQ authority is out of order");
    if (plan.rq_ref != null && !plan.rq_ref.recovery_only) begin
      status = rdma_qp_backing_total_length(plan.rq_ref, total_length);
      if (!status.ok() || total_length != plan.rq_ring.storage_bytes)
        return status.ok() ? rdma_status::make(
          RDMA_SC_INVALID_STATE, "partial QP RQ geometry is invalid"
        ) : status;
    end
  end
  foreach (plan.urc_refs[i]) begin
    if (plan.transport != RDMA_TRANSPORT_URC || plan.urc_refs[i] == null)
      return rdma_status::make(RDMA_SC_INVALID_STATE,
                               "partial QP URC authority is invalid");
    case (plan.urc_refs[i].role)
      RDMA_QUEUE_ROLE_QP_URC_RSQ: seen_urc[0] = 1'b1;
      RDMA_QUEUE_ROLE_QP_URC_RDSQ: seen_urc[1] = 1'b1;
      RDMA_QUEUE_ROLE_QP_URC_DSQ: seen_urc[2] = 1'b1;
      default: return rdma_status::make(
        RDMA_SC_INVALID_ARGUMENT, "partial QP URC role is invalid"
      );
    endcase
    status = rdma_qp_partial_ref_status(
      plan.urc_refs[i], plan.urc_refs[i].role, owner, qp_h,
      "partial QP URC"
    );
    if (!status.ok()) return status;
  end
  if ((plan.transport != RDMA_TRANSPORT_URC &&
       plan.urc_refs.size() != 0) ||
      plan.urc_refs.size() > 3 ||
      (seen_urc[1] && !seen_urc[0]) ||
      (seen_urc[2] && !seen_urc[1]))
    return rdma_status::make(RDMA_SC_INVALID_STATE,
                             "partial QP URC order is invalid");
  if (plan.context_ref != null) begin
    status = plan.context_ref.validate();

    if (status == null)
      return rdma_status::make(
        RDMA_SC_INVALID_STATE,
        "partial QP context validation returned null status"
      );

    if (!status.ok())
      return status;
    if (plan.context_ref.resource_kind != RDMA_RESOURCE_QP ||
        !plan.context_ref.owner.same_instance(owner))
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "partial QP context identity is invalid");
  end
  if (plan.sq_ref == null && plan.sq_sgb_ref == null && plan.sq_pd_ref == null &&
      plan.rq_ref == null && plan.rq_pd_ref == null &&
      plan.urc_refs.size() == 0)
    return rdma_status::make(RDMA_SC_INVALID_STATE,
                             "partial QP plan has no retained authority");
  return rdma_status::success();
endfunction

// 功能：rdma_qp_backing_projection_status 校验 backing_ref、programmed_backing、label 与当前对象状态的一致性，并显式处理“backing authority is missing”等拒绝条件，返回 rdma_status 供上层决定是否提交。
// 输入/输出及副作用：backing_ref（输入）、programmed_backing（输入）、label（输入）；rdma_qp_backing_projection_status 读取 backing_ref、programmed_backing、label 并使用字段 effective_iova；函数返回 rdma_status，不取得调用方资源所有权。
// 失败/边界：rdma_qp_backing_projection_status 返回 RDMA_SC_INVALID_STATE、RDMA_SC_DMA_TRANSLATION；失败路径不提交部分状态或转移未声明资源。
function automatic rdma_status rdma_qp_backing_projection_status(
  rdma_qp_backing_ref backing_ref,
  rdma_backing_addr_t programmed_backing,
  string label
);
  longint unsigned effective_iova;

  if (backing_ref == null || backing_ref.mapping == null)
    return rdma_status::make(RDMA_SC_INVALID_STATE,
                             {label, " backing authority is missing"});
  if (backing_ref.mapping.iova.value >
      64'hffff_ffff_ffff_ffff - backing_ref.mapping_offset)
    return rdma_status::make(RDMA_SC_DMA_TRANSLATION,
                             {label, " effective IOVA overflows"});
  effective_iova = backing_ref.mapping.iova.value +
                   backing_ref.mapping_offset;
  if (programmed_backing.value != effective_iova)
    return rdma_status::make(RDMA_SC_INVALID_STATE,
                             {label, " programmed backing does not match"});
  return rdma_status::success();
endfunction

class rdma_resource extends uvm_object;
  `uvm_object_utils(rdma_resource)

  rdma_handle handle;
  rdma_function_handle owner;
  rdma_resource_state_e state;
  rdma_backing_ref backing_refs[$];
  rdma_hmc_ref hmc_refs[$];
  rdma_handle dependencies[$];
  longint unsigned outstanding_ids[$];
  rdma_hmc_fvm_addr_t hmc_fvm_addr;
  bit hmc_fvm_addr_valid;

  // 功能：构造 rdma_resource，调用 super.new 建立 UVM 对象，并把构造体直接写入的默认值设为：handle=null；owner=null；state=RDMA_RESOURCE_NEW；hmc_fvm_addr='0；hmc_fvm_addr_valid=1'b0。
  // 输入/输出及副作用：name（输入）；new 只写入构造体列出的默认字段并返回 void，外部依赖与资源所有权仍由上层管理。
  // 失败/边界：rdma_resource 构造只建立本地初始状态，不接管外部 Host-memory、PCIe 或 manager；未完成后续 configure/build/activate 时，业务入口必须返回 INVALID_STATE。
  function new(string name = "rdma_resource");
    super.new(name);
    handle = null;
    owner = null;
    state = RDMA_RESOURCE_NEW;
    hmc_fvm_addr = '0;
    hmc_fvm_addr_valid = 1'b0;
  endfunction

  // 功能：resource_kind 使用 当前对象字段 计算并返回 rdma_resource_kind_e 结果；不修改对象字段或外部资源。
  // 输入/输出及副作用：无显式参数；resource_kind 读取固定返回值或局部计算结果，不使用对象成员字段；函数返回 rdma_resource_kind_e，不取得调用方资源所有权。
  // 失败/边界：resource_kind 的结果直接由 return RDMA_RESOURCE_FUNCTION 计算；输入不满足表达式条件时沿函数体的保守分支返回，不修改已发布账本。
  virtual function rdma_resource_kind_e resource_kind();
    return RDMA_RESOURCE_FUNCTION;
  endfunction

  // 功能：将 rhs 中 rdma_resource 的值字段复制到当前对象，建立与源对象隔离的快照。
  // 输入/输出及副作用：rhs（输入）；rhs 是源对象；当前对象字段会被覆盖，嵌套句柄按实现执行 clone 或保持非拥有引用，源对象不被修改。
  // 失败/边界：do_copy 在源对象为空、clone/cast 失败或类型不匹配时触发 UVM fatal（resource copy type mismatch），不保留部分有效快照。
  virtual function void do_copy(uvm_object rhs);
    rdma_resource rhs_resource;
    uvm_object cloned_object;
    rdma_backing_ref cloned_backing_ref;
    rdma_hmc_ref cloned_hmc_ref;
    rdma_handle cloned_handle;

    super.do_copy(rhs);
    if (!$cast(rhs_resource, rhs))
      `uvm_fatal("RDMA_COPY_TYPE", "resource copy type mismatch")
    handle = rdma_clone_handle_value(rhs_resource.handle, "resource");
    owner = rdma_clone_function_handle_value(rhs_resource.owner, "resource");
    state = rhs_resource.state;
    hmc_fvm_addr = rhs_resource.hmc_fvm_addr;
    hmc_fvm_addr_valid = rhs_resource.hmc_fvm_addr_valid;
    backing_refs.delete();
    foreach (rhs_resource.backing_refs[i]) begin
      if (rhs_resource.backing_refs[i] == null) begin
        backing_refs.push_back(null);
      end
      else begin
        cloned_object = rhs_resource.backing_refs[i].clone();
        if (cloned_object == null ||
            !$cast(cloned_backing_ref, cloned_object))
          `uvm_fatal("RDMA_COPY_TYPE", "backing reference clone mismatch")
        backing_refs.push_back(cloned_backing_ref);
      end
    end
    hmc_refs.delete();
    foreach (rhs_resource.hmc_refs[i]) begin
      if (rhs_resource.hmc_refs[i] == null) begin
        hmc_refs.push_back(null);
      end
      else begin
        cloned_object = rhs_resource.hmc_refs[i].clone();
        if (cloned_object == null || !$cast(cloned_hmc_ref, cloned_object))
          `uvm_fatal("RDMA_COPY_TYPE", "HMC reference clone mismatch")
        hmc_refs.push_back(cloned_hmc_ref);
      end
    end
    dependencies.delete();
    foreach (rhs_resource.dependencies[i]) begin
      cloned_handle = rdma_clone_handle_value(rhs_resource.dependencies[i],
                                               "dependency");
      dependencies.push_back(cloned_handle);
    end
    outstanding_ids = rhs_resource.outstanding_ids;
  endfunction

  // 功能：validate 校验 当前对象字段 与当前对象状态的一致性，并显式处理“resource state is invalid”等拒绝条件，返回 rdma_status 供上层决定是否提交。
  // 输入/输出及副作用：无显式参数；validate 读取 对象字段：rdma_status、state、handle、handle.kind 并使用字段 status；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：validate 返回 RDMA_SC_INVALID_ARGUMENT；典型拒绝条件为“resource state is invalid”“resource handle kind is invalid”；失败路径不提交部分状态或转移未声明资源。
  virtual function rdma_status validate();
    rdma_status status;

    if (!(state inside {RDMA_RESOURCE_NEW, RDMA_RESOURCE_ALLOCATED,
                        RDMA_RESOURCE_PROGRAMMED, RDMA_RESOURCE_ACTIVE,
                        RDMA_RESOURCE_QUIESCING, RDMA_RESOURCE_RELEASED,
                        RDMA_RESOURCE_ERROR}))
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "resource state is invalid");
    if (state != RDMA_RESOURCE_NEW) begin
      if (handle == null || handle.kind != resource_kind())
        return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                                 "resource handle kind is invalid");
      status = rdma_handle_owner_status(handle, owner);
      if (!status.ok())
        return status;
      foreach (dependencies[i]) begin
        status = rdma_handle_owner_status(dependencies[i], owner);
        if (!status.ok())
          return status;
      end
    end
    return rdma_status::success();
  endfunction
endclass

class rdma_queue_resource extends rdma_resource;
  `uvm_object_utils(rdma_queue_resource)

  int unsigned depth;
  int unsigned producer_index;
  int unsigned consumer_index;
  bit producer_wrap;
  bit consumer_wrap;
  rdma_iova_t queue_iova;
  rdma_queue_backing_plan queue_plan;

  // 功能：构造 rdma_queue_resource，调用 super.new 建立 UVM 对象，并把构造体直接写入的默认值设为：depth='0；producer_index='0；consumer_index='0；producer_wrap=1'b0；consumer_wrap=1'b0；queue_iova='0；queue_plan=null。
  // 输入/输出及副作用：name（输入）；new 只写入构造体列出的默认字段并返回 void，外部依赖与资源所有权仍由上层管理。
  // 失败/边界：rdma_queue_resource 构造只建立本地初始状态，不接管外部 Host-memory、PCIe 或 manager；未完成后续 configure/build/activate 时，业务入口必须返回 INVALID_STATE。
  function new(string name = "rdma_queue_resource");
    super.new(name);
    depth = '0;
    producer_index = '0;
    consumer_index = '0;
    producer_wrap = 1'b0;
    consumer_wrap = 1'b0;
    queue_iova = '0;
    queue_plan = null;
  endfunction

  // 功能：将 rhs 中 rdma_queue_resource 的值字段复制到当前对象，建立与源对象隔离的快照。
  // 输入/输出及副作用：rhs（输入）；rhs 是源对象；当前对象字段会被覆盖，嵌套句柄按实现执行 clone 或保持非拥有引用，源对象不被修改。
  // 失败/边界：do_copy 在源对象为空、clone/cast 失败或类型不匹配时触发 UVM fatal（queue resource copy type mismatch），不保留部分有效快照。
  virtual function void do_copy(uvm_object rhs);
    rdma_queue_resource rhs_queue;
    uvm_object cloned_object;
    rdma_queue_backing_plan cloned_plan;

    super.do_copy(rhs);
    if (!$cast(rhs_queue, rhs))
      `uvm_fatal("RDMA_COPY_TYPE", "queue resource copy type mismatch")
    depth = rhs_queue.depth;
    producer_index = rhs_queue.producer_index;
    consumer_index = rhs_queue.consumer_index;
    producer_wrap = rhs_queue.producer_wrap;
    consumer_wrap = rhs_queue.consumer_wrap;
    queue_iova = rhs_queue.queue_iova;
    if (rhs_queue.queue_plan == null) begin
      queue_plan = null;
    end
    else begin
      cloned_object = rhs_queue.queue_plan.clone();
      if (cloned_object == null || !$cast(cloned_plan, cloned_object) ||
          cloned_plan == rhs_queue.queue_plan)
        `uvm_fatal("RDMA_COPY_TYPE", "queue plan clone mismatch")
      queue_plan = cloned_plan;
    end
  endfunction

  // 功能：validate 校验 当前对象字段 与当前对象状态的一致性，并显式处理“queue authority must be represented only by the queue plan”；“queue depth is not a nonzero power of two”；“queue index is outside the queue depth”；“queue producer and consumer state is invalid”；“programmed queue plan is null”等拒绝条件，返回 rdma_status 供上层决定是否提交。
  // 输入/输出及副作用：无显式参数；validate 读取 对象字段：rdma_status、state、depth、queue_plan、producer_index、consumer_index、producer_wrap、consumer_wrap 并使用字段 status、lifecycle_queue、plan_required；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：validate 返回 RDMA_SC_INVALID_STATE、RDMA_SC_INVALID_ARGUMENT；具体拒绝条件包括 “queue authority must be represented only by the queue plan”；“queue depth is not a nonzero power of two”；“queue index is outside the queue depth”；“queue producer and consumer state is invalid”；“programmed queue plan is null”；失败路径不提交部分状态、不隐式重试，也不转移未声明资源。
  virtual function rdma_status validate();
    rdma_status status;
    bit lifecycle_queue;
    bit plan_required;

    status = super.validate();
    if (!status.ok())
      return status;
    lifecycle_queue = resource_kind() inside {
      RDMA_RESOURCE_CQ, RDMA_RESOURCE_SRQ,
      RDMA_RESOURCE_CEQ, RDMA_RESOURCE_AEQ
    };
    plan_required = state inside {
      RDMA_RESOURCE_ALLOCATED, RDMA_RESOURCE_PROGRAMMED,
      RDMA_RESOURCE_ACTIVE,
      RDMA_RESOURCE_QUIESCING, RDMA_RESOURCE_ERROR
    };
    if (lifecycle_queue &&
        (backing_refs.size() != 0 || hmc_refs.size() != 0))
      return rdma_status::make(
        RDMA_SC_INVALID_STATE,
        "queue authority must be represented only by the queue plan"
      );
    if (lifecycle_queue && state == RDMA_RESOURCE_ALLOCATED &&
        depth == 0 && queue_plan == null)
      return rdma_status::success();
    if (!rdma_is_power_of_two(depth))
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "queue depth is not a nonzero power of two");
    if (producer_index >= depth || consumer_index >= depth)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "queue index is outside the queue depth");
    if (!rdma_ring_state_valid(producer_index, producer_wrap,
                               consumer_index, consumer_wrap))
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "queue producer and consumer state is invalid");
    if (lifecycle_queue && plan_required) begin
      if (queue_plan == null)
        return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                                 "programmed queue plan is null");
      if (queue_plan.resource_kind != resource_kind())
        return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                                 "queue plan kind does not match resource");
      status = queue_plan.validate();

      if (status == null)
        return rdma_status::make(
          RDMA_SC_INVALID_STATE,
          "queue backing plan validation returned null status"
        );

      if (!status.ok())
        return status;
      if (resource_kind() inside {RDMA_RESOURCE_CQ, RDMA_RESOURCE_SRQ} &&
          (queue_plan.context_ref == null ||
           queue_plan.context_ref.hmc_ref == null ||
           queue_plan.context_ref.hmc_ref.ownership !=
             RDMA_OWNERSHIP_CONTROL_PLANE))
        return rdma_status::make(
          RDMA_SC_INVALID_STATE,
          "CQ/SRQ context HMC must be control-plane owned");
    end
    return rdma_status::success();
  endfunction
endclass

class rdma_function extends rdma_resource;
  `uvm_object_utils(rdma_function)

  int unsigned local_function_id;
  int unsigned global_function_id;
  int unsigned rdma_vf_id;
  int unsigned vsi_id;
  int unsigned pfvf_id;
  rdma_function_binding binding;

  // 功能：构造 rdma_function，调用 super.new 建立 UVM 对象，并把构造体直接写入的默认值设为：local_function_id='0；global_function_id='0；rdma_vf_id='0；vsi_id='0；pfvf_id='0；binding=rdma_function_binding::type_id::create("binding")。
  // 输入/输出及副作用：name（输入）；new 只写入构造体列出的默认字段并返回 void，外部依赖与资源所有权仍由上层管理。
  // 失败/边界：rdma_function 构造只建立本地初始状态，不接管外部 Host-memory、PCIe 或 manager；未完成后续 configure/build/activate 时，业务入口必须返回 INVALID_STATE。
  function new(string name = "rdma_function");
    super.new(name);
    local_function_id = '0;
    global_function_id = '0;
    rdma_vf_id = '0;
    vsi_id = '0;
    pfvf_id = '0;
    binding = rdma_function_binding::type_id::create("binding");
  endfunction

  // 功能：resource_kind 使用 当前对象字段 计算并返回 rdma_resource_kind_e 结果；不修改对象字段或外部资源。
  // 输入/输出及副作用：无显式参数；resource_kind 读取固定返回值或局部计算结果，不使用对象成员字段；函数返回 rdma_resource_kind_e，不取得调用方资源所有权。
  // 失败/边界：resource_kind 的结果直接由 return RDMA_RESOURCE_FUNCTION 计算；输入不满足表达式条件时沿函数体的保守分支返回，不修改已发布账本。
  virtual function rdma_resource_kind_e resource_kind();
    return RDMA_RESOURCE_FUNCTION;
  endfunction

  // 功能：将 rhs 中 rdma_function 的值字段复制到当前对象，建立与源对象隔离的快照。
  // 输入/输出及副作用：rhs（输入）；rhs 是源对象；当前对象字段会被覆盖，嵌套句柄按实现执行 clone 或保持非拥有引用，源对象不被修改。
  // 失败/边界：do_copy 在源对象为空、clone/cast 失败或类型不匹配时触发 UVM fatal（function resource copy type mismatch），不保留部分有效快照。
  virtual function void do_copy(uvm_object rhs);
    rdma_function rhs_function;
    uvm_object cloned_object;

    super.do_copy(rhs);
    if (!$cast(rhs_function, rhs))
      `uvm_fatal("RDMA_COPY_TYPE", "function resource copy type mismatch")
    local_function_id = rhs_function.local_function_id;
    global_function_id = rhs_function.global_function_id;
    rdma_vf_id = rhs_function.rdma_vf_id;
    vsi_id = rhs_function.vsi_id;
    pfvf_id = rhs_function.pfvf_id;
    if (rhs_function.binding == null) begin
      binding = null;
    end
    else begin
      cloned_object = rhs_function.binding.clone();
      if (cloned_object == null || !$cast(binding, cloned_object))
        `uvm_fatal("RDMA_COPY_TYPE", "function binding clone mismatch")
    end
  endfunction

  // 功能：validate 校验 当前对象字段 与当前对象状态的一致性，并显式处理“function handle does not match its owner”等拒绝条件，返回 rdma_status 供上层决定是否提交。
  // 输入/输出及副作用：无显式参数；validate 读取 对象字段：rdma_status、state、owner 并使用字段 status；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：validate 返回 RDMA_SC_INVALID_ARGUMENT；典型拒绝条件为“function handle does not match its owner”；失败路径不提交部分状态或转移未声明资源。
  virtual function rdma_status validate();
    rdma_status status;

    status = super.validate();
    if (!status.ok())
      return status;
    if (state != RDMA_RESOURCE_NEW && !handle.same_instance(owner))
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "function handle does not match its owner");
    return rdma_status::success();
  endfunction
endclass

class rdma_pd extends rdma_resource;
  `uvm_object_utils(rdma_pd)

  int unsigned local_pd_id;
  int unsigned global_pd_id;

  // 功能：构造 rdma_pd，调用 super.new 建立 UVM 对象，并把构造体直接写入的默认值设为：local_pd_id='0；global_pd_id='0。
  // 输入/输出及副作用：name（输入）；new 只写入构造体列出的默认字段并返回 void，外部依赖与资源所有权仍由上层管理。
  // 失败/边界：rdma_pd 构造只建立本地初始状态，不接管外部 Host-memory、PCIe 或 manager；未完成后续 configure/build/activate 时，业务入口必须返回 INVALID_STATE。
  function new(string name = "rdma_pd");
    super.new(name);
    local_pd_id = '0;
    global_pd_id = '0;
  endfunction

  // 功能：resource_kind 使用 当前对象字段 计算并返回 rdma_resource_kind_e 结果；不修改对象字段或外部资源。
  // 输入/输出及副作用：无显式参数；resource_kind 读取固定返回值或局部计算结果，不使用对象成员字段；函数返回 rdma_resource_kind_e，不取得调用方资源所有权。
  // 失败/边界：resource_kind 的结果直接由 return RDMA_RESOURCE_PD 计算；输入不满足表达式条件时沿函数体的保守分支返回，不修改已发布账本。
  virtual function rdma_resource_kind_e resource_kind();
    return RDMA_RESOURCE_PD;
  endfunction

  // 功能：将 rhs 中 rdma_pd 的值字段复制到当前对象，建立与源对象隔离的快照。
  // 输入/输出及副作用：rhs（输入）；rhs 是源对象；当前对象字段会被覆盖，嵌套句柄按实现执行 clone 或保持非拥有引用，源对象不被修改。
  // 失败/边界：do_copy 在源对象为空、clone/cast 失败或类型不匹配时触发 UVM fatal（PD resource copy type mismatch），不保留部分有效快照。
  virtual function void do_copy(uvm_object rhs);
    rdma_pd rhs_pd;

    super.do_copy(rhs);
    if (!$cast(rhs_pd, rhs))
      `uvm_fatal("RDMA_COPY_TYPE", "PD resource copy type mismatch")
    local_pd_id = rhs_pd.local_pd_id;
    global_pd_id = rhs_pd.global_pd_id;
  endfunction
endclass

class rdma_mr extends rdma_resource;
  `uvm_object_utils(rdma_mr)

  int unsigned local_mr_id;
  int unsigned global_mr_id;
  rdma_handle pd_h;
  rdma_iova_t iova;
  longint unsigned length;
  bit [31:0] lkey;
  bit [31:0] rkey;
  rdma_rdma_access_t access;
  bit [11:0] mr_serial;

  // 功能：构造 rdma_mr，调用 super.new 建立 UVM 对象，并把构造体直接写入的默认值设为：local_mr_id='0；global_mr_id='0；pd_h=null；iova='0；length='0；lkey='0；rkey='0；access='0；其余字段按实现默认值初始化。
  // 输入/输出及副作用：name（输入）；new 只写入构造体列出的默认字段并返回 void，外部依赖与资源所有权仍由上层管理。
  // 失败/边界：rdma_mr 构造只建立本地初始状态，不接管外部 Host-memory、PCIe 或 manager；未完成后续 configure/build/activate 时，业务入口必须返回 INVALID_STATE。
  function new(string name = "rdma_mr");
    super.new(name);
    local_mr_id = '0;
    global_mr_id = '0;
    pd_h = null;
    iova = '0;
    length = '0;
    lkey = '0;
    rkey = '0;
    access = '0;
    mr_serial = '0;
  endfunction

  // 功能：resource_kind 使用 当前对象字段 计算并返回 rdma_resource_kind_e 结果；不修改对象字段或外部资源。
  // 输入/输出及副作用：无显式参数；resource_kind 读取固定返回值或局部计算结果，不使用对象成员字段；函数返回 rdma_resource_kind_e，不取得调用方资源所有权。
  // 失败/边界：resource_kind 的结果直接由 return RDMA_RESOURCE_MR 计算；输入不满足表达式条件时沿函数体的保守分支返回，不修改已发布账本。
  virtual function rdma_resource_kind_e resource_kind();
    return RDMA_RESOURCE_MR;
  endfunction

  // 功能：将 rhs 中 rdma_mr 的值字段复制到当前对象，建立与源对象隔离的快照。
  // 输入/输出及副作用：rhs（输入）；rhs 是源对象；当前对象字段会被覆盖，嵌套句柄按实现执行 clone 或保持非拥有引用，源对象不被修改。
  // 失败/边界：do_copy 在源对象为空、clone/cast 失败或类型不匹配时触发 UVM fatal（MR resource copy type mismatch），不保留部分有效快照。
  virtual function void do_copy(uvm_object rhs);
    rdma_mr rhs_mr;

    super.do_copy(rhs);
    if (!$cast(rhs_mr, rhs))
      `uvm_fatal("RDMA_COPY_TYPE", "MR resource copy type mismatch")
    local_mr_id = rhs_mr.local_mr_id;
    global_mr_id = rhs_mr.global_mr_id;
    pd_h = rdma_clone_handle_value(rhs_mr.pd_h, "MR PD");
    iova = rhs_mr.iova;
    length = rhs_mr.length;
    lkey = rhs_mr.lkey;
    rkey = rhs_mr.rkey;
    access = rhs_mr.access;
    mr_serial = rhs_mr.mr_serial;
  endfunction

  // 功能：validate 校验 当前对象字段 与当前对象状态的一致性，并显式处理“MR PD handle is invalid”等拒绝条件，返回 rdma_status 供上层决定是否提交。
  // 输入/输出及副作用：无显式参数；validate 读取 对象字段：rdma_status、state、pd_h、pd_h.kind、length、local_mr_id、lkey、rkey 并使用字段 status、has_remote_access；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：validate 返回 RDMA_SC_INVALID_ARGUMENT；典型拒绝条件为“MR PD handle is invalid”“MR length is zero”；失败路径不提交部分状态或转移未声明资源。
  virtual function rdma_status validate();
    rdma_status status;
    bit has_remote_access;

    status = super.validate();
    if (!status.ok())
      return status;
    if (state inside {RDMA_RESOURCE_PROGRAMMED, RDMA_RESOURCE_ACTIVE}) begin
      if (pd_h != null && pd_h.kind != RDMA_RESOURCE_PD)
        return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                                 "MR PD handle is invalid");
      status = rdma_handle_owner_status(pd_h, owner);
      if (!status.ok())
        return status;
      if (length == 0)
        return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                                 "MR length is zero");
    end
    if (state inside {RDMA_RESOURCE_PROGRAMMED, RDMA_RESOURCE_ACTIVE,
                      RDMA_RESOURCE_QUIESCING, RDMA_RESOURCE_ERROR}) begin
      if (local_mr_id[23:0] != lkey[31:8])
        return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                                 "MR local ID does not match lkey index");
      has_remote_access = access.remote_read || access.remote_write ||
                          access.remote_atomic;
      if ((has_remote_access && rkey != lkey) ||
          (!has_remote_access && !(rkey == 0 || rkey == lkey)))
        return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                                 "MR lkey and rkey are inconsistent");
    end
    return rdma_status::success();
  endfunction
endclass

class rdma_cq extends rdma_queue_resource;
  `uvm_object_utils(rdma_cq)

  int unsigned local_cq_id;
  int unsigned global_cq_id;
  int unsigned cqe_size_bytes;
  rdma_handle ceq_h;
  rdma_cqc_model programmed_cqc;

  // 功能：构造 rdma_cq，调用 super.new 建立 UVM 对象，并把构造体直接写入的默认值设为：local_cq_id='0；global_cq_id='0；cqe_size_bytes=64；ceq_h=null。
  // 输入/输出及副作用：name（输入）；new 只写入构造体列出的默认字段并返回 void，外部依赖与资源所有权仍由上层管理。
  // 失败/边界：rdma_cq 构造只建立本地初始状态，不接管外部 Host-memory、PCIe 或 manager；未完成后续 configure/build/activate 时，业务入口必须返回 INVALID_STATE。
  function new(string name = "rdma_cq");
    super.new(name);
    local_cq_id = '0;
    global_cq_id = '0;
    cqe_size_bytes = 64;
    ceq_h = null;
    programmed_cqc = null;
  endfunction

  // 功能：resource_kind 使用 当前对象字段 计算并返回 rdma_resource_kind_e 结果；不修改对象字段或外部资源。
  // 输入/输出及副作用：无显式参数；resource_kind 读取固定返回值或局部计算结果，不使用对象成员字段；函数返回 rdma_resource_kind_e，不取得调用方资源所有权。
  // 失败/边界：resource_kind 的结果直接由 return RDMA_RESOURCE_CQ 计算；输入不满足表达式条件时沿函数体的保守分支返回，不修改已发布账本。
  virtual function rdma_resource_kind_e resource_kind();
    return RDMA_RESOURCE_CQ;
  endfunction

  // 功能：将 rhs 中 rdma_cq 的值字段复制到当前对象，建立与源对象隔离的快照。
  // 输入/输出及副作用：rhs（输入）；rhs 是源对象；当前对象字段会被覆盖，嵌套句柄按实现执行 clone 或保持非拥有引用，源对象不被修改。
  // 失败/边界：do_copy 在源对象为空、clone/cast 失败或类型不匹配时触发 UVM fatal（CQ resource copy type mismatch），不保留部分有效快照。
  virtual function void do_copy(uvm_object rhs);
    rdma_cq rhs_cq;
    uvm_object cloned_object;

    super.do_copy(rhs);
    if (!$cast(rhs_cq, rhs))
      `uvm_fatal("RDMA_COPY_TYPE", "CQ resource copy type mismatch")
    local_cq_id = rhs_cq.local_cq_id;
    global_cq_id = rhs_cq.global_cq_id;
    cqe_size_bytes = rhs_cq.cqe_size_bytes;
    ceq_h = rdma_clone_handle_value(rhs_cq.ceq_h, "CQ CEQ");
    if (rhs_cq.programmed_cqc == null) begin
      programmed_cqc = null;
    end
    else begin
      cloned_object = rhs_cq.programmed_cqc.clone();
      if (cloned_object == null || !$cast(programmed_cqc, cloned_object) ||
          programmed_cqc == rhs_cq.programmed_cqc)
        `uvm_fatal("RDMA_COPY_TYPE", "CQ programmed CQC clone mismatch")
    end
  endfunction

  // 功能：validate 校验 当前对象字段 与当前对象状态的一致性，并显式处理“CQ entry size is invalid”等拒绝条件，返回 rdma_status 供上层决定是否提交。
  // 输入/输出及副作用：无显式参数；validate 读取 对象字段：rdma_status、state、cqe_size_bytes、ceq_h、ceq_h.kind 并使用字段 status；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：validate 返回 RDMA_SC_INVALID_ARGUMENT；典型拒绝条件为“CQ entry size is invalid”“CQ CEQ handle is invalid”；失败路径不提交部分状态或转移未声明资源。
  virtual function rdma_status validate();
    rdma_status status;

    status = super.validate();
    if (!status.ok())
      return status;
    if (state inside {
          RDMA_RESOURCE_PROGRAMMED, RDMA_RESOURCE_ACTIVE,
          RDMA_RESOURCE_QUIESCING, RDMA_RESOURCE_ERROR
        }) begin
      if (!(cqe_size_bytes inside {32, 64, 128}))
        return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                                 "CQ entry size is invalid");
      if (ceq_h != null && ceq_h.kind != RDMA_RESOURCE_CEQ)
        return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                                 "CQ CEQ handle is invalid");
      status = rdma_handle_owner_status(ceq_h, owner);
      if (!status.ok())
        return status;
      if (programmed_cqc != null) begin
        status = programmed_cqc.validate();

        if (status == null)
          return rdma_status::make(
            RDMA_SC_INVALID_STATE,
            "programmed CQC validation returned null status"
          );

        if (!status.ok())
          return status;
        if (programmed_cqc.cq_h == null ||
            programmed_cqc.cq_h.object_id != local_cq_id ||
            programmed_cqc.cq_h.function_uid != handle.function_uid ||
            programmed_cqc.cq_h.generation != handle.generation)
          return rdma_status::make(
            RDMA_SC_INVALID_STATE,
            "CQ programmed CQC identity does not match resource"
          );
      end
    end
    return rdma_status::success();
  endfunction
endclass

class rdma_qp extends rdma_resource;
  `uvm_object_utils(rdma_qp)

  int unsigned local_qp_id;
  int unsigned global_qp_id;
  rdma_transport_e transport;
  rdma_qp_state_e qp_state;
  int unsigned sq_depth;
  int unsigned rq_depth;
  int unsigned max_send_sge, max_recv_sge, max_inline_data;
  int unsigned sq_producer_index;
  int unsigned sq_consumer_index;
  bit sq_wrap;
  bit sq_consumer_wrap;
  int unsigned rq_producer_index;
  int unsigned rq_consumer_index;
  bit rq_wrap;
  bit rq_consumer_wrap;
  rdma_iova_t sq_iova;
  rdma_iova_t rq_iova;
  rdma_handle pd_h;
  rdma_handle send_cq_h;
  rdma_handle recv_cq_h;
  rdma_handle srq_h;
  rdma_qp_backing_plan qp_plan;
  rdma_qpc_model programmed_qpc;

  // 功能：构造 rdma_qp，调用 super.new 建立 UVM 对象，并把构造体直接写入的默认值设为：local_qp_id='0；global_qp_id='0；transport=RDMA_TRANSPORT_RC；qp_state=RDMA_QPS_RESET；sq_depth='0；rq_depth='0；max_send_sge=0；max_recv_sge=0；其余字段按实现默认值初始化。
  // 输入/输出及副作用：name（输入）；new 只写入构造体列出的默认字段并返回 void，外部依赖与资源所有权仍由上层管理。
  // 失败/边界：rdma_qp 构造只建立本地初始状态，不接管外部 Host-memory、PCIe 或 manager；未完成后续 configure/build/activate 时，业务入口必须返回 INVALID_STATE。
  function new(string name = "rdma_qp");
    super.new(name);
    local_qp_id = '0;
    global_qp_id = '0;
    transport = RDMA_TRANSPORT_RC;
    qp_state = RDMA_QPS_RESET;
    sq_depth = '0;
    rq_depth = '0;
    max_send_sge = 0; max_recv_sge = 0; max_inline_data = 0;
    sq_producer_index = '0;
    sq_consumer_index = '0;
    sq_wrap = 1'b0;
    sq_consumer_wrap = 1'b0;
    rq_producer_index = '0;
    rq_consumer_index = '0;
    rq_wrap = 1'b0;
    rq_consumer_wrap = 1'b0;
    sq_iova = '0;
    rq_iova = '0;
    pd_h = null;
    send_cq_h = null;
    recv_cq_h = null;
    srq_h = null;
    qp_plan = null;
    programmed_qpc = null;
  endfunction

  // 功能：resource_kind 使用 当前对象字段 计算并返回 rdma_resource_kind_e 结果；不修改对象字段或外部资源。
  // 输入/输出及副作用：无显式参数；resource_kind 读取固定返回值或局部计算结果，不使用对象成员字段；函数返回 rdma_resource_kind_e，不取得调用方资源所有权。
  // 失败/边界：resource_kind 的结果直接由 return RDMA_RESOURCE_QP 计算；输入不满足表达式条件时沿函数体的保守分支返回，不修改已发布账本。
  virtual function rdma_resource_kind_e resource_kind();
    return RDMA_RESOURCE_QP;
  endfunction

  // 功能：将 rhs 中 rdma_qp 的值字段复制到当前对象，建立与源对象隔离的快照。
  // 输入/输出及副作用：rhs（输入）；rhs 是源对象；当前对象字段会被覆盖，嵌套句柄按实现执行 clone 或保持非拥有引用，源对象不被修改。
  // 失败/边界：do_copy 在源对象为空、clone/cast 失败或类型不匹配时触发 UVM fatal（QP resource copy type mismatch），不保留部分有效快照。
  virtual function void do_copy(uvm_object rhs);
    rdma_qp rhs_qp;

    super.do_copy(rhs);
    if (!$cast(rhs_qp, rhs))
      `uvm_fatal("RDMA_COPY_TYPE", "QP resource copy type mismatch")
    local_qp_id = rhs_qp.local_qp_id;
    global_qp_id = rhs_qp.global_qp_id;
    transport = rhs_qp.transport;
    qp_state = rhs_qp.qp_state;
    sq_depth = rhs_qp.sq_depth;
    rq_depth = rhs_qp.rq_depth;
    max_send_sge = rhs_qp.max_send_sge; max_recv_sge = rhs_qp.max_recv_sge;
    max_inline_data = rhs_qp.max_inline_data;
    sq_producer_index = rhs_qp.sq_producer_index;
    sq_consumer_index = rhs_qp.sq_consumer_index;
    sq_wrap = rhs_qp.sq_wrap;
    sq_consumer_wrap = rhs_qp.sq_consumer_wrap;
    rq_producer_index = rhs_qp.rq_producer_index;
    rq_consumer_index = rhs_qp.rq_consumer_index;
    rq_wrap = rhs_qp.rq_wrap;
    rq_consumer_wrap = rhs_qp.rq_consumer_wrap;
    sq_iova = rhs_qp.sq_iova;
    rq_iova = rhs_qp.rq_iova;
    pd_h = rdma_clone_handle_value(rhs_qp.pd_h, "QP PD");
    send_cq_h = rdma_clone_handle_value(rhs_qp.send_cq_h, "QP send CQ");
    recv_cq_h = rdma_clone_handle_value(rhs_qp.recv_cq_h, "QP receive CQ");
    srq_h = rdma_clone_handle_value(rhs_qp.srq_h, "QP SRQ");
    if (rhs_qp.qp_plan == null) qp_plan = null;
    else begin
      uvm_object cloned_object;
      cloned_object = rhs_qp.qp_plan.clone();
      if (cloned_object == null || !$cast(qp_plan, cloned_object) ||
          qp_plan == rhs_qp.qp_plan)
        `uvm_fatal("RDMA_COPY_TYPE", "QP backing plan clone mismatch")
    end
    if (rhs_qp.programmed_qpc == null) programmed_qpc = null;
    else begin
      uvm_object cloned_object;
      cloned_object = rhs_qp.programmed_qpc.clone();
      if (cloned_object == null || !$cast(programmed_qpc, cloned_object) ||
          programmed_qpc == rhs_qp.programmed_qpc)
        `uvm_fatal("RDMA_COPY_TYPE", "QP programmed QPC clone mismatch")
    end
  endfunction

  // 功能：validate 校验 当前对象字段 与当前对象状态的一致性，并显式处理“QP depth is not a nonzero power of two”等拒绝条件，返回 rdma_status 供上层决定是否提交。
  // 输入/输出及副作用：无显式参数；validate 读取 对象字段：rdma_status、sq_depth、sq_producer_index、sq_consumer_index、rq_producer_index、rq_depth、rq_consumer_index、sq_wrap 并使用字段 status；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：validate 返回 RDMA_SC_INVALID_ARGUMENT、RDMA_SC_INVALID_STATE；典型拒绝条件为“QP depth is not a nonzero power of two”“QP queue index is outside the queue depth”；失败路径不提交部分状态或转移未声明资源。
  virtual function rdma_status validate();
    rdma_status status;

    status = super.validate();
    if (!status.ok())
      return status;
    if (!rdma_is_power_of_two(sq_depth) ||
        !rdma_is_power_of_two(rq_depth))
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "QP depth is not a nonzero power of two");
    if (sq_producer_index >= sq_depth || sq_consumer_index >= sq_depth ||
        rq_producer_index >= rq_depth || rq_consumer_index >= rq_depth)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "QP queue index is outside the queue depth");
    if (!rdma_ring_state_valid(sq_producer_index, sq_wrap,
                               sq_consumer_index, sq_consumer_wrap) ||
        !rdma_ring_state_valid(rq_producer_index, rq_wrap,
                               rq_consumer_index, rq_consumer_wrap))
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "QP producer and consumer state is invalid");
    if (!(transport inside {RDMA_TRANSPORT_RC, RDMA_TRANSPORT_UD,
                            RDMA_TRANSPORT_URC}))
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "QP transport is invalid");
    if (!(qp_state inside {RDMA_QPS_RESET, RDMA_QPS_INIT, RDMA_QPS_RTR,
                           RDMA_QPS_RTS, RDMA_QPS_SQD, RDMA_QPS_SQE,
                           RDMA_QPS_ERROR}))
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "QP state is invalid");
    if (state == RDMA_RESOURCE_ERROR && programmed_qpc == null) begin
      if (qp_plan == null || backing_refs.size() != 0 || hmc_refs.size() != 0)
        return rdma_status::make(
          RDMA_SC_INVALID_STATE,
          "pre-program QP ERROR backing authority is incomplete or split"
        );
      status = rdma_qp_partial_plan_status(qp_plan, owner, handle);
      if (!status.ok()) return status;
      if (qp_plan.context_ref != null &&
          qp_plan.context_ref.local_id != local_qp_id)
        return rdma_status::make(
          RDMA_SC_INVALID_STATE,
          "pre-program QP ERROR context local ID does not match resource"
        );
      if (qp_plan.transport != transport || qp_plan.sq_depth != sq_depth ||
          qp_plan.rq_depth != rq_depth)
        return rdma_status::make(
          RDMA_SC_INVALID_STATE,
          "pre-program QP ERROR plan does not match resource"
        );
      if (qp_plan.sq_ref != null && !qp_plan.sq_ref.recovery_only &&
          sq_iova.value != qp_plan.sq_ref.mapping.iova.value +
                           qp_plan.sq_ref.mapping_offset)
        return rdma_status::make(
          RDMA_SC_INVALID_STATE,
          "pre-program QP ERROR SQ IOVA does not match retained authority"
        );
      if (qp_plan.rq_source_h == null && qp_plan.rq_ref != null &&
          !qp_plan.rq_ref.recovery_only &&
          rq_iova.value != qp_plan.rq_ref.mapping.iova.value +
                           qp_plan.rq_ref.mapping_offset)
        return rdma_status::make(
          RDMA_SC_INVALID_STATE,
          "pre-program QP ERROR RQ IOVA does not match retained authority"
        );
      if ((srq_h == null) != (qp_plan.rq_source_h == null) ||
          (srq_h != null && !srq_h.same_instance(qp_plan.rq_source_h)))
        return rdma_status::make(
          RDMA_SC_INVALID_STATE,
          "pre-program QP ERROR SRQ authority does not match resource"
        );
    end
    else if (state inside {RDMA_RESOURCE_PROGRAMMED, RDMA_RESOURCE_ACTIVE,
                           RDMA_RESOURCE_QUIESCING,
                           RDMA_RESOURCE_ERROR}) begin
      if (qp_plan == null || programmed_qpc == null ||
          backing_refs.size() != 0 || hmc_refs.size() != 0)
        return rdma_status::make(RDMA_SC_INVALID_STATE,
                                 "QP backing authority is incomplete or split");
      status = qp_plan.validate();

      if (status == null)
        return rdma_status::make(
          RDMA_SC_INVALID_STATE,
          "QP backing plan validation returned null status"
        );

      if (!status.ok())
        return status;
      if (qp_plan.context_ref.local_id != local_qp_id)
        return rdma_status::make(
          RDMA_SC_INVALID_STATE,
          "QP context local ID does not match the resource local QP ID"
        );
      status = programmed_qpc.validate();

      if (status == null)
        return rdma_status::make(
          RDMA_SC_INVALID_STATE,
          "programmed QPC validation returned null status"
        );

      if (!status.ok())
        return status;
      if (qp_plan.transport != transport || programmed_qpc.transport != transport ||
          qp_plan.sq_depth != sq_depth || qp_plan.rq_depth != rq_depth ||
          programmed_qpc.sq_depth != sq_depth ||
          programmed_qpc.rq_depth != rq_depth)
        return rdma_status::make(RDMA_SC_INVALID_STATE,
                                 "QP programmed authority does not match resource");
      status = rdma_qp_projected_handle_status(
        programmed_qpc.qp_h, handle, owner, RDMA_RESOURCE_QP, "QPC QP"
      );
      if (!status.ok()) return status;
      if (programmed_qpc.qp_h.object_id != local_qp_id)
        return rdma_status::make(
          RDMA_SC_INVALID_STATE,
          "QPC projected QP ID does not match the resource local QP ID"
        );
      status = rdma_qp_projected_handle_status(
        programmed_qpc.pd_h, pd_h, owner, RDMA_RESOURCE_PD, "QPC PD"
      );
      if (!status.ok()) return status;
      status = rdma_qp_projected_handle_status(
        programmed_qpc.send_cq_h, send_cq_h, owner, RDMA_RESOURCE_CQ,
        "QPC send CQ"
      );
      if (!status.ok()) return status;
      status = rdma_qp_projected_handle_status(
        programmed_qpc.recv_cq_h, recv_cq_h, owner, RDMA_RESOURCE_CQ,
        "QPC receive CQ"
      );
      if (!status.ok()) return status;
      status = rdma_qp_mapping_authority_status(
        qp_plan.sq_ref, owner, handle, "QP SQ"
      );
      if (!status.ok()) return status;
      if (qp_plan.sq_sgb_ref != null) begin
        status = rdma_qp_mapping_authority_status(
          qp_plan.sq_sgb_ref, owner, handle, "QP SQ SGB"
        );
        if (!status.ok()) return status;
      end
      status = rdma_qp_mapping_authority_status(
        qp_plan.sq_pd_ref, owner, handle, "QP SQ PD"
      );
      if (!status.ok()) return status;
      if (qp_plan.context_ref.owner == null ||
          !qp_plan.context_ref.owner.same_instance(owner) ||
          qp_plan.context_ref.hmc_ref == null ||
          qp_plan.context_ref.hmc_ref.owner == null ||
          !qp_plan.context_ref.hmc_ref.owner.same_instance(owner))
        return rdma_status::make(
          RDMA_SC_INVALID_ARGUMENT,
          "QP context or HMC owner does not match the resource owner"
        );
      foreach (qp_plan.urc_refs[i]) begin
        status = rdma_qp_mapping_authority_status(
          qp_plan.urc_refs[i], owner, handle, "QP URC"
        );
        if (!status.ok()) return status;
      end
      if (programmed_qpc.sq_mode != qp_plan.sq_ring.object_mode)
        return rdma_status::make(RDMA_SC_INVALID_STATE,
                                 "QPC SQ mode does not match the plan");
      status = rdma_qp_backing_projection_status(
        qp_plan.sq_pd_ref, programmed_qpc.sq_backing, "QPC SQ"
      );
      if (!status.ok()) return status;
      if (programmed_qpc.context_backing.value !=
          qp_plan.context_ref.shadow_pointer_base.value)
        return rdma_status::make(
          RDMA_SC_INVALID_STATE,
          "QPC context backing does not match the plan shadow base"
        );
      if (srq_h != null) begin
        status = rdma_handle_owner_status(srq_h, owner);
        if (!status.ok()) return status;
      end
      if ((srq_h == null) != (qp_plan.rq_source_h == null) ||
          (srq_h != null &&
           (!srq_h.same_instance(qp_plan.rq_source_h) ||
            programmed_qpc.srq_h == null)) ||
          (srq_h == null && programmed_qpc.srq_h != null))
        return rdma_status::make(RDMA_SC_INVALID_STATE,
                                 "QP SRQ authority does not match resource");
      if (srq_h != null) begin
        status = rdma_qp_projected_handle_status(
          programmed_qpc.srq_h, srq_h, owner, RDMA_RESOURCE_SRQ, "QPC SRQ"
        );
        if (!status.ok()) return status;
        if (programmed_qpc.rq_mode != RDMA_OBJECT_INDIRECT_4K)
          return rdma_status::make(
            RDMA_SC_INVALID_STATE,
            "SRQ-backed QPC RQ mode must be indirect 4 KiB"
          );
      end
      else begin
        status = rdma_qp_mapping_authority_status(
          qp_plan.rq_ref, owner, handle, "QP RQ"
        );
        if (!status.ok()) return status;
        status = rdma_qp_mapping_authority_status(
          qp_plan.rq_pd_ref, owner, handle, "QP RQ PD"
        );
        if (!status.ok()) return status;
        if (programmed_qpc.rq_mode != qp_plan.rq_ring.object_mode)
          return rdma_status::make(RDMA_SC_INVALID_STATE,
                                   "QPC RQ mode does not match the plan");
        status = rdma_qp_backing_projection_status(
          qp_plan.rq_pd_ref, programmed_qpc.rq_backing, "QPC RQ"
        );
        if (!status.ok()) return status;
      end
    end
    if (state inside {RDMA_RESOURCE_PROGRAMMED, RDMA_RESOURCE_ACTIVE}) begin
      if (pd_h != null && pd_h.kind != RDMA_RESOURCE_PD)
        return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                                 "QP PD handle is invalid");
      status = rdma_handle_owner_status(pd_h, owner);
      if (!status.ok())
        return status;
      if (send_cq_h != null && send_cq_h.kind != RDMA_RESOURCE_CQ)
        return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                                 "QP completion queue handle is invalid");
      status = rdma_handle_owner_status(send_cq_h, owner);
      if (!status.ok())
        return status;
      if (recv_cq_h != null && recv_cq_h.kind != RDMA_RESOURCE_CQ)
        return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                                 "QP completion queue handle is invalid");
      status = rdma_handle_owner_status(recv_cq_h, owner);
      if (!status.ok())
        return status;
      if (srq_h != null) begin
        if (srq_h.kind != RDMA_RESOURCE_SRQ)
          return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                                   "QP SRQ handle is invalid");
        status = rdma_handle_owner_status(srq_h, owner);
        if (!status.ok())
          return status;
      end
    end
    return rdma_status::success();
  endfunction
endclass

class rdma_srq extends rdma_queue_resource;
  `uvm_object_utils(rdma_srq)

  int unsigned local_srq_id;
  int unsigned global_srq_id;
  int unsigned max_sge;
  int unsigned limit_threshold;
  rdma_handle pd_h;

  // 功能：构造 rdma_srq，调用 super.new 建立 UVM 对象，并把构造体直接写入的默认值设为：local_srq_id='0；global_srq_id='0；max_sge='0；limit_threshold=16；pd_h=null。
  // 输入/输出及副作用：name（输入）；new 只写入构造体列出的默认字段并返回 void，外部依赖与资源所有权仍由上层管理。
  // 失败/边界：rdma_srq 构造只建立本地初始状态，不接管外部 Host-memory、PCIe 或 manager；未完成后续 configure/build/activate 时，业务入口必须返回 INVALID_STATE。
  function new(string name = "rdma_srq");
    super.new(name);
    local_srq_id = '0;
    global_srq_id = '0;
    max_sge = '0;
    limit_threshold = 16;
    pd_h = null;
  endfunction

  // 功能：resource_kind 使用 当前对象字段 计算并返回 rdma_resource_kind_e 结果；不修改对象字段或外部资源。
  // 输入/输出及副作用：无显式参数；resource_kind 读取固定返回值或局部计算结果，不使用对象成员字段；函数返回 rdma_resource_kind_e，不取得调用方资源所有权。
  // 失败/边界：resource_kind 的结果直接由 return RDMA_RESOURCE_SRQ 计算；输入不满足表达式条件时沿函数体的保守分支返回，不修改已发布账本。
  virtual function rdma_resource_kind_e resource_kind();
    return RDMA_RESOURCE_SRQ;
  endfunction

  // 功能：将 rhs 中 rdma_srq 的值字段复制到当前对象，建立与源对象隔离的快照。
  // 输入/输出及副作用：rhs（输入）；rhs 是源对象；当前对象字段会被覆盖，嵌套句柄按实现执行 clone 或保持非拥有引用，源对象不被修改。
  // 失败/边界：do_copy 在源对象为空、clone/cast 失败或类型不匹配时触发 UVM fatal（SRQ resource copy type mismatch），不保留部分有效快照。
  virtual function void do_copy(uvm_object rhs);
    rdma_srq rhs_srq;

    super.do_copy(rhs);
    if (!$cast(rhs_srq, rhs))
      `uvm_fatal("RDMA_COPY_TYPE", "SRQ resource copy type mismatch")
    local_srq_id = rhs_srq.local_srq_id;
    global_srq_id = rhs_srq.global_srq_id;
    max_sge = rhs_srq.max_sge;
    limit_threshold = rhs_srq.limit_threshold;
    pd_h = rdma_clone_handle_value(rhs_srq.pd_h, "SRQ PD");
  endfunction

  // 功能：validate 校验 当前对象字段 与当前对象状态的一致性，并显式处理“SRQ PD handle is invalid”等拒绝条件，返回 rdma_status 供上层决定是否提交。
  // 输入/输出及副作用：无显式参数；validate 读取 对象字段：rdma_status、state、pd_h、pd_h.kind、max_sge、limit_threshold、depth 并使用字段 status；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：validate 返回 RDMA_SC_INVALID_ARGUMENT；典型拒绝条件为“SRQ PD handle is invalid”“SRQ maximum SGE count is zero”；失败路径不提交部分状态或转移未声明资源。
  virtual function rdma_status validate();
    rdma_status status;

    status = super.validate();
    if (!status.ok())
      return status;
    if (state inside {
          RDMA_RESOURCE_PROGRAMMED, RDMA_RESOURCE_ACTIVE,
          RDMA_RESOURCE_QUIESCING, RDMA_RESOURCE_ERROR
        }) begin
      if (pd_h != null && pd_h.kind != RDMA_RESOURCE_PD)
        return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                                 "SRQ PD handle is invalid");
      status = rdma_handle_owner_status(pd_h, owner);
      if (!status.ok())
        return status;
      if (max_sge == 0)
        return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                                 "SRQ maximum SGE count is zero");
      if (limit_threshold < 16 || limit_threshold > depth ||
          limit_threshold % 4 != 0)
        return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                                 "SRQ limit threshold is invalid");
    end
    return rdma_status::success();
  endfunction
endclass

class rdma_ceq extends rdma_queue_resource;
  `uvm_object_utils(rdma_ceq)

  int unsigned local_ceq_id;
  int unsigned global_ceq_id;
  int unsigned function_local_vector;
  int unsigned hardware_vector;
  int unsigned msix_table_index;

  // 功能：构造 rdma_ceq，调用 super.new 建立 UVM 对象，并把构造体直接写入的默认值设为：local_ceq_id='0；global_ceq_id='0；function_local_vector='0；hardware_vector='0；msix_table_index='0。
  // 输入/输出及副作用：name（输入）；new 只写入构造体列出的默认字段并返回 void，外部依赖与资源所有权仍由上层管理。
  // 失败/边界：rdma_ceq 构造只建立本地初始状态，不接管外部 Host-memory、PCIe 或 manager；未完成后续 configure/build/activate 时，业务入口必须返回 INVALID_STATE。
  function new(string name = "rdma_ceq");
    super.new(name);
    local_ceq_id = '0;
    global_ceq_id = '0;
    function_local_vector = '0;
    hardware_vector = '0;
    msix_table_index = '0;
  endfunction

  // 功能：resource_kind 使用 当前对象字段 计算并返回 rdma_resource_kind_e 结果；不修改对象字段或外部资源。
  // 输入/输出及副作用：无显式参数；resource_kind 读取固定返回值或局部计算结果，不使用对象成员字段；函数返回 rdma_resource_kind_e，不取得调用方资源所有权。
  // 失败/边界：resource_kind 的结果直接由 return RDMA_RESOURCE_CEQ 计算；输入不满足表达式条件时沿函数体的保守分支返回，不修改已发布账本。
  virtual function rdma_resource_kind_e resource_kind();
    return RDMA_RESOURCE_CEQ;
  endfunction

  // 功能：将 rhs 中 rdma_ceq 的值字段复制到当前对象，建立与源对象隔离的快照。
  // 输入/输出及副作用：rhs（输入）；rhs 是源对象；当前对象字段会被覆盖，嵌套句柄按实现执行 clone 或保持非拥有引用，源对象不被修改。
  // 失败/边界：do_copy 在源对象为空、clone/cast 失败或类型不匹配时触发 UVM fatal（CEQ resource copy type mismatch），不保留部分有效快照。
  virtual function void do_copy(uvm_object rhs);
    rdma_ceq rhs_ceq;

    super.do_copy(rhs);
    if (!$cast(rhs_ceq, rhs))
      `uvm_fatal("RDMA_COPY_TYPE", "CEQ resource copy type mismatch")
    local_ceq_id = rhs_ceq.local_ceq_id;
    global_ceq_id = rhs_ceq.global_ceq_id;
    function_local_vector = rhs_ceq.function_local_vector;
    hardware_vector = rhs_ceq.hardware_vector;
    msix_table_index = rhs_ceq.msix_table_index;
  endfunction
endclass

class rdma_aeq extends rdma_queue_resource;
  `uvm_object_utils(rdma_aeq)

  int unsigned local_aeq_id;
  int unsigned global_aeq_id;
  int unsigned function_local_vector;
  int unsigned hardware_vector;
  int unsigned msix_table_index;

  // 功能：构造 rdma_aeq，调用 super.new 建立 UVM 对象，并把构造体直接写入的默认值设为：local_aeq_id='0；global_aeq_id='0；function_local_vector='0；hardware_vector='0；msix_table_index='0。
  // 输入/输出及副作用：name（输入）；new 只写入构造体列出的默认字段并返回 void，外部依赖与资源所有权仍由上层管理。
  // 失败/边界：rdma_aeq 构造只建立本地初始状态，不接管外部 Host-memory、PCIe 或 manager；未完成后续 configure/build/activate 时，业务入口必须返回 INVALID_STATE。
  function new(string name = "rdma_aeq");
    super.new(name);
    local_aeq_id = '0;
    global_aeq_id = '0;
    function_local_vector = '0;
    hardware_vector = '0;
    msix_table_index = '0;
  endfunction

  // 功能：resource_kind 使用 当前对象字段 计算并返回 rdma_resource_kind_e 结果；不修改对象字段或外部资源。
  // 输入/输出及副作用：无显式参数；resource_kind 读取固定返回值或局部计算结果，不使用对象成员字段；函数返回 rdma_resource_kind_e，不取得调用方资源所有权。
  // 失败/边界：resource_kind 的结果直接由 return RDMA_RESOURCE_AEQ 计算；输入不满足表达式条件时沿函数体的保守分支返回，不修改已发布账本。
  virtual function rdma_resource_kind_e resource_kind();
    return RDMA_RESOURCE_AEQ;
  endfunction

  // 功能：将 rhs 中 rdma_aeq 的值字段复制到当前对象，建立与源对象隔离的快照。
  // 输入/输出及副作用：rhs（输入）；rhs 是源对象；当前对象字段会被覆盖，嵌套句柄按实现执行 clone 或保持非拥有引用，源对象不被修改。
  // 失败/边界：do_copy 在源对象为空、clone/cast 失败或类型不匹配时触发 UVM fatal（AEQ resource copy type mismatch），不保留部分有效快照。
  virtual function void do_copy(uvm_object rhs);
    rdma_aeq rhs_aeq;

    super.do_copy(rhs);
    if (!$cast(rhs_aeq, rhs))
      `uvm_fatal("RDMA_COPY_TYPE", "AEQ resource copy type mismatch")
    local_aeq_id = rhs_aeq.local_aeq_id;
    global_aeq_id = rhs_aeq.global_aeq_id;
    function_local_vector = rhs_aeq.function_local_vector;
    hardware_vector = rhs_aeq.hardware_vector;
    msix_table_index = rhs_aeq.msix_table_index;
  endfunction
endclass

class rdma_cmq extends rdma_queue_resource;
  `uvm_object_utils(rdma_cmq)

  int unsigned local_cmq_id;
  int unsigned global_cmq_id;
  int unsigned completion_producer_index;
  int unsigned completion_consumer_index;
  bit completion_wrap;
  bit completion_consumer_wrap;
  rdma_iova_t completion_iova;

  // 功能：构造 rdma_cmq，调用 super.new 建立 UVM 对象，并把构造体直接写入的默认值设为：local_cmq_id='0；global_cmq_id='0；completion_producer_index='0；completion_consumer_index='0；completion_wrap=1'b0；completion_consumer_wrap=1'b0；completion_iova='0。
  // 输入/输出及副作用：name（输入）；new 只写入构造体列出的默认字段并返回 void，外部依赖与资源所有权仍由上层管理。
  // 失败/边界：rdma_cmq 构造只建立本地初始状态，不接管外部 Host-memory、PCIe 或 manager；未完成后续 configure/build/activate 时，业务入口必须返回 INVALID_STATE。
  function new(string name = "rdma_cmq");
    super.new(name);
    local_cmq_id = '0;
    global_cmq_id = '0;
    completion_producer_index = '0;
    completion_consumer_index = '0;
    completion_wrap = 1'b0;
    completion_consumer_wrap = 1'b0;
    completion_iova = '0;
  endfunction

  // 功能：resource_kind 使用 当前对象字段 计算并返回 rdma_resource_kind_e 结果；不修改对象字段或外部资源。
  // 输入/输出及副作用：无显式参数；resource_kind 读取固定返回值或局部计算结果，不使用对象成员字段；函数返回 rdma_resource_kind_e，不取得调用方资源所有权。
  // 失败/边界：resource_kind 的结果直接由 return RDMA_RESOURCE_CMQ 计算；输入不满足表达式条件时沿函数体的保守分支返回，不修改已发布账本。
  virtual function rdma_resource_kind_e resource_kind();
    return RDMA_RESOURCE_CMQ;
  endfunction

  // 功能：将 rhs 中 rdma_cmq 的值字段复制到当前对象，建立与源对象隔离的快照。
  // 输入/输出及副作用：rhs（输入）；rhs 是源对象；当前对象字段会被覆盖，嵌套句柄按实现执行 clone 或保持非拥有引用，源对象不被修改。
  // 失败/边界：do_copy 在源对象为空、clone/cast 失败或类型不匹配时触发 UVM fatal（CMQ resource copy type mismatch），不保留部分有效快照。
  virtual function void do_copy(uvm_object rhs);
    rdma_cmq rhs_cmq;

    super.do_copy(rhs);
    if (!$cast(rhs_cmq, rhs))
      `uvm_fatal("RDMA_COPY_TYPE", "CMQ resource copy type mismatch")
    local_cmq_id = rhs_cmq.local_cmq_id;
    global_cmq_id = rhs_cmq.global_cmq_id;
    completion_producer_index = rhs_cmq.completion_producer_index;
    completion_consumer_index = rhs_cmq.completion_consumer_index;
    completion_wrap = rhs_cmq.completion_wrap;
    completion_consumer_wrap = rhs_cmq.completion_consumer_wrap;
    completion_iova = rhs_cmq.completion_iova;
  endfunction

  // 功能：validate 校验 当前对象字段 与当前对象状态的一致性，并显式处理“CMQ completion index is outside the queue depth”；“CMQ completion producer and consumer state is invalid”等拒绝条件，返回 rdma_status 供上层决定是否提交。
  // 输入/输出及副作用：无显式参数；validate 读取 对象字段：rdma_status、completion_producer_index、depth、completion_consumer_index、completion_wrap、completion_consumer_wrap 并使用字段 status；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：validate 返回 RDMA_SC_INVALID_ARGUMENT；具体拒绝条件包括 “CMQ completion index is outside the queue depth”；“CMQ completion producer and consumer state is invalid”；失败路径不提交部分状态、不隐式重试，也不转移未声明资源。
  virtual function rdma_status validate();
    rdma_status status;

    status = super.validate();
    if (!status.ok())
      return status;
    if (completion_producer_index >= depth ||
        completion_consumer_index >= depth)
      return rdma_status::make(
        RDMA_SC_INVALID_ARGUMENT,
        "CMQ completion index is outside the queue depth"
      );
    if (!rdma_ring_state_valid(completion_producer_index, completion_wrap,
                               completion_consumer_index,
                               completion_consumer_wrap))
      return rdma_status::make(
        RDMA_SC_INVALID_ARGUMENT,
        "CMQ completion producer and consumer state is invalid"
      );
    return rdma_status::success();
  endfunction
endclass
