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
  // QPC sequence is an incarnation counter for a local QPN within one exact
  // Function generation.  Entries intentionally outlive QP finalization so a
  // reused QPN receives the next sequence value.
  protected bit [7:0] qp_sequences[string];

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
      RDMA_RESOURCE_CQ: return 21'h1f_ffff;
      RDMA_RESOURCE_QP: return 21'h1f_ffff;
      RDMA_RESOURCE_SRQ: return 16'hffff;
      RDMA_RESOURCE_CEQ,
      RDMA_RESOURCE_AEQ: return 12'hfff;
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

  protected function string qp_sequence_key(
    rdma_function_handle owner,
    int unsigned local_qpn
  );
    return $sformatf("%016h:%08h:%08h:%06h", owner.function_uid,
                     owner.object_id, owner.generation, local_qpn);
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
    result.dma_domain_valid = source.dma_domain_valid;
    result.dma_domain_id = source.dma_domain_id;
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
           lhs.dma_domain_valid == rhs.dma_domain_valid &&
           lhs.dma_domain_id == rhs.dma_domain_id &&
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

  protected function bit same_queue_backing_ref_value(
    rdma_queue_backing_ref lhs,
    rdma_queue_backing_ref rhs
  );
    if (lhs == null || rhs == null)
      return lhs == rhs;
    if (lhs.role != rhs.role || lhs.ownership != rhs.ownership ||
        lhs.mapping_offset != rhs.mapping_offset ||
        lhs.length != rhs.length ||
        lhs.logical_queue_offset != rhs.logical_queue_offset ||
        lhs.additional_segments.size() != rhs.additional_segments.size() ||
        !same_mapping_value(lhs.mapping, rhs.mapping))
      return 1'b0;
    foreach (lhs.additional_segments[i]) begin
      if (lhs.additional_segments[i] == null ||
          rhs.additional_segments[i] == null ||
          lhs.additional_segments[i].role != rhs.additional_segments[i].role ||
          lhs.additional_segments[i].ownership !=
            rhs.additional_segments[i].ownership ||
          lhs.additional_segments[i].mapping_offset !=
            rhs.additional_segments[i].mapping_offset ||
          lhs.additional_segments[i].length !=
            rhs.additional_segments[i].length ||
          lhs.additional_segments[i].logical_queue_offset !=
            rhs.additional_segments[i].logical_queue_offset ||
          !same_mapping_value(lhs.additional_segments[i].mapping,
                              rhs.additional_segments[i].mapping))
        return 1'b0;
    end
    return 1'b1;
  endfunction

  protected function bit same_owned_queue_backing_ref_authority(
    rdma_queue_backing_ref authoritative,
    rdma_queue_backing_ref recovery
  );
    if (authoritative == null || recovery == null ||
        authoritative.ownership != RDMA_OWNERSHIP_CONTROL_PLANE ||
        recovery.ownership != RDMA_OWNERSHIP_CONTROL_PLANE ||
        authoritative.additional_segments.size() !=
          recovery.additional_segments.size() ||
        !same_owned_mapping_authority(authoritative.mapping,
                                      recovery.mapping))
      return 1'b0;
    foreach (authoritative.additional_segments[i]) begin
      if (authoritative.additional_segments[i] == null ||
          recovery.additional_segments[i] == null ||
          authoritative.additional_segments[i].ownership !=
            RDMA_OWNERSHIP_CONTROL_PLANE ||
          recovery.additional_segments[i].ownership !=
            RDMA_OWNERSHIP_CONTROL_PLANE ||
          !same_owned_mapping_authority(
            authoritative.additional_segments[i].mapping,
            recovery.additional_segments[i].mapping
          ))
        return 1'b0;
    end
    return 1'b1;
  endfunction

  protected function bit same_queue_ring_value(
    rdma_queue_ring_layout lhs,
    rdma_queue_ring_layout rhs
  );
    if (lhs == null || rhs == null)
      return lhs == rhs;
    if (lhs.role != rhs.role ||
        lhs.entry_size_bytes != rhs.entry_size_bytes ||
        lhs.depth != rhs.depth || lhs.logical_bytes != rhs.logical_bytes ||
        lhs.storage_bytes != rhs.storage_bytes ||
        lhs.page_count != rhs.page_count ||
        lhs.initial_polarity != rhs.initial_polarity ||
        lhs.pages.size() != rhs.pages.size())
      return 1'b0;
    foreach (lhs.pages[i]) begin
      if (lhs.pages[i] == null || rhs.pages[i] == null ||
          lhs.pages[i].role != rhs.pages[i].role ||
          lhs.pages[i].mapping_offset != rhs.pages[i].mapping_offset ||
          lhs.pages[i].logical_page_offset !=
            rhs.pages[i].logical_page_offset ||
          lhs.pages[i].page_iova.value != rhs.pages[i].page_iova.value ||
          !same_mapping_value(lhs.pages[i].mapping, rhs.pages[i].mapping))
        return 1'b0;
    end
    return 1'b1;
  endfunction

  protected function bit same_released_queue_context_value(
    rdma_context_backing_ref authoritative,
    rdma_context_backing_ref candidate
  );
    rdma_queue_slot_token_contract authoritative_token;
    rdma_queue_slot_token_contract candidate_token;

    if (authoritative == null || candidate == null)
      return authoritative == candidate;
    if (!$cast(authoritative_token, authoritative.slot_token) ||
        !$cast(candidate_token, candidate.slot_token) ||
        authoritative_token.completion_authority == null ||
        candidate_token.completion_authority == null ||
        authoritative_token.completion_authority !==
          candidate_token.completion_authority ||
        !candidate_token.completion_authority.complete ||
        !candidate.release_complete ||
        !same_handle_instance(authoritative.owner, candidate.owner) ||
        authoritative.resource_kind != candidate.resource_kind ||
        authoritative.local_id != candidate.local_id ||
        authoritative.shadow_pointer_base.value !=
          candidate.shadow_pointer_base.value ||
        authoritative.slot_length != candidate.slot_length ||
        authoritative.shadow_view_offset != candidate.shadow_view_offset ||
        authoritative.shadow_view_length != candidate.shadow_view_length ||
        authoritative.hmc_ref == null || candidate.hmc_ref == null ||
        !same_mapping_handle_value(authoritative.hmc_ref.owner,
                                   candidate.hmc_ref.owner) ||
        authoritative.hmc_ref.object_kind != candidate.hmc_ref.object_kind ||
        authoritative.hmc_ref.address.value != candidate.hmc_ref.address.value ||
        authoritative.hmc_ref.size != candidate.hmc_ref.size ||
        authoritative.hmc_ref.first_pbl_index !=
          candidate.hmc_ref.first_pbl_index ||
        authoritative.hmc_ref.ownership != candidate.hmc_ref.ownership ||
        authoritative.hmc_ref.release_complete !=
          candidate.hmc_ref.release_complete)
      return 1'b0;
    return 1'b1;
  endfunction

  protected function bit canonical_queue_reservation_release_recovery(
    rdma_recovery_record recovery
  );
    int unsigned backing_completed;

    if (recovery == null || !recovery.queue_recovery_valid ||
        recovery.hardware_presence != RDMA_HW_PRESENCE_ABSENT ||
        recovery.queue_intent != RDMA_QUEUE_RECOVER_CREATE_ROLLBACK ||
        recovery.ambiguous_queue_operation != RDMA_QUEUE_AMBIG_NONE ||
        recovery.ambiguous_ticket != null || recovery.queue_plan == null ||
        recovery.pending_steps.size() != 1 ||
        recovery.pending_steps[0] != RDMA_CTRL_STEP_RESOURCE_RELEASED)
      return 1'b0;
    backing_completed = 0;
    foreach (recovery.completed_steps[i])
      if (recovery.completed_steps[i] == RDMA_CTRL_STEP_BACKING_RELEASED)
        backing_completed++;
    return backing_completed == 1;
  endfunction

  protected function rdma_status queue_reservation_release_plan_status(
    rdma_queue_backing_plan authoritative,
    rdma_queue_backing_plan candidate
  );
    rdma_status status;
    bit release_complete;

    if (authoritative == null || candidate == null ||
        authoritative.resource_kind != candidate.resource_kind ||
        authoritative.rings.size() != candidate.rings.size() ||
        authoritative.refs.size() != candidate.refs.size() ||
        authoritative.flush_targets.size() != candidate.flush_targets.size() ||
        ((authoritative.context_ref == null) !=
         (candidate.context_ref == null)))
      return rdma_status::make(
        RDMA_SC_INVALID_ARGUMENT,
        "queue reservation recovery plan shape changed"
      );
    foreach (authoritative.rings[i]) begin
      if (!same_queue_ring_value(authoritative.rings[i], candidate.rings[i]))
        return rdma_status::make(
          RDMA_SC_INVALID_ARGUMENT,
          "queue reservation recovery ring authority changed"
        );
    end
    foreach (authoritative.refs[i]) begin
      if (!same_queue_backing_ref_value(authoritative.refs[i],
                                        candidate.refs[i]) ||
          candidate.refs[i] == null)
        return rdma_status::make(
          RDMA_SC_INVALID_ARGUMENT,
          "queue reservation recovery backing authority changed"
        );
      if (candidate.refs[i].ownership == RDMA_OWNERSHIP_CONTROL_PLANE) begin
        if (!candidate.refs[i].cleanup_complete)
          return rdma_status::make(
            RDMA_SC_INVALID_ARGUMENT,
            "queue reservation recovery owned backing is not released"
          );
        if (!same_owned_queue_backing_ref_authority(authoritative.refs[i],
                                                    candidate.refs[i]))
          return rdma_status::make(
            RDMA_SC_INVALID_ARGUMENT,
            "queue reservation recovery backing authority changed"
          );
        status = query_owned_release_completion(candidate.refs[i].mapping,
                                                release_complete);
        if (status == null || !status.ok() || !release_complete)
          return rdma_status::make(
            RDMA_SC_INVALID_ARGUMENT,
            "queue reservation recovery backing lacks completion proof"
          );
        foreach (candidate.refs[i].additional_segments[j]) begin
          status = query_owned_release_completion(
            candidate.refs[i].additional_segments[j].mapping,
            release_complete
          );
          if (status == null || !status.ok() || !release_complete)
            return rdma_status::make(
              RDMA_SC_INVALID_ARGUMENT,
              "queue reservation recovery segment lacks completion proof"
            );
        end
      end
      else if (candidate.refs[i].ownership == RDMA_OWNERSHIP_BORROWED) begin
        if (authoritative.refs[i].cleanup_complete ||
            candidate.refs[i].cleanup_complete ||
            candidate.refs[i].mapping == null ||
            candidate.refs[i].mapping.state != RDMA_MAPPING_ACTIVE)
          return rdma_status::make(
            RDMA_SC_INVALID_ARGUMENT,
            "queue reservation recovery borrowed backing was released"
          );
        foreach (candidate.refs[i].additional_segments[j]) begin
          if (candidate.refs[i].additional_segments[j] == null ||
              candidate.refs[i].additional_segments[j].ownership !=
                RDMA_OWNERSHIP_BORROWED ||
              candidate.refs[i].additional_segments[j].mapping == null ||
              candidate.refs[i].additional_segments[j].mapping.state !=
                RDMA_MAPPING_ACTIVE)
            return rdma_status::make(
              RDMA_SC_INVALID_ARGUMENT,
              "queue reservation recovery borrowed segment was released"
            );
        end
      end
      else
        return rdma_status::make(
          RDMA_SC_INVALID_ARGUMENT,
          "queue reservation recovery backing ownership is invalid"
        );
    end
    if (candidate.context_ref != null &&
        !same_released_queue_context_value(authoritative.context_ref,
                                           candidate.context_ref))
      return rdma_status::make(
        RDMA_SC_INVALID_ARGUMENT,
        "queue reservation recovery context lacks completion proof"
      );
    foreach (authoritative.flush_targets[i]) begin
      if (authoritative.flush_targets[i] == null ||
          candidate.flush_targets[i] == null ||
          authoritative.flush_targets[i].role !=
            candidate.flush_targets[i].role ||
          authoritative.flush_targets[i].phase !=
            candidate.flush_targets[i].phase ||
          authoritative.flush_targets[i].flush_complete !=
            candidate.flush_targets[i].flush_complete ||
          !same_queue_backing_ref_value(
            authoritative.flush_targets[i].pd_ref,
            candidate.flush_targets[i].pd_ref
          ))
        return rdma_status::make(
          RDMA_SC_INVALID_ARGUMENT,
          "queue reservation recovery flush authority changed"
        );
      if (candidate.flush_targets[i].pd_ref.ownership ==
            RDMA_OWNERSHIP_CONTROL_PLANE) begin
        if (!candidate.flush_targets[i].pd_ref.cleanup_complete ||
            !same_owned_queue_backing_ref_authority(
              authoritative.flush_targets[i].pd_ref,
              candidate.flush_targets[i].pd_ref
            ))
          return rdma_status::make(
            RDMA_SC_INVALID_ARGUMENT,
            "queue reservation recovery flush release authority changed"
          );
        status = query_owned_release_completion(
          candidate.flush_targets[i].pd_ref.mapping, release_complete
        );
        if (status == null || !status.ok() || !release_complete)
          return rdma_status::make(
            RDMA_SC_INVALID_ARGUMENT,
            "queue reservation recovery flush lacks completion proof"
          );
        foreach (candidate.flush_targets[i].pd_ref.additional_segments[j]) begin
          status = query_owned_release_completion(
            candidate.flush_targets[i].pd_ref.additional_segments[j].mapping,
            release_complete
          );
          if (status == null || !status.ok() || !release_complete)
            return rdma_status::make(
              RDMA_SC_INVALID_ARGUMENT,
              "queue reservation recovery flush segment lacks completion proof"
            );
        end
      end
      else if (candidate.flush_targets[i].pd_ref.ownership ==
                 RDMA_OWNERSHIP_BORROWED) begin
        if (authoritative.flush_targets[i].pd_ref.cleanup_complete ||
            candidate.flush_targets[i].pd_ref.cleanup_complete ||
            candidate.flush_targets[i].pd_ref.mapping == null ||
            candidate.flush_targets[i].pd_ref.mapping.state !=
              RDMA_MAPPING_ACTIVE)
          return rdma_status::make(
            RDMA_SC_INVALID_ARGUMENT,
            "queue reservation recovery borrowed flush backing was released"
          );
        foreach (candidate.flush_targets[i].pd_ref.additional_segments[j]) begin
          if (candidate.flush_targets[i].pd_ref.additional_segments[j] == null ||
              candidate.flush_targets[i].pd_ref.additional_segments[j].ownership !=
                RDMA_OWNERSHIP_BORROWED ||
              candidate.flush_targets[i].pd_ref.additional_segments[j].mapping ==
                null ||
              candidate.flush_targets[i].pd_ref.additional_segments[j].mapping.
                state != RDMA_MAPPING_ACTIVE)
            return rdma_status::make(
              RDMA_SC_INVALID_ARGUMENT,
              "queue reservation recovery borrowed flush segment was released"
            );
        end
      end
      else
        return rdma_status::make(
          RDMA_SC_INVALID_ARGUMENT,
          "queue reservation recovery flush ownership is invalid"
        );
    end
    return rdma_status::success();
  endfunction

  protected function rdma_status queue_local_release_plan_status(
    rdma_queue_backing_plan candidate
  );
    rdma_queue_slot_token_contract token;
    rdma_status status;
    bit release_complete;

    if (candidate == null)
      return rdma_status::make(
        RDMA_SC_INVALID_ARGUMENT, "queue local release plan is missing"
      );
    foreach (candidate.refs[i]) begin
      if (candidate.refs[i] == null)
        return rdma_status::make(
          RDMA_SC_INVALID_ARGUMENT,
          "queue local release backing is missing"
        );
      if (candidate.refs[i].ownership == RDMA_OWNERSHIP_CONTROL_PLANE) begin
        if (!candidate.refs[i].cleanup_complete)
          return rdma_status::make(
            RDMA_SC_INVALID_ARGUMENT,
            "queue local owned release backing is incomplete"
          );
        status = query_owned_release_completion(candidate.refs[i].mapping,
                                                release_complete);
        if (status == null || !status.ok() || !release_complete)
          return rdma_status::make(
            RDMA_SC_INVALID_ARGUMENT,
            "queue local release backing proof is incomplete"
          );
        foreach (candidate.refs[i].additional_segments[j]) begin
          status = query_owned_release_completion(
            candidate.refs[i].additional_segments[j].mapping,
            release_complete
          );
          if (status == null || !status.ok() || !release_complete)
            return rdma_status::make(
              RDMA_SC_INVALID_ARGUMENT,
              "queue local release segment proof is incomplete"
            );
        end
      end
      else if (candidate.refs[i].ownership == RDMA_OWNERSHIP_BORROWED) begin
        if (candidate.refs[i].cleanup_complete ||
            candidate.refs[i].mapping == null ||
            candidate.refs[i].mapping.state != RDMA_MAPPING_ACTIVE)
          return rdma_status::make(
            RDMA_SC_INVALID_ARGUMENT,
            "queue local borrowed backing was released"
          );
        foreach (candidate.refs[i].additional_segments[j]) begin
          if (candidate.refs[i].additional_segments[j] == null ||
              candidate.refs[i].additional_segments[j].ownership !=
                RDMA_OWNERSHIP_BORROWED ||
              candidate.refs[i].additional_segments[j].mapping == null ||
              candidate.refs[i].additional_segments[j].mapping.state !=
                RDMA_MAPPING_ACTIVE)
            return rdma_status::make(
              RDMA_SC_INVALID_ARGUMENT,
              "queue local borrowed segment was released"
            );
        end
      end
      else
        return rdma_status::make(
          RDMA_SC_INVALID_ARGUMENT,
          "queue local release backing ownership is invalid"
        );
    end
    if (candidate.context_ref != null) begin
      if (!$cast(token, candidate.context_ref.slot_token) ||
          token.completion_authority == null ||
          !token.completion_authority.complete ||
          !candidate.context_ref.release_complete)
        return rdma_status::make(
          RDMA_SC_INVALID_ARGUMENT,
          "queue local release context proof is incomplete"
        );
    end
    foreach (candidate.flush_targets[i]) begin
      if (candidate.flush_targets[i] == null ||
          candidate.flush_targets[i].pd_ref == null)
        return rdma_status::make(
          RDMA_SC_INVALID_ARGUMENT,
          "queue local release flush backing is missing"
        );
      if (candidate.flush_targets[i].pd_ref.ownership ==
            RDMA_OWNERSHIP_CONTROL_PLANE) begin
        if (!candidate.flush_targets[i].pd_ref.cleanup_complete)
          return rdma_status::make(
            RDMA_SC_INVALID_ARGUMENT,
            "queue local owned flush backing is incomplete"
          );
        status = query_owned_release_completion(
          candidate.flush_targets[i].pd_ref.mapping, release_complete
        );
        if (status == null || !status.ok() || !release_complete)
          return rdma_status::make(
            RDMA_SC_INVALID_ARGUMENT,
            "queue local owned flush backing proof is incomplete"
          );
        foreach (candidate.flush_targets[i].pd_ref.additional_segments[j]) begin
          status = query_owned_release_completion(
            candidate.flush_targets[i].pd_ref.additional_segments[j].mapping,
            release_complete
          );
          if (status == null || !status.ok() || !release_complete)
            return rdma_status::make(
              RDMA_SC_INVALID_ARGUMENT,
              "queue local owned flush segment proof is incomplete"
            );
        end
      end
      else if (candidate.flush_targets[i].pd_ref.ownership ==
                 RDMA_OWNERSHIP_BORROWED) begin
        if (candidate.flush_targets[i].pd_ref.cleanup_complete ||
            candidate.flush_targets[i].pd_ref.mapping == null ||
            candidate.flush_targets[i].pd_ref.mapping.state !=
              RDMA_MAPPING_ACTIVE)
          return rdma_status::make(
            RDMA_SC_INVALID_ARGUMENT,
            "queue local borrowed flush backing was released"
          );
        foreach (candidate.flush_targets[i].pd_ref.additional_segments[j]) begin
          if (candidate.flush_targets[i].pd_ref.additional_segments[j] == null ||
              candidate.flush_targets[i].pd_ref.additional_segments[j].ownership !=
                RDMA_OWNERSHIP_BORROWED ||
              candidate.flush_targets[i].pd_ref.additional_segments[j].mapping ==
                null ||
              candidate.flush_targets[i].pd_ref.additional_segments[j].mapping.
                state != RDMA_MAPPING_ACTIVE)
            return rdma_status::make(
              RDMA_SC_INVALID_ARGUMENT,
              "queue local borrowed flush segment was released"
            );
        end
      end
      else
        return rdma_status::make(
          RDMA_SC_INVALID_ARGUMENT,
          "queue local release flush ownership is invalid"
        );
    end
    return rdma_status::success();
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
    result.queue_dma = source.queue_dma;
    result.queue_caps = source.queue_caps;
    result.interrupt_vectors = source.interrupt_vectors;
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
    rdma_cmq_opcode_key opcode_copy;
    rdma_queue_backing_plan plan_copy;
    rdma_qp_recovery_state qp_recovery_copy;

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
    result.queue_recovery_valid = source.queue_recovery_valid;
    result.queue_intent = source.queue_intent;
    result.ambiguous_queue_operation = source.ambiguous_queue_operation;
    result.ambiguous_role = source.ambiguous_role;
    status = project_opcode_value(source.queue_create_opcode,
                                  {copy_label, "_queue_create"},
                                  opcode_copy);
    if (!status.ok()) begin result = null; return status; end
    result.queue_create_opcode = opcode_copy;
    status = project_opcode_value(source.queue_delete_opcode,
                                  {copy_label, "_queue_delete"},
                                  opcode_copy);
    if (!status.ok()) begin result = null; return status; end
    result.queue_delete_opcode = opcode_copy;
    status = project_opcode_value(source.queue_query_opcode,
                                  {copy_label, "_queue_query"},
                                  opcode_copy);
    if (!status.ok()) begin result = null; return status; end
    result.queue_query_opcode = opcode_copy;
    status = project_queue_plan_value(source.queue_plan,
                                      {copy_label, "_queue_plan"}, plan_copy);
    if (!status.ok()) begin result = null; return status; end
    result.queue_plan = plan_copy;
    result.qp_recovery_valid = source.qp_recovery_valid;
    status = project_qp_recovery_value(
      source.qp_recovery, {copy_label, "_qp_recovery"}, qp_recovery_copy
    );
    if (!status.ok()) begin result = null; return status; end
    result.qp_recovery = qp_recovery_copy;
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

  protected function rdma_status project_queue_page_value(
    rdma_queue_dma_page_ref source,
    string copy_label,
    output rdma_queue_dma_page_ref result
  );
    rdma_status status;

    result = null;
    if (source == null)
      return rdma_status::success();
    result = new({copy_label, "_page"});
    result.role = source.role;
    result.mapping_offset = source.mapping_offset;
    result.logical_page_offset = source.logical_page_offset;
    result.page_iova = source.page_iova;
    status = project_mapping_value(source.mapping,
                                   {copy_label, "_mapping"},
                                   result.mapping);
    if (!status.ok())
      result = null;
    return status;
  endfunction

  protected function rdma_status project_queue_ring_value(
    rdma_queue_ring_layout source,
    string copy_label,
    output rdma_queue_ring_layout result
  );
    rdma_queue_dma_page_ref page_copy;
    rdma_status status;

    result = null;
    if (source == null)
      return rdma_status::success();
    result = new({copy_label, "_ring"});
    result.role = source.role;
    result.entry_size_bytes = source.entry_size_bytes;
    result.depth = source.depth;
    result.logical_bytes = source.logical_bytes;
    result.storage_bytes = source.storage_bytes;
    result.page_count = source.page_count;
    result.initial_polarity = source.initial_polarity;
    foreach (source.pages[i]) begin
      status = project_queue_page_value(
        source.pages[i], $sformatf("%s_page_%0d", copy_label, i), page_copy
      );
      if (!status.ok()) begin
        result = null;
        return status;
      end
      result.pages.push_back(page_copy);
    end
    return rdma_status::success();
  endfunction

  protected function rdma_status project_queue_backing_ref_value(
    rdma_queue_backing_ref source,
    string copy_label,
    output rdma_queue_backing_ref result
  );
    rdma_queue_backing_segment segment_copy;
    rdma_status status;

    result = null;
    if (source == null)
      return rdma_status::success();
    result = new({copy_label, "_ref"});
    result.role = source.role;
    result.ownership = source.ownership;
    result.mapping_offset = source.mapping_offset;
    result.length = source.length;
    result.logical_queue_offset = source.logical_queue_offset;
    result.cleanup_complete = source.cleanup_complete;
    if (source.ownership == RDMA_OWNERSHIP_CONTROL_PLANE)
      status = clone_owned_mapping_value(source.mapping,
                                         {copy_label, "_owned_mapping"},
                                         result.mapping);
    else
      status = project_mapping_value(source.mapping,
                                     {copy_label, "_borrowed_mapping"},
                                     result.mapping);
    if (!status.ok()) begin
      result = null;
      return status;
    end
    foreach (source.additional_segments[i]) begin
      segment_copy = new($sformatf("%s_segment_%0d", copy_label, i));
      if (source.additional_segments[i] == null) begin
        result = null;
        return rdma_status::make(
          RDMA_SC_INVALID_ARGUMENT,
          {copy_label, " additional backing segment is null"}
        );
      end
      segment_copy.role = source.additional_segments[i].role;
      segment_copy.ownership = source.additional_segments[i].ownership;
      segment_copy.mapping_offset =
        source.additional_segments[i].mapping_offset;
      segment_copy.length = source.additional_segments[i].length;
      segment_copy.logical_queue_offset =
        source.additional_segments[i].logical_queue_offset;
      if (segment_copy.ownership == RDMA_OWNERSHIP_CONTROL_PLANE)
        status = clone_owned_mapping_value(
          source.additional_segments[i].mapping,
          $sformatf("%s_segment_%0d_owned_mapping", copy_label, i),
          segment_copy.mapping
        );
      else
        status = project_mapping_value(
          source.additional_segments[i].mapping,
          $sformatf("%s_segment_%0d_borrowed_mapping", copy_label, i),
          segment_copy.mapping
        );
      if (!status.ok()) begin
        result = null;
        return status;
      end
      result.additional_segments.push_back(segment_copy);
    end
    return rdma_status::success();
  endfunction

  protected function rdma_status project_queue_slot_token_value(
    uvm_object source,
    string copy_label,
    output uvm_object result
  );
    rdma_queue_slot_token_contract source_token;
    rdma_queue_slot_token_contract result_token;
    uvm_object cloned_object;

    result = null;
    if (source == null)
      return rdma_status::success();
    if (!$cast(source_token, source) ||
        source_token.completion_authority == null)
      return rdma_status::make(
        RDMA_SC_INVALID_ARGUMENT,
        {copy_label, " slot token contract is invalid"}
      );
    cloned_object = source_token.clone();
    if (cloned_object == null || cloned_object == source ||
        !$cast(result_token, cloned_object) ||
        result_token.completion_authority == null ||
        result_token.completion_authority !==
          source_token.completion_authority)
      return rdma_status::make(
        RDMA_SC_INVALID_ARGUMENT,
        {copy_label, " slot token clone lost opaque authority"}
      );
    result = result_token;
    return rdma_status::success();
  endfunction

  protected function rdma_status project_queue_context_value(
    rdma_context_backing_ref source,
    string copy_label,
    output rdma_context_backing_ref result
  );
    rdma_status status;

    result = null;
    if (source == null)
      return rdma_status::success();
    result = new({copy_label, "_context"});
    status = project_function_handle_value(
      source.owner, {copy_label, "_owner"}, result.owner
    );
    if (status.ok())
      status = project_queue_slot_token_value(
        source.slot_token, {copy_label, "_token"}, result.slot_token
      );
    if (status.ok())
      status = project_hmc_ref_value(
        source.hmc_ref, {copy_label, "_hmc"}, result.hmc_ref
      );
    if (!status.ok()) begin
      result = null;
      return status;
    end
    result.resource_kind = source.resource_kind;
    result.local_id = source.local_id;
    result.shadow_pointer_base = source.shadow_pointer_base;
    result.slot_length = source.slot_length;
    result.shadow_view_offset = source.shadow_view_offset;
    result.shadow_view_length = source.shadow_view_length;
    result.release_complete = source.release_complete;
    return rdma_status::success();
  endfunction

  protected function rdma_status project_queue_flush_target_value(
    rdma_queue_flush_target source,
    string copy_label,
    output rdma_queue_flush_target result
  );
    rdma_status status;

    result = null;
    if (source == null)
      return rdma_status::success();
    result = new({copy_label, "_flush"});
    result.role = source.role;
    result.phase = source.phase;
    result.flush_complete = source.flush_complete;
    status = project_queue_backing_ref_value(
      source.pd_ref, {copy_label, "_pd_ref"}, result.pd_ref
    );
    if (!status.ok())
      result = null;
    return status;
  endfunction

  protected function rdma_status project_queue_plan_value(
    rdma_queue_backing_plan source,
    string copy_label,
    output rdma_queue_backing_plan result
  );
    rdma_queue_ring_layout ring_copy;
    rdma_queue_backing_ref ref_copy;
    rdma_queue_flush_target flush_copy;
    rdma_status status;

    result = null;
    if (source == null)
      return rdma_status::success();
    result = new({copy_label, "_plan"});
    result.resource_kind = source.resource_kind;
    foreach (source.rings[i]) begin
      status = project_queue_ring_value(
        source.rings[i], $sformatf("%s_ring_%0d", copy_label, i), ring_copy
      );
      if (!status.ok()) begin
        result = null;
        return status;
      end
      result.rings.push_back(ring_copy);
    end
    foreach (source.refs[i]) begin
      status = project_queue_backing_ref_value(
        source.refs[i], $sformatf("%s_ref_%0d", copy_label, i), ref_copy
      );
      if (!status.ok()) begin
        result = null;
        return status;
      end
      result.refs.push_back(ref_copy);
    end
    status = project_queue_context_value(
      source.context_ref, {copy_label, "_context"}, result.context_ref
    );
    if (!status.ok()) begin
      result = null;
      return status;
    end
    foreach (source.flush_targets[i]) begin
      status = project_queue_flush_target_value(
        source.flush_targets[i],
        $sformatf("%s_flush_%0d", copy_label, i), flush_copy
      );
      if (!status.ok()) begin
        result = null;
        return status;
      end
      result.flush_targets.push_back(flush_copy);
    end
    return rdma_status::success();
  endfunction

  protected function rdma_status project_qp_ring_value(
    rdma_qp_ring_layout source,
    string copy_label,
    output rdma_qp_ring_layout result
  );
    result = null;
    if (source == null)
      return rdma_status::success();
    result = new({copy_label, "_ring"});
    result.role = source.role;
    result.entry_size_bytes = source.entry_size_bytes;
    result.depth = source.depth;
    result.logical_bytes = source.logical_bytes;
    result.storage_bytes = source.storage_bytes;
    result.object_mode = source.object_mode;
    return rdma_status::success();
  endfunction

  protected function rdma_status project_qp_backing_ref_value(
    rdma_qp_backing_ref source,
    string copy_label,
    output rdma_qp_backing_ref result
  );
    rdma_status status;

    result = null;
    if (source == null)
      return rdma_status::success();
    result = new({copy_label, "_ref"});
    if (source.ownership == RDMA_OWNERSHIP_CONTROL_PLANE)
      status = clone_owned_mapping_value(
        source.mapping, {copy_label, "_owned_mapping"}, result.mapping
      );
    else
      status = project_mapping_value(
        source.mapping, {copy_label, "_borrowed_mapping"}, result.mapping
      );
    if (!status.ok()) begin
      result = null;
      return status;
    end
    result.role = source.role;
    result.ownership = source.ownership;
    result.mapping_offset = source.mapping_offset;
    result.length = source.length;
    result.cleanup_complete = source.cleanup_complete;
    result.additional_segments.delete();
    foreach (source.additional_segments[i]) begin
      rdma_queue_backing_segment segment;
      if (source.additional_segments[i] == null) begin
        result = null;
        return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                                 "QP backing segment is null");
      end
      segment = new({copy_label, "_segment"});
      segment.role = source.additional_segments[i].role;
      segment.ownership = source.additional_segments[i].ownership;
      segment.mapping_offset = source.additional_segments[i].mapping_offset;
      segment.length = source.additional_segments[i].length;
      segment.logical_queue_offset = source.additional_segments[i].logical_queue_offset;
      if (segment.ownership == RDMA_OWNERSHIP_CONTROL_PLANE)
        status = clone_owned_mapping_value(source.additional_segments[i].mapping,
          {copy_label, "_segment_mapping"}, segment.mapping);
      else
        status = project_mapping_value(source.additional_segments[i].mapping,
          {copy_label, "_segment_mapping"}, segment.mapping);
      if (!status.ok()) begin result = null; return status; end
      result.additional_segments.push_back(segment);
    end
    return rdma_status::success();
  endfunction

  protected function rdma_status project_qp_plan_value(
    rdma_qp_backing_plan source,
    string copy_label,
    output rdma_qp_backing_plan result
  );
    rdma_qp_backing_ref ref_copy;
    rdma_status status;

    result = null;
    if (source == null)
      return rdma_status::success();
    result = new({copy_label, "_plan"});
    result.transport = source.transport;
    result.sq_depth = source.sq_depth;
    result.rq_depth = source.rq_depth;
    result.sq_pd_flush_complete = source.sq_pd_flush_complete;
    result.rq_pd_flush_complete = source.rq_pd_flush_complete;
    result.cleanup_complete = source.cleanup_complete;
    status = project_qp_ring_value(source.sq_ring, {copy_label, "_sq"},
                                   result.sq_ring);
    if (status.ok())
      status = project_qp_ring_value(source.rq_ring, {copy_label, "_rq"},
                                     result.rq_ring);
    if (status.ok())
      status = project_qp_backing_ref_value(
        source.sq_ref, {copy_label, "_sq"}, result.sq_ref
      );
    if (status.ok())
      status = project_qp_backing_ref_value(
        source.rq_ref, {copy_label, "_rq"}, result.rq_ref
      );
    if (status.ok())
      status = project_qp_backing_ref_value(
        source.sq_pd_ref, {copy_label, "_sq_pd"}, result.sq_pd_ref
      );
    if (status.ok())
      status = project_qp_backing_ref_value(
        source.rq_pd_ref, {copy_label, "_rq_pd"}, result.rq_pd_ref
      );
    if (status.ok())
      status = project_handle_value(source.rq_source_h,
                                    {copy_label, "_rq_source"},
                                    result.rq_source_h);
    if (status.ok()) begin
      result.urc_refs.delete();
      foreach (source.urc_refs[i]) begin
        status = project_qp_backing_ref_value(
          source.urc_refs[i], $sformatf("%s_urc_%0d", copy_label, i),
          ref_copy
        );
        if (!status.ok()) break;
        result.urc_refs.push_back(ref_copy);
      end
    end
    if (status.ok())
      status = project_queue_context_value(
        source.context_ref, {copy_label, "_context"}, result.context_ref
      );
    if (!status.ok())
      result = null;
    return status;
  endfunction

  protected function rdma_status project_address_vector_value(
    rdma_address_vector source,
    string copy_label,
    output rdma_address_vector result
  );
    result = null;
    if (source == null)
      return rdma_status::success();
    result = new({copy_label, "_address_vector"});
    result.source_address_index = source.source_address_index;
    result.source_vport = source.source_vport;
    result.destination_vport = source.destination_vport;
    result.destination_port = source.destination_port;
    result.destination_mac = source.destination_mac;
    foreach (result.destination_ip[i])
      result.destination_ip[i] = source.destination_ip[i];
    result.ipv6 = source.ipv6;
    result.vlan_enable = source.vlan_enable;
    result.cfi = source.cfi;
    result.lag_enable = source.lag_enable;
    result.tunnel_enable = source.tunnel_enable;
    result.forwarding_enable = source.forwarding_enable;
    result.vlan_id = source.vlan_id;
    result.traffic_class = source.traffic_class;
    result.flow_label = source.flow_label;
    result.hop_limit = source.hop_limit;
    result.udp_source_port = source.udp_source_port;
    return rdma_status::success();
  endfunction

  protected function rdma_status project_qpc_behavior_value(
    rdma_qpc_behavior source,
    string copy_label,
    output rdma_qpc_behavior result
  );
    result = null;
    if (source == null)
      return rdma_status::success();
    result = new({copy_label, "_behavior"});
    result.transport_version = source.transport_version;
    result.migration_enable = source.migration_enable;
    result.tx_endian_swap = source.tx_endian_swap;
    result.rx_endian_swap = source.rx_endian_swap;
    result.read_after_write_fence = source.read_after_write_fence;
    result.atomic_after_atomic_fence = source.atomic_after_atomic_fence;
    result.\priority = source.\priority ;
    return rdma_status::success();
  endfunction

  protected function rdma_status project_qpc_extension_value(
    rdma_qpc_transport_ext source,
    string copy_label,
    output rdma_qpc_transport_ext result
  );
    rdma_qpc_rc_ext source_rc;
    rdma_qpc_rc_ext result_rc;
    rdma_qpc_ud_ext source_ud;
    rdma_qpc_ud_ext result_ud;
    rdma_qpc_urc_ext source_urc;
    rdma_qpc_urc_ext result_urc;

    result = null;
    if (source == null)
      return rdma_status::success();
    if ($cast(source_rc, source)) begin
      result_rc = new({copy_label, "_rc"});
      result_rc.remote_qpn = source_rc.remote_qpn;
      result_rc.send_psn = source_rc.send_psn;
      result_rc.recv_psn = source_rc.recv_psn;
      result_rc.retry_count = source_rc.retry_count;
      result_rc.rnr_retry_count = source_rc.rnr_retry_count;
      result = result_rc;
    end
    else if ($cast(source_ud, source)) begin
      result_ud = new({copy_label, "_ud"});
      result_ud.qkey = source_ud.qkey;
      result = result_ud;
    end
    else if ($cast(source_urc, source)) begin
      result_urc = new({copy_label, "_urc"});
      result_urc.remote_qpn = source_urc.remote_qpn;
      result_urc.rbsn = source_urc.rbsn;
      result_urc.dbsn = source_urc.dbsn;
      result_urc.rpsn = source_urc.rpsn;
      result_urc.dpsn = source_urc.dpsn;
      if (source_urc.queues == null)
        result_urc.queues = null;
      else begin
        result_urc.queues = new({copy_label, "_urc_queues"});
        result_urc.queues.rsq_backing = source_urc.queues.rsq_backing;
        result_urc.queues.rdsq_backing = source_urc.queues.rdsq_backing;
        result_urc.queues.dsq_backing = source_urc.queues.dsq_backing;
        result_urc.queues.rsq_depth = source_urc.queues.rsq_depth;
        result_urc.queues.rdsq_depth = source_urc.queues.rdsq_depth;
        result_urc.queues.rdsq_fetch_count =
          source_urc.queues.rdsq_fetch_count;
        result_urc.queues.dsq_fetch_count =
          source_urc.queues.dsq_fetch_count;
        result_urc.queues.rq_sequence_threshold_entries =
          source_urc.queues.rq_sequence_threshold_entries;
        result_urc.queues.sq_completion_threshold_entries =
          source_urc.queues.sq_completion_threshold_entries;
      end
      result = result_urc;
    end
    else
      return rdma_status::make(
        RDMA_SC_INVALID_ARGUMENT,
        {copy_label, " QPC transport extension is incompatible"}
      );
    return rdma_status::success();
  endfunction

  protected function rdma_status project_qpc_value(
    rdma_qpc_model source,
    string copy_label,
    output rdma_qpc_model result
  );
    rdma_status status;

    result = null;
    if (source == null)
      return rdma_status::success();
    result = new({copy_label, "_qpc"});
    status = project_handle_value(source.qp_h, {copy_label, "_qp"},
                                  result.qp_h);
    if (status.ok())
      status = project_handle_value(source.pd_h, {copy_label, "_pd"},
                                    result.pd_h);
    if (status.ok())
      status = project_handle_value(source.send_cq_h,
                                    {copy_label, "_send_cq"},
                                    result.send_cq_h);
    if (status.ok())
      status = project_handle_value(source.recv_cq_h,
                                    {copy_label, "_recv_cq"},
                                    result.recv_cq_h);
    if (status.ok())
      status = project_handle_value(source.srq_h, {copy_label, "_srq"},
                                    result.srq_h);
    if (!status.ok()) begin
      result = null;
      return status;
    end
    result.transport = source.transport;
    result.state = source.state;
    result.host_id = source.host_id;
    result.vf_id = source.vf_id;
    result.stat_index = source.stat_index;
    result.pkey = source.pkey;
    result.qp_sequence = source.qp_sequence;
    result.access = source.access;
    result.path_mtu_bytes = source.path_mtu_bytes;
    result.sq_depth = source.sq_depth;
    result.rq_depth = source.rq_depth;
    result.sq_backing = source.sq_backing;
    result.rq_backing = source.rq_backing;
    result.context_backing = source.context_backing;
    result.sq_mode = source.sq_mode;
    result.rq_mode = source.rq_mode;
    result.signature_enable = source.signature_enable;
    result.tx_flow_control = source.tx_flow_control;
    result.rx_flow_control = source.rx_flow_control;
    status = project_address_vector_value(
      source.address_vector, {copy_label, "_av"}, result.address_vector
    );
    if (status.ok())
      status = project_qpc_behavior_value(
        source.behavior, {copy_label, "_behavior"}, result.behavior
      );
    if (status.ok())
      status = project_qpc_extension_value(
        source.transport_ext, {copy_label, "_extension"},
        result.transport_ext
      );
    if (!status.ok())
      result = null;
    return status;
  endfunction

  protected function bit same_qp_backing_ref_value(
    rdma_qp_backing_ref lhs,
    rdma_qp_backing_ref rhs
  );
    if (lhs == null || rhs == null)
      return lhs == rhs;
    if (lhs.role != rhs.role || lhs.ownership != rhs.ownership ||
        lhs.mapping_offset != rhs.mapping_offset || lhs.length != rhs.length ||
        lhs.cleanup_complete != rhs.cleanup_complete ||
        lhs.additional_segments.size() != rhs.additional_segments.size())
      return 1'b0;
    foreach (lhs.additional_segments[i]) begin
      if (lhs.additional_segments[i] == null || rhs.additional_segments[i] == null ||
          lhs.additional_segments[i].role != rhs.additional_segments[i].role ||
          lhs.additional_segments[i].ownership != rhs.additional_segments[i].ownership ||
          lhs.additional_segments[i].mapping_offset != rhs.additional_segments[i].mapping_offset ||
          lhs.additional_segments[i].length != rhs.additional_segments[i].length ||
          lhs.additional_segments[i].logical_queue_offset != rhs.additional_segments[i].logical_queue_offset ||
          !same_mapping_value(lhs.additional_segments[i].mapping,
                              rhs.additional_segments[i].mapping)) return 1'b0;
    end
    if (lhs.ownership == RDMA_OWNERSHIP_CONTROL_PLANE)
      return same_mapping_value(lhs.mapping, rhs.mapping) &&
             same_owned_mapping_authority(lhs.mapping, rhs.mapping);
    return same_mapping_value(lhs.mapping, rhs.mapping);
  endfunction

  protected function bit same_qp_ring_value(
    rdma_qp_ring_layout lhs,
    rdma_qp_ring_layout rhs
  );
    if (lhs == null || rhs == null)
      return lhs == rhs;
    return lhs.role == rhs.role &&
           lhs.entry_size_bytes == rhs.entry_size_bytes &&
           lhs.depth == rhs.depth && lhs.logical_bytes == rhs.logical_bytes &&
           lhs.storage_bytes == rhs.storage_bytes &&
           lhs.object_mode == rhs.object_mode;
  endfunction

  protected function bit same_context_value(
    rdma_context_backing_ref lhs,
    rdma_context_backing_ref rhs
  );
    rdma_queue_slot_token_contract lhs_token;
    rdma_queue_slot_token_contract rhs_token;

    if (lhs == null || rhs == null)
      return lhs == rhs;
    if (!$cast(lhs_token, lhs.slot_token) || !$cast(rhs_token, rhs.slot_token) ||
        lhs_token.completion_authority == null ||
        rhs_token.completion_authority == null)
      return 1'b0;
    return lhs_token.completion_authority === rhs_token.completion_authority &&
           same_handle_instance(lhs.owner, rhs.owner) &&
           lhs.resource_kind == rhs.resource_kind &&
           lhs.local_id == rhs.local_id &&
           lhs.shadow_pointer_base.value == rhs.shadow_pointer_base.value &&
           lhs.slot_length == rhs.slot_length &&
           lhs.shadow_view_offset == rhs.shadow_view_offset &&
           lhs.shadow_view_length == rhs.shadow_view_length &&
           lhs.release_complete == rhs.release_complete &&
           lhs.hmc_ref != null && rhs.hmc_ref != null &&
           same_handle_instance(lhs.hmc_ref.owner, rhs.hmc_ref.owner) &&
           lhs.hmc_ref.object_kind == rhs.hmc_ref.object_kind &&
           lhs.hmc_ref.address.value == rhs.hmc_ref.address.value &&
           lhs.hmc_ref.size == rhs.hmc_ref.size &&
           lhs.hmc_ref.first_pbl_index == rhs.hmc_ref.first_pbl_index &&
           lhs.hmc_ref.ownership == rhs.hmc_ref.ownership &&
           lhs.hmc_ref.release_complete == rhs.hmc_ref.release_complete;
  endfunction

  protected function bit same_qp_plan_value(
    rdma_qp_backing_plan lhs,
    rdma_qp_backing_plan rhs
  );
    if (lhs == null || rhs == null)
      return lhs == rhs;
    if (lhs.transport != rhs.transport || lhs.sq_depth != rhs.sq_depth ||
        lhs.rq_depth != rhs.rq_depth ||
        lhs.sq_pd_flush_complete != rhs.sq_pd_flush_complete ||
        lhs.rq_pd_flush_complete != rhs.rq_pd_flush_complete ||
        lhs.cleanup_complete != rhs.cleanup_complete ||
        !same_qp_ring_value(lhs.sq_ring, rhs.sq_ring) ||
        !same_qp_ring_value(lhs.rq_ring, rhs.rq_ring) ||
        !same_qp_backing_ref_value(lhs.sq_ref, rhs.sq_ref) ||
        !same_qp_backing_ref_value(lhs.rq_ref, rhs.rq_ref) ||
        !same_qp_backing_ref_value(lhs.sq_pd_ref, rhs.sq_pd_ref) ||
        !same_qp_backing_ref_value(lhs.rq_pd_ref, rhs.rq_pd_ref) ||
        !same_handle_instance(lhs.rq_source_h, rhs.rq_source_h) ||
        lhs.urc_refs.size() != rhs.urc_refs.size() ||
        !same_context_value(lhs.context_ref, rhs.context_ref))
      return 1'b0;
    foreach (lhs.urc_refs[i])
      if (!same_qp_backing_ref_value(lhs.urc_refs[i], rhs.urc_refs[i]))
        return 1'b0;
    return 1'b1;
  endfunction

  protected function bit same_address_vector_value(
    rdma_address_vector lhs,
    rdma_address_vector rhs
  );
    if (lhs == null || rhs == null)
      return lhs == rhs;
    if (lhs.source_address_index != rhs.source_address_index ||
        lhs.source_vport != rhs.source_vport ||
        lhs.destination_vport != rhs.destination_vport ||
        lhs.destination_port != rhs.destination_port ||
        lhs.destination_mac != rhs.destination_mac || lhs.ipv6 != rhs.ipv6 ||
        lhs.vlan_enable != rhs.vlan_enable || lhs.cfi != rhs.cfi ||
        lhs.lag_enable != rhs.lag_enable ||
        lhs.tunnel_enable != rhs.tunnel_enable ||
        lhs.forwarding_enable != rhs.forwarding_enable ||
        lhs.vlan_id != rhs.vlan_id ||
        lhs.traffic_class != rhs.traffic_class ||
        lhs.flow_label != rhs.flow_label || lhs.hop_limit != rhs.hop_limit ||
        lhs.udp_source_port != rhs.udp_source_port)
      return 1'b0;
    foreach (lhs.destination_ip[i])
      if (lhs.destination_ip[i] != rhs.destination_ip[i])
        return 1'b0;
    return 1'b1;
  endfunction

  protected function bit same_qpc_behavior_value(
    rdma_qpc_behavior lhs,
    rdma_qpc_behavior rhs
  );
    if (lhs == null || rhs == null)
      return lhs == rhs;
    return lhs.transport_version == rhs.transport_version &&
           lhs.migration_enable == rhs.migration_enable &&
           lhs.tx_endian_swap == rhs.tx_endian_swap &&
           lhs.rx_endian_swap == rhs.rx_endian_swap &&
           lhs.read_after_write_fence == rhs.read_after_write_fence &&
           lhs.atomic_after_atomic_fence == rhs.atomic_after_atomic_fence &&
           lhs.\priority == rhs.\priority ;
  endfunction

  protected function bit same_qpc_extension_value(
    rdma_qpc_transport_ext lhs,
    rdma_qpc_transport_ext rhs
  );
    rdma_qpc_rc_ext lhs_rc;
    rdma_qpc_rc_ext rhs_rc;
    rdma_qpc_ud_ext lhs_ud;
    rdma_qpc_ud_ext rhs_ud;
    rdma_qpc_urc_ext lhs_urc;
    rdma_qpc_urc_ext rhs_urc;

    if (lhs == null || rhs == null)
      return lhs == rhs;
    if ($cast(lhs_rc, lhs) && $cast(rhs_rc, rhs))
      return lhs_rc.remote_qpn == rhs_rc.remote_qpn &&
             lhs_rc.send_psn == rhs_rc.send_psn &&
             lhs_rc.recv_psn == rhs_rc.recv_psn &&
             lhs_rc.retry_count == rhs_rc.retry_count &&
             lhs_rc.rnr_retry_count == rhs_rc.rnr_retry_count;
    if ($cast(lhs_ud, lhs) && $cast(rhs_ud, rhs))
      return lhs_ud.qkey == rhs_ud.qkey;
    if ($cast(lhs_urc, lhs) && $cast(rhs_urc, rhs)) begin
      if (lhs_urc.remote_qpn != rhs_urc.remote_qpn ||
          lhs_urc.rbsn != rhs_urc.rbsn || lhs_urc.dbsn != rhs_urc.dbsn ||
          lhs_urc.rpsn != rhs_urc.rpsn || lhs_urc.dpsn != rhs_urc.dpsn ||
          lhs_urc.queues == null || rhs_urc.queues == null)
        return 1'b0;
      return lhs_urc.queues.rsq_backing.value ==
               rhs_urc.queues.rsq_backing.value &&
             lhs_urc.queues.rdsq_backing.value ==
               rhs_urc.queues.rdsq_backing.value &&
             lhs_urc.queues.dsq_backing.value ==
               rhs_urc.queues.dsq_backing.value &&
             lhs_urc.queues.rsq_depth == rhs_urc.queues.rsq_depth &&
             lhs_urc.queues.rdsq_depth == rhs_urc.queues.rdsq_depth &&
             lhs_urc.queues.rdsq_fetch_count ==
               rhs_urc.queues.rdsq_fetch_count &&
             lhs_urc.queues.dsq_fetch_count ==
               rhs_urc.queues.dsq_fetch_count &&
             lhs_urc.queues.rq_sequence_threshold_entries ==
               rhs_urc.queues.rq_sequence_threshold_entries &&
             lhs_urc.queues.sq_completion_threshold_entries ==
               rhs_urc.queues.sq_completion_threshold_entries;
    end
    return 1'b0;
  endfunction

  protected function bit same_qpc_value(
    rdma_qpc_model lhs,
    rdma_qpc_model rhs
  );
    if (lhs == null || rhs == null)
      return lhs == rhs;
    return same_handle_instance(lhs.qp_h, rhs.qp_h) &&
           same_handle_instance(lhs.pd_h, rhs.pd_h) &&
           same_handle_instance(lhs.send_cq_h, rhs.send_cq_h) &&
           same_handle_instance(lhs.recv_cq_h, rhs.recv_cq_h) &&
           same_handle_instance(lhs.srq_h, rhs.srq_h) &&
           lhs.transport == rhs.transport && lhs.state == rhs.state &&
           lhs.host_id == rhs.host_id && lhs.vf_id == rhs.vf_id &&
           lhs.stat_index == rhs.stat_index && lhs.pkey == rhs.pkey &&
           lhs.qp_sequence == rhs.qp_sequence && lhs.access == rhs.access &&
           lhs.path_mtu_bytes == rhs.path_mtu_bytes &&
           lhs.sq_depth == rhs.sq_depth && lhs.rq_depth == rhs.rq_depth &&
           lhs.sq_backing.value == rhs.sq_backing.value &&
           lhs.rq_backing.value == rhs.rq_backing.value &&
           lhs.context_backing.value == rhs.context_backing.value &&
           lhs.sq_mode == rhs.sq_mode && lhs.rq_mode == rhs.rq_mode &&
           lhs.signature_enable == rhs.signature_enable &&
           lhs.tx_flow_control == rhs.tx_flow_control &&
           lhs.rx_flow_control == rhs.rx_flow_control &&
           same_address_vector_value(lhs.address_vector,
                                     rhs.address_vector) &&
           same_qpc_behavior_value(lhs.behavior, rhs.behavior) &&
           same_qpc_extension_value(lhs.transport_ext, rhs.transport_ext);
  endfunction

  protected function bit same_qp_reconciliation_value(
    rdma_qp lhs,
    rdma_qp rhs
  );
    if (lhs == null || rhs == null)
      return lhs == rhs;
    return same_handle_instance(lhs.handle, rhs.handle) &&
           same_handle_instance(lhs.owner, rhs.owner) &&
           lhs.state == rhs.state &&
           lhs.backing_refs.size() == rhs.backing_refs.size() &&
           lhs.hmc_refs.size() == rhs.hmc_refs.size() &&
           same_dependency_topology(lhs, rhs) &&
           same_outstanding_ids(lhs, rhs) &&
           lhs.hmc_fvm_addr == rhs.hmc_fvm_addr &&
           lhs.hmc_fvm_addr_valid == rhs.hmc_fvm_addr_valid &&
           lhs.local_qp_id == rhs.local_qp_id &&
           lhs.global_qp_id == rhs.global_qp_id &&
           lhs.transport == rhs.transport && lhs.qp_state == rhs.qp_state &&
           lhs.sq_depth == rhs.sq_depth && lhs.rq_depth == rhs.rq_depth &&
           lhs.sq_producer_index == rhs.sq_producer_index &&
           lhs.sq_consumer_index == rhs.sq_consumer_index &&
           lhs.sq_wrap == rhs.sq_wrap &&
           lhs.sq_consumer_wrap == rhs.sq_consumer_wrap &&
           lhs.rq_producer_index == rhs.rq_producer_index &&
           lhs.rq_consumer_index == rhs.rq_consumer_index &&
           lhs.rq_wrap == rhs.rq_wrap &&
           lhs.rq_consumer_wrap == rhs.rq_consumer_wrap &&
           lhs.sq_iova.value == rhs.sq_iova.value &&
           lhs.rq_iova.value == rhs.rq_iova.value &&
           same_handle_instance(lhs.pd_h, rhs.pd_h) &&
           same_handle_instance(lhs.send_cq_h, rhs.send_cq_h) &&
           same_handle_instance(lhs.recv_cq_h, rhs.recv_cq_h) &&
           same_handle_instance(lhs.srq_h, rhs.srq_h) &&
           same_qp_plan_value(lhs.qp_plan, rhs.qp_plan) &&
           same_qpc_value(lhs.programmed_qpc, rhs.programmed_qpc);
  endfunction

  protected function rdma_status project_qp_recovery_value(
    rdma_qp_recovery_state source,
    string copy_label,
    output rdma_qp_recovery_state result
  );
    rdma_status status;

    result = null;
    if (source == null)
      return rdma_status::success();
    result = new({copy_label, "_qp_recovery"});
    result.intent = source.intent;
    result.ambiguous_operation = source.ambiguous_operation;
    result.role_complete = source.role_complete;
    status = project_qpc_value(source.prior_qpc, {copy_label, "_prior"},
                               result.prior_qpc);
    if (status.ok())
      status = project_qpc_value(source.candidate_qpc,
                                 {copy_label, "_candidate"},
                                 result.candidate_qpc);
    if (status.ok())
      status = project_qp_plan_value(source.qp_plan, {copy_label, "_plan"},
                                     result.qp_plan);
    if (status.ok())
      status = project_queue_context_value(
        source.context_ref, {copy_label, "_context"}, result.context_ref
      );
    if (status.ok() && source.staging_mapping != null)
      status = clone_owned_mapping_value(
        source.staging_mapping, {copy_label, "_staging"},
        result.staging_mapping
      );
    if (status.ok() && source.query_mapping != null)
      status = clone_owned_mapping_value(
        source.query_mapping, {copy_label, "_query"}, result.query_mapping
      );
    if (status.ok())
      status = project_opcode_value(source.create_opcode,
                                    {copy_label, "_create"},
                                    result.create_opcode);
    if (status.ok())
      status = project_opcode_value(source.modify_opcode,
                                    {copy_label, "_modify"},
                                    result.modify_opcode);
    if (status.ok())
      status = project_opcode_value(source.delete_opcode,
                                    {copy_label, "_delete"},
                                    result.delete_opcode);
    if (status.ok())
      status = project_opcode_value(source.query_opcode,
                                    {copy_label, "_query_opcode"},
                                    result.query_opcode);
    if (status.ok())
      status = project_ticket_value(source.ambiguous_ticket,
                                    {copy_label, "_ticket"},
                                    result.ambiguous_ticket);
    if (!status.ok())
      result = null;
    return status;
  endfunction

  protected function rdma_status project_queue_fields(
    rdma_queue_resource source,
    rdma_queue_resource result,
    string copy_label
  );
    rdma_status status;

    result.depth = source.depth;
    result.producer_index = source.producer_index;
    result.consumer_index = source.consumer_index;
    result.producer_wrap = source.producer_wrap;
    result.consumer_wrap = source.consumer_wrap;
    result.queue_iova = source.queue_iova;
    status = project_queue_plan_value(source.queue_plan,
                                      {copy_label, "_queue_plan"},
                                      result.queue_plan);
    return status;
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
        status = project_queue_fields(source_cq, result_cq, copy_label);
        result_cq.local_cq_id = source_cq.local_cq_id;
        result_cq.global_cq_id = source_cq.global_cq_id;
        result_cq.cqe_size_bytes = source_cq.cqe_size_bytes;
        if (status.ok())
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
        if (status.ok())
          status = project_qp_plan_value(
            source_qp.qp_plan, {copy_label, "_qp_plan"}, result_qp.qp_plan
          );
        if (status.ok())
          status = project_qpc_value(
            source_qp.programmed_qpc, {copy_label, "_programmed_qpc"},
            result_qp.programmed_qpc
          );
      end
      RDMA_RESOURCE_SRQ: begin
        status = project_queue_fields(source_srq, result_srq, copy_label);
        result_srq.local_srq_id = source_srq.local_srq_id;
        result_srq.global_srq_id = source_srq.global_srq_id;
        result_srq.max_sge = source_srq.max_sge;
        result_srq.limit_threshold = source_srq.limit_threshold;
        if (status.ok())
          status = project_handle_value(
            source_srq.pd_h, {copy_label, "_pd"}, result_srq.pd_h
          );
      end
      RDMA_RESOURCE_CMQ: begin
        status = project_queue_fields(source_cmq, result_cmq, copy_label);
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
        status = project_queue_fields(source_ceq, result_ceq, copy_label);
        result_ceq.local_ceq_id = source_ceq.local_ceq_id;
        result_ceq.global_ceq_id = source_ceq.global_ceq_id;
        result_ceq.function_local_vector = source_ceq.function_local_vector;
        result_ceq.hardware_vector = source_ceq.hardware_vector;
        result_ceq.msix_table_index = source_ceq.msix_table_index;
      end
      RDMA_RESOURCE_AEQ: begin
        status = project_queue_fields(source_aeq, result_aeq, copy_label);
        result_aeq.local_aeq_id = source_aeq.local_aeq_id;
        result_aeq.global_aeq_id = source_aeq.global_aeq_id;
        result_aeq.function_local_vector = source_aeq.function_local_vector;
        result_aeq.hardware_vector = source_aeq.hardware_vector;
        result_aeq.msix_table_index = source_aeq.msix_table_index;
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
        lhs.state != rhs.state || lhs.generation != rhs.generation ||
        lhs.notify_valid != rhs.notify_valid ||
        lhs.notify_ready != rhs.notify_ready ||
        lhs.dmi_valid != rhs.dmi_valid || lhs.dmi_ready != rhs.dmi_ready ||
        lhs.vft_valid != rhs.vft_valid || lhs.vft_ready != rhs.vft_ready ||
        !same_handle_value(lhs.owner_h, rhs.owner_h))
      return 1'b0;
    if (lhs.queue_dma.requester_bdf != rhs.queue_dma.requester_bdf ||
        lhs.queue_dma.pasid_valid != rhs.queue_dma.pasid_valid ||
        lhs.queue_dma.pasid != rhs.queue_dma.pasid ||
        lhs.queue_dma.dma_domain_valid != rhs.queue_dma.dma_domain_valid ||
        lhs.queue_dma.dma_domain_id != rhs.queue_dma.dma_domain_id)
      return 1'b0;
    if (lhs.queue_caps.min_cq_depth != rhs.queue_caps.min_cq_depth ||
        lhs.queue_caps.max_cq_depth != rhs.queue_caps.max_cq_depth ||
        lhs.queue_caps.min_srq_depth != rhs.queue_caps.min_srq_depth ||
        lhs.queue_caps.max_srq_depth != rhs.queue_caps.max_srq_depth ||
        lhs.queue_caps.max_ceq_depth != rhs.queue_caps.max_ceq_depth ||
        lhs.queue_caps.max_aeq_depth != rhs.queue_caps.max_aeq_depth ||
        lhs.queue_caps.max_wq_sge != rhs.queue_caps.max_wq_sge ||
        lhs.queue_caps.max_queue_ring_bytes !=
          rhs.queue_caps.max_queue_ring_bytes ||
        lhs.queue_caps.max_sgb_bytes != rhs.queue_caps.max_sgb_bytes)
      return 1'b0;
    if (lhs.interrupt_vectors.size() != rhs.interrupt_vectors.size())
      return 1'b0;
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
    string sequence_key;

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
    sequence_key = qp_sequence_key(owner, local_id);
    if (qp_sequences.exists(sequence_key))
      qp_sequences[sequence_key]++;
    else
      qp_sequences[sequence_key] = '0;
    return rdma_status::success();
  endfunction

  virtual function rdma_status qp_sequence(
    rdma_function_handle owner,
    int unsigned local_qpn,
    output bit [7:0] sequence_value
  );
    rdma_function_handle trusted_owner;
    rdma_status status;
    string key;

    sequence_value = '0;
    status = project_function_handle_value(owner, "QP sequence owner",
                                           trusted_owner);
    if (!status.ok())
      return status;
    if (trusted_owner == null ||
        trusted_owner.kind != RDMA_RESOURCE_FUNCTION ||
        local_qpn > local_id_limit(RDMA_RESOURCE_QP))
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "QP sequence identity is invalid");
    status = owner_binding_status(trusted_owner);
    if (!status.ok())
      return status;
    key = qp_sequence_key(trusted_owner, local_qpn);
    if (!qp_sequences.exists(key))
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "QP sequence identity is unknown");
    sequence_value = qp_sequences[key];
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
    if (replacement.handle.kind == RDMA_RESOURCE_QP)
      return rdma_status::make(
        RDMA_SC_INVALID_STATE,
        "QP resources require QP-specific programming attachment"
      );
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
    if (replacement.handle.kind == RDMA_RESOURCE_QP)
      return rdma_status::make(
        RDMA_SC_INVALID_STATE,
        "QP resources require QP-specific programmed commit"
      );
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

  virtual function rdma_status attach_qp_programming(rdma_qp candidate);
    rdma_resource authoritative;
    rdma_resource projected;
    rdma_qp replacement;
    rdma_qp authoritative_qp;
    rdma_status status;
    string key;

    status = project_public_resource_value(candidate, "attach QP programming",
                                           projected);
    if (!status.ok() || !$cast(replacement, projected))
      return status.ok() ? rdma_status::make(
        RDMA_SC_INVALID_ARGUMENT, "QP programming candidate is incompatible"
      ) : status;
    if (replacement.state != RDMA_RESOURCE_ALLOCATED ||
        replacement.qp_plan == null || replacement.programmed_qpc == null)
      return rdma_status::make(
        RDMA_SC_INVALID_STATE,
        "QP programming requires a complete ALLOCATED replacement"
      );
    status = lookup(replacement.handle, authoritative);
    if (!status.ok() || !$cast(authoritative_qp, authoritative))
      return status.ok() ? rdma_status::make(
        RDMA_SC_INVALID_ARGUMENT, "QP programming target is not a QP"
      ) : status;
    key = resource_key(authoritative.handle);
    if (registry[key].state != RDMA_RESOURCE_ALLOCATED ||
        staged_allocations.exists(key) || authoritative_qp.qp_plan != null ||
        authoritative_qp.programmed_qpc != null)
      return rdma_status::make(
        RDMA_SC_INVALID_STATE, "QP programming target is not a clean reservation"
      );
    status = publication_identity_status(replacement, authoritative);
    if (!status.ok())
      return status;
    replacement.state = RDMA_RESOURCE_PROGRAMMED;
    status = replacement.validate();
    if (status == null)
      return rdma_status::make(
        RDMA_SC_INVALID_STATE, "QP programming validation returned null"
      );
    if (!status.ok())
      return status;
    registry[key] = replacement;
    return rdma_status::success();
  endfunction

  virtual function rdma_status commit_qp_semantic_state(
    rdma_handle qp_h,
    rdma_qp_state_e state
  );
    rdma_resource authoritative;
    rdma_resource projected;
    rdma_qp replacement;
    rdma_status status;
    string key;

    status = lookup(qp_h, authoritative);
    if (!status.ok() || authoritative.handle.kind != RDMA_RESOURCE_QP)
      return status.ok() ? rdma_status::make(
        RDMA_SC_INVALID_ARGUMENT, "semantic-state target is not a QP"
      ) : status;
    key = resource_key(authoritative.handle);
    if (registry[key].state != RDMA_RESOURCE_ACTIVE ||
        !$cast(replacement, registry[key]) ||
        replacement.qp_state != RDMA_QPS_RESET || state != RDMA_QPS_INIT)
      return rdma_status::make(
        RDMA_SC_INVALID_STATE,
        "QP semantic-only commit requires ACTIVE RESET to INIT"
      );
    status = project_resource_value(registry[key], "commit QP semantic state",
                                    projected);
    if (!status.ok() || !$cast(replacement, projected))
      return status.ok() ? rdma_status::make(
        RDMA_SC_INVALID_STATE, "QP semantic-state projection failed"
      ) : status;
    replacement.qp_state = state;
    status = replacement.validate();
    if (status == null)
      return rdma_status::make(
        RDMA_SC_INVALID_STATE, "QP semantic-state validation returned null"
      );
    if (!status.ok())
      return status;
    registry[key] = replacement;
    return rdma_status::success();
  endfunction

  virtual function rdma_status commit_qp_programmed(rdma_qp candidate);
    rdma_resource authoritative;
    rdma_resource projected;
    rdma_qp authoritative_qp;
    rdma_qp replacement;
    rdma_qp expected_replacement;
    rdma_qpc_model requested_qpc;
    rdma_qp_state_e requested_qp_state;
    rdma_recovery_record recovery;
    rdma_status status;
    bit release_complete;
    string key;
    bit reconciliation;
    bit restore_prior;

    status = project_public_resource_value(candidate, "commit QP programmed",
                                           projected);
    if (!status.ok() || !$cast(replacement, projected))
      return status.ok() ? rdma_status::make(
        RDMA_SC_INVALID_ARGUMENT, "programmed QP candidate is incompatible"
      ) : status;
    status = lookup(replacement.handle, authoritative);
    if (!status.ok() || !$cast(authoritative_qp, authoritative))
      return status.ok() ? rdma_status::make(
        RDMA_SC_INVALID_ARGUMENT, "programmed target is not a QP"
      ) : status;
    key = resource_key(authoritative.handle);
    status = publication_identity_status(replacement, authoritative);
    if (!status.ok())
      return status;
    if (!same_qp_plan_value(replacement.qp_plan,
                            authoritative_qp.qp_plan))
      return rdma_status::make(
        RDMA_SC_INVALID_ARGUMENT, "programmed QP backing authority changed"
      );

    reconciliation = registry[key].state == RDMA_RESOURCE_ERROR;
    if (!reconciliation) begin
      if (registry[key].state != RDMA_RESOURCE_ACTIVE ||
          replacement.state != RDMA_RESOURCE_ACTIVE)
        return rdma_status::make(
          RDMA_SC_INVALID_STATE, "programmed QP commit requires ACTIVE state"
        );
      requested_qp_state = replacement.qp_state;
      status = project_qpc_value(
        replacement.programmed_qpc, "commit QP requested QPC",
        requested_qpc
      );
      if (!status.ok() || requested_qpc == null)
        return status.ok() ? rdma_status::make(
          RDMA_SC_INVALID_STATE,
          "requested QP programmed QPC projection failed"
        ) : status;
      status = project_resource_value(
        registry[key], "commit QP authoritative resource", projected
      );
      if (!status.ok() || !$cast(replacement, projected))
        return status.ok() ? rdma_status::make(
          RDMA_SC_INVALID_STATE,
          "authoritative QP programmed projection failed"
        ) : status;
      replacement.programmed_qpc = requested_qpc;
      replacement.qp_state = requested_qp_state;
    end
    else begin
      status = recovery_entry_schema_status(key, "commit QP programmed");
      if (!status.ok())
        return status;
      if (!recovery_records.exists(key))
        return rdma_status::make(
          RDMA_SC_INVALID_STATE, "ERROR QP lacks modify recovery"
        );
      recovery = recovery_records[key];
      restore_prior = recovery.qp_recovery_valid &&
        recovery.qp_recovery != null &&
        same_qpc_value(replacement.programmed_qpc,
                       recovery.qp_recovery.prior_qpc);
      if (!recovery.qp_recovery_valid || recovery.qp_recovery == null ||
          recovery.qp_recovery.intent !=
            RDMA_QP_RECOVER_MODIFY_RECONCILE ||
          !(restore_prior ||
            same_qpc_value(replacement.programmed_qpc,
                           recovery.qp_recovery.candidate_qpc)))
        return rdma_status::make(
          RDMA_SC_INVALID_ARGUMENT,
          "programmed QP does not match a reconciliation candidate"
        );
      status = project_resource_value(
        registry[key], "commit QP expected reconciliation", projected
      );
      if (!status.ok() || !$cast(expected_replacement, projected))
        return status.ok() ? rdma_status::make(
          RDMA_SC_INVALID_STATE,
          "expected QP reconciliation projection failed"
        ) : status;
      status = project_qpc_value(
        restore_prior ? recovery.qp_recovery.prior_qpc :
                        recovery.qp_recovery.candidate_qpc,
        "commit QP expected reconciliation QPC",
        expected_replacement.programmed_qpc
      );
      if (!status.ok() || expected_replacement.programmed_qpc == null)
        return status.ok() ? rdma_status::make(
          RDMA_SC_INVALID_STATE,
          "expected QP reconciliation QPC projection failed"
        ) : status;
      expected_replacement.qp_state = restore_prior ?
        authoritative_qp.qp_state : expected_replacement.programmed_qpc.state;
      expected_replacement.state = RDMA_RESOURCE_ACTIVE;
      if (!same_qp_reconciliation_value(replacement,
                                         expected_replacement))
        return rdma_status::make(
          RDMA_SC_INVALID_ARGUMENT,
          "programmed QP is not the complete reconciliation replacement"
        );
      if (recovery.qp_recovery.ambiguous_operation != RDMA_QP_AMBIG_NONE ||
          recovery.qp_recovery.ambiguous_ticket != null)
        return rdma_status::make(
          RDMA_SC_RECOVERY_REQUIRED,
          "QP recovery ambiguity is not resolved"
        );
      if (recovery.qp_recovery.staging_mapping != null) begin
        status = query_owned_release_completion(
          recovery.qp_recovery.staging_mapping, release_complete
        );
        if (status == null || !status.ok() || !release_complete)
          return rdma_status::make(
            RDMA_SC_RECOVERY_REQUIRED,
            "QP recovery staging release is not complete"
          );
      end
      if (recovery.qp_recovery.query_mapping != null) begin
        status = query_owned_release_completion(
          recovery.qp_recovery.query_mapping, release_complete
        );
        if (status == null || !status.ok() || !release_complete)
          return rdma_status::make(
            RDMA_SC_RECOVERY_REQUIRED,
            "QP recovery query release is not complete"
          );
      end
      replacement = expected_replacement;
    end
    status = replacement.validate();
    if (status == null)
      return rdma_status::make(
        RDMA_SC_INVALID_STATE, "programmed QP validation returned null"
      );
    if (!status.ok())
      return status;
    registry[key] = replacement;
    if (reconciliation)
      recovery_records.delete(key);
    return rdma_status::success();
  endfunction

  virtual function rdma_status mark_qp_error(
    rdma_handle qp_h,
    rdma_qp_recovery_state recovery
  );
    rdma_resource authoritative;
    rdma_resource projected;
    rdma_qp authoritative_qp;
    rdma_qp replacement;
    rdma_qp_recovery_state recovery_copy;
    rdma_qp_recovery_state existing_recovery;
    rdma_recovery_record record_copy;
    rdma_status status;
    string key;
    bit error_replacement;
    bit progress_changed;

    status = lookup(qp_h, authoritative);
    if (!status.ok() && status.code == RDMA_SC_STALE_GENERATION &&
        recovery != null &&
        recovery.ambiguous_operation != RDMA_QP_AMBIG_NONE &&
        recovery.ambiguous_ticket != null) begin
      key = resource_key(qp_h);
      if (registry.exists(key) && registry[key] != null &&
          registry[key].handle != null &&
          same_handle_instance(registry[key].handle, qp_h))
        status = project_resource_value(
          registry[key], "mark stale in-flight QP ERROR", authoritative
        );
    end
    if (!status.ok() || !$cast(authoritative_qp, authoritative))
      return status.ok() ? rdma_status::make(
        RDMA_SC_INVALID_ARGUMENT, "QP ERROR target is not a QP"
      ) : status;
    key = resource_key(authoritative.handle);
    error_replacement =
      (registry[key].state == RDMA_RESOURCE_ERROR) &&
      recovery_records.exists(key) &&
      (recovery_records[key] != null) &&
      recovery_records[key].qp_recovery_valid &&
      (recovery_records[key].qp_recovery != null);
    if ((!(registry[key].state inside {RDMA_RESOURCE_PROGRAMMED,
                                       RDMA_RESOURCE_ACTIVE,
                                       RDMA_RESOURCE_QUIESCING}) &&
         !error_replacement) ||
        ((registry[key].state != RDMA_RESOURCE_ERROR) &&
         recovery_records.exists(key)))
      return rdma_status::make(
        RDMA_SC_INVALID_STATE, "QP cannot enter ERROR from its current state"
      );
    if (error_replacement) begin
      status = recovery_entry_schema_status(key, "replace QP ERROR recovery");
      if (!status.ok())
        return status;
    end
    status = project_qp_recovery_value(recovery, "mark QP ERROR",
                                       recovery_copy);
    if (!status.ok() || recovery_copy == null)
      return status.ok() ? rdma_status::make(
        RDMA_SC_INVALID_ARGUMENT, "QP recovery projection is empty"
      ) : status;
    status = recovery_copy.validate();
    if (status == null)
      return rdma_status::make(
        RDMA_SC_INVALID_STATE, "QP recovery validation returned null"
      );
    if (!status.ok())
      return status;
    if (!same_qp_plan_value(authoritative_qp.qp_plan,
                            recovery_copy.qp_plan) ||
        !same_context_value(authoritative_qp.qp_plan.context_ref,
                            recovery_copy.context_ref))
      return rdma_status::make(
        RDMA_SC_INVALID_ARGUMENT, "QP recovery authority changed"
      );
    if (recovery_copy.intent inside {
          RDMA_QP_RECOVER_MODIFY_RECONCILE,
          RDMA_QP_RECOVER_NORMAL_DESTROY
        } &&
        !same_qpc_value(recovery_copy.prior_qpc,
                         authoritative_qp.programmed_qpc))
      return rdma_status::make(
        RDMA_SC_INVALID_ARGUMENT,
        "QP recovery prior QPC is not authoritative"
      );
    if (recovery_copy.intent == RDMA_QP_RECOVER_CREATE_ROLLBACK &&
        recovery_copy.candidate_qpc != null &&
        !same_qpc_value(recovery_copy.candidate_qpc,
                         authoritative_qp.programmed_qpc))
      return rdma_status::make(
        RDMA_SC_INVALID_ARGUMENT,
        "QP create recovery candidate QPC is not authoritative"
      );
    if (error_replacement) begin
      existing_recovery = recovery_records[key].qp_recovery;
      progress_changed = 1'b0;
      foreach (existing_recovery.role_complete[i])
        if (existing_recovery.role_complete[i] !=
            recovery_copy.role_complete[i])
          progress_changed = 1'b1;
      if (existing_recovery.ambiguous_operation == RDMA_QP_AMBIG_NONE ||
          existing_recovery.ambiguous_ticket == null ||
          recovery_copy.ambiguous_operation != RDMA_QP_AMBIG_NONE ||
          recovery_copy.ambiguous_ticket != null ||
          recovery_copy.intent != existing_recovery.intent ||
          !same_qpc_value(recovery_copy.prior_qpc,
                           existing_recovery.prior_qpc) ||
          !same_qpc_value(recovery_copy.candidate_qpc,
                           existing_recovery.candidate_qpc) ||
          !same_qp_plan_value(recovery_copy.qp_plan,
                              existing_recovery.qp_plan) ||
          !same_context_value(recovery_copy.context_ref,
                              existing_recovery.context_ref) ||
          !same_mapping_value(recovery_copy.staging_mapping,
                              existing_recovery.staging_mapping) ||
          recovery_copy.staging_mapping != null &&
            !same_owned_mapping_authority(
              recovery_copy.staging_mapping,
              existing_recovery.staging_mapping
            ) ||
          !same_mapping_value(recovery_copy.query_mapping,
                              existing_recovery.query_mapping) ||
          recovery_copy.query_mapping != null &&
            !same_owned_mapping_authority(
              recovery_copy.query_mapping,
              existing_recovery.query_mapping
            ) ||
          !rdma_qp_recovery_opcode_equivalent(
            recovery_copy.create_opcode, existing_recovery.create_opcode
          ) ||
          !rdma_qp_recovery_opcode_equivalent(
            recovery_copy.modify_opcode, existing_recovery.modify_opcode
          ) ||
          !rdma_qp_recovery_opcode_equivalent(
            recovery_copy.delete_opcode, existing_recovery.delete_opcode
          ) ||
          !rdma_qp_recovery_opcode_equivalent(
            recovery_copy.query_opcode, existing_recovery.query_opcode
          ) || progress_changed)
        return rdma_status::make(
          RDMA_SC_INVALID_ARGUMENT,
          "QP ERROR replacement changed retained authority or progress"
        );
    end
    status = project_resource_value(registry[key], "mark QP ERROR resource",
                                    projected);
    if (!status.ok() || !$cast(replacement, projected))
      return status.ok() ? rdma_status::make(
        RDMA_SC_INVALID_STATE, "QP ERROR resource projection failed"
      ) : status;
    replacement.state = RDMA_RESOURCE_ERROR;
    status = replacement.validate();
    if (status == null)
      return rdma_status::make(
        RDMA_SC_INVALID_STATE, "QP ERROR resource validation returned null"
      );
    if (!status.ok())
      return status;

    if (error_replacement) begin
      status = project_recovery_value(
        recovery_records[key], "replace QP ERROR record", record_copy
      );
      if (!status.ok())
        return status;
      record_copy.qp_recovery = recovery_copy;
    end
    else begin
      record_copy = new("qp_recovery_record");
      status = project_handle_value(authoritative.handle, "QP recovery handle",
                                    record_copy.resource_h);
      if (!status.ok())
        return status;
      record_copy.hardware_presence =
        recovery_copy.intent == RDMA_QP_RECOVER_CREATE_ROLLBACK &&
        recovery_copy.ambiguous_operation == RDMA_QP_AMBIG_NONE &&
        recovery_copy.candidate_qpc == null ?
          RDMA_HW_PRESENCE_ABSENT : RDMA_HW_PRESENCE_PRESENT;
      record_copy.primary_status = rdma_status::make(
        RDMA_SC_RECOVERY_REQUIRED, "QP requires lifecycle recovery"
      );
      record_copy.qp_recovery_valid = 1'b1;
      record_copy.qp_recovery = recovery_copy;
    end
    status = record_copy.validate();
    if (status == null)
      return rdma_status::make(
        RDMA_SC_INVALID_STATE, "QP recovery record validation returned null"
      );
    if (!status.ok())
      return status;

    // Durable recovery authority is published before the resource becomes
    // externally observable as ERROR.
    recovery_records[key] = record_copy;
    registry[key] = replacement;
    staged_allocations.delete(key);
    return rdma_status::success();
  endfunction

  protected function rdma_qp_backing_ref qp_plan_ref(
    rdma_qp_backing_plan plan,
    rdma_queue_backing_role_e role
  );
    if (plan == null)
      return null;
    case (role)
      RDMA_QUEUE_ROLE_QP_SQ_RING: return plan.sq_ref;
      RDMA_QUEUE_ROLE_QP_RQ_RING: return plan.rq_ref;
      RDMA_QUEUE_ROLE_QP_SQ_PD: return plan.sq_pd_ref;
      RDMA_QUEUE_ROLE_QP_RQ_PD: return plan.rq_pd_ref;
      default: begin
        foreach (plan.urc_refs[i])
          if (plan.urc_refs[i] != null && plan.urc_refs[i].role == role)
            return plan.urc_refs[i];
      end
    endcase
    return null;
  endfunction

  protected function bit qp_owned_cleanup_role_complete(
    rdma_qp_backing_plan plan,
    rdma_queue_backing_role_e role
  );
    rdma_qp_backing_ref backing_ref;

    if (plan == null)
      return 1'b0;
    if (plan.rq_source_h != null &&
        role inside {RDMA_QUEUE_ROLE_QP_RQ_RING,
                     RDMA_QUEUE_ROLE_QP_RQ_PD})
      return 1'b1;
    backing_ref = qp_plan_ref(plan, role);
    return backing_ref == null ||
           backing_ref.ownership != RDMA_OWNERSHIP_CONTROL_PLANE ||
           backing_ref.cleanup_complete;
  endfunction

  protected function bit qp_cleanup_predecessors_complete(
    rdma_qp_backing_plan plan,
    rdma_queue_backing_role_e role
  );
    bit urc_dsq_complete;
    bit urc_rdsq_complete;
    bit urc_rsq_complete;
    bit rq_pd_complete;
    bit sq_pd_complete;
    bit rq_ring_complete;

    urc_dsq_complete = qp_owned_cleanup_role_complete(
      plan, RDMA_QUEUE_ROLE_QP_URC_DSQ
    );
    urc_rdsq_complete = qp_owned_cleanup_role_complete(
      plan, RDMA_QUEUE_ROLE_QP_URC_RDSQ
    );
    urc_rsq_complete = qp_owned_cleanup_role_complete(
      plan, RDMA_QUEUE_ROLE_QP_URC_RSQ
    );
    rq_pd_complete = qp_owned_cleanup_role_complete(
      plan, RDMA_QUEUE_ROLE_QP_RQ_PD
    );
    sq_pd_complete = qp_owned_cleanup_role_complete(
      plan, RDMA_QUEUE_ROLE_QP_SQ_PD
    );
    rq_ring_complete = qp_owned_cleanup_role_complete(
      plan, RDMA_QUEUE_ROLE_QP_RQ_RING
    );
    case (role)
      RDMA_QUEUE_ROLE_QP_URC_DSQ:
        return 1'b1;
      RDMA_QUEUE_ROLE_QP_URC_RDSQ:
        return urc_dsq_complete;
      RDMA_QUEUE_ROLE_QP_URC_RSQ:
        return urc_dsq_complete && urc_rdsq_complete;
      RDMA_QUEUE_ROLE_QP_RQ_PD:
        return urc_dsq_complete && urc_rdsq_complete && urc_rsq_complete;
      RDMA_QUEUE_ROLE_QP_SQ_PD:
        return urc_dsq_complete && urc_rdsq_complete && urc_rsq_complete &&
               rq_pd_complete;
      RDMA_QUEUE_ROLE_QP_RQ_RING:
        return urc_dsq_complete && urc_rdsq_complete && urc_rsq_complete &&
               rq_pd_complete && sq_pd_complete;
      RDMA_QUEUE_ROLE_QP_SQ_RING:
        return urc_dsq_complete && urc_rdsq_complete && urc_rsq_complete &&
               rq_pd_complete && sq_pd_complete && rq_ring_complete;
      default:
        return 1'b0;
    endcase
  endfunction

  protected function rdma_status qp_progress_snapshots(
    rdma_handle qp_h,
    string operation,
    output string key,
    output rdma_qp resource_copy,
    output rdma_recovery_record recovery_copy,
    output bit has_recovery
  );
    rdma_resource authoritative;
    rdma_resource projected;
    rdma_status status;

    key = "";
    resource_copy = null;
    recovery_copy = null;
    has_recovery = 1'b0;
    status = lookup(qp_h, authoritative);
    if (!status.ok() || authoritative.handle.kind != RDMA_RESOURCE_QP)
      return status.ok() ? rdma_status::make(
        RDMA_SC_INVALID_ARGUMENT, {operation, " target is not a QP"}
      ) : status;
    key = resource_key(authoritative.handle);
    if (!(registry[key].state inside {RDMA_RESOURCE_QUIESCING,
                                      RDMA_RESOURCE_ERROR}))
      return rdma_status::make(
        RDMA_SC_INVALID_STATE,
        {operation, " requires QUIESCING or ERROR QP"}
      );
    status = project_resource_value(registry[key], {operation, " resource"},
                                    projected);
    if (!status.ok() || !$cast(resource_copy, projected) ||
        resource_copy.qp_plan == null)
      return status.ok() ? rdma_status::make(
        RDMA_SC_INVALID_STATE, {operation, " QP plan is missing"}
      ) : status;
    if (registry[key].state == RDMA_RESOURCE_ERROR) begin
      status = recovery_entry_schema_status(key, operation);
      if (!status.ok())
        return status;
      if (!recovery_records.exists(key) ||
          !recovery_records[key].qp_recovery_valid ||
          recovery_records[key].qp_recovery == null)
        return rdma_status::make(
          RDMA_SC_INVALID_STATE, {operation, " QP recovery is missing"}
        );
      status = project_recovery_value(recovery_records[key],
                                      {operation, " recovery"}, recovery_copy);
      if (!status.ok())
        return status;
      has_recovery = 1'b1;
      if (!same_qp_plan_value(resource_copy.qp_plan,
                              recovery_copy.qp_recovery.qp_plan))
        return rdma_status::make(
          RDMA_SC_INVALID_STATE, {operation, " recovery plan diverged"}
        );
    end
    return rdma_status::success();
  endfunction

  protected function rdma_status commit_qp_progress(
    string key,
    rdma_qp resource_copy,
    rdma_recovery_record recovery_copy,
    bit has_recovery,
    string operation
  );
    rdma_status status;

    status = resource_copy.validate();
    if (status == null)
      return rdma_status::make(
        RDMA_SC_INVALID_STATE, {operation, " resource validation returned null"}
      );
    if (!status.ok())
      return status;
    if (has_recovery) begin
      status = recovery_copy.validate();
      if (status == null)
        return rdma_status::make(
          RDMA_SC_INVALID_STATE,
          {operation, " recovery validation returned null"}
        );
      if (!status.ok())
        return status;
    end
    registry[key] = resource_copy;
    if (has_recovery)
      recovery_records[key] = recovery_copy;
    return rdma_status::success();
  endfunction

  virtual function rdma_status record_qp_flush_complete(
    rdma_handle qp_h,
    rdma_queue_backing_role_e role
  );
    rdma_qp resource_copy;
    rdma_recovery_record recovery_copy;
    rdma_qp_backing_plan recovery_plan;
    rdma_status status;
    bit has_recovery;
    bit already_complete;
    string key;

    if (!(role inside {RDMA_QUEUE_ROLE_QP_SQ_RING,
                       RDMA_QUEUE_ROLE_QP_SQ_PD,
                       RDMA_QUEUE_ROLE_QP_RQ_PD}))
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "QP flush role is invalid");
    status = qp_progress_snapshots(qp_h, "QP flush progress", key,
                                   resource_copy, recovery_copy,
                                   has_recovery);
    if (!status.ok())
      return status;
    recovery_plan = has_recovery ? recovery_copy.qp_recovery.qp_plan : null;
    case (role)
      RDMA_QUEUE_ROLE_QP_SQ_RING: begin
        already_complete = resource_copy.qp_plan.cleanup_complete;
        if (!already_complete && has_recovery)
          already_complete = recovery_plan.cleanup_complete;
        if (!already_complete) begin
          resource_copy.qp_plan.cleanup_complete = 1'b1;
          if (has_recovery)
            recovery_plan.cleanup_complete = 1'b1;
        end
      end
      RDMA_QUEUE_ROLE_QP_SQ_PD: begin
        if (!resource_copy.qp_plan.cleanup_complete ||
            has_recovery && !recovery_plan.cleanup_complete)
          return rdma_status::make(
            RDMA_SC_INVALID_STATE, "QP QPN flush predecessor is incomplete"
          );
        already_complete = resource_copy.qp_plan.sq_pd_flush_complete;
        if (!already_complete && has_recovery)
          already_complete = recovery_plan.sq_pd_flush_complete;
        if (!already_complete) begin
          resource_copy.qp_plan.sq_pd_flush_complete = 1'b1;
          if (has_recovery)
            recovery_plan.sq_pd_flush_complete = 1'b1;
        end
      end
      RDMA_QUEUE_ROLE_QP_RQ_PD: begin
        if (resource_copy.qp_plan.rq_source_h != null)
          return rdma_status::make(
            RDMA_SC_INVALID_ARGUMENT, "SRQ-backed QP has no private RQ flush"
          );
        if (!resource_copy.qp_plan.sq_pd_flush_complete ||
            has_recovery && !recovery_plan.sq_pd_flush_complete)
          return rdma_status::make(
            RDMA_SC_INVALID_STATE, "QP SQ PD flush predecessor is incomplete"
          );
        already_complete = resource_copy.qp_plan.rq_pd_flush_complete;
        if (!already_complete && has_recovery)
          already_complete = recovery_plan.rq_pd_flush_complete;
        if (!already_complete) begin
          resource_copy.qp_plan.rq_pd_flush_complete = 1'b1;
          if (has_recovery)
            recovery_plan.rq_pd_flush_complete = 1'b1;
        end
      end
    endcase
    if (already_complete)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "QP flush progress is already complete");
    return commit_qp_progress(key, resource_copy, recovery_copy, has_recovery,
                              "QP flush progress");
  endfunction

  virtual function rdma_status record_qp_cleanup_complete(
    rdma_handle qp_h,
    rdma_queue_backing_role_e role
  );
    rdma_qp resource_copy;
    rdma_recovery_record recovery_copy;
    rdma_qp_backing_ref resource_ref;
    rdma_qp_backing_ref recovery_ref;
    rdma_status status;
    bit has_recovery;
    bit release_complete;
    string key;

    if (!rdma_qp_role_is_payload(role) && !rdma_qp_role_is_pd(role))
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "QP cleanup role is invalid");
    status = qp_progress_snapshots(qp_h, "QP cleanup progress", key,
                                   resource_copy, recovery_copy,
                                   has_recovery);
    if (!status.ok())
      return status;
    resource_ref = qp_plan_ref(resource_copy.qp_plan, role);
    recovery_ref = has_recovery ?
      qp_plan_ref(recovery_copy.qp_recovery.qp_plan, role) : null;
    if (resource_ref == null ||
        resource_ref.ownership != RDMA_OWNERSHIP_CONTROL_PLANE ||
        resource_ref.cleanup_complete ||
        has_recovery && (recovery_ref == null ||
                         recovery_ref.cleanup_complete ||
                         recovery_copy.qp_recovery.role_complete[role]))
      return rdma_status::make(
        RDMA_SC_INVALID_ARGUMENT,
        "QP cleanup role is absent, borrowed, or already complete"
      );
    if (!qp_cleanup_predecessors_complete(resource_copy.qp_plan, role) ||
        has_recovery && !qp_cleanup_predecessors_complete(
          recovery_copy.qp_recovery.qp_plan, role
        ))
      return rdma_status::make(
        RDMA_SC_INVALID_STATE,
        "QP owned backing cleanup predecessor is incomplete"
      );
    if (resource_copy.qp_plan.context_ref == null ||
        !resource_copy.qp_plan.context_ref.release_complete ||
        has_recovery &&
          (recovery_copy.qp_recovery.context_ref == null ||
           !recovery_copy.qp_recovery.context_ref.release_complete ||
           recovery_copy.qp_recovery.qp_plan.context_ref == null ||
           !recovery_copy.qp_recovery.qp_plan.context_ref.release_complete))
      return rdma_status::make(
        RDMA_SC_INVALID_STATE,
        "QP context cleanup must precede owned backing cleanup"
      );
    status = query_owned_release_completion(resource_ref.mapping,
                                            release_complete);
    if (status == null || !status.ok())
      return status == null ? rdma_status::make(
        RDMA_SC_INVALID_STATE,
        "QP backing completion query returned null"
      ) : status;
    if (!release_complete)
      return rdma_status::make(
        RDMA_SC_RECOVERY_REQUIRED,
        "QP backing release is not opaquely complete"
      );
    if (has_recovery) begin
      status = query_owned_release_completion(recovery_ref.mapping,
                                              release_complete);
      if (status == null || !status.ok())
        return status == null ? rdma_status::make(
          RDMA_SC_INVALID_STATE,
          "QP recovery backing completion query returned null"
        ) : status;
      if (!release_complete)
        return rdma_status::make(
          RDMA_SC_RECOVERY_REQUIRED,
          "QP recovery backing release is not opaquely complete"
        );
    end
    resource_ref.cleanup_complete = 1'b1;
    if (has_recovery) begin
      recovery_ref.cleanup_complete = 1'b1;
      recovery_copy.qp_recovery.role_complete[role] = 1'b1;
    end
    return commit_qp_progress(key, resource_copy, recovery_copy, has_recovery,
                              "QP cleanup progress");
  endfunction

  virtual function rdma_status record_qp_context_cleanup_complete(
    rdma_handle qp_h
  );
    rdma_qp resource_copy;
    rdma_recovery_record recovery_copy;
    rdma_queue_slot_token_contract resource_token;
    rdma_queue_slot_token_contract recovery_token;
    rdma_status status;
    bit has_recovery;
    string key;

    status = qp_progress_snapshots(qp_h, "QP context cleanup", key,
                                   resource_copy, recovery_copy,
                                   has_recovery);
    if (!status.ok())
      return status;
    if (resource_copy.qp_plan.context_ref == null ||
        resource_copy.qp_plan.context_ref.release_complete ||
        has_recovery &&
          (recovery_copy.qp_recovery.context_ref == null ||
           recovery_copy.qp_recovery.context_ref.release_complete ||
           recovery_copy.qp_recovery.qp_plan.context_ref == null ||
           recovery_copy.qp_recovery.qp_plan.context_ref.release_complete))
      return rdma_status::make(
        RDMA_SC_INVALID_ARGUMENT,
        "QP context cleanup is absent or already complete"
      );
    if (!resource_copy.qp_plan.cleanup_complete ||
        !resource_copy.qp_plan.sq_pd_flush_complete ||
        resource_copy.qp_plan.rq_source_h == null &&
          !resource_copy.qp_plan.rq_pd_flush_complete ||
        has_recovery &&
          (!recovery_copy.qp_recovery.qp_plan.cleanup_complete ||
           !recovery_copy.qp_recovery.qp_plan.sq_pd_flush_complete ||
           recovery_copy.qp_recovery.qp_plan.rq_source_h == null &&
             !recovery_copy.qp_recovery.qp_plan.rq_pd_flush_complete))
      return rdma_status::make(
        RDMA_SC_INVALID_STATE,
        "QP required flushes must precede context cleanup"
      );
    if (has_recovery &&
        (recovery_copy.qp_recovery.ambiguous_operation !=
           RDMA_QP_AMBIG_NONE ||
         recovery_copy.qp_recovery.ambiguous_ticket != null))
      return rdma_status::make(
        RDMA_SC_RECOVERY_REQUIRED,
        "QP recovery ambiguity must be resolved before context cleanup"
      );
    if (!$cast(resource_token,
               resource_copy.qp_plan.context_ref.slot_token) ||
        resource_token.completion_authority == null)
      return rdma_status::make(
        RDMA_SC_INVALID_ARGUMENT,
        "QP context completion authority is invalid"
      );
    if (!resource_token.completion_authority.complete)
      return rdma_status::make(
        RDMA_SC_RECOVERY_REQUIRED,
        "QP context release is not opaquely complete"
      );
    if (has_recovery) begin
      if (!$cast(recovery_token,
                 recovery_copy.qp_recovery.context_ref.slot_token) ||
          recovery_token.completion_authority == null ||
          recovery_token.completion_authority !==
            resource_token.completion_authority)
        return rdma_status::make(
          RDMA_SC_INVALID_ARGUMENT,
          "QP recovery context completion authority changed"
        );
      if (!recovery_token.completion_authority.complete)
        return rdma_status::make(
          RDMA_SC_RECOVERY_REQUIRED,
          "QP recovery context release is not opaquely complete"
        );
    end
    resource_copy.qp_plan.context_ref.release_complete = 1'b1;
    if (has_recovery) begin
      recovery_copy.qp_recovery.context_ref.release_complete = 1'b1;
      recovery_copy.qp_recovery.qp_plan.context_ref.release_complete = 1'b1;
      recovery_copy.hardware_presence = RDMA_HW_PRESENCE_ABSENT;
    end
    return commit_qp_progress(key, resource_copy, recovery_copy, has_recovery,
                              "QP context cleanup");
  endfunction

  protected function bit qp_plan_cleanup_ready(rdma_qp_backing_plan plan);
    rdma_qp_backing_ref refs[$];
    rdma_queue_slot_token_contract token;
    rdma_status status;
    bit release_complete;

    if (plan == null || !plan.cleanup_complete ||
        !plan.sq_pd_flush_complete ||
        (plan.rq_source_h == null && !plan.rq_pd_flush_complete) ||
        plan.context_ref == null || !plan.context_ref.release_complete ||
        !$cast(token, plan.context_ref.slot_token) ||
        token.completion_authority == null ||
        !token.completion_authority.complete)
      return 1'b0;
    refs.push_back(plan.sq_ref);
    refs.push_back(plan.sq_pd_ref);
    if (plan.rq_source_h == null) begin
      refs.push_back(plan.rq_ref);
      refs.push_back(plan.rq_pd_ref);
    end
    foreach (plan.urc_refs[i])
      refs.push_back(plan.urc_refs[i]);
    foreach (refs[i]) begin
      if (refs[i] == null)
        return 1'b0;
      if (refs[i].ownership == RDMA_OWNERSHIP_CONTROL_PLANE &&
          !refs[i].cleanup_complete)
        return 1'b0;
      if (refs[i].ownership == RDMA_OWNERSHIP_CONTROL_PLANE) begin
        status = query_owned_release_completion(refs[i].mapping,
                                                release_complete);
        if (status == null || !status.ok() || !release_complete)
          return 1'b0;
      end
      if (refs[i].ownership == RDMA_OWNERSHIP_BORROWED &&
          refs[i].cleanup_complete)
        return 1'b0;
    end
    return 1'b1;
  endfunction

  virtual function rdma_status finalize_qp_release(rdma_handle qp_h);
    rdma_resource authoritative;
    rdma_qp authoritative_qp;
    rdma_recovery_record recovery;
    rdma_queue_slot_token_contract resource_context_token;
    rdma_queue_slot_token_contract recovery_context_token;
    rdma_queue_slot_token_contract recovery_plan_context_token;
    rdma_status status;
    bit release_complete;
    string key;

    status = registry_schema_status("finalize QP release");
    if (!status.ok())
      return status;
    status = lookup(qp_h, authoritative);
    if (!status.ok() || !$cast(authoritative_qp, authoritative))
      return status.ok() ? rdma_status::make(
        RDMA_SC_INVALID_ARGUMENT, "QP finalization target is not a QP"
      ) : status;
    key = resource_key(authoritative.handle);
    if (registry[key].state == RDMA_RESOURCE_ALLOCATED &&
        authoritative_qp.qp_plan == null &&
        authoritative_qp.programmed_qpc == null) begin
      if (has_dependents(registry[key]) ||
          registry[key].outstanding_ids.size() != 0)
        return rdma_status::make(RDMA_SC_RESOURCE_BUSY,
                                 "QP reservation is still busy");
      force_release_key(key);
      return rdma_status::success();
    end
    if (!(registry[key].state inside {RDMA_RESOURCE_QUIESCING,
                                      RDMA_RESOURCE_ERROR}))
      return rdma_status::make(
        RDMA_SC_INVALID_STATE,
        "QP finalization requires QUIESCING, ERROR, or empty reservation"
      );
    if (!qp_plan_cleanup_ready(authoritative_qp.qp_plan))
      return rdma_status::make(
        RDMA_SC_RECOVERY_REQUIRED, "QP cleanup is not complete"
      );
    if (registry[key].state == RDMA_RESOURCE_ERROR) begin
      status = recovery_entry_schema_status(key, "finalize QP release");
      if (!status.ok())
        return status;
      if (!recovery_records.exists(key))
        return rdma_status::make(RDMA_SC_RECOVERY_REQUIRED,
                                 "ERROR QP recovery is missing");
      recovery = recovery_records[key];
      if (recovery.hardware_presence != RDMA_HW_PRESENCE_ABSENT)
        return rdma_status::make(
          RDMA_SC_RECOVERY_REQUIRED,
          "ERROR QP hardware absence is not established"
        );
      if (recovery.qp_recovery == null ||
          recovery.qp_recovery.context_ref == null ||
          recovery.qp_recovery.qp_plan == null ||
          recovery.qp_recovery.qp_plan.context_ref == null ||
          !$cast(resource_context_token,
                 authoritative_qp.qp_plan.context_ref.slot_token) ||
          !$cast(recovery_context_token,
                 recovery.qp_recovery.context_ref.slot_token) ||
          !$cast(recovery_plan_context_token,
                 recovery.qp_recovery.qp_plan.context_ref.slot_token) ||
          resource_context_token.completion_authority == null ||
          recovery_context_token.completion_authority == null ||
          recovery_plan_context_token.completion_authority == null ||
          recovery_context_token.completion_authority !==
            resource_context_token.completion_authority ||
          recovery_plan_context_token.completion_authority !==
            resource_context_token.completion_authority)
        return rdma_status::make(
          RDMA_SC_INVALID_ARGUMENT,
          "QP recovery context completion authority changed"
        );
      if (!recovery_context_token.completion_authority.complete)
        return rdma_status::make(
          RDMA_SC_RECOVERY_REQUIRED,
          "QP recovery context release is not opaquely complete"
        );
      if (!recovery.qp_recovery_valid || recovery.qp_recovery == null ||
          recovery.qp_recovery.ambiguous_operation != RDMA_QP_AMBIG_NONE ||
          recovery.qp_recovery.ambiguous_ticket != null ||
          !qp_plan_cleanup_ready(recovery.qp_recovery.qp_plan) ||
          recovery.qp_recovery.context_ref == null ||
          !recovery.qp_recovery.context_ref.release_complete)
        return rdma_status::make(
          RDMA_SC_RECOVERY_REQUIRED, "QP recovery cleanup is not complete"
        );
      if (recovery.qp_recovery.staging_mapping != null) begin
        status = query_owned_release_completion(
          recovery.qp_recovery.staging_mapping, release_complete
        );
        if (status == null || !status.ok() || !release_complete)
          return rdma_status::make(
            RDMA_SC_RECOVERY_REQUIRED,
            "QP recovery staging release is not complete"
          );
      end
      if (recovery.qp_recovery.query_mapping != null) begin
        status = query_owned_release_completion(
          recovery.qp_recovery.query_mapping, release_complete
        );
        if (status == null || !status.ok() || !release_complete)
          return rdma_status::make(
            RDMA_SC_RECOVERY_REQUIRED,
            "QP recovery query release is not complete"
          );
      end
    end
    if (has_dependents(registry[key]) ||
        registry[key].outstanding_ids.size() != 0)
      return rdma_status::make(
        RDMA_SC_RESOURCE_BUSY,
        "QP still has live dependents or outstanding operations"
      );
    force_release_key(key);
    return rdma_status::success();
  endfunction

  protected function rdma_status queue_progress_snapshots(
    rdma_handle handle,
    string operation,
    output string key,
    output rdma_resource resource_copy,
    output rdma_recovery_record recovery_copy,
    output bit has_recovery
  );
    rdma_resource authoritative;
    rdma_queue_resource queue_resource;
    rdma_status status;

    key = "";
    resource_copy = null;
    recovery_copy = null;
    has_recovery = 1'b0;
    status = lookup(handle, authoritative);
    if (!status.ok()) return status;
    key = resource_key(authoritative.handle);
    if (!(authoritative.handle.kind inside {RDMA_RESOURCE_CQ, RDMA_RESOURCE_SRQ,
                                            RDMA_RESOURCE_CEQ, RDMA_RESOURCE_AEQ}) ||
        !(registry[key].state inside {RDMA_RESOURCE_QUIESCING,
                                      RDMA_RESOURCE_ERROR}))
      return rdma_status::make(RDMA_SC_INVALID_STATE,
                               "queue progress requires QUIESCING or ERROR queue");
    status = project_resource_value(registry[key], {operation, " resource"},
                                    resource_copy);
    if (!status.ok() || !$cast(queue_resource, resource_copy) ||
        queue_resource.queue_plan == null)
      return status.ok() ? rdma_status::make(
        RDMA_SC_INVALID_STATE, "queue progress resource plan is missing"
      ) : status;
    status = queue_resource.queue_plan.validate();
    if (status == null)
      return rdma_status::make(RDMA_SC_INVALID_STATE,
                               "queue progress plan validation returned null");
    if (!status.ok()) return status;
    if (registry[key].state == RDMA_RESOURCE_ERROR) begin
      if (!recovery_records.exists(key))
        return rdma_status::make(RDMA_SC_INVALID_STATE,
                                 "ERROR queue has no recovery record");
      status = project_recovery_value(recovery_records[key],
                                      {operation, " recovery"}, recovery_copy);
      if (!status.ok()) return status;
      if (recovery_copy == null || !recovery_copy.queue_recovery_valid ||
          recovery_copy.queue_plan == null ||
          recovery_copy.queue_plan.resource_kind != authoritative.handle.kind)
        return rdma_status::make(RDMA_SC_INVALID_STATE,
                                 "ERROR queue recovery schema is incomplete");
      status = recovery_copy.validate();
      if (status == null)
        return rdma_status::make(RDMA_SC_INVALID_STATE,
                                 "queue recovery validation returned null");
      if (!status.ok()) return status;
      has_recovery = 1'b1;
    end
    return rdma_status::success();
  endfunction

  protected function rdma_status commit_queue_progress(
    string key,
    rdma_resource resource_copy,
    rdma_recovery_record recovery_copy,
    bit has_recovery,
    string operation
  );
    rdma_status status;

    status = resource_copy.validate();
    if (status == null)
      return rdma_status::make(RDMA_SC_INVALID_STATE,
                               "queue progress resource validation returned null");
    if (!status.ok()) return status;
    if (has_recovery) begin
      status = recovery_copy.validate();
      if (status == null)
        return rdma_status::make(RDMA_SC_INVALID_STATE,
                                 "queue progress recovery validation returned null");
      if (!status.ok()) return status;
    end
    // Both complete snapshots have passed validation; publish them together at
    // the single authoritative replacement point.
    registry[key] = resource_copy;
    if (has_recovery)
      recovery_records[key] = recovery_copy;
    return rdma_status::success();
  endfunction

  virtual function rdma_status record_queue_flush_complete(
    rdma_handle handle,
    rdma_queue_backing_role_e role
  );
    rdma_resource resource_copy;
    rdma_recovery_record recovery_copy;
    rdma_queue_resource resource_queue;
    int unsigned role_count;
    int unsigned target_index;
    int unsigned recovery_role_count;
    int unsigned recovery_target_index;
    rdma_status status;
    bit has_recovery;
    string key;

    status = queue_progress_snapshots(handle, "queue flush progress", key,
                                      resource_copy, recovery_copy, has_recovery);
    if (!status.ok()) return status;
    if (!$cast(resource_queue, resource_copy))
      return rdma_status::make(RDMA_SC_INVALID_STATE, "queue resource cast failed");
    role_count = 0;
    foreach (resource_queue.queue_plan.flush_targets[i]) begin
      if (resource_queue.queue_plan.flush_targets[i] != null &&
          resource_queue.queue_plan.flush_targets[i].role == role) begin
        role_count++;
        target_index = i;
      end
    end
    recovery_role_count = 0;
    if (has_recovery) begin
      foreach (recovery_copy.queue_plan.flush_targets[i]) begin
        if (recovery_copy.queue_plan.flush_targets[i] != null &&
            recovery_copy.queue_plan.flush_targets[i].role == role) begin
          recovery_role_count++;
          recovery_target_index = i;
        end
      end
      if (recovery_role_count != 1 ||
          recovery_copy.queue_plan.flush_targets[recovery_target_index].flush_complete ||
          recovery_copy.queue_plan.flush_targets[recovery_target_index].pd_ref == null ||
          resource_queue.queue_plan.flush_targets[target_index].pd_ref == null ||
          !same_mapping_value(
            recovery_copy.queue_plan.flush_targets[recovery_target_index].pd_ref.mapping,
            resource_queue.queue_plan.flush_targets[target_index].pd_ref.mapping
          ))
        return rdma_status::make(RDMA_SC_INVALID_STATE,
                                 "recovery flush role authority diverged");
    end
    if (role_count != 1 || resource_queue.queue_plan.flush_targets[target_index].flush_complete)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "queue flush role is absent, duplicated, or complete");
    foreach (resource_queue.queue_plan.flush_targets[i]) begin
      int unsigned recovery_predecessor_count;

      if (i >= target_index)
        continue;
      if (!resource_queue.queue_plan.flush_targets[i].flush_complete)
        return rdma_status::make(RDMA_SC_INVALID_STATE,
                                 "queue flush predecessor is incomplete");
      if (has_recovery) begin
        recovery_predecessor_count = 0;
        foreach (recovery_copy.queue_plan.flush_targets[j]) begin
          if (recovery_copy.queue_plan.flush_targets[j] != null &&
              recovery_copy.queue_plan.flush_targets[j].role ==
                resource_queue.queue_plan.flush_targets[i].role) begin
            recovery_predecessor_count++;
            if (!recovery_copy.queue_plan.flush_targets[j].flush_complete)
              return rdma_status::make(
                RDMA_SC_INVALID_STATE,
                "recovery queue flush predecessor is incomplete"
              );
          end
        end
        if (recovery_predecessor_count != 1)
          return rdma_status::make(
            RDMA_SC_INVALID_STATE,
            "recovery queue flush predecessor is absent or duplicated"
          );
      end
    end
    resource_queue.queue_plan.flush_targets[target_index].flush_complete = 1'b1;
    if (has_recovery)
      recovery_copy.queue_plan.flush_targets[recovery_target_index].flush_complete = 1'b1;
    return commit_queue_progress(key, resource_copy, recovery_copy, has_recovery,
                                 "queue flush progress");
  endfunction

  virtual function rdma_status record_queue_cleanup_complete(
    rdma_handle handle,
    rdma_queue_backing_role_e role
  );
    rdma_resource resource_copy;
    rdma_recovery_record recovery_copy;
    rdma_queue_resource resource_queue;
    int unsigned role_count;
    int unsigned ref_index;
    int unsigned recovery_role_count;
    int unsigned recovery_ref_index;
    rdma_status status;
    bit has_recovery;
    int unsigned srfq_flush_count;
    int unsigned recovery_srfq_flush_count;
    bit srfq_flush_complete;
    bit recovery_srfq_flush_complete;
    string key;

    status = queue_progress_snapshots(handle, "queue cleanup progress", key,
                                      resource_copy, recovery_copy, has_recovery);
    if (!status.ok()) return status;
    if (!$cast(resource_queue, resource_copy))
      return rdma_status::make(RDMA_SC_INVALID_STATE, "queue resource cast failed");
    role_count = 0;
    foreach (resource_queue.queue_plan.refs[i]) begin
      if (resource_queue.queue_plan.refs[i] != null &&
          resource_queue.queue_plan.refs[i].role == role) begin
        role_count++;
        ref_index = i;
      end
    end
    recovery_role_count = 0;
    if (has_recovery) begin
      foreach (recovery_copy.queue_plan.refs[i]) begin
        if (recovery_copy.queue_plan.refs[i] != null &&
            recovery_copy.queue_plan.refs[i].role == role) begin
          recovery_role_count++;
          recovery_ref_index = i;
        end
      end
      if (recovery_role_count != 1 ||
          recovery_copy.queue_plan.refs[recovery_ref_index].cleanup_complete ||
          recovery_copy.queue_plan.refs[recovery_ref_index].ownership !=
            RDMA_OWNERSHIP_CONTROL_PLANE ||
          !same_queue_backing_ref_value(
            recovery_copy.queue_plan.refs[recovery_ref_index],
            resource_queue.queue_plan.refs[ref_index]
          ) ||
          !same_owned_queue_backing_ref_authority(
            resource_queue.queue_plan.refs[ref_index],
            recovery_copy.queue_plan.refs[recovery_ref_index]
          ))
        return rdma_status::make(RDMA_SC_INVALID_STATE,
                                 "recovery cleanup role authority diverged");
    end
    if (role_count != 1 || resource_queue.queue_plan.refs[ref_index].cleanup_complete ||
        resource_queue.queue_plan.refs[ref_index].ownership !=
          RDMA_OWNERSHIP_CONTROL_PLANE)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "queue cleanup role is not uniquely owned and pending");
    if (role == RDMA_QUEUE_ROLE_SRQ_SGB) begin
      srfq_flush_count = 0;
      srfq_flush_complete = 1'b0;
      foreach (resource_queue.queue_plan.flush_targets[i]) begin
        if (resource_queue.queue_plan.flush_targets[i] != null &&
            resource_queue.queue_plan.flush_targets[i].role ==
              RDMA_QUEUE_ROLE_SRFQ_PD) begin
          srfq_flush_count++;
          srfq_flush_complete =
            resource_queue.queue_plan.flush_targets[i].flush_complete;
        end
      end
      if (srfq_flush_count != 1 || !srfq_flush_complete)
        return rdma_status::make(
          RDMA_SC_INVALID_STATE,
          "SRQ SGB cleanup requires authoritative SRFQ flush completion"
        );
      if (has_recovery) begin
        recovery_srfq_flush_count = 0;
        recovery_srfq_flush_complete = 1'b0;
        foreach (recovery_copy.queue_plan.flush_targets[i]) begin
          if (recovery_copy.queue_plan.flush_targets[i] != null &&
              recovery_copy.queue_plan.flush_targets[i].role ==
                RDMA_QUEUE_ROLE_SRFQ_PD) begin
            recovery_srfq_flush_count++;
            recovery_srfq_flush_complete =
              recovery_copy.queue_plan.flush_targets[i].flush_complete;
          end
        end
        if (recovery_srfq_flush_count != 1 ||
            !recovery_srfq_flush_complete)
          return rdma_status::make(
            RDMA_SC_INVALID_STATE,
            "SRQ SGB cleanup requires recovery SRFQ flush completion"
          );
      end
    end
    resource_queue.queue_plan.refs[ref_index].cleanup_complete = 1'b1;
    if (has_recovery)
      recovery_copy.queue_plan.refs[recovery_ref_index].cleanup_complete = 1'b1;
    return commit_queue_progress(key, resource_copy, recovery_copy, has_recovery,
                                 "queue cleanup progress");
  endfunction

  virtual function rdma_status record_queue_context_cleanup_complete(
    rdma_handle handle
  );
    rdma_resource resource_copy;
    rdma_recovery_record recovery_copy;
    rdma_queue_resource resource_queue;
    rdma_status status;
    bit has_recovery;
    string key;

    status = queue_progress_snapshots(handle, "queue context progress", key,
                                      resource_copy, recovery_copy, has_recovery);
    if (!status.ok()) return status;
    if (!$cast(resource_queue, resource_copy) ||
        resource_queue.queue_plan.context_ref == null ||
        resource_queue.queue_plan.context_ref.release_complete)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "queue context cleanup is absent or complete");
    // Context release is the first local action, so its completion bit must
    // stand on its own.  In particular, SRQ payload roles are released after
    // this call; requiring SGB progress here would either invert the recipe
    // or leave an already-released context unrecorded during recovery.
    resource_queue.queue_plan.context_ref.release_complete = 1'b1;
    if (has_recovery) begin
      recovery_copy.queue_plan.context_ref.release_complete = 1'b1;
    end
    return commit_queue_progress(key, resource_copy, recovery_copy, has_recovery,
                                 "queue context progress");
  endfunction

  // Queue recovery metadata is retired immediately after the ACTIVE
  // replacement is published.  Keep a protected observation point at the
  // atomic boundary so derived managers can audit the prepared metadata
  // without extending its lifetime or changing publication ordering.
  protected virtual function void queue_restore_pre_publish_observer(
    rdma_recovery_record prepared_recovery
  );
  endfunction

  // This protected boundary observes detached queue replacements only.  It is
  // intentionally before their final validation and never exposes a live
  // registry or recovery-record object to the caller.
  protected virtual function void queue_restore_pre_validate_observer(
    rdma_resource prepared_resource
  );
  endfunction

  virtual function rdma_status restore_active(rdma_handle handle);
    rdma_resource authoritative;
    rdma_resource replacement;
    rdma_recovery_record recovery;
    rdma_recovery_record recovery_replacement;
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
      if (authoritative.handle.kind == RDMA_RESOURCE_MR) begin
      if (staged_allocations.exists(key) || !recovery_records.exists(key))
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
      else if (authoritative.handle.kind inside {RDMA_RESOURCE_CQ,
                                                  RDMA_RESOURCE_SRQ,
                                                  RDMA_RESOURCE_CEQ,
                                                  RDMA_RESOURCE_AEQ}) begin
        rdma_queue_resource authoritative_queue;
        bit destructive_cleanup;
        int unsigned recovery_ref_count;
        bit release_complete;

        if (staged_allocations.exists(key) || !recovery_records.exists(key))
          return rdma_status::make(
            RDMA_SC_INVALID_STATE,
            "ERROR queue restore requires an unstaged queue recovery record"
          );
        recovery = recovery_records[key];
        if (recovery == null || !recovery.queue_recovery_valid ||
            recovery.hardware_presence != RDMA_HW_PRESENCE_PRESENT ||
            recovery.ambiguous_ticket != null || recovery.queue_plan == null ||
            recovery.queue_plan.resource_kind != authoritative.handle.kind)
          return rdma_status::make(
            RDMA_SC_INVALID_STATE,
            "ERROR queue recovery is not present and unambiguous"
          );
        destructive_cleanup = recovery.queue_plan.context_ref != null &&
                              recovery.queue_plan.context_ref.release_complete;
        foreach (recovery.queue_plan.refs[i]) begin
          if (recovery.queue_plan.refs[i] != null &&
              recovery.queue_plan.refs[i].cleanup_complete)
            destructive_cleanup = 1'b1;
        end
        if (destructive_cleanup)
          return rdma_status::make(
            RDMA_SC_INVALID_STATE,
            "ERROR queue recovery includes destructive local cleanup"
          );
        if (!$cast(authoritative_queue, registry[key]) ||
            authoritative_queue.queue_plan == null ||
            authoritative_queue.queue_plan.refs.size() !=
              recovery.queue_plan.refs.size() ||
            ((authoritative_queue.queue_plan.context_ref == null) !=
             (recovery.queue_plan.context_ref == null)))
          return rdma_status::make(
            RDMA_SC_INVALID_STATE,
            "ERROR queue authoritative plan diverged from recovery"
          );
        foreach (authoritative_queue.queue_plan.refs[i]) begin
          recovery_ref_count = 0;
          foreach (recovery.queue_plan.refs[j]) begin
            if (recovery.queue_plan.refs[j] != null &&
                authoritative_queue.queue_plan.refs[i] != null &&
                recovery.queue_plan.refs[j].role ==
                  authoritative_queue.queue_plan.refs[i].role) begin
              recovery_ref_count++;
              if (recovery.queue_plan.refs[j].cleanup_complete ||
                  authoritative_queue.queue_plan.refs[i].cleanup_complete ||
                  !same_queue_backing_ref_value(
                    recovery.queue_plan.refs[j],
                    authoritative_queue.queue_plan.refs[i]
                  ) ||
                  recovery.queue_plan.refs[j].mapping == null ||
                  recovery.queue_plan.refs[j].mapping.state != RDMA_MAPPING_ACTIVE)
                return rdma_status::make(
                  RDMA_SC_INVALID_STATE,
                  "ERROR queue backing cleanup or authority changed"
                );
              if (recovery.queue_plan.refs[j].ownership ==
                    RDMA_OWNERSHIP_CONTROL_PLANE) begin
                if (!same_owned_queue_backing_ref_authority(
                      authoritative_queue.queue_plan.refs[i],
                      recovery.queue_plan.refs[j]
                    ))
                  return rdma_status::make(
                    RDMA_SC_INVALID_STATE,
                    "ERROR queue owned backing release authority changed"
                  );
                status = query_owned_release_completion(
                  recovery.queue_plan.refs[j].mapping, release_complete
                );
                if (status == null || !status.ok() || release_complete)
                  return rdma_status::make(
                    RDMA_SC_INVALID_STATE,
                    "ERROR queue recovery backing was released"
                  );
                status = query_owned_release_completion(
                  authoritative_queue.queue_plan.refs[i].mapping, release_complete
                );
                if (status == null || !status.ok() || release_complete)
                  return rdma_status::make(
                    RDMA_SC_INVALID_STATE,
                    "ERROR queue authoritative backing was released"
                  );
                foreach (recovery.queue_plan.refs[j].additional_segments[k]) begin
                  if (recovery.queue_plan.refs[j].additional_segments[k] == null ||
                      authoritative_queue.queue_plan.refs[i].
                        additional_segments[k] == null ||
                      recovery.queue_plan.refs[j].additional_segments[k].mapping ==
                        null ||
                      authoritative_queue.queue_plan.refs[i].
                        additional_segments[k].mapping == null ||
                      recovery.queue_plan.refs[j].additional_segments[k].
                        mapping.state != RDMA_MAPPING_ACTIVE ||
                      authoritative_queue.queue_plan.refs[i].
                        additional_segments[k].mapping.state !=
                          RDMA_MAPPING_ACTIVE)
                    return rdma_status::make(
                      RDMA_SC_INVALID_STATE,
                      "ERROR queue backing segment authority changed"
                    );
                  status = query_owned_release_completion(
                    recovery.queue_plan.refs[j].additional_segments[k].mapping,
                    release_complete
                  );
                  if (status == null || !status.ok() || release_complete)
                    return rdma_status::make(
                      RDMA_SC_INVALID_STATE,
                      "ERROR queue recovery backing segment was released"
                    );
                  status = query_owned_release_completion(
                    authoritative_queue.queue_plan.refs[i].
                      additional_segments[k].mapping,
                    release_complete
                  );
                  if (status == null || !status.ok() || release_complete)
                    return rdma_status::make(
                      RDMA_SC_INVALID_STATE,
                      "ERROR queue authoritative backing segment was released"
                    );
                end
              end
            end
          end
          if (recovery_ref_count != 1)
            return rdma_status::make(RDMA_SC_INVALID_STATE,
                                     "ERROR queue backing role is not unique");
        end
        if (recovery.queue_plan.context_ref != null &&
            (recovery.queue_plan.context_ref.release_complete ||
             authoritative_queue.queue_plan.context_ref.release_complete ||
             recovery.queue_plan.context_ref.hmc_ref == null ||
             authoritative_queue.queue_plan.context_ref.hmc_ref == null ||
             recovery.queue_plan.context_ref.hmc_ref.release_complete ||
             authoritative_queue.queue_plan.context_ref.hmc_ref.release_complete ||
             recovery.queue_plan.context_ref.hmc_ref.address !=
               authoritative_queue.queue_plan.context_ref.hmc_ref.address ||
             recovery.queue_plan.context_ref.hmc_ref.size !=
               authoritative_queue.queue_plan.context_ref.hmc_ref.size))
          return rdma_status::make(
            RDMA_SC_INVALID_STATE,
            "ERROR queue context cleanup or authority changed"
          );
        status = project_recovery_value(recovery, "restore queue recovery",
                                        recovery_replacement);
        if (!status.ok() || recovery_replacement == null)
          return status.ok() ? rdma_status::make(
            RDMA_SC_INVALID_STATE, "ERROR queue recovery replacement is missing"
          ) : status;
        recovery_replacement.ambiguous_queue_operation = RDMA_QUEUE_AMBIG_NONE;
        recovery_replacement.ambiguous_role = RDMA_QUEUE_ROLE_CQ_RING;
        recovery_replacement.ambiguous_ticket = null;
        if (authoritative.handle.kind == RDMA_RESOURCE_SRQ) begin
          foreach (recovery_replacement.queue_plan.flush_targets[i])
            recovery_replacement.queue_plan.flush_targets[i].flush_complete = 1'b0;
        end
        status = recovery_replacement.validate();
        if (status == null)
          return rdma_status::make(
            RDMA_SC_INVALID_STATE,
            "restored queue recovery validation returned null"
          );
        if (!status.ok())
          return status;
      end
      else
        return rdma_status::make(RDMA_SC_INVALID_STATE,
                                 "ERROR restore supports MR or lifecycle queue only");
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
    if (authoritative.state == RDMA_RESOURCE_ERROR &&
        authoritative.handle.kind inside {RDMA_RESOURCE_CQ, RDMA_RESOURCE_SRQ,
                                          RDMA_RESOURCE_CEQ, RDMA_RESOURCE_AEQ}) begin
      rdma_queue_resource queue_replacement;
      rdma_queue_backing_plan restored_plan;

      if (!$cast(queue_replacement, replacement))
        return rdma_status::make(RDMA_SC_INVALID_STATE,
                                 "restored queue resource type mismatch");
      status = project_queue_plan_value(recovery_replacement.queue_plan,
                                        "restore active queue plan",
                                        restored_plan);
      if (!status.ok() || restored_plan == null)
        return status.ok() ? rdma_status::make(
          RDMA_SC_INVALID_STATE, "restored queue plan is missing"
        ) : status;
      queue_replacement.queue_plan = restored_plan;
      if (authoritative.handle.kind == RDMA_RESOURCE_SRQ) begin
        foreach (queue_replacement.queue_plan.flush_targets[i])
          queue_replacement.queue_plan.flush_targets[i].flush_complete = 1'b0;
      end
      replacement = queue_replacement;
    end
    // A failed pre-delete SRQ flush may leave the first progress bit set;
    // restoring ACTIVE is permitted only for definitive no-change failures,
    // and must clear all pre-delete progress so the next destroy retries both
    // commands from a clean authority snapshot.
    if (authoritative.state == RDMA_RESOURCE_QUIESCING &&
        authoritative.handle.kind == RDMA_RESOURCE_SRQ) begin
      rdma_queue_resource queue_replacement;
      if (!$cast(queue_replacement, replacement) ||
          queue_replacement.queue_plan == null)
        return rdma_status::make(RDMA_SC_INVALID_STATE,
                                 "restored SRQ plan is missing");
      foreach (queue_replacement.queue_plan.flush_targets[i])
        queue_replacement.queue_plan.flush_targets[i].flush_complete = 1'b0;
      replacement = queue_replacement;
    end
    replacement.state = RDMA_RESOURCE_ACTIVE;
    if (authoritative.state == RDMA_RESOURCE_ERROR &&
        authoritative.handle.kind inside {RDMA_RESOURCE_CQ, RDMA_RESOURCE_SRQ,
                                          RDMA_RESOURCE_CEQ, RDMA_RESOURCE_AEQ})
      queue_restore_pre_validate_observer(replacement);
    status = replacement.validate();
    if (status == null)
      return rdma_status::make(RDMA_SC_INVALID_STATE,
                               "restored resource validation returned null");
    if (!status.ok())
      return status;
    if (authoritative.state == RDMA_RESOURCE_ERROR &&
        authoritative.handle.kind inside {RDMA_RESOURCE_CQ, RDMA_RESOURCE_SRQ,
                                          RDMA_RESOURCE_CEQ, RDMA_RESOURCE_AEQ})
      queue_restore_pre_publish_observer(recovery_replacement);
    registry[key] = replacement;
    if (authoritative.state == RDMA_RESOURCE_ERROR)
      recovery_records.delete(key);
    return rdma_status::success();
  endfunction

  // Compare the durable progress portion of two recovery snapshots.  Calls
  // that merely re-publish an identical ERROR snapshot are rejected, while a
  // changed pending/completed bit or cleanup proof is accepted atomically.
  protected function bit same_queue_recovery_progress(
    rdma_recovery_record lhs,
    rdma_recovery_record rhs
  );
    if (lhs == null || rhs == null)
      return 1'b0;
    if (lhs.completed_steps.size() != rhs.completed_steps.size() ||
        lhs.pending_steps.size() != rhs.pending_steps.size() ||
        lhs.rollback_statuses.size() != rhs.rollback_statuses.size())
      return 1'b0;
    foreach (lhs.completed_steps[i])
      if (lhs.completed_steps[i] != rhs.completed_steps[i]) return 1'b0;
    foreach (lhs.pending_steps[i])
      if (lhs.pending_steps[i] != rhs.pending_steps[i]) return 1'b0;
    if (lhs.queue_plan == null || rhs.queue_plan == null)
      return lhs.queue_plan == rhs.queue_plan;
    if (lhs.queue_plan.refs.size() != rhs.queue_plan.refs.size() ||
        lhs.queue_plan.flush_targets.size() != rhs.queue_plan.flush_targets.size())
      return 1'b0;
    foreach (lhs.queue_plan.refs[i]) begin
      if (lhs.queue_plan.refs[i] == null || rhs.queue_plan.refs[i] == null ||
          lhs.queue_plan.refs[i].cleanup_complete !=
            rhs.queue_plan.refs[i].cleanup_complete)
        return 1'b0;
    end
    foreach (lhs.queue_plan.flush_targets[i]) begin
      if (lhs.queue_plan.flush_targets[i] == null ||
          rhs.queue_plan.flush_targets[i] == null ||
          lhs.queue_plan.flush_targets[i].flush_complete !=
            rhs.queue_plan.flush_targets[i].flush_complete)
        return 1'b0;
    end
    if ((lhs.queue_plan.context_ref == null) !=
        (rhs.queue_plan.context_ref == null)) return 1'b0;
    if (lhs.queue_plan.context_ref != null &&
        lhs.queue_plan.context_ref.release_complete !=
          rhs.queue_plan.context_ref.release_complete) return 1'b0;
    return 1'b1;
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
    if (trusted_handle != null &&
        trusted_handle.kind == RDMA_RESOURCE_QP)
      return rdma_status::make(
        RDMA_SC_INVALID_STATE,
        "QP resources require QP-specific ERROR publication"
      );
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
    if (replacement.handle.kind inside {RDMA_RESOURCE_CQ, RDMA_RESOURCE_SRQ,
                                        RDMA_RESOURCE_CEQ, RDMA_RESOURCE_AEQ}) begin
      rdma_queue_resource queue_replacement;
      rdma_queue_backing_plan authoritative_plan;
      rdma_queue_backing_plan recovery_plan;
      bit transaction_local_recovery;
      bit reservation_release_recovery;
      bit has_resource_release_step;

      if (!recovery_copy.queue_recovery_valid ||
          !$cast(queue_replacement, replacement))
        return rdma_status::make(
          RDMA_SC_INVALID_ARGUMENT,
          "queue ERROR recovery lacks authoritative queue plan"
        );
      transaction_local_recovery = queue_replacement.queue_plan == null;
      reservation_release_recovery =
        canonical_queue_reservation_release_recovery(recovery_copy);
      if (reservation_release_recovery &&
          queue_replacement.state == RDMA_RESOURCE_ERROR &&
          recovery_records.exists(key) && recovery_records[key] != null &&
          same_queue_recovery_progress(recovery_records[key], recovery_copy))
        return rdma_status::make(RDMA_SC_INVALID_STATE,
                                 "ERROR recovery publication replay");
      has_resource_release_step = 1'b0;
      foreach (recovery_copy.pending_steps[i])
        if (recovery_copy.pending_steps[i] ==
              RDMA_CTRL_STEP_RESOURCE_RELEASED)
          has_resource_release_step = 1'b1;
      if (has_resource_release_step && !reservation_release_recovery)
        return rdma_status::make(
          RDMA_SC_INVALID_ARGUMENT,
          "queue reservation release recovery is not canonical"
        );
      if (transaction_local_recovery) begin
        if (queue_replacement.state != RDMA_RESOURCE_ALLOCATED ||
            staged_allocations.exists(key) ||
            recovery_copy.hardware_presence != RDMA_HW_PRESENCE_ABSENT ||
            recovery_copy.queue_intent !=
              RDMA_QUEUE_RECOVER_CREATE_ROLLBACK ||
            recovery_copy.ambiguous_queue_operation != RDMA_QUEUE_AMBIG_NONE ||
            recovery_copy.ambiguous_ticket != null ||
            recovery_copy.pending_steps.size() != 1 ||
            !(recovery_copy.pending_steps[0] inside {
              RDMA_CTRL_STEP_BACKING_RELEASED,
              RDMA_CTRL_STEP_RESOURCE_RELEASED
            }) ||
            recovery_copy.queue_plan == null ||
            recovery_copy.queue_plan.resource_kind !=
              queue_replacement.resource_kind())
          return rdma_status::make(
            RDMA_SC_INVALID_ARGUMENT,
            "unstaged queue ERROR recovery is not canonical local rollback"
          );
        foreach (recovery_copy.completed_steps[i]) begin
          if (rdma_control_step_is_hardware(recovery_copy.completed_steps[i]))
            return rdma_status::make(
              RDMA_SC_INVALID_ARGUMENT,
              "unstaged queue ERROR recovery contains hardware history"
            );
        end
        foreach (recovery_copy.queue_plan.refs[i]) begin
          if (recovery_copy.queue_plan.refs[i] == null ||
              recovery_copy.queue_plan.refs[i].mapping == null ||
              !same_handle_instance(
                recovery_copy.queue_plan.refs[i].mapping.function_h,
                queue_replacement.owner
              ) ||
              (recovery_copy.queue_plan.refs[i].ownership ==
                 RDMA_OWNERSHIP_CONTROL_PLANE &&
               !same_handle_instance(
                 recovery_copy.queue_plan.refs[i].mapping.owner_h,
                 trusted_handle
               )))
            return rdma_status::make(
              RDMA_SC_INVALID_ARGUMENT,
              "unstaged queue ERROR backing owner is not authoritative"
            );
          foreach (recovery_copy.queue_plan.refs[i].additional_segments[j]) begin
            if (recovery_copy.queue_plan.refs[i].additional_segments[j] == null ||
                recovery_copy.queue_plan.refs[i].additional_segments[j].mapping ==
                  null ||
                !same_handle_instance(
                  recovery_copy.queue_plan.refs[i].additional_segments[j].
                    mapping.function_h,
                  queue_replacement.owner
                ) ||
                (recovery_copy.queue_plan.refs[i].additional_segments[j].
                   ownership == RDMA_OWNERSHIP_CONTROL_PLANE &&
                 !same_handle_instance(
                   recovery_copy.queue_plan.refs[i].additional_segments[j].
                     mapping.owner_h,
                   trusted_handle
                 )))
              return rdma_status::make(
                RDMA_SC_INVALID_ARGUMENT,
                "unstaged queue ERROR segment owner is not authoritative"
              );
          end
        end
        if (recovery_copy.queue_plan.context_ref != null &&
            !same_handle_instance(
              recovery_copy.queue_plan.context_ref.owner,
              queue_replacement.owner
            ))
          return rdma_status::make(
            RDMA_SC_INVALID_ARGUMENT,
            "unstaged queue ERROR context owner is not authoritative"
          );
        if (reservation_release_recovery) begin
          status = queue_local_release_plan_status(recovery_copy.queue_plan);
          if (!status.ok()) return status;
        end
        status = project_queue_plan_value(
          recovery_copy.queue_plan, "mark error transaction resource plan",
          authoritative_plan
        );
        if (status == null)
          return rdma_status::make(
            RDMA_SC_INVALID_STATE,
            "transaction resource plan projection returned null"
          );
        if (!status.ok()) return status;
        status = project_queue_plan_value(
          recovery_copy.queue_plan, "mark error transaction recovery plan",
          recovery_plan
        );
        if (status == null)
          return rdma_status::make(
            RDMA_SC_INVALID_STATE,
            "transaction recovery plan projection returned null"
          );
        if (!status.ok()) return status;
        queue_replacement.queue_plan = authoritative_plan;
        queue_replacement.depth = authoritative_plan.rings[0].depth;
        recovery_copy.queue_plan = recovery_plan;
        replacement = queue_replacement;
      end
      else if (reservation_release_recovery) begin
        // A reservation-only queue rollback is first persisted while the
        // resource is ALLOCATED, then may be retried after mark_error()
        // published the durable ERROR record.  Keep accepting the canonical
        // snapshot in that ERROR state so a subsequent recovery invocation
        // can atomically consume RESOURCE_RELEASED; rejecting it here would
        // strand a successfully cleaned-up ambiguous create forever.
        if (queue_replacement.state != RDMA_RESOURCE_ALLOCATED &&
            !(queue_replacement.state == RDMA_RESOURCE_ERROR &&
              recovery_records.exists(key)))
          return rdma_status::make(
            RDMA_SC_INVALID_STATE,
            "queue reservation recovery requires ALLOCATED or ERROR authority"
          );
        status = queue_reservation_release_plan_status(
          queue_replacement.queue_plan, recovery_copy.queue_plan
        );
        if (!status.ok()) return status;
        status = project_queue_plan_value(
          recovery_copy.queue_plan,
          "mark error reservation resource plan", authoritative_plan
        );
        if (status == null)
          return rdma_status::make(
            RDMA_SC_INVALID_STATE,
            "reservation resource plan projection returned null"
          );
        if (!status.ok()) return status;
        status = project_queue_plan_value(
          recovery_copy.queue_plan,
          "mark error reservation recovery plan", recovery_plan
        );
        if (status == null)
          return rdma_status::make(
            RDMA_SC_INVALID_STATE,
            "reservation recovery plan projection returned null"
          );
        if (!status.ok()) return status;
        queue_replacement.queue_plan = authoritative_plan;
        queue_replacement.depth = authoritative_plan.rings[0].depth;
        recovery_copy.queue_plan = recovery_plan;
        replacement = queue_replacement;
      end
      else begin
        // A QUIESCING progress record lives only in the registry.  Make that
        // snapshot authoritative when ERROR recovery begins so callers cannot
        // erase already-proven cleanup by supplying an older plan.
        status = project_queue_plan_value(
          queue_replacement.queue_plan,
          "mark error authoritative queue plan", authoritative_plan
        );
        if (status == null)
          return rdma_status::make(
            RDMA_SC_INVALID_STATE,
            "queue ERROR plan projection returned null"
          );
        if (!status.ok()) return status;
        recovery_copy.queue_plan = authoritative_plan;
      end
      status = recovery_copy.validate();
      if (status == null)
        return rdma_status::make(RDMA_SC_INVALID_STATE,
                                 "merged queue recovery validation returned null");
      if (!status.ok()) return status;
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
    if (authoritative.handle.kind == RDMA_RESOURCE_QP)
      return rdma_status::make(
        RDMA_SC_INVALID_STATE,
        "QP resources require QP-specific finalization"
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
    rdma_queue_resource queue_resource;
    rdma_recovery_record recovery;
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
    if (authoritative.handle.kind == RDMA_RESOURCE_QP)
      return rdma_status::make(
        RDMA_SC_INVALID_STATE,
        "QP reservations require QP-specific finalization"
      );
    if (registry[key].state == RDMA_RESOURCE_ERROR) begin
      if (!recovery_records.exists(key))
        return rdma_status::make(
          RDMA_SC_INVALID_STATE,
          "ERROR reservation has no recovery record"
        );
      recovery = recovery_records[key];
      if (!$cast(queue_resource, registry[key]) ||
          !canonical_queue_reservation_release_recovery(recovery))
        return rdma_status::make(
          RDMA_SC_INVALID_STATE,
          "ERROR resource is not a queue reservation release recovery"
        );
      status = queue_reservation_release_plan_status(
        queue_resource.queue_plan, recovery.queue_plan
      );
      if (!status.ok()) return status;
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
    end
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
    if (ignored.handle.kind == RDMA_RESOURCE_QP)
      return rdma_status::make(
        RDMA_SC_INVALID_STATE,
        "QP resources require QP-specific finalization"
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
