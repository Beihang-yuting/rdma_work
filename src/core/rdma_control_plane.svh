class rdma_control_plane extends uvm_object;
  `uvm_object_utils(rdma_control_plane)

  protected rdma_resource_manager manager;
  protected rdma_cmq_port cmq;
  protected rdma_stag_key_policy key_policy;
  protected rdma_host_mem_api host_mem;
  protected rdma_hmc_allocator hmc_allocator;
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
    output bit result_finalized
  );
    rdma_resource authoritative_resource;
    rdma_status normalized_primary;
    rdma_status recovery_status;

    mr = null;
    result_finalized = 1'b1;
    normalized_primary = checked_status(
      primary_status, "MR recovery primary status is null"
    );
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

  protected function void cleanup_reserved_mr(
    rdma_mr reserved_mr,
    rdma_status primary_status,
    rdma_control_result result,
    output rdma_mr mr,
    output bit result_finalized
  );
    rdma_recovery_record recovery;
    rdma_status release_status;

    mr = null;
    result_finalized = 1'b0;
    release_status = manager.release_reserved(reserved_mr.handle);
    release_status = checked_status(
      release_status, "MR reservation rollback returned null"
    );
    if (release_status.ok()) begin
      result.final_resource_state = RDMA_RESOURCE_RELEASED;
      return;
    end

    result.rollback_statuses.push_back(
      rdma_cmq_clone_status_value(release_status)
    );
    recovery = rdma_recovery_record::type_id::create(
      "register_mr_absent_recovery"
    );
    recovery.resource_h = snapshot_handle(reserved_mr.handle);
    recovery.hardware_presence = RDMA_HW_PRESENCE_ABSENT;
    recovery.completed_steps = result.completed_steps;
    recovery.backing_refs = reserved_mr.backing_refs;
    recovery.hmc_refs = reserved_mr.hmc_refs;
    recovery.primary_status = rdma_cmq_clone_status_value(primary_status);
    recovery.rollback_statuses = result.rollback_statuses;
    finalize_mr_recovery(reserved_mr, recovery, primary_status, result, mr,
                         result_finalized);
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

  protected function rdma_status validate_backing(
    rdma_function_binding binding,
    rdma_register_mr_req request,
    rdma_mr_backing_desc backing,
    rdma_function_handle owner
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
    if (backing.requester_bdf != binding.pcie.bdf)
      return rdma_status::make(
        RDMA_SC_DMA_TRANSLATION,
        "register MR backing requester BDF does not match Function"
      );
    required_permissions = '0;
    required_permissions.device_read = 1'b1;
    required_permissions.device_write = request.access.local_write ||
                                        request.access.remote_write ||
                                        request.access.remote_atomic;
    required_permissions.atomic = request.access.remote_atomic;
    required_direction = required_permissions.device_write ?
                         RDMA_DMA_BIDIRECTIONAL : RDMA_DMA_DEVICE_READ;
    foreach (backing.backing_refs[i]) begin
      if (backing.backing_refs[i] == null ||
          backing.backing_refs[i].mapping == null)
        return invalid_argument("register MR backing reference is null");
      if (backing.backing_refs[i].ownership != RDMA_OWNERSHIP_BORROWED)
        return invalid_argument("register MR requires borrowed backing");
      if (backing.backing_refs[i].mapping.pasid_valid !=
            backing.pasid_valid ||
          (backing.pasid_valid &&
           backing.backing_refs[i].mapping.pasid != backing.pasid))
        return rdma_status::make(
          RDMA_SC_DMA_TRANSLATION,
          "register MR backing PASID does not match mapping"
        );
      status = backing.backing_refs[i].mapping.check_access(
        owner, backing.requester_bdf, request.iova, request.length,
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
      if (backing.hmc_refs[i].ownership != RDMA_OWNERSHIP_BORROWED)
        return invalid_argument("register MR requires borrowed HMC backing");
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

  protected function string function_key(rdma_function_handle owner);
    return $sformatf("%016h:%08h", owner.function_uid, owner.object_id);
  endfunction

  protected task reserve_transaction_id(
    output longint unsigned transaction_id,
    output rdma_status status
  );
    transaction_id = 0;
    status = invalid_state("transaction ID allocation did not complete");
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
    time command_timeout = 1us
  );
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
    default_timeout = command_timeout;
    configured = 1'b1;
    return rdma_status::success();
  endfunction

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

  task register_mr(
    rdma_function_binding binding,
    rdma_register_mr_req request,
    rdma_mr_backing_desc backing,
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

    mr = null;
    result = make_result();
    function_lock = null;
    result_finalized = 1'b0;
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
          status, "register MR request check returned null"
        );
        break;
      end
      status = validate_backing(binding, request, backing, owner);
      if (status == null || !status.ok()) begin
        status = checked_status(
          status, "register MR backing check returned null"
        );
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
        locked_owner, owner, "post-lock register MR binding"
      );
      if (status == null || !status.ok()) begin
        status = checked_status(
          status, "post-lock Function identity check returned null"
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
      status = validate_backing(binding, request, backing, locked_owner);
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
                                locked_owner);
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
      status = key_policy.derive(reserved_mr, stag_key);
      if (status == null || !status.ok()) begin
        status = checked_status(status,
                                "STAG key policy returned null status");
        cleanup_reserved_mr(reserved_mr, status, result, mr,
                            result_finalized);
        break;
      end
      reserved_mr.lkey = {reserved_mr.local_mr_id[23:0], stag_key};
      has_remote_access = frozen_request.access.remote_read ||
                          frozen_request.access.remote_write ||
                          frozen_request.access.remote_atomic;
      reserved_mr.rkey = has_remote_access ? reserved_mr.lkey : 32'b0;
      result.completed_steps.push_back(RDMA_CTRL_STEP_BACKING_ATTACHED);
      if (reserved_mr.hmc_refs.size() != 0)
        result.completed_steps.push_back(RDMA_CTRL_STEP_HMC_ATTACHED);

      status = manager.stage_allocated(reserved_mr);
      if (status == null || !status.ok()) begin
        status = checked_status(status,
                                "resource manager stage MR returned null");
        cleanup_reserved_mr(reserved_mr, status, result, mr,
                            result_finalized);
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
        cleanup_reserved_mr(reserved_mr, status, result, mr,
                            result_finalized);
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
        status = same_owner_status(
          live_owner, locked_owner, "post-KEY_ALLOC register MR binding"
        );
        status = checked_status(
          status, "post-KEY_ALLOC Function identity check returned null"
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
        break;
      end
      result.final_resource_state = RDMA_RESOURCE_PROGRAMMED;
      result.completed_steps.push_back(RDMA_CTRL_STEP_REGISTRY_PROGRAMMED);

      status = manager.activate(reserved_mr.handle);
      if (status == null || !status.ok()) begin
        status = checked_status(status,
                                "resource manager MR activate returned null");
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
    if (function_lock != null)
      function_lock.put(1);
  endtask
endclass
