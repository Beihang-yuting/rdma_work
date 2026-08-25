class rdma_resource_manager extends uvm_object;
  `uvm_object_utils(rdma_resource_manager)

  // Registry keys are exactly function_uid:generation:kind:object_id.
  protected rdma_resource registry[string];
  protected bit staged_allocations[string];
  protected rdma_recovery_record recovery_records[string];
  // The caller-owned reference is only a monotonic generation observer.  All
  // identity and configuration are read from the immutable deep-copy snapshot.
  protected rdma_function_binding generation_sources[string];
  protected rdma_function_binding binding_snapshots[string];
  protected int unsigned generation_high_water[string];
  protected bit generation_exhausted[string];
  protected bit known_generations[string];
  protected bit retired_generations[string];
  // Exact incarnation ownership is retained after release.  Including the
  // generation prevents a later Function generation from replacing an older
  // tombstone.
  protected rdma_function_handle incarnation_owners[string];
  protected rdma_handle incarnation_handles[string];

  // Local IDs are reusable and independent for every resource kind.  The
  // 28-bit serial component of object_id is monotonic and never reused; the
  // upper nibble carries kind so changing only handle.kind cannot alias a live
  // object from another independent pool.
  protected int unsigned next_local_id[rdma_resource_kind_e];
  protected int unsigned free_local_ids[rdma_resource_kind_e][$];
  protected bit fresh_local_id_exhausted[rdma_resource_kind_e];
  protected int unsigned next_object_serial[rdma_resource_kind_e];

  function new(string name = "rdma_resource_manager");
    super.new(name);
  endfunction

  protected function bit valid_kind(rdma_resource_kind_e kind);
    return kind inside {RDMA_RESOURCE_FUNCTION, RDMA_RESOURCE_PD,
                        RDMA_RESOURCE_MR, RDMA_RESOURCE_CQ,
                        RDMA_RESOURCE_QP, RDMA_RESOURCE_SRQ,
                        RDMA_RESOURCE_CMQ, RDMA_RESOURCE_CEQ,
                        RDMA_RESOURCE_AEQ};
  endfunction

  protected function int unsigned local_id_limit(
    rdma_resource_kind_e kind
  );
    case (kind)
      RDMA_RESOURCE_PD: return 16'hffff;
      RDMA_RESOURCE_MR: return 24'hff_ffff;
      default: return 32'hffff_ffff;
    endcase
  endfunction

  protected function rdma_status local_id_status(
    rdma_resource_kind_e kind,
    output bit has_free_id
  );
    int unsigned limit;

    limit = local_id_limit(kind);
    has_free_id = free_local_ids.exists(kind) &&
                  free_local_ids[kind].size() != 0;
    if (has_free_id) begin
      if (free_local_ids[kind][0] > limit)
        return rdma_status::make(
          RDMA_SC_RESOURCE_EXHAUSTED,
          "resource free-list local ID exceeds the hardware width"
        );
      return rdma_status::success();
    end
    if ((fresh_local_id_exhausted.exists(kind) &&
         fresh_local_id_exhausted[kind]) || next_local_id[kind] > limit)
      return rdma_status::make(RDMA_SC_RESOURCE_EXHAUSTED,
                               "resource local ID pool is exhausted");
    return rdma_status::success();
  endfunction

  protected function void consume_local_id(
    rdma_resource_kind_e kind,
    bit has_free_id,
    output int unsigned local_id
  );
    int unsigned limit;

    if (has_free_id) begin
      local_id = free_local_ids[kind].pop_front();
      return;
    end
    limit = local_id_limit(kind);
    local_id = next_local_id[kind];
    if (local_id == limit)
      fresh_local_id_exhausted[kind] = 1'b1;
    else
      next_local_id[kind]++;
  endfunction

  protected function string resource_key(rdma_handle handle);
    return $sformatf("%016h:%08h:%01h:%08h", handle.function_uid,
                     handle.generation, handle.kind, handle.object_id);
  endfunction

  protected function string incarnation_key(rdma_handle handle);
    return resource_key(handle);
  endfunction

  protected function string function_key(rdma_function_handle owner);
    return $sformatf("%016h:%08h", owner.function_uid, owner.object_id);
  endfunction

  protected function string function_generation_key(
    rdma_function_handle owner
  );
    return $sformatf("%016h:%08h:%08h", owner.function_uid,
                     owner.object_id, owner.generation);
  endfunction

  // Public carriers may be compatible subclasses, but only fields declared by
  // the built-in model are authoritative.  Borrowed carrier graphs are
  // structurally projected into direct-new built-in storage without invoking
  // their virtual clone/copy hooks.  An owned DMA mapping is the explicit
  // exception: its concrete clone carries opaque adapter release authority and
  // is accepted only through the checked contract below.  Future extension
  // support requires another explicit trusted adapter here.
  protected function rdma_status project_handle_value(
    rdma_handle source,
    string copy_label,
    output rdma_handle result
  );
    rdma_function_handle source_function;
    rdma_function_handle result_function;

    result = null;
    if (source == null)
      return rdma_status::success();
    if (source.kind == RDMA_RESOURCE_FUNCTION) begin
      if (!$cast(source_function, source))
        return rdma_status::make(
          RDMA_SC_INVALID_ARGUMENT,
          {copy_label, " Function handle is structurally incompatible"}
        );
      result_function = new({copy_label, "_function_handle"});
      result = result_function;
    end
    else begin
      result = new({copy_label, "_handle"});
    end
    result.kind = source.kind;
    result.function_uid = source.function_uid;
    result.object_id = source.object_id;
    result.generation = source.generation;
    return rdma_status::success();
  endfunction

  protected function rdma_status project_function_handle_value(
    rdma_function_handle source,
    string copy_label,
    output rdma_function_handle result
  );
    result = null;
    if (source == null)
      return rdma_status::success();
    result = new({copy_label, "_function_handle"});
    result.kind = source.kind;
    result.function_uid = source.function_uid;
    result.object_id = source.object_id;
    result.generation = source.generation;
    return rdma_status::success();
  endfunction

  protected function rdma_status project_mapping_value(
    rdma_dma_mapping source,
    string copy_label,
    output rdma_dma_mapping result
  );
    rdma_status status;

    result = null;
    if (source == null)
      return rdma_status::success();
    result = new({copy_label, "_mapping"});
    status = project_function_handle_value(
      source.function_h, {copy_label, "_function"}, result.function_h
    );
    if (!status.ok()) begin
      result = null;
      return status;
    end
    status = project_handle_value(source.owner_h, {copy_label, "_owner"},
                                  result.owner_h);
    if (!status.ok()) begin
      result = null;
      return status;
    end
    result.requester_bdf = source.requester_bdf;
    result.pasid_valid = source.pasid_valid;
    result.pasid = source.pasid;
    result.backing_addr = source.backing_addr;
    result.iova = source.iova;
    result.size = source.size;
    result.direction = source.direction;
    result.permissions = source.permissions;
    result.state = source.state;
    return rdma_status::success();
  endfunction

  protected function bit same_mapping_handle_value(
    rdma_handle lhs,
    rdma_handle rhs
  );
    if (lhs == null || rhs == null)
      return lhs == null && rhs == null;
    return lhs.kind == rhs.kind &&
           lhs.function_uid == rhs.function_uid &&
           lhs.object_id == rhs.object_id &&
           lhs.generation == rhs.generation;
  endfunction

  protected function bit same_mapping_release_fields(
    rdma_dma_mapping lhs,
    rdma_dma_mapping rhs
  );
    if (lhs == null || rhs == null)
      return lhs == null && rhs == null;
    return same_mapping_handle_value(lhs.function_h, rhs.function_h) &&
           lhs.requester_bdf == rhs.requester_bdf &&
           lhs.pasid_valid == rhs.pasid_valid &&
           lhs.pasid == rhs.pasid &&
           lhs.backing_addr.value == rhs.backing_addr.value &&
           lhs.iova.value == rhs.iova.value &&
           lhs.size == rhs.size &&
           lhs.direction == rhs.direction &&
           lhs.permissions == rhs.permissions &&
           same_mapping_handle_value(lhs.owner_h, rhs.owner_h);
  endfunction

  protected function bit same_mapping_value(
    rdma_dma_mapping lhs,
    rdma_dma_mapping rhs
  );
    if (lhs == null || rhs == null)
      return lhs == rhs;
    return same_mapping_release_fields(lhs, rhs) &&
           lhs.state == rhs.state;
  endfunction

  protected function bit mapping_handles_detached(
    rdma_dma_mapping lhs,
    rdma_dma_mapping rhs
  );
    if (lhs == null || rhs == null)
      return 1'b0;
    return (lhs.function_h == null || rhs.function_h == null ||
            lhs.function_h != rhs.function_h) &&
           (lhs.owner_h == null || rhs.owner_h == null ||
            lhs.owner_h != rhs.owner_h);
  endfunction

  protected function bit mapping_hook_value_intact(
    rdma_dma_mapping current,
    rdma_dma_mapping saved,
    uvm_object_wrapper expected_type
  );
    uvm_object_wrapper current_type;

    if (current == null || saved == null || current == saved ||
        expected_type == null)
      return 1'b0;
    current_type = current.get_object_type();
    return current_type != null && current_type == expected_type &&
           same_mapping_value(current, saved) &&
           mapping_handles_detached(current, saved);
  endfunction

  protected function bit owned_mapping_hook_graph_intact(
    rdma_dma_mapping source,
    rdma_dma_mapping result,
    rdma_dma_mapping saved_value,
    uvm_object_wrapper source_type,
    rdma_dma_mapping authority_snapshot,
    rdma_dma_mapping saved_authority,
    uvm_object_wrapper authority_type
  );
    return source != result && source != authority_snapshot &&
           result != authority_snapshot &&
           mapping_hook_value_intact(source, saved_value, source_type) &&
           mapping_hook_value_intact(result, saved_value, source_type) &&
           mapping_hook_value_intact(authority_snapshot, saved_authority,
                                     authority_type) &&
           mapping_handles_detached(source, result) &&
           mapping_handles_detached(source, authority_snapshot) &&
           mapping_handles_detached(result, authority_snapshot);
  endfunction

  // An owned mapping is also the adapter's release capability.  Preserve its
  // concrete value type while treating clone() as an untrusted boundary: the
  // clone must be registered, exact-type, detached, and value preserving.
  protected function rdma_status clone_owned_mapping_value(
    rdma_dma_mapping source,
    string copy_label,
    output rdma_dma_mapping result
  );
    rdma_dma_mapping saved_value;
    rdma_dma_mapping authority_snapshot;
    rdma_dma_mapping saved_authority;
    rdma_status status;
    uvm_object cloned_object;
    uvm_object_wrapper source_type;
    uvm_object_wrapper result_type;
    uvm_object_wrapper authority_type;

    result = null;
    if (source == null)
      return rdma_status::make(
        RDMA_SC_INVALID_ARGUMENT,
        {copy_label, " owned mapping is null"}
      );
    status = project_mapping_value(source, {copy_label, "_saved"},
                                   saved_value);
    if (!status.ok())
      return status;
    source_type = source.get_object_type();
    if (source_type == null ||
        source_type == rdma_dma_mapping::get_type())
      return rdma_status::make(
        RDMA_SC_INVALID_ARGUMENT,
        {copy_label, " owned mapping type is not a registered subtype"}
      );
    status = source.snapshot_release_authority(authority_snapshot);
    if (status == null || !status.ok() || authority_snapshot == null ||
        authority_snapshot == source ||
        !same_mapping_value(source, saved_value)) begin
      result = null;
      return rdma_status::make(
        RDMA_SC_INVALID_ARGUMENT,
        {copy_label, " owned mapping authority snapshot is unsupported or invalid"}
      );
    end
    authority_type = authority_snapshot.get_object_type();
    status = project_mapping_value(
      authority_snapshot, {copy_label, "_saved_authority"}, saved_authority
    );
    if (status == null || !status.ok() || authority_type == null ||
        authority_type != source_type ||
        !mapping_hook_value_intact(authority_snapshot, saved_authority,
                                   authority_type) ||
        !mapping_handles_detached(source, authority_snapshot)) begin
      result = null;
      return rdma_status::make(
        RDMA_SC_INVALID_ARGUMENT,
        {copy_label, " owned mapping authority snapshot changed value, type, or aliases"}
      );
    end
    cloned_object = source.clone();
    if (cloned_object == null || !$cast(result, cloned_object) ||
        result == source) begin
      result = null;
      return rdma_status::make(
        RDMA_SC_INVALID_ARGUMENT,
        {copy_label, " owned mapping clone contract failed"}
      );
    end
    result_type = result.get_object_type();
    if (result_type == null || result_type != source_type ||
        !owned_mapping_hook_graph_intact(
          source, result, saved_value, source_type,
          authority_snapshot, saved_authority, authority_type
        )) begin
      result = null;
      return rdma_status::make(
        RDMA_SC_INVALID_ARGUMENT,
        {copy_label, " owned mapping clone changed type, value, or aliases"}
      );
    end
    status = source.release_authority_status(authority_snapshot);
    if (status == null || !status.ok() ||
        !owned_mapping_hook_graph_intact(
          source, result, saved_value, source_type,
          authority_snapshot, saved_authority, authority_type
        )) begin
      result = null;
      return rdma_status::make(
        RDMA_SC_INVALID_ARGUMENT,
        {copy_label, " owned mapping source authority hook changed value, authority, or aliases"}
      );
    end
    status = result.release_authority_status(authority_snapshot);
    if (status == null || !status.ok() ||
        !owned_mapping_hook_graph_intact(
          source, result, saved_value, source_type,
          authority_snapshot, saved_authority, authority_type
        )) begin
      result = null;
      return rdma_status::make(
        RDMA_SC_INVALID_ARGUMENT,
        {copy_label, " owned mapping result authority hook changed value, authority, or aliases"}
      );
    end
    return rdma_status::success();
  endfunction

  // Recovery may carry a detached copy of an owned mapping, but matching
  // public fields are not proof that it controls the same allocation.  Use an
  // opaque authority snapshot from the authoritative mapping and require the
  // recovery mapping to accept it, while retaining the same type, value, and
  // alias guards used by the owned clone boundary.
  protected function bit same_owned_mapping_authority(
    rdma_dma_mapping authoritative,
    rdma_dma_mapping recovery
  );
    rdma_dma_mapping saved_value;
    rdma_dma_mapping authority_snapshot;
    rdma_dma_mapping saved_authority;
    rdma_status status;
    uvm_object_wrapper mapping_type;
    uvm_object_wrapper authority_type;

    if (authoritative == null || recovery == null)
      return 1'b0;
    mapping_type = authoritative.get_object_type();
    status = project_mapping_value(
      authoritative, "owned authority correspondence value", saved_value
    );
    if (status == null || !status.ok() || mapping_type == null)
      return 1'b0;
    status = authoritative.snapshot_release_authority(authority_snapshot);
    if (status == null || !status.ok() || authority_snapshot == null)
      return 1'b0;
    authority_type = authority_snapshot.get_object_type();
    status = project_mapping_value(
      authority_snapshot, "owned authority correspondence snapshot",
      saved_authority
    );
    if (status == null || !status.ok() || authority_type == null ||
        authority_type != mapping_type ||
        !owned_mapping_hook_graph_intact(
          authoritative, recovery, saved_value, mapping_type,
          authority_snapshot, saved_authority, authority_type
        ))
      return 1'b0;
    status = authoritative.release_authority_status(authority_snapshot);
    if (status == null || !status.ok() ||
        !owned_mapping_hook_graph_intact(
          authoritative, recovery, saved_value, mapping_type,
          authority_snapshot, saved_authority, authority_type
        ))
      return 1'b0;
    status = recovery.release_authority_status(authority_snapshot);
    return status != null && status.ok() &&
           owned_mapping_hook_graph_intact(
             authoritative, recovery, saved_value, mapping_type,
             authority_snapshot, saved_authority, authority_type
           );
  endfunction

  // Completion is an adapter-defined opaque fact.  Invoke its virtual query
  // only on an authority-preserving clone, and reject any public value, type,
  // or handle-alias mutation at the hook boundary.
  function rdma_status query_owned_release_completion(
    rdma_dma_mapping mapping,
    output bit release_complete
  );
    rdma_dma_mapping completion_query;
    rdma_dma_mapping saved_mapping;
    rdma_dma_mapping saved_query;
    rdma_status status;
    uvm_object_wrapper mapping_type;
    uvm_object_wrapper query_type;

    release_complete = 1'b0;
    if (mapping == null)
      return rdma_status::make(
        RDMA_SC_INVALID_ARGUMENT, "release completion mapping is null"
      );
    mapping_type = mapping.get_object_type();
    status = project_mapping_value(
      mapping, "release completion input guard", saved_mapping
    );
    if (status == null || !status.ok() || mapping_type == null ||
        !mapping_hook_value_intact(mapping, saved_mapping, mapping_type))
      return rdma_status::make(
        RDMA_SC_INVALID_ARGUMENT,
        "release completion input guard is invalid"
      );
    status = clone_owned_mapping_value(
      mapping, "release completion query", completion_query
    );
    if (status == null || !status.ok() || completion_query == null)
      return rdma_status::make(
        RDMA_SC_INVALID_ARGUMENT,
        "release completion query clone is invalid"
      );
    query_type = completion_query.get_object_type();
    status = project_mapping_value(
      completion_query, "release completion query guard", saved_query
    );
    if (status == null || !status.ok() || query_type == null ||
        query_type != mapping_type ||
        !mapping_hook_value_intact(completion_query, saved_query,
                                   query_type) ||
        !mapping_handles_detached(mapping, completion_query))
      return rdma_status::make(
        RDMA_SC_INVALID_ARGUMENT,
        "release completion query guard is invalid"
      );
    status = completion_query.release_completion_status(release_complete);
    if (status == null ||
        !mapping_hook_value_intact(mapping, saved_mapping, mapping_type) ||
        !mapping_hook_value_intact(completion_query, saved_query,
                                   query_type) ||
        !mapping_handles_detached(mapping, completion_query)) begin
      release_complete = 1'b0;
      return rdma_status::make(
        RDMA_SC_INVALID_ARGUMENT,
        "release completion hook changed mapping value, type, or aliases"
      );
    end
    if (!status.ok()) begin
      release_complete = 1'b0;
      return status;
    end
    return rdma_status::success();
  endfunction

  protected function rdma_status project_backing_ref_value(
    rdma_backing_ref source,
    string copy_label,
    output rdma_backing_ref result
  );
    rdma_status status;

    result = null;
    if (source == null)
      return rdma_status::success();
    result = new({copy_label, "_backing_ref"});
    result.mapping = null;
    if (source.ownership == RDMA_OWNERSHIP_CONTROL_PLANE)
      status = clone_owned_mapping_value(
        source.mapping, {copy_label, "_mapping"}, result.mapping
      );
    else
      status = project_mapping_value(
        source.mapping, {copy_label, "_mapping"}, result.mapping
      );
    if (!status.ok()) begin
      result = null;
      return status;
    end
    result.ownership = source.ownership;
    result.release_complete = source.release_complete;
    status = result.validate();
    if (status == null) begin
      result = null;
      return rdma_status::make(
        RDMA_SC_INVALID_STATE,
        {copy_label, " backing validation returned null"}
      );
    end
    if (!status.ok())
      result = null;
    return status;
  endfunction

  protected function rdma_status project_hmc_ref_value(
    rdma_hmc_ref source,
    string copy_label,
    output rdma_hmc_ref result
  );
    rdma_status status;

    result = null;
    if (source == null)
      return rdma_status::success();
    result = new({copy_label, "_hmc_ref"});
    status = project_function_handle_value(
      source.owner, {copy_label, "_owner"}, result.owner
    );
    if (!status.ok()) begin
      result = null;
      return status;
    end
    result.object_kind = source.object_kind;
    result.address = source.address;
    result.size = source.size;
    result.first_pbl_index = source.first_pbl_index;
    result.ownership = source.ownership;
    result.release_complete = source.release_complete;
    return rdma_status::success();
  endfunction

  protected function rdma_status project_bar_value(
    rdma_bar_info source,
    string copy_label,
    output rdma_bar_info result
  );
    result = null;
    if (source == null)
      return rdma_status::make(
        RDMA_SC_INVALID_ARGUMENT,
        {copy_label, " BAR metadata is null"}
      );
    result = new({copy_label, "_bar"});
    result.bar_id = source.bar_id;
    result.base = source.base;
    result.size = source.size;
    result.enabled = source.enabled;
    return rdma_status::success();
  endfunction

  protected function rdma_status project_pcie_value(
    rdma_pcie_identity source,
    string copy_label,
    output rdma_pcie_identity result
  );
    rdma_status status;

    result = null;
    if (source == null)
      return rdma_status::make(
        RDMA_SC_INVALID_ARGUMENT,
        {copy_label, " PCIe identity is null"}
      );
    result = new({copy_label, "_pcie"});
    foreach (result.bar[i])
      result.bar[i] = null;
    result.bdf = source.bdf;
    result.parent_pf_bdf = source.parent_pf_bdf;
    result.vf_index = source.vf_index;
    result.mse = source.mse;
    result.bme = source.bme;
    foreach (source.bar[i]) begin
      status = project_bar_value(
        source.bar[i], $sformatf("%s_bar_%0d", copy_label, i),
        result.bar[i]
      );
      if (!status.ok()) begin
        result = null;
        return status;
      end
    end
    return rdma_status::success();
  endfunction

  protected function rdma_status project_binding_value(
    rdma_function_binding source,
    string copy_label,
    output rdma_function_binding result
  );
    rdma_status status;

    result = null;
    if (source == null)
      return rdma_status::make(
        RDMA_SC_INVALID_ARGUMENT,
        {copy_label, " Function binding is null"}
      );
    result = new({copy_label, "_binding"});
    result.pcie = null;
    result.owner_h = null;
    status = project_pcie_value(source.pcie, {copy_label, "_pcie"},
                                result.pcie);
    if (!status.ok()) begin
      result = null;
      return status;
    end
    status = project_handle_value(source.owner_h, {copy_label, "_owner"},
                                  result.owner_h);
    if (!status.ok()) begin
      result = null;
      return status;
    end
    result.function_uid = source.function_uid;
    result.notify_bar_id = source.notify_bar_id;
    result.notify_base = source.notify_base;
    result.notify_size = source.notify_size;
    result.notify_table_sel = source.notify_table_sel;
    result.notify_table_index = source.notify_table_index;
    result.host_id = source.host_id;
    result.pfvf_id = source.pfvf_id;
    result.rdma_vf_id = source.rdma_vf_id;
    result.global_function_id = source.global_function_id;
    result.vsi_id = source.vsi_id;
    result.dma_domain_id = source.dma_domain_id;
    result.dma_domain_valid = source.dma_domain_valid;
    result.state = source.state;
    result.generation = source.generation;
    result.notify_valid = source.notify_valid;
    result.notify_ready = source.notify_ready;
    result.dmi_valid = source.dmi_valid;
    result.dmi_ready = source.dmi_ready;
    result.vft_valid = source.vft_valid;
    result.vft_ready = source.vft_ready;
    return rdma_status::success();
  endfunction

  protected function rdma_status project_opcode_value(
    rdma_cmq_opcode_key source,
    string copy_label,
    output rdma_cmq_opcode_key result
  );
    result = null;
    if (source == null)
      return rdma_status::success();
    result = new({copy_label, "_opcode"});
    result.profile_name = source.profile_name;
    result.opcode = source.opcode;
    result.variant = source.variant;
    return rdma_status::success();
  endfunction

  protected function rdma_status project_status_value(
    rdma_status source,
    string copy_label,
    output rdma_status result
  );
    result = null;
    if (source == null)
      return rdma_status::success();
    result = new({copy_label, "_status"});
    result.category = source.category;
    result.code = source.code;
    result.hardware_code = source.hardware_code;
    result.hardware_code_valid = source.hardware_code_valid;
    result.source_engine = source.source_engine;
    result.function_uid = source.function_uid;
    result.generation = source.generation;
    result.resource_id = source.resource_id;
    result.command_id = source.command_id;
    result.wr_id = source.wr_id;
    result.severity = source.severity;
    result.retryable = source.retryable;
    result.message = source.message;
    return rdma_status::success();
  endfunction

  protected function rdma_status project_ticket_value(
    rdma_cmq_ticket source,
    string copy_label,
    output rdma_cmq_ticket result
  );
    rdma_status status;

    result = null;
    if (source == null)
      return rdma_status::success();
    result = new({copy_label, "_ticket"});
    status = project_function_handle_value(
      source.function_h, {copy_label, "_function"}, result.function_h
    );
    if (!status.ok()) begin
      result = null;
      return status;
    end
    status = project_handle_value(source.cmq_h, {copy_label, "_cmq"},
                                  result.cmq_h);
    if (!status.ok()) begin
      result = null;
      return status;
    end
    status = project_opcode_value(source.opcode_key, {copy_label, "_opcode"},
                                  result.opcode_key);
    if (!status.ok()) begin
      result = null;
      return status;
    end
    result.command_id = source.command_id;
    result.slot_sequence = source.slot_sequence;
    result.sq_index = source.sq_index;
    result.sq_wrap = source.sq_wrap;
    result.absolute_deadline = source.absolute_deadline;
    return rdma_status::success();
  endfunction

  protected function rdma_status project_recovery_value(
    rdma_recovery_record source,
    string copy_label,
    output rdma_recovery_record result
  );
    rdma_backing_ref backing_copy;
    rdma_hmc_ref hmc_copy;
    rdma_status status_copy;
    rdma_status status;

    result = null;
    if (source == null)
      return rdma_status::make(
        RDMA_SC_INVALID_ARGUMENT,
        {copy_label, " recovery record is null"}
      );
    result = new({copy_label, "_recovery"});
    status = project_handle_value(source.resource_h,
                                  {copy_label, "_resource"},
                                  result.resource_h);
    if (!status.ok()) begin
      result = null;
      return status;
    end
    result.hardware_presence = source.hardware_presence;
    result.completed_steps = source.completed_steps;
    result.pending_steps = source.pending_steps;
    result.backing_refs.delete();
    foreach (source.backing_refs[i]) begin
      status = project_backing_ref_value(
        source.backing_refs[i], $sformatf("%s_backing_%0d", copy_label, i),
        backing_copy
      );
      if (!status.ok()) begin
        result = null;
        return status;
      end
      result.backing_refs.push_back(backing_copy);
    end
    result.hmc_refs.delete();
    foreach (source.hmc_refs[i]) begin
      status = project_hmc_ref_value(
        source.hmc_refs[i], $sformatf("%s_hmc_%0d", copy_label, i), hmc_copy
      );
      if (!status.ok()) begin
        result = null;
        return status;
      end
      result.hmc_refs.push_back(hmc_copy);
    end
    status = project_ticket_value(source.ambiguous_ticket,
                                  {copy_label, "_ticket"},
                                  result.ambiguous_ticket);
    if (!status.ok()) begin
      result = null;
      return status;
    end
    status = project_status_value(source.primary_status,
                                  {copy_label, "_primary"},
                                  result.primary_status);
    if (!status.ok()) begin
      result = null;
      return status;
    end
    result.rollback_statuses.delete();
    foreach (source.rollback_statuses[i]) begin
      status = project_status_value(
        source.rollback_statuses[i],
        $sformatf("%s_rollback_%0d", copy_label, i), status_copy
      );
      if (!status.ok()) begin
        result = null;
        return status;
      end
      result.rollback_statuses.push_back(status_copy);
    end
    return rdma_status::success();
  endfunction

  protected function rdma_status project_resource_base_fields(
    rdma_resource source,
    string copy_label,
    rdma_resource result
  );
    rdma_backing_ref backing_copy;
    rdma_hmc_ref hmc_copy;
    rdma_handle dependency_copy;
    rdma_status status;

    status = project_handle_value(source.handle, {copy_label, "_handle"},
                                  result.handle);
    if (!status.ok())
      return status;
    status = project_function_handle_value(
      source.owner, {copy_label, "_owner"}, result.owner
    );
    if (!status.ok())
      return status;
    result.state = source.state;
    result.hmc_fvm_addr = source.hmc_fvm_addr;
    result.hmc_fvm_addr_valid = source.hmc_fvm_addr_valid;
    result.backing_refs.delete();
    foreach (source.backing_refs[i]) begin
      status = project_backing_ref_value(
        source.backing_refs[i], $sformatf("%s_backing_%0d", copy_label, i),
        backing_copy
      );
      if (!status.ok())
        return status;
      result.backing_refs.push_back(backing_copy);
    end
    result.hmc_refs.delete();
    foreach (source.hmc_refs[i]) begin
      status = project_hmc_ref_value(
        source.hmc_refs[i], $sformatf("%s_hmc_%0d", copy_label, i), hmc_copy
      );
      if (!status.ok())
        return status;
      result.hmc_refs.push_back(hmc_copy);
    end
    result.dependencies.delete();
    foreach (source.dependencies[i]) begin
      status = project_handle_value(
        source.dependencies[i],
        $sformatf("%s_dependency_%0d", copy_label, i), dependency_copy
      );
      if (!status.ok())
        return status;
      result.dependencies.push_back(dependency_copy);
    end
    result.outstanding_ids = source.outstanding_ids;
    return rdma_status::success();
  endfunction

  protected function void project_queue_fields(
    rdma_queue_resource source,
    rdma_queue_resource result
  );
    result.depth = source.depth;
    result.producer_index = source.producer_index;
    result.consumer_index = source.consumer_index;
    result.producer_wrap = source.producer_wrap;
    result.consumer_wrap = source.consumer_wrap;
    result.queue_iova = source.queue_iova;
  endfunction

  protected function rdma_status project_resource_value(
    rdma_resource source,
    string copy_label,
    output rdma_resource result
  );
    rdma_function source_function;
    rdma_function result_function;
    rdma_pd source_pd;
    rdma_pd result_pd;
    rdma_mr source_mr;
    rdma_mr result_mr;
    rdma_cq source_cq;
    rdma_cq result_cq;
    rdma_qp source_qp;
    rdma_qp result_qp;
    rdma_srq source_srq;
    rdma_srq result_srq;
    rdma_cmq source_cmq;
    rdma_cmq result_cmq;
    rdma_ceq source_ceq;
    rdma_ceq result_ceq;
    rdma_aeq source_aeq;
    rdma_aeq result_aeq;
    rdma_status status;

    result = null;
    if (source == null || source.handle == null ||
        !valid_kind(source.handle.kind))
      return rdma_status::make(
        RDMA_SC_INVALID_ARGUMENT,
        {copy_label, " resource carrier is structurally incompatible"}
      );

    case (source.handle.kind)
      RDMA_RESOURCE_FUNCTION: begin
        if (!$cast(source_function, source))
          return rdma_status::make(
            RDMA_SC_INVALID_ARGUMENT,
            {copy_label, " Function carrier does not match handle kind"}
          );
        result_function = new({copy_label, "_function"});
        result_function.binding = null;
        result = result_function;
      end
      RDMA_RESOURCE_PD: begin
        if (!$cast(source_pd, source))
          return rdma_status::make(
            RDMA_SC_INVALID_ARGUMENT,
            {copy_label, " PD carrier does not match handle kind"}
          );
        result_pd = new({copy_label, "_pd"});
        result = result_pd;
      end
      RDMA_RESOURCE_MR: begin
        if (!$cast(source_mr, source))
          return rdma_status::make(
            RDMA_SC_INVALID_ARGUMENT,
            {copy_label, " MR carrier does not match handle kind"}
          );
        result_mr = new({copy_label, "_mr"});
        result = result_mr;
      end
      RDMA_RESOURCE_CQ: begin
        if (!$cast(source_cq, source))
          return rdma_status::make(
            RDMA_SC_INVALID_ARGUMENT,
            {copy_label, " CQ carrier does not match handle kind"}
          );
        result_cq = new({copy_label, "_cq"});
        result = result_cq;
      end
      RDMA_RESOURCE_QP: begin
        if (!$cast(source_qp, source))
          return rdma_status::make(
            RDMA_SC_INVALID_ARGUMENT,
            {copy_label, " QP carrier does not match handle kind"}
          );
        result_qp = new({copy_label, "_qp"});
        result = result_qp;
      end
      RDMA_RESOURCE_SRQ: begin
        if (!$cast(source_srq, source))
          return rdma_status::make(
            RDMA_SC_INVALID_ARGUMENT,
            {copy_label, " SRQ carrier does not match handle kind"}
          );
        result_srq = new({copy_label, "_srq"});
        result = result_srq;
      end
      RDMA_RESOURCE_CMQ: begin
        if (!$cast(source_cmq, source))
          return rdma_status::make(
            RDMA_SC_INVALID_ARGUMENT,
            {copy_label, " CMQ carrier does not match handle kind"}
          );
        result_cmq = new({copy_label, "_cmq"});
        result = result_cmq;
      end
      RDMA_RESOURCE_CEQ: begin
        if (!$cast(source_ceq, source))
          return rdma_status::make(
            RDMA_SC_INVALID_ARGUMENT,
            {copy_label, " CEQ carrier does not match handle kind"}
          );
        result_ceq = new({copy_label, "_ceq"});
        result = result_ceq;
      end
      RDMA_RESOURCE_AEQ: begin
        if (!$cast(source_aeq, source))
          return rdma_status::make(
            RDMA_SC_INVALID_ARGUMENT,
            {copy_label, " AEQ carrier does not match handle kind"}
          );
        result_aeq = new({copy_label, "_aeq"});
        result = result_aeq;
      end
      default:
        return rdma_status::make(
          RDMA_SC_INVALID_ARGUMENT,
          {copy_label, " resource kind is invalid"}
        );
    endcase

    status = project_resource_base_fields(source, copy_label, result);
    if (!status.ok()) begin
      result = null;
      return status;
    end

    case (source.handle.kind)
      RDMA_RESOURCE_FUNCTION: begin
        result_function.local_function_id = source_function.local_function_id;
        result_function.global_function_id =
          source_function.global_function_id;
        result_function.rdma_vf_id = source_function.rdma_vf_id;
        result_function.vsi_id = source_function.vsi_id;
        result_function.pfvf_id = source_function.pfvf_id;
        status = project_binding_value(
          source_function.binding, {copy_label, "_binding"},
          result_function.binding
        );
      end
      RDMA_RESOURCE_PD: begin
        result_pd.local_pd_id = source_pd.local_pd_id;
        result_pd.global_pd_id = source_pd.global_pd_id;
      end
      RDMA_RESOURCE_MR: begin
        result_mr.local_mr_id = source_mr.local_mr_id;
        result_mr.global_mr_id = source_mr.global_mr_id;
        status = project_handle_value(
          source_mr.pd_h, {copy_label, "_pd"}, result_mr.pd_h
        );
        result_mr.iova = source_mr.iova;
        result_mr.length = source_mr.length;
        result_mr.lkey = source_mr.lkey;
        result_mr.rkey = source_mr.rkey;
        result_mr.access = source_mr.access;
        result_mr.mr_serial = source_mr.mr_serial;
      end
      RDMA_RESOURCE_CQ: begin
        project_queue_fields(source_cq, result_cq);
        result_cq.local_cq_id = source_cq.local_cq_id;
        result_cq.global_cq_id = source_cq.global_cq_id;
        status = project_handle_value(
          source_cq.ceq_h, {copy_label, "_ceq"}, result_cq.ceq_h
        );
      end
      RDMA_RESOURCE_QP: begin
        result_qp.local_qp_id = source_qp.local_qp_id;
        result_qp.global_qp_id = source_qp.global_qp_id;
        result_qp.transport = source_qp.transport;
        result_qp.qp_state = source_qp.qp_state;
        result_qp.sq_depth = source_qp.sq_depth;
        result_qp.rq_depth = source_qp.rq_depth;
        result_qp.sq_producer_index = source_qp.sq_producer_index;
        result_qp.sq_consumer_index = source_qp.sq_consumer_index;
        result_qp.sq_wrap = source_qp.sq_wrap;
        result_qp.sq_consumer_wrap = source_qp.sq_consumer_wrap;
        result_qp.rq_producer_index = source_qp.rq_producer_index;
        result_qp.rq_consumer_index = source_qp.rq_consumer_index;
        result_qp.rq_wrap = source_qp.rq_wrap;
        result_qp.rq_consumer_wrap = source_qp.rq_consumer_wrap;
        result_qp.sq_iova = source_qp.sq_iova;
        result_qp.rq_iova = source_qp.rq_iova;
        status = project_handle_value(
          source_qp.pd_h, {copy_label, "_pd"}, result_qp.pd_h
        );
        if (status.ok())
          status = project_handle_value(
            source_qp.send_cq_h, {copy_label, "_send_cq"},
            result_qp.send_cq_h
          );
        if (status.ok())
          status = project_handle_value(
            source_qp.recv_cq_h, {copy_label, "_recv_cq"},
            result_qp.recv_cq_h
          );
        if (status.ok())
          status = project_handle_value(
            source_qp.srq_h, {copy_label, "_srq"}, result_qp.srq_h
          );
      end
      RDMA_RESOURCE_SRQ: begin
        project_queue_fields(source_srq, result_srq);
        result_srq.local_srq_id = source_srq.local_srq_id;
        result_srq.global_srq_id = source_srq.global_srq_id;
        result_srq.max_sge = source_srq.max_sge;
        status = project_handle_value(
          source_srq.pd_h, {copy_label, "_pd"}, result_srq.pd_h
        );
      end
      RDMA_RESOURCE_CMQ: begin
        project_queue_fields(source_cmq, result_cmq);
        result_cmq.local_cmq_id = source_cmq.local_cmq_id;
        result_cmq.global_cmq_id = source_cmq.global_cmq_id;
        result_cmq.completion_producer_index =
          source_cmq.completion_producer_index;
        result_cmq.completion_consumer_index =
          source_cmq.completion_consumer_index;
        result_cmq.completion_wrap = source_cmq.completion_wrap;
        result_cmq.completion_consumer_wrap =
          source_cmq.completion_consumer_wrap;
        result_cmq.completion_iova = source_cmq.completion_iova;
      end
      RDMA_RESOURCE_CEQ: begin
        project_queue_fields(source_ceq, result_ceq);
        result_ceq.local_ceq_id = source_ceq.local_ceq_id;
        result_ceq.global_ceq_id = source_ceq.global_ceq_id;
      end
      RDMA_RESOURCE_AEQ: begin
        project_queue_fields(source_aeq, result_aeq);
        result_aeq.local_aeq_id = source_aeq.local_aeq_id;
        result_aeq.global_aeq_id = source_aeq.global_aeq_id;
      end
    endcase

    if (status == null || !status.ok()) begin
      result = null;
      if (status == null)
        return rdma_status::make(
          RDMA_SC_INVALID_STATE,
          {copy_label, " projection returned null status"}
        );
      return status;
    end
    return rdma_status::success();
  endfunction

  protected function rdma_status registry_schema_status(string operation);
    rdma_resource projected;
    rdma_status status;

    foreach (registry[key]) begin
      status = project_resource_value(
        registry[key], {operation, "_registry_entry"}, projected
      );
      if (!status.ok())
        return status;
      registry[key] = projected;
    end
    return rdma_status::success();
  endfunction

  protected function rdma_status recovery_schema_status(string operation);
    rdma_recovery_record projected;
    rdma_status status;

    foreach (recovery_records[key]) begin
      status = project_recovery_value(
        recovery_records[key], {operation, "_recovery_entry"}, projected
      );
      if (!status.ok())
        return status;
      recovery_records[key] = projected;
    end
    return rdma_status::success();
  endfunction

  protected function rdma_status recovery_entry_schema_status(
    string key,
    string operation
  );
    rdma_recovery_record projected;
    rdma_status status;

    if (recovery_records.exists(key)) begin
      status = project_recovery_value(
        recovery_records[key], {operation, "_recovery_entry"}, projected
      );
      if (!status.ok())
        return status;
      recovery_records[key] = projected;
    end
    return rdma_status::success();
  endfunction

  protected function bit same_outstanding_ids(
    rdma_resource lhs,
    rdma_resource rhs
  );
    if (lhs == null || rhs == null ||
        lhs.outstanding_ids.size() != rhs.outstanding_ids.size())
      return 1'b0;
    foreach (lhs.outstanding_ids[i]) begin
      if (lhs.outstanding_ids[i] != rhs.outstanding_ids[i])
        return 1'b0;
    end
    return 1'b1;
  endfunction

  protected function bit same_handle_instance(rdma_handle lhs,
                                               rdma_handle rhs);
    if (lhs == null || rhs == null)
      return lhs == rhs;
    return lhs.kind == rhs.kind &&
           lhs.function_uid == rhs.function_uid &&
           lhs.object_id == rhs.object_id &&
           lhs.generation == rhs.generation;
  endfunction

  protected function bit same_handle_value(rdma_handle lhs,
                                            rdma_handle rhs);
    return same_handle_instance(lhs, rhs);
  endfunction

  protected function bit same_dependency_topology(rdma_resource lhs,
                                                  rdma_resource rhs);
    if (lhs == null || rhs == null ||
        lhs.dependencies.size() != rhs.dependencies.size())
      return 1'b0;
    foreach (lhs.dependencies[i]) begin
      if (!same_handle_instance(lhs.dependencies[i], rhs.dependencies[i]))
        return 1'b0;
    end
    return 1'b1;
  endfunction

  protected function bit same_binding_identity(rdma_function_binding lhs,
                                               rdma_function_binding rhs);
    if (lhs == null || rhs == null)
      return lhs == rhs;
    if (lhs.function_uid != rhs.function_uid ||
        lhs.notify_bar_id != rhs.notify_bar_id ||
        lhs.notify_base != rhs.notify_base ||
        lhs.notify_size != rhs.notify_size ||
        lhs.notify_table_sel != rhs.notify_table_sel ||
        lhs.notify_table_index != rhs.notify_table_index ||
        lhs.host_id != rhs.host_id || lhs.pfvf_id != rhs.pfvf_id ||
        lhs.rdma_vf_id != rhs.rdma_vf_id ||
        lhs.global_function_id != rhs.global_function_id ||
        lhs.vsi_id != rhs.vsi_id ||
        lhs.dma_domain_id != rhs.dma_domain_id ||
        lhs.dma_domain_valid != rhs.dma_domain_valid ||
        lhs.state != rhs.state || lhs.generation != rhs.generation ||
        lhs.notify_valid != rhs.notify_valid ||
        lhs.notify_ready != rhs.notify_ready ||
        lhs.dmi_valid != rhs.dmi_valid || lhs.dmi_ready != rhs.dmi_ready ||
        lhs.vft_valid != rhs.vft_valid || lhs.vft_ready != rhs.vft_ready ||
        !same_handle_value(lhs.owner_h, rhs.owner_h))
      return 1'b0;
    if (lhs.pcie == null || rhs.pcie == null)
      return lhs.pcie == rhs.pcie;
    if (lhs.pcie.bdf != rhs.pcie.bdf ||
        lhs.pcie.parent_pf_bdf != rhs.pcie.parent_pf_bdf ||
        lhs.pcie.vf_index != rhs.pcie.vf_index ||
        lhs.pcie.mse != rhs.pcie.mse || lhs.pcie.bme != rhs.pcie.bme)
      return 1'b0;
    foreach (lhs.pcie.bar[i]) begin
      if (lhs.pcie.bar[i] == null || rhs.pcie.bar[i] == null) begin
        if (lhs.pcie.bar[i] != rhs.pcie.bar[i])
          return 1'b0;
      end
      else if (lhs.pcie.bar[i].bar_id != rhs.pcie.bar[i].bar_id ||
               lhs.pcie.bar[i].base != rhs.pcie.bar[i].base ||
               lhs.pcie.bar[i].size != rhs.pcie.bar[i].size ||
               lhs.pcie.bar[i].enabled != rhs.pcie.bar[i].enabled)
        return 1'b0;
    end
    return 1'b1;
  endfunction

  protected function rdma_status publication_identity_status(
    rdma_resource candidate,
    rdma_resource authoritative
  );
    rdma_function candidate_function;
    rdma_function authoritative_function;
    rdma_pd candidate_pd;
    rdma_pd authoritative_pd;
    rdma_mr candidate_mr;
    rdma_mr authoritative_mr;
    rdma_cq candidate_cq;
    rdma_cq authoritative_cq;
    rdma_qp candidate_qp;
    rdma_qp authoritative_qp;
    rdma_srq candidate_srq;
    rdma_srq authoritative_srq;
    rdma_cmq candidate_cmq;
    rdma_cmq authoritative_cmq;
    rdma_ceq candidate_ceq;
    rdma_ceq authoritative_ceq;
    rdma_aeq candidate_aeq;
    rdma_aeq authoritative_aeq;
    bit fields_match;

    if (candidate == null || authoritative == null ||
        candidate.handle == null || authoritative.handle == null ||
        candidate.handle.kind != authoritative.handle.kind ||
        !same_handle_instance(candidate.handle, authoritative.handle) ||
        !same_handle_instance(candidate.owner, authoritative.owner) ||
        !same_dependency_topology(candidate, authoritative) ||
        !same_outstanding_ids(candidate, authoritative))
      return rdma_status::make(
        RDMA_SC_INVALID_ARGUMENT,
        "published resource identity or topology changed"
      );

    fields_match = 1'b0;
    case (authoritative.handle.kind)
      RDMA_RESOURCE_FUNCTION: begin
        if ($cast(candidate_function, candidate) &&
            $cast(authoritative_function, authoritative))
          fields_match = candidate_function.local_function_id ==
                      authoritative_function.local_function_id &&
                    candidate_function.global_function_id ==
                      authoritative_function.global_function_id &&
                    candidate_function.rdma_vf_id ==
                      authoritative_function.rdma_vf_id &&
                    candidate_function.vsi_id == authoritative_function.vsi_id &&
                    candidate_function.pfvf_id ==
                      authoritative_function.pfvf_id &&
                    same_binding_identity(candidate_function.binding,
                                          authoritative_function.binding);
      end
      RDMA_RESOURCE_PD: begin
        if ($cast(candidate_pd, candidate) &&
            $cast(authoritative_pd, authoritative))
          fields_match = candidate_pd.local_pd_id == authoritative_pd.local_pd_id &&
                    candidate_pd.global_pd_id == authoritative_pd.global_pd_id;
      end
      RDMA_RESOURCE_MR: begin
        if ($cast(candidate_mr, candidate) &&
            $cast(authoritative_mr, authoritative))
          fields_match = candidate_mr.local_mr_id == authoritative_mr.local_mr_id &&
                    candidate_mr.global_mr_id == authoritative_mr.global_mr_id &&
                    same_handle_instance(candidate_mr.pd_h,
                                         authoritative_mr.pd_h);
      end
      RDMA_RESOURCE_CQ: begin
        if ($cast(candidate_cq, candidate) &&
            $cast(authoritative_cq, authoritative))
          fields_match = candidate_cq.local_cq_id == authoritative_cq.local_cq_id &&
                    candidate_cq.global_cq_id == authoritative_cq.global_cq_id &&
                    same_handle_instance(candidate_cq.ceq_h,
                                         authoritative_cq.ceq_h);
      end
      RDMA_RESOURCE_QP: begin
        if ($cast(candidate_qp, candidate) &&
            $cast(authoritative_qp, authoritative))
          fields_match = candidate_qp.local_qp_id == authoritative_qp.local_qp_id &&
                    candidate_qp.global_qp_id == authoritative_qp.global_qp_id &&
                    same_handle_instance(candidate_qp.pd_h,
                                         authoritative_qp.pd_h) &&
                    same_handle_instance(candidate_qp.send_cq_h,
                                         authoritative_qp.send_cq_h) &&
                    same_handle_instance(candidate_qp.recv_cq_h,
                                         authoritative_qp.recv_cq_h) &&
                    same_handle_instance(candidate_qp.srq_h,
                                         authoritative_qp.srq_h);
      end
      RDMA_RESOURCE_SRQ: begin
        if ($cast(candidate_srq, candidate) &&
            $cast(authoritative_srq, authoritative))
          fields_match = candidate_srq.local_srq_id ==
                      authoritative_srq.local_srq_id &&
                    candidate_srq.global_srq_id ==
                      authoritative_srq.global_srq_id &&
                    same_handle_instance(candidate_srq.pd_h,
                                         authoritative_srq.pd_h);
      end
      RDMA_RESOURCE_CMQ: begin
        if ($cast(candidate_cmq, candidate) &&
            $cast(authoritative_cmq, authoritative))
          fields_match = candidate_cmq.local_cmq_id ==
                      authoritative_cmq.local_cmq_id &&
                    candidate_cmq.global_cmq_id ==
                      authoritative_cmq.global_cmq_id;
      end
      RDMA_RESOURCE_CEQ: begin
        if ($cast(candidate_ceq, candidate) &&
            $cast(authoritative_ceq, authoritative))
          fields_match = candidate_ceq.local_ceq_id ==
                      authoritative_ceq.local_ceq_id &&
                    candidate_ceq.global_ceq_id ==
                      authoritative_ceq.global_ceq_id;
      end
      RDMA_RESOURCE_AEQ: begin
        if ($cast(candidate_aeq, candidate) &&
            $cast(authoritative_aeq, authoritative))
          fields_match = candidate_aeq.local_aeq_id ==
                      authoritative_aeq.local_aeq_id &&
                    candidate_aeq.global_aeq_id ==
                      authoritative_aeq.global_aeq_id;
      end
    endcase
    if (!fields_match)
      return rdma_status::make(
        RDMA_SC_INVALID_ARGUMENT,
        "published resource manager-owned fields changed"
      );
    return rdma_status::success();
  endfunction

  protected function rdma_status project_public_resource_value(
    rdma_resource source,
    string copy_label,
    output rdma_resource result
  );
    rdma_status status;

    status = project_resource_value(source, copy_label, result);
    if (!status.ok())
      return status;
    status = publication_identity_status(result, source);
    if (!status.ok()) begin
      result = null;
      return status;
    end
    return rdma_status::success();
  endfunction

  protected function rdma_status project_public_recovery_value(
    rdma_recovery_record source,
    string copy_label,
    output rdma_recovery_record result
  );
    return project_recovery_value(source, copy_label, result);
  endfunction

  protected function bit recovery_ready(rdma_recovery_record recovery);
    return recovery != null &&
           recovery.hardware_presence == RDMA_HW_PRESENCE_ABSENT &&
           recovery.pending_steps.size() == 0;
  endfunction
  protected function rdma_function_handle binding_handle_value(
    rdma_function_binding binding,
    string handle_name
  );
    rdma_function_handle result;

    result = new(handle_name);
    result.kind = RDMA_RESOURCE_FUNCTION;
    result.function_uid = binding.function_uid;
    result.object_id = binding.global_function_id;
    result.generation = binding.generation;
    return result;
  endfunction

  protected function bit source_key(
    rdma_function_binding binding,
    output string key
  );
    key = "";
    foreach (generation_sources[candidate_key]) begin
      if (generation_sources[candidate_key] == binding) begin
        key = candidate_key;
        return 1'b1;
      end
    end
    return 1'b0;
  endfunction

  protected function void refresh_generation(string key);
    int unsigned observed_generation;

    if (!generation_sources.exists(key) ||
        generation_sources[key] == null)
      return;
    observed_generation = generation_sources[key].generation;
    if (generation_high_water.exists(key) &&
        generation_high_water[key] == 32'hffff_ffff &&
        observed_generation == 0)
      generation_exhausted[key] = 1'b1;
    if (!generation_high_water.exists(key) ||
        observed_generation > generation_high_water[key])
      generation_high_water[key] = observed_generation;
  endfunction

  protected function rdma_status binding_context_status(
    rdma_function_binding binding,
    output rdma_function_binding trusted_binding,
    output rdma_function_handle owner,
    output string key,
    output bit registration_needed
  );
    rdma_status status;
    rdma_function_binding projected_binding;
    int unsigned observed_generation;
    bit source_is_known;

    trusted_binding = null;
    owner = null;
    key = "";
    registration_needed = 1'b0;
    if (binding == null)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "function binding is null");
    status = project_binding_value(binding, "binding input",
                                   projected_binding);
    if (!status.ok())
      return status;
    status = registry_schema_status("binding context");
    if (!status.ok())
      return status;

    source_is_known = source_key(binding, key);
    if (!source_is_known) begin
      key = $sformatf("%016h:%08h", projected_binding.function_uid,
                      projected_binding.global_function_id);
      if (binding_snapshots.exists(key))
        return rdma_status::make(
          RDMA_SC_INVALID_ARGUMENT,
          "Function generation source is not the registered binding"
        );
    end

    if (!binding_snapshots.exists(key)) begin
      status = projected_binding.validate();
      if (status == null)
        return rdma_status::make(
          RDMA_SC_INVALID_STATE,
          "Function binding validation returned null"
        );
      if (!status.ok())
        return status;
      if (projected_binding.state != RDMA_BIND_ACTIVE)
        return rdma_status::make(RDMA_SC_INVALID_STATE,
                                 "function binding is not ACTIVE");
      trusted_binding = projected_binding;
      observed_generation = projected_binding.generation;
      registration_needed = 1'b1;
    end
    else begin
      status = project_binding_value(binding_snapshots[key],
                                   "trusted binding", trusted_binding);
      if (!status.ok())
        return status;
      observed_generation = projected_binding.generation;
      if (!generation_high_water.exists(key))
        return rdma_status::make(RDMA_SC_INVALID_STATE,
                                 "Function generation ledger is missing");
      if (generation_exhausted.exists(key))
        return rdma_status::make(
          RDMA_SC_RESOURCE_EXHAUSTED,
          "Function generation counter is permanently exhausted"
        );
      if (observed_generation < generation_high_water[key]) begin
        if (generation_high_water[key] == 32'hffff_ffff &&
            observed_generation == 0) begin
          generation_exhausted[key] = 1'b1;
          return rdma_status::make(
            RDMA_SC_RESOURCE_EXHAUSTED,
            "Function generation wrapped after 32-bit exhaustion"
          );
        end
        return rdma_status::make(RDMA_SC_STALE_GENERATION,
                                 "Function generation moved backwards");
      end
      if (observed_generation > generation_high_water[key])
        generation_high_water[key] = observed_generation;
    end

    trusted_binding.generation = observed_generation;
    trusted_binding.owner_h = binding_handle_value(
      trusted_binding, "trusted_binding_owner"
    );
    owner = binding_handle_value(trusted_binding, "binding_owner");
    if (retired_generations.exists(function_generation_key(owner)))
      return rdma_status::make(RDMA_SC_STALE_GENERATION,
                               "Function generation is retired");
    status = trusted_binding.validate();
    if (status == null)
      return rdma_status::make(
        RDMA_SC_INVALID_STATE,
        "Trusted Function binding validation returned null"
      );
    if (!status.ok())
      return status;
    if (trusted_binding.state != RDMA_BIND_ACTIVE)
      return rdma_status::make(RDMA_SC_INVALID_STATE,
                               "function binding is not ACTIVE");
    return rdma_status::success();
  endfunction

  protected function rdma_status register_binding_context(
    rdma_function_binding source,
    rdma_function_binding trusted_binding,
    rdma_function_handle owner,
    string key
  );
    rdma_function_binding binding_copy;
    rdma_status status;

    status = project_binding_value(trusted_binding, "binding registry",
                                 binding_copy);
    if (!status.ok())
      return status;
    generation_sources[key] = source;
    binding_snapshots[key] = binding_copy;
    generation_high_water[key] = owner.generation;
    return rdma_status::success();
  endfunction

  protected function rdma_status active_binding_status(
    rdma_function_binding binding,
    output rdma_function_handle owner
  );
    rdma_function_binding trusted_binding;
    string key;
    bit registration_needed;

    return binding_context_status(binding, trusted_binding, owner, key,
                                  registration_needed);
  endfunction

  protected function rdma_status owner_binding_status(
    rdma_function_handle owner
  );
    string key;
    string generation_key;

    if (owner == null || owner.kind != RDMA_RESOURCE_FUNCTION)
      return rdma_status::make(RDMA_SC_INVALID_STATE,
                               "registry owner is not a Function handle");
    key = function_key(owner);
    if (!binding_snapshots.exists(key))
      return rdma_status::make(RDMA_SC_INVALID_STATE,
                               "Function binding is not registered");
    refresh_generation(key);
    generation_key = function_generation_key(owner);
    if (retired_generations.exists(generation_key))
      return rdma_status::make(RDMA_SC_STALE_GENERATION,
                               "Function generation is retired");
    if (generation_exhausted.exists(key))
      return rdma_status::make(RDMA_SC_STALE_GENERATION,
                               "Function generation counter is exhausted");
    if (!generation_high_water.exists(key) ||
        generation_high_water[key] != owner.generation)
      return rdma_status::make(RDMA_SC_STALE_GENERATION,
                               "Function generation is not current");
    return rdma_status::success();
  endfunction

  protected function bit has_conflicting_generation(
    rdma_function_handle owner
  );
    foreach (registry[key]) begin
      if (registry[key].owner != null &&
          registry[key].owner.function_uid == owner.function_uid &&
          registry[key].owner.object_id == owner.object_id &&
          registry[key].owner.kind == owner.kind &&
          registry[key].owner.generation != owner.generation)
        return 1'b1;
    end
    return 1'b0;
  endfunction

  protected function rdma_status reserve_identity(
    rdma_function_binding binding,
    rdma_resource_kind_e kind,
    output rdma_function_handle owner,
    output rdma_handle handle,
    output int unsigned local_id,
    output bit used_free_id,
    output bit registered_binding,
    output int unsigned prior_serial
  );
    rdma_status status;
    rdma_function_binding trusted_binding;
    int unsigned serial;
    string owner_key;
    bit registration_needed;
    bit has_free_id;

    owner = null;
    handle = null;
    local_id = '0;
    used_free_id = 1'b0;
    registered_binding = 1'b0;
    prior_serial = next_object_serial[kind];
    status = binding_context_status(binding, trusted_binding, owner,
                                    owner_key, registration_needed);
    if (!status.ok())
      return status;
    if (!valid_kind(kind) || kind == RDMA_RESOURCE_FUNCTION)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "object resource kind is invalid");

    serial = next_object_serial[kind];
    if (serial == 0)
      serial = 1;
    if (serial > 32'h0fff_ffff)
      return rdma_status::make(RDMA_SC_RESOURCE_EXHAUSTED,
                               "resource incarnation serial is exhausted");
    status = local_id_status(kind, has_free_id);
    if (!status.ok())
      return status;

    if (has_conflicting_generation(owner))
      return rdma_status::make(
        RDMA_SC_INVALID_STATE,
        "older Function generation still owns live resources"
      );
    if (registration_needed) begin
      status = register_binding_context(binding, trusted_binding, owner,
                                        owner_key);
      if (!status.ok())
        return status;
      registered_binding = 1'b1;
    end

    consume_local_id(kind, has_free_id, local_id);
    used_free_id = has_free_id;
    next_object_serial[kind] = serial + 1'b1;

    handle = new("resource_handle");
    handle.kind = kind;
    handle.function_uid = owner.function_uid;
    handle.object_id = {kind, serial[27:0]};
    handle.generation = owner.generation;
    return rdma_status::success();
  endfunction

  protected function void rollback_local_id_reservation(
    rdma_resource_kind_e kind,
    int unsigned local_id,
    bit used_free_id
  );
    if (used_free_id)
      free_local_ids[kind].push_front(local_id);
    else if (fresh_local_id_exhausted.exists(kind) &&
             fresh_local_id_exhausted[kind] &&
             local_id == local_id_limit(kind))
      fresh_local_id_exhausted.delete(kind);
    else if (next_local_id[kind] != 0)
      next_local_id[kind]--;
  endfunction

  protected function void rollback_binding_registration(
    rdma_function_handle owner,
    bit registered_binding
  );
    string owner_key;

    if (!registered_binding)
      return;
    owner_key = function_key(owner);
    generation_sources.delete(owner_key);
    binding_snapshots.delete(owner_key);
    generation_high_water.delete(owner_key);
    generation_exhausted.delete(owner_key);
  endfunction

  protected function void rollback_identity_reservation(
    rdma_resource_kind_e kind,
    rdma_function_handle owner,
    int unsigned local_id,
    bit used_free_id,
    bit registered_binding,
    int unsigned prior_serial
  );
    rollback_local_id_reservation(kind, local_id, used_free_id);
    next_object_serial[kind] = prior_serial;
    rollback_binding_registration(owner, registered_binding);
  endfunction

  protected function rdma_status register_resource(
    rdma_resource resource,
    string copy_label,
    output rdma_resource published
  );
    string key;
    rdma_resource registry_copy;
    rdma_function_handle owner_copy;
    rdma_handle handle_copy;
    rdma_status status;

    published = null;
    status = project_resource_value(resource, {copy_label, " registry"},
                                  registry_copy);
    if (!status.ok())
      return status;
    status = project_resource_value(registry_copy, copy_label, published);
    if (!status.ok())
      return status;
    status = project_function_handle_value(resource.owner,
                                        "resource_incarnation_owner",
                                        owner_copy);
    if (!status.ok()) begin
      published = null;
      return status;
    end
    status = project_handle_value(resource.handle, "resource_incarnation",
                               handle_copy);
    if (!status.ok()) begin
      published = null;
      return status;
    end

    key = resource_key(resource.handle);
    registry[key] = registry_copy;
    incarnation_owners[incarnation_key(resource.handle)] = owner_copy;
    incarnation_handles[incarnation_key(resource.handle)] = handle_copy;
    known_generations[function_generation_key(resource.owner)] = 1'b1;
    return rdma_status::success();
  endfunction

  protected function bit related_incarnation_owner(
    rdma_handle handle,
    output rdma_function_handle owner
  );
    owner = null;
    foreach (incarnation_handles[key]) begin
      if (incarnation_handles[key] == null ||
          !incarnation_owners.exists(key) ||
          incarnation_owners[key] == null)
        continue;
      if (incarnation_handles[key].function_uid == handle.function_uid &&
          incarnation_handles[key].kind == handle.kind &&
          incarnation_handles[key].object_id == handle.object_id) begin
        owner = incarnation_owners[key];
        return 1'b1;
      end
    end
    return 1'b0;
  endfunction

  protected function rdma_status dependency_status(
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
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "required resource dependency is null");
    end
    if (dependency.kind != expected_kind)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "resource dependency kind is invalid");
    status = lookup(dependency, dependency_resource);
    if (!status.ok())
      return status;
    if (dependency_resource.state inside {RDMA_RESOURCE_QUIESCING,
                                          RDMA_RESOURCE_ERROR})
      return rdma_status::make(
        RDMA_SC_INVALID_STATE,
        "closing or failed dependency cannot admit new resources"
      );
    if (dependency_resource.owner == null ||
        !same_handle_instance(dependency_resource.owner, owner))
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "resource dependency has another owner");
    return rdma_status::success();
  endfunction

  protected function int unsigned resource_local_id(rdma_resource resource);
    rdma_pd pd;
    rdma_mr mr;
    rdma_cq cq;
    rdma_qp qp;
    rdma_srq srq;
    rdma_cmq cmq;
    rdma_ceq ceq;
    rdma_aeq aeq;
    rdma_function function_resource;

    case (resource.handle.kind)
      RDMA_RESOURCE_FUNCTION: begin
        if (!$cast(function_resource, resource))
          `uvm_fatal("RM_TYPE", "Function resource type mismatch")
        return function_resource.local_function_id;
      end
      RDMA_RESOURCE_PD: begin
        if (!$cast(pd, resource))
          `uvm_fatal("RM_TYPE", "PD resource type mismatch")
        return pd.local_pd_id;
      end
      RDMA_RESOURCE_MR: begin
        if (!$cast(mr, resource))
          `uvm_fatal("RM_TYPE", "MR resource type mismatch")
        return mr.local_mr_id;
      end
      RDMA_RESOURCE_CQ: begin
        if (!$cast(cq, resource))
          `uvm_fatal("RM_TYPE", "CQ resource type mismatch")
        return cq.local_cq_id;
      end
      RDMA_RESOURCE_QP: begin
        if (!$cast(qp, resource))
          `uvm_fatal("RM_TYPE", "QP resource type mismatch")
        return qp.local_qp_id;
      end
      RDMA_RESOURCE_SRQ: begin
        if (!$cast(srq, resource))
          `uvm_fatal("RM_TYPE", "SRQ resource type mismatch")
        return srq.local_srq_id;
      end
      RDMA_RESOURCE_CMQ: begin
        if (!$cast(cmq, resource))
          `uvm_fatal("RM_TYPE", "CMQ resource type mismatch")
        return cmq.local_cmq_id;
      end
      RDMA_RESOURCE_CEQ: begin
        if (!$cast(ceq, resource))
          `uvm_fatal("RM_TYPE", "CEQ resource type mismatch")
        return ceq.local_ceq_id;
      end
      RDMA_RESOURCE_AEQ: begin
        if (!$cast(aeq, resource))
          `uvm_fatal("RM_TYPE", "AEQ resource type mismatch")
        return aeq.local_aeq_id;
      end
    endcase
    `uvm_fatal("RM_KIND", "resource kind has no local ID pool")
    return '0;
  endfunction

  protected function bit resource_depends_on(
    rdma_resource candidate,
    rdma_handle dependency
  );
    if (candidate == null || dependency == null)
      return 1'b0;
    foreach (candidate.dependencies[i]) begin
      if (candidate.dependencies[i] != null &&
          same_handle_instance(candidate.dependencies[i], dependency))
        return 1'b1;
    end
    return 1'b0;
  endfunction

  protected function bit has_dependents(rdma_resource resource);
    foreach (registry[key]) begin
      if (registry[key] == resource)
        continue;
      if (resource_depends_on(registry[key], resource.handle))
        return 1'b1;
      if (resource.handle.kind == RDMA_RESOURCE_FUNCTION &&
          registry[key].owner != null &&
          same_handle_instance(registry[key].owner, resource.handle))
        return 1'b1;
    end
    return 1'b0;
  endfunction

  protected function void force_release_key(string key);
    rdma_resource resource;
    rdma_resource_kind_e kind;
    int unsigned local_id;

    resource = registry[key];
    kind = resource.handle.kind;
    local_id = resource_local_id(resource);
    if (local_id > local_id_limit(kind))
      `uvm_fatal("RM_LOCAL_ID",
                 "authoritative local ID exceeds its hardware width")
    foreach (free_local_ids[kind][i]) begin
      if (free_local_ids[kind][i] == local_id)
        `uvm_fatal("RM_LOCAL_ID",
                   "authoritative local ID is already on the free list")
    end
    resource.state = RDMA_RESOURCE_RELEASED;
    recovery_records.delete(key);
    staged_allocations.delete(key);
    free_local_ids[kind].push_back(local_id);
    registry.delete(key);
  endfunction

  function rdma_status create_function(
    rdma_function_binding binding,
    output rdma_function function_resource
  );
    rdma_status status;
    rdma_function authoritative;
    rdma_function_binding trusted_binding;
    rdma_resource published;
    rdma_function_handle owner;
    string key;
    string owner_key;
    int unsigned local_id;
    bit registration_needed;
    bit has_free_id;
    bit registered_binding;

    function_resource = null;
    status = binding_context_status(binding, trusted_binding, owner,
                                    owner_key, registration_needed);
    if (!status.ok())
      return status;
    key = resource_key(owner);
    if (registry.exists(key))
      return rdma_status::make(RDMA_SC_INVALID_STATE,
                               "Function incarnation already exists");
    if (has_conflicting_generation(owner))
      return rdma_status::make(
        RDMA_SC_INVALID_STATE,
        "older Function generation still owns live resources"
      );
    if (incarnation_owners.exists(incarnation_key(owner)))
      return rdma_status::make(RDMA_SC_INVALID_STATE,
                               "Function incarnation was already released");
    status = local_id_status(RDMA_RESOURCE_FUNCTION, has_free_id);
    if (!status.ok())
      return status;
    registered_binding = 1'b0;
    if (registration_needed) begin
      status = register_binding_context(binding, trusted_binding, owner,
                                        owner_key);
      if (!status.ok())
        return status;
      registered_binding = 1'b1;
    end
    consume_local_id(RDMA_RESOURCE_FUNCTION, has_free_id, local_id);
    authoritative = new("function_resource");
    authoritative.handle = owner;
    status = project_function_handle_value(owner, "Function owner",
                                        authoritative.owner);
    if (!status.ok()) begin
      rollback_local_id_reservation(RDMA_RESOURCE_FUNCTION, local_id,
                                    has_free_id);
      rollback_binding_registration(owner, registered_binding);
      return status;
    end
    authoritative.state = RDMA_RESOURCE_ALLOCATED;
    authoritative.local_function_id = local_id;
    authoritative.global_function_id = owner.object_id;
    authoritative.rdma_vf_id = trusted_binding.rdma_vf_id;
    authoritative.vsi_id = trusted_binding.vsi_id;
    authoritative.pfvf_id = trusted_binding.pfvf_id;
    // rdma_function::new creates its default binding through the factory.
    // Replace it explicitly before any manager clone or validation dispatch.
    authoritative.binding = null;
    status = project_binding_value(trusted_binding, "Function resource",
                                 authoritative.binding);
    if (!status.ok()) begin
      rollback_local_id_reservation(RDMA_RESOURCE_FUNCTION, local_id,
                                    has_free_id);
      rollback_binding_registration(owner, registered_binding);
      return status;
    end
    status = register_resource(authoritative, "create Function", published);
    if (!status.ok()) begin
      rollback_local_id_reservation(RDMA_RESOURCE_FUNCTION, local_id,
                                    has_free_id);
      rollback_binding_registration(owner, registered_binding);
      return status;
    end
    if (!$cast(function_resource, published))
      `uvm_fatal("RM_COPY_TYPE", "published Function type mismatch")
    return rdma_status::success();
  endfunction

  function rdma_status create_pd(
    rdma_function_binding binding,
    output rdma_pd pd
  );
    rdma_status status;
    rdma_function_handle owner;
    rdma_handle handle;
    rdma_pd authoritative;
    rdma_resource published;
    int unsigned local_id;
    int unsigned prior_serial;
    bit used_free_id;
    bit registered_binding;

    pd = null;
    status = reserve_identity(binding, RDMA_RESOURCE_PD, owner, handle,
                              local_id, used_free_id, registered_binding,
                              prior_serial);
    if (!status.ok())
      return status;
    authoritative = new("pd");
    authoritative.handle = handle;
    authoritative.owner = owner;
    authoritative.state = RDMA_RESOURCE_ALLOCATED;
    authoritative.local_pd_id = local_id;
    authoritative.global_pd_id = handle.object_id;
    status = register_resource(authoritative, "create PD", published);
    if (!status.ok()) begin
      rollback_identity_reservation(RDMA_RESOURCE_PD, owner, local_id,
                                    used_free_id, registered_binding,
                                    prior_serial);
      return status;
    end
    if (!$cast(pd, published))
      `uvm_fatal("RM_COPY_TYPE", "published PD type mismatch")
    return rdma_status::success();
  endfunction

  function rdma_status create_mr(
    rdma_function_binding binding,
    rdma_handle pd_h,
    output rdma_mr mr
  );
    rdma_status status;
    rdma_function_handle owner;
    rdma_handle handle;
    rdma_mr authoritative;
    rdma_resource published;
    rdma_handle dependency_copy;
    int unsigned local_id;
    int unsigned prior_serial;
    bit used_free_id;
    bit registered_binding;

    mr = null;
    status = active_binding_status(binding, owner);
    if (!status.ok())
      return status;
    status = dependency_status(owner, pd_h, RDMA_RESOURCE_PD, 1'b0);
    if (!status.ok())
      return status;
    status = reserve_identity(binding, RDMA_RESOURCE_MR, owner, handle,
                              local_id, used_free_id, registered_binding,
                              prior_serial);
    if (!status.ok())
      return status;
    authoritative = new("mr");
    authoritative.handle = handle;
    authoritative.owner = owner;
    authoritative.state = RDMA_RESOURCE_ALLOCATED;
    authoritative.local_mr_id = local_id;
    authoritative.global_mr_id = handle.object_id;
    status = project_handle_value(pd_h, "MR PD", authoritative.pd_h);
    if (status.ok())
      status = project_handle_value(pd_h, "MR dependency", dependency_copy);
    if (!status.ok()) begin
      rollback_identity_reservation(RDMA_RESOURCE_MR, owner, local_id,
                                    used_free_id, registered_binding,
                                    prior_serial);
      return status;
    end
    authoritative.dependencies.push_back(dependency_copy);
    status = register_resource(authoritative, "create MR", published);
    if (!status.ok()) begin
      rollback_identity_reservation(RDMA_RESOURCE_MR, owner, local_id,
                                    used_free_id, registered_binding,
                                    prior_serial);
      return status;
    end
    if (!$cast(mr, published))
      `uvm_fatal("RM_COPY_TYPE", "published MR type mismatch")
    return rdma_status::success();
  endfunction

  function rdma_status create_cq(
    rdma_function_binding binding,
    rdma_handle ceq_h,
    output rdma_cq cq
  );
    rdma_status status;
    rdma_function_handle owner;
    rdma_handle handle;
    rdma_cq authoritative;
    rdma_resource published;
    rdma_handle dependency_copy;
    int unsigned local_id;
    int unsigned prior_serial;
    bit used_free_id;
    bit registered_binding;

    cq = null;
    status = active_binding_status(binding, owner);
    if (!status.ok())
      return status;
    status = dependency_status(owner, ceq_h, RDMA_RESOURCE_CEQ, 1'b1);
    if (!status.ok())
      return status;
    status = reserve_identity(binding, RDMA_RESOURCE_CQ, owner, handle,
                              local_id, used_free_id, registered_binding,
                              prior_serial);
    if (!status.ok())
      return status;
    authoritative = new("cq");
    authoritative.handle = handle;
    authoritative.owner = owner;
    authoritative.state = RDMA_RESOURCE_ALLOCATED;
    authoritative.local_cq_id = local_id;
    authoritative.global_cq_id = handle.object_id;
    if (ceq_h != null) begin
      status = project_handle_value(ceq_h, "CQ CEQ", authoritative.ceq_h);
      if (status.ok())
        status = project_handle_value(ceq_h, "CQ dependency",
                                   dependency_copy);
      if (!status.ok()) begin
        rollback_identity_reservation(RDMA_RESOURCE_CQ, owner, local_id,
                                      used_free_id, registered_binding,
                                      prior_serial);
        return status;
      end
      authoritative.dependencies.push_back(dependency_copy);
    end
    status = register_resource(authoritative, "create CQ", published);
    if (!status.ok()) begin
      rollback_identity_reservation(RDMA_RESOURCE_CQ, owner, local_id,
                                    used_free_id, registered_binding,
                                    prior_serial);
      return status;
    end
    if (!$cast(cq, published))
      `uvm_fatal("RM_COPY_TYPE", "published CQ type mismatch")
    return rdma_status::success();
  endfunction

  function rdma_status create_qp(
    rdma_function_binding binding,
    rdma_handle pd_h,
    rdma_handle send_cq_h,
    rdma_handle recv_cq_h,
    rdma_handle srq_h,
    output rdma_qp qp
  );
    rdma_status status;
    rdma_function_handle owner;
    rdma_handle handle;
    rdma_qp authoritative;
    rdma_resource published;
    rdma_handle dependency_copy;
    int unsigned local_id;
    int unsigned prior_serial;
    bit used_free_id;
    bit registered_binding;

    qp = null;
    status = active_binding_status(binding, owner);
    if (!status.ok())
      return status;
    status = dependency_status(owner, pd_h, RDMA_RESOURCE_PD, 1'b0);
    if (!status.ok())
      return status;
    status = dependency_status(owner, send_cq_h, RDMA_RESOURCE_CQ, 1'b0);
    if (!status.ok())
      return status;
    status = dependency_status(owner, recv_cq_h, RDMA_RESOURCE_CQ, 1'b0);
    if (!status.ok())
      return status;
    status = dependency_status(owner, srq_h, RDMA_RESOURCE_SRQ, 1'b1);
    if (!status.ok())
      return status;
    status = reserve_identity(binding, RDMA_RESOURCE_QP, owner, handle,
                              local_id, used_free_id, registered_binding,
                              prior_serial);
    if (!status.ok())
      return status;
    authoritative = new("qp");
    authoritative.handle = handle;
    authoritative.owner = owner;
    authoritative.state = RDMA_RESOURCE_ALLOCATED;
    authoritative.local_qp_id = local_id;
    authoritative.global_qp_id = handle.object_id;
    status = project_handle_value(pd_h, "QP PD", authoritative.pd_h);
    if (status.ok())
      status = project_handle_value(send_cq_h, "QP send CQ",
                                 authoritative.send_cq_h);
    if (status.ok())
      status = project_handle_value(recv_cq_h, "QP receive CQ",
                                 authoritative.recv_cq_h);
    if (status.ok())
      status = project_handle_value(pd_h, "QP PD dependency", dependency_copy);
    if (status.ok()) begin
      authoritative.dependencies.push_back(dependency_copy);
      status = project_handle_value(send_cq_h, "QP send CQ dependency",
                                 dependency_copy);
    end
    if (status.ok()) begin
      authoritative.dependencies.push_back(dependency_copy);
      status = project_handle_value(recv_cq_h, "QP receive CQ dependency",
                                 dependency_copy);
    end
    if (status.ok())
      authoritative.dependencies.push_back(dependency_copy);
    if (!status.ok()) begin
      rollback_identity_reservation(RDMA_RESOURCE_QP, owner, local_id,
                                    used_free_id, registered_binding,
                                    prior_serial);
      return status;
    end
    if (srq_h != null) begin
      status = project_handle_value(srq_h, "QP SRQ", authoritative.srq_h);
      if (status.ok())
        status = project_handle_value(srq_h, "QP SRQ dependency",
                                   dependency_copy);
      if (!status.ok()) begin
        rollback_identity_reservation(RDMA_RESOURCE_QP, owner, local_id,
                                      used_free_id, registered_binding,
                                      prior_serial);
        return status;
      end
      authoritative.dependencies.push_back(dependency_copy);
    end
    status = register_resource(authoritative, "create QP", published);
    if (!status.ok()) begin
      rollback_identity_reservation(RDMA_RESOURCE_QP, owner, local_id,
                                    used_free_id, registered_binding,
                                    prior_serial);
      return status;
    end
    if (!$cast(qp, published))
      `uvm_fatal("RM_COPY_TYPE", "published QP type mismatch")
    return rdma_status::success();
  endfunction

  function rdma_status create_srq(
    rdma_function_binding binding,
    rdma_handle pd_h,
    output rdma_srq srq
  );
    rdma_status status;
    rdma_function_handle owner;
    rdma_handle handle;
    rdma_srq authoritative;
    rdma_resource published;
    rdma_handle dependency_copy;
    int unsigned local_id;
    int unsigned prior_serial;
    bit used_free_id;
    bit registered_binding;

    srq = null;
    status = active_binding_status(binding, owner);
    if (!status.ok())
      return status;
    status = dependency_status(owner, pd_h, RDMA_RESOURCE_PD, 1'b0);
    if (!status.ok())
      return status;
    status = reserve_identity(binding, RDMA_RESOURCE_SRQ, owner, handle,
                              local_id, used_free_id, registered_binding,
                              prior_serial);
    if (!status.ok())
      return status;
    authoritative = new("srq");
    authoritative.handle = handle;
    authoritative.owner = owner;
    authoritative.state = RDMA_RESOURCE_ALLOCATED;
    authoritative.local_srq_id = local_id;
    authoritative.global_srq_id = handle.object_id;
    status = project_handle_value(pd_h, "SRQ PD", authoritative.pd_h);
    if (status.ok())
      status = project_handle_value(pd_h, "SRQ dependency", dependency_copy);
    if (!status.ok()) begin
      rollback_identity_reservation(RDMA_RESOURCE_SRQ, owner, local_id,
                                    used_free_id, registered_binding,
                                    prior_serial);
      return status;
    end
    authoritative.dependencies.push_back(dependency_copy);
    status = register_resource(authoritative, "create SRQ", published);
    if (!status.ok()) begin
      rollback_identity_reservation(RDMA_RESOURCE_SRQ, owner, local_id,
                                    used_free_id, registered_binding,
                                    prior_serial);
      return status;
    end
    if (!$cast(srq, published))
      `uvm_fatal("RM_COPY_TYPE", "published SRQ type mismatch")
    return rdma_status::success();
  endfunction

  function rdma_status create_cmq(
    rdma_function_binding binding,
    output rdma_cmq cmq
  );
    rdma_status status;
    rdma_function_handle owner;
    rdma_handle handle;
    rdma_cmq authoritative;
    rdma_resource published;
    int unsigned local_id;
    int unsigned prior_serial;
    bit used_free_id;
    bit registered_binding;

    cmq = null;
    status = reserve_identity(binding, RDMA_RESOURCE_CMQ, owner, handle,
                              local_id, used_free_id, registered_binding,
                              prior_serial);
    if (!status.ok())
      return status;
    authoritative = new("cmq");
    authoritative.handle = handle;
    authoritative.owner = owner;
    authoritative.state = RDMA_RESOURCE_ALLOCATED;
    authoritative.local_cmq_id = local_id;
    authoritative.global_cmq_id = handle.object_id;
    status = register_resource(authoritative, "create CMQ", published);
    if (!status.ok()) begin
      rollback_identity_reservation(RDMA_RESOURCE_CMQ, owner, local_id,
                                    used_free_id, registered_binding,
                                    prior_serial);
      return status;
    end
    if (!$cast(cmq, published))
      `uvm_fatal("RM_COPY_TYPE", "published CMQ type mismatch")
    return rdma_status::success();
  endfunction

  function rdma_status create_ceq(
    rdma_function_binding binding,
    output rdma_ceq ceq
  );
    rdma_status status;
    rdma_function_handle owner;
    rdma_handle handle;
    rdma_ceq authoritative;
    rdma_resource published;
    int unsigned local_id;
    int unsigned prior_serial;
    bit used_free_id;
    bit registered_binding;

    ceq = null;
    status = reserve_identity(binding, RDMA_RESOURCE_CEQ, owner, handle,
                              local_id, used_free_id, registered_binding,
                              prior_serial);
    if (!status.ok())
      return status;
    authoritative = new("ceq");
    authoritative.handle = handle;
    authoritative.owner = owner;
    authoritative.state = RDMA_RESOURCE_ALLOCATED;
    authoritative.local_ceq_id = local_id;
    authoritative.global_ceq_id = handle.object_id;
    status = register_resource(authoritative, "create CEQ", published);
    if (!status.ok()) begin
      rollback_identity_reservation(RDMA_RESOURCE_CEQ, owner, local_id,
                                    used_free_id, registered_binding,
                                    prior_serial);
      return status;
    end
    if (!$cast(ceq, published))
      `uvm_fatal("RM_COPY_TYPE", "published CEQ type mismatch")
    return rdma_status::success();
  endfunction

  function rdma_status create_aeq(
    rdma_function_binding binding,
    output rdma_aeq aeq
  );
    rdma_status status;
    rdma_function_handle owner;
    rdma_handle handle;
    rdma_aeq authoritative;
    rdma_resource published;
    int unsigned local_id;
    int unsigned prior_serial;
    bit used_free_id;
    bit registered_binding;

    aeq = null;
    status = reserve_identity(binding, RDMA_RESOURCE_AEQ, owner, handle,
                              local_id, used_free_id, registered_binding,
                              prior_serial);
    if (!status.ok())
      return status;
    authoritative = new("aeq");
    authoritative.handle = handle;
    authoritative.owner = owner;
    authoritative.state = RDMA_RESOURCE_ALLOCATED;
    authoritative.local_aeq_id = local_id;
    authoritative.global_aeq_id = handle.object_id;
    status = register_resource(authoritative, "create AEQ", published);
    if (!status.ok()) begin
      rollback_identity_reservation(RDMA_RESOURCE_AEQ, owner, local_id,
                                    used_free_id, registered_binding,
                                    prior_serial);
      return status;
    end
    if (!$cast(aeq, published))
      `uvm_fatal("RM_COPY_TYPE", "published AEQ type mismatch")
    return rdma_status::success();
  endfunction

  function rdma_status lookup(
    rdma_handle handle,
    output rdma_resource resource
  );
    string key;
    string incarnation;
    rdma_resource authoritative;
    rdma_function_handle owner;
    rdma_handle trusted_handle;
    rdma_status status;

    resource = null;
    status = project_handle_value(handle, "lookup", trusted_handle);
    if (!status.ok())
      return status;
    if (trusted_handle == null)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "resource handle is null");
    if (!valid_kind(trusted_handle.kind))
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "resource handle kind is invalid");
    if (trusted_handle.kind != RDMA_RESOURCE_FUNCTION &&
        trusted_handle.object_id[31:28] != trusted_handle.kind)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "resource incarnation kind prefix is invalid");

    key = resource_key(trusted_handle);
    if (registry.exists(key)) begin
      status = project_resource_value(registry[key], "lookup registry entry",
                                      authoritative);
      if (!status.ok())
        return status;
      if (authoritative.handle == null ||
          !same_handle_instance(authoritative.handle, trusted_handle))
        return rdma_status::make(RDMA_SC_INVALID_STATE,
                                 "registry identity is inconsistent");
      status = owner_binding_status(authoritative.owner);
      if (!status.ok())
        return status;
      registry[key] = authoritative;
      return project_resource_value(authoritative, "lookup", resource);
    end

    incarnation = incarnation_key(trusted_handle);
    if (!incarnation_owners.exists(incarnation)) begin
      if (related_incarnation_owner(trusted_handle, owner))
        return rdma_status::make(RDMA_SC_STALE_GENERATION,
                                 "resource handle generation is stale");
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "resource handle is unknown or forged");
    end
    owner = incarnation_owners[incarnation];
    status = owner_binding_status(owner);
    if (status.code == RDMA_SC_STALE_GENERATION)
      return status;
    if (!status.ok())
      return status;
    return rdma_status::make(RDMA_SC_INVALID_STATE,
                             "resource handle has been released");
  endfunction

  virtual function rdma_status stage_allocated(rdma_resource candidate);
    rdma_resource authoritative;
    rdma_resource prepared;
    rdma_resource replacement;
    rdma_status status;
    string key;

    status = project_public_resource_value(candidate, "stage allocated",
                                           replacement);
    if (!status.ok())
      return status;
    if (replacement.state != RDMA_RESOURCE_ALLOCATED)
      return rdma_status::make(RDMA_SC_INVALID_STATE,
                               "staged candidate must be ALLOCATED");
    status = lookup(replacement.handle, authoritative);
    if (!status.ok())
      return status;
    key = resource_key(authoritative.handle);
    if (registry[key].state != RDMA_RESOURCE_ALLOCATED)
      return rdma_status::make(RDMA_SC_INVALID_STATE,
                               "registry resource is not ALLOCATED");
    status = publication_identity_status(replacement, authoritative);
    if (!status.ok())
      return status;
    if (replacement.handle.kind != RDMA_RESOURCE_PD) begin
      status = project_public_resource_value(replacement, "stage prepared",
                                           prepared);
      if (!status.ok())
        return status;
      prepared.state = RDMA_RESOURCE_PROGRAMMED;
      status = prepared.validate();
      if (status == null)
        return rdma_status::make(
          RDMA_SC_INVALID_STATE,
          "prepared staged candidate validation returned null"
        );
      if (!status.ok())
        return status;
    end
    replacement.state = RDMA_RESOURCE_ALLOCATED;
    status = replacement.validate();
    if (status == null)
      return rdma_status::make(RDMA_SC_INVALID_STATE,
                               "staged candidate validation returned null");
    if (!status.ok())
      return status;
    registry[key] = replacement;
    staged_allocations[key] = 1'b1;
    return rdma_status::success();
  endfunction

  virtual function rdma_status commit_programmed(rdma_resource candidate);
    rdma_resource authoritative;
    rdma_resource replacement;
    rdma_status status;
    string key;

    status = project_public_resource_value(candidate, "commit programmed",
                                           replacement);
    if (!status.ok())
      return status;
    if (replacement.state != RDMA_RESOURCE_ALLOCATED)
      return rdma_status::make(RDMA_SC_INVALID_STATE,
                               "programmed candidate must be ALLOCATED");
    status = lookup(replacement.handle, authoritative);
    if (!status.ok())
      return status;
    if (authoritative.handle.kind == RDMA_RESOURCE_PD)
      return rdma_status::make(
        RDMA_SC_INVALID_STATE,
        "PD transitions directly from ALLOCATED to ACTIVE"
      );
    key = resource_key(authoritative.handle);
    if (registry[key].state != RDMA_RESOURCE_ALLOCATED ||
        !staged_allocations.exists(key))
      return rdma_status::make(
        RDMA_SC_INVALID_STATE,
        "only a staged ALLOCATED resource can be programmed"
      );
    status = publication_identity_status(replacement, authoritative);
    if (!status.ok())
      return status;
    replacement.state = RDMA_RESOURCE_PROGRAMMED;
    status = replacement.validate();
    if (status == null)
      return rdma_status::make(
        RDMA_SC_INVALID_STATE,
        "programmed candidate validation returned null"
      );
    if (!status.ok())
      return status;
    registry[key] = replacement;
    staged_allocations.delete(key);
    return rdma_status::success();
  endfunction

  virtual function rdma_status activate(rdma_handle handle);
    rdma_resource authoritative;
    rdma_resource replacement;
    rdma_status status;
    string key;

    status = lookup(handle, authoritative);
    if (!status.ok())
      return status;
    key = resource_key(authoritative.handle);
    if (authoritative.handle.kind == RDMA_RESOURCE_PD) begin
      if (registry[key].state != RDMA_RESOURCE_ALLOCATED)
        return rdma_status::make(
          RDMA_SC_INVALID_STATE,
          "PD activation requires ALLOCATED state"
        );
    end
    else if (registry[key].state != RDMA_RESOURCE_PROGRAMMED) begin
      return rdma_status::make(
        RDMA_SC_INVALID_STATE,
        "non-PD activation requires PROGRAMMED state"
      );
    end
    status = project_resource_value(registry[key], "activate", replacement);
    if (!status.ok())
      return status;
    replacement.state = RDMA_RESOURCE_ACTIVE;
    status = replacement.validate();
    if (status == null)
      return rdma_status::make(RDMA_SC_INVALID_STATE,
                               "active resource validation returned null");
    if (!status.ok())
      return status;
    registry[key] = replacement;
    staged_allocations.delete(key);
    return rdma_status::success();
  endfunction

  virtual function rdma_status begin_quiesce(rdma_handle handle);
    rdma_resource authoritative;
    rdma_resource replacement;
    rdma_status status;
    string key;

    status = registry_schema_status("begin quiesce");
    if (!status.ok())
      return status;
    status = lookup(handle, authoritative);
    if (!status.ok())
      return status;
    key = resource_key(authoritative.handle);
    if (registry[key].state != RDMA_RESOURCE_ACTIVE)
      return rdma_status::make(RDMA_SC_INVALID_STATE,
                               "only ACTIVE resource can begin quiesce");
    if (has_dependents(registry[key]))
      return rdma_status::make(RDMA_SC_RESOURCE_BUSY,
                               "resource still has live dependents");
    if (registry[key].outstanding_ids.size() != 0)
      return rdma_status::make(
        RDMA_SC_RESOURCE_BUSY,
        "resource still has outstanding operations"
      );
    status = project_resource_value(registry[key], "begin quiesce",
                                    replacement);
    if (!status.ok())
      return status;
    replacement.state = RDMA_RESOURCE_QUIESCING;
    registry[key] = replacement;
    return rdma_status::success();
  endfunction

  virtual function rdma_status restore_active(rdma_handle handle);
    rdma_resource authoritative;
    rdma_resource replacement;
    rdma_recovery_record recovery;
    rdma_status status;
    bit authoritative_release_complete;
    bit recovery_release_complete;
    string key;

    status = lookup(handle, authoritative);
    if (!status.ok())
      return status;
    key = resource_key(authoritative.handle);
    if (registry[key].state == RDMA_RESOURCE_ERROR) begin
      status = recovery_entry_schema_status(key, "restore active");
      if (!status.ok())
        return status;
      if (authoritative.handle.kind != RDMA_RESOURCE_MR ||
          staged_allocations.exists(key) || !recovery_records.exists(key))
        return rdma_status::make(
          RDMA_SC_INVALID_STATE,
          "ERROR restore requires an unstaged MR recovery record"
        );
      recovery = recovery_records[key];
      if (recovery == null ||
          recovery.hardware_presence != RDMA_HW_PRESENCE_PRESENT ||
          recovery.ambiguous_ticket != null ||
          recovery.pending_steps.size() != 0 ||
          !(recovery.completed_steps.size() == 0 ||
            (recovery.completed_steps.size() == 1 &&
             recovery.completed_steps[0] ==
               RDMA_CTRL_STEP_HW_OCC_FLUSHED)))
        return rdma_status::make(
          RDMA_SC_INVALID_STATE,
          "ERROR MR recovery is not safe to restore ACTIVE"
        );
      if (registry[key].backing_refs.size() !=
            recovery.backing_refs.size() ||
          registry[key].hmc_refs.size() != recovery.hmc_refs.size())
        return rdma_status::make(
          RDMA_SC_INVALID_STATE,
          "ERROR MR recovery reference cardinality changed"
        );
      foreach (registry[key].backing_refs[i]) begin
        if (registry[key].backing_refs[i] == null ||
            recovery.backing_refs[i] == null ||
            registry[key].backing_refs[i].mapping == null ||
            recovery.backing_refs[i].mapping == null ||
            registry[key].backing_refs[i].ownership !=
              recovery.backing_refs[i].ownership ||
            registry[key].backing_refs[i].release_complete ||
            recovery.backing_refs[i].release_complete ||
            !same_mapping_value(
              registry[key].backing_refs[i].mapping,
              recovery.backing_refs[i].mapping
            ) ||
            registry[key].backing_refs[i].mapping.state !=
              RDMA_MAPPING_ACTIVE)
          return rdma_status::make(
            RDMA_SC_INVALID_STATE,
            "ERROR MR recovery backing authority changed"
          );
        if (registry[key].backing_refs[i].ownership ==
              RDMA_OWNERSHIP_CONTROL_PLANE) begin
          if (!same_owned_mapping_authority(
                registry[key].backing_refs[i].mapping,
                recovery.backing_refs[i].mapping
              ))
            return rdma_status::make(
              RDMA_SC_INVALID_STATE,
              "ERROR MR owned backing release authority changed"
            );
          status = query_owned_release_completion(
            registry[key].backing_refs[i].mapping,
            authoritative_release_complete
          );
          if (status == null || !status.ok() ||
              authoritative_release_complete)
            return rdma_status::make(
              RDMA_SC_INVALID_STATE,
              "ERROR MR authoritative owned backing was released"
            );
          status = query_owned_release_completion(
            recovery.backing_refs[i].mapping, recovery_release_complete
          );
          if (status == null || !status.ok() || recovery_release_complete)
            return rdma_status::make(
              RDMA_SC_INVALID_STATE,
              "ERROR MR recovery owned backing was released"
            );
        end
      end
      foreach (registry[key].hmc_refs[i]) begin
        if (registry[key].hmc_refs[i] == null ||
            recovery.hmc_refs[i] == null ||
            !same_mapping_handle_value(
              registry[key].hmc_refs[i].owner,
              recovery.hmc_refs[i].owner
            ) ||
            registry[key].hmc_refs[i].object_kind !=
              recovery.hmc_refs[i].object_kind ||
            registry[key].hmc_refs[i].address !=
              recovery.hmc_refs[i].address ||
            registry[key].hmc_refs[i].size != recovery.hmc_refs[i].size ||
            registry[key].hmc_refs[i].first_pbl_index !=
              recovery.hmc_refs[i].first_pbl_index ||
            registry[key].hmc_refs[i].ownership !=
              recovery.hmc_refs[i].ownership ||
            registry[key].hmc_refs[i].release_complete ||
            recovery.hmc_refs[i].release_complete)
          return rdma_status::make(
            RDMA_SC_INVALID_STATE,
            "ERROR MR recovery HMC authority changed"
          );
      end
    end
    else if (registry[key].state != RDMA_RESOURCE_QUIESCING)
      return rdma_status::make(
        RDMA_SC_INVALID_STATE,
        "only QUIESCING or safe ERROR MR can be restored ACTIVE"
      );
    status = project_resource_value(registry[key], "restore active",
                                  replacement);
    if (!status.ok())
      return status;
    replacement.state = RDMA_RESOURCE_ACTIVE;
    status = replacement.validate();
    if (status == null)
      return rdma_status::make(RDMA_SC_INVALID_STATE,
                               "restored resource validation returned null");
    if (!status.ok())
      return status;
    registry[key] = replacement;
    if (authoritative.state == RDMA_RESOURCE_ERROR)
      recovery_records.delete(key);
    return rdma_status::success();
  endfunction

  protected function rdma_status mark_error_transition(
    rdma_handle handle,
    rdma_recovery_record recovery,
    bit reserved_only
  );
    rdma_resource replacement;
    rdma_recovery_record recovery_copy;
    rdma_function_handle related_owner;
    rdma_handle trusted_handle;
    rdma_status status;
    bit opaque_release_complete;
    bit backing_release_pending;
    string key;

    status = project_handle_value(handle, "mark error", trusted_handle);
    if (!status.ok())
      return status;
    status = project_public_recovery_value(recovery, "mark error",
                                           recovery_copy);
    if (!status.ok())
      return status;
    if (trusted_handle == null)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "error resource handle is null");
    if (!valid_kind(trusted_handle.kind) ||
        (trusted_handle.kind != RDMA_RESOURCE_FUNCTION &&
         trusted_handle.object_id[31:28] != trusted_handle.kind))
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "error resource handle is malformed");
    key = resource_key(trusted_handle);
    status = recovery_entry_schema_status(key, "mark error");
    if (!status.ok())
      return status;
    if (!registry.exists(key)) begin
      if (related_incarnation_owner(trusted_handle, related_owner))
        return rdma_status::make(RDMA_SC_STALE_GENERATION,
                                 "error resource generation is stale");
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "error resource incarnation is unknown");
    end
    status = project_resource_value(registry[key], "mark error registry",
                                    replacement);
    if (!status.ok())
      return status;
    if (replacement.handle == null ||
        !same_handle_instance(replacement.handle, trusted_handle))
      return rdma_status::make(RDMA_SC_INVALID_STATE,
                               "error registry identity is inconsistent");
    if (recovery_copy.resource_h == null ||
        !same_handle_instance(recovery_copy.resource_h, trusted_handle))
      return rdma_status::make(
        RDMA_SC_INVALID_ARGUMENT,
        "recovery record does not match the resource incarnation"
      );
    status = recovery_copy.validate();
    if (status == null)
      return rdma_status::make(RDMA_SC_INVALID_STATE,
                               "recovery validation returned null");
    if (!status.ok())
      return status;
    if (reserved_only) begin
      if (replacement.handle.kind != RDMA_RESOURCE_MR ||
          replacement.state != RDMA_RESOURCE_ALLOCATED ||
          staged_allocations.exists(key))
        return rdma_status::make(
          RDMA_SC_INVALID_STATE,
          "reserved ERROR requires an unstaged ALLOCATED MR"
        );
      if (recovery_copy.hardware_presence != RDMA_HW_PRESENCE_ABSENT ||
          recovery_copy.ambiguous_ticket != null ||
          recovery_copy.hmc_refs.size() != 0 ||
          recovery_copy.pending_steps.size() != 1 ||
          !(recovery_copy.pending_steps[0] inside {
            RDMA_CTRL_STEP_BACKING_RELEASED,
            RDMA_CTRL_STEP_RESOURCE_RELEASED
          }) ||
          recovery_copy.backing_refs.size() != 1)
        return rdma_status::make(
          RDMA_SC_INVALID_ARGUMENT,
          "reserved ERROR recovery is not canonical local cleanup"
        );
      backing_release_pending = recovery_copy.pending_steps[0] ==
        RDMA_CTRL_STEP_BACKING_RELEASED;
      foreach (recovery_copy.backing_refs[i]) begin
        if (recovery_copy.backing_refs[i] == null ||
            recovery_copy.backing_refs[i].ownership !=
              RDMA_OWNERSHIP_CONTROL_PLANE ||
            recovery_copy.backing_refs[i].mapping == null)
          return rdma_status::make(
            RDMA_SC_INVALID_ARGUMENT,
            "reserved ERROR backing authority is incomplete"
          );
        status = query_owned_release_completion(
          recovery_copy.backing_refs[i].mapping, opaque_release_complete
        );
        if (status == null || !status.ok())
          return rdma_status::make(
            RDMA_SC_INVALID_ARGUMENT,
            "reserved ERROR backing completion proof is invalid"
          );
        if (backing_release_pending &&
            (recovery_copy.backing_refs[i].release_complete ||
             recovery_copy.backing_refs[i].mapping.state !=
               RDMA_MAPPING_ACTIVE || opaque_release_complete))
          return rdma_status::make(
            RDMA_SC_INVALID_ARGUMENT,
            "reserved ERROR backing cleanup is not owned and live"
          );
        if (!backing_release_pending &&
            (!recovery_copy.backing_refs[i].release_complete ||
             recovery_copy.backing_refs[i].mapping.state !=
               RDMA_MAPPING_RELEASED || !opaque_release_complete))
          return rdma_status::make(
            RDMA_SC_INVALID_ARGUMENT,
            "reserved ERROR resource cleanup lacks released backing"
          );
      end
    end
    else if (replacement.handle.kind == RDMA_RESOURCE_MR &&
             replacement.state == RDMA_RESOURCE_ALLOCATED &&
             !staged_allocations.exists(key)) begin
      return rdma_status::make(
        RDMA_SC_INVALID_STATE,
        "ALLOCATED MR requires staged key authority before ERROR"
      );
    end
    replacement.state = RDMA_RESOURCE_ERROR;
    status = replacement.validate();
    if (status == null)
      return rdma_status::make(RDMA_SC_INVALID_STATE,
                               "ERROR resource validation returned null");
    if (!status.ok())
      return status;
    registry[key] = replacement;
    recovery_records[key] = recovery_copy;
    staged_allocations.delete(key);
    return rdma_status::success();
  endfunction

  virtual function rdma_status mark_error(
    rdma_handle handle,
    rdma_recovery_record recovery
  );
    return mark_error_transition(handle, recovery, 1'b0);
  endfunction

  virtual function rdma_status mark_reserved_error(
    rdma_handle handle,
    rdma_recovery_record recovery
  );
    return mark_error_transition(handle, recovery, 1'b1);
  endfunction

  // Completes only the no-hardware recovery shape created by
  // mark_reserved_error().  The control plane must release the retained
  // backing authority before invoking this atomic local transition.
  virtual function rdma_status complete_reserved_error(
    rdma_handle handle
  );
    rdma_resource authoritative;
    rdma_recovery_record recovery;
    rdma_dma_mapping canonical_mapping;
    rdma_status status;
    bit backing_release_pending;
    bit release_complete;
    string key;

    status = registry_schema_status("complete reserved error");
    if (!status.ok())
      return status;
    status = lookup(handle, authoritative);
    if (!status.ok())
      return status;
    key = resource_key(authoritative.handle);
    status = recovery_entry_schema_status(key, "complete reserved error");
    if (!status.ok())
      return status;
    if (authoritative.handle.kind != RDMA_RESOURCE_MR ||
        registry[key].state != RDMA_RESOURCE_ERROR ||
        staged_allocations.exists(key) || !recovery_records.exists(key))
      return rdma_status::make(
        RDMA_SC_INVALID_STATE,
        "resource is not a reserved ERROR MR"
      );
    recovery = recovery_records[key];
    if (recovery != null) begin
      foreach (recovery.completed_steps[i]) begin
        if (rdma_control_step_is_hardware(recovery.completed_steps[i]))
          return rdma_status::make(
            RDMA_SC_INVALID_STATE,
            "reserved ERROR completion rejects hardware history"
          );
      end
    end
    if (recovery == null ||
        recovery.hardware_presence != RDMA_HW_PRESENCE_ABSENT ||
        recovery.ambiguous_ticket != null ||
        recovery.hmc_refs.size() != 0 ||
        recovery.pending_steps.size() != 1 ||
        !(recovery.pending_steps[0] inside {
          RDMA_CTRL_STEP_BACKING_RELEASED,
          RDMA_CTRL_STEP_RESOURCE_RELEASED
        }) ||
        recovery.backing_refs.size() != 1 ||
        recovery.backing_refs[0] == null ||
        recovery.backing_refs[0].ownership !=
          RDMA_OWNERSHIP_CONTROL_PLANE ||
        recovery.backing_refs[0].mapping == null)
      return rdma_status::make(
        RDMA_SC_RECOVERY_REQUIRED,
        "reserved ERROR MR still requires non-local recovery"
      );
    backing_release_pending = recovery.pending_steps[0] ==
      RDMA_CTRL_STEP_BACKING_RELEASED;
    if (backing_release_pending &&
        (recovery.backing_refs[0].release_complete ||
         recovery.backing_refs[0].mapping.state != RDMA_MAPPING_ACTIVE))
      return rdma_status::make(
        RDMA_SC_INVALID_ARGUMENT,
        "reserved ERROR backing cleanup schema is invalid"
      );
    if (!backing_release_pending &&
        (!recovery.backing_refs[0].release_complete ||
         recovery.backing_refs[0].mapping.state != RDMA_MAPPING_RELEASED))
      return rdma_status::make(
        RDMA_SC_INVALID_ARGUMENT,
        "reserved ERROR resource cleanup schema is invalid"
      );
    // Public RELEASED state is forgeable; completion is proven solely by the
    // adapter-sealed fact shared with the canonical recovery mapping.
    canonical_mapping = recovery.backing_refs[0].mapping;
    status = query_owned_release_completion(
      canonical_mapping, release_complete
    );
    if (status == null || !status.ok() || !release_complete)
      return rdma_status::make(
        RDMA_SC_INVALID_ARGUMENT,
        "reserved ERROR backing release is not opaquely complete"
      );
    if (has_dependents(registry[key]) ||
        registry[key].outstanding_ids.size() != 0)
      return rdma_status::make(
        RDMA_SC_RESOURCE_BUSY,
        "reserved ERROR MR still has live dependents or operations"
      );
    force_release_key(key);
    return rdma_status::success();
  endfunction

  virtual function rdma_status lookup_recovery(
    rdma_handle handle,
    output rdma_recovery_record recovery
  );
    rdma_resource authoritative;
    rdma_status status;
    string key;

    recovery = null;
    status = lookup(handle, authoritative);
    if (!status.ok())
      return status;
    key = resource_key(authoritative.handle);
    status = recovery_entry_schema_status(key, "recovery lookup");
    if (!status.ok())
      return status;
    if (!recovery_records.exists(key))
      return rdma_status::make(RDMA_SC_INVALID_STATE,
                               "resource has no recovery record");
    return project_recovery_value(recovery_records[key], "lookup recovery",
                                recovery);
  endfunction

  virtual function rdma_status clear_recovery(rdma_handle handle);
    rdma_resource authoritative;
    rdma_status status;
    string key;

    status = lookup(handle, authoritative);
    if (!status.ok())
      return status;
    key = resource_key(authoritative.handle);
    status = recovery_entry_schema_status(key, "clear recovery");
    if (!status.ok())
      return status;
    if (registry[key].state != RDMA_RESOURCE_ERROR)
      return rdma_status::make(RDMA_SC_INVALID_STATE,
                               "only ERROR resource recovery can be cleared");
    if (!recovery_records.exists(key))
      return rdma_status::make(RDMA_SC_INVALID_STATE,
                               "resource has no recovery record");
    if (!recovery_ready(recovery_records[key]))
      return rdma_status::make(
        RDMA_SC_RECOVERY_REQUIRED,
        "recovery cannot be cleared before hardware absence is proven"
      );
    recovery_records.delete(key);
    return rdma_status::success();
  endfunction

  virtual function rdma_status finalize_release(rdma_handle handle);
    rdma_resource authoritative;
    rdma_status status;
    string key;

    status = registry_schema_status("finalize release");
    if (!status.ok())
      return status;
    status = lookup(handle, authoritative);
    if (!status.ok())
      return status;
    key = resource_key(authoritative.handle);
    status = recovery_entry_schema_status(key, "finalize release");
    if (!status.ok())
      return status;
    if (authoritative.handle.kind == RDMA_RESOURCE_FUNCTION)
      return rdma_status::make(
        RDMA_SC_INVALID_STATE,
        "Function resources require privileged Function teardown"
      );
    if (registry[key].state == RDMA_RESOURCE_ERROR) begin
      if (!recovery_records.exists(key) ||
          !recovery_ready(recovery_records[key]))
        return rdma_status::make(
          RDMA_SC_RECOVERY_REQUIRED,
          "ERROR resource still requires recovery"
        );
    end
    else if (registry[key].state != RDMA_RESOURCE_QUIESCING) begin
      return rdma_status::make(
        RDMA_SC_INVALID_STATE,
        "only QUIESCING or recovered ERROR resource can be finalized"
      );
    end
    if (has_dependents(registry[key]))
      return rdma_status::make(RDMA_SC_RESOURCE_BUSY,
                               "resource still has live dependents");
    if (registry[key].outstanding_ids.size() != 0)
      return rdma_status::make(
        RDMA_SC_RESOURCE_BUSY,
        "resource still has outstanding operations"
      );
    force_release_key(key);
    return rdma_status::success();
  endfunction

  virtual function rdma_status release_reserved(rdma_handle handle);
    rdma_resource authoritative;
    rdma_status status;
    string key;

    status = registry_schema_status("release reserved");
    if (!status.ok())
      return status;
    status = lookup(handle, authoritative);
    if (!status.ok())
      return status;
    key = resource_key(authoritative.handle);
    status = recovery_entry_schema_status(key, "release reserved");
    if (!status.ok())
      return status;
    if (authoritative.handle.kind == RDMA_RESOURCE_FUNCTION)
      return rdma_status::make(
        RDMA_SC_INVALID_STATE,
        "Function resources require privileged Function teardown"
      );
    if (registry[key].state != RDMA_RESOURCE_ALLOCATED)
      return rdma_status::make(
        RDMA_SC_INVALID_STATE,
        "only an ALLOCATED reservation can be rolled back"
      );
    if (has_dependents(registry[key]))
      return rdma_status::make(RDMA_SC_RESOURCE_BUSY,
                               "resource still has live dependents");
    if (registry[key].outstanding_ids.size() != 0)
      return rdma_status::make(
        RDMA_SC_RESOURCE_BUSY,
        "resource still has outstanding operations"
      );
    force_release_key(key);
    return rdma_status::success();
  endfunction

  virtual function rdma_status track_outstanding(
    rdma_handle handle,
    longint unsigned outstanding_id
  );
    rdma_resource authoritative;
    rdma_resource replacement;
    rdma_status status;
    string key;

    if (outstanding_id == 0)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "outstanding operation ID is zero");
    status = lookup(handle, authoritative);
    if (!status.ok())
      return status;
    key = resource_key(authoritative.handle);
    if (registry[key].state != RDMA_RESOURCE_ACTIVE)
      return rdma_status::make(
        RDMA_SC_INVALID_STATE,
        "only ACTIVE resources accept outstanding operations"
      );
    foreach (registry[key].outstanding_ids[i]) begin
      if (registry[key].outstanding_ids[i] == outstanding_id)
        return rdma_status::make(
          RDMA_SC_INVALID_ARGUMENT,
          "outstanding operation ID is already tracked"
        );
    end
    status = project_resource_value(registry[key], "track outstanding",
                                  replacement);
    if (!status.ok())
      return status;
    replacement.outstanding_ids.push_back(outstanding_id);
    registry[key] = replacement;
    return rdma_status::success();
  endfunction

  virtual function rdma_status retire_outstanding(
    rdma_handle handle,
    longint unsigned outstanding_id
  );
    rdma_resource authoritative;
    rdma_resource replacement;
    rdma_status status;
    string key;
    int found_index;

    status = lookup(handle, authoritative);
    if (!status.ok())
      return status;
    key = resource_key(authoritative.handle);
    found_index = -1;
    foreach (registry[key].outstanding_ids[i]) begin
      if (registry[key].outstanding_ids[i] == outstanding_id) begin
        found_index = i;
        break;
      end
    end
    if (found_index < 0)
      return rdma_status::make(
        RDMA_SC_INVALID_ARGUMENT,
        "outstanding operation ID is not tracked"
      );
    status = project_resource_value(registry[key], "retire outstanding",
                                  replacement);
    if (!status.ok())
      return status;
    replacement.outstanding_ids.delete(found_index);
    registry[key] = replacement;
    return rdma_status::success();
  endfunction

  function rdma_status freeze(rdma_handle handle);
    rdma_resource candidate;
    rdma_status status;

    status = lookup(handle, candidate);
    if (!status.ok())
      return status;
    return commit_programmed(candidate);
  endfunction

  function rdma_status \release (rdma_handle handle);
    rdma_resource ignored;
    rdma_status status;
    string key;

    status = registry_schema_status("release");
    if (!status.ok())
      return status;
    status = lookup(handle, ignored);
    if (!status.ok())
      return status;
    key = resource_key(ignored.handle);
    status = recovery_entry_schema_status(key, "release");
    if (!status.ok())
      return status;
    if (ignored.handle.kind == RDMA_RESOURCE_FUNCTION)
      return rdma_status::make(
        RDMA_SC_INVALID_STATE,
        "Function resources require privileged Function teardown"
      );
    if (registry[key].state == RDMA_RESOURCE_ERROR)
      return rdma_status::make(
        RDMA_SC_RECOVERY_REQUIRED,
        "ERROR resource requires recovery finalization"
      );
    if (registry[key].state != RDMA_RESOURCE_ALLOCATED)
      return rdma_status::make(RDMA_SC_INVALID_STATE,
                               "frozen resource requires Function teardown");
    if (has_dependents(registry[key]))
      return rdma_status::make(RDMA_SC_INVALID_STATE,
                               "resource still has live dependents");
    force_release_key(key);
    return rdma_status::success();
  endfunction

  function rdma_status release_function(rdma_function_handle owner);
    bit selected[string];
    string release_order[$];
    string owner_key;
    string generation_key;
    int unsigned target_count;
    bit progress;
    bit blocked;
    rdma_function_handle trusted_owner;
    rdma_status status;

    status = project_function_handle_value(owner, "Function teardown",
                                           trusted_owner);
    if (!status.ok())
      return status;
    if (trusted_owner == null ||
        trusted_owner.kind != RDMA_RESOURCE_FUNCTION)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "Function teardown handle is invalid");
    status = registry_schema_status("Function teardown");
    if (!status.ok())
      return status;
    status = recovery_schema_status("Function teardown");
    if (!status.ok())
      return status;
    owner_key = function_key(trusted_owner);
    generation_key = function_generation_key(trusted_owner);
    if (!binding_snapshots.exists(owner_key))
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "Function teardown identity is unknown");
    refresh_generation(owner_key);
    if (retired_generations.exists(generation_key))
      return rdma_status::make(RDMA_SC_STALE_GENERATION,
                               "Function generation is already retired");
    if (!known_generations.exists(generation_key))
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "Function generation was never registered");

    target_count = 0;
    foreach (registry[key]) begin
      if (registry[key].owner != null &&
          same_handle_instance(registry[key].owner, trusted_owner))
        target_count++;
    end

    while (release_order.size() < target_count) begin
      progress = 1'b0;
      foreach (registry[key]) begin
        if (selected.exists(key) || registry[key].owner == null ||
            !same_handle_instance(registry[key].owner, trusted_owner))
          continue;
        blocked = 1'b0;
        foreach (registry[other_key]) begin
          if (key == other_key || selected.exists(other_key) ||
              registry[other_key].owner == null ||
              !same_handle_instance(registry[other_key].owner,
                                    trusted_owner))
            continue;
          if (resource_depends_on(registry[other_key],
                                  registry[key].handle))
            blocked = 1'b1;
          if (registry[key].handle.kind == RDMA_RESOURCE_FUNCTION &&
              registry[other_key].handle.kind !=
                RDMA_RESOURCE_FUNCTION)
            blocked = 1'b1;
        end
        if (!blocked) begin
          selected[key] = 1'b1;
          release_order.push_back(key);
          progress = 1'b1;
        end
      end
      if (!progress)
        return rdma_status::make(RDMA_SC_INVALID_STATE,
                                 "resource dependency graph has a cycle");
    end

    foreach (release_order[i])
      force_release_key(release_order[i]);
    retired_generations[generation_key] = 1'b1;
    return rdma_status::success();
  endfunction

  function rdma_status check_leaks(
    output int unsigned leak_count,
    input rdma_function_handle owner = null
  );
    rdma_function_handle trusted_owner;
    rdma_status status;

    leak_count = 0;
    trusted_owner = null;
    if (owner != null) begin
      status = project_function_handle_value(owner, "leak filter",
                                             trusted_owner);
      if (!status.ok())
        return status;
      if (trusted_owner.kind != RDMA_RESOURCE_FUNCTION)
        return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                                 "leak filter is not a Function handle");
    end
    status = registry_schema_status("leak audit");
    if (!status.ok())
      return status;
    foreach (registry[key]) begin
      if (trusted_owner == null ||
          (registry[key].owner != null &&
           same_handle_instance(registry[key].owner, trusted_owner)))
        leak_count++;
    end
    if (leak_count != 0)
      return rdma_status::make(RDMA_SC_INVALID_STATE,
                               $sformatf("%0d RDMA resources leaked",
                                         leak_count));
    return rdma_status::success();
  endfunction
endclass
