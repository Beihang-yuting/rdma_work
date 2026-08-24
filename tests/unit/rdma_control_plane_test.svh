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

class rdma_blocking_mock_cmq_port extends rdma_mock_cmq_port;
  `uvm_object_utils(rdma_blocking_mock_cmq_port)

  semaphore entered;
  semaphore resume;

  function new(string name = "rdma_blocking_mock_cmq_port");
    super.new(name);
    entered = new(0);
    resume = new(0);
  endfunction

  virtual task execute(
    rdma_cmq_command_desc command,
    output rdma_cmq_ticket ticket,
    output rdma_cmq_completion completion,
    output rdma_status status
  );
    entered.put(1);
    resume.get(1);
    super.execute(command, ticket, completion, status);
  endtask

  task wait_until_entered(time timeout, output bit observed);
    observed = 1'b0;
    fork : wait_for_blocked_execute
      begin
        entered.get(1);
        observed = 1'b1;
      end
      begin
        #(timeout);
      end
    join_any
    disable wait_for_blocked_execute;
  endtask

  task resume_execute();
    resume.put(1);
  endtask

endclass

class rdma_recovery_probe_manager extends rdma_resource_manager;
  `uvm_object_utils(rdma_recovery_probe_manager)

  function new(string name = "rdma_recovery_probe_manager");
    super.new(name);
  endfunction

  function rdma_status peek_resource(
    rdma_handle handle,
    output rdma_resource resource
  );
    string key;

    resource = null;
    if (handle == null)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "probe resource handle is null");
    key = resource_key(handle);
    if (!registry.exists(key))
      return rdma_status::make(RDMA_SC_INVALID_STATE,
                               "probe resource is absent");
    return project_resource_value(registry[key], "probe resource", resource);
  endfunction

  function rdma_status peek_recovery(
    rdma_handle handle,
    output rdma_recovery_record recovery
  );
    string key;

    recovery = null;
    if (handle == null)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "probe recovery handle is null");
    key = resource_key(handle);
    if (!recovery_records.exists(key))
      return rdma_status::make(RDMA_SC_INVALID_STATE,
                               "probe recovery is absent");
    return project_recovery_value(recovery_records[key], "probe recovery",
                                  recovery);
  endfunction

endclass

