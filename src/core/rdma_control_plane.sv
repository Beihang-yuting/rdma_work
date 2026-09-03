// 中文说明：rdma_control_plane.sv 属于核心执行层，负责队列、控制面、资源和恢复流程。
// 阅读提示：先看公开类型和接口，再看实现细节；失败路径应保持状态与资源所有权可追踪。

class rdma_control_plane extends uvm_object;
  `uvm_object_utils(rdma_control_plane)

  protected rdma_resource_manager manager;
  protected rdma_cmq_port cmq;
  protected rdma_stag_key_policy key_policy;
  protected rdma_host_mem_api host_mem;
  protected rdma_hmc_allocator hmc_allocator;
  protected rdma_context_backing_api context_backing;
  protected rdma_queue_lifecycle_executor queue_executor;
  protected rdma_qp_lifecycle_executor qp_executor;
  protected time default_timeout;
  protected bit configured;

  protected longint unsigned next_transaction_id;
  protected bit transaction_ids_exhausted;
  protected semaphore lock_table_guard;
  protected semaphore function_locks[string];

  function new(string name = "rdma_control_plane");
    super.new(name);
    manager = null;
    cmq = null;
    key_policy = null;
    host_mem = null;
    hmc_allocator = null;
    context_backing = null;
    queue_executor = null;
    qp_executor = null;
    default_timeout = 0;
    configured = 1'b0;
    next_transaction_id = 1;
    transaction_ids_exhausted = 1'b0;
    lock_table_guard = new(1);
    function_locks.delete();
  endfunction

  protected function rdma_status invalid_argument(string message);
    return rdma_status::make(RDMA_SC_INVALID_ARGUMENT, message);
  endfunction

  protected function rdma_status invalid_state(string message);
    return rdma_status::make(RDMA_SC_INVALID_STATE, message);
  endfunction

  protected function rdma_handle snapshot_handle(rdma_handle source);
    rdma_handle snapshot;

    if (source == null)
      return null;
    snapshot = new("control_handle_snapshot");
    snapshot.kind = source.kind;
    snapshot.function_uid = source.function_uid;
    snapshot.object_id = source.object_id;
    snapshot.generation = source.generation;
    return snapshot;
  endfunction

  protected function rdma_status checked_status(
    rdma_status source,
    string null_message
  );
    if (source == null)
      return invalid_state(null_message);
    return rdma_cmq_clone_status_value(source);
  endfunction

  protected function rdma_control_result make_result();
    rdma_control_result result;
    rdma_status pending_status;

    result = new("control_result");
    pending_status = invalid_state("control-plane operation did not complete");
    result.status = rdma_cmq_clone_status_value(pending_status);
    result.primary_status = rdma_cmq_clone_status_value(pending_status);
    result.final_resource_state = RDMA_RESOURCE_NEW;
    result.recovery_required = 1'b0;
    return result;
  endfunction

  protected function void cleanup_activated_pd(
    rdma_handle pd_h,
    rdma_control_result result
  );
    rdma_status cleanup_status;

    cleanup_status = manager.begin_quiesce(pd_h);
    cleanup_status = checked_status(
      cleanup_status, "active PD cleanup quiesce returned null"
    );
    if (!cleanup_status.ok()) begin
      result.rollback_statuses.push_back(
        rdma_cmq_clone_status_value(cleanup_status)
      );
      return;
    end
    result.final_resource_state = RDMA_RESOURCE_QUIESCING;
    result.final_resource_state_known = 1'b1;

    cleanup_status = manager.finalize_release(pd_h);
    cleanup_status = checked_status(
      cleanup_status, "active PD cleanup release returned null"
    );
    if (!cleanup_status.ok()) begin
      result.rollback_statuses.push_back(
        rdma_cmq_clone_status_value(cleanup_status)
      );
      return;
    end
    result.final_resource_state = RDMA_RESOURCE_RELEASED;
    result.completed_steps.push_back(RDMA_CTRL_STEP_RESOURCE_RELEASED);
  endfunction

  protected function void finalize_mr_recovery(
    rdma_mr reserved_mr,
    rdma_recovery_record recovery,
    rdma_status primary_status,
    rdma_control_result result,
    output rdma_mr mr,
    output bit result_finalized,
    input bit reserved_error = 1'b0
  );
    rdma_resource authoritative_resource;
    rdma_status normalized_primary;
    rdma_status recovery_status;

    mr = null;
    result_finalized = 1'b1;
    normalized_primary = checked_status(
      primary_status, "MR recovery primary status is null"
    );
    if (reserved_error)
      recovery_status = manager.mark_reserved_error(
        reserved_mr.handle, recovery
      );
    else
      recovery_status = manager.mark_error(reserved_mr.handle, recovery);
    recovery_status = checked_status(
      recovery_status, "MR recovery freeze returned null"
    );
    if (recovery_status.ok()) begin
      result.final_resource_state = RDMA_RESOURCE_ERROR;
      result.final_resource_state_known = 1'b1;
      result.recovery_required = 1'b1;
      recovery_status = manager.lookup(
        reserved_mr.handle, authoritative_resource
      );
      recovery_status = checked_status(
        recovery_status, "resource manager ERROR MR lookup returned null"
      );
      if (recovery_status.ok()) begin
        if (!$cast(mr, authoritative_resource) || mr == null ||
            mr.handle == null || mr.state != RDMA_RESOURCE_ERROR)
          mr = null;
      end
    end
    else begin
      result.rollback_statuses.push_back(
        rdma_cmq_clone_status_value(recovery_status)
      );
      recovery_status = manager.lookup(
        reserved_mr.handle, authoritative_resource
      );
      recovery_status = checked_status(
        recovery_status, "authoritative MR fallback lookup returned null"
      );
      if (recovery_status.ok() && authoritative_resource != null) begin
        result.final_resource_state = authoritative_resource.state;
        result.final_resource_state_known = 1'b1;
      end
      else begin
        if (recovery_status.ok())
          recovery_status = invalid_state(
            "authoritative MR fallback snapshot is null"
          );
        result.rollback_statuses.push_back(
          rdma_cmq_clone_status_value(recovery_status)
        );
        result.final_resource_state = RDMA_RESOURCE_NEW;
        result.final_resource_state_known = 1'b0;
      end
      result.recovery_required = 1'b0;
    end
    result.primary_status = rdma_cmq_clone_status_value(normalized_primary);
    result.status = rdma_status::make(
      RDMA_SC_RECOVERY_REQUIRED,
      "MR state requires recovery"
    );
  endfunction

  protected function void retain_mr_rollback_error(
    rdma_mr reserved_mr,
    rdma_status primary_status,
    rdma_control_result result,
    rdma_hw_presence_e hardware_presence,
    bit has_pending_step,
    rdma_control_step_e pending_step,
    rdma_cmq_ticket ambiguous_ticket,
    output rdma_mr mr,
    output bit result_finalized
  );
    rdma_recovery_record recovery;

    recovery = rdma_recovery_record::type_id::create(
      "register_mr_rollback_recovery"
    );
    recovery.resource_h = snapshot_handle(reserved_mr.handle);
    recovery.hardware_presence = hardware_presence;
    recovery.completed_steps = result.completed_steps;
    if (has_pending_step)
      recovery.pending_steps.push_back(pending_step);
    recovery.backing_refs = reserved_mr.backing_refs;
    recovery.hmc_refs = reserved_mr.hmc_refs;
    recovery.ambiguous_ticket = rdma_cmq_clone_ticket_value(
      ambiguous_ticket, "register MR rollback recovery"
    );
    recovery.primary_status = rdma_cmq_clone_status_value(primary_status);
    recovery.rollback_statuses = result.rollback_statuses;
    finalize_mr_recovery(reserved_mr, recovery, primary_status, result, mr,
                         result_finalized);
  endfunction

  protected task rollback_mr_creation(
    rdma_mr reserved_mr,
    rdma_function_handle owner,
    rdma_status primary_status,
    rdma_control_result result,
    bit hardware_key_allocated,
    bit registry_programmed,
    output rdma_mr mr,
    output bit result_finalized
  );
    rdma_xtr_v1_mr_deregister_body deregister_body;
    rdma_cmq_command_desc command;
    rdma_cmq_opcode_key opcode_key;
    rdma_cmq_ticket ticket;
    rdma_cmq_completion completion;
    rdma_recovery_record recovery;
    rdma_status rollback_status;
    rdma_hw_presence_e failure_presence;
    bit released_owned_backing;

    mr = null;
    result_finalized = 1'b0;
    ticket = null;
    released_owned_backing = 1'b0;

    if (hardware_key_allocated) begin
      deregister_body = rdma_xtr_v1_mr_deregister_body::type_id::create(
        "register_mr_rollback_deregister_body"
      );
      deregister_body.mr_h = project_handle(
        reserved_mr.handle, reserved_mr.local_mr_id,
        RDMA_RESOURCE_MR
      );
      deregister_body.stag_key = reserved_mr.lkey[7:0];
      deregister_body.next_state = RDMA_CONTEXT_INVALID;
      opcode_key = rdma_cmq_opcode_key::type_id::create(
        "register_mr_rollback_deregister_opcode"
      );
      opcode_key.profile_name = "xtr_v1";
      opcode_key.opcode = XTR_V1_OP_MR_DEREGISTER;
      opcode_key.variant = "deregister";
      command = rdma_cmq_command_desc::type_id::create(
        "register_mr_rollback_deregister"
      );
      command.function_h = rdma_clone_function_handle_value(
        owner, "register MR rollback command"
      );
      command.opcode_key = opcode_key;
      command.body = deregister_body;
      command.timeout = default_timeout;
      cmq.execute(command, ticket, completion, rollback_status);
      rollback_status = checked_status(
        rollback_status, "MR_DEREGISTER rollback returned null"
      );
      if (!rollback_status.ok()) begin
        result.rollback_statuses.push_back(
          rdma_cmq_clone_status_value(rollback_status)
        );
        failure_presence = (rollback_status.code == RDMA_SC_TIMEOUT) ?
          RDMA_HW_PRESENCE_UNKNOWN : RDMA_HW_PRESENCE_PRESENT;
        retain_mr_rollback_error(
          reserved_mr, primary_status, result, failure_presence, 1'b1,
          RDMA_CTRL_STEP_HW_MR_DEREGISTERED,
          (rollback_status.code == RDMA_SC_TIMEOUT) ? ticket : null, mr,
          result_finalized
        );
        return;
      end
      result.completed_steps.push_back(
        RDMA_CTRL_STEP_HW_MR_DEREGISTERED
      );
    end

    for (int i = int'(reserved_mr.hmc_refs.size()) - 1; i >= 0; i--) begin
      if (reserved_mr.hmc_refs[i] == null ||
          reserved_mr.hmc_refs[i].ownership !=
            RDMA_OWNERSHIP_CONTROL_PLANE ||
          reserved_mr.hmc_refs[i].release_complete)
        continue;
      if (hmc_allocator == null)
        rollback_status = invalid_state(
          "owned MR HMC rollback allocator is unavailable"
        );
      else
        rollback_status = hmc_allocator.\release (
          reserved_mr.hmc_refs[i].owner,
          reserved_mr.hmc_refs[i].object_kind,
          reserved_mr.hmc_refs[i].address
        );
      rollback_status = checked_status(
        rollback_status, "owned MR HMC rollback returned null"
      );
      if (!rollback_status.ok()) begin
        result.rollback_statuses.push_back(
          rdma_cmq_clone_status_value(rollback_status)
        );
        retain_mr_rollback_error(
          reserved_mr, primary_status, result, RDMA_HW_PRESENCE_ABSENT,
          1'b1, RDMA_CTRL_STEP_BACKING_RELEASED, null, mr,
          result_finalized
        );
        return;
      end
      reserved_mr.hmc_refs[i].release_complete = 1'b1;
      released_owned_backing = 1'b1;
    end

    for (int i = int'(reserved_mr.backing_refs.size()) - 1; i >= 0; i--) begin
      if (reserved_mr.backing_refs[i] == null ||
          reserved_mr.backing_refs[i].ownership !=
            RDMA_OWNERSHIP_CONTROL_PLANE ||
          reserved_mr.backing_refs[i].release_complete)
        continue;
      if (host_mem == null)
        rollback_status = invalid_state(
          "owned MR backing rollback host memory is unavailable"
        );
      else
        rollback_status = host_mem.\release (
          reserved_mr.backing_refs[i].mapping
        );
      rollback_status = checked_status(
        rollback_status, "owned MR backing rollback returned null"
      );
      if (!rollback_status.ok()) begin
        result.rollback_statuses.push_back(
          rdma_cmq_clone_status_value(rollback_status)
        );
        if (hardware_key_allocated || registry_programmed) begin
          retain_mr_rollback_error(
            reserved_mr, primary_status, result, RDMA_HW_PRESENCE_ABSENT,
            1'b1, RDMA_CTRL_STEP_BACKING_RELEASED, null, mr,
            result_finalized
          );
          return;
        end
        recovery = rdma_recovery_record::type_id::create(
          "register_mr_reserved_backing_rollback"
        );
        recovery.resource_h = snapshot_handle(reserved_mr.handle);
        recovery.hardware_presence = RDMA_HW_PRESENCE_ABSENT;
        recovery.completed_steps = result.completed_steps;
        recovery.pending_steps.push_back(RDMA_CTRL_STEP_BACKING_RELEASED);
        recovery.backing_refs = reserved_mr.backing_refs;
        recovery.hmc_refs = reserved_mr.hmc_refs;
        recovery.primary_status = rdma_cmq_clone_status_value(primary_status);
        recovery.rollback_statuses = result.rollback_statuses;
        finalize_mr_recovery(
          reserved_mr, recovery, primary_status, result, mr,
          result_finalized, 1'b1
        );
        return;
      end
      reserved_mr.backing_refs[i].release_complete = 1'b1;
      released_owned_backing = 1'b1;
    end
    if (released_owned_backing)
      result.completed_steps.push_back(RDMA_CTRL_STEP_BACKING_RELEASED);

    if (!registry_programmed) begin
      rollback_status = manager.release_reserved(reserved_mr.handle);
      rollback_status = checked_status(
        rollback_status, "MR reservation rollback returned null"
      );
      if (!rollback_status.ok()) begin
        result.rollback_statuses.push_back(
          rdma_cmq_clone_status_value(rollback_status)
        );
        if (reserved_mr.hmc_refs.size() == 0 &&
            reserved_mr.backing_refs.size() == 1 &&
            reserved_mr.backing_refs[0] != null &&
            reserved_mr.backing_refs[0].ownership ==
              RDMA_OWNERSHIP_CONTROL_PLANE) begin
          recovery = rdma_recovery_record::type_id::create(
            "register_mr_reserved_resource_rollback"
          );
          recovery.resource_h = snapshot_handle(reserved_mr.handle);
          recovery.hardware_presence = RDMA_HW_PRESENCE_ABSENT;
          recovery.completed_steps = result.completed_steps;
          recovery.pending_steps.push_back(RDMA_CTRL_STEP_RESOURCE_RELEASED);
          recovery.backing_refs = reserved_mr.backing_refs;
          recovery.hmc_refs = reserved_mr.hmc_refs;
          recovery.primary_status =
            rdma_cmq_clone_status_value(primary_status);
          recovery.rollback_statuses = result.rollback_statuses;
          finalize_mr_recovery(
            reserved_mr, recovery, primary_status, result, mr,
            result_finalized, 1'b1
          );
        end
        else begin
          retain_mr_rollback_error(
            reserved_mr, primary_status, result,
            RDMA_HW_PRESENCE_ABSENT, 1'b1,
            RDMA_CTRL_STEP_RESOURCE_RELEASED, null, mr,
            result_finalized
          );
        end
        return;
      end
    end
    else begin
      recovery = rdma_recovery_record::type_id::create(
        "register_mr_programmed_rollback"
      );
      recovery.resource_h = snapshot_handle(reserved_mr.handle);
      recovery.hardware_presence = RDMA_HW_PRESENCE_ABSENT;
      recovery.completed_steps = result.completed_steps;
      recovery.backing_refs = reserved_mr.backing_refs;
      recovery.hmc_refs = reserved_mr.hmc_refs;
      recovery.primary_status = rdma_cmq_clone_status_value(primary_status);
      recovery.rollback_statuses = result.rollback_statuses;
      rollback_status = manager.mark_error(reserved_mr.handle, recovery);
      rollback_status = checked_status(
        rollback_status, "programmed MR rollback mark ERROR returned null"
      );
      if (!rollback_status.ok()) begin
        result.rollback_statuses.push_back(
          rdma_cmq_clone_status_value(rollback_status)
        );
        retain_mr_rollback_error(
          reserved_mr, primary_status, result, RDMA_HW_PRESENCE_ABSENT,
          1'b1, RDMA_CTRL_STEP_RESOURCE_RELEASED, null, mr,
          result_finalized
        );
        return;
      end
      result.final_resource_state = RDMA_RESOURCE_ERROR;
      result.final_resource_state_known = 1'b1;
      rollback_status = manager.finalize_release(reserved_mr.handle);
      rollback_status = checked_status(
        rollback_status, "programmed MR rollback release returned null"
      );
      if (!rollback_status.ok()) begin
        result.rollback_statuses.push_back(
          rdma_cmq_clone_status_value(rollback_status)
        );
        retain_mr_rollback_error(
          reserved_mr, primary_status, result, RDMA_HW_PRESENCE_ABSENT,
          1'b1, RDMA_CTRL_STEP_RESOURCE_RELEASED, null, mr,
          result_finalized
        );
        return;
      end
    end
    result.completed_steps.push_back(RDMA_CTRL_STEP_RESOURCE_RELEASED);
    result.final_resource_state = RDMA_RESOURCE_RELEASED;
    result.final_resource_state_known = 1'b1;
  endtask

  protected function void retain_mr_destroy_error(
    rdma_mr mr_snapshot,
    rdma_status primary_status,
    rdma_control_result result,
    rdma_hw_presence_e hardware_presence,
    bit has_pending_step,
    rdma_control_step_e pending_step,
    rdma_cmq_ticket ambiguous_ticket,
    output bit result_finalized
  );
    rdma_mr ignored_mr;
    rdma_recovery_record recovery;

    recovery = rdma_recovery_record::type_id::create(
      "deregister_mr_recovery"
    );
    recovery.resource_h = snapshot_handle(mr_snapshot.handle);
    recovery.hardware_presence = hardware_presence;
    recovery.completed_steps = result.completed_steps;
    if (has_pending_step)
      recovery.pending_steps.push_back(pending_step);
    recovery.backing_refs = mr_snapshot.backing_refs;
    recovery.hmc_refs = mr_snapshot.hmc_refs;
    recovery.ambiguous_ticket = rdma_cmq_clone_ticket_value(
      ambiguous_ticket, "deregister MR recovery"
    );
    recovery.primary_status = rdma_cmq_clone_status_value(primary_status);
    recovery.rollback_statuses = result.rollback_statuses;
    finalize_mr_recovery(
      mr_snapshot, recovery, primary_status, result, ignored_mr,
      result_finalized
    );
  endfunction

  protected function void finish_result(
    rdma_control_result result,
    rdma_status operation_status
  );
    rdma_status normalized;

    if (result == null)
      return;
    normalized = checked_status(
      operation_status, "control-plane operation returned null status"
    );
    result.status = rdma_cmq_clone_status_value(normalized);
    result.primary_status = rdma_cmq_clone_status_value(normalized);
  endfunction

  protected function rdma_status configured_status();
    if (!configured || manager == null || cmq == null ||
        key_policy == null || default_timeout == 0)
      return invalid_state("control plane is not configured");
    return rdma_status::success();
  endfunction

  protected function rdma_status binding_owner_status(
    rdma_function_binding binding,
    output rdma_function_handle owner
  );
    rdma_status status;

    owner = null;
    if (binding == null)
      return invalid_argument("control-plane Function binding is null");
    status = binding.validate();
    if (status == null)
      return invalid_state("Function binding validation returned null");
    if (!status.ok())
      return rdma_cmq_clone_status_value(status);
    if (binding.state != RDMA_BIND_ACTIVE)
      return invalid_state("control-plane Function binding is not ACTIVE");
    owner = binding.make_handle();
    if (owner == null || owner.kind != RDMA_RESOURCE_FUNCTION)
      return invalid_state("Function binding owner construction failed");
    return rdma_status::success();
  endfunction

  protected function rdma_status generation_fence(
    rdma_function_binding binding,
    rdma_function_handle expected_owner
  );
    if (binding == null || expected_owner == null)
      return rdma_status::make(
        RDMA_SC_INVALID_ARGUMENT, "generation fence authority is null"
      );
    if (binding.function_uid != expected_owner.function_uid ||
        binding.global_function_id != expected_owner.object_id)
      return rdma_status::make(
        RDMA_SC_INVALID_ARGUMENT, "generation fence Function differs"
      );
    if (binding.generation != expected_owner.generation)
      return rdma_status::make(
        RDMA_SC_STALE_GENERATION,
        "Function generation changed during transaction"
      );
    return rdma_status::success();
  endfunction

  protected function rdma_status same_owner_status(
    rdma_function_handle candidate,
    rdma_function_handle expected,
    string label
  );
    if (candidate == null || candidate.kind != RDMA_RESOURCE_FUNCTION)
      return invalid_argument({label, " owner is not a Function handle"});
    if (expected == null || expected.kind != RDMA_RESOURCE_FUNCTION)
      return invalid_state({label, " expected Function owner is invalid"});
    if (candidate.function_uid != expected.function_uid ||
        candidate.object_id != expected.object_id)
      return invalid_argument({label, " Function identity does not match"});
    if (candidate.generation != expected.generation)
      return rdma_status::make(
        RDMA_SC_STALE_GENERATION,
        {label, " Function generation is stale"}
      );
    return rdma_status::success();
  endfunction

  protected function rdma_status request_status(
    rdma_create_pd_req request,
    rdma_function_handle owner
  );
    rdma_status status;

    if (request == null)
      return invalid_argument("create PD request is null");
    status = request.validate();
    if (status == null)
      return invalid_state("create PD request validation returned null");
    if (!status.ok())
      return rdma_cmq_clone_status_value(status);
    return same_owner_status(request.owner, owner, "create PD request");
  endfunction

  protected function rdma_status register_mr_request_status(
    rdma_register_mr_req request,
    rdma_function_handle owner
  );
    rdma_status status;

    if (request == null)
      return invalid_argument("register MR request is null");
    status = request.validate();
    if (status == null)
      return invalid_state("register MR request validation returned null");
    if (!status.ok())
      return rdma_cmq_clone_status_value(status);
    return same_owner_status(request.owner, owner, "register MR request");
  endfunction

  protected function rdma_dma_direction_e required_dma_direction(
    rdma_rdma_access_t access
  );
    return (access.local_write || access.remote_write ||
            access.remote_atomic) ?
           RDMA_DMA_BIDIRECTIONAL : RDMA_DMA_DEVICE_READ;
  endfunction

  protected function rdma_status validate_backing(
    rdma_function_binding binding,
    rdma_register_mr_req request,
    rdma_mr_backing_desc backing,
    rdma_function_handle owner,
    rdma_resource_ownership_e required_ownership
  );
    rdma_dma_permission_t required_permissions;
    rdma_dma_direction_e required_direction;
    rdma_status status;
    longint unsigned lease_size;

    if (binding == null || request == null || owner == null)
      return invalid_state("register MR backing authority is incomplete");
    if (backing == null)
      return invalid_argument("register MR backing descriptor is null");
    status = backing.validate();
    if (status == null)
      return invalid_state("register MR backing validation returned null");
    if (!status.ok())
      return rdma_cmq_clone_status_value(status);
    if (backing.page_layout.pbl_mode == RDMA_MR_PBL2 &&
        backing.page_layout.first_pbl_index > 28'hfff_ffff)
      return invalid_argument("register MR first PBL index exceeds 28 bits");
    status = same_owner_status(backing.function_h, owner,
                               "register MR backing");
    if (status == null || !status.ok())
      return checked_status(status,
                            "register MR backing owner check returned null");
    if (backing.requester_bdf != binding.queue_dma.requester_bdf)
      return rdma_status::make(
        RDMA_SC_DMA_TRANSLATION,
        "register MR backing requester BDF does not match Function"
      );
    if (backing.pasid_valid != binding.queue_dma.pasid_valid ||
        backing.pasid != binding.queue_dma.pasid)
      return rdma_status::make(
        RDMA_SC_DMA_TRANSLATION,
        "register MR backing PASID does not match Function"
      );
    required_permissions = '0;
    required_permissions.device_read = 1'b1;
    required_permissions.device_write = request.access.local_write ||
                                        request.access.remote_write ||
                                        request.access.remote_atomic;
    required_permissions.atomic = request.access.remote_atomic;
    required_direction = required_dma_direction(request.access);
    foreach (backing.backing_refs[i]) begin
      if (backing.backing_refs[i] == null ||
          backing.backing_refs[i].mapping == null)
        return invalid_argument("register MR backing reference is null");
      if (backing.backing_refs[i].ownership != required_ownership)
        return invalid_argument("register MR backing ownership is invalid");
      if (backing.backing_refs[i].mapping.pasid_valid !=
            backing.pasid_valid ||
          (backing.pasid_valid &&
           backing.backing_refs[i].mapping.pasid != backing.pasid))
        return rdma_status::make(
          RDMA_SC_DMA_TRANSLATION,
          "register MR backing PASID does not match mapping"
        );
      status = backing.backing_refs[i].mapping.check_access(
        owner, backing.requester_bdf, backing.pasid_valid, backing.pasid,
        binding.queue_dma.dma_domain_valid,
        binding.queue_dma.dma_domain_id, request.iova, request.length,
        required_direction, required_permissions
      );
      if (status == null)
        return invalid_state("register MR mapping access returned null");
      if (!status.ok())
        return rdma_cmq_clone_status_value(status);
    end
    foreach (backing.hmc_refs[i]) begin
      if (backing.hmc_refs[i] == null)
        return invalid_argument("register MR HMC reference is null");
      if (backing.hmc_refs[i].ownership != required_ownership)
        return invalid_argument("register MR HMC ownership is invalid");
      status = same_owner_status(backing.hmc_refs[i].owner, owner,
                                 "register MR HMC backing");
      if (status == null || !status.ok())
        return checked_status(
          status, "register MR HMC owner check returned null"
        );
      if (hmc_allocator == null)
        return invalid_state("register MR HMC allocator is unavailable");
      status = hmc_allocator.lookup(
        owner, backing.hmc_refs[i].object_kind,
        backing.hmc_refs[i].address, lease_size
      );
      if (status == null)
        return invalid_state("register MR HMC lookup returned null");
      if (!status.ok())
        return rdma_cmq_clone_status_value(status);
      if (lease_size != backing.hmc_refs[i].size)
        return invalid_argument("register MR HMC lease size does not match");
    end
    return rdma_status::success();
  endfunction

  protected function rdma_handle project_handle(
    rdma_handle software_h,
    int unsigned local_id,
    rdma_resource_kind_e expected_kind
  );
    rdma_handle projected;

    if (software_h == null || software_h.kind != expected_kind)
      return null;
    projected = new("control_plane_hw_projection");
    projected.kind = expected_kind;
    projected.function_uid = software_h.function_uid;
    projected.object_id = local_id;
    projected.generation = software_h.generation;
    return projected;
  endfunction

  protected function rdma_status pd_handle_owner_status(
    rdma_handle pd_h,
    rdma_function_handle owner
  );
    if (pd_h == null)
      return invalid_argument("destroy PD handle is null");
    if (pd_h.kind != RDMA_RESOURCE_PD)
      return invalid_argument("destroy PD handle kind is not PD");
    if (owner == null || owner.kind != RDMA_RESOURCE_FUNCTION)
      return invalid_state("destroy PD Function owner is invalid");
    if (pd_h.function_uid != owner.function_uid)
      return invalid_argument("destroy PD belongs to another Function");
    if (pd_h.generation != owner.generation)
      return rdma_status::make(
        RDMA_SC_STALE_GENERATION,
        "destroy PD Function generation is stale"
      );
    return rdma_status::success();
  endfunction

  protected function rdma_status mr_handle_owner_status(
    rdma_handle mr_h,
    rdma_function_handle owner
  );
    if (mr_h == null)
      return invalid_argument("deregister MR handle is null");
    if (mr_h.kind != RDMA_RESOURCE_MR)
      return invalid_argument("deregister MR handle kind is not MR");
    if (owner == null || owner.kind != RDMA_RESOURCE_FUNCTION)
      return invalid_state("deregister MR Function owner is invalid");
    if (mr_h.function_uid != owner.function_uid)
      return invalid_argument("deregister MR belongs to another Function");
    if (mr_h.generation != owner.generation)
      return rdma_status::make(
        RDMA_SC_STALE_GENERATION,
        "deregister MR Function generation is stale"
      );
    return rdma_status::success();
  endfunction

  protected function string function_key(rdma_function_handle owner);
    return $sformatf("%016h:%08h", owner.function_uid, owner.object_id);
  endfunction

  protected task reserve_transaction_id(
    output longint unsigned transaction_id,
    output rdma_status status
  );
    transaction_id = 0;
    status = invalid_state("transaction ID allocation did not complete");
    // Keep the uncontended guard off the blocking scheduler; a failed fast
    // path still uses get() and preserves real contention semantics.
    if (!lock_table_guard.try_get(1))
      lock_table_guard.get(1);
    if (transaction_ids_exhausted) begin
      status = rdma_status::make(
        RDMA_SC_RESOURCE_EXHAUSTED,
        "control-plane transaction ID space is exhausted"
      );
    end
    else begin
      transaction_id = next_transaction_id;
      if (next_transaction_id == 64'hffff_ffff_ffff_ffff)
        transaction_ids_exhausted = 1'b1;
      else
        next_transaction_id++;
      status = rdma_status::success();
    end
    lock_table_guard.put(1);
  endtask

  protected task acquire_function_lock(
    rdma_function_handle owner,
    output semaphore function_lock
  );
    string key;

    function_lock = null;
    key = function_key(owner);
    // Keep the uncontended guard off the blocking scheduler; a failed fast
    // path still uses get() and preserves real contention semantics.
    if (!lock_table_guard.try_get(1))
      lock_table_guard.get(1);
    if (!function_locks.exists(key))
      function_locks[key] = new(1);
    function_lock = function_locks[key];
    lock_table_guard.put(1);
    function_lock.get(1);
  endtask

  function rdma_status configure(
    rdma_resource_manager resource_manager,
    rdma_cmq_port cmq_port,
    rdma_stag_key_policy key_policy,
    rdma_host_mem_api host_mem = null,
    rdma_hmc_allocator hmc_allocator = null,
    rdma_context_backing_api context_backing = null,
    time command_timeout = 1us
  );
    rdma_status status;

    if (configured)
      return invalid_state("control plane is already configured");
    if (resource_manager == null)
      return invalid_argument("resource manager is null");
    if (cmq_port == null)
      return invalid_argument("CMQ port is null");
    if (key_policy == null)
      return invalid_argument("STAG key policy is null");
    if (command_timeout == 0)
      return invalid_argument("default control-plane timeout is zero");

    this.manager = resource_manager;
    this.cmq = cmq_port;
    this.key_policy = key_policy;
    this.host_mem = host_mem;
    this.hmc_allocator = hmc_allocator;
    this.context_backing = context_backing;
    default_timeout = command_timeout;
    queue_executor = rdma_queue_lifecycle_executor::type_id::create(
      "control_plane_queue_executor"
    );
    if (queue_executor == null)
      return invalid_state("queue lifecycle executor construction failed");
    status = queue_executor.configure(
      resource_manager, cmq_port, host_mem, context_backing, command_timeout
    );
    status = checked_status(status, "queue executor configure returned null");
    if (!status.ok()) begin
      queue_executor = null;
      return status;
    end
    qp_executor = rdma_qp_lifecycle_executor::type_id::create(
      "control_plane_qp_executor"
    );
    if (qp_executor == null)
      return invalid_state("QP lifecycle executor construction failed");
    if (host_mem != null && context_backing != null) begin
      status = qp_executor.configure(
        resource_manager, cmq_port, host_mem, context_backing, command_timeout
      );
      status = checked_status(status, "QP executor configure returned null");
      if (!status.ok()) begin
        qp_executor = null;
        return status;
      end
    end
    configured = 1'b1;
    return rdma_status::success();
  endfunction

  protected function rdma_status queue_request_status(
    rdma_semantic_request request,
    rdma_function_handle owner,
    string label
  );
    rdma_status status;

    if (request == null)
      return invalid_argument({label, " request is null"});
    status = request.validate();
    if (status == null)
      return invalid_state({label, " request validation returned null"});
    if (!status.ok())
      return rdma_cmq_clone_status_value(status);
    return same_owner_status(request.owner, owner, label);
  endfunction

  protected function rdma_status queue_target_owner_status(
    rdma_handle target,
    rdma_function_handle owner,
    string label
  );
    if (target == null)
      return invalid_argument({label, " target handle is null"});
    if (owner == null || owner.kind != RDMA_RESOURCE_FUNCTION)
      return invalid_state({label, " Function owner is invalid"});
    if (target.function_uid != owner.function_uid)
      return invalid_argument({label, " target belongs to another Function"});
    if (target.generation != owner.generation)
      return rdma_status::make(RDMA_SC_STALE_GENERATION,
                               {label, " target generation is stale"});
    return rdma_status::success();
  endfunction

  protected task create_queue_facade(
    rdma_function_binding binding,
    rdma_semantic_request request,
    bit requires_context,
    rdma_resource_kind_e expected_kind,
    output rdma_queue_resource queue,
    output rdma_control_result result
  );
    rdma_function_handle owner;
    rdma_function_handle locked_owner;
    rdma_status status;
    semaphore function_lock;
    longint unsigned transaction_id;

    queue = null;
    result = make_result();
    function_lock = null;
    reserve_transaction_id(transaction_id, status);
    result.transaction_id = transaction_id;
    do begin
      if (status == null || !status.ok()) begin
        status = checked_status(status,
                                "queue transaction ID allocation returned null");
        break;
      end
      status = configured_status();
      if (status == null || !status.ok()) begin
        status = checked_status(status,
                                "queue control-plane configuration check returned null");
        break;
      end
      if (queue_executor == null) begin
        status = invalid_state("queue lifecycle executor is unavailable");
        break;
      end
      if (host_mem == null) begin
        status = invalid_state("queue create requires a host-memory adapter");
        break;
      end
      if (requires_context && context_backing == null) begin
        status = invalid_state(
          "CQ/SRQ queue create requires a context-backing adapter"
        );
        break;
      end
      status = binding_owner_status(binding, owner);
      if (status == null || !status.ok()) begin
        status = checked_status(status,
                                "queue Function binding check returned null");
        break;
      end
      status = queue_request_status(request, owner, "queue create request");
      if (status == null || !status.ok()) begin
        status = checked_status(status,
                                "queue create request check returned null");
        break;
      end

      acquire_function_lock(owner, function_lock);
      status = binding_owner_status(binding, locked_owner);
      if (status == null || !status.ok()) begin
        status = checked_status(status,
                                "post-lock queue Function check returned null");
        break;
      end
      status = same_owner_status(locked_owner, owner,
                                 "post-lock queue Function");
      if (status == null || !status.ok()) begin
        status = checked_status(status,
                                "post-lock queue Function identity returned null");
        break;
      end
      status = queue_request_status(request, locked_owner,
                                    "post-lock queue create request");
      if (status == null || !status.ok()) begin
        status = checked_status(status,
                                "post-lock queue request check returned null");
        break;
      end
      queue_executor.create_locked(binding, owner, request, transaction_id,
                                   queue, result);
      if (result != null && result.ok() &&
          (queue == null || queue.resource_kind() != expected_kind)) begin
        queue = null;
        status = invalid_state("queue executor returned the wrong resource kind");
        finish_result(result, status);
        break;
      end
      status = (result == null) ?
        invalid_state("queue executor returned a null result") :
        rdma_cmq_clone_status_value(result.status);
      if (status == null)
        status = invalid_state("queue executor result status is null");
      break;
    end while (1'b0);
    if (result == null)
      result = make_result();
    if (status == null || !status.ok()) begin
      queue = null;
      finish_result(result, status);
    end
    if (function_lock != null)
      function_lock.put(1);
  endtask

  protected task destroy_queue_facade(
    rdma_function_binding binding,
    rdma_destroy_resource_req request,
    rdma_resource_kind_e expected_kind,
    output rdma_control_result result
  );
    rdma_function_handle owner;
    rdma_function_handle locked_owner;
    rdma_status status;
    semaphore function_lock;
    longint unsigned transaction_id;

    result = make_result();
    function_lock = null;
    reserve_transaction_id(transaction_id, status);
    result.transaction_id = transaction_id;
    do begin
      if (status == null || !status.ok()) begin
        status = checked_status(status,
                                "queue destroy transaction ID returned null");
        break;
      end
      status = configured_status();
      if (status == null || !status.ok()) begin
        status = checked_status(status,
                                "queue destroy configuration check returned null");
        break;
      end
      status = binding_owner_status(binding, owner);
      if (status == null || !status.ok()) begin
        status = checked_status(status,
                                "queue destroy Function check returned null");
        break;
      end
      status = queue_request_status(request, owner, "queue destroy request");
      if (status == null || !status.ok()) begin
        status = checked_status(status,
                                "queue destroy request check returned null");
        break;
      end
      if (request.target_h.kind != expected_kind) begin
        status = invalid_argument("queue destroy target kind is invalid");
        break;
      end
      status = queue_target_owner_status(request.target_h, owner,
                                         "queue destroy target");
      if (status == null || !status.ok()) break;

      acquire_function_lock(owner, function_lock);
      status = binding_owner_status(binding, locked_owner);
      if (status == null || !status.ok()) begin
        status = checked_status(status,
                                "post-lock queue destroy Function returned null");
        break;
      end
      status = same_owner_status(locked_owner, owner,
                                 "post-lock queue destroy Function");
      if (status == null || !status.ok()) break;
      if (request.target_h.kind != expected_kind) begin
        status = invalid_argument("post-lock queue destroy target kind is invalid");
        break;
      end
      status = queue_target_owner_status(request.target_h, locked_owner,
                                         "post-lock queue destroy target");
      if (status == null || !status.ok()) break;
      queue_executor.destroy_locked(binding, owner, request,
                                    transaction_id, result);
      status = (result == null) ?
        invalid_state("queue destroy executor returned null result") :
        rdma_cmq_clone_status_value(result.status);
      break;
    end while (1'b0);
    if (status == null || !status.ok())
      finish_result(result, status);
    if (function_lock != null)
      function_lock.put(1);
  endtask

  task create_cq(
    rdma_function_binding binding,
    rdma_create_cq_req request,
    output rdma_cq cq,
    output rdma_control_result result
  );
    rdma_queue_resource queue;
    cq = null;
    create_queue_facade(binding, request, 1'b1, RDMA_RESOURCE_CQ, queue, result);
    if (result != null && result.ok()) begin
      if (!$cast(cq, queue) || cq == null || cq.state != RDMA_RESOURCE_ACTIVE) begin
        cq = null;
        finish_result(result, invalid_state("typed CQ projection is invalid"));
      end
    end
  endtask

  task create_srq(
    rdma_function_binding binding,
    rdma_create_srq_req request,
    output rdma_srq srq,
    output rdma_control_result result
  );
    rdma_queue_resource queue;
    srq = null;
    create_queue_facade(binding, request, 1'b1, RDMA_RESOURCE_SRQ, queue, result);
    if (result != null && result.ok()) begin
      if (!$cast(srq, queue) || srq == null || srq.state != RDMA_RESOURCE_ACTIVE) begin
        srq = null;
        finish_result(result, invalid_state("typed SRQ projection is invalid"));
      end
    end
  endtask

  task create_ceq(
    rdma_function_binding binding,
    rdma_create_ceq_req request,
    output rdma_ceq ceq,
    output rdma_control_result result
  );
    rdma_queue_resource queue;
    ceq = null;
    create_queue_facade(binding, request, 1'b0, RDMA_RESOURCE_CEQ, queue, result);
    if (result != null && result.ok()) begin
      if (!$cast(ceq, queue) || ceq == null || ceq.state != RDMA_RESOURCE_ACTIVE) begin
        ceq = null;
        finish_result(result, invalid_state("typed CEQ projection is invalid"));
      end
    end
  endtask

  task create_aeq(
    rdma_function_binding binding,
    rdma_create_aeq_req request,
    output rdma_aeq aeq,
    output rdma_control_result result
  );
    rdma_queue_resource queue;
    aeq = null;
    create_queue_facade(binding, request, 1'b0, RDMA_RESOURCE_AEQ, queue, result);
    if (result != null && result.ok()) begin
      if (!$cast(aeq, queue) || aeq == null || aeq.state != RDMA_RESOURCE_ACTIVE) begin
        aeq = null;
        finish_result(result, invalid_state("typed AEQ projection is invalid"));
      end
    end
  endtask

  task create_qp(
    rdma_function_binding binding,
    rdma_create_qp_req request,
    output rdma_qp qp,
    output rdma_control_result result
  );
    rdma_function_handle owner;
    rdma_function_handle locked_owner;
    rdma_status status;
    rdma_status qp_validation_status;
    semaphore function_lock;
    longint unsigned transaction_id;
    bit executor_called;

    qp = null;
    result = make_result();
    function_lock = null;
    executor_called = 1'b0;
    reserve_transaction_id(transaction_id, status);
    result.transaction_id = transaction_id;
    do begin
      if (status == null || !status.ok()) begin
        status = checked_status(status,
                                "QP transaction ID allocation returned null");
        break;
      end
      status = configured_status();
      if (status == null || !status.ok()) begin
        status = checked_status(status,
                                "QP control-plane configuration returned null");
        break;
      end
      if (host_mem == null || context_backing == null) begin
        status = invalid_state(
          "QP create requires host-memory and context-backing adapters"
        );
        break;
      end
      if (qp_executor == null) begin
        status = invalid_state("QP lifecycle executor is unavailable");
        break;
      end
      status = binding_owner_status(binding, owner);
      if (status == null || !status.ok()) begin
        status = checked_status(status, "QP Function binding returned null");
        break;
      end
      status = queue_request_status(request, owner, "QP create request");
      if (status == null || !status.ok()) begin
        status = checked_status(status, "QP create request returned null");
        break;
      end

      acquire_function_lock(owner, function_lock);
      status = binding_owner_status(binding, locked_owner);
      if (status == null || !status.ok()) begin
        status = checked_status(status,
                                "post-lock QP Function returned null");
        break;
      end
      status = same_owner_status(locked_owner, owner,
                                 "post-lock QP Function");
      if (status == null || !status.ok()) begin
        status = checked_status(status,
                                "post-lock QP identity returned null");
        break;
      end
      status = queue_request_status(request, locked_owner,
                                    "post-lock QP create request");
      if (status == null || !status.ok()) begin
        status = checked_status(status,
                                "post-lock QP request returned null");
        break;
      end

      executor_called = 1'b1;
      qp_executor.create_locked(binding, owner, request, transaction_id,
                                qp, result);
      if (result == null) begin
        status = invalid_state("QP executor returned a null result");
        break;
      end
      if (result.transaction_id != transaction_id) begin
        qp = null;
        status = invalid_state("QP executor changed the transaction ID");
        finish_result(result, status);
        break;
      end
      status = checked_status(result.status,
                              "QP executor result status is null");
      if (status.ok()) begin
        qp_validation_status = qp == null ? null : qp.validate();
        if (qp == null || qp.state != RDMA_RESOURCE_ACTIVE ||
            qp.qp_state != RDMA_QPS_RESET || qp_validation_status == null ||
            !qp_validation_status.ok()) begin
          qp = null;
          status = invalid_state("typed QP projection is invalid");
          finish_result(result, status);
        end
      end
      break;
    end while (1'b0);
    if (result == null) begin
      result = make_result();
      result.transaction_id = transaction_id;
    end
    if (status == null || !status.ok()) begin
      qp = null;
      if (!executor_called)
        finish_result(result, status);
    end
    if (function_lock != null)
      function_lock.put(1);
  endtask

  task modify_qp(
    rdma_function_binding binding,
    rdma_modify_qp_req request,
    output rdma_qp qp,
    output rdma_control_result result
  );
    rdma_function_handle owner;
    rdma_function_handle locked_owner;
    rdma_status status;
    rdma_status qp_validation_status;
    semaphore function_lock;
    longint unsigned transaction_id;
    bit executor_called;

    qp = null;
    result = make_result();
    function_lock = null;
    executor_called = 1'b0;
    reserve_transaction_id(transaction_id, status);
    result.transaction_id = transaction_id;
    do begin
      if (status == null || !status.ok()) begin
        status = checked_status(status,
                                "QP modify transaction ID allocation returned null");
        break;
      end
      status = configured_status();
      if (status == null || !status.ok()) begin
        status = checked_status(status,
                                "QP modify control-plane configuration returned null");
        break;
      end
      if (host_mem == null || context_backing == null || qp_executor == null) begin
        status = invalid_state("QP modify requires a configured QP executor");
        break;
      end
      status = binding_owner_status(binding, owner);
      if (status == null || !status.ok()) begin
        status = checked_status(status, "QP modify Function binding returned null");
        break;
      end
      status = queue_request_status(request, owner, "QP modify request");
      if (status == null || !status.ok()) begin
        status = checked_status(status, "QP modify request returned null");
        break;
      end
      status = queue_target_owner_status(request.qp_h, owner,
                                         "QP modify target");
      if (status == null || !status.ok()) break;

      acquire_function_lock(owner, function_lock);
      status = binding_owner_status(binding, locked_owner);
      if (status == null || !status.ok()) begin
        status = checked_status(status,
                                "post-lock QP modify Function returned null");
        break;
      end
      status = same_owner_status(locked_owner, owner,
                                 "post-lock QP modify Function");
      if (status == null || !status.ok()) break;
      status = queue_request_status(request, locked_owner,
                                    "post-lock QP modify request");
      if (status == null || !status.ok()) begin
        status = checked_status(status, "post-lock QP modify request returned null");
        break;
      end
      status = queue_target_owner_status(request.qp_h, locked_owner,
                                         "post-lock QP modify target");
      if (status == null || !status.ok()) break;

      executor_called = 1'b1;
      qp_executor.modify_locked(binding, owner, request, transaction_id,
                                qp, result);
      if (result == null) begin
        status = invalid_state("QP modify executor returned a null result");
        break;
      end
      if (result.transaction_id != transaction_id) begin
        qp = null;
        status = invalid_state("QP modify executor changed the transaction ID");
        finish_result(result, status);
        break;
      end
      status = checked_status(result.status,
                              "QP modify executor result status is null");
      if (status.ok()) begin
        qp_validation_status = qp == null ? null : qp.validate();
        if (qp == null || qp.state != RDMA_RESOURCE_ACTIVE ||
            qp_validation_status == null || !qp_validation_status.ok()) begin
          qp = null;
          status = invalid_state("typed QP modify projection is invalid");
          finish_result(result, status);
        end
      end
      break;
    end while (1'b0);
    if (result == null) begin
      result = make_result();
      result.transaction_id = transaction_id;
    end
    if (status == null || !status.ok()) begin
      qp = null;
      if (!executor_called)
        finish_result(result, status);
    end
    if (function_lock != null)
      function_lock.put(1);
  endtask

  task destroy_qp(
    rdma_function_binding binding,
    rdma_destroy_resource_req request,
    output rdma_control_result result
  );
    rdma_function_handle owner, locked_owner;
    rdma_status status;
    semaphore function_lock;
    longint unsigned transaction_id;
    bit executor_called;
    result = make_result(); function_lock = null; executor_called = 1'b0;
    reserve_transaction_id(transaction_id, status);
    result.transaction_id = transaction_id;
    do begin
      if (status == null || !status.ok()) begin status = checked_status(status,
        "QP destroy transaction ID allocation returned null"); break; end
      status = configured_status(); if (status == null || !status.ok()) begin
        status = checked_status(status, "QP destroy control-plane configuration returned null"); break; end
      status = binding_owner_status(binding, owner); if (status == null || !status.ok()) begin
        status = checked_status(status, "QP destroy Function binding returned null"); break; end
      status = queue_request_status(request, owner, "QP destroy request");
      if (status == null || !status.ok()) begin status = checked_status(status, "QP destroy request returned null"); break; end
      if (request.target_h.kind != RDMA_RESOURCE_QP) begin status = invalid_argument("QP destroy target kind is invalid"); break; end
      status = queue_target_owner_status(request.target_h, owner, "QP destroy target"); if (status == null || !status.ok()) break;
      acquire_function_lock(owner, function_lock);
      status = binding_owner_status(binding, locked_owner); if (status == null || !status.ok()) break;
      status = same_owner_status(locked_owner, owner, "post-lock QP destroy Function"); if (status == null || !status.ok()) break;
      status = queue_target_owner_status(request.target_h, locked_owner, "post-lock QP destroy target"); if (status == null || !status.ok()) break;
      executor_called = 1'b1;
      qp_executor.destroy_locked(binding, owner, request, transaction_id, result);
      if (result == null) status = invalid_state("QP destroy executor returned null result");
      else if (result.transaction_id != transaction_id) begin status = invalid_state("QP destroy executor changed transaction ID"); finish_result(result, status); end
      else status = checked_status(result.status, "QP destroy executor result status is null");
      break;
    end while (1'b0);
    if (result == null) begin result = make_result(); result.transaction_id = transaction_id; end
    if ((status == null || !status.ok()) && !executor_called) finish_result(result, status);
    if (function_lock != null) function_lock.put(1);
  endtask

  task destroy_cq(
    rdma_function_binding binding,
    rdma_destroy_resource_req request,
    output rdma_control_result result
  );
    destroy_queue_facade(binding, request, RDMA_RESOURCE_CQ, result);
  endtask

  task destroy_srq(
    rdma_function_binding binding,
    rdma_destroy_resource_req request,
    output rdma_control_result result
  );
    destroy_queue_facade(binding, request, RDMA_RESOURCE_SRQ, result);
  endtask

  task destroy_ceq(
    rdma_function_binding binding,
    rdma_destroy_resource_req request,
    output rdma_control_result result
  );
    destroy_queue_facade(binding, request, RDMA_RESOURCE_CEQ, result);
  endtask

  task destroy_aeq(
    rdma_function_binding binding,
    rdma_destroy_resource_req request,
    output rdma_control_result result
  );
    destroy_queue_facade(binding, request, RDMA_RESOURCE_AEQ, result);
  endtask

  task create_pd(
    rdma_function_binding binding,
    rdma_create_pd_req request,
    output rdma_pd pd,
    output rdma_control_result result
  );
    rdma_function_handle owner;
    rdma_function_handle locked_owner;
    rdma_pd reserved_pd;
    rdma_resource active_resource;
    rdma_status status;
    rdma_status rollback_status;
    semaphore function_lock;
    longint unsigned transaction_id;

    pd = null;
    result = make_result();
    function_lock = null;
    reserve_transaction_id(transaction_id, status);
    result.transaction_id = transaction_id;

    do begin
      if (status == null || !status.ok()) begin
        status = checked_status(
          status, "transaction ID allocation returned null status"
        );
        break;
      end
      status = configured_status();
      if (status == null || !status.ok()) begin
        status = checked_status(
          status, "control-plane configuration check returned null"
        );
        break;
      end
      status = binding_owner_status(binding, owner);
      if (status == null || !status.ok()) begin
        status = checked_status(status,
                                "Function binding check returned null");
        break;
      end
      status = request_status(request, owner);
      if (status == null || !status.ok()) begin
        status = checked_status(status,
                                "create PD request check returned null");
        break;
      end

      acquire_function_lock(owner, function_lock);
      status = binding_owner_status(binding, locked_owner);
      if (status == null || !status.ok()) begin
        status = checked_status(
          status, "post-lock Function binding check returned null"
        );
        break;
      end
      status = same_owner_status(
        locked_owner, owner, "post-lock create PD binding"
      );
      if (status == null || !status.ok()) begin
        status = checked_status(
          status, "post-lock Function identity check returned null"
        );
        break;
      end
      status = request_status(request, locked_owner);
      if (status == null || !status.ok()) begin
        status = checked_status(
          status, "post-lock create PD request check returned null"
        );
        break;
      end
      status = manager.create_pd(binding, reserved_pd);
      if (status == null || !status.ok()) begin
        status = checked_status(status,
                                "resource manager create PD returned null");
        break;
      end
      if (reserved_pd == null || reserved_pd.handle == null ||
          reserved_pd.state != RDMA_RESOURCE_ALLOCATED) begin
        status = invalid_state(
          "resource manager returned an invalid PD reservation"
        );
        if (reserved_pd != null && reserved_pd.handle != null) begin
          result.resource_h = snapshot_handle(reserved_pd.handle);
          result.final_resource_state = RDMA_RESOURCE_ALLOCATED;
          result.final_resource_state_known = 1'b1;
          rollback_status = manager.release_reserved(reserved_pd.handle);
          rollback_status = checked_status(
            rollback_status, "PD reservation rollback returned null"
          );
          if (rollback_status.ok()) begin
            result.final_resource_state = RDMA_RESOURCE_RELEASED;
          end
          else
            result.rollback_statuses.push_back(
              rdma_cmq_clone_status_value(rollback_status)
            );
        end
        break;
      end
      result.resource_h = snapshot_handle(reserved_pd.handle);
      result.final_resource_state = RDMA_RESOURCE_ALLOCATED;
      result.final_resource_state_known = 1'b1;
      result.completed_steps.push_back(RDMA_CTRL_STEP_RESOURCE_RESERVED);

      status = manager.activate(reserved_pd.handle);
      if (status == null || !status.ok()) begin
        status = checked_status(status,
                                "resource manager PD activate returned null");
        rollback_status = manager.release_reserved(reserved_pd.handle);
        rollback_status = checked_status(
          rollback_status, "PD reservation rollback returned null"
        );
        if (rollback_status.ok()) begin
          result.final_resource_state = RDMA_RESOURCE_RELEASED;
        end
        else begin
          result.rollback_statuses.push_back(
            rdma_cmq_clone_status_value(rollback_status)
          );
        end
        break;
      end
      result.final_resource_state = RDMA_RESOURCE_ACTIVE;
      result.final_resource_state_known = 1'b1;
      result.completed_steps.push_back(RDMA_CTRL_STEP_REGISTRY_ACTIVE);

      status = manager.lookup(reserved_pd.handle, active_resource);
      if (status == null || !status.ok()) begin
        status = checked_status(
          status, "resource manager active PD lookup returned null"
        );
        cleanup_activated_pd(reserved_pd.handle, result);
        break;
      end
      if (!$cast(pd, active_resource) || pd == null || pd.handle == null ||
          pd.state != RDMA_RESOURCE_ACTIVE) begin
        pd = null;
        status = invalid_state(
          "resource manager active PD snapshot is invalid"
        );
        cleanup_activated_pd(reserved_pd.handle, result);
        break;
      end
      result.resource_h = snapshot_handle(pd.handle);
      status = rdma_status::success();
    end while (1'b0);

    finish_result(result, status);
    if (function_lock != null)
      function_lock.put(1);
  endtask

  task destroy_pd(
    rdma_function_binding binding,
    rdma_handle pd_h,
    output rdma_control_result result
  );
    rdma_function_handle owner;
    rdma_resource resource;
    rdma_pd pd_snapshot;
    rdma_status status;
    semaphore function_lock;
    longint unsigned transaction_id;

    result = make_result();
    result.resource_h = snapshot_handle(pd_h);
    function_lock = null;
    reserve_transaction_id(transaction_id, status);
    result.transaction_id = transaction_id;

    do begin
      if (status == null || !status.ok()) begin
        status = checked_status(
          status, "transaction ID allocation returned null status"
        );
        break;
      end
      status = configured_status();
      if (status == null || !status.ok()) begin
        status = checked_status(
          status, "control-plane configuration check returned null"
        );
        break;
      end
      status = binding_owner_status(binding, owner);
      if (status == null || !status.ok()) begin
        status = checked_status(status,
                                "Function binding check returned null");
        break;
      end
      status = pd_handle_owner_status(pd_h, owner);
      if (status == null || !status.ok()) begin
        status = checked_status(status,
                                "destroy PD handle check returned null");
        break;
      end

      acquire_function_lock(owner, function_lock);
      status = manager.lookup(pd_h, resource);
      if (status == null || !status.ok()) begin
        status = checked_status(status,
                                "resource manager PD lookup returned null");
        break;
      end
      if (!$cast(pd_snapshot, resource) || pd_snapshot == null ||
          pd_snapshot.handle == null || pd_snapshot.owner == null) begin
        status = invalid_state("resource manager PD snapshot is invalid");
        break;
      end
      result.resource_h = snapshot_handle(pd_snapshot.handle);
      result.final_resource_state = pd_snapshot.state;
      result.final_resource_state_known = 1'b1;
      status = same_owner_status(pd_snapshot.owner, owner, "destroy PD");
      if (status == null || !status.ok()) begin
        status = checked_status(status,
                                "destroy PD owner check returned null");
        break;
      end
      if (pd_snapshot.state != RDMA_RESOURCE_ACTIVE) begin
        status = invalid_state("destroy PD requires an ACTIVE PD");
        break;
      end

      status = manager.begin_quiesce(pd_snapshot.handle);
      if (status == null || !status.ok()) begin
        status = checked_status(
          status, "resource manager PD quiesce returned null"
        );
        result.final_resource_state = RDMA_RESOURCE_ACTIVE;
        break;
      end
      result.final_resource_state = RDMA_RESOURCE_QUIESCING;

      status = manager.finalize_release(pd_snapshot.handle);
      if (status == null || !status.ok()) begin
        status = checked_status(
          status, "resource manager PD release returned null"
        );
        break;
      end
      result.final_resource_state = RDMA_RESOURCE_RELEASED;
      result.completed_steps.push_back(RDMA_CTRL_STEP_RESOURCE_RELEASED);
      status = rdma_status::success();
    end while (1'b0);

    finish_result(result, status);
    if (function_lock != null)
      function_lock.put(1);
  endtask

  task deregister_mr(
    rdma_function_binding binding,
    rdma_handle mr_h,
    output rdma_control_result result
  );
    rdma_function_handle owner;
    rdma_function_handle locked_owner;
    rdma_resource resource;
    rdma_mr mr_snapshot;
    rdma_xtr_v1_occ_flush_body occ_body;
    rdma_xtr_v1_mr_deregister_body deregister_body;
    rdma_xtr_v1_cmq_empty_body drain_body;
    rdma_cmq_command_desc command;
    rdma_cmq_opcode_key opcode_key;
    rdma_cmq_ticket ticket;
    rdma_cmq_completion completion;
    rdma_status status;
    rdma_status primary_status;
    rdma_status cleanup_status;
    semaphore function_lock;
    longint unsigned transaction_id;
    bit result_finalized;

    result = make_result();
    result.resource_h = snapshot_handle(mr_h);
    function_lock = null;
    result_finalized = 1'b0;
    reserve_transaction_id(transaction_id, status);
    result.transaction_id = transaction_id;

    do begin
      if (status == null || !status.ok()) begin
        status = checked_status(
          status, "deregister MR transaction ID allocation returned null"
        );
        break;
      end
      status = configured_status();
      if (status == null || !status.ok()) begin
        status = checked_status(
          status, "deregister MR configuration check returned null"
        );
        break;
      end
      status = binding_owner_status(binding, owner);
      if (status == null || !status.ok()) begin
        status = checked_status(
          status, "deregister MR Function check returned null"
        );
        break;
      end
      status = generation_fence(binding, owner);
      if (status == null || !status.ok()) begin
        status = checked_status(
          status, "initial deregister MR generation fence returned null"
        );
        break;
      end
      status = mr_handle_owner_status(mr_h, owner);
      if (status == null || !status.ok()) begin
        status = checked_status(
          status, "deregister MR handle check returned null"
        );
        break;
      end

      acquire_function_lock(owner, function_lock);
      status = binding_owner_status(binding, locked_owner);
      if (status == null || !status.ok()) begin
        status = checked_status(
          status, "post-lock deregister MR Function check returned null"
        );
        break;
      end
      status = generation_fence(binding, owner);
      if (status == null || !status.ok()) begin
        status = checked_status(
          status, "post-lock deregister MR generation fence returned null"
        );
        break;
      end
      status = mr_handle_owner_status(mr_h, locked_owner);
      if (status == null || !status.ok()) begin
        status = checked_status(
          status, "post-lock deregister MR handle check returned null"
        );
        break;
      end
      status = manager.lookup(mr_h, resource);
      if (status == null || !status.ok()) begin
        status = checked_status(
          status, "resource manager deregister MR lookup returned null"
        );
        break;
      end
      if (!$cast(mr_snapshot, resource) || mr_snapshot == null ||
          mr_snapshot.handle == null || mr_snapshot.owner == null) begin
        status = invalid_state(
          "resource manager deregister MR snapshot is invalid"
        );
        break;
      end
      result.resource_h = snapshot_handle(mr_snapshot.handle);
      result.final_resource_state = mr_snapshot.state;
      result.final_resource_state_known = 1'b1;
      status = same_owner_status(
        mr_snapshot.owner, locked_owner, "deregister MR"
      );
      if (status == null || !status.ok()) begin
        status = checked_status(
          status, "deregister MR owner check returned null"
        );
        break;
      end
      if (mr_snapshot.state != RDMA_RESOURCE_ACTIVE) begin
        status = invalid_state("deregister MR requires an ACTIVE MR");
        break;
      end
      if (mr_snapshot.outstanding_ids.size() != 0) begin
        status = rdma_status::make(
          RDMA_SC_RESOURCE_BUSY,
          "deregister MR has outstanding operations"
        );
        break;
      end

      status = manager.begin_quiesce(mr_snapshot.handle);
      if (status == null || !status.ok()) begin
        status = checked_status(
          status, "resource manager MR quiesce returned null"
        );
        result.final_resource_state = RDMA_RESOURCE_ACTIVE;
        break;
      end
      result.final_resource_state = RDMA_RESOURCE_QUIESCING;

      if (mr_snapshot.hmc_refs.size() != 0) begin
        occ_body = rdma_xtr_v1_occ_flush_body::type_id::create(
          "deregister_mr_occ_flush_body"
        );
        occ_body.mr_serial_flush = 1'b1;
        occ_body.pble = 1'b1;
        occ_body.mr_serial = mr_snapshot.mr_serial[11:0];
        opcode_key = rdma_cmq_opcode_key::type_id::create(
          "deregister_mr_occ_flush_opcode"
        );
        opcode_key.profile_name = "xtr_v1";
        opcode_key.opcode = XTR_V1_OP_OCC_FLUSH;
        opcode_key.variant = "occ_flush";
        command = rdma_cmq_command_desc::type_id::create(
          "deregister_mr_occ_flush"
        );
        command.function_h = rdma_clone_function_handle_value(
          locked_owner, "deregister MR OCC command"
        );
        command.opcode_key = opcode_key;
        command.body = occ_body;
        command.timeout = default_timeout;
        ticket = null;
        completion = null;
        cmq.execute(command, ticket, completion, status);
        status = checked_status(status, "OCC_FLUSH execution returned null");
        if (!status.ok()) begin
          primary_status = rdma_cmq_clone_status_value(status);
          if (status.code == RDMA_SC_TIMEOUT) begin
            retain_mr_destroy_error(
              mr_snapshot, primary_status, result,
              RDMA_HW_PRESENCE_UNKNOWN, 1'b1,
              RDMA_CTRL_STEP_HW_OCC_FLUSHED, ticket, result_finalized
            );
          end
          else begin
            cleanup_status = manager.restore_active(mr_snapshot.handle);
            cleanup_status = checked_status(
              cleanup_status, "OCC failure restore ACTIVE returned null"
            );
            if (cleanup_status.ok()) begin
              result.final_resource_state = RDMA_RESOURCE_ACTIVE;
              status = primary_status;
            end
            else begin
              result.rollback_statuses.push_back(
                rdma_cmq_clone_status_value(cleanup_status)
              );
              retain_mr_destroy_error(
                mr_snapshot, primary_status, result,
                RDMA_HW_PRESENCE_PRESENT, 1'b1,
                RDMA_CTRL_STEP_HW_OCC_FLUSHED, null, result_finalized
              );
            end
          end
          break;
        end
        result.completed_steps.push_back(RDMA_CTRL_STEP_HW_OCC_FLUSHED);
        status = generation_fence(binding, locked_owner);
        status = checked_status(
          status, "post-OCC_FLUSH generation fence returned null"
        );
        if (!status.ok()) begin
          primary_status = rdma_cmq_clone_status_value(status);
          retain_mr_destroy_error(
            mr_snapshot, primary_status, result,
            RDMA_HW_PRESENCE_PRESENT, 1'b1,
            RDMA_CTRL_STEP_HW_MR_DEREGISTERED, null, result_finalized
          );
          break;
        end
      end

      deregister_body = rdma_xtr_v1_mr_deregister_body::type_id::create(
        "deregister_mr_body"
      );
      deregister_body.mr_h = project_handle(
        mr_snapshot.handle, mr_snapshot.local_mr_id, RDMA_RESOURCE_MR
      );
      deregister_body.stag_key = mr_snapshot.lkey[7:0];
      deregister_body.next_state = RDMA_CONTEXT_INVALID;
      opcode_key = rdma_cmq_opcode_key::type_id::create(
        "deregister_mr_opcode"
      );
      opcode_key.profile_name = "xtr_v1";
      opcode_key.opcode = XTR_V1_OP_MR_DEREGISTER;
      opcode_key.variant = "deregister";
      command = rdma_cmq_command_desc::type_id::create(
        "deregister_mr_command"
      );
      command.function_h = rdma_clone_function_handle_value(
        locked_owner, "deregister MR command"
      );
      command.opcode_key = opcode_key;
      command.body = deregister_body;
      command.timeout = default_timeout;
      ticket = null;
      completion = null;
      cmq.execute(command, ticket, completion, status);
      status = checked_status(
        status, "MR_DEREGISTER execution returned null"
      );
      if (!status.ok()) begin
        primary_status = rdma_cmq_clone_status_value(status);
        if (status.code == RDMA_SC_TIMEOUT) begin
          retain_mr_destroy_error(
            mr_snapshot, primary_status, result,
            RDMA_HW_PRESENCE_UNKNOWN, 1'b1,
            RDMA_CTRL_STEP_HW_MR_DEREGISTERED, ticket, result_finalized
          );
        end
        else begin
          cleanup_status = manager.restore_active(mr_snapshot.handle);
          cleanup_status = checked_status(
            cleanup_status,
            "MR_DEREGISTER failure restore ACTIVE returned null"
          );
          if (cleanup_status.ok()) begin
            result.final_resource_state = RDMA_RESOURCE_ACTIVE;
            status = primary_status;
          end
          else begin
            result.rollback_statuses.push_back(
              rdma_cmq_clone_status_value(cleanup_status)
            );
            retain_mr_destroy_error(
              mr_snapshot, primary_status, result,
              RDMA_HW_PRESENCE_PRESENT, 1'b1,
              RDMA_CTRL_STEP_HW_MR_DEREGISTERED, null,
              result_finalized
            );
          end
        end
        break;
      end
      result.completed_steps.push_back(
        RDMA_CTRL_STEP_HW_MR_DEREGISTERED
      );
      status = generation_fence(binding, locked_owner);
      status = checked_status(
        status, "post-MR_DEREGISTER generation fence returned null"
      );
      if (!status.ok()) begin
        primary_status = rdma_cmq_clone_status_value(status);
        retain_mr_destroy_error(
          mr_snapshot, primary_status, result, RDMA_HW_PRESENCE_ABSENT,
          1'b1, RDMA_CTRL_STEP_HW_DRAINED, null, result_finalized
        );
        break;
      end

      drain_body = rdma_xtr_v1_cmq_empty_body::type_id::create(
        "deregister_mr_tq_flush_body"
      );
      opcode_key = rdma_cmq_opcode_key::type_id::create(
        "deregister_mr_tq_flush_opcode"
      );
      opcode_key.profile_name = "xtr_v1";
      opcode_key.opcode = XTR_V1_OP_TQ_FLUSH;
      opcode_key.variant = "tq_flush";
      command = rdma_cmq_command_desc::type_id::create(
        "deregister_mr_tq_flush"
      );
      command.function_h = rdma_clone_function_handle_value(
        locked_owner, "deregister MR TQ command"
      );
      command.opcode_key = opcode_key;
      command.body = drain_body;
      command.timeout = default_timeout;
      ticket = null;
      completion = null;
      cmq.execute(command, ticket, completion, status);
      status = checked_status(status, "TQ_FLUSH execution returned null");
      if (!status.ok()) begin
        primary_status = rdma_cmq_clone_status_value(status);
        retain_mr_destroy_error(
          mr_snapshot, primary_status, result, RDMA_HW_PRESENCE_ABSENT,
          1'b1, RDMA_CTRL_STEP_HW_DRAINED,
          (status.code == RDMA_SC_TIMEOUT) ? ticket : null,
          result_finalized
        );
        break;
      end
      result.completed_steps.push_back(RDMA_CTRL_STEP_HW_DRAINED);
      status = generation_fence(binding, locked_owner);
      status = checked_status(
        status, "post-TQ_FLUSH generation fence returned null"
      );
      if (!status.ok()) begin
        primary_status = rdma_cmq_clone_status_value(status);
        retain_mr_destroy_error(
          mr_snapshot, primary_status, result, RDMA_HW_PRESENCE_ABSENT,
          1'b1, RDMA_CTRL_STEP_BACKING_RELEASED, null, result_finalized
        );
        break;
      end

      for (int i = int'(mr_snapshot.hmc_refs.size()) - 1;
           i >= 0; i--) begin
        if (mr_snapshot.hmc_refs[i] == null) begin
          status = invalid_state("deregister MR HMC reference is null");
          break;
        end
        if (mr_snapshot.hmc_refs[i].ownership !=
              RDMA_OWNERSHIP_CONTROL_PLANE ||
            mr_snapshot.hmc_refs[i].release_complete)
          continue;
        if (hmc_allocator == null)
          status = invalid_state(
            "owned deregister MR HMC allocator is unavailable"
          );
        else
          status = hmc_allocator.\release (
            mr_snapshot.hmc_refs[i].owner,
            mr_snapshot.hmc_refs[i].object_kind,
            mr_snapshot.hmc_refs[i].address
          );
        status = checked_status(
          status, "owned deregister MR HMC release returned null"
        );
        if (!status.ok())
          break;
        mr_snapshot.hmc_refs[i].release_complete = 1'b1;
      end
      if (!status.ok()) begin
        primary_status = rdma_cmq_clone_status_value(status);
        retain_mr_destroy_error(
          mr_snapshot, primary_status, result, RDMA_HW_PRESENCE_ABSENT,
          1'b1, RDMA_CTRL_STEP_BACKING_RELEASED, null,
          result_finalized
        );
        break;
      end

      for (int i = int'(mr_snapshot.backing_refs.size()) - 1;
           i >= 0; i--) begin
        if (mr_snapshot.backing_refs[i] == null ||
            mr_snapshot.backing_refs[i].mapping == null) begin
          status = invalid_state(
            "deregister MR backing reference is null"
          );
          break;
        end
        if (mr_snapshot.backing_refs[i].ownership !=
              RDMA_OWNERSHIP_CONTROL_PLANE ||
            mr_snapshot.backing_refs[i].release_complete)
          continue;
        if (host_mem == null)
          status = invalid_state(
            "owned deregister MR host memory is unavailable"
          );
        else
          status = host_mem.\release (
            mr_snapshot.backing_refs[i].mapping
          );
        status = checked_status(
          status, "owned deregister MR backing release returned null"
        );
        if (!status.ok())
          break;
        mr_snapshot.backing_refs[i].release_complete = 1'b1;
      end
      if (!status.ok()) begin
        primary_status = rdma_cmq_clone_status_value(status);
        retain_mr_destroy_error(
          mr_snapshot, primary_status, result, RDMA_HW_PRESENCE_ABSENT,
          1'b1, RDMA_CTRL_STEP_BACKING_RELEASED, null,
          result_finalized
        );
        break;
      end
      result.completed_steps.push_back(RDMA_CTRL_STEP_BACKING_RELEASED);

      status = generation_fence(binding, locked_owner);
      status = checked_status(
        status, "pre-finalize MR generation fence returned null"
      );
      if (!status.ok()) begin
        primary_status = rdma_cmq_clone_status_value(status);
        retain_mr_destroy_error(
          mr_snapshot, primary_status, result, RDMA_HW_PRESENCE_ABSENT,
          1'b1, RDMA_CTRL_STEP_RESOURCE_RELEASED, null, result_finalized
        );
        break;
      end

      status = manager.finalize_release(mr_snapshot.handle);
      status = checked_status(
        status, "resource manager MR release returned null"
      );
      if (!status.ok()) begin
        primary_status = rdma_cmq_clone_status_value(status);
        retain_mr_destroy_error(
          mr_snapshot, primary_status, result, RDMA_HW_PRESENCE_ABSENT,
          1'b1, RDMA_CTRL_STEP_RESOURCE_RELEASED, null,
          result_finalized
        );
        break;
      end
      result.completed_steps.push_back(RDMA_CTRL_STEP_RESOURCE_RELEASED);
      result.final_resource_state = RDMA_RESOURCE_RELEASED;
      result.final_resource_state_known = 1'b1;
      status = rdma_status::success();
    end while (1'b0);

    if (!result_finalized)
      finish_result(result, status);
    if (function_lock != null)
      function_lock.put(1);
  endtask

  protected task register_mr_internal(
    rdma_function_binding binding,
    rdma_register_mr_req request,
    rdma_mr_backing_desc backing,
    rdma_resource_ownership_e required_ownership,
    longint unsigned supplied_transaction_id,
    semaphore supplied_function_lock,
    output rdma_mr mr,
    output rdma_control_result result
  );
    rdma_function_handle owner;
    rdma_function_handle locked_owner;
    rdma_function_handle live_owner;
    rdma_register_mr_req frozen_request;
    rdma_mr_backing_desc frozen_backing;
    rdma_resource pd_resource;
    rdma_pd pd_snapshot;
    rdma_mr reserved_mr;
    rdma_resource active_resource;
    rdma_mrt_model mrt;
    rdma_cmq_command_desc command;
    rdma_cmq_opcode_key opcode_key;
    rdma_cmq_ticket ticket;
    rdma_cmq_completion completion;
    rdma_recovery_record recovery;
    rdma_status status;
    uvm_object cloned_object;
    semaphore function_lock;
    longint unsigned transaction_id;
    longint unsigned live_lease_size;
    bit [7:0] stag_key;
    bit has_remote_access;
    bit result_finalized;
    bit function_lock_acquired_here;

    mr = null;
    result = make_result();
    function_lock = supplied_function_lock;
    result_finalized = 1'b0;
    function_lock_acquired_here = 1'b0;
    transaction_id = supplied_transaction_id;
    if (transaction_id == 0)
      reserve_transaction_id(transaction_id, status);
    else
      status = rdma_status::success();
    result.transaction_id = transaction_id;

    do begin
      if (status == null || !status.ok()) begin
        status = checked_status(
          status, "transaction ID allocation returned null status"
        );
        break;
      end
      status = configured_status();
      if (status == null || !status.ok()) begin
        status = checked_status(
          status, "control-plane configuration check returned null"
        );
        break;
      end
      status = binding_owner_status(binding, owner);
      if (status == null || !status.ok()) begin
        status = checked_status(status,
                                "Function binding check returned null");
        break;
      end
      status = generation_fence(binding, owner);
      if (status == null || !status.ok()) begin
        status = checked_status(
          status, "initial register MR generation fence returned null"
        );
        break;
      end
      status = register_mr_request_status(request, owner);
      if (status == null || !status.ok()) begin
        status = checked_status(
          status, "register MR request check returned null"
        );
        break;
      end
      status = validate_backing(binding, request, backing, owner,
                                required_ownership);
      if (status == null || !status.ok()) begin
        status = checked_status(
          status, "register MR backing check returned null"
        );
        break;
      end

      if (function_lock == null) begin
        acquire_function_lock(owner, function_lock);
        function_lock_acquired_here = 1'b1;
      end
      status = binding_owner_status(binding, locked_owner);
      if (status == null || !status.ok()) begin
        status = checked_status(
          status, "post-lock Function binding check returned null"
        );
        break;
      end
      status = generation_fence(binding, owner);
      if (status == null || !status.ok()) begin
        status = checked_status(
          status, "post-lock register MR generation fence returned null"
        );
        break;
      end
      status = register_mr_request_status(request, locked_owner);
      if (status == null || !status.ok()) begin
        status = checked_status(
          status, "post-lock register MR request check returned null"
        );
        break;
      end
      status = validate_backing(binding, request, backing, locked_owner,
                                required_ownership);
      if (status == null || !status.ok()) begin
        status = checked_status(
          status, "post-lock register MR backing check returned null"
        );
        break;
      end

      cloned_object = request.clone();
      if (cloned_object == null ||
          !$cast(frozen_request, cloned_object) ||
          frozen_request == request ||
          frozen_request.owner == request.owner ||
          frozen_request.pd_h == request.pd_h) begin
        status = invalid_state(
          "register MR request snapshot is not deeply detached"
        );
        break;
      end
      cloned_object = backing.clone();
      if (cloned_object == null ||
          !$cast(frozen_backing, cloned_object) ||
          frozen_backing == backing ||
          frozen_backing.function_h == backing.function_h ||
          frozen_backing.page_layout == backing.page_layout ||
          frozen_backing.backing_refs.size() != backing.backing_refs.size() ||
          frozen_backing.hmc_refs.size() != backing.hmc_refs.size()) begin
        status = invalid_state(
          "register MR backing snapshot is not deeply detached"
        );
        break;
      end
      foreach (frozen_backing.backing_refs[i]) begin
        if (frozen_backing.backing_refs[i] == null ||
            backing.backing_refs[i] == null ||
            frozen_backing.backing_refs[i] == backing.backing_refs[i] ||
            frozen_backing.backing_refs[i].mapping == null ||
            backing.backing_refs[i].mapping == null ||
            frozen_backing.backing_refs[i].mapping ==
              backing.backing_refs[i].mapping ||
            frozen_backing.backing_refs[i].mapping.function_h ==
              backing.backing_refs[i].mapping.function_h ||
            (backing.backing_refs[i].mapping.owner_h == null &&
             frozen_backing.backing_refs[i].mapping.owner_h != null) ||
            (backing.backing_refs[i].mapping.owner_h != null &&
             (frozen_backing.backing_refs[i].mapping.owner_h == null ||
              frozen_backing.backing_refs[i].mapping.owner_h ==
                backing.backing_refs[i].mapping.owner_h))) begin
          status = invalid_state(
            "register MR backing reference snapshot is not deeply detached"
          );
          break;
        end
      end
      if (status == null || !status.ok())
        break;
      foreach (frozen_backing.hmc_refs[i]) begin
        if (frozen_backing.hmc_refs[i] == null ||
            backing.hmc_refs[i] == null ||
            frozen_backing.hmc_refs[i] == backing.hmc_refs[i] ||
            frozen_backing.hmc_refs[i].owner == backing.hmc_refs[i].owner) begin
          status = invalid_state(
            "register MR HMC reference snapshot is not deeply detached"
          );
          break;
        end
      end
      if (status == null || !status.ok())
        break;
      status = register_mr_request_status(frozen_request, locked_owner);
      if (status == null || !status.ok()) begin
        status = checked_status(
          status, "register MR request snapshot check returned null"
        );
        break;
      end
      status = validate_backing(binding, frozen_request, frozen_backing,
                                locked_owner, required_ownership);
      if (status == null || !status.ok()) begin
        status = checked_status(
          status, "register MR backing snapshot check returned null"
        );
        break;
      end

      status = manager.lookup(frozen_request.pd_h, pd_resource);
      if (status == null || !status.ok()) begin
        status = checked_status(status,
                                "resource manager PD lookup returned null");
        break;
      end
      if (!$cast(pd_snapshot, pd_resource) || pd_snapshot == null ||
          pd_snapshot.handle == null || pd_snapshot.owner == null ||
          pd_snapshot.state != RDMA_RESOURCE_ACTIVE) begin
        status = invalid_state("register MR requires an ACTIVE PD");
        break;
      end
      status = same_owner_status(pd_snapshot.owner, locked_owner,
                                 "register MR PD");
      if (status == null || !status.ok()) begin
        status = checked_status(status,
                                "register MR PD owner check returned null");
        break;
      end

      status = manager.create_mr(binding, frozen_request.pd_h, reserved_mr);
      if (status == null || !status.ok()) begin
        status = checked_status(status,
                                "resource manager create MR returned null");
        break;
      end
      if (reserved_mr == null || reserved_mr.handle == null ||
          reserved_mr.state != RDMA_RESOURCE_ALLOCATED) begin
        status = invalid_state(
          "resource manager returned an invalid MR reservation"
        );
        break;
      end
      result.resource_h = snapshot_handle(reserved_mr.handle);
      result.final_resource_state = RDMA_RESOURCE_ALLOCATED;
      result.final_resource_state_known = 1'b1;
      result.completed_steps.push_back(RDMA_CTRL_STEP_RESOURCE_RESERVED);

      reserved_mr.iova = frozen_request.iova;
      reserved_mr.length = frozen_request.length;
      reserved_mr.access = frozen_request.access;
      reserved_mr.mr_serial = reserved_mr.handle.object_id[11:0];
      reserved_mr.backing_refs = frozen_backing.backing_refs;
      reserved_mr.hmc_refs = frozen_backing.hmc_refs;
      result.completed_steps.push_back(RDMA_CTRL_STEP_BACKING_ATTACHED);
      if (reserved_mr.hmc_refs.size() != 0)
        result.completed_steps.push_back(RDMA_CTRL_STEP_HMC_ATTACHED);
      status = key_policy.derive(reserved_mr, stag_key);
      if (status == null || !status.ok()) begin
        status = checked_status(status,
                                "STAG key policy returned null status");
        rollback_mr_creation(reserved_mr, locked_owner, status, result,
                             1'b0, 1'b0, mr, result_finalized);
        break;
      end
      reserved_mr.lkey = {reserved_mr.local_mr_id[23:0], stag_key};
      has_remote_access = frozen_request.access.remote_read ||
                          frozen_request.access.remote_write ||
                          frozen_request.access.remote_atomic;
      reserved_mr.rkey = has_remote_access ? reserved_mr.lkey : 32'b0;
      status = manager.stage_allocated(reserved_mr);
      if (status == null || !status.ok()) begin
        status = checked_status(status,
                                "resource manager stage MR returned null");
        rollback_mr_creation(reserved_mr, locked_owner, status, result,
                             1'b0, 1'b0, mr, result_finalized);
        break;
      end

      mrt = rdma_mrt_model::type_id::create("register_mr_mrt");
      mrt.mr_h = project_handle(reserved_mr.handle,
                                reserved_mr.local_mr_id,
                                RDMA_RESOURCE_MR);
      mrt.pd_h = project_handle(pd_snapshot.handle,
                                pd_snapshot.local_pd_id,
                                RDMA_RESOURCE_PD);
      mrt.state = RDMA_CONTEXT_VALID;
      mrt.iova = reserved_mr.iova;
      mrt.length = reserved_mr.length;
      mrt.lkey = reserved_mr.lkey;
      mrt.rkey = reserved_mr.rkey;
      mrt.access = reserved_mr.access;
      mrt.object_type = 2'b0;
      mrt.page_layout = rdma_clone_mr_page_layout_value(
        frozen_backing.page_layout, "register MR"
      );
      if (mrt.page_layout != null)
        mrt.page_layout.mr_serial = reserved_mr.mr_serial;

      command = rdma_cmq_command_desc::type_id::create(
        "register_mr_key_alloc"
      );
      command.function_h = rdma_clone_function_handle_value(
        locked_owner, "register MR command"
      );
      opcode_key = rdma_cmq_opcode_key::type_id::create(
        "register_mr_key_alloc_opcode"
      );
      opcode_key.profile_name = "xtr_v1";
      opcode_key.opcode = XTR_V1_OP_KEY_ALLOC;
      opcode_key.variant = "key_alloc";
      command.opcode_key = opcode_key;
      command.body = mrt;
      command.timeout = default_timeout;

      cmq.execute(command, ticket, completion, status);
      if (status == null || !status.ok()) begin
        status = checked_status(status,
                                "KEY_ALLOC execution returned null status");
        if (status.code == RDMA_SC_TIMEOUT) begin
          recovery = rdma_recovery_record::type_id::create(
            "register_mr_timeout_recovery"
          );
          recovery.resource_h = snapshot_handle(reserved_mr.handle);
          recovery.hardware_presence = RDMA_HW_PRESENCE_UNKNOWN;
          recovery.completed_steps = result.completed_steps;
          recovery.pending_steps.push_back(
            RDMA_CTRL_STEP_HW_KEY_ALLOCATED
          );
          recovery.backing_refs = reserved_mr.backing_refs;
          recovery.hmc_refs = reserved_mr.hmc_refs;
          recovery.ambiguous_ticket = rdma_cmq_clone_ticket_value(
            ticket, "register MR timeout recovery"
          );
          recovery.primary_status = rdma_cmq_clone_status_value(status);
          finalize_mr_recovery(reserved_mr, recovery, status, result, mr,
                               result_finalized);
          break;
        end
        rollback_mr_creation(reserved_mr, locked_owner, status, result,
                             1'b0, 1'b0, mr, result_finalized);
        break;
      end
      result.completed_steps.push_back(RDMA_CTRL_STEP_HW_KEY_ALLOCATED);

      status = binding_owner_status(binding, live_owner);
      if (status == null || !status.ok()) begin
        status = checked_status(
          status, "post-KEY_ALLOC Function binding check returned null"
        );
      end
      else begin
        status = generation_fence(binding, locked_owner);
        status = checked_status(
          status, "post-KEY_ALLOC generation fence returned null"
        );
      end
      if (status.ok()) begin
        foreach (frozen_backing.hmc_refs[i]) begin
          status = hmc_allocator.lookup(
            locked_owner, frozen_backing.hmc_refs[i].object_kind,
            frozen_backing.hmc_refs[i].address, live_lease_size
          );
          status = checked_status(
            status, "post-KEY_ALLOC HMC lookup returned null"
          );
          if (!status.ok())
            break;
          if (live_lease_size != frozen_backing.hmc_refs[i].size) begin
            status = invalid_argument(
              "post-KEY_ALLOC HMC lease size does not match"
            );
            break;
          end
        end
      end
      if (!status.ok()) begin
        recovery = rdma_recovery_record::type_id::create(
          "register_mr_post_cmq_recovery"
        );
        recovery.resource_h = snapshot_handle(reserved_mr.handle);
        recovery.hardware_presence = RDMA_HW_PRESENCE_PRESENT;
        recovery.completed_steps = result.completed_steps;
        recovery.pending_steps.push_back(
          RDMA_CTRL_STEP_HW_MR_DEREGISTERED
        );
        recovery.backing_refs = reserved_mr.backing_refs;
        recovery.hmc_refs = reserved_mr.hmc_refs;
        recovery.primary_status = rdma_cmq_clone_status_value(status);
        finalize_mr_recovery(reserved_mr, recovery, status, result, mr,
                             result_finalized);
        break;
      end

      status = manager.commit_programmed(reserved_mr);
      if (status == null || !status.ok()) begin
        status = checked_status(
          status, "resource manager MR commit returned null"
        );
        rollback_mr_creation(reserved_mr, locked_owner, status, result,
                             1'b1, 1'b0, mr, result_finalized);
        break;
      end
      result.final_resource_state = RDMA_RESOURCE_PROGRAMMED;
      result.completed_steps.push_back(RDMA_CTRL_STEP_REGISTRY_PROGRAMMED);

      status = generation_fence(binding, locked_owner);
      status = checked_status(
        status, "pre-activate MR generation fence returned null"
      );
      if (!status.ok()) begin
        rollback_mr_creation(reserved_mr, locked_owner, status, result,
                             1'b1, 1'b1, mr, result_finalized);
        break;
      end

      status = manager.activate(reserved_mr.handle);
      if (status == null || !status.ok()) begin
        status = checked_status(status,
                                "resource manager MR activate returned null");
        rollback_mr_creation(reserved_mr, locked_owner, status, result,
                             1'b1, 1'b1, mr, result_finalized);
        break;
      end
      result.final_resource_state = RDMA_RESOURCE_ACTIVE;
      result.completed_steps.push_back(RDMA_CTRL_STEP_REGISTRY_ACTIVE);

      status = manager.lookup(reserved_mr.handle, active_resource);
      if (status == null || !status.ok()) begin
        status = checked_status(
          status, "resource manager active MR lookup returned null"
        );
        break;
      end
      if (!$cast(mr, active_resource) || mr == null || mr.handle == null ||
          mr.state != RDMA_RESOURCE_ACTIVE) begin
        mr = null;
        status = invalid_state(
          "resource manager active MR snapshot is invalid"
        );
        break;
      end
      result.resource_h = snapshot_handle(mr.handle);
      status = rdma_status::success();
    end while (1'b0);

    if (!result_finalized)
      finish_result(result, status);
    if (function_lock_acquired_here && function_lock != null)
      function_lock.put(1);
  endtask

  task register_mr(
    rdma_function_binding binding,
    rdma_register_mr_req request,
    rdma_mr_backing_desc backing,
    output rdma_mr mr,
    output rdma_control_result result
  );
    register_mr_internal(binding, request, backing,
                         RDMA_OWNERSHIP_BORROWED, 0, null, mr, result);
  endtask

  task alloc_and_register_mr(
    rdma_function_binding binding,
    rdma_register_mr_req request,
    rdma_dma_request_context dma_context,
    int unsigned alignment,
    output rdma_dma_mapping mapping,
    output rdma_mr mr,
    output rdma_control_result result
  );
    rdma_function_handle owner;
    rdma_function_handle locked_owner;
    rdma_register_mr_req frozen_request;
    rdma_dma_request_context frozen_context;
    rdma_dma_mapping allocated_mapping;
    rdma_mr_backing_desc backing;
    rdma_backing_ref backing_ref;
    rdma_status status;
    rdma_status release_status;
    uvm_object cloned_object;
    semaphore function_lock;
    longint unsigned transaction_id;
    bit ownership_transferred;
    bit registration_started;

    mapping = null;
    mr = null;
    result = make_result();
    allocated_mapping = null;
    function_lock = null;
    ownership_transferred = 1'b0;
    registration_started = 1'b0;
    reserve_transaction_id(transaction_id, status);
    result.transaction_id = transaction_id;

    do begin
      if (status == null || !status.ok()) begin
        status = checked_status(
          status, "transaction ID allocation returned null status"
        );
        break;
      end
      status = configured_status();
      if (status == null || !status.ok()) begin
        status = checked_status(
          status, "control-plane configuration check returned null"
        );
        break;
      end
      status = binding_owner_status(binding, owner);
      if (status == null || !status.ok()) begin
        status = checked_status(status,
                                "Function binding check returned null");
        break;
      end
      status = register_mr_request_status(request, owner);
      if (status == null || !status.ok()) begin
        status = checked_status(
          status, "owned register MR request check returned null"
        );
        break;
      end
      if (alignment < 4096 ||
          (alignment & (alignment - 1'b1)) != 0) begin
        status = invalid_argument(
          "owned MR alignment must be a power of two of at least 4096"
        );
        break;
      end
      if (request.length > 64'h0000_0000_ffff_ffff) begin
        status = invalid_argument(
          "owned MR length exceeds host allocation size"
        );
        break;
      end
      if (request.access.remote_atomic) begin
        status = rdma_status::make(
          RDMA_SC_UNSUPPORTED_OPCODE,
          "owned MR helper cannot allocate atomic DMA authority"
        );
        break;
      end
      if (dma_context == null) begin
        status = invalid_argument("owned MR DMA request context is null");
        break;
      end
      status = dma_context.validate();
      if (status == null || !status.ok()) begin
        status = checked_status(
          status, "owned MR DMA context validation returned null"
        );
        break;
      end
      status = same_owner_status(dma_context.function_h, owner,
                                 "owned MR DMA context");
      if (status == null || !status.ok()) begin
        status = checked_status(
          status, "owned MR DMA Function check returned null"
        );
        break;
      end
      if (dma_context.requester_bdf != binding.queue_dma.requester_bdf ||
          dma_context.pasid_valid != binding.queue_dma.pasid_valid ||
          dma_context.pasid != binding.queue_dma.pasid ||
          dma_context.dma_domain_valid !=
            binding.queue_dma.dma_domain_valid ||
          dma_context.dma_domain_id != binding.queue_dma.dma_domain_id) begin
        status = rdma_status::make(
          RDMA_SC_DMA_TRANSLATION,
          "owned MR DMA authority does not match Function"
        );
        break;
      end
      if (dma_context.owner_h != null) begin
        status = invalid_argument(
          "owned MR DMA request owner must be null"
        );
        break;
      end
      if (host_mem == null) begin
        status = invalid_state(
          "owned MR host memory adapter is unavailable"
        );
        break;
      end

      acquire_function_lock(owner, function_lock);
      status = binding_owner_status(binding, locked_owner);
      if (status == null || !status.ok()) begin
        status = checked_status(
          status, "post-lock owned MR Function binding check returned null"
        );
        break;
      end
      status = same_owner_status(
        locked_owner, owner, "post-lock owned MR Function binding"
      );
      if (status == null || !status.ok()) begin
        status = checked_status(
          status, "post-lock owned MR Function identity check returned null"
        );
        break;
      end
      status = register_mr_request_status(request, locked_owner);
      if (status == null || !status.ok()) begin
        status = checked_status(
          status, "post-lock owned register MR request check returned null"
        );
        break;
      end
      if (request.length > 64'h0000_0000_ffff_ffff) begin
        status = invalid_argument(
          "owned MR length exceeds host allocation size"
        );
        break;
      end
      if (request.access.remote_atomic) begin
        status = rdma_status::make(
          RDMA_SC_UNSUPPORTED_OPCODE,
          "owned MR helper cannot allocate atomic DMA authority"
        );
        break;
      end
      status = dma_context.validate();
      if (status == null || !status.ok()) begin
        status = checked_status(
          status, "post-lock owned MR DMA context validation returned null"
        );
        break;
      end
      status = same_owner_status(
        dma_context.function_h, locked_owner,
        "post-lock owned MR DMA context"
      );
      if (status == null || !status.ok()) begin
        status = checked_status(
          status, "post-lock owned MR DMA Function check returned null"
        );
        break;
      end
      if (dma_context.requester_bdf != binding.queue_dma.requester_bdf ||
          dma_context.pasid_valid != binding.queue_dma.pasid_valid ||
          dma_context.pasid != binding.queue_dma.pasid ||
          dma_context.dma_domain_valid !=
            binding.queue_dma.dma_domain_valid ||
          dma_context.dma_domain_id != binding.queue_dma.dma_domain_id) begin
        status = rdma_status::make(
          RDMA_SC_DMA_TRANSLATION,
          "owned MR DMA authority does not match Function"
        );
        break;
      end
      if (dma_context.owner_h != null) begin
        status = invalid_argument(
          "owned MR DMA request owner must be null"
        );
        break;
      end

      cloned_object = request.clone();
      if (cloned_object == null ||
          !$cast(frozen_request, cloned_object) ||
          frozen_request == request ||
          frozen_request.owner == request.owner ||
          frozen_request.pd_h == request.pd_h) begin
        status = invalid_state(
          "owned MR request snapshot is not deeply detached"
        );
        break;
      end
      cloned_object = dma_context.clone();
      if (cloned_object == null ||
          !$cast(frozen_context, cloned_object) ||
          frozen_context == dma_context ||
          frozen_context.function_h == dma_context.function_h ||
          (dma_context.owner_h == null && frozen_context.owner_h != null) ||
          (dma_context.owner_h != null &&
           (frozen_context.owner_h == null ||
            frozen_context.owner_h == dma_context.owner_h))) begin
        status = invalid_state(
          "owned MR DMA context snapshot is not deeply detached"
        );
        break;
      end
      status = register_mr_request_status(frozen_request, locked_owner);
      if (status == null || !status.ok()) begin
        status = checked_status(
          status, "owned MR request snapshot check returned null"
        );
        break;
      end
      if (frozen_request.length > 64'h0000_0000_ffff_ffff) begin
        status = invalid_argument(
          "owned MR snapshot length exceeds host allocation size"
        );
        break;
      end
      if (frozen_request.access.remote_atomic) begin
        status = rdma_status::make(
          RDMA_SC_UNSUPPORTED_OPCODE,
          "owned MR snapshot cannot request atomic DMA authority"
        );
        break;
      end
      status = frozen_context.validate();
      if (status == null || !status.ok()) begin
        status = checked_status(
          status, "owned MR DMA context snapshot validation returned null"
        );
        break;
      end
      status = same_owner_status(
        frozen_context.function_h, locked_owner,
        "owned MR DMA context snapshot"
      );
      if (status == null || !status.ok()) begin
        status = checked_status(
          status, "owned MR DMA context snapshot Function check returned null"
        );
        break;
      end
      if (frozen_context.requester_bdf !=
            binding.queue_dma.requester_bdf ||
          frozen_context.pasid_valid != binding.queue_dma.pasid_valid ||
          frozen_context.pasid != binding.queue_dma.pasid ||
          frozen_context.dma_domain_valid !=
            binding.queue_dma.dma_domain_valid ||
          frozen_context.dma_domain_id != binding.queue_dma.dma_domain_id ||
          frozen_context.owner_h != null) begin
        status = invalid_argument(
          "owned MR DMA context snapshot authority is invalid"
        );
        break;
      end
      // Preserve the caller-selected MR IOVA.  The allocation contract cannot
      // request one, so inner backing validation must prove that the returned
      // mapping covers request.iova rather than silently rewriting it.
      status = host_mem.allocate(
        frozen_context, frozen_request.length, alignment,
        required_dma_direction(frozen_request.access), allocated_mapping
      );
      status = checked_status(
        status, "owned MR host memory allocation returned null"
      );
      if (!status.ok())
        break;
      if (allocated_mapping == null ||
          allocated_mapping.state != RDMA_MAPPING_ACTIVE ||
          allocated_mapping.owner_h != null) begin
        status = invalid_state(
          "owned MR host memory allocation is invalid"
        );
        break;
      end

      backing = rdma_mr_backing_desc::type_id::create(
        "allocated_mr_backing"
      );
      backing.function_h = rdma_clone_function_handle_value(
        frozen_context.function_h, "allocated MR backing"
      );
      backing.requester_bdf = frozen_context.requester_bdf;
      backing.pasid_valid = frozen_context.pasid_valid;
      backing.pasid = frozen_context.pasid;
      backing_ref = rdma_backing_ref::type_id::create(
        "allocated_mr_backing_ref"
      );
      backing_ref.mapping = allocated_mapping;
      backing_ref.ownership = RDMA_OWNERSHIP_CONTROL_PLANE;
      backing_ref.release_complete = 1'b0;
      backing.backing_refs.push_back(backing_ref);
      backing.page_layout.pbl_mode = RDMA_MR_PBL0;
      backing.page_layout.host_page_size = RDMA_MR_PAGE_4K;
      backing.page_layout.pba0 = allocated_mapping.backing_addr;
      backing.page_layout.pba1 = '0;
      backing.page_layout.first_pbl_index = 0;
      backing.page_layout.address_mode = RDMA_MR_ADDRESS_VA_BASED;
      backing.page_layout.odp = 1'b0;

      registration_started = 1'b1;
      register_mr_internal(
        binding, frozen_request, backing, RDMA_OWNERSHIP_CONTROL_PLANE,
        transaction_id, function_lock, mr, result
      );
      foreach (result.completed_steps[i])
        if (result.completed_steps[i] == RDMA_CTRL_STEP_BACKING_ATTACHED)
          ownership_transferred = 1'b1;
      if (result.ok())
        mapping = allocated_mapping;
    end while (1'b0);

    if (!registration_started)
      finish_result(result, status);
    if (allocated_mapping != null && !ownership_transferred) begin
      release_status = host_mem.\release (allocated_mapping);
      release_status = checked_status(
        release_status, "unattached owned MR release returned null"
      );
      if (!release_status.ok()) begin
        result.rollback_statuses.push_back(
          rdma_cmq_clone_status_value(release_status)
        );
        result.status = rdma_status::make(
          RDMA_SC_RECOVERY_REQUIRED,
          "unattached owned MR mapping requires caller recovery"
        );
        result.recovery_required = 1'b0;
        result.final_resource_state = RDMA_RESOURCE_NEW;
        result.final_resource_state_known = 1'b0;
        mapping = allocated_mapping;
      end
    end
    if (function_lock != null)
      function_lock.put(1);
  endtask

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

  protected function void remove_recovery_pending_step(
    rdma_recovery_record recovery,
    rdma_control_step_e step
  );
    if (recovery == null)
      return;
    foreach (recovery.pending_steps[i]) begin
      if (recovery.pending_steps[i] == step) begin
        recovery.pending_steps.delete(i);
        return;
      end
    end
  endfunction

  protected function void remove_recovery_completed_step(
    rdma_recovery_record recovery,
    rdma_control_step_e step
  );
    if (recovery == null)
      return;
    foreach (recovery.completed_steps[i]) begin
      if (recovery.completed_steps[i] == step) begin
        recovery.completed_steps.delete(i);
        return;
      end
    end
  endfunction

  protected function void queue_recovery_step(
    rdma_recovery_record recovery,
    rdma_control_step_e step
  );
    if (recovery == null || recovery_step_completed(recovery, step) ||
        recovery_step_pending(recovery, step))
      return;
    recovery.pending_steps.push_back(step);
  endfunction

  protected function void complete_recovery_step(
    rdma_recovery_record recovery,
    rdma_control_step_e step
  );
    if (recovery == null)
      return;
    remove_recovery_pending_step(recovery, step);
    if (!recovery_step_completed(recovery, step))
      recovery.completed_steps.push_back(step);
  endfunction

  protected function void project_recovery_result_history(
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

  protected function void publish_recovery_required(
    rdma_recovery_record recovery,
    rdma_control_result result,
    string message
  );
    project_recovery_result_history(recovery, result);
    result.status = rdma_status::make(RDMA_SC_RECOVERY_REQUIRED, message);
    result.final_resource_state = RDMA_RESOURCE_ERROR;
    result.final_resource_state_known = 1'b1;
    result.recovery_required = 1'b1;
  endfunction

  protected function rdma_status persist_recovery_record(
    rdma_handle resource_h,
    rdma_recovery_record recovery
  );
    rdma_status first_status;
    rdma_status retry_status;

    first_status = manager.mark_error(resource_h, recovery);
    first_status = checked_status(
      first_status, "recovery progress persistence returned null"
    );
    if (first_status.ok())
      return first_status;

    recovery.rollback_statuses.push_back(
      rdma_cmq_clone_status_value(first_status)
    );
    retry_status = manager.mark_error(resource_h, recovery);
    retry_status = checked_status(
      retry_status, "recovery progress retry returned null"
    );
    if (!retry_status.ok())
      recovery.rollback_statuses.push_back(
        rdma_cmq_clone_status_value(retry_status)
      );
    return first_status;
  endfunction

  protected function void retain_recovery_failure(
    rdma_handle resource_h,
    rdma_recovery_record recovery,
    rdma_status failure,
    rdma_control_result result,
    string message
  );
    rdma_status persist_status;

    recovery.rollback_statuses.push_back(
      checked_status(failure, "recovery failure status is null")
    );
    persist_status = persist_recovery_record(resource_h, recovery);
    if (!persist_status.ok() && recovery.rollback_statuses.size() == 0)
      recovery.rollback_statuses.push_back(
        rdma_cmq_clone_status_value(persist_status)
      );
    publish_recovery_required(recovery, result, message);
  endfunction

  protected function bit destroy_recovery_restore_ready(
    rdma_recovery_record recovery
  );
    if (recovery == null ||
        recovery.hardware_presence != RDMA_HW_PRESENCE_PRESENT ||
        recovery.ambiguous_ticket != null ||
        recovery.pending_steps.size() != 0)
      return 1'b0;
    return recovery.completed_steps.size() == 0 ||
           (recovery.completed_steps.size() == 1 &&
            recovery.completed_steps[0] == RDMA_CTRL_STEP_HW_OCC_FLUSHED);
  endfunction

  protected function void restore_destroy_recovery(
    rdma_handle resource_h,
    rdma_recovery_record recovery,
    rdma_control_result result
  );
    rdma_status status;

    status = manager.restore_active(resource_h);
    status = checked_status(
      status, "destroy recovery restore ACTIVE returned null"
    );
    if (!status.ok()) begin
      retain_recovery_failure(
        resource_h, recovery, status, result,
        "destroy MR still requires ACTIVE restoration"
      );
      return;
    end
    project_recovery_result_history(recovery, result);
    result.status = rdma_status::success();
    result.final_resource_state = RDMA_RESOURCE_ACTIVE;
    result.final_resource_state_known = 1'b1;
    result.recovery_required = 1'b0;
  endfunction

  // Reserved-only ERROR MRs use the resource manager's atomic completion
  // transition.  In particular, do not publish a locally RELEASED mapping
  // before complete_reserved_error() succeeds: the adapter's opaque release
  // seal is the durable proof that makes a retry idempotent.
  protected function void recover_reserved_error(
    rdma_handle resource_h,
    rdma_recovery_record recovery,
    rdma_control_result result
  );
    rdma_recovery_record durable_recovery;
    rdma_status status;
    rdma_status lookup_status;
    rdma_status persist_status;
    bit backing_release_pending;
    bit release_complete;

    backing_release_pending = recovery.pending_steps[0] ==
      RDMA_CTRL_STEP_BACKING_RELEASED;
    status = rdma_status::success();
    if (backing_release_pending) begin
      if (host_mem == null)
        status = invalid_state(
          "reserved recovery host memory adapter is unavailable"
        );
      else begin
        foreach (recovery.backing_refs[i]) begin
          if (recovery.backing_refs[i] == null ||
              recovery.backing_refs[i].ownership !=
                RDMA_OWNERSHIP_CONTROL_PLANE ||
              recovery.backing_refs[i].mapping == null) begin
            status = invalid_state(
              "reserved recovery backing authority is incomplete"
            );
            break;
          end
          status = manager.query_owned_release_completion(
            recovery.backing_refs[i].mapping, release_complete
          );
          status = checked_status(
            status, "reserved recovery completion query returned null"
          );
          if (!status.ok())
            break;
          if (!release_complete) begin
            status = host_mem.\release (
              recovery.backing_refs[i].mapping
            );
            status = checked_status(
              status, "reserved recovery backing release returned null"
            );
            if (!status.ok())
              break;
            status = manager.query_owned_release_completion(
              recovery.backing_refs[i].mapping, release_complete
            );
            status = checked_status(
              status, "post-release completion query returned null"
            );
            if (!status.ok())
              break;
            if (!release_complete) begin
              status = invalid_state(
                "host memory release did not seal completion"
              );
              break;
            end
          end
        end
      end
    end

    if (status.ok()) begin
      status = manager.complete_reserved_error(resource_h);
      status = checked_status(
        status, "reserved ERROR completion returned null"
      );
    end
    if (!status.ok()) begin
      // A successful host release mutates only this working clone.  Refresh
      // the canonical record before appending the new failure so the retry
      // keeps the reserved-error schema and consumes the opaque release seal.
      durable_recovery = null;
      lookup_status = manager.lookup_recovery(
        resource_h, durable_recovery
      );
      lookup_status = checked_status(
        lookup_status, "reserved recovery refresh returned null"
      );
      if (!lookup_status.ok() || durable_recovery == null) begin
        recovery.rollback_statuses.push_back(
          rdma_cmq_clone_status_value(status)
        );
        if (!lookup_status.ok())
          recovery.rollback_statuses.push_back(
            rdma_cmq_clone_status_value(lookup_status)
          );
        publish_recovery_required(
          recovery, result, "reserved MR still requires recovery"
        );
        return;
      end
      durable_recovery.rollback_statuses.push_back(
        rdma_cmq_clone_status_value(status)
      );
      persist_status = persist_recovery_record(
        resource_h, durable_recovery
      );
      if (!persist_status.ok() &&
          durable_recovery.rollback_statuses.size() == 0)
        durable_recovery.rollback_statuses.push_back(
          rdma_cmq_clone_status_value(persist_status)
        );
      publish_recovery_required(
        durable_recovery, result, "reserved MR still requires recovery"
      );
      return;
    end

    if (backing_release_pending)
      complete_recovery_step(
        recovery, RDMA_CTRL_STEP_BACKING_RELEASED
      );
    complete_recovery_step(
      recovery, RDMA_CTRL_STEP_RESOURCE_RELEASED
    );
    project_recovery_result_history(recovery, result);
    result.status = rdma_status::success();
    result.final_resource_state = RDMA_RESOURCE_RELEASED;
    result.final_resource_state_known = 1'b1;
    result.recovery_required = 1'b0;
  endfunction

  protected task execute_recovery_hardware_step(
    rdma_mr error_mr,
    rdma_function_handle owner,
    rdma_control_step_e step,
    output rdma_cmq_ticket ticket,
    output rdma_cmq_completion completion,
    output rdma_status status
  );
    rdma_xtr_v1_occ_flush_body occ_body;
    rdma_xtr_v1_mr_deregister_body deregister_body;
    rdma_xtr_v1_cmq_empty_body drain_body;
    rdma_cmq_command_desc command;
    rdma_cmq_opcode_key opcode_key;

    ticket = null;
    completion = null;
    status = invalid_state("recovery hardware command was not executed");
    if (error_mr == null || owner == null) begin
      status = invalid_state("recovery hardware authority is incomplete");
      return;
    end

    opcode_key = rdma_cmq_opcode_key::type_id::create(
      "recovery_opcode"
    );
    opcode_key.profile_name = "xtr_v1";
    case (step)
      RDMA_CTRL_STEP_HW_OCC_FLUSHED: begin
        occ_body = rdma_xtr_v1_occ_flush_body::type_id::create(
          "recovery_occ_flush_body"
        );
        occ_body.mr_serial_flush = 1'b1;
        occ_body.pble = 1'b1;
        occ_body.mr_serial = error_mr.mr_serial[11:0];
        opcode_key.opcode = XTR_V1_OP_OCC_FLUSH;
        opcode_key.variant = "occ_flush";
      end
      RDMA_CTRL_STEP_HW_MR_DEREGISTERED: begin
        deregister_body = rdma_xtr_v1_mr_deregister_body::type_id::create(
          "recovery_mr_deregister_body"
        );
        deregister_body.mr_h = project_handle(
          error_mr.handle, error_mr.local_mr_id, RDMA_RESOURCE_MR
        );
        deregister_body.stag_key = error_mr.lkey[7:0];
        deregister_body.next_state = RDMA_CONTEXT_INVALID;
        opcode_key.opcode = XTR_V1_OP_MR_DEREGISTER;
        opcode_key.variant = "deregister";
      end
      RDMA_CTRL_STEP_HW_DRAINED: begin
        drain_body = rdma_xtr_v1_cmq_empty_body::type_id::create(
          "recovery_tq_flush_body"
        );
        opcode_key.opcode = XTR_V1_OP_TQ_FLUSH;
        opcode_key.variant = "tq_flush";
      end
      default: begin
        status = rdma_status::make(
          RDMA_SC_UNSUPPORTED_OPCODE,
          "recovery pending hardware step is unsupported"
        );
        return;
      end
    endcase

    command = rdma_cmq_command_desc::type_id::create(
      "recovery_hardware_command"
    );
    command.function_h = rdma_clone_function_handle_value(
      owner, "recovery hardware command"
    );
    command.opcode_key = opcode_key;
    case (step)
      RDMA_CTRL_STEP_HW_OCC_FLUSHED: command.body = occ_body;
      RDMA_CTRL_STEP_HW_MR_DEREGISTERED: command.body = deregister_body;
      RDMA_CTRL_STEP_HW_DRAINED: command.body = drain_body;
      default: command.body = null;
    endcase
    command.timeout = default_timeout;
    cmq.execute(command, ticket, completion, status);
    status = checked_status(status,
                            "recovery hardware execution returned null");
  endtask

  task recover_resource(
    rdma_function_binding binding,
    rdma_handle resource_h,
    output rdma_control_result result
  );
    rdma_function_handle owner;
    rdma_function_handle locked_owner;
    rdma_resource resource;
    rdma_mr error_mr;
    rdma_queue_resource error_queue;
    rdma_recovery_record recovery;
    rdma_cmq_ticket ticket;
    rdma_cmq_completion completion;
    rdma_status status;
    rdma_status completion_status;
    rdma_status persist_status;
    rdma_status reconcile_status;
    semaphore function_lock;
    longint unsigned transaction_id;
    longint unsigned lease_size;
    rdma_control_step_e pending_hardware_step;
    bit terminal_known;
    bit release_complete;
    bit creation_origin;
    bit has_hardware_pending;
    bit reserved_only;
    bit result_finalized;
    bit defer_terminal_retry;

    result = make_result();
    function_lock = null;
    result_finalized = 1'b0;
    reserve_transaction_id(transaction_id, status);
    result.transaction_id = transaction_id;
    result.resource_h = snapshot_handle(resource_h);

    do begin
      if (status == null || !status.ok()) begin
        status = checked_status(
          status, "recovery transaction ID allocation returned null"
        );
        break;
      end
      status = configured_status();
      if (status == null || !status.ok()) begin
        status = checked_status(
          status, "recovery configuration check returned null"
        );
        break;
      end
      status = binding_owner_status(binding, owner);
      if (status == null || !status.ok()) begin
        status = checked_status(status,
                                "recovery Function check returned null");
        break;
      end
      if (resource_h == null ||
          !(resource_h.kind inside {RDMA_RESOURCE_MR, RDMA_RESOURCE_QP,
                                    RDMA_RESOURCE_CQ, RDMA_RESOURCE_SRQ,
                                    RDMA_RESOURCE_CEQ, RDMA_RESOURCE_AEQ})) begin
        status = invalid_argument("recovery handle kind is unsupported");
        break;
      end
      status = queue_target_owner_status(resource_h, owner,
                                         "recovery target");
      if (status == null || !status.ok())
        break;

      acquire_function_lock(owner, function_lock);
      status = binding_owner_status(binding, locked_owner);
      if (status == null || !status.ok()) begin
        status = checked_status(
          status, "post-lock recovery Function check returned null"
        );
        break;
      end
      status = same_owner_status(locked_owner, owner,
                                 "post-lock recovery Function");
      if (status == null || !status.ok()) begin
        status = checked_status(
          status, "post-lock recovery Function identity returned null"
        );
        break;
      end
      status = manager.lookup(resource_h, resource);
      status = checked_status(status, "recovery lookup returned null");
      if (!status.ok())
        break;

      // QP recovery has its own lifecycle executor because QPC images,
      // query-buffer authority, and ordered backing cleanup differ from the
      // generic queue/MR recovery protocol.  Dispatch while the per-Function
      // lock is held, exactly like create/modify/destroy.
      if (resource_h.kind == RDMA_RESOURCE_QP) begin
        rdma_qp error_qp;
        if (qp_executor == null) begin
          status = invalid_state("QP lifecycle executor is unavailable");
          break;
        end
        if (!$cast(error_qp, resource) || error_qp == null ||
            error_qp.state != RDMA_RESOURCE_ERROR) begin
          status = invalid_state("QP recovery requires an ERROR QP");
          break;
        end
        status = same_owner_status(error_qp.owner, locked_owner,
                                   "recovery QP");
        if (status == null || !status.ok())
          break;
        qp_executor.recover_locked(binding, locked_owner, resource_h,
                                   transaction_id, result);
        if (result == null) begin
          result = make_result();
          result.transaction_id = transaction_id;
          status = invalid_state("QP recovery executor returned null result");
          break;
        end
        result_finalized = 1'b1;
        break;
      end

      // Queue recovery is policy-driven and lives in the queue executor.  Do
      // this dispatch while the same per-Function lock used by create/destroy
      // is held; the executor never allocates IDs or acquires another lock.
      if (resource_h.kind inside {RDMA_RESOURCE_CQ, RDMA_RESOURCE_SRQ,
                                  RDMA_RESOURCE_CEQ, RDMA_RESOURCE_AEQ}) begin
        if (queue_executor == null) begin
          status = invalid_state("queue lifecycle executor is unavailable");
          break;
        end
        if (!$cast(error_queue, resource) || error_queue == null ||
            error_queue.state != RDMA_RESOURCE_ERROR) begin
          status = invalid_state("recovery requires an ERROR queue");
          break;
        end
        status = same_owner_status(error_queue.owner, locked_owner,
                                   "recovery queue");
        if (status == null || !status.ok())
          break;
        queue_executor.recover_locked(
          binding, locked_owner, resource_h, transaction_id, result
        );
        if (result == null) begin
          result = make_result();
          result.transaction_id = transaction_id;
          status = invalid_state("queue recovery executor returned null result");
          break;
        end
        result_finalized = 1'b1;
        break;
      end
      if (!$cast(error_mr, resource) || error_mr == null ||
          error_mr.state != RDMA_RESOURCE_ERROR) begin
        status = invalid_state("recovery requires an ERROR MR");
        break;
      end
      result.resource_h = snapshot_handle(error_mr.handle);
      status = same_owner_status(error_mr.owner, locked_owner, "recovery MR");
      if (status == null || !status.ok()) begin
        status = checked_status(status, "recovery owner check returned null");
        break;
      end
      status = manager.lookup_recovery(resource_h, recovery);
      status = checked_status(
        status, "recovery record lookup returned null"
      );
      if (!status.ok())
        break;
      if (recovery == null || recovery.primary_status == null) begin
        status = invalid_state("ERROR MR recovery record is incomplete");
        break;
      end
      project_recovery_result_history(recovery, result);
      creation_origin = recovery_step_completed(
        recovery, RDMA_CTRL_STEP_RESOURCE_RESERVED
      );
      reserved_only = recovery.hardware_presence ==
                        RDMA_HW_PRESENCE_ABSENT &&
                      recovery.ambiguous_ticket == null &&
                      recovery.hmc_refs.size() == 0 &&
                      recovery.backing_refs.size() == 1 &&
                      recovery.backing_refs[0] != null &&
                      recovery.backing_refs[0].ownership ==
                        RDMA_OWNERSHIP_CONTROL_PLANE &&
                      recovery.pending_steps.size() == 1 &&
                      recovery.pending_steps[0] inside {
                        RDMA_CTRL_STEP_BACKING_RELEASED,
                        RDMA_CTRL_STEP_RESOURCE_RELEASED
                      };
      if (reserved_only) begin
        foreach (recovery.completed_steps[i]) begin
          if (rdma_control_step_is_hardware(recovery.completed_steps[i]))
            reserved_only = 1'b0;
        end
      end
      if (reserved_only) begin
        recover_reserved_error(resource_h, recovery, result);
        result_finalized = 1'b1;
        break;
      end

      if (!creation_origin &&
          destroy_recovery_restore_ready(recovery)) begin
        restore_destroy_recovery(resource_h, recovery, result);
        result_finalized = 1'b1;
        break;
      end

      if (recovery.ambiguous_ticket != null) begin
        ticket = recovery.ambiguous_ticket;
        terminal_known = 1'b0;
        completion = null;
        cmq.reconcile(ticket, terminal_known, completion,
                      reconcile_status);
        reconcile_status = checked_status(
          reconcile_status, "CMQ reconciliation returned null"
        );
        if (!terminal_known) begin
          publish_recovery_required(
            recovery, result,
            "ambiguous CMQ command has no terminal result"
          );
          if (!reconcile_status.ok())
            result.rollback_statuses.push_back(
              rdma_cmq_clone_status_value(reconcile_status)
            );
          result_finalized = 1'b1;
          break;
        end
        if (completion == null || completion.status == null) begin
          retain_recovery_failure(
            resource_h, recovery,
            invalid_state("CMQ reconciliation completion is incomplete"),
            result, "CMQ reconciliation still requires recovery"
          );
          result_finalized = 1'b1;
          break;
        end
        completion_status = checked_status(
          completion.status, "CMQ reconciliation status returned null"
        );
        if (completion_status.code == RDMA_SC_RESET_CANCELLED) begin
          publish_recovery_required(
            recovery, result,
            "reset cancellation does not prove hardware absence"
          );
          result_finalized = 1'b1;
          break;
        end

        if (ticket.opcode_key == null) begin
          retain_recovery_failure(
            resource_h, recovery,
            invalid_state("ambiguous CMQ ticket has no opcode"), result,
            "ambiguous CMQ command still requires recovery"
          );
          result_finalized = 1'b1;
          break;
        end
        defer_terminal_retry = 1'b0;
        case (ticket.opcode_key.opcode)
          XTR_V1_OP_KEY_ALLOC: begin
            if (!recovery_step_pending(
                  recovery, RDMA_CTRL_STEP_HW_KEY_ALLOCATED)) begin
              retain_recovery_failure(
                resource_h, recovery,
                invalid_state("KEY_ALLOC ticket has no pending step"),
                result, "ambiguous KEY_ALLOC still requires recovery"
              );
              result_finalized = 1'b1;
              break;
            end
            recovery.ambiguous_ticket = null;
            if (completion_status.ok()) begin
              recovery.hardware_presence = RDMA_HW_PRESENCE_PRESENT;
              complete_recovery_step(
                recovery, RDMA_CTRL_STEP_HW_KEY_ALLOCATED
              );
              queue_recovery_step(
                recovery, RDMA_CTRL_STEP_HW_MR_DEREGISTERED
              );
            end
            else begin
              recovery.hardware_presence = RDMA_HW_PRESENCE_ABSENT;
              remove_recovery_pending_step(
                recovery, RDMA_CTRL_STEP_HW_KEY_ALLOCATED
              );
              recovery.rollback_statuses.push_back(
                rdma_cmq_clone_status_value(completion_status)
              );
              queue_recovery_step(
                recovery, RDMA_CTRL_STEP_BACKING_RELEASED
              );
            end
          end
          XTR_V1_OP_OCC_FLUSH: begin
            recovery.ambiguous_ticket = null;
            recovery.hardware_presence = RDMA_HW_PRESENCE_PRESENT;
            if (completion_status.ok()) begin
              complete_recovery_step(
                recovery, RDMA_CTRL_STEP_HW_OCC_FLUSHED
              );
              queue_recovery_step(
                recovery, RDMA_CTRL_STEP_HW_MR_DEREGISTERED
              );
            end
            else begin
              if (!creation_origin)
                remove_recovery_pending_step(
                  recovery, RDMA_CTRL_STEP_HW_OCC_FLUSHED
                );
              recovery.rollback_statuses.push_back(
                rdma_cmq_clone_status_value(completion_status)
              );
            end
          end
          XTR_V1_OP_MR_DEREGISTER: begin
            recovery.ambiguous_ticket = null;
            if (completion_status.ok()) begin
              recovery.hardware_presence = RDMA_HW_PRESENCE_ABSENT;
              complete_recovery_step(
                recovery, RDMA_CTRL_STEP_HW_MR_DEREGISTERED
              );
              if (creation_origin)
                queue_recovery_step(
                  recovery, RDMA_CTRL_STEP_BACKING_RELEASED
                );
              else
                queue_recovery_step(
                  recovery, RDMA_CTRL_STEP_HW_DRAINED
                );
            end
            else begin
              recovery.hardware_presence = RDMA_HW_PRESENCE_PRESENT;
              if (!creation_origin)
                remove_recovery_pending_step(
                  recovery, RDMA_CTRL_STEP_HW_MR_DEREGISTERED
                );
              else
                defer_terminal_retry = 1'b1;
              recovery.rollback_statuses.push_back(
                rdma_cmq_clone_status_value(completion_status)
              );
            end
          end
          XTR_V1_OP_TQ_FLUSH: begin
            recovery.ambiguous_ticket = null;
            recovery.hardware_presence = RDMA_HW_PRESENCE_ABSENT;
            if (completion_status.ok()) begin
              complete_recovery_step(
                recovery, RDMA_CTRL_STEP_HW_DRAINED
              );
              queue_recovery_step(
                recovery, RDMA_CTRL_STEP_BACKING_RELEASED
              );
            end
            else begin
              recovery.rollback_statuses.push_back(
                rdma_cmq_clone_status_value(completion_status)
              );
              defer_terminal_retry = 1'b1;
            end
          end
          default: begin
            retain_recovery_failure(
              resource_h, recovery,
              rdma_status::make(
                RDMA_SC_UNSUPPORTED_OPCODE,
                "ambiguous recovery opcode is unsupported"
              ), result, "ambiguous CMQ command still requires recovery"
            );
            result_finalized = 1'b1;
          end
        endcase
        if (result_finalized)
          break;
        persist_status = persist_recovery_record(resource_h, recovery);
        if (!persist_status.ok()) begin
          publish_recovery_required(
            recovery, result,
            "reconciled CMQ progress could not be persisted"
          );
          result_finalized = 1'b1;
          break;
        end
        if (defer_terminal_retry) begin
          publish_recovery_required(
            recovery, result,
            "terminal hardware failure was retained for a later retry"
          );
          result_finalized = 1'b1;
          break;
        end
        if (!creation_origin &&
            destroy_recovery_restore_ready(recovery)) begin
          restore_destroy_recovery(resource_h, recovery, result);
          result_finalized = 1'b1;
          break;
        end
      end

      while (1'b1) begin
        has_hardware_pending = 1'b0;
        pending_hardware_step = RDMA_CTRL_STEP_RESOURCE_RESERVED;
        foreach (recovery.pending_steps[i]) begin
          if (!has_hardware_pending &&
              rdma_control_step_is_hardware(recovery.pending_steps[i])) begin
            has_hardware_pending = 1'b1;
            pending_hardware_step = recovery.pending_steps[i];
          end
        end
        if (!has_hardware_pending)
          break;
        if (recovery.hardware_presence == RDMA_HW_PRESENCE_UNKNOWN) begin
          publish_recovery_required(
            recovery, result,
            "unknown hardware state lacks terminal reconciliation"
          );
          result_finalized = 1'b1;
          break;
        end
        if (pending_hardware_step == RDMA_CTRL_STEP_HW_KEY_ALLOCATED) begin
          publish_recovery_required(
            recovery, result,
            "KEY_ALLOC ambiguity requires its original terminal result"
          );
          result_finalized = 1'b1;
          break;
        end

        execute_recovery_hardware_step(
          error_mr, locked_owner, pending_hardware_step,
          ticket, completion, status
        );
        if (!status.ok()) begin
          if (status.code == RDMA_SC_TIMEOUT) begin
            recovery.ambiguous_ticket = rdma_cmq_clone_ticket_value(
              ticket, "recovery timeout ticket"
            );
            if (pending_hardware_step == RDMA_CTRL_STEP_HW_DRAINED)
              recovery.hardware_presence = RDMA_HW_PRESENCE_ABSENT;
            else
              recovery.hardware_presence = RDMA_HW_PRESENCE_UNKNOWN;
          end
          else begin
            recovery.ambiguous_ticket = null;
            if (pending_hardware_step == RDMA_CTRL_STEP_HW_DRAINED)
              recovery.hardware_presence = RDMA_HW_PRESENCE_ABSENT;
            else
              recovery.hardware_presence = RDMA_HW_PRESENCE_PRESENT;
          end
          retain_recovery_failure(
            resource_h, recovery, status, result,
            "hardware recovery step failed"
          );
          result_finalized = 1'b1;
          break;
        end

        case (pending_hardware_step)
          RDMA_CTRL_STEP_HW_OCC_FLUSHED: begin
            recovery.hardware_presence = RDMA_HW_PRESENCE_PRESENT;
            complete_recovery_step(recovery, pending_hardware_step);
            queue_recovery_step(
              recovery, RDMA_CTRL_STEP_HW_MR_DEREGISTERED
            );
          end
          RDMA_CTRL_STEP_HW_MR_DEREGISTERED: begin
            recovery.hardware_presence = RDMA_HW_PRESENCE_ABSENT;
            complete_recovery_step(recovery, pending_hardware_step);
            if (creation_origin)
              queue_recovery_step(
                recovery, RDMA_CTRL_STEP_BACKING_RELEASED
              );
            else
              queue_recovery_step(recovery, RDMA_CTRL_STEP_HW_DRAINED);
          end
          RDMA_CTRL_STEP_HW_DRAINED: begin
            recovery.hardware_presence = RDMA_HW_PRESENCE_ABSENT;
            complete_recovery_step(recovery, pending_hardware_step);
            queue_recovery_step(
              recovery, RDMA_CTRL_STEP_BACKING_RELEASED
            );
          end
          default: begin
          end
        endcase
        persist_status = persist_recovery_record(resource_h, recovery);
        if (!persist_status.ok()) begin
          publish_recovery_required(
            recovery, result,
            "hardware recovery progress could not be persisted"
          );
          result_finalized = 1'b1;
          break;
        end
      end
      if (result_finalized)
        break;

      has_hardware_pending = 1'b0;
      foreach (recovery.pending_steps[i]) begin
        if (rdma_control_step_is_hardware(recovery.pending_steps[i]))
          has_hardware_pending = 1'b1;
      end
      if (has_hardware_pending ||
          recovery.hardware_presence != RDMA_HW_PRESENCE_ABSENT) begin
        publish_recovery_required(
          recovery, result,
          "hardware absence is not yet proven"
        );
        result_finalized = 1'b1;
        break;
      end

      if (!recovery_step_pending(
            recovery, RDMA_CTRL_STEP_BACKING_RELEASED) &&
          !recovery_step_completed(
            recovery, RDMA_CTRL_STEP_BACKING_RELEASED) &&
          !recovery_step_pending(
            recovery, RDMA_CTRL_STEP_RESOURCE_RELEASED)) begin
        queue_recovery_step(recovery, RDMA_CTRL_STEP_BACKING_RELEASED);
        persist_status = persist_recovery_record(resource_h, recovery);
        if (!persist_status.ok()) begin
          publish_recovery_required(
            recovery, result,
            "local recovery plan could not be persisted"
          );
          result_finalized = 1'b1;
          break;
        end
      end

      if (recovery_step_pending(
            recovery, RDMA_CTRL_STEP_BACKING_RELEASED)) begin
        for (int i = int'(recovery.hmc_refs.size()) - 1; i >= 0; i--) begin
          if (recovery.hmc_refs[i] == null) begin
            status = invalid_state("recovery HMC reference is null");
            retain_recovery_failure(
              resource_h, recovery, status, result,
              "HMC cleanup still requires recovery"
            );
            result_finalized = 1'b1;
            break;
          end
          if (recovery.hmc_refs[i].ownership == RDMA_OWNERSHIP_BORROWED ||
              recovery.hmc_refs[i].release_complete)
            continue;
          if (hmc_allocator == null) begin
            status = invalid_state("recovery HMC allocator is unavailable");
          end
          else begin
            status = hmc_allocator.lookup(
              recovery.hmc_refs[i].owner,
              recovery.hmc_refs[i].object_kind,
              recovery.hmc_refs[i].address, lease_size
            );
            status = checked_status(
              status, "recovery HMC lookup returned null"
            );
            if (status.ok() && lease_size != recovery.hmc_refs[i].size)
              status = invalid_state("recovery HMC lease size changed");
            if (status.ok()) begin
              status = hmc_allocator.\release (
                recovery.hmc_refs[i].owner,
                recovery.hmc_refs[i].object_kind,
                recovery.hmc_refs[i].address
              );
              status = checked_status(
                status, "recovery HMC release returned null"
              );
            end
            else if (status.code == RDMA_SC_INVALID_STATE) begin
              status = rdma_status::success(
                "recovery HMC lease was already released"
              );
            end
          end
          if (!status.ok()) begin
            retain_recovery_failure(
              resource_h, recovery, status, result,
              "HMC cleanup still requires recovery"
            );
            result_finalized = 1'b1;
            break;
          end
          recovery.hmc_refs[i].release_complete = 1'b1;
          persist_status = persist_recovery_record(resource_h, recovery);
          if (!persist_status.ok()) begin
            publish_recovery_required(
              recovery, result,
              "HMC cleanup progress could not be persisted"
            );
            result_finalized = 1'b1;
            break;
          end
        end
        if (result_finalized)
          break;

        foreach (recovery.backing_refs[i]) begin
          if (recovery.backing_refs[i] == null ||
              recovery.backing_refs[i].mapping == null) begin
            status = invalid_state("recovery backing reference is null");
            retain_recovery_failure(
              resource_h, recovery, status, result,
              "backing cleanup still requires recovery"
            );
            result_finalized = 1'b1;
            break;
          end
          if (recovery.backing_refs[i].ownership ==
                RDMA_OWNERSHIP_BORROWED ||
              recovery.backing_refs[i].release_complete)
            continue;
          status = manager.query_owned_release_completion(
            recovery.backing_refs[i].mapping, release_complete
          );
          status = checked_status(
            status, "recovery completion query returned null"
          );
          if (!status.ok()) begin
            retain_recovery_failure(
              resource_h, recovery, status, result,
              "backing cleanup still requires recovery"
            );
            result_finalized = 1'b1;
            break;
          end
          if (!release_complete) begin
            if (host_mem == null)
              status = invalid_state(
                "recovery host memory adapter is unavailable"
              );
            else
              status = host_mem.\release (
                recovery.backing_refs[i].mapping
              );
            status = checked_status(
              status, "recovery backing release returned null"
            );
            if (!status.ok()) begin
              retain_recovery_failure(
                resource_h, recovery, status, result,
                "backing cleanup still requires recovery"
              );
              result_finalized = 1'b1;
              break;
            end
            status = manager.query_owned_release_completion(
              recovery.backing_refs[i].mapping, release_complete
            );
            status = checked_status(
              status, "post-release completion query returned null"
            );
            if (!status.ok() || !release_complete) begin
              if (status.ok())
                status = invalid_state(
                  "host memory release did not seal completion"
                );
              retain_recovery_failure(
                resource_h, recovery, status, result,
                "backing cleanup still requires recovery"
              );
              result_finalized = 1'b1;
              break;
            end
          end
          recovery.backing_refs[i].release_complete = 1'b1;
          persist_status = persist_recovery_record(resource_h, recovery);
          if (!persist_status.ok()) begin
            publish_recovery_required(
              recovery, result,
              "backing cleanup progress could not be persisted"
            );
            result_finalized = 1'b1;
            break;
          end
        end
        if (result_finalized)
          break;

        complete_recovery_step(
          recovery, RDMA_CTRL_STEP_BACKING_RELEASED
        );
        queue_recovery_step(recovery, RDMA_CTRL_STEP_RESOURCE_RELEASED);
        persist_status = persist_recovery_record(resource_h, recovery);
        if (!persist_status.ok()) begin
          publish_recovery_required(
            recovery, result,
            "backing cleanup completion could not be persisted"
          );
          result_finalized = 1'b1;
          break;
        end
      end

      if (recovery.pending_steps.size() != 0 &&
          !recovery_step_pending(
            recovery, RDMA_CTRL_STEP_RESOURCE_RELEASED)) begin
        retain_recovery_failure(
          resource_h, recovery,
          invalid_state("recovery contains an unsupported pending step"),
          result, "resource still requires recovery"
        );
        result_finalized = 1'b1;
        break;
      end

      if (!recovery_step_completed(
            recovery, RDMA_CTRL_STEP_RESOURCE_RELEASED)) begin
        queue_recovery_step(
          recovery, RDMA_CTRL_STEP_RESOURCE_RELEASED
        );
        complete_recovery_step(
          recovery, RDMA_CTRL_STEP_RESOURCE_RELEASED
        );
        persist_status = persist_recovery_record(resource_h, recovery);
        if (!persist_status.ok()) begin
          publish_recovery_required(
            recovery, result,
            "resource-release progress could not be persisted"
          );
          result_finalized = 1'b1;
          break;
        end
      end
      if (recovery.pending_steps.size() != 0) begin
        publish_recovery_required(
          recovery, result,
          "resource still has pending recovery work"
        );
        result_finalized = 1'b1;
        break;
      end
      status = manager.finalize_release(resource_h);
      status = checked_status(
        status, "recovered ERROR final release returned null"
      );
      if (!status.ok()) begin
        remove_recovery_completed_step(
          recovery, RDMA_CTRL_STEP_RESOURCE_RELEASED
        );
        queue_recovery_step(
          recovery, RDMA_CTRL_STEP_RESOURCE_RELEASED
        );
        retain_recovery_failure(
          resource_h, recovery, status, result,
          "resource finalization still requires recovery"
        );
        result_finalized = 1'b1;
        break;
      end

      project_recovery_result_history(recovery, result);
      result.status = rdma_status::success();
      result.final_resource_state = RDMA_RESOURCE_RELEASED;
      result.final_resource_state_known = 1'b1;
      result.recovery_required = 1'b0;
      status = rdma_status::success();
    end while (1'b0);

    if (!result_finalized && (status == null || !status.ok()))
      finish_result(result, status);
    if (function_lock != null)
      function_lock.put(1);
  endtask
endclass
