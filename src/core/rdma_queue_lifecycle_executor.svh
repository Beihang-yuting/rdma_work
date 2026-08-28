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
  protected rdma_xtr_v1_queue_pd_codec pd_codec;

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
    pd_codec = rdma_xtr_v1_queue_pd_codec::type_id::create({name, "_pd"});
  endfunction

  protected function rdma_status invalid_argument(string message);
    return rdma_status::make(RDMA_SC_INVALID_ARGUMENT, message);
  endfunction

  protected function rdma_status invalid_state(string message);
    return rdma_status::make(RDMA_SC_INVALID_STATE, message);
  endfunction

  protected function rdma_status normalize_status(
    rdma_status status, string null_message
  );
    if (status == null)
      return invalid_state(null_message);
    return status;
  endfunction

  protected function bit cmq_outcome_ambiguous(
    rdma_status status,
    rdma_cmq_completion completion
  );
    if (status == null || completion == null || completion.status == null)
      return 1'b1;
    return status.code inside {RDMA_SC_TIMEOUT, RDMA_SC_RESET_CANCELLED} ||
           completion.status.code inside {
             RDMA_SC_TIMEOUT, RDMA_SC_RESET_CANCELLED
           };
  endfunction

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

  protected function rdma_control_result make_result(
    longint unsigned transaction_id
  );
    rdma_control_result result;
    result = rdma_control_result::type_id::create("queue_create_result");
    result.transaction_id = transaction_id;
    return result;
  endfunction

  protected function bit same_owner(
    rdma_function_handle lhs, rdma_function_handle rhs
  );
    return lhs != null && rhs != null && lhs.same_instance(rhs);
  endfunction

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
    uvm_object cloned_object;

    builder_resource = null;
    if (!$cast(cq, authoritative))
      return invalid_argument("CQ builder projection requires a CQ");
    cloned_object = cq.clone();
    if (cloned_object == null || !$cast(builder_cq, cloned_object) ||
        builder_cq == cq)
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
    uvm_object cloned_object;

    builder_resource = null;
    if (!$cast(srq, authoritative) || srq.pd_h == null)
      return invalid_argument("SRQ builder projection requires SRQ PD");
    cloned_object = srq.clone();
    if (cloned_object == null || !$cast(builder_srq, cloned_object) ||
        builder_srq == srq)
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

  protected function bit [7:0] delete_opcode(rdma_resource_kind_e kind);
    case (kind)
      RDMA_RESOURCE_CQ:  return XTR_V1_OP_CQC_DELETE;
      RDMA_RESOURCE_SRQ: return XTR_V1_OP_SRFQC_DELETE;
      RDMA_RESOURCE_CEQ: return XTR_V1_OP_CEQC_DELETE;
      RDMA_RESOURCE_AEQ: return XTR_V1_OP_AEQC_DELETE;
      default:           return 8'h00;
    endcase
  endfunction

  protected function bit [7:0] create_opcode(rdma_resource_kind_e kind);
    case (kind)
      RDMA_RESOURCE_CQ:  return XTR_V1_OP_CQC_CREATE;
      RDMA_RESOURCE_SRQ: return XTR_V1_OP_SRFQC_CREATE;
      RDMA_RESOURCE_CEQ: return XTR_V1_OP_CEQC_CREATE;
      RDMA_RESOURCE_AEQ: return XTR_V1_OP_AEQC_CREATE;
      default:           return 8'h00;
    endcase
  endfunction

  protected function bit [7:0] query_opcode(rdma_resource_kind_e kind);
    case (kind)
      RDMA_RESOURCE_CQ:  return XTR_V1_OP_CQC_QUERY;
      RDMA_RESOURCE_SRQ: return XTR_V1_OP_SRFQC_QUERY;
      RDMA_RESOURCE_CEQ: return XTR_V1_OP_CEQC_QUERY;
      RDMA_RESOURCE_AEQ: return XTR_V1_OP_AEQC_QUERY;
      default:           return 8'h00;
    endcase
  endfunction

  protected function void append_rollback(
    rdma_control_result result, rdma_status status
  );
    if (result != null && status != null)
      result.rollback_statuses.push_back(
        rdma_cmq_clone_status_value(status)
      );
  endfunction

  protected function rdma_status cleanup_local(
    rdma_queue_backing_plan plan,
    rdma_control_result result,
    bit record_progress,
    rdma_handle resource_h
  );
    rdma_status status;
    rdma_status first_failure;
    bit complete;
    bit released_any;

    first_failure = null;
    released_any = 1'b0;
    if (plan == null)
      return rdma_status::success();
    if (plan.context_ref != null && !plan.context_ref.release_complete) begin
      status = normalize_status(context_backing.\release (plan.context_ref),
                                "queue context release returned null");
      if (!status.ok()) begin
        append_rollback(result, status);
        if (first_failure == null) first_failure = status;
      end
      else begin
        released_any = 1'b1;
        if (record_progress) begin
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
    output rdma_recovery_record recovery
  );
    rdma_cmq_command_desc delete_command;
    rdma_cmq_command_desc query_command;
    rdma_status status;

    recovery = null;
    if (policy == null || resource == null || plan == null ||
        primary == null || result == null)
      return invalid_argument("queue recovery input is incomplete");
    status = normalize_status(policy.build_object_command(
      delete_opcode(resource.resource_kind()), resource.owner, resource,
      command_timeout, delete_command
    ), "queue recovery delete descriptor returned null");
    if (!status.ok()) return status;
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
    recovery.ambiguous_ticket = rdma_cmq_clone_ticket_value(
      ticket, "queue recovery"
    );
    recovery.primary_status = rdma_cmq_clone_status_value(primary);
    recovery.rollback_statuses = result.rollback_statuses;
    recovery.queue_recovery_valid = 1'b1;
    recovery.queue_intent = RDMA_QUEUE_RECOVER_CREATE_ROLLBACK;
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
      recovery.queue_create_opcode.profile_name = "xtr_v1";
      recovery.queue_create_opcode.opcode =
        create_opcode(resource.resource_kind());
      recovery.queue_create_opcode.variant = "create";
    end
    recovery.queue_delete_opcode = rdma_cmq_clone_opcode_key_value(
      delete_command.opcode_key, "queue recovery delete"
    );
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

  protected function void retain_recovery(
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
    output rdma_queue_resource queue
  );
    rdma_recovery_record recovery;
    rdma_resource snapshot;
    rdma_status status;

    queue = null;
    status = build_recovery(policy, resource, plan, create_command, primary,
                            result, presence, ambiguous_operation, ticket,
                            pending_delete, pending_local_cleanup, recovery);
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
      1'b0, 1'b0, recovery
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

  protected task rollback_created(
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
    rdma_hw_presence_e presence;
    bit ambiguous;

    queue = null;
    foreach (plan.flush_targets[i]) begin
      if (plan.flush_targets[i] == null ||
          plan.flush_targets[i].phase != RDMA_QUEUE_FLUSH_PRE_DELETE ||
          plan.flush_targets[i].flush_complete)
        continue;
      status = normalize_status(policy.build_flush_command(
        resource.owner, plan.flush_targets[i], command_timeout, command
      ), "queue rollback pre-delete flush descriptor returned null");
      if (status.ok()) begin
        ticket = null;
        completion = null;
        cmq.execute(command, ticket, completion, status);
        ambiguous = cmq_outcome_ambiguous(status, completion);
        status = normalize_status(status,
          "queue rollback pre-delete flush result was lost");
        if (status.ok() &&
            (completion == null || completion.status == null))
          status = invalid_state("queue rollback pre-delete flush completion was lost");
      end
      else ambiguous = 1'b0;
      if (!status.ok()) begin
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
      append_rollback(result, status);
      retain_recovery(policy, resource, plan, create_command, primary, result,
                      RDMA_HW_PRESENCE_PRESENT, RDMA_QUEUE_AMBIG_NONE, null,
                      1'b1, 1'b1, queue);
      return;
    end
    ticket = null;
    completion = null;
    cmq.execute(command, ticket, completion, status);
    ambiguous = cmq_outcome_ambiguous(status, completion);
    status = normalize_status(status, "queue rollback delete result was lost");
    if (status.ok() &&
        (completion == null || completion.status == null))
      status = invalid_state("queue rollback delete completion was lost");
    if (!status.ok()) begin
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
        ticket = null;
        completion = null;
        cmq.execute(command, ticket, completion, status);
        ambiguous = cmq_outcome_ambiguous(status, completion);
        status = normalize_status(status,
                                  "queue rollback post-delete flush result was lost");
        if (status.ok() &&
            (completion == null || completion.status == null))
          status = invalid_state(
            "queue rollback post-delete flush completion was lost"
          );
      end
      else ambiguous = 1'b0;
      if (!status.ok()) begin
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
                              recovery);
      if (status.ok())
        status = normalize_status(manager.mark_error(resource.handle, recovery),
                                  "programmed queue mark ERROR returned null");
      if (!status.ok()) begin
        append_rollback(result, status);
        publish_failure(primary, result, RDMA_RESOURCE_ERROR, 1'b0, 1'b1);
        return;
      end
    end
    status = cleanup_local(plan, result, registry_programmed,
                           resource.handle);
    if (!status.ok()) begin
      retain_recovery(policy, resource, plan, create_command, primary, result,
                      RDMA_HW_PRESENCE_ABSENT, RDMA_QUEUE_AMBIG_NONE, null,
                      1'b0, 1'b1, queue);
      return;
    end
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

  protected function void rollback_local(
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
    status = cleanup_local(plan, result, 1'b0,
                           resource == null ? null : resource.handle);
    if (!status.ok() && resource != null && plan != null) begin
      retain_recovery(policy, resource, plan, create_command, primary, result,
                      RDMA_HW_PRESENCE_ABSENT, RDMA_QUEUE_AMBIG_NONE, null,
                      1'b0, 1'b1, queue);
      return;
    end
    if (resource != null) begin
      status = normalize_status(manager.release_reserved(resource.handle),
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
      status = generation_status(binding, expected_owner);
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
      if (!status.ok()) begin
        rollback_local(policy, reserved, null, create_command, status, result,
                       queue);
        return;
      end
      status = normalize_status(planner.materialize(
        binding, preflight, reserved.handle, plan
      ), "queue planner materialize returned null");
      if (!status.ok()) begin
        rollback_local(policy, reserved, null, create_command, status, result,
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
            rollback_local(policy, reserved, plan, create_command, status,
                           result, queue);
            return;
          end
          local_id = cq.local_cq_id;
        end
        else begin
          rdma_srq srq;
          if (!$cast(srq, reserved)) begin
            status = invalid_state("reserved SRQ type was lost");
            rollback_local(policy, reserved, plan, create_command, status,
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
          rollback_local(policy, reserved, plan, create_command, status,
                         result, queue);
          return;
        end
        plan.context_ref = context_ref;
        result.completed_steps.push_back(RDMA_CTRL_STEP_HMC_ATTACHED);
      end
      reserved.queue_plan = plan;
      status = normalize_status(manager.stage_allocated(reserved),
                                "queue stage allocated returned null");
      if (!status.ok()) begin
        rollback_local(policy, reserved, plan, create_command, status, result,
                       queue);
        return;
      end
      status = initialize_plan(binding, plan);
      if (!status.ok()) begin
        rollback_local(policy, reserved, plan, create_command, status, result,
                       queue);
        return;
      end
      builder_resource = reserved;
      if (reserved.resource_kind() == RDMA_RESOURCE_CQ) begin
        status = cq_builder_view(reserved, builder_resource);
        if (!status.ok()) begin
          rollback_local(policy, reserved, plan, create_command, status,
                         result, queue);
          return;
        end
      end
      else if (reserved.resource_kind() == RDMA_RESOURCE_SRQ) begin
        status = srq_builder_view(reserved, builder_resource);
        if (!status.ok()) begin
          rollback_local(policy, reserved, plan, create_command, status,
                         result, queue);
          return;
        end
      end
      status = normalize_status(policy.build_create_context(
        builder_resource, plan, context_model, slot_image, shadow_image
      ), "queue context builder returned null");
      if (!status.ok()) begin
        rollback_local(policy, reserved, plan, create_command, status, result,
                       queue);
        return;
      end
      if (reserved.resource_kind() inside {RDMA_RESOURCE_CQ,
                                           RDMA_RESOURCE_SRQ}) begin
        if (plan.context_ref == null ||
            slot_image.size() < plan.context_ref.slot_length) begin
          status = invalid_state("queue context image is smaller than slot");
          rollback_local(policy, reserved, plan, create_command, status,
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
          rollback_local(policy, reserved, plan, create_command, status,
                         result, queue);
          return;
        end
      end
      status = normalize_status(policy.build_create_command(
        expected_owner, reserved, context_model, command_timeout,
        create_command
      ), "queue create descriptor returned null");
      if (!status.ok()) begin
        rollback_local(policy, reserved, plan, create_command, status, result,
                       queue);
        return;
      end
      ticket = null;
      completion = null;
      cmq.execute(create_command, ticket, completion, status);
      cmq_ambiguous = cmq_outcome_ambiguous(status, completion);
      status = normalize_status(status, "queue create result was lost");
      if (status.ok() &&
          (completion == null || completion.status == null))
        status = invalid_state("queue create completion was lost");
      if (!status.ok()) begin
        primary = rdma_cmq_clone_status_value(status);
        if (cmq_ambiguous) begin
          retain_recovery(policy, reserved, plan, create_command, primary,
                          result, RDMA_HW_PRESENCE_UNKNOWN,
                          RDMA_QUEUE_AMBIG_CREATE, ticket, 1'b1, 1'b1, queue);
        end
        else begin
          rollback_local(policy, reserved, plan, create_command, primary,
                         result, queue);
        end
        return;
      end
      result.completed_steps.push_back(RDMA_CTRL_STEP_HW_CONTEXT_CREATED);
      status = generation_status(binding, expected_owner);
      if (!status.ok()) begin
        rollback_created(policy, reserved, plan, create_command, status,
                         result, 1'b0, queue);
        return;
      end
      status = normalize_status(manager.commit_programmed(reserved),
                                "queue commit programmed returned null");
      if (!status.ok()) begin
        rollback_created(policy, reserved, plan, create_command, status,
                         result, 1'b0, queue);
        return;
      end
      result.completed_steps.push_back(RDMA_CTRL_STEP_REGISTRY_PROGRAMMED);
      result.final_resource_state = RDMA_RESOURCE_PROGRAMMED;
      status = normalize_status(manager.activate(reserved.handle),
                                "queue activate returned null");
      if (!status.ok()) begin
        rollback_created(policy, reserved, plan, create_command, status,
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
        rollback_created(policy, reserved, plan, create_command, status,
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

  // Queue destruction is intentionally not routed through recovery until the
  // dedicated delete/recovery transaction is introduced.  Keeping this
  // locked entry point makes the facade use the same ownership boundary as
  // create without inventing a second control-plane lock domain.
  task destroy_locked(
    rdma_function_binding binding,
    rdma_function_handle expected_owner,
    rdma_destroy_resource_req request,
    longint unsigned transaction_id,
    output rdma_control_result result
  );
    rdma_status status;

    result = make_result(transaction_id);
    if (transaction_id == 0)
      status = invalid_argument("queue transaction ID is zero");
    else if (binding == null || expected_owner == null || request == null ||
             request.target_h == null)
      status = invalid_argument("queue destroy authority is incomplete");
    else begin
      result.resource_h = rdma_clone_handle_value(
        request.target_h, "queue destroy result"
      );
      status = rdma_status::make(
        RDMA_SC_UNSUPPORTED_OPCODE,
        "queue destroy transaction is not implemented"
      );
    end
    publish_failure(status, result, RDMA_RESOURCE_NEW, 1'b0, 1'b0);
  endtask
endclass
