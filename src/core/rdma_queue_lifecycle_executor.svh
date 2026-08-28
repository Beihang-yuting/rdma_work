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
    rdma_cmq_ticket ticket,
    rdma_cmq_completion completion
  );
    // A null status means the adapter did not provide an outcome at all.  A
    // timeout/reset is inherently ambiguous even when the adapter did return
    // a status.  A missing ticket/completion is ambiguous by default: status
    // code alone cannot prove that a destructive command was rejected before
    // submission.  Only an explicit adapter proof may make that a definitive
    // no-submit outcome and permit ACTIVE restoration.
    if (status == null)
      return 1'b1;
    if (status.code inside {RDMA_SC_TIMEOUT, RDMA_SC_RESET_CANCELLED})
      return 1'b1;
    if (completion != null && completion.status != null &&
        completion.status.code inside {RDMA_SC_TIMEOUT,
                                       RDMA_SC_RESET_CANCELLED})
      return 1'b1;
    if (completion == null || completion.status == null) begin
      if (status.ok() || ticket != null)
        return 1'b1;
      return cmq == null || !cmq.last_execute_definitive_no_submit();
    end
    return 1'b0;
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

  // Named checkpoint used by lifecycle paths at lock/terminal boundaries.
  // Keeping it virtual lets tests inject a rebind while a CMQ gate is held
  // without mutating transaction-local authority.
  protected virtual function rdma_status live_binding_fence(
    rdma_function_binding binding,
    rdma_function_handle expected_owner
  );
    return generation_status(binding, expected_owner);
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
      bit context_complete;

      context_complete = 1'b0;
      if (context_backing == null) begin
        status = invalid_state("queue context backing adapter is unavailable");
      end
      else begin
        // A context release can complete remotely while the process is
        // between the adapter call and its durable progress update.  Always
        // consult the opaque completion authority first so a retry never
        // invokes release twice.
        status = normalize_status(
          context_backing.query_release_completion(
            plan.context_ref, context_complete
          ), "queue context completion query returned null"
        );
        if (status.ok() && !context_complete)
          status = normalize_status(
            context_backing.\release (plan.context_ref),
            "queue context release returned null"
          );
        if (status.ok()) begin
          context_complete = 1'b0;
          status = normalize_status(
            context_backing.query_release_completion(
              plan.context_ref, context_complete
            ), "queue context completion recheck returned null"
          );
          if (status.ok() && !context_complete)
            status = invalid_state("queue context release did not complete");
        end
      end
      if (!status.ok()) begin
        append_rollback(result, status);
        if (first_failure == null) first_failure = status;
      end
      else begin
        released_any = 1'b1;
        if (record_progress) begin
          // Persist the context completion immediately after its physical
          // release.  This leaves an authoritative proof in the manager even
          // if a later backing role fails and recovery must resume.
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
    rdma_queue_recovery_intent_e intent,
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
    // A ticket is retained only when the adapter reported an ambiguous
    // outcome.  Definitive failures still return a ticket in many CMQ
    // adapters, but that ticket is not evidence awaiting reconciliation; if
    // it were persisted here, recovery would stop waiting for a terminal
    // result and never retry the failed operation.
    recovery.ambiguous_ticket = ambiguous_operation == RDMA_QUEUE_AMBIG_NONE ?
      null : rdma_cmq_clone_ticket_value(ticket, "queue recovery");
    recovery.primary_status = rdma_cmq_clone_status_value(primary);
    recovery.rollback_statuses = result.rollback_statuses;
    recovery.queue_recovery_valid = 1'b1;
    recovery.queue_intent = intent;
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

  protected function void retain_recovery_int(
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
    rdma_queue_recovery_intent_e intent,
    output rdma_queue_resource queue
  );
    rdma_recovery_record recovery;
    rdma_resource snapshot;
    rdma_status status;

    queue = null;
    status = build_recovery(policy, resource, plan, create_command, primary,
                            result, presence, ambiguous_operation, ticket,
                            pending_delete, pending_local_cleanup, intent, recovery);
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

  protected function void retain_recovery(
    rdma_queue_lifecycle_policy policy, rdma_queue_resource resource,
    rdma_queue_backing_plan plan, rdma_cmq_command_desc create_command,
    rdma_status primary, rdma_control_result result, rdma_hw_presence_e presence,
    rdma_queue_ambiguous_operation_e ambiguous_operation, rdma_cmq_ticket ticket,
    bit pending_delete, bit pending_local_cleanup, output rdma_queue_resource queue
  );
    retain_recovery_int(policy, resource, plan, create_command, primary, result,
                        presence, ambiguous_operation, ticket,
                        pending_delete, pending_local_cleanup,
                        RDMA_QUEUE_RECOVER_CREATE_ROLLBACK, queue);
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
      1'b0, 1'b0, RDMA_QUEUE_RECOVER_CREATE_ROLLBACK, recovery
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

  // Recovery metadata is intentionally manipulated through small, local
  // helpers rather than relying on queue ordering in pending_steps.  The
  // latter is a coarse transaction history; the authoritative per-role
  // completion bits live in queue_plan and are updated atomically by the
  // resource manager.
  protected function bit recovery_step_completed(
    rdma_recovery_record recovery,
    rdma_control_step_e step
  );
    if (recovery == null)
      return 1'b0;
    foreach (recovery.completed_steps[i])
      if (recovery.completed_steps[i] == step)
        return 1'b1;
    return 1'b0;
  endfunction

  protected function bit recovery_step_pending(
    rdma_recovery_record recovery,
    rdma_control_step_e step
  );
    if (recovery == null)
      return 1'b0;
    foreach (recovery.pending_steps[i])
      if (recovery.pending_steps[i] == step)
        return 1'b1;
    return 1'b0;
  endfunction

  protected function void recovery_remove_step(
    rdma_recovery_record recovery,
    rdma_control_step_e step
  );
    if (recovery == null)
      return;
    for (int i = int'(recovery.pending_steps.size()) - 1; i >= 0; i--)
      if (recovery.pending_steps[i] == step)
        recovery.pending_steps.delete(i);
  endfunction

  protected function void recovery_complete_step(
    rdma_recovery_record recovery,
    rdma_control_step_e step
  );
    if (recovery == null)
      return;
    recovery_remove_step(recovery, step);
    if (!recovery_step_completed(recovery, step))
      recovery.completed_steps.push_back(step);
  endfunction

  protected function void recovery_queue_step(
    rdma_recovery_record recovery,
    rdma_control_step_e step
  );
    if (recovery == null || recovery_step_completed(recovery, step) ||
        recovery_step_pending(recovery, step))
      return;
    recovery.pending_steps.push_back(step);
  endfunction

  protected function rdma_status queue_policy_for_kind(
    rdma_resource_kind_e kind,
    output rdma_queue_lifecycle_policy policy
  );
    policy = null;
    case (kind)
      RDMA_RESOURCE_CQ:  policy = cq_policy;
      RDMA_RESOURCE_SRQ: policy = srq_policy;
      RDMA_RESOURCE_CEQ: policy = ceq_policy;
      RDMA_RESOURCE_AEQ: policy = aeq_policy;
      default:
        return rdma_status::make(RDMA_SC_UNSUPPORTED_OPCODE,
                                 "queue recovery kind is unsupported");
    endcase
    if (policy == null)
      return invalid_state("queue recovery policy is unavailable");
    return rdma_status::success();
  endfunction

  protected function void project_queue_recovery_result(
    rdma_recovery_record recovery,
    rdma_control_result result
  );
    if (recovery == null || result == null)
      return;
    result.completed_steps = recovery.completed_steps;
    result.primary_status = rdma_cmq_clone_status_value(
      recovery.primary_status
    );
    result.rollback_statuses.delete();
    foreach (recovery.rollback_statuses[i])
      result.rollback_statuses.push_back(
        rdma_cmq_clone_status_value(recovery.rollback_statuses[i])
      );
  endfunction

  protected function void publish_queue_recovery_required(
    rdma_recovery_record recovery,
    rdma_control_result result,
    string message
  );
    project_queue_recovery_result(recovery, result);
    result.status = rdma_status::make(RDMA_SC_RECOVERY_REQUIRED, message);
    result.final_resource_state = RDMA_RESOURCE_ERROR;
    result.final_resource_state_known = 1'b1;
    result.recovery_required = 1'b1;
  endfunction

  protected function rdma_status persist_queue_recovery(
    rdma_handle resource_h,
    rdma_recovery_record recovery
  );
    rdma_status status;

    if (manager == null || resource_h == null || recovery == null)
      return invalid_argument("queue recovery persistence input is incomplete");
    status = manager.mark_error(resource_h, recovery);
    return normalize_status(status, "queue recovery persistence returned null");
  endfunction

  protected function bit queue_flushes_complete(
    rdma_queue_backing_plan plan
  );
    if (plan == null)
      return 1'b0;
    foreach (plan.flush_targets[i]) begin
      if (plan.flush_targets[i] == null ||
          !plan.flush_targets[i].flush_complete)
        return 1'b0;
    end
    return 1'b1;
  endfunction

  protected function bit queue_local_cleanup_complete(
    rdma_queue_backing_plan plan
  );
    if (plan == null)
      return 1'b0;
    if (plan.context_ref != null && !plan.context_ref.release_complete)
      return 1'b0;
    foreach (plan.refs[i]) begin
      if (plan.refs[i] == null)
        return 1'b0;
      // Borrowed mappings are detached, not released, and therefore retain
      // cleanup_complete=0 by contract.
      if (plan.refs[i].ownership == RDMA_OWNERSHIP_CONTROL_PLANE &&
          !plan.refs[i].cleanup_complete)
        return 1'b0;
    end
    return 1'b1;
  endfunction

  protected task execute_queue_command(
    rdma_cmq_command_desc command,
    output rdma_cmq_ticket ticket,
    output rdma_cmq_completion completion,
    output rdma_status status,
    output bit ambiguous
  );
    rdma_status execute_status;

    ticket = null;
    completion = null;
    ambiguous = 1'b0;
    status = invalid_state("queue CMQ command was not executed");
    if (cmq == null || command == null) begin
      status = invalid_argument("queue CMQ command is incomplete");
      return;
    end
    execute_status = null;
    cmq.execute(command, ticket, completion, execute_status);
    ambiguous = cmq_outcome_ambiguous(execute_status, ticket, completion);
    status = normalize_status(execute_status,
                              "queue CMQ execution returned null");
    if (status.ok() && (completion == null || completion.status == null))
      status = invalid_state("queue CMQ completion was lost");
  endtask

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
        ambiguous = cmq_outcome_ambiguous(status, ticket, completion);
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
    ambiguous = cmq_outcome_ambiguous(status, ticket, completion);
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
        ambiguous = cmq_outcome_ambiguous(status, ticket, completion);
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
                              RDMA_QUEUE_RECOVER_CREATE_ROLLBACK, recovery);
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

  // Recover an ERROR queue while the caller owns the per-Function lifecycle
  // semaphore.  Transaction-ID allocation and locking deliberately remain in
  // the control-plane facade; this task only advances the durable queue
  // recipe and never publishes an ACTIVE object itself.
  task recover_locked(
    rdma_function_binding binding,
    rdma_function_handle expected_owner,
    rdma_handle resource_h,
    longint unsigned transaction_id,
    output rdma_control_result result
  );
    rdma_resource snapshot;
    rdma_queue_resource queue;
    rdma_queue_lifecycle_policy policy;
    rdma_recovery_record recovery;
    rdma_recovery_record refreshed;
    rdma_cmq_command_desc command;
    rdma_cmq_ticket ticket;
    rdma_cmq_completion completion;
    rdma_status status;
    rdma_status completion_status;
    rdma_status classify_status;
    rdma_status persist_status;
    rdma_status reconcile_status;
    rdma_hw_presence_e query_presence;
    bit query_conclusive;
    bit terminal_known;
    bit ambiguous;
    bit done;
    bit creation_origin;
    bit local_done;
    bit predelete_target;
    int target_index;
    int unsigned i;
    rdma_queue_backing_role_e target_role;
    rdma_queue_flush_phase_e target_phase;

    result = make_result(transaction_id);
    done = 1'b0;
    status = rdma_status::success();

    do begin
      if (transaction_id == 0) begin
        status = invalid_argument("queue recovery transaction ID is zero");
        break;
      end
      if (manager == null || cmq == null || command_timeout == 0) begin
        status = invalid_state("queue recovery executor is not configured");
        break;
      end
      if (binding == null || expected_owner == null || resource_h == null) begin
        status = invalid_argument("queue recovery authority is incomplete");
        break;
      end
      status = live_binding_fence(binding, expected_owner);
      if (!status.ok()) break;
      status = queue_policy_for_kind(resource_h.kind, policy);
      if (!status.ok()) break;

      status = normalize_status(manager.lookup(resource_h, snapshot),
                                "queue recovery lookup returned null");
      if (!status.ok()) break;
      if (!$cast(queue, snapshot) || queue == null ||
          queue.state != RDMA_RESOURCE_ERROR) begin
        status = invalid_state("queue recovery requires an ERROR queue");
        break;
      end
      if (!same_owner(queue.owner, expected_owner)) begin
        status = invalid_argument("queue recovery owner mismatch");
        break;
      end
      result.resource_h = rdma_clone_handle_value(queue.handle,
                                                   "queue recovery result");
      status = normalize_status(manager.lookup_recovery(resource_h, recovery),
                                "queue recovery record lookup returned null");
      if (!status.ok()) break;
      if (recovery == null || !recovery.queue_recovery_valid ||
          recovery.queue_plan == null || recovery.primary_status == null) begin
        status = invalid_state("queue recovery record is incomplete");
        break;
      end
      if (recovery.resource_h == null ||
          !recovery.resource_h.same_instance(queue.handle) ||
          recovery.queue_plan.resource_kind != queue.resource_kind()) begin
        status = invalid_state("queue recovery record identity is inconsistent");
        break;
      end
      status = normalize_status(recovery.validate(),
                                "queue recovery record validation returned null");
      if (!status.ok()) break;
      creation_origin = recovery.queue_intent == RDMA_QUEUE_RECOVER_CREATE_ROLLBACK;
      project_queue_recovery_result(recovery, result);

      // Reconcile any earlier ambiguous command before issuing another CMQ
      // command for this queue.
      if (recovery.ambiguous_ticket != null) begin
        ticket = recovery.ambiguous_ticket;
        terminal_known = 1'b0;
        completion = null;
        reconcile_status = null;
        cmq.reconcile(ticket, terminal_known, completion, reconcile_status);
        reconcile_status = normalize_status(reconcile_status,
          "queue CMQ reconciliation returned null");
        if (!terminal_known) begin
          publish_queue_recovery_required(recovery, result,
            "ambiguous queue command has no terminal result");
          if (!reconcile_status.ok())
            result.rollback_statuses.push_back(
              rdma_cmq_clone_status_value(reconcile_status));
          done = 1'b1;
          break;
        end
        if (completion == null || completion.status == null) begin
          recovery.rollback_statuses.push_back(
            invalid_state("queue reconciliation completion is incomplete"));
          void'(persist_queue_recovery(resource_h, recovery));
          publish_queue_recovery_required(recovery, result,
            "queue reconciliation still requires recovery");
          done = 1'b1;
          break;
        end
        completion_status = normalize_status(completion.status,
          "queue reconciliation status returned null");
        if (completion_status.code inside {RDMA_SC_TIMEOUT,
                                          RDMA_SC_RESET_CANCELLED}) begin
          publish_queue_recovery_required(recovery, result,
            "queue reconciliation has no trustworthy terminal evidence");
          done = 1'b1;
          break;
        end
        if (ticket.opcode_key == null) begin
          recovery.rollback_statuses.push_back(
            invalid_state("queue reconciliation ticket has no opcode"));
          void'(persist_queue_recovery(resource_h, recovery));
          publish_queue_recovery_required(recovery, result,
            "queue reconciliation ticket is invalid");
          done = 1'b1;
          break;
        end

        // A QUERY can itself be ambiguous.  Its terminal result is handled
        // through the same ticket field, but is classified rather than
        // projected as a create/delete completion.
        if (ticket.opcode_key.opcode == query_opcode(queue.resource_kind())) begin
          query_presence = RDMA_HW_PRESENCE_UNKNOWN;
          query_conclusive = 1'b0;
          classify_status = policy.classify_query_completion(
            queue, completion, query_presence, query_conclusive);
          classify_status = normalize_status(classify_status,
            "queue QUERY classification returned null");
          recovery.ambiguous_ticket = null;
          recovery.ambiguous_queue_operation = RDMA_QUEUE_AMBIG_NONE;
          if (classify_status.ok() && query_conclusive) begin
            recovery.hardware_presence = query_presence;
            if (query_presence == RDMA_HW_PRESENCE_ABSENT)
              recovery_remove_step(recovery, RDMA_CTRL_STEP_HW_CONTEXT_DELETED);
            else
              recovery_queue_step(recovery, RDMA_CTRL_STEP_HW_CONTEXT_DELETED);
            persist_status = persist_queue_recovery(resource_h, recovery);
            if (!persist_status.ok()) begin
              publish_queue_recovery_required(recovery, result,
                "reconciled queue QUERY progress could not be persisted");
              done = 1'b1;
              break;
            end
          end
          else begin
            if (!classify_status.ok())
              recovery.rollback_statuses.push_back(
                rdma_cmq_clone_status_value(classify_status));
            recovery.hardware_presence = RDMA_HW_PRESENCE_UNKNOWN;
            persist_status = persist_queue_recovery(resource_h, recovery);
            publish_queue_recovery_required(recovery, result,
              "reconciled queue QUERY was inconclusive");
            if (!persist_status.ok())
              result.rollback_statuses.push_back(
                rdma_cmq_clone_status_value(persist_status));
            done = 1'b1;
            break;
          end
        end
        else if (ticket.opcode_key.opcode == create_opcode(queue.resource_kind())) begin
          recovery.ambiguous_ticket = null;
          recovery.ambiguous_queue_operation = RDMA_QUEUE_AMBIG_NONE;
          if (completion_status.ok()) begin
            recovery.hardware_presence = RDMA_HW_PRESENCE_PRESENT;
            recovery_complete_step(recovery, RDMA_CTRL_STEP_HW_CONTEXT_CREATED);
            recovery_queue_step(recovery, RDMA_CTRL_STEP_HW_CONTEXT_DELETED);
          end
          else begin
            // Definitive create failure proves no queue object was installed.
            recovery.hardware_presence = RDMA_HW_PRESENCE_ABSENT;
            recovery_remove_step(recovery, RDMA_CTRL_STEP_HW_CONTEXT_DELETED);
            recovery.rollback_statuses.push_back(
              rdma_cmq_clone_status_value(completion_status));
          end
          persist_status = persist_queue_recovery(resource_h, recovery);
          if (!persist_status.ok()) begin
            publish_queue_recovery_required(recovery, result,
              "reconciled queue create progress could not be persisted");
            done = 1'b1;
            break;
          end
        end
        else if (ticket.opcode_key.opcode == delete_opcode(queue.resource_kind())) begin
          recovery.ambiguous_ticket = null;
          recovery.ambiguous_queue_operation = RDMA_QUEUE_AMBIG_NONE;
          if (completion_status.ok()) begin
            recovery.hardware_presence = RDMA_HW_PRESENCE_ABSENT;
            recovery_complete_step(recovery, RDMA_CTRL_STEP_HW_CONTEXT_DELETED);
          end
          else begin
            recovery.hardware_presence = RDMA_HW_PRESENCE_PRESENT;
            recovery_queue_step(recovery, RDMA_CTRL_STEP_HW_CONTEXT_DELETED);
            recovery.rollback_statuses.push_back(
              rdma_cmq_clone_status_value(completion_status));
          end
          persist_status = persist_queue_recovery(resource_h, recovery);
          if (!persist_status.ok()) begin
            publish_queue_recovery_required(recovery, result,
              "reconciled queue delete progress could not be persisted");
            done = 1'b1;
            break;
          end
          if (!completion_status.ok()) begin
            // A normal destroy has not started any local cleanup at this
            // point.  A definitive terminal delete failure therefore proves
            // that the queue is still PRESENT and is safe to restore to its
            // pre-destroy ACTIVE publication.  Keep create-rollback recovery
            // on the destructive retry path: a failed create must still be
            // unwound, never resurrected.
            if (!creation_origin && recovery.hardware_presence ==
                  RDMA_HW_PRESENCE_PRESENT) begin
              status = normalize_status(manager.restore_active(resource_h),
                "queue delete failure restore ACTIVE returned null");
              if (status.ok()) begin
                project_queue_recovery_result(recovery, result);
                // The terminal failure is the operation's observable result;
                // the durable primary timeout remains in the recovery history
                // and rollback list for callers that inspect it.
                result.status = rdma_cmq_clone_status_value(completion_status);
                result.final_resource_state = RDMA_RESOURCE_ACTIVE;
                result.final_resource_state_known = 1'b1;
                result.recovery_required = 1'b0;
                done = 1'b1;
                break;
              end
              recovery.rollback_statuses.push_back(
                rdma_cmq_clone_status_value(status));
              persist_status = persist_queue_recovery(resource_h, recovery);
              publish_queue_recovery_required(recovery, result,
                "queue delete failure ACTIVE restore still requires recovery");
              if (!persist_status.ok())
                result.rollback_statuses.push_back(
                  rdma_cmq_clone_status_value(persist_status));
              done = 1'b1;
              break;
            end
            publish_queue_recovery_required(recovery, result,
              "queue delete terminal failure requires a retry");
            done = 1'b1;
            break;
          end
        end
        else if (ticket.opcode_key.opcode == XTR_V1_OP_OCC_FLUSH) begin
          recovery.ambiguous_ticket = null;
          recovery.ambiguous_queue_operation = RDMA_QUEUE_AMBIG_NONE;
          predelete_target = 1'b0;
          foreach (recovery.queue_plan.flush_targets[i]) begin
            if (recovery.queue_plan.flush_targets[i] != null &&
                recovery.queue_plan.flush_targets[i].role ==
                  recovery.ambiguous_role &&
                recovery.queue_plan.flush_targets[i].phase ==
                  RDMA_QUEUE_FLUSH_PRE_DELETE)
              predelete_target = 1'b1;
          end
          if (completion_status.ok()) begin
            target_index = -1;
            foreach (recovery.queue_plan.flush_targets[i]) begin
              if (recovery.queue_plan.flush_targets[i] != null &&
                  recovery.queue_plan.flush_targets[i].role ==
                    recovery.ambiguous_role) begin
                target_index = int'(i);
                break;
              end
            end
            if (target_index < 0) begin
              recovery.rollback_statuses.push_back(
                invalid_state("reconciled OCC target is missing"));
              void'(persist_queue_recovery(resource_h, recovery));
              publish_queue_recovery_required(recovery, result,
                "queue OCC target cannot be identified");
              done = 1'b1;
              break;
            end
            if (!recovery.queue_plan.flush_targets[target_index].flush_complete) begin
              status = normalize_status(
                manager.record_queue_flush_complete(
                  resource_h, recovery.ambiguous_role),
                "reconciled queue OCC progress returned null");
              if (!status.ok()) begin
                recovery.rollback_statuses.push_back(
                  rdma_cmq_clone_status_value(status));
                void'(persist_queue_recovery(resource_h, recovery));
                publish_queue_recovery_required(recovery, result,
                  "reconciled queue OCC progress failed");
                done = 1'b1;
                break;
              end
            end
            recovery.queue_plan.flush_targets[target_index].flush_complete = 1'b1;
            recovery_complete_step(recovery, RDMA_CTRL_STEP_HW_OCC_FLUSHED);
          end
          else begin
            // Keep this role incomplete and stop at the barrier.  A later
            // recovery invocation may retry the exact target.
            if (!creation_origin && predelete_target)
              recovery.hardware_presence = RDMA_HW_PRESENCE_PRESENT;
            recovery.rollback_statuses.push_back(
              rdma_cmq_clone_status_value(completion_status));
            if (!creation_origin && predelete_target) begin
              persist_status = persist_queue_recovery(resource_h, recovery);
              if (persist_status.ok()) begin
                status = normalize_status(manager.restore_active(resource_h),
                  "queue OCC failure restore ACTIVE returned null");
                if (status.ok()) begin
                  project_queue_recovery_result(recovery, result);
                  result.status = rdma_cmq_clone_status_value(
                    completion_status);
                  result.final_resource_state = RDMA_RESOURCE_ACTIVE;
                  result.final_resource_state_known = 1'b1;
                  result.recovery_required = 1'b0;
                  done = 1'b1;
                  break;
                end
                recovery.rollback_statuses.push_back(
                  rdma_cmq_clone_status_value(status));
              end
              else
                recovery.rollback_statuses.push_back(
                  rdma_cmq_clone_status_value(persist_status));
              // If either persistence or the atomic restore failed, retain
              // the PRESENT recovery record for a later retry.
              persist_status = persist_queue_recovery(resource_h, recovery);
              publish_queue_recovery_required(recovery, result,
                "queue OCC failure ACTIVE restore still requires recovery");
              if (!persist_status.ok())
                result.rollback_statuses.push_back(
                  rdma_cmq_clone_status_value(persist_status));
              done = 1'b1;
              break;
            end
            persist_status = persist_queue_recovery(resource_h, recovery);
            publish_queue_recovery_required(recovery, result,
              "queue OCC target still requires recovery");
            if (!persist_status.ok())
              result.rollback_statuses.push_back(
                rdma_cmq_clone_status_value(persist_status));
            done = 1'b1;
            break;
          end
          persist_status = persist_queue_recovery(resource_h, recovery);
          if (!persist_status.ok()) begin
            publish_queue_recovery_required(recovery, result,
              "reconciled queue OCC progress could not be persisted");
            done = 1'b1;
            break;
          end
        end
        else begin
          recovery.rollback_statuses.push_back(
            rdma_status::make(RDMA_SC_UNSUPPORTED_OPCODE,
                              "queue recovery ticket opcode is unsupported"));
          void'(persist_queue_recovery(resource_h, recovery));
          publish_queue_recovery_required(recovery, result,
            "queue recovery ticket opcode is unsupported");
          done = 1'b1;
          break;
        end
      end

      // If presence remains unknown, issue exactly one typed QUERY.  QUERY
      // establishes only object presence, never OCC completion.
      if (recovery.hardware_presence == RDMA_HW_PRESENCE_UNKNOWN &&
          recovery.ambiguous_ticket == null) begin
        status = normalize_status(policy.build_object_command(
          query_opcode(queue.resource_kind()), expected_owner, queue,
          command_timeout, command),
          "queue recovery QUERY descriptor returned null");
        if (!status.ok()) begin
          recovery.rollback_statuses.push_back(
            rdma_cmq_clone_status_value(status));
          void'(persist_queue_recovery(resource_h, recovery));
          publish_queue_recovery_required(recovery, result,
            "queue QUERY descriptor could not be built");
          done = 1'b1;
          break;
        end
        execute_queue_command(command, ticket, completion, status, ambiguous);
        if (ambiguous) begin
          recovery.ambiguous_ticket = rdma_cmq_clone_ticket_value(
            ticket, "queue QUERY recovery");
          recovery.ambiguous_queue_operation =
            (creation_origin && !recovery_step_completed(
              recovery, RDMA_CTRL_STEP_HW_CONTEXT_CREATED)) ?
              RDMA_QUEUE_AMBIG_CREATE : RDMA_QUEUE_AMBIG_DELETE;
          persist_status = persist_queue_recovery(resource_h, recovery);
          publish_queue_recovery_required(recovery, result,
            "queue QUERY has no terminal result");
          if (!persist_status.ok())
            result.rollback_statuses.push_back(
              rdma_cmq_clone_status_value(persist_status));
          done = 1'b1;
          break;
        end
        if (!status.ok() || completion == null || completion.status == null) begin
          if (status == null) status = invalid_state("queue QUERY result is null");
          recovery.rollback_statuses.push_back(
            rdma_cmq_clone_status_value(status));
          void'(persist_queue_recovery(resource_h, recovery));
          publish_queue_recovery_required(recovery, result,
            "queue QUERY failed to establish presence");
          done = 1'b1;
          break;
        end
        query_presence = RDMA_HW_PRESENCE_UNKNOWN;
        query_conclusive = 1'b0;
        classify_status = policy.classify_query_completion(
          queue, completion, query_presence, query_conclusive);
        classify_status = normalize_status(classify_status,
          "queue QUERY classification returned null");
        if (!classify_status.ok() || !query_conclusive) begin
          if (!classify_status.ok())
            recovery.rollback_statuses.push_back(
              rdma_cmq_clone_status_value(classify_status));
          void'(persist_queue_recovery(resource_h, recovery));
          publish_queue_recovery_required(recovery, result,
            "queue QUERY response is inconclusive");
          done = 1'b1;
          break;
        end
        recovery.hardware_presence = query_presence;
        if (query_presence == RDMA_HW_PRESENCE_ABSENT)
          recovery_remove_step(recovery, RDMA_CTRL_STEP_HW_CONTEXT_DELETED);
        else
          recovery_queue_step(recovery, RDMA_CTRL_STEP_HW_CONTEXT_DELETED);
        persist_status = persist_queue_recovery(resource_h, recovery);
        if (!persist_status.ok()) begin
          publish_queue_recovery_required(recovery, result,
            "queue QUERY progress could not be persisted");
          done = 1'b1;
          break;
        end
      end

      if (recovery.hardware_presence == RDMA_HW_PRESENCE_UNKNOWN) begin
        publish_queue_recovery_required(recovery, result,
          "queue hardware presence remains unknown");
        done = 1'b1;
        break;
      end

      // Execute persisted OCC targets in order.  This enforces the SRQ
      // pre-delete barrier and defers CQ post-delete flushes until absence.
      for (i = 0; i < recovery.queue_plan.flush_targets.size(); i++) begin
        if (recovery.queue_plan.flush_targets[i] == null) begin
          recovery.rollback_statuses.push_back(
            invalid_state("queue recovery flush target is null"));
          void'(persist_queue_recovery(resource_h, recovery));
          publish_queue_recovery_required(recovery, result,
            "queue OCC recipe is invalid");
          done = 1'b1;
          break;
        end
        if (recovery.queue_plan.flush_targets[i].flush_complete)
          continue;
        target_phase = recovery.queue_plan.flush_targets[i].phase;
        if (target_phase == RDMA_QUEUE_FLUSH_POST_DELETE &&
            recovery.hardware_presence != RDMA_HW_PRESENCE_ABSENT)
          continue;
        target_role = recovery.queue_plan.flush_targets[i].role;
        status = normalize_status(policy.build_flush_command(
          expected_owner, recovery.queue_plan.flush_targets[i],
          command_timeout, command),
          "queue recovery OCC descriptor returned null");
        if (!status.ok()) begin
          recovery.rollback_statuses.push_back(
            rdma_cmq_clone_status_value(status));
          void'(persist_queue_recovery(resource_h, recovery));
          publish_queue_recovery_required(recovery, result,
            "queue OCC descriptor could not be built");
          done = 1'b1;
          break;
        end
        execute_queue_command(command, ticket, completion, status, ambiguous);
        if (ambiguous) begin
          recovery.ambiguous_ticket = rdma_cmq_clone_ticket_value(
            ticket, "queue OCC recovery");
          recovery.ambiguous_queue_operation = RDMA_QUEUE_AMBIG_OCC_FLUSH;
          recovery.ambiguous_role = target_role;
          persist_status = persist_queue_recovery(resource_h, recovery);
          publish_queue_recovery_required(recovery, result,
            "queue OCC target has no terminal result");
          if (!persist_status.ok())
            result.rollback_statuses.push_back(
              rdma_cmq_clone_status_value(persist_status));
          done = 1'b1;
          break;
        end
        if (!status.ok()) begin
          recovery.rollback_statuses.push_back(
            rdma_cmq_clone_status_value(status));
          persist_status = persist_queue_recovery(resource_h, recovery);
          publish_queue_recovery_required(recovery, result,
            "queue OCC target failed");
          if (!persist_status.ok())
            result.rollback_statuses.push_back(
              rdma_cmq_clone_status_value(persist_status));
          done = 1'b1;
          break;
        end
        status = normalize_status(manager.record_queue_flush_complete(
          resource_h, target_role), "queue OCC progress returned null");
        if (!status.ok()) begin
          recovery.rollback_statuses.push_back(
            rdma_cmq_clone_status_value(status));
          void'(persist_queue_recovery(resource_h, recovery));
          publish_queue_recovery_required(recovery, result,
            "queue OCC progress could not be persisted");
          done = 1'b1;
          break;
        end
        recovery.queue_plan.flush_targets[i].flush_complete = 1'b1;
        recovery_complete_step(recovery, RDMA_CTRL_STEP_HW_OCC_FLUSHED);
        persist_status = persist_queue_recovery(resource_h, recovery);
        if (!persist_status.ok()) begin
          publish_queue_recovery_required(recovery, result,
            "queue OCC progress could not be persisted");
          done = 1'b1;
          break;
        end
      end
      if (done) break;

      // A PRESENT queue still needs delete.  For SRQ this is reached only
      // after all pre-delete OCC targets above are complete.
      if (recovery.hardware_presence == RDMA_HW_PRESENCE_PRESENT &&
          !recovery_step_completed(recovery, RDMA_CTRL_STEP_HW_CONTEXT_DELETED)) begin
        for (i = 0; i < recovery.queue_plan.flush_targets.size(); i++) begin
          if (recovery.queue_plan.flush_targets[i] != null &&
              recovery.queue_plan.flush_targets[i].phase ==
                RDMA_QUEUE_FLUSH_PRE_DELETE &&
              !recovery.queue_plan.flush_targets[i].flush_complete) begin
            publish_queue_recovery_required(recovery, result,
              "queue pre-delete OCC barrier is incomplete");
            done = 1'b1;
            break;
          end
        end
        if (done) break;
        status = normalize_status(policy.build_object_command(
          delete_opcode(queue.resource_kind()), expected_owner, queue,
          command_timeout, command),
          "queue recovery delete descriptor returned null");
        if (!status.ok()) begin
          recovery.rollback_statuses.push_back(
            rdma_cmq_clone_status_value(status));
          void'(persist_queue_recovery(resource_h, recovery));
          publish_queue_recovery_required(recovery, result,
            "queue delete descriptor could not be built");
          done = 1'b1;
          break;
        end
        execute_queue_command(command, ticket, completion, status, ambiguous);
        if (ambiguous) begin
          recovery.ambiguous_ticket = rdma_cmq_clone_ticket_value(
            ticket, "queue delete recovery");
          recovery.ambiguous_queue_operation = RDMA_QUEUE_AMBIG_DELETE;
          recovery.ambiguous_role = recovery.queue_plan.refs.size() == 0 ?
            RDMA_QUEUE_ROLE_CQ_RING : recovery.queue_plan.refs[0].role;
          recovery.hardware_presence = RDMA_HW_PRESENCE_UNKNOWN;
          persist_status = persist_queue_recovery(resource_h, recovery);
          publish_queue_recovery_required(recovery, result,
            "queue delete has no terminal result");
          if (!persist_status.ok())
            result.rollback_statuses.push_back(
              rdma_cmq_clone_status_value(persist_status));
          done = 1'b1;
          break;
        end
        if (!status.ok()) begin
          recovery.hardware_presence = RDMA_HW_PRESENCE_PRESENT;
          recovery_queue_step(recovery, RDMA_CTRL_STEP_HW_CONTEXT_DELETED);
          recovery.rollback_statuses.push_back(
            rdma_cmq_clone_status_value(status));
          persist_status = persist_queue_recovery(resource_h, recovery);
          publish_queue_recovery_required(recovery, result,
            "queue delete failed");
          if (!persist_status.ok())
            result.rollback_statuses.push_back(
              rdma_cmq_clone_status_value(persist_status));
          done = 1'b1;
          break;
        end
        recovery.hardware_presence = RDMA_HW_PRESENCE_ABSENT;
        recovery_complete_step(recovery, RDMA_CTRL_STEP_HW_CONTEXT_DELETED);
        persist_status = persist_queue_recovery(resource_h, recovery);
        if (!persist_status.ok()) begin
          publish_queue_recovery_required(recovery, result,
            "queue delete progress could not be persisted");
          done = 1'b1;
          break;
        end
      end

      if (recovery.hardware_presence != RDMA_HW_PRESENCE_ABSENT) begin
        publish_queue_recovery_required(recovery, result,
          "queue hardware absence is not proven");
        done = 1'b1;
        break;
      end

      // The first OCC loop intentionally skipped post-delete targets while
      // PRESENT.  Revisit those targets after delete/QUERY absence.
      for (i = 0; i < recovery.queue_plan.flush_targets.size(); i++) begin
        if (recovery.queue_plan.flush_targets[i] == null ||
            recovery.queue_plan.flush_targets[i].flush_complete ||
            recovery.queue_plan.flush_targets[i].phase !=
              RDMA_QUEUE_FLUSH_POST_DELETE)
          continue;
        target_role = recovery.queue_plan.flush_targets[i].role;
        status = normalize_status(policy.build_flush_command(
          expected_owner, recovery.queue_plan.flush_targets[i],
          command_timeout, command),
          "queue post-delete OCC descriptor returned null");
        if (!status.ok()) begin
          recovery.rollback_statuses.push_back(
            rdma_cmq_clone_status_value(status));
          void'(persist_queue_recovery(resource_h, recovery));
          publish_queue_recovery_required(recovery, result,
            "queue post-delete OCC descriptor failed");
          done = 1'b1;
          break;
        end
        execute_queue_command(command, ticket, completion, status, ambiguous);
        if (ambiguous) begin
          recovery.ambiguous_ticket = rdma_cmq_clone_ticket_value(
            ticket, "queue post-delete OCC recovery");
          recovery.ambiguous_queue_operation = RDMA_QUEUE_AMBIG_OCC_FLUSH;
          recovery.ambiguous_role = target_role;
          persist_status = persist_queue_recovery(resource_h, recovery);
          publish_queue_recovery_required(recovery, result,
            "queue post-delete OCC has no terminal result");
          if (!persist_status.ok())
            result.rollback_statuses.push_back(
              rdma_cmq_clone_status_value(persist_status));
          done = 1'b1;
          break;
        end
        if (!status.ok()) begin
          recovery.rollback_statuses.push_back(
            rdma_cmq_clone_status_value(status));
          persist_status = persist_queue_recovery(resource_h, recovery);
          publish_queue_recovery_required(recovery, result,
            "queue post-delete OCC failed");
          if (!persist_status.ok())
            result.rollback_statuses.push_back(
              rdma_cmq_clone_status_value(persist_status));
          done = 1'b1;
          break;
        end
        status = normalize_status(manager.record_queue_flush_complete(
          resource_h, target_role), "queue post-delete OCC progress returned null");
        if (!status.ok()) begin
          recovery.rollback_statuses.push_back(
            rdma_cmq_clone_status_value(status));
          void'(persist_queue_recovery(resource_h, recovery));
          publish_queue_recovery_required(recovery, result,
            "queue post-delete OCC progress failed");
          done = 1'b1;
          break;
        end
        recovery.queue_plan.flush_targets[i].flush_complete = 1'b1;
        recovery_complete_step(recovery, RDMA_CTRL_STEP_HW_OCC_FLUSHED);
        persist_status = persist_queue_recovery(resource_h, recovery);
        if (!persist_status.ok()) begin
          publish_queue_recovery_required(recovery, result,
            "queue post-delete OCC progress failed");
          done = 1'b1;
          break;
        end
      end
      if (done) break;
      if (!queue_flushes_complete(recovery.queue_plan)) begin
        publish_queue_recovery_required(recovery, result,
          "queue OCC recipe remains incomplete");
        done = 1'b1;
        break;
      end

      local_done = queue_local_cleanup_complete(recovery.queue_plan);
      if (!local_done) begin
        status = cleanup_local(recovery.queue_plan, result, 1'b1, resource_h);
        status = normalize_status(status,
          "queue local recovery cleanup returned null");
        refreshed = null;
        persist_status = manager.lookup_recovery(resource_h, refreshed);
        persist_status = normalize_status(persist_status,
          "queue local recovery refresh returned null");
        if (persist_status.ok() && refreshed != null)
          recovery = refreshed;
        if (!status.ok()) begin
          recovery.rollback_statuses.push_back(
            rdma_cmq_clone_status_value(status));
          void'(persist_queue_recovery(resource_h, recovery));
          publish_queue_recovery_required(recovery, result,
            "queue local cleanup still requires recovery");
          done = 1'b1;
          break;
        end
        if (!persist_status.ok()) begin
          recovery.rollback_statuses.push_back(
            rdma_cmq_clone_status_value(persist_status));
          publish_queue_recovery_required(recovery, result,
            "queue local cleanup progress is unavailable");
          done = 1'b1;
          break;
        end
      end
      local_done = queue_local_cleanup_complete(recovery.queue_plan);
      if (!local_done) begin
        publish_queue_recovery_required(recovery, result,
          "queue local cleanup remains incomplete");
        done = 1'b1;
        break;
      end

      recovery_complete_step(recovery, RDMA_CTRL_STEP_BACKING_RELEASED);
      // A normal destroy is an unstaged, already-published queue.  Its ERROR
      // recovery schema must not advertise RESOURCE_RELEASED while the
      // registry entry is still present: manager.mark_error() reserves that
      // pending step for the canonical create-rollback reservation shape.
      // Create-rollback recovery is the one exception; release_reserved()
      // consumes that canonical pending step after the recovery is persisted.
      if (creation_origin)
        recovery_queue_step(recovery, RDMA_CTRL_STEP_RESOURCE_RELEASED);
      persist_status = persist_queue_recovery(resource_h, recovery);
      if (!persist_status.ok()) begin
        publish_queue_recovery_required(recovery, result,
          "queue backing progress could not be persisted");
        done = 1'b1;
        break;
      end

      // The recovery intent, not the partial step history, selects the
      // registry transition.  A normal destroy starts with an ACTIVE queue
      // whose recovery result deliberately contains only destroy progress;
      // using the absence of create steps here would misclassify it as an
      // ALLOCATED reservation and route it through release_reserved().
      if (creation_origin)
        status = manager.release_reserved(resource_h);
      else
        status = manager.finalize_release(resource_h);
      status = normalize_status(status,
        "queue recovery final release returned null");
      if (!status.ok()) begin
        recovery.rollback_statuses.push_back(
          rdma_cmq_clone_status_value(status));
        void'(persist_queue_recovery(resource_h, recovery));
        publish_queue_recovery_required(recovery, result,
          "queue resource finalization still requires recovery");
        done = 1'b1;
        break;
      end
      recovery_complete_step(recovery, RDMA_CTRL_STEP_RESOURCE_RELEASED);
      project_queue_recovery_result(recovery, result);
      result.status = rdma_status::success();
      result.final_resource_state = RDMA_RESOURCE_RELEASED;
      result.final_resource_state_known = 1'b1;
      result.recovery_required = 1'b0;
      done = 1'b1;
    end while (1'b0);

    if (!done) begin
      if (status == null)
        status = invalid_state("queue recovery returned null");
      publish_failure(status, result, RDMA_RESOURCE_NEW, 1'b0, 1'b0);
    end
  endtask

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
      status = live_binding_fence(binding, expected_owner);
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
      cmq_ambiguous = cmq_outcome_ambiguous(status, ticket, completion);
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
      status = live_binding_fence(binding, expected_owner);
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

  task destroy_locked(
    rdma_function_binding binding,
    rdma_function_handle expected_owner,
    rdma_destroy_resource_req request,
    longint unsigned transaction_id,
    output rdma_control_result result
  );
    rdma_status status, primary, step_status;
    rdma_resource snapshot;
    rdma_queue_resource queue;
    rdma_queue_backing_plan plan;
    rdma_queue_lifecycle_policy policy;
    rdma_queue_backing_role_e flush_roles[$], local_roles[$];
    rdma_queue_flush_phase_e flush_phases[$];
    rdma_cmq_command_desc command;
    rdma_cmq_ticket ticket;
    rdma_cmq_completion completion;
    bit delete_before_flush, release_context_first, ambiguous, hardware_absent;
    rdma_queue_ambiguous_operation_e ambiguous_op;
    int unsigned i, j, k, count, ref_cursor, ref_role_count;

    result = make_result(transaction_id);
    status = rdma_status::success(); ambiguous_op = RDMA_QUEUE_AMBIG_NONE;
    if (transaction_id == 0) status = invalid_argument("queue transaction ID is zero");
    else if (manager == null || cmq == null || binding == null || expected_owner == null || request == null || request.target_h == null)
      status = invalid_argument("queue destroy authority is incomplete");
    if (status.ok()) status = live_binding_fence(binding, expected_owner);
    if (status.ok()) begin
      result.resource_h = rdma_clone_handle_value(request.target_h, "queue destroy result");
      status = normalize_status(manager.lookup(request.target_h, snapshot), "queue destroy lookup returned null");
      if (status.ok() && (snapshot == null || snapshot.state != RDMA_RESOURCE_ACTIVE || !$cast(queue, snapshot)))
        status = (snapshot != null && snapshot.state != RDMA_RESOURCE_ACTIVE) ? rdma_status::make(RDMA_SC_INVALID_STATE, "queue is not ACTIVE") : invalid_state("queue destroy resource snapshot invalid");
    end
    if (status.ok() && !same_owner(queue.owner, expected_owner)) status = invalid_argument("queue destroy owner mismatch");
    if (status.ok()) begin
      case (queue.resource_kind())
        RDMA_RESOURCE_CQ: policy = cq_policy;
        RDMA_RESOURCE_SRQ: policy = srq_policy;
        RDMA_RESOURCE_CEQ: policy = ceq_policy;
        RDMA_RESOURCE_AEQ: policy = aeq_policy;
        default: status = invalid_argument("unsupported queue kind");
      endcase
    end
    if (status.ok()) begin
      plan = queue.queue_plan;
      status = (plan == null) ? invalid_state("queue backing plan is missing") : normalize_status(plan.validate(), "queue backing plan validation returned null");
    end
    if (status.ok()) begin
      policy.hardware_cleanup_roles(flush_roles, flush_phases, delete_before_flush);
      policy.local_cleanup_roles(local_roles, release_context_first);
      if (flush_roles.size() != flush_phases.size()) status = invalid_state("cleanup recipe phase mismatch");
      foreach (flush_roles[k]) begin
        count = 0; foreach (plan.flush_targets[j]) if (plan.flush_targets[j] != null && plan.flush_targets[j].role == flush_roles[k] && plan.flush_targets[j].phase == flush_phases[k]) count++;
        if (count != 1) status = invalid_state("cleanup recipe role missing or duplicated");
      end
      foreach (local_roles[k]) begin
        count = 0; foreach (plan.refs[j]) if (plan.refs[j] != null && plan.refs[j].role == local_roles[k]) count++;
        if (count != 1 && !(queue.resource_kind() == RDMA_RESOURCE_SRQ && local_roles[k] == RDMA_QUEUE_ROLE_SRQ_SGB && count == 0))
          status = invalid_state("local cleanup role missing or duplicated");
      end
      if (release_context_first != (plan.context_ref != null))
        status = invalid_state("local cleanup context recipe mismatch");
      // cleanup_local() walks refs in reverse planner order; enforce that
      // planner order exactly projects the policy recipe.  SRQ_SGB is an
      // optional role for max_sge <= 2, so skip that recipe entry when the
      // canonical plan intentionally omits it.
      ref_cursor = plan.refs.size();
      for (k = 0; k < local_roles.size(); k++) begin
        ref_role_count = 0;
        foreach (plan.refs[j]) begin
          if (plan.refs[j] != null && plan.refs[j].role == local_roles[k])
            ref_role_count++;
        end
        if (ref_role_count == 0 && queue.resource_kind() == RDMA_RESOURCE_SRQ &&
            local_roles[k] == RDMA_QUEUE_ROLE_SRQ_SGB)
          continue;
        if (ref_cursor == 0) begin
          status = invalid_state("planner local cleanup order diverges from recipe");
          continue;
        end
        ref_cursor--;
        if (plan.refs[ref_cursor] == null ||
            plan.refs[ref_cursor].role != local_roles[k])
          status = invalid_state("planner local cleanup order diverges from recipe");
      end
      if (ref_cursor != 0)
        status = invalid_state("planner local cleanup has unlisted roles");
    end
    if (status.ok()) status = normalize_status(manager.begin_quiesce(queue.handle), "queue begin quiesce returned null");
    if (status.ok()) begin
      hardware_absent = 1'b0;
      // SRQ flushes precede delete; CQ/EQ delete precedes optional flush.
      if (!delete_before_flush) begin
        for (i = 0; i < flush_roles.size(); i++) begin
          foreach (plan.flush_targets[j]) if (plan.flush_targets[j].role == flush_roles[i]) begin
            ticket = null;
            completion = null;
            command = null;
            ambiguous = 1'b0;
            status = normalize_status(policy.build_flush_command(
              expected_owner, plan.flush_targets[j], command_timeout, command
            ), "flush descriptor returned null");
            if (status.ok()) begin
              ticket = null;
              completion = null;
              step_status = null;
              cmq.execute(command, ticket, completion, step_status);
              ambiguous = cmq_outcome_ambiguous(step_status, ticket,
                                                completion);
              status = normalize_status(step_status, "flush result was lost");
              if (status.ok() &&
                  (completion == null || completion.status == null))
                status = invalid_state("flush completion was lost");
            end
            if (ambiguous) ambiguous_op = RDMA_QUEUE_AMBIG_OCC_FLUSH;
            if (status.ok() && completion != null && completion.status != null && completion.status.ok()) begin status = normalize_status(manager.record_queue_flush_complete(queue.handle, flush_roles[i]), "flush progress returned null"); if (status.ok()) result.completed_steps.push_back(RDMA_CTRL_STEP_HW_OCC_FLUSHED); end
            if (!status.ok()) break;
          end
          if (!status.ok()) break;
        end
      end
      if (status.ok()) begin
        ticket = null;
        completion = null;
        command = null;
        status = normalize_status(policy.build_object_command(
          delete_opcode(queue.resource_kind()), expected_owner, queue,
          command_timeout, command
        ), "delete descriptor returned null");
        ambiguous = 1'b0;
        if (status.ok()) begin
          ticket = null;
          completion = null;
          step_status = null;
          cmq.execute(command, ticket, completion, step_status);
          ambiguous = cmq_outcome_ambiguous(step_status, ticket,
                                            completion);
          status = normalize_status(step_status, "delete result was lost");
          if (status.ok() &&
              (completion == null || completion.status == null))
            status = invalid_state("delete completion was lost");
          if (ambiguous)
            ambiguous_op = RDMA_QUEUE_AMBIG_DELETE;
        end
        if (status.ok() && completion != null && completion.status != null && completion.status.ok()) begin hardware_absent = 1'b1; result.completed_steps.push_back(RDMA_CTRL_STEP_HW_CONTEXT_DELETED); end
      end
      if (status.ok() && delete_before_flush) begin
        for (i = 0; i < flush_roles.size(); i++) begin
          foreach (plan.flush_targets[j]) if (plan.flush_targets[j].role == flush_roles[i]) begin
            ticket = null;
            completion = null;
            command = null;
            ambiguous = 1'b0;
            status = normalize_status(policy.build_flush_command(
              expected_owner, plan.flush_targets[j], command_timeout, command
            ), "flush descriptor returned null");
            if (status.ok()) begin
              ticket = null;
              completion = null;
              step_status = null;
              cmq.execute(command, ticket, completion, step_status);
              ambiguous = cmq_outcome_ambiguous(step_status, ticket,
                                                completion);
              status = normalize_status(step_status, "flush result was lost");
              if (status.ok() &&
                  (completion == null || completion.status == null))
                status = invalid_state("flush completion was lost");
            end
            if (ambiguous) ambiguous_op = RDMA_QUEUE_AMBIG_OCC_FLUSH;
            if (status.ok() && completion != null && completion.status != null && completion.status.ok()) begin status = normalize_status(manager.record_queue_flush_complete(queue.handle, flush_roles[i]), "flush progress returned null"); if (status.ok()) result.completed_steps.push_back(RDMA_CTRL_STEP_HW_OCC_FLUSHED); end
            if (!status.ok()) break;
          end
          if (!status.ok()) break;
        end
      end
      if (status.ok()) status = live_binding_fence(binding, expected_owner);
      if (status.ok()) begin
        status = cleanup_local(plan, result, 1'b1, queue.handle);
        if (status.ok()) status = live_binding_fence(binding, expected_owner);
        if (status.ok()) status = normalize_status(manager.finalize_release(queue.handle), "queue finalize release returned null");
      end
      if (!status.ok()) begin
        primary = rdma_cmq_clone_status_value(status);
        if (!hardware_absent && !ambiguous && ticket == null && status.code inside {RDMA_SC_INVALID_ARGUMENT, RDMA_SC_INVALID_STATE, RDMA_SC_RESOURCE_BUSY}) begin
          rdma_status restore_status;
          restore_status = manager.restore_active(queue.handle);
          if (restore_status == null || !restore_status.ok()) begin
            retain_recovery_int(policy, queue, plan, null, primary, result, RDMA_HW_PRESENCE_UNKNOWN, ambiguous_op, ticket, 1'b1, 1'b1, RDMA_QUEUE_RECOVER_NORMAL_DESTROY, queue);
            return;
          end
          publish_failure(primary, result, RDMA_RESOURCE_ACTIVE, 1'b1, 1'b0);
          return;
        end
        retain_recovery_int(policy, queue, plan, null, primary, result,
                        hardware_absent ? RDMA_HW_PRESENCE_ABSENT : RDMA_HW_PRESENCE_UNKNOWN,
                        ambiguous ? ambiguous_op : RDMA_QUEUE_AMBIG_NONE,
                        ticket, !hardware_absent, 1'b1,
                        RDMA_QUEUE_RECOVER_NORMAL_DESTROY, queue);
        return;
      end
      publish_failure(rdma_status::success(), result, RDMA_RESOURCE_RELEASED, 1'b1, 1'b0);
      return;
    end
    publish_failure(status, result, RDMA_RESOURCE_NEW, 1'b0, 1'b0);
  endtask
endclass
