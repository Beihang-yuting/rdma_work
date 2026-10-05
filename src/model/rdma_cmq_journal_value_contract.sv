// 目录：模型层 model/rdma_cmq_journal_value_contract.sv。
// 职责：集中 CMQ retained journal 中 owner、DMA context、mapping、command identity、
//   Function binding、reset-isolation proof 与 recovery batch tuple 的只读值比较契约。
// 依赖：CMQ execution model、Function binding、DMA context/mapping 及共享 handle 值契约；
//   不依赖 codec、profile、core 或外部 adapter。
// 所有权与生命周期：helper 无状态，只读调用方对象，不保存引用，不转移所有权；
//   binding 比较仅创建短生命周期 status/identity。

// 设计说明：instance 路径保留 same_instance() 的 incarnation 值语义，detached 路径用共享
// handle 值比较；两者都不证明对象 alias。owner 形状、binding wrapper、proof tuple 顺序与
// 字段短路顺序保持 engine 既有契约。binding 比较的 identity snapshot 仅限本次比较。
// recovery batch tuple 只读最终三列，并额外拒绝空图或数量漂移；engine 在其原有门禁之后
// 才映射 tuple 错误。

// 功能：比较两个 retained frozen recovery-owner 的公开字段，resource handle 用 same_instance()。
// 输入/输出及副作用：只读；比较 workflow、transaction、action mask、Function incarnation 等。
// 失败/边界：shape 非法、handle/identity 缺失或字段漂移返回 0；两个 legacy sentinel 返回 1；
//   值相等不表示对象 alias。
function automatic bit rdma_cmq_same_journal_owner_value(
  input rdma_cmq_recovery_owner lhs,
  input rdma_cmq_recovery_owner rhs
);
  if (!rdma_cmq_frozen_owner_shape_valid(lhs) ||
      !rdma_cmq_frozen_owner_shape_valid(rhs))
    return 1'b0;
  if (lhs.is_legacy_unmigrated() || rhs.is_legacy_unmigrated())
    return lhs.is_legacy_unmigrated() && rhs.is_legacy_unmigrated();
  return lhs.workflow == rhs.workflow &&
         lhs.resource_h != null && rhs.resource_h != null &&
         lhs.resource_h.same_instance(rhs.resource_h) &&
         lhs.transaction_id == rhs.transaction_id &&
         lhs.allowed_actions == rhs.allowed_actions &&
         lhs.function_identity != null && rhs.function_identity != null &&
         lhs.function_identity.same_incarnation(rhs.function_identity) &&
         lhs.admission_attempt_id == rhs.admission_attempt_id &&
         lhs.frozen == rhs.frozen;
endfunction

// 功能：比较两个 detached frozen recovery-owner 的公开值（resource handle 按值比较）。
// 输入/输出及副作用：只读，不恢复嵌套 handle alias。
// 失败/边界：shape 非法、handle/identity 缺失或字段漂移返回 0；两个 legacy sentinel 返回 1。
function automatic bit rdma_cmq_same_journal_owner_detached_value(
  input rdma_cmq_recovery_owner lhs,
  input rdma_cmq_recovery_owner rhs
);
  if (!rdma_cmq_frozen_owner_shape_valid(lhs) ||
      !rdma_cmq_frozen_owner_shape_valid(rhs))
    return 1'b0;
  if (lhs.is_legacy_unmigrated() || rhs.is_legacy_unmigrated())
    return lhs.is_legacy_unmigrated() && rhs.is_legacy_unmigrated();
  return lhs.workflow == rhs.workflow && lhs.resource_h != null &&
         rhs.resource_h != null &&
         rdma_cmq_same_handle_value(lhs.resource_h, rhs.resource_h) &&
         lhs.transaction_id == rhs.transaction_id &&
         lhs.allowed_actions == rhs.allowed_actions &&
         lhs.function_identity != null && rhs.function_identity != null &&
         lhs.function_identity.same_incarnation(rhs.function_identity) &&
         lhs.admission_attempt_id == rhs.admission_attempt_id &&
         lhs.frozen == rhs.frozen;
endfunction

