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

  function automatic void expect_recovery_result(
    string check_name,
    rdma_control_result result,
    rdma_status_code_e expected_primary_code
  );
    rdma_status validation_status;

    if (result == null) begin
      `uvm_error(check_name, "control-plane recovery result is null")
      return;
    end
    expect_status({check_name, "_STATUS"}, result.status,
                  RDMA_SC_RECOVERY_REQUIRED);
    expect_status({check_name, "_PRIMARY"}, result.primary_status,
                  expected_primary_code);
    if (result.status == result.primary_status)
      `uvm_error(check_name, "recovery status and primary status are aliased")
    if (result.transaction_id == 0)
      `uvm_error(check_name, "recovery result has a zero transaction ID")
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

  function automatic rdma_register_mr_req make_register_mr_request(
    string name,
    rdma_function_binding binding,
    rdma_pd pd
  );
    rdma_register_mr_req request;

    request = rdma_register_mr_req::type_id::create(name);
    request.request_id = 64'h3000;
    request.correlation_id = 64'h4000;
    request.owner = binding.make_handle();
    request.pd_h = rdma_clone_handle_value(pd.handle, {name, " PD"});
    request.iova.value = 64'h0000_0001_2000_0000;
    request.length = 64'h2000;
    request.access = '{local_write:1'b0, remote_read:1'b1,
                       remote_write:1'b0, memory_window_bind:1'b0,
                       remote_atomic:1'b0};
    return request;
  endfunction

  function automatic rdma_mr_backing_desc make_borrowed_pbl0_backing(
    string name,
    rdma_function_binding binding,
    rdma_register_mr_req request,
    rdma_mr_pbl_mode_e pbl_mode = RDMA_MR_PBL0
  );
    rdma_mr_backing_desc backing;
    rdma_dma_mapping mapping;
    rdma_backing_ref backing_ref;
    int unsigned ref_count;

    backing = rdma_mr_backing_desc::type_id::create(name);
    backing.function_h = binding.make_handle();
    backing.requester_bdf = binding.pcie.bdf;
    backing.pasid_valid = 1'b1;
    backing.pasid = 20'habcde;

    ref_count = (pbl_mode == RDMA_MR_PBL1) ? 2 : 1;
    for (int unsigned i = 0; i < ref_count; i++) begin
      mapping = rdma_dma_mapping::type_id::create(
        $sformatf("%s_mapping_%0d", name, i)
      );
      mapping.function_h = binding.make_handle();
      mapping.requester_bdf = backing.requester_bdf;
      mapping.pasid_valid = backing.pasid_valid;
      mapping.pasid = backing.pasid;
      mapping.backing_addr.value = 64'h0000_0002_0000_0000 +
                                   (i * 64'h1000);
      mapping.iova = request.iova;
      mapping.size = request.length;
      mapping.direction = (request.access.local_write ||
                           request.access.remote_write ||
                           request.access.remote_atomic) ?
                          RDMA_DMA_BIDIRECTIONAL : RDMA_DMA_DEVICE_READ;
      mapping.permissions.device_read = 1'b1;
      mapping.permissions.device_write =
        request.access.local_write || request.access.remote_write ||
        request.access.remote_atomic;
      mapping.permissions.atomic = request.access.remote_atomic;
      mapping.state = RDMA_MAPPING_ACTIVE;
      mapping.owner_h = rdma_clone_handle_value(request.pd_h,
                                                {name, " mapping owner"});

      backing_ref = rdma_backing_ref::type_id::create(
        $sformatf("%s_ref_%0d", name, i)
      );
      backing_ref.mapping = mapping;
      backing_ref.ownership = RDMA_OWNERSHIP_BORROWED;
      backing_ref.release_complete = 1'b0;
      backing.backing_refs.push_back(backing_ref);
    end
    backing.page_layout.pbl_mode = pbl_mode;
    case (pbl_mode)
      RDMA_MR_PBL0:
        backing.page_layout.pba0 =
          backing.backing_refs[0].mapping.backing_addr;
      RDMA_MR_PBL1: begin
        backing.page_layout.pba0 =
          backing.backing_refs[0].mapping.backing_addr;
        backing.page_layout.pba1 =
          backing.backing_refs[1].mapping.backing_addr;
      end
      default: begin
      end
    endcase
    return backing;
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

  function automatic rdma_hmc_ref make_borrowed_hmc_ref(
    string name,
    rdma_function_binding binding,
    rdma_hmc_fvm_addr_t address,
    longint unsigned size,
    int unsigned first_pbl_index
  );
    rdma_hmc_ref hmc_ref;

    hmc_ref = rdma_hmc_ref::type_id::create(name);
    hmc_ref.owner = binding.make_handle();
    hmc_ref.object_kind = RDMA_RESOURCE_MR;
    hmc_ref.address = address;
    hmc_ref.size = size;
    hmc_ref.first_pbl_index = first_pbl_index;
    hmc_ref.ownership = RDMA_OWNERSHIP_BORROWED;
    hmc_ref.release_complete = 1'b0;
    return hmc_ref;
  endfunction

  task automatic expect_pre_cmq_reject(
    string check_name,
    rdma_control_plane control,
    rdma_mock_cmq_port mock_cmq,
    rdma_function_binding binding,
    rdma_register_mr_req request,
    rdma_mr_backing_desc backing,
    rdma_status_code_e expected_code
  );
    rdma_mr mr;
    rdma_control_result result;
    int unsigned call_count;

    call_count = mock_cmq.calls.size();
    control.register_mr(binding, request, backing, mr, result);
    expect_result(check_name, result, expected_code);
    if (mr != null || mock_cmq.calls.size() != call_count ||
        result == null || result.resource_h != null ||
        result.final_resource_state_known ||
        result.final_resource_state != RDMA_RESOURCE_NEW)
      `uvm_error(check_name,
                 "invalid borrowed MR reached CMQ or published resource state")
    foreach (backing.backing_refs[i]) begin
      if (backing.backing_refs[i] == null ||
          backing.backing_refs[i].ownership != RDMA_OWNERSHIP_BORROWED ||
          backing.backing_refs[i].release_complete)
        `uvm_error(check_name,
                   "invalid path released or changed borrowed mapping authority")
    end
    foreach (backing.hmc_refs[i]) begin
      if (backing.hmc_refs[i] == null ||
          backing.hmc_refs[i].ownership != RDMA_OWNERSHIP_BORROWED ||
          backing.hmc_refs[i].release_complete)
        `uvm_error(check_name,
                   "invalid path released or changed borrowed HMC authority")
    end
  endtask

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

  task automatic check_borrowed_pbl0_registration();
    rdma_control_plane control;
    rdma_resource_manager manager;
    rdma_mock_cmq_port mock_cmq;
    rdma_mock_stag_key_policy key_policy;
    rdma_function_binding binding;
    rdma_create_pd_req pd_request;
    rdma_register_mr_req request;
    rdma_mr_backing_desc backing;
    rdma_pd pd;
    rdma_mr mr;
    rdma_mrt_model mrt;
    rdma_control_result result;
    rdma_status status;

    control = rdma_control_plane::type_id::create("pbl0_control");
    manager = rdma_resource_manager::type_id::create("pbl0_manager");
    mock_cmq = rdma_mock_cmq_port::type_id::create("pbl0_cmq");
    key_policy = rdma_mock_stag_key_policy::type_id::create("pbl0_policy");
    key_policy.fixed_key = 8'h5a;
    binding = make_active_binding(
      "pbl0_binding", 64'ha100_0000_0000_0001, 32'ha100_0101, 41
    );
    pd_request = make_create_pd_request("pbl0_pd_request", binding);
    status = control.configure(manager, mock_cmq, key_policy, null, null,
                               2us);
    expect_status("PBL0_CONFIGURE", status, RDMA_SC_OK);
    control.create_pd(binding, pd_request, pd, result);
    expect_result("PBL0_PD_CREATE", result, RDMA_SC_OK);
    if (pd == null || pd.handle == null)
      return;

    request = make_register_mr_request("pbl0_request", binding, pd);
    backing = make_borrowed_pbl0_backing("pbl0_backing", binding, request);
    control.register_mr(binding, request, backing, mr, result);
    expect_result("PBL0_REGISTER", result, RDMA_SC_OK);
    if (mr == null || mr.handle == null ||
        mr.state != RDMA_RESOURCE_ACTIVE ||
        mr.handle.object_id[31:28] != RDMA_RESOURCE_MR ||
        mr.lkey != {mr.local_mr_id[23:0], 8'h5a} ||
        mr.rkey != mr.lkey || key_policy.call_count != 1)
      `uvm_error("PBL0_REGISTER",
                 "borrowed PBL0 registration did not publish the ACTIVE MR")
    if (mock_cmq.calls.size() != 1 || mock_cmq.calls[0] == null ||
        mock_cmq.calls[0].opcode != XTR_V1_OP_KEY_ALLOC ||
        !$cast(mrt, mock_cmq.calls[0].command.body) || mrt == null ||
        mrt.mr_h == null || mrt.pd_h == null ||
        mrt.mr_h.object_id != mr.local_mr_id[23:0] ||
        mrt.pd_h.object_id != pd.local_pd_id[15:0] ||
        mrt.mr_h.object_id == mr.handle.object_id ||
        mrt.pd_h.object_id == pd.handle.object_id)
      `uvm_error("PBL0_PROJECTION",
                 "KEY_ALLOC did not separate local hardware IDs from registry handles")
  endtask

  task automatic check_key_alloc_explicit_failure();
    rdma_control_plane control;
    rdma_resource_manager manager;
    rdma_mock_cmq_port mock_cmq;
    rdma_mock_stag_key_policy key_policy;
    rdma_hmc_allocator hmc;
    rdma_function_binding binding;
    rdma_create_pd_req pd_request;
    rdma_register_mr_req request;
    rdma_mr_backing_desc backing;
    rdma_hmc_ref hmc_ref;
    rdma_hmc_fvm_addr_t hmc_base;
    rdma_hmc_fvm_addr_t hmc_address;
    rdma_pd pd;
    rdma_mr mr;
    rdma_resource resource;
    rdma_control_result result;
    rdma_status injected_status;
    rdma_status status;
    longint unsigned lease_size;
    int unsigned baseline_leak_count;
    int unsigned final_leak_count;

    control = rdma_control_plane::type_id::create("fail_control");
    manager = rdma_resource_manager::type_id::create("fail_manager");
    mock_cmq = rdma_mock_cmq_port::type_id::create("fail_cmq");
    key_policy = rdma_mock_stag_key_policy::type_id::create("fail_policy");
    hmc = rdma_hmc_allocator::type_id::create("fail_hmc");
    hmc_base.value = 64'h0000_0004_3000_0000;
    status = hmc.configure(hmc_base, 64'h4000);
    expect_status("FAIL_HMC_CONFIGURE", status, RDMA_SC_OK);
    binding = make_active_binding(
      "fail_binding", 64'ha400_0000_0000_0001, 32'ha400_0101, 53
    );
    pd_request = make_create_pd_request("fail_pd_request", binding);
    status = control.configure(manager, mock_cmq, key_policy, null, hmc,
                               5us);
    expect_status("FAIL_CONFIGURE", status, RDMA_SC_OK);
    control.create_pd(binding, pd_request, pd, result);
    expect_result("FAIL_PD_CREATE", result, RDMA_SC_OK);
    if (pd == null || pd.handle == null)
      return;

    void'(manager.check_leaks(baseline_leak_count, binding.make_handle()));
    request = make_register_mr_request("fail_request", binding, pd);
    backing = make_borrowed_pbl0_backing(
      "fail_backing", binding, request, RDMA_MR_PBL2
    );
    status = hmc.allocate(binding.make_handle(), RDMA_RESOURCE_MR,
                          64'h1000, 64'h1000, hmc_address);
    expect_status("FAIL_HMC_ALLOCATE", status, RDMA_SC_OK);
    status = hmc.lookup(binding.make_handle(), RDMA_RESOURCE_MR,
                        hmc_address, lease_size);
    expect_status("FAIL_HMC_PRE_LOOKUP", status, RDMA_SC_OK);
    hmc_ref = make_borrowed_hmc_ref(
      "fail_hmc_ref", binding, hmc_address, lease_size, 28'h000_0200
    );
    backing.hmc_refs.push_back(hmc_ref);
    backing.page_layout.first_pbl_index = hmc_ref.first_pbl_index;
    injected_status = rdma_status::make(
      RDMA_SC_UNKNOWN_HW_ERROR, "injected KEY_ALLOC failure"
    );
    mock_cmq.fail_opcode(XTR_V1_OP_KEY_ALLOC, injected_status);

    control.register_mr(binding, request, backing, mr, result);
    expect_result("KEY_ALLOC_FAILURE", result, RDMA_SC_UNKNOWN_HW_ERROR);
    if (mr != null || result == null || result.resource_h == null ||
        !result.final_resource_state_known ||
        result.final_resource_state != RDMA_RESOURCE_RELEASED ||
        result.recovery_required || result.rollback_statuses.size() != 0 ||
        result.completed_steps.size() != 3 ||
        result.completed_steps[0] != RDMA_CTRL_STEP_RESOURCE_RESERVED ||
        result.completed_steps[1] != RDMA_CTRL_STEP_BACKING_ATTACHED ||
        result.completed_steps[2] != RDMA_CTRL_STEP_HMC_ATTACHED)
      `uvm_error("KEY_ALLOC_FAILURE_RESULT",
                 "explicit KEY_ALLOC failure did not release local state")
    if (mock_cmq.calls.size() != 1 || mock_cmq.calls[0] == null ||
        mock_cmq.calls[0].opcode != XTR_V1_OP_KEY_ALLOC)
      `uvm_error("KEY_ALLOC_FAILURE_COMMANDS",
                 "explicit KEY_ALLOC failure issued an unexpected command")
    if (result != null && result.resource_h != null) begin
      status = manager.lookup(result.resource_h, resource);
      expect_status("KEY_ALLOC_FAILURE_LOOKUP", status,
                    RDMA_SC_INVALID_STATE);
    end
    void'(manager.check_leaks(final_leak_count, binding.make_handle()));
    if (final_leak_count != baseline_leak_count)
      `uvm_error("KEY_ALLOC_FAILURE_RESERVATION",
                 "explicit KEY_ALLOC failure leaked the MR reservation")
    if (backing.backing_refs[0] == null ||
        backing.backing_refs[0].ownership != RDMA_OWNERSHIP_BORROWED ||
        backing.backing_refs[0].release_complete ||
        backing.backing_refs[0].mapping == null ||
        backing.backing_refs[0].mapping.state != RDMA_MAPPING_ACTIVE ||
        backing.hmc_refs[0] == null ||
        backing.hmc_refs[0].ownership != RDMA_OWNERSHIP_BORROWED ||
        backing.hmc_refs[0].release_complete)
      `uvm_error("KEY_ALLOC_FAILURE_BORROWED",
                 "explicit KEY_ALLOC failure changed borrowed authority")
    status = hmc.lookup(binding.make_handle(), RDMA_RESOURCE_MR,
                        hmc_address, lease_size);
    expect_status("KEY_ALLOC_FAILURE_HMC_LOOKUP", status, RDMA_SC_OK);
  endtask

  task automatic check_key_alloc_timeout_recovery();
    rdma_control_plane control;
    rdma_resource_manager manager;
    rdma_mock_cmq_port mock_cmq;
    rdma_mock_stag_key_policy key_policy;
    rdma_hmc_allocator hmc;
    rdma_function_binding binding;
    rdma_create_pd_req pd_request;
    rdma_register_mr_req request;
    rdma_mr_backing_desc backing;
    rdma_hmc_ref hmc_ref;
    rdma_hmc_fvm_addr_t hmc_base;
    rdma_hmc_fvm_addr_t hmc_address;
    rdma_pd pd;
    rdma_mr mr;
    rdma_mr registry_mr;
    rdma_resource resource;
    rdma_control_result result;
    rdma_recovery_record recovery;
    rdma_status status;
    longint unsigned lease_size;
    int unsigned baseline_leak_count;
    int unsigned final_leak_count;

    control = rdma_control_plane::type_id::create("timeout_control");
    manager = rdma_resource_manager::type_id::create("timeout_manager");
    mock_cmq = rdma_mock_cmq_port::type_id::create("timeout_cmq");
    key_policy = rdma_mock_stag_key_policy::type_id::create(
      "timeout_policy"
    );
    hmc = rdma_hmc_allocator::type_id::create("timeout_hmc");
    hmc_base.value = 64'h0000_0004_4000_0000;
    status = hmc.configure(hmc_base, 64'h4000);
    expect_status("TIMEOUT_HMC_CONFIGURE", status, RDMA_SC_OK);
    binding = make_active_binding(
      "timeout_binding", 64'ha500_0000_0000_0001, 32'ha500_0101, 59
    );
    pd_request = make_create_pd_request("timeout_pd_request", binding);
    status = control.configure(manager, mock_cmq, key_policy, null, hmc,
                               6us);
    expect_status("TIMEOUT_CONFIGURE", status, RDMA_SC_OK);
    control.create_pd(binding, pd_request, pd, result);
    expect_result("TIMEOUT_PD_CREATE", result, RDMA_SC_OK);
    if (pd == null || pd.handle == null)
      return;

    void'(manager.check_leaks(baseline_leak_count, binding.make_handle()));
    request = make_register_mr_request("timeout_request", binding, pd);
    backing = make_borrowed_pbl0_backing(
      "timeout_backing", binding, request, RDMA_MR_PBL2
    );
    status = hmc.allocate(binding.make_handle(), RDMA_RESOURCE_MR,
                          64'h1000, 64'h1000, hmc_address);
    expect_status("TIMEOUT_HMC_ALLOCATE", status, RDMA_SC_OK);
    status = hmc.lookup(binding.make_handle(), RDMA_RESOURCE_MR,
                        hmc_address, lease_size);
    expect_status("TIMEOUT_HMC_PRE_LOOKUP", status, RDMA_SC_OK);
    hmc_ref = make_borrowed_hmc_ref(
      "timeout_hmc_ref", binding, hmc_address, lease_size, 28'h000_0300
    );
    backing.hmc_refs.push_back(hmc_ref);
    backing.page_layout.first_pbl_index = hmc_ref.first_pbl_index;
    mock_cmq.timeout_opcode(XTR_V1_OP_KEY_ALLOC);

    control.register_mr(binding, request, backing, mr, result);
    expect_recovery_result("KEY_ALLOC_TIMEOUT", result, RDMA_SC_TIMEOUT);
    if (mr == null || mr.handle == null ||
        mr.state != RDMA_RESOURCE_ERROR || result == null ||
        result.resource_h == null || !result.final_resource_state_known ||
        result.final_resource_state != RDMA_RESOURCE_ERROR ||
        !result.recovery_required || result.rollback_statuses.size() != 0 ||
        result.completed_steps.size() != 3 ||
        result.completed_steps[0] != RDMA_CTRL_STEP_RESOURCE_RESERVED ||
        result.completed_steps[1] != RDMA_CTRL_STEP_BACKING_ATTACHED ||
        result.completed_steps[2] != RDMA_CTRL_STEP_HMC_ATTACHED)
      `uvm_error("KEY_ALLOC_TIMEOUT_RESULT",
                 "timeout did not preserve an ERROR MR for recovery")
    if (mock_cmq.calls.size() != 1 || mock_cmq.calls[0] == null ||
        mock_cmq.calls[0].opcode != XTR_V1_OP_KEY_ALLOC ||
        mock_cmq.calls[0].ticket == null)
      `uvm_error("KEY_ALLOC_TIMEOUT_COMMANDS",
                 "timeout lost its sole ambiguous KEY_ALLOC ticket")
    if (result != null && result.resource_h != null) begin
      status = manager.lookup(result.resource_h, resource);
      expect_status("KEY_ALLOC_TIMEOUT_LOOKUP", status, RDMA_SC_OK);
      if (!$cast(registry_mr, resource) || registry_mr == null ||
          registry_mr.state != RDMA_RESOURCE_ERROR ||
          !same_handle_fields(registry_mr.handle, result.resource_h))
        `uvm_error("KEY_ALLOC_TIMEOUT_STATE",
                   "manager did not retain the ERROR MR incarnation")
      status = manager.lookup_recovery(result.resource_h, recovery);
      expect_status("KEY_ALLOC_TIMEOUT_RECOVERY", status, RDMA_SC_OK);
    end
    if (recovery == null ||
        recovery.hardware_presence != RDMA_HW_PRESENCE_UNKNOWN ||
        recovery.resource_h == null ||
        !same_handle_fields(recovery.resource_h, result.resource_h) ||
        recovery.completed_steps != result.completed_steps ||
        recovery.pending_steps.size() != 1 ||
        recovery.pending_steps[0] != RDMA_CTRL_STEP_HW_KEY_ALLOCATED ||
        recovery.backing_refs.size() != 1 ||
        recovery.hmc_refs.size() != 1 ||
        recovery.ambiguous_ticket == null ||
        recovery.primary_status == null ||
        recovery.primary_status.code != RDMA_SC_TIMEOUT)
      `uvm_error("KEY_ALLOC_TIMEOUT_RECORD",
                 "timeout recovery record is incomplete")
    else if (mock_cmq.calls[0] != null &&
             mock_cmq.calls[0].ticket != null &&
             (recovery.ambiguous_ticket == mock_cmq.calls[0].ticket ||
              recovery.ambiguous_ticket.command_id !=
                mock_cmq.calls[0].ticket.command_id ||
              !same_handle_fields(recovery.ambiguous_ticket.function_h,
                                  mock_cmq.calls[0].ticket.function_h) ||
              recovery.ambiguous_ticket.opcode_key == null ||
              recovery.ambiguous_ticket.opcode_key.opcode !=
                XTR_V1_OP_KEY_ALLOC))
      `uvm_error("KEY_ALLOC_TIMEOUT_TICKET",
                 "timeout recovery ticket is aliased or corrupted")
    void'(manager.check_leaks(final_leak_count, binding.make_handle()));
    if (final_leak_count != baseline_leak_count + 1)
      `uvm_error("KEY_ALLOC_TIMEOUT_RESERVATION",
                 "timeout released or duplicated the staged MR")
    if (backing.backing_refs[0] == null ||
        backing.backing_refs[0].ownership != RDMA_OWNERSHIP_BORROWED ||
        backing.backing_refs[0].release_complete ||
        backing.backing_refs[0].mapping == null ||
        backing.backing_refs[0].mapping.state != RDMA_MAPPING_ACTIVE ||
        backing.hmc_refs[0] == null ||
        backing.hmc_refs[0].ownership != RDMA_OWNERSHIP_BORROWED ||
        backing.hmc_refs[0].release_complete)
      `uvm_error("KEY_ALLOC_TIMEOUT_BORROWED",
                 "timeout changed borrowed backing authority")
    status = hmc.lookup(binding.make_handle(), RDMA_RESOURCE_MR,
                        hmc_address, lease_size);
    expect_status("KEY_ALLOC_TIMEOUT_HMC_LOOKUP", status, RDMA_SC_OK);
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

  task automatic check_register_mr_post_lock_revalidation();
    rdma_control_plane_probe control;
    rdma_resource_manager manager;
    rdma_mock_cmq_port mock_cmq;
    rdma_mock_stag_key_policy key_policy;
    rdma_function_binding binding;
    rdma_function_binding wrong_binding;
    rdma_create_pd_req pd_request;
    rdma_register_mr_req request;
    rdma_mr_backing_desc backing;
    rdma_function_handle prelock_owner;
    rdma_pd pd;
    rdma_mr mr;
    rdma_control_result result;
    rdma_status status;
    semaphore held_lock;

    control = rdma_control_plane_probe::type_id::create(
      "mr_fence_control"
    );
    manager = rdma_resource_manager::type_id::create("mr_fence_manager");
    mock_cmq = rdma_mock_cmq_port::type_id::create("mr_fence_cmq");
    key_policy = rdma_mock_stag_key_policy::type_id::create(
      "mr_fence_policy"
    );
    binding = make_active_binding(
      "mr_fence_binding", 64'hf300_0000_0000_0001, 32'hf300_0101, 61
    );
    wrong_binding = make_active_binding(
      "mr_fence_wrong_binding", 64'hf300_0000_0000_0002,
      32'hf300_0202, 61
    );
    pd_request = make_create_pd_request("mr_fence_pd_request", binding);
    status = control.configure(manager, mock_cmq, key_policy);
    expect_status("MR_FENCE_CONFIGURE", status, RDMA_SC_OK);
    control.create_pd(binding, pd_request, pd, result);
    expect_result("MR_FENCE_PD_CREATE", result, RDMA_SC_OK);
    if (pd == null || pd.handle == null)
      return;

    request = make_register_mr_request(
      "mr_request_fence_request", binding, pd
    );
    backing = make_borrowed_pbl0_backing(
      "mr_request_fence_backing", binding, request
    );
    prelock_owner = binding.make_handle();
    control.acquire_test_function_lock(prelock_owner, held_lock);
    fork
      begin
        control.register_mr(binding, request, backing, mr, result);
      end
      begin
        #1ns;
        request.owner = wrong_binding.make_handle();
        control.release_test_function_lock(held_lock);
      end
    join
    expect_result("MR_REQUEST_FENCE", result, RDMA_SC_INVALID_ARGUMENT);
    if (mr != null || result == null || result.resource_h != null ||
        result.final_resource_state_known ||
        result.final_resource_state != RDMA_RESOURCE_NEW ||
        mock_cmq.calls.size() != 0 || key_policy.call_count != 0)
      `uvm_error("MR_REQUEST_FENCE_RESULT",
                 "post-lock request mutation reached MR side effects")

    request = make_register_mr_request(
      "mr_backing_fence_request", binding, pd
    );
    backing = make_borrowed_pbl0_backing(
      "mr_backing_fence_backing", binding, request
    );
    control.acquire_test_function_lock(prelock_owner, held_lock);
    fork
      begin
        control.register_mr(binding, request, backing, mr, result);
      end
      begin
        #1ns;
        backing.backing_refs[0].mapping.function_h.generation++;
        control.release_test_function_lock(held_lock);
      end
    join
    expect_result("MR_BACKING_FENCE", result, RDMA_SC_STALE_GENERATION);
    if (mr != null || result == null || result.resource_h != null ||
        result.final_resource_state_known ||
        result.final_resource_state != RDMA_RESOURCE_NEW ||
        mock_cmq.calls.size() != 0 || key_policy.call_count != 0 ||
        backing.backing_refs[0].release_complete ||
        backing.backing_refs[0].mapping.state != RDMA_MAPPING_ACTIVE)
      `uvm_error("MR_BACKING_FENCE_RESULT",
                 "post-lock backing mutation reached MR side effects")
  endtask

  task automatic check_register_mr_pre_cmq_rejections();
    rdma_control_plane control;
    rdma_resource_manager manager;
    rdma_mock_cmq_port mock_cmq;
    rdma_mock_stag_key_policy key_policy;
    rdma_hmc_allocator hmc;
    rdma_function_binding binding;
    rdma_create_pd_req pd_request;
    rdma_register_mr_req request;
    rdma_mr_backing_desc backing;
    rdma_hmc_ref hmc_ref;
    rdma_hmc_fvm_addr_t hmc_base;
    rdma_hmc_fvm_addr_t hmc_address;
    rdma_pd pd;
    rdma_control_result result;
    rdma_status status;
    longint unsigned lease_size;

    control = rdma_control_plane::type_id::create("reject_control");
    manager = rdma_resource_manager::type_id::create("reject_manager");
    mock_cmq = rdma_mock_cmq_port::type_id::create("reject_cmq");
    key_policy = rdma_mock_stag_key_policy::type_id::create("reject_policy");
    hmc = rdma_hmc_allocator::type_id::create("reject_hmc");
    hmc_base.value = 64'h0000_0004_2000_0000;
    status = hmc.configure(hmc_base, 64'h4000);
    expect_status("REJECT_HMC_CONFIGURE", status, RDMA_SC_OK);
    binding = make_active_binding(
      "reject_binding", 64'ha300_0000_0000_0001, 32'ha300_0101, 47
    );
    pd_request = make_create_pd_request("reject_pd_request", binding);
    status = control.configure(manager, mock_cmq, key_policy, null, hmc,
                               4us);
    expect_status("REJECT_CONFIGURE", status, RDMA_SC_OK);
    control.create_pd(binding, pd_request, pd, result);
    expect_result("REJECT_PD_CREATE", result, RDMA_SC_OK);
    if (pd == null || pd.handle == null)
      return;

    request = make_register_mr_request("reject_uid_request", binding, pd);
    backing = make_borrowed_pbl0_backing(
      "reject_uid_backing", binding, request
    );
    backing.backing_refs[0].mapping.function_h.function_uid++;
    expect_pre_cmq_reject("REJECT_MAPPING_UID", control, mock_cmq,
                          binding, request, backing,
                          RDMA_SC_DMA_TRANSLATION);

    request = make_register_mr_request("reject_gen_request", binding, pd);
    backing = make_borrowed_pbl0_backing(
      "reject_gen_backing", binding, request
    );
    backing.backing_refs[0].mapping.function_h.generation++;
    expect_pre_cmq_reject("REJECT_MAPPING_GENERATION", control, mock_cmq,
                          binding, request, backing,
                          RDMA_SC_STALE_GENERATION);

    request = make_register_mr_request("reject_bdf_request", binding, pd);
    backing = make_borrowed_pbl0_backing(
      "reject_bdf_backing", binding, request
    );
    backing.backing_refs[0].mapping.requester_bdf.bus++;
    expect_pre_cmq_reject("REJECT_MAPPING_BDF", control, mock_cmq,
                          binding, request, backing,
                          RDMA_SC_DMA_TRANSLATION);

    request = make_register_mr_request("reject_pasid_request", binding, pd);
    backing = make_borrowed_pbl0_backing(
      "reject_pasid_backing", binding, request
    );
    backing.backing_refs[0].mapping.pasid++;
    expect_pre_cmq_reject("REJECT_MAPPING_PASID", control, mock_cmq,
                          binding, request, backing,
                          RDMA_SC_DMA_TRANSLATION);

    request = make_register_mr_request("reject_overflow_request", binding,
                                       pd);
    request.iova.value = 64'hffff_ffff_ffff_ff80;
    request.length = 64'h100;
    backing = make_borrowed_pbl0_backing(
      "reject_overflow_backing", binding, request
    );
    expect_pre_cmq_reject("REJECT_IOVA_OVERFLOW", control, mock_cmq,
                          binding, request, backing,
                          RDMA_SC_DMA_TRANSLATION);

    request = make_register_mr_request("reject_range_request", binding, pd);
    backing = make_borrowed_pbl0_backing(
      "reject_range_backing", binding, request
    );
    request.iova.value += backing.backing_refs[0].mapping.size;
    expect_pre_cmq_reject("REJECT_IOVA_RANGE", control, mock_cmq,
                          binding, request, backing,
                          RDMA_SC_DMA_TRANSLATION);

    request = make_register_mr_request("reject_read_request", binding, pd);
    backing = make_borrowed_pbl0_backing(
      "reject_read_backing", binding, request
    );
    backing.backing_refs[0].mapping.permissions.device_read = 1'b0;
    expect_pre_cmq_reject("REJECT_DEVICE_READ", control, mock_cmq,
                          binding, request, backing,
                          RDMA_SC_DMA_PERMISSION);

    request = make_register_mr_request("reject_write_request", binding, pd);
    request.access.remote_write = 1'b1;
    backing = make_borrowed_pbl0_backing(
      "reject_write_backing", binding, request
    );
    backing.backing_refs[0].mapping.permissions.device_write = 1'b0;
    expect_pre_cmq_reject("REJECT_DEVICE_WRITE", control, mock_cmq,
                          binding, request, backing,
                          RDMA_SC_DMA_PERMISSION);

    request = make_register_mr_request("reject_atomic_request", binding, pd);
    request.access.remote_atomic = 1'b1;
    backing = make_borrowed_pbl0_backing(
      "reject_atomic_backing", binding, request
    );
    backing.backing_refs[0].mapping.permissions.atomic = 1'b0;
    expect_pre_cmq_reject("REJECT_ATOMIC", control, mock_cmq,
                          binding, request, backing,
                          RDMA_SC_DMA_PERMISSION);

    status = hmc.allocate(binding.make_handle(), RDMA_RESOURCE_MR,
                          64'h1000, 64'h1000, hmc_address);
    expect_status("REJECT_HMC_ALLOCATE", status, RDMA_SC_OK);
    status = hmc.lookup(binding.make_handle(), RDMA_RESOURCE_MR,
                        hmc_address, lease_size);
    expect_status("REJECT_HMC_LOOKUP", status, RDMA_SC_OK);

    request = make_register_mr_request("reject_hmc_owner_request", binding,
                                       pd);
    backing = make_borrowed_pbl0_backing(
      "reject_hmc_owner_backing", binding, request, RDMA_MR_PBL2
    );
    hmc_ref = make_borrowed_hmc_ref(
      "reject_hmc_owner_ref", binding, hmc_address, lease_size, 28'h20
    );
    hmc_ref.owner.function_uid++;
    backing.hmc_refs.push_back(hmc_ref);
    backing.page_layout.first_pbl_index = hmc_ref.first_pbl_index;
    expect_pre_cmq_reject("REJECT_HMC_OWNER", control, mock_cmq,
                          binding, request, backing,
                          RDMA_SC_INVALID_ARGUMENT);

    request = make_register_mr_request("reject_hmc_gen_request", binding,
                                       pd);
    backing = make_borrowed_pbl0_backing(
      "reject_hmc_gen_backing", binding, request, RDMA_MR_PBL2
    );
    hmc_ref = make_borrowed_hmc_ref(
      "reject_hmc_gen_ref", binding, hmc_address, lease_size, 28'h20
    );
    hmc_ref.owner.generation++;
    backing.hmc_refs.push_back(hmc_ref);
    backing.page_layout.first_pbl_index = hmc_ref.first_pbl_index;
    expect_pre_cmq_reject("REJECT_HMC_GENERATION", control, mock_cmq,
                          binding, request, backing,
                          RDMA_SC_STALE_GENERATION);

    request = make_register_mr_request("reject_hmc_kind_request", binding,
                                       pd);
    backing = make_borrowed_pbl0_backing(
      "reject_hmc_kind_backing", binding, request, RDMA_MR_PBL2
    );
    hmc_ref = make_borrowed_hmc_ref(
      "reject_hmc_kind_ref", binding, hmc_address, lease_size, 28'h20
    );
    hmc_ref.object_kind = RDMA_RESOURCE_PD;
    backing.hmc_refs.push_back(hmc_ref);
    backing.page_layout.first_pbl_index = hmc_ref.first_pbl_index;
    expect_pre_cmq_reject("REJECT_HMC_KIND", control, mock_cmq,
                          binding, request, backing,
                          RDMA_SC_INVALID_ARGUMENT);

    request = make_register_mr_request("reject_hmc_index_request", binding,
                                       pd);
    backing = make_borrowed_pbl0_backing(
      "reject_hmc_index_backing", binding, request, RDMA_MR_PBL2
    );
    hmc_ref = make_borrowed_hmc_ref(
      "reject_hmc_index_ref", binding, hmc_address, lease_size, 28'h20
    );
    backing.hmc_refs.push_back(hmc_ref);
    backing.page_layout.first_pbl_index = hmc_ref.first_pbl_index + 1'b1;
    expect_pre_cmq_reject("REJECT_HMC_INDEX", control, mock_cmq,
                          binding, request, backing,
                          RDMA_SC_INVALID_ARGUMENT);

    request = make_register_mr_request("reject_hmc_width_request", binding,
                                       pd);
    backing = make_borrowed_pbl0_backing(
      "reject_hmc_width_backing", binding, request, RDMA_MR_PBL2
    );
    hmc_ref = make_borrowed_hmc_ref(
      "reject_hmc_width_ref", binding, hmc_address, lease_size,
      32'h1000_0000
    );
    backing.hmc_refs.push_back(hmc_ref);
    backing.page_layout.first_pbl_index = hmc_ref.first_pbl_index;
    expect_pre_cmq_reject("REJECT_HMC_INDEX_WIDTH", control, mock_cmq,
                          binding, request, backing,
                          RDMA_SC_INVALID_ARGUMENT);

    status = hmc.\release (binding.make_handle(), RDMA_RESOURCE_MR,
                           hmc_address);
    expect_status("REJECT_HMC_RELEASE", status, RDMA_SC_OK);
    request = make_register_mr_request("reject_hmc_active_request", binding,
                                       pd);
    backing = make_borrowed_pbl0_backing(
      "reject_hmc_active_backing", binding, request, RDMA_MR_PBL2
    );
    hmc_ref = make_borrowed_hmc_ref(
      "reject_hmc_active_ref", binding, hmc_address, lease_size, 28'h20
    );
    backing.hmc_refs.push_back(hmc_ref);
    backing.page_layout.first_pbl_index = hmc_ref.first_pbl_index;
    expect_pre_cmq_reject("REJECT_HMC_ACTIVE", control, mock_cmq,
                          binding, request, backing,
                          RDMA_SC_INVALID_STATE);

    if (mock_cmq.calls.size() != 0 || key_policy.call_count != 0)
      `uvm_error("REJECT_SIDE_EFFECTS",
                 "pre-CMQ rejection reached key derivation or hardware")
  endtask

  task automatic check_borrowed_pbl1_pbl2_registration();
    rdma_control_plane control;
    rdma_resource_manager manager;
    rdma_mock_cmq_port mock_cmq;
    rdma_mock_stag_key_policy key_policy;
    rdma_hmc_allocator hmc;
    rdma_function_binding binding;
    rdma_create_pd_req pd_request;
    rdma_register_mr_req request;
    rdma_mr_backing_desc backing;
    rdma_hmc_ref hmc_ref;
    rdma_hmc_fvm_addr_t hmc_base;
    rdma_hmc_fvm_addr_t hmc_address;
    rdma_pd pd;
    rdma_mr mr;
    rdma_mr registry_mr;
    rdma_resource resource;
    rdma_mrt_model mrt;
    rdma_control_result result;
    rdma_status status;
    longint unsigned lease_size;

    control = rdma_control_plane::type_id::create("pbl12_control");
    manager = rdma_resource_manager::type_id::create("pbl12_manager");
    mock_cmq = rdma_mock_cmq_port::type_id::create("pbl12_cmq");
    key_policy = rdma_mock_stag_key_policy::type_id::create("pbl12_policy");
    key_policy.fixed_key = 8'ha5;
    hmc = rdma_hmc_allocator::type_id::create("pbl12_hmc");
    hmc_base.value = 64'h0000_0004_1000_0000;
    status = hmc.configure(hmc_base, 64'h4000);
    expect_status("PBL12_HMC_CONFIGURE", status, RDMA_SC_OK);
    binding = make_active_binding(
      "pbl12_binding", 64'ha200_0000_0000_0001, 32'ha200_0101, 43
    );
    pd_request = make_create_pd_request("pbl12_pd_request", binding);
    status = control.configure(manager, mock_cmq, key_policy, null, hmc,
                               3us);
    expect_status("PBL12_CONFIGURE", status, RDMA_SC_OK);
    control.create_pd(binding, pd_request, pd, result);
    expect_result("PBL12_PD_CREATE", result, RDMA_SC_OK);
    if (pd == null || pd.handle == null)
      return;

    request = make_register_mr_request("pbl1_request", binding, pd);
    request.access = '{local_write:1'b1, remote_read:1'b0,
                       remote_write:1'b0, memory_window_bind:1'b0,
                       remote_atomic:1'b0};
    backing = make_borrowed_pbl0_backing(
      "pbl1_backing", binding, request, RDMA_MR_PBL1
    );
    control.register_mr(binding, request, backing, mr, result);
    expect_result("PBL1_REGISTER", result, RDMA_SC_OK);
    if (mr == null || mr.handle == null || mr.rkey != 0 ||
        mr.mr_serial != mr.handle.object_id[11:0] ||
        mr.backing_refs.size() != 2 || mr.hmc_refs.size() != 0 ||
        result == null || result.completed_steps.size() != 5 ||
        result.completed_steps[0] != RDMA_CTRL_STEP_RESOURCE_RESERVED ||
        result.completed_steps[1] != RDMA_CTRL_STEP_BACKING_ATTACHED ||
        result.completed_steps[2] != RDMA_CTRL_STEP_HW_KEY_ALLOCATED ||
        result.completed_steps[3] != RDMA_CTRL_STEP_REGISTRY_PROGRAMMED ||
        result.completed_steps[4] != RDMA_CTRL_STEP_REGISTRY_ACTIVE)
      `uvm_error("PBL1_RESULT",
                 "PBL1 registration lost keys, backing, or lifecycle steps")
    if (mock_cmq.calls.size() != 1 || mock_cmq.calls[0] == null ||
        mock_cmq.calls[0].command == null ||
        mock_cmq.calls[0].command.opcode_key == null ||
        mock_cmq.calls[0].command.opcode_key.profile_name != "xtr_v1" ||
        mock_cmq.calls[0].command.opcode_key.opcode !=
          XTR_V1_OP_KEY_ALLOC ||
        mock_cmq.calls[0].command.opcode_key.variant != "key_alloc" ||
        mock_cmq.calls[0].command.timeout != 3us ||
        !$cast(mrt, mock_cmq.calls[0].command.body) || mrt == null ||
        mrt.page_layout == null ||
        mrt.page_layout.pbl_mode != RDMA_MR_PBL1 ||
        mrt.page_layout.pba0 != backing.page_layout.pba0 ||
        mrt.page_layout.pba1 != backing.page_layout.pba1 ||
        mrt.page_layout.mr_serial != mr.mr_serial ||
        mrt.lkey != mr.lkey || mrt.rkey != mr.rkey)
      `uvm_error("PBL1_COMMAND",
                 "PBL1 KEY_ALLOC command projection is incomplete")
    if (mr != null && mr.handle != null) begin
      status = manager.lookup(mr.handle, resource);
      expect_status("PBL1_LOOKUP", status, RDMA_SC_OK);
      if (!$cast(registry_mr, resource) || registry_mr == null ||
          registry_mr == mr || registry_mr.handle == mr.handle ||
          !same_handle_fields(registry_mr.handle, mr.handle))
        `uvm_error("PBL1_SNAPSHOT",
                   "PBL1 output is not a detached ACTIVE snapshot")
    end

    request = make_register_mr_request("pbl2_request", binding, pd);
    request.iova.value += 64'h0001_0000;
    request.access = '{local_write:1'b0, remote_read:1'b0,
                       remote_write:1'b0, memory_window_bind:1'b0,
                       remote_atomic:1'b1};
    backing = make_borrowed_pbl0_backing(
      "pbl2_backing", binding, request, RDMA_MR_PBL2
    );
    status = hmc.allocate(binding.make_handle(), RDMA_RESOURCE_MR,
                          64'h1000, 64'h1000, hmc_address);
    expect_status("PBL2_HMC_ALLOCATE", status, RDMA_SC_OK);
    status = hmc.lookup(binding.make_handle(), RDMA_RESOURCE_MR,
                        hmc_address, lease_size);
    expect_status("PBL2_HMC_PRE_LOOKUP", status, RDMA_SC_OK);
    hmc_ref = rdma_hmc_ref::type_id::create("pbl2_hmc_ref");
    hmc_ref.owner = binding.make_handle();
    hmc_ref.object_kind = RDMA_RESOURCE_MR;
    hmc_ref.address = hmc_address;
    hmc_ref.size = lease_size;
    hmc_ref.first_pbl_index = 28'h012_3456;
    hmc_ref.ownership = RDMA_OWNERSHIP_BORROWED;
    hmc_ref.release_complete = 1'b0;
    backing.hmc_refs.push_back(hmc_ref);
    backing.page_layout.first_pbl_index = hmc_ref.first_pbl_index;

    control.register_mr(binding, request, backing, mr, result);
    expect_result("PBL2_REGISTER", result, RDMA_SC_OK);
    if (mr == null || mr.handle == null || mr.rkey != mr.lkey ||
        mr.backing_refs.size() != 1 || mr.hmc_refs.size() != 1 ||
        result == null || result.completed_steps.size() != 6 ||
        result.completed_steps[0] != RDMA_CTRL_STEP_RESOURCE_RESERVED ||
        result.completed_steps[1] != RDMA_CTRL_STEP_BACKING_ATTACHED ||
        result.completed_steps[2] != RDMA_CTRL_STEP_HMC_ATTACHED ||
        result.completed_steps[3] != RDMA_CTRL_STEP_HW_KEY_ALLOCATED ||
        result.completed_steps[4] != RDMA_CTRL_STEP_REGISTRY_PROGRAMMED ||
        result.completed_steps[5] != RDMA_CTRL_STEP_REGISTRY_ACTIVE)
      `uvm_error("PBL2_RESULT",
                 "PBL2 registration lost key, backing, HMC, or steps")
    if (mock_cmq.calls.size() != 2 || mock_cmq.calls[1] == null ||
        mock_cmq.calls[1].opcode != XTR_V1_OP_KEY_ALLOC ||
        !$cast(mrt, mock_cmq.calls[1].command.body) || mrt == null ||
        mrt.page_layout == null ||
        mrt.page_layout.pbl_mode != RDMA_MR_PBL2 ||
        mrt.page_layout.first_pbl_index != hmc_ref.first_pbl_index ||
        mrt.mr_h == null || mrt.pd_h == null ||
        mrt.mr_h.object_id != mr.local_mr_id[23:0] ||
        mrt.pd_h.object_id != pd.local_pd_id[15:0] ||
        mr.handle.object_id[31:28] != RDMA_RESOURCE_MR)
      `uvm_error("PBL2_COMMAND",
                 "PBL2 KEY_ALLOC command projection is incomplete")
    status = hmc.lookup(binding.make_handle(), RDMA_RESOURCE_MR,
                        hmc_address, lease_size);
    expect_status("PBL2_HMC_POST_LOOKUP", status, RDMA_SC_OK);
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
    check_borrowed_pbl0_registration();
    check_key_alloc_explicit_failure();
    check_key_alloc_timeout_recovery();
    check_borrowed_pbl1_pbl2_registration();
    check_register_mr_pre_cmq_rejections();
    check_post_activate_snapshot_cleanup();
    check_post_lock_revalidation();
    check_register_mr_post_lock_revalidation();
    check_transaction_id_exhaustion();
    phase.drop_objection(this);
  endtask
endclass