class rdma_fault_resource_manager extends rdma_recovery_probe_manager;
  `uvm_object_utils(rdma_fault_resource_manager)

  int unsigned release_reserved_calls;
  int unsigned mark_error_calls;
  protected rdma_status next_release_failure;
  protected rdma_status next_mark_error_failure;

  function new(string name = "rdma_fault_resource_manager");
    super.new(name);
    release_reserved_calls = 0;
    mark_error_calls = 0;
    next_release_failure = null;
    next_mark_error_failure = null;
  endfunction

  function void fail_next_release_reserved(rdma_status failure);
    next_release_failure = rdma_cmq_clone_status_value(failure);
  endfunction

  function void fail_next_mark_error(rdma_status failure);
    next_mark_error_failure = rdma_cmq_clone_status_value(failure);
  endfunction

  virtual function rdma_status release_reserved(rdma_handle handle);
    rdma_status failure;

    release_reserved_calls++;
    if (next_release_failure != null) begin
      failure = rdma_cmq_clone_status_value(next_release_failure);
      next_release_failure = null;
      return failure;
    end
    return super.release_reserved(handle);
  endfunction

  virtual function rdma_status mark_error(
    rdma_handle handle,
    rdma_recovery_record recovery
  );
    rdma_status failure;

    mark_error_calls++;
    if (next_mark_error_failure != null) begin
      failure = rdma_cmq_clone_status_value(next_mark_error_failure);
      next_mark_error_failure = null;
      return failure;
    end
    return super.mark_error(handle, recovery);
  endfunction

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

  function automatic void expect_recovery_fallback(
    string check_name,
    rdma_control_result result,
    rdma_status_code_e expected_primary_code
  );
    rdma_status validation_status;

    if (result == null) begin
      `uvm_error(check_name, "control-plane recovery fallback is null")
      return;
    end
    expect_status({check_name, "_STATUS"}, result.status,
                  RDMA_SC_RECOVERY_REQUIRED);
    expect_status({check_name, "_PRIMARY"}, result.primary_status,
                  expected_primary_code);
    if (result.status == result.primary_status)
      `uvm_error(check_name, "fallback status and primary status are aliased")
    if (result.transaction_id == 0)
      `uvm_error(check_name, "fallback result has a zero transaction ID")
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

  function automatic rdma_dma_request_context make_dma_context(
    string name,
    rdma_function_binding binding
  );
    rdma_dma_request_context dma_context;

    dma_context = rdma_dma_request_context::type_id::create(name);
    dma_context.function_h = binding.make_handle();
    dma_context.requester_bdf = binding.pcie.bdf;
    dma_context.pasid_valid = 1'b1;
    dma_context.pasid = 20'h5a123;
    dma_context.owner_h = null;
    return dma_context;
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

  function automatic void expect_cmq_opcodes(
    string check_name,
    rdma_mock_cmq_port mock_cmq,
    input bit [7:0] expected[$]
  );
    bit [7:0] actual[$];

    if (mock_cmq == null) begin
      `uvm_error(check_name, "mock CMQ is null")
      return;
    end
    mock_cmq.get_opcodes(actual);
    if (actual != expected)
      `uvm_error(check_name,
                 $sformatf("unexpected CMQ opcode sequence: %p", actual))
  endfunction

  task automatic setup_owned_mr_case(
    string prefix,
    bit inject_host_mem,
    output rdma_control_plane control,
    output rdma_fault_inject_resource_manager manager,
    output rdma_mock_cmq_port mock_cmq,
    output rdma_mock_stag_key_policy key_policy,
    output rdma_mock_host_mem host_mem,
    output rdma_function_binding binding,
    output rdma_register_mr_req request,
    output rdma_dma_request_context dma_context,
    output rdma_pd pd,
    output int unsigned baseline_allocations,
    output int unsigned baseline_leaks
  );
    rdma_create_pd_req pd_request;
    rdma_control_result result;
    rdma_status status;

    control = rdma_control_plane::type_id::create({prefix, "_control"});
    manager = rdma_fault_inject_resource_manager::type_id::create(
      {prefix, "_manager"}
    );
    mock_cmq = rdma_mock_cmq_port::type_id::create({prefix, "_cmq"});
    key_policy = rdma_mock_stag_key_policy::type_id::create(
      {prefix, "_policy"}
    );
    key_policy.fixed_key = 8'h7c;
    host_mem = rdma_mock_host_mem::type_id::create({prefix, "_host_mem"});
    binding = make_active_binding(
      {prefix, "_binding"}, 64'ha150_0000_0000_0001,
      32'ha150_0101, 43
    );
    status = control.configure(
      manager, mock_cmq, key_policy,
      inject_host_mem ? host_mem : null, null, 2us
    );
    expect_status({prefix, "_CONFIGURE"}, status, RDMA_SC_OK);
    pd_request = make_create_pd_request({prefix, "_pd_request"}, binding);
    control.create_pd(binding, pd_request, pd, result);
    expect_result({prefix, "_PD_CREATE"}, result, RDMA_SC_OK);
    request = make_register_mr_request({prefix, "_request"}, binding, pd);
    // The current allocation API cannot request a desired IOVA.  The caller's
    // MR IOVA therefore remains authoritative and must be covered by the
    // mapping selected by the allocator; this mock chooses that address next.
    request.iova.value = host_mem.next_address;
    dma_context = make_dma_context({prefix, "_dma_context"}, binding);
    baseline_allocations = host_mem.live_allocations();
    void'(manager.check_leaks(baseline_leaks, binding.make_handle()));
  endtask

  task automatic expect_owned_preallocate_reject(
    string check_name,
    rdma_control_plane control,
    rdma_fault_inject_resource_manager manager,
    rdma_mock_cmq_port mock_cmq,
    rdma_mock_host_mem host_mem,
    rdma_function_binding binding,
    rdma_register_mr_req request,
    rdma_dma_request_context dma_context,
    int unsigned alignment,
    rdma_status_code_e expected_code,
    int unsigned baseline_allocations,
    int unsigned baseline_leaks
  );
    rdma_dma_mapping mapping;
    rdma_mr mr;
    rdma_control_result result;
    int unsigned final_leaks;
    bit [7:0] expected_opcodes[$];

    control.alloc_and_register_mr(binding, request, dma_context, alignment,
                                  mapping, mr, result);
    expect_result(check_name, result, expected_code);
    expect_cmq_opcodes({check_name, "_OPCODES"}, mock_cmq,
                       expected_opcodes);
    void'(manager.check_leaks(final_leaks, binding.make_handle()));
    if (mapping != null || mr != null ||
        host_mem.calls.size() != 0 ||
        host_mem.live_allocations() != baseline_allocations ||
        final_leaks != baseline_leaks || result == null ||
        result.resource_h != null || result.final_resource_state_known ||
        result.final_resource_state != RDMA_RESOURCE_NEW)
      `uvm_error(check_name,
                 "pre-allocation rejection changed owned resource state")
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

  task automatic check_mock_typed_body_snapshot();
    rdma_mock_cmq_port mock_cmq;
    rdma_function_binding binding;
    rdma_cmq_command_desc command;
    rdma_cmq_opcode_key opcode_key;
    rdma_xtr_v1_mr_deregister_body body;
    rdma_xtr_v1_mr_deregister_body snapshot_body;
    rdma_cmq_ticket ticket;
    rdma_cmq_completion completion;
    rdma_status status;

    mock_cmq = rdma_mock_cmq_port::type_id::create("typed_snapshot_cmq");
    binding = make_active_binding(
      "typed_snapshot_binding", 64'ha050_0000_0000_0001,
      32'ha050_0101, 37
    );
    body = rdma_xtr_v1_mr_deregister_body::type_id::create(
      "typed_snapshot_body"
    );
    body.mr_h = new("typed_snapshot_mr");
    body.mr_h.kind = RDMA_RESOURCE_MR;
    body.mr_h.function_uid = binding.function_uid;
    body.mr_h.object_id = 24'h65_4321;
    body.mr_h.generation = binding.generation;
    body.stag_key = 8'hd3;
    body.next_state = RDMA_CONTEXT_INVALID;
    opcode_key = rdma_cmq_opcode_key::type_id::create(
      "typed_snapshot_opcode"
    );
    opcode_key.profile_name = "xtr_v1";
    opcode_key.opcode = XTR_V1_OP_MR_DEREGISTER;
    opcode_key.variant = "deregister";
    command = rdma_cmq_command_desc::type_id::create(
      "typed_snapshot_command"
    );
    command.function_h = binding.make_handle();
    command.opcode_key = opcode_key;
    command.body = body;
    command.timeout = 1us;

    mock_cmq.execute(command, ticket, completion, status);
    expect_status("TYPED_SNAPSHOT_EXECUTE", status, RDMA_SC_OK);
    snapshot_body = null;
    if (mock_cmq.calls.size() != 1 || mock_cmq.calls[0] == null ||
        mock_cmq.calls[0].command == null ||
        !$cast(snapshot_body, mock_cmq.calls[0].command.body) ||
        snapshot_body == null || snapshot_body == body ||
        snapshot_body.mr_h == null || snapshot_body.mr_h == body.mr_h ||
        !same_handle_fields(snapshot_body.mr_h, body.mr_h) ||
        snapshot_body.stag_key != body.stag_key ||
        snapshot_body.next_state != body.next_state)
      `uvm_error("TYPED_SNAPSHOT_DETACHED",
                 "mock CMQ did not retain a detached typed-body snapshot")
  endtask

  task automatic check_owned_mr_validation();
    rdma_control_plane control;
    rdma_fault_inject_resource_manager manager;
    rdma_mock_cmq_port mock_cmq;
    rdma_mock_stag_key_policy key_policy;
    rdma_mock_host_mem host_mem;
    rdma_function_binding binding;
    rdma_function_binding wrong_binding;
    rdma_register_mr_req request;
    rdma_dma_request_context dma_context;
    rdma_pd pd;
    rdma_function_handle saved_function;
    rdma_bdf_t saved_bdf;
    longint unsigned saved_length;
    int unsigned baseline_allocations;
    int unsigned baseline_leaks;

    setup_owned_mr_case(
      "owned_validate", 1'b1, control, manager, mock_cmq, key_policy,
      host_mem, binding, request, dma_context, pd, baseline_allocations,
      baseline_leaks
    );
    if (pd == null)
      return;

    expect_owned_preallocate_reject(
      "OWNED_NULL_CONTEXT", control, manager, mock_cmq, host_mem, binding,
      request, null, 4096, RDMA_SC_INVALID_ARGUMENT,
      baseline_allocations, baseline_leaks
    );

    wrong_binding = make_active_binding(
      "owned_wrong_binding", 64'ha151_0000_0000_0001,
      32'ha151_0101, binding.generation
    );
    saved_function = dma_context.function_h;
    dma_context.function_h = wrong_binding.make_handle();
    expect_owned_preallocate_reject(
      "OWNED_FUNCTION_MISMATCH", control, manager, mock_cmq, host_mem,
      binding, request, dma_context, 4096, RDMA_SC_INVALID_ARGUMENT,
      baseline_allocations, baseline_leaks
    );
    dma_context.function_h = saved_function;

    saved_bdf = dma_context.requester_bdf;
    dma_context.requester_bdf.function_num ^= 3'h1;
    expect_owned_preallocate_reject(
      "OWNED_BDF_MISMATCH", control, manager, mock_cmq, host_mem, binding,
      request, dma_context, 4096, RDMA_SC_DMA_TRANSLATION,
      baseline_allocations, baseline_leaks
    );
    dma_context.requester_bdf = saved_bdf;

    dma_context.owner_h = rdma_clone_handle_value(
      request.pd_h, "owned validation DMA owner"
    );
    expect_owned_preallocate_reject(
      "OWNED_NON_NULL_OWNER", control, manager, mock_cmq, host_mem, binding,
      request, dma_context, 4096, RDMA_SC_INVALID_ARGUMENT,
      baseline_allocations, baseline_leaks
    );
    dma_context.owner_h = null;

    expect_owned_preallocate_reject(
      "OWNED_SMALL_ALIGNMENT", control, manager, mock_cmq, host_mem,
      binding, request, dma_context, 2048, RDMA_SC_INVALID_ARGUMENT,
      baseline_allocations, baseline_leaks
    );
    expect_owned_preallocate_reject(
      "OWNED_NON_POWER_ALIGNMENT", control, manager, mock_cmq, host_mem,
      binding, request, dma_context, 6144, RDMA_SC_INVALID_ARGUMENT,
      baseline_allocations, baseline_leaks
    );

    request.access.remote_atomic = 1'b1;
    expect_owned_preallocate_reject(
      "OWNED_REMOTE_ATOMIC", control, manager, mock_cmq, host_mem, binding,
      request, dma_context, 4096, RDMA_SC_UNSUPPORTED_OPCODE,
      baseline_allocations, baseline_leaks
    );
    request.access.remote_atomic = 1'b0;

    saved_length = request.length;
    request.length = 64'h0000_0001_0000_0000;
    expect_owned_preallocate_reject(
      "OWNED_LENGTH_TOO_LARGE", control, manager, mock_cmq, host_mem,
      binding, request, dma_context, 4096, RDMA_SC_INVALID_ARGUMENT,
      baseline_allocations, baseline_leaks
    );
    request.length = saved_length;

    setup_owned_mr_case(
      "owned_no_host", 1'b0, control, manager, mock_cmq, key_policy,
      host_mem, binding, request, dma_context, pd, baseline_allocations,
      baseline_leaks
    );
    if (pd == null)
      return;
    expect_owned_preallocate_reject(
      "OWNED_NO_HOST_MEM", control, manager, mock_cmq, host_mem, binding,
      request, dma_context, 4096, RDMA_SC_INVALID_STATE,
      baseline_allocations, baseline_leaks
    );
  endtask

  task automatic run_owned_mr_failure(string failure_kind);
    rdma_control_plane control;
    rdma_fault_inject_resource_manager manager;
    rdma_mock_cmq_port mock_cmq;
    rdma_mock_stag_key_policy key_policy;
    rdma_mock_host_mem host_mem;
    rdma_function_binding binding;
    rdma_register_mr_req request;
    rdma_dma_request_context dma_context;
    rdma_pd pd;
    rdma_dma_mapping mapping;
    rdma_mr mr;
    rdma_control_result result;
    rdma_mrt_model key_alloc_body;
    rdma_xtr_v1_mr_deregister_body dereg_body;
    rdma_recovery_record recovery;
    rdma_status injected_status;
    rdma_status status;
    rdma_status_code_e expected_primary;
    rdma_resource_state_e expected_state;
    int unsigned baseline_allocations;
    int unsigned baseline_leaks;
    int unsigned final_leaks;
    int unsigned release_calls;
    bit [7:0] expected_opcodes[$];
    bit rollback_failure;

    setup_owned_mr_case(
      {"owned_", failure_kind}, 1'b1, control, manager, mock_cmq,
      key_policy, host_mem, binding, request, dma_context, pd,
      baseline_allocations, baseline_leaks
    );
    if (pd == null)
      return;
    rollback_failure = 1'b0;
    expected_primary = RDMA_SC_INVALID_STATE;
    expected_state = RDMA_RESOURCE_RELEASED;
    case (failure_kind)
      "allocate": begin
        injected_status = rdma_status::make(
          RDMA_SC_RESOURCE_EXHAUSTED, "injected owned allocation failure"
        );
        status = host_mem.fail_next("allocate", injected_status);
        expect_status("OWNED_ALLOCATE_INJECT", status, RDMA_SC_OK);
        expected_primary = RDMA_SC_RESOURCE_EXHAUSTED;
        expected_state = RDMA_RESOURCE_NEW;
      end
      "key_alloc": begin
        injected_status = rdma_status::make(
          RDMA_SC_UNKNOWN_HW_ERROR, "injected owned KEY_ALLOC failure"
        );
        mock_cmq.fail_opcode(XTR_V1_OP_KEY_ALLOC, injected_status);
        expected_primary = RDMA_SC_UNKNOWN_HW_ERROR;
        expected_opcodes.push_back(XTR_V1_OP_KEY_ALLOC);
      end
      "commit_programmed": begin
        injected_status = rdma_status::make(
          RDMA_SC_INVALID_STATE, "injected owned commit failure"
        );
        status = manager.fail_next_transition(
          "commit_programmed", injected_status
        );
        expect_status("OWNED_COMMIT_INJECT", status, RDMA_SC_OK);
        expected_opcodes.push_back(XTR_V1_OP_KEY_ALLOC);
        expected_opcodes.push_back(XTR_V1_OP_MR_DEREGISTER);
      end
      "activate": begin
        injected_status = rdma_status::make(
          RDMA_SC_INVALID_STATE, "injected owned activate failure"
        );
        status = manager.fail_next_transition("activate", injected_status);
        expect_status("OWNED_ACTIVATE_INJECT", status, RDMA_SC_OK);
        expected_opcodes.push_back(XTR_V1_OP_KEY_ALLOC);
        expected_opcodes.push_back(XTR_V1_OP_MR_DEREGISTER);
      end
      "deregister": begin
        injected_status = rdma_status::make(
          RDMA_SC_INVALID_STATE,
          "injected commit before owned deregister failure"
        );
        status = manager.fail_next_transition(
          "commit_programmed", injected_status
        );
        expect_status("OWNED_DEREG_COMMIT_INJECT", status, RDMA_SC_OK);
        injected_status = rdma_status::make(
          RDMA_SC_UNKNOWN_HW_ERROR, "injected owned deregister failure"
        );
        mock_cmq.fail_opcode(XTR_V1_OP_MR_DEREGISTER, injected_status);
        expected_opcodes.push_back(XTR_V1_OP_KEY_ALLOC);
        expected_opcodes.push_back(XTR_V1_OP_MR_DEREGISTER);
        rollback_failure = 1'b1;
        expected_state = RDMA_RESOURCE_ERROR;
      end
      default:
        `uvm_fatal("OWNED_FAILURE_KIND", "unknown owned failure case")
    endcase

    control.alloc_and_register_mr(binding, request, dma_context, 4096,
                                  mapping, mr, result);
    if (rollback_failure)
      expect_recovery_result({"OWNED_", failure_kind}, result,
                             expected_primary);
    else
      expect_result({"OWNED_", failure_kind}, result, expected_primary);
    expect_cmq_opcodes({"OWNED_", failure_kind, "_OPCODES"}, mock_cmq,
                       expected_opcodes);
    void'(manager.check_leaks(final_leaks, binding.make_handle()));
    release_calls = 0;
    foreach (host_mem.calls[i])
      if (host_mem.calls[i] != null &&
          host_mem.calls[i].method_name == "release")
        release_calls++;

    if (failure_kind == "allocate") begin
      if (host_mem.live_allocations() != baseline_allocations ||
          final_leaks != baseline_leaks || result == null ||
          result.resource_h != null || result.final_resource_state_known ||
          result.final_resource_state != RDMA_RESOURCE_NEW ||
          release_calls != 0 || mapping != null || mr != null)
        `uvm_error("OWNED_ALLOCATE_STATE",
                   "allocation failure changed owned resource state")
    end
    else if (rollback_failure) begin
      recovery = null;
      if (result != null && result.resource_h != null)
        status = manager.lookup_recovery(result.resource_h, recovery);
      else
        status = null;
      expect_status("OWNED_DEREG_RECOVERY_LOOKUP", status, RDMA_SC_OK);
      if (host_mem.live_allocations() != baseline_allocations + 1 ||
          final_leaks != baseline_leaks + 1 || release_calls != 0 ||
          result == null || !result.final_resource_state_known ||
          result.final_resource_state != RDMA_RESOURCE_ERROR ||
          result.rollback_statuses.size() != 1 ||
          result.rollback_statuses[0] == null ||
          result.rollback_statuses[0].code != RDMA_SC_UNKNOWN_HW_ERROR ||
          mr == null || mr.state != RDMA_RESOURCE_ERROR ||
          recovery == null ||
          recovery.hardware_presence != RDMA_HW_PRESENCE_PRESENT ||
          recovery.pending_steps.size() != 1 ||
          recovery.pending_steps[0] != RDMA_CTRL_STEP_HW_MR_DEREGISTERED)
        `uvm_error("OWNED_DEREG_RECOVERY",
                   "rollback failure did not retain one owned ERROR MR")
    end
    else if (host_mem.live_allocations() != baseline_allocations ||
             final_leaks != baseline_leaks || release_calls != 1 ||
             result == null || !result.final_resource_state_known ||
             result.final_resource_state != expected_state ||
             result.recovery_required ||
             result.rollback_statuses.size() != 0 || mr != null)
      `uvm_error({"OWNED_", failure_kind, "_STATE"},
                 "complete rollback did not restore owned baselines")

    if (expected_opcodes.size() == 2) begin
      key_alloc_body = null;
      dereg_body = null;
      if (mock_cmq.calls[0] == null ||
          mock_cmq.calls[0].command == null ||
          !$cast(key_alloc_body, mock_cmq.calls[0].command.body) ||
          key_alloc_body == null || key_alloc_body.mr_h == null ||
          mock_cmq.calls[1] == null ||
          mock_cmq.calls[1].command == null ||
          mock_cmq.calls[1].command.opcode_key == null ||
          mock_cmq.calls[1].command.opcode_key.profile_name != "xtr_v1" ||
          mock_cmq.calls[1].command.opcode_key.variant != "deregister" ||
          !$cast(dereg_body, mock_cmq.calls[1].command.body) ||
          dereg_body == null || dereg_body.mr_h == null ||
          dereg_body.mr_h.kind != RDMA_RESOURCE_MR ||
          dereg_body.mr_h.function_uid != binding.function_uid ||
          dereg_body.mr_h.generation != binding.generation ||
          dereg_body.mr_h.object_id != key_alloc_body.mr_h.object_id ||
          dereg_body.stag_key != key_policy.fixed_key ||
          dereg_body.next_state != RDMA_CONTEXT_INVALID)
        `uvm_error({"OWNED_", failure_kind, "_DEREG_BODY"},
                   "rollback MR_DEREGISTER command is malformed")
    end
  endtask

  task automatic check_owned_mr_unattached_release_failure();
    rdma_control_plane control;
    rdma_fault_inject_resource_manager manager;
    rdma_mock_cmq_port mock_cmq;
    rdma_mock_stag_key_policy key_policy;
    rdma_mock_host_mem host_mem;
    rdma_function_binding binding;
    rdma_register_mr_req request;
    rdma_dma_request_context dma_context;
    rdma_pd pd;
    rdma_dma_mapping mapping;
    rdma_mr mr;
    rdma_control_result result;
    rdma_status injected_status;
    rdma_status status;
    int unsigned baseline_allocations;
    int unsigned baseline_leaks;
    int unsigned final_leaks;
    int unsigned release_calls;
    bit [7:0] expected_opcodes[$];

    setup_owned_mr_case(
      "owned_unattached_release", 1'b1, control, manager, mock_cmq,
      key_policy, host_mem, binding, request, dma_context, pd,
      baseline_allocations, baseline_leaks
    );
    if (pd == null)
      return;

    // Keep the request valid while placing it outside the mapping returned by
    // the host-memory adapter.  Inner registration then fails before create_mr
    // can publish a registry resource.
    request.iova.value += request.length + 4096;
    injected_status = rdma_status::make(
      RDMA_SC_UNKNOWN_HW_ERROR, "injected unattached mapping release failure"
    );
    status = host_mem.fail_next("release", injected_status);
    expect_status("OWNED_UNATTACHED_RELEASE_INJECT", status, RDMA_SC_OK);

    control.alloc_and_register_mr(binding, request, dma_context, 4096,
                                  mapping, mr, result);
    expect_recovery_fallback("OWNED_UNATTACHED_RELEASE", result,
                             RDMA_SC_DMA_TRANSLATION);
    expect_cmq_opcodes("OWNED_UNATTACHED_RELEASE_OPCODES", mock_cmq,
                       expected_opcodes);
    void'(manager.check_leaks(final_leaks, binding.make_handle()));
    release_calls = 0;
    foreach (host_mem.calls[i])
      if (host_mem.calls[i] != null &&
          host_mem.calls[i].method_name == "release")
        release_calls++;

    if (result == null || result.resource_h != null ||
        result.recovery_required || result.final_resource_state_known ||
        result.final_resource_state != RDMA_RESOURCE_NEW ||
        result.rollback_statuses.size() != 1 ||
        result.rollback_statuses[0] == null ||
        result.rollback_statuses[0].code != RDMA_SC_UNKNOWN_HW_ERROR ||
        mapping == null || mapping.state != RDMA_MAPPING_ACTIVE || mr != null ||
        host_mem.live_allocations() != baseline_allocations + 1 ||
        final_leaks != baseline_leaks || release_calls != 1)
      `uvm_error(
        "OWNED_UNATTACHED_RELEASE_STATE",
        "failed unattached cleanup did not return caller-operable authority"
      )

    if (mapping != null) begin
      status = host_mem.\release (mapping);
      expect_status("OWNED_UNATTACHED_RELEASE_CALLER_CLEANUP", status,
                    RDMA_SC_OK);
      if (host_mem.live_allocations() != baseline_allocations)
        `uvm_error("OWNED_UNATTACHED_RELEASE_CALLER_STATE",
                   "caller could not release returned mapping authority")
    end
  endtask

  task automatic check_owned_mr_prestage_release_failure();
    rdma_control_plane control;
    rdma_fault_inject_resource_manager manager;
    rdma_mock_cmq_port mock_cmq;
    rdma_mock_stag_key_policy key_policy;
    rdma_mock_host_mem host_mem;
    rdma_function_binding binding;
    rdma_register_mr_req request;
    rdma_dma_request_context dma_context;
    rdma_pd pd;
    rdma_dma_mapping mapping;
    rdma_mr mr;
    rdma_resource registry_resource;
    rdma_mr registry_mr;
    rdma_recovery_record recovery;
    rdma_control_result result;
    rdma_status injected_status;
    rdma_status status;
    int unsigned baseline_allocations;
    int unsigned baseline_leaks;
    int unsigned final_leaks;
    int unsigned release_calls;
    bit [7:0] expected_opcodes[$];

    setup_owned_mr_case(
      "owned_prestage_release", 1'b1, control, manager, mock_cmq,
      key_policy, host_mem, binding, request, dma_context, pd,
      baseline_allocations, baseline_leaks
    );
    if (pd == null)
      return;

    injected_status = rdma_status::make(
      RDMA_SC_INVALID_STATE, "injected owned STAG derivation failure"
    );
    status = key_policy.fail_next(injected_status);
    expect_status("OWNED_PRESTAGE_KEY_INJECT", status, RDMA_SC_OK);
    injected_status = rdma_status::make(
      RDMA_SC_UNKNOWN_HW_ERROR, "injected pre-stage mapping release failure"
    );
    status = host_mem.fail_next("release", injected_status);
    expect_status("OWNED_PRESTAGE_RELEASE_INJECT", status, RDMA_SC_OK);

    control.alloc_and_register_mr(binding, request, dma_context, 4096,
                                  mapping, mr, result);
    expect_recovery_fallback("OWNED_PRESTAGE_RELEASE", result,
                             RDMA_SC_INVALID_STATE);
    expect_cmq_opcodes("OWNED_PRESTAGE_RELEASE_OPCODES", mock_cmq,
                       expected_opcodes);
    registry_resource = null;
    recovery = null;
    if (result != null && result.resource_h != null) begin
      status = manager.lookup(result.resource_h, registry_resource);
      expect_status("OWNED_PRESTAGE_RESOURCE_LOOKUP", status, RDMA_SC_OK);
      status = manager.lookup_recovery(result.resource_h, recovery);
      expect_status("OWNED_PRESTAGE_RECOVERY_ABSENT", status,
                    RDMA_SC_INVALID_STATE);
    end
    else begin
      `uvm_error("OWNED_PRESTAGE_RESOURCE_HANDLE",
                 "pre-stage fallback lost the reserved MR handle")
    end
    registry_mr = null;
    void'($cast(registry_mr, registry_resource));
    void'(manager.check_leaks(final_leaks, binding.make_handle()));
    release_calls = 0;
    foreach (host_mem.calls[i])
      if (host_mem.calls[i] != null &&
          host_mem.calls[i].method_name == "release")
        release_calls++;

    if (result == null || result.resource_h == null ||
        !result.final_resource_state_known ||
        result.final_resource_state != RDMA_RESOURCE_ALLOCATED ||
        result.recovery_required || result.rollback_statuses.size() != 2 ||
        result.rollback_statuses[0] == null ||
        result.rollback_statuses[0].code != RDMA_SC_UNKNOWN_HW_ERROR ||
        result.rollback_statuses[1] == null ||
        result.rollback_statuses[1].code != RDMA_SC_INVALID_STATE ||
        mapping == null || mapping.state != RDMA_MAPPING_ACTIVE || mr != null ||
        registry_mr == null || registry_mr.handle == null ||
        registry_mr.state != RDMA_RESOURCE_ALLOCATED ||
        !same_handle_fields(result.resource_h, registry_mr.handle) ||
        recovery != null ||
        host_mem.live_allocations() != baseline_allocations + 1 ||
        final_leaks != baseline_leaks + 1 || release_calls != 1)
      `uvm_error(
        "OWNED_PRESTAGE_RELEASE_STATE",
        "pre-stage rollback fallback lost mapping or reservation authority"
      )

    if (mapping != null) begin
      status = host_mem.\release (mapping);
      expect_status("OWNED_PRESTAGE_CALLER_RELEASE", status, RDMA_SC_OK);
    end
    release_calls = 0;
    foreach (host_mem.calls[i])
      if (host_mem.calls[i] != null &&
          host_mem.calls[i].method_name == "release")
        release_calls++;
    void'(manager.check_leaks(final_leaks, binding.make_handle()));
    if (mapping == null || mapping.state != RDMA_MAPPING_RELEASED ||
        host_mem.live_allocations() != baseline_allocations ||
        final_leaks != baseline_leaks + 1 || release_calls != 2)
      `uvm_error("OWNED_PRESTAGE_CALLER_STATE",
                 "caller release retried or changed the retained reservation")
  endtask

  task automatic check_owned_mr_timeout_freeze_failure_no_mapping();
    rdma_control_plane control;
    rdma_fault_inject_resource_manager manager;
    rdma_mock_cmq_port mock_cmq;
    rdma_mock_stag_key_policy key_policy;
    rdma_mock_host_mem host_mem;
    rdma_function_binding binding;
    rdma_register_mr_req request;
    rdma_dma_request_context dma_context;
    rdma_pd pd;
    rdma_dma_mapping mapping;
    rdma_mr mr;
    rdma_resource registry_resource;
    rdma_mr registry_mr;
    rdma_recovery_record recovery;
    rdma_control_result result;
    rdma_status injected_status;
    rdma_status status;
    int unsigned baseline_allocations;
    int unsigned baseline_leaks;
    int unsigned final_leaks;
    int unsigned release_calls;
    bit [7:0] expected_opcodes[$];

    setup_owned_mr_case(
      "owned_timeout_freeze", 1'b1, control, manager, mock_cmq,
      key_policy, host_mem, binding, request, dma_context, pd,
      baseline_allocations, baseline_leaks
    );
    if (pd == null)
      return;

    injected_status = rdma_status::make(
      RDMA_SC_RESOURCE_BUSY, "injected timeout recovery publication failure"
    );
    status = manager.fail_next_transition("mark_error", injected_status);
    expect_status("OWNED_TIMEOUT_FREEZE_INJECT", status, RDMA_SC_OK);
    mock_cmq.timeout_opcode(XTR_V1_OP_KEY_ALLOC);
    expected_opcodes.push_back(XTR_V1_OP_KEY_ALLOC);

    control.alloc_and_register_mr(binding, request, dma_context, 4096,
                                  mapping, mr, result);
    expect_recovery_fallback("OWNED_TIMEOUT_FREEZE", result,
                             RDMA_SC_TIMEOUT);
    expect_cmq_opcodes("OWNED_TIMEOUT_FREEZE_OPCODES", mock_cmq,
                       expected_opcodes);
    registry_resource = null;
    recovery = null;
    if (result != null && result.resource_h != null) begin
      status = manager.lookup(result.resource_h, registry_resource);
      expect_status("OWNED_TIMEOUT_FREEZE_LOOKUP", status, RDMA_SC_OK);
      status = manager.lookup_recovery(result.resource_h, recovery);
      expect_status("OWNED_TIMEOUT_FREEZE_RECOVERY_ABSENT", status,
                    RDMA_SC_INVALID_STATE);
    end
    registry_mr = null;
    void'($cast(registry_mr, registry_resource));
    void'(manager.check_leaks(final_leaks, binding.make_handle()));
    release_calls = 0;
    foreach (host_mem.calls[i])
      if (host_mem.calls[i] != null &&
          host_mem.calls[i].method_name == "release")
        release_calls++;

    if (result == null || result.resource_h == null ||
        !result.final_resource_state_known ||
        result.final_resource_state != RDMA_RESOURCE_ALLOCATED ||
        result.recovery_required || result.rollback_statuses.size() != 1 ||
        result.rollback_statuses[0] == null ||
        result.rollback_statuses[0].code != RDMA_SC_RESOURCE_BUSY ||
        mapping != null || mr != null || registry_mr == null ||
        registry_mr.state != RDMA_RESOURCE_ALLOCATED || recovery != null ||
        host_mem.live_allocations() != baseline_allocations + 1 ||
        final_leaks != baseline_leaks + 1 || release_calls != 0)
      `uvm_error(
        "OWNED_TIMEOUT_FREEZE_STATE",
        "HW-unknown fallback exposed mapping release authority"
      )
  endtask

  task automatic check_owned_mr_released_mapping_not_returned();
    rdma_control_plane control;
    rdma_fault_inject_resource_manager manager;
    rdma_mock_cmq_port mock_cmq;
    rdma_mock_stag_key_policy key_policy;
    rdma_mock_host_mem host_mem;
    rdma_function_binding binding;
    rdma_register_mr_req request;
    rdma_dma_request_context dma_context;
    rdma_pd pd;
    rdma_dma_mapping mapping;
    rdma_mr mr;
    rdma_resource registry_resource;
    rdma_mr registry_mr;
    rdma_recovery_record recovery;
    rdma_control_result result;
    rdma_status injected_status;
    rdma_status status;
    int unsigned baseline_allocations;
    int unsigned baseline_leaks;
    int unsigned final_leaks;
    int unsigned release_calls;
    bit [7:0] expected_opcodes[$];

    setup_owned_mr_case(
      "owned_released_mapping", 1'b1, control, manager, mock_cmq,
      key_policy, host_mem, binding, request, dma_context, pd,
      baseline_allocations, baseline_leaks
    );
    if (pd == null)
      return;

    injected_status = rdma_status::make(
      RDMA_SC_INVALID_STATE, "injected owned STAG derivation failure"
    );
    status = key_policy.fail_next(injected_status);
    expect_status("OWNED_RELEASED_MAPPING_KEY_INJECT", status, RDMA_SC_OK);
    injected_status = rdma_status::make(
      RDMA_SC_RESOURCE_BUSY, "injected reservation cleanup failure"
    );
    status = manager.fail_next_transition(
      "release_reserved", injected_status
    );
    expect_status("OWNED_RELEASED_MAPPING_RESERVE_INJECT", status,
                  RDMA_SC_OK);

    control.alloc_and_register_mr(binding, request, dma_context, 4096,
                                  mapping, mr, result);
    expect_recovery_fallback("OWNED_RELEASED_MAPPING", result,
                             RDMA_SC_INVALID_STATE);
    expect_cmq_opcodes("OWNED_RELEASED_MAPPING_OPCODES", mock_cmq,
                       expected_opcodes);
    registry_resource = null;
    recovery = null;
    if (result != null && result.resource_h != null) begin
      status = manager.lookup(result.resource_h, registry_resource);
      expect_status("OWNED_RELEASED_MAPPING_LOOKUP", status, RDMA_SC_OK);
      status = manager.lookup_recovery(result.resource_h, recovery);
      expect_status("OWNED_RELEASED_MAPPING_RECOVERY_ABSENT", status,
                    RDMA_SC_INVALID_STATE);
    end
    registry_mr = null;
    void'($cast(registry_mr, registry_resource));
    void'(manager.check_leaks(final_leaks, binding.make_handle()));
    release_calls = 0;
    foreach (host_mem.calls[i])
      if (host_mem.calls[i] != null &&
          host_mem.calls[i].method_name == "release")
        release_calls++;

    if (result == null || result.resource_h == null ||
        !result.final_resource_state_known ||
        result.final_resource_state != RDMA_RESOURCE_ALLOCATED ||
        result.recovery_required || result.rollback_statuses.size() != 2 ||
        result.rollback_statuses[0] == null ||
        result.rollback_statuses[0].code != RDMA_SC_RESOURCE_BUSY ||
        result.rollback_statuses[1] == null ||
        result.rollback_statuses[1].code != RDMA_SC_INVALID_STATE ||
        mapping != null || mr != null || registry_mr == null ||
        registry_mr.state != RDMA_RESOURCE_ALLOCATED || recovery != null ||
        host_mem.live_allocations() != baseline_allocations ||
        final_leaks != baseline_leaks + 1 || release_calls != 1)
      `uvm_error(
        "OWNED_RELEASED_MAPPING_STATE",
        "post-release fallback returned a stale active mapping snapshot"
      )
  endtask

  task automatic check_owned_mr_success();
    rdma_control_plane control;
    rdma_fault_inject_resource_manager manager;
    rdma_mock_cmq_port mock_cmq;
    rdma_mock_stag_key_policy key_policy;
    rdma_mock_host_mem host_mem;
    rdma_function_binding binding;
    rdma_register_mr_req request;
    rdma_dma_request_context dma_context;
    rdma_pd pd;
    rdma_dma_mapping mapping;
    rdma_mr mr;
    rdma_mrt_model mrt;
    rdma_control_result result;
    int unsigned baseline_allocations;
    int unsigned baseline_leaks;
    int unsigned final_leaks;
    bit [7:0] expected_opcodes[$];
    bit registration_completed;

    setup_owned_mr_case(
      "owned_success", 1'b1, control, manager, mock_cmq, key_policy,
      host_mem, binding, request, dma_context, pd, baseline_allocations,
      baseline_leaks
    );
    if (pd == null)
      return;
    request.access.remote_write = 1'b1;
    registration_completed = 1'b0;
    fork : wait_for_owned_registration
      begin
        control.alloc_and_register_mr(binding, request, dma_context, 4096,
                                      mapping, mr, result);
        registration_completed = 1'b1;
      end
      begin
        #(1us);
      end
    join_any
    disable wait_for_owned_registration;
    if (!registration_completed) begin
      `uvm_error("OWNED_SUCCESS_DEADLOCK",
                 "owned registration did not complete with its supplied lock")
      return;
    end
    expect_result("OWNED_SUCCESS", result, RDMA_SC_OK);
    expected_opcodes.push_back(XTR_V1_OP_KEY_ALLOC);
    expect_cmq_opcodes("OWNED_SUCCESS_OPCODES", mock_cmq,
                       expected_opcodes);
    void'(manager.check_leaks(final_leaks, binding.make_handle()));
    mrt = null;
    if (mock_cmq.calls.size() != 0 && mock_cmq.calls[0] != null &&
        mock_cmq.calls[0].command != null)
      void'($cast(mrt, mock_cmq.calls[0].command.body));
    if (mapping == null || mapping.state != RDMA_MAPPING_ACTIVE ||
        mapping.owner_h != null ||
        mapping.direction != RDMA_DMA_BIDIRECTIONAL ||
        mapping.pasid_valid != dma_context.pasid_valid ||
        mapping.pasid != dma_context.pasid ||
        mr == null || mr.state != RDMA_RESOURCE_ACTIVE ||
        mr.backing_refs.size() != 1 || mr.backing_refs[0] == null ||
        mr.backing_refs[0].mapping == null ||
        mr.backing_refs[0].ownership != RDMA_OWNERSHIP_CONTROL_PLANE ||
        mr.backing_refs[0].release_complete ||
        host_mem.live_allocations() != baseline_allocations + 1 ||
        final_leaks != baseline_leaks + 1 ||
        host_mem.calls.size() != 1 || host_mem.calls[0] == null ||
        host_mem.calls[0].method_name != "allocate" ||
        host_mem.calls[0].direction != RDMA_DMA_BIDIRECTIONAL ||
        host_mem.calls[0].request_context == null ||
        host_mem.calls[0].request_context == dma_context ||
        host_mem.calls[0].request_context.pasid != dma_context.pasid ||
        mrt == null || mrt.page_layout == null ||
        mrt.page_layout.pbl_mode != RDMA_MR_PBL0 ||
        mrt.page_layout.host_page_size != RDMA_MR_PAGE_4K ||
        mrt.page_layout.address_mode != RDMA_MR_ADDRESS_VA_BASED ||
        mrt.page_layout.pba0 != mapping.backing_addr)
      `uvm_error("OWNED_SUCCESS_STATE",
                 "owned PBL0 registration lost mapping authority or layout")
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

  task automatic check_register_mr_caller_snapshot();
    rdma_control_plane control;
    rdma_resource_manager manager;
    rdma_blocking_mock_cmq_port blocking_cmq;
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
    rdma_mr registry_mr;
    rdma_mrt_model mrt;
    rdma_recovery_record recovery;
    rdma_control_result result;
    rdma_status status;
    longint unsigned lease_size;
    longint unsigned original_iova;
    longint unsigned original_length;
    longint unsigned original_backing_address;
    longint unsigned original_hmc_size;
    int unsigned original_first_pbl_index;
    bit cmq_entered;

    control = rdma_control_plane::type_id::create("snapshot_control");
    manager = rdma_resource_manager::type_id::create("snapshot_manager");
    blocking_cmq = rdma_blocking_mock_cmq_port::type_id::create(
      "snapshot_cmq"
    );
    key_policy = rdma_mock_stag_key_policy::type_id::create(
      "snapshot_policy"
    );
    hmc = rdma_hmc_allocator::type_id::create("snapshot_hmc");
    hmc_base.value = 64'h0000_0004_5000_0000;
    status = hmc.configure(hmc_base, 64'h8000);
    expect_status("SNAPSHOT_HMC_CONFIGURE", status, RDMA_SC_OK);
    binding = make_active_binding(
      "snapshot_binding", 64'ha600_0000_0000_0001, 32'ha600_0101, 67
    );
    pd_request = make_create_pd_request("snapshot_pd_request", binding);
    status = control.configure(manager, blocking_cmq, key_policy, null, hmc,
                               7us);
    expect_status("SNAPSHOT_CONFIGURE", status, RDMA_SC_OK);
    control.create_pd(binding, pd_request, pd, result);
    expect_result("SNAPSHOT_PD_CREATE", result, RDMA_SC_OK);
    if (pd == null || pd.handle == null)
      return;

    request = make_register_mr_request("snapshot_success_request",
                                       binding, pd);
    backing = make_borrowed_pbl0_backing(
      "snapshot_success_backing", binding, request, RDMA_MR_PBL2
    );
    status = hmc.allocate(binding.make_handle(), RDMA_RESOURCE_MR,
                          64'h1000, 64'h1000, hmc_address);
    expect_status("SNAPSHOT_SUCCESS_HMC_ALLOCATE", status, RDMA_SC_OK);
    status = hmc.lookup(binding.make_handle(), RDMA_RESOURCE_MR,
                        hmc_address, lease_size);
    expect_status("SNAPSHOT_SUCCESS_HMC_LOOKUP", status, RDMA_SC_OK);
    hmc_ref = make_borrowed_hmc_ref(
      "snapshot_success_hmc_ref", binding, hmc_address, lease_size,
      28'h000_0400
    );
    backing.hmc_refs.push_back(hmc_ref);
    backing.page_layout.first_pbl_index = hmc_ref.first_pbl_index;
    backing.backing_refs[0].mapping.owner_h = null;
    original_iova = request.iova.value;
    original_length = request.length;
    original_backing_address =
      backing.backing_refs[0].mapping.backing_addr.value;
    original_hmc_size = backing.hmc_refs[0].size;
    original_first_pbl_index = backing.hmc_refs[0].first_pbl_index;
    fork
      begin
        control.register_mr(binding, request, backing, mr, result);
      end
      begin
        blocking_cmq.wait_until_entered(1us, cmq_entered);
        if (!cmq_entered)
          `uvm_error("SNAPSHOT_SUCCESS_HANDSHAKE",
                     "KEY_ALLOC did not enter the blocking CMQ")
        else begin
          request.iova.value += 64'h0010_0000;
          request.length += 64'h1000;
          backing.backing_refs[0].ownership = RDMA_OWNERSHIP_CONTROL_PLANE;
          backing.backing_refs[0].mapping.backing_addr.value += 64'h2000;
          backing.hmc_refs[0].size += 64'h1000;
          backing.hmc_refs[0].first_pbl_index += 1'b1;
          backing.page_layout.first_pbl_index += 1'b1;
        end
        blocking_cmq.resume_execute();
      end
    join
    expect_result("SNAPSHOT_SUCCESS", result, RDMA_SC_OK);
    if (mr == null || mr.handle == null || mr.state != RDMA_RESOURCE_ACTIVE)
      `uvm_error("SNAPSHOT_SUCCESS_RESULT",
                 "caller mutation prevented ACTIVE MR publication")
    if (mr != null && mr.handle != null) begin
      status = manager.lookup(mr.handle, resource);
      expect_status("SNAPSHOT_SUCCESS_REGISTRY", status, RDMA_SC_OK);
      if (!$cast(registry_mr, resource) || registry_mr == null ||
          registry_mr.backing_refs.size() != 1 ||
          registry_mr.hmc_refs.size() != 1 ||
          registry_mr.iova.value != original_iova ||
          registry_mr.length != original_length ||
          registry_mr.backing_refs[0].ownership !=
            RDMA_OWNERSHIP_BORROWED ||
          registry_mr.backing_refs[0].mapping.backing_addr.value !=
            original_backing_address ||
          registry_mr.hmc_refs[0].size != original_hmc_size ||
          registry_mr.hmc_refs[0].first_pbl_index !=
            original_first_pbl_index)
        `uvm_error("SNAPSHOT_SUCCESS_VALUES",
                   "ACTIVE MR consumed caller mutations after KEY_ALLOC began")
      else if (registry_mr.backing_refs[0] == backing.backing_refs[0] ||
               registry_mr.backing_refs[0].mapping ==
                 backing.backing_refs[0].mapping ||
               registry_mr.hmc_refs[0] == backing.hmc_refs[0])
        `uvm_error("SNAPSHOT_SUCCESS_ALIAS",
                   "ACTIVE MR aliases caller-owned backing objects")
    end
    if (blocking_cmq.calls.size() != 1 ||
        blocking_cmq.calls[0] == null ||
        !$cast(mrt, blocking_cmq.calls[0].command.body) || mrt == null ||
        mrt.iova.value != original_iova || mrt.length != original_length ||
        mrt.page_layout == null ||
        mrt.page_layout.first_pbl_index != original_first_pbl_index)
      `uvm_error("SNAPSHOT_SUCCESS_COMMAND",
                 "KEY_ALLOC command consumed caller mutations")

    request = make_register_mr_request("snapshot_timeout_request",
                                       binding, pd);
    request.iova.value += 64'h0002_0000;
    backing = make_borrowed_pbl0_backing(
      "snapshot_timeout_backing", binding, request, RDMA_MR_PBL2
    );
    status = hmc.allocate(binding.make_handle(), RDMA_RESOURCE_MR,
                          64'h1000, 64'h1000, hmc_address);
    expect_status("SNAPSHOT_TIMEOUT_HMC_ALLOCATE", status, RDMA_SC_OK);
    status = hmc.lookup(binding.make_handle(), RDMA_RESOURCE_MR,
                        hmc_address, lease_size);
    expect_status("SNAPSHOT_TIMEOUT_HMC_LOOKUP", status, RDMA_SC_OK);
    hmc_ref = make_borrowed_hmc_ref(
      "snapshot_timeout_hmc_ref", binding, hmc_address, lease_size,
      28'h000_0500
    );
    backing.hmc_refs.push_back(hmc_ref);
    backing.page_layout.first_pbl_index = hmc_ref.first_pbl_index;
    original_backing_address =
      backing.backing_refs[0].mapping.backing_addr.value;
    original_hmc_size = backing.hmc_refs[0].size;
    original_first_pbl_index = backing.hmc_refs[0].first_pbl_index;
    blocking_cmq.timeout_opcode(XTR_V1_OP_KEY_ALLOC);
    fork
      begin
        control.register_mr(binding, request, backing, mr, result);
      end
      begin
        blocking_cmq.wait_until_entered(1us, cmq_entered);
        if (!cmq_entered)
          `uvm_error("SNAPSHOT_TIMEOUT_HANDSHAKE",
                     "timed KEY_ALLOC did not enter the blocking CMQ")
        else begin
          backing.backing_refs[0].ownership = RDMA_OWNERSHIP_CONTROL_PLANE;
          backing.backing_refs[0].mapping.backing_addr.value += 64'h4000;
          backing.hmc_refs[0].size += 64'h2000;
          backing.hmc_refs[0].first_pbl_index += 2;
          backing.page_layout.first_pbl_index += 2;
        end
        blocking_cmq.resume_execute();
      end
    join
    expect_recovery_result("SNAPSHOT_TIMEOUT", result, RDMA_SC_TIMEOUT);
    recovery = null;
    if (result != null && result.resource_h != null) begin
      status = manager.lookup_recovery(result.resource_h, recovery);
      expect_status("SNAPSHOT_TIMEOUT_RECOVERY", status, RDMA_SC_OK);
    end
    if (recovery == null || recovery.backing_refs.size() != 1 ||
        recovery.hmc_refs.size() != 1 ||
        recovery.backing_refs[0].ownership != RDMA_OWNERSHIP_BORROWED ||
        recovery.backing_refs[0].mapping.backing_addr.value !=
          original_backing_address ||
        recovery.hmc_refs[0].size != original_hmc_size ||
        recovery.hmc_refs[0].first_pbl_index != original_first_pbl_index)
      `uvm_error("SNAPSHOT_TIMEOUT_VALUES",
                 "timeout recovery consumed caller mutations")
    else if (recovery.backing_refs[0] == backing.backing_refs[0] ||
             recovery.backing_refs[0].mapping ==
               backing.backing_refs[0].mapping ||
             recovery.hmc_refs[0] == backing.hmc_refs[0])
      `uvm_error("SNAPSHOT_TIMEOUT_ALIAS",
                 "timeout recovery aliases caller-owned backing objects")
    if (blocking_cmq.calls.size() != 2)
      `uvm_error("SNAPSHOT_COMMAND_COUNT",
                 "snapshot regressions issued unexpected CMQ commands")
  endtask

  task automatic check_register_mr_post_cmq_fence();
    rdma_control_plane control;
    rdma_resource_manager manager;
    rdma_recovery_probe_manager probe_manager;
    rdma_blocking_mock_cmq_port blocking_cmq;
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
    rdma_recovery_record recovery;
    rdma_control_result result;
    rdma_status status;
    longint unsigned lease_size;
    bit cmq_entered;

    control = rdma_control_plane::type_id::create("post_cmq_control");
    probe_manager = rdma_recovery_probe_manager::type_id::create(
      "post_cmq_manager"
    );
    manager = probe_manager;
    blocking_cmq = rdma_blocking_mock_cmq_port::type_id::create(
      "post_cmq_cmq"
    );
    key_policy = rdma_mock_stag_key_policy::type_id::create(
      "post_cmq_policy"
    );
    hmc = rdma_hmc_allocator::type_id::create("post_cmq_hmc");
    hmc_base.value = 64'h0000_0004_6000_0000;
    status = hmc.configure(hmc_base, 64'h8000);
    expect_status("POST_CMQ_HMC_CONFIGURE", status, RDMA_SC_OK);
    binding = make_active_binding(
      "post_cmq_binding", 64'ha700_0000_0000_0001, 32'ha700_0101, 71
    );
    pd_request = make_create_pd_request("post_cmq_pd_request", binding);
    status = control.configure(manager, blocking_cmq, key_policy, null, hmc,
                               8us);
    expect_status("POST_CMQ_CONFIGURE", status, RDMA_SC_OK);
    control.create_pd(binding, pd_request, pd, result);
    expect_result("POST_CMQ_PD_CREATE", result, RDMA_SC_OK);
    if (pd == null || pd.handle == null)
      return;

    request = make_register_mr_request("post_cmq_binding_request",
                                       binding, pd);
    backing = make_borrowed_pbl0_backing(
      "post_cmq_binding_backing", binding, request, RDMA_MR_PBL2
    );
    status = hmc.allocate(binding.make_handle(), RDMA_RESOURCE_MR,
                          64'h1000, 64'h1000, hmc_address);
    expect_status("POST_CMQ_BINDING_HMC_ALLOCATE", status, RDMA_SC_OK);
    status = hmc.lookup(binding.make_handle(), RDMA_RESOURCE_MR,
                        hmc_address, lease_size);
    expect_status("POST_CMQ_BINDING_HMC_LOOKUP", status, RDMA_SC_OK);
    hmc_ref = make_borrowed_hmc_ref(
      "post_cmq_binding_hmc_ref", binding, hmc_address, lease_size,
      28'h000_0600
    );
    backing.hmc_refs.push_back(hmc_ref);
    backing.page_layout.first_pbl_index = hmc_ref.first_pbl_index;
    fork
      begin
        control.register_mr(binding, request, backing, mr, result);
      end
      begin
        blocking_cmq.wait_until_entered(1us, cmq_entered);
        if (!cmq_entered)
          `uvm_error("POST_CMQ_BINDING_HANDSHAKE",
                     "KEY_ALLOC did not enter the blocking CMQ")
        else begin
          binding.generation++;
          binding.owner_h = binding.make_handle();
        end
        blocking_cmq.resume_execute();
      end
    join
    expect_recovery_result("POST_CMQ_BINDING", result,
                           RDMA_SC_STALE_GENERATION);
    if (mr != null || result == null || result.resource_h == null ||
        !result.final_resource_state_known ||
        result.final_resource_state != RDMA_RESOURCE_ERROR ||
        !result.recovery_required || result.completed_steps.size() != 4 ||
        result.completed_steps[3] != RDMA_CTRL_STEP_HW_KEY_ALLOCATED ||
        result.rollback_statuses.size() != 0)
      `uvm_error("POST_CMQ_BINDING_RESULT",
                 "binding fence did not preserve durable ERROR recovery")
    recovery = null;
    if (result != null && result.resource_h != null) begin
      status = manager.lookup(result.resource_h, resource);
      expect_status("POST_CMQ_BINDING_LOOKUP", status,
                    RDMA_SC_STALE_GENERATION);
      status = manager.lookup_recovery(result.resource_h, recovery);
      expect_status("POST_CMQ_BINDING_RECOVERY", status,
                    RDMA_SC_STALE_GENERATION);
      status = probe_manager.peek_resource(result.resource_h, resource);
      expect_status("POST_CMQ_BINDING_RAW_LOOKUP", status, RDMA_SC_OK);
      if (!$cast(registry_mr, resource) || registry_mr == null ||
          registry_mr.state != RDMA_RESOURCE_ERROR)
        `uvm_error("POST_CMQ_BINDING_RAW_STATE",
                   "binding fence raw registry state is not ERROR")
      status = probe_manager.peek_recovery(result.resource_h, recovery);
      expect_status("POST_CMQ_BINDING_RAW_RECOVERY", status, RDMA_SC_OK);
    end
    if (recovery == null ||
        recovery.hardware_presence != RDMA_HW_PRESENCE_PRESENT ||
        recovery.completed_steps != result.completed_steps ||
        recovery.pending_steps.size() != 1 ||
        recovery.pending_steps[0] != RDMA_CTRL_STEP_HW_MR_DEREGISTERED ||
        recovery.primary_status == null ||
        recovery.primary_status.code != RDMA_SC_STALE_GENERATION ||
        recovery.backing_refs.size() != 1 ||
        recovery.hmc_refs.size() != 1)
      `uvm_error("POST_CMQ_BINDING_RECORD",
                 "binding fence recovery record is incomplete")
    else if (recovery.backing_refs[0] == backing.backing_refs[0] ||
             recovery.hmc_refs[0] == backing.hmc_refs[0])
      `uvm_error("POST_CMQ_BINDING_ALIAS",
                 "binding fence recovery aliases caller backing")
    if (blocking_cmq.calls.size() != 1 ||
        blocking_cmq.calls[0] == null ||
        blocking_cmq.calls[0].opcode != XTR_V1_OP_KEY_ALLOC)
      `uvm_error("POST_CMQ_BINDING_COMMANDS",
                 "binding fence issued unexpected hardware commands")

    control = rdma_control_plane::type_id::create("post_cmq_hmc_control");
    manager = rdma_resource_manager::type_id::create("post_cmq_hmc_manager");
    blocking_cmq = rdma_blocking_mock_cmq_port::type_id::create(
      "post_cmq_hmc_cmq"
    );
    key_policy = rdma_mock_stag_key_policy::type_id::create(
      "post_cmq_hmc_policy"
    );
    hmc = rdma_hmc_allocator::type_id::create("post_cmq_hmc_allocator");
    hmc_base.value = 64'h0000_0004_7000_0000;
    status = hmc.configure(hmc_base, 64'h8000);
    expect_status("POST_CMQ_HMC_FENCE_CONFIGURE", status, RDMA_SC_OK);
    binding = make_active_binding(
      "post_cmq_hmc_binding", 64'ha800_0000_0000_0001,
      32'ha800_0101, 73
    );
    pd_request = make_create_pd_request("post_cmq_hmc_pd_request", binding);
    status = control.configure(manager, blocking_cmq, key_policy, null, hmc,
                               8us);
    expect_status("POST_CMQ_HMC_CONTROL_CONFIGURE", status, RDMA_SC_OK);
    control.create_pd(binding, pd_request, pd, result);
    expect_result("POST_CMQ_HMC_PD_CREATE", result, RDMA_SC_OK);
    if (pd == null || pd.handle == null)
      return;

    request = make_register_mr_request("post_cmq_hmc_request", binding, pd);
    request.iova.value += 64'h0002_0000;
    backing = make_borrowed_pbl0_backing(
      "post_cmq_hmc_backing", binding, request, RDMA_MR_PBL2
    );
    status = hmc.allocate(binding.make_handle(), RDMA_RESOURCE_MR,
                          64'h1000, 64'h1000, hmc_address);
    expect_status("POST_CMQ_HMC_ALLOCATE", status, RDMA_SC_OK);
    status = hmc.lookup(binding.make_handle(), RDMA_RESOURCE_MR,
                        hmc_address, lease_size);
    expect_status("POST_CMQ_HMC_LOOKUP", status, RDMA_SC_OK);
    hmc_ref = make_borrowed_hmc_ref(
      "post_cmq_hmc_ref", binding, hmc_address, lease_size, 28'h000_0700
    );
    backing.hmc_refs.push_back(hmc_ref);
    backing.page_layout.first_pbl_index = hmc_ref.first_pbl_index;
    fork
      begin
        control.register_mr(binding, request, backing, mr, result);
      end
      begin
        blocking_cmq.wait_until_entered(1us, cmq_entered);
        if (!cmq_entered)
          `uvm_error("POST_CMQ_HMC_HANDSHAKE",
                     "KEY_ALLOC did not enter the blocking CMQ")
        else begin
          status = hmc.\release (binding.make_handle(), RDMA_RESOURCE_MR,
                                 hmc_address);
          expect_status("POST_CMQ_HMC_RELEASE", status, RDMA_SC_OK);
        end
        blocking_cmq.resume_execute();
      end
    join
    expect_recovery_result("POST_CMQ_HMC", result, RDMA_SC_INVALID_STATE);
    if (mr == null || mr.handle == null ||
        mr.state != RDMA_RESOURCE_ERROR || result == null ||
        !result.final_resource_state_known ||
        result.final_resource_state != RDMA_RESOURCE_ERROR ||
        !result.recovery_required || result.completed_steps.size() != 4 ||
        result.completed_steps[3] != RDMA_CTRL_STEP_HW_KEY_ALLOCATED)
      `uvm_error("POST_CMQ_HMC_RESULT",
                 "HMC fence did not preserve an ERROR MR")
    recovery = null;
    if (result != null && result.resource_h != null) begin
      status = manager.lookup(result.resource_h, resource);
      expect_status("POST_CMQ_HMC_STATE_LOOKUP", status, RDMA_SC_OK);
      if (!$cast(registry_mr, resource) || registry_mr == null ||
          registry_mr.state != RDMA_RESOURCE_ERROR)
        `uvm_error("POST_CMQ_HMC_STATE",
                   "HMC fence committed or lost the MR")
      status = manager.lookup_recovery(result.resource_h, recovery);
      expect_status("POST_CMQ_HMC_RECOVERY", status, RDMA_SC_OK);
    end
    if (recovery == null ||
        recovery.hardware_presence != RDMA_HW_PRESENCE_PRESENT ||
        recovery.completed_steps != result.completed_steps ||
        recovery.pending_steps.size() != 1 ||
        recovery.pending_steps[0] != RDMA_CTRL_STEP_HW_MR_DEREGISTERED ||
        recovery.primary_status == null ||
        recovery.primary_status.code != RDMA_SC_INVALID_STATE ||
        recovery.backing_refs.size() != 1 ||
        recovery.hmc_refs.size() != 1)
      `uvm_error("POST_CMQ_HMC_RECORD",
                 "HMC fence recovery record is incomplete")
    else if (recovery.backing_refs[0] == backing.backing_refs[0] ||
             recovery.hmc_refs[0] == backing.hmc_refs[0])
      `uvm_error("POST_CMQ_HMC_ALIAS",
                 "HMC fence recovery aliases caller backing")
    if (blocking_cmq.calls.size() != 1 ||
        blocking_cmq.calls[0] == null ||
        blocking_cmq.calls[0].opcode != XTR_V1_OP_KEY_ALLOC)
      `uvm_error("POST_CMQ_COMMANDS",
                 "post-CMQ fences issued unexpected hardware commands")
  endtask

  task automatic check_register_mr_recovery_freeze_failures();
    rdma_control_plane control;
    rdma_fault_resource_manager manager;
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
    rdma_recovery_record recovery;
    rdma_control_result result;
    rdma_status hardware_failure;
    rdma_status release_failure;
    rdma_status mark_error_failure;
    rdma_status status;
    longint unsigned lease_size;

    control = rdma_control_plane::type_id::create("freeze_failure_control");
    manager = rdma_fault_resource_manager::type_id::create(
      "freeze_failure_manager"
    );
    mock_cmq = rdma_mock_cmq_port::type_id::create("freeze_failure_cmq");
    key_policy = rdma_mock_stag_key_policy::type_id::create(
      "freeze_failure_policy"
    );
    hmc = rdma_hmc_allocator::type_id::create("freeze_failure_hmc");
    hmc_base.value = 64'h0000_0004_8000_0000;
    status = hmc.configure(hmc_base, 64'h1_0000);
    expect_status("FREEZE_FAILURE_HMC_CONFIGURE", status, RDMA_SC_OK);
    binding = make_active_binding(
      "freeze_failure_binding", 64'ha900_0000_0000_0001,
      32'ha900_0101, 79
    );
    pd_request = make_create_pd_request("freeze_failure_pd_request",
                                        binding);
    status = control.configure(manager, mock_cmq, key_policy, null, hmc,
                               9us);
    expect_status("FREEZE_FAILURE_CONFIGURE", status, RDMA_SC_OK);
    control.create_pd(binding, pd_request, pd, result);
    expect_result("FREEZE_FAILURE_PD_CREATE", result, RDMA_SC_OK);
    if (pd == null || pd.handle == null)
      return;

    hardware_failure = rdma_status::make(
      RDMA_SC_UNKNOWN_HW_ERROR, "injected KEY_ALLOC failure"
    );
    release_failure = rdma_status::make(
      RDMA_SC_RESOURCE_BUSY, "injected release_reserved failure"
    );
    mark_error_failure = rdma_status::make(
      RDMA_SC_INVALID_STATE, "injected mark_error failure"
    );

    request = make_register_mr_request("freeze_release_request", binding,
                                       pd);
    backing = make_borrowed_pbl0_backing(
      "freeze_release_backing", binding, request, RDMA_MR_PBL2
    );
    status = hmc.allocate(binding.make_handle(), RDMA_RESOURCE_MR,
                          64'h1000, 64'h1000, hmc_address);
    expect_status("FREEZE_RELEASE_HMC_ALLOCATE", status, RDMA_SC_OK);
    status = hmc.lookup(binding.make_handle(), RDMA_RESOURCE_MR,
                        hmc_address, lease_size);
    expect_status("FREEZE_RELEASE_HMC_LOOKUP", status, RDMA_SC_OK);
    hmc_ref = make_borrowed_hmc_ref(
      "freeze_release_hmc_ref", binding, hmc_address, lease_size,
      28'h000_0800
    );
    backing.hmc_refs.push_back(hmc_ref);
    backing.page_layout.first_pbl_index = hmc_ref.first_pbl_index;
    manager.fail_next_release_reserved(release_failure);
    mock_cmq.fail_opcode(XTR_V1_OP_KEY_ALLOC, hardware_failure);
    control.register_mr(binding, request, backing, mr, result);
    expect_recovery_result("FREEZE_RELEASE", result,
                           RDMA_SC_UNKNOWN_HW_ERROR);
    if (mr == null || mr.handle == null ||
        mr.state != RDMA_RESOURCE_ERROR || result == null ||
        !result.final_resource_state_known ||
        result.final_resource_state != RDMA_RESOURCE_ERROR ||
        !result.recovery_required || result.rollback_statuses.size() != 1 ||
        result.rollback_statuses[0] == null ||
        result.rollback_statuses[0].code != RDMA_SC_RESOURCE_BUSY)
      `uvm_error("FREEZE_RELEASE_RESULT",
                 "release failure did not freeze durable ERROR recovery")
    recovery = null;
    if (result != null && result.resource_h != null) begin
      status = manager.lookup(result.resource_h, resource);
      expect_status("FREEZE_RELEASE_LOOKUP", status, RDMA_SC_OK);
      if (!$cast(registry_mr, resource) || registry_mr == null ||
          registry_mr.state != RDMA_RESOURCE_ERROR)
        `uvm_error("FREEZE_RELEASE_STATE",
                   "release failure registry state is not ERROR")
      status = manager.lookup_recovery(result.resource_h, recovery);
      expect_status("FREEZE_RELEASE_RECOVERY", status, RDMA_SC_OK);
    end
    if (recovery == null ||
        recovery.hardware_presence != RDMA_HW_PRESENCE_ABSENT ||
        recovery.completed_steps != result.completed_steps ||
        recovery.pending_steps.size() != 0 ||
        recovery.primary_status == null ||
        recovery.primary_status.code != RDMA_SC_UNKNOWN_HW_ERROR ||
        recovery.rollback_statuses.size() != 1 ||
        recovery.rollback_statuses[0] == null ||
        recovery.rollback_statuses[0].code != RDMA_SC_RESOURCE_BUSY ||
        recovery.backing_refs.size() != 1 ||
        recovery.hmc_refs.size() != 1)
      `uvm_error("FREEZE_RELEASE_RECORD",
                 "release failure recovery record is incomplete")
    else if (recovery.backing_refs[0] == backing.backing_refs[0] ||
             recovery.hmc_refs[0] == backing.hmc_refs[0])
      `uvm_error("FREEZE_RELEASE_ALIAS",
                 "release failure recovery aliases caller backing")
    if (manager.release_reserved_calls != 1 ||
        manager.mark_error_calls != 1)
      `uvm_error("FREEZE_RELEASE_CALLS",
                 "release failure did not attempt one recovery freeze")

    request = make_register_mr_request("freeze_double_request", binding,
                                       pd);
    request.iova.value += 64'h0002_0000;
    backing = make_borrowed_pbl0_backing(
      "freeze_double_backing", binding, request, RDMA_MR_PBL2
    );
    status = hmc.allocate(binding.make_handle(), RDMA_RESOURCE_MR,
                          64'h1000, 64'h1000, hmc_address);
    expect_status("FREEZE_DOUBLE_HMC_ALLOCATE", status, RDMA_SC_OK);
    status = hmc.lookup(binding.make_handle(), RDMA_RESOURCE_MR,
                        hmc_address, lease_size);
    expect_status("FREEZE_DOUBLE_HMC_LOOKUP", status, RDMA_SC_OK);
    hmc_ref = make_borrowed_hmc_ref(
      "freeze_double_hmc_ref", binding, hmc_address, lease_size,
      28'h000_0900
    );
    backing.hmc_refs.push_back(hmc_ref);
    backing.page_layout.first_pbl_index = hmc_ref.first_pbl_index;
    manager.fail_next_release_reserved(release_failure);
    manager.fail_next_mark_error(mark_error_failure);
    mock_cmq.fail_opcode(XTR_V1_OP_KEY_ALLOC, hardware_failure);
    control.register_mr(binding, request, backing, mr, result);
    expect_recovery_fallback("FREEZE_DOUBLE", result,
                             RDMA_SC_UNKNOWN_HW_ERROR);
    if (mr != null || result == null || result.resource_h == null ||
        !result.final_resource_state_known ||
        result.final_resource_state != RDMA_RESOURCE_ALLOCATED ||
        result.recovery_required || result.rollback_statuses.size() != 2 ||
        result.rollback_statuses[0] == null ||
        result.rollback_statuses[0].code != RDMA_SC_RESOURCE_BUSY ||
        result.rollback_statuses[1] == null ||
        result.rollback_statuses[1].code != RDMA_SC_INVALID_STATE)
      `uvm_error("FREEZE_DOUBLE_RESULT",
                 "double cleanup failure fallback is incomplete")
    recovery = null;
    if (result != null && result.resource_h != null) begin
      status = manager.lookup(result.resource_h, resource);
      expect_status("FREEZE_DOUBLE_LOOKUP", status, RDMA_SC_OK);
      if (!$cast(registry_mr, resource) || registry_mr == null ||
          registry_mr.state != RDMA_RESOURCE_ALLOCATED)
        `uvm_error("FREEZE_DOUBLE_STATE",
                   "double cleanup failure lost the ALLOCATED MR")
      status = manager.lookup_recovery(result.resource_h, recovery);
      expect_status("FREEZE_DOUBLE_RECOVERY", status,
                    RDMA_SC_INVALID_STATE);
    end
    if (recovery != null || manager.release_reserved_calls != 2 ||
        manager.mark_error_calls != 2)
      `uvm_error("FREEZE_DOUBLE_CALLS",
                 "double cleanup failure published recovery or skipped calls")

    request = make_register_mr_request("freeze_timeout_request", binding,
                                       pd);
    request.iova.value += 64'h0004_0000;
    backing = make_borrowed_pbl0_backing(
      "freeze_timeout_backing", binding, request, RDMA_MR_PBL2
    );
    status = hmc.allocate(binding.make_handle(), RDMA_RESOURCE_MR,
                          64'h1000, 64'h1000, hmc_address);
    expect_status("FREEZE_TIMEOUT_HMC_ALLOCATE", status, RDMA_SC_OK);
    status = hmc.lookup(binding.make_handle(), RDMA_RESOURCE_MR,
                        hmc_address, lease_size);
    expect_status("FREEZE_TIMEOUT_HMC_LOOKUP", status, RDMA_SC_OK);
    hmc_ref = make_borrowed_hmc_ref(
      "freeze_timeout_hmc_ref", binding, hmc_address, lease_size,
      28'h000_0a00
    );
    backing.hmc_refs.push_back(hmc_ref);
    backing.page_layout.first_pbl_index = hmc_ref.first_pbl_index;
    manager.fail_next_mark_error(mark_error_failure);
    mock_cmq.timeout_opcode(XTR_V1_OP_KEY_ALLOC);
    control.register_mr(binding, request, backing, mr, result);
    expect_recovery_fallback("FREEZE_TIMEOUT", result, RDMA_SC_TIMEOUT);
    if (mr != null || result == null || result.resource_h == null ||
        !result.final_resource_state_known ||
        result.final_resource_state != RDMA_RESOURCE_ALLOCATED ||
        result.recovery_required || result.rollback_statuses.size() != 1 ||
        result.rollback_statuses[0] == null ||
        result.rollback_statuses[0].code != RDMA_SC_INVALID_STATE)
      `uvm_error("FREEZE_TIMEOUT_RESULT",
                 "timeout freeze failure fallback is incomplete")
    recovery = null;
    if (result != null && result.resource_h != null) begin
      status = manager.lookup(result.resource_h, resource);
      expect_status("FREEZE_TIMEOUT_LOOKUP", status, RDMA_SC_OK);
      if (!$cast(registry_mr, resource) || registry_mr == null ||
          registry_mr.state != RDMA_RESOURCE_ALLOCATED)
        `uvm_error("FREEZE_TIMEOUT_STATE",
                   "timeout freeze failure lost the ALLOCATED MR")
      status = manager.lookup_recovery(result.resource_h, recovery);
      expect_status("FREEZE_TIMEOUT_RECOVERY", status,
                    RDMA_SC_INVALID_STATE);
    end
    if (recovery != null || manager.release_reserved_calls != 2 ||
        manager.mark_error_calls != 3 || mock_cmq.calls.size() != 3)
      `uvm_error("FREEZE_TIMEOUT_CALLS",
                 "timeout freeze failure published recovery or skipped calls")
    foreach (mock_cmq.calls[i]) begin
      if (mock_cmq.calls[i] == null ||
          mock_cmq.calls[i].opcode != XTR_V1_OP_KEY_ALLOC)
        `uvm_error("FREEZE_FAILURE_COMMANDS",
                   "freeze failure test issued a non-KEY_ALLOC command")
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
    check_mock_typed_body_snapshot();
    check_owned_mr_validation();
    run_owned_mr_failure("allocate");
    run_owned_mr_failure("key_alloc");
    run_owned_mr_failure("commit_programmed");
    run_owned_mr_failure("activate");
    run_owned_mr_failure("deregister");
    check_owned_mr_prestage_release_failure();
    check_owned_mr_timeout_freeze_failure_no_mapping();
    check_owned_mr_released_mapping_not_returned();
    check_owned_mr_unattached_release_failure();
    check_owned_mr_success();
    check_pd_lifecycle();
    check_borrowed_pbl0_registration();
    check_key_alloc_explicit_failure();
    check_key_alloc_timeout_recovery();
    check_register_mr_caller_snapshot();
    check_register_mr_post_cmq_fence();
    check_register_mr_recovery_freeze_failures();
    check_borrowed_pbl1_pbl2_registration();
    check_register_mr_pre_cmq_rejections();
    check_post_activate_snapshot_cleanup();
    check_post_lock_revalidation();
    check_register_mr_post_lock_revalidation();
    check_transaction_id_exhaustion();
    phase.drop_objection(this);
  endtask
endclass
