// 目录/层次：协议与资源模型层 model/rdma_resources.sv。
// 职责：定义 Function/PD/MR/CQ/QP/SRQ/CEQ/AEQ/CMQ 资源值模型及其 validate/do_copy，
//   并提供句柄克隆、ring 状态与 QP backing authority 的校验函数。
// 依赖：依赖 rdma_status、rdma_handle 与 backing/plan/context 模型；不访问外部资源。
// 所有权与生命周期：对象只拥有自身值快照，嵌套句柄/plan 经 do_copy 深拷贝；外部资源只保存非拥有引用。

typedef class rdma_qpc_model;
typedef class rdma_cqc_model;

// 功能：克隆 handle，得到独立快照。
// 输入/输出及副作用：source 只读，copy_label 用于 fatal 文本；返回新 handle。
// 失败/边界：source 为空返回 null；clone/cast 失败触发 UVM fatal。
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

// 功能：克隆 function handle，得到独立快照。
// 输入/输出及副作用：source 只读，copy_label 用于 fatal 文本；返回新 function handle。
// 失败/边界：source 为空返回 null；clone/cast 失败触发 UVM fatal。
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

// 功能：判断 producer/consumer 的 index 与 wrap 组合是否构成合法 ring 状态。
// 输入/输出及副作用：四个标量为输入；返回 bit。
// 失败/边界：wrap 相同要求 producer_index >= consumer_index，不同要求 producer_index <= consumer_index。
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

// 功能：校验 QP 投影的 handle 与其依赖 handle 的 kind 和 Function 归属。
// 输入/输出及副作用：projected_h、dependency_h、owner、expected_kind 只读，label 用于诊断；返回 status。
// 失败/边界：任一 handle 为空或 kind 不等于 expected_kind 返回 INVALID_ARGUMENT；归属不符透传 owner 校验错误。
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

// 功能：校验 QP backing ref（含 segment）的 mapping 属于该 Function 与 QP。
// 输入/输出及副作用：backing_ref、owner、qp_h 只读，label 用于诊断；返回 status。
// 失败/边界：mapping 缺失、owner 非当前 QP 或任一 segment 的 mapping authority 无效返回 INVALID_STATE；
//   mapping 的 Function 不符返回 INVALID_ARGUMENT。
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

// 设计说明：失败的分配可能带着适配器持有的 release capability，即便其公开 ring 几何已损坏；
// recovery-only 引用因此只校验清理路由所需的 identity 与 opaque completion 查询，
// 正常 QP plan 仍走下方的严格几何校验。
// 功能：校验 recovery-only 的 opaque mapping 归属于该 Function 与 QP。
// 输入/输出及副作用：mapping、owner、qp_h 只读，label 用于诊断；查询 release completion；返回 status。
// 失败/边界：mapping 缺失、QP owner 不符或 completion 查询返回 null 为 INVALID_STATE；
//   Function 不符返回 INVALID_ARGUMENT。
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

