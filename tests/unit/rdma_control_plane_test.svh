class rdma_control_plane_probe extends rdma_control_plane;
  `uvm_object_utils(rdma_control_plane_probe)

  function new(string name = "rdma_control_plane_probe");
    super.new(name);
  endfunction

  function void force_transaction_allocator(
    longint unsigned next_id,
    bit exhausted
  );
    next_transaction_id = next_id;
    transaction_ids_exhausted = exhausted;
  endfunction

  task acquire_test_function_lock(
    rdma_function_handle owner,
    output semaphore function_lock
  );
    acquire_function_lock(owner, function_lock);
  endtask

  task release_test_function_lock(semaphore function_lock);
    if (function_lock != null)
      function_lock.put(1);
  endtask

endclass

class rdma_post_activate_snapshot_failure_manager extends
  rdma_resource_manager;
  `uvm_object_utils(rdma_post_activate_snapshot_failure_manager)

  int unsigned begin_quiesce_calls;
  int unsigned finalize_release_calls;
  protected bit hostile_snapshot_pending;
  protected string hostile_key;

  function new(string name = "rdma_post_activate_snapshot_failure_manager");
    super.new(name);
    begin_quiesce_calls = 0;
    finalize_release_calls = 0;
    hostile_snapshot_pending = 1'b0;
  endfunction

  virtual function rdma_status activate(rdma_handle handle);
    rdma_status status;

    status = super.activate(handle);
    if (status != null && status.ok()) begin
      hostile_key = resource_key(handle);
      registry[hostile_key].state = RDMA_RESOURCE_ERROR;
      hostile_snapshot_pending = 1'b1;
    end
    return status;
  endfunction

  virtual function rdma_status begin_quiesce(rdma_handle handle);
    begin_quiesce_calls++;
    if (hostile_snapshot_pending && registry.exists(hostile_key)) begin
      registry[hostile_key].state = RDMA_RESOURCE_ACTIVE;
      hostile_snapshot_pending = 1'b0;
    end
    return super.begin_quiesce(handle);
  endfunction

  virtual function rdma_status finalize_release(rdma_handle handle);
    finalize_release_calls++;
    return super.finalize_release(handle);
  endfunction

endclass

