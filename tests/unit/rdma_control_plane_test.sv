// 中文说明：rdma_control_plane_test.sv 属于单元测试，覆盖对应模型、编码器或执行器契约。
// 阅读提示：先看公开类型和接口，再看实现细节；失败路径应保持状态与资源所有权可追踪。

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

  task acquire_test_lock_table_guard(output semaphore guard);
    guard = lock_table_guard;
    guard.get(1);
  endtask

  task release_test_lock_table_guard(semaphore guard);
    if (guard != null)
      guard.put(1);
  endtask

  task register_mr_with_test_lock(
    rdma_function_binding binding,
    rdma_register_mr_req request,
    rdma_mr_backing_desc backing,
    semaphore function_lock,
    output rdma_mr mr,
    output rdma_control_result result
  );
    register_mr_internal(
      binding, request, backing, RDMA_OWNERSHIP_BORROWED, 0,
      function_lock, mr, result
    );
  endtask

  task register_owned_mr_for_test(
    rdma_function_binding binding,
    rdma_register_mr_req request,
    rdma_mr_backing_desc backing,
    output rdma_mr mr,
    output rdma_control_result result
  );
    register_mr_internal(
      binding, request, backing, RDMA_OWNERSHIP_CONTROL_PLANE, 0,
      null, mr, result
    );
  endtask

  function void use_hmc_allocator_for_test(
    rdma_hmc_allocator replacement
  );
    hmc_allocator = replacement;
  endfunction

  function void use_host_mem_for_test(rdma_host_mem_api replacement);
    host_mem = replacement;
  endfunction

endclass

class rdma_generation_mutating_host_mem extends rdma_mock_host_mem;
  `uvm_object_utils(rdma_generation_mutating_host_mem)

  protected rdma_mock_host_mem delegate;
  protected rdma_function_binding mutation_target;

  function new(string name = "rdma_generation_mutating_host_mem");
    super.new(name);
    delegate = null;
    mutation_target = null;
  endfunction

  function void configure_mutation(
    rdma_mock_host_mem release_delegate,
    rdma_function_binding binding
  );
    delegate = release_delegate;
    mutation_target = binding;
  endfunction

  virtual function rdma_status \release (rdma_dma_mapping mapping);
    rdma_status status;

    if (delegate == null)
      return rdma_status::make(
        RDMA_SC_INVALID_STATE, "release mutation delegate is null"
      );
    status = delegate.\release (mapping);
    if (status != null && status.ok() && mutation_target != null) begin
      mutation_target.generation++;
      mutation_target.owner_h = mutation_target.make_handle();
      mutation_target = null;
    end
    return status;
  endfunction

endclass

class rdma_cp_mutating_completion_mapping extends rdma_mock_dma_mapping;
  `uvm_object_utils(rdma_cp_mutating_completion_mapping)

  local static bit mutation_armed = 1'b0;

  function new(string name = "rdma_cp_mutating_completion_mapping");
    super.new(name);
  endfunction

  static function void arm_completion_mutation();
    mutation_armed = 1'b1;
  endfunction

  static function void disarm_completion_mutation();
    mutation_armed = 1'b0;
  endfunction

  virtual function rdma_status release_completion_status(
    output bit release_complete
  );
    rdma_status status;

    status = super.release_completion_status(release_complete);
    if (mutation_armed)
      size++;
    return status;
  endfunction
endclass