// 功能：校验 partial QP plan 中的单个可选 backing ref。
// 输入/输出及副作用：backing_ref、expected_role、owner、qp_h 只读，label 用于诊断；对 ref 做深拷贝后校验。
// 失败/边界：backing_ref 为空视为成功；克隆失败、cleanup/recovery-only 的所有权或 segment 非法为
//   INVALID_STATE；role 不符为 INVALID_ARGUMENT；其余沿用 mapping authority 校验。
function automatic rdma_status rdma_qp_partial_ref_status(
  rdma_qp_backing_ref backing_ref,
  rdma_queue_backing_role_e expected_role,
  rdma_function_handle owner,
  rdma_handle qp_h,
  string label
);
  rdma_qp_backing_ref validation_ref;
  rdma_status status;

  if (backing_ref == null)
    return rdma_status::success();
  if (!rdma_deep_copy#(rdma_qp_backing_ref)::try_of(backing_ref, validation_ref))
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

// 功能：校验 partial QP plan 的元数据与各 SQ/RQ/SGB/PD/URC backing authority 的完整性与先后顺序。
// 输入/输出及副作用：plan、owner、qp_h 只读；返回 status。
// 失败/边界：plan/owner/qp_h 为空或 URC role 非法为 INVALID_ARGUMENT；元数据、ring、authority 顺序、
//   几何或 context identity 不符返回 INVALID_STATE；SGB 几何非法返回 INVALID_ARGUMENT；
//   未保留任何 authority 返回 INVALID_STATE。
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
  status = rdma_status::nonnull(
    plan.sq_ring.validate(),
    "partial QP SQ ring validation returned null status"
  );
  if (!status.ok())
    return status;
  if (plan.sq_ring.role != RDMA_QUEUE_ROLE_QP_SQ_RING ||
      plan.sq_ring.depth != plan.sq_depth)
    return rdma_status::make(RDMA_SC_INVALID_STATE,
                             "partial QP SQ ring is invalid");
  // partial recovery 也须检查可选 SQ-SGB 的取整几何，不能绕过正常 plan 校验。
  status = rdma_qp_partial_ref_status(
    plan.sq_ref, RDMA_QUEUE_ROLE_QP_SQ_RING, owner, qp_h, "partial QP SQ"
  );
  if (!status.ok()) return status;
  status = rdma_qp_partial_ref_status(
    plan.sq_sgb_ref, RDMA_QUEUE_ROLE_QP_SQ_SGB, owner, qp_h,
    "partial QP SQ SGB"
  );
  if (!status.ok()) return status;
  // SQ-SGB 对 RC/URC 可选，但一旦保留即是已发布的 authority；此处与完整 plan 校验一样检查其
  // 取整后 depth*512 的几何，避免 pre-program recovery 携带伪造或截断的 SGB。
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
    plan.rq_sgb_ref, RDMA_QUEUE_ROLE_QP_RQ_SGB, owner, qp_h,
    "partial QP RQ SGB"
  );
  if (!status.ok()) return status;
  if (plan.rq_sgb_ref != null) begin
    status = rdma_qp_backing_total_length(plan.rq_sgb_ref, total_length);
    if (!status.ok()) return status;
    if (total_length != rdma_qp_sgb_storage_bytes(plan.rq_depth))
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "partial QP RQ SGB geometry is invalid");
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
      status = rdma_status::nonnull(
        plan.rq_ring.validate(),
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
    status = rdma_status::nonnull(
      plan.context_ref.validate(),
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
      plan.rq_ref == null && plan.rq_pd_ref == null && plan.rq_sgb_ref == null &&
      plan.urc_refs.size() == 0)
    return rdma_status::make(RDMA_SC_INVALID_STATE,
                             "partial QP plan has no retained authority");
  return rdma_status::success();
endfunction

// 功能：校验 QP backing 的有效 IOVA 与已编程的 backing 地址一致。
// 输入/输出及副作用：backing_ref、programmed_backing 只读，label 用于诊断；返回 status。
// 失败/边界：backing/mapping 缺失或地址不一致返回 INVALID_STATE；mapping.iova+offset 溢出返回 DMA_TRANSLATION。
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
  `rdma_object_utils(rdma_resource)

  rdma_handle handle;
  rdma_function_handle owner;
  rdma_resource_state_e state;
  rdma_backing_ref backing_refs[$];
  rdma_hmc_ref hmc_refs[$];
  rdma_handle dependencies[$];
  longint unsigned outstanding_ids[$];
  rdma_hmc_fvm_addr_t hmc_fvm_addr;
  bit hmc_fvm_addr_valid;

  // 功能：构造资源基类，状态为 NEW，句柄/owner 为空。
  // 输入/输出及副作用：name 为 UVM 实例名；仅初始化本地字段为默认值。
  // 失败/边界：无。
  function new(string name = "rdma_resource");
    super.new(name);
    handle = null;
    owner = null;
    state = RDMA_RESOURCE_NEW;
    hmc_fvm_addr = '0;
    hmc_fvm_addr_valid = 1'b0;
  endfunction

  // 功能：返回资源类型 RDMA_RESOURCE_FUNCTION。
  // 输入/输出及副作用：无输入输出。
  // 失败/边界：无。
  virtual function rdma_resource_kind_e resource_kind();
    return RDMA_RESOURCE_FUNCTION;
  endfunction

  // 功能：复制资源基类的值字段，嵌套句柄克隆为独立快照。
  // 输入/输出及副作用：rhs 为源对象；覆盖 handle、owner、state、HMC 地址、backing/HMC ref 等字段。
  // 失败/边界：类型不符或嵌套 clone 失败触发 UVM fatal（resource copy type mismatch）。
  virtual function void do_copy(uvm_object rhs);
    rdma_resource rhs_resource;
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
        cloned_backing_ref = rdma_deep_copy#(rdma_backing_ref)::of(
          rhs_resource.backing_refs[i], "backing reference clone mismatch");
        backing_refs.push_back(cloned_backing_ref);
      end
    end
    hmc_refs.delete();
    foreach (rhs_resource.hmc_refs[i]) begin
      if (rhs_resource.hmc_refs[i] == null) begin
        hmc_refs.push_back(null);
      end
      else begin
        cloned_hmc_ref = rdma_deep_copy#(rdma_hmc_ref)::of(
          rhs_resource.hmc_refs[i], "HMC reference clone mismatch");
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

  // 功能：校验资源基类状态、handle kind 及其与 owner/dependencies 的归属。
  // 输入/输出及副作用：只读对象字段；返回 status。
  // 失败/边界：state 非法或（非 NEW 时）handle 为空/kind 不符返回 INVALID_ARGUMENT；归属不符透传 owner 校验错误。
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
  `rdma_object_utils(rdma_queue_resource)

  int unsigned depth;
  int unsigned producer_index;
  int unsigned consumer_index;
  bit producer_wrap;
  bit consumer_wrap;
  rdma_iova_t queue_iova;
  rdma_queue_backing_plan queue_plan;

  // 功能：构造队列资源基类，ring 指针与 plan 置默认。
  // 输入/输出及副作用：name 为 UVM 实例名；仅初始化本地字段为默认值。
  // 失败/边界：无。
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

  // 功能：复制队列资源的值字段，嵌套句柄克隆为独立快照。
  // 输入/输出及副作用：rhs 为源对象；覆盖 depth、ring 指针/wrap、queue_iova，并深拷贝 queue_plan。
  // 失败/边界：类型不符或嵌套 clone 失败触发 UVM fatal（queue resource copy type mismatch）。
  virtual function void do_copy(uvm_object rhs);
    rdma_queue_resource rhs_queue;
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
      cloned_plan = rdma_deep_copy#(rdma_queue_backing_plan)::of(
        rhs_queue.queue_plan, "queue plan clone mismatch");
      queue_plan = cloned_plan;
    end
  endfunction

  // 功能：校验队列资源的 depth、指针/wrap 状态与 queue plan。
  // 输入/输出及副作用：只读对象字段；返回 status。
  // 失败/边界：CQ/SRQ/CEQ/AEQ 若同时带 backing/HMC ref 返回 INVALID_STATE；
  //   depth 非 2 的幂、指针越界或状态非法、plan 缺失或 kind 不符返回 INVALID_ARGUMENT；
  //   CQ/SRQ context HMC 非 control-plane 拥有返回 INVALID_STATE。
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
      status = rdma_status::nonnull(
        queue_plan.validate(),
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

class rdma_qp extends rdma_resource;
  `rdma_object_utils(rdma_qp)

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

  // 功能：构造QP 资源，默认 RC transport、RESET 状态、队列指针清零。
  // 输入/输出及副作用：name 为 UVM 实例名；仅初始化本地字段为默认值。
  // 失败/边界：无。
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

  // 功能：返回资源类型 RDMA_RESOURCE_QP。
  // 输入/输出及副作用：无输入输出。
  // 失败/边界：无。
  virtual function rdma_resource_kind_e resource_kind();
    return RDMA_RESOURCE_QP;
  endfunction

  // 功能：复制QP 资源的值字段，嵌套句柄克隆为独立快照。
  // 输入/输出及副作用：rhs 为源对象；覆盖 ID、transport、状态、深度、SGE/inline、SQ/RQ 指针与 plan/QPC 等字段。
  // 失败/边界：类型不符或嵌套 clone 失败触发 UVM fatal（QP resource copy type mismatch）。
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
      qp_plan = rdma_deep_copy#(rdma_qp_backing_plan)::of(
        rhs_qp.qp_plan, "QP backing plan clone mismatch");
    end
    if (rhs_qp.programmed_qpc == null) programmed_qpc = null;
    else begin
      uvm_object cloned_object;
      programmed_qpc = rdma_deep_copy#(rdma_qpc_model)::of(
        rhs_qp.programmed_qpc, "QP programmed QPC clone mismatch");
    end
  endfunction

  // 功能：校验 QP 的深度、SQ/RQ 指针与 wrap、transport、qp_state，并按状态校验 backing plan 与 programmed QPC 的身份一致性。
  // 输入/输出及副作用：只读对象字段；返回 status。
  // 失败/边界：depth 非 2 的幂、指针越界、状态/transport 非法或句柄 kind 错误返回 INVALID_ARGUMENT；
  //   plan/QPC/SRQ/PD/CQ authority 与资源不符或 backing 不完整返回 INVALID_STATE。
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
      status = rdma_status::nonnull(
        qp_plan.validate(),
        "QP backing plan validation returned null status"
      );
      if (!status.ok())
        return status;
      if (qp_plan.context_ref.local_id != local_qp_id)
        return rdma_status::make(
          RDMA_SC_INVALID_STATE,
          "QP context local ID does not match the resource local QP ID"
        );
      status = rdma_status::nonnull(
        programmed_qpc.validate(),
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
      if (qp_plan.rq_sgb_ref != null) begin
        status = rdma_qp_mapping_authority_status(
          qp_plan.rq_sgb_ref, owner, handle, "QP RQ SGB"
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
  `rdma_object_utils(rdma_srq)

  int unsigned local_srq_id;
  int unsigned global_srq_id;
  int unsigned max_sge;
  int unsigned limit_threshold;
  rdma_handle pd_h;

  // 功能：构造SRQ 资源，limit_threshold 默认 16。
  // 输入/输出及副作用：name 为 UVM 实例名；仅初始化本地字段为默认值。
  // 失败/边界：无。
  function new(string name = "rdma_srq");
    super.new(name);
    local_srq_id = '0;
    global_srq_id = '0;
    max_sge = '0;
    limit_threshold = 16;
    pd_h = null;
  endfunction

  // 功能：返回资源类型 RDMA_RESOURCE_SRQ。
  // 输入/输出及副作用：无输入输出。
  // 失败/边界：无。
  virtual function rdma_resource_kind_e resource_kind();
    return RDMA_RESOURCE_SRQ;
  endfunction

  // 功能：复制SRQ 资源的值字段，嵌套句柄克隆为独立快照。
  // 输入/输出及副作用：rhs 为源对象；覆盖 ID、max_sge、limit_threshold，克隆 pd_h。
  // 失败/边界：类型不符或嵌套 clone 失败触发 UVM fatal（SRQ resource copy type mismatch）。
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

  // 功能：校验 SRQ 在已编程状态下的 PD 归属、max_sge 与 limit_threshold。
  // 输入/输出及副作用：只读对象字段；返回 status。
  // 失败/边界：PD handle 非 PD、max_sge 为零或 limit_threshold 非法返回 INVALID_ARGUMENT。
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

class rdma_cmq extends rdma_queue_resource;
  `rdma_object_utils(rdma_cmq)

  int unsigned local_cmq_id;
  int unsigned global_cmq_id;
  int unsigned completion_producer_index;
  int unsigned completion_consumer_index;
  bit completion_wrap;
  bit completion_consumer_wrap;
  rdma_iova_t completion_iova;

  // 功能：构造CMQ 资源，completion 指针与 iova 清零。
  // 输入/输出及副作用：name 为 UVM 实例名；仅初始化本地字段为默认值。
  // 失败/边界：无。
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

  // 功能：返回资源类型 RDMA_RESOURCE_CMQ。
  // 输入/输出及副作用：无输入输出。
  // 失败/边界：无。
  virtual function rdma_resource_kind_e resource_kind();
    return RDMA_RESOURCE_CMQ;
  endfunction

  // 功能：复制CMQ 资源的值字段，嵌套句柄克隆为独立快照。
  // 输入/输出及副作用：rhs 为源对象；覆盖 ID 与 completion 指针/wrap/iova。
  // 失败/边界：类型不符或嵌套 clone 失败触发 UVM fatal（CMQ resource copy type mismatch）。
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

  // 功能：校验 CMQ 的 completion 指针与 wrap 状态。
  // 输入/输出及副作用：只读对象字段；返回 status。
  // 失败/边界：index 超出队列深度或 producer/consumer 状态非法返回 INVALID_ARGUMENT。
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