class rdma_control_plane_test extends uvm_test;
  `uvm_component_utils(rdma_control_plane_test)

  function new(string name = "rdma_control_plane_test",
               uvm_component parent = null);
    super.new(name, parent);
  endfunction

  function automatic void expect_status(
    string check_name,
    rdma_status status,
    rdma_status_code_e expected_code
  );
    if (status == null) begin
      `uvm_error(check_name, "control-plane API returned a null status")
      return;
    end
    if (status.code != expected_code)
      `uvm_error(check_name,
                 $sformatf("expected %s, got %s (%s)",
                           expected_code.name(), status.code.name(),
                           status.convert2string()))
  endfunction

  function automatic void expect_result(
    string check_name,
    rdma_control_result result,
    rdma_status_code_e expected_code,
    bit require_transaction_id = 1'b1
  );
    rdma_status validation_status;

    if (result == null) begin
      `uvm_error(check_name, "control-plane result is null")
      return;
    end
    expect_status({check_name, "_STATUS"}, result.status, expected_code);
    if (result.primary_status == null ||
        result.primary_status.code != expected_code)
      `uvm_error(check_name, "primary status does not match the result")
    if (result.status != null && result.status == result.primary_status)
      `uvm_error(check_name, "status and primary status are aliased")
    if (require_transaction_id && result.transaction_id == 0)
      `uvm_error(check_name, "result has a zero transaction ID")
    validation_status = result.validate();
    expect_status({check_name, "_VALIDATE"}, validation_status, RDMA_SC_OK);
  endfunction

  function automatic rdma_function_binding make_active_binding(
    string name,
    longint unsigned function_uid = 64'h0123_4567_89ab_cdef,
    int unsigned global_function_id = 32'h9000_0101,
    int unsigned generation = 32'd7
  );
    rdma_function_binding binding;

    binding = rdma_function_binding::type_id::create(name);
    binding.function_uid = function_uid;
    binding.generation = generation;
    binding.global_function_id = global_function_id;
    binding.rdma_vf_id = 32'h9000_0202;
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
    binding.dma_domain_valid = 1'b1;
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

  function automatic rdma_create_pd_req make_create_pd_request(
    string name,
    rdma_function_binding binding
  );
    rdma_create_pd_req request;

    request = rdma_create_pd_req::type_id::create(name);
    request.request_id = 64'h1000;
    request.correlation_id = 64'h2000;
    request.owner = binding.make_handle();
    return request;
  endfunction

  function automatic bit same_handle_fields(
    rdma_handle lhs,
    rdma_handle rhs
  );
    if (lhs == null || rhs == null)
      return lhs == rhs;
    return lhs.kind == rhs.kind &&
           lhs.function_uid == rhs.function_uid &&
           lhs.object_id == rhs.object_id &&
           lhs.generation == rhs.generation;
  endfunction

  task automatic check_configure_contract();
    rdma_control_plane controls[8];
    rdma_resource_manager managers[8];
    rdma_mock_cmq_port cmqs[8];
    rdma_mock_stag_key_policy policies[8];
    rdma_mock_host_mem mem;
    rdma_hmc_allocator hmc;
    rdma_status status;

    mem = rdma_mock_host_mem::type_id::create("configure_mem");
    hmc = rdma_hmc_allocator::type_id::create("configure_hmc");
    foreach (controls[i]) begin
      controls[i] = rdma_control_plane::type_id::create(
        $sformatf("configure_control_%0d", i)
      );
      managers[i] = rdma_resource_manager::type_id::create(
        $sformatf("configure_manager_%0d", i)
      );
      cmqs[i] = rdma_mock_cmq_port::type_id::create(
        $sformatf("configure_cmq_%0d", i)
      );
      policies[i] = rdma_mock_stag_key_policy::type_id::create(
        $sformatf("configure_policy_%0d", i)
      );
    end

    status = controls[0].configure(null, cmqs[0], policies[0], mem, hmc,
                                   1us);
    expect_status("CONFIGURE_NULL_MANAGER", status,
                  RDMA_SC_INVALID_ARGUMENT);
    status = controls[1].configure(managers[1], null, policies[1], mem, hmc,
                                   1us);
    expect_status("CONFIGURE_NULL_CMQ", status, RDMA_SC_INVALID_ARGUMENT);
    status = controls[2].configure(managers[2], cmqs[2], null, mem, hmc,
                                   1us);
    expect_status("CONFIGURE_NULL_POLICY", status,
                  RDMA_SC_INVALID_ARGUMENT);
    status = controls[3].configure(managers[3], cmqs[3], policies[3], mem,
                                   hmc, 0ns);
    expect_status("CONFIGURE_ZERO_TIMEOUT", status,
                  RDMA_SC_INVALID_ARGUMENT);
    status = controls[4].configure(managers[4], cmqs[4], policies[4], mem,
                                   hmc, 1us);
    expect_status("CONFIGURE_OK", status, RDMA_SC_OK);
    status = controls[4].configure(managers[4], cmqs[4], policies[4], mem,
                                   hmc, 1us);
    expect_status("CONFIGURE_REPEAT", status, RDMA_SC_INVALID_STATE);
    status = controls[5].configure(managers[5], cmqs[5], policies[5], null,
                                   null, 1us);
    expect_status("CONFIGURE_OPTIONAL_ADAPTERS", status, RDMA_SC_OK);
    status = controls[6].configure(
      .resource_manager(managers[6]),
      .cmq_port(cmqs[6]),
      .key_policy(policies[6]),
      .host_mem(null),
      .hmc_allocator(null),
      .command_timeout(1us)
    );
    expect_status("CONFIGURE_NAMED_ARGUMENTS", status, RDMA_SC_OK);
    status = controls[7].configure(managers[7], cmqs[7], policies[7]);
    expect_status("CONFIGURE_DEFAULT_ARGUMENTS", status, RDMA_SC_OK);
    if (mem.calls.size() != 0)
      `uvm_error("CONFIGURE_SIDE_EFFECT",
                 "configure invoked the optional host-memory adapter")
  endtask

  task automatic check_pd_lifecycle();
    rdma_control_plane_probe control;
    rdma_resource_manager manager;
    rdma_mock_cmq_port mock_cmq;
    rdma_mock_stag_key_policy key_policy;
    rdma_mock_host_mem mock_mem;
    rdma_hmc_allocator hmc;
    rdma_function_binding binding;
    rdma_function_binding wrong_binding;
    rdma_function_binding stale_binding;
    rdma_create_pd_req request;
    rdma_create_pd_req hostile_request;
    rdma_pd pd;
    rdma_pd next_pd;
    rdma_pd registry_pd;
    rdma_mr reserved_mr;
    rdma_resource resource;
    rdma_handle saved_pd_h;
    rdma_control_result result;
    rdma_status status;
    rdma_hmc_fvm_addr_t hmc_base;
    rdma_hmc_fvm_addr_t first_hmc_address;
    longint unsigned first_transaction_id;

    control = rdma_control_plane_probe::type_id::create("control");
    manager = rdma_resource_manager::type_id::create("manager");
    mock_cmq = rdma_mock_cmq_port::type_id::create("mock_cmq");
    key_policy = rdma_mock_stag_key_policy::type_id::create("key_policy");
    mock_mem = rdma_mock_host_mem::type_id::create("mock_mem");
    hmc = rdma_hmc_allocator::type_id::create("hmc");
    hmc_base.value = 64'h0000_0004_0000_0000;
    status = hmc.configure(hmc_base, 64'h1000);
    expect_status("HMC_CONFIGURE", status, RDMA_SC_OK);
    binding = make_active_binding("binding");
    request = make_create_pd_request("request", binding);

    status = control.configure(manager, mock_cmq, key_policy, mock_mem, hmc,
                               1us);
    expect_status("CONFIGURE", status, RDMA_SC_OK);
    control.create_pd(binding, request, pd, result);
    expect_result("PD_CREATE", result, RDMA_SC_OK);
    first_transaction_id = (result == null) ? 0 : result.transaction_id;
    if (pd == null || pd.handle == null ||
        pd.state != RDMA_RESOURCE_ACTIVE ||
        result == null || result.resource_h == null ||
        result.resource_h == pd.handle ||
        !same_handle_fields(result.resource_h, pd.handle) ||
        !result.final_resource_state_known ||
        result.final_resource_state != RDMA_RESOURCE_ACTIVE ||
        result.completed_steps.size() != 2 ||
        result.completed_steps[0] != RDMA_CTRL_STEP_RESOURCE_RESERVED ||
        result.completed_steps[1] != RDMA_CTRL_STEP_REGISTRY_ACTIVE)
      `uvm_error("PD_CREATE",
                 "PD create did not publish the required ACTIVE result")
    if (pd == null || pd.handle == null)
      return;

    saved_pd_h = rdma_clone_handle_value(pd.handle, "PD test handle");
    status = manager.lookup(saved_pd_h, resource);
    expect_status("PD_LOOKUP", status, RDMA_SC_OK);
    if (!$cast(registry_pd, resource) || registry_pd == null ||
        registry_pd == pd || registry_pd.handle == pd.handle ||
        !same_handle_fields(registry_pd.handle, pd.handle))
      `uvm_error("PD_SNAPSHOT_DETACHED",
                 "control output aliases the manager registry snapshot")
    pd.state = RDMA_RESOURCE_ERROR;
    pd.handle.object_id ^= 32'h0000_00ff;
    status = manager.lookup(saved_pd_h, resource);
    expect_status("PD_LOOKUP_AFTER_MUTATION", status, RDMA_SC_OK);
    if (!$cast(registry_pd, resource) || registry_pd == null ||
        registry_pd.state != RDMA_RESOURCE_ACTIVE ||
        !same_handle_fields(registry_pd.handle, saved_pd_h))
      `uvm_error("PD_SNAPSHOT_AUTHORITY",
                 "caller mutation changed authoritative PD state")

    status = manager.create_mr(binding, saved_pd_h, reserved_mr);
    expect_status("MR_DEP_CREATE", status, RDMA_SC_OK);
    if (reserved_mr == null || reserved_mr.handle == null) begin
      `uvm_error("MR_DEP_CREATE_RESULT",
                 "resource manager returned a null MR reservation")
      return;
    end
    control.destroy_pd(binding, saved_pd_h, result);
    expect_result("PD_BUSY", result, RDMA_SC_RESOURCE_BUSY);
    if (result == null || result.resource_h == null ||
        !result.final_resource_state_known ||
        result.final_resource_state != RDMA_RESOURCE_ACTIVE ||
        !same_handle_fields(result.resource_h, saved_pd_h) ||
        result.transaction_id <= first_transaction_id)
      `uvm_error("PD_BUSY_RESULT",
                 "busy destroy lost PD identity/state/transaction order")
    status = manager.lookup(saved_pd_h, resource);
    expect_status("PD_BUSY_LOOKUP", status, RDMA_SC_OK);
    if (!$cast(registry_pd, resource) || registry_pd == null ||
        registry_pd.state != RDMA_RESOURCE_ACTIVE)
      `uvm_error("PD_BUSY_STATE", "busy destroy changed the ACTIVE PD")

    status = manager.release_reserved(reserved_mr.handle);
    expect_status("MR_DEP_RELEASE", status, RDMA_SC_OK);
    control.destroy_pd(binding, saved_pd_h, result);
    expect_result("PD_DESTROY", result, RDMA_SC_OK);
    if (result == null || result.resource_h == null ||
        !result.final_resource_state_known ||
        result.final_resource_state != RDMA_RESOURCE_RELEASED ||
        result.completed_steps.size() != 1 ||
        result.completed_steps[0] != RDMA_CTRL_STEP_RESOURCE_RELEASED ||
        !same_handle_fields(result.resource_h, saved_pd_h))
      `uvm_error("PD_DESTROY_RESULT",
                 "successful destroy result is incomplete")
    status = manager.lookup(saved_pd_h, resource);
    expect_status("PD_DESTROY_LOOKUP", status, RDMA_SC_INVALID_STATE);

    control.create_pd(binding, request, next_pd, result);
    expect_result("PD_RECREATE", result, RDMA_SC_OK);
    if (next_pd == null || next_pd.handle == null)
      return;
    saved_pd_h = rdma_clone_handle_value(next_pd.handle,
                                         "second PD test handle");
    wrong_binding = make_active_binding(
      "wrong_binding", 64'hfeed_0000_0000_0001, 32'h9000_0bad,
      binding.generation
    );
    control.destroy_pd(wrong_binding, saved_pd_h, result);
    expect_result("PD_WRONG_BINDING", result, RDMA_SC_INVALID_ARGUMENT);
    if (result == null || result.final_resource_state_known)
      `uvm_error("PD_WRONG_BINDING_STATE",
                 "wrong binding reported an authoritative final PD state")
    stale_binding = make_active_binding(
      "stale_binding", binding.function_uid, binding.global_function_id,
      binding.generation + 1'b1
    );
    control.destroy_pd(stale_binding, saved_pd_h, result);
    expect_result("PD_STALE_BINDING", result, RDMA_SC_STALE_GENERATION);
    if (result == null || result.final_resource_state_known)
      `uvm_error("PD_STALE_BINDING_STATE",
                 "stale binding reported an authoritative final PD state")
    status = manager.lookup(saved_pd_h, resource);
    expect_status("PD_REJECTED_DESTROY_LOOKUP", status, RDMA_SC_OK);
    if (!$cast(registry_pd, resource) || registry_pd == null ||
        registry_pd.state != RDMA_RESOURCE_ACTIVE)
      `uvm_error("PD_REJECTED_DESTROY_STATE",
                 "wrong/stale binding changed the ACTIVE PD")
    control.destroy_pd(binding, saved_pd_h, result);
    expect_result("PD_SECOND_DESTROY", result, RDMA_SC_OK);
    control.destroy_pd(binding, saved_pd_h, result);
    expect_result("PD_ALREADY_DESTROYED", result, RDMA_SC_INVALID_STATE);
    if (result == null || result.final_resource_state_known)
      `uvm_error("PD_ALREADY_DESTROYED_STATE",
                 "released-PD lookup reported a known final state")

    hostile_request = make_create_pd_request("hostile_request", binding);
    hostile_request.owner = wrong_binding.make_handle();
    control.create_pd(binding, hostile_request, pd, result);
    expect_result("PD_REQUEST_OWNER", result, RDMA_SC_INVALID_ARGUMENT);
    control.create_pd(binding, request, pd, result);
    expect_result("PD_AFTER_REJECT", result, RDMA_SC_OK);
    if (pd != null && pd.handle != null) begin
      saved_pd_h = rdma_clone_handle_value(pd.handle,
                                           "post-reject PD handle");
      control.destroy_pd(binding, saved_pd_h, result);
      expect_result("PD_AFTER_REJECT_DESTROY", result, RDMA_SC_OK);
    end

    if (mock_cmq.calls.size() != 0 || mock_mem.calls.size() != 0 ||
        key_policy.call_count != 0)
      `uvm_error("PD_NO_EXTERNAL_SIDE_EFFECTS",
                 "software PD lifecycle used CMQ, host memory, or key policy")
    status = hmc.allocate(binding.make_handle(), RDMA_RESOURCE_PD,
                          64, 64, first_hmc_address);
    expect_status("PD_NO_HMC_ALLOCATE", status, RDMA_SC_OK);
    if (first_hmc_address.value != hmc_base.value)
      `uvm_error("PD_NO_HMC_SIDE_EFFECTS",
                 "software PD lifecycle advanced the HMC allocator")
    status = hmc.\release (binding.make_handle(), RDMA_RESOURCE_PD,
                           first_hmc_address);
    expect_status("PD_HMC_TEST_CLEANUP", status, RDMA_SC_OK);
  endtask

  task automatic check_post_activate_snapshot_cleanup();
    rdma_control_plane control;
    rdma_post_activate_snapshot_failure_manager manager;
    rdma_mock_cmq_port mock_cmq;
    rdma_mock_stag_key_policy key_policy;
    rdma_function_binding binding;
    rdma_create_pd_req request;
    rdma_pd pd;
    rdma_resource resource;
    rdma_control_result result;
    rdma_status status;

    control = rdma_control_plane::type_id::create("cleanup_control");
    manager = rdma_post_activate_snapshot_failure_manager::type_id::create(
      "cleanup_manager"
    );
    mock_cmq = rdma_mock_cmq_port::type_id::create("cleanup_cmq");
    key_policy = rdma_mock_stag_key_policy::type_id::create(
      "cleanup_policy"
    );
    binding = make_active_binding(
      "cleanup_binding", 64'hc100_0000_0000_0001, 32'hc100_0101, 23
    );
    request = make_create_pd_request("cleanup_request", binding);
    status = control.configure(manager, mock_cmq, key_policy);
    expect_status("POST_ACTIVATE_CONFIGURE", status, RDMA_SC_OK);

    control.create_pd(binding, request, pd, result);
    expect_result("POST_ACTIVATE_SNAPSHOT", result, RDMA_SC_INVALID_STATE);
    if (pd != null)
      `uvm_error("POST_ACTIVATE_PD",
                 "failed active snapshot returned a public PD")
    if (result == null || result.resource_h == null ||
        !result.final_resource_state_known ||
        result.final_resource_state != RDMA_RESOURCE_RELEASED ||
        result.completed_steps.size() != 3 ||
        result.completed_steps[0] != RDMA_CTRL_STEP_RESOURCE_RESERVED ||
        result.completed_steps[1] != RDMA_CTRL_STEP_REGISTRY_ACTIVE ||
        result.completed_steps[2] != RDMA_CTRL_STEP_RESOURCE_RELEASED ||
        result.rollback_statuses.size() != 0)
      `uvm_error("POST_ACTIVATE_RESULT",
                 "post-activation cleanup result is incomplete")
    if (manager.begin_quiesce_calls != 1 ||
        manager.finalize_release_calls != 1)
      `uvm_error("POST_ACTIVATE_CLEANUP_CALLS",
                 "post-activation cleanup did not quiesce and release once")
    if (result != null && result.resource_h != null) begin
      status = manager.lookup(result.resource_h, resource);
      expect_status("POST_ACTIVATE_LOOKUP", status, RDMA_SC_INVALID_STATE);
    end
  endtask

  task automatic check_post_lock_revalidation();
    rdma_control_plane_probe binding_control;
    rdma_control_plane_probe request_control;
    rdma_resource_manager binding_manager;
    rdma_resource_manager request_manager;
    rdma_mock_cmq_port mock_cmq;
    rdma_mock_stag_key_policy key_policy;
    rdma_function_binding binding;
    rdma_function_binding request_binding;
    rdma_function_binding wrong_binding;
    rdma_create_pd_req request;
    rdma_create_pd_req mutable_request;
    rdma_function_handle prelock_owner;
    rdma_pd pd;
    rdma_control_result result;
    rdma_status status;
    semaphore held_lock;

    binding_control = rdma_control_plane_probe::type_id::create(
      "binding_fence_control"
    );
    binding_manager = rdma_resource_manager::type_id::create(
      "binding_fence_manager"
    );
    mock_cmq = rdma_mock_cmq_port::type_id::create("fence_cmq");
    key_policy = rdma_mock_stag_key_policy::type_id::create("fence_policy");
    binding = make_active_binding(
      "mutable_binding", 64'hf100_0000_0000_0001, 32'hf100_0101, 31
    );
    request = make_create_pd_request("binding_fence_request", binding);
    status = binding_control.configure(binding_manager, mock_cmq, key_policy);
    expect_status("BINDING_FENCE_CONFIGURE", status, RDMA_SC_OK);
    prelock_owner = binding.make_handle();
    binding_control.acquire_test_function_lock(prelock_owner, held_lock);
    fork
      begin
        binding_control.create_pd(binding, request, pd, result);
      end
      begin
        #1ns;
        binding.generation++;
        binding.owner_h = binding.make_handle();
        binding_control.release_test_function_lock(held_lock);
      end
    join
    expect_result("BINDING_FENCE", result, RDMA_SC_STALE_GENERATION);
    if (pd != null)
      `uvm_error("BINDING_FENCE_PD",
                 "post-lock binding mutation created a PD")
    if (pd != null && pd.handle != null) begin
      status = binding_manager.begin_quiesce(pd.handle);
      expect_status("BINDING_FENCE_RED_CLEANUP_QUIESCE", status, RDMA_SC_OK);
      status = binding_manager.finalize_release(pd.handle);
      expect_status("BINDING_FENCE_RED_CLEANUP_RELEASE", status, RDMA_SC_OK);
    end

    request_control = rdma_control_plane_probe::type_id::create(
      "request_fence_control"
    );
    request_manager = rdma_resource_manager::type_id::create(
      "request_fence_manager"
    );
    request_binding = make_active_binding(
      "request_binding", 64'hf200_0000_0000_0001, 32'hf200_0101, 37
    );
    wrong_binding = make_active_binding(
      "request_wrong_binding", 64'hf200_0000_0000_0002, 32'hf200_0202, 37
    );
    mutable_request = make_create_pd_request(
      "mutable_request", request_binding
    );
    status = request_control.configure(request_manager, mock_cmq, key_policy);
    expect_status("REQUEST_FENCE_CONFIGURE", status, RDMA_SC_OK);
    prelock_owner = request_binding.make_handle();
    request_control.acquire_test_function_lock(prelock_owner, held_lock);
    fork
      begin
        request_control.create_pd(
          request_binding, mutable_request, pd, result
        );
      end
      begin
        #1ns;
        mutable_request.owner = wrong_binding.make_handle();
        request_control.release_test_function_lock(held_lock);
      end
    join
    expect_result("REQUEST_FENCE", result, RDMA_SC_INVALID_ARGUMENT);
    if (pd != null)
      `uvm_error("REQUEST_FENCE_PD",
                 "post-lock request mutation created a PD")
    if (pd != null && pd.handle != null) begin
      status = request_manager.begin_quiesce(pd.handle);
      expect_status("REQUEST_FENCE_RED_CLEANUP_QUIESCE", status, RDMA_SC_OK);
      status = request_manager.finalize_release(pd.handle);
      expect_status("REQUEST_FENCE_RED_CLEANUP_RELEASE", status, RDMA_SC_OK);
    end
  endtask

  task automatic check_transaction_id_exhaustion();
    rdma_control_plane_probe control;
    rdma_resource_manager manager;
    rdma_mock_cmq_port mock_cmq;
    rdma_mock_stag_key_policy key_policy;
    rdma_function_binding binding;
    rdma_create_pd_req request;
    rdma_pd pd;
    rdma_control_result result;
    rdma_resource resource;
    rdma_status status;

    control = rdma_control_plane_probe::type_id::create("exhaust_control");
    manager = rdma_resource_manager::type_id::create("exhaust_manager");
    mock_cmq = rdma_mock_cmq_port::type_id::create("exhaust_cmq");
    key_policy = rdma_mock_stag_key_policy::type_id::create(
      "exhaust_policy"
    );
    binding = make_active_binding(
      "exhaust_binding", 64'he000_0000_0000_0001, 32'he000_0101, 17
    );
    request = make_create_pd_request("exhaust_request", binding);
    status = control.configure(manager, mock_cmq, key_policy, null, null,
                               1us);
    expect_status("TXN_CONFIGURE", status, RDMA_SC_OK);
    control.force_transaction_allocator(64'hffff_ffff_ffff_ffff, 1'b0);
    control.create_pd(binding, request, pd, result);
    expect_result("TXN_MAX", result, RDMA_SC_OK);
    if (result == null ||
        result.transaction_id != 64'hffff_ffff_ffff_ffff ||
        pd == null || pd.handle == null) begin
      `uvm_error("TXN_MAX", "maximum transaction ID was not issued once")
      return;
    end
    control.destroy_pd(binding, pd.handle, result);
    expect_result("TXN_EXHAUSTED", result, RDMA_SC_RESOURCE_EXHAUSTED,
                  1'b0);
    if (result == null || result.transaction_id != 0 ||
        result.resource_h == null ||
        result.final_resource_state_known ||
        !same_handle_fields(result.resource_h, pd.handle))
      `uvm_error("TXN_EXHAUSTED",
                 "exhaustion reused an ID or lost the supplied PD handle")
    status = manager.lookup(pd.handle, resource);
    expect_status("TXN_EXHAUSTED_PD_LOOKUP", status, RDMA_SC_OK);
    if (resource == null || resource.state != RDMA_RESOURCE_ACTIVE)
      `uvm_error("TXN_EXHAUSTED_PD_STATE",
                 "transaction-ID exhaustion changed the PD")
    status = manager.begin_quiesce(pd.handle);
    expect_status("TXN_EXHAUSTED_CLEANUP_QUIESCE", status, RDMA_SC_OK);
    status = manager.finalize_release(pd.handle);
    expect_status("TXN_EXHAUSTED_CLEANUP_RELEASE", status, RDMA_SC_OK);
  endtask

  virtual task run_phase(uvm_phase phase);
    phase.raise_objection(this);
    check_configure_contract();
    check_pd_lifecycle();
    check_post_activate_snapshot_cleanup();
    check_post_lock_revalidation();
    check_transaction_id_exhaustion();
    phase.drop_objection(this);
  endtask
endclass