class rdma_reconcile_fault_mock_cmq_port extends rdma_mock_cmq_port;
  `uvm_object_utils(rdma_reconcile_fault_mock_cmq_port)

  protected rdma_status next_reconcile_failure;

  function new(string name = "rdma_reconcile_fault_mock_cmq_port");
    super.new(name);
    next_reconcile_failure = null;
  endfunction

  function void fail_next_reconcile(rdma_status failure);
    next_reconcile_failure = rdma_cmq_clone_status_value(failure);
  endfunction

  virtual task reconcile(
    rdma_cmq_ticket ticket,
    output bit terminal_known,
    output rdma_cmq_completion completion,
    output rdma_status status
  );
    if (next_reconcile_failure != null) begin
      terminal_known = 1'b0;
      completion = null;
      status = rdma_cmq_clone_status_value(next_reconcile_failure);
      next_reconcile_failure = null;
      return;
    end
    super.reconcile(ticket, terminal_known, completion, status);
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
  int unsigned finalize_release_calls;
  int unsigned begin_quiesce_calls;
  int unsigned restore_active_calls;
  protected rdma_status next_release_failure;
  protected rdma_status next_mark_error_failure;
  protected rdma_status next_activate_failure;
  protected rdma_status next_finalize_failure;
  protected rdma_status next_restore_active_failure;

  function new(string name = "rdma_fault_resource_manager");
    super.new(name);
    release_reserved_calls = 0;
    mark_error_calls = 0;
    finalize_release_calls = 0;
    begin_quiesce_calls = 0;
    restore_active_calls = 0;
    next_release_failure = null;
    next_mark_error_failure = null;
    next_activate_failure = null;
    next_finalize_failure = null;
    next_restore_active_failure = null;
  endfunction

  function void fail_next_release_reserved(rdma_status failure);
    next_release_failure = rdma_cmq_clone_status_value(failure);
  endfunction

  function void fail_next_mark_error(rdma_status failure);
    next_mark_error_failure = rdma_cmq_clone_status_value(failure);
  endfunction

  function void fail_next_activate(rdma_status failure);
    next_activate_failure = rdma_cmq_clone_status_value(failure);
  endfunction

  function void fail_next_finalize_release(rdma_status failure);
    next_finalize_failure = rdma_cmq_clone_status_value(failure);
  endfunction

  function void fail_next_restore_active(rdma_status failure);
    next_restore_active_failure = rdma_cmq_clone_status_value(failure);
  endfunction

  virtual function rdma_status activate(rdma_handle handle);
    rdma_status failure;

    if (next_activate_failure != null) begin
      failure = rdma_cmq_clone_status_value(next_activate_failure);
      next_activate_failure = null;
      return failure;
    end
    return super.activate(handle);
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

  virtual function rdma_status finalize_release(rdma_handle handle);
    rdma_status failure;

    finalize_release_calls++;
    if (next_finalize_failure != null) begin
      failure = rdma_cmq_clone_status_value(next_finalize_failure);
      next_finalize_failure = null;
      return failure;
    end
    return super.finalize_release(handle);
  endfunction

  virtual function rdma_status begin_quiesce(rdma_handle handle);
    begin_quiesce_calls++;
    return super.begin_quiesce(handle);
  endfunction

  virtual function rdma_status restore_active(rdma_handle handle);
    rdma_status failure;

    restore_active_calls++;
    if (next_restore_active_failure != null) begin
      failure = rdma_cmq_clone_status_value(next_restore_active_failure);
      next_restore_active_failure = null;
      return failure;
    end
    return super.restore_active(handle);
  endfunction

endclass

class rdma_generation_mutating_resource_manager extends
  rdma_fault_resource_manager;
  `uvm_object_utils(rdma_generation_mutating_resource_manager)

  protected rdma_function_binding mutation_target;
  protected bit mutate_after_commit;
  int unsigned activate_calls;

  function new(string name = "rdma_generation_mutating_resource_manager");
    super.new(name);
    mutation_target = null;
    mutate_after_commit = 1'b0;
    activate_calls = 0;
  endfunction

  function void mutate_generation_on_next_commit(
    rdma_function_binding binding
  );
    mutation_target = binding;
    mutate_after_commit = 1'b1;
  endfunction

  virtual function rdma_status commit_programmed(rdma_resource candidate);
    rdma_status status;

    status = super.commit_programmed(candidate);
    if (mutate_after_commit && status != null && status.ok() &&
        mutation_target != null) begin
      mutation_target.generation++;
      mutation_target.owner_h = mutation_target.make_handle();
      mutate_after_commit = 1'b0;
    end
    return status;
  endfunction

  virtual function rdma_status activate(rdma_handle handle);
    activate_calls++;
    return super.activate(handle);
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

  function automatic void expect_completed_recovery(
    string check_name,
    rdma_control_result result,
    rdma_status_code_e expected_primary_code
  );
    rdma_status validation_status;

    if (result == null) begin
      `uvm_error(check_name, "completed recovery result is null")
      return;
    end
    expect_status({check_name, "_STATUS"}, result.status, RDMA_SC_OK);
    expect_status({check_name, "_PRIMARY"}, result.primary_status,
                  expected_primary_code);
    if (result.transaction_id == 0 || result.recovery_required ||
        !result.final_resource_state_known ||
        result.final_resource_state != RDMA_RESOURCE_RELEASED)
      `uvm_error(check_name,
                 "completed recovery result does not publish RELEASED")
    validation_status = result.validate();
    expect_status({check_name, "_VALIDATE"}, validation_status, RDMA_SC_OK);
  endfunction

  function automatic void expect_restored_recovery(
    string check_name,
    rdma_control_result result,
    rdma_status_code_e expected_primary_code
  );
    rdma_status validation_status;

    if (result == null) begin
      `uvm_error(check_name, "restored recovery result is null")
      return;
    end
    expect_status({check_name, "_STATUS"}, result.status, RDMA_SC_OK);
    expect_status({check_name, "_PRIMARY"}, result.primary_status,
                  expected_primary_code);
    if (result.transaction_id == 0 || result.recovery_required ||
        !result.final_resource_state_known ||
        result.final_resource_state != RDMA_RESOURCE_ACTIVE)
      `uvm_error(check_name,
                 "restored recovery result does not publish ACTIVE")
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
    binding.queue_dma.pasid = 20'habcde;
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
    dma_context.requester_bdf = binding.queue_dma.requester_bdf;
    dma_context.pasid_valid = binding.queue_dma.pasid_valid;
    dma_context.pasid = binding.queue_dma.pasid;
    dma_context.dma_domain_valid = binding.queue_dma.dma_domain_valid;
    dma_context.dma_domain_id = binding.queue_dma.dma_domain_id;
    dma_context.owner_h = null;
    return dma_context;
  endfunction

  function automatic rdma_queue_backing_slice make_queue_borrowed_slice(
    string name,
    rdma_function_binding binding,
    rdma_queue_backing_role_e role,
    longint unsigned iova,
    longint unsigned backing
  );
    rdma_dma_mapping mapping;
    rdma_queue_backing_slice slice;

    mapping = rdma_dma_mapping::type_id::create({name, "_mapping"});
    mapping.function_h = binding.make_handle();
    mapping.requester_bdf = binding.queue_dma.requester_bdf;
    mapping.pasid_valid = binding.queue_dma.pasid_valid;
    mapping.pasid = binding.queue_dma.pasid;
    mapping.dma_domain_valid = binding.queue_dma.dma_domain_valid;
    mapping.dma_domain_id = binding.queue_dma.dma_domain_id;
    mapping.iova.value = iova;
    mapping.backing_addr.value = backing;
    mapping.size = 4096;
    mapping.direction = RDMA_DMA_BIDIRECTIONAL;
    mapping.permissions =
      '{device_read:1'b1, device_write:1'b1, atomic:1'b0};
    mapping.state = RDMA_MAPPING_ACTIVE;
    slice = rdma_queue_backing_slice::type_id::create({name, "_slice"});
    slice.role = role;
    slice.mapping = mapping;
    slice.mapping_offset = 0;
    slice.length = 4096;
    slice.logical_queue_offset = 0;
    return slice;
  endfunction

  function automatic rdma_create_cq_req make_create_cq_request(
    string name,
    rdma_function_binding binding,
    rdma_ceq dependency
  );
    rdma_create_cq_req request;

    request = rdma_create_cq_req::type_id::create(name);
    request.owner = binding.make_handle();
    request.depth = 64;
    request.cqe_size_bytes = 64;
    request.ceq_h = dependency.handle;
    request.ring_backing.mode = RDMA_QUEUE_BACKING_OWNED;
    return request;
  endfunction

  function automatic rdma_create_srq_req make_create_srq_request(
    string name,
    rdma_function_binding binding,
    rdma_pd dependency
  );
    rdma_create_srq_req request;

    request = rdma_create_srq_req::type_id::create(name);
    request.owner = binding.make_handle();
    request.depth = 64;
    request.max_sge = 2;
    request.limit_threshold = 16;
    request.pd_h = dependency.handle;
    request.payload_backing.mode = RDMA_QUEUE_BACKING_OWNED;
    return request;
  endfunction

  function automatic rdma_create_qp_req make_create_qp_request(
    string name,
    rdma_function_binding binding,
    rdma_pd pd,
    rdma_cq cq
  );
    rdma_create_qp_req request;
    rdma_qp_context_attributes attrs;
    rdma_qpc_rc_ext ext;

    request = rdma_create_qp_req::type_id::create(name);
    request.owner = binding.make_handle();
    request.transport = RDMA_TRANSPORT_RC;
    request.sq_depth = 128;
    request.rq_depth = 64;
    request.max_send_sge = 4;
    request.max_recv_sge = 4;
    request.pd_h = rdma_clone_handle_value(pd.handle, {name, " PD"});
    request.send_cq_h = rdma_clone_handle_value(cq.handle,
                                                 {name, " send CQ"});
    request.recv_cq_h = rdma_clone_handle_value(cq.handle,
                                                 {name, " receive CQ"});
    attrs = rdma_qp_context_attributes::type_id::create({name, " attrs"});
    attrs.path_mtu_bytes = 4096;
    attrs.pkey = 16'hbeef;
    attrs.address_vector = rdma_address_vector::type_id::create(
      {name, " address vector"});
    attrs.address_vector.destination_mac = 48'h1122_3344_5566;
    attrs.address_vector.traffic_class = 8'h02;
    attrs.behavior = rdma_qpc_behavior::type_id::create({name, " behavior"});
    attrs.behavior.transport_version = 1;
    ext = rdma_qpc_rc_ext::type_id::create({name, " RC"});
    ext.remote_qpn = 24'h456789;
    ext.send_psn = 24'h123456;
    ext.recv_psn = 24'h654321;
    ext.retry_count = 2;
    ext.rnr_retry_count = 2;
    attrs.transport_ext = ext;
    request.context_attrs = attrs;
    return request;
  endfunction

  function automatic rdma_create_ceq_req make_create_ceq_request(
    string name,
    rdma_function_binding binding
  );
    rdma_create_ceq_req request;

    request = rdma_create_ceq_req::type_id::create(name);
    request.owner = binding.make_handle();
    request.depth = 64;
    request.vector_id = 3;
    request.ring_backing.mode = RDMA_QUEUE_BACKING_OWNED;
    return request;
  endfunction

  function automatic rdma_create_aeq_req make_create_aeq_request(
    string name,
    rdma_function_binding binding
  );
    rdma_create_aeq_req request;

    request = rdma_create_aeq_req::type_id::create(name);
    request.owner = binding.make_handle();
    request.depth = 64;
    request.vector_id = 3;
    request.ring_backing.mode = RDMA_QUEUE_BACKING_OWNED;
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
    backing.requester_bdf = binding.queue_dma.requester_bdf;
    backing.pasid_valid = binding.queue_dma.pasid_valid;
    backing.pasid = binding.queue_dma.pasid;

    ref_count = (pbl_mode == RDMA_MR_PBL1) ? 2 : 1;
    for (int unsigned i = 0; i < ref_count; i++) begin
      mapping = rdma_dma_mapping::type_id::create(
        $sformatf("%s_mapping_%0d", name, i)
      );
      mapping.function_h = binding.make_handle();
      mapping.requester_bdf = backing.requester_bdf;
      mapping.pasid_valid = backing.pasid_valid;
      mapping.pasid = backing.pasid;
      mapping.dma_domain_valid = binding.queue_dma.dma_domain_valid;
      mapping.dma_domain_id = binding.queue_dma.dma_domain_id;
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

  function automatic bit same_status_fields(
    rdma_status lhs,
    rdma_status rhs
  );
    if (lhs == null || rhs == null)
      return lhs == rhs;
    return lhs.category == rhs.category && lhs.code == rhs.code &&
           lhs.hardware_code == rhs.hardware_code &&
           lhs.hardware_code_valid == rhs.hardware_code_valid &&
           lhs.source_engine == rhs.source_engine &&
           lhs.function_uid == rhs.function_uid &&
           lhs.generation == rhs.generation &&
           lhs.resource_id == rhs.resource_id &&
           lhs.command_id == rhs.command_id && lhs.wr_id == rhs.wr_id &&
           lhs.severity == rhs.severity && lhs.retryable == rhs.retryable &&
           lhs.message == rhs.message;
  endfunction

  function automatic bit same_ticket_fields(
    rdma_cmq_ticket lhs,
    rdma_cmq_ticket rhs
  );
    if (lhs == null || rhs == null)
      return lhs == rhs;
    if (lhs.opcode_key == null || rhs.opcode_key == null)
      return lhs.opcode_key == rhs.opcode_key;
    return lhs.command_id == rhs.command_id &&
           same_handle_fields(lhs.function_h, rhs.function_h) &&
           same_handle_fields(lhs.cmq_h, rhs.cmq_h) &&
           lhs.slot_sequence == rhs.slot_sequence &&
           lhs.sq_index == rhs.sq_index && lhs.sq_wrap == rhs.sq_wrap &&
           lhs.opcode_key.profile_name == rhs.opcode_key.profile_name &&
           lhs.opcode_key.opcode == rhs.opcode_key.opcode &&
           lhs.opcode_key.variant == rhs.opcode_key.variant &&
           lhs.absolute_deadline == rhs.absolute_deadline;
  endfunction

  function automatic bit same_mapping_fields(
    rdma_dma_mapping lhs,
    rdma_dma_mapping rhs
  );
    if (lhs == null || rhs == null)
      return lhs == rhs;
    return same_handle_fields(lhs.function_h, rhs.function_h) &&
           lhs.requester_bdf == rhs.requester_bdf &&
           lhs.pasid_valid == rhs.pasid_valid && lhs.pasid == rhs.pasid &&
           lhs.dma_domain_valid == rhs.dma_domain_valid &&
           lhs.dma_domain_id == rhs.dma_domain_id &&
           lhs.backing_addr == rhs.backing_addr && lhs.iova == rhs.iova &&
           lhs.size == rhs.size && lhs.direction == rhs.direction &&
           lhs.permissions == rhs.permissions && lhs.state == rhs.state &&
           same_handle_fields(lhs.owner_h, rhs.owner_h);
  endfunction

  function automatic bit same_recovery_fields(
    rdma_recovery_record lhs,
    rdma_recovery_record rhs
  );
    if (lhs == null || rhs == null)
      return lhs == rhs;
    if (!same_handle_fields(lhs.resource_h, rhs.resource_h) ||
        lhs.hardware_presence != rhs.hardware_presence ||
        lhs.completed_steps != rhs.completed_steps ||
        lhs.pending_steps != rhs.pending_steps ||
        !same_ticket_fields(lhs.ambiguous_ticket,
                            rhs.ambiguous_ticket) ||
        !same_status_fields(lhs.primary_status, rhs.primary_status) ||
        lhs.backing_refs.size() != rhs.backing_refs.size() ||
        lhs.hmc_refs.size() != rhs.hmc_refs.size() ||
        lhs.rollback_statuses.size() != rhs.rollback_statuses.size())
      return 1'b0;
    foreach (lhs.backing_refs[i]) begin
      if (lhs.backing_refs[i] == null || rhs.backing_refs[i] == null) begin
        if (lhs.backing_refs[i] != rhs.backing_refs[i])
          return 1'b0;
      end
      else if (lhs.backing_refs[i].ownership !=
                 rhs.backing_refs[i].ownership ||
               lhs.backing_refs[i].release_complete !=
                 rhs.backing_refs[i].release_complete ||
               !same_mapping_fields(lhs.backing_refs[i].mapping,
                                    rhs.backing_refs[i].mapping))
        return 1'b0;
    end
    foreach (lhs.hmc_refs[i]) begin
      if (lhs.hmc_refs[i] == null || rhs.hmc_refs[i] == null) begin
        if (lhs.hmc_refs[i] != rhs.hmc_refs[i])
          return 1'b0;
      end
      else if (!same_handle_fields(lhs.hmc_refs[i].owner,
                                   rhs.hmc_refs[i].owner) ||
               lhs.hmc_refs[i].object_kind !=
                 rhs.hmc_refs[i].object_kind ||
               lhs.hmc_refs[i].address != rhs.hmc_refs[i].address ||
               lhs.hmc_refs[i].size != rhs.hmc_refs[i].size ||
               lhs.hmc_refs[i].first_pbl_index !=
                 rhs.hmc_refs[i].first_pbl_index ||
               lhs.hmc_refs[i].ownership != rhs.hmc_refs[i].ownership ||
               lhs.hmc_refs[i].release_complete !=
                 rhs.hmc_refs[i].release_complete)
        return 1'b0;
    end
    foreach (lhs.rollback_statuses[i]) begin
      if (!same_status_fields(lhs.rollback_statuses[i],
                              rhs.rollback_statuses[i]))
        return 1'b0;
    end
    return 1'b1;
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
      inject_host_mem ? host_mem : null, null, null, 2us
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
    int unsigned baseline_leaks,
    string expected_message = ""
  );
    rdma_dma_mapping mapping;
    rdma_mr mr;
    rdma_control_result result;
    int unsigned final_leaks;
    bit [7:0] expected_opcodes[$];

    control.alloc_and_register_mr(binding, request, dma_context, alignment,
                                  mapping, mr, result);
    expect_result(check_name, result, expected_code);
    if (expected_message != "" &&
        (result == null || result.primary_status == null ||
         result.primary_status.message != expected_message))
      `uvm_error(check_name,
                 "pre-allocation rejection diagnostic is inaccurate")
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

  task automatic setup_deregister_mr_case(
    string prefix,
    rdma_mr_pbl_mode_e pbl_mode,
    rdma_resource_ownership_e ownership,
    output rdma_control_plane_probe control,
    output rdma_fault_resource_manager manager,
    output rdma_mock_cmq_port mock_cmq,
    output rdma_mock_host_mem host_mem,
    output rdma_hmc_allocator hmc,
    output rdma_function_binding binding,
    output rdma_pd pd,
    output rdma_mr mr,
    output rdma_dma_mapping mapping,
    output rdma_hmc_fvm_addr_t hmc_address,
    output int unsigned baseline_allocations
  );
    rdma_mock_stag_key_policy key_policy;
    rdma_create_pd_req pd_request;
    rdma_register_mr_req request;
    rdma_dma_request_context dma_context;
    rdma_mr_backing_desc backing;
    rdma_backing_ref backing_ref;
    rdma_backing_ref backing_ref2;
    rdma_hmc_ref hmc_ref;
    rdma_hmc_fvm_addr_t hmc_base;
    rdma_dma_mapping mapping2;
    rdma_control_result result;
    rdma_status status;
    longint unsigned lease_size;

    control = rdma_control_plane_probe::type_id::create(
      {prefix, "_control"}
    );
    manager = rdma_fault_resource_manager::type_id::create(
      {prefix, "_manager"}
    );
    mock_cmq = rdma_mock_cmq_port::type_id::create({prefix, "_cmq"});
    key_policy = rdma_mock_stag_key_policy::type_id::create(
      {prefix, "_policy"}
    );
    key_policy.fixed_key = 8'h6d;
    host_mem = rdma_mock_host_mem::type_id::create({prefix, "_mem"});
    hmc = rdma_hmc_allocator::type_id::create({prefix, "_hmc"});
    hmc_base.value = 64'h0000_0007_0000_0000;
    status = hmc.configure(hmc_base, 64'h0001_0000);
    expect_status({prefix, "_HMC_CONFIGURE"}, status, RDMA_SC_OK);
    binding = make_active_binding(
      {prefix, "_binding"}, 64'hd900_0000_0000_0001,
      32'hd900_0101, 93
    );
    status = control.configure(manager, mock_cmq, key_policy, host_mem,
                               hmc, null, 4us);
    expect_status({prefix, "_CONFIGURE"}, status, RDMA_SC_OK);
    pd_request = make_create_pd_request({prefix, "_pd_request"}, binding);
    control.create_pd(binding, pd_request, pd, result);
    expect_result({prefix, "_PD_CREATE"}, result, RDMA_SC_OK);

    request = make_register_mr_request({prefix, "_request"}, binding, pd);
    request.iova.value = host_mem.next_address;
    dma_context = make_dma_context({prefix, "_dma_context"}, binding);
    baseline_allocations = host_mem.live_allocations();
    status = host_mem.allocate(
      dma_context, int'(request.length), 4096, RDMA_DMA_DEVICE_READ, mapping
    );
    expect_status({prefix, "_MAP_ALLOCATE"}, status, RDMA_SC_OK);

    backing = rdma_mr_backing_desc::type_id::create({prefix, "_backing"});
    backing.function_h = binding.make_handle();
    backing.requester_bdf = binding.pcie.bdf;
    backing.pasid_valid = dma_context.pasid_valid;
    backing.pasid = dma_context.pasid;
    backing_ref = rdma_backing_ref::type_id::create(
      {prefix, "_backing_ref"}
    );
    backing_ref.mapping = mapping;
    backing_ref.ownership = ownership;
    backing_ref.release_complete = 1'b0;
    backing.backing_refs.push_back(backing_ref);
    backing.page_layout.pbl_mode = pbl_mode;
    if (pbl_mode == RDMA_MR_PBL0)
      backing.page_layout.pba0 = mapping.backing_addr;
    else if (pbl_mode == RDMA_MR_PBL1) begin
      status = host_mem.allocate(
        dma_context, int'(request.length), 4096, RDMA_DMA_DEVICE_READ,
        mapping2
      );
      expect_status({prefix, "_MAP2_ALLOCATE"}, status, RDMA_SC_OK);
      mapping2.iova = request.iova;
      backing_ref2 = rdma_backing_ref::type_id::create(
        {prefix, "_backing_ref2"}
      );
      backing_ref2.mapping = mapping2;
      backing_ref2.ownership = ownership;
      backing_ref2.release_complete = 1'b0;
      backing.backing_refs.push_back(backing_ref2);
      backing.page_layout.pba0 = mapping.backing_addr;
      backing.page_layout.pba1 = mapping2.backing_addr;
    end
    else if (pbl_mode == RDMA_MR_PBL2) begin
      status = hmc.allocate(binding.make_handle(), RDMA_RESOURCE_MR,
                            64'h2000, 64'h1000, hmc_address);
      expect_status({prefix, "_HMC_ALLOCATE"}, status, RDMA_SC_OK);
      status = hmc.lookup(binding.make_handle(), RDMA_RESOURCE_MR,
                          hmc_address, lease_size);
      expect_status({prefix, "_HMC_LOOKUP"}, status, RDMA_SC_OK);
      hmc_ref = rdma_hmc_ref::type_id::create({prefix, "_hmc_ref"});
      hmc_ref.owner = binding.make_handle();
      hmc_ref.object_kind = RDMA_RESOURCE_MR;
      hmc_ref.address = hmc_address;
      hmc_ref.size = lease_size;
      hmc_ref.first_pbl_index = 28'h000_0900;
      hmc_ref.ownership = ownership;
      hmc_ref.release_complete = 1'b0;
      backing.hmc_refs.push_back(hmc_ref);
      backing.page_layout.first_pbl_index = hmc_ref.first_pbl_index;
    end

    if (ownership == RDMA_OWNERSHIP_CONTROL_PLANE)
      control.register_owned_mr_for_test(
        binding, request, backing, mr, result
      );
    else
      control.register_mr(binding, request, backing, mr, result);
    expect_result({prefix, "_REGISTER"}, result, RDMA_SC_OK);
    if (mr == null || mr.handle == null ||
        mr.state != RDMA_RESOURCE_ACTIVE)
      `uvm_error({prefix, "_REGISTER"},
                 "deregister fixture did not publish an ACTIVE MR")
    mock_cmq.calls.delete();
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
                                   null, 1us);
    expect_status("CONFIGURE_NULL_MANAGER", status,
                  RDMA_SC_INVALID_ARGUMENT);
    status = controls[1].configure(managers[1], null, policies[1], mem, hmc,
                                   null, 1us);
    expect_status("CONFIGURE_NULL_CMQ", status, RDMA_SC_INVALID_ARGUMENT);
    status = controls[2].configure(managers[2], cmqs[2], null, mem, hmc,
                                   null, 1us);
    expect_status("CONFIGURE_NULL_POLICY", status,
                  RDMA_SC_INVALID_ARGUMENT);
    status = controls[3].configure(managers[3], cmqs[3], policies[3], mem,
                                   hmc, null, 0ns);
    expect_status("CONFIGURE_ZERO_TIMEOUT", status,
                  RDMA_SC_INVALID_ARGUMENT);
    status = controls[4].configure(managers[4], cmqs[4], policies[4], mem,
                                   hmc, null, 1us);
    expect_status("CONFIGURE_OK", status, RDMA_SC_OK);
    status = controls[4].configure(managers[4], cmqs[4], policies[4], mem,
                                   hmc, null, 1us);
    expect_status("CONFIGURE_REPEAT", status, RDMA_SC_INVALID_STATE);
    status = controls[5].configure(managers[5], cmqs[5], policies[5], null,
                                   null, null, 1us);
    expect_status("CONFIGURE_OPTIONAL_ADAPTERS", status, RDMA_SC_OK);
    status = controls[6].configure(
      .resource_manager(managers[6]),
      .cmq_port(cmqs[6]),
      .key_policy(policies[6]),
      .host_mem(null),
      .hmc_allocator(null),
      .context_backing(null),
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
    int unsigned saved_dma_domain_id;
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

    saved_dma_domain_id = dma_context.dma_domain_id;
    dma_context.dma_domain_id++;
    expect_owned_preallocate_reject(
      "OWNED_DOMAIN_MISMATCH", control, manager, mock_cmq, host_mem,
      binding, request, dma_context, 4096, RDMA_SC_DMA_TRANSLATION,
      baseline_allocations, baseline_leaks,
      "owned MR DMA authority does not match Function"
    );
    dma_context.dma_domain_id = saved_dma_domain_id;

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
    rdma_status_code_e expected_rollback;
    rdma_resource_state_e expected_state;
    rdma_hw_presence_e expected_presence;
    int unsigned baseline_allocations;
    int unsigned baseline_leaks;
    int unsigned final_leaks;
    int unsigned release_calls;
    bit [7:0] expected_opcodes[$];
    bit rollback_failure;
    bit expected_ambiguous_ticket;

    setup_owned_mr_case(
      {"owned_", failure_kind}, 1'b1, control, manager, mock_cmq,
      key_policy, host_mem, binding, request, dma_context, pd,
      baseline_allocations, baseline_leaks
    );
    if (pd == null)
      return;
    rollback_failure = 1'b0;
    expected_ambiguous_ticket = 1'b0;
    expected_primary = RDMA_SC_INVALID_STATE;
    expected_rollback = RDMA_SC_OK;
    expected_presence = RDMA_HW_PRESENCE_ABSENT;
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
        expected_rollback = RDMA_SC_UNKNOWN_HW_ERROR;
        expected_presence = RDMA_HW_PRESENCE_PRESENT;
        expected_state = RDMA_RESOURCE_ERROR;
      end
      "deregister_timeout": begin
        injected_status = rdma_status::make(
          RDMA_SC_INVALID_STATE,
          "injected commit before owned deregister timeout"
        );
        status = manager.fail_next_transition(
          "commit_programmed", injected_status
        );
        expect_status("OWNED_DEREG_TIMEOUT_COMMIT_INJECT", status,
                      RDMA_SC_OK);
        mock_cmq.timeout_opcode(XTR_V1_OP_MR_DEREGISTER);
        expected_opcodes.push_back(XTR_V1_OP_KEY_ALLOC);
        expected_opcodes.push_back(XTR_V1_OP_MR_DEREGISTER);
        rollback_failure = 1'b1;
        expected_rollback = RDMA_SC_TIMEOUT;
        expected_presence = RDMA_HW_PRESENCE_UNKNOWN;
        expected_ambiguous_ticket = 1'b1;
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
          result.rollback_statuses[0].code != expected_rollback ||
          mr == null || mr.state != RDMA_RESOURCE_ERROR ||
          recovery == null ||
          recovery.hardware_presence != expected_presence ||
          recovery.pending_steps.size() != 1 ||
          recovery.pending_steps[0] != RDMA_CTRL_STEP_HW_MR_DEREGISTERED ||
          (expected_ambiguous_ticket &&
           recovery.ambiguous_ticket == null) ||
          (!expected_ambiguous_ticket &&
           recovery.ambiguous_ticket != null))
        `uvm_error("OWNED_DEREG_RECOVERY",
                   "rollback failure did not retain one owned ERROR MR")
      else if (expected_ambiguous_ticket &&
               mock_cmq.calls[1] != null &&
               mock_cmq.calls[1].ticket != null &&
               (recovery.ambiguous_ticket == mock_cmq.calls[1].ticket ||
                recovery.ambiguous_ticket.command_id !=
                  mock_cmq.calls[1].ticket.command_id))
        `uvm_error("OWNED_DEREG_RECOVERY_TICKET",
                   "rollback timeout ticket is aliased or corrupted")
    end
    else if (host_mem.live_allocations() != baseline_allocations ||
             final_leaks != baseline_leaks || release_calls != 1 ||
             result == null || !result.final_resource_state_known ||
             result.final_resource_state != expected_state ||
             result.recovery_required ||
             result.rollback_statuses.size() != 0 || mr != null ||
             result.completed_steps.size() == 0 ||
             result.completed_steps[$] != RDMA_CTRL_STEP_RESOURCE_RELEASED)
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

  task automatic check_creation_deregister_late_failure_deferred_retry();
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
    rdma_mr live_mr;
    rdma_resource resource;
    rdma_control_result result;
    rdma_control_result recovery_result;
    rdma_control_result second_recovery_result;
    rdma_control_result third_recovery_result;
    rdma_recovery_record recovery;
    rdma_status injected_status;
    rdma_status status;
    int unsigned baseline_allocations;
    int unsigned baseline_leaks;
    int unsigned final_leaks;
    bit [7:0] expected_opcodes[$];

    setup_owned_mr_case(
      "creation_dereg_late_failure", 1'b1, control, manager, mock_cmq,
      key_policy, host_mem, binding, request, dma_context, pd,
      baseline_allocations, baseline_leaks
    );
    if (pd == null)
      return;
    injected_status = rdma_status::make(
      RDMA_SC_INVALID_STATE,
      "injected creation commit before deregister timeout"
    );
    status = manager.fail_next_transition(
      "commit_programmed", injected_status
    );
    expect_status("CREATION_DEREG_LATE_COMMIT_INJECT", status,
                  RDMA_SC_OK);
    mock_cmq.timeout_opcode(XTR_V1_OP_MR_DEREGISTER);
    control.alloc_and_register_mr(binding, request, dma_context, 4096,
                                  mapping, mr, result);
    expect_recovery_result("CREATION_DEREG_LATE_TIMEOUT", result,
                           RDMA_SC_INVALID_STATE);
    if (result == null || result.resource_h == null)
      return;
    status = manager.lookup_recovery(result.resource_h, recovery);
    expect_status("CREATION_DEREG_LATE_TIMEOUT_RECOVERY", status,
                  RDMA_SC_OK);
    expected_opcodes.push_back(XTR_V1_OP_KEY_ALLOC);
    expected_opcodes.push_back(XTR_V1_OP_MR_DEREGISTER);
    expect_cmq_opcodes("CREATION_DEREG_LATE_TIMEOUT_ORDER", mock_cmq,
                       expected_opcodes);
    if (recovery == null || recovery.ambiguous_ticket == null ||
        recovery.hardware_presence != RDMA_HW_PRESENCE_UNKNOWN ||
        recovery.pending_steps.size() != 1 ||
        recovery.pending_steps[0] !=
          RDMA_CTRL_STEP_HW_MR_DEREGISTERED ||
        recovery.primary_status == null ||
        recovery.primary_status.code != RDMA_SC_INVALID_STATE ||
        host_mem.calls.size() != 1 ||
        host_mem.calls[0].method_name != "allocate")
      `uvm_error("CREATION_DEREG_LATE_TIMEOUT_STATE",
                 "creation timeout did not retain its owned ERROR MR")
    if (recovery == null || recovery.ambiguous_ticket == null)
      return;

    injected_status = rdma_status::make(
      RDMA_SC_UNKNOWN_HW_ERROR,
      "late creation MR_DEREGISTER terminal failure"
    );
    mock_cmq.push_late_completion(recovery.ambiguous_ticket,
                                  injected_status);
    control.recover_resource(binding, result.resource_h, recovery_result);
    expect_recovery_result("CREATION_DEREG_LATE_FIRST", recovery_result,
                           RDMA_SC_INVALID_STATE);
    status = manager.lookup(result.resource_h, resource);
    expect_status("CREATION_DEREG_LATE_FIRST_LOOKUP", status, RDMA_SC_OK);
    live_mr = null;
    void'($cast(live_mr, resource));
    status = manager.lookup_recovery(result.resource_h, recovery);
    expect_status("CREATION_DEREG_LATE_FIRST_RECOVERY", status,
                  RDMA_SC_OK);
    if (live_mr == null || live_mr.state != RDMA_RESOURCE_ERROR ||
        recovery == null ||
        recovery.hardware_presence != RDMA_HW_PRESENCE_PRESENT ||
        recovery.ambiguous_ticket != null ||
        recovery.pending_steps.size() != 1 ||
        recovery.pending_steps[0] !=
          RDMA_CTRL_STEP_HW_MR_DEREGISTERED ||
        recovery.primary_status == null ||
        recovery.primary_status.code != RDMA_SC_INVALID_STATE ||
        recovery.rollback_statuses.size() != 2 ||
        recovery.rollback_statuses[0] == null ||
        recovery.rollback_statuses[0].code != RDMA_SC_TIMEOUT ||
        recovery.rollback_statuses[1] == null ||
        recovery.rollback_statuses[1].code !=
          RDMA_SC_UNKNOWN_HW_ERROR ||
        mock_cmq.calls.size() != 2 || host_mem.calls.size() != 1 ||
        host_mem.live_allocations() != baseline_allocations + 1)
      `uvm_error("CREATION_DEREG_LATE_FIRST_STATE",
                 "late failure replayed deregister in the same call")
    if (live_mr == null || recovery == null)
      return;

    control.recover_resource(binding, result.resource_h,
                             second_recovery_result);
    expect_completed_recovery("CREATION_DEREG_LATE_SECOND",
                              second_recovery_result,
                              RDMA_SC_INVALID_STATE);
    expected_opcodes.push_back(XTR_V1_OP_MR_DEREGISTER);
    expect_cmq_opcodes("CREATION_DEREG_LATE_SECOND_ORDER", mock_cmq,
                       expected_opcodes);
    status = manager.lookup(result.resource_h, resource);
    expect_status("CREATION_DEREG_LATE_SECOND_RELEASED", status,
                  RDMA_SC_INVALID_STATE);
    void'(manager.check_leaks(final_leaks, binding.make_handle()));
    if (host_mem.calls.size() != 2 ||
        host_mem.calls[1].method_name != "release" ||
        host_mem.live_allocations() != baseline_allocations ||
        final_leaks != baseline_leaks)
      `uvm_error("CREATION_DEREG_LATE_SECOND_STATE",
                 "deferred retry did not release owned state once")

    control.recover_resource(binding, result.resource_h,
                             third_recovery_result);
    expect_result("CREATION_DEREG_LATE_THIRD", third_recovery_result,
                  RDMA_SC_INVALID_STATE);
    if (mock_cmq.calls.size() != 3 || host_mem.calls.size() != 2 ||
        host_mem.live_allocations() != baseline_allocations)
      `uvm_error("CREATION_DEREG_LATE_THIRD_STATE",
                 "completed creation recovery repeated a side effect")
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
    rdma_control_result recovery_result;
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
    expect_recovery_result("OWNED_PRESTAGE_RELEASE", result,
                           RDMA_SC_INVALID_STATE);
    expect_cmq_opcodes("OWNED_PRESTAGE_RELEASE_OPCODES", mock_cmq,
                       expected_opcodes);
    registry_resource = null;
    recovery = null;
    if (result != null && result.resource_h != null) begin
      status = manager.lookup(result.resource_h, registry_resource);
      expect_status("OWNED_PRESTAGE_RESOURCE_ERROR", status, RDMA_SC_OK);
      status = manager.lookup_recovery(result.resource_h, recovery);
      expect_status("OWNED_PRESTAGE_RECOVERY", status, RDMA_SC_OK);
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

    if (result == null ||
        !result.final_resource_state_known ||
        result.final_resource_state != RDMA_RESOURCE_ERROR ||
        !result.recovery_required || result.rollback_statuses.size() != 1 ||
        result.rollback_statuses[0] == null ||
        result.rollback_statuses[0].code != RDMA_SC_UNKNOWN_HW_ERROR ||
        mapping != null || mr == null || mr.state != RDMA_RESOURCE_ERROR ||
        registry_mr == null || registry_mr.state != RDMA_RESOURCE_ERROR ||
        recovery == null ||
        recovery.hardware_presence != RDMA_HW_PRESENCE_ABSENT ||
        recovery.pending_steps.size() != 1 ||
        recovery.pending_steps[0] != RDMA_CTRL_STEP_BACKING_RELEASED ||
        recovery.backing_refs.size() != 1 ||
        recovery.backing_refs[0] == null ||
        recovery.backing_refs[0].release_complete ||
        recovery.backing_refs[0].mapping == null ||
        recovery.backing_refs[0].mapping.state != RDMA_MAPPING_ACTIVE ||
        host_mem.live_allocations() != baseline_allocations + 1 ||
        final_leaks != baseline_leaks + 1 || release_calls != 1 ||
        manager.release_reserved_calls != 0)
      `uvm_error(
        "OWNED_PRESTAGE_RELEASE_STATE",
        "pre-stage backing failure was not durably retained"
      )

    if (result != null && result.resource_h != null)
      control.recover_resource(binding, result.resource_h, recovery_result);
    else
      recovery_result = null;
    expect_completed_recovery("OWNED_PRESTAGE_RECOVER", recovery_result,
                              RDMA_SC_INVALID_STATE);
    if (result != null && result.resource_h != null) begin
      status = manager.lookup(result.resource_h, registry_resource);
      expect_status("OWNED_PRESTAGE_RELEASED", status,
                    RDMA_SC_INVALID_STATE);
      status = manager.lookup_recovery(result.resource_h, recovery);
      expect_status("OWNED_PRESTAGE_RECOVERY_CLEARED", status,
                    RDMA_SC_INVALID_STATE);
    end
    release_calls = 0;
    foreach (host_mem.calls[i])
      if (host_mem.calls[i] != null &&
          host_mem.calls[i].method_name == "release")
        release_calls++;
    void'(manager.check_leaks(final_leaks, binding.make_handle()));
    if (host_mem.live_allocations() != baseline_allocations ||
        final_leaks != baseline_leaks || release_calls != 2 ||
        manager.release_reserved_calls != 0)
      `uvm_error("OWNED_PRESTAGE_RECOVER_STATE",
                 "durable pre-stage recovery did not finish exactly once")
  endtask

  task automatic check_owned_mr_prestage_double_cleanup_failure();
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
    rdma_recovery_record recovery;
    rdma_control_result result;
    rdma_control_result recovery_result;
    rdma_status injected_status;
    rdma_status status;
    int unsigned baseline_allocations;
    int unsigned baseline_leaks;
    int unsigned final_leaks;
    int unsigned release_calls;
    bit [7:0] expected_opcodes[$];

    setup_owned_mr_case(
      "owned_prestage_double", 1'b1, control, manager, mock_cmq,
      key_policy, host_mem, binding, request, dma_context, pd,
      baseline_allocations, baseline_leaks
    );
    if (pd == null)
      return;

    injected_status = rdma_status::make(
      RDMA_SC_INVALID_STATE, "injected owned STAG derivation failure"
    );
    status = key_policy.fail_next(injected_status);
    expect_status("OWNED_PRESTAGE_DOUBLE_KEY_INJECT", status, RDMA_SC_OK);
    injected_status = rdma_status::make(
      RDMA_SC_UNKNOWN_HW_ERROR, "injected pre-stage mapping release failure"
    );
    status = host_mem.fail_next("release", injected_status);
    expect_status("OWNED_PRESTAGE_DOUBLE_MAPPING_INJECT", status,
                  RDMA_SC_OK);
    injected_status = rdma_status::make(
      RDMA_SC_RESOURCE_BUSY, "injected reservation release failure"
    );
    status = manager.fail_next_transition("release_reserved",
                                          injected_status);
    expect_status("OWNED_PRESTAGE_DOUBLE_RESERVATION_INJECT", status,
                  RDMA_SC_OK);

    control.alloc_and_register_mr(binding, request, dma_context, 4096,
                                  mapping, mr, result);
    expect_recovery_result("OWNED_PRESTAGE_DOUBLE", result,
                           RDMA_SC_INVALID_STATE);
    expect_cmq_opcodes("OWNED_PRESTAGE_DOUBLE_OPCODES", mock_cmq,
                       expected_opcodes);
    recovery = null;
    registry_resource = null;
    if (result != null && result.resource_h != null) begin
      status = manager.lookup(result.resource_h, registry_resource);
      expect_status("OWNED_PRESTAGE_DOUBLE_LOOKUP", status, RDMA_SC_OK);
      status = manager.lookup_recovery(result.resource_h, recovery);
      expect_status("OWNED_PRESTAGE_DOUBLE_RECOVERY", status, RDMA_SC_OK);
    end
    void'(manager.check_leaks(final_leaks, binding.make_handle()));
    release_calls = 0;
    foreach (host_mem.calls[i])
      if (host_mem.calls[i] != null &&
          host_mem.calls[i].method_name == "release")
        release_calls++;
    if (result == null || result.resource_h == null || mapping != null ||
        mr == null || mr.state != RDMA_RESOURCE_ERROR ||
        registry_resource == null ||
        registry_resource.state != RDMA_RESOURCE_ERROR ||
        !result.recovery_required ||
        result.final_resource_state != RDMA_RESOURCE_ERROR ||
        !result.final_resource_state_known ||
        result.rollback_statuses.size() != 1 ||
        result.rollback_statuses[0] == null ||
        result.rollback_statuses[0].code != RDMA_SC_UNKNOWN_HW_ERROR ||
        recovery == null ||
        recovery.hardware_presence != RDMA_HW_PRESENCE_ABSENT ||
        recovery.pending_steps.size() != 1 ||
        recovery.pending_steps[0] != RDMA_CTRL_STEP_BACKING_RELEASED ||
        recovery.backing_refs.size() != 1 ||
        recovery.backing_refs[0] == null ||
        recovery.backing_refs[0].mapping == null ||
        recovery.backing_refs[0].release_complete ||
        recovery.backing_refs[0].mapping.state != RDMA_MAPPING_ACTIVE ||
        host_mem.live_allocations() != baseline_allocations + 1 ||
        final_leaks != baseline_leaks + 1 || release_calls != 1 ||
        manager.release_reserved_calls != 0)
      `uvm_error("OWNED_PRESTAGE_DOUBLE_STATE",
                 "double cleanup failure lost durable manager authority")

    injected_status = rdma_status::make(
      RDMA_SC_RESOURCE_BUSY, "injected reserved recovery release failure"
    );
    status = host_mem.fail_next("release", injected_status);
    expect_status("OWNED_PRESTAGE_DOUBLE_RECOVER_INJECT", status,
                  RDMA_SC_OK);
    if (result != null && result.resource_h != null)
      control.recover_resource(binding, result.resource_h, recovery_result);
    else
      recovery_result = null;
    expect_recovery_result("OWNED_PRESTAGE_DOUBLE_RETRY", recovery_result,
                           RDMA_SC_INVALID_STATE);
    recovery = null;
    registry_resource = null;
    if (result != null && result.resource_h != null) begin
      status = manager.lookup(result.resource_h, registry_resource);
      expect_status("OWNED_PRESTAGE_DOUBLE_RETRY_LOOKUP", status,
                    RDMA_SC_OK);
      status = manager.lookup_recovery(result.resource_h, recovery);
      expect_status("OWNED_PRESTAGE_DOUBLE_RETRY_RECORD", status,
                    RDMA_SC_OK);
    end
    void'(manager.check_leaks(final_leaks, binding.make_handle()));
    if (registry_resource == null ||
        registry_resource.state != RDMA_RESOURCE_ERROR || recovery == null ||
        recovery.pending_steps.size() != 1 ||
        recovery.pending_steps[0] != RDMA_CTRL_STEP_BACKING_RELEASED ||
        host_mem.live_allocations() != baseline_allocations + 1 ||
        final_leaks != baseline_leaks + 1 ||
        manager.release_reserved_calls != 0)
      `uvm_error("OWNED_PRESTAGE_DOUBLE_RETRY_STATE",
                 "failed retry did not retain durable recovery authority")

    injected_status = rdma_status::make(
      RDMA_SC_RESOURCE_BUSY, "injected reserved completion failure"
    );
    status = manager.fail_next_transition("complete_reserved_error",
                                          injected_status);
    expect_status("OWNED_PRESTAGE_DOUBLE_COMPLETE_INJECT", status,
                  RDMA_SC_OK);
    if (result != null && result.resource_h != null)
      control.recover_resource(binding, result.resource_h, recovery_result);
    else
      recovery_result = null;
    expect_recovery_result(
      "OWNED_PRESTAGE_DOUBLE_COMPLETE_RETRY", recovery_result,
      RDMA_SC_INVALID_STATE
    );
    recovery = null;
    registry_resource = null;
    if (result != null && result.resource_h != null) begin
      status = manager.lookup(result.resource_h, registry_resource);
      expect_status("OWNED_PRESTAGE_DOUBLE_COMPLETE_LOOKUP", status,
                    RDMA_SC_OK);
      status = manager.lookup_recovery(result.resource_h, recovery);
      expect_status("OWNED_PRESTAGE_DOUBLE_COMPLETE_RECORD", status,
                    RDMA_SC_OK);
    end
    void'(manager.check_leaks(final_leaks, binding.make_handle()));
    release_calls = 0;
    foreach (host_mem.calls[i])
      if (host_mem.calls[i] != null &&
          host_mem.calls[i].method_name == "release")
        release_calls++;
    if (recovery_result == null ||
        !recovery_result.recovery_required ||
        !recovery_result.final_resource_state_known ||
        recovery_result.final_resource_state != RDMA_RESOURCE_ERROR ||
        registry_resource == null ||
        registry_resource.state != RDMA_RESOURCE_ERROR || recovery == null ||
        recovery.pending_steps.size() != 1 ||
        recovery.pending_steps[0] != RDMA_CTRL_STEP_BACKING_RELEASED ||
        recovery.backing_refs.size() != 1 ||
        recovery.backing_refs[0] == null ||
        recovery.backing_refs[0].release_complete ||
        recovery.backing_refs[0].mapping == null ||
        recovery.backing_refs[0].mapping.state != RDMA_MAPPING_ACTIVE ||
        host_mem.live_allocations() != baseline_allocations ||
        final_leaks != baseline_leaks + 1 || release_calls != 3 ||
        manager.release_reserved_calls != 0)
      `uvm_error("OWNED_PRESTAGE_DOUBLE_COMPLETE_STATE",
                 "post-release completion failure was not retryable")

    if (result != null && result.resource_h != null)
      control.recover_resource(binding, result.resource_h, recovery_result);
    else
      recovery_result = null;
    expect_completed_recovery("OWNED_PRESTAGE_DOUBLE_RECOVER",
                              recovery_result, RDMA_SC_INVALID_STATE);
    if (result != null && result.resource_h != null) begin
      status = manager.lookup(result.resource_h, registry_resource);
      expect_status("OWNED_PRESTAGE_DOUBLE_RELEASED", status,
                    RDMA_SC_INVALID_STATE);
    end
    void'(manager.check_leaks(final_leaks, binding.make_handle()));
    release_calls = 0;
    foreach (host_mem.calls[i])
      if (host_mem.calls[i] != null &&
          host_mem.calls[i].method_name == "release")
        release_calls++;
    if (host_mem.live_allocations() != baseline_allocations ||
        final_leaks != baseline_leaks || release_calls != 3 ||
        manager.release_reserved_calls != 0)
      `uvm_error("OWNED_PRESTAGE_DOUBLE_RECOVER_STATE",
                 "reserved ERROR recovery did not finish exactly once")
  endtask

  task automatic check_owned_recovery_status_accumulation();
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
    rdma_resource resource;
    rdma_control_result result;
    rdma_control_result recovery_result;
    rdma_control_result second_recovery_result;
    rdma_recovery_record recovery;
    rdma_status primary_failure;
    rdma_status old_rollback_failure;
    rdma_status new_rollback_failure;
    rdma_status status;
    int unsigned baseline_allocations;
    int unsigned baseline_leaks;

    setup_owned_mr_case(
      "owned_recovery_accumulate", 1'b1, control, manager, mock_cmq,
      key_policy, host_mem, binding, request, dma_context, pd,
      baseline_allocations, baseline_leaks
    );
    if (pd == null)
      return;

    primary_failure = rdma_status::make(
      RDMA_SC_INVALID_STATE, "injected activation primary failure"
    );
    status = manager.fail_next_transition("activate", primary_failure);
    expect_status("RECOVERY_ACCUMULATE_PRIMARY_INJECT", status, RDMA_SC_OK);
    old_rollback_failure = rdma_status::make(
      RDMA_SC_UNKNOWN_HW_ERROR, "injected original rollback release failure"
    );
    status = host_mem.fail_next("release", old_rollback_failure);
    expect_status("RECOVERY_ACCUMULATE_OLD_INJECT", status, RDMA_SC_OK);

    control.alloc_and_register_mr(binding, request, dma_context, 4096,
                                  mapping, mr, result);
    expect_recovery_result("RECOVERY_ACCUMULATE_SETUP", result,
                           RDMA_SC_INVALID_STATE);
    status = manager.lookup_recovery(result.resource_h, recovery);
    expect_status("RECOVERY_ACCUMULATE_SETUP_RECORD", status, RDMA_SC_OK);
    if (recovery == null || recovery.primary_status == null ||
        recovery.primary_status.code != RDMA_SC_INVALID_STATE ||
        recovery.rollback_statuses.size() != 1 ||
        recovery.rollback_statuses[0] == null ||
        recovery.rollback_statuses[0].code != RDMA_SC_UNKNOWN_HW_ERROR ||
        recovery.pending_steps.size() != 1 ||
        recovery.pending_steps[0] != RDMA_CTRL_STEP_BACKING_RELEASED ||
        recovery.hardware_presence != RDMA_HW_PRESENCE_ABSENT ||
        mock_cmq.calls.size() != 2 || host_mem.calls.size() != 2)
      `uvm_error("RECOVERY_ACCUMULATE_SETUP_STATE",
                 "setup did not retain the original rollback history")

    new_rollback_failure = rdma_status::make(
      RDMA_SC_RESOURCE_BUSY, "injected recovery release failure"
    );
    status = host_mem.fail_next("release", new_rollback_failure);
    expect_status("RECOVERY_ACCUMULATE_NEW_INJECT", status, RDMA_SC_OK);
    control.recover_resource(binding, result.resource_h, recovery_result);
    expect_recovery_result("RECOVERY_ACCUMULATE_RETRY", recovery_result,
                           RDMA_SC_INVALID_STATE);
    status = manager.lookup_recovery(result.resource_h, recovery);
    expect_status("RECOVERY_ACCUMULATE_RETRY_RECORD", status, RDMA_SC_OK);
    if (recovery_result.rollback_statuses.size() != 2 ||
        recovery_result.rollback_statuses[0] == null ||
        recovery_result.rollback_statuses[0].code !=
          RDMA_SC_UNKNOWN_HW_ERROR ||
        recovery_result.rollback_statuses[1] == null ||
        recovery_result.rollback_statuses[1].code != RDMA_SC_RESOURCE_BUSY ||
        recovery == null || recovery.primary_status == null ||
        recovery.primary_status.code != RDMA_SC_INVALID_STATE ||
        recovery.rollback_statuses.size() != 2 ||
        recovery.rollback_statuses[0] == null ||
        recovery.rollback_statuses[0].code != RDMA_SC_UNKNOWN_HW_ERROR ||
        recovery.rollback_statuses[1] == null ||
        recovery.rollback_statuses[1].code != RDMA_SC_RESOURCE_BUSY ||
        recovery.pending_steps.size() != 1 ||
        recovery.pending_steps[0] != RDMA_CTRL_STEP_BACKING_RELEASED ||
        mock_cmq.calls.size() != 2 || host_mem.calls.size() != 3 ||
        host_mem.live_allocations() != baseline_allocations + 1)
      `uvm_error("RECOVERY_ACCUMULATE_RETRY_STATE",
                 "recovery replaced primary or rollback history")

    control.recover_resource(binding, result.resource_h, recovery_result);
    expect_completed_recovery("RECOVERY_ACCUMULATE_COMPLETE",
                              recovery_result, RDMA_SC_INVALID_STATE);
    status = manager.lookup(result.resource_h, resource);
    expect_status("RECOVERY_ACCUMULATE_RELEASED", status,
                  RDMA_SC_INVALID_STATE);
    if (recovery_result.rollback_statuses.size() != 2 ||
        recovery_result.rollback_statuses[0] == null ||
        recovery_result.rollback_statuses[0].code !=
          RDMA_SC_UNKNOWN_HW_ERROR ||
        recovery_result.rollback_statuses[1] == null ||
        recovery_result.rollback_statuses[1].code != RDMA_SC_RESOURCE_BUSY ||
        mock_cmq.calls.size() != 2 || host_mem.calls.size() != 4 ||
        host_mem.live_allocations() != baseline_allocations)
      `uvm_error("RECOVERY_ACCUMULATE_COMPLETE_STATE",
                 "successful retry lost history or repeated hardware")
    control.recover_resource(binding, result.resource_h,
                             second_recovery_result);
    expect_result("RECOVERY_ACCUMULATE_SECOND", second_recovery_result,
                  RDMA_SC_INVALID_STATE);
    if (mock_cmq.calls.size() != 2 || host_mem.calls.size() != 4)
      `uvm_error("RECOVERY_ACCUMULATE_IDEMPOTENT",
                 "released resource repeated a recovery side effect")
  endtask

  task automatic check_owned_recovery_completion_hook_guard();
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
    rdma_recovery_record recovery;
    rdma_control_result result;
    rdma_control_result recovery_result;
    rdma_status injected_status;
    rdma_status status;
    uvm_factory factory;
    longint unsigned canonical_size;
    int unsigned baseline_allocations;
    int unsigned baseline_leaks;
    int unsigned final_leaks;
    int unsigned release_calls;

    factory = uvm_factory::get();
    factory.set_type_override_by_type(
      rdma_mock_dma_mapping::get_type(),
      rdma_cp_mutating_completion_mapping::get_type()
    );
    setup_owned_mr_case(
      "owned_completion_hook_guard", 1'b1, control, manager, mock_cmq,
      key_policy, host_mem, binding, request, dma_context, pd,
      baseline_allocations, baseline_leaks
    );
    if (pd == null)
      return;

    injected_status = rdma_status::make(
      RDMA_SC_INVALID_STATE, "injected guarded-query key failure"
    );
    status = key_policy.fail_next(injected_status);
    expect_status("COMPLETION_HOOK_KEY_INJECT", status, RDMA_SC_OK);
    injected_status = rdma_status::make(
      RDMA_SC_UNKNOWN_HW_ERROR,
      "injected guarded-query mapping release failure"
    );
    status = host_mem.fail_next("release", injected_status);
    expect_status("COMPLETION_HOOK_RELEASE_INJECT", status, RDMA_SC_OK);
    injected_status = rdma_status::make(
      RDMA_SC_RESOURCE_BUSY,
      "injected guarded-query reservation release failure"
    );
    status = manager.fail_next_transition("release_reserved",
                                          injected_status);
    expect_status("COMPLETION_HOOK_RESERVATION_INJECT", status,
                  RDMA_SC_OK);

    control.alloc_and_register_mr(binding, request, dma_context, 4096,
                                  mapping, mr, result);
    expect_recovery_result("COMPLETION_HOOK_SETUP", result,
                           RDMA_SC_INVALID_STATE);
    recovery = null;
    if (result != null && result.resource_h != null) begin
      status = manager.lookup_recovery(result.resource_h, recovery);
      expect_status("COMPLETION_HOOK_SETUP_RECORD", status, RDMA_SC_OK);
    end
    if (recovery == null || recovery.backing_refs.size() != 1 ||
        recovery.backing_refs[0] == null ||
        recovery.backing_refs[0].mapping == null) begin
      `uvm_error("COMPLETION_HOOK_SETUP_STATE",
                 "guarded-query setup lost backing recovery authority")
      return;
    end
    canonical_size = recovery.backing_refs[0].mapping.size;

    rdma_cp_mutating_completion_mapping::arm_completion_mutation();
    control.recover_resource(binding, result.resource_h, recovery_result);
    rdma_cp_mutating_completion_mapping::disarm_completion_mutation();
    expect_recovery_result("COMPLETION_HOOK_REJECT", recovery_result,
                           RDMA_SC_INVALID_STATE);
    recovery = null;
    registry_resource = null;
    status = manager.lookup(result.resource_h, registry_resource);
    expect_status("COMPLETION_HOOK_REJECT_LOOKUP", status, RDMA_SC_OK);
    status = manager.lookup_recovery(result.resource_h, recovery);
    expect_status("COMPLETION_HOOK_REJECT_RECORD", status, RDMA_SC_OK);
    void'(manager.check_leaks(final_leaks, binding.make_handle()));
    release_calls = 0;
    foreach (host_mem.calls[i])
      if (host_mem.calls[i] != null &&
          host_mem.calls[i].method_name == "release")
        release_calls++;
    if (recovery_result == null ||
        !recovery_result.recovery_required ||
        !recovery_result.final_resource_state_known ||
        recovery_result.final_resource_state != RDMA_RESOURCE_ERROR ||
        registry_resource == null ||
        registry_resource.state != RDMA_RESOURCE_ERROR || recovery == null ||
        recovery.backing_refs.size() != 1 ||
        recovery.backing_refs[0] == null ||
        recovery.backing_refs[0].release_complete ||
        recovery.backing_refs[0].mapping == null ||
        recovery.backing_refs[0].mapping.state != RDMA_MAPPING_ACTIVE ||
        recovery.backing_refs[0].mapping.size != canonical_size ||
        host_mem.live_allocations() != baseline_allocations + 1 ||
        final_leaks != baseline_leaks + 1 || release_calls != 1)
      `uvm_error("COMPLETION_HOOK_REJECT_STATE",
                 "completion hook mutation reached release or durable state")

    control.recover_resource(binding, result.resource_h, recovery_result);
    expect_completed_recovery("COMPLETION_HOOK_RECOVER", recovery_result,
                              RDMA_SC_INVALID_STATE);
    status = manager.lookup(result.resource_h, registry_resource);
    expect_status("COMPLETION_HOOK_RELEASED", status,
                  RDMA_SC_INVALID_STATE);
    void'(manager.check_leaks(final_leaks, binding.make_handle()));
    release_calls = 0;
    foreach (host_mem.calls[i])
      if (host_mem.calls[i] != null &&
          host_mem.calls[i].method_name == "release")
        release_calls++;
    if (host_mem.live_allocations() != baseline_allocations ||
        final_leaks != baseline_leaks || release_calls != 2)
      `uvm_error("COMPLETION_HOOK_RECOVER_STATE",
                 "guarded-query rejection was not retryable")
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
    rdma_control_result recovery_result;
    rdma_status injected_status;
    rdma_status status;
    int unsigned baseline_allocations;
    int unsigned baseline_leaks;
    int unsigned final_leaks;
    int unsigned release_calls;
    bit release_complete;
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
    expect_recovery_result("OWNED_RELEASED_MAPPING", result,
                           RDMA_SC_INVALID_STATE);
    expect_cmq_opcodes("OWNED_RELEASED_MAPPING_OPCODES", mock_cmq,
                       expected_opcodes);
    registry_resource = null;
    recovery = null;
    if (result != null && result.resource_h != null) begin
      status = manager.lookup(result.resource_h, registry_resource);
      expect_status("OWNED_RELEASED_MAPPING_LOOKUP", status, RDMA_SC_OK);
      status = manager.lookup_recovery(result.resource_h, recovery);
      expect_status("OWNED_RELEASED_MAPPING_RECOVERY", status, RDMA_SC_OK);
    end
    release_complete = 1'b0;
    if (recovery != null && recovery.backing_refs.size() == 1 &&
        recovery.backing_refs[0] != null &&
        recovery.backing_refs[0].mapping != null) begin
      status = manager.query_owned_release_completion(
        recovery.backing_refs[0].mapping, release_complete
      );
      expect_status("OWNED_RELEASED_MAPPING_OPAQUE", status, RDMA_SC_OK);
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
        result.final_resource_state != RDMA_RESOURCE_ERROR ||
        !result.recovery_required || result.rollback_statuses.size() != 1 ||
        result.rollback_statuses[0] == null ||
        result.rollback_statuses[0].code != RDMA_SC_RESOURCE_BUSY ||
        mapping != null || mr == null || mr.state != RDMA_RESOURCE_ERROR ||
        registry_mr == null || registry_mr.state != RDMA_RESOURCE_ERROR ||
        recovery == null ||
        recovery.hardware_presence != RDMA_HW_PRESENCE_ABSENT ||
        recovery.ambiguous_ticket != null || recovery.hmc_refs.size() != 0 ||
        recovery.pending_steps.size() != 1 ||
        recovery.pending_steps[0] != RDMA_CTRL_STEP_RESOURCE_RELEASED ||
        recovery.completed_steps.size() == 0 ||
        recovery.completed_steps[$] != RDMA_CTRL_STEP_BACKING_RELEASED ||
        recovery.backing_refs.size() != 1 ||
        recovery.backing_refs[0] == null ||
        !recovery.backing_refs[0].release_complete ||
        recovery.backing_refs[0].mapping == null ||
        recovery.backing_refs[0].mapping.state != RDMA_MAPPING_RELEASED ||
        !release_complete ||
        host_mem.live_allocations() != baseline_allocations ||
        final_leaks != baseline_leaks + 1 || release_calls != 1 ||
        manager.release_reserved_calls != 1)
      `uvm_error(
        "OWNED_RELEASED_MAPPING_STATE",
        "released backing was not retained as durable resource recovery"
      )

    injected_status = rdma_status::make(
      RDMA_SC_RESOURCE_BUSY,
      "injected released-backing completion failure"
    );
    status = manager.fail_next_transition("complete_reserved_error",
                                          injected_status);
    expect_status("OWNED_RELEASED_MAPPING_COMPLETE_INJECT", status,
                  RDMA_SC_OK);
    if (result != null && result.resource_h != null)
      control.recover_resource(binding, result.resource_h, recovery_result);
    else
      recovery_result = null;
    expect_recovery_result("OWNED_RELEASED_MAPPING_RETRY", recovery_result,
                           RDMA_SC_INVALID_STATE);
    recovery = null;
    registry_resource = null;
    if (result != null && result.resource_h != null) begin
      status = manager.lookup(result.resource_h, registry_resource);
      expect_status("OWNED_RELEASED_MAPPING_RETRY_LOOKUP", status,
                    RDMA_SC_OK);
      status = manager.lookup_recovery(result.resource_h, recovery);
      expect_status("OWNED_RELEASED_MAPPING_RETRY_RECORD", status,
                    RDMA_SC_OK);
    end
    void'(manager.check_leaks(final_leaks, binding.make_handle()));
    release_calls = 0;
    foreach (host_mem.calls[i])
      if (host_mem.calls[i] != null &&
          host_mem.calls[i].method_name == "release")
        release_calls++;
    if (registry_resource == null ||
        registry_resource.state != RDMA_RESOURCE_ERROR || recovery == null ||
        recovery.pending_steps.size() != 1 ||
        recovery.pending_steps[0] != RDMA_CTRL_STEP_RESOURCE_RELEASED ||
        host_mem.live_allocations() != baseline_allocations ||
        final_leaks != baseline_leaks + 1 || release_calls != 1)
      `uvm_error("OWNED_RELEASED_MAPPING_RETRY_STATE",
                 "resource-only recovery failure was not retryable")

    if (result != null && result.resource_h != null)
      control.recover_resource(binding, result.resource_h, recovery_result);
    else
      recovery_result = null;
    expect_completed_recovery("OWNED_RELEASED_MAPPING_RECOVER",
                              recovery_result, RDMA_SC_INVALID_STATE);
    if (result != null && result.resource_h != null) begin
      status = manager.lookup(result.resource_h, registry_resource);
      expect_status("OWNED_RELEASED_MAPPING_RELEASED", status,
                    RDMA_SC_INVALID_STATE);
    end
    void'(manager.check_leaks(final_leaks, binding.make_handle()));
    release_calls = 0;
    foreach (host_mem.calls[i])
      if (host_mem.calls[i] != null &&
          host_mem.calls[i].method_name == "release")
        release_calls++;
    if (host_mem.live_allocations() != baseline_allocations ||
        final_leaks != baseline_leaks || release_calls != 1)
      `uvm_error("OWNED_RELEASED_MAPPING_RECOVER_STATE",
                 "resource-only recovery released backing more than once")
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
                               null, 1us);
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
                               null, 2us);
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
                               null, 5us);
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
        result.completed_steps.size() != 4 ||
        result.completed_steps[0] != RDMA_CTRL_STEP_RESOURCE_RESERVED ||
        result.completed_steps[1] != RDMA_CTRL_STEP_BACKING_ATTACHED ||
        result.completed_steps[2] != RDMA_CTRL_STEP_HMC_ATTACHED ||
        result.completed_steps[3] != RDMA_CTRL_STEP_RESOURCE_RELEASED)
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
    rdma_reconcile_fault_mock_cmq_port mock_cmq;
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
    rdma_control_result recovery_result;
    rdma_control_result second_recovery_result;
    rdma_recovery_record recovery;
    rdma_recovery_record recovery_before;
    rdma_recovery_record recovery_after;
    rdma_status reconcile_failure;
    rdma_status reset_status;
    rdma_status status;
    longint unsigned lease_size;
    int unsigned baseline_leak_count;
    int unsigned final_leak_count;

    control = rdma_control_plane::type_id::create("timeout_control");
    manager = rdma_resource_manager::type_id::create("timeout_manager");
    mock_cmq = rdma_reconcile_fault_mock_cmq_port::type_id::create(
      "timeout_cmq"
    );
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
                               null, 6us);
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

    if (recovery != null && recovery.ambiguous_ticket != null) begin
      recovery_before = recovery;
      control.recover_resource(binding, result.resource_h,
                               recovery_result);
      expect_recovery_result("KEY_ALLOC_UNKNOWN", recovery_result,
                             RDMA_SC_TIMEOUT);
      status = manager.lookup_recovery(result.resource_h, recovery_after);
      expect_status("KEY_ALLOC_UNKNOWN_RECORD", status, RDMA_SC_OK);
      if (!same_recovery_fields(recovery_before, recovery_after) ||
          mock_cmq.calls.size() != 1)
        `uvm_error("KEY_ALLOC_UNKNOWN_STATE",
                   "unknown terminal state mutated recovery or sent CMQ")

      reconcile_failure = rdma_status::make(
        RDMA_SC_RESOURCE_BUSY, "injected reconciliation transport failure"
      );
      mock_cmq.fail_next_reconcile(reconcile_failure);
      control.recover_resource(binding, result.resource_h,
                               recovery_result);
      expect_recovery_result("KEY_ALLOC_UNKNOWN_FAILURE", recovery_result,
                             RDMA_SC_TIMEOUT);
      status = manager.lookup_recovery(result.resource_h, recovery_after);
      expect_status("KEY_ALLOC_UNKNOWN_FAILURE_RECORD", status, RDMA_SC_OK);
      if (!same_recovery_fields(recovery_before, recovery_after) ||
          recovery_result.rollback_statuses.size() != 1 ||
          recovery_result.rollback_statuses[0] == null ||
          recovery_result.rollback_statuses[0].code !=
            RDMA_SC_RESOURCE_BUSY || mock_cmq.calls.size() != 1)
        `uvm_error(
          "KEY_ALLOC_UNKNOWN_FAILURE_STATE",
          "failed unknown reconciliation changed durable recovery"
        )

      reset_status = rdma_status::make(
        RDMA_SC_RESET_CANCELLED, "late reset cancellation"
      );
      mock_cmq.push_late_completion(recovery_before.ambiguous_ticket,
                                    reset_status);
      control.recover_resource(binding, result.resource_h,
                               recovery_result);
      expect_recovery_result("KEY_ALLOC_RESET_CANCELLED", recovery_result,
                             RDMA_SC_TIMEOUT);
      status = manager.lookup_recovery(result.resource_h, recovery_after);
      expect_status("KEY_ALLOC_RESET_CANCELLED_RECORD", status,
                    RDMA_SC_OK);
      if (!same_recovery_fields(recovery_before, recovery_after) ||
          recovery_after.hardware_presence != RDMA_HW_PRESENCE_UNKNOWN ||
          recovery_after.ambiguous_ticket == null ||
          mock_cmq.calls.size() != 1)
        `uvm_error("KEY_ALLOC_RESET_CANCELLED_STATE",
                   "reset cancellation was treated as absence proof")

      mock_cmq.push_late_completion(recovery_before.ambiguous_ticket,
                                    rdma_status::success());
      control.recover_resource(binding, result.resource_h,
                               recovery_result);
      expect_completed_recovery("KEY_ALLOC_LATE_SUCCESS", recovery_result,
                                RDMA_SC_TIMEOUT);
      if (mock_cmq.calls.size() != 2 || mock_cmq.calls[1] == null ||
          mock_cmq.calls[1].opcode != XTR_V1_OP_MR_DEREGISTER ||
          !recovery_result.final_resource_state_known ||
          recovery_result.final_resource_state != RDMA_RESOURCE_RELEASED)
        `uvm_error("KEY_ALLOC_LATE_SUCCESS_STATE",
                   "late KEY_ALLOC success was not undone exactly once")
      status = manager.lookup(result.resource_h, resource);
      expect_status("KEY_ALLOC_LATE_SUCCESS_RELEASED", status,
                    RDMA_SC_INVALID_STATE);
      control.recover_resource(binding, result.resource_h,
                               second_recovery_result);
      expect_result("KEY_ALLOC_LATE_SUCCESS_SECOND", second_recovery_result,
                    RDMA_SC_INVALID_STATE);
      if (mock_cmq.calls.size() != 2)
        `uvm_error("KEY_ALLOC_LATE_SUCCESS_IDEMPOTENT",
                   "second recovery repeated a hardware side effect")
    end
  endtask

  task automatic check_key_alloc_late_failure_recovery();
    rdma_control_plane control;
    rdma_fault_resource_manager manager;
    rdma_mock_cmq_port mock_cmq;
    rdma_mock_stag_key_policy key_policy;
    rdma_function_binding binding;
    rdma_create_pd_req pd_request;
    rdma_register_mr_req request;
    rdma_mr_backing_desc backing;
    rdma_pd pd;
    rdma_mr mr;
    rdma_resource resource;
    rdma_control_result result;
    rdma_control_result recovery_result;
    rdma_control_result second_recovery_result;
    rdma_recovery_record recovery;
    rdma_status late_failure;
    rdma_status status;

    control = rdma_control_plane::type_id::create(
      "late_failure_control"
    );
    manager = rdma_fault_resource_manager::type_id::create(
      "late_failure_manager"
    );
    mock_cmq = rdma_mock_cmq_port::type_id::create("late_failure_cmq");
    key_policy = rdma_mock_stag_key_policy::type_id::create(
      "late_failure_policy"
    );
    binding = make_active_binding(
      "late_failure_binding", 64'ha510_0000_0000_0001,
      32'ha510_0101, 60
    );
    status = control.configure(manager, mock_cmq, key_policy, null, null,
                               null, 6us);
    expect_status("KEY_ALLOC_LATE_FAILURE_CONFIGURE", status, RDMA_SC_OK);
    pd_request = make_create_pd_request(
      "late_failure_pd_request", binding
    );
    control.create_pd(binding, pd_request, pd, result);
    expect_result("KEY_ALLOC_LATE_FAILURE_PD", result, RDMA_SC_OK);
    if (pd == null || pd.handle == null)
      return;

    request = make_register_mr_request(
      "late_failure_request", binding, pd
    );
    backing = make_borrowed_pbl0_backing(
      "late_failure_backing", binding, request
    );
    mock_cmq.timeout_opcode(XTR_V1_OP_KEY_ALLOC);
    control.register_mr(binding, request, backing, mr, result);
    expect_recovery_result("KEY_ALLOC_LATE_FAILURE_TIMEOUT", result,
                           RDMA_SC_TIMEOUT);
    if (mr == null || mr.state != RDMA_RESOURCE_ERROR)
      `uvm_error("KEY_ALLOC_LATE_FAILURE_TIMEOUT_STATE",
                 "ambiguous MR was discarded")
    status = manager.lookup_recovery(result.resource_h, recovery);
    expect_status("KEY_ALLOC_LATE_FAILURE_RECORD", status, RDMA_SC_OK);
    if (recovery == null || recovery.ambiguous_ticket == null)
      return;

    late_failure = rdma_status::make(
      RDMA_SC_UNKNOWN_HW_ERROR, "late KEY_ALLOC terminal failure"
    );
    mock_cmq.push_late_completion(recovery.ambiguous_ticket, late_failure);
    control.recover_resource(binding, result.resource_h, recovery_result);
    expect_completed_recovery("KEY_ALLOC_LATE_FAILURE", recovery_result,
                              RDMA_SC_TIMEOUT);
    if (mock_cmq.calls.size() != 1 || mock_cmq.calls[0] == null ||
        mock_cmq.calls[0].opcode != XTR_V1_OP_KEY_ALLOC ||
        manager.finalize_release_calls != 1 ||
        backing.backing_refs[0] == null ||
        backing.backing_refs[0].release_complete ||
        backing.backing_refs[0].mapping == null ||
        backing.backing_refs[0].mapping.state != RDMA_MAPPING_ACTIVE)
      `uvm_error("KEY_ALLOC_LATE_FAILURE_STATE",
                 "late failure sent deregister or changed borrowed backing")
    status = manager.lookup(result.resource_h, resource);
    expect_status("KEY_ALLOC_LATE_FAILURE_RELEASED", status,
                  RDMA_SC_INVALID_STATE);
    control.recover_resource(binding, result.resource_h,
                             second_recovery_result);
    expect_result("KEY_ALLOC_LATE_FAILURE_SECOND", second_recovery_result,
                  RDMA_SC_INVALID_STATE);
    if (mock_cmq.calls.size() != 1 || manager.finalize_release_calls != 1)
      `uvm_error("KEY_ALLOC_LATE_FAILURE_IDEMPOTENT",
                 "second recovery repeated a side effect")
  endtask

  task automatic check_register_mr_caller_snapshot();
    rdma_control_plane control;
    rdma_resource_manager manager;
    rdma_mock_cmq_port blocking_cmq;
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
    blocking_cmq = rdma_mock_cmq_port::type_id::create(
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
                               null, 7us);
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
    blocking_cmq.gate_opcode(XTR_V1_OP_KEY_ALLOC);
    fork
      begin
        control.register_mr(binding, request, backing, mr, result);
      end
      begin
        blocking_cmq.wait_until_entered(1, 1us, cmq_entered);
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
        blocking_cmq.release_one();
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
    blocking_cmq.gate_opcode(XTR_V1_OP_KEY_ALLOC);
    fork
      begin
        control.register_mr(binding, request, backing, mr, result);
      end
      begin
        blocking_cmq.wait_until_entered(1, 1us, cmq_entered);
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
        blocking_cmq.release_one();
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
    rdma_mock_cmq_port blocking_cmq;
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
    blocking_cmq = rdma_mock_cmq_port::type_id::create(
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
                               null, 8us);
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
    blocking_cmq.gate_opcode(XTR_V1_OP_KEY_ALLOC);
    fork
      begin
        control.register_mr(binding, request, backing, mr, result);
      end
      begin
        blocking_cmq.wait_until_entered(1, 1us, cmq_entered);
        if (!cmq_entered)
          `uvm_error("POST_CMQ_BINDING_HANDSHAKE",
                     "KEY_ALLOC did not enter the blocking CMQ")
        else begin
          binding.generation++;
          binding.owner_h = binding.make_handle();
        end
        blocking_cmq.release_one();
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
    blocking_cmq = rdma_mock_cmq_port::type_id::create(
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
                               null, 8us);
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
    blocking_cmq.gate_opcode(XTR_V1_OP_KEY_ALLOC);
    fork
      begin
        control.register_mr(binding, request, backing, mr, result);
      end
      begin
        blocking_cmq.wait_until_entered(1, 1us, cmq_entered);
        if (!cmq_entered)
          `uvm_error("POST_CMQ_HMC_HANDSHAKE",
                     "KEY_ALLOC did not enter the blocking CMQ")
        else begin
          status = hmc.\release (binding.make_handle(), RDMA_RESOURCE_MR,
                                 hmc_address);
          expect_status("POST_CMQ_HMC_RELEASE", status, RDMA_SC_OK);
        end
        blocking_cmq.release_one();
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

  task automatic check_function_concurrency();
    rdma_control_plane_probe control;
    rdma_resource_manager manager;
    rdma_mock_cmq_port mock_cmq;
    rdma_mock_stag_key_policy key_policy;
    rdma_function_binding binding_a;
    rdma_function_binding binding_b;
    rdma_function_handle owner_b;
    rdma_function_handle contender_owner_a;
    rdma_create_pd_req pd_request;
    rdma_register_mr_req request;
    rdma_mr_backing_desc backing;
    rdma_pd pd;
    rdma_mr mr;
    rdma_control_result result;
    rdma_status status;
    semaphore held_b;
    semaphore contender_lock_a;
    semaphore contender_enable;
    semaphore contender_started;
    bit contender_a_acquired;
    bit public_completed;
    bit first_gate_observed;
    bit cleanup_gate_observed;
    bit held_b_released;

    control = rdma_control_plane_probe::type_id::create(
      "concurrency_control"
    );
    manager = rdma_resource_manager::type_id::create("concurrency_manager");
    mock_cmq = rdma_mock_cmq_port::type_id::create("concurrency_cmq");
    key_policy = rdma_mock_stag_key_policy::type_id::create(
      "concurrency_policy"
    );
    binding_a = make_active_binding(
      "concurrency_binding_a", 64'hb100_0000_0000_0001,
      32'hb100_0101, 79
    );
    binding_b = make_active_binding(
      "concurrency_binding_b", 64'hb200_0000_0000_0002,
      32'hb200_0202, 79
    );
    if (binding_a.function_uid == binding_b.function_uid ||
        binding_a.global_function_id == binding_b.global_function_id ||
        binding_a.generation != binding_b.generation)
      `uvm_fatal("FUNCTION_CONCURRENCY_FIXTURE",
                 "Functions must be distinct with the same generation")
    status = control.configure(manager, mock_cmq, key_policy, null, null,
                               null, 8us);
    expect_status("FUNCTION_CONCURRENCY_CONFIGURE", status, RDMA_SC_OK);
    pd_request = make_create_pd_request("concurrency_pd_request", binding_a);
    control.create_pd(binding_a, pd_request, pd, result);
    expect_result("FUNCTION_CONCURRENCY_PD", result, RDMA_SC_OK);
    if (pd == null || pd.handle == null)
      return;
    request = make_register_mr_request(
      "concurrency_register_request", binding_a, pd
    );
    backing = make_borrowed_pbl0_backing(
      "concurrency_register_backing", binding_a, request
    );
    owner_b = binding_b.make_handle();
    contender_owner_a = binding_a.make_handle();
    if (owner_b == null || contender_owner_a == null)
      return;
    contender_owner_a.generation++;

    contender_enable = new(0);
    contender_started = new(0);
    contender_a_acquired = 1'b0;
    public_completed = 1'b0;
    first_gate_observed = 1'b0;
    cleanup_gate_observed = 1'b0;
    held_b_released = 1'b0;
    control.acquire_test_function_lock(owner_b, held_b);
    mock_cmq.gate_opcode(XTR_V1_OP_KEY_ALLOC);
    // VCS W-2024.09-SP1 faults while reclaiming concurrent class-output
    // handles from multiple public calls, so keep one public registration.
    fork
      begin
        control.register_mr(binding_a, request, backing, mr, result);
        public_completed = 1'b1;
      end
      begin
        contender_enable.get(1);
        contender_started.put(1);
        control.acquire_test_function_lock(
          contender_owner_a, contender_lock_a
        );
        contender_a_acquired = 1'b1;
        control.release_test_function_lock(contender_lock_a);
      end
      begin
        mock_cmq.wait_until_entered(1, 1us, first_gate_observed);
        if (!first_gate_observed) begin
          `uvm_error("DIFFERENT_FUNCTION_LOCK",
                     "Function A did not reach CMQ while Function B was held")
          control.release_test_function_lock(held_b);
          held_b_released = 1'b1;
          mock_cmq.wait_until_entered(1, 1us, cleanup_gate_observed);
          if (!cleanup_gate_observed)
            `uvm_error("DIFFERENT_FUNCTION_CLEANUP",
                       "Function A did not reach CMQ after releasing B")
        end
        if (!held_b_released) begin
          control.release_test_function_lock(held_b);
          held_b_released = 1'b1;
        end
        contender_enable.put(1);
        contender_started.get(1);
        if (contender_a_acquired)
          `uvm_error("SAME_FUNCTION_LOCK",
                     "next generation bypassed the public Function A lock")
        mock_cmq.release_one();
      end
    join
    if (!public_completed)
      `uvm_error("FUNCTION_CONCURRENCY_COMPLETE",
                 "public Function A registration did not complete")
    if (!contender_a_acquired)
      `uvm_error("SAME_FUNCTION_RELEASE",
                 "same-Function contender did not resume after release")
    expect_result("FUNCTION_CONCURRENCY_RESULT", result, RDMA_SC_OK);
    if (mr == null || mock_cmq.calls.size() != 1 ||
        mock_cmq.calls[0] == null ||
        mock_cmq.calls[0].opcode != XTR_V1_OP_KEY_ALLOC)
      `uvm_error("FUNCTION_CONCURRENCY_COMMAND",
                 "public registration result or CMQ command is incomplete")
  endtask

  task automatic check_register_mr_pre_activate_generation_fence();
    rdma_control_plane control;
    rdma_generation_mutating_resource_manager manager;
    rdma_mock_cmq_port mock_cmq;
    rdma_mock_stag_key_policy key_policy;
    rdma_function_binding binding;
    rdma_create_pd_req pd_request;
    rdma_register_mr_req request;
    rdma_mr_backing_desc backing;
    rdma_pd pd;
    rdma_mr mr;
    rdma_recovery_record recovery;
    rdma_control_result result;
    rdma_status status;

    control = rdma_control_plane::type_id::create(
      "pre_activate_fence_control"
    );
    manager = rdma_generation_mutating_resource_manager::type_id::create(
      "pre_activate_fence_manager"
    );
    mock_cmq = rdma_mock_cmq_port::type_id::create(
      "pre_activate_fence_cmq"
    );
    key_policy = rdma_mock_stag_key_policy::type_id::create(
      "pre_activate_fence_policy"
    );
    binding = make_active_binding(
      "pre_activate_fence_binding", 64'hb300_0000_0000_0003,
      32'hb300_0303, 89
    );
    status = control.configure(manager, mock_cmq, key_policy, null, null,
                               null, 8us);
    expect_status("PRE_ACTIVATE_FENCE_CONFIGURE", status, RDMA_SC_OK);
    pd_request = make_create_pd_request("pre_activate_fence_pd", binding);
    control.create_pd(binding, pd_request, pd, result);
    expect_result("PRE_ACTIVATE_FENCE_PD", result, RDMA_SC_OK);
    if (pd == null || pd.handle == null)
      return;
    manager.activate_calls = 0;
    request = make_register_mr_request(
      "pre_activate_fence_request", binding, pd
    );
    backing = make_borrowed_pbl0_backing(
      "pre_activate_fence_backing", binding, request
    );
    manager.mutate_generation_on_next_commit(binding);
    control.register_mr(binding, request, backing, mr, result);
    expect_recovery_result("PRE_ACTIVATE_FENCE", result,
                           RDMA_SC_STALE_GENERATION);
    status = manager.peek_recovery(result.resource_h, recovery);
    expect_status("PRE_ACTIVATE_FENCE_RECOVERY_LOOKUP", status,
                  RDMA_SC_OK);
    if (mr != null || result == null || result.resource_h == null ||
        !result.final_resource_state_known ||
        result.final_resource_state != RDMA_RESOURCE_ERROR ||
        !result.recovery_required || recovery == null ||
        recovery.primary_status == null ||
        recovery.primary_status.code != RDMA_SC_STALE_GENERATION ||
        recovery.hardware_presence != RDMA_HW_PRESENCE_ABSENT ||
        recovery.ambiguous_ticket != null ||
        recovery.completed_steps.size() != 5 ||
        recovery.completed_steps[0] != RDMA_CTRL_STEP_RESOURCE_RESERVED ||
        recovery.completed_steps[1] != RDMA_CTRL_STEP_BACKING_ATTACHED ||
        recovery.completed_steps[2] != RDMA_CTRL_STEP_HW_KEY_ALLOCATED ||
        recovery.completed_steps[3] != RDMA_CTRL_STEP_REGISTRY_PROGRAMMED ||
        recovery.completed_steps[4] !=
          RDMA_CTRL_STEP_HW_MR_DEREGISTERED ||
        recovery.pending_steps.size() != 1 ||
        recovery.pending_steps[0] != RDMA_CTRL_STEP_RESOURCE_RELEASED ||
        manager.activate_calls != 0 ||
        mock_cmq.calls.size() != 2 || mock_cmq.calls[0] == null ||
        mock_cmq.calls[0].opcode != XTR_V1_OP_KEY_ALLOC ||
        mock_cmq.calls[1] == null ||
        mock_cmq.calls[1].opcode != XTR_V1_OP_MR_DEREGISTER)
      `uvm_error("PRE_ACTIVATE_FENCE_STATE",
                 "stale programmed MR reached activate or lost recovery")
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
                               null, 9us);
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
        recovery.pending_steps.size() != 1 ||
        recovery.pending_steps[0] != RDMA_CTRL_STEP_RESOURCE_RELEASED ||
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

    request = make_register_mr_request("freeze_finalize_request", binding,
                                       pd);
    request.iova.value += 64'h0006_0000;
    backing = make_borrowed_pbl0_backing(
      "freeze_finalize_backing", binding, request, RDMA_MR_PBL2
    );
    status = hmc.allocate(binding.make_handle(), RDMA_RESOURCE_MR,
                          64'h1000, 64'h1000, hmc_address);
    expect_status("FREEZE_FINALIZE_HMC_ALLOCATE", status, RDMA_SC_OK);
    status = hmc.lookup(binding.make_handle(), RDMA_RESOURCE_MR,
                        hmc_address, lease_size);
    expect_status("FREEZE_FINALIZE_HMC_LOOKUP", status, RDMA_SC_OK);
    hmc_ref = make_borrowed_hmc_ref(
      "freeze_finalize_hmc_ref", binding, hmc_address, lease_size,
      28'h000_0b00
    );
    backing.hmc_refs.push_back(hmc_ref);
    backing.page_layout.first_pbl_index = hmc_ref.first_pbl_index;
    manager.fail_next_activate(mark_error_failure);
    manager.fail_next_finalize_release(release_failure);
    control.register_mr(binding, request, backing, mr, result);
    expect_recovery_result("FREEZE_FINALIZE", result,
                           RDMA_SC_INVALID_STATE);
    recovery = null;
    if (result != null && result.resource_h != null) begin
      status = manager.lookup(result.resource_h, resource);
      expect_status("FREEZE_FINALIZE_LOOKUP", status, RDMA_SC_OK);
      status = manager.lookup_recovery(result.resource_h, recovery);
      expect_status("FREEZE_FINALIZE_RECOVERY", status, RDMA_SC_OK);
    end
    if (mr == null || mr.state != RDMA_RESOURCE_ERROR || result == null ||
        result.final_resource_state != RDMA_RESOURCE_ERROR ||
        !result.recovery_required || result.rollback_statuses.size() != 1 ||
        result.rollback_statuses[0] == null ||
        result.rollback_statuses[0].code != RDMA_SC_RESOURCE_BUSY ||
        recovery == null ||
        recovery.hardware_presence != RDMA_HW_PRESENCE_ABSENT ||
        recovery.pending_steps.size() != 1 ||
        recovery.pending_steps[0] != RDMA_CTRL_STEP_RESOURCE_RELEASED ||
        recovery.ambiguous_ticket != null)
      `uvm_error("FREEZE_FINALIZE_RECORD",
                 "finalize failure did not retain pending release recovery")
    if (manager.release_reserved_calls != 2 ||
        manager.mark_error_calls != 5 ||
        manager.finalize_release_calls != 1 ||
        mock_cmq.calls.size() != 5 ||
        mock_cmq.calls[3] == null ||
        mock_cmq.calls[3].opcode != XTR_V1_OP_KEY_ALLOC ||
        mock_cmq.calls[4] == null ||
        mock_cmq.calls[4].opcode != XTR_V1_OP_MR_DEREGISTER)
      `uvm_error("FREEZE_FINALIZE_CALLS",
                 "finalize failure command or recovery calls are incomplete")
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

  task automatic check_supplied_lock_ownership();
    rdma_control_plane_probe control;
    rdma_resource_manager manager;
    rdma_mock_cmq_port mock_cmq;
    rdma_mock_stag_key_policy key_policy;
    rdma_function_binding binding;
    rdma_create_pd_req pd_request;
    rdma_register_mr_req request;
    rdma_mr_backing_desc backing;
    rdma_function_handle owner;
    rdma_pd pd;
    rdma_mr mr;
    rdma_control_result result;
    rdma_status status;
    semaphore outer_lock;
    semaphore contender_lock;
    bit inner_done;
    bit contender_acquired;

    control = rdma_control_plane_probe::type_id::create(
      "supplied_lock_control"
    );
    manager = rdma_resource_manager::type_id::create(
      "supplied_lock_manager"
    );
    mock_cmq = rdma_mock_cmq_port::type_id::create("supplied_lock_cmq");
    key_policy = rdma_mock_stag_key_policy::type_id::create(
      "supplied_lock_policy"
    );
    binding = make_active_binding(
      "supplied_lock_binding", 64'hf310_0000_0000_0001,
      32'hf310_0101, 63
    );
    status = control.configure(manager, mock_cmq, key_policy);
    expect_status("SUPPLIED_LOCK_CONFIGURE", status, RDMA_SC_OK);
    pd_request = make_create_pd_request("supplied_lock_pd_request", binding);
    control.create_pd(binding, pd_request, pd, result);
    expect_result("SUPPLIED_LOCK_PD_CREATE", result, RDMA_SC_OK);
    if (pd == null || pd.handle == null)
      return;
    request = make_register_mr_request("supplied_lock_request", binding, pd);
    backing = make_borrowed_pbl0_backing(
      "supplied_lock_backing", binding, request
    );
    status = key_policy.fail_next(
      rdma_status::make(RDMA_SC_INVALID_STATE,
                        "injected supplied-lock registration failure")
    );
    expect_status("SUPPLIED_LOCK_INJECT", status, RDMA_SC_OK);
    owner = binding.make_handle();
    control.acquire_test_function_lock(owner, outer_lock);
    inner_done = 1'b0;
    contender_acquired = 1'b0;
    fork
      begin
        control.register_mr_with_test_lock(
          binding, request, backing, outer_lock, mr, result
        );
        inner_done = 1'b1;
      end
      begin
        control.acquire_test_function_lock(owner, contender_lock);
        contender_acquired = 1'b1;
        control.release_test_function_lock(contender_lock);
      end
      begin
        wait (inner_done);
        #1ns;
        if (contender_acquired)
          `uvm_error("SUPPLIED_LOCK_EARLY_RELEASE",
                     "inner registration released its caller-owned lock")
        control.release_test_function_lock(outer_lock);
        #1ns;
        if (!contender_acquired)
          `uvm_error("SUPPLIED_LOCK_FINAL_RELEASE",
                     "contender remained blocked after outer lock release")
      end
    join
    expect_result("SUPPLIED_LOCK_RESULT", result, RDMA_SC_INVALID_STATE);
    if (mr != null)
      `uvm_error("SUPPLIED_LOCK_MR",
                 "failing supplied-lock registration returned an MR")
  endtask

  task automatic check_owned_post_lock_snapshot();
    rdma_control_plane_probe control;
    rdma_resource_manager manager;
    rdma_mock_cmq_port blocking_cmq;
    rdma_mock_stag_key_policy key_policy;
    rdma_mock_host_mem host_mem;
    rdma_function_binding binding;
    rdma_create_pd_req pd_request;
    rdma_register_mr_req request;
    rdma_dma_request_context dma_context;
    rdma_function_handle owner;
    rdma_pd pd;
    rdma_mr mr;
    rdma_mrt_model mrt;
    rdma_dma_mapping mapping;
    rdma_control_result result;
    rdma_status status;
    semaphore held_lock;
    longint unsigned first_length;
    bit [19:0] first_pasid;
    rdma_rdma_access_t first_access;
    bit cmq_entered;

    control = rdma_control_plane_probe::type_id::create(
      "owned_snapshot_control"
    );
    manager = rdma_resource_manager::type_id::create(
      "owned_snapshot_manager"
    );
    blocking_cmq = rdma_mock_cmq_port::type_id::create(
      "owned_snapshot_cmq"
    );
    key_policy = rdma_mock_stag_key_policy::type_id::create(
      "owned_snapshot_policy"
    );
    host_mem = rdma_mock_host_mem::type_id::create("owned_snapshot_mem");
    binding = make_active_binding(
      "owned_snapshot_binding", 64'hf320_0000_0000_0001,
      32'hf320_0101, 65
    );
    status = control.configure(
      manager, blocking_cmq, key_policy, host_mem, null, null, 3us
    );
    expect_status("OWNED_SNAPSHOT_CONFIGURE", status, RDMA_SC_OK);
    pd_request = make_create_pd_request("owned_snapshot_pd_request", binding);
    control.create_pd(binding, pd_request, pd, result);
    expect_result("OWNED_SNAPSHOT_PD_CREATE", result, RDMA_SC_OK);
    if (pd == null || pd.handle == null)
      return;
    request = make_register_mr_request("owned_snapshot_request", binding, pd);
    request.iova.value = host_mem.next_address;
    dma_context = make_dma_context("owned_snapshot_context", binding);
    owner = binding.make_handle();
    control.acquire_test_function_lock(owner, held_lock);
    first_length = 64'h3000;
    first_pasid = binding.queue_dma.pasid;
    first_access = '{local_write:1'b1, remote_read:1'b1,
                     remote_write:1'b0, memory_window_bind:1'b0,
                     remote_atomic:1'b0};
    blocking_cmq.gate_opcode(XTR_V1_OP_KEY_ALLOC);
    fork
      begin
        control.alloc_and_register_mr(
          binding, request, dma_context, 4096, mapping, mr, result
        );
      end
      begin
        #1ns;
        request.length = first_length;
        request.access = first_access;
        dma_context.pasid = first_pasid;
        control.release_test_function_lock(held_lock);
        blocking_cmq.wait_until_entered(1, 1us, cmq_entered);
        if (!cmq_entered)
          `uvm_error("OWNED_SNAPSHOT_HANDSHAKE",
                     "owned registration did not reach blocking CMQ")
        else begin
          request.length = 64'h4000;
          request.access = '{local_write:1'b0, remote_read:1'b0,
                             remote_write:1'b1,
                             memory_window_bind:1'b0,
                             remote_atomic:1'b0};
          dma_context.pasid = 20'h2b222;
        end
        blocking_cmq.release_one();
      end
    join
    expect_result("OWNED_SNAPSHOT_RESULT", result, RDMA_SC_OK);
    mrt = null;
    if (blocking_cmq.calls.size() != 1 ||
        blocking_cmq.calls[0] == null ||
        blocking_cmq.calls[0].command == null ||
        !$cast(mrt, blocking_cmq.calls[0].command.body))
      `uvm_error("OWNED_SNAPSHOT_COMMAND",
                 "owned snapshot lost its KEY_ALLOC MRT")
    if (host_mem.calls.size() != 1 || host_mem.calls[0] == null ||
        host_mem.calls[0].method_name != "allocate" ||
        host_mem.calls[0].size != first_length ||
        host_mem.calls[0].direction != RDMA_DMA_BIDIRECTIONAL ||
        host_mem.calls[0].request_context == null ||
        host_mem.calls[0].request_context == dma_context ||
        host_mem.calls[0].request_context.pasid != first_pasid ||
        mrt == null || mrt.length != first_length ||
        mrt.access != first_access || mr == null ||
        mr.length != first_length || mr.access != first_access ||
        mr.backing_refs.size() != 1 || mr.backing_refs[0] == null ||
        mr.backing_refs[0].mapping == null ||
        mr.backing_refs[0].mapping.pasid != first_pasid ||
        request.length != 64'h4000 || dma_context.pasid != 20'h2b222)
      `uvm_error("OWNED_SNAPSHOT_VALUES",
                 "owned registration mixed pre-lock or later caller values")
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
                               null, 4us);
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
                               null, 3us);
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

  task automatic check_mr_deregister_success_and_busy();
    rdma_control_plane_probe control;
    rdma_fault_resource_manager manager;
    rdma_mock_cmq_port mock_cmq;
    rdma_mock_host_mem host_mem;
    rdma_hmc_allocator hmc;
    rdma_function_binding binding;
    rdma_pd pd;
    rdma_mr mr;
    rdma_mr live_mr;
    rdma_resource resource;
    rdma_dma_mapping mapping;
    rdma_dma_mapping mapping2;
    rdma_hmc_fvm_addr_t hmc_address;
    rdma_xtr_v1_occ_flush_body occ_body;
    rdma_xtr_v1_mr_deregister_body dereg_body;
    rdma_xtr_v1_cmq_empty_body drain_body;
    rdma_control_result result;
    rdma_status status;
    bit [7:0] expected_opcodes[$];
    longint unsigned lease_size;
    int unsigned baseline_allocations;
    int unsigned hmc_leaks;

    setup_deregister_mr_case(
      "dereg_borrowed_pbl0", RDMA_MR_PBL0, RDMA_OWNERSHIP_BORROWED,
      control, manager, mock_cmq, host_mem, hmc, binding, pd, mr,
      mapping, hmc_address, baseline_allocations
    );
    status = manager.track_outstanding(mr.handle, 64'h55);
    expect_status("MR_DEREG_BUSY_TRACK", status, RDMA_SC_OK);
    control.deregister_mr(binding, mr.handle, result);
    expect_result("MR_DEREG_BUSY", result, RDMA_SC_RESOURCE_BUSY);
    status = manager.lookup(mr.handle, resource);
    expect_status("MR_DEREG_BUSY_LOOKUP", status, RDMA_SC_OK);
    live_mr = null;
    void'($cast(live_mr, resource));
    if (live_mr == null || live_mr.state != RDMA_RESOURCE_ACTIVE ||
        live_mr.outstanding_ids.size() != 1 ||
        live_mr.outstanding_ids[0] != 64'h55 ||
        manager.begin_quiesce_calls != 0 ||
        manager.restore_active_calls != 0 || mock_cmq.calls.size() != 0 ||
        host_mem.live_allocations() != baseline_allocations + 1)
      `uvm_error("MR_DEREG_BUSY",
                 "busy MR changed state or reached quiesce/cleanup")
    status = manager.retire_outstanding(mr.handle, 64'h55);
    expect_status("MR_DEREG_BUSY_RETIRE", status, RDMA_SC_OK);
    control.deregister_mr(binding, mr.handle, result);
    expect_result("MR_DEREG_BORROWED_PBL0", result, RDMA_SC_OK);
    expected_opcodes.push_back(XTR_V1_OP_MR_DEREGISTER);
    expected_opcodes.push_back(XTR_V1_OP_TQ_FLUSH);
    expect_cmq_opcodes("MR_DEREG_BORROWED_PBL0_ORDER", mock_cmq,
                       expected_opcodes);
    dereg_body = null;
    drain_body = null;
    if (mock_cmq.calls.size() != 2 || mock_cmq.calls[0] == null ||
        mock_cmq.calls[0].command == null ||
        mock_cmq.calls[0].command.opcode_key == null ||
        mock_cmq.calls[0].command.opcode_key.variant != "deregister" ||
        !$cast(dereg_body, mock_cmq.calls[0].command.body) ||
        dereg_body == null || dereg_body.mr_h == null ||
        dereg_body.mr_h.kind != RDMA_RESOURCE_MR ||
        dereg_body.mr_h.function_uid != binding.function_uid ||
        dereg_body.mr_h.generation != binding.generation ||
        dereg_body.mr_h.object_id != mr.local_mr_id[23:0] ||
        dereg_body.mr_h.object_id == mr.handle.object_id ||
        dereg_body.stag_key != mr.lkey[7:0] ||
        dereg_body.next_state != RDMA_CONTEXT_INVALID ||
        mock_cmq.calls[1] == null ||
        mock_cmq.calls[1].command == null ||
        mock_cmq.calls[1].command.opcode_key == null ||
        mock_cmq.calls[1].command.opcode_key.variant != "tq_flush" ||
        !$cast(drain_body, mock_cmq.calls[1].command.body) ||
        drain_body == null)
      `uvm_error("MR_DEREG_PBL0_BODIES",
                 "PBL0 destroy command bodies or projection are wrong")
    status = manager.lookup(mr.handle, resource);
    expect_status("MR_DEREG_BORROWED_PBL0_RELEASED", status,
                  RDMA_SC_INVALID_STATE);
    if (result.final_resource_state != RDMA_RESOURCE_RELEASED ||
        !result.final_resource_state_known ||
        manager.begin_quiesce_calls != 1 ||
        manager.finalize_release_calls != 1 ||
        host_mem.live_allocations() != baseline_allocations + 1 ||
        host_mem.calls.size() != 1 ||
        host_mem.calls[0].method_name != "allocate")
      `uvm_error("MR_DEREG_BORROWED_PBL0_CLEANUP",
                 "borrowed PBL0 mapping was released or MR stayed live")
    status = host_mem.\release (mapping);
    expect_status("MR_DEREG_BORROWED_PBL0_CALLER_RELEASE", status,
                  RDMA_SC_OK);

    setup_deregister_mr_case(
      "dereg_borrowed_pbl1", RDMA_MR_PBL1, RDMA_OWNERSHIP_BORROWED,
      control, manager, mock_cmq, host_mem, hmc, binding, pd, mr,
      mapping, hmc_address, baseline_allocations
    );
    if (mr == null || mr.backing_refs.size() != 2 ||
        mr.backing_refs[1] == null || host_mem.regions.size() != 2 ||
        host_mem.regions[1] == null ||
        host_mem.regions[1].mapping == null)
      `uvm_fatal("MR_DEREG_BORROWED_PBL1_SETUP",
                 "PBL1 fixture lost its second borrowed mapping")
    mapping2 = host_mem.regions[1].mapping;
    control.deregister_mr(binding, mr.handle, result);
    expect_result("MR_DEREG_BORROWED_PBL1", result, RDMA_SC_OK);
    expected_opcodes.delete();
    expected_opcodes.push_back(XTR_V1_OP_MR_DEREGISTER);
    expected_opcodes.push_back(XTR_V1_OP_TQ_FLUSH);
    expect_cmq_opcodes("MR_DEREG_BORROWED_PBL1_ORDER", mock_cmq,
                       expected_opcodes);
    if (mapping == null || mapping.state != RDMA_MAPPING_ACTIVE ||
        mapping2 == null || mapping2.state != RDMA_MAPPING_ACTIVE ||
        host_mem.live_allocations() != baseline_allocations + 2 ||
        host_mem.calls.size() != 2 ||
        host_mem.calls[0].method_name != "allocate" ||
        host_mem.calls[1].method_name != "allocate" ||
        manager.finalize_release_calls != 1)
      `uvm_error("MR_DEREG_BORROWED_PBL1_CLEANUP",
                 "PBL1 deregister released borrowed mapping authority")
    status = host_mem.\release (mapping);
    expect_status("MR_DEREG_BORROWED_PBL1_CALLER_MAP0", status,
                  RDMA_SC_OK);
    status = host_mem.\release (mapping2);
    expect_status("MR_DEREG_BORROWED_PBL1_CALLER_MAP1", status,
                  RDMA_SC_OK);
    if (host_mem.live_allocations() != baseline_allocations)
      `uvm_error("MR_DEREG_BORROWED_PBL1_CALLER_CLEANUP",
                 "caller did not release both PBL1 mappings")

    setup_deregister_mr_case(
      "dereg_borrowed_pbl2", RDMA_MR_PBL2, RDMA_OWNERSHIP_BORROWED,
      control, manager, mock_cmq, host_mem, hmc, binding, pd, mr,
      mapping, hmc_address, baseline_allocations
    );
    control.deregister_mr(binding, mr.handle, result);
    expect_result("MR_DEREG_BORROWED_PBL2", result, RDMA_SC_OK);
    expected_opcodes.delete();
    expected_opcodes.push_back(XTR_V1_OP_OCC_FLUSH);
    expected_opcodes.push_back(XTR_V1_OP_MR_DEREGISTER);
    expected_opcodes.push_back(XTR_V1_OP_TQ_FLUSH);
    expect_cmq_opcodes("MR_DEREG_BORROWED_PBL2_ORDER", mock_cmq,
                       expected_opcodes);
    occ_body = null;
    dereg_body = null;
    drain_body = null;
    if (mock_cmq.calls.size() != 3 || mock_cmq.calls[0] == null ||
        mock_cmq.calls[0].command == null ||
        mock_cmq.calls[0].command.opcode_key == null ||
        mock_cmq.calls[0].command.opcode_key.variant != "occ_flush" ||
        !$cast(occ_body, mock_cmq.calls[0].command.body) ||
        occ_body == null || occ_body.vf_flush ||
        !occ_body.mr_serial_flush || occ_body.qpc || occ_body.cqc ||
        occ_body.mrt || !occ_body.pble || occ_body.sqrqe ||
        occ_body.sgb_irqe || occ_body.eirqe || occ_body.orqe ||
        occ_body.uaqe || occ_body.pd || occ_body.qpn != 0 ||
        occ_body.mr_serial != mr.mr_serial ||
        occ_body.pd_backing.value != 0 || mock_cmq.calls[1] == null ||
        mock_cmq.calls[1].command == null ||
        !$cast(dereg_body, mock_cmq.calls[1].command.body) ||
        dereg_body == null || dereg_body.mr_h == null ||
        dereg_body.mr_h.object_id != mr.local_mr_id[23:0] ||
        dereg_body.stag_key != mr.lkey[7:0] ||
        dereg_body.next_state != RDMA_CONTEXT_INVALID ||
        mock_cmq.calls[2] == null ||
        mock_cmq.calls[2].command == null ||
        !$cast(drain_body, mock_cmq.calls[2].command.body) ||
        drain_body == null)
      `uvm_error("MR_DEREG_PBL2_BODIES",
                 "PBL2 OCC/deregister/drain bodies are wrong")
    status = hmc.lookup(binding.make_handle(), RDMA_RESOURCE_MR,
                        hmc_address, lease_size);
    expect_status("MR_DEREG_BORROWED_PBL2_HMC", status, RDMA_SC_OK);
    if (host_mem.live_allocations() != baseline_allocations + 1 ||
        host_mem.calls.size() != 1 ||
        host_mem.calls[0].method_name != "allocate")
      `uvm_error("MR_DEREG_BORROWED_PBL2_CLEANUP",
                 "borrowed PBL2 authority was released")
    status = host_mem.\release (mapping);
    expect_status("MR_DEREG_BORROWED_PBL2_CALLER_MAP_RELEASE", status,
                  RDMA_SC_OK);
    status = hmc.\release (binding.make_handle(), RDMA_RESOURCE_MR,
                            hmc_address);
    expect_status("MR_DEREG_BORROWED_PBL2_CALLER_HMC_RELEASE", status,
                  RDMA_SC_OK);

    setup_deregister_mr_case(
      "dereg_owned_pbl2", RDMA_MR_PBL2,
      RDMA_OWNERSHIP_CONTROL_PLANE, control, manager, mock_cmq, host_mem,
      hmc, binding, pd, mr, mapping, hmc_address, baseline_allocations
    );
    control.deregister_mr(binding, mr.handle, result);
    expect_result("MR_DEREG_OWNED_PBL2", result, RDMA_SC_OK);
    expected_opcodes.delete();
    expected_opcodes.push_back(XTR_V1_OP_OCC_FLUSH);
    expected_opcodes.push_back(XTR_V1_OP_MR_DEREGISTER);
    expected_opcodes.push_back(XTR_V1_OP_TQ_FLUSH);
    expect_cmq_opcodes("MR_DEREG_OWNED_PBL2_ORDER", mock_cmq,
                       expected_opcodes);
    status = hmc.check_leaks(hmc_leaks, binding.make_handle());
    expect_status("MR_DEREG_OWNED_PBL2_HMC_CLEAN", status, RDMA_SC_OK);
    if (hmc_leaks != 0 ||
        host_mem.live_allocations() != baseline_allocations ||
        host_mem.calls.size() != 2 ||
        host_mem.calls[0].method_name != "allocate" ||
        host_mem.calls[1].method_name != "release" ||
        manager.finalize_release_calls != 1)
      `uvm_error("MR_DEREG_OWNED_PBL2_CLEANUP",
                 "owned PBL2 backing was not released exactly once")
  endtask

  task automatic run_deregister_generation_fence(
    string prefix,
    rdma_mr_pbl_mode_e pbl_mode,
    bit [7:0] gated_opcode,
    rdma_hw_presence_e expected_presence,
    rdma_control_step_e expected_pending_step,
    int unsigned expected_command_count
  );
    rdma_control_plane_probe control;
    rdma_fault_resource_manager manager;
    rdma_mock_cmq_port mock_cmq;
    rdma_mock_host_mem host_mem;
    rdma_hmc_allocator hmc;
    rdma_function_binding binding;
    rdma_pd pd;
    rdma_mr mr;
    rdma_resource resource;
    rdma_mr raw_mr;
    rdma_dma_mapping mapping;
    rdma_hmc_fvm_addr_t hmc_address;
    rdma_control_result result;
    rdma_recovery_record recovery;
    rdma_status status;
    int unsigned baseline_allocations;
    bit observed;

    setup_deregister_mr_case(
      prefix, pbl_mode, RDMA_OWNERSHIP_BORROWED, control, manager,
      mock_cmq, host_mem, hmc, binding, pd, mr, mapping, hmc_address,
      baseline_allocations
    );
    if (mr == null || mr.handle == null)
      return;
    mock_cmq.gate_opcode(gated_opcode);
    fork
      begin
        control.deregister_mr(binding, mr.handle, result);
      end
      begin
        mock_cmq.wait_until_entered(1, 1us, observed);
        if (!observed)
          `uvm_error({prefix, "_HANDSHAKE"},
                     "deregister command did not enter the CMQ gate")
        else begin
          binding.generation++;
          binding.owner_h = binding.make_handle();
        end
        mock_cmq.release_one();
      end
    join
    expect_recovery_result(prefix, result, RDMA_SC_STALE_GENERATION);
    recovery = null;
    resource = null;
    status = manager.peek_resource(mr.handle, resource);
    expect_status({prefix, "_RAW_RESOURCE"}, status, RDMA_SC_OK);
    void'($cast(raw_mr, resource));
    status = manager.peek_recovery(mr.handle, recovery);
    expect_status({prefix, "_RAW_RECOVERY"}, status, RDMA_SC_OK);
    if (raw_mr == null || raw_mr.state != RDMA_RESOURCE_ERROR ||
        recovery == null ||
        recovery.hardware_presence != expected_presence ||
        recovery.primary_status == null ||
        recovery.primary_status.code != RDMA_SC_STALE_GENERATION ||
        recovery.pending_steps.size() != 1 ||
        recovery.pending_steps[0] != expected_pending_step ||
        result == null || !result.final_resource_state_known ||
        result.final_resource_state != RDMA_RESOURCE_ERROR ||
        !result.recovery_required ||
        mock_cmq.calls.size() != expected_command_count ||
        manager.finalize_release_calls != 0)
      `uvm_error({prefix, "_STATE"},
                 "stale deregistration continued or lost old authority")
  endtask

  task automatic check_deregister_generation_fences();
    run_deregister_generation_fence(
      "DEREG_OCC_GENERATION_FENCE", RDMA_MR_PBL2,
      XTR_V1_OP_OCC_FLUSH, RDMA_HW_PRESENCE_PRESENT,
      RDMA_CTRL_STEP_HW_MR_DEREGISTERED, 1
    );
    run_deregister_generation_fence(
      "DEREG_MR_GENERATION_FENCE", RDMA_MR_PBL0,
      XTR_V1_OP_MR_DEREGISTER, RDMA_HW_PRESENCE_ABSENT,
      RDMA_CTRL_STEP_HW_DRAINED, 1
    );
    run_deregister_generation_fence(
      "DEREG_TQ_GENERATION_FENCE", RDMA_MR_PBL0,
      XTR_V1_OP_TQ_FLUSH, RDMA_HW_PRESENCE_ABSENT,
      RDMA_CTRL_STEP_BACKING_RELEASED, 2
    );
    run_deregister_local_release_generation_fence();
  endtask

  task automatic run_deregister_local_release_generation_fence();
    string prefix;
    rdma_control_plane_probe control;
    rdma_fault_resource_manager manager;
    rdma_mock_cmq_port mock_cmq;
    rdma_mock_host_mem host_mem;
    rdma_generation_mutating_host_mem mutating_host_mem;
    rdma_hmc_allocator hmc;
    rdma_function_binding binding;
    rdma_pd pd;
    rdma_mr mr;
    rdma_resource resource;
    rdma_mr raw_mr;
    rdma_dma_mapping mapping;
    rdma_hmc_fvm_addr_t hmc_address;
    rdma_control_result result;
    rdma_recovery_record recovery;
    rdma_status status;
    int unsigned baseline_allocations;

    prefix = "DEREG_RELEASE_GENERATION_FENCE";
    setup_deregister_mr_case(
      prefix, RDMA_MR_PBL0, RDMA_OWNERSHIP_CONTROL_PLANE,
      control, manager, mock_cmq, host_mem, hmc, binding, pd, mr,
      mapping, hmc_address, baseline_allocations
    );
    if (mr == null || mr.handle == null)
      return;
    mutating_host_mem = rdma_generation_mutating_host_mem::type_id::create(
      "deregister_release_generation_mutator"
    );
    mutating_host_mem.configure_mutation(host_mem, binding);
    control.use_host_mem_for_test(mutating_host_mem);
    control.deregister_mr(binding, mr.handle, result);
    expect_recovery_result(prefix, result, RDMA_SC_STALE_GENERATION);
    recovery = null;
    resource = null;
    status = manager.peek_resource(mr.handle, resource);
    expect_status({prefix, "_RAW_RESOURCE"}, status, RDMA_SC_OK);
    void'($cast(raw_mr, resource));
    status = manager.peek_recovery(mr.handle, recovery);
    expect_status({prefix, "_RAW_RECOVERY"}, status, RDMA_SC_OK);
    if (raw_mr == null || raw_mr.state != RDMA_RESOURCE_ERROR ||
        recovery == null ||
        recovery.hardware_presence != RDMA_HW_PRESENCE_ABSENT ||
        recovery.primary_status == null ||
        recovery.primary_status.code != RDMA_SC_STALE_GENERATION ||
        recovery.pending_steps.size() != 1 ||
        recovery.pending_steps[0] != RDMA_CTRL_STEP_RESOURCE_RELEASED ||
        result == null || !result.final_resource_state_known ||
        result.final_resource_state != RDMA_RESOURCE_ERROR ||
        !result.recovery_required || mock_cmq.calls.size() != 2 ||
        host_mem.live_allocations() != baseline_allocations ||
        manager.finalize_release_calls != 0)
      `uvm_error({prefix, "_STATE"},
                 "stale local release finalized or lost old authority")
  endtask

  task automatic check_mr_deregister_failure_table();
    rdma_control_plane_probe control;
    rdma_fault_resource_manager manager;
    rdma_mock_cmq_port mock_cmq;
    rdma_mock_host_mem host_mem;
    rdma_hmc_allocator hmc;
    rdma_hmc_allocator fault_hmc;
    rdma_function_binding binding;
    rdma_pd pd;
    rdma_mr mr;
    rdma_mr live_mr;
    rdma_resource resource;
    rdma_dma_mapping mapping;
    rdma_hmc_fvm_addr_t hmc_address;
    rdma_hmc_fvm_addr_t fault_hmc_base;
    rdma_control_result result;
    rdma_control_result recovery_result;
    rdma_control_result second_recovery_result;
    rdma_control_result third_recovery_result;
    rdma_recovery_record recovery;
    rdma_status injected_status;
    rdma_status status;
    bit [7:0] expected_opcodes[$];
    longint unsigned lease_size;
    int unsigned baseline_allocations;

    setup_deregister_mr_case(
      "dereg_occ_failure", RDMA_MR_PBL2, RDMA_OWNERSHIP_BORROWED,
      control, manager, mock_cmq, host_mem, hmc, binding, pd, mr,
      mapping, hmc_address, baseline_allocations
    );
    injected_status = rdma_status::make(
      RDMA_SC_UNKNOWN_HW_ERROR, "injected OCC failure"
    );
    mock_cmq.fail_opcode(XTR_V1_OP_OCC_FLUSH, injected_status);
    control.deregister_mr(binding, mr.handle, result);
    expect_result("MR_DEREG_OCC_FAILURE", result,
                  RDMA_SC_UNKNOWN_HW_ERROR);
    status = manager.lookup(mr.handle, resource);
    expect_status("MR_DEREG_OCC_FAILURE_LOOKUP", status, RDMA_SC_OK);
    live_mr = null;
    void'($cast(live_mr, resource));
    expected_opcodes.push_back(XTR_V1_OP_OCC_FLUSH);
    expect_cmq_opcodes("MR_DEREG_OCC_FAILURE_ORDER", mock_cmq,
                       expected_opcodes);
    if (live_mr == null || live_mr.state != RDMA_RESOURCE_ACTIVE ||
        result.final_resource_state != RDMA_RESOURCE_ACTIVE ||
        !result.final_resource_state_known ||
        manager.begin_quiesce_calls != 1 ||
        manager.restore_active_calls != 1 ||
        manager.finalize_release_calls != 0 ||
        host_mem.live_allocations() != baseline_allocations + 1)
      `uvm_error("MR_DEREG_OCC_FAILURE_STATE",
                 "explicit OCC failure did not restore ACTIVE")
    status = hmc.lookup(binding.make_handle(), RDMA_RESOURCE_MR,
                        hmc_address, lease_size);
    expect_status("MR_DEREG_OCC_FAILURE_HMC", status, RDMA_SC_OK);
    status = host_mem.\release (mapping);
    expect_status("MR_DEREG_OCC_FAILURE_CALLER_MAP_RELEASE", status,
                  RDMA_SC_OK);
    status = hmc.\release (binding.make_handle(), RDMA_RESOURCE_MR,
                            hmc_address);
    expect_status("MR_DEREG_OCC_FAILURE_CALLER_HMC_RELEASE", status,
                  RDMA_SC_OK);

    setup_deregister_mr_case(
      "dereg_occ_restore_failure", RDMA_MR_PBL2,
      RDMA_OWNERSHIP_BORROWED, control, manager, mock_cmq, host_mem, hmc,
      binding, pd, mr, mapping, hmc_address, baseline_allocations
    );
    injected_status = rdma_status::make(
      RDMA_SC_UNKNOWN_HW_ERROR, "injected OCC explicit failure"
    );
    mock_cmq.fail_opcode(XTR_V1_OP_OCC_FLUSH, injected_status);
    injected_status = rdma_status::make(
      RDMA_SC_RESOURCE_BUSY, "injected OCC restore ACTIVE failure"
    );
    manager.fail_next_restore_active(injected_status);
    control.deregister_mr(binding, mr.handle, result);
    expect_recovery_result("MR_DEREG_OCC_RESTORE_FAILURE", result,
                           RDMA_SC_UNKNOWN_HW_ERROR);
    status = manager.lookup(mr.handle, resource);
    expect_status("MR_DEREG_OCC_RESTORE_LOOKUP", status, RDMA_SC_OK);
    live_mr = null;
    void'($cast(live_mr, resource));
    status = manager.lookup_recovery(mr.handle, recovery);
    expect_status("MR_DEREG_OCC_RESTORE_RECOVERY", status, RDMA_SC_OK);
    expected_opcodes.delete();
    expected_opcodes.push_back(XTR_V1_OP_OCC_FLUSH);
    expect_cmq_opcodes("MR_DEREG_OCC_RESTORE_ORDER", mock_cmq,
                       expected_opcodes);
    if (live_mr == null || live_mr.state != RDMA_RESOURCE_ERROR ||
        result.rollback_statuses.size() != 1 ||
        result.rollback_statuses[0] == null ||
        result.rollback_statuses[0].code != RDMA_SC_RESOURCE_BUSY ||
        recovery == null ||
        recovery.hardware_presence != RDMA_HW_PRESENCE_PRESENT ||
        recovery.completed_steps.size() != 0 ||
        recovery.pending_steps.size() != 1 ||
        recovery.pending_steps[0] != RDMA_CTRL_STEP_HW_OCC_FLUSHED ||
        recovery.ambiguous_ticket != null ||
        recovery.rollback_statuses.size() != 1 ||
        recovery.rollback_statuses[0] == null ||
        recovery.rollback_statuses[0].code != RDMA_SC_RESOURCE_BUSY ||
        manager.restore_active_calls != 1 ||
        manager.mark_error_calls != 1 ||
        manager.finalize_release_calls != 0 ||
        host_mem.live_allocations() != baseline_allocations + 1)
      `uvm_error("MR_DEREG_OCC_RESTORE_STATE",
                 "failed OCC restore lost actionable PRESENT recovery")
    status = hmc.lookup(binding.make_handle(), RDMA_RESOURCE_MR,
                        hmc_address, lease_size);
    expect_status("MR_DEREG_OCC_RESTORE_HMC", status, RDMA_SC_OK);
    status = host_mem.\release (mapping);
    expect_status("MR_DEREG_OCC_RESTORE_MAP_RELEASE", status, RDMA_SC_OK);
    status = hmc.\release (binding.make_handle(), RDMA_RESOURCE_MR,
                            hmc_address);
    expect_status("MR_DEREG_OCC_RESTORE_HMC_RELEASE", status, RDMA_SC_OK);

    setup_deregister_mr_case(
      "dereg_occ_timeout", RDMA_MR_PBL2, RDMA_OWNERSHIP_BORROWED,
      control, manager, mock_cmq, host_mem, hmc, binding, pd, mr,
      mapping, hmc_address, baseline_allocations
    );
    mock_cmq.timeout_opcode(XTR_V1_OP_OCC_FLUSH);
    control.deregister_mr(binding, mr.handle, result);
    expect_recovery_result("MR_DEREG_OCC_TIMEOUT", result, RDMA_SC_TIMEOUT);
    status = manager.lookup(mr.handle, resource);
    expect_status("MR_DEREG_OCC_TIMEOUT_LOOKUP", status, RDMA_SC_OK);
    live_mr = null;
    void'($cast(live_mr, resource));
    status = manager.lookup_recovery(mr.handle, recovery);
    expect_status("MR_DEREG_OCC_TIMEOUT_RECOVERY", status, RDMA_SC_OK);
    if (live_mr == null || live_mr.state != RDMA_RESOURCE_ERROR ||
        recovery == null ||
        recovery.hardware_presence != RDMA_HW_PRESENCE_UNKNOWN ||
        recovery.completed_steps.size() != 0 ||
        recovery.pending_steps.size() != 1 ||
        recovery.pending_steps[0] != RDMA_CTRL_STEP_HW_OCC_FLUSHED ||
        recovery.ambiguous_ticket == null || mock_cmq.calls.size() != 1 ||
        mock_cmq.calls[0] == null || mock_cmq.calls[0].ticket == null ||
        recovery.ambiguous_ticket == mock_cmq.calls[0].ticket ||
        recovery.ambiguous_ticket.command_id !=
          mock_cmq.calls[0].ticket.command_id ||
        manager.restore_active_calls != 0 ||
        manager.finalize_release_calls != 0)
      `uvm_error("MR_DEREG_OCC_TIMEOUT_STATE",
                 "OCC timeout did not retain UNKNOWN ERROR recovery")

    injected_status = rdma_status::make(
      RDMA_SC_UNKNOWN_HW_ERROR, "late OCC terminal failure"
    );
    if (recovery != null && recovery.ambiguous_ticket != null)
      mock_cmq.push_late_completion(recovery.ambiguous_ticket,
                                    injected_status);
    control.recover_resource(binding, mr.handle, recovery_result);
    expect_restored_recovery("MR_DEREG_OCC_LATE_FAILURE", recovery_result,
                             RDMA_SC_TIMEOUT);
    status = manager.lookup(mr.handle, resource);
    expect_status("MR_DEREG_OCC_LATE_FAILURE_LOOKUP", status, RDMA_SC_OK);
    live_mr = null;
    void'($cast(live_mr, resource));
    status = manager.lookup_recovery(mr.handle, recovery);
    expect_status("MR_DEREG_OCC_LATE_FAILURE_CLEARED", status,
                  RDMA_SC_INVALID_STATE);
    expected_opcodes.delete();
    expected_opcodes.push_back(XTR_V1_OP_OCC_FLUSH);
    expect_cmq_opcodes("MR_DEREG_OCC_LATE_FAILURE_ORDER", mock_cmq,
                       expected_opcodes);
    if (live_mr == null || live_mr.state != RDMA_RESOURCE_ACTIVE ||
        recovery_result.rollback_statuses.size() != 1 ||
        recovery_result.rollback_statuses[0] == null ||
        recovery_result.rollback_statuses[0].code !=
          RDMA_SC_UNKNOWN_HW_ERROR ||
        manager.restore_active_calls != 1 ||
        manager.mark_error_calls != 2 ||
        manager.finalize_release_calls != 0 ||
        host_mem.live_allocations() != baseline_allocations + 1 ||
        host_mem.calls.size() != 1)
      `uvm_error("MR_DEREG_OCC_LATE_FAILURE_STATE",
                 "late OCC failure did not atomically restore ACTIVE")
    control.recover_resource(binding, mr.handle, second_recovery_result);
    expect_result("MR_DEREG_OCC_LATE_FAILURE_SECOND",
                  second_recovery_result, RDMA_SC_INVALID_STATE);
    if (mock_cmq.calls.size() != 1 || manager.restore_active_calls != 1 ||
        manager.mark_error_calls != 2 || host_mem.calls.size() != 1)
      `uvm_error("MR_DEREG_OCC_LATE_FAILURE_IDEMPOTENT",
                 "restored OCC recovery repeated a side effect")
    status = host_mem.\release (mapping);
    expect_status("MR_DEREG_OCC_LATE_FAILURE_MAP_RELEASE", status,
                  RDMA_SC_OK);
    status = hmc.\release (binding.make_handle(), RDMA_RESOURCE_MR,
                           hmc_address);
    expect_status("MR_DEREG_OCC_LATE_FAILURE_HMC_RELEASE", status,
                  RDMA_SC_OK);

    setup_deregister_mr_case(
      "dereg_command_failure", RDMA_MR_PBL0, RDMA_OWNERSHIP_BORROWED,
      control, manager, mock_cmq, host_mem, hmc, binding, pd, mr,
      mapping, hmc_address, baseline_allocations
    );
    injected_status = rdma_status::make(
      RDMA_SC_UNKNOWN_HW_ERROR, "injected MR deregister failure"
    );
    mock_cmq.fail_opcode(XTR_V1_OP_MR_DEREGISTER, injected_status);
    control.deregister_mr(binding, mr.handle, result);
    expect_result("MR_DEREG_COMMAND_FAILURE", result,
                  RDMA_SC_UNKNOWN_HW_ERROR);
    status = manager.lookup(mr.handle, resource);
    expect_status("MR_DEREG_COMMAND_FAILURE_LOOKUP", status, RDMA_SC_OK);
    live_mr = null;
    void'($cast(live_mr, resource));
    expected_opcodes.delete();
    expected_opcodes.push_back(XTR_V1_OP_MR_DEREGISTER);
    expect_cmq_opcodes("MR_DEREG_COMMAND_FAILURE_ORDER", mock_cmq,
                       expected_opcodes);
    if (live_mr == null || live_mr.state != RDMA_RESOURCE_ACTIVE ||
        manager.restore_active_calls != 1 ||
        manager.finalize_release_calls != 0 ||
        host_mem.live_allocations() != baseline_allocations + 1)
      `uvm_error("MR_DEREG_COMMAND_FAILURE_STATE",
                 "explicit MR_DEREGISTER failure did not restore ACTIVE")
    status = host_mem.\release (mapping);
    expect_status("MR_DEREG_COMMAND_FAILURE_CALLER_RELEASE", status,
                  RDMA_SC_OK);

    setup_deregister_mr_case(
      "dereg_command_restore_failure", RDMA_MR_PBL2,
      RDMA_OWNERSHIP_BORROWED, control, manager, mock_cmq, host_mem, hmc,
      binding, pd, mr, mapping, hmc_address, baseline_allocations
    );
    injected_status = rdma_status::make(
      RDMA_SC_UNKNOWN_HW_ERROR, "injected MR deregister explicit failure"
    );
    mock_cmq.fail_opcode(XTR_V1_OP_MR_DEREGISTER, injected_status);
    injected_status = rdma_status::make(
      RDMA_SC_RESOURCE_BUSY, "injected MR restore ACTIVE failure"
    );
    manager.fail_next_restore_active(injected_status);
    control.deregister_mr(binding, mr.handle, result);
    expect_recovery_result("MR_DEREG_COMMAND_RESTORE_FAILURE", result,
                           RDMA_SC_UNKNOWN_HW_ERROR);
    status = manager.lookup(mr.handle, resource);
    expect_status("MR_DEREG_COMMAND_RESTORE_LOOKUP", status, RDMA_SC_OK);
    live_mr = null;
    void'($cast(live_mr, resource));
    status = manager.lookup_recovery(mr.handle, recovery);
    expect_status("MR_DEREG_COMMAND_RESTORE_RECOVERY", status, RDMA_SC_OK);
    expected_opcodes.delete();
    expected_opcodes.push_back(XTR_V1_OP_OCC_FLUSH);
    expected_opcodes.push_back(XTR_V1_OP_MR_DEREGISTER);
    expect_cmq_opcodes("MR_DEREG_COMMAND_RESTORE_ORDER", mock_cmq,
                       expected_opcodes);
    if (live_mr == null || live_mr.state != RDMA_RESOURCE_ERROR ||
        result.rollback_statuses.size() != 1 ||
        result.rollback_statuses[0] == null ||
        result.rollback_statuses[0].code != RDMA_SC_RESOURCE_BUSY ||
        recovery == null ||
        recovery.hardware_presence != RDMA_HW_PRESENCE_PRESENT ||
        recovery.completed_steps.size() != 1 ||
        recovery.completed_steps[0] != RDMA_CTRL_STEP_HW_OCC_FLUSHED ||
        recovery.pending_steps.size() != 1 ||
        recovery.pending_steps[0] !=
          RDMA_CTRL_STEP_HW_MR_DEREGISTERED ||
        recovery.ambiguous_ticket != null ||
        recovery.rollback_statuses.size() != 1 ||
        recovery.rollback_statuses[0] == null ||
        recovery.rollback_statuses[0].code != RDMA_SC_RESOURCE_BUSY ||
        manager.restore_active_calls != 1 ||
        manager.mark_error_calls != 1 ||
        manager.finalize_release_calls != 0 ||
        host_mem.live_allocations() != baseline_allocations + 1)
      `uvm_error("MR_DEREG_COMMAND_RESTORE_STATE",
                 "failed MR restore lost actionable PRESENT recovery")
    status = hmc.lookup(binding.make_handle(), RDMA_RESOURCE_MR,
                        hmc_address, lease_size);
    expect_status("MR_DEREG_COMMAND_RESTORE_HMC", status, RDMA_SC_OK);
    status = host_mem.\release (mapping);
    expect_status("MR_DEREG_COMMAND_RESTORE_MAP_RELEASE", status,
                  RDMA_SC_OK);
    status = hmc.\release (binding.make_handle(), RDMA_RESOURCE_MR,
                            hmc_address);
    expect_status("MR_DEREG_COMMAND_RESTORE_HMC_RELEASE", status,
                  RDMA_SC_OK);

    setup_deregister_mr_case(
      "dereg_command_timeout", RDMA_MR_PBL0, RDMA_OWNERSHIP_BORROWED,
      control, manager, mock_cmq, host_mem, hmc, binding, pd, mr,
      mapping, hmc_address, baseline_allocations
    );
    mock_cmq.timeout_opcode(XTR_V1_OP_MR_DEREGISTER);
    control.deregister_mr(binding, mr.handle, result);
    expect_recovery_result("MR_DEREG_COMMAND_TIMEOUT", result,
                           RDMA_SC_TIMEOUT);
    status = manager.lookup_recovery(mr.handle, recovery);
    expect_status("MR_DEREG_COMMAND_TIMEOUT_RECOVERY", status, RDMA_SC_OK);
    if (recovery == null ||
        recovery.hardware_presence != RDMA_HW_PRESENCE_UNKNOWN ||
        recovery.completed_steps.size() != 0 ||
        recovery.pending_steps.size() != 1 ||
        recovery.pending_steps[0] !=
          RDMA_CTRL_STEP_HW_MR_DEREGISTERED ||
        recovery.ambiguous_ticket == null || mock_cmq.calls.size() != 1 ||
        manager.restore_active_calls != 0 ||
        manager.finalize_release_calls != 0)
      `uvm_error("MR_DEREG_COMMAND_TIMEOUT_STATE",
                 "MR_DEREGISTER timeout did not retain UNKNOWN ERROR")

    injected_status = rdma_status::make(
      RDMA_SC_UNKNOWN_HW_ERROR, "late MR_DEREGISTER terminal failure"
    );
    if (recovery != null && recovery.ambiguous_ticket != null)
      mock_cmq.push_late_completion(recovery.ambiguous_ticket,
                                    injected_status);
    control.recover_resource(binding, mr.handle, recovery_result);
    expect_restored_recovery("MR_DEREG_COMMAND_LATE_FAILURE",
                             recovery_result, RDMA_SC_TIMEOUT);
    status = manager.lookup(mr.handle, resource);
    expect_status("MR_DEREG_COMMAND_LATE_FAILURE_LOOKUP", status,
                  RDMA_SC_OK);
    live_mr = null;
    void'($cast(live_mr, resource));
    status = manager.lookup_recovery(mr.handle, recovery);
    expect_status("MR_DEREG_COMMAND_LATE_FAILURE_CLEARED", status,
                  RDMA_SC_INVALID_STATE);
    expected_opcodes.delete();
    expected_opcodes.push_back(XTR_V1_OP_MR_DEREGISTER);
    expect_cmq_opcodes("MR_DEREG_COMMAND_LATE_FAILURE_ORDER", mock_cmq,
                       expected_opcodes);
    if (live_mr == null || live_mr.state != RDMA_RESOURCE_ACTIVE ||
        recovery_result.rollback_statuses.size() != 1 ||
        recovery_result.rollback_statuses[0] == null ||
        recovery_result.rollback_statuses[0].code !=
          RDMA_SC_UNKNOWN_HW_ERROR ||
        manager.restore_active_calls != 1 ||
        manager.mark_error_calls != 2 ||
        manager.finalize_release_calls != 0 ||
        host_mem.live_allocations() != baseline_allocations + 1 ||
        host_mem.calls.size() != 1)
      `uvm_error("MR_DEREG_COMMAND_LATE_FAILURE_STATE",
                 "late MR_DEREGISTER failure did not restore ACTIVE")
    control.recover_resource(binding, mr.handle, second_recovery_result);
    expect_result("MR_DEREG_COMMAND_LATE_FAILURE_SECOND",
                  second_recovery_result, RDMA_SC_INVALID_STATE);
    if (mock_cmq.calls.size() != 1 || manager.restore_active_calls != 1 ||
        manager.mark_error_calls != 2 || host_mem.calls.size() != 1)
      `uvm_error("MR_DEREG_COMMAND_LATE_FAILURE_IDEMPOTENT",
                 "restored MR_DEREGISTER recovery repeated a side effect")
    status = host_mem.\release (mapping);
    expect_status("MR_DEREG_COMMAND_LATE_FAILURE_MAP_RELEASE", status,
                  RDMA_SC_OK);

    setup_deregister_mr_case(
      "dereg_late_restore_retry", RDMA_MR_PBL0,
      RDMA_OWNERSHIP_BORROWED, control, manager, mock_cmq, host_mem, hmc,
      binding, pd, mr, mapping, hmc_address, baseline_allocations
    );
    mock_cmq.timeout_opcode(XTR_V1_OP_MR_DEREGISTER);
    control.deregister_mr(binding, mr.handle, result);
    expect_recovery_result("MR_DEREG_LATE_RESTORE_RETRY_TIMEOUT", result,
                           RDMA_SC_TIMEOUT);
    status = manager.lookup_recovery(mr.handle, recovery);
    expect_status("MR_DEREG_LATE_RESTORE_RETRY_RECOVERY", status,
                  RDMA_SC_OK);
    injected_status = rdma_status::make(
      RDMA_SC_UNKNOWN_HW_ERROR,
      "late MR_DEREGISTER failure before restore retry"
    );
    if (recovery != null && recovery.ambiguous_ticket != null)
      mock_cmq.push_late_completion(recovery.ambiguous_ticket,
                                    injected_status);
    injected_status = rdma_status::make(
      RDMA_SC_RESOURCE_BUSY, "injected late ACTIVE restore failure"
    );
    manager.fail_next_restore_active(injected_status);
    control.recover_resource(binding, mr.handle, recovery_result);
    expect_recovery_result("MR_DEREG_LATE_RESTORE_RETRY_FIRST",
                           recovery_result, RDMA_SC_TIMEOUT);
    status = manager.lookup_recovery(mr.handle, recovery);
    expect_status("MR_DEREG_LATE_RESTORE_RETRY_FIRST_RECOVERY", status,
                  RDMA_SC_OK);
    expected_opcodes.delete();
    expected_opcodes.push_back(XTR_V1_OP_MR_DEREGISTER);
    expect_cmq_opcodes("MR_DEREG_LATE_RESTORE_RETRY_FIRST_ORDER", mock_cmq,
                       expected_opcodes);
    if (recovery == null ||
        recovery.hardware_presence != RDMA_HW_PRESENCE_PRESENT ||
        recovery.ambiguous_ticket != null ||
        recovery.pending_steps.size() != 0 ||
        recovery.completed_steps.size() != 0 ||
        recovery.rollback_statuses.size() != 2 ||
        recovery.rollback_statuses[0] == null ||
        recovery.rollback_statuses[0].code != RDMA_SC_UNKNOWN_HW_ERROR ||
        recovery.rollback_statuses[1] == null ||
        recovery.rollback_statuses[1].code != RDMA_SC_RESOURCE_BUSY ||
        manager.restore_active_calls != 1 ||
        manager.mark_error_calls != 3 ||
        manager.finalize_release_calls != 0 || mock_cmq.calls.size() != 1 ||
        host_mem.calls.size() != 1)
      `uvm_error("MR_DEREG_LATE_RESTORE_RETRY_FIRST_STATE",
                 "failed late restore did not retain a retry-ready record")
    control.recover_resource(binding, mr.handle, second_recovery_result);
    expect_restored_recovery("MR_DEREG_LATE_RESTORE_RETRY_SECOND",
                             second_recovery_result, RDMA_SC_TIMEOUT);
    status = manager.lookup(mr.handle, resource);
    expect_status("MR_DEREG_LATE_RESTORE_RETRY_SECOND_LOOKUP", status,
                  RDMA_SC_OK);
    live_mr = null;
    void'($cast(live_mr, resource));
    status = manager.lookup_recovery(mr.handle, recovery);
    expect_status("MR_DEREG_LATE_RESTORE_RETRY_SECOND_CLEARED", status,
                  RDMA_SC_INVALID_STATE);
    if (live_mr == null || live_mr.state != RDMA_RESOURCE_ACTIVE ||
        second_recovery_result.rollback_statuses.size() != 2 ||
        manager.restore_active_calls != 2 ||
        manager.mark_error_calls != 3 ||
        manager.finalize_release_calls != 0 || mock_cmq.calls.size() != 1 ||
        host_mem.calls.size() != 1)
      `uvm_error("MR_DEREG_LATE_RESTORE_RETRY_SECOND_STATE",
                 "retry-ready recovery replayed work or did not restore")
    status = host_mem.\release (mapping);
    expect_status("MR_DEREG_LATE_RESTORE_RETRY_MAP_RELEASE", status,
                  RDMA_SC_OK);

    setup_deregister_mr_case(
      "dereg_drain_failure", RDMA_MR_PBL0, RDMA_OWNERSHIP_BORROWED,
      control, manager, mock_cmq, host_mem, hmc, binding, pd, mr,
      mapping, hmc_address, baseline_allocations
    );
    injected_status = rdma_status::make(
      RDMA_SC_UNKNOWN_HW_ERROR, "injected TQ flush failure"
    );
    mock_cmq.fail_opcode(XTR_V1_OP_TQ_FLUSH, injected_status);
    control.deregister_mr(binding, mr.handle, result);
    expect_recovery_result("MR_DEREG_DRAIN_FAILURE", result,
                           RDMA_SC_UNKNOWN_HW_ERROR);
    status = manager.lookup_recovery(mr.handle, recovery);
    expect_status("MR_DEREG_DRAIN_FAILURE_RECOVERY", status, RDMA_SC_OK);
    expected_opcodes.delete();
    expected_opcodes.push_back(XTR_V1_OP_MR_DEREGISTER);
    expected_opcodes.push_back(XTR_V1_OP_TQ_FLUSH);
    expect_cmq_opcodes("MR_DEREG_DRAIN_FAILURE_ORDER", mock_cmq,
                       expected_opcodes);
    if (recovery == null ||
        recovery.hardware_presence != RDMA_HW_PRESENCE_ABSENT ||
        recovery.completed_steps.size() != 1 ||
        recovery.completed_steps[0] !=
          RDMA_CTRL_STEP_HW_MR_DEREGISTERED ||
        recovery.pending_steps.size() != 1 ||
        recovery.pending_steps[0] != RDMA_CTRL_STEP_HW_DRAINED ||
        recovery.ambiguous_ticket != null ||
        host_mem.live_allocations() != baseline_allocations + 1 ||
        host_mem.calls.size() != 1 ||
        manager.restore_active_calls != 0 ||
        manager.finalize_release_calls != 0)
      `uvm_error("MR_DEREG_DRAIN_FAILURE_STATE",
                 "post-deregister drain failure recovery is wrong")

    injected_status = rdma_status::make(
      RDMA_SC_RESOURCE_BUSY,
      "injected persistence failure after recovered TQ flush"
    );
    manager.fail_next_mark_error(injected_status);
    control.recover_resource(binding, mr.handle, recovery_result);
    expect_recovery_result("MR_DEREG_DRAIN_PERSIST_FIRST",
                           recovery_result,
                           RDMA_SC_UNKNOWN_HW_ERROR);
    status = manager.lookup_recovery(mr.handle, recovery);
    expect_status("MR_DEREG_DRAIN_PERSIST_FIRST_RECOVERY", status,
                  RDMA_SC_OK);
    expected_opcodes.push_back(XTR_V1_OP_TQ_FLUSH);
    expect_cmq_opcodes("MR_DEREG_DRAIN_PERSIST_FIRST_ORDER", mock_cmq,
                       expected_opcodes);
    if (recovery == null ||
        recovery.hardware_presence != RDMA_HW_PRESENCE_ABSENT ||
        recovery.completed_steps.size() != 2 ||
        recovery.completed_steps[0] !=
          RDMA_CTRL_STEP_HW_MR_DEREGISTERED ||
        recovery.completed_steps[1] != RDMA_CTRL_STEP_HW_DRAINED ||
        recovery.pending_steps.size() != 1 ||
        recovery.pending_steps[0] != RDMA_CTRL_STEP_BACKING_RELEASED ||
        recovery.primary_status == null ||
        recovery.primary_status.code != RDMA_SC_UNKNOWN_HW_ERROR ||
        recovery.rollback_statuses.size() != 1 ||
        recovery.rollback_statuses[0] == null ||
        recovery.rollback_statuses[0].code != RDMA_SC_RESOURCE_BUSY ||
        recovery_result.rollback_statuses.size() != 1 ||
        recovery_result.rollback_statuses[0] == null ||
        recovery_result.rollback_statuses[0].code !=
          RDMA_SC_RESOURCE_BUSY ||
        mock_cmq.calls.size() != 3 || host_mem.calls.size() != 1 ||
        manager.mark_error_calls != 3 ||
        manager.finalize_release_calls != 0)
      `uvm_error("MR_DEREG_DRAIN_PERSIST_FIRST_STATE",
                 "failed hardware progress persistence crossed a boundary")

    control.recover_resource(binding, mr.handle, second_recovery_result);
    expect_completed_recovery("MR_DEREG_DRAIN_PERSIST_SECOND",
                              second_recovery_result,
                              RDMA_SC_UNKNOWN_HW_ERROR);
    status = manager.lookup(mr.handle, resource);
    expect_status("MR_DEREG_DRAIN_PERSIST_SECOND_RELEASED", status,
                  RDMA_SC_INVALID_STATE);
    if (mock_cmq.calls.size() != 3 || host_mem.calls.size() != 1 ||
        manager.mark_error_calls != 5 ||
        manager.finalize_release_calls != 1)
      `uvm_error("MR_DEREG_DRAIN_PERSIST_SECOND_STATE",
                 "durable hardware progress was replayed on retry")
    control.recover_resource(binding, mr.handle, third_recovery_result);
    expect_result("MR_DEREG_DRAIN_PERSIST_THIRD", third_recovery_result,
                  RDMA_SC_INVALID_STATE);
    if (mock_cmq.calls.size() != 3 || host_mem.calls.size() != 1 ||
        manager.mark_error_calls != 5 ||
        manager.finalize_release_calls != 1)
      `uvm_error("MR_DEREG_DRAIN_PERSIST_THIRD_STATE",
                 "completed hardware-boundary recovery repeated work")
    status = host_mem.\release (mapping);
    expect_status("MR_DEREG_DRAIN_PERSIST_MAP_RELEASE", status,
                  RDMA_SC_OK);

    setup_deregister_mr_case(
      "dereg_drain_timeout", RDMA_MR_PBL0, RDMA_OWNERSHIP_BORROWED,
      control, manager, mock_cmq, host_mem, hmc, binding, pd, mr,
      mapping, hmc_address, baseline_allocations
    );
    mock_cmq.timeout_opcode(XTR_V1_OP_TQ_FLUSH);
    control.deregister_mr(binding, mr.handle, result);
    expect_recovery_result("MR_DEREG_DRAIN_TIMEOUT", result,
                           RDMA_SC_TIMEOUT);
    status = manager.lookup(mr.handle, resource);
    expect_status("MR_DEREG_DRAIN_TIMEOUT_LOOKUP", status, RDMA_SC_OK);
    live_mr = null;
    void'($cast(live_mr, resource));
    status = manager.lookup_recovery(mr.handle, recovery);
    expect_status("MR_DEREG_DRAIN_TIMEOUT_RECOVERY", status, RDMA_SC_OK);
    expected_opcodes.delete();
    expected_opcodes.push_back(XTR_V1_OP_MR_DEREGISTER);
    expected_opcodes.push_back(XTR_V1_OP_TQ_FLUSH);
    expect_cmq_opcodes("MR_DEREG_DRAIN_TIMEOUT_ORDER", mock_cmq,
                       expected_opcodes);
    if (live_mr == null || live_mr.state != RDMA_RESOURCE_ERROR ||
        recovery == null ||
        recovery.hardware_presence != RDMA_HW_PRESENCE_ABSENT ||
        recovery.completed_steps.size() != 1 ||
        recovery.completed_steps[0] !=
          RDMA_CTRL_STEP_HW_MR_DEREGISTERED ||
        recovery.pending_steps.size() != 1 ||
        recovery.pending_steps[0] != RDMA_CTRL_STEP_HW_DRAINED ||
        recovery.ambiguous_ticket == null || mock_cmq.calls.size() != 2 ||
        mock_cmq.calls[1] == null || mock_cmq.calls[1].ticket == null ||
        recovery.ambiguous_ticket == mock_cmq.calls[1].ticket ||
        recovery.ambiguous_ticket.command_id !=
          mock_cmq.calls[1].ticket.command_id ||
        host_mem.live_allocations() != baseline_allocations + 1 ||
        host_mem.calls.size() != 1 ||
        host_mem.calls[0].method_name != "allocate" ||
        manager.restore_active_calls != 0 ||
        manager.finalize_release_calls != 0)
      `uvm_error("MR_DEREG_DRAIN_TIMEOUT_STATE",
                 "TQ timeout did not retain detached ABSENT recovery")

    injected_status = rdma_status::make(
      RDMA_SC_UNKNOWN_HW_ERROR, "late TQ_FLUSH terminal failure"
    );
    if (recovery != null && recovery.ambiguous_ticket != null)
      mock_cmq.push_late_completion(recovery.ambiguous_ticket,
                                    injected_status);
    control.recover_resource(binding, mr.handle, recovery_result);
    expect_recovery_result("MR_DEREG_DRAIN_LATE_FAILURE_FIRST",
                           recovery_result, RDMA_SC_TIMEOUT);
    status = manager.lookup(mr.handle, resource);
    expect_status("MR_DEREG_DRAIN_LATE_FAILURE_FIRST_LOOKUP", status,
                  RDMA_SC_OK);
    live_mr = null;
    void'($cast(live_mr, resource));
    status = manager.lookup_recovery(mr.handle, recovery);
    expect_status("MR_DEREG_DRAIN_LATE_FAILURE_FIRST_RECOVERY", status,
                  RDMA_SC_OK);
    if (live_mr == null || live_mr.state != RDMA_RESOURCE_ERROR ||
        recovery == null ||
        recovery.hardware_presence != RDMA_HW_PRESENCE_ABSENT ||
        recovery.ambiguous_ticket != null ||
        recovery.completed_steps.size() != 1 ||
        recovery.completed_steps[0] !=
          RDMA_CTRL_STEP_HW_MR_DEREGISTERED ||
        recovery.pending_steps.size() != 1 ||
        recovery.pending_steps[0] != RDMA_CTRL_STEP_HW_DRAINED ||
        recovery.primary_status == null ||
        recovery.primary_status.code != RDMA_SC_TIMEOUT ||
        recovery.rollback_statuses.size() != 1 ||
        recovery.rollback_statuses[0] == null ||
        recovery.rollback_statuses[0].code !=
          RDMA_SC_UNKNOWN_HW_ERROR ||
        mock_cmq.calls.size() != 2 || host_mem.calls.size() != 1 ||
        manager.finalize_release_calls != 0)
      `uvm_error("MR_DEREG_DRAIN_LATE_FAILURE_FIRST_STATE",
                 "late TQ failure replayed the drain in the same call")
    if (live_mr == null || recovery == null)
      return;

    control.recover_resource(binding, mr.handle, second_recovery_result);
    expect_completed_recovery("MR_DEREG_DRAIN_LATE_FAILURE_SECOND",
                              second_recovery_result, RDMA_SC_TIMEOUT);
    expected_opcodes.push_back(XTR_V1_OP_TQ_FLUSH);
    expect_cmq_opcodes("MR_DEREG_DRAIN_LATE_FAILURE_SECOND_ORDER",
                       mock_cmq, expected_opcodes);
    status = manager.lookup(mr.handle, resource);
    expect_status("MR_DEREG_DRAIN_LATE_FAILURE_SECOND_RELEASED", status,
                  RDMA_SC_INVALID_STATE);
    if (host_mem.calls.size() != 1 ||
        host_mem.live_allocations() != baseline_allocations + 1 ||
        manager.finalize_release_calls != 1)
      `uvm_error("MR_DEREG_DRAIN_LATE_FAILURE_SECOND_STATE",
                 "deferred TQ retry did not finalize exactly once")

    control.recover_resource(binding, mr.handle, third_recovery_result);
    expect_result("MR_DEREG_DRAIN_LATE_FAILURE_THIRD",
                  third_recovery_result, RDMA_SC_INVALID_STATE);
    if (mock_cmq.calls.size() != 3 || host_mem.calls.size() != 1 ||
        manager.finalize_release_calls != 1)
      `uvm_error("MR_DEREG_DRAIN_LATE_FAILURE_THIRD_STATE",
                 "completed drain recovery repeated a side effect")
    status = host_mem.\release (mapping);
    expect_status("MR_DEREG_DRAIN_LATE_FAILURE_MAP_RELEASE", status,
                  RDMA_SC_OK);

    setup_deregister_mr_case(
      "dereg_owned_release_failure", RDMA_MR_PBL0,
      RDMA_OWNERSHIP_CONTROL_PLANE, control, manager, mock_cmq, host_mem,
      hmc, binding, pd, mr, mapping, hmc_address, baseline_allocations
    );
    injected_status = rdma_status::make(
      RDMA_SC_INVALID_STATE, "injected owned backing release failure"
    );
    status = host_mem.fail_next("release", injected_status);
    expect_status("MR_DEREG_OWNED_RELEASE_INJECT", status, RDMA_SC_OK);
    control.deregister_mr(binding, mr.handle, result);
    expect_recovery_result("MR_DEREG_OWNED_RELEASE_FAILURE", result,
                           RDMA_SC_INVALID_STATE);
    status = manager.lookup_recovery(mr.handle, recovery);
    expect_status("MR_DEREG_OWNED_RELEASE_RECOVERY", status, RDMA_SC_OK);
    if (recovery == null ||
        recovery.hardware_presence != RDMA_HW_PRESENCE_ABSENT ||
        recovery.completed_steps.size() != 2 ||
        recovery.completed_steps[0] !=
          RDMA_CTRL_STEP_HW_MR_DEREGISTERED ||
        recovery.completed_steps[1] != RDMA_CTRL_STEP_HW_DRAINED ||
        recovery.pending_steps.size() != 1 ||
        recovery.pending_steps[0] != RDMA_CTRL_STEP_BACKING_RELEASED ||
        host_mem.live_allocations() != baseline_allocations + 1 ||
        host_mem.calls.size() != 2 ||
        host_mem.calls[1].method_name != "release" ||
        manager.mark_error_calls != 1 ||
        manager.finalize_release_calls != 0)
      `uvm_error("MR_DEREG_OWNED_RELEASE_GATE",
                 "failed owned release reached finalize or lost recovery")
    expected_opcodes.delete();
    expected_opcodes.push_back(XTR_V1_OP_MR_DEREGISTER);
    expected_opcodes.push_back(XTR_V1_OP_TQ_FLUSH);
    expect_cmq_opcodes("MR_DEREG_OWNED_RECOVERY_BOUNDARY_ORDER", mock_cmq,
                       expected_opcodes);
    injected_status = rdma_status::make(
      RDMA_SC_RESOURCE_BUSY,
      "injected persistence failure after owned backing release"
    );
    manager.fail_next_mark_error(injected_status);
    control.recover_resource(binding, mr.handle, recovery_result);
    expect_recovery_result("MR_DEREG_OWNED_RECOVERY_FIRST",
                           recovery_result, RDMA_SC_INVALID_STATE);
    status = manager.lookup_recovery(mr.handle, recovery);
    expect_status("MR_DEREG_OWNED_RECOVERY_FIRST_RECORD", status,
                  RDMA_SC_OK);
    if (host_mem.live_allocations() != baseline_allocations ||
        host_mem.calls.size() != 3 || mock_cmq.calls.size() != 2 ||
        recovery == null ||
        recovery.hardware_presence != RDMA_HW_PRESENCE_ABSENT ||
        recovery.pending_steps.size() != 1 ||
        recovery.pending_steps[0] != RDMA_CTRL_STEP_BACKING_RELEASED ||
        recovery.backing_refs.size() != 1 ||
        recovery.backing_refs[0] == null ||
        !recovery.backing_refs[0].release_complete ||
        recovery.primary_status == null ||
        recovery.primary_status.code != RDMA_SC_INVALID_STATE ||
        recovery.rollback_statuses.size() != 1 ||
        recovery.rollback_statuses[0] == null ||
        recovery.rollback_statuses[0].code != RDMA_SC_RESOURCE_BUSY ||
        manager.restore_active_calls != 0 ||
        manager.mark_error_calls != 3 ||
        manager.finalize_release_calls != 0)
      `uvm_error("MR_DEREG_OWNED_RECOVERY_FIRST_STATE",
                 "owned release persistence crossed the finalize boundary")
    else if (host_mem.calls[0].method_name != "allocate" ||
             host_mem.calls[1].method_name != "release" ||
             host_mem.calls[2].method_name != "release")
      `uvm_error("MR_DEREG_OWNED_RECOVERY_FIRST_CALLS",
                 "recovery issued the wrong host-memory operations")

    control.recover_resource(binding, mr.handle, second_recovery_result);
    expect_completed_recovery("MR_DEREG_OWNED_RECOVERY_SECOND",
                              second_recovery_result,
                              RDMA_SC_INVALID_STATE);
    status = manager.lookup(mr.handle, resource);
    expect_status("MR_DEREG_OWNED_RECOVERY_SECOND_RELEASED", status,
                  RDMA_SC_INVALID_STATE);
    status = manager.lookup_recovery(mr.handle, recovery);
    expect_status("MR_DEREG_OWNED_RECOVERY_SECOND_CLEARED", status,
                  RDMA_SC_INVALID_STATE);
    if (host_mem.calls.size() != 3 || mock_cmq.calls.size() != 2 ||
        manager.mark_error_calls != 5 ||
        manager.finalize_release_calls != 1)
      `uvm_error("MR_DEREG_OWNED_RECOVERY_SECOND_STATE",
                 "durable owned release was replayed on retry")
    control.recover_resource(binding, mr.handle, third_recovery_result);
    expect_result("MR_DEREG_OWNED_RECOVERY_THIRD", third_recovery_result,
                  RDMA_SC_INVALID_STATE);
    if (host_mem.calls.size() != 3 || mock_cmq.calls.size() != 2 ||
        manager.mark_error_calls != 5 ||
        manager.finalize_release_calls != 1)
      `uvm_error("MR_DEREG_OWNED_RECOVERY_IDEMPOTENT",
                 "completed owned recovery repeated a side effect")

    setup_deregister_mr_case(
      "dereg_owned_hmc_release_failure", RDMA_MR_PBL2,
      RDMA_OWNERSHIP_CONTROL_PLANE, control, manager, mock_cmq, host_mem,
      hmc, binding, pd, mr, mapping, hmc_address, baseline_allocations
    );
    fault_hmc = rdma_hmc_allocator::type_id::create(
      "dereg_owned_hmc_release_fault"
    );
    fault_hmc_base.value = 64'h0000_0009_0000_0000;
    status = fault_hmc.configure(fault_hmc_base, 64'h0001_0000);
    expect_status("MR_DEREG_OWNED_HMC_FAULT_CONFIGURE", status,
                  RDMA_SC_OK);
    control.use_hmc_allocator_for_test(fault_hmc);
    control.deregister_mr(binding, mr.handle, result);
    expect_recovery_result("MR_DEREG_OWNED_HMC_RELEASE_FAILURE", result,
                           RDMA_SC_INVALID_ARGUMENT);
    status = manager.lookup(mr.handle, resource);
    expect_status("MR_DEREG_OWNED_HMC_RELEASE_LOOKUP", status, RDMA_SC_OK);
    live_mr = null;
    void'($cast(live_mr, resource));
    status = manager.lookup_recovery(mr.handle, recovery);
    expect_status("MR_DEREG_OWNED_HMC_RELEASE_RECOVERY", status,
                  RDMA_SC_OK);
    expected_opcodes.delete();
    expected_opcodes.push_back(XTR_V1_OP_OCC_FLUSH);
    expected_opcodes.push_back(XTR_V1_OP_MR_DEREGISTER);
    expected_opcodes.push_back(XTR_V1_OP_TQ_FLUSH);
    expect_cmq_opcodes("MR_DEREG_OWNED_HMC_RELEASE_ORDER", mock_cmq,
                       expected_opcodes);
    status = hmc.lookup(binding.make_handle(), RDMA_RESOURCE_MR,
                        hmc_address, lease_size);
    expect_status("MR_DEREG_OWNED_HMC_RELEASE_LEASE", status, RDMA_SC_OK);
    if (result.primary_status == null ||
        result.primary_status.message != "HMC address is unknown or forged" ||
        live_mr == null || live_mr.state != RDMA_RESOURCE_ERROR ||
        recovery == null ||
        recovery.hardware_presence != RDMA_HW_PRESENCE_ABSENT ||
        recovery.completed_steps.size() != 3 ||
        recovery.completed_steps[0] != RDMA_CTRL_STEP_HW_OCC_FLUSHED ||
        recovery.completed_steps[1] !=
          RDMA_CTRL_STEP_HW_MR_DEREGISTERED ||
        recovery.completed_steps[2] != RDMA_CTRL_STEP_HW_DRAINED ||
        recovery.pending_steps.size() != 1 ||
        recovery.pending_steps[0] != RDMA_CTRL_STEP_BACKING_RELEASED ||
        recovery.hmc_refs.size() != 1 || recovery.hmc_refs[0] == null ||
        recovery.hmc_refs[0].ownership !=
          RDMA_OWNERSHIP_CONTROL_PLANE ||
        recovery.hmc_refs[0].release_complete ||
        recovery.hmc_refs[0].object_kind != RDMA_RESOURCE_MR ||
        recovery.hmc_refs[0].address != hmc_address ||
        recovery.hmc_refs[0].owner == null ||
        !recovery.hmc_refs[0].owner.same_instance(binding.make_handle()) ||
        recovery.backing_refs.size() != 1 ||
        recovery.backing_refs[0] == null ||
        recovery.backing_refs[0].mapping == null ||
        recovery.backing_refs[0].ownership !=
          RDMA_OWNERSHIP_CONTROL_PLANE ||
        recovery.backing_refs[0].release_complete ||
        host_mem.live_allocations() != baseline_allocations + 1 ||
        host_mem.calls.size() != 1 ||
        host_mem.calls[0].method_name != "allocate" ||
        manager.restore_active_calls != 0 ||
        manager.finalize_release_calls != 0)
      `uvm_error("MR_DEREG_OWNED_HMC_RELEASE_STATE",
                 "HMC release failure lost retryable owned authority")

    control.use_hmc_allocator_for_test(hmc);
    control.recover_resource(binding, mr.handle, recovery_result);
    expect_completed_recovery("MR_DEREG_OWNED_HMC_RECOVERY",
                              recovery_result,
                              RDMA_SC_INVALID_ARGUMENT);
    status = manager.lookup(mr.handle, resource);
    expect_status("MR_DEREG_OWNED_HMC_RECOVERY_RELEASED", status,
                  RDMA_SC_INVALID_STATE);
    status = manager.lookup_recovery(mr.handle, recovery);
    expect_status("MR_DEREG_OWNED_HMC_RECOVERY_CLEARED", status,
                  RDMA_SC_INVALID_STATE);
    status = hmc.lookup(binding.make_handle(), RDMA_RESOURCE_MR,
                        hmc_address, lease_size);
    expect_status("MR_DEREG_OWNED_HMC_RECOVERY_LEASE", status,
                  RDMA_SC_INVALID_STATE);
    if (mock_cmq.calls.size() != 3 ||
        host_mem.live_allocations() != baseline_allocations ||
        host_mem.calls.size() != 2 ||
        host_mem.calls[1].method_name != "release" ||
        manager.mark_error_calls != 5 ||
        manager.finalize_release_calls != 1)
      `uvm_error("MR_DEREG_OWNED_HMC_RECOVERY_STATE",
                 "HMC recovery replayed hardware or skipped owned cleanup")
    control.recover_resource(binding, mr.handle, second_recovery_result);
    expect_result("MR_DEREG_OWNED_HMC_RECOVERY_SECOND",
                  second_recovery_result, RDMA_SC_INVALID_STATE);
    if (mock_cmq.calls.size() != 3 || host_mem.calls.size() != 2 ||
        manager.mark_error_calls != 5 ||
        manager.finalize_release_calls != 1)
      `uvm_error("MR_DEREG_OWNED_HMC_RECOVERY_IDEMPOTENT",
                 "completed HMC recovery repeated a side effect")

    setup_deregister_mr_case(
      "dereg_finalize_failure", RDMA_MR_PBL0,
      RDMA_OWNERSHIP_CONTROL_PLANE, control, manager, mock_cmq, host_mem,
      hmc, binding, pd, mr, mapping, hmc_address, baseline_allocations
    );
    injected_status = rdma_status::make(
      RDMA_SC_RESOURCE_BUSY, "injected finalize release failure"
    );
    manager.fail_next_finalize_release(injected_status);
    control.deregister_mr(binding, mr.handle, result);
    expect_recovery_result("MR_DEREG_FINALIZE_FAILURE", result,
                           RDMA_SC_RESOURCE_BUSY);
    status = manager.lookup_recovery(mr.handle, recovery);
    expect_status("MR_DEREG_FINALIZE_RECOVERY", status, RDMA_SC_OK);
    if (recovery == null ||
        recovery.hardware_presence != RDMA_HW_PRESENCE_ABSENT ||
        recovery.completed_steps.size() != 3 ||
        recovery.completed_steps[0] !=
          RDMA_CTRL_STEP_HW_MR_DEREGISTERED ||
        recovery.completed_steps[1] != RDMA_CTRL_STEP_HW_DRAINED ||
        recovery.completed_steps[2] != RDMA_CTRL_STEP_BACKING_RELEASED ||
        recovery.pending_steps.size() != 1 ||
        recovery.pending_steps[0] != RDMA_CTRL_STEP_RESOURCE_RELEASED ||
        host_mem.live_allocations() != baseline_allocations ||
        host_mem.calls.size() != 2 ||
        host_mem.calls[1].method_name != "release" ||
        manager.mark_error_calls != 1 ||
        manager.finalize_release_calls != 1)
      `uvm_error("MR_DEREG_FINALIZE_FAILURE_STATE",
                 "finalize failure did not retain ABSENT ERROR recovery")
    expected_opcodes.delete();
    expected_opcodes.push_back(XTR_V1_OP_MR_DEREGISTER);
    expected_opcodes.push_back(XTR_V1_OP_TQ_FLUSH);
    expect_cmq_opcodes("MR_DEREG_FINALIZE_BOUNDARY_ORDER", mock_cmq,
                       expected_opcodes);
    status = manager.complete_reserved_error(mr.handle);
    expect_status("MR_DEREG_FINALIZE_MANAGER_BOUNDARY", status,
                  RDMA_SC_INVALID_STATE);
    status = manager.lookup(mr.handle, resource);
    expect_status("MR_DEREG_FINALIZE_BOUNDARY_LOOKUP", status, RDMA_SC_OK);
    live_mr = null;
    void'($cast(live_mr, resource));
    status = manager.lookup_recovery(mr.handle, recovery);
    expect_status("MR_DEREG_FINALIZE_BOUNDARY_RECOVERY", status,
                  RDMA_SC_OK);
    if (live_mr == null || live_mr.state != RDMA_RESOURCE_ERROR ||
        recovery == null ||
        recovery.hardware_presence != RDMA_HW_PRESENCE_ABSENT ||
        recovery.completed_steps.size() != 3 ||
        recovery.completed_steps[0] !=
          RDMA_CTRL_STEP_HW_MR_DEREGISTERED ||
        recovery.completed_steps[1] != RDMA_CTRL_STEP_HW_DRAINED ||
        recovery.completed_steps[2] != RDMA_CTRL_STEP_BACKING_RELEASED ||
        recovery.pending_steps.size() != 1 ||
        recovery.pending_steps[0] != RDMA_CTRL_STEP_RESOURCE_RELEASED ||
        recovery.backing_refs.size() != 1 ||
        recovery.backing_refs[0] == null ||
        !recovery.backing_refs[0].release_complete ||
        host_mem.live_allocations() != baseline_allocations ||
        host_mem.calls.size() != 2 || mock_cmq.calls.size() != 2 ||
        manager.restore_active_calls != 0 ||
        manager.finalize_release_calls != 1)
      `uvm_error("MR_DEREG_FINALIZE_BOUNDARY_STATE",
                 "manager completed an active-origin MR recovery record")

    control.recover_resource(binding, mr.handle, recovery_result);
    expect_completed_recovery("MR_DEREG_FINALIZE_RECOVERY_RUN",
                              recovery_result, RDMA_SC_RESOURCE_BUSY);
    status = manager.lookup(mr.handle, resource);
    expect_status("MR_DEREG_FINALIZE_RECOVERY_RELEASED", status,
                  RDMA_SC_INVALID_STATE);
    status = manager.lookup_recovery(mr.handle, recovery);
    expect_status("MR_DEREG_FINALIZE_RECOVERY_CLEARED", status,
                  RDMA_SC_INVALID_STATE);
    if (mock_cmq.calls.size() != 2 || host_mem.calls.size() != 2 ||
        host_mem.live_allocations() != baseline_allocations ||
        manager.mark_error_calls != 2 ||
        manager.finalize_release_calls != 2)
      `uvm_error("MR_DEREG_FINALIZE_RECOVERY_STATE",
                 "finalize retry replayed hardware or backing cleanup")
    control.recover_resource(binding, mr.handle, second_recovery_result);
    expect_result("MR_DEREG_FINALIZE_RECOVERY_SECOND",
                  second_recovery_result, RDMA_SC_INVALID_STATE);
    if (mock_cmq.calls.size() != 2 || host_mem.calls.size() != 2 ||
        manager.mark_error_calls != 2 ||
        manager.finalize_release_calls != 2)
      `uvm_error("MR_DEREG_FINALIZE_RECOVERY_IDEMPOTENT",
                 "completed finalize recovery repeated a side effect")

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
                               null, 1us);
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

  task automatic check_lock_table_guard_contention();
    rdma_control_plane_probe control;
    rdma_resource_manager manager;
    rdma_mock_cmq_port mock_cmq;
    rdma_mock_stag_key_policy key_policy;
    rdma_function_binding binding;
    rdma_create_pd_req request;
    rdma_pd pd;
    rdma_control_result result;
    rdma_status status;
    semaphore held_guard;
    bit request_completed;

    control = rdma_control_plane_probe::type_id::create(
      "guard_contention_control"
    );
    manager = rdma_resource_manager::type_id::create(
      "guard_contention_manager"
    );
    mock_cmq = rdma_mock_cmq_port::type_id::create(
      "guard_contention_cmq"
    );
    key_policy = rdma_mock_stag_key_policy::type_id::create(
      "guard_contention_policy"
    );
    binding = make_active_binding(
      "guard_contention_binding", 64'hfa00_0000_0000_0001,
      32'hfa00_0101, 117
    );
    request = make_create_pd_request(
      "guard_contention_request", binding
    );
    status = control.configure(manager, mock_cmq, key_policy);
    expect_status("GUARD_CONTENTION_CONFIGURE", status, RDMA_SC_OK);

    request_completed = 1'b0;
    control.acquire_test_lock_table_guard(held_guard);
    fork
      begin
        control.create_pd(binding, request, pd, result);
        request_completed = 1'b1;
      end
      begin
        #1ns;
        if (request_completed)
          `uvm_error("GUARD_CONTENTION_BLOCKED",
                     "public API bypassed the held lock-table guard")
        control.release_test_lock_table_guard(held_guard);
      end
    join

    if (!request_completed)
      `uvm_error("GUARD_CONTENTION_RELEASED",
                 "public API did not resume after guard release")
    expect_result("GUARD_CONTENTION_RESULT", result, RDMA_SC_OK);
    if (pd == null || pd.handle == null)
      return;
    status = manager.begin_quiesce(pd.handle);
    expect_status("GUARD_CONTENTION_CLEANUP_QUIESCE", status, RDMA_SC_OK);
    status = manager.finalize_release(pd.handle);
    expect_status("GUARD_CONTENTION_CLEANUP_RELEASE", status, RDMA_SC_OK);
  endtask

  // Catches a missing typed facade, wrong resource projection, or a facade
  // that lets a mismatched destroy handle reach the queue executor.
  task automatic check_typed_queue_facade();
    rdma_control_plane control;
    rdma_resource_manager manager;
    rdma_mock_cmq_port cmq;
    rdma_mock_stag_key_policy key_policy;
    rdma_mock_host_mem host_mem;
    rdma_mock_context_backing context_backing;
    rdma_function_binding binding;
    rdma_create_pd_req pd_request;
    rdma_create_cq_req cq_request;
    rdma_create_srq_req srq_request;
    rdma_create_ceq_req ceq_request;
    rdma_create_aeq_req aeq_request;
    rdma_destroy_resource_req destroy_request;
    rdma_pd pd;
    rdma_ceq dependency;
    rdma_cq cq;
    rdma_srq srq;
    rdma_ceq ceq;
    rdma_aeq aeq;
    rdma_control_result result;
    rdma_status status;
    int unsigned cmq_before;

    control = rdma_control_plane::type_id::create("typed_queue_control");
    manager = rdma_resource_manager::type_id::create("typed_queue_manager");
    cmq = rdma_mock_cmq_port::type_id::create("typed_queue_cmq");
    key_policy = rdma_mock_stag_key_policy::type_id::create(
      "typed_queue_policy"
    );
    host_mem = rdma_mock_host_mem::type_id::create("typed_queue_mem");
    context_backing = rdma_mock_context_backing::type_id::create(
      "typed_queue_context"
    );
    binding = make_active_binding(
      "typed_queue_binding", 64'hfb00_0000_0000_0001, 32'hfb00_0101, 121
    );
    status = control.configure(manager, cmq, key_policy, host_mem, null,
                               context_backing, 2us);
    expect_status("TYPED_QUEUE_CONFIGURE", status, RDMA_SC_OK);
    pd_request = make_create_pd_request("typed_queue_pd_request", binding);
    control.create_pd(binding, pd_request, pd, result);
    expect_result("TYPED_QUEUE_PD", result, RDMA_SC_OK);
    status = manager.create_ceq(binding, dependency);
    expect_status("TYPED_QUEUE_DEPENDENCY", status, RDMA_SC_OK);
    if (pd == null || dependency == null)
      return;

    cq_request = make_create_cq_request("typed_queue_cq_request", binding,
                                        dependency);
    control.create_cq(binding, cq_request, cq, result);
    if (result == null || !result.ok() || cq == null ||
        cq.state != RDMA_RESOURCE_ACTIVE)
      `uvm_error("CP_CREATE_CQ", $sformatf("typed CQ facade failed: %s",
        result == null || result.status == null ? "null" :
          result.status.convert2string()))

    srq_request = make_create_srq_request("typed_queue_srq_request", binding,
                                          pd);
    control.create_srq(binding, srq_request, srq, result);
    if (result == null || !result.ok() || srq == null ||
        srq.state != RDMA_RESOURCE_ACTIVE)
      `uvm_error("CP_CREATE_SRQ", $sformatf("typed SRQ facade failed: %s",
        result == null || result.status == null ? "null" :
          result.status.convert2string()))

    ceq_request = make_create_ceq_request("typed_queue_ceq_request", binding);
    control.create_ceq(binding, ceq_request, ceq, result);
    if (result == null || !result.ok() || ceq == null ||
        ceq.state != RDMA_RESOURCE_ACTIVE)
      `uvm_error("CP_CREATE_CEQ", $sformatf("typed CEQ facade failed: %s",
        result == null || result.status == null ? "null" :
          result.status.convert2string()))

    aeq_request = make_create_aeq_request("typed_queue_aeq_request", binding);
    control.create_aeq(binding, aeq_request, aeq, result);
    if (result == null || !result.ok() || aeq == null ||
        aeq.state != RDMA_RESOURCE_ACTIVE)
      `uvm_error("CP_CREATE_AEQ", $sformatf("typed AEQ facade failed: %s",
        result == null || result.status == null ? "null" :
          result.status.convert2string()))

    destroy_request = rdma_destroy_resource_req::type_id::create(
      "typed_queue_destroy_request"
    );
    destroy_request.owner = binding.make_handle();
    destroy_request.target_h = cq == null ? null : cq.handle;
    cmq_before = cmq.calls.size();
    control.destroy_ceq(binding, destroy_request, result);
    if (result == null || result.status == null ||
        result.status.code != RDMA_SC_INVALID_ARGUMENT ||
        cmq.calls.size() != cmq_before)
      `uvm_error("CP_KIND_GUARD", "CEQ API accepted a CQ handle")
  endtask

  task automatic check_typed_queue_lock_serialization();
    rdma_control_plane_probe control;
    rdma_resource_manager manager;
    rdma_mock_cmq_port cmq;
    rdma_mock_stag_key_policy key_policy;
    rdma_mock_host_mem host_mem;
    rdma_mock_context_backing context_backing;
    rdma_function_binding binding;
    rdma_create_pd_req pd_request;
    rdma_register_mr_req mr_request;
    rdma_mr_backing_desc backing;
    rdma_create_cq_req cq_request;
    rdma_pd pd;
    rdma_ceq dependency;
    rdma_mr mr;
    rdma_cq cq;
    rdma_control_result result;
    rdma_control_result cq_result;
    rdma_status status;
    bit mr_entered;
    bit cq_done;
    bit entered;

    control = rdma_control_plane_probe::type_id::create("serial_control");
    manager = rdma_resource_manager::type_id::create("serial_manager");
    cmq = rdma_mock_cmq_port::type_id::create("serial_cmq");
    key_policy = rdma_mock_stag_key_policy::type_id::create("serial_policy");
    host_mem = rdma_mock_host_mem::type_id::create("serial_mem");
    context_backing = rdma_mock_context_backing::type_id::create("serial_context");
    binding = make_active_binding("serial_binding", 64'hfc00_0000_0000_0001,
                                  32'hfc00_0101, 131);
    status = control.configure(manager, cmq, key_policy, host_mem, null,
                               context_backing, 2us);
    expect_status("SERIAL_CONFIGURE", status, RDMA_SC_OK);
    pd_request = make_create_pd_request("serial_pd_request", binding);
    control.create_pd(binding, pd_request, pd, result);
    expect_result("SERIAL_PD", result, RDMA_SC_OK);
    status = manager.create_ceq(binding, dependency);
    expect_status("SERIAL_DEPENDENCY", status, RDMA_SC_OK);
    if (pd == null || dependency == null)
      return;
    mr_request = make_register_mr_request("serial_mr_request", binding, pd);
    backing = make_borrowed_pbl0_backing("serial_mr_backing", binding,
                                          mr_request);
    cq_request = make_create_cq_request("serial_cq_request", binding,
                                        dependency);
    cmq.gate_opcode(XTR_V1_OP_KEY_ALLOC);
    mr_entered = 1'b0;
    cq_done = 1'b0;
    fork
      begin
        control.register_mr(binding, mr_request, backing, mr, result);
        mr_entered = 1'b1;
      end
      begin
        cmq.wait_until_entered(1, 1us, entered);
        if (!entered)
          `uvm_error("SERIAL_MR_GATE", "MR did not enter the CMQ gate")
        else begin
          fork
            begin
              control.create_cq(binding, cq_request, cq, cq_result);
              cq_done = 1'b1;
            end
          join_none
          #1ns;
          if (cmq.calls.size() != 0)
            `uvm_error("SERIAL_CMQ_OVERLAP",
                       "same-Function CQ reached CMQ while MR was gated")
          cmq.release_one();
          wait (cq_done);
        end
      end
    join
    expect_result("SERIAL_MR_RESULT", result, RDMA_SC_OK);
    expect_result("SERIAL_CQ_RESULT", cq_result, RDMA_SC_OK);
  endtask

  task automatic check_typed_queue_cross_function_barrier();
    rdma_control_plane controls[2];
    rdma_resource_manager managers[2];
    rdma_mock_host_mem mem[2];
    rdma_mock_context_backing contexts[2];
    rdma_mock_stag_key_policy policies[2];
    rdma_function_binding bindings[2];
    rdma_mock_cmq_port cmq;
    rdma_create_ceq_req requests[2];
    rdma_ceq ceqs[2];
    rdma_control_result results[2];
    rdma_status status;
    bit done[2];
    bit entered;

    cmq = rdma_mock_cmq_port::type_id::create("cross_function_cmq");
    for (int unsigned i = 0; i < 2; i++) begin
      controls[i] = rdma_control_plane::type_id::create(
        $sformatf("cross_function_control_%0d", i)
      );
      managers[i] = rdma_resource_manager::type_id::create(
        $sformatf("cross_function_manager_%0d", i)
      );
      mem[i] = rdma_mock_host_mem::type_id::create(
        $sformatf("cross_function_mem_%0d", i)
      );
      contexts[i] = rdma_mock_context_backing::type_id::create(
        $sformatf("cross_function_context_%0d", i)
      );
      policies[i] = rdma_mock_stag_key_policy::type_id::create(
        $sformatf("cross_function_policy_%0d", i)
      );
      bindings[i] = make_active_binding(
        $sformatf("cross_function_binding_%0d", i),
        64'hfd00_0000_0000_0000 + i + 1,
        32'hfd00_0101 + i, 137
      );
      status = controls[i].configure(managers[i], cmq, policies[i], mem[i],
                                     null, contexts[i], 2us);
      expect_status($sformatf("CROSS_FUNCTION_CONFIGURE_%0d", i), status,
                    RDMA_SC_OK);
      requests[i] = make_create_ceq_request(
        $sformatf("cross_function_request_%0d", i), bindings[i]
      );
      done[i] = 1'b0;
    end

    cmq.gate_opcode_count(XTR_V1_OP_CEQC_CREATE, 2);
    fork
      begin
        controls[0].create_ceq(bindings[0], requests[0], ceqs[0], results[0]);
        done[0] = 1'b1;
      end
      begin
        controls[1].create_ceq(bindings[1], requests[1], ceqs[1], results[1]);
        done[1] = 1'b1;
      end
      begin
        cmq.wait_until_entered(2, 1us, entered);
        if (!entered)
          `uvm_error("CROSS_FUNCTION_BARRIER", "both EQ creates did not enter")
        cmq.release_one();
        wait (done[0] && done[1]);
      end
    join
    expect_result("CROSS_FUNCTION_RESULT_A", results[0], RDMA_SC_OK);
    expect_result("CROSS_FUNCTION_RESULT_B", results[1], RDMA_SC_OK);
  endtask

  task automatic check_typed_queue_rebind_while_waiting();
    rdma_control_plane_probe control;
    rdma_resource_manager manager;
    rdma_mock_cmq_port cmq;
    rdma_mock_stag_key_policy policy;
    rdma_mock_host_mem mem;
    rdma_mock_context_backing context_adapter;
    rdma_function_binding binding;
    rdma_ceq dependency;
    rdma_create_cq_req request;
    rdma_cq cq;
    rdma_control_result result;
    rdma_status status;
    semaphore held_lock;
    int unsigned baseline_allocations;

    control = rdma_control_plane_probe::type_id::create("rebind_control");
    manager = rdma_resource_manager::type_id::create("rebind_manager");
    cmq = rdma_mock_cmq_port::type_id::create("rebind_cmq");
    policy = rdma_mock_stag_key_policy::type_id::create("rebind_policy");
    mem = rdma_mock_host_mem::type_id::create("rebind_mem");
    context_adapter = rdma_mock_context_backing::type_id::create("rebind_context");
    binding = make_active_binding("rebind_binding", 64'hfe00_0000_0000_0001,
                                  32'hfe00_0101, 149);
    status = control.configure(manager, cmq, policy, mem, null, context_adapter, 2us);
    expect_status("REBIND_CONFIGURE", status, RDMA_SC_OK);
    status = manager.create_ceq(binding, dependency);
    expect_status("REBIND_DEPENDENCY", status, RDMA_SC_OK);
    if (dependency == null)
      return;
    request = make_create_cq_request("rebind_request", binding, dependency);
    baseline_allocations = mem.live_allocations();
    control.acquire_test_function_lock(binding.make_handle(), held_lock);
    fork
      begin
        control.create_cq(binding, request, cq, result);
      end
      begin
        #1ns;
        binding.generation++;
        binding.owner_h = binding.make_handle();
        control.release_test_function_lock(held_lock);
      end
    join
    expect_result("REBIND_RESULT", result, RDMA_SC_STALE_GENERATION);
    if (cq != null || mem.live_allocations() != baseline_allocations)
      `uvm_error("REBIND_NO_BACKING", "stale queue create allocated backing")
  endtask

  task automatic check_typed_qp_facade();
    rdma_control_plane_probe control;
    rdma_resource_manager manager;
    rdma_mock_cmq_port cmq;
    rdma_mock_stag_key_policy policy;
    rdma_mock_host_mem mem;
    rdma_mock_context_backing contexts;
    rdma_function_binding binding;
    rdma_function function_resource;
    rdma_pd pd;
    rdma_cq cq;
    rdma_create_qp_req request;
    rdma_qp qp;
    rdma_qp authoritative_qp;
    rdma_resource authoritative;
    rdma_control_result result;
    rdma_status status;

    control = rdma_control_plane_probe::type_id::create("typed_qp_control");
    manager = rdma_resource_manager::type_id::create("typed_qp_manager");
    cmq = rdma_mock_cmq_port::type_id::create("typed_qp_cmq");
    policy = rdma_mock_stag_key_policy::type_id::create("typed_qp_policy");
    mem = rdma_mock_host_mem::type_id::create("typed_qp_mem");
    contexts = rdma_mock_context_backing::type_id::create("typed_qp_contexts");
    binding = make_active_binding("typed_qp_binding",
                                  64'hfc00_0000_0000_0001,
                                  32'hfc00_0101, 151);
    expect_status("TYPED_QP_CONFIGURE",
      control.configure(manager, cmq, policy, mem, null, contexts, 2us),
      RDMA_SC_OK);
    expect_status("TYPED_QP_FUNCTION",
                  manager.create_function(binding, function_resource),
                  RDMA_SC_OK);
    expect_status("TYPED_QP_PD", manager.create_pd(binding, pd), RDMA_SC_OK);
    expect_status("TYPED_QP_CQ", manager.create_cq(binding, null, cq),
                  RDMA_SC_OK);
    request = make_create_qp_request("typed_qp_request", binding, pd, cq);
    control.create_qp(binding, request, qp, result);
    expect_result("TYPED_QP_RESULT", result, RDMA_SC_OK);
    if (qp == null || qp.state != RDMA_RESOURCE_ACTIVE ||
        qp.qp_state != RDMA_QPS_RESET || result.transaction_id == 0 ||
        cmq.calls.size() != 1 ||
        cmq.calls[0].opcode != XTR_V1_OP_QPC_CREATE)
      `uvm_error("TYPED_QP_OUTPUT",
                 "public create_qp did not return ACTIVE+RESET authority")
    if (qp != null) begin
      status = manager.lookup(qp.handle, authoritative);
      expect_status("TYPED_QP_LOOKUP", status, RDMA_SC_OK);
      if (!$cast(authoritative_qp, authoritative) || authoritative_qp == null ||
          authoritative_qp === qp)
        `uvm_error("TYPED_QP_DETACHED",
                   "public create_qp returned aliased registry authority")
    end
  endtask

  task automatic check_typed_qp_rebind_while_waiting();
    rdma_control_plane_probe control;
    rdma_resource_manager manager;
    rdma_mock_cmq_port cmq;
    rdma_mock_stag_key_policy policy;
    rdma_mock_host_mem mem;
    rdma_mock_context_backing contexts;
    rdma_function_binding binding;
    rdma_function function_resource;
    rdma_pd pd;
    rdma_cq cq;
    rdma_create_qp_req request;
    rdma_qp qp;
    rdma_control_result result;
    semaphore held_lock;
    int unsigned baseline_allocations;

    control = rdma_control_plane_probe::type_id::create("qp_rebind_control");
    manager = rdma_resource_manager::type_id::create("qp_rebind_manager");
    cmq = rdma_mock_cmq_port::type_id::create("qp_rebind_cmq");
    policy = rdma_mock_stag_key_policy::type_id::create("qp_rebind_policy");
    mem = rdma_mock_host_mem::type_id::create("qp_rebind_mem");
    contexts = rdma_mock_context_backing::type_id::create("qp_rebind_contexts");
    binding = make_active_binding("qp_rebind_binding",
                                  64'hfc00_0000_0000_0002,
                                  32'hfc00_0102, 153);
    expect_status("QP_REBIND_CONFIGURE",
      control.configure(manager, cmq, policy, mem, null, contexts, 2us),
      RDMA_SC_OK);
    expect_status("QP_REBIND_FUNCTION",
                  manager.create_function(binding, function_resource),
                  RDMA_SC_OK);
    expect_status("QP_REBIND_PD", manager.create_pd(binding, pd), RDMA_SC_OK);
    expect_status("QP_REBIND_CQ", manager.create_cq(binding, null, cq),
                  RDMA_SC_OK);
    request = make_create_qp_request("qp_rebind_request", binding, pd, cq);
    baseline_allocations = mem.live_allocations();
    control.acquire_test_function_lock(binding.make_handle(), held_lock);
    fork
      begin
        control.create_qp(binding, request, qp, result);
      end
      begin
        #1ns;
        binding.generation++;
        binding.owner_h = binding.make_handle();
        control.release_test_function_lock(held_lock);
      end
    join
    expect_result("QP_REBIND_RESULT", result, RDMA_SC_STALE_GENERATION);
    if (qp != null || result.transaction_id == 0 || cmq.calls.size() != 0 ||
        mem.live_allocations() != baseline_allocations)
      `uvm_error("QP_REBIND_NO_SIDE_EFFECT",
                 "post-lock QP rebind reached executor side effects")
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
    run_owned_mr_failure("deregister_timeout");
    check_creation_deregister_late_failure_deferred_retry();
    check_owned_mr_prestage_release_failure();
    check_owned_mr_prestage_double_cleanup_failure();
    check_owned_recovery_status_accumulation();
    check_owned_mr_timeout_freeze_failure_no_mapping();
    check_owned_mr_released_mapping_not_returned();
    check_owned_mr_unattached_release_failure();
    check_owned_mr_success();
    check_pd_lifecycle();
    check_borrowed_pbl0_registration();
    check_key_alloc_explicit_failure();
    check_key_alloc_timeout_recovery();
    check_key_alloc_late_failure_recovery();
    check_register_mr_caller_snapshot();
    check_register_mr_post_cmq_fence();
    check_function_concurrency();
    check_register_mr_pre_activate_generation_fence();
    check_register_mr_recovery_freeze_failures();
    check_borrowed_pbl1_pbl2_registration();
    check_mr_deregister_success_and_busy();
    check_deregister_generation_fences();
    check_mr_deregister_failure_table();
    check_register_mr_pre_cmq_rejections();
    check_post_activate_snapshot_cleanup();
    check_post_lock_revalidation();
    check_register_mr_post_lock_revalidation();
    check_supplied_lock_ownership();
    check_owned_post_lock_snapshot();
    check_transaction_id_exhaustion();
    check_owned_recovery_completion_hook_guard();
    check_lock_table_guard_contention();
    check_typed_queue_facade();
    check_typed_queue_lock_serialization();
    check_typed_queue_cross_function_barrier();
    check_typed_queue_rebind_while_waiting();
    check_typed_qp_facade();
    check_typed_qp_rebind_while_waiting();
    phase.drop_objection(this);
  endtask
endclass