// 功能：比较两个 DMA request context 的公开 authority 投影，handle 用 same_instance()。
// 输入/输出及副作用：只读，不执行 DMA。
// 失败/边界：context/Function 为 null、owner 空值形状不一致或字段漂移返回 0；
//   不做 validate 或对象 alias 判断。
function automatic bit rdma_cmq_same_journal_dma_context_value(
  input rdma_dma_request_context lhs,
  input rdma_dma_request_context rhs
);
  if (lhs == null || rhs == null || lhs.function_h == null ||
      rhs.function_h == null ||
      !lhs.function_h.same_instance(rhs.function_h))
    return 1'b0;
  if ((lhs.owner_h == null) != (rhs.owner_h == null))
    return 1'b0;
  if (lhs.owner_h != null && !lhs.owner_h.same_instance(rhs.owner_h))
    return 1'b0;
  return lhs.requester_bdf == rhs.requester_bdf &&
         lhs.pasid_valid == rhs.pasid_valid && lhs.pasid == rhs.pasid &&
         lhs.dma_domain_valid == rhs.dma_domain_valid &&
         lhs.dma_domain_id == rhs.dma_domain_id &&
         lhs.route == rhs.route && lhs.reset_epoch == rhs.reset_epoch &&
         lhs.route_valid == rhs.route_valid &&
         lhs.epoch_valid == rhs.epoch_valid &&
         lhs.queue_role_valid == rhs.queue_role_valid &&
         lhs.queue_role == rhs.queue_role;
endfunction

// 功能：比较两个 detached DMA request context 的公开 authority 值，handle 用共享值比较。
// 输入/输出及副作用：只读，不修改 context。
// 失败/边界：context/Function 为 null、owner 空值形状不一致或字段漂移返回 0；
//   不做 validate 或嵌套 handle alias 恢复。
function automatic bit rdma_cmq_same_journal_dma_context_detached_value(
  input rdma_dma_request_context lhs,
  input rdma_dma_request_context rhs
);
  if (lhs == null || rhs == null || lhs.function_h == null ||
      rhs.function_h == null ||
      !rdma_cmq_same_handle_value(lhs.function_h, rhs.function_h))
    return 1'b0;
  if ((lhs.owner_h == null) != (rhs.owner_h == null))
    return 1'b0;
  if (lhs.owner_h != null &&
      !rdma_cmq_same_handle_value(lhs.owner_h, rhs.owner_h))
    return 1'b0;
  return lhs.requester_bdf == rhs.requester_bdf &&
         lhs.pasid_valid == rhs.pasid_valid && lhs.pasid == rhs.pasid &&
         lhs.dma_domain_valid == rhs.dma_domain_valid &&
         lhs.dma_domain_id == rhs.dma_domain_id && lhs.route == rhs.route &&
         lhs.reset_epoch == rhs.reset_epoch &&
         lhs.route_valid == rhs.route_valid &&
         lhs.epoch_valid == rhs.epoch_valid &&
         lhs.queue_role_valid == rhs.queue_role_valid &&
         lhs.queue_role == rhs.queue_role;
endfunction

// 功能：比较两个 DMA mapping 的公开投影；Function/owner 用 same_instance()，
//   UMEM/PBL/MW 比较外部非拥有引用 identity。
// 输入/输出及副作用：只读；覆盖 authority、range、permission、state、引用与 UMEM page 元数据。
// 失败/边界：mapping/Function 为 null、owner 空值形状不一致或字段漂移返回 0；
//   不做 validate，也不比较私有 release authority。
function automatic bit rdma_cmq_same_journal_mapping_public_value(
  input rdma_dma_mapping lhs,
  input rdma_dma_mapping rhs
);
  if (lhs == null || rhs == null || lhs.function_h == null ||
      rhs.function_h == null ||
      !lhs.function_h.same_instance(rhs.function_h))
    return 1'b0;
  if ((lhs.owner_h == null) != (rhs.owner_h == null))
    return 1'b0;
  if (lhs.owner_h != null && !lhs.owner_h.same_instance(rhs.owner_h))
    return 1'b0;
  return lhs.requester_bdf == rhs.requester_bdf &&
         lhs.pasid_valid == rhs.pasid_valid && lhs.pasid == rhs.pasid &&
         lhs.dma_domain_valid == rhs.dma_domain_valid &&
         lhs.dma_domain_id == rhs.dma_domain_id &&
         lhs.route == rhs.route && lhs.reset_epoch == rhs.reset_epoch &&
         lhs.route_valid == rhs.route_valid &&
         lhs.epoch_valid == rhs.epoch_valid &&
         lhs.backing_addr.value == rhs.backing_addr.value &&
         lhs.iova.value == rhs.iova.value && lhs.size == rhs.size &&
         lhs.direction == rhs.direction &&
         lhs.permissions == rhs.permissions && lhs.state == rhs.state &&
         lhs.umem_ref == rhs.umem_ref && lhs.pbl_ref == rhs.pbl_ref &&
         lhs.mw_ref == rhs.mw_ref && lhs.umem_backed == rhs.umem_backed &&
         lhs.umem_page_count == rhs.umem_page_count;
endfunction

