class rdma_resource_manager_probe extends rdma_resource_manager;
  function new(string name = "rdma_resource_manager_probe");
    super.new(name);
  endfunction

  function void force_next_object_serial(
    rdma_resource_kind_e kind,
    int unsigned next_serial
  );
    next_object_serial[kind] = next_serial;
  endfunction

  function int unsigned observed_next_local_id(
    rdma_resource_kind_e kind
  );
    return next_local_id[kind];
  endfunction

  function int unsigned observed_next_object_serial(
    rdma_resource_kind_e kind
  );
    return next_object_serial[kind];
  endfunction

  function int unsigned observed_recovery_count();
    return recovery_records.num();
  endfunction
endclass

// Generic QP mutation bypass tests need exact staged and ACTIVE registry
// preconditions without relying on another public transition under test.
class rdma_qp_generic_bypass_probe_manager extends rdma_resource_manager;
  function new(string name = "rdma_qp_generic_bypass_probe_manager");
    super.new(name);
  endfunction

  function rdma_status force_qp_staged_precondition(rdma_qp candidate);
    rdma_resource projected;
    rdma_qp replacement;
    rdma_status status;
    string key;

    status = project_public_resource_value(
      candidate, "force QP staged precondition", projected
    );
    if (!status.ok() || !$cast(replacement, projected))
      return status.ok() ? rdma_status::make(
        RDMA_SC_INVALID_ARGUMENT, "staged precondition is not a QP"
      ) : status;
    key = resource_key(replacement.handle);
    if (!registry.exists(key))
      return rdma_status::make(
        RDMA_SC_INVALID_ARGUMENT, "staged precondition QP is unknown"
      );
    replacement.state = RDMA_RESOURCE_ALLOCATED;
    status = replacement.validate();
    if (status == null || !status.ok())
      return status == null ? rdma_status::make(
        RDMA_SC_INVALID_STATE, "staged precondition validation returned null"
      ) : status;
    registry[key] = replacement;
    staged_allocations[key] = 1'b1;
    return rdma_status::success();
  endfunction

  function rdma_status force_qp_active_precondition(rdma_qp candidate);
    rdma_resource projected;
    rdma_qp replacement;
    rdma_status status;
    string key;

    status = project_public_resource_value(
      candidate, "force QP ACTIVE precondition", projected
    );
    if (!status.ok() || !$cast(replacement, projected))
      return status.ok() ? rdma_status::make(
        RDMA_SC_INVALID_ARGUMENT, "ACTIVE precondition is not a QP"
      ) : status;
    key = resource_key(replacement.handle);
    if (!registry.exists(key))
      return rdma_status::make(
        RDMA_SC_INVALID_ARGUMENT, "ACTIVE precondition QP is unknown"
      );
    replacement.state = RDMA_RESOURCE_ACTIVE;
    status = replacement.validate();
    if (status == null || !status.ok())
      return status == null ? rdma_status::make(
        RDMA_SC_INVALID_STATE, "ACTIVE precondition validation returned null"
      ) : status;
    registry[key] = replacement;
    staged_allocations.delete(key);
    recovery_records.delete(key);
    return rdma_status::success();
  endfunction

endclass

// Boundary injection is intentionally isolated from the behavior tests.  It
// models corrupted allocator state without exposing registry mutation hooks.
class rdma_width_probe_manager extends rdma_resource_manager;
  function new(string name = "rdma_width_probe_manager");
    super.new(name);
  endfunction

  function void set_next_local_id(rdma_resource_kind_e kind,
                                  int unsigned value);
    next_local_id[kind] = value;
  endfunction

  function void seed_next_local_id(rdma_resource_kind_e kind,
                                   int unsigned value);
    next_local_id[kind] = value;
  endfunction

  function void inject_free_local_id(rdma_resource_kind_e kind,
                                     int unsigned value);
    free_local_ids[kind].push_back(value);
  endfunction

  function int unsigned observed_next_object_serial(
    rdma_resource_kind_e kind
  );
    return next_object_serial[kind];
  endfunction

  function int unsigned observed_next_local_id(
    rdma_resource_kind_e kind
  );
    return next_local_id[kind];
  endfunction

  function int unsigned observed_free_local_id_count(
    rdma_resource_kind_e kind
  );
    if (!free_local_ids.exists(kind))
      return 0;
    return free_local_ids[kind].size();
  endfunction

  function int unsigned observed_registry_count();
    return registry.num();
  endfunction
endclass

// This adapter deliberately gives each projected mapping copy its own
// completion fact while retaining common opaque release authority.  It models
// a corrupted snapshot that claims a release occurred on only one side of the
// restore comparison.
class rdma_rm_independent_release_mapping extends rdma_dma_mapping;
  `uvm_object_utils(rdma_rm_independent_release_mapping)

  local longint unsigned allocation_token;
  local bit allocation_token_initialized;
  local bit release_complete;
  local static longint unsigned next_allocation_token = 1;

  function new(string name = "rdma_rm_independent_release_mapping");
    super.new(name);
    allocation_token = 0;
    allocation_token_initialized = 1'b0;
    release_complete = 1'b0;
  endfunction

  function void initialize_release_authority();
    allocation_token = next_allocation_token;
    allocation_token_initialized = 1'b1;
    next_allocation_token++;
  endfunction

  function void set_release_complete(bit value);
    release_complete = value;
  endfunction

  virtual function rdma_status snapshot_release_authority(
    output rdma_dma_mapping snapshot
  );
    rdma_rm_independent_release_mapping candidate;

    snapshot = null;
    if (!allocation_token_initialized)
      return rdma_status::make(
        RDMA_SC_INVALID_STATE, "independent release authority is uninitialized"
      );
    candidate = rdma_rm_independent_release_mapping::type_id::create(
      {get_name(), "_authority"}
    );
    candidate.allocation_token = allocation_token;
    candidate.allocation_token_initialized = 1'b1;
    snapshot = candidate;
    return rdma_status::success();
  endfunction

  virtual function rdma_status release_authority_status(
    rdma_dma_mapping snapshot
  );
    rdma_rm_independent_release_mapping candidate;

    if (!$cast(candidate, snapshot) || candidate == null ||
        !allocation_token_initialized ||
        !candidate.allocation_token_initialized ||
        candidate.allocation_token != allocation_token)
      return rdma_status::make(
        RDMA_SC_INVALID_ARGUMENT, "independent release authority changed"
      );
    return rdma_status::success();
  endfunction

  virtual function rdma_status release_completion_status(
    output bit release_complete
  );
    release_complete = this.release_complete;
    return rdma_status::success();
  endfunction

  virtual function void do_copy(uvm_object rhs);
    rdma_rm_independent_release_mapping rhs_mapping;

    super.do_copy(rhs);
    if (!$cast(rhs_mapping, rhs) || rhs_mapping == null)
      `uvm_fatal("RM_INDEPENDENT_RELEASE", "mapping copy cast failed")
    allocation_token = rhs_mapping.allocation_token;
    allocation_token_initialized = rhs_mapping.allocation_token_initialized;
    release_complete = rhs_mapping.release_complete;
  endfunction
endclass

class rdma_qp_lifecycle_probe_manager
  extends rdma_qp_generic_bypass_probe_manager;
  function new(string name = "rdma_qp_lifecycle_probe_manager");
    super.new(name);
  endfunction

  function rdma_status complete_qp_mapping_release(
    rdma_handle qp_h,
    rdma_queue_backing_role_e role
  );
    rdma_qp resource_qp;
    rdma_qp_backing_ref resource_ref;
    rdma_qp_backing_ref recovery_ref;
    rdma_rm_independent_release_mapping resource_mapping;
    rdma_rm_independent_release_mapping recovery_mapping;
    string key;

    key = resource_key(qp_h);
    if (!registry.exists(key) || !$cast(resource_qp, registry[key]))
      return rdma_status::make(
        RDMA_SC_INVALID_ARGUMENT, "QP mapping completion target is unknown"
      );
    resource_ref = qp_plan_ref(resource_qp.qp_plan, role);
    if (resource_ref == null ||
        !$cast(resource_mapping, resource_ref.mapping))
      return rdma_status::make(
        RDMA_SC_INVALID_ARGUMENT, "QP mapping completion role is unsupported"
      );
    resource_mapping.set_release_complete(1'b1);
    if (recovery_records.exists(key)) begin
      recovery_ref = qp_plan_ref(
        recovery_records[key].qp_recovery.qp_plan, role
      );
      if (recovery_ref == null ||
          !$cast(recovery_mapping, recovery_ref.mapping))
        return rdma_status::make(
          RDMA_SC_INVALID_ARGUMENT,
          "QP recovery mapping completion role is unsupported"
        );
      recovery_mapping.set_release_complete(1'b1);
    end
    return rdma_status::success();
  endfunction

  function rdma_status set_qp_recovery_hardware_presence(
    rdma_handle qp_h,
    rdma_hw_presence_e hardware_presence
  );
    string key;

    key = resource_key(qp_h);
    if (!recovery_records.exists(key) || recovery_records[key] == null)
      return rdma_status::make(
        RDMA_SC_INVALID_ARGUMENT,
        "QP recovery hardware-presence target is invalid"
      );
    recovery_records[key].hardware_presence = hardware_presence;
    return rdma_status::success();
  endfunction

  function rdma_status complete_qp_context_release(rdma_handle qp_h);
    rdma_qp resource_qp;
    rdma_queue_slot_token_contract token;
    string key;

    key = resource_key(qp_h);
    if (!registry.exists(key) || !$cast(resource_qp, registry[key]) ||
        resource_qp.qp_plan == null ||
        resource_qp.qp_plan.context_ref == null ||
        !$cast(token, resource_qp.qp_plan.context_ref.slot_token) ||
        token.completion_authority == null)
      return rdma_status::make(
        RDMA_SC_INVALID_ARGUMENT, "QP context completion target is invalid"
      );
    token.completion_authority.complete = 1'b1;
    return rdma_status::success();
  endfunction

  function rdma_status complete_qp_temporary_mapping_release(
    rdma_handle qp_h,
    bit staging_mapping
  );
    rdma_dma_mapping temporary_mapping;
    rdma_rm_independent_release_mapping completion_mapping;
    string key;

    key = resource_key(qp_h);
    if (!recovery_records.exists(key) ||
        recovery_records[key] == null ||
        !recovery_records[key].qp_recovery_valid ||
        recovery_records[key].qp_recovery == null)
      return rdma_status::make(
        RDMA_SC_INVALID_ARGUMENT,
        "QP temporary mapping completion target is invalid"
      );
    temporary_mapping = staging_mapping ?
      recovery_records[key].qp_recovery.staging_mapping :
      recovery_records[key].qp_recovery.query_mapping;
    if (!$cast(completion_mapping, temporary_mapping))
      return rdma_status::make(
        RDMA_SC_INVALID_ARGUMENT,
        "QP temporary mapping completion authority is unsupported"
      );
    completion_mapping.set_release_complete(1'b1);
    return rdma_status::success();
  endfunction

  function rdma_status replace_qp_recovery_context_authority(
    rdma_handle qp_h
  );
    rdma_queue_slot_token_contract context_token;
    rdma_queue_slot_token_contract plan_token;
    rdma_queue_completion_authority replacement_authority;
    string key;

    key = resource_key(qp_h);
    if (!recovery_records.exists(key) ||
        recovery_records[key] == null ||
        recovery_records[key].qp_recovery == null ||
        recovery_records[key].qp_recovery.context_ref == null ||
        recovery_records[key].qp_recovery.qp_plan == null ||
        recovery_records[key].qp_recovery.qp_plan.context_ref == null ||
        !$cast(context_token, recovery_records[key].qp_recovery.
          context_ref.slot_token) ||
        !$cast(plan_token, recovery_records[key].qp_recovery.qp_plan.
          context_ref.slot_token))
      return rdma_status::make(
        RDMA_SC_INVALID_ARGUMENT,
        "QP recovery context authority replacement target is invalid"
      );
    replacement_authority =
      rdma_queue_completion_authority::type_id::create(
        "qp_recovery_replacement_authority"
      );
    replacement_authority.complete = 1'b1;
    context_token.completion_authority = replacement_authority;
    plan_token.completion_authority = replacement_authority;
    return rdma_status::success();
  endfunction

  function rdma_status restore_qp_recovery_context_authority(
    rdma_handle qp_h
  );
    rdma_qp resource_qp;
    rdma_queue_slot_token_contract resource_token;
    rdma_queue_slot_token_contract context_token;
    rdma_queue_slot_token_contract plan_token;
    string key;

    key = resource_key(qp_h);
    if (!registry.exists(key) || !$cast(resource_qp, registry[key]) ||
        resource_qp.qp_plan == null ||
        resource_qp.qp_plan.context_ref == null ||
        !recovery_records.exists(key) ||
        recovery_records[key] == null ||
        recovery_records[key].qp_recovery == null ||
        recovery_records[key].qp_recovery.context_ref == null ||
        recovery_records[key].qp_recovery.qp_plan == null ||
        recovery_records[key].qp_recovery.qp_plan.context_ref == null ||
        !$cast(resource_token,
               resource_qp.qp_plan.context_ref.slot_token) ||
        !$cast(context_token, recovery_records[key].qp_recovery.
          context_ref.slot_token) ||
        !$cast(plan_token, recovery_records[key].qp_recovery.qp_plan.
          context_ref.slot_token) ||
        resource_token.completion_authority == null)
      return rdma_status::make(
        RDMA_SC_INVALID_ARGUMENT,
        "QP recovery context authority restore target is invalid"
      );
    context_token.completion_authority =
      resource_token.completion_authority;
    plan_token.completion_authority =
      resource_token.completion_authority;
    return rdma_status::success();
  endfunction
endclass

class rdma_queue_recovery_probe_manager extends rdma_resource_manager;
  rdma_recovery_record observed_pre_retire_recovery;
  bit force_queue_restore_late_failure;

  function new(string name = "rdma_queue_recovery_probe_manager");
    super.new(name);
    observed_pre_retire_recovery = null;
    force_queue_restore_late_failure = 1'b0;
  endfunction

  function void swap_recovery_refs(rdma_handle handle, int unsigned lhs,
                                   int unsigned rhs);
    rdma_queue_backing_ref saved;
    string key;
    key = resource_key(handle);
    saved = recovery_records[key].queue_plan.refs[lhs];
    recovery_records[key].queue_plan.refs[lhs] =
      recovery_records[key].queue_plan.refs[rhs];
    recovery_records[key].queue_plan.refs[rhs] = saved;
  endfunction

  function void set_queue_cleanup(rdma_handle handle, bit recovery_side,
                                  rdma_queue_backing_role_e role, bit value);
    string key;
    key = resource_key(handle);
    if (recovery_side) begin
      foreach (recovery_records[key].queue_plan.refs[i])
        if (recovery_records[key].queue_plan.refs[i].role == role)
          recovery_records[key].queue_plan.refs[i].cleanup_complete = value;
      if (recovery_records[key].queue_plan.context_ref != null)
        recovery_records[key].queue_plan.context_ref.release_complete = value;
    end
    else begin
      rdma_queue_resource queue_resource;
      if ($cast(queue_resource, registry[key])) begin
        foreach (queue_resource.queue_plan.refs[i])
          if (queue_resource.queue_plan.refs[i].role == role)
            queue_resource.queue_plan.refs[i].cleanup_complete = value;
        if (queue_resource.queue_plan.context_ref != null)
          queue_resource.queue_plan.context_ref.release_complete = value;
      end
    end
  endfunction

  function void clear_queue_ambiguity(rdma_handle handle);
    string key;
    key = resource_key(handle);
    recovery_records[key].ambiguous_queue_operation = RDMA_QUEUE_AMBIG_NONE;
    recovery_records[key].ambiguous_role = RDMA_QUEUE_ROLE_CQ_RING;
    recovery_records[key].ambiguous_ticket = null;
  endfunction

  function void set_queue_ambiguity(
    rdma_handle handle,
    rdma_queue_ambiguous_operation_e operation,
    rdma_queue_backing_role_e role
  );
    string key;

    key = resource_key(handle);
    recovery_records[key].ambiguous_queue_operation = operation;
    recovery_records[key].ambiguous_role = role;
    recovery_records[key].ambiguous_ticket = null;
  endfunction

  function void set_queue_flush_complete(
    rdma_handle handle,
    bit recovery_side,
    rdma_queue_backing_role_e role,
    bit value
  );
    rdma_queue_backing_plan plan;
    rdma_queue_resource queue_resource;
    string key;

    key = resource_key(handle);
    plan = null;
    if (recovery_side)
      plan = recovery_records[key].queue_plan;
    else if ($cast(queue_resource, registry[key]))
      plan = queue_resource.queue_plan;
    if (plan == null)
      `uvm_fatal("QUEUE_FLUSH_PROGRESS", "queue plan is unavailable")
    foreach (plan.flush_targets[i]) begin
      if (plan.flush_targets[i] != null && plan.flush_targets[i].role == role) begin
        plan.flush_targets[i].flush_complete = value;
        return;
      end
    end
    `uvm_fatal("QUEUE_FLUSH_PROGRESS", "queue flush role is unavailable")
  endfunction

  function bit observed_queue_flush_complete(
    rdma_handle handle,
    bit recovery_side,
    rdma_queue_backing_role_e role
  );
    rdma_queue_backing_plan plan;
    rdma_queue_resource queue_resource;
    string key;

    key = resource_key(handle);
    plan = null;
    if (recovery_side)
      plan = recovery_records[key].queue_plan;
    else if ($cast(queue_resource, registry[key]))
      plan = queue_resource.queue_plan;
    if (plan == null)
      `uvm_fatal("QUEUE_FLUSH_PROGRESS", "queue plan is unavailable")
    foreach (plan.flush_targets[i]) begin
      if (plan.flush_targets[i] != null && plan.flush_targets[i].role == role)
        return plan.flush_targets[i].flush_complete;
    end
    `uvm_fatal("QUEUE_FLUSH_PROGRESS", "queue flush role is unavailable")
    return 1'b0;
  endfunction

  function void set_queue_release_evidence(
    rdma_handle handle,
    bit recovery_side,
    rdma_queue_backing_role_e role,
    bit value
  );
    rdma_queue_backing_plan plan;
    rdma_queue_resource queue_resource;
    rdma_rm_independent_release_mapping mapping;
    string key;

    key = resource_key(handle);
    plan = null;
    if (recovery_side)
      plan = recovery_records[key].queue_plan;
    else if ($cast(queue_resource, registry[key]))
      plan = queue_resource.queue_plan;
    if (plan == null)
      `uvm_fatal("QUEUE_RELEASE_EVIDENCE", "queue plan is unavailable")
    foreach (plan.refs[i]) begin
      if (plan.refs[i] != null && plan.refs[i].role == role) begin
        if (!$cast(mapping, plan.refs[i].mapping) || mapping == null)
          `uvm_fatal("QUEUE_RELEASE_EVIDENCE", "queue mapping type mismatch")
        mapping.set_release_complete(value);
        return;
      end
    end
    `uvm_fatal("QUEUE_RELEASE_EVIDENCE", "queue role is unavailable")
  endfunction

  function void set_queue_segment_iova(
    rdma_handle handle,
    bit recovery_side,
    rdma_queue_backing_role_e role,
    int unsigned segment_index,
    longint unsigned iova_value
  );
    rdma_queue_backing_plan plan;
    rdma_queue_resource queue_resource;
    string key;

    key = resource_key(handle);
    plan = null;
    if (recovery_side)
      plan = recovery_records[key].queue_plan;
    else if ($cast(queue_resource, registry[key]))
      plan = queue_resource.queue_plan;
    if (plan == null)
      `uvm_fatal("QUEUE_SEGMENT_IOVA", "queue plan is unavailable")
    foreach (plan.refs[i]) begin
      if (plan.refs[i] != null && plan.refs[i].role == role) begin
        if (segment_index >= plan.refs[i].additional_segments.size() ||
            plan.refs[i].additional_segments[segment_index] == null ||
            plan.refs[i].additional_segments[segment_index].mapping == null)
          `uvm_fatal("QUEUE_SEGMENT_IOVA",
                     "queue backing segment is unavailable")
        plan.refs[i].additional_segments[segment_index].mapping.iova.value =
          iova_value;
        return;
      end
    end
    `uvm_fatal("QUEUE_SEGMENT_IOVA", "queue role is unavailable")
  endfunction

  function void set_queue_segment_release_evidence(
    rdma_handle handle,
    bit recovery_side,
    rdma_queue_backing_role_e role,
    int unsigned segment_index,
    bit value
  );
    rdma_queue_backing_plan plan;
    rdma_queue_resource queue_resource;
    rdma_rm_independent_release_mapping mapping;
    string key;

    key = resource_key(handle);
    plan = null;
    if (recovery_side)
      plan = recovery_records[key].queue_plan;
    else if ($cast(queue_resource, registry[key]))
      plan = queue_resource.queue_plan;
    if (plan == null)
      `uvm_fatal("QUEUE_SEGMENT_RELEASE", "queue plan is unavailable")
    foreach (plan.refs[i]) begin
      if (plan.refs[i] != null && plan.refs[i].role == role) begin
        if (segment_index >= plan.refs[i].additional_segments.size() ||
            plan.refs[i].additional_segments[segment_index] == null ||
            !$cast(mapping,
              plan.refs[i].additional_segments[segment_index].mapping) ||
            mapping == null)
          `uvm_fatal("QUEUE_SEGMENT_RELEASE",
                     "queue backing segment mapping is unavailable")
        mapping.set_release_complete(value);
        return;
      end
    end
    `uvm_fatal("QUEUE_SEGMENT_RELEASE", "queue role is unavailable")
  endfunction

  virtual function void queue_restore_pre_publish_observer(
    rdma_recovery_record prepared_recovery
  );
    uvm_object cloned_object;

    observed_pre_retire_recovery = null;
    if (prepared_recovery == null)
      return;
    cloned_object = prepared_recovery.clone();
    if (cloned_object == null ||
        !$cast(observed_pre_retire_recovery, cloned_object))
      `uvm_fatal("QUEUE_RESTORE_OBSERVER", "recovery snapshot clone failed")
  endfunction

  virtual function void queue_restore_pre_validate_observer(
    rdma_resource prepared_resource
  );
    rdma_queue_resource queue_resource;

    if (!force_queue_restore_late_failure ||
        !$cast(queue_resource, prepared_resource) ||
        queue_resource.queue_plan == null ||
        queue_resource.queue_plan.flush_targets.size() == 0)
      return;
    // Corrupt only the prepared resource after recovery reset preparation.
    // The manager must reject it without leaking any prepared state live.
    queue_resource.queue_plan.flush_targets[0].pd_ref = null;
  endfunction
endclass

typedef enum bit [5:0] {
  RDMA_RM_CLONE_GOOD,
  RDMA_RM_CLONE_SELF,
  RDMA_RM_CLONE_WRONG,
  RDMA_RM_CLONE_DRIFT,
  RDMA_RM_CLONE_BACKING_DRIFT,
  RDMA_RM_CLONE_HMC_DRIFT,
  RDMA_RM_CLONE_PROGRAMMABLE_DRIFT,
  RDMA_RM_CLONE_SHALLOW_RESOURCE_HANDLE,
  RDMA_RM_CLONE_SHALLOW_RESOURCE_OWNER,
  RDMA_RM_CLONE_SHALLOW_RESOURCE_DEPENDENCY,
  RDMA_RM_CLONE_SHALLOW_RESOURCE_BACKING_REF,
  RDMA_RM_CLONE_SHALLOW_RESOURCE_MAPPING,
  RDMA_RM_CLONE_SHALLOW_RESOURCE_MAPPING_FUNCTION,
  RDMA_RM_CLONE_SHALLOW_RESOURCE_MAPPING_OWNER,
  RDMA_RM_CLONE_SHALLOW_RESOURCE_HMC_REF,
  RDMA_RM_CLONE_SHALLOW_RESOURCE_HMC_OWNER,
  RDMA_RM_CLONE_SHALLOW_RESOURCE_KIND_HANDLE,
  RDMA_RM_CLONE_SHALLOW_RECOVERY_RESOURCE_HANDLE,
  RDMA_RM_CLONE_SHALLOW_RECOVERY_BACKING_REF,
  RDMA_RM_CLONE_SHALLOW_RECOVERY_MAPPING,
  RDMA_RM_CLONE_SHALLOW_RECOVERY_MAPPING_FUNCTION,
  RDMA_RM_CLONE_SHALLOW_RECOVERY_MAPPING_OWNER,
  RDMA_RM_CLONE_SHALLOW_RECOVERY_HMC_REF,
  RDMA_RM_CLONE_SHALLOW_RECOVERY_HMC_OWNER,
  RDMA_RM_CLONE_SHALLOW_RECOVERY_TICKET,
  RDMA_RM_CLONE_SHALLOW_RECOVERY_TICKET_FUNCTION,
  RDMA_RM_CLONE_SHALLOW_RECOVERY_TICKET_CMQ,
  RDMA_RM_CLONE_SHALLOW_RECOVERY_TICKET_OPCODE,
  RDMA_RM_CLONE_SHALLOW_RECOVERY_PRIMARY_STATUS,
  RDMA_RM_CLONE_SHALLOW_RECOVERY_ROLLBACK_STATUS,
  RDMA_RM_CLONE_CROSS_RESOURCE_ALIAS,
  RDMA_RM_CLONE_RECOVERY_TICKET_DRIFT,
  RDMA_RM_CLONE_RECOVERY_STEPS_DRIFT,
  RDMA_RM_CLONE_RECOVERY_PRIMARY_HIDDEN_HW_DRIFT,
  RDMA_RM_CLONE_RECOVERY_ROLLBACK_STATUS_DRIFT,
  RDMA_RM_CLONE_MUTATE_SOURCE_SCALAR,
  RDMA_RM_CLONE_LAUNDER_SOURCE_CHILD
} rdma_rm_clone_fault_e;

typedef enum bit [1:0] {
  RDMA_RM_KIND_CLONE_GOOD,
  RDMA_RM_KIND_CLONE_VALUE_DRIFT,
  RDMA_RM_KIND_CLONE_SHALLOW_HANDLES
} rdma_rm_kind_clone_fault_e;

typedef enum bit [1:0] {
  RDMA_RM_FUNCTION_CLONE_GOOD,
  RDMA_RM_FUNCTION_CLONE_SHALLOW_BINDING,
  RDMA_RM_FUNCTION_CLONE_SHALLOW_PCIE,
  RDMA_RM_FUNCTION_CLONE_SHALLOW_BAR
} rdma_rm_function_clone_fault_e;

class rdma_rm_fault_mr extends rdma_mr;
  `uvm_object_utils(rdma_rm_fault_mr)

  rdma_rm_clone_fault_e clone_fault;

  function new(string name = "rdma_rm_fault_mr");
    super.new(name);
    clone_fault = RDMA_RM_CLONE_GOOD;
  endfunction

  virtual function uvm_object clone();
    uvm_object cloned_object;
    rdma_rm_fault_mr cloned_mr;
    rdma_pd wrong_pd;
    rdma_handle saved_pd_h;

    case (clone_fault)
      RDMA_RM_CLONE_SELF: return this;
      RDMA_RM_CLONE_WRONG: begin
        wrong_pd = rdma_pd::type_id::create("wrong_mr_clone");
        wrong_pd.handle = rdma_clone_handle_value(handle, "wrong MR clone");
        wrong_pd.owner = rdma_clone_function_handle_value(
          owner, "wrong MR clone"
        );
        wrong_pd.state = state;
        return wrong_pd;
      end
      RDMA_RM_CLONE_DRIFT: begin
        cloned_object = super.clone();
        if (!$cast(cloned_mr, cloned_object))
          `uvm_fatal("RM_TEST_CLONE", "fault MR clone cast failed")
        cloned_mr.local_mr_id++;
        return cloned_mr;
      end
      RDMA_RM_CLONE_BACKING_DRIFT: begin
        cloned_object = super.clone();
        if (!$cast(cloned_mr, cloned_object) ||
            cloned_mr.backing_refs.size() == 0 ||
            cloned_mr.backing_refs[0] == null ||
            cloned_mr.backing_refs[0].mapping == null)
          `uvm_fatal("RM_TEST_CLONE",
                     "fault MR backing clone setup failed")
        cloned_mr.backing_refs[0].mapping.iova.value++;
        return cloned_mr;
      end
      RDMA_RM_CLONE_HMC_DRIFT: begin
        cloned_object = super.clone();
        if (!$cast(cloned_mr, cloned_object) ||
            cloned_mr.hmc_refs.size() == 0 ||
            cloned_mr.hmc_refs[0] == null)
          `uvm_fatal("RM_TEST_CLONE", "fault MR HMC clone setup failed")
        cloned_mr.hmc_refs[0].address.value++;
        return cloned_mr;
      end
      RDMA_RM_CLONE_PROGRAMMABLE_DRIFT: begin
        cloned_object = super.clone();
        if (!$cast(cloned_mr, cloned_object))
          `uvm_fatal("RM_TEST_CLONE", "fault MR clone cast failed")
        cloned_mr.iova.value += 64'h1000;
        cloned_mr.length += 64'h1000;
        cloned_mr.lkey[7:0]++;
        cloned_mr.rkey = cloned_mr.lkey;
        cloned_mr.access.local_write = !cloned_mr.access.local_write;
        cloned_mr.mr_serial++;
        cloned_mr.hmc_fvm_addr.value++;
        return cloned_mr;
      end
      RDMA_RM_CLONE_SHALLOW_RESOURCE_HANDLE: begin
        cloned_object = super.clone();
        if (!$cast(cloned_mr, cloned_object))
          `uvm_fatal("RM_TEST_CLONE", "fault MR clone cast failed")
        cloned_mr.handle = handle;
        return cloned_mr;
      end
      RDMA_RM_CLONE_SHALLOW_RESOURCE_OWNER: begin
        cloned_object = super.clone();
        if (!$cast(cloned_mr, cloned_object))
          `uvm_fatal("RM_TEST_CLONE", "fault MR clone cast failed")
        cloned_mr.owner = owner;
        return cloned_mr;
      end
      RDMA_RM_CLONE_SHALLOW_RESOURCE_DEPENDENCY: begin
        cloned_object = super.clone();
        if (!$cast(cloned_mr, cloned_object) || dependencies.size() == 0)
          `uvm_fatal("RM_TEST_CLONE",
                     "fault MR dependency clone setup failed")
        cloned_mr.dependencies[0] = dependencies[0];
        return cloned_mr;
      end
      RDMA_RM_CLONE_SHALLOW_RESOURCE_BACKING_REF: begin
        cloned_object = super.clone();
        if (!$cast(cloned_mr, cloned_object) || backing_refs.size() == 0)
          `uvm_fatal("RM_TEST_CLONE",
                     "fault MR backing reference clone setup failed")
        cloned_mr.backing_refs[0] = backing_refs[0];
        return cloned_mr;
      end
      RDMA_RM_CLONE_SHALLOW_RESOURCE_MAPPING: begin
        cloned_object = super.clone();
        if (!$cast(cloned_mr, cloned_object) || backing_refs.size() == 0 ||
            backing_refs[0] == null)
          `uvm_fatal("RM_TEST_CLONE",
                     "fault MR mapping clone setup failed")
        cloned_mr.backing_refs[0].mapping = backing_refs[0].mapping;
        return cloned_mr;
      end
      RDMA_RM_CLONE_SHALLOW_RESOURCE_MAPPING_FUNCTION: begin
        cloned_object = super.clone();
        if (!$cast(cloned_mr, cloned_object) || backing_refs.size() == 0 ||
            backing_refs[0] == null || backing_refs[0].mapping == null)
          `uvm_fatal("RM_TEST_CLONE",
                     "fault MR mapping Function clone setup failed")
        cloned_mr.backing_refs[0].mapping.function_h =
          backing_refs[0].mapping.function_h;
        return cloned_mr;
      end
      RDMA_RM_CLONE_SHALLOW_RESOURCE_MAPPING_OWNER: begin
        cloned_object = super.clone();
        if (!$cast(cloned_mr, cloned_object) || backing_refs.size() == 0 ||
            backing_refs[0] == null || backing_refs[0].mapping == null)
          `uvm_fatal("RM_TEST_CLONE",
                     "fault MR mapping owner clone setup failed")
        cloned_mr.backing_refs[0].mapping.owner_h =
          backing_refs[0].mapping.owner_h;
        return cloned_mr;
      end
      RDMA_RM_CLONE_SHALLOW_RESOURCE_HMC_REF: begin
        cloned_object = super.clone();
        if (!$cast(cloned_mr, cloned_object) || hmc_refs.size() == 0)
          `uvm_fatal("RM_TEST_CLONE",
                     "fault MR HMC reference clone setup failed")
        cloned_mr.hmc_refs[0] = hmc_refs[0];
        return cloned_mr;
      end
      RDMA_RM_CLONE_SHALLOW_RESOURCE_HMC_OWNER: begin
        cloned_object = super.clone();
        if (!$cast(cloned_mr, cloned_object) || hmc_refs.size() == 0 ||
            hmc_refs[0] == null)
          `uvm_fatal("RM_TEST_CLONE",
                     "fault MR HMC owner clone setup failed")
        cloned_mr.hmc_refs[0].owner = hmc_refs[0].owner;
        return cloned_mr;
      end
      RDMA_RM_CLONE_SHALLOW_RESOURCE_KIND_HANDLE: begin
        cloned_object = super.clone();
        if (!$cast(cloned_mr, cloned_object))
          `uvm_fatal("RM_TEST_CLONE", "fault MR clone cast failed")
        cloned_mr.pd_h = pd_h;
        return cloned_mr;
      end
      RDMA_RM_CLONE_CROSS_RESOURCE_ALIAS: begin
        cloned_object = super.clone();
        if (!$cast(cloned_mr, cloned_object) || backing_refs.size() == 0 ||
            backing_refs[0] == null || backing_refs[0].mapping == null ||
            hmc_refs.size() == 0 || hmc_refs[0] == null)
          `uvm_fatal("RM_TEST_CLONE",
                     "fault MR cross-alias setup failed")
        cloned_mr.backing_refs[0].mapping.function_h = hmc_refs[0].owner;
        cloned_mr.backing_refs[0].mapping.owner_h = handle;
        return cloned_mr;
      end
      RDMA_RM_CLONE_MUTATE_SOURCE_SCALAR: begin
        cloned_object = super.clone();
        if (!$cast(cloned_mr, cloned_object))
          `uvm_fatal("RM_TEST_CLONE", "fault MR clone cast failed")
        length++;
        return cloned_mr;
      end
      RDMA_RM_CLONE_LAUNDER_SOURCE_CHILD: begin
        saved_pd_h = pd_h;
        cloned_object = super.clone();
        if (!$cast(cloned_mr, cloned_object))
          `uvm_fatal("RM_TEST_CLONE", "fault MR clone cast failed")
        pd_h = cloned_mr.pd_h;
        cloned_mr.pd_h = saved_pd_h;
        return cloned_mr;
      end
      default: return super.clone();
    endcase
  endfunction
endclass

class rdma_rm_fault_function extends rdma_function;
  `uvm_object_utils(rdma_rm_fault_function)

  rdma_rm_function_clone_fault_e clone_fault;

  function new(string name = "rdma_rm_fault_function");
    super.new(name);
    clone_fault = RDMA_RM_FUNCTION_CLONE_GOOD;
  endfunction

  virtual function uvm_object clone();
    uvm_object cloned_object;
    rdma_rm_fault_function cloned_function;

    cloned_object = super.clone();
    if (!$cast(cloned_function, cloned_object))
      `uvm_fatal("RM_TEST_CLONE", "fault Function clone cast failed")
    case (clone_fault)
      RDMA_RM_FUNCTION_CLONE_SHALLOW_BINDING:
        cloned_function.binding = binding;
      RDMA_RM_FUNCTION_CLONE_SHALLOW_PCIE:
        cloned_function.binding.pcie = binding.pcie;
      RDMA_RM_FUNCTION_CLONE_SHALLOW_BAR:
        cloned_function.binding.pcie.bar[0] = binding.pcie.bar[0];
    endcase
    return cloned_function;
  endfunction
endclass

class rdma_rm_fault_pd extends rdma_pd;
  `uvm_object_utils(rdma_rm_fault_pd)
  rdma_rm_kind_clone_fault_e clone_fault;
  function new(string name = "rdma_rm_fault_pd");
    super.new(name);
    clone_fault = RDMA_RM_KIND_CLONE_GOOD;
  endfunction
  virtual function uvm_object clone();
    uvm_object cloned_object;
    rdma_rm_fault_pd cloned_pd;
    cloned_object = super.clone();
    if (!$cast(cloned_pd, cloned_object))
      `uvm_fatal("RM_TEST_CLONE", "fault PD clone cast failed")
    if (clone_fault == RDMA_RM_KIND_CLONE_VALUE_DRIFT)
      cloned_pd.global_pd_id++;
    return cloned_pd;
  endfunction
endclass

class rdma_rm_fault_cq extends rdma_cq;
  `uvm_object_utils(rdma_rm_fault_cq)
  rdma_rm_kind_clone_fault_e clone_fault;
  function new(string name = "rdma_rm_fault_cq");
    super.new(name);
    clone_fault = RDMA_RM_KIND_CLONE_GOOD;
  endfunction
  virtual function uvm_object clone();
    uvm_object cloned_object;
    rdma_rm_fault_cq cloned_cq;
    cloned_object = super.clone();
    if (!$cast(cloned_cq, cloned_object))
      `uvm_fatal("RM_TEST_CLONE", "fault CQ clone cast failed")
    case (clone_fault)
      RDMA_RM_KIND_CLONE_VALUE_DRIFT: begin
        cloned_cq.queue_iova.value++;
      end
      RDMA_RM_KIND_CLONE_SHALLOW_HANDLES: cloned_cq.ceq_h = ceq_h;
    endcase
    return cloned_cq;
  endfunction
endclass

class rdma_rm_fault_qp extends rdma_qp;
  `uvm_object_utils(rdma_rm_fault_qp)
  rdma_rm_kind_clone_fault_e clone_fault;
  function new(string name = "rdma_rm_fault_qp");
    super.new(name);
    clone_fault = RDMA_RM_KIND_CLONE_GOOD;
  endfunction
  virtual function uvm_object clone();
    uvm_object cloned_object;
    rdma_rm_fault_qp cloned_qp;
    cloned_object = super.clone();
    if (!$cast(cloned_qp, cloned_object))
      `uvm_fatal("RM_TEST_CLONE", "fault QP clone cast failed")
    case (clone_fault)
      RDMA_RM_KIND_CLONE_VALUE_DRIFT: begin
        cloned_qp.rq_iova.value++;
      end
      RDMA_RM_KIND_CLONE_SHALLOW_HANDLES: begin
        cloned_qp.pd_h = pd_h;
        cloned_qp.send_cq_h = send_cq_h;
        cloned_qp.recv_cq_h = recv_cq_h;
        cloned_qp.srq_h = srq_h;
      end
    endcase
    return cloned_qp;
  endfunction
endclass

class rdma_rm_fault_srq extends rdma_srq;
  `uvm_object_utils(rdma_rm_fault_srq)
  rdma_rm_kind_clone_fault_e clone_fault;
  function new(string name = "rdma_rm_fault_srq");
    super.new(name);
    clone_fault = RDMA_RM_KIND_CLONE_GOOD;
  endfunction
  virtual function uvm_object clone();
    uvm_object cloned_object;
    rdma_rm_fault_srq cloned_srq;
    cloned_object = super.clone();
    if (!$cast(cloned_srq, cloned_object))
      `uvm_fatal("RM_TEST_CLONE", "fault SRQ clone cast failed")
    case (clone_fault)
      RDMA_RM_KIND_CLONE_VALUE_DRIFT: begin
        cloned_srq.max_sge++;
      end
      RDMA_RM_KIND_CLONE_SHALLOW_HANDLES: cloned_srq.pd_h = pd_h;
    endcase
    return cloned_srq;
  endfunction
endclass

class rdma_rm_fault_cmq extends rdma_cmq;
  `uvm_object_utils(rdma_rm_fault_cmq)
  rdma_rm_kind_clone_fault_e clone_fault;
  function new(string name = "rdma_rm_fault_cmq");
    super.new(name);
    clone_fault = RDMA_RM_KIND_CLONE_GOOD;
  endfunction
  virtual function uvm_object clone();
    uvm_object cloned_object;
    rdma_rm_fault_cmq cloned_cmq;
    cloned_object = super.clone();
    if (!$cast(cloned_cmq, cloned_object))
      `uvm_fatal("RM_TEST_CLONE", "fault CMQ clone cast failed")
    if (clone_fault == RDMA_RM_KIND_CLONE_VALUE_DRIFT) begin
      cloned_cmq.completion_iova.value++;
    end
    return cloned_cmq;
  endfunction
endclass

class rdma_rm_fault_ceq extends rdma_ceq;
  `uvm_object_utils(rdma_rm_fault_ceq)
  rdma_rm_kind_clone_fault_e clone_fault;
  function new(string name = "rdma_rm_fault_ceq");
    super.new(name);
    clone_fault = RDMA_RM_KIND_CLONE_GOOD;
  endfunction
  virtual function uvm_object clone();
    uvm_object cloned_object;
    rdma_rm_fault_ceq cloned_ceq;
    cloned_object = super.clone();
    if (!$cast(cloned_ceq, cloned_object))
      `uvm_fatal("RM_TEST_CLONE", "fault CEQ clone cast failed")
    if (clone_fault == RDMA_RM_KIND_CLONE_VALUE_DRIFT) begin
      cloned_ceq.queue_iova.value++;
    end
    return cloned_ceq;
  endfunction
endclass

class rdma_rm_fault_aeq extends rdma_aeq;
  `uvm_object_utils(rdma_rm_fault_aeq)
  rdma_rm_kind_clone_fault_e clone_fault;
  function new(string name = "rdma_rm_fault_aeq");
    super.new(name);
    clone_fault = RDMA_RM_KIND_CLONE_GOOD;
  endfunction
  virtual function uvm_object clone();
    uvm_object cloned_object;
    rdma_rm_fault_aeq cloned_aeq;
    cloned_object = super.clone();
    if (!$cast(cloned_aeq, cloned_object))
      `uvm_fatal("RM_TEST_CLONE", "fault AEQ clone cast failed")
    if (clone_fault == RDMA_RM_KIND_CLONE_VALUE_DRIFT) begin
      cloned_aeq.queue_iova.value++;
    end
    return cloned_aeq;
  endfunction
endclass

class rdma_rm_fault_recovery extends rdma_recovery_record;
  `uvm_object_utils(rdma_rm_fault_recovery)

  rdma_rm_clone_fault_e clone_fault;

  function new(string name = "rdma_rm_fault_recovery");
    super.new(name);
    clone_fault = RDMA_RM_CLONE_GOOD;
  endfunction

  virtual function uvm_object clone();
    uvm_object cloned_object;
    rdma_rm_fault_recovery cloned_recovery;
    rdma_cmq_ticket saved_ticket;

    case (clone_fault)
      RDMA_RM_CLONE_SELF: return this;
      RDMA_RM_CLONE_DRIFT: begin
        cloned_object = super.clone();
        if (!$cast(cloned_recovery, cloned_object))
          `uvm_fatal("RM_TEST_CLONE", "fault recovery clone cast failed")
        cloned_recovery.resource_h.object_id++;
        return cloned_recovery;
      end
      RDMA_RM_CLONE_BACKING_DRIFT: begin
        cloned_object = super.clone();
        if (!$cast(cloned_recovery, cloned_object) ||
            cloned_recovery.backing_refs.size() == 0 ||
            cloned_recovery.backing_refs[0] == null ||
            cloned_recovery.backing_refs[0].mapping == null)
          `uvm_fatal("RM_TEST_CLONE",
                     "fault recovery backing clone setup failed")
        cloned_recovery.backing_refs[0].mapping.iova.value++;
        return cloned_recovery;
      end
      RDMA_RM_CLONE_HMC_DRIFT: begin
        cloned_object = super.clone();
        if (!$cast(cloned_recovery, cloned_object) ||
            cloned_recovery.hmc_refs.size() == 0 ||
            cloned_recovery.hmc_refs[0] == null)
          `uvm_fatal("RM_TEST_CLONE",
                     "fault recovery HMC clone setup failed")
        cloned_recovery.hmc_refs[0].address.value++;
        return cloned_recovery;
      end
      RDMA_RM_CLONE_SHALLOW_RECOVERY_RESOURCE_HANDLE: begin
        cloned_object = super.clone();
        if (!$cast(cloned_recovery, cloned_object))
          `uvm_fatal("RM_TEST_CLONE", "fault recovery clone cast failed")
        cloned_recovery.resource_h = resource_h;
        return cloned_recovery;
      end
      RDMA_RM_CLONE_SHALLOW_RECOVERY_BACKING_REF: begin
        cloned_object = super.clone();
        if (!$cast(cloned_recovery, cloned_object) ||
            backing_refs.size() == 0)
          `uvm_fatal("RM_TEST_CLONE",
                     "fault recovery backing reference setup failed")
        cloned_recovery.backing_refs[0] = backing_refs[0];
        return cloned_recovery;
      end
      RDMA_RM_CLONE_SHALLOW_RECOVERY_MAPPING: begin
        cloned_object = super.clone();
        if (!$cast(cloned_recovery, cloned_object) ||
            backing_refs.size() == 0 || backing_refs[0] == null)
          `uvm_fatal("RM_TEST_CLONE",
                     "fault recovery mapping setup failed")
        cloned_recovery.backing_refs[0].mapping = backing_refs[0].mapping;
        return cloned_recovery;
      end
      RDMA_RM_CLONE_SHALLOW_RECOVERY_MAPPING_FUNCTION: begin
        cloned_object = super.clone();
        if (!$cast(cloned_recovery, cloned_object) ||
            backing_refs.size() == 0 || backing_refs[0] == null ||
            backing_refs[0].mapping == null)
          `uvm_fatal("RM_TEST_CLONE",
                     "fault recovery mapping Function setup failed")
        cloned_recovery.backing_refs[0].mapping.function_h =
          backing_refs[0].mapping.function_h;
        return cloned_recovery;
      end
      RDMA_RM_CLONE_SHALLOW_RECOVERY_MAPPING_OWNER: begin
        cloned_object = super.clone();
        if (!$cast(cloned_recovery, cloned_object) ||
            backing_refs.size() == 0 || backing_refs[0] == null ||
            backing_refs[0].mapping == null)
          `uvm_fatal("RM_TEST_CLONE",
                     "fault recovery mapping owner setup failed")
        cloned_recovery.backing_refs[0].mapping.owner_h =
          backing_refs[0].mapping.owner_h;
        return cloned_recovery;
      end
      RDMA_RM_CLONE_SHALLOW_RECOVERY_HMC_REF: begin
        cloned_object = super.clone();
        if (!$cast(cloned_recovery, cloned_object) || hmc_refs.size() == 0)
          `uvm_fatal("RM_TEST_CLONE",
                     "fault recovery HMC reference setup failed")
        cloned_recovery.hmc_refs[0] = hmc_refs[0];
        return cloned_recovery;
      end
      RDMA_RM_CLONE_SHALLOW_RECOVERY_HMC_OWNER: begin
        cloned_object = super.clone();
        if (!$cast(cloned_recovery, cloned_object) || hmc_refs.size() == 0 ||
            hmc_refs[0] == null)
          `uvm_fatal("RM_TEST_CLONE",
                     "fault recovery HMC owner setup failed")
        cloned_recovery.hmc_refs[0].owner = hmc_refs[0].owner;
        return cloned_recovery;
      end
      RDMA_RM_CLONE_SHALLOW_RECOVERY_TICKET: begin
        cloned_object = super.clone();
        if (!$cast(cloned_recovery, cloned_object))
          `uvm_fatal("RM_TEST_CLONE", "fault recovery clone cast failed")
        cloned_recovery.ambiguous_ticket = ambiguous_ticket;
        return cloned_recovery;
      end
      RDMA_RM_CLONE_SHALLOW_RECOVERY_TICKET_FUNCTION: begin
        cloned_object = super.clone();
        if (!$cast(cloned_recovery, cloned_object) ||
            ambiguous_ticket == null)
          `uvm_fatal("RM_TEST_CLONE",
                     "fault recovery ticket Function setup failed")
        cloned_recovery.ambiguous_ticket.function_h =
          ambiguous_ticket.function_h;
        return cloned_recovery;
      end
      RDMA_RM_CLONE_SHALLOW_RECOVERY_TICKET_CMQ: begin
        cloned_object = super.clone();
        if (!$cast(cloned_recovery, cloned_object) ||
            ambiguous_ticket == null)
          `uvm_fatal("RM_TEST_CLONE",
                     "fault recovery ticket CMQ setup failed")
        cloned_recovery.ambiguous_ticket.cmq_h = ambiguous_ticket.cmq_h;
        return cloned_recovery;
      end
      RDMA_RM_CLONE_SHALLOW_RECOVERY_TICKET_OPCODE: begin
        cloned_object = super.clone();
        if (!$cast(cloned_recovery, cloned_object) ||
            ambiguous_ticket == null)
          `uvm_fatal("RM_TEST_CLONE",
                     "fault recovery ticket opcode setup failed")
        cloned_recovery.ambiguous_ticket.opcode_key =
          ambiguous_ticket.opcode_key;
        return cloned_recovery;
      end
      RDMA_RM_CLONE_SHALLOW_RECOVERY_PRIMARY_STATUS: begin
        cloned_object = super.clone();
        if (!$cast(cloned_recovery, cloned_object))
          `uvm_fatal("RM_TEST_CLONE", "fault recovery clone cast failed")
        cloned_recovery.primary_status = primary_status;
        return cloned_recovery;
      end
      RDMA_RM_CLONE_SHALLOW_RECOVERY_ROLLBACK_STATUS: begin
        cloned_object = super.clone();
        if (!$cast(cloned_recovery, cloned_object) ||
            rollback_statuses.size() == 0)
          `uvm_fatal("RM_TEST_CLONE",
                     "fault recovery rollback status setup failed")
        cloned_recovery.rollback_statuses[0] = rollback_statuses[0];
        return cloned_recovery;
      end
      RDMA_RM_CLONE_RECOVERY_TICKET_DRIFT: begin
        cloned_object = super.clone();
        if (!$cast(cloned_recovery, cloned_object) ||
            cloned_recovery.ambiguous_ticket == null)
          `uvm_fatal("RM_TEST_CLONE",
                     "fault recovery ticket drift setup failed")
        cloned_recovery.ambiguous_ticket.command_id++;
        return cloned_recovery;
      end
      RDMA_RM_CLONE_RECOVERY_STEPS_DRIFT: begin
        cloned_object = super.clone();
        if (!$cast(cloned_recovery, cloned_object) ||
            cloned_recovery.completed_steps.size() == 0)
          `uvm_fatal("RM_TEST_CLONE",
                     "fault recovery step drift setup failed")
        cloned_recovery.completed_steps[0] =
          RDMA_CTRL_STEP_BACKING_ATTACHED;
        return cloned_recovery;
      end
      RDMA_RM_CLONE_RECOVERY_PRIMARY_HIDDEN_HW_DRIFT: begin
        cloned_object = super.clone();
        if (!$cast(cloned_recovery, cloned_object) ||
            cloned_recovery.primary_status == null)
          `uvm_fatal("RM_TEST_CLONE",
                     "fault recovery primary status setup failed")
        cloned_recovery.primary_status.hardware_code++;
        return cloned_recovery;
      end
      RDMA_RM_CLONE_RECOVERY_ROLLBACK_STATUS_DRIFT: begin
        cloned_object = super.clone();
        if (!$cast(cloned_recovery, cloned_object) ||
            cloned_recovery.rollback_statuses.size() == 0 ||
            cloned_recovery.rollback_statuses[0] == null)
          `uvm_fatal("RM_TEST_CLONE",
                     "fault recovery rollback status drift setup failed")
        cloned_recovery.rollback_statuses[0].retryable =
          !cloned_recovery.rollback_statuses[0].retryable;
        return cloned_recovery;
      end
      RDMA_RM_CLONE_MUTATE_SOURCE_SCALAR: begin
        cloned_object = super.clone();
        if (!$cast(cloned_recovery, cloned_object))
          `uvm_fatal("RM_TEST_CLONE", "fault recovery clone cast failed")
        hardware_presence = RDMA_HW_PRESENCE_PRESENT;
        return cloned_recovery;
      end
      RDMA_RM_CLONE_LAUNDER_SOURCE_CHILD: begin
        saved_ticket = ambiguous_ticket;
        cloned_object = super.clone();
        if (!$cast(cloned_recovery, cloned_object))
          `uvm_fatal("RM_TEST_CLONE", "fault recovery clone cast failed")
        ambiguous_ticket = cloned_recovery.ambiguous_ticket;
        cloned_recovery.ambiguous_ticket = saved_ticket;
        return cloned_recovery;
      end
      default: return super.clone();
    endcase
  endfunction
endclass

class rdma_rm_schema_mr extends rdma_mr;
  `uvm_object_utils(rdma_rm_schema_mr)

  int unsigned clone_calls;
  int unsigned extra_scalar;
  rdma_handle extra_child;

  function new(string name = "rdma_rm_schema_mr");
    super.new(name);
    clone_calls = 0;
    extra_scalar = 32'h51a7_e001;
    extra_child = null;
  endfunction

  virtual function uvm_object clone();
    clone_calls++;
    return super.clone();
  endfunction
endclass

class rdma_rm_schema_recovery extends rdma_recovery_record;
  `uvm_object_utils(rdma_rm_schema_recovery)

  int unsigned clone_calls;
  int unsigned extra_scalar;
  rdma_handle extra_child;

  function new(string name = "rdma_rm_schema_recovery");
    super.new(name);
    clone_calls = 0;
    extra_scalar = 32'h51a7_e002;
    extra_child = null;
  endfunction

  virtual function uvm_object clone();
    clone_calls++;
    return super.clone();
  endfunction
endclass

class rdma_rm_schema_handle extends rdma_handle;
  `uvm_object_utils(rdma_rm_schema_handle)

  int unsigned clone_calls;

  function new(string name = "rdma_rm_schema_handle");
    super.new(name);
    clone_calls = 0;
  endfunction

  virtual function uvm_object clone();
    clone_calls++;
    return super.clone();
  endfunction
endclass

class rdma_rm_schema_function_handle extends rdma_function_handle;
  `uvm_object_utils(rdma_rm_schema_function_handle)

  int unsigned clone_calls;

  function new(string name = "rdma_rm_schema_function_handle");
    super.new(name);
    clone_calls = 0;
  endfunction

  virtual function uvm_object clone();
    clone_calls++;
    return super.clone();
  endfunction
endclass

class rdma_rm_schema_backing_ref extends rdma_backing_ref;
  `uvm_object_utils(rdma_rm_schema_backing_ref)

  int unsigned clone_calls;

  function new(string name = "rdma_rm_schema_backing_ref");
    super.new(name);
    clone_calls = 0;
  endfunction

  virtual function uvm_object clone();
    clone_calls++;
    return super.clone();
  endfunction
endclass

class rdma_rm_schema_mapping extends rdma_dma_mapping;
  `uvm_object_utils(rdma_rm_schema_mapping)

  int unsigned clone_calls;

  function new(string name = "rdma_rm_schema_mapping");
    super.new(name);
    clone_calls = 0;
  endfunction

  virtual function uvm_object clone();
    clone_calls++;
    return super.clone();
  endfunction
endclass

class rdma_rm_owned_alias_mapping extends rdma_dma_mapping;
  `uvm_object_utils(rdma_rm_owned_alias_mapping)

  int unsigned clone_calls;
  local longint unsigned allocation_token;
  local static longint unsigned next_allocation_token = 1;

  function new(string name = "rdma_rm_owned_alias_mapping");
    super.new(name);
    clone_calls = 0;
    allocation_token = next_allocation_token;
    next_allocation_token++;
  endfunction

  virtual function rdma_status snapshot_release_authority(
    output rdma_dma_mapping snapshot
  );
    rdma_rm_owned_alias_mapping candidate;

    candidate = rdma_rm_owned_alias_mapping::type_id::create(
      {get_name(), "_authority"}
    );
    candidate.allocation_token = allocation_token;
    snapshot = candidate;
    return rdma_status::success();
  endfunction

  virtual function rdma_status release_authority_status(
    rdma_dma_mapping snapshot
  );
    rdma_rm_owned_alias_mapping candidate;

    if (!$cast(candidate, snapshot) || candidate == null ||
        candidate.allocation_token != allocation_token)
      return rdma_status::make(
        RDMA_SC_INVALID_ARGUMENT, "test alias allocation authority changed"
      );
    return rdma_status::success();
  endfunction

  virtual function uvm_object clone();
    clone_calls++;
    return this;
  endfunction
endclass

class rdma_rm_owned_drift_mapping extends rdma_dma_mapping;
  `uvm_object_utils(rdma_rm_owned_drift_mapping)

  int unsigned clone_calls;
  local longint unsigned allocation_token;
  local static longint unsigned next_allocation_token = 1;

  function new(string name = "rdma_rm_owned_drift_mapping");
    super.new(name);
    clone_calls = 0;
    allocation_token = next_allocation_token;
    next_allocation_token++;
  endfunction

  virtual function rdma_status snapshot_release_authority(
    output rdma_dma_mapping snapshot
  );
    rdma_rm_owned_drift_mapping candidate;

    candidate = rdma_rm_owned_drift_mapping::type_id::create(
      {get_name(), "_authority"}
    );
    candidate.allocation_token = allocation_token;
    snapshot = candidate;
    return rdma_status::success();
  endfunction

  virtual function rdma_status release_authority_status(
    rdma_dma_mapping snapshot
  );
    rdma_rm_owned_drift_mapping candidate;

    if (!$cast(candidate, snapshot) || candidate == null ||
        candidate.allocation_token != allocation_token)
      return rdma_status::make(
        RDMA_SC_INVALID_ARGUMENT, "test drift allocation authority changed"
      );
    return rdma_status::success();
  endfunction

  virtual function void do_copy(uvm_object rhs);
    rdma_rm_owned_drift_mapping rhs_mapping;

    super.do_copy(rhs);
    if (!$cast(rhs_mapping, rhs) || rhs_mapping == null)
      `uvm_fatal("RM_OWNED_COPY", "drift mapping copy cast failed")
    allocation_token = rhs_mapping.allocation_token;
  endfunction

  virtual function uvm_object clone();
    uvm_object cloned_object;
    rdma_rm_owned_drift_mapping result;

    clone_calls++;
    cloned_object = super.clone();
    if (!$cast(result, cloned_object))
      `uvm_fatal("RM_OWNED_CLONE", "drift mapping clone cast failed")
    result.size++;
    return result;
  endfunction
endclass

// Registered exact-type clone whose public fields remain stable while its
// controlled do_copy() override silently drops private release authority.
class rdma_rm_owned_authority_loss_mapping extends rdma_dma_mapping;
  `uvm_object_utils(rdma_rm_owned_authority_loss_mapping)

  local longint unsigned allocation_token;
  local bit allocation_token_initialized;
  local bit drop_allocation_token_on_copy;

  function new(string name = "rdma_rm_owned_authority_loss_mapping");
    super.new(name);
    allocation_token = 0;
    allocation_token_initialized = 1'b0;
    drop_allocation_token_on_copy = 1'b1;
  endfunction

  function void initialize_allocation_token(longint unsigned token);
    allocation_token = token;
    allocation_token_initialized = 1'b1;
  endfunction

  function void set_drop_allocation_token_on_copy(bit drop_token);
    drop_allocation_token_on_copy = drop_token;
  endfunction

  virtual function void do_copy(uvm_object rhs);
    rdma_rm_owned_authority_loss_mapping rhs_mapping;

    super.do_copy(rhs);
    if (!$cast(rhs_mapping, rhs) || rhs_mapping == null)
      `uvm_fatal("RM_OWNED_COPY", "authority-loss mapping copy cast failed")
    drop_allocation_token_on_copy =
      rhs_mapping.drop_allocation_token_on_copy;
    if (!rhs_mapping.drop_allocation_token_on_copy) begin
      allocation_token = rhs_mapping.allocation_token;
      allocation_token_initialized = rhs_mapping.allocation_token_initialized;
    end
  endfunction

  virtual function rdma_status snapshot_release_authority(
    output rdma_dma_mapping snapshot
  );
    rdma_rm_owned_authority_loss_mapping candidate;

    snapshot = null;
    if (!allocation_token_initialized)
      return rdma_status::make(
        RDMA_SC_INVALID_STATE, "test allocation token is not initialized"
      );
    candidate = rdma_rm_owned_authority_loss_mapping::type_id::create(
      {get_name(), "_authority"}
    );
    candidate.allocation_token = allocation_token;
    candidate.allocation_token_initialized = 1'b1;
    snapshot = candidate;
    return rdma_status::success();
  endfunction

  virtual function rdma_status release_authority_status(
    rdma_dma_mapping snapshot
  );
    rdma_rm_owned_authority_loss_mapping candidate;

    if (!$cast(candidate, snapshot) || candidate == null ||
        !allocation_token_initialized ||
        !candidate.allocation_token_initialized ||
        allocation_token != candidate.allocation_token)
      return rdma_status::make(
        RDMA_SC_INVALID_ARGUMENT, "test allocation authority changed"
      );
    return rdma_status::success();
  endfunction
endclass

typedef enum bit [1:0] {
  RDMA_RM_AUTHORITY_HOOK_STABLE,
  RDMA_RM_AUTHORITY_HOOK_MUTATE_SOURCE,
  RDMA_RM_AUTHORITY_HOOK_MUTATE_RESULT,
  RDMA_RM_AUTHORITY_HOOK_MUTATE_COMPLETION
} rdma_rm_authority_hook_fault_e;

class rdma_rm_authority_hook_controller extends uvm_object;
  rdma_rm_authority_hook_fault_e fault;
  rdma_dma_mapping original;
  rdma_dma_mapping clone_result;

  function new(string name = "rdma_rm_authority_hook_controller");
    super.new(name);
    fault = RDMA_RM_AUTHORITY_HOOK_STABLE;
    original = null;
    clone_result = null;
  endfunction
endclass

// A registered mapping whose authority comparison remains successful while a
// selected virtual hook mutates a public value field.
class rdma_rm_owned_authority_hook_mapping extends rdma_dma_mapping;
  `uvm_object_utils(rdma_rm_owned_authority_hook_mapping)

  local longint unsigned allocation_token;
  local bit allocation_token_initialized;
  local rdma_rm_authority_hook_controller controller;

  function new(string name = "rdma_rm_owned_authority_hook_mapping");
    super.new(name);
    allocation_token = 0;
    allocation_token_initialized = 1'b0;
    controller = null;
  endfunction

  function void initialize_allocation_token(longint unsigned token);
    allocation_token = token;
    allocation_token_initialized = 1'b1;
    controller = new({get_name(), "_controller"});
    controller.original = this;
  endfunction

  function void set_authority_hook_fault(
    rdma_rm_authority_hook_fault_e fault
  );
    if (controller == null)
      `uvm_fatal("RM_AUTHORITY_HOOK", "hook controller is not initialized")
    controller.fault = fault;
  endfunction

  virtual function rdma_status snapshot_release_authority(
    output rdma_dma_mapping snapshot
  );
    rdma_rm_owned_authority_hook_mapping candidate;

    snapshot = null;
    if (!allocation_token_initialized)
      return rdma_status::make(
        RDMA_SC_INVALID_STATE, "test allocation token is not initialized"
      );
    candidate = rdma_rm_owned_authority_hook_mapping::type_id::create(
      {get_name(), "_authority"}
    );
    candidate.allocation_token = allocation_token;
    candidate.allocation_token_initialized = 1'b1;
    snapshot = candidate;
    return rdma_status::success();
  endfunction

  virtual function rdma_status release_authority_status(
    rdma_dma_mapping snapshot
  );
    rdma_rm_owned_authority_hook_mapping candidate;

    if (!$cast(candidate, snapshot) || candidate == null ||
        !allocation_token_initialized ||
        !candidate.allocation_token_initialized ||
        allocation_token != candidate.allocation_token)
      return rdma_status::make(
        RDMA_SC_INVALID_ARGUMENT, "test allocation authority changed"
      );
    if (controller != null) begin
      if (controller.fault == RDMA_RM_AUTHORITY_HOOK_MUTATE_SOURCE &&
          this == controller.original)
        size++;
      else if (controller.fault == RDMA_RM_AUTHORITY_HOOK_MUTATE_RESULT &&
               this == controller.clone_result)
        size++;
    end
    return rdma_status::success();
  endfunction

  virtual function rdma_status release_completion_status(
    output bit release_complete
  );
    release_complete = 1'b0;
    if (controller == null)
      return rdma_status::make(
        RDMA_SC_INVALID_STATE, "hook controller is not initialized"
      );
    if (controller.fault == RDMA_RM_AUTHORITY_HOOK_MUTATE_COMPLETION) begin
      size++;
      release_complete = 1'b1;
    end
    return rdma_status::success();
  endfunction

  virtual function uvm_object clone();
    uvm_object cloned_object;
    rdma_rm_owned_authority_hook_mapping result;

    cloned_object = super.clone();
    if (!$cast(result, cloned_object) || result == null)
      `uvm_fatal("RM_AUTHORITY_HOOK", "hook mapping clone cast failed")
    if (controller != null)
      controller.clone_result = result;
    return result;
  endfunction

  virtual function void do_copy(uvm_object rhs);
    rdma_rm_owned_authority_hook_mapping rhs_mapping;

    super.do_copy(rhs);
    if (!$cast(rhs_mapping, rhs) || rhs_mapping == null)
      `uvm_fatal("RM_AUTHORITY_HOOK", "hook mapping copy cast failed")
    allocation_token = rhs_mapping.allocation_token;
    allocation_token_initialized = rhs_mapping.allocation_token_initialized;
    controller = rhs_mapping.controller;
  endfunction
endclass

class rdma_rm_schema_hmc_ref extends rdma_hmc_ref;
  `uvm_object_utils(rdma_rm_schema_hmc_ref)

  int unsigned clone_calls;

  function new(string name = "rdma_rm_schema_hmc_ref");
    super.new(name);
    clone_calls = 0;
  endfunction

  virtual function uvm_object clone();
    clone_calls++;
    return super.clone();
  endfunction
endclass

class rdma_rm_schema_binding extends rdma_function_binding;
  `uvm_object_utils(rdma_rm_schema_binding)

  int unsigned clone_calls;

  function new(string name = "rdma_rm_schema_binding");
    super.new(name);
    clone_calls = 0;
  endfunction

  virtual function uvm_object clone();
    clone_calls++;
    return super.clone();
  endfunction
endclass

class rdma_rm_schema_pcie extends rdma_pcie_identity;
  `uvm_object_utils(rdma_rm_schema_pcie)

  int unsigned clone_calls;

  function new(string name = "rdma_rm_schema_pcie");
    super.new(name);
    clone_calls = 0;
  endfunction

  virtual function uvm_object clone();
    clone_calls++;
    return super.clone();
  endfunction
endclass

class rdma_rm_schema_bar extends rdma_bar_info;
  `uvm_object_utils(rdma_rm_schema_bar)

  int unsigned clone_calls;

  function new(string name = "rdma_rm_schema_bar");
    super.new(name);
    clone_calls = 0;
  endfunction

  virtual function uvm_object clone();
    clone_calls++;
    return super.clone();
  endfunction
endclass

class rdma_rm_schema_ticket extends rdma_cmq_ticket;
  `uvm_object_utils(rdma_rm_schema_ticket)

  int unsigned clone_calls;

  function new(string name = "rdma_rm_schema_ticket");
    super.new(name);
    clone_calls = 0;
  endfunction

  virtual function uvm_object clone();
    clone_calls++;
    return super.clone();
  endfunction
endclass

class rdma_rm_schema_opcode extends rdma_cmq_opcode_key;
  `uvm_object_utils(rdma_rm_schema_opcode)

  int unsigned clone_calls;

  function new(string name = "rdma_rm_schema_opcode");
    super.new(name);
    clone_calls = 0;
  endfunction

  virtual function uvm_object clone();
    clone_calls++;
    return super.clone();
  endfunction
endclass

class rdma_rm_schema_status extends rdma_status;
  `uvm_object_utils(rdma_rm_schema_status)

  int unsigned clone_calls;

  function new(string name = "rdma_rm_schema_status");
    super.new(name);
    clone_calls = 0;
  endfunction

  virtual function uvm_object clone();
    clone_calls++;
    return super.clone();
  endfunction
endclass

class rdma_rm_stateful_mr extends rdma_mr;
  `uvm_object_utils(rdma_rm_stateful_mr)

  int unsigned clone_calls;

  function new(string name = "rdma_rm_stateful_mr");
    super.new(name);
    clone_calls = 0;
  endfunction

  virtual function uvm_object clone();
    uvm_object cloned_object;
    rdma_rm_stateful_mr cloned_mr;

    clone_calls++;
    cloned_object = super.clone();
    if (clone_calls > 1) begin
      if (!$cast(cloned_mr, cloned_object))
        `uvm_fatal("RM_TEST_SCHEMA", "stateful MR clone cast failed")
      cloned_mr.length++;
    end
    return cloned_object;
  endfunction
endclass

// These carriers model the two ways wrapper identity can be spoofed.  The
// unregistered subclasses inherit the built-in wrapper, while the registered
// subclasses deliberately report the built-in wrapper.  Neither extension is
// authoritative at the resource-manager boundary.
class rdma_rm_unregistered_mr extends rdma_mr;
  int unsigned clone_calls;
  int unsigned extra_scalar;
  rdma_handle extra_child;

  function new(string name = "rdma_rm_unregistered_mr");
    super.new(name);
    clone_calls = 0;
    extra_scalar = 32'hc011_a001;
    extra_child = null;
  endfunction

  virtual function uvm_object clone();
    uvm_object result;

    clone_calls++;
    result = super.clone();
    length++;
    return result;
  endfunction
endclass

class rdma_rm_lying_mr extends rdma_mr;
  typedef uvm_object_registry#(rdma_rm_lying_mr,
                               "rdma_rm_lying_mr") type_id;

  static function type_id get_type();
    return type_id::get();
  endfunction

  int unsigned clone_calls;
  int unsigned extra_scalar;
  rdma_handle extra_child;

  function new(string name = "rdma_rm_lying_mr");
    super.new(name);
    clone_calls = 0;
    extra_scalar = 32'hc011_a002;
    extra_child = null;
  endfunction

  virtual function uvm_object_wrapper get_object_type();
    return rdma_mr::get_type();
  endfunction

  virtual function uvm_object clone();
    uvm_object result;

    clone_calls++;
    result = super.clone();
    length++;
    return result;
  endfunction
endclass

class rdma_rm_unregistered_mapping extends rdma_dma_mapping;
  int unsigned clone_calls;
  int unsigned extra_scalar;
  rdma_handle extra_child;

  function new(string name = "rdma_rm_unregistered_mapping");
    super.new(name);
    clone_calls = 0;
    extra_scalar = 32'hc011_b001;
    extra_child = null;
  endfunction

  virtual function uvm_object clone();
    uvm_object result;

    clone_calls++;
    result = super.clone();
    size++;
    return result;
  endfunction
endclass

// Inherits the built-in wrapper and clone implementation without changing any
// source or public mapping value.  Its clone therefore collapses to the base
// rdma_dma_mapping type unless the owned-capability boundary rejects it.
class rdma_rm_stable_unregistered_mapping extends rdma_dma_mapping;
  function new(string name = "rdma_rm_stable_unregistered_mapping");
    super.new(name);
  endfunction
endclass

class rdma_rm_lying_mapping extends rdma_dma_mapping;
  typedef uvm_object_registry#(rdma_rm_lying_mapping,
                               "rdma_rm_lying_mapping") type_id;

  static function type_id get_type();
    return type_id::get();
  endfunction

  int unsigned clone_calls;
  int unsigned extra_scalar;
  rdma_handle extra_child;

  function new(string name = "rdma_rm_lying_mapping");
    super.new(name);
    clone_calls = 0;
    extra_scalar = 32'hc011_b002;
    extra_child = null;
  endfunction

  virtual function uvm_object_wrapper get_object_type();
    return rdma_dma_mapping::get_type();
  endfunction

  virtual function uvm_object clone();
    uvm_object result;

    clone_calls++;
    result = super.clone();
    size++;
    return result;
  endfunction
endclass

class rdma_rm_unregistered_recovery extends rdma_recovery_record;
  int unsigned clone_calls;
  int unsigned extra_scalar;
  rdma_handle extra_child;

  function new(string name = "rdma_rm_unregistered_recovery");
    super.new(name);
    clone_calls = 0;
    extra_scalar = 32'hc011_c001;
    extra_child = null;
  endfunction

  virtual function uvm_object clone();
    uvm_object result;

    clone_calls++;
    result = super.clone();
    hardware_presence = RDMA_HW_PRESENCE_PRESENT;
    return result;
  endfunction
endclass

class rdma_rm_lying_recovery extends rdma_recovery_record;
  typedef uvm_object_registry#(rdma_rm_lying_recovery,
                               "rdma_rm_lying_recovery") type_id;

  static function type_id get_type();
    return type_id::get();
  endfunction

  int unsigned clone_calls;
  int unsigned extra_scalar;
  rdma_handle extra_child;

  function new(string name = "rdma_rm_lying_recovery");
    super.new(name);
    clone_calls = 0;
    extra_scalar = 32'hc011_c002;
    extra_child = null;
  endfunction

  virtual function uvm_object_wrapper get_object_type();
    return rdma_recovery_record::get_type();
  endfunction

  virtual function uvm_object clone();
    uvm_object result;

    clone_calls++;
    result = super.clone();
    hardware_presence = RDMA_HW_PRESENCE_PRESENT;
    return result;
  endfunction
endclass

class rdma_clone_probe_manager extends rdma_resource_manager;
  function new(string name = "rdma_clone_probe_manager");
    super.new(name);
  endfunction

  function void replace_authoritative(rdma_resource replacement);
    registry[resource_key(replacement.handle)] = replacement;
  endfunction

  function rdma_resource observed_resource_probe(rdma_handle handle);
    string key;

    key = resource_key(handle);
    if (!registry.exists(key))
      return null;
    return registry[key];
  endfunction

  function int unsigned observed_generation_high_water(
    rdma_function_handle owner
  );
    string key;

    key = function_key(owner);
    if (!generation_high_water.exists(key))
      return 0;
    return generation_high_water[key];
  endfunction

  function void reset_publication_probe(rdma_resource replacement,
                                        bit staged);
    string key;

    key = resource_key(replacement.handle);
    registry[key] = replacement;
    if (staged)
      staged_allocations[key] = 1'b1;
    else
      staged_allocations.delete(key);
  endfunction

  function rdma_status probe_public_resource_projection(
    rdma_resource source,
    output rdma_resource result
  );
    return project_public_resource_value(source, "projection gate probe",
                                         result);
  endfunction

  function void reset_error_probe(rdma_resource replacement);
    string key;
    rdma_resource replacement_copy;
    rdma_status status;

    key = resource_key(replacement.handle);
    status = project_resource_value(replacement, "error probe reset",
                                    replacement_copy);
    if (!status.ok())
      `uvm_fatal("RM_TEST_SCHEMA", status.convert2string())
    registry[key] = replacement_copy;
    recovery_records.delete(key);
  endfunction

  function void inject_recovery_probe(
    rdma_handle handle,
    rdma_recovery_record recovery
  );
    recovery_records[resource_key(handle)] = recovery;
  endfunction

  function rdma_recovery_record observed_recovery_probe(rdma_handle handle);
    string key;

    key = resource_key(handle);
    if (!recovery_records.exists(key))
      return null;
    return recovery_records[key];
  endfunction
endclass

class rdma_resource_manager_test extends uvm_test;
  `uvm_component_utils(rdma_resource_manager_test)

  function new(string name = "rdma_resource_manager_test",
               uvm_component parent = null);
    super.new(name, parent);
  endfunction

  function automatic void expect_status(
    string check_name,
    rdma_status status,
    rdma_status_code_e expected_code
  );
    if (status == null) begin
      `uvm_error(check_name, "resource API returned a null status")
      return;
    end
    if (status.code != expected_code)
      `uvm_error(check_name,
                 $sformatf("expected %s, got %s (%s)",
                           expected_code.name(), status.code.name(),
                           status.convert2string()))
  endfunction

  function automatic rdma_handle clone_handle(
    string check_name,
    rdma_handle source
  );
    uvm_object cloned_object;
    rdma_handle cloned_handle;

    if (source == null)
      `uvm_fatal(check_name, "cannot clone a null handle")
    cloned_object = source.clone();
    if (cloned_object == null || !$cast(cloned_handle, cloned_object))
      `uvm_fatal(check_name, "handle clone cast failed")
    return cloned_handle;
  endfunction

  function automatic rdma_function_handle clone_function_handle(
    string check_name,
    rdma_function_handle source
  );
    uvm_object cloned_object;
    rdma_function_handle cloned_handle;

    if (source == null)
      `uvm_fatal(check_name, "cannot clone a null function handle")
    cloned_object = source.clone();
    if (cloned_object == null || !$cast(cloned_handle, cloned_object))
      `uvm_fatal(check_name, "function handle clone cast failed")
    return cloned_handle;
  endfunction

  function automatic rdma_function_binding make_active_binding(
    string name,
    longint unsigned function_uid = 64'h0123_4567_89ab_cdef,
    int unsigned global_function_id = 32'h9000_0101,
    int unsigned generation = 32'd7
  );
    rdma_function_binding binding;
    rdma_interrupt_vector_binding vector;

    binding = rdma_function_binding::type_id::create(name);
    binding.function_uid = function_uid;
    binding.generation = generation;
    binding.global_function_id = global_function_id;
    binding.rdma_vf_id = 8'h22;
    binding.pfvf_id = 32'h9000_0303;
    binding.pcie.vf_index = 32'h8000_8080;
    binding.pcie.bdf = '{segment:16'h1001, bus:8'h20, device:5'h03,
                         function_num:3'h5};
    binding.pcie.parent_pf_bdf = '{segment:16'h2002, bus:8'h30,
                                   device:5'h04, function_num:3'h2};
    binding.pcie.bar[0].base.value = 64'h0000_0000_8000_0000;
    binding.pcie.bar[0].size = 64'h4000;
    binding.pcie.bar[0].enabled = 1'b1;
    binding.notify_bar_id = 3'd0;
    binding.notify_base.value = 64'h0000_0000_8000_2000;
    binding.notify_size = 64'h2000;
    binding.state = RDMA_BIND_ACTIVE;
    binding.owner_h = binding.make_handle();
    binding.queue_dma.requester_bdf = binding.pcie.bdf;
    binding.queue_dma.pasid_valid = 1'b1;
    binding.queue_dma.pasid = 20'he2251;
    binding.queue_dma.dma_domain_valid = 1'b1;
    binding.queue_dma.dma_domain_id = 32'h1122_3344;
    binding.queue_caps.min_cq_depth = 16;
    binding.queue_caps.max_cq_depth = 32768;
    binding.queue_caps.min_srq_depth = 16;
    binding.queue_caps.max_srq_depth = 32768;
    binding.queue_caps.max_ceq_depth = 4096;
    binding.queue_caps.max_aeq_depth = 4096;
    binding.queue_caps.max_wq_sge = 8;
    binding.queue_caps.max_queue_ring_bytes = 32'h0020_0000;
    binding.queue_caps.max_sgb_bytes = 32'h0040_0000;
    vector = '{default:'0};
    vector.function_local_vector = 3;
    vector.hardware_eq_vector = 17;
    vector.msix_table_index = 5;
    vector.enabled = 1'b1;
    binding.interrupt_vectors.push_back(vector);
    binding.pcie.mse = 1'b1;
    binding.pcie.bme = 1'b1;
    binding.notify_valid = 1'b1;
    binding.notify_ready = 1'b1;
    binding.dmi_valid = 1'b1;
    binding.dmi_ready = 1'b1;
    binding.vft_valid = 1'b1;
    binding.vft_ready = 1'b1;
    return binding;
  endfunction

  function automatic rdma_dma_mapping make_queue_test_mapping(
    string name,
    rdma_function_handle owner,
    rdma_handle owner_h,
    longint unsigned iova_value,
    bit control_plane_owned
  );
    rdma_dma_mapping mapping;
    rdma_rm_owned_authority_hook_mapping owned_mapping;

    if (control_plane_owned) begin
      owned_mapping =
        rdma_rm_owned_authority_hook_mapping::type_id::create(name);
      owned_mapping.initialize_allocation_token(iova_value);
      mapping = owned_mapping;
    end
    else begin
      mapping = rdma_dma_mapping::type_id::create(name);
    end
    mapping.function_h = clone_function_handle({name, "_function"}, owner);
    mapping.owner_h = clone_handle({name, "_owner"}, owner_h);
    mapping.iova.value = iova_value;
    mapping.backing_addr.value = iova_value + 64'h1000_0000;
    mapping.size = control_plane_owned ? 4096 : 64'h20_0000;
    mapping.direction = RDMA_DMA_BIDIRECTIONAL;
    mapping.permissions =
      '{device_read:1'b1, device_write:1'b1, atomic:1'b0};
    mapping.state = RDMA_MAPPING_ACTIVE;
    return mapping;
  endfunction

  function automatic rdma_dma_mapping make_independent_queue_test_mapping(
    string name,
    rdma_function_handle owner,
    rdma_handle owner_h,
    longint unsigned iova_value
  );
    rdma_rm_independent_release_mapping mapping;

    mapping = rdma_rm_independent_release_mapping::type_id::create(name);
    mapping.initialize_release_authority();
    mapping.function_h = clone_function_handle({name, "_function"}, owner);
    mapping.owner_h = clone_handle({name, "_owner"}, owner_h);
    mapping.iova.value = iova_value;
    mapping.backing_addr.value = iova_value + 64'h1000_0000;
    mapping.size = 4096;
    mapping.direction = RDMA_DMA_BIDIRECTIONAL;
    mapping.permissions =
      '{device_read:1'b1, device_write:1'b1, atomic:1'b0};
    mapping.state = RDMA_MAPPING_ACTIVE;
    return mapping;
  endfunction

  function automatic rdma_queue_ring_layout make_queue_test_ring(
    string name,
    rdma_queue_backing_role_e role,
    int unsigned depth,
    int unsigned entry_size_bytes,
    rdma_dma_mapping mapping
  );
    rdma_queue_ring_layout ring;
    rdma_queue_dma_page_ref page;
    longint unsigned logical_bytes;
    longint unsigned storage_bytes;

    logical_bytes = depth * entry_size_bytes;
    storage_bytes = ((logical_bytes + 4095) / 4096) * 4096;
    ring = rdma_queue_ring_layout::type_id::create(name);
    ring.role = role;
    ring.entry_size_bytes = entry_size_bytes;
    ring.depth = depth;
    ring.logical_bytes = logical_bytes;
    ring.storage_bytes = storage_bytes;
    ring.page_count = storage_bytes / 4096;
    ring.initial_polarity = 1'b1;
    for (int unsigned i = 0; i < ring.page_count; i++) begin
      page = rdma_queue_dma_page_ref::type_id::create(
        $sformatf("%s_page_%0d", name, i)
      );
      page.role = role;
      page.mapping = mapping;
      page.mapping_offset = i * 4096;
      page.logical_page_offset = i * 4096;
      page.page_iova.value = mapping.iova.value + i * 4096;
      ring.pages.push_back(page);
    end
    return ring;
  endfunction

  function automatic rdma_queue_backing_ref make_queue_test_ref(
    string name,
    rdma_queue_backing_role_e role,
    rdma_dma_mapping mapping,
    longint unsigned length,
    rdma_resource_ownership_e ownership
  );
    rdma_queue_backing_ref ref_value;

    ref_value = rdma_queue_backing_ref::type_id::create(name);
    ref_value.role = role;
    ref_value.mapping = mapping;
    ref_value.length = length;
    ref_value.ownership = ownership;
    return ref_value;
  endfunction

  function automatic rdma_cmq_opcode_key make_queue_test_opcode(
    string name,
    string variant
  );
    rdma_cmq_opcode_key opcode_key;

    opcode_key = rdma_cmq_opcode_key::type_id::create(name);
    opcode_key.profile_name = "generic_profile";
    opcode_key.variant = variant;
    return opcode_key;
  endfunction

  function automatic rdma_queue_backing_plan make_queue_test_plan(
    string name,
    rdma_resource_kind_e kind,
    int unsigned depth,
    rdma_function_handle owner,
    rdma_handle owner_h,
    int unsigned local_id
  );
    rdma_queue_backing_plan plan;
    rdma_queue_ring_layout ring;
    rdma_queue_backing_ref ring_ref;
    rdma_queue_backing_ref pd_ref;
    rdma_queue_flush_target flush_target;
    rdma_context_backing_ref context_ref;
    rdma_queue_opaque_slot_token token;
    rdma_queue_completion_authority completion_authority;
    rdma_hmc_ref hmc_ref;
    rdma_dma_mapping ring_mapping;
    rdma_dma_mapping pd_mapping;
    rdma_queue_backing_role_e ring_role;
    rdma_queue_backing_role_e pd_role;
    int unsigned entry_size;

    plan = rdma_queue_backing_plan::type_id::create(name);
    plan.resource_kind = kind;
    case (kind)
      RDMA_RESOURCE_CQ: begin
        ring_role = RDMA_QUEUE_ROLE_CQ_RING;
        pd_role = RDMA_QUEUE_ROLE_CQ_PD;
        entry_size = 64;
      end
      RDMA_RESOURCE_CEQ: begin
        ring_role = RDMA_QUEUE_ROLE_CEQ_RING;
        pd_role = RDMA_QUEUE_ROLE_CEQ_PD;
        entry_size = 16;
      end
      RDMA_RESOURCE_AEQ: begin
        ring_role = RDMA_QUEUE_ROLE_AEQ_RING;
        pd_role = RDMA_QUEUE_ROLE_AEQ_PD;
        entry_size = 16;
      end
      default: begin
        ring_role = RDMA_QUEUE_ROLE_SRQ_RING;
        pd_role = RDMA_QUEUE_ROLE_SRQ_PD;
        entry_size = 64;
      end
    endcase

    ring_mapping = make_queue_test_mapping(
      {name, "_ring_mapping"}, owner, owner_h,
      64'h0000_4000_0000_0000 + longint'(kind) * 64'h0100_0000,
      1'b0
    );
    ring = make_queue_test_ring({name, "_ring"}, ring_role, depth,
                                entry_size, ring_mapping);
    ring_ref = make_queue_test_ref(
      {name, "_ring_ref"}, ring_role, ring_mapping, ring.storage_bytes,
      RDMA_OWNERSHIP_BORROWED
    );
    pd_mapping = make_queue_test_mapping(
      {name, "_pd_mapping"}, owner, owner_h,
      64'h0000_5000_0000_0000 + longint'(kind) * 64'h0100_0000,
      1'b1
    );
    pd_ref = make_queue_test_ref(
      {name, "_pd_ref"}, pd_role, pd_mapping, 4096,
      RDMA_OWNERSHIP_CONTROL_PLANE
    );
    plan.rings.push_back(ring);
    plan.refs.push_back(ring_ref);
    plan.refs.push_back(pd_ref);

    if (kind == RDMA_RESOURCE_CQ || kind == RDMA_RESOURCE_SRQ) begin
      context_ref = rdma_context_backing_ref::type_id::create(
        {name, "_context"}
      );
      context_ref.owner = clone_function_handle({name, "_context_owner"},
                                                owner);
      context_ref.resource_kind = kind;
      context_ref.local_id = local_id;
      token = rdma_queue_opaque_slot_token::type_id::create(
        {name, "_token"}
      );
      completion_authority =
        rdma_queue_completion_authority::type_id::create(
          {name, "_completion_authority"}
        );
      token.completion_authority = completion_authority;
      context_ref.slot_token = token;
      hmc_ref = rdma_hmc_ref::type_id::create({name, "_hmc_ref"});
      hmc_ref.owner = clone_function_handle({name, "_hmc_owner"}, owner);
      hmc_ref.object_kind = RDMA_RESOURCE_MR;
      hmc_ref.address.value =
        64'h0000_6000_0000_0000 + longint'(kind) * 64'h1000;
      hmc_ref.size = 4096;
      hmc_ref.first_pbl_index = local_id + 1;
      hmc_ref.ownership = RDMA_OWNERSHIP_CONTROL_PLANE;
      context_ref.hmc_ref = hmc_ref;
      context_ref.shadow_pointer_base.value =
        64'h0000_7000_0000_0000 + longint'(kind) * 64'h1000;
      context_ref.slot_length = 64;
      context_ref.shadow_view_offset = 0;
      context_ref.shadow_view_length = 32;
      plan.context_ref = context_ref;
    end

    if (kind == RDMA_RESOURCE_CQ) begin
      flush_target = rdma_queue_flush_target::type_id::create(
        {name, "_flush"}
      );
      flush_target.role = RDMA_QUEUE_ROLE_CQ_PD;
      flush_target.phase = RDMA_QUEUE_FLUSH_POST_DELETE;
      flush_target.pd_ref = pd_ref;
      plan.flush_targets.push_back(flush_target);
    end
    else if (kind == RDMA_RESOURCE_SRQ) begin
      rdma_queue_ring_layout srfq_ring;
      rdma_queue_backing_ref srfq_ring_ref;
      rdma_queue_backing_ref srfq_pd_ref;
      rdma_dma_mapping srfq_ring_mapping;
      rdma_dma_mapping srfq_pd_mapping;

      srfq_ring_mapping = make_queue_test_mapping(
        {name, "_srfq_ring_mapping"}, owner, owner_h,
        64'h0000_4100_0000_0000, 1'b0
      );
      srfq_ring = make_queue_test_ring(
        {name, "_srfq_ring"}, RDMA_QUEUE_ROLE_SRFQ_RING, depth, 64,
        srfq_ring_mapping
      );
      srfq_ring_ref = make_queue_test_ref(
        {name, "_srfq_ring_ref"}, RDMA_QUEUE_ROLE_SRFQ_RING,
        srfq_ring_mapping, srfq_ring.storage_bytes,
        RDMA_OWNERSHIP_BORROWED
      );
      srfq_pd_mapping = make_queue_test_mapping(
        {name, "_srfq_pd_mapping"}, owner, owner_h,
        64'h0000_5100_0000_0000, 1'b1
      );
      srfq_pd_ref = make_queue_test_ref(
        {name, "_srfq_pd_ref"}, RDMA_QUEUE_ROLE_SRFQ_PD,
        srfq_pd_mapping, 4096, RDMA_OWNERSHIP_CONTROL_PLANE
      );
      plan.rings.push_back(srfq_ring);
      plan.refs.push_back(srfq_ring_ref);
      plan.refs.push_back(srfq_pd_ref);

      flush_target = rdma_queue_flush_target::type_id::create(
        {name, "_srfq_flush"}
      );
      flush_target.role = RDMA_QUEUE_ROLE_SRFQ_PD;
      flush_target.phase = RDMA_QUEUE_FLUSH_PRE_DELETE;
      flush_target.pd_ref = srfq_pd_ref;
      plan.flush_targets.push_back(flush_target);
      flush_target = rdma_queue_flush_target::type_id::create(
        {name, "_srq_flush"}
      );
      flush_target.role = RDMA_QUEUE_ROLE_SRQ_PD;
      flush_target.phase = RDMA_QUEUE_FLUSH_PRE_DELETE;
      flush_target.pd_ref = pd_ref;
      plan.flush_targets.push_back(flush_target);
    end
    return plan;
  endfunction

  function automatic rdma_handle make_qp_projected_handle(
    string name,
    rdma_resource_kind_e kind,
    rdma_function_handle owner,
    int unsigned local_id
  );
    rdma_handle handle;

    handle = rdma_handle::type_id::create(name);
    handle.kind = kind;
    handle.function_uid = owner.function_uid;
    handle.object_id = local_id;
    handle.generation = owner.generation;
    return handle;
  endfunction

  function automatic rdma_qp_ring_layout make_qp_test_ring(
    string name,
    rdma_queue_backing_role_e role,
    int unsigned depth
  );
    rdma_qp_ring_layout ring;

    ring = rdma_qp_ring_layout::type_id::create(name);
    ring.role = role;
    ring.entry_size_bytes = 64;
    ring.depth = depth;
    ring.logical_bytes = longint'(depth) * 64;
    ring.storage_bytes = ((ring.logical_bytes + 4095) / 4096) * 4096;
    ring.object_mode = RDMA_OBJECT_INDIRECT_4K;
    return ring;
  endfunction

  function automatic rdma_qp_backing_ref make_qp_test_ref(
    string name,
    rdma_queue_backing_role_e role,
    rdma_dma_mapping mapping,
    longint unsigned length,
    rdma_resource_ownership_e ownership
  );
    rdma_qp_backing_ref ref_value;

    ref_value = rdma_qp_backing_ref::type_id::create(name);
    ref_value.role = role;
    ref_value.mapping = mapping;
    ref_value.length = length;
    ref_value.ownership = ownership;
    return ref_value;
  endfunction

  function automatic rdma_qp_backing_plan make_qp_test_plan(
    string name,
    rdma_qp qp,
    int unsigned depth
  );
    rdma_qp_backing_plan plan;
    rdma_dma_mapping sq_mapping;
    rdma_dma_mapping rq_mapping;
    rdma_dma_mapping sq_pd_mapping;
    rdma_dma_mapping rq_pd_mapping;
    rdma_context_backing_ref context_ref;
    rdma_queue_opaque_slot_token token;
    rdma_queue_completion_authority completion_authority;

    plan = rdma_qp_backing_plan::type_id::create(name);
    plan.transport = RDMA_TRANSPORT_RC;
    plan.sq_depth = depth;
    plan.rq_depth = depth;
    plan.sq_ring = make_qp_test_ring(
      {name, "_sq_ring"}, RDMA_QUEUE_ROLE_QP_SQ_RING, depth
    );
    plan.rq_ring = make_qp_test_ring(
      {name, "_rq_ring"}, RDMA_QUEUE_ROLE_QP_RQ_RING, depth
    );
    sq_mapping = make_queue_test_mapping(
      {name, "_sq_mapping"}, qp.owner, qp.handle,
      64'h0000_8100_0000_0000 + longint'(qp.local_qp_id) * 64'h20_0000,
      1'b0
    );
    rq_mapping = make_queue_test_mapping(
      {name, "_rq_mapping"}, qp.owner, qp.handle,
      64'h0000_8200_0000_0000 + longint'(qp.local_qp_id) * 64'h20_0000,
      1'b0
    );
    sq_pd_mapping = make_independent_queue_test_mapping(
      {name, "_sq_pd_mapping"}, qp.owner, qp.handle,
      64'h0000_8300_0000_0000 + longint'(qp.local_qp_id) * 64'h1000
    );
    rq_pd_mapping = make_independent_queue_test_mapping(
      {name, "_rq_pd_mapping"}, qp.owner, qp.handle,
      64'h0000_8400_0000_0000 + longint'(qp.local_qp_id) * 64'h1000
    );
    plan.sq_ref = make_qp_test_ref(
      {name, "_sq_ref"}, RDMA_QUEUE_ROLE_QP_SQ_RING, sq_mapping,
      plan.sq_ring.storage_bytes, RDMA_OWNERSHIP_BORROWED
    );
    plan.rq_ref = make_qp_test_ref(
      {name, "_rq_ref"}, RDMA_QUEUE_ROLE_QP_RQ_RING, rq_mapping,
      plan.rq_ring.storage_bytes, RDMA_OWNERSHIP_BORROWED
    );
    plan.sq_pd_ref = make_qp_test_ref(
      {name, "_sq_pd_ref"}, RDMA_QUEUE_ROLE_QP_SQ_PD, sq_pd_mapping,
      4096, RDMA_OWNERSHIP_CONTROL_PLANE
    );
    plan.rq_pd_ref = make_qp_test_ref(
      {name, "_rq_pd_ref"}, RDMA_QUEUE_ROLE_QP_RQ_PD, rq_pd_mapping,
      4096, RDMA_OWNERSHIP_CONTROL_PLANE
    );

    context_ref = rdma_context_backing_ref::type_id::create(
      {name, "_context"}
    );
    context_ref.owner = clone_function_handle({name, "_context_owner"},
                                              qp.owner);
    context_ref.resource_kind = RDMA_RESOURCE_QP;
    context_ref.local_id = qp.local_qp_id;
    token = rdma_queue_opaque_slot_token::type_id::create({name, "_token"});
    completion_authority = rdma_queue_completion_authority::type_id::create(
      {name, "_completion_authority"}
    );
    token.completion_authority = completion_authority;
    context_ref.slot_token = token;
    context_ref.hmc_ref = rdma_hmc_ref::type_id::create({name, "_hmc"});
    context_ref.hmc_ref.owner = clone_function_handle({name, "_hmc_owner"},
                                                      qp.owner);
    context_ref.hmc_ref.object_kind = RDMA_RESOURCE_MR;
    context_ref.hmc_ref.address.value =
      64'h0000_8500_0000_0000 + longint'(qp.local_qp_id) * 512;
    context_ref.hmc_ref.size = 512;
    context_ref.hmc_ref.first_pbl_index = qp.local_qp_id + 1;
    context_ref.hmc_ref.ownership = RDMA_OWNERSHIP_CONTROL_PLANE;
    context_ref.shadow_pointer_base.value =
      64'h0000_8600_0000_0000 + longint'(qp.local_qp_id) * 512;
    context_ref.slot_length = 512;
    context_ref.shadow_view_offset = 0;
    context_ref.shadow_view_length = 512;
    plan.context_ref = context_ref;
    return plan;
  endfunction

  function automatic rdma_qpc_model make_qp_test_qpc(
    string name,
    rdma_qp qp,
    rdma_pd pd,
    rdma_cq send_cq,
    rdma_cq recv_cq,
    rdma_qp_backing_plan plan,
    rdma_qp_state_e state
  );
    rdma_qpc_model model;
    rdma_qpc_rc_ext extension;

    model = rdma_qpc_model::type_id::create(name);
    model.qp_h = make_qp_projected_handle(
      {name, "_qp"}, RDMA_RESOURCE_QP, qp.owner, qp.local_qp_id
    );
    model.pd_h = make_qp_projected_handle(
      {name, "_pd"}, RDMA_RESOURCE_PD, qp.owner, pd.local_pd_id
    );
    model.send_cq_h = make_qp_projected_handle(
      {name, "_send_cq"}, RDMA_RESOURCE_CQ, qp.owner, send_cq.local_cq_id
    );
    model.recv_cq_h = make_qp_projected_handle(
      {name, "_recv_cq"}, RDMA_RESOURCE_CQ, qp.owner, recv_cq.local_cq_id
    );
    model.transport = RDMA_TRANSPORT_RC;
    model.state = state;
    model.path_mtu_bytes = 4096;
    model.sq_depth = plan.sq_depth;
    model.rq_depth = plan.rq_depth;
    model.sq_backing.value = plan.sq_pd_ref.mapping.iova.value;
    model.rq_backing.value = plan.rq_pd_ref.mapping.iova.value;
    model.context_backing = plan.context_ref.shadow_pointer_base;
    model.sq_mode = RDMA_OBJECT_INDIRECT_4K;
    model.rq_mode = RDMA_OBJECT_INDIRECT_4K;
    extension = rdma_qpc_rc_ext::type_id::create({name, "_rc"});
    extension.remote_qpn = 24'h12_3456;
    model.transport_ext = extension;
    return model;
  endfunction

  function automatic void prepare_qp_candidate(
    rdma_qp qp,
    rdma_pd pd,
    rdma_cq send_cq,
    rdma_cq recv_cq,
    string name
  );
    qp.transport = RDMA_TRANSPORT_RC;
    qp.qp_state = RDMA_QPS_RESET;
    qp.sq_depth = 128;
    qp.rq_depth = 128;
    qp.qp_plan = make_qp_test_plan({name, "_plan"}, qp, 128);
    qp.programmed_qpc = make_qp_test_qpc(
      {name, "_qpc"}, qp, pd, send_cq, recv_cq, qp.qp_plan,
      RDMA_QPS_RESET
    );
    qp.sq_iova = qp.qp_plan.sq_ref.mapping.iova;
    qp.rq_iova = qp.qp_plan.rq_ref.mapping.iova;
  endfunction

  function automatic void prepare_urc_qp_candidate(
    rdma_qp qp,
    rdma_pd pd,
    rdma_cq send_cq,
    rdma_cq recv_cq,
    string name
  );
    rdma_dma_mapping urc_mapping;
    rdma_qp_backing_ref urc_ref;
    rdma_qpc_urc_ext urc_ext;

    prepare_qp_candidate(qp, pd, send_cq, recv_cq, name);
    qp.transport = RDMA_TRANSPORT_URC;
    qp.qp_plan.transport = RDMA_TRANSPORT_URC;
    urc_mapping = make_independent_queue_test_mapping(
      {name, "_urc_rsq_mapping"}, qp.owner, qp.handle,
      64'h0000_9100_0000_0000 + longint'(qp.local_qp_id) * 64'h1_0000
    );
    urc_ref = make_qp_test_ref(
      {name, "_urc_rsq_ref"}, RDMA_QUEUE_ROLE_QP_URC_RSQ,
      urc_mapping, 4096, RDMA_OWNERSHIP_CONTROL_PLANE
    );
    qp.qp_plan.urc_refs.push_back(urc_ref);
    urc_mapping = make_independent_queue_test_mapping(
      {name, "_urc_rdsq_mapping"}, qp.owner, qp.handle,
      64'h0000_9200_0000_0000 + longint'(qp.local_qp_id) * 64'h1_0000
    );
    urc_ref = make_qp_test_ref(
      {name, "_urc_rdsq_ref"}, RDMA_QUEUE_ROLE_QP_URC_RDSQ,
      urc_mapping, 4096, RDMA_OWNERSHIP_CONTROL_PLANE
    );
    qp.qp_plan.urc_refs.push_back(urc_ref);
    urc_mapping = make_independent_queue_test_mapping(
      {name, "_urc_dsq_mapping"}, qp.owner, qp.handle,
      64'h0000_9300_0000_0000 + longint'(qp.local_qp_id) * 64'h1_0000
    );
    urc_mapping.size = 8192;
    urc_ref = make_qp_test_ref(
      {name, "_urc_dsq_ref"}, RDMA_QUEUE_ROLE_QP_URC_DSQ,
      urc_mapping, 8192, RDMA_OWNERSHIP_CONTROL_PLANE
    );
    qp.qp_plan.urc_refs.push_back(urc_ref);

    qp.programmed_qpc.transport = RDMA_TRANSPORT_URC;
    urc_ext = rdma_qpc_urc_ext::type_id::create({name, "_urc_ext"});
    urc_ext.remote_qpn = 24'h65_4321;
    urc_ext.queues.rsq_backing.value =
      qp.qp_plan.urc_refs[0].mapping.iova.value;
    urc_ext.queues.rdsq_backing.value =
      qp.qp_plan.urc_refs[1].mapping.iova.value;
    urc_ext.queues.dsq_backing.value =
      qp.qp_plan.urc_refs[2].mapping.iova.value;
    urc_ext.queues.rsq_depth = 64;
    urc_ext.queues.rdsq_depth = 128;
    urc_ext.queues.rdsq_fetch_count = 8;
    urc_ext.queues.dsq_fetch_count = 16;
    urc_ext.queues.rq_sequence_threshold_entries = 64;
    urc_ext.queues.sq_completion_threshold_entries = 64;
    qp.programmed_qpc.transport_ext = urc_ext;
  endfunction

  function automatic rdma_cmq_opcode_key make_qp_test_opcode(
    string name,
    bit [31:0] opcode,
    string variant
  );
    rdma_cmq_opcode_key opcode_key;

    opcode_key = rdma_cmq_opcode_key::type_id::create(name);
    opcode_key.profile_name = "xtr_v1";
    opcode_key.opcode = opcode;
    opcode_key.variant = variant;
    return opcode_key;
  endfunction

  function automatic rdma_cmq_ticket make_qp_test_ticket(
    string name,
    rdma_function_handle owner,
    rdma_handle cmq_h,
    rdma_cmq_opcode_key opcode_key
  );
    rdma_cmq_ticket ticket;

    ticket = rdma_cmq_ticket::type_id::create(name);
    ticket.command_id = 64'h1234;
    ticket.function_h = clone_function_handle({name, "_function"}, owner);
    ticket.cmq_h = clone_handle({name, "_cmq"}, cmq_h);
    ticket.slot_sequence = 3;
    ticket.sq_index = 3;
    ticket.sq_wrap = 1'b0;
    ticket.opcode_key = rdma_cmq_clone_opcode_key_value(opcode_key, name);
    ticket.absolute_deadline = 100;
    return ticket;
  endfunction

  function automatic rdma_qp_recovery_state make_qp_test_recovery(
    string name,
    rdma_qp qp,
    rdma_qp_recovery_intent_e intent,
    rdma_qpc_model candidate_qpc = null
  );
    rdma_qp_recovery_state recovery;
    uvm_object cloned_object;

    recovery = rdma_qp_recovery_state::type_id::create(name);
    recovery.intent = intent;
    cloned_object = qp.qp_plan.clone();
    if (cloned_object == null || !$cast(recovery.qp_plan, cloned_object))
      `uvm_fatal("QP_RECOVERY_FIXTURE", "QP plan clone failed")
    cloned_object = recovery.qp_plan.context_ref.clone();
    if (cloned_object == null || !$cast(recovery.context_ref, cloned_object))
      `uvm_fatal("QP_RECOVERY_FIXTURE", "QP context clone failed")
    cloned_object = qp.programmed_qpc.clone();
    if (cloned_object == null || !$cast(recovery.prior_qpc, cloned_object))
      `uvm_fatal("QP_RECOVERY_FIXTURE", "prior QPC clone failed")
    if (candidate_qpc != null) begin
      cloned_object = candidate_qpc.clone();
      if (cloned_object == null ||
          !$cast(recovery.candidate_qpc, cloned_object))
        `uvm_fatal("QP_RECOVERY_FIXTURE", "candidate QPC clone failed")
    end
    recovery.create_opcode = make_qp_test_opcode(
      {name, "_create"}, 32'h100, "create"
    );
    recovery.modify_opcode = make_qp_test_opcode(
      {name, "_modify"}, 32'h101, "modify"
    );
    recovery.delete_opcode = make_qp_test_opcode(
      {name, "_delete"}, 32'h102, "delete"
    );
    recovery.query_opcode = make_qp_test_opcode(
      {name, "_query"}, 32'h103, "query"
    );
    recovery.occ_opcode = make_qp_test_opcode(
      {name, "_occ"}, 32'h104, "occ_flush"
    );
    if (intent == RDMA_QP_RECOVER_MODIFY_RECONCILE) begin
      recovery.query_mapping = make_queue_test_mapping(
        {name, "_query_mapping"}, qp.owner, qp.handle,
        64'h0000_8700_0000_0000 + longint'(qp.local_qp_id) * 512,
        1'b1
      );
      recovery.query_mapping.size = 512;
      recovery.query_mapping.backing_addr.value =
        64'h0000_8800_0000_0000 + longint'(qp.local_qp_id) * 512;
    end
    return recovery;
  endfunction

  function automatic void prepare_mr(rdma_mr mr,
                                     longint unsigned iova_value);
    mr.iova.value = iova_value;
    mr.length = 64'h2000;
    mr.lkey = {mr.local_mr_id[23:0], 8'h5a};
    mr.rkey = mr.lkey;
    mr.access = '{local_write:1'b1, remote_read:1'b1,
                  remote_write:1'b0, memory_window_bind:1'b0,
                  remote_atomic:1'b0};
  endfunction

  task automatic check_owned_mapping_clone_contract_rejections();
    rdma_resource_manager contract_rm;
    rdma_function_binding contract_binding;
    rdma_pd contract_pd;
    rdma_mr candidate;
    rdma_resource resource;
    rdma_dma_mapping mappings[$];
    rdma_rm_owned_alias_mapping alias_mapping;
    rdma_rm_owned_drift_mapping drift_mapping;
    rdma_rm_owned_authority_loss_mapping authority_loss_mapping;
    rdma_rm_owned_authority_hook_mapping hook_mapping;
    rdma_rm_unregistered_mapping unregistered_mapping;
    rdma_rm_stable_unregistered_mapping stable_unregistered_mapping;
    rdma_dma_mapping base_mapping;
    string mapping_labels[$];
    rdma_backing_ref backing_ref;
    longint unsigned hook_mapping_size;

    contract_rm = rdma_resource_manager::type_id::create(
      "owned_clone_contract_rm"
    );
    contract_binding = make_active_binding(
      "owned_clone_contract_binding", 64'hca10_0000_0000_0001,
      32'hca10_0101, 32'd90
    );
    expect_status(
      "OWNED_CLONE_CONTRACT_PD_CREATE",
      contract_rm.create_pd(contract_binding, contract_pd), RDMA_SC_OK
    );
    expect_status(
      "OWNED_CLONE_CONTRACT_PD_ACTIVATE",
      contract_rm.activate(contract_pd.handle), RDMA_SC_OK
    );

    alias_mapping = rdma_rm_owned_alias_mapping::type_id::create(
      "owned_alias_mapping"
    );
    mappings.push_back(alias_mapping);
    mapping_labels.push_back("ALIAS");
    drift_mapping = rdma_rm_owned_drift_mapping::type_id::create(
      "owned_drift_mapping"
    );
    mappings.push_back(drift_mapping);
    mapping_labels.push_back("DRIFT");
    authority_loss_mapping =
      rdma_rm_owned_authority_loss_mapping::type_id::create(
        "owned_authority_loss_mapping"
      );
    authority_loss_mapping.initialize_allocation_token(64'hca10_a110_c001);
    mappings.push_back(authority_loss_mapping);
    mapping_labels.push_back("PRIVATE_AUTHORITY_LOSS");
    unregistered_mapping = new("owned_unregistered_mapping");
    mappings.push_back(unregistered_mapping);
    mapping_labels.push_back("MUTATING_UNREGISTERED");
    stable_unregistered_mapping =
      new("owned_stable_unregistered_mapping");
    mappings.push_back(stable_unregistered_mapping);
    mapping_labels.push_back("STABLE_UNREGISTERED");
    base_mapping = rdma_dma_mapping::type_id::create("owned_base_mapping");
    mappings.push_back(base_mapping);
    mapping_labels.push_back("EXACT_BASE");

    foreach (mappings[i]) begin
      mappings[i].function_h = contract_binding.make_handle();
      mappings[i].requester_bdf = contract_binding.pcie.bdf;
      mappings[i].backing_addr.value =
        64'hca10_1000_0000_0000 + (i * 64'h10000);
      mappings[i].iova.value =
        64'hca10_2000_0000_0000 + (i * 64'h10000);
      mappings[i].size = 64'h2000;
      mappings[i].direction = RDMA_DMA_BIDIRECTIONAL;
      mappings[i].permissions =
        '{device_read:1'b1, device_write:1'b1, atomic:1'b0};
      mappings[i].state = RDMA_MAPPING_ACTIVE;
      mappings[i].owner_h = null;

      expect_status(
        {"OWNED_CLONE_CONTRACT_CREATE_", mapping_labels[i]},
        contract_rm.create_mr(contract_binding, contract_pd.handle, candidate),
        RDMA_SC_OK
      );
      prepare_mr(candidate, mappings[i].iova.value);
      backing_ref = rdma_backing_ref::type_id::create(
        {"owned_clone_contract_ref_", mapping_labels[i]}
      );
      backing_ref.mapping = mappings[i];
      backing_ref.ownership = RDMA_OWNERSHIP_CONTROL_PLANE;
      candidate.backing_refs.push_back(backing_ref);
      expect_status(
        {"OWNED_CLONE_CONTRACT_REJECT_", mapping_labels[i]},
        contract_rm.stage_allocated(candidate), RDMA_SC_INVALID_ARGUMENT
      );
      if (i == 0 && alias_mapping.clone_calls != 1)
        `uvm_error("OWNED_CLONE_CONTRACT_ALIAS_REACH",
                   "alias rejection did not reach the custom clone fault")
      if (i == 1 && drift_mapping.clone_calls != 1)
        `uvm_error("OWNED_CLONE_CONTRACT_DRIFT_REACH",
                   "drift rejection did not reach the custom clone fault")
      expect_status(
        {"OWNED_CLONE_CONTRACT_LOOKUP_", mapping_labels[i]},
        contract_rm.lookup(candidate.handle, resource), RDMA_SC_OK
      );
      if (resource == null || resource.state != RDMA_RESOURCE_ALLOCATED ||
          resource.backing_refs.size() != 0)
        `uvm_error("OWNED_CLONE_CONTRACT_ATOMIC",
                   "rejected owned clone changed the canonical MR")
    end

    // The same private-authority check must run on the later commit copy.
    // Preserve the token while staging, then drop it only for commit and prove
    // both the canonical value and its staged marker remain retryable.
    authority_loss_mapping =
      rdma_rm_owned_authority_loss_mapping::type_id::create(
        "owned_commit_authority_loss_mapping"
      );
    authority_loss_mapping.initialize_allocation_token(64'hca10_a110_c002);
    authority_loss_mapping.set_drop_allocation_token_on_copy(1'b0);
    authority_loss_mapping.function_h = contract_binding.make_handle();
    authority_loss_mapping.requester_bdf = contract_binding.pcie.bdf;
    authority_loss_mapping.backing_addr.value = 64'hca10_1000_0006_0000;
    authority_loss_mapping.iova.value = 64'hca10_2000_0006_0000;
    authority_loss_mapping.size = 64'h2000;
    authority_loss_mapping.direction = RDMA_DMA_BIDIRECTIONAL;
    authority_loss_mapping.permissions =
      '{device_read:1'b1, device_write:1'b1, atomic:1'b0};
    authority_loss_mapping.state = RDMA_MAPPING_ACTIVE;
    authority_loss_mapping.owner_h = null;

    expect_status(
      "OWNED_CLONE_COMMIT_CREATE",
      contract_rm.create_mr(contract_binding, contract_pd.handle, candidate),
      RDMA_SC_OK
    );
    prepare_mr(candidate, authority_loss_mapping.iova.value);
    backing_ref = rdma_backing_ref::type_id::create(
      "owned_clone_commit_authority_loss_ref"
    );
    backing_ref.mapping = authority_loss_mapping;
    backing_ref.ownership = RDMA_OWNERSHIP_CONTROL_PLANE;
    candidate.backing_refs.push_back(backing_ref);
    expect_status(
      "OWNED_CLONE_COMMIT_STAGE",
      contract_rm.stage_allocated(candidate), RDMA_SC_OK
    );

    authority_loss_mapping.set_drop_allocation_token_on_copy(1'b1);
    expect_status(
      "OWNED_CLONE_COMMIT_REJECT_PRIVATE_AUTHORITY_LOSS",
      contract_rm.commit_programmed(candidate), RDMA_SC_INVALID_ARGUMENT
    );
    expect_status(
      "OWNED_CLONE_COMMIT_LOOKUP_AFTER_REJECT",
      contract_rm.lookup(candidate.handle, resource), RDMA_SC_OK
    );
    if (resource == null || resource.state != RDMA_RESOURCE_ALLOCATED ||
        resource.backing_refs.size() != 1 ||
        resource.backing_refs[0] == null ||
        resource.backing_refs[0].mapping == null ||
        resource.backing_refs[0].mapping.iova.value !=
          authority_loss_mapping.iova.value ||
        resource.backing_refs[0].mapping.state != RDMA_MAPPING_ACTIVE)
      `uvm_error("OWNED_CLONE_COMMIT_ATOMIC",
                 "rejected commit changed the canonical staged MR")

    authority_loss_mapping.set_drop_allocation_token_on_copy(1'b0);
    expect_status(
      "OWNED_CLONE_COMMIT_RETRY",
      contract_rm.commit_programmed(candidate), RDMA_SC_OK
    );

    hook_mapping = rdma_rm_owned_authority_hook_mapping::type_id::create(
      "owned_source_authority_hook_mapping"
    );
    hook_mapping.initialize_allocation_token(64'hca10_a110_c003);
    hook_mapping.function_h = contract_binding.make_handle();
    hook_mapping.requester_bdf = contract_binding.pcie.bdf;
    hook_mapping.backing_addr.value = 64'hca10_1000_0007_0000;
    hook_mapping.iova.value = 64'hca10_2000_0007_0000;
    hook_mapping.size = 64'h2000;
    hook_mapping.direction = RDMA_DMA_BIDIRECTIONAL;
    hook_mapping.permissions =
      '{device_read:1'b1, device_write:1'b1, atomic:1'b0};
    hook_mapping.state = RDMA_MAPPING_ACTIVE;
    hook_mapping.owner_h = null;
    expect_status(
      "OWNED_SOURCE_HOOK_CREATE",
      contract_rm.create_mr(contract_binding, contract_pd.handle, candidate),
      RDMA_SC_OK
    );
    prepare_mr(candidate, hook_mapping.iova.value);
    backing_ref = rdma_backing_ref::type_id::create(
      "owned_source_authority_hook_ref"
    );
    backing_ref.mapping = hook_mapping;
    backing_ref.ownership = RDMA_OWNERSHIP_CONTROL_PLANE;
    candidate.backing_refs.push_back(backing_ref);
    hook_mapping_size = hook_mapping.size;
    hook_mapping.set_authority_hook_fault(
      RDMA_RM_AUTHORITY_HOOK_MUTATE_SOURCE
    );
    expect_status(
      "OWNED_SOURCE_HOOK_REJECT",
      contract_rm.stage_allocated(candidate), RDMA_SC_INVALID_ARGUMENT
    );
    hook_mapping.set_authority_hook_fault(RDMA_RM_AUTHORITY_HOOK_STABLE);
    expect_status(
      "OWNED_SOURCE_HOOK_LOOKUP",
      contract_rm.lookup(candidate.handle, resource), RDMA_SC_OK
    );
    if (hook_mapping.size != hook_mapping_size + 1 || resource == null ||
        resource.state != RDMA_RESOURCE_ALLOCATED ||
        resource.backing_refs.size() != 0)
      `uvm_error("OWNED_SOURCE_HOOK_ATOMIC",
                 "source hook mutation entered the canonical MR")

    hook_mapping = rdma_rm_owned_authority_hook_mapping::type_id::create(
      "owned_result_authority_hook_mapping"
    );
    hook_mapping.initialize_allocation_token(64'hca10_a110_c004);
    hook_mapping.function_h = contract_binding.make_handle();
    hook_mapping.requester_bdf = contract_binding.pcie.bdf;
    hook_mapping.backing_addr.value = 64'hca10_1000_0008_0000;
    hook_mapping.iova.value = 64'hca10_2000_0008_0000;
    hook_mapping.size = 64'h2000;
    hook_mapping.direction = RDMA_DMA_BIDIRECTIONAL;
    hook_mapping.permissions =
      '{device_read:1'b1, device_write:1'b1, atomic:1'b0};
    hook_mapping.state = RDMA_MAPPING_ACTIVE;
    hook_mapping.owner_h = null;
    expect_status(
      "OWNED_RESULT_HOOK_CREATE",
      contract_rm.create_mr(contract_binding, contract_pd.handle, candidate),
      RDMA_SC_OK
    );
    prepare_mr(candidate, hook_mapping.iova.value);
    backing_ref = rdma_backing_ref::type_id::create(
      "owned_result_authority_hook_ref"
    );
    backing_ref.mapping = hook_mapping;
    backing_ref.ownership = RDMA_OWNERSHIP_CONTROL_PLANE;
    candidate.backing_refs.push_back(backing_ref);
    expect_status(
      "OWNED_RESULT_HOOK_STAGE",
      contract_rm.stage_allocated(candidate), RDMA_SC_OK
    );
    hook_mapping_size = hook_mapping.size;
    hook_mapping.set_authority_hook_fault(
      RDMA_RM_AUTHORITY_HOOK_MUTATE_RESULT
    );
    expect_status(
      "OWNED_RESULT_HOOK_COMMIT_REJECT",
      contract_rm.commit_programmed(candidate), RDMA_SC_INVALID_ARGUMENT
    );
    hook_mapping.set_authority_hook_fault(RDMA_RM_AUTHORITY_HOOK_STABLE);
    expect_status(
      "OWNED_RESULT_HOOK_LOOKUP",
      contract_rm.lookup(candidate.handle, resource), RDMA_SC_OK
    );
    if (hook_mapping.size != hook_mapping_size || resource == null ||
        resource.state != RDMA_RESOURCE_ALLOCATED ||
        resource.backing_refs.size() != 1 ||
        resource.backing_refs[0] == null ||
        resource.backing_refs[0].mapping == null ||
        resource.backing_refs[0].mapping.size != hook_mapping_size)
      `uvm_error("OWNED_RESULT_HOOK_ATOMIC",
                 "result hook mutation entered caller or canonical MR")
  endtask

  task automatic check_owned_mapping_capability_snapshots();
    rdma_resource_manager capability_rm;
    rdma_mock_host_mem capability_mem;
    rdma_function_binding capability_binding;
    rdma_dma_request_context capability_context;
    rdma_pd capability_pd;
    rdma_mr active_mr;
    rdma_mr recovery_mr;
    rdma_mr active_snapshot;
    rdma_resource resource;
    rdma_dma_mapping active_mapping;
    rdma_dma_mapping recovery_mapping;
    rdma_backing_ref active_ref;
    rdma_backing_ref recovery_ref;
    rdma_recovery_record recovery;
    rdma_recovery_record recovery_snapshot;
    rdma_status status;

    capability_rm = rdma_resource_manager::type_id::create(
      "owned_capability_rm"
    );
    capability_mem = rdma_mock_host_mem::type_id::create(
      "owned_capability_mem"
    );
    capability_binding = make_active_binding(
      "owned_capability_binding", 64'hca11_0000_0000_0001,
      32'hca11_0101, 32'd91
    );
    capability_context = rdma_dma_request_context::type_id::create(
      "owned_capability_context"
    );
    capability_context.function_h = capability_binding.make_handle();
    capability_context.requester_bdf = capability_binding.pcie.bdf;
    capability_context.pasid_valid = 1'b1;
    capability_context.pasid = 20'hca111;
    capability_context.owner_h = null;

    expect_status(
      "OWNED_CAPABILITY_PD_CREATE",
      capability_rm.create_pd(capability_binding, capability_pd), RDMA_SC_OK
    );
    expect_status(
      "OWNED_CAPABILITY_PD_ACTIVATE",
      capability_rm.activate(capability_pd.handle), RDMA_SC_OK
    );

    status = capability_mem.allocate(
      capability_context, 8192, 4096, RDMA_DMA_BIDIRECTIONAL,
      active_mapping
    );
    expect_status("OWNED_CAPABILITY_ACTIVE_ALLOCATE", status, RDMA_SC_OK);
    expect_status(
      "OWNED_CAPABILITY_ACTIVE_CREATE",
      capability_rm.create_mr(capability_binding, capability_pd.handle,
                              active_mr),
      RDMA_SC_OK
    );
    prepare_mr(active_mr, active_mapping.iova.value);
    active_ref = rdma_backing_ref::type_id::create(
      "owned_capability_active_ref"
    );
    active_ref.mapping = active_mapping;
    active_ref.ownership = RDMA_OWNERSHIP_CONTROL_PLANE;
    active_mr.backing_refs.push_back(active_ref);
    expect_status("OWNED_CAPABILITY_ACTIVE_STAGE",
                  capability_rm.stage_allocated(active_mr), RDMA_SC_OK);
    expect_status("OWNED_CAPABILITY_ACTIVE_COMMIT",
                  capability_rm.commit_programmed(active_mr), RDMA_SC_OK);
    expect_status("OWNED_CAPABILITY_ACTIVE_ACTIVATE",
                  capability_rm.activate(active_mr.handle), RDMA_SC_OK);
    expect_status("OWNED_CAPABILITY_ACTIVE_LOOKUP",
                  capability_rm.lookup(active_mr.handle, resource),
                  RDMA_SC_OK);
    active_snapshot = null;
    if (!$cast(active_snapshot, resource) || active_snapshot == null ||
        active_snapshot.backing_refs.size() != 1 ||
        active_snapshot.backing_refs[0] == null ||
        active_snapshot.backing_refs[0].mapping == null)
      `uvm_fatal("OWNED_CAPABILITY_ACTIVE_LOOKUP",
                 "ACTIVE lookup lost its owned mapping")
    status = capability_mem.\release (
      active_snapshot.backing_refs[0].mapping
    );
    expect_status("OWNED_CAPABILITY_ACTIVE_RELEASE", status, RDMA_SC_OK);
    status = capability_mem.\release (
      active_snapshot.backing_refs[0].mapping
    );
    expect_status("OWNED_CAPABILITY_ACTIVE_RELEASE_AGAIN", status,
                  RDMA_SC_INVALID_STATE);

    status = capability_mem.allocate(
      capability_context, 8192, 4096, RDMA_DMA_BIDIRECTIONAL,
      recovery_mapping
    );
    expect_status("OWNED_CAPABILITY_RECOVERY_ALLOCATE", status, RDMA_SC_OK);
    expect_status(
      "OWNED_CAPABILITY_RECOVERY_CREATE",
      capability_rm.create_mr(capability_binding, capability_pd.handle,
                              recovery_mr),
      RDMA_SC_OK
    );
    prepare_mr(recovery_mr, recovery_mapping.iova.value);
    recovery_ref = rdma_backing_ref::type_id::create(
      "owned_capability_recovery_ref"
    );
    recovery_ref.mapping = recovery_mapping;
    recovery_ref.ownership = RDMA_OWNERSHIP_CONTROL_PLANE;
    recovery_mr.backing_refs.push_back(recovery_ref);
    expect_status("OWNED_CAPABILITY_RECOVERY_STAGE",
                  capability_rm.stage_allocated(recovery_mr), RDMA_SC_OK);
    expect_status("OWNED_CAPABILITY_RECOVERY_COMMIT",
                  capability_rm.commit_programmed(recovery_mr), RDMA_SC_OK);
    expect_status("OWNED_CAPABILITY_RECOVERY_ACTIVATE",
                  capability_rm.activate(recovery_mr.handle), RDMA_SC_OK);
    recovery = rdma_recovery_record::type_id::create(
      "owned_capability_recovery"
    );
    recovery.resource_h = clone_handle(
      "OWNED_CAPABILITY_RECOVERY_HANDLE", recovery_mr.handle
    );
    recovery.hardware_presence = RDMA_HW_PRESENCE_ABSENT;
    recovery.backing_refs.push_back(recovery_ref);
    recovery.primary_status = rdma_status::make(
      RDMA_SC_UNKNOWN_HW_ERROR, "owned mapping recovery authority"
    );
    expect_status("OWNED_CAPABILITY_RECOVERY_MARK",
                  capability_rm.mark_error(recovery_mr.handle, recovery),
                  RDMA_SC_OK);
    expect_status(
      "OWNED_CAPABILITY_RECOVERY_LOOKUP",
      capability_rm.lookup_recovery(recovery_mr.handle, recovery_snapshot),
      RDMA_SC_OK
    );
    if (recovery_snapshot == null ||
        recovery_snapshot.backing_refs.size() != 1 ||
        recovery_snapshot.backing_refs[0] == null ||
        recovery_snapshot.backing_refs[0].mapping == null)
      `uvm_fatal("OWNED_CAPABILITY_RECOVERY_LOOKUP",
                 "recovery lookup lost its owned mapping")
    status = capability_mem.\release (
      recovery_snapshot.backing_refs[0].mapping
    );
    expect_status("OWNED_CAPABILITY_RECOVERY_RELEASE", status, RDMA_SC_OK);
    status = capability_mem.\release (
      recovery_snapshot.backing_refs[0].mapping
    );
    expect_status("OWNED_CAPABILITY_RECOVERY_RELEASE_AGAIN", status,
                  RDMA_SC_INVALID_STATE);
    if (capability_mem.live_allocations() != 0)
      `uvm_error("OWNED_CAPABILITY_RELEASE_COUNT",
                 "canonical snapshots did not release each allocation once")
  endtask

  task automatic check_reserved_error_completion_proof();
    rdma_resource_manager proof_rm;
    rdma_mock_host_mem proof_mem;
    rdma_function_binding proof_binding;
    rdma_dma_request_context proof_context;
    rdma_pd proof_pd;
    rdma_mr proof_mr;
    rdma_mr completion_hook_mr;
    rdma_dma_mapping proof_mapping;
    rdma_dma_mapping wrong_mapping;
    rdma_dma_mapping forged_mapping;
    rdma_rm_owned_authority_hook_mapping completion_hook_mapping;
    rdma_backing_ref proof_ref;
    rdma_backing_ref completion_hook_ref;
    rdma_recovery_record recovery;
    rdma_recovery_record recovery_lookup;
    rdma_resource resource;
    rdma_status status;

    proof_rm = rdma_resource_manager::type_id::create(
      "reserved_error_proof_rm"
    );
    proof_mem = rdma_mock_host_mem::type_id::create(
      "reserved_error_proof_mem"
    );
    proof_binding = make_active_binding(
      "reserved_error_proof_binding", 64'hca12_0000_0000_0001,
      32'hca12_0101, 32'd92
    );
    proof_context = rdma_dma_request_context::type_id::create(
      "reserved_error_proof_context"
    );
    proof_context.function_h = proof_binding.make_handle();
    proof_context.requester_bdf = proof_binding.pcie.bdf;
    proof_context.owner_h = null;

    expect_status("RESERVED_PROOF_PD_CREATE",
                  proof_rm.create_pd(proof_binding, proof_pd), RDMA_SC_OK);
    expect_status("RESERVED_PROOF_PD_ACTIVATE",
                  proof_rm.activate(proof_pd.handle), RDMA_SC_OK);
    status = proof_mem.allocate(proof_context, 4096, 4096,
                                RDMA_DMA_BIDIRECTIONAL, proof_mapping);
    expect_status("RESERVED_PROOF_ALLOCATE", status, RDMA_SC_OK);
    status = proof_mem.allocate(proof_context, 4096, 4096,
                                RDMA_DMA_BIDIRECTIONAL, wrong_mapping);
    expect_status("RESERVED_PROOF_WRONG_ALLOCATE", status, RDMA_SC_OK);
    expect_status("RESERVED_PROOF_MR_CREATE",
                  proof_rm.create_mr(proof_binding, proof_pd.handle,
                                     proof_mr), RDMA_SC_OK);
    proof_ref = rdma_backing_ref::type_id::create("reserved_proof_ref");
    proof_ref.mapping = proof_mapping;
    proof_ref.ownership = RDMA_OWNERSHIP_CONTROL_PLANE;
    recovery = rdma_recovery_record::type_id::create(
      "reserved_proof_recovery"
    );
    recovery.resource_h = clone_handle("RESERVED_PROOF_H", proof_mr.handle);
    recovery.hardware_presence = RDMA_HW_PRESENCE_ABSENT;
    recovery.pending_steps.push_back(RDMA_CTRL_STEP_BACKING_RELEASED);
    recovery.backing_refs.push_back(proof_ref);
    recovery.primary_status = rdma_status::make(
      RDMA_SC_UNKNOWN_HW_ERROR, "reserved proof setup"
    );
    expect_status("RESERVED_PROOF_MARK",
                  proof_rm.mark_reserved_error(proof_mr.handle, recovery),
                  RDMA_SC_OK);

    expect_status("RESERVED_PROOF_FORGED_LOOKUP",
                  proof_rm.lookup_recovery(proof_mr.handle, recovery_lookup),
                  RDMA_SC_OK);
    forged_mapping = null;
    if (recovery_lookup != null &&
        recovery_lookup.backing_refs.size() == 1 &&
        recovery_lookup.backing_refs[0] != null)
      forged_mapping = recovery_lookup.backing_refs[0].mapping;
    if (forged_mapping == null)
      `uvm_fatal("RESERVED_PROOF_FORGED_LOOKUP",
                 "forged-proof setup lost the retained mapping")
    forged_mapping.state = RDMA_MAPPING_RELEASED;
    expect_status("RESERVED_PROOF_FORGED_RELEASE_REJECT",
                  proof_rm.complete_reserved_error(proof_mr.handle),
                  RDMA_SC_INVALID_ARGUMENT);
    if (proof_mem.live_allocations() != 2)
      `uvm_error("RESERVED_PROOF_FORGED_ALLOCATION",
                 "forged public state discarded a live allocation")

    expect_status("RESERVED_PROOF_LIVE_REJECT",
                  proof_rm.complete_reserved_error(proof_mr.handle),
                  RDMA_SC_INVALID_ARGUMENT);
    status = proof_mem.\release (wrong_mapping);
    expect_status("RESERVED_PROOF_WRONG_RELEASE", status, RDMA_SC_OK);
    expect_status("RESERVED_PROOF_WRONG_REJECT",
                  proof_rm.complete_reserved_error(proof_mr.handle),
                  RDMA_SC_INVALID_ARGUMENT);
    expect_status("RESERVED_PROOF_ATOMIC_LOOKUP",
                  proof_rm.lookup(proof_mr.handle, resource), RDMA_SC_OK);
    expect_status("RESERVED_PROOF_ATOMIC_RECOVERY",
                  proof_rm.lookup_recovery(proof_mr.handle, recovery_lookup),
                  RDMA_SC_OK);
    if (resource == null || resource.state != RDMA_RESOURCE_ERROR ||
        recovery_lookup == null ||
        recovery_lookup.pending_steps.size() != 1 ||
        recovery_lookup.pending_steps[0] !=
          RDMA_CTRL_STEP_BACKING_RELEASED)
      `uvm_error("RESERVED_PROOF_ATOMIC",
                 "invalid completion proof changed durable recovery")

    status = proof_mem.\release (proof_mapping);
    expect_status("RESERVED_PROOF_RELEASE", status, RDMA_SC_OK);
    expect_status("RESERVED_PROOF_COMPLETE",
                  proof_rm.complete_reserved_error(proof_mr.handle),
                  RDMA_SC_OK);
    expect_status("RESERVED_PROOF_RELEASED_LOOKUP",
                  proof_rm.lookup(proof_mr.handle, resource),
                  RDMA_SC_INVALID_STATE);
    if (proof_mem.live_allocations() != 0)
      `uvm_error("RESERVED_PROOF_RELEASE_COUNT",
                 "reserved completion did not release allocations once")

    completion_hook_mapping =
      rdma_rm_owned_authority_hook_mapping::type_id::create(
        "reserved_completion_hook_mapping"
      );
    completion_hook_mapping.initialize_allocation_token(
      64'hca12_a110_c001
    );
    completion_hook_mapping.function_h = proof_binding.make_handle();
    completion_hook_mapping.requester_bdf = proof_binding.pcie.bdf;
    completion_hook_mapping.backing_addr.value = 64'hca12_1000_0000_0000;
    completion_hook_mapping.iova.value = 64'hca12_2000_0000_0000;
    completion_hook_mapping.size = 64'h2000;
    completion_hook_mapping.direction = RDMA_DMA_BIDIRECTIONAL;
    completion_hook_mapping.permissions =
      '{device_read:1'b1, device_write:1'b1, atomic:1'b0};
    completion_hook_mapping.state = RDMA_MAPPING_ACTIVE;
    completion_hook_mapping.owner_h = null;
    expect_status("RESERVED_COMPLETION_HOOK_MR_CREATE",
                  proof_rm.create_mr(proof_binding, proof_pd.handle,
                                     completion_hook_mr), RDMA_SC_OK);
    prepare_mr(completion_hook_mr, completion_hook_mapping.iova.value);
    completion_hook_ref = rdma_backing_ref::type_id::create(
      "reserved_completion_hook_ref"
    );
    completion_hook_ref.mapping = completion_hook_mapping;
    completion_hook_ref.ownership = RDMA_OWNERSHIP_CONTROL_PLANE;
    recovery = rdma_recovery_record::type_id::create(
      "reserved_completion_hook_recovery"
    );
    recovery.resource_h = clone_handle(
      "RESERVED_COMPLETION_HOOK_H", completion_hook_mr.handle
    );
    recovery.hardware_presence = RDMA_HW_PRESENCE_ABSENT;
    recovery.pending_steps.push_back(RDMA_CTRL_STEP_BACKING_RELEASED);
    recovery.backing_refs.push_back(completion_hook_ref);
    recovery.primary_status = rdma_status::make(
      RDMA_SC_UNKNOWN_HW_ERROR, "completion hook mutation setup"
    );
    expect_status("RESERVED_COMPLETION_HOOK_MARK",
                  proof_rm.mark_reserved_error(completion_hook_mr.handle,
                                               recovery), RDMA_SC_OK);
    completion_hook_mapping.set_authority_hook_fault(
      RDMA_RM_AUTHORITY_HOOK_MUTATE_COMPLETION
    );
    expect_status("RESERVED_COMPLETION_HOOK_REJECT",
                  proof_rm.complete_reserved_error(
                    completion_hook_mr.handle
                  ), RDMA_SC_INVALID_ARGUMENT);
    completion_hook_mapping.set_authority_hook_fault(
      RDMA_RM_AUTHORITY_HOOK_STABLE
    );
    expect_status("RESERVED_COMPLETION_HOOK_LOOKUP",
                  proof_rm.lookup(completion_hook_mr.handle, resource),
                  RDMA_SC_OK);
    expect_status("RESERVED_COMPLETION_HOOK_RECOVERY",
                  proof_rm.lookup_recovery(completion_hook_mr.handle,
                                           recovery_lookup), RDMA_SC_OK);
    if (resource == null || resource.state != RDMA_RESOURCE_ERROR ||
        resource.backing_refs.size() != 0 || recovery_lookup == null ||
        recovery_lookup.backing_refs.size() != 1 ||
        recovery_lookup.backing_refs[0] == null ||
        recovery_lookup.backing_refs[0].mapping == null ||
        recovery_lookup.backing_refs[0].mapping.size != 64'h2000)
      `uvm_error("RESERVED_COMPLETION_HOOK_ATOMIC",
                 "completion query mutation changed canonical recovery")
  endtask

  task automatic create_restore_gate_mr(
    string check_name,
    rdma_resource_manager manager,
    rdma_function_binding binding,
    rdma_pd pd,
    longint unsigned iova_value,
    output rdma_mr mr
  );
    expect_status({check_name, "_CREATE"},
                  manager.create_mr(binding, pd.handle, mr), RDMA_SC_OK);
    if (mr == null)
      return;
    prepare_mr(mr, iova_value);
    expect_status({check_name, "_STAGE"}, manager.stage_allocated(mr),
                  RDMA_SC_OK);
    expect_status({check_name, "_PROGRAM"}, manager.commit_programmed(mr),
                  RDMA_SC_OK);
    expect_status({check_name, "_ACTIVATE"}, manager.activate(mr.handle),
                  RDMA_SC_OK);
    expect_status({check_name, "_QUIESCE"},
                  manager.begin_quiesce(mr.handle), RDMA_SC_OK);
  endtask

  task automatic create_prepared_restore_gate_mr(
    string check_name,
    rdma_resource_manager manager,
    rdma_function_binding binding,
    rdma_pd pd,
    longint unsigned iova_value,
    output rdma_mr mr
  );
    expect_status({check_name, "_CREATE"},
                  manager.create_mr(binding, pd.handle, mr), RDMA_SC_OK);
    if (mr != null)
      prepare_mr(mr, iova_value);
  endtask

  task automatic activate_restore_gate_mr(
    string check_name,
    rdma_resource_manager manager,
    rdma_mr mr
  );
    if (mr == null)
      return;
    expect_status({check_name, "_STAGE"}, manager.stage_allocated(mr),
                  RDMA_SC_OK);
    expect_status({check_name, "_PROGRAM"}, manager.commit_programmed(mr),
                  RDMA_SC_OK);
    expect_status({check_name, "_ACTIVATE"}, manager.activate(mr.handle),
                  RDMA_SC_OK);
    expect_status({check_name, "_QUIESCE"},
                  manager.begin_quiesce(mr.handle), RDMA_SC_OK);
  endtask

  function automatic void initialize_restore_gate_mapping(
    rdma_dma_mapping mapping,
    rdma_function_binding binding,
    longint unsigned iova_value
  );
    if (mapping == null || binding == null)
      return;
    mapping.function_h = binding.make_handle();
    mapping.requester_bdf = binding.pcie.bdf;
    mapping.pasid_valid = 1'b1;
    mapping.pasid = 20'he2251;
    mapping.backing_addr.value = iova_value + 64'h1000_0000;
    mapping.iova.value = iova_value;
    mapping.size = 64'h2000;
    mapping.direction = RDMA_DMA_BIDIRECTIONAL;
    mapping.permissions =
      '{device_read:1'b1, device_write:1'b1, atomic:1'b0};
    mapping.state = RDMA_MAPPING_ACTIVE;
    mapping.owner_h = null;
  endfunction

  function automatic rdma_backing_ref make_restore_gate_backing_ref(
    string name,
    rdma_dma_mapping mapping,
    rdma_resource_ownership_e ownership
  );
    rdma_backing_ref backing_ref;

    backing_ref = rdma_backing_ref::type_id::create(name);
    backing_ref.mapping = mapping;
    backing_ref.ownership = ownership;
    backing_ref.release_complete = 1'b0;
    return backing_ref;
  endfunction

  function automatic rdma_hmc_ref make_restore_gate_hmc_ref(
    string name,
    rdma_function_handle owner,
    longint unsigned address_value
  );
    rdma_hmc_ref hmc_ref;

    hmc_ref = rdma_hmc_ref::type_id::create(name);
    hmc_ref.owner = owner;
    hmc_ref.object_kind = RDMA_RESOURCE_MR;
    hmc_ref.address.value = address_value;
    hmc_ref.size = 64'h3000;
    hmc_ref.first_pbl_index = 28'he2251;
    hmc_ref.ownership = RDMA_OWNERSHIP_BORROWED;
    hmc_ref.release_complete = 1'b0;
    return hmc_ref;
  endfunction

  function automatic rdma_recovery_record make_restore_gate_recovery(
    string name,
    rdma_mr mr
  );
    rdma_recovery_record recovery;

    recovery = rdma_recovery_record::type_id::create(name);
    recovery.resource_h = clone_handle({name, "_h"}, mr.handle);
    recovery.hardware_presence = RDMA_HW_PRESENCE_PRESENT;
    recovery.primary_status = rdma_status::make(
      RDMA_SC_TIMEOUT, "late destroy failure is terminal"
    );
    return recovery;
  endfunction

  task automatic check_error_restore_active_gate();
    rdma_resource_manager manager;
    rdma_function_binding binding;
    rdma_pd pd;
    rdma_mr mr;
    rdma_resource resource;
    rdma_recovery_record recovery;
    rdma_recovery_record recovery_lookup;
    rdma_hmc_ref hmc_ref;

    manager = rdma_resource_manager::type_id::create(
      "error_restore_manager"
    );
    binding = make_active_binding(
      "error_restore_binding", 64'he225_0000_0000_0001,
      32'he225_0101, 32'd25
    );
    expect_status("ERROR_RESTORE_PD_CREATE",
                  manager.create_pd(binding, pd), RDMA_SC_OK);
    expect_status("ERROR_RESTORE_PD_ACTIVATE", manager.activate(pd.handle),
                  RDMA_SC_OK);

    create_restore_gate_mr(
      "ERROR_RESTORE_EMPTY", manager, binding, pd,
      64'he225_1000_0000_0000, mr
    );
    recovery = make_restore_gate_recovery("error_restore_empty", mr);
    expect_status("ERROR_RESTORE_EMPTY_MARK",
                  manager.mark_error(mr.handle, recovery), RDMA_SC_OK);
    expect_status("ERROR_RESTORE_EMPTY_RUN", manager.restore_active(mr.handle),
                  RDMA_SC_OK);
    expect_status("ERROR_RESTORE_EMPTY_LOOKUP",
                  manager.lookup(mr.handle, resource), RDMA_SC_OK);
    expect_status("ERROR_RESTORE_EMPTY_CLEARED",
                  manager.lookup_recovery(mr.handle, recovery_lookup),
                  RDMA_SC_INVALID_STATE);
    if (resource == null || resource.state != RDMA_RESOURCE_ACTIVE)
      `uvm_error("ERROR_RESTORE_EMPTY_STATE",
                 "safe ERROR recovery did not atomically restore ACTIVE")

    create_restore_gate_mr(
      "ERROR_RESTORE_OCC", manager, binding, pd,
      64'he225_1000_0001_0000, mr
    );
    recovery = make_restore_gate_recovery("error_restore_occ", mr);
    recovery.completed_steps.push_back(RDMA_CTRL_STEP_HW_OCC_FLUSHED);
    expect_status("ERROR_RESTORE_OCC_MARK",
                  manager.mark_error(mr.handle, recovery), RDMA_SC_OK);
    expect_status("ERROR_RESTORE_OCC_RUN", manager.restore_active(mr.handle),
                  RDMA_SC_OK);
    expect_status("ERROR_RESTORE_OCC_LOOKUP",
                  manager.lookup(mr.handle, resource), RDMA_SC_OK);
    expect_status("ERROR_RESTORE_OCC_CLEARED",
                  manager.lookup_recovery(mr.handle, recovery_lookup),
                  RDMA_SC_INVALID_STATE);
    if (resource == null || resource.state != RDMA_RESOURCE_ACTIVE)
      `uvm_error("ERROR_RESTORE_OCC_STATE",
                 "non-destructive OCC history blocked ACTIVE recovery")

    create_restore_gate_mr(
      "ERROR_RESTORE_ABSENT", manager, binding, pd,
      64'he225_1000_0002_0000, mr
    );
    recovery = make_restore_gate_recovery("error_restore_absent", mr);
    recovery.hardware_presence = RDMA_HW_PRESENCE_ABSENT;
    expect_status("ERROR_RESTORE_ABSENT_MARK",
                  manager.mark_error(mr.handle, recovery), RDMA_SC_OK);
    expect_status("ERROR_RESTORE_ABSENT_REJECT",
                  manager.restore_active(mr.handle), RDMA_SC_INVALID_STATE);

    create_restore_gate_mr(
      "ERROR_RESTORE_PENDING", manager, binding, pd,
      64'he225_1000_0003_0000, mr
    );
    recovery = make_restore_gate_recovery("error_restore_pending", mr);
    recovery.pending_steps.push_back(RDMA_CTRL_STEP_HW_MR_DEREGISTERED);
    expect_status("ERROR_RESTORE_PENDING_MARK",
                  manager.mark_error(mr.handle, recovery), RDMA_SC_OK);
    expect_status("ERROR_RESTORE_PENDING_REJECT",
                  manager.restore_active(mr.handle), RDMA_SC_INVALID_STATE);

    create_restore_gate_mr(
      "ERROR_RESTORE_CREATE", manager, binding, pd,
      64'he225_1000_0004_0000, mr
    );
    recovery = make_restore_gate_recovery("error_restore_create", mr);
    recovery.completed_steps.push_back(RDMA_CTRL_STEP_RESOURCE_RESERVED);
    expect_status("ERROR_RESTORE_CREATE_MARK",
                  manager.mark_error(mr.handle, recovery), RDMA_SC_OK);
    expect_status("ERROR_RESTORE_CREATE_REJECT",
                  manager.restore_active(mr.handle), RDMA_SC_INVALID_STATE);

    create_restore_gate_mr(
      "ERROR_RESTORE_DESTRUCTIVE", manager, binding, pd,
      64'he225_1000_0005_0000, mr
    );
    recovery = make_restore_gate_recovery("error_restore_destructive", mr);
    recovery.completed_steps.push_back(
      RDMA_CTRL_STEP_HW_MR_DEREGISTERED
    );
    expect_status("ERROR_RESTORE_DESTRUCTIVE_MARK",
                  manager.mark_error(mr.handle, recovery), RDMA_SC_OK);
    expect_status("ERROR_RESTORE_DESTRUCTIVE_REJECT",
                  manager.restore_active(mr.handle), RDMA_SC_INVALID_STATE);

    create_restore_gate_mr(
      "ERROR_RESTORE_RELEASED_REF", manager, binding, pd,
      64'he225_1000_0006_0000, mr
    );
    recovery = make_restore_gate_recovery("error_restore_released_ref", mr);
    hmc_ref = rdma_hmc_ref::type_id::create("error_restore_hmc_ref");
    hmc_ref.owner = binding.make_handle();
    hmc_ref.object_kind = RDMA_RESOURCE_MR;
    hmc_ref.address.value = 64'he225_2000_0000_0000;
    hmc_ref.size = 64'h1000;
    hmc_ref.first_pbl_index = 28'h1;
    hmc_ref.ownership = RDMA_OWNERSHIP_CONTROL_PLANE;
    hmc_ref.release_complete = 1'b1;
    recovery.hmc_refs.push_back(hmc_ref);
    expect_status("ERROR_RESTORE_RELEASED_REF_MARK",
                  manager.mark_error(mr.handle, recovery), RDMA_SC_OK);
    expect_status("ERROR_RESTORE_RELEASED_REF_REJECT",
                  manager.restore_active(mr.handle), RDMA_SC_INVALID_STATE);

    recovery = rdma_recovery_record::type_id::create("error_restore_pd");
    recovery.resource_h = clone_handle("ERROR_RESTORE_PD_H", pd.handle);
    recovery.hardware_presence = RDMA_HW_PRESENCE_PRESENT;
    recovery.primary_status = rdma_status::make(
      RDMA_SC_TIMEOUT, "PD cannot use MR ERROR restore"
    );
    expect_status("ERROR_RESTORE_PD_MARK",
                  manager.mark_error(pd.handle, recovery), RDMA_SC_OK);
    expect_status("ERROR_RESTORE_PD_REJECT",
                  manager.restore_active(pd.handle), RDMA_SC_INVALID_STATE);
  endtask

  task automatic check_error_restore_ref_authority_gate();
    rdma_resource_manager manager;
    rdma_function_binding binding;
    rdma_function_binding other_binding;
    rdma_pd pd;
    rdma_mr mr;
    rdma_recovery_record recovery;
    rdma_dma_mapping authoritative_mapping;
    rdma_dma_mapping recovery_mapping;
    rdma_mock_dma_mapping authoritative_owned_mapping;
    rdma_mock_dma_mapping recovery_owned_mapping;
    rdma_mock_release_seal release_seal;
    rdma_backing_ref authoritative_backing;
    rdma_backing_ref recovery_backing;
    rdma_hmc_ref authoritative_hmc;
    rdma_hmc_ref recovery_hmc;
    string check_name;

    manager = rdma_resource_manager::type_id::create(
      "error_restore_ref_manager"
    );
    binding = make_active_binding(
      "error_restore_ref_binding", 64'he226_0000_0000_0001,
      32'he226_0101, 32'd26
    );
    other_binding = make_active_binding(
      "error_restore_ref_other_binding", 64'he226_0000_0000_0002,
      32'he226_0102, 32'd26
    );
    expect_status("ERROR_RESTORE_REF_PD_CREATE",
                  manager.create_pd(binding, pd), RDMA_SC_OK);
    expect_status("ERROR_RESTORE_REF_PD_ACTIVATE",
                  manager.activate(pd.handle), RDMA_SC_OK);

    create_prepared_restore_gate_mr(
      "ERROR_RESTORE_BACKING_OMITTED", manager, binding, pd,
      64'he226_1000_0000_0000, mr
    );
    authoritative_mapping = rdma_dma_mapping::type_id::create(
      "error_restore_backing_omitted_mapping"
    );
    initialize_restore_gate_mapping(
      authoritative_mapping, binding, 64'he226_1000_0000_0000
    );
    authoritative_backing = make_restore_gate_backing_ref(
      "error_restore_backing_omitted_ref", authoritative_mapping,
      RDMA_OWNERSHIP_BORROWED
    );
    mr.backing_refs.push_back(authoritative_backing);
    activate_restore_gate_mr("ERROR_RESTORE_BACKING_OMITTED", manager, mr);
    recovery = make_restore_gate_recovery(
      "error_restore_backing_omitted", mr
    );
    expect_status("ERROR_RESTORE_BACKING_OMITTED_MARK",
                  manager.mark_error(mr.handle, recovery), RDMA_SC_OK);
    expect_status("ERROR_RESTORE_BACKING_OMITTED_REJECT",
                  manager.restore_active(mr.handle), RDMA_SC_INVALID_STATE);

    create_prepared_restore_gate_mr(
      "ERROR_RESTORE_BACKING_EXTRA", manager, binding, pd,
      64'he226_1000_0001_0000, mr
    );
    activate_restore_gate_mr("ERROR_RESTORE_BACKING_EXTRA", manager, mr);
    recovery = make_restore_gate_recovery("error_restore_backing_extra", mr);
    recovery_mapping = rdma_dma_mapping::type_id::create(
      "error_restore_backing_extra_mapping"
    );
    initialize_restore_gate_mapping(
      recovery_mapping, binding, 64'he226_1000_0001_0000
    );
    recovery.backing_refs.push_back(make_restore_gate_backing_ref(
      "error_restore_backing_extra_ref", recovery_mapping,
      RDMA_OWNERSHIP_BORROWED
    ));
    expect_status("ERROR_RESTORE_BACKING_EXTRA_MARK",
                  manager.mark_error(mr.handle, recovery), RDMA_SC_OK);
    expect_status("ERROR_RESTORE_BACKING_EXTRA_REJECT",
                  manager.restore_active(mr.handle), RDMA_SC_INVALID_STATE);

    create_prepared_restore_gate_mr(
      "ERROR_RESTORE_BACKING_DIFFERENT", manager, binding, pd,
      64'he226_1000_0002_0000, mr
    );
    authoritative_mapping = rdma_dma_mapping::type_id::create(
      "error_restore_backing_different_authoritative"
    );
    recovery_mapping = rdma_dma_mapping::type_id::create(
      "error_restore_backing_different_recovery"
    );
    initialize_restore_gate_mapping(
      authoritative_mapping, binding, 64'he226_1000_0002_0000
    );
    initialize_restore_gate_mapping(
      recovery_mapping, binding, 64'he226_1000_0002_1000
    );
    authoritative_backing = make_restore_gate_backing_ref(
      "error_restore_backing_different_authoritative_ref",
      authoritative_mapping, RDMA_OWNERSHIP_BORROWED
    );
    mr.backing_refs.push_back(authoritative_backing);
    activate_restore_gate_mr("ERROR_RESTORE_BACKING_DIFFERENT", manager, mr);
    recovery = make_restore_gate_recovery(
      "error_restore_backing_different", mr
    );
    recovery.backing_refs.push_back(make_restore_gate_backing_ref(
      "error_restore_backing_different_recovery_ref", recovery_mapping,
      RDMA_OWNERSHIP_BORROWED
    ));
    expect_status("ERROR_RESTORE_BACKING_DIFFERENT_MARK",
                  manager.mark_error(mr.handle, recovery), RDMA_SC_OK);
    expect_status("ERROR_RESTORE_BACKING_DIFFERENT_REJECT",
                  manager.restore_active(mr.handle), RDMA_SC_INVALID_STATE);

    release_seal = new("error_restore_ownership_seal");
    authoritative_owned_mapping = rdma_mock_dma_mapping::type_id::create(
      "error_restore_ownership_mapping"
    );
    expect_status("ERROR_RESTORE_OWNERSHIP_TOKEN",
                  authoritative_owned_mapping.initialize_allocation_token(
                    release_seal
                  ), RDMA_SC_OK);
    initialize_restore_gate_mapping(
      authoritative_owned_mapping, binding, 64'he226_1000_0003_0000
    );
    create_prepared_restore_gate_mr(
      "ERROR_RESTORE_BACKING_OWNERSHIP", manager, binding, pd,
      authoritative_owned_mapping.iova.value, mr
    );
    authoritative_backing = make_restore_gate_backing_ref(
      "error_restore_ownership_authoritative_ref",
      authoritative_owned_mapping, RDMA_OWNERSHIP_BORROWED
    );
    mr.backing_refs.push_back(authoritative_backing);
    activate_restore_gate_mr("ERROR_RESTORE_BACKING_OWNERSHIP", manager, mr);
    recovery = make_restore_gate_recovery(
      "error_restore_backing_ownership", mr
    );
    recovery.backing_refs.push_back(make_restore_gate_backing_ref(
      "error_restore_ownership_recovery_ref", authoritative_owned_mapping,
      RDMA_OWNERSHIP_CONTROL_PLANE
    ));
    expect_status("ERROR_RESTORE_BACKING_OWNERSHIP_MARK",
                  manager.mark_error(mr.handle, recovery), RDMA_SC_OK);
    expect_status("ERROR_RESTORE_BACKING_OWNERSHIP_REJECT",
                  manager.restore_active(mr.handle), RDMA_SC_INVALID_STATE);

    release_seal = new("error_restore_different_owned_seal");
    authoritative_owned_mapping = rdma_mock_dma_mapping::type_id::create(
      "error_restore_different_owned_authoritative"
    );
    recovery_owned_mapping = rdma_mock_dma_mapping::type_id::create(
      "error_restore_different_owned_recovery"
    );
    expect_status("ERROR_RESTORE_DIFFERENT_OWNED_AUTH_TOKEN",
                  authoritative_owned_mapping.initialize_allocation_token(
                    release_seal
                  ), RDMA_SC_OK);
    expect_status("ERROR_RESTORE_DIFFERENT_OWNED_RECOVERY_TOKEN",
                  recovery_owned_mapping.initialize_allocation_token(
                    release_seal
                  ), RDMA_SC_OK);
    initialize_restore_gate_mapping(
      authoritative_owned_mapping, binding, 64'he226_1000_0004_0000
    );
    initialize_restore_gate_mapping(
      recovery_owned_mapping, binding, 64'he226_1000_0004_0000
    );
    create_prepared_restore_gate_mr(
      "ERROR_RESTORE_DIFFERENT_OWNED", manager, binding, pd,
      authoritative_owned_mapping.iova.value, mr
    );
    mr.backing_refs.push_back(make_restore_gate_backing_ref(
      "error_restore_different_owned_authoritative_ref",
      authoritative_owned_mapping, RDMA_OWNERSHIP_CONTROL_PLANE
    ));
    activate_restore_gate_mr("ERROR_RESTORE_DIFFERENT_OWNED", manager, mr);
    recovery = make_restore_gate_recovery(
      "error_restore_different_owned", mr
    );
    recovery.backing_refs.push_back(make_restore_gate_backing_ref(
      "error_restore_different_owned_recovery_ref", recovery_owned_mapping,
      RDMA_OWNERSHIP_CONTROL_PLANE
    ));
    expect_status("ERROR_RESTORE_DIFFERENT_OWNED_MARK",
                  manager.mark_error(mr.handle, recovery), RDMA_SC_OK);
    expect_status("ERROR_RESTORE_DIFFERENT_OWNED_REJECT",
                  manager.restore_active(mr.handle), RDMA_SC_INVALID_STATE);

    create_prepared_restore_gate_mr(
      "ERROR_RESTORE_HMC_OMITTED", manager, binding, pd,
      64'he226_1000_0005_0000, mr
    );
    authoritative_hmc = make_restore_gate_hmc_ref(
      "error_restore_hmc_omitted_ref", binding.make_handle(),
      64'he226_2000_0000_0000
    );
    mr.hmc_refs.push_back(authoritative_hmc);
    activate_restore_gate_mr("ERROR_RESTORE_HMC_OMITTED", manager, mr);
    recovery = make_restore_gate_recovery("error_restore_hmc_omitted", mr);
    expect_status("ERROR_RESTORE_HMC_OMITTED_MARK",
                  manager.mark_error(mr.handle, recovery), RDMA_SC_OK);
    expect_status("ERROR_RESTORE_HMC_OMITTED_REJECT",
                  manager.restore_active(mr.handle), RDMA_SC_INVALID_STATE);

    create_prepared_restore_gate_mr(
      "ERROR_RESTORE_HMC_EXTRA", manager, binding, pd,
      64'he226_1000_0006_0000, mr
    );
    activate_restore_gate_mr("ERROR_RESTORE_HMC_EXTRA", manager, mr);
    recovery = make_restore_gate_recovery("error_restore_hmc_extra", mr);
    recovery.hmc_refs.push_back(make_restore_gate_hmc_ref(
      "error_restore_hmc_extra_ref", binding.make_handle(),
      64'he226_2000_0001_0000
    ));
    expect_status("ERROR_RESTORE_HMC_EXTRA_MARK",
                  manager.mark_error(mr.handle, recovery), RDMA_SC_OK);
    expect_status("ERROR_RESTORE_HMC_EXTRA_REJECT",
                  manager.restore_active(mr.handle), RDMA_SC_INVALID_STATE);

    for (int variant = 0; variant < 6; variant++) begin
      check_name = $sformatf("ERROR_RESTORE_HMC_DIFFERENT_%0d", variant);
      create_prepared_restore_gate_mr(
        check_name, manager, binding, pd,
        64'he226_1000_0010_0000 + (variant * 64'h1_0000), mr
      );
      authoritative_hmc = make_restore_gate_hmc_ref(
        {check_name, "_AUTHORITATIVE"}, binding.make_handle(),
        64'he226_2000_0010_0000 + (variant * 64'h1_0000)
      );
      mr.hmc_refs.push_back(authoritative_hmc);
      activate_restore_gate_mr(check_name, manager, mr);
      recovery = make_restore_gate_recovery(
        {check_name, "_RECOVERY"}, mr
      );
      recovery_hmc = make_restore_gate_hmc_ref(
        {check_name, "_RECOVERY_REF"}, binding.make_handle(),
        authoritative_hmc.address.value
      );
      case (variant)
        0: recovery_hmc.owner = other_binding.make_handle();
        1: recovery_hmc.object_kind = RDMA_RESOURCE_PD;
        2: recovery_hmc.address.value++;
        3: recovery_hmc.size++;
        4: recovery_hmc.first_pbl_index++;
        5: recovery_hmc.ownership = RDMA_OWNERSHIP_CONTROL_PLANE;
      endcase
      recovery.hmc_refs.push_back(recovery_hmc);
      if (variant == 1) begin
        expect_status({check_name, "_MARK_REJECT"},
                      manager.mark_error(mr.handle, recovery),
                      RDMA_SC_INVALID_ARGUMENT);
      end
      else begin
        expect_status({check_name, "_MARK"},
                      manager.mark_error(mr.handle, recovery), RDMA_SC_OK);
        expect_status({check_name, "_REJECT"},
                      manager.restore_active(mr.handle),
                      RDMA_SC_INVALID_STATE);
      end
    end

    release_seal = new("error_restore_sealed_owned_seal");
    authoritative_owned_mapping = rdma_mock_dma_mapping::type_id::create(
      "error_restore_sealed_owned_mapping"
    );
    expect_status("ERROR_RESTORE_SEALED_OWNED_TOKEN",
                  authoritative_owned_mapping.initialize_allocation_token(
                    release_seal
                  ), RDMA_SC_OK);
    initialize_restore_gate_mapping(
      authoritative_owned_mapping, binding, 64'he226_1000_0020_0000
    );
    create_prepared_restore_gate_mr(
      "ERROR_RESTORE_SEALED_OWNED", manager, binding, pd,
      authoritative_owned_mapping.iova.value, mr
    );
    authoritative_backing = make_restore_gate_backing_ref(
      "error_restore_sealed_owned_ref", authoritative_owned_mapping,
      RDMA_OWNERSHIP_CONTROL_PLANE
    );
    mr.backing_refs.push_back(authoritative_backing);
    activate_restore_gate_mr("ERROR_RESTORE_SEALED_OWNED", manager, mr);
    recovery = make_restore_gate_recovery(
      "error_restore_sealed_owned", mr
    );
    recovery.backing_refs.push_back(authoritative_backing);
    expect_status("ERROR_RESTORE_SEALED_OWNED_MARK",
                  manager.mark_error(mr.handle, recovery), RDMA_SC_OK);
    expect_status("ERROR_RESTORE_SEALED_OWNED_SEAL",
                  authoritative_owned_mapping.mark_release_complete(
                    release_seal
                  ), RDMA_SC_OK);
    expect_status("ERROR_RESTORE_SEALED_OWNED_REJECT",
                  manager.restore_active(mr.handle), RDMA_SC_INVALID_STATE);

    release_seal = new("error_restore_exact_owned_seal");
    authoritative_owned_mapping = rdma_mock_dma_mapping::type_id::create(
      "error_restore_exact_owned_mapping"
    );
    expect_status("ERROR_RESTORE_EXACT_OWNED_TOKEN",
                  authoritative_owned_mapping.initialize_allocation_token(
                    release_seal
                  ), RDMA_SC_OK);
    initialize_restore_gate_mapping(
      authoritative_owned_mapping, binding, 64'he226_1000_0021_0000
    );
    create_prepared_restore_gate_mr(
      "ERROR_RESTORE_EXACT", manager, binding, pd,
      authoritative_owned_mapping.iova.value, mr
    );
    authoritative_backing = make_restore_gate_backing_ref(
      "error_restore_exact_backing", authoritative_owned_mapping,
      RDMA_OWNERSHIP_CONTROL_PLANE
    );
    authoritative_hmc = make_restore_gate_hmc_ref(
      "error_restore_exact_hmc", binding.make_handle(),
      64'he226_2000_0021_0000
    );
    mr.backing_refs.push_back(authoritative_backing);
    mr.hmc_refs.push_back(authoritative_hmc);
    activate_restore_gate_mr("ERROR_RESTORE_EXACT", manager, mr);
    recovery = make_restore_gate_recovery("error_restore_exact", mr);
    recovery.backing_refs.push_back(authoritative_backing);
    recovery.hmc_refs.push_back(authoritative_hmc);
    expect_status("ERROR_RESTORE_EXACT_MARK",
                  manager.mark_error(mr.handle, recovery), RDMA_SC_OK);
    expect_status("ERROR_RESTORE_EXACT_RUN",
                  manager.restore_active(mr.handle), RDMA_SC_OK);
  endtask

  function automatic bit same_handle_fields(rdma_handle lhs,
                                             rdma_handle rhs);
    if (lhs == null || rhs == null)
      return lhs == rhs;
    return lhs.kind == rhs.kind &&
           lhs.function_uid == rhs.function_uid &&
           lhs.object_id == rhs.object_id &&
           lhs.generation == rhs.generation;
  endfunction

  function automatic bit same_status_fields(rdma_status lhs,
                                             rdma_status rhs);
    if (lhs == null || rhs == null)
      return lhs == rhs;
    return lhs.category == rhs.category &&
           lhs.code == rhs.code &&
           lhs.hardware_code == rhs.hardware_code &&
           lhs.hardware_code_valid == rhs.hardware_code_valid &&
           lhs.source_engine == rhs.source_engine &&
           lhs.function_uid == rhs.function_uid &&
           lhs.generation == rhs.generation &&
           lhs.resource_id == rhs.resource_id &&
           lhs.command_id == rhs.command_id &&
           lhs.wr_id == rhs.wr_id &&
           lhs.severity == rhs.severity &&
           lhs.retryable == rhs.retryable &&
           lhs.message == rhs.message;
  endfunction

  task run_phase(uvm_phase phase);
    rdma_resource_manager rm;
    rdma_resource_manager dep_rm;
    rdma_resource_manager teardown_rm;
    rdma_resource_manager identity_rm;
    rdma_resource_manager all_kind_rm;
    rdma_resource_manager generation_rm;
    rdma_resource_manager snapshot_rm;
    rdma_resource_manager rollback_rm;
    rdma_resource_manager function_cycle_rm;
    rdma_resource_manager function_wrap_rm;
    rdma_resource_manager function_release_rm;
    rdma_resource_manager_probe permanent_exhaustion_rm;
    rdma_resource_manager_probe exhaustion_rm;
    rdma_width_probe_manager width_pd_rm;
    rdma_width_probe_manager width_mr_rm;
    rdma_width_probe_manager width_cq_rm;
    rdma_width_probe_manager width_function_rm;
    rdma_width_probe_manager width_free_pd_rm;
    rdma_width_probe_manager width_free_mr_rm;
    rdma_resource_manager lifecycle_rm;
    rdma_width_probe_manager publication_rm;
    rdma_resource_manager pd_commit_rm;
    rdma_width_probe_manager dependency_gate_rm;
    rdma_clone_probe_manager clone_gate_rm;
    rdma_clone_probe_manager schema_rm;
    rdma_clone_probe_manager schema_lookup_rm;
    rdma_clone_probe_manager projection_rm;
    rdma_clone_probe_manager composite_function_rm;
    rdma_clone_probe_manager composite_mr_rm;
    rdma_clone_probe_manager composite_recovery_rm;
    rdma_resource_manager allocated_error_rm;
    rdma_resource_manager recovery_rm;
    rdma_resource_manager_probe privileged_recovery_rm;
    rdma_resource_manager stale_recovery_rm;
    rdma_resource_manager queue_snapshot_rm;
    rdma_qp_lifecycle_probe_manager qp_rm;
    rdma_qp_lifecycle_probe_manager qp_generic_bypass_rm;
    rdma_width_probe_manager qp_width_rm;
    rdma_hmc_allocator hmc;
    rdma_hmc_allocator hmc_exhaustion;
    rdma_hmc_allocator hmc_overflow;
    rdma_function_binding active_binding;
    rdma_function_binding binding_a;
    rdma_function_binding binding_b;
    rdma_function_binding exhaustion_binding;
    rdma_function_binding snapshot_binding;
    rdma_function_binding rollback_binding;
    rdma_function_binding function_cycle_binding;
    rdma_function_binding function_wrap_binding;
    rdma_function_binding function_release_binding;
    rdma_function_binding permanent_exhaustion_binding;
    rdma_function_binding width_binding;
    rdma_function_binding width_binding_copy;
    rdma_function_binding width_function_binding_a;
    rdma_function_binding width_function_binding_b;
    rdma_function_binding width_function_binding_b_copy;
    rdma_function_binding lifecycle_binding;
    rdma_function_binding publication_binding;
    rdma_function_binding pd_commit_binding;
    rdma_function_binding dependency_gate_binding;
    rdma_function_binding clone_gate_binding;
    rdma_function_binding schema_binding;
    rdma_function_binding schema_lookup_binding;
    rdma_function_binding schema_nested_binding;
    rdma_function_binding projection_binding;
    rdma_function_binding composite_mr_binding;
    rdma_function_binding composite_recovery_binding;
    rdma_rm_schema_binding schema_binding_probe;
    rdma_rm_schema_pcie schema_pcie_probe;
    rdma_rm_schema_bar schema_bar_probe;
    rdma_rm_schema_binding composite_function_binding;
    rdma_rm_schema_pcie composite_function_pcie;
    rdma_rm_schema_bar composite_function_bars[6];
    rdma_interrupt_vector_binding composite_function_vector;
    rdma_rm_schema_function_handle composite_function_owner;
    rdma_function_binding allocated_error_binding;
    rdma_function_binding recovery_binding;
    rdma_function_binding privileged_recovery_binding;
    rdma_function_binding stale_recovery_binding;
    rdma_function_binding queue_snapshot_binding;
    rdma_function_binding qp_binding;
    rdma_function_binding qp_generic_bypass_binding;
    rdma_function_binding qp_width_binding;
    rdma_function_handle owner_h;
    rdma_function_handle owner_b_h;
    rdma_pd pd;
    rdma_pd pd_first;
    rdma_pd pd_reused;
    rdma_pd pd_b;
    rdma_pd dep_pd;
    rdma_pd teardown_pd;
    rdma_pd exhausted_pd;
    rdma_pd width_pd;
    rdma_pd width_pd_failed;
    rdma_pd width_mr_pd;
    rdma_pd width_free_mr_pd;
    rdma_pd lifecycle_pd;
    rdma_pd publication_pd;
    rdma_pd pd_commit_pd;
    rdma_pd dependency_quiescing_pd;
    rdma_pd dependency_error_pd;
    rdma_pd clone_gate_pd;
    rdma_pd clone_kind_pd_seed;
    rdma_rm_fault_pd clone_kind_pd_authoritative;
    rdma_rm_fault_pd clone_kind_pd_candidate;
    rdma_rm_fault_pd clone_kind_pd_lookup;
    rdma_pd clone_recovery_pd;
    rdma_pd schema_pd;
    rdma_pd schema_recovery_pd;
    rdma_pd projection_pd;
    rdma_pd projection_recovery_pd_a;
    rdma_pd projection_recovery_pd_b;
    rdma_pd composite_mr_pd;
    rdma_pd composite_recovery_pd;
    rdma_pd allocated_error_pd;
    rdma_pd wrong_stage_pd;
    rdma_pd recovery_pd;
    rdma_pd privileged_recovery_pd;
    rdma_pd privileged_recovery_pd_reused;
    rdma_pd stale_recovery_pd;
    rdma_pd qp_pd;
    rdma_pd qp_generic_bypass_pd;
    rdma_pd qp_width_pd;
    rdma_function all_kind_function;
    rdma_pd all_kind_pd;
    rdma_pd generation_pd;
    rdma_pd rejected_generation_pd;
    rdma_pd next_generation_pd;
    rdma_pd snapshot_pd;
    rdma_pd rollback_pd;
    rdma_mr all_kind_mr;
    rdma_cq all_kind_cq;
    rdma_cq all_kind_lookup_cq;
    rdma_queue_resource all_kind_lookup_queue;
    rdma_qp all_kind_qp;
    rdma_qp all_kind_lookup_qp;
    rdma_srq all_kind_srq;
    rdma_srq all_kind_lookup_srq;
    rdma_cmq all_kind_cmq;
    rdma_ceq all_kind_ceq;
    rdma_ceq all_kind_lookup_ceq;
    rdma_aeq all_kind_aeq;
    rdma_aeq all_kind_lookup_aeq;
    rdma_function snapshot_function;
    rdma_function snapshot_function_lookup;
    rdma_function function_a;
    rdma_function function_b;
    rdma_function rejected_function;
    rdma_function function_max;
    rdma_function function_wrapped;
    rdma_function function_release_function;
    rdma_function function_release_lookup;
    rdma_function width_function_a;
    rdma_function width_function_b_failed;
    rdma_function width_function_b_reused;
    rdma_function clone_gate_function;
    rdma_rm_fault_function clone_fault_function;
    rdma_function composite_function;
    rdma_function composite_function_lookup;
    rdma_pd function_release_pd;
    rdma_function permanent_exhaustion_function;
    rdma_pd permanent_exhaustion_pd;
    rdma_cmq permanent_exhaustion_cmq;
    rdma_cmq qp_generic_bypass_cmq;
    rdma_cmq qp_cmq;
    rdma_aeq permanent_exhaustion_aeq;
    rdma_mr dep_mr;
    rdma_mr teardown_mr;
    rdma_mr width_mr;
    rdma_mr width_mr_failed;
    rdma_mr width_free_mr;
    rdma_mr lifecycle_mr;
    rdma_mr publication_local_mr;
    rdma_mr publication_global_mr;
    rdma_mr publication_topology_mr;
    rdma_mr publication_commit_mr;
    rdma_mr publication_lookup_mr;
    rdma_mr dependency_blocked_mr;
    rdma_mr clone_seed_mr;
    rdma_rm_fault_mr clone_authoritative_mr;
    rdma_rm_fault_mr clone_candidate_mr;
    rdma_rm_fault_mr clone_wrong_mr;
    rdma_rm_fault_mr clone_drift_mr;
    rdma_rm_schema_mr schema_mr;
    rdma_mr schema_nested_mr;
    rdma_mr schema_seed_mr;
    rdma_rm_stateful_mr schema_registry_mr;
    rdma_mr projection_seed_mr;
    rdma_mr projection_nested_mr;
    rdma_mr projection_lookup_mr;
    rdma_mr composite_mr_seed;
    rdma_mr composite_mr_lookup;
    rdma_rm_schema_mr composite_mr_candidate;
    rdma_rm_unregistered_mr projection_unregistered_mr;
    rdma_rm_unregistered_mr projection_unregistered_mr_leak;
    rdma_rm_unregistered_mr projection_mismatched_mr;
    rdma_rm_lying_mr projection_lying_mr;
    rdma_rm_lying_mr projection_lying_mr_leak;
    rdma_mr allocated_error_mr;
    rdma_cq cq_pool;
    rdma_cq width_cq;
    rdma_cq width_cq_failed;
    rdma_cq width_cq_reused;
    rdma_cq publication_cq;
    rdma_cq publication_lookup_cq;
    rdma_cq queue_snapshot_cq;
    rdma_cq queue_snapshot_lookup_cq;
    rdma_ceq queue_snapshot_ceq;
    rdma_cq dep_cq;
    rdma_cq teardown_cq;
    rdma_cq clone_kind_cq_seed;
    rdma_rm_fault_cq clone_kind_cq_authoritative;
    rdma_rm_fault_cq clone_kind_cq_candidate;
    rdma_rm_fault_cq clone_kind_cq_lookup;
    rdma_cq qp_send_cq;
    rdma_cq qp_recv_cq;
    rdma_cq qp_generic_bypass_send_cq;
    rdma_cq qp_generic_bypass_recv_cq;
    rdma_cq qp_width_send_cq;
    rdma_cq qp_width_recv_cq;
    rdma_qp dep_qp;
    rdma_qp teardown_qp;
    rdma_qp snapshot_qp;
    rdma_qp snapshot_qp_lookup;
    rdma_qp clone_kind_qp_seed;
    rdma_rm_fault_qp clone_kind_qp_authoritative;
    rdma_rm_fault_qp clone_kind_qp_candidate;
    rdma_rm_fault_qp clone_kind_qp_lookup;
    rdma_qp qp_candidate;
    rdma_qp qp_nested_candidate;
    rdma_qp qp_generic_bypass_candidate;
    rdma_qp qp_generic_bypass_lookup;
    rdma_qp qp_lookup;
    rdma_qp qp_failed_lookup;
    rdma_qp qp_reused;
    rdma_qp qp_urc;
    rdma_qp qp_prior_candidate;
    rdma_qp qp_restore;
    rdma_qp qp_restore_candidate;
    rdma_qp qp_width_max;
    rdma_qp qp_width_overflow;
    rdma_srq dep_srq;
    rdma_srq clone_kind_srq_seed;
    rdma_rm_fault_srq clone_kind_srq_authoritative;
    rdma_rm_fault_srq clone_kind_srq_candidate;
    rdma_rm_fault_srq clone_kind_srq_lookup;
    rdma_ceq dep_ceq;
    rdma_ceq teardown_ceq;
    rdma_ceq clone_kind_ceq_seed;
    rdma_rm_fault_ceq clone_kind_ceq_authoritative;
    rdma_rm_fault_ceq clone_kind_ceq_candidate;
    rdma_rm_fault_ceq clone_kind_ceq_lookup;
    rdma_aeq frozen_aeq;
    rdma_aeq width_probe_aeq;
    rdma_aeq rollback_aeq;
    rdma_aeq schema_rejected_aeq;
    rdma_aeq clone_kind_aeq_seed;
    rdma_rm_fault_aeq clone_kind_aeq_authoritative;
    rdma_rm_fault_aeq clone_kind_aeq_candidate;
    rdma_rm_fault_aeq clone_kind_aeq_lookup;
    rdma_cmq clone_kind_cmq_seed;
    rdma_rm_fault_cmq clone_kind_cmq_authoritative;
    rdma_rm_fault_cmq clone_kind_cmq_candidate;
    rdma_rm_fault_cmq clone_kind_cmq_lookup;
    rdma_handle old_h;
    rdma_handle same_generation_old_h;
    rdma_handle frozen_qp_h;
    rdma_handle forged_h;
    rdma_handle generation_old_h;
    rdma_handle snapshot_pd_h;
    rdma_handle snapshot_qp_h;
    rdma_handle rollback_h;
    rdma_handle function_release_h;
    rdma_handle width_pd_h;
    rdma_handle width_cq_h;
    rdma_function_handle width_function_owner_a;
    rdma_handle lifecycle_mr_h;
    rdma_handle stale_recovery_h;
    rdma_function_handle stale_recovery_owner;
    rdma_function_handle privileged_recovery_owner;
    rdma_resource resource;
    rdma_resource second_resource;
    rdma_resource clone_probe_result;
    rdma_resource schema_authoritative;
    rdma_recovery_record recovery_record;
    rdma_recovery_record recovery_lookup;
    rdma_recovery_record recovery_lookup_again;
    rdma_recovery_record qp_generic_bypass_recovery;
    rdma_recovery_record malformed_recovery;
    rdma_recovery_record ready_recovery;
    rdma_qp_recovery_state qp_recovery_state;
    rdma_qp_recovery_state qp_modify_recovery_state;
    rdma_qp_recovery_state qp_prior_recovery_state;
    rdma_qp_recovery_state qp_urc_recovery_state;
    rdma_qp_recovery_state qp_nested_recovery_state;
    rdma_qp_recovery_state qp_qpc_binding_recovery;
    rdma_qp_recovery_state qp_error_replacement;
    rdma_rm_fault_recovery clone_fault_recovery;
    rdma_rm_schema_recovery schema_recovery;
    rdma_recovery_record schema_nested_recovery;
    rdma_rm_schema_recovery schema_registry_recovery;
    rdma_recovery_record schema_recovery_before;
    rdma_rm_unregistered_recovery projection_unregistered_recovery;
    rdma_rm_unregistered_recovery projection_unregistered_recovery_leak;
    rdma_rm_lying_recovery projection_lying_recovery;
    rdma_rm_lying_recovery projection_lying_recovery_leak;
    rdma_rm_schema_recovery composite_recovery;
    rdma_backing_ref clone_backing_ref;
    rdma_backing_ref schema_exact_backing_ref;
    rdma_backing_ref projection_unregistered_backing_ref;
    rdma_backing_ref projection_lying_backing_ref;
    rdma_backing_ref qp_generic_backing_ref;
    rdma_dma_mapping clone_mapping;
    rdma_dma_mapping qp_nested_mapping;
    rdma_dma_mapping schema_mapping;
    rdma_rm_schema_mapping schema_mapping_probe;
    rdma_rm_unregistered_mapping projection_unregistered_mapping;
    rdma_rm_unregistered_mapping projection_unregistered_mapping_leak;
    rdma_rm_lying_mapping projection_lying_mapping;
    rdma_rm_lying_mapping projection_lying_mapping_leak;
    rdma_rm_schema_backing_ref composite_backing_refs[2];
    rdma_rm_schema_mapping composite_mappings[2];
    rdma_rm_schema_hmc_ref composite_hmc_refs[2];
    rdma_rm_schema_function_handle composite_mapping_functions[2];
    rdma_rm_schema_handle composite_mapping_owners[2];
    rdma_rm_schema_function_handle composite_hmc_owners[2];
    rdma_hmc_ref clone_hmc_ref;
    rdma_rm_schema_hmc_ref schema_hmc_probe;
    rdma_mr clone_lookup_mr;
    rdma_rm_clone_fault_e resource_clone_faults[$];
    string resource_clone_fault_names[$];
    rdma_rm_clone_fault_e recovery_clone_faults[$];
    string recovery_clone_fault_names[$];
    rdma_cmq_ticket clone_ticket;
    rdma_cmq_ticket schema_exact_ticket;
    rdma_cmq_opcode_key schema_opcode;
    rdma_rm_schema_opcode schema_opcode_probe;
    rdma_rm_schema_handle schema_handle;
    rdma_rm_schema_backing_ref schema_backing_ref;
    rdma_rm_schema_ticket schema_ticket;
    rdma_rm_schema_status schema_status;
    rdma_rm_schema_function_handle schema_function_handle;
    rdma_rm_schema_handle composite_mr_handle;
    rdma_rm_schema_handle composite_mr_pd_handle;
    rdma_rm_schema_handle composite_mr_dependency;
    rdma_rm_schema_function_handle composite_mr_owner;
    rdma_rm_schema_handle composite_recovery_resource;
    rdma_rm_schema_ticket composite_recovery_ticket;
    rdma_rm_schema_function_handle composite_ticket_function;
    rdma_rm_schema_handle composite_ticket_cmq;
    rdma_rm_schema_opcode composite_ticket_opcode;
    rdma_rm_schema_status composite_primary_status;
    rdma_rm_schema_status composite_rollback_statuses[2];
    rdma_rm_schema_binding composite_binding_leak;
    rdma_rm_schema_pcie composite_pcie_leak;
    rdma_rm_schema_bar composite_bar_leak;
    rdma_rm_schema_mr composite_mr_leak;
    rdma_rm_schema_backing_ref composite_backing_leak;
    rdma_rm_schema_mapping composite_mapping_leak;
    rdma_rm_schema_hmc_ref composite_hmc_leak;
    rdma_rm_schema_recovery composite_recovery_leak;
    rdma_rm_schema_ticket composite_ticket_leak;
    rdma_rm_schema_opcode composite_opcode_leak;
    rdma_rm_schema_status composite_status_leak;
    rdma_rm_schema_handle composite_handle_leak;
    rdma_rm_schema_function_handle composite_function_handle_leak;
    rdma_handle mutating_clone_pd_ref;
    rdma_queue_slot_token_contract qp_nested_context_token;
    rdma_queue_slot_token_contract qp_nested_plan_context_token;
    rdma_queue_completion_authority qp_nested_context_authority;
    rdma_cmq_ticket mutating_clone_ticket_ref;
    longint unsigned mutating_clone_length;
    rdma_hw_presence_e mutating_clone_presence;
    longint unsigned projection_size_before;
    rdma_hw_presence_e projection_presence_before;
    rdma_status s;
    int unsigned leak_count;
    int unsigned pd_local_before_exhaustion;
    int unsigned pd_serial_before_exhaustion;
    int unsigned cmq_local_before_exhaustion;
    int unsigned cmq_serial_before_exhaustion;
    int unsigned serial_before_width_failure;
    int unsigned free_count_before_width_failure;
    int unsigned publication_serial_before;
    int unsigned publication_free_before;
    int unsigned publication_local_before;
    int unsigned publication_global_before;
    int unsigned schema_generation_before;
    rdma_resource all_kind_resources[$];
    rdma_hmc_fvm_addr_t hmc_base;
    rdma_hmc_fvm_addr_t hmc_addr;
    rdma_hmc_fvm_addr_t hmc_addr_two;
    rdma_hmc_fvm_addr_t hmc_other_addr;
    rdma_iova_t equal_iova;
    rdma_dma_mapping untouched_mapping;
    rdma_dma_mapping queue_snapshot_segment_mapping;
    rdma_queue_backing_plan queue_snapshot_plan;
    rdma_queue_backing_segment queue_snapshot_segment;
    rdma_queue_slot_token_contract queue_snapshot_source_token;
    rdma_queue_slot_token_contract queue_snapshot_stored_token;
    rdma_queue_completion_authority queue_snapshot_source_authority;
    rdma_queue_completion_authority queue_snapshot_replacement_authority;
    rdma_dma_mapping queue_snapshot_authority;
    rdma_dma_mapping queue_snapshot_unsupported_authority;
    rdma_rm_owned_authority_hook_mapping queue_snapshot_borrowed_leak;
    longint unsigned lease_size;
    string hmc_type_name;
    string iova_type_name;
    rdma_bdf_t snapshot_bdf;
    rdma_pcie_identity schema_saved_pcie;
    uvm_object qp_cloned_object;
    rdma_qpc_rc_ext qp_unexpected_ext;
    rdma_qpc_model qp_qpc_binding_candidate;
    bit [7:0] qp_sequence_first;
    bit [7:0] qp_sequence_reused;

    phase.raise_objection(this);
    check_owned_mapping_clone_contract_rejections();
    check_owned_mapping_capability_snapshots();
    check_reserved_error_completion_proof();
    check_error_restore_active_gate();
    check_error_restore_ref_authority_gate();

    queue_snapshot_rm =
      rdma_resource_manager::type_id::create("queue_snapshot_rm");
    queue_snapshot_binding = make_active_binding(
      "queue_snapshot_binding", 64'h5155_4555_4500_0001,
      32'h5155_0101, 32'd51
    );
    expect_status(
      "QUEUE_SNAPSHOT_CREATE_CEQ",
      queue_snapshot_rm.create_ceq(queue_snapshot_binding,
                                   queue_snapshot_ceq),
      RDMA_SC_OK
    );
    expect_status(
      "QUEUE_SNAPSHOT_CREATE_CQ",
      queue_snapshot_rm.create_cq(queue_snapshot_binding,
                                  queue_snapshot_ceq.handle,
                                  queue_snapshot_cq),
      RDMA_SC_OK
    );
    queue_snapshot_cq.depth = 128;
    queue_snapshot_cq.cqe_size_bytes = 128;
    expect_status(
      "QUEUE_SNAPSHOT_STAGE_REQUIRES_PROGRAMMED_PLAN",
      queue_snapshot_rm.stage_allocated(queue_snapshot_cq),
      RDMA_SC_INVALID_ARGUMENT
    );
    queue_snapshot_plan = make_queue_test_plan(
      "queue_snapshot_plan", RDMA_RESOURCE_CQ, queue_snapshot_cq.depth,
      queue_snapshot_cq.owner, queue_snapshot_cq.handle,
      queue_snapshot_cq.local_cq_id
    );
    queue_snapshot_segment_mapping = make_queue_test_mapping(
      "queue_snapshot_segment_mapping", queue_snapshot_cq.owner,
      queue_snapshot_cq.handle, 64'h0000_4300_0000_0000, 1'b0
    );
    queue_snapshot_segment = rdma_queue_backing_segment::type_id::create(
      "queue_snapshot_segment"
    );
    queue_snapshot_segment.role = RDMA_QUEUE_ROLE_CQ_RING;
    queue_snapshot_segment.mapping = queue_snapshot_segment_mapping;
    queue_snapshot_segment.ownership = RDMA_OWNERSHIP_BORROWED;
    queue_snapshot_segment.mapping_offset = 4096;
    queue_snapshot_segment.length = 4096;
    queue_snapshot_segment.logical_queue_offset =
      queue_snapshot_plan.refs[0].length;
    queue_snapshot_plan.refs[0].additional_segments.push_back(
      queue_snapshot_segment
    );
    queue_snapshot_cq.queue_plan = queue_snapshot_plan;
    if (!$cast(queue_snapshot_source_token,
               queue_snapshot_plan.context_ref.slot_token))
      `uvm_fatal("QUEUE_SNAPSHOT_TOKEN", "source token contract cast failed")
    queue_snapshot_source_authority =
      queue_snapshot_source_token.completion_authority;
    expect_status(
      "QUEUE_SNAPSHOT_OWNED_AUTHORITY",
      queue_snapshot_plan.refs[1].mapping.snapshot_release_authority(
        queue_snapshot_authority
      ),
      RDMA_SC_OK
    );
    queue_snapshot_plan.context_ref.hmc_ref.ownership =
      RDMA_OWNERSHIP_BORROWED;
    expect_status(
      "QUEUE_SNAPSHOT_STAGE_BORROWED_CONTEXT_HMC",
      queue_snapshot_rm.stage_allocated(queue_snapshot_cq),
      RDMA_SC_INVALID_STATE
    );
    queue_snapshot_plan.context_ref.hmc_ref.ownership =
      RDMA_OWNERSHIP_CONTROL_PLANE;
    expect_status(
      "QUEUE_SNAPSHOT_STAGE",
      queue_snapshot_rm.stage_allocated(queue_snapshot_cq), RDMA_SC_OK
    );

    queue_snapshot_plan.rings[0].depth = 64;
    queue_snapshot_plan.refs[0].mapping.size = 4096;
    queue_snapshot_segment.length = 8192;
    queue_snapshot_segment.mapping.iova.value += 64'h0000_0000_0001_0000;
    queue_snapshot_replacement_authority =
      rdma_queue_completion_authority::type_id::create(
        "queue_snapshot_replacement_authority"
      );
    queue_snapshot_source_token.completion_authority =
      queue_snapshot_replacement_authority;
    expect_status(
      "QUEUE_SNAPSHOT_LOOKUP",
      queue_snapshot_rm.lookup(queue_snapshot_cq.handle, resource),
      RDMA_SC_OK
    );
    if (!$cast(queue_snapshot_lookup_cq, resource) ||
        queue_snapshot_lookup_cq.queue_plan == null ||
        queue_snapshot_lookup_cq.queue_plan == queue_snapshot_plan ||
        queue_snapshot_lookup_cq.queue_plan.rings[0].depth != 128 ||
        queue_snapshot_lookup_cq.queue_plan.refs[0].mapping.size !=
          64'h20_0000 ||
        queue_snapshot_lookup_cq.queue_plan.rings[0] ==
          queue_snapshot_plan.rings[0] ||
        queue_snapshot_lookup_cq.queue_plan.refs[0].mapping ==
          queue_snapshot_plan.refs[0].mapping ||
        queue_snapshot_lookup_cq.queue_plan.refs[0].additional_segments.size()
          != 1 ||
        queue_snapshot_lookup_cq.queue_plan.refs[0].additional_segments[0] ==
          queue_snapshot_segment ||
        queue_snapshot_lookup_cq.queue_plan.refs[0].additional_segments[0].
          mapping == queue_snapshot_segment.mapping ||
        queue_snapshot_lookup_cq.queue_plan.refs[0].additional_segments[0].
          mapping.iova.value != 64'h0000_4300_0000_0000 ||
        queue_snapshot_lookup_cq.queue_plan.refs[0].additional_segments[0].
          mapping_offset != 4096 ||
        queue_snapshot_lookup_cq.queue_plan.refs[0].additional_segments[0].
          length != 4096 ||
        queue_snapshot_lookup_cq.queue_plan.refs[0].additional_segments[0].
          logical_queue_offset != 8192 ||
        queue_snapshot_lookup_cq.cqe_size_bytes != 128 ||
        queue_snapshot_lookup_cq.backing_refs.size() != 0 ||
        queue_snapshot_lookup_cq.hmc_refs.size() != 0)
      `uvm_error("QUEUE_SNAPSHOT_ISOLATION",
                 "registry queue plan aliased caller state or duplicated authority")
    else begin
      if (!$cast(queue_snapshot_stored_token,
                 queue_snapshot_lookup_cq.queue_plan.context_ref.slot_token) ||
          queue_snapshot_stored_token == queue_snapshot_source_token ||
          queue_snapshot_stored_token.completion_authority !==
            queue_snapshot_source_authority)
        `uvm_error("QUEUE_SNAPSHOT_TOKEN_ISOLATION",
                   "registry context token aliased caller token mutation")
      expect_status(
        "QUEUE_SNAPSHOT_OWNED_AUTHORITY_PRESERVED",
        queue_snapshot_lookup_cq.queue_plan.refs[1].mapping.
          release_authority_status(queue_snapshot_authority),
        RDMA_SC_OK
      );
      queue_snapshot_borrowed_leak = null;
      if ($cast(queue_snapshot_borrowed_leak,
                queue_snapshot_lookup_cq.queue_plan.refs[0].mapping))
        `uvm_error("QUEUE_SNAPSHOT_BORROWED_DETACH",
                   "borrowed mapping retained releasable adapter subtype")
      expect_status(
        "QUEUE_SNAPSHOT_BORROWED_NONRELEASABLE",
        queue_snapshot_lookup_cq.queue_plan.refs[0].mapping.
          snapshot_release_authority(queue_snapshot_unsupported_authority),
        RDMA_SC_UNSUPPORTED_OPCODE
      );
    end

    // Queue local IDs use their wire widths and reject the next fresh value
    // without changing the live registry or allocator cursor.
    begin : queue_width_and_recovery
      rdma_width_probe_manager cq_width_rm;
      rdma_width_probe_manager srq_width_rm;
      rdma_width_probe_manager ceq_width_rm;
      rdma_width_probe_manager aeq_width_rm;
      rdma_queue_recovery_probe_manager queue_recovery_manager;
      rdma_function_binding queue_binding;
      rdma_cq cq_last;
      rdma_cq cq_overflow;
      rdma_pd srq_width_pd;
      rdma_srq srq_last;
      rdma_srq srq_overflow;
      rdma_ceq ceq_last;
      rdma_ceq ceq_overflow;
      rdma_aeq aeq_last;
      rdma_aeq aeq_overflow;
      rdma_pd queue_recovery_pd;
      rdma_srq srq;
      rdma_srq restored_srq;
      rdma_srq late_failure_before_srq;
      rdma_srq late_failure_after_srq;
      rdma_recovery_record queue_recovery;
      rdma_recovery_record queue_recovery_lookup;
      rdma_recovery_record late_failure_recovery_before;
      rdma_cmq_ticket queue_ticket;
      rdma_cmq_opcode_key queue_create_opcode;
      rdma_cmq_opcode_key queue_delete_opcode;
      rdma_cmq_opcode_key queue_query_opcode;
      rdma_queue_ring_layout sgb_ring;
      rdma_queue_backing_ref sgb_ref;
      rdma_queue_backing_segment sgb_segment;
      rdma_dma_mapping sgb_mapping;
      rdma_dma_mapping sgb_segment_mapping;
      int unsigned serial_before;
      int unsigned local_before;
      int unsigned registry_before;
      int unsigned free_before;
      int unsigned srq_width_leak_count;
      int unsigned queue_recovery_leak_count;

      queue_binding = make_active_binding(
        "queue_width_binding", 64'h1d00_0000_0000_0008,
        32'h1d00_0808, 32'd8
      );
      cq_width_rm = new("cq_width_rm");
      cq_width_rm.seed_next_local_id(RDMA_RESOURCE_CQ, 21'h1f_ffff);
      expect_status("WIDTH_CQ_21_LAST",
                    cq_width_rm.create_cq(queue_binding, null, cq_last),
                    RDMA_SC_OK);
      serial_before = cq_width_rm.observed_next_object_serial(RDMA_RESOURCE_CQ);
      local_before = cq_width_rm.observed_next_local_id(RDMA_RESOURCE_CQ);
      registry_before = cq_width_rm.observed_registry_count();
      free_before = cq_width_rm.observed_free_local_id_count(RDMA_RESOURCE_CQ);
      expect_status("WIDTH_CQ_21_EXHAUSTED",
                    cq_width_rm.create_cq(queue_binding, null, cq_overflow),
                    RDMA_SC_RESOURCE_EXHAUSTED);
      if (cq_last == null || cq_last.local_cq_id != 21'h1f_ffff ||
          cq_overflow != null ||
          cq_width_rm.observed_next_local_id(RDMA_RESOURCE_CQ) != local_before ||
          cq_width_rm.observed_registry_count() != registry_before ||
          cq_width_rm.observed_free_local_id_count(RDMA_RESOURCE_CQ) != free_before ||
          cq_width_rm.observed_next_object_serial(RDMA_RESOURCE_CQ) != serial_before)
        `uvm_error("WIDTH_CQ_21_ATOMIC", "CQ width failure changed allocator state")

      srq_width_rm = new("srq_width_rm");
      expect_status("WIDTH_SRQ_PD_CREATE",
                    srq_width_rm.create_pd(queue_binding, srq_width_pd),
                    RDMA_SC_OK);
      srq_width_rm.seed_next_local_id(RDMA_RESOURCE_SRQ, 16'hffff);
      expect_status("WIDTH_SRQ_16_LAST",
                    srq_width_rm.create_srq(queue_binding, srq_width_pd.handle,
                                            srq_last),
                    RDMA_SC_OK);
      local_before = srq_width_rm.observed_next_local_id(RDMA_RESOURCE_SRQ);
      registry_before = srq_width_rm.observed_registry_count();
      free_before = srq_width_rm.observed_free_local_id_count(RDMA_RESOURCE_SRQ);
      expect_status("WIDTH_SRQ_16_EXHAUSTED",
                    srq_width_rm.create_srq(queue_binding, srq_width_pd.handle,
                                            srq_overflow),
                    RDMA_SC_RESOURCE_EXHAUSTED);
      if (srq_last == null || srq_last.local_srq_id != 16'hffff ||
          srq_overflow != null ||
          srq_width_rm.observed_next_local_id(RDMA_RESOURCE_SRQ) != local_before ||
          srq_width_rm.observed_registry_count() != registry_before ||
          srq_width_rm.observed_free_local_id_count(RDMA_RESOURCE_SRQ) != free_before)
        `uvm_error("WIDTH_SRQ_16_ATOMIC", "SRQ width boundary is not atomic")
      expect_status("WIDTH_SRQ_16_RELEASE", srq_width_rm.\release (srq_last.handle),
                    RDMA_SC_OK);
      expect_status("WIDTH_SRQ_PD_RELEASE",
                    srq_width_rm.\release (srq_width_pd.handle), RDMA_SC_OK);
      expect_status("WIDTH_SRQ_NO_LEAKS",
                    srq_width_rm.check_leaks(srq_width_leak_count), RDMA_SC_OK);
      if (srq_width_leak_count != 0)
        `uvm_error("WIDTH_SRQ_NO_LEAKS", "SRQ width fixture leaked resources")

      ceq_width_rm = new("ceq_width_rm");
      ceq_width_rm.seed_next_local_id(RDMA_RESOURCE_CEQ, 12'hfff);
      expect_status("WIDTH_CEQ_12_LAST",
                    ceq_width_rm.create_ceq(queue_binding, ceq_last), RDMA_SC_OK);
      local_before = ceq_width_rm.observed_next_local_id(RDMA_RESOURCE_CEQ);
      registry_before = ceq_width_rm.observed_registry_count();
      free_before = ceq_width_rm.observed_free_local_id_count(RDMA_RESOURCE_CEQ);
      expect_status("WIDTH_CEQ_12_EXHAUSTED",
                    ceq_width_rm.create_ceq(queue_binding, ceq_overflow),
                    RDMA_SC_RESOURCE_EXHAUSTED);
      if (ceq_last == null || ceq_last.local_ceq_id != 12'hfff ||
          ceq_overflow != null ||
          ceq_width_rm.observed_next_local_id(RDMA_RESOURCE_CEQ) != local_before ||
          ceq_width_rm.observed_registry_count() != registry_before ||
          ceq_width_rm.observed_free_local_id_count(RDMA_RESOURCE_CEQ) != free_before)
        `uvm_error("WIDTH_CEQ_12_ATOMIC", "CEQ width boundary is not atomic")

      aeq_width_rm = new("aeq_width_rm");
      aeq_width_rm.seed_next_local_id(RDMA_RESOURCE_AEQ, 12'hfff);
      expect_status("WIDTH_AEQ_12_LAST",
                    aeq_width_rm.create_aeq(queue_binding, aeq_last), RDMA_SC_OK);
      local_before = aeq_width_rm.observed_next_local_id(RDMA_RESOURCE_AEQ);
      registry_before = aeq_width_rm.observed_registry_count();
      free_before = aeq_width_rm.observed_free_local_id_count(RDMA_RESOURCE_AEQ);
      expect_status("WIDTH_AEQ_12_EXHAUSTED",
                    aeq_width_rm.create_aeq(queue_binding, aeq_overflow),
                    RDMA_SC_RESOURCE_EXHAUSTED);
      if (aeq_last == null || aeq_last.local_aeq_id != 12'hfff ||
          aeq_overflow != null ||
          aeq_width_rm.observed_next_local_id(RDMA_RESOURCE_AEQ) != local_before ||
          aeq_width_rm.observed_registry_count() != registry_before ||
          aeq_width_rm.observed_free_local_id_count(RDMA_RESOURCE_AEQ) != free_before)
        `uvm_error("WIDTH_AEQ_12_ATOMIC", "AEQ width boundary is not atomic")

      queue_recovery_manager = new("queue_recovery_manager");
      expect_status("QUEUE_RECOVERY_PD_CREATE", queue_recovery_manager.create_pd(
        queue_binding, queue_recovery_pd), RDMA_SC_OK);
      expect_status("QUEUE_RECOVERY_CREATE",
                    queue_recovery_manager.create_srq(queue_binding,
                                                      queue_recovery_pd.handle,
                                                      srq),
                    RDMA_SC_OK);
      srq.depth = 32;
      srq.max_sge = 4;
      srq.limit_threshold = 20;
      srq.queue_plan = make_queue_test_plan(
        "queue_recovery_plan", RDMA_RESOURCE_SRQ, srq.depth, srq.owner,
        srq.handle, srq.local_srq_id
      );
      sgb_mapping = make_independent_queue_test_mapping(
        "queue_recovery_sgb_mapping", srq.owner, srq.handle,
        64'h0000_5200_0000_0000
      );
      sgb_ring = make_queue_test_ring(
        "queue_recovery_sgb_ring", RDMA_QUEUE_ROLE_SRQ_SGB, srq.depth,
        64, sgb_mapping
      );
      sgb_ref = make_queue_test_ref(
        "queue_recovery_sgb_ref", RDMA_QUEUE_ROLE_SRQ_SGB, sgb_mapping,
        sgb_ring.storage_bytes, RDMA_OWNERSHIP_CONTROL_PLANE
      );
      sgb_segment_mapping = make_independent_queue_test_mapping(
        "queue_recovery_sgb_segment_mapping", srq.owner, srq.handle,
        64'h0000_5300_0000_0000
      );
      sgb_segment = rdma_queue_backing_segment::type_id::create(
        "queue_recovery_sgb_segment"
      );
      sgb_segment.role = RDMA_QUEUE_ROLE_SRQ_SGB;
      sgb_segment.mapping = sgb_segment_mapping;
      sgb_segment.ownership = RDMA_OWNERSHIP_CONTROL_PLANE;
      sgb_segment.mapping_offset = 0;
      sgb_segment.length = 4096;
      sgb_segment.logical_queue_offset = sgb_ref.length;
      sgb_ref.additional_segments.push_back(sgb_segment);
      srq.queue_plan.rings.push_back(sgb_ring);
      srq.queue_plan.refs.push_back(sgb_ref);
      expect_status("QUEUE_RECOVERY_STAGE",
                    queue_recovery_manager.stage_allocated(srq), RDMA_SC_OK);
      expect_status("QUEUE_RECOVERY_COMMIT",
                    queue_recovery_manager.commit_programmed(srq), RDMA_SC_OK);
      expect_status("QUEUE_RECOVERY_ACTIVATE",
                    queue_recovery_manager.activate(srq.handle), RDMA_SC_OK);
      expect_status("QUEUE_RECOVERY_QUIESCE",
                    queue_recovery_manager.begin_quiesce(srq.handle), RDMA_SC_OK);
      expect_status("QUIESCING_FLUSH_PROGRESS", queue_recovery_manager.
        record_queue_flush_complete(srq.handle, RDMA_QUEUE_ROLE_SRFQ_PD),
        RDMA_SC_OK);

      queue_recovery = rdma_recovery_record::type_id::create("queue_recovery");
      queue_recovery.resource_h = clone_handle("QUEUE_RECOVERY_H", srq.handle);
      queue_recovery.hardware_presence = RDMA_HW_PRESENCE_PRESENT;
      queue_recovery.primary_status = rdma_status::make(
        RDMA_SC_TIMEOUT, "queue progress requires recovery"
      );
      queue_recovery.queue_recovery_valid = 1'b1;
      queue_recovery.queue_intent = RDMA_QUEUE_RECOVER_NORMAL_DESTROY;
      queue_recovery.ambiguous_queue_operation = RDMA_QUEUE_AMBIG_OCC_FLUSH;
      queue_recovery.ambiguous_role = RDMA_QUEUE_ROLE_SRFQ_PD;
      queue_recovery.queue_plan = srq.queue_plan;
      queue_create_opcode = new("queue_create_opcode");
      queue_delete_opcode = new("queue_delete_opcode");
      queue_query_opcode = new("queue_query_opcode");
      queue_create_opcode.profile_name = "generic_profile";
      queue_delete_opcode.profile_name = "generic_profile";
      queue_query_opcode.profile_name = "generic_profile";
      queue_create_opcode.variant = "create";
      queue_delete_opcode.variant = "delete";
      queue_query_opcode.variant = "query";
      queue_recovery.queue_create_opcode = queue_create_opcode;
      queue_recovery.queue_delete_opcode = queue_delete_opcode;
      queue_recovery.queue_query_opcode = queue_query_opcode;
      queue_ticket = new("queue_recovery_ticket");
      queue_ticket.command_id = 64'h1234;
      queue_ticket.function_h = clone_function_handle("QUEUE_TICKET_F", srq.owner);
      queue_ticket.cmq_h = new("queue_ticket_cmq_h");
      queue_ticket.cmq_h.kind = RDMA_RESOURCE_CMQ;
      queue_ticket.cmq_h.function_uid = srq.handle.function_uid;
      queue_ticket.cmq_h.object_id = {RDMA_RESOURCE_CMQ, 28'h1};
      queue_ticket.cmq_h.generation = srq.handle.generation;
      queue_ticket.opcode_key = queue_create_opcode;
      queue_ticket.absolute_deadline = 64'd100;
      queue_recovery.ambiguous_ticket = queue_ticket;
      expect_status("QUEUE_RECOVERY", queue_recovery.validate(), RDMA_SC_OK);
      expect_status("QUEUE_RECOVERY_ERROR",
                    queue_recovery_manager.mark_error(srq.handle, queue_recovery),
                    RDMA_SC_OK);
      // Each detached plan must independently prove the predecessor before a
      // later SRQ flush can be recorded.  Rejection cannot publish either
      // target's progress bit.
      queue_recovery_manager.set_queue_flush_complete(
        srq.handle, 1'b1, RDMA_QUEUE_ROLE_SRFQ_PD, 1'b0
      );
      expect_status("RECOVERY_FLUSH_PREDECESSOR_REJECT", queue_recovery_manager.
        record_queue_flush_complete(srq.handle, RDMA_QUEUE_ROLE_SRQ_PD),
        RDMA_SC_INVALID_STATE);
      if (!queue_recovery_manager.observed_queue_flush_complete(
            srq.handle, 1'b0, RDMA_QUEUE_ROLE_SRFQ_PD) ||
          queue_recovery_manager.observed_queue_flush_complete(
            srq.handle, 1'b1, RDMA_QUEUE_ROLE_SRFQ_PD) ||
          queue_recovery_manager.observed_queue_flush_complete(
            srq.handle, 1'b0, RDMA_QUEUE_ROLE_SRQ_PD) ||
          queue_recovery_manager.observed_queue_flush_complete(
            srq.handle, 1'b1, RDMA_QUEUE_ROLE_SRQ_PD))
        `uvm_error("RECOVERY_FLUSH_PREDECESSOR_ATOMIC",
                   "failed recovery predecessor check published progress")
      queue_recovery_manager.set_queue_flush_complete(
        srq.handle, 1'b1, RDMA_QUEUE_ROLE_SRFQ_PD, 1'b1
      );
      queue_recovery_manager.set_queue_flush_complete(
        srq.handle, 1'b0, RDMA_QUEUE_ROLE_SRFQ_PD, 1'b0
      );
      expect_status("REGISTRY_FLUSH_PREDECESSOR_REJECT", queue_recovery_manager.
        record_queue_flush_complete(srq.handle, RDMA_QUEUE_ROLE_SRQ_PD),
        RDMA_SC_INVALID_STATE);
      if (queue_recovery_manager.observed_queue_flush_complete(
            srq.handle, 1'b0, RDMA_QUEUE_ROLE_SRFQ_PD) ||
          !queue_recovery_manager.observed_queue_flush_complete(
            srq.handle, 1'b1, RDMA_QUEUE_ROLE_SRFQ_PD) ||
          queue_recovery_manager.observed_queue_flush_complete(
            srq.handle, 1'b0, RDMA_QUEUE_ROLE_SRQ_PD) ||
          queue_recovery_manager.observed_queue_flush_complete(
            srq.handle, 1'b1, RDMA_QUEUE_ROLE_SRQ_PD))
        `uvm_error("REGISTRY_FLUSH_PREDECESSOR_ATOMIC",
                   "failed registry predecessor check published progress")
      queue_recovery_manager.set_queue_flush_complete(
        srq.handle, 1'b0, RDMA_QUEUE_ROLE_SRFQ_PD, 1'b1
      );
      // The recovery plan may legitimately have a different serialization
      // order.  A role-based update must not use the resource-plan index.
      queue_recovery_manager.swap_recovery_refs(srq.handle, 0, 4);
      queue_recovery_manager.set_queue_flush_complete(
        srq.handle, 1'b1, RDMA_QUEUE_ROLE_SRFQ_PD, 1'b0
      );
      expect_status("RECOVERY_SGB_PREDECESSOR_REJECT", queue_recovery_manager.
        record_queue_cleanup_complete(srq.handle, RDMA_QUEUE_ROLE_SRQ_SGB),
        RDMA_SC_INVALID_STATE);
      expect_status("RECOVERY_SGB_PREDECESSOR_LOOKUP", queue_recovery_manager.
        lookup_recovery(srq.handle, queue_recovery_lookup), RDMA_SC_OK);
      if (queue_recovery_lookup == null ||
          queue_recovery_lookup.queue_plan.refs[0].cleanup_complete)
        `uvm_error("RECOVERY_SGB_PREDECESSOR_ATOMIC",
                   "failed SGB predecessor check published cleanup")
      queue_recovery_manager.set_queue_flush_complete(
        srq.handle, 1'b1, RDMA_QUEUE_ROLE_SRFQ_PD, 1'b1
      );
      queue_recovery_manager.set_queue_segment_iova(
        srq.handle, 1'b1, RDMA_QUEUE_ROLE_SRQ_SGB, 0,
        64'h0000_5300_0000_1000
      );
      expect_status("SEGMENT_DIVERGED_CLEANUP", queue_recovery_manager.
        record_queue_cleanup_complete(srq.handle, RDMA_QUEUE_ROLE_SRQ_SGB),
        RDMA_SC_INVALID_STATE);
      queue_recovery_manager.set_queue_cleanup(
        srq.handle, 1'b0, RDMA_QUEUE_ROLE_SRQ_SGB, 1'b0
      );
      queue_recovery_manager.set_queue_cleanup(
        srq.handle, 1'b1, RDMA_QUEUE_ROLE_SRQ_SGB, 1'b0
      );
      queue_recovery_manager.set_queue_segment_iova(
        srq.handle, 1'b1, RDMA_QUEUE_ROLE_SRQ_SGB, 0,
        64'h0000_5300_0000_0000
      );
      expect_status("REORDERED_CLEANUP_PROGRESS", queue_recovery_manager.
        record_queue_cleanup_complete(srq.handle, RDMA_QUEUE_ROLE_SRQ_SGB),
        RDMA_SC_OK);
      expect_status("REORDERED_CONTEXT_PROGRESS", queue_recovery_manager.
        record_queue_context_cleanup_complete(srq.handle), RDMA_SC_OK);
      expect_status("QUEUE_PROGRESS_LOOKUP", queue_recovery_manager.lookup_recovery(
        srq.handle, queue_recovery_lookup), RDMA_SC_OK);
      if (queue_recovery_lookup == null ||
          !queue_recovery_lookup.queue_plan.flush_targets[0].flush_complete ||
          !queue_recovery_lookup.queue_plan.refs[0].cleanup_complete ||
          !queue_recovery_lookup.queue_plan.context_ref.release_complete ||
          queue_recovery_lookup.queue_plan == queue_recovery.queue_plan ||
          queue_recovery_lookup.queue_create_opcode ==
            queue_recovery.queue_create_opcode ||
          queue_recovery_lookup.queue_delete_opcode ==
            queue_recovery.queue_delete_opcode ||
          queue_recovery_lookup.queue_query_opcode ==
            queue_recovery.queue_query_opcode)
        `uvm_error("QUEUE_PROGRESS_PERSIST", "queue progress was not persisted")

      // Check registry and recovery evidence independently: either side's
      // destructive cleanup proof blocks restore.  Once both are live and
      // present, SRQ restore succeeds and resets both pre-delete flushes.
      queue_recovery_manager.clear_queue_ambiguity(srq.handle);
      expect_status("RESTORE_BOTH_DESTRUCTIVE", queue_recovery_manager.
        restore_active(srq.handle), RDMA_SC_INVALID_STATE);
      queue_recovery_manager.set_queue_cleanup(
        srq.handle, 1'b1, RDMA_QUEUE_ROLE_SRQ_SGB, 1'b0
      );
      expect_status("RESTORE_REGISTRY_DESTRUCTIVE", queue_recovery_manager.
        restore_active(srq.handle), RDMA_SC_INVALID_STATE);
      queue_recovery_manager.set_queue_cleanup(
        srq.handle, 1'b0, RDMA_QUEUE_ROLE_SRQ_SGB, 1'b0
      );
      queue_recovery_manager.set_queue_cleanup(
        srq.handle, 1'b1, RDMA_QUEUE_ROLE_SRQ_SGB, 1'b1
      );
      expect_status("RESTORE_RECOVERY_DESTRUCTIVE", queue_recovery_manager.
        restore_active(srq.handle), RDMA_SC_INVALID_STATE);
      queue_recovery_manager.set_queue_cleanup(
        srq.handle, 1'b1, RDMA_QUEUE_ROLE_SRQ_SGB, 1'b0
      );
      // Completion is deliberately held in one detached snapshot at a time.
      // Removing either release-completion query must make one of these
      // independently corrupt recovery records restore incorrectly.
      queue_recovery_manager.set_queue_release_evidence(
        srq.handle, 1'b1, RDMA_QUEUE_ROLE_SRQ_SGB, 1'b1
      );
      expect_status("RESTORE_RECOVERY_RELEASED", queue_recovery_manager.
        restore_active(srq.handle), RDMA_SC_INVALID_STATE);
      queue_recovery_manager.set_queue_release_evidence(
        srq.handle, 1'b1, RDMA_QUEUE_ROLE_SRQ_SGB, 1'b0
      );
      queue_recovery_manager.set_queue_release_evidence(
        srq.handle, 1'b0, RDMA_QUEUE_ROLE_SRQ_SGB, 1'b1
      );
      expect_status("RESTORE_REGISTRY_RELEASED", queue_recovery_manager.
        restore_active(srq.handle), RDMA_SC_INVALID_STATE);
      queue_recovery_manager.set_queue_release_evidence(
        srq.handle, 1'b0, RDMA_QUEUE_ROLE_SRQ_SGB, 1'b0
      );
      queue_recovery_manager.set_queue_segment_release_evidence(
        srq.handle, 1'b1, RDMA_QUEUE_ROLE_SRQ_SGB, 0, 1'b1
      );
      expect_status("RESTORE_RECOVERY_SEGMENT_RELEASED",
        queue_recovery_manager.restore_active(srq.handle),
        RDMA_SC_INVALID_STATE);
      queue_recovery_manager.set_queue_segment_release_evidence(
        srq.handle, 1'b1, RDMA_QUEUE_ROLE_SRQ_SGB, 0, 1'b0
      );
      queue_recovery_manager.set_queue_segment_release_evidence(
        srq.handle, 1'b0, RDMA_QUEUE_ROLE_SRQ_SGB, 0, 1'b1
      );
      expect_status("RESTORE_REGISTRY_SEGMENT_RELEASED",
        queue_recovery_manager.restore_active(srq.handle),
        RDMA_SC_INVALID_STATE);
      queue_recovery_manager.set_queue_segment_release_evidence(
        srq.handle, 1'b0, RDMA_QUEUE_ROLE_SRQ_SGB, 0, 1'b0
      );
      // Force only the detached replacement to fail after reset preparation.
      // The ERROR registry object and recovery evidence must remain exactly
      // recoverable for the following successful restore attempt.
      queue_recovery_manager.set_queue_ambiguity(
        srq.handle, RDMA_QUEUE_AMBIG_CREATE, RDMA_QUEUE_ROLE_SRQ_RING
      );
      expect_status("RESTORE_LATE_FAILURE_BEFORE_RECOVERY", queue_recovery_manager.
        lookup_recovery(srq.handle, late_failure_recovery_before), RDMA_SC_OK);
      expect_status("RESTORE_LATE_FAILURE_BEFORE_RESOURCE", queue_recovery_manager.
        lookup(srq.handle, resource), RDMA_SC_OK);
      if (!$cast(late_failure_before_srq, resource))
        `uvm_fatal("RESTORE_LATE_FAILURE", "SRQ snapshot cast failed")
      queue_recovery_manager.force_queue_restore_late_failure = 1'b1;
      // The observer removes a required PD reference, so the prepared queue
      // fails argument validation after reset preparation but before publish.
      expect_status("RESTORE_LATE_FAILURE", queue_recovery_manager.
        restore_active(srq.handle), RDMA_SC_INVALID_ARGUMENT);
      queue_recovery_manager.force_queue_restore_late_failure = 1'b0;
      expect_status("RESTORE_LATE_FAILURE_AFTER_RECOVERY", queue_recovery_manager.
        lookup_recovery(srq.handle, queue_recovery_lookup), RDMA_SC_OK);
      expect_status("RESTORE_LATE_FAILURE_AFTER_RESOURCE", queue_recovery_manager.
        lookup(srq.handle, resource), RDMA_SC_OK);
      if (!$cast(late_failure_after_srq, resource) ||
          late_failure_recovery_before == null || queue_recovery_lookup == null ||
          late_failure_after_srq.state != late_failure_before_srq.state ||
          late_failure_after_srq.state != RDMA_RESOURCE_ERROR ||
          late_failure_after_srq.queue_plan.flush_targets.size() != 2 ||
          late_failure_before_srq.queue_plan.flush_targets.size() != 2 ||
          late_failure_after_srq.queue_plan.flush_targets[0].flush_complete !=
            late_failure_before_srq.queue_plan.flush_targets[0].flush_complete ||
          late_failure_after_srq.queue_plan.flush_targets[1].flush_complete !=
            late_failure_before_srq.queue_plan.flush_targets[1].flush_complete ||
          queue_recovery_lookup.ambiguous_queue_operation !=
            late_failure_recovery_before.ambiguous_queue_operation ||
          queue_recovery_lookup.ambiguous_role !=
            late_failure_recovery_before.ambiguous_role ||
          queue_recovery_lookup.ambiguous_ticket != null ||
          late_failure_recovery_before.ambiguous_ticket != null ||
          queue_recovery_lookup.queue_plan.flush_targets.size() != 2 ||
          queue_recovery_lookup.queue_plan.flush_targets[0].flush_complete !=
            late_failure_recovery_before.queue_plan.flush_targets[0].flush_complete ||
          queue_recovery_lookup.queue_plan.flush_targets[1].flush_complete !=
            late_failure_recovery_before.queue_plan.flush_targets[1].flush_complete)
        `uvm_error("RESTORE_LATE_FAILURE_ATOMIC",
                   "late restore failure changed live queue recovery evidence")
      expect_status("RESTORE_QUEUE_SAFE", queue_recovery_manager.
        restore_active(srq.handle), RDMA_SC_OK);
      expect_status("RESTORE_QUEUE_LOOKUP", queue_recovery_manager.lookup(
        srq.handle, resource), RDMA_SC_OK);
      if (!$cast(restored_srq, resource) ||
          restored_srq.state != RDMA_RESOURCE_ACTIVE ||
          restored_srq.queue_plan.flush_targets.size() != 2 ||
          restored_srq.queue_plan.flush_targets[0].flush_complete ||
          restored_srq.queue_plan.flush_targets[1].flush_complete ||
          queue_recovery_manager.observed_pre_retire_recovery == null ||
          queue_recovery_manager.observed_pre_retire_recovery.
            ambiguous_queue_operation != RDMA_QUEUE_AMBIG_NONE ||
          queue_recovery_manager.observed_pre_retire_recovery.
            ambiguous_role != RDMA_QUEUE_ROLE_CQ_RING ||
          queue_recovery_manager.observed_pre_retire_recovery.
            ambiguous_ticket != null ||
          queue_recovery_manager.observed_pre_retire_recovery.queue_plan == null ||
          queue_recovery_manager.observed_pre_retire_recovery.
            queue_plan.flush_targets.size() != 2 ||
          queue_recovery_manager.observed_pre_retire_recovery.
            queue_plan.flush_targets[0].flush_complete ||
          queue_recovery_manager.observed_pre_retire_recovery.
            queue_plan.flush_targets[1].flush_complete)
        `uvm_error("RESTORE_SRQ_RESET",
                   "safe SRQ restore did not reset progress and ambiguity")
      expect_status("RESTORE_QUEUE_FUNCTION_RELEASE", queue_recovery_manager.
        release_function(queue_binding.make_handle()), RDMA_SC_OK);
      expect_status("RESTORE_QUEUE_NO_LEAKS", queue_recovery_manager.check_leaks(
        queue_recovery_leak_count), RDMA_SC_OK);
      if (queue_recovery_leak_count != 0)
        `uvm_error("RESTORE_QUEUE_NO_LEAKS", "queue recovery fixture leaked resources")
    end

    // PD and MR local IDs are hardware-width projections.  The inclusive
    // boundary succeeds, while the next fresh ID fails atomically without
    // consuming another incarnation serial or registering another resource.
    width_pd_rm = new("width_pd_rm");
    width_binding = make_active_binding(
      "width_pd_binding", 64'h1d00_0000_0000_0001,
      32'h1d00_0101, 32'd1
    );
    width_pd_rm.set_next_local_id(RDMA_RESOURCE_PD, 16'hffff);
    expect_status("WIDTH_PD_LAST",
                  width_pd_rm.create_pd(width_binding, width_pd),
                  RDMA_SC_OK);
    if (width_pd == null || width_pd.local_pd_id != 16'hffff)
      `uvm_error("WIDTH_PD_LAST",
                 "allocator did not return the last 16-bit PD ID")
    width_pd_h = clone_handle("WIDTH_PD_LAST_H", width_pd.handle);
    serial_before_width_failure =
      width_pd_rm.observed_next_object_serial(RDMA_RESOURCE_PD);
    expect_status("WIDTH_PD_EXHAUSTED",
                  width_pd_rm.create_pd(width_binding, width_pd_failed),
                  RDMA_SC_RESOURCE_EXHAUSTED);
    if (width_pd_failed != null ||
        width_pd_rm.observed_next_object_serial(RDMA_RESOURCE_PD) !=
          serial_before_width_failure)
      `uvm_error("WIDTH_PD_EXHAUSTED",
                 "failed PD allocation consumed output or serial state")
    expect_status("WIDTH_PD_FAILURE_LEAK_COUNT",
                  width_pd_rm.check_leaks(leak_count),
                  RDMA_SC_INVALID_STATE);
    if (leak_count != 1)
      `uvm_error("WIDTH_PD_FAILURE_LEAK_COUNT",
                 $sformatf("expected one live PD, got %0d", leak_count))
    expect_status("WIDTH_PD_RELEASE",
                  width_pd_rm.\release (width_pd.handle), RDMA_SC_OK);
    expect_status("WIDTH_PD_REUSE_LIMIT",
                  width_pd_rm.create_pd(width_binding, width_pd_failed),
                  RDMA_SC_OK);
    if (width_pd_failed == null ||
        width_pd_failed.local_pd_id != 16'hffff ||
        width_pd_failed.handle.same_instance(width_pd_h))
      `uvm_error("WIDTH_PD_REUSE_LIMIT",
                 "valid boundary ID reuse lost incarnation uniqueness")
    expect_status("WIDTH_PD_REUSE_RELEASE",
                  width_pd_rm.\release (width_pd_failed.handle), RDMA_SC_OK);

    width_mr_rm = new("width_mr_rm");
    width_binding = make_active_binding(
      "width_mr_binding", 64'h1d00_0000_0000_0002,
      32'h1d00_0202, 32'd2
    );
    expect_status("WIDTH_MR_PD",
                  width_mr_rm.create_pd(width_binding, width_mr_pd),
                  RDMA_SC_OK);
    width_mr_rm.set_next_local_id(RDMA_RESOURCE_MR, 24'hff_ffff);
    expect_status("WIDTH_MR_LAST",
                  width_mr_rm.create_mr(width_binding, width_mr_pd.handle,
                                         width_mr),
                  RDMA_SC_OK);
    if (width_mr == null || width_mr.local_mr_id != 24'hff_ffff)
      `uvm_error("WIDTH_MR_LAST",
                 "allocator did not return the last 24-bit MR ID")
    serial_before_width_failure =
      width_mr_rm.observed_next_object_serial(RDMA_RESOURCE_MR);
    expect_status("WIDTH_MR_EXHAUSTED",
                  width_mr_rm.create_mr(width_binding, width_mr_pd.handle,
                                         width_mr_failed),
                  RDMA_SC_RESOURCE_EXHAUSTED);
    if (width_mr_failed != null ||
        width_mr_rm.observed_next_object_serial(RDMA_RESOURCE_MR) !=
          serial_before_width_failure)
      `uvm_error("WIDTH_MR_EXHAUSTED",
                 "failed MR allocation consumed output or serial state")
    expect_status("WIDTH_MR_FAILURE_LEAK_COUNT",
                  width_mr_rm.check_leaks(leak_count),
                  RDMA_SC_INVALID_STATE);
    if (leak_count != 2)
      `uvm_error("WIDTH_MR_FAILURE_LEAK_COUNT",
                 $sformatf("expected PD plus MR, got %0d", leak_count))
    expect_status("WIDTH_MR_RELEASE",
                  width_mr_rm.\release (width_mr.handle), RDMA_SC_OK);
    expect_status("WIDTH_MR_PD_RELEASE",
                  width_mr_rm.\release (width_mr_pd.handle), RDMA_SC_OK);

    // The CQ wire-width pool owns its inclusive 21-bit maximum.  Fresh-pool
    // exhaustion must not wrap the counter, mutate the registry, or consume
    // an incarnation; a released maximum remains reusable from the free list.
    width_cq_rm = new("width_cq_rm");
    width_binding = make_active_binding(
      "width_cq_binding", 64'h1d00_0000_0000_0005,
      32'h1d00_0505, 32'd5
    );
    width_cq_rm.set_next_local_id(RDMA_RESOURCE_CQ, 21'h1f_ffff);
    expect_status("WIDTH_CQ_LAST",
                  width_cq_rm.create_cq(width_binding, null, width_cq),
                  RDMA_SC_OK);
    if (width_cq == null) begin
      `uvm_error("WIDTH_CQ_LAST",
                 "allocator rejected the last 21-bit CQ ID")
    end
    else begin
      if (width_cq.local_cq_id != 21'h1f_ffff)
        `uvm_error("WIDTH_CQ_LAST",
                   "allocator did not return the last 21-bit CQ ID")
      width_cq_h = clone_handle("WIDTH_CQ_LAST_H", width_cq.handle);
      serial_before_width_failure =
        width_cq_rm.observed_next_object_serial(RDMA_RESOURCE_CQ);
      free_count_before_width_failure =
        width_cq_rm.observed_free_local_id_count(RDMA_RESOURCE_CQ);
      expect_status("WIDTH_CQ_EXHAUSTED",
                    width_cq_rm.create_cq(width_binding, null,
                                           width_cq_failed),
                    RDMA_SC_RESOURCE_EXHAUSTED);
      if (width_cq_failed != null ||
          width_cq_rm.observed_next_object_serial(RDMA_RESOURCE_CQ) !=
            serial_before_width_failure ||
          width_cq_rm.observed_free_local_id_count(RDMA_RESOURCE_CQ) !=
            free_count_before_width_failure)
        `uvm_error("WIDTH_CQ_EXHAUSTED",
                   "failed CQ allocation mutated allocator state")
      expect_status("WIDTH_CQ_FAILURE_LIVE",
                    width_cq_rm.lookup(width_cq_h, resource), RDMA_SC_OK);
      if (resource == null || resource.state != RDMA_RESOURCE_ALLOCATED)
        `uvm_error("WIDTH_CQ_FAILURE_LIVE",
                   "failed CQ allocation changed the live registry entry")
      expect_status("WIDTH_CQ_FAILURE_LEAK_COUNT",
                    width_cq_rm.check_leaks(leak_count),
                    RDMA_SC_INVALID_STATE);
      if (leak_count != 1)
        `uvm_error("WIDTH_CQ_FAILURE_LEAK_COUNT",
                   $sformatf("expected one live CQ, got %0d", leak_count))
      expect_status("WIDTH_CQ_RELEASE",
                    width_cq_rm.\release (width_cq_h), RDMA_SC_OK);
      expect_status("WIDTH_CQ_REUSE_LIMIT",
                    width_cq_rm.create_cq(width_binding, null,
                                           width_cq_reused),
                    RDMA_SC_OK);
      if (width_cq_reused == null ||
          width_cq_reused.local_cq_id != 21'h1f_ffff ||
          width_cq_reused.handle.same_instance(width_cq_h))
        `uvm_error("WIDTH_CQ_REUSE_LIMIT",
                   "recycled maximum CQ ID lost incarnation uniqueness")
      expect_status("WIDTH_CQ_REUSE_RELEASE",
                    width_cq_rm.\release (width_cq_reused.handle),
                    RDMA_SC_OK);
      expect_status("WIDTH_CQ_NO_LEAKS",
                    width_cq_rm.check_leaks(leak_count), RDMA_SC_OK);
    end

    // Function IDs share the same inclusive 32-bit boundary.  A failed
    // allocation must not register its caller-owned binding, so a distinct
    // binding object with the same identity can consume a recycled maximum.
    width_function_rm = new("width_function_rm");
    width_function_binding_a = make_active_binding(
      "width_function_binding_a", 64'h1d00_0000_0000_0006,
      32'h1d00_0606, 32'd6
    );
    width_function_binding_b = make_active_binding(
      "width_function_binding_b", 64'h1d00_0000_0000_0007,
      32'h1d00_0707, 32'd7
    );
    width_function_binding_b_copy = make_active_binding(
      "width_function_binding_b_copy", 64'h1d00_0000_0000_0007,
      32'h1d00_0707, 32'd7
    );
    width_function_rm.set_next_local_id(RDMA_RESOURCE_FUNCTION,
                                         32'hffff_ffff);
    expect_status(
      "WIDTH_FUNCTION_LAST",
      width_function_rm.create_function(width_function_binding_a,
                                         width_function_a),
      RDMA_SC_OK
    );
    if (width_function_a == null) begin
      `uvm_error("WIDTH_FUNCTION_LAST",
                 "allocator rejected the last 32-bit Function ID")
    end
    else begin
      if (width_function_a.local_function_id != 32'hffff_ffff)
        `uvm_error("WIDTH_FUNCTION_LAST",
                   "allocator did not return the last 32-bit Function ID")
      width_function_owner_a = clone_function_handle(
        "WIDTH_FUNCTION_OWNER_A", width_function_a.owner
      );
      free_count_before_width_failure =
        width_function_rm.observed_free_local_id_count(
          RDMA_RESOURCE_FUNCTION
        );
      expect_status(
        "WIDTH_FUNCTION_EXHAUSTED",
        width_function_rm.create_function(width_function_binding_b,
                                           width_function_b_failed),
        RDMA_SC_RESOURCE_EXHAUSTED
      );
      if (width_function_b_failed != null ||
          width_function_rm.observed_free_local_id_count(
            RDMA_RESOURCE_FUNCTION
          ) != free_count_before_width_failure)
        `uvm_error("WIDTH_FUNCTION_EXHAUSTED",
                   "failed Function allocation mutated allocator state")
      expect_status("WIDTH_FUNCTION_FAILURE_LIVE",
                    width_function_rm.lookup(width_function_a.handle,
                                             resource),
                    RDMA_SC_OK);
      expect_status("WIDTH_FUNCTION_FAILURE_LEAK_COUNT",
                    width_function_rm.check_leaks(leak_count),
                    RDMA_SC_INVALID_STATE);
      if (leak_count != 1)
        `uvm_error("WIDTH_FUNCTION_FAILURE_LEAK_COUNT",
                   $sformatf("expected one live Function, got %0d",
                             leak_count))
      expect_status(
        "WIDTH_FUNCTION_RELEASE_A",
        width_function_rm.release_function(width_function_owner_a),
        RDMA_SC_OK
      );
      expect_status(
        "WIDTH_FUNCTION_REUSE_LIMIT",
        width_function_rm.create_function(width_function_binding_b_copy,
                                           width_function_b_reused),
        RDMA_SC_OK
      );
      if (width_function_b_reused == null ||
          width_function_b_reused.local_function_id != 32'hffff_ffff ||
          width_function_b_reused.handle.same_instance(
            width_function_a.handle
          ))
        `uvm_error("WIDTH_FUNCTION_REUSE_LIMIT",
                   "recycled maximum Function ID or binding was invalid")
      expect_status(
        "WIDTH_FUNCTION_RELEASE_B",
        width_function_rm.release_function(width_function_b_reused.owner),
        RDMA_SC_OK
      );
      expect_status("WIDTH_FUNCTION_NO_LEAKS",
                    width_function_rm.check_leaks(leak_count), RDMA_SC_OK);
    end

    // An invalid free-list head is neither returned nor silently discarded.
    // The first failed allocation also must not install a binding source.
    width_free_pd_rm = new("width_free_pd_rm");
    width_binding = make_active_binding(
      "width_free_pd_binding", 64'h1d00_0000_0000_0003,
      32'h1d00_0303, 32'd3
    );
    width_binding_copy = make_active_binding(
      "width_free_pd_binding_copy", 64'h1d00_0000_0000_0003,
      32'h1d00_0303, 32'd3
    );
    width_free_pd_rm.inject_free_local_id(RDMA_RESOURCE_PD, 32'h0001_0000);
    free_count_before_width_failure =
      width_free_pd_rm.observed_free_local_id_count(RDMA_RESOURCE_PD);
    serial_before_width_failure =
      width_free_pd_rm.observed_next_object_serial(RDMA_RESOURCE_PD);
    expect_status("WIDTH_PD_BAD_FREE",
                  width_free_pd_rm.create_pd(width_binding, width_pd_failed),
                  RDMA_SC_RESOURCE_EXHAUSTED);
    if (width_pd_failed != null ||
        width_free_pd_rm.observed_free_local_id_count(RDMA_RESOURCE_PD) !=
          free_count_before_width_failure ||
        width_free_pd_rm.observed_next_object_serial(RDMA_RESOURCE_PD) !=
          serial_before_width_failure)
      `uvm_error("WIDTH_PD_BAD_FREE",
                 "invalid free-list PD ID mutated allocator state")
    expect_status("WIDTH_PD_BAD_FREE_NO_LEAKS",
                  width_free_pd_rm.check_leaks(leak_count), RDMA_SC_OK);
    expect_status("WIDTH_PD_BAD_FREE_NO_BINDING",
                  width_free_pd_rm.create_aeq(width_binding_copy,
                                               width_probe_aeq),
                  RDMA_SC_OK);
    expect_status("WIDTH_PD_BAD_FREE_AEQ_RELEASE",
                  width_free_pd_rm.\release (width_probe_aeq.handle),
                  RDMA_SC_OK);

    width_free_mr_rm = new("width_free_mr_rm");
    width_binding = make_active_binding(
      "width_free_mr_binding", 64'h1d00_0000_0000_0004,
      32'h1d00_0404, 32'd4
    );
    expect_status("WIDTH_BAD_FREE_MR_PD",
                  width_free_mr_rm.create_pd(width_binding,
                                              width_free_mr_pd),
                  RDMA_SC_OK);
    width_free_mr_rm.inject_free_local_id(RDMA_RESOURCE_MR,
                                           32'h0100_0000);
    free_count_before_width_failure =
      width_free_mr_rm.observed_free_local_id_count(RDMA_RESOURCE_MR);
    serial_before_width_failure =
      width_free_mr_rm.observed_next_object_serial(RDMA_RESOURCE_MR);
    expect_status("WIDTH_MR_BAD_FREE",
                  width_free_mr_rm.create_mr(width_binding,
                                              width_free_mr_pd.handle,
                                              width_free_mr),
                  RDMA_SC_RESOURCE_EXHAUSTED);
    if (width_free_mr != null ||
        width_free_mr_rm.observed_free_local_id_count(RDMA_RESOURCE_MR) !=
          free_count_before_width_failure ||
        width_free_mr_rm.observed_next_object_serial(RDMA_RESOURCE_MR) !=
          serial_before_width_failure)
      `uvm_error("WIDTH_MR_BAD_FREE",
                 "invalid free-list MR ID mutated allocator state")
    expect_status("WIDTH_BAD_FREE_MR_PD_RELEASE",
                  width_free_mr_rm.\release (width_free_mr_pd.handle),
                  RDMA_SC_OK);

    // ERROR snapshots require the key authority handed off by staging.  A raw
    // zero-ID ALLOCATED MR happens to validate after forcing ERROR, but must be
    // rejected atomically until that incarnation is populated and staged.
    allocated_error_rm = rdma_resource_manager::type_id::create(
      "allocated_error_rm"
    );
    allocated_error_binding = make_active_binding(
      "allocated_error_binding", 64'he220_0000_0000_0004,
      32'he220_0404, 32'd14
    );
    expect_status("ALLOC_ERROR_CREATE_PD",
                  allocated_error_rm.create_pd(allocated_error_binding,
                                                allocated_error_pd),
                  RDMA_SC_OK);
    expect_status("ALLOC_ERROR_CREATE_MR",
                  allocated_error_rm.create_mr(allocated_error_binding,
                                                allocated_error_pd.handle,
                                                allocated_error_mr),
                  RDMA_SC_OK);
    if (allocated_error_mr.local_mr_id != 0)
      `uvm_error("ALLOC_ERROR_CREATE_MR",
                 "test requires the first, zero-ID unprogrammed MR")
    expect_status("ALLOC_ERROR_FREEZE_RAW",
                  allocated_error_rm.freeze(allocated_error_mr.handle),
                  RDMA_SC_INVALID_STATE);
    expect_status("ALLOC_ERROR_FREEZE_RAW_LOOKUP",
                  allocated_error_rm.lookup(allocated_error_mr.handle,
                                            resource),
                  RDMA_SC_OK);
    if (resource == null || resource.state != RDMA_RESOURCE_ALLOCATED)
      `uvm_error("ALLOC_ERROR_FREEZE_RAW_LOOKUP",
                 "raw freeze attempt changed authoritative MR state")
    expect_status("ALLOC_ERROR_STAGE_RAW",
                  allocated_error_rm.stage_allocated(allocated_error_mr),
                  RDMA_SC_INVALID_ARGUMENT);
    expect_status("ALLOC_ERROR_STAGE_RAW_LOOKUP",
                  allocated_error_rm.lookup(allocated_error_mr.handle,
                                            resource),
                  RDMA_SC_OK);
    if (resource == null || resource.state != RDMA_RESOURCE_ALLOCATED)
      `uvm_error("ALLOC_ERROR_STAGE_RAW_LOOKUP",
                 "raw stage attempt changed authoritative MR state")
    expect_status("ALLOC_ERROR_STAGE_RAW_NO_RECOVERY",
                  allocated_error_rm.lookup_recovery(
                    allocated_error_mr.handle, recovery_lookup
                  ),
                  RDMA_SC_INVALID_STATE);
    expect_status("ALLOC_ERROR_PD_RESERVED_BUSY",
                  allocated_error_rm.release_reserved(
                    allocated_error_pd.handle
                  ), RDMA_SC_RESOURCE_BUSY);
    expect_status("ALLOC_ERROR_PD_RESERVED_PRESERVED",
                  allocated_error_rm.lookup(allocated_error_pd.handle,
                                            resource),
                  RDMA_SC_OK);
    if (resource == null || resource.state != RDMA_RESOURCE_ALLOCATED)
      `uvm_error("ALLOC_ERROR_PD_RESERVED_PRESERVED",
                 "busy reservation rollback changed PD state")
    recovery_record = rdma_recovery_record::type_id::create(
      "allocated_error_recovery"
    );
    recovery_record.resource_h = clone_handle(
      "ALLOC_ERROR_H", allocated_error_mr.handle
    );
    recovery_record.hardware_presence = RDMA_HW_PRESENCE_ABSENT;
    recovery_record.primary_status = rdma_status::make(
      RDMA_SC_RESET_CANCELLED, "programming aborted before key commit"
    );
    expect_status("ALLOC_ERROR_MARK_RAW",
                  allocated_error_rm.mark_error(allocated_error_mr.handle,
                                                recovery_record),
                  RDMA_SC_INVALID_STATE);
    expect_status("ALLOC_ERROR_RAW_LOOKUP",
                  allocated_error_rm.lookup(allocated_error_mr.handle,
                                            resource),
                  RDMA_SC_OK);
    if (resource == null || resource.state != RDMA_RESOURCE_ALLOCATED)
      `uvm_error("ALLOC_ERROR_RAW_LOOKUP",
                 "rejected raw MR recovery changed registry state")
    expect_status("ALLOC_ERROR_RAW_NO_RECOVERY",
                  allocated_error_rm.lookup_recovery(
                    allocated_error_mr.handle, recovery_lookup
                  ), RDMA_SC_INVALID_STATE);
    allocated_error_mr.iova.value = 64'h2000_0000;
    allocated_error_mr.length = 64'h4000;
    allocated_error_mr.lkey = {
      allocated_error_mr.local_mr_id[23:0], 8'ha5
    };
    allocated_error_mr.rkey = allocated_error_mr.lkey;
    allocated_error_mr.access = '{local_write:1'b1, remote_read:1'b1,
                                  remote_write:1'b0,
                                  memory_window_bind:1'b0,
                                  remote_atomic:1'b0};
    expect_status("ALLOC_ERROR_STAGE",
                  allocated_error_rm.stage_allocated(allocated_error_mr),
                  RDMA_SC_OK);
    expect_status("ALLOC_ERROR_MARK_STAGED",
                  allocated_error_rm.mark_error(allocated_error_mr.handle,
                                                recovery_record),
                  RDMA_SC_OK);
    expect_status("ALLOC_ERROR_STAGED_LOOKUP",
                  allocated_error_rm.lookup(allocated_error_mr.handle,
                                            resource),
                  RDMA_SC_OK);
    if (resource == null || resource.state != RDMA_RESOURCE_ERROR)
      `uvm_error("ALLOC_ERROR_STAGED_LOOKUP",
                 "staged exact incarnation did not enter ERROR")
    expect_status("ALLOC_ERROR_FUNCTION_RELEASE",
                  allocated_error_rm.release_function(
                    allocated_error_binding.make_handle()
                  ), RDMA_SC_OK);
    expect_status("ALLOC_ERROR_NO_LEAKS",
                  allocated_error_rm.check_leaks(leak_count), RDMA_SC_OK);

    // Publication may update programmable context, but allocator identity and
    // dependency topology remain manager-owned across staging and commit.
    publication_rm = new("publication_rm");
    publication_binding = make_active_binding(
      "publication_binding", 64'h1c1f_1000_0000_0001,
      32'h1c1f_1101, 32'd18
    );
    expect_status("PUBLICATION_CREATE_PD",
                  publication_rm.create_pd(publication_binding,
                                            publication_pd),
                  RDMA_SC_OK);
    expect_status("PUBLICATION_CREATE_LOCAL_MR",
                  publication_rm.create_mr(publication_binding,
                                            publication_pd.handle,
                                            publication_local_mr),
                  RDMA_SC_OK);
    prepare_mr(publication_local_mr, 64'h3100_0000);
    publication_local_before = publication_local_mr.local_mr_id;
    publication_serial_before =
      publication_rm.observed_next_object_serial(RDMA_RESOURCE_MR);
    publication_free_before =
      publication_rm.observed_free_local_id_count(RDMA_RESOURCE_MR);
    publication_local_mr.local_mr_id++;
    publication_local_mr.lkey = {
      publication_local_mr.local_mr_id[23:0], 8'h5a
    };
    publication_local_mr.rkey = publication_local_mr.lkey;
    expect_status("PUBLICATION_REJECT_LOCAL_ID",
                  publication_rm.stage_allocated(publication_local_mr),
                  RDMA_SC_INVALID_ARGUMENT);
    expect_status("PUBLICATION_LOCAL_ID_REGISTRY",
                  publication_rm.lookup(publication_local_mr.handle,
                                         resource),
                  RDMA_SC_OK);
    if (resource == null || !$cast(publication_lookup_mr, resource) ||
        publication_lookup_mr.local_mr_id != publication_local_before)
      `uvm_error("PUBLICATION_LOCAL_ID_REGISTRY",
                 "rejected local-ID mutation changed authoritative MR")

    expect_status("PUBLICATION_CREATE_GLOBAL_MR",
                  publication_rm.create_mr(publication_binding,
                                            publication_pd.handle,
                                            publication_global_mr),
                  RDMA_SC_OK);
    prepare_mr(publication_global_mr, 64'h3200_0000);
    publication_global_before = publication_global_mr.global_mr_id;
    publication_global_mr.global_mr_id++;
    expect_status("PUBLICATION_REJECT_GLOBAL_ID",
                  publication_rm.stage_allocated(publication_global_mr),
                  RDMA_SC_INVALID_ARGUMENT);
    expect_status("PUBLICATION_GLOBAL_ID_REGISTRY",
                  publication_rm.lookup(publication_global_mr.handle,
                                         resource),
                  RDMA_SC_OK);
    if (resource == null || !$cast(publication_lookup_mr, resource) ||
        publication_lookup_mr.global_mr_id != publication_global_before)
      `uvm_error("PUBLICATION_GLOBAL_ID_REGISTRY",
                 "rejected global-ID mutation changed authoritative MR")

    expect_status("PUBLICATION_CREATE_TOPOLOGY_MR",
                  publication_rm.create_mr(publication_binding,
                                            publication_pd.handle,
                                            publication_topology_mr),
                  RDMA_SC_OK);
    prepare_mr(publication_topology_mr, 64'h3300_0000);
    publication_topology_mr.pd_h = null;
    publication_topology_mr.dependencies.delete();
    expect_status("PUBLICATION_REJECT_TOPOLOGY",
                  publication_rm.stage_allocated(publication_topology_mr),
                  RDMA_SC_INVALID_ARGUMENT);
    expect_status("PUBLICATION_PD_STILL_BUSY",
                  publication_rm.release_reserved(publication_pd.handle),
                  RDMA_SC_RESOURCE_BUSY);

    expect_status("PUBLICATION_CREATE_CQ",
                  publication_rm.create_cq(publication_binding, null,
                                            publication_cq),
                  RDMA_SC_OK);
    publication_cq.depth = 8;
    publication_local_before = publication_cq.local_cq_id;
    publication_global_before = publication_cq.global_cq_id;
    publication_cq.local_cq_id++;
    publication_cq.global_cq_id++;
    expect_status("PUBLICATION_REJECT_CQ_IDS",
                  publication_rm.stage_allocated(publication_cq),
                  RDMA_SC_INVALID_ARGUMENT);
    expect_status("PUBLICATION_CQ_REGISTRY",
                  publication_rm.lookup(publication_cq.handle, resource),
                  RDMA_SC_OK);
    if (resource == null || !$cast(publication_lookup_cq, resource) ||
        publication_lookup_cq.local_cq_id != publication_local_before ||
        publication_lookup_cq.global_cq_id != publication_global_before)
      `uvm_error("PUBLICATION_CQ_REGISTRY",
                 "rejected CQ identity mutation changed registry")

    expect_status("PUBLICATION_CREATE_COMMIT_MR",
                  publication_rm.create_mr(publication_binding,
                                            publication_pd.handle,
                                            publication_commit_mr),
                  RDMA_SC_OK);
    prepare_mr(publication_commit_mr, 64'h3400_0000);
    expect_status("PUBLICATION_STAGE_COMMIT_MR",
                  publication_rm.stage_allocated(publication_commit_mr),
                  RDMA_SC_OK);
    publication_local_before = publication_commit_mr.local_mr_id;
    publication_commit_mr.local_mr_id++;
    publication_commit_mr.lkey = {
      publication_commit_mr.local_mr_id[23:0], 8'h5a
    };
    publication_commit_mr.rkey = publication_commit_mr.lkey;
    expect_status("PUBLICATION_REJECT_COMMIT_ID",
                  publication_rm.commit_programmed(publication_commit_mr),
                  RDMA_SC_INVALID_ARGUMENT);
    expect_status("PUBLICATION_COMMIT_REGISTRY",
                  publication_rm.lookup(publication_commit_mr.handle,
                                         resource),
                  RDMA_SC_OK);
    if (resource == null || !$cast(publication_lookup_mr, resource) ||
        publication_lookup_mr.state != RDMA_RESOURCE_ALLOCATED ||
        publication_lookup_mr.local_mr_id != publication_local_before)
      `uvm_error("PUBLICATION_COMMIT_REGISTRY",
                 "rejected commit changed staged authoritative MR")
    if (publication_rm.observed_next_object_serial(RDMA_RESOURCE_MR) !=
          publication_serial_before + 3 ||
        publication_rm.observed_free_local_id_count(RDMA_RESOURCE_MR) !=
          publication_free_before)
      `uvm_error("PUBLICATION_ALLOCATOR_ATOMIC",
                 "publication attacks changed allocator bookkeeping")
    expect_status("PUBLICATION_RELEASE_FUNCTION",
                  publication_rm.release_function(
                    publication_binding.make_handle()
                  ),
                  RDMA_SC_OK);
    expect_status("PUBLICATION_NO_LEAKS",
                  publication_rm.check_leaks(leak_count), RDMA_SC_OK);

    // PD bypasses hardware programming and transitions directly from
    // ALLOCATED to ACTIVE, even if a caller previously staged its snapshot.
    pd_commit_rm = rdma_resource_manager::type_id::create("pd_commit_rm");
    pd_commit_binding = make_active_binding(
      "pd_commit_binding", 64'h1c1f_2000_0000_0001,
      32'h1c1f_2201, 32'd19
    );
    expect_status("PD_COMMIT_CREATE",
                  pd_commit_rm.create_pd(pd_commit_binding, pd_commit_pd),
                  RDMA_SC_OK);
    expect_status("PD_COMMIT_FREEZE_REJECT",
                  pd_commit_rm.freeze(pd_commit_pd.handle),
                  RDMA_SC_INVALID_STATE);
    expect_status("PD_COMMIT_ORDINARY_REJECT",
                  pd_commit_rm.commit_programmed(pd_commit_pd),
                  RDMA_SC_INVALID_STATE);
    expect_status("PD_COMMIT_STAGE",
                  pd_commit_rm.stage_allocated(pd_commit_pd), RDMA_SC_OK);
    expect_status("PD_COMMIT_STAGED_FREEZE_REJECT",
                  pd_commit_rm.freeze(pd_commit_pd.handle),
                  RDMA_SC_INVALID_STATE);
    expect_status("PD_COMMIT_STAGED_REJECT",
                  pd_commit_rm.commit_programmed(pd_commit_pd),
                  RDMA_SC_INVALID_STATE);
    expect_status("PD_COMMIT_STATE_PRESERVED",
                  pd_commit_rm.lookup(pd_commit_pd.handle, resource),
                  RDMA_SC_OK);
    if (resource == null || resource.state != RDMA_RESOURCE_ALLOCATED)
      `uvm_error("PD_COMMIT_STATE_PRESERVED",
                 "PD commit attempt changed ALLOCATED state")
    expect_status("PD_COMMIT_ACTIVATE",
                  pd_commit_rm.activate(pd_commit_pd.handle), RDMA_SC_OK);
    expect_status("PD_COMMIT_RELEASE_FUNCTION",
                  pd_commit_rm.release_function(
                    pd_commit_binding.make_handle()
                  ),
                  RDMA_SC_OK);
    expect_status("PD_COMMIT_NO_LEAKS",
                  pd_commit_rm.check_leaks(leak_count), RDMA_SC_OK);

    // Dependencies that are closing or failed cannot admit new children.
    dependency_gate_rm = new("dependency_gate_rm");
    dependency_gate_binding = make_active_binding(
      "dependency_gate_binding", 64'h1c1f_3000_0000_0001,
      32'h1c1f_3301, 32'd20
    );
    expect_status("DEPENDENCY_QUIESCING_CREATE_PD",
                  dependency_gate_rm.create_pd(dependency_gate_binding,
                                                dependency_quiescing_pd),
                  RDMA_SC_OK);
    expect_status("DEPENDENCY_QUIESCING_ACTIVATE_PD",
                  dependency_gate_rm.activate(dependency_quiescing_pd.handle),
                  RDMA_SC_OK);
    expect_status("DEPENDENCY_QUIESCING_BEGIN",
                  dependency_gate_rm.begin_quiesce(
                    dependency_quiescing_pd.handle
                  ),
                  RDMA_SC_OK);
    expect_status("DEPENDENCY_ERROR_CREATE_PD",
                  dependency_gate_rm.create_pd(dependency_gate_binding,
                                                dependency_error_pd),
                  RDMA_SC_OK);
    recovery_record = rdma_recovery_record::type_id::create(
      "dependency_error_recovery"
    );
    recovery_record.resource_h = clone_handle(
      "DEPENDENCY_ERROR_H", dependency_error_pd.handle
    );
    recovery_record.hardware_presence = RDMA_HW_PRESENCE_ABSENT;
    recovery_record.primary_status = rdma_status::make(
      RDMA_SC_RESET_CANCELLED, "dependency failed before child creation"
    );
    expect_status("DEPENDENCY_ERROR_MARK",
                  dependency_gate_rm.mark_error(dependency_error_pd.handle,
                                                recovery_record),
                  RDMA_SC_OK);
    publication_serial_before =
      dependency_gate_rm.observed_next_object_serial(RDMA_RESOURCE_MR);
    publication_free_before =
      dependency_gate_rm.observed_free_local_id_count(RDMA_RESOURCE_MR);
    expect_status("DEPENDENCY_QUIESCING_REJECT_CHILD",
                  dependency_gate_rm.create_mr(
                    dependency_gate_binding, dependency_quiescing_pd.handle,
                    dependency_blocked_mr
                  ),
                  RDMA_SC_INVALID_STATE);
    if (dependency_blocked_mr != null ||
        dependency_gate_rm.observed_next_object_serial(RDMA_RESOURCE_MR) !=
          publication_serial_before ||
        dependency_gate_rm.observed_free_local_id_count(RDMA_RESOURCE_MR) !=
          publication_free_before)
      `uvm_error("DEPENDENCY_QUIESCING_ATOMIC",
                 "QUIESCING dependency consumed MR allocator state")
    expect_status("DEPENDENCY_ERROR_REJECT_CHILD",
                  dependency_gate_rm.create_mr(
                    dependency_gate_binding, dependency_error_pd.handle,
                    dependency_blocked_mr
                  ),
                  RDMA_SC_INVALID_STATE);
    if (dependency_blocked_mr != null ||
        dependency_gate_rm.observed_next_object_serial(RDMA_RESOURCE_MR) !=
          publication_serial_before ||
        dependency_gate_rm.observed_free_local_id_count(RDMA_RESOURCE_MR) !=
          publication_free_before)
      `uvm_error("DEPENDENCY_ERROR_ATOMIC",
                 "ERROR dependency consumed MR allocator state")
    expect_status("DEPENDENCY_GATE_LEAK_COUNT",
                  dependency_gate_rm.check_leaks(leak_count),
                  RDMA_SC_INVALID_STATE);
    if (leak_count != 2)
      `uvm_error("DEPENDENCY_GATE_LEAK_COUNT",
                 $sformatf("rejected child creation left %0d resources",
                           leak_count))
    expect_status("DEPENDENCY_GATE_RELEASE_FUNCTION",
                  dependency_gate_rm.release_function(
                    dependency_gate_binding.make_handle()
                  ),
                  RDMA_SC_OK);
    expect_status("DEPENDENCY_GATE_NO_LEAKS",
                  dependency_gate_rm.check_leaks(leak_count), RDMA_SC_OK);

    // Public values are carriers, not trusted UVM implementations.  Compatible
    // subclasses are projected field-by-field into built-in manager storage;
    // inherited or forged wrapper identity must never trigger a virtual hook.
    void'(rdma_rm_lying_mr::get_type());
    void'(rdma_rm_lying_mapping::get_type());
    void'(rdma_rm_lying_recovery::get_type());
    projection_rm = new("projection_rm");
    projection_binding = make_active_binding(
      "projection_binding", 64'h1c1f_5000_0000_0001,
      32'h1c1f_5501, 32'd23
    );
    expect_status("PROJECTION_CREATE_PD",
                  projection_rm.create_pd(projection_binding, projection_pd),
                  RDMA_SC_OK);
    expect_status("PROJECTION_CREATE_MR",
                  projection_rm.create_mr(projection_binding,
                                          projection_pd.handle,
                                          projection_seed_mr),
                  RDMA_SC_OK);
    prepare_mr(projection_seed_mr, 64'h6100_0000);

    projection_unregistered_mr = new("projection_unregistered_mr");
    projection_unregistered_mr.copy(projection_seed_mr);
    projection_unregistered_mr.extra_scalar = 32'hc011_aa01;
    projection_unregistered_mr.extra_child = clone_handle(
      "PROJECTION_UNREGISTERED_MR_EXTRA", projection_seed_mr.pd_h
    );
    projection_unregistered_mr.clone_calls = 0;
    mutating_clone_length = projection_unregistered_mr.length;
    expect_status("PROJECTION_UNREGISTERED_MR_STAGE",
                  projection_rm.stage_allocated(projection_unregistered_mr),
                  RDMA_SC_OK);
    if (projection_unregistered_mr.clone_calls != 0 ||
        projection_unregistered_mr.length != mutating_clone_length ||
        projection_unregistered_mr.extra_scalar != 32'hc011_aa01 ||
        projection_unregistered_mr.extra_child == null)
      `uvm_error("PROJECTION_UNREGISTERED_MR_SOURCE",
                 "unregistered MR virtual hook ran or source fields changed")
    expect_status("PROJECTION_UNREGISTERED_MR_LOOKUP",
                  projection_rm.lookup(projection_seed_mr.handle, resource),
                  RDMA_SC_OK);
    projection_unregistered_mr_leak = null;
    projection_lookup_mr = null;
    if (resource == null ||
        !$cast(projection_lookup_mr, resource) ||
        $cast(projection_unregistered_mr_leak, resource) ||
        resource.handle == projection_unregistered_mr.handle ||
        resource.owner == projection_unregistered_mr.owner ||
        projection_lookup_mr.pd_h ==
          projection_unregistered_mr.extra_child)
      `uvm_error("PROJECTION_UNREGISTERED_MR_STORAGE",
                 "unregistered MR, root handle, or extension child escaped projection")
    expect_status("PROJECTION_UNREGISTERED_MR_COMMIT",
                  projection_rm.commit_programmed(projection_unregistered_mr),
                  RDMA_SC_OK);
    expect_status("PROJECTION_UNREGISTERED_MR_ACTIVATE",
                  projection_rm.activate(projection_seed_mr.handle),
                  RDMA_SC_OK);
    if (projection_unregistered_mr.clone_calls != 0 ||
        projection_unregistered_mr.length != mutating_clone_length)
      `uvm_error("PROJECTION_UNREGISTERED_MR_LIFECYCLE",
                 "MR lifecycle dispatched through the public carrier")

    // A registered subtype can lie about get_object_type().  Inject it into the
    // registry to cover later lookup/quiesce/restore paths as well as ingress.
    projection_lying_mr = new("projection_lying_mr");
    projection_lying_mr.copy(projection_unregistered_mr);
    projection_lying_mr.state = RDMA_RESOURCE_ACTIVE;
    projection_lying_mr.extra_scalar = 32'hc011_aa02;
    projection_lying_mr.extra_child = clone_handle(
      "PROJECTION_LYING_MR_EXTRA", projection_seed_mr.pd_h
    );
    projection_lying_mr.clone_calls = 0;
    mutating_clone_length = projection_lying_mr.length;
    projection_rm.replace_authoritative(projection_lying_mr);
    expect_status("PROJECTION_LYING_MR_LOOKUP",
                  projection_rm.lookup(projection_lying_mr.handle, resource),
                  RDMA_SC_OK);
    projection_lying_mr_leak = null;
    projection_lookup_mr = null;
    if (projection_lying_mr.clone_calls != 0 ||
        projection_lying_mr.length != mutating_clone_length ||
        projection_lying_mr.extra_scalar != 32'hc011_aa02 ||
        !$cast(projection_lookup_mr, resource) ||
        $cast(projection_lying_mr_leak, resource) ||
        projection_lookup_mr.pd_h == projection_lying_mr.extra_child)
      `uvm_error("PROJECTION_LYING_MR_LOOKUP_STORAGE",
                 "lying MR hook ran, source changed, subtype escaped, or extension child leaked")
    expect_status("PROJECTION_LYING_MR_QUIESCE",
                  projection_rm.begin_quiesce(projection_lying_mr.handle),
                  RDMA_SC_OK);
    projection_lying_mr_leak = null;
    if (projection_lying_mr.clone_calls != 0 ||
        projection_lying_mr.state != RDMA_RESOURCE_ACTIVE ||
        $cast(projection_lying_mr_leak,
              projection_rm.observed_resource_probe(
                projection_lying_mr.handle
              )) ||
        projection_rm.observed_resource_probe(
          projection_lying_mr.handle
        ).state != RDMA_RESOURCE_QUIESCING)
      `uvm_error("PROJECTION_LYING_MR_QUIESCE_STORAGE",
                 "quiesce retained or mutated a lying registry carrier")
    expect_status("PROJECTION_LYING_MR_RESTORE",
                  projection_rm.restore_active(projection_lying_mr.handle),
                  RDMA_SC_OK);
    if (projection_lying_mr.clone_calls != 0 ||
        projection_lying_mr.state != RDMA_RESOURCE_ACTIVE)
      `uvm_error("PROJECTION_LYING_MR_RESTORE_SOURCE",
                 "restore dispatched through the lying registry carrier")

    // handle.kind selects the built-in projection class.  A carrier whose
    // declared resource class disagrees must fail with a null output and must
    // not disturb the already-normalized registry entry.
    projection_mismatched_mr = new("projection_mismatched_mr");
    projection_mismatched_mr.copy(projection_seed_mr);
    projection_mismatched_mr.handle.kind = RDMA_RESOURCE_PD;
    resource = projection_seed_mr;
    expect_status(
      "PROJECTION_KIND_CLASS_MISMATCH",
      projection_rm.probe_public_resource_projection(
        projection_mismatched_mr, resource
      ), RDMA_SC_INVALID_ARGUMENT
    );
    if (resource != null || projection_mismatched_mr.clone_calls != 0)
      `uvm_error("PROJECTION_KIND_CLASS_MISMATCH_OUTPUT",
                 "kind/class mismatch retained output or invoked a hook")
    expect_status("PROJECTION_KIND_CLASS_MISMATCH_ROLLBACK",
                  projection_rm.lookup(projection_seed_mr.handle, resource),
                  RDMA_SC_OK);
    if (resource == null || resource.state != RDMA_RESOURCE_ACTIVE)
      `uvm_error("PROJECTION_KIND_CLASS_MISMATCH_ROLLBACK",
                 "failed projection changed the authoritative registry")

    // Nested inherited-wrapper and lying-wrapper mappings are independently
    // projected; extension children cannot enter the registry graph.
    expect_status("PROJECTION_CREATE_NESTED_MR",
                  projection_rm.create_mr(projection_binding,
                                          projection_pd.handle,
                                          projection_nested_mr),
                  RDMA_SC_OK);
    prepare_mr(projection_nested_mr, 64'h6200_0000);
    projection_unregistered_mapping =
      new("projection_unregistered_mapping");
    projection_unregistered_mapping.function_h = clone_function_handle(
      "PROJECTION_UNREGISTERED_MAPPING_FUNCTION",
      projection_binding.make_handle()
    );
    projection_unregistered_mapping.requester_bdf =
      projection_binding.pcie.bdf;
    projection_unregistered_mapping.backing_addr.value = 64'h6300_0000;
    projection_unregistered_mapping.iova.value = 64'h6400_0000;
    projection_unregistered_mapping.size = 64'h1000;
    projection_unregistered_mapping.direction = RDMA_DMA_BIDIRECTIONAL;
    projection_unregistered_mapping.permissions =
      '{device_read:1'b1, device_write:1'b1, atomic:1'b0};
    projection_unregistered_mapping.state = RDMA_MAPPING_ACTIVE;
    projection_unregistered_mapping.owner_h = clone_handle(
      "PROJECTION_UNREGISTERED_MAPPING_OWNER", projection_nested_mr.handle
    );
    projection_unregistered_mapping.extra_child = clone_handle(
      "PROJECTION_UNREGISTERED_MAPPING_EXTRA", projection_nested_mr.pd_h
    );
    projection_unregistered_mapping.clone_calls = 0;
    projection_unregistered_backing_ref =
      new("projection_unregistered_backing_ref");
    projection_unregistered_backing_ref.mapping =
      projection_unregistered_mapping;
    projection_unregistered_backing_ref.ownership =
      RDMA_OWNERSHIP_BORROWED;
    projection_nested_mr.backing_refs.push_back(
      projection_unregistered_backing_ref
    );

    projection_lying_mapping = new("projection_lying_mapping");
    projection_lying_mapping.function_h = clone_function_handle(
      "PROJECTION_LYING_MAPPING_FUNCTION", projection_binding.make_handle()
    );
    projection_lying_mapping.requester_bdf = projection_binding.pcie.bdf;
    projection_lying_mapping.backing_addr.value = 64'h6500_0000;
    projection_lying_mapping.iova.value = 64'h6600_0000;
    projection_lying_mapping.size = 64'h1000;
    projection_lying_mapping.direction = RDMA_DMA_BIDIRECTIONAL;
    projection_lying_mapping.permissions =
      '{device_read:1'b1, device_write:1'b1, atomic:1'b0};
    projection_lying_mapping.state = RDMA_MAPPING_ACTIVE;
    projection_lying_mapping.owner_h = clone_handle(
      "PROJECTION_LYING_MAPPING_OWNER", projection_nested_mr.handle
    );
    projection_lying_mapping.extra_child = clone_handle(
      "PROJECTION_LYING_MAPPING_EXTRA", projection_nested_mr.pd_h
    );
    projection_lying_mapping.clone_calls = 0;
    projection_lying_backing_ref = new("projection_lying_backing_ref");
    projection_lying_backing_ref.mapping = projection_lying_mapping;
    projection_lying_backing_ref.ownership = RDMA_OWNERSHIP_BORROWED;
    projection_nested_mr.backing_refs.push_back(
      projection_lying_backing_ref
    );
    projection_size_before = projection_unregistered_mapping.size;
    expect_status("PROJECTION_NESTED_MAPPING_STAGE",
                  projection_rm.stage_allocated(projection_nested_mr),
                  RDMA_SC_OK);
    if (projection_unregistered_mapping.clone_calls != 0 ||
        projection_lying_mapping.clone_calls != 0 ||
        projection_unregistered_mapping.size != projection_size_before ||
        projection_lying_mapping.size != projection_size_before)
      `uvm_error("PROJECTION_NESTED_MAPPING_SOURCE",
                 "nested mapping hook ran or source mapping changed")
    expect_status("PROJECTION_NESTED_MAPPING_LOOKUP",
                  projection_rm.lookup(projection_nested_mr.handle, resource),
                  RDMA_SC_OK);
    projection_unregistered_mapping_leak = null;
    projection_lying_mapping_leak = null;
    if (resource == null || resource.backing_refs.size() != 2 ||
        resource.backing_refs[0] == null ||
        resource.backing_refs[1] == null ||
        $cast(projection_unregistered_mapping_leak,
              resource.backing_refs[0].mapping) ||
        $cast(projection_lying_mapping_leak,
              resource.backing_refs[1].mapping) ||
        resource.backing_refs[0].mapping ==
          projection_unregistered_mapping ||
        resource.backing_refs[1].mapping == projection_lying_mapping ||
        resource.backing_refs[0].mapping.function_h ==
          projection_unregistered_mapping.extra_child ||
        resource.backing_refs[0].mapping.owner_h ==
          projection_unregistered_mapping.extra_child ||
        resource.backing_refs[1].mapping.function_h ==
          projection_lying_mapping.extra_child ||
        resource.backing_refs[1].mapping.owner_h ==
          projection_lying_mapping.extra_child)
      `uvm_error("PROJECTION_NESTED_MAPPING_STORAGE",
                 "mapping subtype, extension graph, or alias escaped projection")

    // Recovery roots use the same carrier rule at ingress and on later table
    // reads.  Both wrapper-spoof mechanisms must remain hook-free.
    expect_status("PROJECTION_CREATE_RECOVERY_PD_A",
                  projection_rm.create_pd(projection_binding,
                                          projection_recovery_pd_a),
                  RDMA_SC_OK);
    projection_unregistered_recovery =
      new("projection_unregistered_recovery");
    projection_unregistered_recovery.resource_h = clone_handle(
      "PROJECTION_UNREGISTERED_RECOVERY_H",
      projection_recovery_pd_a.handle
    );
    projection_unregistered_recovery.hardware_presence =
      RDMA_HW_PRESENCE_ABSENT;
    projection_unregistered_recovery.primary_status = rdma_status::make(
      RDMA_SC_RESET_CANCELLED, "unregistered recovery carrier"
    );
    projection_unregistered_recovery.extra_child = clone_handle(
      "PROJECTION_UNREGISTERED_RECOVERY_EXTRA",
      projection_recovery_pd_a.handle
    );
    projection_unregistered_recovery.clone_calls = 0;
    projection_presence_before =
      projection_unregistered_recovery.hardware_presence;
    expect_status("PROJECTION_UNREGISTERED_RECOVERY_MARK",
                  projection_rm.mark_error(
                    projection_recovery_pd_a.handle,
                    projection_unregistered_recovery
                  ), RDMA_SC_OK);
    if (projection_unregistered_recovery.clone_calls != 0 ||
        projection_unregistered_recovery.hardware_presence !=
          projection_presence_before ||
        projection_unregistered_recovery.extra_scalar != 32'hc011_c001 ||
        projection_unregistered_recovery.extra_child == null)
      `uvm_error("PROJECTION_UNREGISTERED_RECOVERY_SOURCE",
                 "unregistered recovery hook ran or source changed")
    expect_status("PROJECTION_UNREGISTERED_RECOVERY_LOOKUP",
                  projection_rm.lookup_recovery(
                    projection_recovery_pd_a.handle, recovery_lookup
                  ), RDMA_SC_OK);
    projection_unregistered_recovery_leak = null;
    if (recovery_lookup == null ||
        $cast(projection_unregistered_recovery_leak, recovery_lookup) ||
        recovery_lookup.resource_h ==
          projection_unregistered_recovery.resource_h ||
        recovery_lookup.resource_h ==
          projection_unregistered_recovery.extra_child)
      `uvm_error("PROJECTION_UNREGISTERED_RECOVERY_STORAGE",
                 "unregistered recovery or handle alias escaped projection")
    expect_status("PROJECTION_UNREGISTERED_RECOVERY_CLEAR",
                  projection_rm.clear_recovery(
                    projection_recovery_pd_a.handle
                  ), RDMA_SC_OK);

    expect_status("PROJECTION_CREATE_RECOVERY_PD_B",
                  projection_rm.create_pd(projection_binding,
                                          projection_recovery_pd_b),
                  RDMA_SC_OK);
    projection_lying_recovery = new("projection_lying_recovery");
    projection_lying_recovery.resource_h = clone_handle(
      "PROJECTION_LYING_RECOVERY_H", projection_recovery_pd_b.handle
    );
    projection_lying_recovery.hardware_presence = RDMA_HW_PRESENCE_ABSENT;
    projection_lying_recovery.primary_status = rdma_status::make(
      RDMA_SC_RESET_CANCELLED, "lying recovery carrier"
    );
    projection_lying_recovery.extra_child = clone_handle(
      "PROJECTION_LYING_RECOVERY_EXTRA", projection_recovery_pd_b.handle
    );
    projection_lying_recovery.clone_calls = 0;
    projection_presence_before = projection_lying_recovery.hardware_presence;
    expect_status("PROJECTION_LYING_RECOVERY_MARK",
                  projection_rm.mark_error(
                    projection_recovery_pd_b.handle,
                    projection_lying_recovery
                  ), RDMA_SC_OK);
    if (projection_lying_recovery.clone_calls != 0 ||
        projection_lying_recovery.hardware_presence !=
          projection_presence_before ||
        projection_lying_recovery.extra_scalar != 32'hc011_c002)
      `uvm_error("PROJECTION_LYING_RECOVERY_SOURCE",
                 "lying recovery hook ran or source changed")
    expect_status("PROJECTION_LYING_RECOVERY_LOOKUP",
                  projection_rm.lookup_recovery(
                    projection_recovery_pd_b.handle, recovery_lookup
                  ), RDMA_SC_OK);
    projection_lying_recovery_leak = null;
    if (recovery_lookup == null ||
        $cast(projection_lying_recovery_leak, recovery_lookup) ||
        recovery_lookup.resource_h == projection_lying_recovery.extra_child)
      `uvm_error("PROJECTION_LYING_RECOVERY_STORAGE",
                 "lying recovery subtype or extension child escaped ingress projection")

    // Simulate later table corruption with a fresh lying carrier.  Lookup must
    // return a built-in projection and clear must remove it without dispatch.
    projection_lying_recovery = new("projection_late_lying_recovery");
    projection_lying_recovery.copy(recovery_lookup);
    projection_lying_recovery.extra_child = clone_handle(
      "PROJECTION_LATE_RECOVERY_EXTRA", projection_recovery_pd_b.handle
    );
    projection_lying_recovery.clone_calls = 0;
    projection_presence_before = projection_lying_recovery.hardware_presence;
    projection_rm.inject_recovery_probe(projection_recovery_pd_b.handle,
                                        projection_lying_recovery);
    expect_status("PROJECTION_LATE_RECOVERY_LOOKUP",
                  projection_rm.lookup_recovery(
                    projection_recovery_pd_b.handle, recovery_lookup_again
                  ), RDMA_SC_OK);
    projection_lying_recovery_leak = null;
    if (projection_lying_recovery.clone_calls != 0 ||
        projection_lying_recovery.hardware_presence !=
          projection_presence_before ||
        recovery_lookup_again == null ||
        $cast(projection_lying_recovery_leak, recovery_lookup_again) ||
        recovery_lookup_again.resource_h ==
          projection_lying_recovery.extra_child)
      `uvm_error("PROJECTION_LATE_RECOVERY_STORAGE",
                 "later recovery lookup dispatched or retained subtype")
    expect_status("PROJECTION_LATE_RECOVERY_CLEAR",
                  projection_rm.clear_recovery(
                    projection_recovery_pd_b.handle
                  ), RDMA_SC_OK);
    if (projection_lying_recovery.clone_calls != 0 ||
        projection_rm.observed_recovery_probe(
          projection_recovery_pd_b.handle
        ) != null)
      `uvm_error("PROJECTION_LATE_RECOVERY_CLEAR",
                 "later recovery clear dispatched or retained carrier")

    expect_status("PROJECTION_RELEASE_FUNCTION",
                  projection_rm.release_function(
                    projection_binding.make_handle()
                  ), RDMA_SC_OK);
    expect_status("PROJECTION_NO_LEAKS",
                  projection_rm.check_leaks(leak_count), RDMA_SC_OK);

    // Composite 1: a registered Function carrier with registered PCIe/BAR
    // nodes is normalized through the real Function registration path.
    composite_function_rm = new("composite_function_rm");
    composite_function_binding = new("composite_function_binding");
    composite_function_pcie = new("composite_function_pcie");
    composite_function_binding.pcie = composite_function_pcie;
    composite_function_binding.function_uid = 64'hc0a1_0000_0000_0001;
    composite_function_binding.notify_bar_id = 3'd3;
    composite_function_binding.notify_base.value =
      64'h0000_0001_0003_2000;
    composite_function_binding.notify_size = 64'h2000;
    composite_function_binding.notify_table_sel = 32'hc0a1_0101;
    composite_function_binding.notify_table_index = 32'hc0a1_0202;
    composite_function_binding.host_id = 32'hc0a1_0303;
    composite_function_binding.pfvf_id = 32'hc0a1_0404;
    composite_function_binding.rdma_vf_id = 8'h05;
    composite_function_binding.global_function_id = 32'hc0a1_0606;
    composite_function_binding.vsi_id = 32'hc0a1_0707;
    composite_function_binding.state = RDMA_BIND_ACTIVE;
    composite_function_binding.generation = 32'hc0a1_0909;
    composite_function_binding.notify_valid = 1'b1;
    composite_function_binding.notify_ready = 1'b1;
    composite_function_binding.dmi_valid = 1'b1;
    composite_function_binding.dmi_ready = 1'b1;
    composite_function_binding.vft_valid = 1'b1;
    composite_function_binding.vft_ready = 1'b1;
    composite_function_pcie.bdf =
      '{segment:16'hc0a1, bus:8'h11, device:5'h12, function_num:3'h3};
    composite_function_pcie.parent_pf_bdf =
      '{segment:16'hc0a2, bus:8'h21, device:5'h13, function_num:3'h4};
    composite_function_pcie.vf_index = 32'hc0a1_0a0a;
    composite_function_pcie.mse = 1'b1;
    composite_function_pcie.bme = 1'b1;
    composite_function_binding.queue_dma.requester_bdf =
      composite_function_pcie.bdf;
    composite_function_binding.queue_dma.pasid_valid = 1'b1;
    composite_function_binding.queue_dma.pasid = 20'hc0a18;
    composite_function_binding.queue_dma.dma_domain_id = 32'hc0a1_0808;
    composite_function_binding.queue_dma.dma_domain_valid = 1'b1;
    composite_function_binding.queue_caps.min_cq_depth = 16;
    composite_function_binding.queue_caps.max_cq_depth = 32768;
    composite_function_binding.queue_caps.min_srq_depth = 16;
    composite_function_binding.queue_caps.max_srq_depth = 32768;
    composite_function_binding.queue_caps.max_ceq_depth = 4096;
    composite_function_binding.queue_caps.max_aeq_depth = 4096;
    composite_function_binding.queue_caps.max_wq_sge = 8;
    composite_function_binding.queue_caps.max_queue_ring_bytes =
      32'h0020_0000;
    composite_function_binding.queue_caps.max_sgb_bytes = 32'h0040_0000;
    composite_function_vector = '{default:'0};
    composite_function_vector.function_local_vector = 3;
    composite_function_vector.hardware_eq_vector = 17;
    composite_function_vector.msix_table_index = 5;
    composite_function_vector.enabled = 1'b1;
    composite_function_binding.interrupt_vectors.push_back(
      composite_function_vector
    );
    foreach (composite_function_bars[i]) begin
      composite_function_bars[i] = new(
        $sformatf("composite_function_bar_%0d", i)
      );
      composite_function_bars[i].bar_id = i;
      composite_function_bars[i].base.value =
        64'h0000_0001_0000_0000 + (i * 64'h0001_0000);
      composite_function_bars[i].size = 64'h8000 + (i * 64'h1000);
      composite_function_bars[i].enabled = (i != 2);
      composite_function_bars[i].clone_calls = 0;
      composite_function_pcie.bar[i] = composite_function_bars[i];
    end
    composite_function_owner = new("composite_function_owner");
    composite_function_owner.kind = RDMA_RESOURCE_FUNCTION;
    composite_function_owner.function_uid =
      composite_function_binding.function_uid;
    composite_function_owner.object_id =
      composite_function_binding.global_function_id;
    composite_function_owner.generation =
      composite_function_binding.generation;
    composite_function_owner.clone_calls = 0;
    composite_function_binding.owner_h = composite_function_owner;
    composite_function_binding.clone_calls = 0;
    composite_function_pcie.clone_calls = 0;
    expect_status(
      "COMPOSITE_FUNCTION_CREATE",
      composite_function_rm.create_function(composite_function_binding,
                                            composite_function),
      RDMA_SC_OK
    );
    if (composite_function_binding.clone_calls != 0 ||
        composite_function_pcie.clone_calls != 0 ||
        composite_function_owner.clone_calls != 0 ||
        composite_function_binding.pcie != composite_function_pcie ||
        composite_function_binding.owner_h != composite_function_owner ||
        composite_function_binding.function_uid !=
          64'hc0a1_0000_0000_0001 ||
        composite_function_binding.notify_bar_id != 3'd3 ||
        composite_function_binding.notify_base.value !=
          64'h0000_0001_0003_2000 ||
        composite_function_binding.notify_size != 64'h2000 ||
        composite_function_binding.notify_table_sel != 32'hc0a1_0101 ||
        composite_function_binding.notify_table_index != 32'hc0a1_0202 ||
        composite_function_binding.host_id != 32'hc0a1_0303 ||
        composite_function_binding.pfvf_id != 32'hc0a1_0404 ||
        composite_function_binding.rdma_vf_id != 8'h05 ||
        composite_function_binding.global_function_id != 32'hc0a1_0606 ||
        composite_function_binding.vsi_id != 32'hc0a1_0707 ||
        composite_function_binding.queue_dma.dma_domain_id !=
          32'hc0a1_0808 ||
        !composite_function_binding.queue_dma.dma_domain_valid ||
        composite_function_binding.state != RDMA_BIND_ACTIVE ||
        composite_function_binding.generation != 32'hc0a1_0909 ||
        !composite_function_binding.notify_valid ||
        !composite_function_binding.notify_ready ||
        !composite_function_binding.dmi_valid ||
        !composite_function_binding.dmi_ready ||
        !composite_function_binding.vft_valid ||
        !composite_function_binding.vft_ready ||
        composite_function_pcie.bdf.segment != 16'hc0a1 ||
        composite_function_pcie.bdf.bus != 8'h11 ||
        composite_function_pcie.bdf.device != 5'h12 ||
        composite_function_pcie.bdf.function_num != 3'h3 ||
        composite_function_pcie.parent_pf_bdf.segment != 16'hc0a2 ||
        composite_function_pcie.parent_pf_bdf.bus != 8'h21 ||
        composite_function_pcie.parent_pf_bdf.device != 5'h13 ||
        composite_function_pcie.parent_pf_bdf.function_num != 3'h4 ||
        composite_function_pcie.vf_index != 32'hc0a1_0a0a ||
        !composite_function_pcie.mse || !composite_function_pcie.bme)
      `uvm_error("COMPOSITE_FUNCTION_SOURCE",
                 "Function carrier hook ran or a source sentinel changed")
    foreach (composite_function_bars[i]) begin
      if (composite_function_bars[i].clone_calls != 0 ||
          composite_function_pcie.bar[i] != composite_function_bars[i] ||
          composite_function_bars[i].bar_id != i ||
          composite_function_bars[i].base.value !=
            64'h0000_0001_0000_0000 + (i * 64'h0001_0000) ||
          composite_function_bars[i].size !=
            64'h8000 + (i * 64'h1000) ||
          composite_function_bars[i].enabled != (i != 2))
        `uvm_error("COMPOSITE_FUNCTION_BAR_SOURCE",
                   $sformatf("BAR[%0d] hook ran or sentinel changed", i))
    end
    composite_binding_leak = null;
    composite_pcie_leak = null;
    composite_function_handle_leak = null;
    if (composite_function == null || composite_function.binding == null ||
        composite_function.binding.pcie == null ||
        $cast(composite_binding_leak, composite_function.binding) ||
        $cast(composite_pcie_leak, composite_function.binding.pcie) ||
        $cast(composite_function_handle_leak, composite_function.handle) ||
        $cast(composite_function_handle_leak,
              composite_function.binding.owner_h) ||
        $cast(composite_function_handle_leak, composite_function.owner) ||
        composite_function.binding == composite_function_binding ||
        composite_function.binding.pcie == composite_function_pcie ||
        composite_function.binding.owner_h == composite_function_owner ||
        composite_function.handle == composite_function_owner ||
        composite_function.owner == composite_function_owner)
      `uvm_error("COMPOSITE_FUNCTION_PUBLICATION",
                 "Function publication retained a derived node or alias")
    foreach (composite_function_bars[i]) begin
      composite_bar_leak = null;
      if (composite_function.binding.pcie.bar[i] == null ||
          $cast(composite_bar_leak,
                composite_function.binding.pcie.bar[i]) ||
          composite_function.binding.pcie.bar[i] ==
            composite_function_bars[i])
        `uvm_error("COMPOSITE_FUNCTION_BAR_PUBLICATION",
                   $sformatf("BAR[%0d] was not detached and built-in", i))
    end
    expect_status(
      "COMPOSITE_FUNCTION_LOOKUP",
      composite_function_rm.lookup(composite_function_owner, resource),
      RDMA_SC_OK
    );
    composite_binding_leak = null;
    composite_pcie_leak = null;
    composite_function_handle_leak = null;
    if (!$cast(composite_function_lookup, resource) ||
        $cast(composite_binding_leak,
              composite_function_lookup.binding) ||
        $cast(composite_pcie_leak,
              composite_function_lookup.binding.pcie) ||
        $cast(composite_function_handle_leak,
              composite_function_lookup.handle) ||
        $cast(composite_function_handle_leak,
              composite_function_lookup.binding.owner_h) ||
        $cast(composite_function_handle_leak,
              composite_function_lookup.owner) ||
        composite_function_lookup == composite_function ||
        composite_function_lookup.binding == composite_function.binding ||
        composite_function_lookup.binding.pcie ==
          composite_function.binding.pcie ||
        composite_function_lookup.binding.owner_h ==
          composite_function.binding.owner_h ||
        composite_function_lookup.binding == composite_function_binding ||
        composite_function_lookup.binding.function_uid !=
          composite_function_binding.function_uid ||
        composite_function_lookup.binding.notify_bar_id !=
          composite_function_binding.notify_bar_id ||
        composite_function_lookup.binding.notify_base !=
          composite_function_binding.notify_base ||
        composite_function_lookup.binding.notify_size !=
          composite_function_binding.notify_size ||
        composite_function_lookup.binding.notify_table_sel !=
          composite_function_binding.notify_table_sel ||
        composite_function_lookup.binding.notify_table_index !=
          composite_function_binding.notify_table_index ||
        composite_function_lookup.binding.host_id !=
          composite_function_binding.host_id ||
        composite_function_lookup.binding.pfvf_id !=
          composite_function_binding.pfvf_id ||
        composite_function_lookup.binding.rdma_vf_id !=
          composite_function_binding.rdma_vf_id ||
        composite_function_lookup.binding.global_function_id !=
          composite_function_binding.global_function_id ||
        composite_function_lookup.binding.vsi_id !=
          composite_function_binding.vsi_id ||
        composite_function_lookup.binding.queue_dma.dma_domain_id !=
          composite_function_binding.queue_dma.dma_domain_id ||
        composite_function_lookup.binding.queue_dma.dma_domain_valid !=
          composite_function_binding.queue_dma.dma_domain_valid ||
        composite_function_lookup.binding.queue_caps.max_queue_ring_bytes !=
          composite_function_binding.queue_caps.max_queue_ring_bytes ||
        composite_function_lookup.binding.interrupt_vectors.size() != 1 ||
        composite_function_lookup.binding.interrupt_vectors[0].
          function_local_vector !=
          composite_function_vector.function_local_vector ||
        composite_function_lookup.binding.state !=
          composite_function_binding.state ||
        composite_function_lookup.binding.generation !=
          composite_function_binding.generation ||
        !same_handle_fields(composite_function_lookup.binding.owner_h,
                            composite_function_owner) ||
        composite_function_lookup.binding.notify_valid !=
          composite_function_binding.notify_valid ||
        composite_function_lookup.binding.notify_ready !=
          composite_function_binding.notify_ready ||
        composite_function_lookup.binding.dmi_valid !=
          composite_function_binding.dmi_valid ||
        composite_function_lookup.binding.dmi_ready !=
          composite_function_binding.dmi_ready ||
        composite_function_lookup.binding.vft_valid !=
          composite_function_binding.vft_valid ||
        composite_function_lookup.binding.vft_ready !=
          composite_function_binding.vft_ready ||
        composite_function_lookup.binding.pcie.bdf !=
          composite_function_pcie.bdf ||
        composite_function_lookup.binding.pcie.parent_pf_bdf !=
          composite_function_pcie.parent_pf_bdf ||
        composite_function_lookup.binding.pcie.vf_index !=
          composite_function_pcie.vf_index ||
        composite_function_lookup.binding.pcie.mse !=
          composite_function_pcie.mse ||
        composite_function_lookup.binding.pcie.bme !=
          composite_function_pcie.bme)
      `uvm_error("COMPOSITE_FUNCTION_LOOKUP_FIELDS",
                 "Function lookup lost a declared sentinel or detachment")
    foreach (composite_function_bars[i]) begin
      composite_bar_leak = null;
      if ($cast(composite_bar_leak,
                composite_function_lookup.binding.pcie.bar[i]) ||
          composite_function_lookup.binding.pcie.bar[i] == null ||
          composite_function_lookup.binding.pcie.bar[i] ==
            composite_function_bars[i] ||
          composite_function_lookup.binding.pcie.bar[i] ==
            composite_function.binding.pcie.bar[i] ||
          composite_function_lookup.binding.pcie.bar[i].bar_id !=
            composite_function_bars[i].bar_id ||
          composite_function_lookup.binding.pcie.bar[i].base !=
            composite_function_bars[i].base ||
          composite_function_lookup.binding.pcie.bar[i].size !=
            composite_function_bars[i].size ||
          composite_function_lookup.binding.pcie.bar[i].enabled !=
            composite_function_bars[i].enabled)
        `uvm_error("COMPOSITE_FUNCTION_BAR_LOOKUP",
                   $sformatf("BAR[%0d] projection lost its sentinel", i))
    end
    expect_status("COMPOSITE_FUNCTION_RELEASE",
                  composite_function_rm.release_function(
                    composite_function_owner
                  ), RDMA_SC_OK);
    expect_status("COMPOSITE_FUNCTION_NO_LEAKS",
                  composite_function_rm.check_leaks(leak_count), RDMA_SC_OK);
    if (composite_function_binding.clone_calls != 0 ||
        composite_function_pcie.clone_calls != 0 ||
        composite_function_owner.clone_calls != 0 ||
        composite_function_owner.kind != RDMA_RESOURCE_FUNCTION ||
        composite_function_owner.function_uid !=
          64'hc0a1_0000_0000_0001 ||
        composite_function_owner.object_id != 32'hc0a1_0606 ||
        composite_function_owner.generation != 32'hc0a1_0909)
      `uvm_error("COMPOSITE_FUNCTION_POST_LIFECYCLE_HOOKS",
                 "Function lifecycle invoked a hook or changed its handle")
    foreach (composite_function_bars[i]) begin
      if (composite_function_bars[i].clone_calls != 0)
        `uvm_error("COMPOSITE_FUNCTION_BAR_POST_LIFECYCLE_HOOKS",
                   $sformatf("BAR[%0d] hook ran during lifecycle", i))
    end

    // Composite 2: a registered MR root carries ordered registered backing,
    // mapping, handle, and HMC nodes through stage/lookup/commit.
    composite_mr_rm = new("composite_mr_rm");
    composite_mr_binding = make_active_binding(
      "composite_mr_binding", 64'hc0a2_0000_0000_0001,
      32'hc0a2_0101, 32'hc0a2_0202
    );
    expect_status("COMPOSITE_MR_CREATE_PD",
                  composite_mr_rm.create_pd(composite_mr_binding,
                                            composite_mr_pd),
                  RDMA_SC_OK);
    expect_status("COMPOSITE_MR_CREATE",
                  composite_mr_rm.create_mr(composite_mr_binding,
                                            composite_mr_pd.handle,
                                            composite_mr_seed),
                  RDMA_SC_OK);
    prepare_mr(composite_mr_seed, 64'hc0a2_1000_0000_0000);
    composite_mr_candidate = new("composite_mr_candidate");
    composite_mr_candidate.copy(composite_mr_seed);
    composite_mr_candidate.extra_scalar = 32'hc0a2_e001;
    composite_mr_candidate.hmc_fvm_addr.value =
      64'hc0a2_2000_0000_0000;
    composite_mr_candidate.hmc_fvm_addr_valid = 1'b1;
    composite_mr_handle = new("composite_mr_handle");
    composite_mr_handle.kind = composite_mr_seed.handle.kind;
    composite_mr_handle.function_uid = composite_mr_seed.handle.function_uid;
    composite_mr_handle.object_id = composite_mr_seed.handle.object_id;
    composite_mr_handle.generation = composite_mr_seed.handle.generation;
    composite_mr_handle.clone_calls = 0;
    composite_mr_candidate.handle = composite_mr_handle;
    composite_mr_owner = new("composite_mr_owner");
    composite_mr_owner.kind = composite_mr_seed.owner.kind;
    composite_mr_owner.function_uid = composite_mr_seed.owner.function_uid;
    composite_mr_owner.object_id = composite_mr_seed.owner.object_id;
    composite_mr_owner.generation = composite_mr_seed.owner.generation;
    composite_mr_owner.clone_calls = 0;
    composite_mr_candidate.owner = composite_mr_owner;
    composite_mr_pd_handle = new("composite_mr_pd_handle");
    composite_mr_pd_handle.kind = composite_mr_seed.pd_h.kind;
    composite_mr_pd_handle.function_uid = composite_mr_seed.pd_h.function_uid;
    composite_mr_pd_handle.object_id = composite_mr_seed.pd_h.object_id;
    composite_mr_pd_handle.generation = composite_mr_seed.pd_h.generation;
    composite_mr_pd_handle.clone_calls = 0;
    composite_mr_candidate.pd_h = composite_mr_pd_handle;
    composite_mr_candidate.extra_child = composite_mr_pd_handle;
    composite_mr_dependency = new("composite_mr_dependency");
    composite_mr_dependency.kind = composite_mr_seed.dependencies[0].kind;
    composite_mr_dependency.function_uid =
      composite_mr_seed.dependencies[0].function_uid;
    composite_mr_dependency.object_id =
      composite_mr_seed.dependencies[0].object_id;
    composite_mr_dependency.generation =
      composite_mr_seed.dependencies[0].generation;
    composite_mr_dependency.clone_calls = 0;
    composite_mr_candidate.dependencies[0] = composite_mr_dependency;
    composite_mr_candidate.backing_refs.delete();
    composite_mr_candidate.hmc_refs.delete();
    foreach (composite_backing_refs[i]) begin
      composite_mapping_functions[i] = new(
        $sformatf("composite_mapping_function_%0d", i)
      );
      composite_mapping_functions[i].kind = RDMA_RESOURCE_FUNCTION;
      composite_mapping_functions[i].function_uid =
        composite_mr_binding.function_uid;
      composite_mapping_functions[i].object_id =
        composite_mr_binding.global_function_id;
      composite_mapping_functions[i].generation =
        composite_mr_binding.generation;
      composite_mapping_functions[i].clone_calls = 0;
      composite_mapping_owners[i] = new(
        $sformatf("composite_mapping_owner_%0d", i)
      );
      composite_mapping_owners[i].kind = RDMA_RESOURCE_MR;
      composite_mapping_owners[i].function_uid =
        composite_mr_candidate.handle.function_uid;
      composite_mapping_owners[i].object_id =
        composite_mr_candidate.handle.object_id;
      composite_mapping_owners[i].generation =
        composite_mr_candidate.handle.generation;
      composite_mapping_owners[i].clone_calls = 0;
      composite_mappings[i] = new($sformatf("composite_mapping_%0d", i));
      composite_mappings[i].function_h = composite_mapping_functions[i];
      composite_mappings[i].requester_bdf = composite_mr_binding.pcie.bdf;
      composite_mappings[i].pasid_valid = (i == 1);
      composite_mappings[i].pasid = 20'hca200 + i;
      composite_mappings[i].dma_domain_valid = 1'b1;
      composite_mappings[i].dma_domain_id = 32'hca2d_0000 + i;
      composite_mappings[i].backing_addr.value =
        64'hc0a2_3000_0000_0000 + (i * 64'h10000);
      composite_mappings[i].iova.value =
        64'hc0a2_4000_0000_0000 + (i * 64'h20000);
      composite_mappings[i].size = 64'h3000 + (i * 64'h1000);
      composite_mappings[i].direction =
        (i == 0) ? RDMA_DMA_DEVICE_READ : RDMA_DMA_BIDIRECTIONAL;
      composite_mappings[i].permissions =
        (i == 0) ?
          '{device_read:1'b1, device_write:1'b0, atomic:1'b0} :
          '{device_read:1'b1, device_write:1'b1, atomic:1'b1};
      composite_mappings[i].state = RDMA_MAPPING_ACTIVE;
      composite_mappings[i].owner_h = composite_mapping_owners[i];
      composite_mappings[i].clone_calls = 0;
      composite_backing_refs[i] = new(
        $sformatf("composite_backing_ref_%0d", i)
      );
      composite_backing_refs[i].mapping = composite_mappings[i];
      composite_backing_refs[i].ownership = RDMA_OWNERSHIP_BORROWED;
      composite_backing_refs[i].release_complete = 1'b0;
      composite_backing_refs[i].clone_calls = 0;
      composite_mr_candidate.backing_refs.push_back(
        composite_backing_refs[i]
      );
      composite_hmc_owners[i] = new(
        $sformatf("composite_hmc_owner_%0d", i)
      );
      composite_hmc_owners[i].kind = RDMA_RESOURCE_FUNCTION;
      composite_hmc_owners[i].function_uid = composite_mr_binding.function_uid;
      composite_hmc_owners[i].object_id =
        composite_mr_binding.global_function_id;
      composite_hmc_owners[i].generation = composite_mr_binding.generation;
      composite_hmc_owners[i].clone_calls = 0;
      composite_hmc_refs[i] = new(
        $sformatf("composite_hmc_ref_%0d", i)
      );
      composite_hmc_refs[i].owner = composite_hmc_owners[i];
      composite_hmc_refs[i].object_kind = RDMA_RESOURCE_MR;
      composite_hmc_refs[i].address.value =
        64'hc0a2_5000_0000_0000 + (i * 64'h4000);
      composite_hmc_refs[i].size = 64'h5000 + (i * 64'h1000);
      composite_hmc_refs[i].first_pbl_index = 32'hc0a2_1000 + i;
      composite_hmc_refs[i].ownership =
        (i == 0) ? RDMA_OWNERSHIP_BORROWED :
                   RDMA_OWNERSHIP_CONTROL_PLANE;
      composite_hmc_refs[i].release_complete = (i == 1);
      composite_hmc_refs[i].clone_calls = 0;
      composite_mr_candidate.hmc_refs.push_back(composite_hmc_refs[i]);
    end
    composite_mr_candidate.clone_calls = 0;
    expect_status("COMPOSITE_MR_STAGE",
                  composite_mr_rm.stage_allocated(composite_mr_candidate),
                  RDMA_SC_OK);
    if (composite_mr_candidate.clone_calls != 0 ||
        composite_mr_handle.clone_calls != 0 ||
        composite_mr_owner.clone_calls != 0 ||
        composite_mr_pd_handle.clone_calls != 0 ||
        composite_mr_dependency.clone_calls != 0 ||
        composite_mr_candidate.handle != composite_mr_handle ||
        composite_mr_candidate.owner != composite_mr_owner ||
        composite_mr_candidate.pd_h != composite_mr_pd_handle ||
        !same_handle_fields(composite_mr_candidate.handle,
                            composite_mr_seed.handle) ||
        !same_handle_fields(composite_mr_candidate.owner,
                            composite_mr_seed.owner) ||
        !same_handle_fields(composite_mr_candidate.pd_h,
                            composite_mr_seed.pd_h) ||
        composite_mr_candidate.extra_child != composite_mr_pd_handle ||
        composite_mr_candidate.extra_scalar != 32'hc0a2_e001 ||
        composite_mr_candidate.state != composite_mr_seed.state ||
        composite_mr_candidate.local_mr_id !=
          composite_mr_seed.local_mr_id ||
        composite_mr_candidate.global_mr_id !=
          composite_mr_seed.global_mr_id ||
        composite_mr_candidate.iova.value !=
          64'hc0a2_1000_0000_0000 ||
        composite_mr_candidate.length != 64'h2000 ||
        composite_mr_candidate.lkey != composite_mr_seed.lkey ||
        composite_mr_candidate.rkey != composite_mr_seed.rkey ||
        composite_mr_candidate.access != composite_mr_seed.access ||
        composite_mr_candidate.mr_serial != composite_mr_seed.mr_serial ||
        composite_mr_candidate.dependencies.size() != 1 ||
        !same_handle_fields(composite_mr_candidate.dependencies[0],
                            composite_mr_seed.dependencies[0]) ||
        composite_mr_candidate.hmc_fvm_addr.value !=
          64'hc0a2_2000_0000_0000 ||
        !composite_mr_candidate.hmc_fvm_addr_valid ||
        composite_mr_candidate.backing_refs.size() != 2 ||
        composite_mr_candidate.hmc_refs.size() != 2)
      `uvm_error("COMPOSITE_MR_SOURCE",
                 "MR carrier hook ran, alias changed, or sentinel changed")
    foreach (composite_backing_refs[i]) begin
      if (composite_backing_refs[i].clone_calls != 0 ||
          composite_mappings[i].clone_calls != 0 ||
          composite_mapping_functions[i].clone_calls != 0 ||
          composite_mapping_owners[i].clone_calls != 0 ||
          composite_hmc_refs[i].clone_calls != 0 ||
          composite_hmc_owners[i].clone_calls != 0 ||
          composite_mr_candidate.backing_refs[i] !=
            composite_backing_refs[i] ||
          composite_backing_refs[i].mapping != composite_mappings[i] ||
          composite_mappings[i].function_h !=
            composite_mapping_functions[i] ||
          composite_mappings[i].owner_h != composite_mapping_owners[i] ||
          composite_mapping_functions[i].kind != RDMA_RESOURCE_FUNCTION ||
          composite_mapping_functions[i].function_uid !=
            composite_mr_binding.function_uid ||
          composite_mapping_functions[i].object_id !=
            composite_mr_binding.global_function_id ||
          composite_mapping_functions[i].generation !=
            composite_mr_binding.generation ||
          composite_mapping_owners[i].kind != RDMA_RESOURCE_MR ||
          composite_mapping_owners[i].function_uid !=
            composite_mr_candidate.handle.function_uid ||
          composite_mapping_owners[i].object_id !=
            composite_mr_candidate.handle.object_id ||
          composite_mapping_owners[i].generation !=
            composite_mr_candidate.handle.generation ||
          composite_mr_candidate.hmc_refs[i] != composite_hmc_refs[i] ||
          composite_hmc_refs[i].owner != composite_hmc_owners[i] ||
          composite_backing_refs[i].ownership !=
            RDMA_OWNERSHIP_BORROWED ||
          composite_backing_refs[i].release_complete ||
          composite_mappings[i].requester_bdf !=
            composite_mr_binding.pcie.bdf ||
          composite_mappings[i].pasid_valid != (i == 1) ||
          composite_mappings[i].pasid != 20'hca200 + i ||
          composite_mappings[i].backing_addr.value !=
            64'hc0a2_3000_0000_0000 + (i * 64'h10000) ||
          composite_mappings[i].iova.value !=
            64'hc0a2_4000_0000_0000 + (i * 64'h20000) ||
          composite_mappings[i].size !=
            64'h3000 + (i * 64'h1000) ||
          composite_mappings[i].direction !=
            ((i == 0) ? RDMA_DMA_DEVICE_READ :
                        RDMA_DMA_BIDIRECTIONAL) ||
          !composite_mappings[i].permissions.device_read ||
          composite_mappings[i].permissions.device_write != (i == 1) ||
          composite_mappings[i].permissions.atomic != (i == 1) ||
          composite_mappings[i].state != RDMA_MAPPING_ACTIVE ||
          composite_hmc_owners[i].kind != RDMA_RESOURCE_FUNCTION ||
          composite_hmc_owners[i].function_uid !=
            composite_mr_binding.function_uid ||
          composite_hmc_owners[i].object_id !=
            composite_mr_binding.global_function_id ||
          composite_hmc_owners[i].generation !=
            composite_mr_binding.generation ||
          composite_hmc_refs[i].object_kind != RDMA_RESOURCE_MR ||
          composite_hmc_refs[i].address.value !=
            64'hc0a2_5000_0000_0000 + (i * 64'h4000) ||
          composite_hmc_refs[i].size !=
            64'h5000 + (i * 64'h1000) ||
          composite_hmc_refs[i].first_pbl_index != 32'hc0a2_1000 + i ||
          composite_hmc_refs[i].ownership !=
            ((i == 0) ? RDMA_OWNERSHIP_BORROWED :
                        RDMA_OWNERSHIP_CONTROL_PLANE) ||
          composite_hmc_refs[i].release_complete != (i == 1))
        `uvm_error("COMPOSITE_MR_NESTED_SOURCE",
                   $sformatf("nested source[%0d] changed or dispatched", i))
    end
    expect_status("COMPOSITE_MR_LOOKUP",
                  composite_mr_rm.lookup(composite_mr_handle, resource),
                  RDMA_SC_OK);
    composite_mr_leak = null;
    composite_handle_leak = null;
    composite_function_handle_leak = null;
    if (!$cast(composite_mr_lookup, resource) ||
        $cast(composite_mr_leak, resource) ||
        $cast(composite_handle_leak, composite_mr_lookup.handle) ||
        $cast(composite_function_handle_leak, composite_mr_lookup.owner) ||
        $cast(composite_handle_leak, composite_mr_lookup.pd_h) ||
        composite_mr_lookup.dependencies.size() != 1 ||
        $cast(composite_handle_leak,
              composite_mr_lookup.dependencies[0]) ||
        composite_mr_lookup.handle == composite_mr_handle ||
        composite_mr_lookup.owner == composite_mr_owner ||
        composite_mr_lookup.pd_h == composite_mr_pd_handle ||
        composite_mr_lookup.dependencies[0] == composite_mr_dependency ||
        !same_handle_fields(composite_mr_lookup.handle,
                            composite_mr_handle) ||
        !same_handle_fields(composite_mr_lookup.owner,
                            composite_mr_owner) ||
        !same_handle_fields(composite_mr_lookup.pd_h,
                            composite_mr_pd_handle) ||
        !same_handle_fields(composite_mr_lookup.dependencies[0],
                            composite_mr_dependency) ||
        composite_mr_lookup.state != RDMA_RESOURCE_ALLOCATED ||
        composite_mr_lookup.local_mr_id !=
          composite_mr_candidate.local_mr_id ||
        composite_mr_lookup.global_mr_id !=
          composite_mr_candidate.global_mr_id ||
        composite_mr_lookup.iova != composite_mr_candidate.iova ||
        composite_mr_lookup.length != composite_mr_candidate.length ||
        composite_mr_lookup.lkey != composite_mr_candidate.lkey ||
        composite_mr_lookup.rkey != composite_mr_candidate.rkey ||
        composite_mr_lookup.access != composite_mr_candidate.access ||
        composite_mr_lookup.mr_serial != composite_mr_candidate.mr_serial ||
        composite_mr_lookup.backing_refs.size() != 2 ||
        composite_mr_lookup.hmc_refs.size() != 2 ||
        composite_mr_lookup.hmc_fvm_addr.value !=
          64'hc0a2_2000_0000_0000 ||
        !composite_mr_lookup.hmc_fvm_addr_valid)
      `uvm_error("COMPOSITE_MR_LOOKUP_ROOT",
                 "MR lookup retained a subtype/alias or lost root fields")
    foreach (composite_backing_refs[i]) begin
      composite_backing_leak = null;
      composite_mapping_leak = null;
      composite_hmc_leak = null;
      composite_function_handle_leak = null;
      composite_handle_leak = null;
      if (composite_mr_lookup.backing_refs[i] == null ||
          composite_mr_lookup.backing_refs[i].mapping == null ||
          composite_mr_lookup.hmc_refs[i] == null ||
          $cast(composite_backing_leak,
                composite_mr_lookup.backing_refs[i]) ||
          $cast(composite_mapping_leak,
                composite_mr_lookup.backing_refs[i].mapping) ||
          $cast(composite_hmc_leak, composite_mr_lookup.hmc_refs[i]) ||
          $cast(composite_function_handle_leak,
                composite_mr_lookup.backing_refs[i].mapping.function_h) ||
          $cast(composite_function_handle_leak,
                composite_mr_lookup.hmc_refs[i].owner) ||
          $cast(composite_handle_leak,
                composite_mr_lookup.backing_refs[i].mapping.owner_h) ||
          composite_mr_lookup.backing_refs[i] == composite_backing_refs[i] ||
          composite_mr_lookup.backing_refs[i].mapping ==
            composite_mappings[i] ||
          composite_mr_lookup.backing_refs[i].mapping.function_h ==
            composite_mapping_functions[i] ||
          composite_mr_lookup.backing_refs[i].mapping.owner_h ==
            composite_mapping_owners[i] ||
          composite_mr_lookup.hmc_refs[i] == composite_hmc_refs[i] ||
          composite_mr_lookup.hmc_refs[i].owner == composite_hmc_owners[i] ||
          composite_mr_lookup.backing_refs[i].ownership !=
            composite_backing_refs[i].ownership ||
          composite_mr_lookup.backing_refs[i].release_complete !=
            composite_backing_refs[i].release_complete ||
          composite_mr_lookup.backing_refs[i].mapping.requester_bdf !=
            composite_mappings[i].requester_bdf ||
          composite_mr_lookup.backing_refs[i].mapping.pasid_valid !=
            composite_mappings[i].pasid_valid ||
          composite_mr_lookup.backing_refs[i].mapping.pasid !=
            composite_mappings[i].pasid ||
          composite_mr_lookup.backing_refs[i].mapping.dma_domain_valid !=
            composite_mappings[i].dma_domain_valid ||
          composite_mr_lookup.backing_refs[i].mapping.dma_domain_id !=
            composite_mappings[i].dma_domain_id ||
          composite_mr_lookup.backing_refs[i].mapping.backing_addr !=
            composite_mappings[i].backing_addr ||
          composite_mr_lookup.backing_refs[i].mapping.iova !=
            composite_mappings[i].iova ||
          composite_mr_lookup.backing_refs[i].mapping.size !=
            composite_mappings[i].size ||
          composite_mr_lookup.backing_refs[i].mapping.direction !=
            composite_mappings[i].direction ||
          composite_mr_lookup.backing_refs[i].mapping.permissions !=
            composite_mappings[i].permissions ||
          composite_mr_lookup.backing_refs[i].mapping.state !=
            composite_mappings[i].state ||
          !same_handle_fields(
            composite_mr_lookup.backing_refs[i].mapping.function_h,
            composite_mapping_functions[i]
          ) ||
          !same_handle_fields(
            composite_mr_lookup.backing_refs[i].mapping.owner_h,
            composite_mapping_owners[i]
          ) ||
          composite_mr_lookup.hmc_refs[i].object_kind !=
            composite_hmc_refs[i].object_kind ||
          composite_mr_lookup.hmc_refs[i].address !=
            composite_hmc_refs[i].address ||
          composite_mr_lookup.hmc_refs[i].size != composite_hmc_refs[i].size ||
          composite_mr_lookup.hmc_refs[i].first_pbl_index !=
            composite_hmc_refs[i].first_pbl_index ||
          composite_mr_lookup.hmc_refs[i].ownership !=
            composite_hmc_refs[i].ownership ||
          composite_mr_lookup.hmc_refs[i].release_complete !=
            composite_hmc_refs[i].release_complete ||
          !same_handle_fields(composite_mr_lookup.hmc_refs[i].owner,
                              composite_hmc_owners[i]))
        `uvm_error("COMPOSITE_MR_LOOKUP_NESTED",
                   $sformatf("nested projection[%0d] lost order/fields", i))
    end
    expect_status("COMPOSITE_MR_COMMIT",
                  composite_mr_rm.commit_programmed(composite_mr_candidate),
                  RDMA_SC_OK);
    expect_status("COMPOSITE_MR_COMMIT_LOOKUP",
                  composite_mr_rm.lookup(composite_mr_handle, resource),
                  RDMA_SC_OK);
    composite_mr_leak = null;
    composite_handle_leak = null;
    composite_function_handle_leak = null;
    if (!$cast(composite_mr_lookup, resource) ||
        $cast(composite_mr_leak, resource) ||
        $cast(composite_handle_leak, composite_mr_lookup.handle) ||
        $cast(composite_function_handle_leak, composite_mr_lookup.owner) ||
        $cast(composite_handle_leak, composite_mr_lookup.pd_h) ||
        composite_mr_lookup.dependencies.size() != 1 ||
        $cast(composite_handle_leak,
              composite_mr_lookup.dependencies[0]) ||
        composite_mr_lookup.handle == composite_mr_handle ||
        composite_mr_lookup.owner == composite_mr_owner ||
        composite_mr_lookup.pd_h == composite_mr_pd_handle ||
        composite_mr_lookup.dependencies[0] == composite_mr_dependency ||
        composite_mr_lookup.state != RDMA_RESOURCE_PROGRAMMED ||
        composite_mr_lookup.backing_refs.size() != 2 ||
        composite_mr_lookup.hmc_refs.size() != 2 ||
        composite_mr_lookup.backing_refs[0].mapping.backing_addr.value !=
          64'hc0a2_3000_0000_0000 ||
        composite_mr_lookup.backing_refs[1].mapping.backing_addr.value !=
          64'hc0a2_3000_0001_0000 ||
        composite_mr_lookup.hmc_refs[0].address.value !=
          64'hc0a2_5000_0000_0000 ||
        composite_mr_lookup.hmc_refs[1].address.value !=
          64'hc0a2_5000_0000_4000)
      `uvm_error("COMPOSITE_MR_COMMIT_FIELDS",
                 "commit lost nested queue order or sentinels")
    foreach (composite_backing_refs[i]) begin
      composite_backing_leak = null;
      composite_mapping_leak = null;
      composite_hmc_leak = null;
      composite_function_handle_leak = null;
      composite_handle_leak = null;
      if ($cast(composite_backing_leak,
                composite_mr_lookup.backing_refs[i]) ||
          $cast(composite_mapping_leak,
                composite_mr_lookup.backing_refs[i].mapping) ||
          $cast(composite_hmc_leak, composite_mr_lookup.hmc_refs[i]) ||
          $cast(composite_function_handle_leak,
                composite_mr_lookup.backing_refs[i].mapping.function_h) ||
          $cast(composite_handle_leak,
                composite_mr_lookup.backing_refs[i].mapping.owner_h) ||
          $cast(composite_function_handle_leak,
                composite_mr_lookup.hmc_refs[i].owner) ||
          composite_mr_lookup.backing_refs[i] == composite_backing_refs[i] ||
          composite_mr_lookup.backing_refs[i].mapping ==
            composite_mappings[i] ||
          composite_mr_lookup.backing_refs[i].mapping.function_h ==
            composite_mapping_functions[i] ||
          composite_mr_lookup.backing_refs[i].mapping.owner_h ==
            composite_mapping_owners[i] ||
          composite_mr_lookup.hmc_refs[i] == composite_hmc_refs[i] ||
          composite_mr_lookup.hmc_refs[i].owner == composite_hmc_owners[i] ||
          composite_mr_lookup.backing_refs[i].mapping.dma_domain_valid !=
            composite_mappings[i].dma_domain_valid ||
          composite_mr_lookup.backing_refs[i].mapping.dma_domain_id !=
            composite_mappings[i].dma_domain_id ||
          composite_mr_lookup.backing_refs[i].mapping.backing_addr.value !=
            64'hc0a2_3000_0000_0000 + (i * 64'h10000) ||
          composite_mr_lookup.hmc_refs[i].address.value !=
            64'hc0a2_5000_0000_0000 + (i * 64'h4000))
        `uvm_error("COMPOSITE_MR_COMMIT_NESTED",
                   $sformatf("commit projection[%0d] retained subtype/alias",
                             i))
    end
    expect_status("COMPOSITE_MR_RELEASE",
                  composite_mr_rm.release_function(
                    composite_mr_binding.make_handle()
                  ), RDMA_SC_OK);
    expect_status("COMPOSITE_MR_NO_LEAKS",
                  composite_mr_rm.check_leaks(leak_count), RDMA_SC_OK);
    if (composite_mr_candidate.clone_calls != 0 ||
        composite_mr_handle.clone_calls != 0 ||
        composite_mr_owner.clone_calls != 0 ||
        composite_mr_pd_handle.clone_calls != 0 ||
        composite_mr_dependency.clone_calls != 0 ||
        composite_mr_candidate.handle != composite_mr_handle ||
        composite_mr_candidate.owner != composite_mr_owner ||
        composite_mr_candidate.pd_h != composite_mr_pd_handle ||
        composite_mr_candidate.dependencies[0] != composite_mr_dependency ||
        composite_mr_candidate.extra_child != composite_mr_pd_handle ||
        composite_mr_candidate.extra_scalar != 32'hc0a2_e001 ||
        composite_mr_candidate.iova.value !=
          64'hc0a2_1000_0000_0000 ||
        composite_mr_candidate.length != 64'h2000 ||
        composite_mr_candidate.hmc_fvm_addr.value !=
          64'hc0a2_2000_0000_0000 ||
        !composite_mr_candidate.hmc_fvm_addr_valid)
      `uvm_error("COMPOSITE_MR_POST_LIFECYCLE_SOURCE",
                 "MR lifecycle invoked a root hook or changed its source")
    foreach (composite_backing_refs[i]) begin
      if (composite_backing_refs[i].clone_calls != 0 ||
          composite_mappings[i].clone_calls != 0 ||
          composite_mapping_functions[i].clone_calls != 0 ||
          composite_mapping_owners[i].clone_calls != 0 ||
          composite_hmc_refs[i].clone_calls != 0 ||
          composite_hmc_owners[i].clone_calls != 0 ||
          composite_mr_candidate.backing_refs[i] !=
            composite_backing_refs[i] ||
          composite_backing_refs[i].mapping != composite_mappings[i] ||
          composite_mr_candidate.hmc_refs[i] != composite_hmc_refs[i] ||
          composite_mappings[i].backing_addr.value !=
            64'hc0a2_3000_0000_0000 + (i * 64'h10000) ||
          composite_mappings[i].iova.value !=
            64'hc0a2_4000_0000_0000 + (i * 64'h20000) ||
          !composite_mappings[i].dma_domain_valid ||
          composite_mappings[i].dma_domain_id != 32'hca2d_0000 + i ||
          composite_hmc_refs[i].address.value !=
            64'hc0a2_5000_0000_0000 + (i * 64'h4000))
        `uvm_error("COMPOSITE_MR_POST_LIFECYCLE_HOOKS",
                   $sformatf("nested source[%0d] changed during lifecycle",
                             i))
    end

    // Composite 3: a registered recovery root carries a registered ticket,
    // opcode, handles, and ordered status queue through mark/lookup.
    composite_recovery_rm = new("composite_recovery_rm");
    composite_recovery_binding = make_active_binding(
      "composite_recovery_binding", 64'hc0a3_0000_0000_0001,
      32'hc0a3_0101, 32'hc0a3_0202
    );
    expect_status("COMPOSITE_RECOVERY_CREATE_PD",
                  composite_recovery_rm.create_pd(
                    composite_recovery_binding, composite_recovery_pd
                  ), RDMA_SC_OK);
    composite_recovery = new("composite_recovery");
    composite_recovery_resource = new("composite_recovery_resource");
    composite_recovery_resource.kind = composite_recovery_pd.handle.kind;
    composite_recovery_resource.function_uid =
      composite_recovery_pd.handle.function_uid;
    composite_recovery_resource.object_id =
      composite_recovery_pd.handle.object_id;
    composite_recovery_resource.generation =
      composite_recovery_pd.handle.generation;
    composite_recovery_resource.clone_calls = 0;
    composite_recovery.resource_h = composite_recovery_resource;
    composite_recovery.hardware_presence = RDMA_HW_PRESENCE_UNKNOWN;
    composite_recovery.completed_steps.push_back(
      RDMA_CTRL_STEP_RESOURCE_RESERVED
    );
    composite_recovery.completed_steps.push_back(
      RDMA_CTRL_STEP_REGISTRY_PROGRAMMED
    );
    composite_recovery.pending_steps.push_back(RDMA_CTRL_STEP_HW_DRAINED);
    composite_recovery.pending_steps.push_back(
      RDMA_CTRL_STEP_BACKING_RELEASED
    );
    composite_recovery_ticket = new("composite_recovery_ticket");
    composite_recovery_ticket.command_id = 64'hc0a3_1000_0000_0001;
    composite_ticket_function = new("composite_ticket_function");
    composite_ticket_function.kind = RDMA_RESOURCE_FUNCTION;
    composite_ticket_function.function_uid =
      composite_recovery_binding.function_uid;
    composite_ticket_function.object_id =
      composite_recovery_binding.global_function_id;
    composite_ticket_function.generation =
      composite_recovery_binding.generation;
    composite_ticket_function.clone_calls = 0;
    composite_recovery_ticket.function_h = composite_ticket_function;
    composite_ticket_cmq = new("composite_ticket_cmq");
    composite_ticket_cmq.kind = RDMA_RESOURCE_CMQ;
    composite_ticket_cmq.function_uid =
      composite_recovery_binding.function_uid;
    composite_ticket_cmq.object_id = {RDMA_RESOURCE_CMQ, 28'h0c0_a301};
    composite_ticket_cmq.generation = composite_recovery_binding.generation;
    composite_ticket_cmq.clone_calls = 0;
    composite_recovery_ticket.cmq_h = composite_ticket_cmq;
    composite_recovery_ticket.slot_sequence = 64'd33;
    composite_recovery_ticket.sq_index = 32'd1;
    composite_recovery_ticket.sq_wrap = 1'b1;
    composite_ticket_opcode = new("composite_ticket_opcode");
    composite_ticket_opcode.profile_name = "composite_profile_c0a3";
    composite_ticket_opcode.opcode = 32'hc0a3_2002;
    composite_ticket_opcode.variant = "composite_variant_c0a3";
    composite_ticket_opcode.clone_calls = 0;
    composite_recovery_ticket.opcode_key = composite_ticket_opcode;
    composite_recovery_ticket.absolute_deadline = 987ns;
    composite_recovery_ticket.clone_calls = 0;
    composite_recovery.ambiguous_ticket = composite_recovery_ticket;
    composite_primary_status = new("composite_primary_status");
    composite_primary_status.category = RDMA_STATUS_RESET;
    composite_primary_status.code = RDMA_SC_RESET_CANCELLED;
    composite_primary_status.hardware_code = 32'hc0a3_3003;
    composite_primary_status.hardware_code_valid = 1'b1;
    composite_primary_status.source_engine = RDMA_ENGINE_RESET;
    composite_primary_status.function_uid =
      composite_recovery_binding.function_uid;
    composite_primary_status.generation =
      composite_recovery_binding.generation;
    composite_primary_status.resource_id = 64'hc0a3_4000_0000_0001;
    composite_primary_status.command_id = 64'hc0a3_5000_0000_0001;
    composite_primary_status.wr_id = 64'hc0a3_6000_0000_0001;
    composite_primary_status.severity = RDMA_SEVERITY_FATAL;
    composite_primary_status.retryable = 1'b1;
    composite_primary_status.message = "composite primary c0a3";
    composite_primary_status.clone_calls = 0;
    composite_recovery.primary_status = composite_primary_status;
    foreach (composite_rollback_statuses[i]) begin
      composite_rollback_statuses[i] = new(
        $sformatf("composite_rollback_status_%0d", i)
      );
      if (i == 0) begin
        composite_rollback_statuses[i].category = RDMA_STATUS_DMA;
        composite_rollback_statuses[i].code = RDMA_SC_DMA_TRANSLATION;
        composite_rollback_statuses[i].source_engine = RDMA_ENGINE_DMA;
        composite_rollback_statuses[i].severity = RDMA_SEVERITY_WARNING;
        composite_rollback_statuses[i].retryable = 1'b1;
      end
      else begin
        composite_rollback_statuses[i].category = RDMA_STATUS_PCIE;
        composite_rollback_statuses[i].code = RDMA_SC_PCIE_COMPLETION;
        composite_rollback_statuses[i].source_engine = RDMA_ENGINE_PCIE;
        composite_rollback_statuses[i].severity = RDMA_SEVERITY_ERROR;
        composite_rollback_statuses[i].retryable = 1'b0;
      end
      composite_rollback_statuses[i].hardware_code = 32'hc0a3_7000 + i;
      composite_rollback_statuses[i].hardware_code_valid = (i == 0);
      composite_rollback_statuses[i].function_uid =
        composite_recovery_binding.function_uid;
      composite_rollback_statuses[i].generation =
        composite_recovery_binding.generation;
      composite_rollback_statuses[i].resource_id =
        64'hc0a3_8000_0000_0000 + i;
      composite_rollback_statuses[i].command_id =
        64'hc0a3_9000_0000_0000 + i;
      composite_rollback_statuses[i].wr_id =
        64'hc0a3_a000_0000_0000 + i;
      composite_rollback_statuses[i].message =
        $sformatf("composite rollback c0a3 %0d", i);
      composite_rollback_statuses[i].clone_calls = 0;
      composite_recovery.rollback_statuses.push_back(
        composite_rollback_statuses[i]
      );
    end
    composite_recovery.extra_scalar = 32'hc0a3_e002;
    composite_recovery.extra_child = composite_recovery_resource;
    composite_recovery.clone_calls = 0;
    expect_status(
      "COMPOSITE_RECOVERY_MARK",
      composite_recovery_rm.mark_error(composite_recovery_pd.handle,
                                       composite_recovery),
      RDMA_SC_OK
    );
    if (composite_recovery.clone_calls != 0 ||
        composite_recovery_resource.clone_calls != 0 ||
        composite_recovery_ticket.clone_calls != 0 ||
        composite_ticket_function.clone_calls != 0 ||
        composite_ticket_cmq.clone_calls != 0 ||
        composite_ticket_opcode.clone_calls != 0 ||
        composite_primary_status.clone_calls != 0 ||
        composite_recovery.resource_h != composite_recovery_resource ||
        composite_recovery.ambiguous_ticket != composite_recovery_ticket ||
        composite_recovery.primary_status != composite_primary_status ||
        composite_recovery.extra_child != composite_recovery_resource ||
        composite_recovery.extra_scalar != 32'hc0a3_e002 ||
        composite_recovery.hardware_presence != RDMA_HW_PRESENCE_UNKNOWN ||
        composite_recovery.completed_steps.size() != 2 ||
        composite_recovery.completed_steps[0] !=
          RDMA_CTRL_STEP_RESOURCE_RESERVED ||
        composite_recovery.completed_steps[1] !=
          RDMA_CTRL_STEP_REGISTRY_PROGRAMMED ||
        composite_recovery.pending_steps.size() != 2 ||
        composite_recovery.pending_steps[0] != RDMA_CTRL_STEP_HW_DRAINED ||
        composite_recovery.pending_steps[1] !=
          RDMA_CTRL_STEP_BACKING_RELEASED ||
        composite_recovery_ticket.command_id !=
          64'hc0a3_1000_0000_0001 ||
        composite_recovery_ticket.function_h != composite_ticket_function ||
        composite_recovery_ticket.cmq_h != composite_ticket_cmq ||
        composite_recovery_ticket.slot_sequence != 64'd33 ||
        composite_recovery_ticket.sq_index != 32'd1 ||
        !composite_recovery_ticket.sq_wrap ||
        composite_recovery_ticket.opcode_key != composite_ticket_opcode ||
        composite_recovery_ticket.absolute_deadline != 987ns ||
        composite_ticket_opcode.profile_name != "composite_profile_c0a3" ||
        composite_ticket_opcode.opcode != 32'hc0a3_2002 ||
        composite_ticket_opcode.variant != "composite_variant_c0a3" ||
        composite_primary_status.category != RDMA_STATUS_RESET ||
        composite_primary_status.code != RDMA_SC_RESET_CANCELLED ||
        composite_primary_status.hardware_code != 32'hc0a3_3003 ||
        !composite_primary_status.hardware_code_valid ||
        composite_primary_status.source_engine != RDMA_ENGINE_RESET ||
        composite_primary_status.function_uid !=
          composite_recovery_binding.function_uid ||
        composite_primary_status.generation !=
          composite_recovery_binding.generation ||
        composite_primary_status.resource_id !=
          64'hc0a3_4000_0000_0001 ||
        composite_primary_status.command_id !=
          64'hc0a3_5000_0000_0001 ||
        composite_primary_status.wr_id != 64'hc0a3_6000_0000_0001 ||
        composite_primary_status.severity != RDMA_SEVERITY_FATAL ||
        !composite_primary_status.retryable ||
        composite_primary_status.message != "composite primary c0a3" ||
        composite_recovery.rollback_statuses.size() != 2)
      `uvm_error("COMPOSITE_RECOVERY_SOURCE",
                 "recovery source hook ran or a sentinel/order changed")
    foreach (composite_rollback_statuses[i]) begin
      if (composite_rollback_statuses[i].clone_calls != 0 ||
          composite_recovery.rollback_statuses[i] !=
            composite_rollback_statuses[i] ||
          composite_rollback_statuses[i].category !=
            ((i == 0) ? RDMA_STATUS_DMA : RDMA_STATUS_PCIE) ||
          composite_rollback_statuses[i].code !=
            ((i == 0) ? RDMA_SC_DMA_TRANSLATION :
                        RDMA_SC_PCIE_COMPLETION) ||
          composite_rollback_statuses[i].hardware_code !=
            32'hc0a3_7000 + i ||
          composite_rollback_statuses[i].hardware_code_valid != (i == 0) ||
          composite_rollback_statuses[i].source_engine !=
            ((i == 0) ? RDMA_ENGINE_DMA : RDMA_ENGINE_PCIE) ||
          composite_rollback_statuses[i].function_uid !=
            composite_recovery_binding.function_uid ||
          composite_rollback_statuses[i].generation !=
            composite_recovery_binding.generation ||
          composite_rollback_statuses[i].resource_id !=
            64'hc0a3_8000_0000_0000 + i ||
          composite_rollback_statuses[i].command_id !=
            64'hc0a3_9000_0000_0000 + i ||
          composite_rollback_statuses[i].wr_id !=
            64'hc0a3_a000_0000_0000 + i ||
          composite_rollback_statuses[i].severity !=
            ((i == 0) ? RDMA_SEVERITY_WARNING : RDMA_SEVERITY_ERROR) ||
          composite_rollback_statuses[i].retryable != (i == 0) ||
          composite_rollback_statuses[i].message !=
            $sformatf("composite rollback c0a3 %0d", i))
        `uvm_error("COMPOSITE_RECOVERY_ROLLBACK_SOURCE",
                   $sformatf("rollback status[%0d] changed/dispatched", i))
    end
    expect_status(
      "COMPOSITE_RECOVERY_LOOKUP",
      composite_recovery_rm.lookup_recovery(composite_recovery_resource,
                                            recovery_lookup),
      RDMA_SC_OK
    );
    composite_recovery_leak = null;
    composite_handle_leak = null;
    composite_ticket_leak = null;
    composite_function_handle_leak = null;
    composite_opcode_leak = null;
    composite_status_leak = null;
    if (recovery_lookup == null ||
        $cast(composite_recovery_leak, recovery_lookup) ||
        $cast(composite_handle_leak, recovery_lookup.resource_h) ||
        $cast(composite_ticket_leak, recovery_lookup.ambiguous_ticket) ||
        $cast(composite_function_handle_leak,
              recovery_lookup.ambiguous_ticket.function_h) ||
        $cast(composite_handle_leak,
              recovery_lookup.ambiguous_ticket.cmq_h) ||
        $cast(composite_opcode_leak,
              recovery_lookup.ambiguous_ticket.opcode_key) ||
        $cast(composite_status_leak, recovery_lookup.primary_status) ||
        recovery_lookup == composite_recovery ||
        recovery_lookup.resource_h == composite_recovery_resource ||
        recovery_lookup.ambiguous_ticket == composite_recovery_ticket ||
        recovery_lookup.ambiguous_ticket.function_h ==
          composite_ticket_function ||
        recovery_lookup.ambiguous_ticket.cmq_h == composite_ticket_cmq ||
        recovery_lookup.ambiguous_ticket.opcode_key ==
          composite_ticket_opcode ||
        recovery_lookup.primary_status == composite_primary_status ||
        !same_handle_fields(recovery_lookup.resource_h,
                            composite_recovery_resource) ||
        recovery_lookup.hardware_presence != RDMA_HW_PRESENCE_UNKNOWN ||
        recovery_lookup.completed_steps.size() != 2 ||
        recovery_lookup.completed_steps[0] !=
          RDMA_CTRL_STEP_RESOURCE_RESERVED ||
        recovery_lookup.completed_steps[1] !=
          RDMA_CTRL_STEP_REGISTRY_PROGRAMMED ||
        recovery_lookup.pending_steps.size() != 2 ||
        recovery_lookup.pending_steps[0] != RDMA_CTRL_STEP_HW_DRAINED ||
        recovery_lookup.pending_steps[1] != RDMA_CTRL_STEP_BACKING_RELEASED ||
        recovery_lookup.ambiguous_ticket.command_id !=
          composite_recovery_ticket.command_id ||
        recovery_lookup.ambiguous_ticket.slot_sequence !=
          composite_recovery_ticket.slot_sequence ||
        recovery_lookup.ambiguous_ticket.sq_index !=
          composite_recovery_ticket.sq_index ||
        recovery_lookup.ambiguous_ticket.sq_wrap !=
          composite_recovery_ticket.sq_wrap ||
        recovery_lookup.ambiguous_ticket.absolute_deadline !=
          composite_recovery_ticket.absolute_deadline ||
        !same_handle_fields(recovery_lookup.ambiguous_ticket.function_h,
                            composite_ticket_function) ||
        !same_handle_fields(recovery_lookup.ambiguous_ticket.cmq_h,
                            composite_ticket_cmq) ||
        recovery_lookup.ambiguous_ticket.opcode_key.profile_name !=
          composite_ticket_opcode.profile_name ||
        recovery_lookup.ambiguous_ticket.opcode_key.opcode !=
          composite_ticket_opcode.opcode ||
        recovery_lookup.ambiguous_ticket.opcode_key.variant !=
          composite_ticket_opcode.variant ||
        !same_status_fields(recovery_lookup.primary_status,
                            composite_primary_status) ||
        recovery_lookup.rollback_statuses.size() != 2)
      `uvm_error("COMPOSITE_RECOVERY_LOOKUP_ROOT",
                 "recovery projection lost subtype, detachment, or fields")
    foreach (composite_rollback_statuses[i]) begin
      composite_status_leak = null;
      if ($cast(composite_status_leak,
                recovery_lookup.rollback_statuses[i]) ||
          recovery_lookup.rollback_statuses[i] ==
            composite_rollback_statuses[i] ||
          !same_status_fields(recovery_lookup.rollback_statuses[i],
                              composite_rollback_statuses[i]))
        `uvm_error("COMPOSITE_RECOVERY_ROLLBACK_LOOKUP",
                   $sformatf("rollback status[%0d] lost order/fields", i))
    end
    expect_status("COMPOSITE_RECOVERY_RELEASE",
                  composite_recovery_rm.release_function(
                    composite_recovery_binding.make_handle()
                  ), RDMA_SC_OK);
    expect_status("COMPOSITE_RECOVERY_NO_LEAKS",
                  composite_recovery_rm.check_leaks(leak_count), RDMA_SC_OK);
    if (composite_recovery.clone_calls != 0 ||
        composite_recovery_resource.clone_calls != 0 ||
        composite_recovery_ticket.clone_calls != 0 ||
        composite_ticket_function.clone_calls != 0 ||
        composite_ticket_cmq.clone_calls != 0 ||
        composite_ticket_opcode.clone_calls != 0 ||
        composite_primary_status.clone_calls != 0 ||
        composite_recovery_resource.kind != composite_recovery_pd.handle.kind ||
        composite_recovery_resource.function_uid !=
          composite_recovery_pd.handle.function_uid ||
        composite_recovery_resource.object_id !=
          composite_recovery_pd.handle.object_id ||
        composite_recovery_resource.generation !=
          composite_recovery_pd.handle.generation)
      `uvm_error("COMPOSITE_RECOVERY_POST_LIFECYCLE_HOOKS",
                 "recovery lifecycle invoked a hook or changed its handle")
    foreach (composite_rollback_statuses[i]) begin
      if (composite_rollback_statuses[i].clone_calls != 0)
        `uvm_error("COMPOSITE_RECOVERY_ROLLBACK_HOOKS",
                   $sformatf("rollback status[%0d] hook ran", i))
    end

    // Controlled lifecycle publication keeps the registry authoritative and
    // detached from every candidate and lookup snapshot.
    lifecycle_rm = rdma_resource_manager::type_id::create("lifecycle_rm");
    lifecycle_binding = make_active_binding(
      "lifecycle_binding", 64'h1c1f_0000_0000_0001,
      32'h1c1f_0101, 32'd17
    );
    expect_status("LIFECYCLE_CREATE_PD",
                  lifecycle_rm.create_pd(lifecycle_binding, lifecycle_pd),
                  RDMA_SC_OK);
    expect_status("LIFECYCLE_ACTIVATE_NULL",
                  lifecycle_rm.activate(null), RDMA_SC_INVALID_ARGUMENT);
    expect_status("LIFECYCLE_PD_ACTIVATE",
                  lifecycle_rm.activate(lifecycle_pd.handle), RDMA_SC_OK);
    expect_status("LIFECYCLE_PD_ACTIVATE_AGAIN",
                  lifecycle_rm.activate(lifecycle_pd.handle),
                  RDMA_SC_INVALID_STATE);
    expect_status("LIFECYCLE_QUIESCE_NULL",
                  lifecycle_rm.begin_quiesce(null),
                  RDMA_SC_INVALID_ARGUMENT);
    expect_status("LIFECYCLE_RESTORE_NULL",
                  lifecycle_rm.restore_active(null),
                  RDMA_SC_INVALID_ARGUMENT);
    expect_status("LIFECYCLE_FINALIZE_NULL",
                  lifecycle_rm.finalize_release(null),
                  RDMA_SC_INVALID_ARGUMENT);
    expect_status("LIFECYCLE_RELEASE_RESERVED_NULL",
                  lifecycle_rm.release_reserved(null),
                  RDMA_SC_INVALID_ARGUMENT);
    expect_status("LIFECYCLE_CREATE_MR",
                  lifecycle_rm.create_mr(lifecycle_binding,
                                          lifecycle_pd.handle,
                                          lifecycle_mr),
                  RDMA_SC_OK);
    expect_status("LIFECYCLE_PD_BUSY",
                  lifecycle_rm.begin_quiesce(lifecycle_pd.handle),
                  RDMA_SC_RESOURCE_BUSY);
    expect_status("LIFECYCLE_PD_BUSY_STATE",
                  lifecycle_rm.lookup(lifecycle_pd.handle, resource),
                  RDMA_SC_OK);
    if (resource == null || resource.state != RDMA_RESOURCE_ACTIVE)
      `uvm_error("LIFECYCLE_PD_BUSY_STATE",
                 "busy quiesce changed the PD state")

    lifecycle_mr.iova.value = 64'h1000_0000;
    lifecycle_mr.length = 64'h2000;
    lifecycle_mr.lkey = {lifecycle_mr.local_mr_id[23:0], 8'h5a};
    lifecycle_mr.rkey = lifecycle_mr.lkey;
    lifecycle_mr.access = '{local_write:1'b1, remote_read:1'b1,
                            remote_write:1'b0, memory_window_bind:1'b0,
                            remote_atomic:1'b0};
    lifecycle_mr_h = clone_handle("LIFECYCLE_MR_H", lifecycle_mr.handle);
    expect_status("LIFECYCLE_COMMIT_NULL",
                  lifecycle_rm.commit_programmed(null),
                  RDMA_SC_INVALID_ARGUMENT);
    expect_status("LIFECYCLE_COMMIT_BEFORE_STAGE",
                  lifecycle_rm.commit_programmed(lifecycle_mr),
                  RDMA_SC_INVALID_STATE);
    expect_status("LIFECYCLE_ACTIVATE_ALLOCATED_MR",
                  lifecycle_rm.activate(lifecycle_mr.handle),
                  RDMA_SC_INVALID_STATE);
    expect_status("LIFECYCLE_STAGE_NULL",
                  lifecycle_rm.stage_allocated(null),
                  RDMA_SC_INVALID_ARGUMENT);
    wrong_stage_pd = rdma_pd::type_id::create("wrong_stage_pd");
    wrong_stage_pd.handle = clone_handle("WRONG_STAGE_H",
                                         lifecycle_mr.handle);
    wrong_stage_pd.owner = clone_function_handle("WRONG_STAGE_OWNER",
                                                  lifecycle_mr.owner);
    wrong_stage_pd.state = RDMA_RESOURCE_ALLOCATED;
    expect_status("LIFECYCLE_STAGE_WRONG_TYPE",
                  lifecycle_rm.stage_allocated(wrong_stage_pd),
                  RDMA_SC_INVALID_ARGUMENT);
    lifecycle_mr.handle.object_id++;
    expect_status("LIFECYCLE_STAGE_WRONG_INCARCATION",
                  lifecycle_rm.stage_allocated(lifecycle_mr),
                  RDMA_SC_INVALID_ARGUMENT);
    lifecycle_mr.handle = lifecycle_mr_h;
    lifecycle_mr.state = RDMA_RESOURCE_PROGRAMMED;
    expect_status("LIFECYCLE_STAGE_WRONG_STATE",
                  lifecycle_rm.stage_allocated(lifecycle_mr),
                  RDMA_SC_INVALID_STATE);
    lifecycle_mr.state = RDMA_RESOURCE_ALLOCATED;
    lifecycle_mr.outstanding_ids.push_back(64'hfeed);
    expect_status("LIFECYCLE_STAGE_INJECT_OUTSTANDING",
                  lifecycle_rm.stage_allocated(lifecycle_mr),
                  RDMA_SC_INVALID_ARGUMENT);
    lifecycle_mr.outstanding_ids.delete();
    expect_status("LIFECYCLE_STAGE",
                  lifecycle_rm.stage_allocated(lifecycle_mr), RDMA_SC_OK);
    lifecycle_mr.length = 64'h4000;
    expect_status("LIFECYCLE_STAGE_LOOKUP",
                  lifecycle_rm.lookup(lifecycle_mr.handle, resource),
                  RDMA_SC_OK);
    if (resource == null || resource.state != RDMA_RESOURCE_ALLOCATED ||
        !$cast(width_mr_failed, resource) ||
        width_mr_failed.length != 64'h2000)
      `uvm_error("LIFECYCLE_STAGE_LOOKUP",
                 "stage did not publish a detached ALLOCATED snapshot")
    expect_status("LIFECYCLE_COMMIT_WRONG_TYPE",
                  lifecycle_rm.commit_programmed(wrong_stage_pd),
                  RDMA_SC_INVALID_ARGUMENT);
    lifecycle_mr.state = RDMA_RESOURCE_PROGRAMMED;
    expect_status("LIFECYCLE_COMMIT_WRONG_STATE",
                  lifecycle_rm.commit_programmed(lifecycle_mr),
                  RDMA_SC_INVALID_STATE);
    lifecycle_mr.state = RDMA_RESOURCE_ALLOCATED;
    lifecycle_mr.length = 0;
    expect_status("LIFECYCLE_COMMIT_INVALID",
                  lifecycle_rm.commit_programmed(lifecycle_mr),
                  RDMA_SC_INVALID_ARGUMENT);
    expect_status("LIFECYCLE_COMMIT_INVALID_STATE_PRESERVED",
                  lifecycle_rm.lookup(lifecycle_mr.handle, resource),
                  RDMA_SC_OK);
    if (resource == null || resource.state != RDMA_RESOURCE_ALLOCATED)
      `uvm_error("LIFECYCLE_COMMIT_INVALID_STATE_PRESERVED",
                 "invalid commit mutated the staged registry state")
    lifecycle_mr.length = 64'h2000;
    expect_status("LIFECYCLE_PROGRAM",
                  lifecycle_rm.commit_programmed(lifecycle_mr), RDMA_SC_OK);
    lifecycle_mr.length = 64'h8000;
    expect_status("LIFECYCLE_PROGRAM_LOOKUP",
                  lifecycle_rm.lookup(lifecycle_mr.handle, resource),
                  RDMA_SC_OK);
    if (resource == null || resource.state != RDMA_RESOURCE_PROGRAMMED ||
        !$cast(width_mr_failed, resource) ||
        width_mr_failed.length != 64'h2000)
      `uvm_error("LIFECYCLE_PROGRAM_LOOKUP",
                 "commit did not publish a detached PROGRAMMED snapshot")
    expect_status("LIFECYCLE_MR_ACTIVATE",
                  lifecycle_rm.activate(lifecycle_mr.handle), RDMA_SC_OK);
    expect_status("LIFECYCLE_RELEASE_ACTIVE",
                  lifecycle_rm.release_reserved(lifecycle_mr.handle),
                  RDMA_SC_INVALID_STATE);
    expect_status("LIFECYCLE_COMPAT_RELEASE_ACTIVE",
                  lifecycle_rm.\release (lifecycle_mr.handle),
                  RDMA_SC_INVALID_STATE);
    expect_status("LIFECYCLE_COMPAT_FREEZE_ACTIVE",
                  lifecycle_rm.freeze(lifecycle_mr.handle),
                  RDMA_SC_INVALID_STATE);

    expect_status("OUTSTANDING_ZERO",
                  lifecycle_rm.track_outstanding(lifecycle_mr.handle, 0),
                  RDMA_SC_INVALID_ARGUMENT);
    expect_status("OUTSTANDING_TRACK_NULL",
                  lifecycle_rm.track_outstanding(null, 64'h1234),
                  RDMA_SC_INVALID_ARGUMENT);
    expect_status("OUTSTANDING_RETIRE_NULL",
                  lifecycle_rm.retire_outstanding(null, 64'h1234),
                  RDMA_SC_INVALID_ARGUMENT);
    expect_status("OUTSTANDING_TRACK",
                  lifecycle_rm.track_outstanding(lifecycle_mr.handle,
                                                  64'h1234),
                  RDMA_SC_OK);
    expect_status("OUTSTANDING_DUPLICATE",
                  lifecycle_rm.track_outstanding(lifecycle_mr.handle,
                                                  64'h1234),
                  RDMA_SC_INVALID_ARGUMENT);
    expect_status("OUTSTANDING_LOOKUP",
                  lifecycle_rm.lookup(lifecycle_mr.handle, resource),
                  RDMA_SC_OK);
    if (resource == null || resource.outstanding_ids.size() != 1 ||
        resource.outstanding_ids[0] != 64'h1234)
      `uvm_error("OUTSTANDING_LOOKUP",
                 "registry did not authoritatively track one unique ID")
    expect_status("OUTSTANDING_QUIESCE_BUSY",
                  lifecycle_rm.begin_quiesce(lifecycle_mr.handle),
                  RDMA_SC_RESOURCE_BUSY);
    expect_status("OUTSTANDING_RETIRE_UNKNOWN",
                  lifecycle_rm.retire_outstanding(lifecycle_mr.handle,
                                                   64'h9999),
                  RDMA_SC_INVALID_ARGUMENT);
    expect_status("OUTSTANDING_RETIRE",
                  lifecycle_rm.retire_outstanding(lifecycle_mr.handle,
                                                   64'h1234),
                  RDMA_SC_OK);
    expect_status("OUTSTANDING_QUIESCE",
                  lifecycle_rm.begin_quiesce(lifecycle_mr.handle),
                  RDMA_SC_OK);
    expect_status("OUTSTANDING_TRACK_QUIESCING",
                  lifecycle_rm.track_outstanding(lifecycle_mr.handle,
                                                  64'h5678),
                  RDMA_SC_INVALID_STATE);
    expect_status("LIFECYCLE_RESTORE",
                  lifecycle_rm.restore_active(lifecycle_mr.handle),
                  RDMA_SC_OK);
    expect_status("LIFECYCLE_RESTORE_ACTIVE",
                  lifecycle_rm.restore_active(lifecycle_mr.handle),
                  RDMA_SC_INVALID_STATE);
    expect_status("LIFECYCLE_MR_QUIESCE",
                  lifecycle_rm.begin_quiesce(lifecycle_mr.handle),
                  RDMA_SC_OK);
    expect_status("LIFECYCLE_MR_FINALIZE",
                  lifecycle_rm.finalize_release(lifecycle_mr.handle),
                  RDMA_SC_OK);
    expect_status("LIFECYCLE_PD_QUIESCE",
                  lifecycle_rm.begin_quiesce(lifecycle_pd.handle),
                  RDMA_SC_OK);
    expect_status("LIFECYCLE_PD_FINALIZE",
                  lifecycle_rm.finalize_release(lifecycle_pd.handle),
                  RDMA_SC_OK);
    expect_status("LIFECYCLE_CREATE_ROLLBACK",
                  lifecycle_rm.create_aeq(lifecycle_binding, rollback_aeq),
                  RDMA_SC_OK);
    expect_status("LIFECYCLE_RELEASE_RESERVED",
                  lifecycle_rm.release_reserved(rollback_aeq.handle),
                  RDMA_SC_OK);
    expect_status("LIFECYCLE_RELEASE_RESERVED_AGAIN",
                  lifecycle_rm.release_reserved(rollback_aeq.handle),
                  RDMA_SC_INVALID_STATE);

    // ERROR owns a detached recovery record.  Neither normal release nor
    // clearing a completed record may bypass the recovery release gate.
    recovery_rm = rdma_resource_manager::type_id::create("recovery_rm");
    recovery_binding = make_active_binding(
      "recovery_binding", 64'he220_0000_0000_0001,
      32'he220_0101, 32'd22
    );
    expect_status("RECOVERY_CREATE_PD",
                  recovery_rm.create_pd(recovery_binding, recovery_pd),
                  RDMA_SC_OK);
    expect_status("RECOVERY_ACTIVATE_PD",
                  recovery_rm.activate(recovery_pd.handle), RDMA_SC_OK);
    recovery_record = rdma_recovery_record::type_id::create(
      "recovery_record"
    );
    recovery_record.resource_h = clone_handle("RECOVERY_RECORD_H",
                                               recovery_pd.handle);
    recovery_record.hardware_presence = RDMA_HW_PRESENCE_PRESENT;
    recovery_record.pending_steps.push_back(RDMA_CTRL_STEP_HW_DRAINED);
    recovery_record.primary_status = rdma_status::make(
      RDMA_SC_TIMEOUT, "hardware state is ambiguous"
    );
    malformed_recovery = rdma_recovery_record::type_id::create(
      "malformed_recovery"
    );
    malformed_recovery.copy(recovery_record);
    expect_status("RECOVERY_MARK_NULL_HANDLE",
                  recovery_rm.mark_error(null, recovery_record),
                  RDMA_SC_INVALID_ARGUMENT);
    expect_status("RECOVERY_MARK_NULL_RECORD",
                  recovery_rm.mark_error(recovery_pd.handle, null),
                  RDMA_SC_INVALID_ARGUMENT);
    expect_status("RECOVERY_LOOKUP_NULL",
                  recovery_rm.lookup_recovery(null, recovery_lookup),
                  RDMA_SC_INVALID_ARGUMENT);
    expect_status("RECOVERY_LOOKUP_MISSING",
                  recovery_rm.lookup_recovery(recovery_pd.handle,
                                              recovery_lookup),
                  RDMA_SC_INVALID_STATE);
    malformed_recovery.primary_status = null;
    expect_status("RECOVERY_MARK_MALFORMED",
                  recovery_rm.mark_error(recovery_pd.handle,
                                         malformed_recovery),
                  RDMA_SC_INVALID_ARGUMENT);
    malformed_recovery.copy(recovery_record);
    malformed_recovery.resource_h.object_id++;
    expect_status("RECOVERY_MARK_MISMATCH",
                  recovery_rm.mark_error(recovery_pd.handle,
                                         malformed_recovery),
                  RDMA_SC_INVALID_ARGUMENT);
    expect_status("RECOVERY_MALFORMED_STATE_PRESERVED",
                  recovery_rm.lookup(recovery_pd.handle, resource),
                  RDMA_SC_OK);
    if (resource == null || resource.state != RDMA_RESOURCE_ACTIVE)
      `uvm_error("RECOVERY_MALFORMED_STATE_PRESERVED",
                 "malformed recovery changed resource state")
    expect_status("RECOVERY_MARK_ERROR",
                  recovery_rm.mark_error(recovery_pd.handle,
                                         recovery_record),
                  RDMA_SC_OK);
    recovery_record.hardware_presence = RDMA_HW_PRESENCE_ABSENT;
    recovery_record.pending_steps.delete();
    expect_status("RECOVERY_LOOKUP",
                  recovery_rm.lookup_recovery(recovery_pd.handle,
                                              recovery_lookup),
                  RDMA_SC_OK);
    if (recovery_lookup == null ||
        recovery_lookup.hardware_presence != RDMA_HW_PRESENCE_PRESENT ||
        recovery_lookup.pending_steps.size() != 1)
      `uvm_error("RECOVERY_LOOKUP",
                 "mark_error did not retain a detached recovery record")
    recovery_lookup.hardware_presence = RDMA_HW_PRESENCE_ABSENT;
    recovery_lookup.pending_steps.delete();
    expect_status("RECOVERY_LOOKUP_AGAIN",
                  recovery_rm.lookup_recovery(recovery_pd.handle,
                                              recovery_lookup_again),
                  RDMA_SC_OK);
    if (recovery_lookup_again == null ||
        recovery_lookup_again.hardware_presence != RDMA_HW_PRESENCE_PRESENT ||
        recovery_lookup_again.pending_steps.size() != 1)
      `uvm_error("RECOVERY_LOOKUP_AGAIN",
                 "caller mutation reached recovery side-table state")
    expect_status("RECOVERY_ERROR_LOOKUP",
                  recovery_rm.lookup(recovery_pd.handle, resource),
                  RDMA_SC_OK);
    if (resource == null || resource.state != RDMA_RESOURCE_ERROR)
      `uvm_error("RECOVERY_ERROR_LOOKUP",
                 "mark_error did not publish ERROR state")
    expect_status("RECOVERY_ERROR_ACTIVATE",
                  recovery_rm.activate(recovery_pd.handle),
                  RDMA_SC_INVALID_STATE);
    expect_status("RECOVERY_ERROR_RELEASE_RESERVED",
                  recovery_rm.release_reserved(recovery_pd.handle),
                  RDMA_SC_INVALID_STATE);
    expect_status("RECOVERY_ERROR_COMPAT_RELEASE",
                  recovery_rm.\release (recovery_pd.handle),
                  RDMA_SC_RECOVERY_REQUIRED);
    expect_status("RECOVERY_ERROR_FINALIZE_PRESENT",
                  recovery_rm.finalize_release(recovery_pd.handle),
                  RDMA_SC_RECOVERY_REQUIRED);
    expect_status("RECOVERY_CLEAR_INCOMPLETE",
                  recovery_rm.clear_recovery(recovery_pd.handle),
                  RDMA_SC_RECOVERY_REQUIRED);
    expect_status("RECOVERY_INCOMPLETE_RETAINED",
                  recovery_rm.lookup_recovery(recovery_pd.handle,
                                              recovery_lookup),
                  RDMA_SC_OK);

    ready_recovery = rdma_recovery_record::type_id::create(
      "ready_recovery"
    );
    ready_recovery.resource_h = clone_handle("READY_RECOVERY_H",
                                              recovery_pd.handle);
    ready_recovery.hardware_presence = RDMA_HW_PRESENCE_ABSENT;
    ready_recovery.primary_status = rdma_status::make(
      RDMA_SC_TIMEOUT, "hardware absence confirmed"
    );
    ready_recovery.pending_steps.push_back(RDMA_CTRL_STEP_HW_DRAINED);
    expect_status("RECOVERY_REMARK_PENDING_ONLY",
                  recovery_rm.mark_error(recovery_pd.handle,
                                         ready_recovery),
                  RDMA_SC_OK);
    expect_status("RECOVERY_FINALIZE_PENDING_ONLY",
                  recovery_rm.finalize_release(recovery_pd.handle),
                  RDMA_SC_RECOVERY_REQUIRED);
    ready_recovery.pending_steps.delete();
    ready_recovery.hardware_presence = RDMA_HW_PRESENCE_PRESENT;
    expect_status("RECOVERY_REMARK_PRESENT_ONLY",
                  recovery_rm.mark_error(recovery_pd.handle,
                                         ready_recovery),
                  RDMA_SC_OK);
    expect_status("RECOVERY_FINALIZE_PRESENT_ONLY",
                  recovery_rm.finalize_release(recovery_pd.handle),
                  RDMA_SC_RECOVERY_REQUIRED);
    ready_recovery.hardware_presence = RDMA_HW_PRESENCE_ABSENT;
    expect_status("RECOVERY_REMARK_READY",
                  recovery_rm.mark_error(recovery_pd.handle,
                                         ready_recovery),
                  RDMA_SC_OK);
    expect_status("RECOVERY_CLEAR_READY",
                  recovery_rm.clear_recovery(recovery_pd.handle),
                  RDMA_SC_OK);
    expect_status("RECOVERY_CLEARED_LOOKUP",
                  recovery_rm.lookup_recovery(recovery_pd.handle,
                                              recovery_lookup),
                  RDMA_SC_INVALID_STATE);
    expect_status("RECOVERY_CLEAR_NO_BYPASS",
                  recovery_rm.finalize_release(recovery_pd.handle),
                  RDMA_SC_RECOVERY_REQUIRED);
    expect_status("RECOVERY_REATTACH_READY",
                  recovery_rm.mark_error(recovery_pd.handle,
                                         ready_recovery),
                  RDMA_SC_OK);
    expect_status("RECOVERY_FINALIZE",
                  recovery_rm.finalize_release(recovery_pd.handle),
                  RDMA_SC_OK);
    expect_status("RECOVERY_RELEASED_LOOKUP",
                  recovery_rm.lookup(recovery_pd.handle, resource),
                  RDMA_SC_INVALID_STATE);

    // Function retirement is the privileged reset boundary: its complete
    // dependency-order preflight supplies hardware invalidation authority and
    // may force an incomplete ERROR topology down without weakening any
    // ordinary per-resource gate.
    privileged_recovery_rm = new("privileged_recovery_rm");
    privileged_recovery_binding = make_active_binding(
      "privileged_recovery_binding", 64'he220_0000_0000_0003,
      32'he220_0303, 32'd41
    );
    privileged_recovery_owner = privileged_recovery_binding.make_handle();
    expect_status("PRIV_RECOVERY_CREATE",
                  privileged_recovery_rm.create_pd(
                    privileged_recovery_binding, privileged_recovery_pd
                  ), RDMA_SC_OK);
    expect_status("PRIV_RECOVERY_ACTIVATE",
                  privileged_recovery_rm.activate(
                    privileged_recovery_pd.handle
                  ), RDMA_SC_OK);
    recovery_record = rdma_recovery_record::type_id::create(
      "privileged_unknown_recovery"
    );
    recovery_record.resource_h = clone_handle(
      "PRIV_RECOVERY_H", privileged_recovery_pd.handle
    );
    recovery_record.hardware_presence = RDMA_HW_PRESENCE_UNKNOWN;
    recovery_record.pending_steps.push_back(RDMA_CTRL_STEP_HW_DRAINED);
    recovery_record.primary_status = rdma_status::make(
      RDMA_SC_TIMEOUT, "reset owns ambiguous hardware invalidation"
    );
    expect_status("PRIV_RECOVERY_MARK",
                  privileged_recovery_rm.mark_error(
                    privileged_recovery_pd.handle, recovery_record
                  ), RDMA_SC_OK);
    expect_status("PRIV_RECOVERY_ORDINARY_FINALIZE",
                  privileged_recovery_rm.finalize_release(
                    privileged_recovery_pd.handle
                  ), RDMA_SC_RECOVERY_REQUIRED);
    expect_status("PRIV_RECOVERY_FUNCTION_RELEASE",
                  privileged_recovery_rm.release_function(
                    privileged_recovery_owner
                  ), RDMA_SC_OK);
    expect_status("PRIV_RECOVERY_NO_LEAKS",
                  privileged_recovery_rm.check_leaks(
                    leak_count, privileged_recovery_owner
                  ), RDMA_SC_OK);
    if (privileged_recovery_rm.observed_recovery_count() != 0)
      `uvm_error("PRIV_RECOVERY_NO_LEAKS",
                 "privileged ERROR teardown leaked recovery metadata")
    expect_status("PRIV_RECOVERY_RECORD_RETIRED",
                  privileged_recovery_rm.lookup_recovery(
                    privileged_recovery_pd.handle, recovery_lookup
                  ), RDMA_SC_STALE_GENERATION);
    privileged_recovery_binding.generation++;
    privileged_recovery_binding.owner_h =
      privileged_recovery_binding.make_handle();
    expect_status("PRIV_RECOVERY_ID_REUSE",
                  privileged_recovery_rm.create_pd(
                    privileged_recovery_binding,
                    privileged_recovery_pd_reused
                  ), RDMA_SC_OK);
    if (privileged_recovery_pd_reused == null ||
        privileged_recovery_pd_reused.local_pd_id !=
          privileged_recovery_pd.local_pd_id ||
        privileged_recovery_pd_reused.handle.same_instance(
          privileged_recovery_pd.handle
        ))
      `uvm_error("PRIV_RECOVERY_ID_REUSE",
                 "privileged ERROR teardown leaked ID/incarnation state")
    expect_status("PRIV_RECOVERY_RELEASE_NEXT",
                  privileged_recovery_rm.release_function(
                    privileged_recovery_binding.make_handle()
                  ), RDMA_SC_OK);

    // Only mark_error receives the exact-key stale-generation exception.
    // Other public operations retain ordinary live-binding authority checks.
    stale_recovery_rm = rdma_resource_manager::type_id::create(
      "stale_recovery_rm"
    );
    stale_recovery_binding = make_active_binding(
      "stale_recovery_binding", 64'he220_0000_0000_0002,
      32'he220_0202, 32'd31
    );
    stale_recovery_owner = stale_recovery_binding.make_handle();
    expect_status("STALE_RECOVERY_CREATE",
                  stale_recovery_rm.create_pd(stale_recovery_binding,
                                               stale_recovery_pd),
                  RDMA_SC_OK);
    stale_recovery_h = clone_handle("STALE_RECOVERY_H",
                                    stale_recovery_pd.handle);
    ready_recovery = rdma_recovery_record::type_id::create(
      "stale_ready_recovery"
    );
    ready_recovery.resource_h = clone_handle("STALE_READY_H",
                                              stale_recovery_h);
    ready_recovery.hardware_presence = RDMA_HW_PRESENCE_ABSENT;
    ready_recovery.primary_status = rdma_status::make(
      RDMA_SC_RESET_CANCELLED, "Function generation advanced"
    );
    stale_recovery_binding.generation++;
    stale_recovery_binding.owner_h = stale_recovery_binding.make_handle();
    expect_status("STALE_RECOVERY_MARK_EXCEPTION",
                  stale_recovery_rm.mark_error(stale_recovery_h,
                                                ready_recovery),
                  RDMA_SC_OK);
    expect_status("STALE_RECOVERY_ORDINARY_LOOKUP",
                  stale_recovery_rm.lookup(stale_recovery_h, resource),
                  RDMA_SC_STALE_GENERATION);
    expect_status("STALE_RECOVERY_ACTIVATE",
                  stale_recovery_rm.activate(stale_recovery_h),
                  RDMA_SC_STALE_GENERATION);
    expect_status("STALE_RECOVERY_RECORD_LOOKUP",
                  stale_recovery_rm.lookup_recovery(stale_recovery_h,
                                                    recovery_lookup),
                  RDMA_SC_STALE_GENERATION);
    expect_status("STALE_RECOVERY_CLEAR",
                  stale_recovery_rm.clear_recovery(stale_recovery_h),
                  RDMA_SC_STALE_GENERATION);
    expect_status("STALE_RECOVERY_FINALIZE",
                  stale_recovery_rm.finalize_release(stale_recovery_h),
                  RDMA_SC_STALE_GENERATION);
    expect_status("STALE_RECOVERY_PRIVILEGED_TEARDOWN",
                  stale_recovery_rm.release_function(stale_recovery_owner),
                  RDMA_SC_OK);
    expect_status("STALE_RECOVERY_NO_LEAKS",
                  stale_recovery_rm.check_leaks(leak_count,
                                                stale_recovery_owner),
                  RDMA_SC_OK);

    // Required minimal stale-generation scenario.
    rm = rdma_resource_manager::type_id::create("rm_stale");
    active_binding = make_active_binding("active_binding");
    s = rm.create_pd(active_binding, pd);
    old_h = clone_handle("RM", pd.handle);
    expect_status("RM_CREATE_PD", s, RDMA_SC_OK);
    s = rm.\release (pd.handle);
    expect_status("RM_RELEASE_PD", s, RDMA_SC_OK);
    active_binding.generation++;
    s = rm.lookup(old_h, resource);
    expect_status("RM_STALE_GENERATION", s, RDMA_SC_STALE_GENERATION);

    // Local IDs are recycled independently by kind, while the opaque global
    // incarnation in object_id is never recycled within a generation.
    rm = rdma_resource_manager::type_id::create("rm_id_pool");
    binding_a = make_active_binding("binding_a");
    expect_status("ID_CREATE_PD_FIRST",
                  rm.create_pd(binding_a, pd_first), RDMA_SC_OK);
    same_generation_old_h = clone_handle("ID_OLD_HANDLE", pd_first.handle);
    expect_status("ID_RELEASE_PD_FIRST", rm.\release (pd_first.handle),
                  RDMA_SC_OK);
    expect_status("ID_RELEASED_LOOKUP",
                  rm.lookup(same_generation_old_h, resource),
                  RDMA_SC_INVALID_STATE);
    expect_status("ID_CREATE_PD_REUSED",
                  rm.create_pd(binding_a, pd_reused), RDMA_SC_OK);
    if (pd_reused.local_pd_id != pd_first.local_pd_id)
      `uvm_error("ID_REUSE", "released PD local ID was not reused")
    if (pd_reused.handle.object_id == same_generation_old_h.object_id ||
        pd_reused.global_pd_id != pd_reused.handle.object_id ||
        pd_reused.handle.same_instance(same_generation_old_h))
      `uvm_error("ID_INCAR",
                 "reused local ID did not receive a new incarnation")
    expect_status("ID_OLD_LOOKUP_AFTER_REUSE",
                  rm.lookup(same_generation_old_h, resource),
                  RDMA_SC_INVALID_STATE);
    expect_status("ID_OLD_RELEASE_AFTER_REUSE",
                  rm.\release (same_generation_old_h),
                  RDMA_SC_INVALID_STATE);
    expect_status("ID_CREATE_CQ_POOL",
                  rm.create_cq(binding_a, null, cq_pool), RDMA_SC_OK);
    if (cq_pool.local_cq_id != pd_first.local_pd_id)
      `uvm_error("ID_KIND_POOL", "PD and CQ did not use independent pools")

    // Registry lookups are value based and return deep copies.
    expect_status("LOOKUP_CLONE",
                  rm.lookup(clone_handle("LOOKUP_CLONE_H",
                                         pd_reused.handle), resource),
                  RDMA_SC_OK);
    if (resource == null || resource == pd_reused ||
        resource.handle == pd_reused.handle)
      `uvm_error("LOOKUP_COPY", "lookup did not return a deep value copy")
    else begin
      resource.handle.object_id++;
      expect_status("LOOKUP_COPY_ISOLATION",
                    rm.lookup(pd_reused.handle, second_resource), RDMA_SC_OK);
      if (second_resource == null ||
          second_resource.handle.object_id != pd_reused.handle.object_id)
        `uvm_error("LOOKUP_COPY_ISOLATION",
                   "caller mutation reached the authoritative registry")
    end

    forged_h = clone_handle("FORGED_KIND", pd_reused.handle);
    forged_h.kind = RDMA_RESOURCE_CQ;
    expect_status("FORGED_KIND_LOOKUP", rm.lookup(forged_h, resource),
                  RDMA_SC_INVALID_ARGUMENT);
    forged_h = clone_handle("FORGED_OWNER", pd_reused.handle);
    forged_h.function_uid ^= 64'h1;
    expect_status("FORGED_OWNER_LOOKUP", rm.lookup(forged_h, resource),
                  RDMA_SC_INVALID_ARGUMENT);
    forged_h = clone_handle("FORGED_GENERATION", pd_reused.handle);
    forged_h.generation++;
    expect_status("FORGED_GENERATION_LOOKUP", rm.lookup(forged_h, resource),
                  RDMA_SC_STALE_GENERATION);
    forged_h = clone_handle("FORGED_OBJECT_ID", pd_reused.handle);
    forged_h.object_id++;
    expect_status("FORGED_OBJECT_ID_LOOKUP", rm.lookup(forged_h, resource),
                  RDMA_SC_INVALID_ARGUMENT);
    expect_status("ID_RELEASE_CQ", rm.\release (cq_pool.handle), RDMA_SC_OK);
    expect_status("ID_RELEASE_PD_REUSED", rm.\release (pd_reused.handle),
                  RDMA_SC_OK);
    expect_status("ID_REPEAT_RELEASE", rm.\release (pd_reused.handle),
                  RDMA_SC_INVALID_STATE);

    // Caller-owned bindings and published resources are never authoritative.
    // Only monotonic generation changes from the original binding reference
    // may affect lifecycle checks; identity and configuration are snapshots.
    snapshot_rm = rdma_resource_manager::type_id::create("snapshot_rm");
    snapshot_binding = make_active_binding(
      "snapshot_binding", 64'h5a5a_0000_0000_0001,
      32'h5a5a_0101, 32'd11
    );
    snapshot_binding.rdma_vf_id = 8'h22;
    snapshot_binding.vsi_id = 32'h5a5a_0303;
    snapshot_binding.pfvf_id = 32'h5a5a_0404;
    snapshot_bdf = snapshot_binding.pcie.bdf;
    expect_status("SNAPSHOT_CREATE_FUNCTION",
                  snapshot_rm.create_function(snapshot_binding,
                                              snapshot_function),
                  RDMA_SC_OK);
    if (snapshot_function == null ||
        snapshot_function.rdma_vf_id != 8'h22 ||
        snapshot_function.vsi_id != 32'h5a5a_0303 ||
        snapshot_function.pfvf_id != 32'h5a5a_0404)
      `uvm_error("SNAPSHOT_FUNCTION_LOGICAL_IDS",
                 "created Function omitted trusted logical identity fields")
    if (snapshot_function == null || snapshot_function.binding == null ||
        snapshot_function.binding.rdma_vf_id != 8'h22 ||
        snapshot_function.binding.vsi_id != 32'h5a5a_0303 ||
        snapshot_function.binding.pfvf_id != 32'h5a5a_0404)
      `uvm_error("SNAPSHOT_FUNCTION_NESTED_IDS",
                 "created Function binding omitted logical identity fields")
    owner_h = clone_function_handle("SNAPSHOT_OWNER",
                                    snapshot_function.owner);
    expect_status("SNAPSHOT_CREATE_PD",
                  snapshot_rm.create_pd(snapshot_binding, snapshot_pd),
                  RDMA_SC_OK);
    snapshot_pd_h = clone_handle("SNAPSHOT_PD_H", snapshot_pd.handle);
    expect_status("SNAPSHOT_CREATE_CQ",
                  snapshot_rm.create_cq(snapshot_binding, null, cq_pool),
                  RDMA_SC_OK);
    expect_status("SNAPSHOT_CREATE_QP",
                  snapshot_rm.create_qp(snapshot_binding,
                                        snapshot_pd.handle,
                                        cq_pool.handle, cq_pool.handle,
                                        null, snapshot_qp),
                  RDMA_SC_OK);
    snapshot_qp_h = clone_handle("SNAPSHOT_QP_H", snapshot_qp.handle);

    snapshot_function.handle.object_id++;
    snapshot_function.owner.object_id++;
    snapshot_function.binding.global_function_id++;
    snapshot_function.binding.pcie.bdf.bus++;
    snapshot_function.rdma_vf_id++;
    snapshot_function.vsi_id++;
    snapshot_function.pfvf_id++;
    snapshot_function.binding.rdma_vf_id++;
    snapshot_function.binding.vsi_id++;
    snapshot_function.binding.pfvf_id++;
    snapshot_qp.handle.object_id++;
    snapshot_qp.owner.object_id++;
    snapshot_qp.pd_h.object_id++;
    snapshot_qp.dependencies[0].object_id++;
    snapshot_pd.handle.object_id++;
    snapshot_binding.function_uid ^= 64'hffff;
    snapshot_binding.global_function_id++;
    snapshot_binding.host_id = 32'hffff_0001;
    snapshot_binding.pcie.bdf.bus++;
    snapshot_binding.rdma_vf_id++;
    snapshot_binding.vsi_id++;
    snapshot_binding.pfvf_id++;

    expect_status("SNAPSHOT_FUNCTION_LOOKUP",
                  snapshot_rm.lookup(owner_h, resource), RDMA_SC_OK);
    if (resource == null || !$cast(snapshot_function_lookup, resource)) begin
      `uvm_error("SNAPSHOT_FUNCTION_LOOKUP",
                 "Function lookup returned the wrong resource type")
    end
    else begin
      if (snapshot_function_lookup.rdma_vf_id != 8'h22 ||
          snapshot_function_lookup.vsi_id != 32'h5a5a_0303 ||
          snapshot_function_lookup.pfvf_id != 32'h5a5a_0404)
        `uvm_error("SNAPSHOT_FUNCTION_LOGICAL_IDS_LOOKUP",
                   "caller mutation changed Function logical identity")
      if (snapshot_function_lookup.binding == null ||
          snapshot_function_lookup.binding.function_uid !=
            64'h5a5a_0000_0000_0001 ||
          snapshot_function_lookup.binding.global_function_id !=
            32'h5a5a_0101 ||
          snapshot_function_lookup.binding.rdma_vf_id != 8'h22 ||
          snapshot_function_lookup.binding.vsi_id != 32'h5a5a_0303 ||
          snapshot_function_lookup.binding.pfvf_id != 32'h5a5a_0404 ||
          snapshot_function_lookup.binding.host_id != 0 ||
          snapshot_function_lookup.binding.pcie == null ||
          snapshot_function_lookup.binding.pcie.bdf != snapshot_bdf)
        `uvm_error("SNAPSHOT_FUNCTION_VALUE",
                   "caller mutation changed authoritative Function binding")
    end
    expect_status("SNAPSHOT_QP_LOOKUP",
                  snapshot_rm.lookup(snapshot_qp_h, resource), RDMA_SC_OK);
    if (resource == null || !$cast(snapshot_qp_lookup, resource)) begin
      `uvm_error("SNAPSHOT_QP_LOOKUP",
                 "QP lookup returned the wrong resource type")
    end
    else if (snapshot_qp_lookup.owner == null ||
             !snapshot_qp_lookup.owner.same_instance(owner_h) ||
             snapshot_qp_lookup.pd_h == null ||
             !snapshot_qp_lookup.pd_h.same_instance(snapshot_pd_h) ||
             snapshot_qp_lookup.dependencies.size() == 0 ||
             !snapshot_qp_lookup.dependencies[0].same_instance(snapshot_pd_h))
      `uvm_error("SNAPSHOT_QP_VALUE",
                 "caller mutation changed authoritative QP ownership")
    expect_status("SNAPSHOT_TEARDOWN",
                  snapshot_rm.release_function(owner_h), RDMA_SC_OK);
    expect_status("SNAPSHOT_RETIRED_LOOKUP",
                  snapshot_rm.lookup(snapshot_qp_h, resource),
                  RDMA_SC_STALE_GENERATION);

    // Generation observation is monotonic.  Seeing B makes A stale forever,
    // even if the caller later writes A back into the source binding.
    rollback_rm = rdma_resource_manager::type_id::create("rollback_rm");
    rollback_binding = make_active_binding(
      "rollback_binding", 64'hb011_bacc_0000_0001,
      32'hb011_0101, 32'd41
    );
    owner_h = rollback_binding.make_handle();
    expect_status("ROLLBACK_CREATE_A",
                  rollback_rm.create_pd(rollback_binding, rollback_pd),
                  RDMA_SC_OK);
    rollback_h = clone_handle("ROLLBACK_H", rollback_pd.handle);
    rollback_binding.generation = 32'd42;
    rollback_binding.owner_h = rollback_binding.make_handle();
    expect_status("ROLLBACK_A_STALE_AT_B",
                  rollback_rm.lookup(rollback_h, resource),
                  RDMA_SC_STALE_GENERATION);
    rollback_binding.generation = 32'd41;
    rollback_binding.owner_h = rollback_binding.make_handle();
    expect_status("ROLLBACK_A_STAYS_STALE",
                  rollback_rm.lookup(rollback_h, resource),
                  RDMA_SC_STALE_GENERATION);
    expect_status("ROLLBACK_PRIVILEGED_TEARDOWN",
                  rollback_rm.release_function(owner_h), RDMA_SC_OK);
    expect_status("ROLLBACK_REPEATED_TEARDOWN",
                  rollback_rm.release_function(owner_h),
                  RDMA_SC_STALE_GENERATION);

    // A new Function generation cannot be admitted while an older generation
    // still owns live resources.  Once the old generation is drained, the
    // local ID may be reused but the old cloned handle remains stale.
    generation_rm = rdma_resource_manager::type_id::create("generation_rm");
    binding_a = make_active_binding("generation_binding",
                                    64'h600d_0000_0000_0001,
                                    32'h600d_0001, 32'd31);
    owner_h = binding_a.make_handle();
    expect_status("GENERATION_CREATE_OLD",
                  generation_rm.create_pd(binding_a, generation_pd),
                  RDMA_SC_OK);
    generation_old_h = clone_handle("GENERATION_OLD_H",
                                    generation_pd.handle);
    binding_a.generation++;
    binding_a.owner_h = binding_a.make_handle();
    expect_status("GENERATION_REJECT_OVERLAP",
                  generation_rm.create_pd(binding_a,
                                          rejected_generation_pd),
                  RDMA_SC_INVALID_STATE);
    if (rejected_generation_pd != null)
      `uvm_error("GENERATION_REJECT_OVERLAP",
                 "overlapping Function generation returned a resource")
    expect_status("GENERATION_RELEASE_OLD",
                  generation_rm.release_function(owner_h), RDMA_SC_OK);
    expect_status("GENERATION_OLD_LOOKUP_RETIRED",
                  generation_rm.lookup(generation_old_h, resource),
                  RDMA_SC_STALE_GENERATION);
    expect_status("GENERATION_OLD_RELEASE_RETIRED",
                  generation_rm.\release (generation_old_h),
                  RDMA_SC_STALE_GENERATION);
    expect_status("GENERATION_OLD_TEARDOWN_RETIRED",
                  generation_rm.release_function(owner_h),
                  RDMA_SC_STALE_GENERATION);
    expect_status("GENERATION_CREATE_NEXT",
                  generation_rm.create_pd(binding_a, next_generation_pd),
                  RDMA_SC_OK);
    if (next_generation_pd == null) begin
      `uvm_error("GENERATION_REUSE",
                 "next Function generation returned no resource")
    end
    else if (next_generation_pd.local_pd_id != generation_pd.local_pd_id ||
             next_generation_pd.handle.object_id ==
               generation_old_h.object_id)
      `uvm_error("GENERATION_REUSE",
                 "generation transition violated ID/incarnation rules")
    expect_status("GENERATION_OLD_STAYS_STALE",
                  generation_rm.lookup(generation_old_h, resource),
                  RDMA_SC_STALE_GENERATION);
    expect_status("GENERATION_RELEASE_NEXT",
                  generation_rm.release_function(binding_a.make_handle()),
                  RDMA_SC_OK);
    if (next_generation_pd != null)
      expect_status("GENERATION_NEXT_RETIRED",
                    generation_rm.lookup(next_generation_pd.handle, resource),
                    RDMA_SC_STALE_GENERATION);

    // A display-key collision on uid/generation must not alias distinct
    // complete Function instances.
    identity_rm = rdma_resource_manager::type_id::create("identity_rm");
    binding_a = make_active_binding("identity_binding_a",
                                    64'hface_cafe_0123_4567,
                                    32'h1111_0001, 32'd19);
    binding_b = make_active_binding("identity_binding_b",
                                    64'hface_cafe_0123_4567,
                                    32'h2222_0002, 32'd19);
    expect_status("IDENTITY_CREATE_A",
                  identity_rm.create_pd(binding_a, pd), RDMA_SC_OK);
    expect_status("IDENTITY_CREATE_B",
                  identity_rm.create_pd(binding_b, pd_b), RDMA_SC_OK);
    owner_b_h = clone_function_handle("IDENTITY_OWNER_B", pd_b.owner);
    binding_b.generation++;
    expect_status("IDENTITY_A_REMAINS_LIVE",
                  identity_rm.lookup(pd.handle, resource), RDMA_SC_OK);
    expect_status("IDENTITY_B_IS_STALE",
                  identity_rm.lookup(pd_b.handle, resource),
                  RDMA_SC_STALE_GENERATION);
    expect_status("IDENTITY_RELEASE_A",
                  identity_rm.release_function(binding_a.make_handle()),
                  RDMA_SC_OK);
    expect_status("IDENTITY_RELEASE_B",
                  identity_rm.release_function(owner_b_h),
                  RDMA_SC_OK);
    expect_status("IDENTITY_B_RETIRED",
                  identity_rm.lookup(pd_b.handle, resource),
                  RDMA_SC_STALE_GENERATION);

    // Dependency checks reject unsafe release; explicit leaf-first release is
    // accepted once all dependents are gone.
    dep_rm = rdma_resource_manager::type_id::create("dep_rm");
    binding_a = make_active_binding("dep_binding");
    expect_status("DEP_CREATE_PD",
                  dep_rm.create_pd(binding_a, dep_pd), RDMA_SC_OK);
    expect_status("DEP_CREATE_CEQ",
                  dep_rm.create_ceq(binding_a, dep_ceq), RDMA_SC_OK);
    expect_status("DEP_CREATE_CQ",
                  dep_rm.create_cq(binding_a, dep_ceq.handle, dep_cq),
                  RDMA_SC_OK);
    expect_status("DEP_CREATE_SRQ",
                  dep_rm.create_srq(binding_a, dep_pd.handle, dep_srq),
                  RDMA_SC_OK);
    expect_status("DEP_CREATE_MR",
                  dep_rm.create_mr(binding_a, dep_pd.handle, dep_mr),
                  RDMA_SC_OK);
    expect_status("DEP_CREATE_QP",
                  dep_rm.create_qp(binding_a, dep_pd.handle,
                                   dep_cq.handle, dep_cq.handle,
                                   dep_srq.handle, dep_qp), RDMA_SC_OK);
    expect_status("DEP_RELEASE_PD_BUSY", dep_rm.\release (dep_pd.handle),
                  RDMA_SC_INVALID_STATE);
    expect_status("DEP_RELEASE_CQ_BUSY", dep_rm.\release (dep_cq.handle),
                  RDMA_SC_INVALID_STATE);
    expect_status("DEP_RELEASE_SRQ_BUSY", dep_rm.\release (dep_srq.handle),
                  RDMA_SC_INVALID_STATE);
    expect_status("DEP_RELEASE_CEQ_BUSY", dep_rm.\release (dep_ceq.handle),
                  RDMA_SC_INVALID_STATE);
    expect_status("DEP_RELEASE_QP",
                  dep_rm.finalize_qp_release(dep_qp.handle), RDMA_SC_OK);
    expect_status("DEP_RELEASE_MR", dep_rm.\release (dep_mr.handle),
                  RDMA_SC_OK);
    expect_status("DEP_RELEASE_SRQ", dep_rm.\release (dep_srq.handle),
                  RDMA_SC_OK);
    expect_status("DEP_RELEASE_CQ", dep_rm.\release (dep_cq.handle),
                  RDMA_SC_OK);
    expect_status("DEP_RELEASE_CEQ", dep_rm.\release (dep_ceq.handle),
                  RDMA_SC_OK);
    expect_status("DEP_RELEASE_PD", dep_rm.\release (dep_pd.handle),
                  RDMA_SC_OK);
    expect_status("DEP_NO_LEAKS", dep_rm.check_leaks(leak_count), RDMA_SC_OK);
    if (leak_count != 0)
      `uvm_error("DEP_NO_LEAKS", "released dependency graph leaked")

    // freeze locks individual release. release_function computes a complete
    // dependent-first order and is allowed to tear down frozen resources.
    teardown_rm = rdma_resource_manager::type_id::create("teardown_rm");
    binding_a = make_active_binding("teardown_binding");
    owner_h = binding_a.make_handle();
    expect_status("TEARDOWN_CREATE_PD",
                  teardown_rm.create_pd(binding_a, teardown_pd), RDMA_SC_OK);
    expect_status("TEARDOWN_CREATE_CEQ",
                  teardown_rm.create_ceq(binding_a, teardown_ceq), RDMA_SC_OK);
    expect_status("TEARDOWN_CREATE_CQ",
                  teardown_rm.create_cq(binding_a, teardown_ceq.handle,
                                        teardown_cq), RDMA_SC_OK);
    expect_status("TEARDOWN_CREATE_MR",
                  teardown_rm.create_mr(binding_a, teardown_pd.handle,
                                        teardown_mr), RDMA_SC_OK);
    expect_status("TEARDOWN_CREATE_QP",
                  teardown_rm.create_qp(binding_a, teardown_pd.handle,
                                        teardown_cq.handle,
                                        teardown_cq.handle, null,
                                        teardown_qp), RDMA_SC_OK);
    frozen_qp_h = clone_handle("TEARDOWN_QP_H", teardown_qp.handle);
    expect_status("TEARDOWN_FREEZE_PD",
                  teardown_rm.freeze(teardown_pd.handle),
                  RDMA_SC_INVALID_STATE);
    expect_status("TEARDOWN_FREEZE_CEQ",
                  teardown_rm.freeze(teardown_ceq.handle),
                  RDMA_SC_INVALID_STATE);
    expect_status("TEARDOWN_FREEZE_CQ",
                  teardown_rm.freeze(teardown_cq.handle),
                  RDMA_SC_INVALID_STATE);
    prepare_mr(teardown_mr, 64'h6100_0000);
    expect_status("TEARDOWN_STAGE_MR",
                  teardown_rm.stage_allocated(teardown_mr), RDMA_SC_OK);
    expect_status("TEARDOWN_FREEZE_MR",
                  teardown_rm.freeze(teardown_mr.handle), RDMA_SC_OK);
    expect_status("TEARDOWN_FREEZE_QP",
                  teardown_rm.freeze(teardown_qp.handle),
                  RDMA_SC_INVALID_STATE);
    expect_status("TEARDOWN_FROZEN_LOOKUP",
                  teardown_rm.lookup(teardown_mr.handle, resource), RDMA_SC_OK);
    if (resource == null || resource.state != RDMA_RESOURCE_PROGRAMMED)
      `uvm_error("TEARDOWN_FROZEN_LOOKUP",
                 "freeze did not publish PROGRAMMED state")
    expect_status("TEARDOWN_FROZEN_RELEASE",
                  teardown_rm.\release (teardown_mr.handle),
                  RDMA_SC_INVALID_STATE);
    expect_status("TEARDOWN_HAS_LEAKS",
                  teardown_rm.check_leaks(leak_count, owner_h),
                  RDMA_SC_INVALID_STATE);
    if (leak_count != 5)
      `uvm_error("TEARDOWN_HAS_LEAKS",
                 $sformatf("expected 5 leaks, got %0d", leak_count))
    expect_status("TEARDOWN_RELEASE_FUNCTION",
                  teardown_rm.release_function(owner_h), RDMA_SC_OK);
    expect_status("TEARDOWN_USE_AFTER_FREE",
                  teardown_rm.lookup(frozen_qp_h, resource),
                  RDMA_SC_STALE_GENERATION);
    expect_status("TEARDOWN_RELEASE_AFTER_FREE",
                  teardown_rm.\release (frozen_qp_h),
                  RDMA_SC_STALE_GENERATION);
    expect_status("TEARDOWN_NO_LEAKS",
                  teardown_rm.check_leaks(leak_count, owner_h), RDMA_SC_OK);
    if (leak_count != 0)
      `uvm_error("TEARDOWN_NO_LEAKS", "release_function leaked resources")
    expect_status("TEARDOWN_REPEATED_FUNCTION",
                  teardown_rm.release_function(owner_h),
                  RDMA_SC_STALE_GENERATION);

    // A Function is the retirement boundary.  Ordinary release must preserve
    // it so only privileged Function teardown can atomically retire topology.
    function_release_rm = rdma_resource_manager::type_id::create(
      "function_release_rm"
    );
    function_release_binding = make_active_binding(
      "function_release_binding", 64'hf00d_0000_0000_0001,
      32'hf00d_0101, 32'd77
    );
    function_release_binding.vsi_id = 32'hf00d_0202;
    expect_status(
      "FUNCTION_ORDINARY_RELEASE_CREATE",
      function_release_rm.create_function(function_release_binding,
                                           function_release_function),
      RDMA_SC_OK
    );
    owner_h = clone_function_handle("FUNCTION_ORDINARY_RELEASE_OWNER",
                                    function_release_function.owner);
    function_release_h = clone_handle("FUNCTION_ORDINARY_RELEASE_HANDLE",
                                      function_release_function.handle);
    expect_status(
      "FUNCTION_ORDINARY_RELEASE_REJECT",
      function_release_rm.\release (function_release_h),
      RDMA_SC_INVALID_STATE
    );
    expect_status(
      "FUNCTION_ORDINARY_RELEASE_STILL_LIVE",
      function_release_rm.lookup(function_release_h, resource), RDMA_SC_OK
    );
    if (resource == null || !$cast(function_release_lookup, resource)) begin
      `uvm_error("FUNCTION_ORDINARY_RELEASE_STILL_LIVE",
                 "ordinary release removed or changed Function type")
    end
    else if (!function_release_lookup.handle.same_instance(
               function_release_h
             ) ||
             !function_release_lookup.owner.same_instance(owner_h) ||
             function_release_lookup.local_function_id !=
               function_release_function.local_function_id ||
             function_release_lookup.rdma_vf_id !=
               function_release_binding.rdma_vf_id ||
             function_release_lookup.vsi_id !=
               function_release_binding.vsi_id ||
             function_release_lookup.pfvf_id !=
               function_release_binding.pfvf_id)
      `uvm_error("FUNCTION_ORDINARY_RELEASE_UNCHANGED",
                 "rejected ordinary release changed the live Function")
    expect_status(
      "FUNCTION_ORDINARY_RELEASE_CREATE_PD",
      function_release_rm.create_pd(function_release_binding,
                                    function_release_pd),
      RDMA_SC_OK
    );
    expect_status(
      "FUNCTION_ORDINARY_RELEASE_TEARDOWN",
      function_release_rm.release_function(owner_h), RDMA_SC_OK
    );
    expect_status(
      "FUNCTION_ORDINARY_RELEASE_RETIRED",
      function_release_rm.lookup(function_release_h, resource),
      RDMA_SC_STALE_GENERATION
    );
    expect_status(
      "FUNCTION_ORDINARY_RELEASE_RETIRED_RELEASE",
      function_release_rm.\release (function_release_h),
      RDMA_SC_STALE_GENERATION
    );
    expect_status(
      "FUNCTION_ORDINARY_RELEASE_PD_RETIRED",
      function_release_rm.lookup(function_release_pd.handle, resource),
      RDMA_SC_STALE_GENERATION
    );
    expect_status(
      "FUNCTION_ORDINARY_RELEASE_NO_LEAKS",
      function_release_rm.check_leaks(leak_count, owner_h), RDMA_SC_OK
    );
    if (leak_count != 0)
      `uvm_error("FUNCTION_ORDINARY_RELEASE_NO_LEAKS",
                 "privileged Function teardown leaked topology")

    // Function generations are exact non-reusable incarnations.  A -> B -> A
    // rollback is rejected, and max -> zero is exhaustion rather than wrap.
    function_cycle_rm = rdma_resource_manager::type_id::create(
      "function_cycle_rm"
    );
    function_cycle_binding = make_active_binding(
      "function_cycle_binding", 64'hf00c_0000_0000_0001,
      32'hf00c_0101, 32'd5
    );
    expect_status("FUNCTION_CYCLE_CREATE_A",
                  function_cycle_rm.create_function(function_cycle_binding,
                                                    function_a),
                  RDMA_SC_OK);
    owner_h = clone_function_handle("FUNCTION_CYCLE_OWNER_A",
                                    function_a.owner);
    expect_status("FUNCTION_CYCLE_RELEASE_A",
                  function_cycle_rm.release_function(owner_h), RDMA_SC_OK);
    function_cycle_binding.generation = 32'd6;
    function_cycle_binding.owner_h = function_cycle_binding.make_handle();
    expect_status("FUNCTION_CYCLE_CREATE_B",
                  function_cycle_rm.create_function(function_cycle_binding,
                                                    function_b),
                  RDMA_SC_OK);
    if (function_b.local_function_id != function_a.local_function_id ||
        function_b.handle.same_instance(function_a.handle))
      `uvm_error("FUNCTION_CYCLE_B",
                 "Function local ID/incarnation transition is invalid")
    owner_b_h = clone_function_handle("FUNCTION_CYCLE_OWNER_B",
                                      function_b.owner);
    expect_status("FUNCTION_CYCLE_RELEASE_B",
                  function_cycle_rm.release_function(owner_b_h), RDMA_SC_OK);
    function_cycle_binding.generation = 32'd5;
    function_cycle_binding.owner_h = function_cycle_binding.make_handle();
    expect_status("FUNCTION_CYCLE_REJECT_A",
                  function_cycle_rm.create_function(function_cycle_binding,
                                                    rejected_function),
                  RDMA_SC_STALE_GENERATION);
    if (rejected_function != null)
      `uvm_error("FUNCTION_CYCLE_REJECT_A",
                 "retired Function generation was recreated")

    function_wrap_rm = rdma_resource_manager::type_id::create(
      "function_wrap_rm"
    );
    function_wrap_binding = make_active_binding(
      "function_wrap_binding", 64'hf00c_0000_0000_0002,
      32'hf00c_0202, 32'hffff_ffff
    );
    expect_status("FUNCTION_WRAP_CREATE_MAX",
                  function_wrap_rm.create_function(function_wrap_binding,
                                                   function_max),
                  RDMA_SC_OK);
    owner_h = clone_function_handle("FUNCTION_WRAP_OWNER_MAX",
                                    function_max.owner);
    expect_status("FUNCTION_WRAP_RELEASE_MAX",
                  function_wrap_rm.release_function(owner_h), RDMA_SC_OK);
    function_wrap_binding.generation = 32'd0;
    function_wrap_binding.owner_h = function_wrap_binding.make_handle();
    expect_status("FUNCTION_WRAP_REJECT_ZERO",
                  function_wrap_rm.create_function(function_wrap_binding,
                                                   function_wrapped),
                  RDMA_SC_RESOURCE_EXHAUSTED);
    if (function_wrapped != null)
      `uvm_error("FUNCTION_WRAP_REJECT_ZERO",
                 "wrapped Function generation returned a resource")
    expect_status("FUNCTION_WRAP_OLD_STALE",
                  function_wrap_rm.lookup(owner_h, resource),
                  RDMA_SC_STALE_GENERATION);

    // Once max -> zero is observed, exhaustion is permanent even if the same
    // live source is written back to max.  Rejected retries are atomic and the
    // privileged teardown path remains available for the old max topology.
    permanent_exhaustion_rm = new("permanent_exhaustion_rm");
    permanent_exhaustion_binding = make_active_binding(
      "permanent_exhaustion_binding", 64'hf00c_0000_0000_0003,
      32'hf00c_0303, 32'hffff_ffff
    );
    expect_status(
      "PERMANENT_EXHAUSTION_CREATE_MAX",
      permanent_exhaustion_rm.create_function(
        permanent_exhaustion_binding, permanent_exhaustion_function
      ),
      RDMA_SC_OK
    );
    owner_h = clone_function_handle(
      "PERMANENT_EXHAUSTION_OWNER_MAX", permanent_exhaustion_function.owner
    );
    old_h = clone_handle("PERMANENT_EXHAUSTION_OLD_HANDLE",
                         permanent_exhaustion_function.handle);
    expect_status(
      "PERMANENT_EXHAUSTION_INITIAL_LIVE",
      permanent_exhaustion_rm.check_leaks(leak_count, owner_h),
      RDMA_SC_INVALID_STATE
    );
    if (leak_count != 1)
      `uvm_error("PERMANENT_EXHAUSTION_INITIAL_LIVE",
                 $sformatf("expected 1 live resource, got %0d", leak_count))

    pd_local_before_exhaustion =
      permanent_exhaustion_rm.observed_next_local_id(RDMA_RESOURCE_PD);
    pd_serial_before_exhaustion =
      permanent_exhaustion_rm.observed_next_object_serial(RDMA_RESOURCE_PD);
    cmq_local_before_exhaustion =
      permanent_exhaustion_rm.observed_next_local_id(RDMA_RESOURCE_CMQ);
    cmq_serial_before_exhaustion =
      permanent_exhaustion_rm.observed_next_object_serial(RDMA_RESOURCE_CMQ);

    permanent_exhaustion_binding.generation = 32'd0;
    permanent_exhaustion_binding.owner_h =
      permanent_exhaustion_binding.make_handle();
    expect_status(
      "PERMANENT_EXHAUSTION_REJECT_ZERO",
      permanent_exhaustion_rm.create_pd(permanent_exhaustion_binding,
                                        permanent_exhaustion_pd),
      RDMA_SC_RESOURCE_EXHAUSTED
    );
    if (permanent_exhaustion_pd != null)
      `uvm_error("PERMANENT_EXHAUSTION_REJECT_ZERO",
                 "zero generation returned a PD")

    permanent_exhaustion_binding.generation = 32'hffff_ffff;
    permanent_exhaustion_binding.owner_h =
      permanent_exhaustion_binding.make_handle();
    expect_status(
      "PERMANENT_EXHAUSTION_REJECT_MAX_PD",
      permanent_exhaustion_rm.create_pd(permanent_exhaustion_binding,
                                        permanent_exhaustion_pd),
      RDMA_SC_RESOURCE_EXHAUSTED
    );
    if (permanent_exhaustion_pd != null)
      `uvm_error("PERMANENT_EXHAUSTION_REJECT_MAX_PD",
                 "max-generation retry returned a PD")
    expect_status(
      "PERMANENT_EXHAUSTION_REJECT_MAX_CMQ",
      permanent_exhaustion_rm.create_cmq(permanent_exhaustion_binding,
                                         permanent_exhaustion_cmq),
      RDMA_SC_RESOURCE_EXHAUSTED
    );
    if (permanent_exhaustion_cmq != null)
      `uvm_error("PERMANENT_EXHAUSTION_REJECT_MAX_CMQ",
                 "max-generation retry returned a CMQ")
    expect_status(
      "PERMANENT_EXHAUSTION_NO_GHOSTS",
      permanent_exhaustion_rm.check_leaks(leak_count, owner_h),
      RDMA_SC_INVALID_STATE
    );
    if (leak_count != 1)
      `uvm_error("PERMANENT_EXHAUSTION_NO_GHOSTS",
                 $sformatf("failed creates changed leak count to %0d",
                           leak_count))
    if (permanent_exhaustion_rm.observed_next_local_id(RDMA_RESOURCE_PD) !=
          pd_local_before_exhaustion ||
        permanent_exhaustion_rm.observed_next_object_serial(
          RDMA_RESOURCE_PD
        ) != pd_serial_before_exhaustion)
      `uvm_error("PERMANENT_EXHAUSTION_PD_ATOMIC",
                 "failed PD creates consumed an ID or incarnation serial")
    if (permanent_exhaustion_rm.observed_next_local_id(RDMA_RESOURCE_CMQ) !=
          cmq_local_before_exhaustion ||
        permanent_exhaustion_rm.observed_next_object_serial(
          RDMA_RESOURCE_CMQ
        ) != cmq_serial_before_exhaustion)
      `uvm_error("PERMANENT_EXHAUSTION_CMQ_ATOMIC",
                 "failed CMQ create consumed an ID or incarnation serial")
    expect_status(
      "PERMANENT_EXHAUSTION_OLD_LOOKUP",
      permanent_exhaustion_rm.lookup(old_h, resource),
      RDMA_SC_STALE_GENERATION
    );
    expect_status(
      "PERMANENT_EXHAUSTION_OLD_RELEASE",
      permanent_exhaustion_rm.\release (old_h),
      RDMA_SC_STALE_GENERATION
    );
    expect_status(
      "PERMANENT_EXHAUSTION_PRIVILEGED_TEARDOWN",
      permanent_exhaustion_rm.release_function(owner_h), RDMA_SC_OK
    );
    expect_status(
      "PERMANENT_EXHAUSTION_NO_LEAKS",
      permanent_exhaustion_rm.check_leaks(leak_count, owner_h), RDMA_SC_OK
    );
    if (leak_count != 0)
      `uvm_error("PERMANENT_EXHAUSTION_NO_LEAKS",
                 "privileged teardown leaked the max-generation topology")
    expect_status(
      "PERMANENT_EXHAUSTION_AFTER_TEARDOWN",
      permanent_exhaustion_rm.create_aeq(permanent_exhaustion_binding,
                                         permanent_exhaustion_aeq),
      RDMA_SC_RESOURCE_EXHAUSTED
    );
    if (permanent_exhaustion_aeq != null)
      `uvm_error("PERMANENT_EXHAUSTION_AFTER_TEARDOWN",
                 "post-teardown retry returned an AEQ")
    expect_status(
      "PERMANENT_EXHAUSTION_RETIRED_LOOKUP",
      permanent_exhaustion_rm.lookup(old_h, resource),
      RDMA_SC_STALE_GENERATION
    );
    expect_status(
      "PERMANENT_EXHAUSTION_RETIRED_RELEASE",
      permanent_exhaustion_rm.\release (old_h),
      RDMA_SC_STALE_GENERATION
    );

    // Incarnation exhaustion is a clean failure; it never wraps to revive an
    // earlier handle, and another kind's serial pool remains independent.
    exhaustion_rm = new("exhaustion_rm");
    exhaustion_binding = make_active_binding("exhaustion_binding");
    exhaustion_rm.force_next_object_serial(RDMA_RESOURCE_PD,
                                            32'h1000_0000);
    expect_status("SERIAL_EXHAUSTED",
                  exhaustion_rm.create_pd(exhaustion_binding, exhausted_pd),
                  RDMA_SC_RESOURCE_EXHAUSTED);
    if (exhausted_pd != null)
      `uvm_error("SERIAL_EXHAUSTED", "serial exhaustion returned a PD")
    expect_status("SERIAL_OTHER_KIND",
                  exhaustion_rm.create_aeq(exhaustion_binding, frozen_aeq),
                  RDMA_SC_OK);
    expect_status("SERIAL_OTHER_KIND_RELEASE",
                  exhaustion_rm.\release (frozen_aeq.handle), RDMA_SC_OK);
    expect_status("SERIAL_NO_LEAKS",
                  exhaustion_rm.check_leaks(leak_count), RDMA_SC_OK);

    // Every resource kind owns a separate local ID pool.  The first object in
    // each pool therefore receives local ID zero, independent of creation
    // order in the other pools.
    all_kind_rm = rdma_resource_manager::type_id::create("all_kind_rm");
    binding_a = make_active_binding("all_kind_binding",
                                    64'ha110_ca7e_0000_0001,
                                    32'h0102_0304, 32'd23);
    expect_status("ALL_KIND_FUNCTION",
                  all_kind_rm.create_function(binding_a, all_kind_function),
                  RDMA_SC_OK);
    expect_status("ALL_KIND_PD",
                  all_kind_rm.create_pd(binding_a, all_kind_pd), RDMA_SC_OK);
    expect_status("ALL_KIND_CEQ",
                  all_kind_rm.create_ceq(binding_a, all_kind_ceq), RDMA_SC_OK);
    expect_status("ALL_KIND_CQ",
                  all_kind_rm.create_cq(binding_a, all_kind_ceq.handle,
                                        all_kind_cq), RDMA_SC_OK);
    expect_status("ALL_KIND_SRQ",
                  all_kind_rm.create_srq(binding_a, all_kind_pd.handle,
                                         all_kind_srq), RDMA_SC_OK);
    expect_status("ALL_KIND_MR",
                  all_kind_rm.create_mr(binding_a, all_kind_pd.handle,
                                        all_kind_mr), RDMA_SC_OK);
    expect_status("ALL_KIND_QP",
                  all_kind_rm.create_qp(binding_a, all_kind_pd.handle,
                                        all_kind_cq.handle,
                                        all_kind_cq.handle,
                                        null, all_kind_qp), RDMA_SC_OK);
    expect_status("ALL_KIND_CMQ",
                  all_kind_rm.create_cmq(binding_a, all_kind_cmq),
                  RDMA_SC_OK);
    expect_status("ALL_KIND_AEQ",
                  all_kind_rm.create_aeq(binding_a, all_kind_aeq),
                  RDMA_SC_OK);
    prepare_mr(all_kind_mr, 64'h7100_0000);
    all_kind_ceq.depth = 8;
    all_kind_ceq.function_local_vector = 3;
    all_kind_ceq.hardware_vector = 17;
    all_kind_ceq.msix_table_index = 5;
    all_kind_ceq.queue_plan = make_queue_test_plan(
      "all_kind_ceq_plan", RDMA_RESOURCE_CEQ, all_kind_ceq.depth,
      all_kind_ceq.owner, all_kind_ceq.handle, all_kind_ceq.local_ceq_id
    );
    all_kind_cq.depth = 8;
    all_kind_cq.cqe_size_bytes = 128;
    all_kind_cq.queue_plan = make_queue_test_plan(
      "all_kind_cq_plan", RDMA_RESOURCE_CQ, all_kind_cq.depth,
      all_kind_cq.owner, all_kind_cq.handle, all_kind_cq.local_cq_id
    );
    all_kind_srq.depth = 32;
    all_kind_srq.max_sge = 4;
    all_kind_srq.limit_threshold = 20;
    all_kind_srq.queue_plan = make_queue_test_plan(
      "all_kind_srq_plan", RDMA_RESOURCE_SRQ, all_kind_srq.depth,
      all_kind_srq.owner, all_kind_srq.handle, all_kind_srq.local_srq_id
    );
    prepare_qp_candidate(all_kind_qp, all_kind_pd, all_kind_cq,
                         all_kind_cq, "all_kind_qp");
    all_kind_cmq.depth = 8;
    all_kind_aeq.depth = 8;
    all_kind_aeq.function_local_vector = 3;
    all_kind_aeq.hardware_vector = 17;
    all_kind_aeq.msix_table_index = 5;
    all_kind_aeq.queue_plan = make_queue_test_plan(
      "all_kind_aeq_plan", RDMA_RESOURCE_AEQ, all_kind_aeq.depth,
      all_kind_aeq.owner, all_kind_aeq.handle, all_kind_aeq.local_aeq_id
    );
    all_kind_resources.delete();
    all_kind_resources.push_back(all_kind_function);
    all_kind_resources.push_back(all_kind_pd);
    all_kind_resources.push_back(all_kind_mr);
    all_kind_resources.push_back(all_kind_cq);
    all_kind_resources.push_back(all_kind_qp);
    all_kind_resources.push_back(all_kind_srq);
    all_kind_resources.push_back(all_kind_cmq);
    all_kind_resources.push_back(all_kind_ceq);
    all_kind_resources.push_back(all_kind_aeq);
    foreach (all_kind_resources[i]) begin
      if (all_kind_resources[i].resource_kind() == RDMA_RESOURCE_QP) begin
        expect_status(
          "ALL_KIND_RDMA_RESOURCE_QP_ATTACH",
          all_kind_rm.attach_qp_programming(all_kind_qp), RDMA_SC_OK
        );
      end
      else begin
        expect_status(
          $sformatf("ALL_KIND_%s_STAGE",
                    all_kind_resources[i].resource_kind().name()),
          all_kind_rm.stage_allocated(all_kind_resources[i]), RDMA_SC_OK
        );
        if (all_kind_resources[i].resource_kind() != RDMA_RESOURCE_PD)
          expect_status(
            $sformatf("ALL_KIND_%s_COMMIT",
                      all_kind_resources[i].resource_kind().name()),
            all_kind_rm.commit_programmed(all_kind_resources[i]), RDMA_SC_OK
          );
      end
      expect_status(
        $sformatf("ALL_KIND_%s_ACTIVATE",
                  all_kind_resources[i].resource_kind().name()),
        all_kind_rm.activate(all_kind_resources[i].handle), RDMA_SC_OK
      );
      expect_status(
        $sformatf("ALL_KIND_%s_LOOKUP",
                  all_kind_resources[i].resource_kind().name()),
        all_kind_rm.lookup(all_kind_resources[i].handle, resource),
        RDMA_SC_OK
      );
      if (resource == null || resource.state != RDMA_RESOURCE_ACTIVE)
        `uvm_error("ALL_KIND_LOOKUP",
                   "exact lifecycle lookup did not return ACTIVE authority")
      case (all_kind_resources[i].resource_kind())
        RDMA_RESOURCE_QP: begin
          if (!$cast(all_kind_lookup_qp, resource))
            `uvm_fatal("ALL_KIND_QP_METADATA",
                       "QP lookup returned incompatible authority")
        end
        RDMA_RESOURCE_CQ: begin
          if (!$cast(all_kind_lookup_cq, resource) ||
              all_kind_lookup_cq.cqe_size_bytes != 128)
            `uvm_error("ALL_KIND_CQ_METADATA",
                       "CQ lookup lost entry-size metadata")
        end
        RDMA_RESOURCE_SRQ: begin
          if (!$cast(all_kind_lookup_srq, resource) ||
              all_kind_lookup_srq.limit_threshold != 20)
            `uvm_error("ALL_KIND_SRQ_METADATA",
                       "SRQ lookup lost limit-threshold metadata")
        end
        RDMA_RESOURCE_CEQ: begin
          if (!$cast(all_kind_lookup_ceq, resource) ||
              all_kind_lookup_ceq.function_local_vector != 3 ||
              all_kind_lookup_ceq.hardware_vector != 17 ||
              all_kind_lookup_ceq.msix_table_index != 5)
            `uvm_error("ALL_KIND_CEQ_METADATA",
                       "CEQ lookup lost vector metadata")
        end
        RDMA_RESOURCE_AEQ: begin
          if (!$cast(all_kind_lookup_aeq, resource) ||
              all_kind_lookup_aeq.function_local_vector != 3 ||
              all_kind_lookup_aeq.hardware_vector != 17 ||
              all_kind_lookup_aeq.msix_table_index != 5)
            `uvm_error("ALL_KIND_AEQ_METADATA",
                       "AEQ lookup lost vector metadata")
        end
        default: begin
        end
      endcase
      if (all_kind_resources[i].resource_kind() == RDMA_RESOURCE_QP) begin
        qp_recovery_state = make_qp_test_recovery(
          "all_kind_qp_recovery", all_kind_lookup_qp,
          RDMA_QP_RECOVER_CREATE_ROLLBACK
        );
        expect_status(
          "ALL_KIND_RDMA_RESOURCE_QP_MARK_ERROR",
          all_kind_rm.mark_qp_error(all_kind_qp.handle,
                                    qp_recovery_state),
          RDMA_SC_OK
        );
      end
      else begin
        recovery_record = new(
          $sformatf("all_kind_%s_recovery",
                    all_kind_resources[i].resource_kind().name())
        );
        recovery_record.resource_h = clone_handle(
          "ALL_KIND_RECOVERY_H", all_kind_resources[i].handle
        );
        recovery_record.hardware_presence = RDMA_HW_PRESENCE_ABSENT;
        recovery_record.primary_status = rdma_status::make(
          RDMA_SC_RESET_CANCELLED, "all-kind exact recovery probe"
        );
        if (all_kind_resources[i].resource_kind() inside {
              RDMA_RESOURCE_CQ, RDMA_RESOURCE_SRQ,
              RDMA_RESOURCE_CEQ, RDMA_RESOURCE_AEQ
            }) begin
          if (!$cast(all_kind_lookup_queue, resource) ||
              all_kind_lookup_queue.queue_plan == null)
            `uvm_fatal("ALL_KIND_QUEUE_RECOVERY",
                       "queue lookup lacks an authoritative recovery plan")
          recovery_record.queue_recovery_valid = 1'b1;
          recovery_record.queue_intent = RDMA_QUEUE_RECOVER_NORMAL_DESTROY;
          recovery_record.ambiguous_queue_operation = RDMA_QUEUE_AMBIG_NONE;
          case (all_kind_resources[i].resource_kind())
            RDMA_RESOURCE_CQ:
              recovery_record.ambiguous_role = RDMA_QUEUE_ROLE_CQ_RING;
            RDMA_RESOURCE_SRQ:
              recovery_record.ambiguous_role = RDMA_QUEUE_ROLE_SRQ_RING;
            RDMA_RESOURCE_CEQ:
              recovery_record.ambiguous_role = RDMA_QUEUE_ROLE_CEQ_RING;
            RDMA_RESOURCE_AEQ:
              recovery_record.ambiguous_role = RDMA_QUEUE_ROLE_AEQ_RING;
            default: begin
            end
          endcase
          recovery_record.queue_plan = all_kind_lookup_queue.queue_plan;
          recovery_record.queue_create_opcode = make_queue_test_opcode(
            $sformatf("all_kind_%0d_create", i), "create"
          );
          recovery_record.queue_delete_opcode = make_queue_test_opcode(
            $sformatf("all_kind_%0d_delete", i), "delete"
          );
          recovery_record.queue_query_opcode = make_queue_test_opcode(
            $sformatf("all_kind_%0d_query", i), "query"
          );
        end
        expect_status(
          $sformatf("ALL_KIND_%s_MARK_ERROR",
                    all_kind_resources[i].resource_kind().name()),
          all_kind_rm.mark_error(all_kind_resources[i].handle,
                                 recovery_record),
          RDMA_SC_OK
        );
      end
      expect_status(
        $sformatf("ALL_KIND_%s_RECOVERY_LOOKUP",
                  all_kind_resources[i].resource_kind().name()),
        all_kind_rm.lookup_recovery(all_kind_resources[i].handle,
                                    recovery_lookup),
        RDMA_SC_OK
      );
      expect_status(
        $sformatf("ALL_KIND_%s_RECOVERY_CLEAR",
                  all_kind_resources[i].resource_kind().name()),
        all_kind_rm.clear_recovery(all_kind_resources[i].handle),
        RDMA_SC_OK
      );
    end
    if (all_kind_function.local_function_id != 0 ||
        all_kind_pd.local_pd_id != 0 || all_kind_mr.local_mr_id != 0 ||
        all_kind_cq.local_cq_id != 0 || all_kind_qp.local_qp_id != 0 ||
        all_kind_srq.local_srq_id != 0 ||
        all_kind_cmq.local_cmq_id != 0 ||
        all_kind_ceq.local_ceq_id != 0 ||
        all_kind_aeq.local_aeq_id != 0)
      `uvm_error("ALL_KIND_POOLS",
                 "resource kinds did not use independent local ID pools")
    expect_status("ALL_KIND_RELEASE_FUNCTION",
                  all_kind_rm.release_function(binding_a.make_handle()),
                  RDMA_SC_OK);
    expect_status("ALL_KIND_NO_LEAKS",
                  all_kind_rm.check_leaks(leak_count), RDMA_SC_OK);

    // HMC/FVM is an independent aperture and lease registry.  Deliberately
    // make its first address numerically equal to an IOVA and prove that the
    // wrapper/API domain remains distinct and no DMA mapping is modified.
    hmc = rdma_hmc_allocator::type_id::create("hmc");
    hmc_base.value = 64'h0000_0001_0000_0000;
    equal_iova.value = hmc_base.value;
    untouched_mapping = rdma_dma_mapping::type_id::create(
      "untouched_mapping"
    );
    untouched_mapping.iova = equal_iova;
    untouched_mapping.backing_addr.value = 64'hdead_beef_0000_0000;
    expect_status("HMC_CONFIGURE", hmc.configure(hmc_base, 64'h1000),
                  RDMA_SC_OK);
    owner_h = exhaustion_binding.make_handle();
    expect_status("HMC_ALLOCATE_EQUAL_IOVA",
                  hmc.allocate(owner_h, RDMA_RESOURCE_QP, 64, 64, hmc_addr),
                  RDMA_SC_OK);
    hmc_type_name = $typename(hmc_addr);
    iova_type_name = $typename(equal_iova);
    if (hmc_addr.value != equal_iova.value ||
        hmc_type_name == iova_type_name)
      `uvm_error("HMC_WRAPPER",
                 "equal numeric values collapsed HMC and IOVA domains")
    if (untouched_mapping.iova != equal_iova ||
        untouched_mapping.backing_addr.value !=
          64'hdead_beef_0000_0000)
      `uvm_error("HMC_DMA_SEPARATION",
                 "HMC allocation modified a DMA mapping")
    expect_status("HMC_LOOKUP",
                  hmc.lookup(owner_h, RDMA_RESOURCE_QP, hmc_addr,
                             lease_size), RDMA_SC_OK);
    if (lease_size != 64)
      `uvm_error("HMC_LOOKUP", "HMC lease size was not retained")

    owner_b_h = clone_function_handle("HMC_OTHER_OWNER", owner_h);
    owner_b_h.object_id++;
    expect_status("HMC_RELEASE_WRONG_OWNER",
                  hmc.\release (owner_b_h, RDMA_RESOURCE_QP, hmc_addr),
                  RDMA_SC_INVALID_ARGUMENT);
    expect_status("HMC_ACTIVE_AFTER_WRONG_OWNER",
                  hmc.lookup(owner_h, RDMA_RESOURCE_QP, hmc_addr,
                             lease_size), RDMA_SC_OK);
    expect_status("HMC_WRONG_OWNER",
                  hmc.lookup(owner_b_h, RDMA_RESOURCE_QP, hmc_addr,
                             lease_size), RDMA_SC_INVALID_ARGUMENT);
    owner_b_h = clone_function_handle("HMC_STALE_OWNER", owner_h);
    owner_b_h.generation++;
    expect_status("HMC_RELEASE_STALE_OWNER",
                  hmc.\release (owner_b_h, RDMA_RESOURCE_QP, hmc_addr),
                  RDMA_SC_STALE_GENERATION);
    expect_status("HMC_ACTIVE_AFTER_STALE_OWNER",
                  hmc.lookup(owner_h, RDMA_RESOURCE_QP, hmc_addr,
                             lease_size), RDMA_SC_OK);
    expect_status("HMC_STALE_OWNER",
                  hmc.lookup(owner_b_h, RDMA_RESOURCE_QP, hmc_addr,
                             lease_size), RDMA_SC_STALE_GENERATION);
    expect_status("HMC_RELEASE_WRONG_KIND",
                  hmc.\release (owner_h, RDMA_RESOURCE_CQ, hmc_addr),
                  RDMA_SC_INVALID_ARGUMENT);
    expect_status("HMC_ACTIVE_AFTER_WRONG_KIND",
                  hmc.lookup(owner_h, RDMA_RESOURCE_QP, hmc_addr,
                             lease_size), RDMA_SC_OK);
    expect_status("HMC_WRONG_KIND",
                  hmc.lookup(owner_h, RDMA_RESOURCE_CQ, hmc_addr,
                             lease_size), RDMA_SC_INVALID_ARGUMENT);
    expect_status("HMC_RELEASE",
                  hmc.\release (owner_h, RDMA_RESOURCE_QP, hmc_addr),
                  RDMA_SC_OK);
    expect_status("HMC_USE_AFTER_FREE",
                  hmc.lookup(owner_h, RDMA_RESOURCE_QP, hmc_addr,
                             lease_size), RDMA_SC_INVALID_STATE);
    expect_status("HMC_REPEAT_RELEASE",
                  hmc.\release (owner_h, RDMA_RESOURCE_QP, hmc_addr),
                  RDMA_SC_INVALID_STATE);

    // Alignment, per-Function lease teardown, and owner isolation.
    expect_status("HMC_ALLOCATE_ALIGNED",
                  hmc.allocate(owner_h, RDMA_RESOURCE_CQ, 32, 256,
                               hmc_addr), RDMA_SC_OK);
    if ((hmc_addr.value & 64'hff) != 0)
      `uvm_error("HMC_ALIGNMENT", "HMC allocation is not 256-byte aligned")
    expect_status("HMC_ALLOCATE_SECOND",
                  hmc.allocate(owner_h, RDMA_RESOURCE_PD, 16, 16,
                               hmc_addr_two), RDMA_SC_OK);
    owner_b_h = clone_function_handle("HMC_OTHER_FUNCTION", owner_h);
    owner_b_h.object_id += 32'h100;
    expect_status("HMC_ALLOCATE_OTHER_OWNER",
                  hmc.allocate(owner_b_h, RDMA_RESOURCE_MR, 16, 16,
                               hmc_other_addr), RDMA_SC_OK);
    expect_status("HMC_HAS_LEASES",
                  hmc.check_leaks(leak_count, owner_h),
                  RDMA_SC_INVALID_STATE);
    if (leak_count != 2)
      `uvm_error("HMC_HAS_LEASES",
                 $sformatf("expected 2 HMC leases, got %0d", leak_count))
    expect_status("HMC_RELEASE_FUNCTION",
                  hmc.release_function(owner_h), RDMA_SC_OK);
    expect_status("HMC_FUNCTION_RELEASED",
                  hmc.lookup(owner_h, RDMA_RESOURCE_CQ, hmc_addr,
                             lease_size), RDMA_SC_INVALID_STATE);
    expect_status("HMC_OTHER_OWNER_REMAINS",
                  hmc.lookup(owner_b_h, RDMA_RESOURCE_MR, hmc_other_addr,
                             lease_size), RDMA_SC_OK);
    expect_status("HMC_RELEASE_OTHER_OWNER",
                  hmc.release_function(owner_b_h), RDMA_SC_OK);
    expect_status("HMC_NO_LEAKS", hmc.check_leaks(leak_count), RDMA_SC_OK);

    // Function generations occupy isolated lease namespaces.  Teardown of one
    // generation must neither fail because of nor release another generation.
    owner_h = exhaustion_binding.make_handle();
    owner_b_h = clone_function_handle("HMC_NEXT_GENERATION", owner_h);
    owner_b_h.generation++;
    expect_status("HMC_GENERATION_OLD_ALLOC",
                  hmc.allocate(owner_h, RDMA_RESOURCE_CEQ, 16, 16,
                               hmc_addr), RDMA_SC_OK);
    expect_status("HMC_GENERATION_NEXT_ALLOC",
                  hmc.allocate(owner_b_h, RDMA_RESOURCE_CEQ, 16, 16,
                               hmc_addr_two), RDMA_SC_OK);
    expect_status("HMC_GENERATION_NEXT_RELEASE",
                  hmc.release_function(owner_b_h), RDMA_SC_OK);
    expect_status("HMC_GENERATION_OLD_REMAINS",
                  hmc.lookup(owner_h, RDMA_RESOURCE_CEQ, hmc_addr,
                             lease_size), RDMA_SC_OK);
    expect_status("HMC_GENERATION_NEXT_GONE",
                  hmc.lookup(owner_b_h, RDMA_RESOURCE_CEQ, hmc_addr_two,
                             lease_size), RDMA_SC_INVALID_STATE);
    expect_status("HMC_GENERATION_OLD_RELEASE",
                  hmc.release_function(owner_h), RDMA_SC_OK);
    expect_status("HMC_GENERATION_NO_LEAKS",
                  hmc.check_leaks(leak_count), RDMA_SC_OK);

    // Invalid sizes/alignments and aperture exhaustion do not advance or
    // manufacture leases.
    hmc_exhaustion = rdma_hmc_allocator::type_id::create("hmc_exhaustion");
    hmc_base.value = 64'h0000_0000_0000_1003;
    expect_status("HMC_SMALL_CONFIGURE",
                  hmc_exhaustion.configure(hmc_base, 64'hfd), RDMA_SC_OK);
    expect_status("HMC_ZERO_SIZE",
                  hmc_exhaustion.allocate(owner_h, RDMA_RESOURCE_QP,
                                          0, 16, hmc_addr),
                  RDMA_SC_INVALID_ARGUMENT);
    expect_status("HMC_ZERO_ALIGNMENT",
                  hmc_exhaustion.allocate(owner_h, RDMA_RESOURCE_QP,
                                          16, 0, hmc_addr),
                  RDMA_SC_INVALID_ARGUMENT);
    expect_status("HMC_BAD_ALIGNMENT",
                  hmc_exhaustion.allocate(owner_h, RDMA_RESOURCE_QP,
                                          16, 24, hmc_addr),
                  RDMA_SC_INVALID_ARGUMENT);
    expect_status("HMC_SMALL_ALLOCATE",
                  hmc_exhaustion.allocate(owner_h, RDMA_RESOURCE_QP,
                                          128, 64, hmc_addr), RDMA_SC_OK);
    if (hmc_addr.value != 64'h1040)
      `uvm_error("HMC_SMALL_ALLOCATE", "alignment skipped wrong prefix")
    expect_status("HMC_APERTURE_EXHAUSTED",
                  hmc_exhaustion.allocate(owner_h, RDMA_RESOURCE_QP,
                                          65, 64, hmc_addr_two),
                  RDMA_SC_RESOURCE_EXHAUSTED);
    if (hmc_addr_two.value != 0)
      `uvm_error("HMC_APERTURE_EXHAUSTED",
                 "failed allocation returned an address")
    expect_status("HMC_SMALL_RELEASE_FUNCTION",
                  hmc_exhaustion.release_function(owner_h), RDMA_SC_OK);

    // Both aperture-end overflow and alignment addition overflow are checked
    // before allocator state is mutated.
    hmc_overflow = rdma_hmc_allocator::type_id::create("hmc_overflow");
    hmc_base.value = 64'hffff_ffff_ffff_fff0;
    expect_status("HMC_APERTURE_OVERFLOW",
                  hmc_overflow.configure(hmc_base, 64'h20),
                  RDMA_SC_INVALID_ARGUMENT);
    expect_status("HMC_OVERFLOW_CONFIGURE",
                  hmc_overflow.configure(hmc_base, 64'h10), RDMA_SC_OK);
    expect_status("HMC_ALIGNMENT_OVERFLOW",
                  hmc_overflow.allocate(owner_h, RDMA_RESOURCE_QP,
                                        1, 32, hmc_addr),
                  RDMA_SC_RESOURCE_EXHAUSTED);
    expect_status("HMC_OVERFLOW_NO_LEAKS",
                  hmc_overflow.check_leaks(leak_count), RDMA_SC_OK);

    // QP has the sole 21-bit local-ID extension in this task.  The inclusive
    // maximum is allocatable; the next fresh identity is rejected atomically.
    qp_width_rm = new("qp_width_rm");
    qp_width_binding = make_active_binding(
      "qp_width_binding", 64'h7170_0000_0000_0001,
      32'h7170_0101, 32'd71
    );
    expect_status("QP_WIDTH_PD_CREATE",
                  qp_width_rm.create_pd(qp_width_binding, qp_width_pd),
                  RDMA_SC_OK);
    expect_status("QP_WIDTH_SEND_CQ_CREATE",
                  qp_width_rm.create_cq(qp_width_binding, null,
                                        qp_width_send_cq), RDMA_SC_OK);
    expect_status("QP_WIDTH_RECV_CQ_CREATE",
                  qp_width_rm.create_cq(qp_width_binding, null,
                                        qp_width_recv_cq), RDMA_SC_OK);
    qp_width_rm.set_next_local_id(RDMA_RESOURCE_QP, 21'h1f_ffff);
    expect_status(
      "QP_WIDTH_MAX_ACCEPTED",
      qp_width_rm.create_qp(qp_width_binding, qp_width_pd.handle,
                            qp_width_send_cq.handle,
                            qp_width_recv_cq.handle, null, qp_width_max),
      RDMA_SC_OK
    );
    if (qp_width_max == null || qp_width_max.local_qp_id != 21'h1f_ffff)
      `uvm_error("QP_WIDTH_MAX_ACCEPTED",
                 "inclusive 21-bit QPN maximum was not allocated")
    expect_status(
      "QP_WIDTH_OVERFLOW_REJECTED",
      qp_width_rm.create_qp(qp_width_binding, qp_width_pd.handle,
                            qp_width_send_cq.handle,
                            qp_width_recv_cq.handle, null,
                            qp_width_overflow),
      RDMA_SC_RESOURCE_EXHAUSTED
    );
    if (qp_width_overflow != null ||
        qp_width_rm.observed_registry_count() != 4)
      `uvm_error("QP_WIDTH_OVERFLOW_ATOMIC",
                 "rejected QPN overflow changed manager state")

    // QP lifecycle authority is exclusive: generic publication and ERROR
    // methods must reject before changing either registry or recovery state.
    qp_generic_bypass_rm = new("qp_generic_bypass_rm");
    qp_generic_bypass_binding = make_active_binding(
      "qp_generic_bypass_binding", 64'h7171_0000_0000_0001,
      32'h7171_0101, 32'd71
    );
    expect_status(
      "QP_GENERIC_BYPASS_PD_CREATE",
      qp_generic_bypass_rm.create_pd(qp_generic_bypass_binding,
                                      qp_generic_bypass_pd),
      RDMA_SC_OK
    );
    expect_status(
      "QP_GENERIC_BYPASS_SEND_CQ_CREATE",
      qp_generic_bypass_rm.create_cq(qp_generic_bypass_binding, null,
                                      qp_generic_bypass_send_cq),
      RDMA_SC_OK
    );
    expect_status(
      "QP_GENERIC_BYPASS_RECV_CQ_CREATE",
      qp_generic_bypass_rm.create_cq(qp_generic_bypass_binding, null,
                                      qp_generic_bypass_recv_cq),
      RDMA_SC_OK
    );
    expect_status(
      "QP_GENERIC_BYPASS_CMQ_CREATE",
      qp_generic_bypass_rm.create_cmq(qp_generic_bypass_binding,
                                       qp_generic_bypass_cmq),
      RDMA_SC_OK
    );
    expect_status(
      "QP_GENERIC_BYPASS_CREATE",
      qp_generic_bypass_rm.create_qp(
        qp_generic_bypass_binding, qp_generic_bypass_pd.handle,
        qp_generic_bypass_send_cq.handle,
        qp_generic_bypass_recv_cq.handle, null,
        qp_generic_bypass_candidate
      ),
      RDMA_SC_OK
    );
    prepare_qp_candidate(
      qp_generic_bypass_candidate, qp_generic_bypass_pd,
      qp_generic_bypass_send_cq, qp_generic_bypass_recv_cq,
      "qp_generic_bypass_candidate"
    );
    expect_status(
      "QP_GENERIC_STAGE_REJECTED",
      qp_generic_bypass_rm.stage_allocated(qp_generic_bypass_candidate),
      RDMA_SC_INVALID_STATE
    );
    expect_status(
      "QP_GENERIC_STAGE_ATOMIC_LOOKUP",
      qp_generic_bypass_rm.lookup(qp_generic_bypass_candidate.handle,
                                   resource),
      RDMA_SC_OK
    );
    if (resource == null || !$cast(qp_generic_bypass_lookup, resource) ||
        qp_generic_bypass_lookup.state != RDMA_RESOURCE_ALLOCATED ||
        qp_generic_bypass_lookup.qp_plan != null ||
        qp_generic_bypass_lookup.programmed_qpc != null)
      `uvm_error("QP_GENERIC_STAGE_ATOMIC",
                 "generic stage rejection changed the QP reservation")

    expect_status(
      "QP_GENERIC_COMMIT_PRECONDITION",
      qp_generic_bypass_rm.force_qp_staged_precondition(
        qp_generic_bypass_candidate
      ),
      RDMA_SC_OK
    );
    expect_status(
      "QP_GENERIC_COMMIT_REJECTED",
      qp_generic_bypass_rm.commit_programmed(qp_generic_bypass_candidate),
      RDMA_SC_INVALID_STATE
    );
    expect_status(
      "QP_GENERIC_COMMIT_ATOMIC_LOOKUP",
      qp_generic_bypass_rm.lookup(qp_generic_bypass_candidate.handle,
                                   resource),
      RDMA_SC_OK
    );
    if (resource == null || !$cast(qp_generic_bypass_lookup, resource) ||
        qp_generic_bypass_lookup.state != RDMA_RESOURCE_ALLOCATED ||
        qp_generic_bypass_lookup.qp_plan == null ||
        qp_generic_bypass_lookup.programmed_qpc == null)
      `uvm_error("QP_GENERIC_COMMIT_ATOMIC",
                 "generic commit rejection changed the staged QP")

    expect_status(
      "QP_GENERIC_ERROR_PRECONDITION",
      qp_generic_bypass_rm.force_qp_active_precondition(
        qp_generic_bypass_candidate
      ),
      RDMA_SC_OK
    );
    qp_generic_bypass_recovery = new("qp_generic_bypass_recovery");
    qp_generic_bypass_recovery.resource_h = clone_handle(
      "QP_GENERIC_ERROR_RECOVERY_H", qp_generic_bypass_candidate.handle
    );
    qp_generic_bypass_recovery.hardware_presence = RDMA_HW_PRESENCE_PRESENT;
    qp_generic_bypass_recovery.primary_status = rdma_status::make(
      RDMA_SC_RECOVERY_REQUIRED, "generic QP ERROR bypass probe"
    );
    qp_generic_bypass_recovery.qp_recovery_valid = 1'b1;
    qp_generic_bypass_recovery.qp_recovery = make_qp_test_recovery(
      "qp_generic_bypass_state", qp_generic_bypass_candidate,
      RDMA_QP_RECOVER_NORMAL_DESTROY
    );
    expect_status(
      "QP_GENERIC_MARK_ERROR_REJECTED",
      qp_generic_bypass_rm.mark_error(
        qp_generic_bypass_candidate.handle, qp_generic_bypass_recovery
      ),
      RDMA_SC_INVALID_STATE
    );
    expect_status(
      "QP_GENERIC_MARK_ERROR_ATOMIC_LOOKUP",
      qp_generic_bypass_rm.lookup(qp_generic_bypass_candidate.handle,
                                   resource),
      RDMA_SC_OK
    );
    if (resource == null || resource.state != RDMA_RESOURCE_ACTIVE)
      `uvm_error("QP_GENERIC_MARK_ERROR_ATOMIC",
                 "generic ERROR rejection changed the registry QP")
    expect_status(
      "QP_GENERIC_MARK_ERROR_NO_RECOVERY",
      qp_generic_bypass_rm.lookup_recovery(
        qp_generic_bypass_candidate.handle, recovery_lookup
      ),
      RDMA_SC_INVALID_STATE
    );

    expect_status(
      "QP_GENERIC_RESERVED_ERROR_PRECONDITION",
      qp_generic_bypass_rm.force_qp_active_precondition(
        qp_generic_bypass_candidate
      ),
      RDMA_SC_OK
    );
    expect_status(
      "QP_GENERIC_RESERVED_ERROR_REJECTED",
      qp_generic_bypass_rm.mark_reserved_error(
        qp_generic_bypass_candidate.handle, null
      ),
      RDMA_SC_INVALID_STATE
    );
    expect_status(
      "QP_GENERIC_RESERVED_ERROR_ATOMIC_LOOKUP",
      qp_generic_bypass_rm.lookup(qp_generic_bypass_candidate.handle,
                                   resource),
      RDMA_SC_OK
    );
    if (resource == null || resource.state != RDMA_RESOURCE_ACTIVE)
      `uvm_error("QP_GENERIC_RESERVED_ERROR_ATOMIC",
                 "generic reserved ERROR rejection changed the registry QP")

    // Structurally valid QPC snapshots are still caller input.  Bind them to
    // the current programmed authority before publishing ERROR recovery.
    qp_qpc_binding_recovery = make_qp_test_recovery(
      "qp_modify_bad_prior", qp_generic_bypass_candidate,
      RDMA_QP_RECOVER_MODIFY_RECONCILE,
      qp_generic_bypass_candidate.programmed_qpc
    );
    qp_qpc_binding_recovery.prior_qpc.sq_backing.value += 4096;
    expect_status(
      "QP_MODIFY_PRIOR_QPC_BINDING",
      qp_generic_bypass_rm.mark_qp_error(
        qp_generic_bypass_candidate.handle, qp_qpc_binding_recovery
      ),
      RDMA_SC_INVALID_ARGUMENT
    );
    expect_status(
      "QP_MODIFY_PRIOR_QPC_ATOMIC_LOOKUP",
      qp_generic_bypass_rm.lookup(qp_generic_bypass_candidate.handle,
                                   resource),
      RDMA_SC_OK
    );
    if (resource == null || resource.state != RDMA_RESOURCE_ACTIVE)
      `uvm_error("QP_MODIFY_PRIOR_QPC_ATOMIC",
                 "rejected modify prior QPC changed registry authority")
    expect_status(
      "QP_MODIFY_PRIOR_QPC_NO_RECOVERY",
      qp_generic_bypass_rm.lookup_recovery(
        qp_generic_bypass_candidate.handle, recovery_lookup
      ),
      RDMA_SC_INVALID_STATE
    );

    expect_status(
      "QP_DESTROY_PRIOR_QPC_PRECONDITION",
      qp_generic_bypass_rm.force_qp_active_precondition(
        qp_generic_bypass_candidate
      ),
      RDMA_SC_OK
    );
    qp_qpc_binding_recovery = make_qp_test_recovery(
      "qp_destroy_bad_prior", qp_generic_bypass_candidate,
      RDMA_QP_RECOVER_NORMAL_DESTROY
    );
    qp_qpc_binding_recovery.prior_qpc.rq_backing.value += 4096;
    expect_status(
      "QP_DESTROY_PRIOR_QPC_BINDING",
      qp_generic_bypass_rm.mark_qp_error(
        qp_generic_bypass_candidate.handle, qp_qpc_binding_recovery
      ),
      RDMA_SC_INVALID_ARGUMENT
    );
    expect_status(
      "QP_DESTROY_PRIOR_QPC_ATOMIC_LOOKUP",
      qp_generic_bypass_rm.lookup(qp_generic_bypass_candidate.handle,
                                   resource),
      RDMA_SC_OK
    );
    if (resource == null || resource.state != RDMA_RESOURCE_ACTIVE)
      `uvm_error("QP_DESTROY_PRIOR_QPC_ATOMIC",
                 "rejected destroy prior QPC changed registry authority")
    expect_status(
      "QP_DESTROY_PRIOR_QPC_NO_RECOVERY",
      qp_generic_bypass_rm.lookup_recovery(
        qp_generic_bypass_candidate.handle, recovery_lookup
      ),
      RDMA_SC_INVALID_STATE
    );

    expect_status(
      "QP_CREATE_CANDIDATE_QPC_PRECONDITION",
      qp_generic_bypass_rm.force_qp_active_precondition(
        qp_generic_bypass_candidate
      ),
      RDMA_SC_OK
    );
    qp_cloned_object =
      qp_generic_bypass_candidate.programmed_qpc.clone();
    if (qp_cloned_object == null ||
        !$cast(qp_qpc_binding_candidate, qp_cloned_object))
      `uvm_fatal("QP_CREATE_CANDIDATE_QPC",
                 "create candidate QPC clone failed")
    qp_qpc_binding_candidate.context_backing.value += 512;
    qp_qpc_binding_recovery = make_qp_test_recovery(
      "qp_create_bad_candidate", qp_generic_bypass_candidate,
      RDMA_QP_RECOVER_CREATE_ROLLBACK, qp_qpc_binding_candidate
    );
    expect_status(
      "QP_CREATE_CANDIDATE_QPC_BINDING",
      qp_generic_bypass_rm.mark_qp_error(
        qp_generic_bypass_candidate.handle, qp_qpc_binding_recovery
      ),
      RDMA_SC_INVALID_ARGUMENT
    );
    expect_status(
      "QP_CREATE_CANDIDATE_QPC_ATOMIC_LOOKUP",
      qp_generic_bypass_rm.lookup(qp_generic_bypass_candidate.handle,
                                   resource),
      RDMA_SC_OK
    );
    if (resource == null || resource.state != RDMA_RESOURCE_ACTIVE)
      `uvm_error("QP_CREATE_CANDIDATE_QPC_ATOMIC",
                 "rejected create candidate QPC changed registry authority")
    expect_status(
      "QP_CREATE_CANDIDATE_QPC_NO_RECOVERY",
      qp_generic_bypass_rm.lookup_recovery(
        qp_generic_bypass_candidate.handle, recovery_lookup
      ),
      RDMA_SC_INVALID_STATE
    );

    expect_status(
      "QP_OCC_REPLACEMENT_PRECONDITION",
      qp_generic_bypass_rm.force_qp_active_precondition(
        qp_generic_bypass_candidate
      ),
      RDMA_SC_OK
    );
    qp_qpc_binding_recovery = make_qp_test_recovery(
      "qp_occ_replacement_initial", qp_generic_bypass_candidate,
      RDMA_QP_RECOVER_CREATE_ROLLBACK,
      qp_generic_bypass_candidate.programmed_qpc
    );
    expect_status(
      "QP_OCC_REPLACEMENT_INITIAL_MARK",
      qp_generic_bypass_rm.mark_qp_error(
        qp_generic_bypass_candidate.handle, qp_qpc_binding_recovery
      ),
      RDMA_SC_OK
    );
    expect_status(
      "QP_OCC_REPLACEMENT_INITIAL_LOOKUP",
      qp_generic_bypass_rm.lookup_recovery(
        qp_generic_bypass_candidate.handle, recovery_lookup
      ),
      RDMA_SC_OK
    );
    qp_cloned_object = recovery_lookup.qp_recovery.clone();
    if (qp_cloned_object == null ||
        !$cast(qp_error_replacement, qp_cloned_object))
      `uvm_fatal("QP_OCC_REPLACEMENT_CLONE",
                 "stored QP recovery clone failed")
    qp_error_replacement.ambiguous_operation = RDMA_QP_AMBIG_OCC_FLUSH;
    qp_error_replacement.ambiguous_role = RDMA_QUEUE_ROLE_QP_SQ_RING;
    qp_error_replacement.ambiguous_ticket = make_qp_test_ticket(
      "qp_occ_replacement_ticket", qp_generic_bypass_candidate.owner,
      qp_generic_bypass_cmq.handle, qp_error_replacement.occ_opcode
    );
    expect_status(
      "QP_OCC_REPLACEMENT_SET_AMBIGUITY",
      qp_generic_bypass_rm.mark_qp_error(
        qp_generic_bypass_candidate.handle, qp_error_replacement
      ),
      RDMA_SC_OK
    );
    qp_error_replacement.ambiguous_role = RDMA_QUEUE_ROLE_QP_RQ_PD;
    qp_error_replacement.occ_opcode.opcode++;
    qp_error_replacement.ambiguous_ticket.command_id++;
    expect_status(
      "QP_OCC_REPLACEMENT_PROJECTED_LOOKUP",
      qp_generic_bypass_rm.lookup_recovery(
        qp_generic_bypass_candidate.handle, recovery_lookup
      ),
      RDMA_SC_OK
    );
    if (recovery_lookup == null || recovery_lookup.qp_recovery == null ||
        recovery_lookup.qp_recovery.ambiguous_operation !=
          RDMA_QP_AMBIG_OCC_FLUSH ||
        recovery_lookup.qp_recovery.ambiguous_role !=
          RDMA_QUEUE_ROLE_QP_SQ_RING ||
        recovery_lookup.qp_recovery.occ_opcode == null ||
        recovery_lookup.qp_recovery.occ_opcode.opcode != 32'h104 ||
        recovery_lookup.qp_recovery.ambiguous_ticket == null ||
        recovery_lookup.qp_recovery.ambiguous_ticket.command_id != 64'h1234)
      `uvm_error("QP_OCC_REPLACEMENT_PROJECTION",
                 "manager lost or aliased QP OCC recovery authority")
    qp_cloned_object = recovery_lookup.qp_recovery.clone();
    if (qp_cloned_object == null ||
        !$cast(qp_error_replacement, qp_cloned_object))
      `uvm_fatal("QP_OCC_REPLACEMENT_INVALID_CLONE",
                 "stored QP OCC recovery clone failed")
    qp_error_replacement.ambiguous_role = RDMA_QUEUE_ROLE_QP_SQ_PD;
    expect_status(
      "QP_OCC_REPLACEMENT_OUT_OF_ORDER_ATOMIC",
      qp_generic_bypass_rm.mark_qp_error(
        qp_generic_bypass_candidate.handle, qp_error_replacement
      ),
      RDMA_SC_INVALID_STATE
    );
    expect_status(
      "QP_OCC_REPLACEMENT_ATOMIC_LOOKUP",
      qp_generic_bypass_rm.lookup_recovery(
        qp_generic_bypass_candidate.handle, recovery_lookup
      ),
      RDMA_SC_OK
    );
    if (recovery_lookup == null || recovery_lookup.qp_recovery == null ||
        recovery_lookup.qp_recovery.ambiguous_role !=
          RDMA_QUEUE_ROLE_QP_SQ_RING)
      `uvm_error("QP_OCC_REPLACEMENT_ATOMIC",
                 "rejected OCC replacement changed stored authority")

    begin
      rdma_queue_backing_role_e pd_roles[$];
      pd_roles.push_back(RDMA_QUEUE_ROLE_QP_SQ_PD);
      pd_roles.push_back(RDMA_QUEUE_ROLE_QP_RQ_PD);
      foreach (pd_roles[i]) begin
        string label;
        bit expected_sq_ring_complete;
        bit expected_sq_pd_complete;

        label = $sformatf("QP_OCC_PD_CLEAR_%0d", i);
        qp_generic_bypass_candidate.qp_plan.cleanup_complete = 1'b1;
        qp_generic_bypass_candidate.qp_plan.sq_pd_flush_complete =
          pd_roles[i] == RDMA_QUEUE_ROLE_QP_RQ_PD;
        qp_generic_bypass_candidate.qp_plan.rq_pd_flush_complete = 1'b0;
        expect_status(
          {label, "_PRECONDITION"},
          qp_generic_bypass_rm.force_qp_active_precondition(
            qp_generic_bypass_candidate
          ),
          RDMA_SC_OK
        );
        qp_qpc_binding_recovery = make_qp_test_recovery(
          {label, "_INITIAL"}, qp_generic_bypass_candidate,
          RDMA_QP_RECOVER_CREATE_ROLLBACK,
          qp_generic_bypass_candidate.programmed_qpc
        );
        qp_qpc_binding_recovery.role_complete[
          RDMA_QUEUE_ROLE_QP_SQ_RING
        ] = 1'b1;
        qp_qpc_binding_recovery.role_complete[
          RDMA_QUEUE_ROLE_QP_SQ_PD
        ] = pd_roles[i] == RDMA_QUEUE_ROLE_QP_RQ_PD;
        expected_sq_ring_complete = 1'b1;
        expected_sq_pd_complete =
          pd_roles[i] == RDMA_QUEUE_ROLE_QP_RQ_PD;
        expect_status(
          {label, "_INITIAL_MARK"},
          qp_generic_bypass_rm.mark_qp_error(
            qp_generic_bypass_candidate.handle, qp_qpc_binding_recovery
          ),
          RDMA_SC_OK
        );
        expect_status(
          {label, "_INITIAL_LOOKUP"},
          qp_generic_bypass_rm.lookup_recovery(
            qp_generic_bypass_candidate.handle, recovery_lookup
          ),
          RDMA_SC_OK
        );
        qp_cloned_object = recovery_lookup.qp_recovery.clone();
        if (qp_cloned_object == null ||
            !$cast(qp_error_replacement, qp_cloned_object))
          `uvm_fatal({label, "_AMBIG_CLONE"},
                     "stored QP recovery clone failed")
        qp_error_replacement.ambiguous_operation =
          RDMA_QP_AMBIG_OCC_FLUSH;
        qp_error_replacement.ambiguous_role = pd_roles[i];
        qp_error_replacement.ambiguous_ticket = make_qp_test_ticket(
          {label, "_TICKET"}, qp_generic_bypass_candidate.owner,
          qp_generic_bypass_cmq.handle, qp_error_replacement.occ_opcode
        );
        expect_status(
          {label, "_SET"},
          qp_generic_bypass_rm.mark_qp_error(
            qp_generic_bypass_candidate.handle, qp_error_replacement
          ),
          RDMA_SC_OK
        );

        expect_status(
          {label, "_AMBIG_LOOKUP"},
          qp_generic_bypass_rm.lookup_recovery(
            qp_generic_bypass_candidate.handle, recovery_lookup
          ),
          RDMA_SC_OK
        );
        qp_cloned_object = recovery_lookup.qp_recovery.clone();
        if (qp_cloned_object == null ||
            !$cast(qp_error_replacement, qp_cloned_object))
          `uvm_fatal({label, "_MALFORMED_CLONE"},
                     "stored QP OCC recovery clone failed")
        qp_error_replacement.ambiguous_operation = RDMA_QP_AMBIG_NONE;
        qp_error_replacement.ambiguous_ticket = null;
        expect_status(
          {label, "_NONCANONICAL_REJECT"},
          qp_generic_bypass_rm.mark_qp_error(
            qp_generic_bypass_candidate.handle, qp_error_replacement
          ),
          RDMA_SC_INVALID_ARGUMENT
        );

        qp_cloned_object = recovery_lookup.qp_recovery.clone();
        if (qp_cloned_object == null ||
            !$cast(qp_error_replacement, qp_cloned_object))
          `uvm_fatal({label, "_PROGRESS_CLONE"},
                     "stored QP OCC recovery clone failed")
        qp_error_replacement.ambiguous_operation = RDMA_QP_AMBIG_NONE;
        qp_error_replacement.ambiguous_role = RDMA_QUEUE_ROLE_QP_SQ_RING;
        qp_error_replacement.ambiguous_ticket = null;
        qp_error_replacement.role_complete[
          RDMA_QUEUE_ROLE_QP_RQ_RING
        ] = 1'b1;
        expect_status(
          {label, "_PROGRESS_REJECT"},
          qp_generic_bypass_rm.mark_qp_error(
            qp_generic_bypass_candidate.handle, qp_error_replacement
          ),
          RDMA_SC_INVALID_ARGUMENT
        );
        expect_status(
          {label, "_REJECT_ATOMIC_LOOKUP"},
          qp_generic_bypass_rm.lookup_recovery(
            qp_generic_bypass_candidate.handle, recovery_lookup
          ),
          RDMA_SC_OK
        );
        if (recovery_lookup == null || recovery_lookup.qp_recovery == null ||
            recovery_lookup.qp_recovery.ambiguous_operation !=
              RDMA_QP_AMBIG_OCC_FLUSH ||
            recovery_lookup.qp_recovery.ambiguous_role != pd_roles[i] ||
            recovery_lookup.qp_recovery.ambiguous_ticket == null ||
            recovery_lookup.qp_recovery.role_complete[
              RDMA_QUEUE_ROLE_QP_RQ_RING
            ])
          `uvm_error({label, "_REJECT_ATOMIC"},
                     "rejected OCC clear changed stored recovery")

        qp_cloned_object = recovery_lookup.qp_recovery.clone();
        if (qp_cloned_object == null ||
            !$cast(qp_error_replacement, qp_cloned_object))
          `uvm_fatal({label, "_CLEAR_CLONE"},
                     "stored QP OCC recovery clone failed")
        qp_error_replacement.ambiguous_operation = RDMA_QP_AMBIG_NONE;
        qp_error_replacement.ambiguous_role = RDMA_QUEUE_ROLE_QP_SQ_RING;
        qp_error_replacement.ambiguous_ticket = null;
        expect_status(
          {label, "_CLEAR"},
          qp_generic_bypass_rm.mark_qp_error(
            qp_generic_bypass_candidate.handle, qp_error_replacement
          ),
          RDMA_SC_OK
        );
        expect_status(
          {label, "_CLEAR_LOOKUP"},
          qp_generic_bypass_rm.lookup_recovery(
            qp_generic_bypass_candidate.handle, recovery_lookup
          ),
          RDMA_SC_OK
        );
        if (recovery_lookup == null || recovery_lookup.qp_recovery == null ||
            recovery_lookup.qp_recovery.ambiguous_operation !=
              RDMA_QP_AMBIG_NONE ||
            recovery_lookup.qp_recovery.ambiguous_role !=
              RDMA_QUEUE_ROLE_QP_SQ_RING ||
            recovery_lookup.qp_recovery.ambiguous_ticket != null ||
            recovery_lookup.qp_recovery.role_complete[
              RDMA_QUEUE_ROLE_QP_SQ_RING
            ] != expected_sq_ring_complete ||
            recovery_lookup.qp_recovery.role_complete[
              RDMA_QUEUE_ROLE_QP_SQ_PD
            ] != expected_sq_pd_complete ||
            recovery_lookup.qp_recovery.qp_plan.cleanup_complete != 1'b1 ||
            recovery_lookup.qp_recovery.qp_plan.sq_pd_flush_complete !=
              expected_sq_pd_complete ||
            recovery_lookup.qp_recovery.qp_plan.rq_pd_flush_complete != 1'b0)
          `uvm_error({label, "_CLEAR_RESULT"},
                     "OCC clear lost canonical role or retained progress")
      end
      qp_generic_bypass_candidate.qp_plan.cleanup_complete = 1'b0;
      qp_generic_bypass_candidate.qp_plan.sq_pd_flush_complete = 1'b0;
      qp_generic_bypass_candidate.qp_plan.rq_pd_flush_complete = 1'b0;
    end

    expect_status(
      "QP_ERROR_REPLACEMENT_PRECONDITION",
      qp_generic_bypass_rm.force_qp_active_precondition(
        qp_generic_bypass_candidate
      ),
      RDMA_SC_OK
    );
    expect_status(
      "QP_ERROR_REPLACEMENT_QUIESCE",
      qp_generic_bypass_rm.begin_quiesce(
        qp_generic_bypass_candidate.handle
      ),
      RDMA_SC_OK
    );
    expect_status(
      "QP_ERROR_REPLACEMENT_RETAINED_PROGRESS",
      qp_generic_bypass_rm.record_qp_flush_complete(
        qp_generic_bypass_candidate.handle, RDMA_QUEUE_ROLE_QP_SQ_RING
      ),
      RDMA_SC_OK
    );
    expect_status(
      "QP_ERROR_REPLACEMENT_QP_LOOKUP",
      qp_generic_bypass_rm.lookup(qp_generic_bypass_candidate.handle,
                                   resource),
      RDMA_SC_OK
    );
    if (resource == null || !$cast(qp_generic_bypass_lookup, resource))
      `uvm_fatal("QP_ERROR_REPLACEMENT_QP_LOOKUP",
                 "replacement precondition QP lookup failed")
    qp_qpc_binding_recovery = make_qp_test_recovery(
      "qp_error_ambiguous_destroy", qp_generic_bypass_lookup,
      RDMA_QP_RECOVER_NORMAL_DESTROY
    );
    qp_qpc_binding_recovery.ambiguous_operation = RDMA_QP_AMBIG_DELETE;
    qp_qpc_binding_recovery.ambiguous_ticket = make_qp_test_ticket(
      "qp_error_delete_ticket", qp_generic_bypass_candidate.owner,
      qp_generic_bypass_cmq.handle,
      qp_qpc_binding_recovery.delete_opcode
    );
    qp_qpc_binding_recovery.staging_mapping =
      make_independent_queue_test_mapping(
        "qp_error_retained_staging",
        qp_generic_bypass_candidate.owner,
        qp_generic_bypass_candidate.handle,
        64'h0000_8a00_0000_0000
      );
    qp_qpc_binding_recovery.staging_mapping.size = 512;
    expect_status(
      "QP_ERROR_REPLACEMENT_INITIAL_MARK",
      qp_generic_bypass_rm.mark_qp_error(
        qp_generic_bypass_candidate.handle, qp_qpc_binding_recovery
      ),
      RDMA_SC_OK
    );
    expect_status(
      "QP_ERROR_REPLACEMENT_INITIAL_LOOKUP",
      qp_generic_bypass_rm.lookup_recovery(
        qp_generic_bypass_candidate.handle, recovery_lookup
      ),
      RDMA_SC_OK
    );
    qp_cloned_object = recovery_lookup.qp_recovery.clone();
    if (qp_cloned_object == null ||
        !$cast(qp_nested_recovery_state, qp_cloned_object))
      `uvm_fatal("QP_ERROR_STAGING_AUTHORITY_CLONE",
                 "stored staging recovery clone failed")
    qp_nested_recovery_state.ambiguous_operation = RDMA_QP_AMBIG_NONE;
    qp_nested_recovery_state.ambiguous_ticket = null;
    qp_nested_recovery_state.staging_mapping =
      make_independent_queue_test_mapping(
        "qp_error_replacement_wrong_staging_authority",
        qp_generic_bypass_candidate.owner,
        qp_generic_bypass_candidate.handle,
        recovery_lookup.qp_recovery.staging_mapping.iova.value
      );
    qp_nested_recovery_state.staging_mapping.size = 512;
    expect_status(
      "QP_ERROR_STAGING_AUTHORITY_REJECTED",
      qp_generic_bypass_rm.mark_qp_error(
        qp_generic_bypass_candidate.handle, qp_nested_recovery_state
      ),
      RDMA_SC_INVALID_ARGUMENT
    );
    expect_status(
      "QP_ERROR_REPLACEMENT_SQ_PD_FLUSH",
      qp_generic_bypass_rm.record_qp_flush_complete(
        qp_generic_bypass_candidate.handle, RDMA_QUEUE_ROLE_QP_SQ_PD
      ),
      RDMA_SC_OK
    );
    expect_status(
      "QP_ERROR_REPLACEMENT_RQ_PD_FLUSH",
      qp_generic_bypass_rm.record_qp_flush_complete(
        qp_generic_bypass_candidate.handle, RDMA_QUEUE_ROLE_QP_RQ_PD
      ),
      RDMA_SC_OK
    );
    expect_status(
      "QP_ERROR_REPLACEMENT_CONTEXT_OPAQUE_COMPLETE",
      qp_generic_bypass_rm.complete_qp_context_release(
        qp_generic_bypass_candidate.handle
      ),
      RDMA_SC_OK
    );
    expect_status(
      "QP_ERROR_REPLACEMENT_CONTEXT_AMBIGUITY_GATE",
      qp_generic_bypass_rm.record_qp_context_cleanup_complete(
        qp_generic_bypass_candidate.handle
      ),
      RDMA_SC_RECOVERY_REQUIRED
    );
    expect_status(
      "QP_ERROR_REPLACEMENT_CONTEXT_AMBIGUITY_ATOMIC",
      qp_generic_bypass_rm.lookup_recovery(
        qp_generic_bypass_candidate.handle, recovery_lookup
      ),
      RDMA_SC_OK
    );
    if (recovery_lookup == null || recovery_lookup.qp_recovery == null ||
        recovery_lookup.hardware_presence != RDMA_HW_PRESENCE_PRESENT ||
        recovery_lookup.qp_recovery.context_ref.release_complete ||
        recovery_lookup.qp_recovery.qp_plan.context_ref.release_complete ||
        recovery_lookup.qp_recovery.ambiguous_operation !=
          RDMA_QP_AMBIG_DELETE ||
        recovery_lookup.qp_recovery.ambiguous_ticket == null)
      `uvm_error("QP_ERROR_REPLACEMENT_CONTEXT_AMBIGUITY_ATOMIC",
                 "ambiguity-gated context cleanup changed recovery")
    qp_cloned_object = recovery_lookup.qp_recovery.clone();
    if (qp_cloned_object == null ||
        !$cast(qp_error_replacement, qp_cloned_object))
      `uvm_fatal("QP_ERROR_REPLACEMENT_CLONE",
                 "stored QP recovery clone failed")
    qp_error_replacement.ambiguous_operation = RDMA_QP_AMBIG_NONE;
    qp_error_replacement.ambiguous_ticket = null;
    expect_status(
      "QP_ERROR_REPLACEMENT_RESOLVE",
      qp_generic_bypass_rm.mark_qp_error(
        qp_generic_bypass_candidate.handle, qp_error_replacement
      ),
      RDMA_SC_OK
    );
    expect_status(
      "QP_ERROR_REPLACEMENT_CONTEXT_CLEANUP",
      qp_generic_bypass_rm.record_qp_context_cleanup_complete(
        qp_generic_bypass_candidate.handle
      ),
      RDMA_SC_OK
    );
    expect_status(
      "QP_ERROR_REPLACEMENT_RQ_PD_OPAQUE_COMPLETE",
      qp_generic_bypass_rm.complete_qp_mapping_release(
        qp_generic_bypass_candidate.handle, RDMA_QUEUE_ROLE_QP_RQ_PD
      ),
      RDMA_SC_OK
    );
    expect_status(
      "QP_ERROR_REPLACEMENT_RQ_PD_CLEANUP",
      qp_generic_bypass_rm.record_qp_cleanup_complete(
        qp_generic_bypass_candidate.handle, RDMA_QUEUE_ROLE_QP_RQ_PD
      ),
      RDMA_SC_OK
    );
    expect_status(
      "QP_ERROR_REPLACEMENT_SQ_PD_OPAQUE_COMPLETE",
      qp_generic_bypass_rm.complete_qp_mapping_release(
        qp_generic_bypass_candidate.handle, RDMA_QUEUE_ROLE_QP_SQ_PD
      ),
      RDMA_SC_OK
    );
    expect_status(
      "QP_ERROR_REPLACEMENT_SQ_PD_CLEANUP",
      qp_generic_bypass_rm.record_qp_cleanup_complete(
        qp_generic_bypass_candidate.handle, RDMA_QUEUE_ROLE_QP_SQ_PD
      ),
      RDMA_SC_OK
    );
    expect_status(
      "QP_ERROR_REPLACEMENT_RESOLVED_LOOKUP",
      qp_generic_bypass_rm.lookup_recovery(
        qp_generic_bypass_candidate.handle, recovery_lookup
      ),
      RDMA_SC_OK
    );
    if (recovery_lookup == null || recovery_lookup.qp_recovery == null ||
        recovery_lookup.qp_recovery.ambiguous_operation !=
          RDMA_QP_AMBIG_NONE ||
        recovery_lookup.qp_recovery.ambiguous_ticket != null ||
        !recovery_lookup.qp_recovery.qp_plan.cleanup_complete ||
        recovery_lookup.qp_recovery.prior_qpc == null ||
        recovery_lookup.qp_recovery.prior_qpc.sq_backing.value !=
          qp_generic_bypass_candidate.programmed_qpc.sq_backing.value)
      `uvm_error("QP_ERROR_REPLACEMENT_AUTHORITY",
                 "ERROR replacement lost immutable authority or progress")
    s = qp_generic_bypass_rm.finalize_qp_release(
      qp_generic_bypass_candidate.handle
    );
    expect_status(
      "QP_FINALIZE_RETAINED_STAGING_INCOMPLETE", s,
      RDMA_SC_RECOVERY_REQUIRED
    );
    if (s != null && s.code == RDMA_SC_RECOVERY_REQUIRED) begin
      expect_status(
        "QP_FINALIZE_RETAINED_STAGING_COMPLETE",
        qp_generic_bypass_rm.complete_qp_temporary_mapping_release(
          qp_generic_bypass_candidate.handle, 1'b1
        ),
        RDMA_SC_OK
      );
      expect_status(
        "QP_FINALIZE_AFTER_RETAINED_STAGING",
        qp_generic_bypass_rm.finalize_qp_release(
          qp_generic_bypass_candidate.handle
        ),
        RDMA_SC_OK
      );
    end

    qp_rm = new("qp_rm");
    qp_binding = make_active_binding(
      "qp_binding", 64'h7270_0000_0000_0001,
      32'h7270_0101, 32'd72
    );
    expect_status("QP_PD_CREATE", qp_rm.create_pd(qp_binding, qp_pd),
                  RDMA_SC_OK);
    expect_status("QP_SEND_CQ_CREATE",
                  qp_rm.create_cq(qp_binding, null, qp_send_cq), RDMA_SC_OK);
    expect_status("QP_RECV_CQ_CREATE",
                  qp_rm.create_cq(qp_binding, null, qp_recv_cq), RDMA_SC_OK);
    expect_status("QP_CMQ_CREATE",
                  qp_rm.create_cmq(qp_binding, qp_cmq), RDMA_SC_OK);
    expect_status(
      "QP_CREATE",
      qp_rm.create_qp(qp_binding, qp_pd.handle, qp_send_cq.handle,
                      qp_recv_cq.handle, null, qp_candidate), RDMA_SC_OK
    );
    expect_status(
      "QP_SEQUENCE_FIRST",
      qp_rm.qp_sequence(qp_candidate.owner, qp_candidate.local_qp_id,
                        qp_sequence_first), RDMA_SC_OK
    );
    prepare_qp_candidate(qp_candidate, qp_pd, qp_send_cq, qp_recv_cq,
                         "qp_candidate");

    qp_generic_backing_ref = rdma_backing_ref::type_id::create(
      "qp_generic_backing_ref"
    );
    qp_generic_backing_ref.mapping = make_queue_test_mapping(
      "qp_generic_backing_mapping", qp_candidate.owner,
      qp_candidate.handle, 64'h0000_8900_0000_0000, 1'b0
    );
    qp_generic_backing_ref.ownership = RDMA_OWNERSHIP_BORROWED;
    qp_candidate.backing_refs.push_back(qp_generic_backing_ref);
    expect_status("QP_GENERIC_AUTHORITY_REJECTED",
                  qp_rm.attach_qp_programming(qp_candidate),
                  RDMA_SC_INVALID_STATE);
    expect_status("QP_GENERIC_REJECT_LOOKUP",
                  qp_rm.lookup(qp_candidate.handle, resource), RDMA_SC_OK);
    if (resource == null || !$cast(qp_failed_lookup, resource) ||
        qp_failed_lookup.state != RDMA_RESOURCE_ALLOCATED ||
        qp_failed_lookup.qp_plan != null ||
        qp_failed_lookup.programmed_qpc != null ||
        qp_failed_lookup.backing_refs.size() != 0)
      `uvm_error("QP_GENERIC_REJECT_ATOMIC",
                 "rejected split authority changed the registry QP")
    qp_candidate.backing_refs.delete();

    expect_status("QP_ATTACH_PROGRAMMING",
                  qp_rm.attach_qp_programming(qp_candidate), RDMA_SC_OK);
    qp_candidate.qp_plan.context_ref.shadow_pointer_base.value += 512;
    expect_status("QP_ATTACH_LOOKUP",
                  qp_rm.lookup(qp_candidate.handle, resource), RDMA_SC_OK);
    if (resource == null || !$cast(qp_lookup, resource) ||
        qp_lookup.state != RDMA_RESOURCE_PROGRAMMED ||
        qp_lookup.qp_plan == null || qp_lookup.programmed_qpc == null ||
        qp_lookup.qp_plan === qp_candidate.qp_plan ||
        qp_lookup.programmed_qpc === qp_candidate.programmed_qpc ||
        qp_lookup.qp_plan.context_ref.shadow_pointer_base.value !=
          64'h0000_8600_0000_0000)
      `uvm_error("QP_ATTACH_SNAPSHOT",
                 "QP programming was not published as a detached snapshot")
    expect_status("QP_ACTIVATE", qp_rm.activate(qp_lookup.handle),
                  RDMA_SC_OK);

    expect_status("QP_SEMANTIC_RESET_TO_INIT",
                  qp_rm.commit_qp_semantic_state(qp_lookup.handle,
                                                  RDMA_QPS_INIT),
                  RDMA_SC_OK);
    expect_status("QP_SEMANTIC_DUPLICATE",
                  qp_rm.commit_qp_semantic_state(qp_lookup.handle,
                                                  RDMA_QPS_INIT),
                  RDMA_SC_INVALID_STATE);
    expect_status("QP_SEMANTIC_LOOKUP",
                  qp_rm.lookup(qp_lookup.handle, resource), RDMA_SC_OK);
    if (resource == null || !$cast(qp_lookup, resource) ||
        qp_lookup.state != RDMA_RESOURCE_ACTIVE ||
        qp_lookup.qp_state != RDMA_QPS_INIT ||
        qp_lookup.programmed_qpc == null ||
        qp_lookup.programmed_qpc.state != RDMA_QPS_RESET)
      `uvm_error("QP_SEMANTIC_AUTHORITY",
                 "software-only INIT changed programmed QPC authority")

    qp_cloned_object = qp_lookup.clone();
    if (qp_cloned_object == null ||
        !$cast(qp_nested_candidate, qp_cloned_object) ||
        qp_nested_candidate.qp_plan == null ||
        qp_nested_candidate.qp_plan.context_ref == null ||
        !$cast(qp_nested_context_token,
               qp_nested_candidate.qp_plan.context_ref.slot_token))
      `uvm_fatal("QP_NESTED_CONTEXT_CANDIDATE",
                 "QP context-authority candidate clone failed")
    qp_nested_context_authority =
      rdma_queue_completion_authority::type_id::create(
        "qp_nested_replacement_context_authority"
      );
    qp_nested_context_token.completion_authority =
      qp_nested_context_authority;
    expect_status("QP_NESTED_CONTEXT_AUTHORITY_REJECTED",
                  qp_rm.commit_qp_programmed(qp_nested_candidate),
                  RDMA_SC_INVALID_ARGUMENT);

    qp_cloned_object = qp_lookup.clone();
    if (qp_cloned_object == null ||
        !$cast(qp_nested_candidate, qp_cloned_object) ||
        qp_nested_candidate.qp_plan == null ||
        qp_nested_candidate.qp_plan.sq_pd_ref == null ||
        qp_nested_candidate.qp_plan.sq_pd_ref.mapping == null)
      `uvm_fatal("QP_NESTED_MAPPING_CANDIDATE",
                 "QP mapping-authority candidate clone failed")
    qp_nested_mapping = make_independent_queue_test_mapping(
      "qp_nested_replacement_sq_pd", qp_lookup.owner, qp_lookup.handle,
      qp_nested_candidate.qp_plan.sq_pd_ref.mapping.iova.value
    );
    qp_nested_candidate.qp_plan.sq_pd_ref.mapping = qp_nested_mapping;
    expect_status("QP_NESTED_MAPPING_AUTHORITY_REJECTED",
                  qp_rm.commit_qp_programmed(qp_nested_candidate),
                  RDMA_SC_INVALID_ARGUMENT);
    expect_status("QP_NESTED_AUTHORITY_ATOMIC_LOOKUP",
                  qp_rm.lookup(qp_lookup.handle, resource), RDMA_SC_OK);
    if (resource == null || !$cast(qp_lookup, resource) ||
        qp_lookup.state != RDMA_RESOURCE_ACTIVE ||
        qp_lookup.qp_state != RDMA_QPS_INIT ||
        qp_lookup.programmed_qpc.state != RDMA_QPS_RESET ||
        !$cast(qp_nested_context_token,
               qp_lookup.qp_plan.context_ref.slot_token) ||
        qp_nested_context_token.completion_authority ===
          qp_nested_context_authority)
      `uvm_error("QP_NESTED_AUTHORITY_ATOMIC",
                 "rejected nested authority changed the registry QP")

    qp_cloned_object = qp_lookup.clone();
    if (qp_cloned_object == null ||
        !$cast(qp_failed_lookup, qp_cloned_object))
      `uvm_fatal("QP_FAILED_CANDIDATE", "QP clone failed")
    qp_failed_lookup.qp_state = RDMA_QPS_RTR;
    qp_failed_lookup.programmed_qpc.state = RDMA_QPS_RTR;
    qp_failed_lookup.programmed_qpc.sq_backing.value += 4096;
    expect_status("QP_PROGRAMMED_BAD_CANDIDATE",
                  qp_rm.commit_qp_programmed(qp_failed_lookup),
                  RDMA_SC_INVALID_STATE);
    expect_status("QP_PROGRAMMED_BAD_LOOKUP",
                  qp_rm.lookup(qp_lookup.handle, resource), RDMA_SC_OK);
    if (resource == null || !$cast(qp_lookup, resource) ||
        qp_lookup.qp_state != RDMA_QPS_INIT ||
        qp_lookup.programmed_qpc.state != RDMA_QPS_RESET)
      `uvm_error("QP_PROGRAMMED_BAD_ATOMIC",
                 "failed programmed candidate partially changed registry")

    qp_cloned_object = qp_lookup.clone();
    if (qp_cloned_object == null || !$cast(qp_candidate, qp_cloned_object))
      `uvm_fatal("QP_PROGRAMMED_CANDIDATE", "QP clone failed")
    qp_candidate.qp_state = RDMA_QPS_RTR;
    qp_candidate.programmed_qpc.state = RDMA_QPS_RTR;
    qp_candidate.sq_producer_index = 1;
    expect_status("QP_PROGRAMMED_COMMIT",
                  qp_rm.commit_qp_programmed(qp_candidate), RDMA_SC_OK);
    expect_status("QP_PROGRAMMED_LOOKUP",
                  qp_rm.lookup(qp_candidate.handle, resource), RDMA_SC_OK);
    if (resource == null || !$cast(qp_lookup, resource) ||
        qp_lookup.qp_state != RDMA_QPS_RTR ||
        qp_lookup.programmed_qpc.state != RDMA_QPS_RTR ||
        qp_lookup.sq_producer_index != 0)
      `uvm_error("QP_PROGRAMMED_AUTHORITY",
                 "programmed commit leaked unrelated caller QP fields")

    qp_recovery_state = make_qp_test_recovery(
      "qp_destroy_recovery", qp_lookup, RDMA_QP_RECOVER_NORMAL_DESTROY
    );
    qp_recovery_state.query_mapping =
      make_independent_queue_test_mapping(
        "qp_destroy_retained_query", qp_lookup.owner, qp_lookup.handle,
        64'h0000_8b00_0000_0000
      );
    qp_recovery_state.query_mapping.size = 512;
    expect_status("QP_MARK_ERROR",
                  qp_rm.mark_qp_error(qp_lookup.handle, qp_recovery_state),
                  RDMA_SC_OK);
    qp_recovery_state.role_complete[RDMA_QUEUE_ROLE_QP_SQ_PD] = 1'b1;
    expect_status("QP_MARK_ERROR_LOOKUP",
                  qp_rm.lookup_recovery(qp_lookup.handle, recovery_lookup),
                  RDMA_SC_OK);
    if (recovery_lookup == null || !recovery_lookup.qp_recovery_valid ||
        recovery_lookup.qp_recovery == null ||
        recovery_lookup.hardware_presence != RDMA_HW_PRESENCE_PRESENT ||
        recovery_lookup.qp_recovery === qp_recovery_state ||
        recovery_lookup.qp_recovery.
          role_complete[RDMA_QUEUE_ROLE_QP_SQ_PD])
      `uvm_error("QP_MARK_ERROR_SNAPSHOT",
                 "QP recovery was not cloned before ERROR publication")
    expect_status("QP_ERROR_RESOURCE_LOOKUP",
                  qp_rm.lookup(qp_lookup.handle, resource), RDMA_SC_OK);
    if (resource == null || resource.state != RDMA_RESOURCE_ERROR)
      `uvm_error("QP_MARK_ERROR_ATOMIC",
                 "QP recovery and ERROR state were not published together")

    // ERROR authority retains the QPN; another allocation cannot reuse it.
    expect_status(
      "QP_CREATE_WHILE_ERROR",
      qp_rm.create_qp(qp_binding, qp_pd.handle, qp_send_cq.handle,
                      qp_recv_cq.handle, null, qp_restore), RDMA_SC_OK
    );
    if (qp_restore.local_qp_id == qp_lookup.local_qp_id)
      `uvm_error("QP_ERROR_IDENTITY_RETAINED",
                 "ERROR QPN was returned before finalization")

    expect_status("QP_FLUSH_PREDECESSOR",
                  qp_rm.record_qp_flush_complete(
                    qp_lookup.handle, RDMA_QUEUE_ROLE_QP_SQ_PD
                  ), RDMA_SC_INVALID_STATE);
    expect_status("QP_QPN_FLUSH",
                  qp_rm.record_qp_flush_complete(
                    qp_lookup.handle, RDMA_QUEUE_ROLE_QP_SQ_RING
                  ), RDMA_SC_OK);
    expect_status("QP_QPN_FLUSH_DUPLICATE",
                  qp_rm.record_qp_flush_complete(
                    qp_lookup.handle, RDMA_QUEUE_ROLE_QP_SQ_RING
                  ), RDMA_SC_INVALID_ARGUMENT);
    expect_status("QP_CONTEXT_BEFORE_REQUIRED_FLUSHES",
                  qp_rm.record_qp_context_cleanup_complete(qp_lookup.handle),
                  RDMA_SC_INVALID_STATE);
    expect_status("QP_CONTEXT_PREDECESSOR_ATOMIC_LOOKUP",
                  qp_rm.lookup_recovery(qp_lookup.handle, recovery_lookup),
                  RDMA_SC_OK);
    if (recovery_lookup == null || recovery_lookup.qp_recovery == null ||
        recovery_lookup.qp_recovery.context_ref.release_complete ||
        recovery_lookup.qp_recovery.qp_plan.context_ref.release_complete)
      `uvm_error("QP_CONTEXT_PREDECESSOR_ATOMIC",
                 "failed context predecessor changed recovery progress")
    expect_status("QP_SQ_PD_FLUSH",
                  qp_rm.record_qp_flush_complete(
                    qp_lookup.handle, RDMA_QUEUE_ROLE_QP_SQ_PD
                  ), RDMA_SC_OK);
    expect_status("QP_RQ_PD_FLUSH",
                  qp_rm.record_qp_flush_complete(
                    qp_lookup.handle, RDMA_QUEUE_ROLE_QP_RQ_PD
                  ), RDMA_SC_OK);
    expect_status("QP_CONTEXT_OPAQUE_PROOF_REQUIRED",
                  qp_rm.record_qp_context_cleanup_complete(qp_lookup.handle),
                  RDMA_SC_RECOVERY_REQUIRED);
    expect_status("QP_CONTEXT_OPAQUE_ATOMIC_LOOKUP",
                  qp_rm.lookup_recovery(qp_lookup.handle, recovery_lookup),
                  RDMA_SC_OK);
    if (recovery_lookup == null || recovery_lookup.qp_recovery == null ||
        recovery_lookup.qp_recovery.context_ref.release_complete ||
        recovery_lookup.qp_recovery.qp_plan.context_ref.release_complete)
      `uvm_error("QP_CONTEXT_OPAQUE_ATOMIC",
                 "failed opaque context proof changed recovery progress")
    expect_status("QP_CONTEXT_OPAQUE_COMPLETE",
                  qp_rm.complete_qp_context_release(qp_lookup.handle),
                  RDMA_SC_OK);
    expect_status("QP_CONTEXT_CLEANUP",
                  qp_rm.record_qp_context_cleanup_complete(qp_lookup.handle),
                  RDMA_SC_OK);
    expect_status("QP_CONTEXT_ABSENCE_LOOKUP",
                  qp_rm.lookup_recovery(qp_lookup.handle, recovery_lookup),
                  RDMA_SC_OK);
    if (recovery_lookup == null ||
        recovery_lookup.hardware_presence != RDMA_HW_PRESENCE_ABSENT)
      `uvm_error("QP_CONTEXT_ABSENCE",
                 "ERROR context completion did not persist hardware absence")
    expect_status("QP_CONTEXT_CLEANUP_DUPLICATE",
                  qp_rm.record_qp_context_cleanup_complete(qp_lookup.handle),
                  RDMA_SC_INVALID_ARGUMENT);
    expect_status("QP_BORROWED_RQ_RING_CLEANUP_REJECTED",
                  qp_rm.record_qp_cleanup_complete(
                    qp_lookup.handle, RDMA_QUEUE_ROLE_QP_RQ_RING
                  ), RDMA_SC_INVALID_ARGUMENT);
    expect_status("QP_BORROWED_SQ_RING_CLEANUP_REJECTED",
                  qp_rm.record_qp_cleanup_complete(
                    qp_lookup.handle, RDMA_QUEUE_ROLE_QP_SQ_RING
                  ), RDMA_SC_INVALID_ARGUMENT);
    expect_status("QP_SQ_PD_REVERSE_PREDECESSOR",
                  qp_rm.record_qp_cleanup_complete(
                    qp_lookup.handle, RDMA_QUEUE_ROLE_QP_SQ_PD
                  ), RDMA_SC_INVALID_STATE);
    expect_status("QP_SQ_PD_OPAQUE_COMPLETE",
                  qp_rm.complete_qp_mapping_release(
                    qp_lookup.handle, RDMA_QUEUE_ROLE_QP_SQ_PD
                  ), RDMA_SC_OK);
    expect_status("QP_SQ_PD_REVERSE_PREDECESSOR_AFTER_PROOF",
                  qp_rm.record_qp_cleanup_complete(
                    qp_lookup.handle, RDMA_QUEUE_ROLE_QP_SQ_PD
                  ), RDMA_SC_INVALID_STATE);
    expect_status("QP_SQ_PD_REVERSE_ATOMIC_LOOKUP",
                  qp_rm.lookup_recovery(qp_lookup.handle, recovery_lookup),
                  RDMA_SC_OK);
    if (recovery_lookup == null || recovery_lookup.qp_recovery == null ||
        recovery_lookup.qp_recovery.
          role_complete[RDMA_QUEUE_ROLE_QP_SQ_PD] ||
        recovery_lookup.qp_recovery.qp_plan.sq_pd_ref.cleanup_complete)
      `uvm_error("QP_SQ_PD_REVERSE_ATOMIC",
                 "rejected SQ PD cleanup changed recovery progress")
    expect_status("QP_RQ_PD_OPAQUE_PROOF_REQUIRED",
                  qp_rm.record_qp_cleanup_complete(
                    qp_lookup.handle, RDMA_QUEUE_ROLE_QP_RQ_PD
                  ), RDMA_SC_RECOVERY_REQUIRED);
    expect_status("QP_RQ_PD_OPAQUE_COMPLETE",
                  qp_rm.complete_qp_mapping_release(
                    qp_lookup.handle, RDMA_QUEUE_ROLE_QP_RQ_PD
                  ), RDMA_SC_OK);
    expect_status("QP_RQ_PD_CLEANUP",
                  qp_rm.record_qp_cleanup_complete(
                    qp_lookup.handle, RDMA_QUEUE_ROLE_QP_RQ_PD
                  ), RDMA_SC_OK);
    expect_status("QP_FINALIZE_BEFORE_ALL_BACKING",
                  qp_rm.finalize_qp_release(qp_lookup.handle),
                  RDMA_SC_RECOVERY_REQUIRED);
    expect_status("QP_SQ_PD_CLEANUP",
                  qp_rm.record_qp_cleanup_complete(
                    qp_lookup.handle, RDMA_QUEUE_ROLE_QP_SQ_PD
                  ), RDMA_SC_OK);
    expect_status("QP_SQ_PD_CLEANUP_DUPLICATE",
                  qp_rm.record_qp_cleanup_complete(
                    qp_lookup.handle, RDMA_QUEUE_ROLE_QP_SQ_PD
                  ), RDMA_SC_INVALID_ARGUMENT);
    expect_status(
      "QP_FINALIZE_CONTEXT_AUTHORITY_REPLACE",
      qp_rm.replace_qp_recovery_context_authority(qp_lookup.handle),
      RDMA_SC_OK
    );
    expect_status("QP_FINALIZE_CONTEXT_AUTHORITY_REJECTED",
                  qp_rm.finalize_qp_release(qp_lookup.handle),
                  RDMA_SC_INVALID_ARGUMENT);
    expect_status(
      "QP_FINALIZE_CONTEXT_AUTHORITY_RESTORE",
      qp_rm.restore_qp_recovery_context_authority(qp_lookup.handle),
      RDMA_SC_OK
    );
    s = qp_rm.finalize_qp_release(qp_lookup.handle);
    expect_status("QP_FINALIZE_RETAINED_QUERY_INCOMPLETE", s,
                  RDMA_SC_RECOVERY_REQUIRED);
    if (s != null && s.code == RDMA_SC_RECOVERY_REQUIRED) begin
      expect_status(
        "QP_FINALIZE_RETAINED_QUERY_COMPLETE",
        qp_rm.complete_qp_temporary_mapping_release(
          qp_lookup.handle, 1'b0
        ),
        RDMA_SC_OK
      );
      expect_status(
        "QP_FINALIZE_FORCE_HARDWARE_PRESENT",
        qp_rm.set_qp_recovery_hardware_presence(
          qp_lookup.handle, RDMA_HW_PRESENCE_PRESENT
        ),
        RDMA_SC_OK
      );
      expect_status("QP_FINALIZE_HARDWARE_ABSENCE_REQUIRED",
                    qp_rm.finalize_qp_release(qp_lookup.handle),
                    RDMA_SC_RECOVERY_REQUIRED);
      expect_status("QP_FINALIZE_HARDWARE_GATE_RESOURCE_ATOMIC",
                    qp_rm.lookup(qp_lookup.handle, resource), RDMA_SC_OK);
      expect_status("QP_FINALIZE_HARDWARE_GATE_RECOVERY_ATOMIC",
                    qp_rm.lookup_recovery(qp_lookup.handle,
                                          recovery_lookup), RDMA_SC_OK);
      if (resource == null || resource.state != RDMA_RESOURCE_ERROR ||
          recovery_lookup == null ||
          recovery_lookup.hardware_presence != RDMA_HW_PRESENCE_PRESENT)
        `uvm_error("QP_FINALIZE_HARDWARE_GATE_ATOMIC",
                   "hardware-presence rejection changed QP authority")
      expect_status(
        "QP_FINALIZE_RESTORE_HARDWARE_ABSENT",
        qp_rm.set_qp_recovery_hardware_presence(
          qp_lookup.handle, RDMA_HW_PRESENCE_ABSENT
        ),
        RDMA_SC_OK
      );
      expect_status("QP_FINALIZE_RELEASE",
                    qp_rm.finalize_qp_release(qp_lookup.handle), RDMA_SC_OK);
    end
    expect_status("QP_FINALIZE_RELEASE_DUPLICATE",
                  qp_rm.finalize_qp_release(qp_lookup.handle),
                  RDMA_SC_INVALID_STATE);

    expect_status(
      "QP_REUSE_CREATE",
      qp_rm.create_qp(qp_binding, qp_pd.handle, qp_send_cq.handle,
                      qp_recv_cq.handle, null, qp_reused), RDMA_SC_OK
    );
    if (qp_reused.local_qp_id != qp_lookup.local_qp_id)
      `uvm_error("QP_REUSE_LOCAL_ID", "finalized QPN was not reused")
    expect_status(
      "QP_SEQUENCE_REUSED",
      qp_rm.qp_sequence(qp_reused.owner, qp_reused.local_qp_id,
                        qp_sequence_reused), RDMA_SC_OK
    );
    if (qp_sequence_reused != qp_sequence_first + 8'd1)
      `uvm_error("QP_SEQUENCE_INCREMENT",
                 $sformatf("expected sequence %0d got %0d",
                           qp_sequence_first + 1'b1, qp_sequence_reused))

    // URC owned backing retires in exact reverse dependency order before
    // the ordinary private-RQ and SQ page-directory roles.
    expect_status(
      "QP_URC_CREATE",
      qp_rm.create_qp(qp_binding, qp_pd.handle, qp_send_cq.handle,
                      qp_recv_cq.handle, null, qp_urc), RDMA_SC_OK
    );
    prepare_urc_qp_candidate(qp_urc, qp_pd, qp_send_cq, qp_recv_cq,
                             "qp_urc");
    expect_status("QP_URC_ATTACH", qp_rm.attach_qp_programming(qp_urc),
                  RDMA_SC_OK);
    expect_status("QP_URC_ACTIVATE", qp_rm.activate(qp_urc.handle),
                  RDMA_SC_OK);
    qp_urc_recovery_state = make_qp_test_recovery(
      "qp_urc_destroy_recovery", qp_urc, RDMA_QP_RECOVER_NORMAL_DESTROY
    );
    expect_status("QP_URC_MARK_ERROR",
                  qp_rm.mark_qp_error(qp_urc.handle,
                                       qp_urc_recovery_state), RDMA_SC_OK);
    expect_status("QP_URC_QPN_FLUSH",
                  qp_rm.record_qp_flush_complete(
                    qp_urc.handle, RDMA_QUEUE_ROLE_QP_SQ_RING
                  ), RDMA_SC_OK);
    expect_status("QP_URC_SQ_PD_FLUSH",
                  qp_rm.record_qp_flush_complete(
                    qp_urc.handle, RDMA_QUEUE_ROLE_QP_SQ_PD
                  ), RDMA_SC_OK);
    expect_status("QP_URC_RQ_PD_FLUSH",
                  qp_rm.record_qp_flush_complete(
                    qp_urc.handle, RDMA_QUEUE_ROLE_QP_RQ_PD
                  ), RDMA_SC_OK);
    expect_status("QP_URC_CONTEXT_OPAQUE_COMPLETE",
                  qp_rm.complete_qp_context_release(qp_urc.handle),
                  RDMA_SC_OK);
    expect_status("QP_URC_CONTEXT_CLEANUP",
                  qp_rm.record_qp_context_cleanup_complete(qp_urc.handle),
                  RDMA_SC_OK);
    expect_status("QP_URC_DSQ_OPAQUE_COMPLETE",
                  qp_rm.complete_qp_mapping_release(
                    qp_urc.handle, RDMA_QUEUE_ROLE_QP_URC_DSQ
                  ), RDMA_SC_OK);
    expect_status("QP_URC_RDSQ_OPAQUE_COMPLETE",
                  qp_rm.complete_qp_mapping_release(
                    qp_urc.handle, RDMA_QUEUE_ROLE_QP_URC_RDSQ
                  ), RDMA_SC_OK);
    expect_status("QP_URC_RSQ_OPAQUE_COMPLETE",
                  qp_rm.complete_qp_mapping_release(
                    qp_urc.handle, RDMA_QUEUE_ROLE_QP_URC_RSQ
                  ), RDMA_SC_OK);
    expect_status("QP_URC_RDSQ_BEFORE_DSQ_REJECTED",
                  qp_rm.record_qp_cleanup_complete(
                    qp_urc.handle, RDMA_QUEUE_ROLE_QP_URC_RDSQ
                  ), RDMA_SC_INVALID_STATE);
    expect_status("QP_URC_RDSQ_REJECTION_ATOMIC_LOOKUP",
                  qp_rm.lookup_recovery(qp_urc.handle, recovery_lookup),
                  RDMA_SC_OK);
    if (recovery_lookup == null || recovery_lookup.qp_recovery == null ||
        recovery_lookup.qp_recovery.
          role_complete[RDMA_QUEUE_ROLE_QP_URC_DSQ] ||
        recovery_lookup.qp_recovery.
          role_complete[RDMA_QUEUE_ROLE_QP_URC_RDSQ] ||
        recovery_lookup.qp_recovery.
          role_complete[RDMA_QUEUE_ROLE_QP_URC_RSQ])
      `uvm_error("QP_URC_RDSQ_REJECTION_ATOMIC",
                 "rejected RDSQ cleanup changed URC progress")
    expect_status("QP_URC_DSQ_CLEANUP",
                  qp_rm.record_qp_cleanup_complete(
                    qp_urc.handle, RDMA_QUEUE_ROLE_QP_URC_DSQ
                  ), RDMA_SC_OK);
    expect_status("QP_URC_RSQ_BEFORE_RDSQ_REJECTED",
                  qp_rm.record_qp_cleanup_complete(
                    qp_urc.handle, RDMA_QUEUE_ROLE_QP_URC_RSQ
                  ), RDMA_SC_INVALID_STATE);
    expect_status("QP_URC_RSQ_REJECTION_ATOMIC_LOOKUP",
                  qp_rm.lookup_recovery(qp_urc.handle, recovery_lookup),
                  RDMA_SC_OK);
    if (recovery_lookup == null || recovery_lookup.qp_recovery == null ||
        !recovery_lookup.qp_recovery.
          role_complete[RDMA_QUEUE_ROLE_QP_URC_DSQ] ||
        recovery_lookup.qp_recovery.
          role_complete[RDMA_QUEUE_ROLE_QP_URC_RDSQ] ||
        recovery_lookup.qp_recovery.
          role_complete[RDMA_QUEUE_ROLE_QP_URC_RSQ])
      `uvm_error("QP_URC_RSQ_REJECTION_ATOMIC",
                 "rejected RSQ cleanup changed URC progress")
    expect_status("QP_URC_RDSQ_CLEANUP",
                  qp_rm.record_qp_cleanup_complete(
                    qp_urc.handle, RDMA_QUEUE_ROLE_QP_URC_RDSQ
                  ), RDMA_SC_OK);
    expect_status("QP_URC_RSQ_CLEANUP",
                  qp_rm.record_qp_cleanup_complete(
                    qp_urc.handle, RDMA_QUEUE_ROLE_QP_URC_RSQ
                  ), RDMA_SC_OK);
    expect_status("QP_URC_RQ_PD_OPAQUE_COMPLETE",
                  qp_rm.complete_qp_mapping_release(
                    qp_urc.handle, RDMA_QUEUE_ROLE_QP_RQ_PD
                  ), RDMA_SC_OK);
    expect_status("QP_URC_RQ_PD_CLEANUP",
                  qp_rm.record_qp_cleanup_complete(
                    qp_urc.handle, RDMA_QUEUE_ROLE_QP_RQ_PD
                  ), RDMA_SC_OK);
    expect_status("QP_URC_SQ_PD_OPAQUE_COMPLETE",
                  qp_rm.complete_qp_mapping_release(
                    qp_urc.handle, RDMA_QUEUE_ROLE_QP_SQ_PD
                  ), RDMA_SC_OK);
    expect_status("QP_URC_SQ_PD_CLEANUP",
                  qp_rm.record_qp_cleanup_complete(
                    qp_urc.handle, RDMA_QUEUE_ROLE_QP_SQ_PD
                  ), RDMA_SC_OK);
    expect_status("QP_URC_FINALIZE",
                  qp_rm.finalize_qp_release(qp_urc.handle), RDMA_SC_OK);

    // Reconciliation accepts only a complete desired ACTIVE replacement.
    // Selecting the prior QPC therefore requires its retained semantic state
    // and every unrelated QP field from the authoritative ERROR snapshot.
    prepare_qp_candidate(qp_reused, qp_pd, qp_send_cq, qp_recv_cq,
                         "qp_prior_restore");
    expect_status("QP_PRIOR_ATTACH",
                  qp_rm.attach_qp_programming(qp_reused), RDMA_SC_OK);
    expect_status("QP_PRIOR_ACTIVATE", qp_rm.activate(qp_reused.handle),
                  RDMA_SC_OK);
    expect_status("QP_PRIOR_SEMANTIC_INIT",
                  qp_rm.commit_qp_semantic_state(qp_reused.handle,
                                                  RDMA_QPS_INIT),
                  RDMA_SC_OK);
    expect_status("QP_PRIOR_LOOKUP",
                  qp_rm.lookup(qp_reused.handle, resource), RDMA_SC_OK);
    if (resource == null || !$cast(qp_reused, resource))
      `uvm_fatal("QP_PRIOR_LOOKUP", "QP prior lookup cast failed")
    qp_cloned_object = qp_reused.clone();
    if (qp_cloned_object == null ||
        !$cast(qp_prior_candidate, qp_cloned_object))
      `uvm_fatal("QP_PRIOR_CANDIDATE", "QP prior candidate clone failed")
    qp_prior_candidate.qp_state = RDMA_QPS_RTR;
    qp_prior_candidate.programmed_qpc.state = RDMA_QPS_RTR;
    qp_prior_recovery_state = make_qp_test_recovery(
      "qp_prior_recovery", qp_reused,
      RDMA_QP_RECOVER_MODIFY_RECONCILE,
      qp_prior_candidate.programmed_qpc
    );
    qp_prior_recovery_state.query_mapping =
      make_independent_queue_test_mapping(
        "qp_prior_retained_query", qp_reused.owner, qp_reused.handle,
        64'h0000_8d00_0000_0000
      );
    qp_prior_recovery_state.query_mapping.size = 512;
    expect_status("QP_PRIOR_MARK_ERROR",
                  qp_rm.mark_qp_error(qp_reused.handle,
                                       qp_prior_recovery_state),
                  RDMA_SC_OK);
    qp_cloned_object = qp_prior_recovery_state.prior_qpc.clone();
    if (qp_cloned_object == null ||
        !$cast(qp_prior_candidate.programmed_qpc, qp_cloned_object))
      `uvm_fatal("QP_PRIOR_EXPECTED_QPC", "prior QPC clone failed")
    expect_status(
      "QP_PRIOR_QUERY_OPAQUE_COMPLETE",
      qp_rm.complete_qp_temporary_mapping_release(qp_reused.handle, 1'b0),
      RDMA_SC_OK
    );
    expect_status("QP_PRIOR_SEMANTIC_MISMATCH_REJECTED",
                  qp_rm.commit_qp_programmed(qp_prior_candidate),
                  RDMA_SC_INVALID_ARGUMENT);
    expect_status("QP_PRIOR_SEMANTIC_ATOMIC_RESOURCE",
                  qp_rm.lookup(qp_reused.handle, resource), RDMA_SC_OK);
    expect_status("QP_PRIOR_SEMANTIC_ATOMIC_RECOVERY",
                  qp_rm.lookup_recovery(qp_reused.handle, recovery_lookup),
                  RDMA_SC_OK);
    if (resource == null || !$cast(qp_failed_lookup, resource) ||
        qp_failed_lookup.state != RDMA_RESOURCE_ERROR ||
        qp_failed_lookup.qp_state != RDMA_QPS_INIT ||
        qp_failed_lookup.programmed_qpc.state != RDMA_QPS_RESET ||
        recovery_lookup == null || recovery_lookup.qp_recovery == null ||
        recovery_lookup.qp_recovery.intent !=
          RDMA_QP_RECOVER_MODIFY_RECONCILE)
      `uvm_error("QP_PRIOR_SEMANTIC_ATOMIC",
                 "semantic mismatch changed registry or recovery")
    qp_prior_candidate.qp_state = RDMA_QPS_INIT;
    qp_prior_candidate.sq_producer_index = 1;
    expect_status("QP_PRIOR_INDEX_MISMATCH_REJECTED",
                  qp_rm.commit_qp_programmed(qp_prior_candidate),
                  RDMA_SC_INVALID_ARGUMENT);
    expect_status("QP_PRIOR_INDEX_ATOMIC_RESOURCE",
                  qp_rm.lookup(qp_reused.handle, resource), RDMA_SC_OK);
    expect_status("QP_PRIOR_INDEX_ATOMIC_RECOVERY",
                  qp_rm.lookup_recovery(qp_reused.handle, recovery_lookup),
                  RDMA_SC_OK);
    if (resource == null || !$cast(qp_failed_lookup, resource) ||
        qp_failed_lookup.state != RDMA_RESOURCE_ERROR ||
        qp_failed_lookup.sq_producer_index != 0 ||
        recovery_lookup == null || recovery_lookup.qp_recovery == null)
      `uvm_error("QP_PRIOR_INDEX_ATOMIC",
                 "index mismatch changed registry or recovery")
    qp_prior_candidate.sq_producer_index = 0;
    qp_prior_candidate.sq_iova.value += 4096;
    expect_status("QP_PRIOR_IOVA_MISMATCH_REJECTED",
                  qp_rm.commit_qp_programmed(qp_prior_candidate),
                  RDMA_SC_INVALID_ARGUMENT);
    expect_status("QP_PRIOR_IOVA_ATOMIC_RESOURCE",
                  qp_rm.lookup(qp_reused.handle, resource), RDMA_SC_OK);
    expect_status("QP_PRIOR_IOVA_ATOMIC_RECOVERY",
                  qp_rm.lookup_recovery(qp_reused.handle, recovery_lookup),
                  RDMA_SC_OK);
    if (resource == null || !$cast(qp_failed_lookup, resource) ||
        qp_failed_lookup.state != RDMA_RESOURCE_ERROR ||
        qp_failed_lookup.sq_iova.value != qp_reused.sq_iova.value ||
        recovery_lookup == null || recovery_lookup.qp_recovery == null)
      `uvm_error("QP_PRIOR_IOVA_ATOMIC",
                 "IOVA mismatch changed registry or recovery")
    qp_prior_candidate.sq_iova = qp_reused.sq_iova;
    expect_status("QP_PRIOR_COMMIT",
                  qp_rm.commit_qp_programmed(qp_prior_candidate),
                  RDMA_SC_OK);
    expect_status("QP_PRIOR_ACTIVE_LOOKUP",
                  qp_rm.lookup(qp_reused.handle, resource), RDMA_SC_OK);
    if (resource == null || !$cast(qp_reused, resource) ||
        qp_reused.state != RDMA_RESOURCE_ACTIVE ||
        qp_reused.qp_state != RDMA_QPS_INIT ||
        qp_reused.programmed_qpc.state != RDMA_QPS_RESET ||
        qp_reused.sq_producer_index != 0 ||
        qp_reused.sq_iova.value != qp_prior_candidate.sq_iova.value)
      `uvm_error("QP_PRIOR_SEMANTIC_RESTORE",
                 "valid prior reconciliation did not publish exact input")
    expect_status("QP_PRIOR_RECOVERY_RETIRED",
                  qp_rm.lookup_recovery(qp_reused.handle, recovery_lookup),
                  RDMA_SC_INVALID_STATE);

    // The same programmed commit is the atomic prior/candidate restoration
    // point for modify reconciliation and retires ERROR recovery metadata.
    prepare_qp_candidate(qp_restore, qp_pd, qp_send_cq, qp_recv_cq,
                         "qp_restore");
    expect_status("QP_RESTORE_ATTACH",
                  qp_rm.attach_qp_programming(qp_restore), RDMA_SC_OK);
    expect_status("QP_RESTORE_ACTIVATE", qp_rm.activate(qp_restore.handle),
                  RDMA_SC_OK);
    expect_status("QP_RESTORE_SEMANTIC_INIT",
                  qp_rm.commit_qp_semantic_state(qp_restore.handle,
                                                  RDMA_QPS_INIT),
                  RDMA_SC_OK);
    expect_status("QP_RESTORE_LOOKUP",
                  qp_rm.lookup(qp_restore.handle, resource), RDMA_SC_OK);
    if (resource == null || !$cast(qp_restore, resource))
      `uvm_fatal("QP_RESTORE_LOOKUP", "QP lookup cast failed")
    qp_cloned_object = qp_restore.clone();
    if (qp_cloned_object == null ||
        !$cast(qp_restore_candidate, qp_cloned_object))
      `uvm_fatal("QP_RESTORE_CANDIDATE", "QP candidate clone failed")
    qp_restore_candidate.qp_state = RDMA_QPS_RTR;
    qp_restore_candidate.programmed_qpc.state = RDMA_QPS_RTR;
    qp_modify_recovery_state = make_qp_test_recovery(
      "qp_modify_recovery", qp_restore,
      RDMA_QP_RECOVER_MODIFY_RECONCILE,
      qp_restore_candidate.programmed_qpc
    );
    qp_modify_recovery_state.query_mapping =
      make_independent_queue_test_mapping(
        "qp_modify_retained_query", qp_restore.owner, qp_restore.handle,
        64'h0000_8c00_0000_0000
      );
    qp_modify_recovery_state.query_mapping.size = 512;
    qp_modify_recovery_state.staging_mapping =
      make_independent_queue_test_mapping(
        "qp_modify_retained_staging", qp_restore.owner,
        qp_restore.handle, 64'h0000_8c00_0000_1000
      );
    qp_modify_recovery_state.staging_mapping.size = 512;
    qp_modify_recovery_state.ambiguous_operation = RDMA_QP_AMBIG_MODIFY;
    qp_modify_recovery_state.ambiguous_ticket = make_qp_test_ticket(
      "qp_modify_ambiguous_ticket", qp_restore.owner, qp_cmq.handle,
      qp_modify_recovery_state.modify_opcode
    );
    qp_cloned_object = qp_modify_recovery_state.clone();
    if (qp_cloned_object == null ||
        !$cast(qp_nested_recovery_state, qp_cloned_object) ||
        qp_nested_recovery_state.context_ref == null ||
        qp_nested_recovery_state.qp_plan == null ||
        qp_nested_recovery_state.qp_plan.context_ref == null ||
        !$cast(qp_nested_context_token,
               qp_nested_recovery_state.context_ref.slot_token) ||
        !$cast(qp_nested_plan_context_token,
               qp_nested_recovery_state.qp_plan.context_ref.slot_token))
      `uvm_fatal("QP_RECOVERY_CONTEXT_AUTHORITY_CLONE",
                 "QP recovery context candidate clone failed")
    qp_nested_context_authority =
      rdma_queue_completion_authority::type_id::create(
        "qp_recovery_replacement_context_authority"
      );
    qp_nested_context_token.completion_authority =
      qp_nested_context_authority;
    qp_nested_plan_context_token.completion_authority =
      qp_nested_context_authority;
    expect_status("QP_RECOVERY_CONTEXT_AUTHORITY_REJECTED",
                  qp_rm.mark_qp_error(qp_restore.handle,
                                       qp_nested_recovery_state),
                  RDMA_SC_INVALID_ARGUMENT);
    expect_status("QP_MODIFY_MARK_ERROR",
                  qp_rm.mark_qp_error(qp_restore.handle,
                                       qp_modify_recovery_state),
                  RDMA_SC_OK);
    qp_unexpected_ext = rdma_qpc_rc_ext::type_id::create(
      "qp_unexpected_rc"
    );
    qp_unexpected_ext.remote_qpn = 24'h65_4321;
    qp_restore_candidate.programmed_qpc.transport_ext = qp_unexpected_ext;
    expect_status("QP_RESTORE_UNEXPECTED_CANDIDATE",
                  qp_rm.commit_qp_programmed(qp_restore_candidate),
                  RDMA_SC_INVALID_ARGUMENT);
    expect_status("QP_RESTORE_UNEXPECTED_ATOMIC_RESOURCE",
                  qp_rm.lookup(qp_restore.handle, resource), RDMA_SC_OK);
    expect_status("QP_RESTORE_UNEXPECTED_ATOMIC_RECOVERY",
                  qp_rm.lookup_recovery(qp_restore.handle, recovery_lookup),
                  RDMA_SC_OK);
    if (resource == null || !$cast(qp_failed_lookup, resource) ||
        qp_failed_lookup.state != RDMA_RESOURCE_ERROR ||
        qp_failed_lookup.qp_state != RDMA_QPS_INIT ||
        recovery_lookup == null || recovery_lookup.qp_recovery == null ||
        recovery_lookup.qp_recovery.ambiguous_operation !=
          RDMA_QP_AMBIG_MODIFY)
      `uvm_error("QP_RESTORE_UNEXPECTED_ATOMIC",
                 "unexpected QPC changed registry or recovery")
    qp_cloned_object = qp_modify_recovery_state.candidate_qpc.clone();
    if (qp_cloned_object == null ||
        !$cast(qp_restore_candidate.programmed_qpc, qp_cloned_object))
      `uvm_fatal("QP_RESTORE_EXPECTED_CANDIDATE", "QPC clone failed")
    qp_restore_candidate.qp_state = RDMA_QPS_RTR;
    s = qp_rm.commit_qp_programmed(qp_restore_candidate);
    expect_status("QP_RESTORE_QUERY_COMPLETION_REQUIRED", s,
                  RDMA_SC_RECOVERY_REQUIRED);
    if (s != null && s.code == RDMA_SC_RECOVERY_REQUIRED) begin
      expect_status("QP_RESTORE_QUERY_ATOMIC_RESOURCE",
                    qp_rm.lookup(qp_restore.handle, resource), RDMA_SC_OK);
      if (resource == null || !$cast(qp_restore, resource) ||
          qp_restore.state != RDMA_RESOURCE_ERROR ||
          qp_restore.qp_state != RDMA_QPS_INIT ||
          qp_restore.programmed_qpc.state != RDMA_QPS_RESET)
        `uvm_error("QP_RESTORE_QUERY_ATOMIC_RESOURCE",
                   "query-gated reconciliation changed the registry QP")
      expect_status("QP_RESTORE_QUERY_ATOMIC_RECOVERY",
                    qp_rm.lookup_recovery(qp_restore.handle,
                                          recovery_lookup),
                    RDMA_SC_OK);
      if (recovery_lookup == null || recovery_lookup.qp_recovery == null ||
          recovery_lookup.qp_recovery.query_mapping == null ||
          recovery_lookup.qp_recovery.ambiguous_operation !=
            RDMA_QP_AMBIG_MODIFY)
        `uvm_error("QP_RESTORE_QUERY_ATOMIC_RECOVERY",
                   "query-gated reconciliation changed recovery")
      expect_status(
        "QP_RESTORE_QUERY_OPAQUE_COMPLETE",
        qp_rm.complete_qp_temporary_mapping_release(
          qp_restore.handle, 1'b0
        ),
        RDMA_SC_OK
      );
      s = qp_rm.commit_qp_programmed(qp_restore_candidate);
      expect_status("QP_RESTORE_STAGING_COMPLETION_REQUIRED", s,
                    RDMA_SC_RECOVERY_REQUIRED);
      if (s != null && s.code == RDMA_SC_RECOVERY_REQUIRED) begin
        expect_status("QP_RESTORE_STAGING_ATOMIC_RESOURCE",
                      qp_rm.lookup(qp_restore.handle, resource), RDMA_SC_OK);
        expect_status("QP_RESTORE_STAGING_ATOMIC_RECOVERY",
                      qp_rm.lookup_recovery(qp_restore.handle,
                                            recovery_lookup), RDMA_SC_OK);
        if (resource == null || !$cast(qp_failed_lookup, resource) ||
            qp_failed_lookup.state != RDMA_RESOURCE_ERROR ||
            recovery_lookup == null || recovery_lookup.qp_recovery == null ||
            recovery_lookup.qp_recovery.staging_mapping == null)
          `uvm_error("QP_RESTORE_STAGING_ATOMIC",
                     "staging-gated reconciliation changed authority")
        expect_status(
          "QP_RESTORE_STAGING_OPAQUE_COMPLETE",
          qp_rm.complete_qp_temporary_mapping_release(
            qp_restore.handle, 1'b1
          ),
          RDMA_SC_OK
        );
        s = qp_rm.commit_qp_programmed(qp_restore_candidate);
        expect_status("QP_RESTORE_AMBIGUITY_RESOLUTION_REQUIRED", s,
                      RDMA_SC_RECOVERY_REQUIRED);
        if (s != null && s.code == RDMA_SC_RECOVERY_REQUIRED) begin
          expect_status("QP_RESTORE_AMBIGUITY_ATOMIC_RESOURCE",
                        qp_rm.lookup(qp_restore.handle, resource),
                        RDMA_SC_OK);
          if (resource == null || !$cast(qp_restore, resource) ||
              qp_restore.state != RDMA_RESOURCE_ERROR ||
              qp_restore.qp_state != RDMA_QPS_INIT ||
              qp_restore.programmed_qpc.state != RDMA_QPS_RESET)
            `uvm_error("QP_RESTORE_AMBIGUITY_ATOMIC_RESOURCE",
                       "ambiguity-gated reconciliation changed the QP")
          expect_status("QP_RESTORE_AMBIGUITY_ATOMIC_RECOVERY",
                        qp_rm.lookup_recovery(qp_restore.handle,
                                              recovery_lookup),
                        RDMA_SC_OK);
          if (recovery_lookup == null ||
              recovery_lookup.qp_recovery == null ||
              recovery_lookup.qp_recovery.ambiguous_operation !=
                RDMA_QP_AMBIG_MODIFY ||
              recovery_lookup.qp_recovery.ambiguous_ticket == null)
            `uvm_error("QP_RESTORE_AMBIGUITY_ATOMIC_RECOVERY",
                       "ambiguity-gated reconciliation retired recovery")
          qp_cloned_object = recovery_lookup.qp_recovery.clone();
          if (qp_cloned_object == null ||
              !$cast(qp_nested_recovery_state, qp_cloned_object))
            `uvm_fatal("QP_RESTORE_QUERY_AUTHORITY_CLONE",
                       "modify query recovery clone failed")
          qp_nested_recovery_state.ambiguous_operation =
            RDMA_QP_AMBIG_NONE;
          qp_nested_recovery_state.ambiguous_ticket = null;
          qp_nested_recovery_state.query_mapping =
            make_independent_queue_test_mapping(
              "qp_restore_wrong_query_authority", qp_restore.owner,
              qp_restore.handle,
              recovery_lookup.qp_recovery.query_mapping.iova.value
            );
          qp_nested_recovery_state.query_mapping.size = 512;
          expect_status("QP_RESTORE_QUERY_AUTHORITY_REJECTED",
                        qp_rm.mark_qp_error(qp_restore.handle,
                                             qp_nested_recovery_state),
                        RDMA_SC_INVALID_ARGUMENT);
          qp_cloned_object = recovery_lookup.qp_recovery.clone();
          if (qp_cloned_object == null ||
              !$cast(qp_error_replacement, qp_cloned_object))
            `uvm_fatal("QP_RESTORE_AMBIGUITY_CLONE",
                       "modify recovery clone failed")
          qp_error_replacement.ambiguous_operation = RDMA_QP_AMBIG_NONE;
          qp_error_replacement.ambiguous_ticket = null;
          expect_status("QP_RESTORE_AMBIGUITY_RESOLVE",
                        qp_rm.mark_qp_error(qp_restore.handle,
                                             qp_error_replacement),
                        RDMA_SC_OK);
          expect_status("QP_RESTORE_CANDIDATE_COMMIT",
                        qp_rm.commit_qp_programmed(qp_restore_candidate),
                        RDMA_SC_OK);
        end
      end
    end
    expect_status("QP_RESTORE_ACTIVE_LOOKUP",
                  qp_rm.lookup(qp_restore.handle, resource), RDMA_SC_OK);
    if (resource == null || !$cast(qp_restore, resource) ||
        qp_restore.state != RDMA_RESOURCE_ACTIVE ||
        qp_restore.qp_state != RDMA_QPS_RTR ||
        qp_restore.programmed_qpc.state != RDMA_QPS_RTR)
      `uvm_error("QP_RESTORE_ACTIVE",
                 "modify reconciliation did not restore ACTIVE candidate")
    expect_status("QP_RESTORE_RECOVERY_RETIRED",
                  qp_rm.lookup_recovery(qp_restore.handle, recovery_lookup),
                  RDMA_SC_INVALID_STATE);

    // Terminal mutation probe: retained-candidate equality includes nested
    // address-vector and behavior values before any recovery gates run.
    qp_cloned_object = qp_restore.clone();
    if (qp_cloned_object == null ||
        !$cast(qp_nested_candidate, qp_cloned_object))
      `uvm_fatal("QP_NESTED_QPC_CANDIDATE",
                 "nested QPC candidate clone failed")
    qp_nested_candidate.qp_state = RDMA_QPS_RTS;
    qp_nested_candidate.programmed_qpc.state = RDMA_QPS_RTS;
    qp_nested_recovery_state = make_qp_test_recovery(
      "qp_nested_qpc_recovery", qp_restore,
      RDMA_QP_RECOVER_MODIFY_RECONCILE,
      qp_nested_candidate.programmed_qpc
    );
    expect_status("QP_NESTED_QPC_MARK_ERROR",
                  qp_rm.mark_qp_error(qp_restore.handle,
                                       qp_nested_recovery_state),
                  RDMA_SC_OK);
    qp_cloned_object = qp_nested_recovery_state.candidate_qpc.clone();
    if (qp_cloned_object == null ||
        !$cast(qp_nested_candidate.programmed_qpc, qp_cloned_object))
      `uvm_fatal("QP_NESTED_ADDRESS_VECTOR_CANDIDATE",
                 "address-vector QPC clone failed")
    qp_nested_candidate.programmed_qpc.address_vector.hop_limit++;
    expect_status("QP_NESTED_ADDRESS_VECTOR_REJECTED",
                  qp_rm.commit_qp_programmed(qp_nested_candidate),
                  RDMA_SC_INVALID_ARGUMENT);
    expect_status("QP_NESTED_ADDRESS_VECTOR_ATOMIC_RESOURCE",
                  qp_rm.lookup(qp_restore.handle, resource), RDMA_SC_OK);
    expect_status("QP_NESTED_ADDRESS_VECTOR_ATOMIC_RECOVERY",
                  qp_rm.lookup_recovery(qp_restore.handle, recovery_lookup),
                  RDMA_SC_OK);
    if (resource == null || !$cast(qp_failed_lookup, resource) ||
        qp_failed_lookup.state != RDMA_RESOURCE_ERROR ||
        qp_failed_lookup.programmed_qpc.state != RDMA_QPS_RTR ||
        recovery_lookup == null || recovery_lookup.qp_recovery == null)
      `uvm_error("QP_NESTED_ADDRESS_VECTOR_ATOMIC",
                 "address-vector rejection changed authority")
    qp_cloned_object = qp_nested_recovery_state.candidate_qpc.clone();
    if (qp_cloned_object == null ||
        !$cast(qp_nested_candidate.programmed_qpc, qp_cloned_object))
      `uvm_fatal("QP_NESTED_BEHAVIOR_CANDIDATE",
                 "behavior QPC clone failed")
    qp_nested_candidate.programmed_qpc.behavior.migration_enable =
      !qp_nested_candidate.programmed_qpc.behavior.migration_enable;
    expect_status("QP_NESTED_BEHAVIOR_REJECTED",
                  qp_rm.commit_qp_programmed(qp_nested_candidate),
                  RDMA_SC_INVALID_ARGUMENT);
    expect_status("QP_NESTED_BEHAVIOR_ATOMIC_RESOURCE",
                  qp_rm.lookup(qp_restore.handle, resource), RDMA_SC_OK);
    expect_status("QP_NESTED_BEHAVIOR_ATOMIC_RECOVERY",
                  qp_rm.lookup_recovery(qp_restore.handle, recovery_lookup),
                  RDMA_SC_OK);
    if (resource == null || !$cast(qp_failed_lookup, resource) ||
        qp_failed_lookup.state != RDMA_RESOURCE_ERROR ||
        qp_failed_lookup.programmed_qpc.state != RDMA_QPS_RTR ||
        recovery_lookup == null || recovery_lookup.qp_recovery == null)
      `uvm_error("QP_NESTED_BEHAVIOR_ATOMIC",
                 "behavior rejection changed authority")

    phase.drop_objection(this);
  endtask
endclass