// 功能：比较两个 command identity 的 Function kind/UID/global ID、generation、profile、
//   opcode 与 variant。
// 输入/输出及副作用：只读。
// 失败/边界：null、非 Function kind、零 UID/generation 或空 profile/variant 返回 0；
//   不拒绝零 global Function ID 或零 opcode。
function automatic bit rdma_cmq_same_journal_command_identity_value(
  input rdma_cmq_command_identity lhs,
  input rdma_cmq_command_identity rhs
);
  if (lhs == null || rhs == null ||
      lhs.function_kind != RDMA_RESOURCE_FUNCTION ||
      rhs.function_kind != RDMA_RESOURCE_FUNCTION ||
      lhs.function_uid == 0 || rhs.function_uid == 0 ||
      lhs.generation == 0 || rhs.generation == 0 ||
      lhs.profile_name.len() == 0 || rhs.profile_name.len() == 0 ||
      lhs.variant.len() == 0 || rhs.variant.len() == 0)
    return 1'b0;
  return lhs.function_kind == rhs.function_kind &&
         lhs.function_uid == rhs.function_uid &&
         lhs.global_function_id == rhs.global_function_id &&
         lhs.generation == rhs.generation &&
         lhs.profile_name == rhs.profile_name &&
         lhs.opcode == rhs.opcode && lhs.variant == rhs.variant;
endfunction

// 功能：逐字段比较两个 retained Function binding 的公开投影（identity、PCIe/BAR、notify、
//   DMA/capability、vector、owner、lifecycle、readiness）。
// 输入/输出及副作用：只读；经 nonfatal accessor 创建短生命周期 identity/status。
// 失败/边界：null、非 exact base wrapper、identity snapshot 失败、PCIe/BAR 缺失、owner 或
//   任一字段漂移返回 0；不调用 validate，不比较 PCIe/BAR 子类扩展字段。
function automatic bit rdma_cmq_same_journal_binding_value(
  input rdma_function_binding lhs,
  input rdma_function_binding rhs
);
  rdma_function_identity lhs_identity;
  rdma_function_identity rhs_identity;
  rdma_status lhs_status;
  rdma_status rhs_status;

  if (lhs == null || rhs == null ||
      lhs.get_object_type() != rdma_function_binding::get_type() ||
      rhs.get_object_type() != rdma_function_binding::get_type() ||
      lhs.pcie == null || rhs.pcie == null)
    return 1'b0;
  lhs_status = lhs.snapshot_identity_nonfatal(lhs_identity);
  rhs_status = rhs.snapshot_identity_nonfatal(rhs_identity);
  if (lhs_status == null || !lhs_status.ok() || rhs_status == null ||
      !rhs_status.ok() || lhs_identity == null || rhs_identity == null ||
      !lhs_identity.same_incarnation(rhs_identity) ||
      lhs.function_uid != rhs.function_uid ||
      lhs.pcie.bdf != rhs.pcie.bdf ||
      lhs.pcie.parent_pf_bdf != rhs.pcie.parent_pf_bdf ||
      lhs.pcie.vf_index != rhs.pcie.vf_index ||
      lhs.pcie.mse != rhs.pcie.mse || lhs.pcie.bme != rhs.pcie.bme ||
      lhs.notify_bar_id != rhs.notify_bar_id ||
      lhs.notify_base != rhs.notify_base ||
      lhs.notify_size != rhs.notify_size ||
      lhs.notify_table_sel != rhs.notify_table_sel ||
      lhs.notify_table_index != rhs.notify_table_index ||
      lhs.host_id != rhs.host_id || lhs.pfvf_id != rhs.pfvf_id ||
      lhs.rdma_vf_id != rhs.rdma_vf_id ||
      lhs.global_function_id != rhs.global_function_id ||
      lhs.vsi_id != rhs.vsi_id || lhs.queue_dma != rhs.queue_dma ||
      lhs.queue_caps != rhs.queue_caps ||
      lhs.interrupt_vectors.size() != rhs.interrupt_vectors.size() ||
      lhs.state != rhs.state || lhs.generation != rhs.generation ||
      lhs.notify_valid != rhs.notify_valid ||
      lhs.notify_ready != rhs.notify_ready ||
      lhs.dmi_valid != rhs.dmi_valid || lhs.dmi_ready != rhs.dmi_ready ||
      lhs.vft_valid != rhs.vft_valid || lhs.vft_ready != rhs.vft_ready ||
      ((lhs.owner_h == null) != (rhs.owner_h == null)))
    return 1'b0;
  if (lhs.owner_h != null &&
      (lhs.owner_h.get_object_type() != rhs.owner_h.get_object_type() ||
       !lhs.owner_h.same_instance(rhs.owner_h)))
    return 1'b0;
  foreach (lhs.pcie.bar[i]) begin
    if (lhs.pcie.bar[i] == null || rhs.pcie.bar[i] == null ||
        lhs.pcie.bar[i].bar_id != rhs.pcie.bar[i].bar_id ||
        lhs.pcie.bar[i].base != rhs.pcie.bar[i].base ||
        lhs.pcie.bar[i].size != rhs.pcie.bar[i].size ||
        lhs.pcie.bar[i].enabled != rhs.pcie.bar[i].enabled)
      return 1'b0;
  end
  foreach (lhs.interrupt_vectors[i]) begin
    if (lhs.interrupt_vectors[i].function_local_vector !=
          rhs.interrupt_vectors[i].function_local_vector ||
        lhs.interrupt_vectors[i].hardware_eq_vector !=
          rhs.interrupt_vectors[i].hardware_eq_vector ||
        lhs.interrupt_vectors[i].msix_table_index !=
          rhs.interrupt_vectors[i].msix_table_index ||
        lhs.interrupt_vectors[i].enabled !=
          rhs.interrupt_vectors[i].enabled)
      return 1'b0;
  end
  return 1'b1;
endfunction

// 功能：比较 request 携带与 retained 的 reset-isolation proof 完整公开值，
//   覆盖 stable digest 未包含的 replacement identity、state 与 backing release 确认。
// 输入/输出及副作用：只读，不 mint、登记或推进 proof 生命周期。
// 失败/边界：proof/isolated identity 为 null、replacement 不一致、队列数量或字段漂移返回 0；
//   不做 validate 或 digest 重算，validator-invalid 但值相等时仍可返回 1。
function automatic bit rdma_cmq_same_reset_isolation_proof_value(
  input rdma_cmq_reset_isolation_proof lhs,
  input rdma_cmq_reset_isolation_proof rhs
);
  if (lhs == null || rhs == null || lhs.isolated_identity == null ||
      rhs.isolated_identity == null ||
      lhs.proof_key != rhs.proof_key || lhs.proof_id != rhs.proof_id ||
      lhs.batch_key != rhs.batch_key || lhs.batch_id != rhs.batch_id ||
      lhs.attempt_id != rhs.attempt_id ||
      lhs.engine_instance_id != rhs.engine_instance_id ||
      lhs.engine_incarnation != rhs.engine_incarnation ||
      !lhs.isolated_identity.same_incarnation(rhs.isolated_identity) ||
      ((lhs.replacement_identity == null) !=
       (rhs.replacement_identity == null)) ||
      lhs.batch_digest !== rhs.batch_digest ||
      lhs.proof_digest !== rhs.proof_digest || lhs.state != rhs.state ||
      lhs.backing_release_confirmed != rhs.backing_release_confirmed ||
      lhs.isolated_request_indices.size() !=
        rhs.isolated_request_indices.size() ||
      lhs.isolated_image_digests.size() !=
        rhs.isolated_image_digests.size() ||
      lhs.isolated_authority_digests.size() !=
        rhs.isolated_authority_digests.size() ||
      lhs.isolated_recovery_owners.size() !=
        rhs.isolated_recovery_owners.size())
    return 1'b0;
  if (lhs.replacement_identity != null &&
      !lhs.replacement_identity.same_incarnation(
        rhs.replacement_identity
      ))
    return 1'b0;
  foreach (lhs.isolated_request_indices[i]) begin
    if (lhs.isolated_request_indices[i] !=
          rhs.isolated_request_indices[i] ||
        lhs.isolated_image_digests[i] !==
          rhs.isolated_image_digests[i] ||
        lhs.isolated_authority_digests[i] !==
          rhs.isolated_authority_digests[i] ||
        !rdma_cmq_same_journal_owner_value(
          lhs.isolated_recovery_owners[i],
          rhs.isolated_recovery_owners[i]
        ))
      return 1'b0;
  end
  return 1'b1;
endfunction

// 功能：按 request 顺序逐项比较 recovery batch 与 journal 的 request_index/image_digest/
//   authority_digest 三列，供 batch matcher 最后阶段使用。
// 输入/输出及副作用：只读两侧对象图，不复制 item、不重算 digest。
// 失败/边界：外层为 null、request 无 item、数量不等、item 为 null 或三列漂移返回 0；
//   重复但相等的 tuple 仍接受。
function automatic bit rdma_cmq_recovery_batch_ordered_item_tuple_matches(
  input rdma_cmq_submission_recovery_request request,
  input rdma_cmq_batch_submission_record journal_record
);
  if (request == null || journal_record == null ||
      request.items.size() == 0 ||
      request.items.size() != journal_record.items.size())
    return 1'b0;
  foreach (request.items[i]) begin
    if (request.items[i] == null || journal_record.items[i] == null ||
        request.items[i].request_index !=
          journal_record.items[i].request_index ||
        request.items[i].image_digest !==
          journal_record.items[i].image_digest ||
        request.items[i].authority_digest !==
          journal_record.items[i].authority_digest)
      return 1'b0;
  end
  return 1'b1;
endfunction
