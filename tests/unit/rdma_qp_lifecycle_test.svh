class rdma_qp_allocate_error_host_mem extends rdma_mock_host_mem;
  `uvm_object_utils(rdma_qp_allocate_error_host_mem)
  bit injected;

  function new(string name = "rdma_qp_allocate_error_host_mem");
    super.new(name);
    injected = 1'b0;
  endfunction

  virtual function rdma_status allocate(
    rdma_dma_request_context request_context,
    int unsigned size,
    int unsigned alignment,
    rdma_dma_direction_e direction,
    output rdma_dma_mapping mapping
  );
    rdma_status status;
    status = super.allocate(request_context, size, alignment, direction, mapping);
    if (status != null && status.ok() && !injected) begin
      injected = 1'b1;
      return rdma_status::make(
        RDMA_SC_RESOURCE_EXHAUSTED,
        "injected allocation error with a non-null mapping"
      );
    end
    return status;
  endfunction
endclass

class rdma_qp_authority_probe_mapping extends rdma_mock_dma_mapping;
  `uvm_object_utils(rdma_qp_authority_probe_mapping)
  bit fail_before_copy;
  bit fail_after_copy;
  int unsigned check_count;

  function new(string name = "rdma_qp_authority_probe_mapping");
    super.new(name);
    fail_before_copy = 1'b0;
    fail_after_copy = 1'b0;
    check_count = 0;
  endfunction

  virtual function rdma_status release_authority_status(
    rdma_dma_mapping snapshot
  );
    check_count++;
    if (snapshot != null &&
        (fail_before_copy && snapshot.iova.value == 0 ||
         fail_after_copy && snapshot.iova.value != 0))
      return rdma_status::make(
        RDMA_SC_INVALID_STATE,
        "injected opaque release-authority mismatch"
      );
    return super.release_authority_status(snapshot);
  endfunction
endclass

class rdma_qp_authority_failure_host_mem extends rdma_mock_host_mem;
  `uvm_object_utils(rdma_qp_authority_failure_host_mem)
  int unsigned fail_check_ordinal;
  bit decorated;

  function new(string name = "rdma_qp_authority_failure_host_mem");
    super.new(name);
    fail_check_ordinal = 1;
    decorated = 1'b0;
  endfunction

  virtual function rdma_status allocate(
    rdma_dma_request_context request_context,
    int unsigned size,
    int unsigned alignment,
    rdma_dma_direction_e direction,
    output rdma_dma_mapping mapping
  );
    rdma_status status;
    rdma_qp_authority_probe_mapping probe;

    status = super.allocate(request_context, size, alignment, direction, mapping);
    if (status != null && status.ok() && !decorated) begin
      probe = rdma_qp_authority_probe_mapping::type_id::create(
        "qp_authority_probe"
      );
      probe.copy(mapping);
      probe.fail_before_copy = fail_check_ordinal == 1;
      probe.fail_after_copy = fail_check_ordinal == 2;
      mapping = probe;
      decorated = 1'b1;
    end
    return status;
  endfunction
endclass

class rdma_qp_rebind_host_mem extends rdma_mock_host_mem;
  `uvm_object_utils(rdma_qp_rebind_host_mem)
  rdma_function_binding binding_target;
  bit rebound;

  function new(string name = "rdma_qp_rebind_host_mem");
    super.new(name);
    binding_target = null;
    rebound = 1'b0;
  endfunction

  virtual function rdma_status write(
    rdma_dma_mapping mapping,
    longint unsigned offset,
    byte data[]
  );
    rdma_status status;
    status = super.write(mapping, offset, data);
    if (status != null && status.ok() && data.size() == 512 &&
        binding_target != null && !rebound) begin
      binding_target.generation++;
      binding_target.owner_h = binding_target.make_handle();
      rebound = 1'b1;
    end
    return status;
  endfunction
endclass

class rdma_qp_lifecycle_test extends uvm_test;
  `uvm_component_utils(rdma_qp_lifecycle_test)

  function new(string name = "rdma_qp_lifecycle_test",
               uvm_component parent = null);
    super.new(name, parent);
  endfunction

  function automatic void expect_ok(string label, rdma_status status);
    if (status == null || !status.ok())
      `uvm_error(label, status == null ? "null status" : status.convert2string())
  endfunction

  function automatic void expect_code(
    string label, rdma_status status, rdma_status_code_e expected
  );
    if (status == null || status.code != expected)
      `uvm_error(label, $sformatf("expected %s, got %s", expected.name(),
        status == null ? "null" : status.convert2string()))
  endfunction

  function automatic rdma_function_binding make_binding(string name);
    rdma_function_binding binding;
    rdma_interrupt_vector_binding vector;

    binding = rdma_function_binding::type_id::create(name);
    binding.function_uid = 64'h1122_3344_5566_7788;
    binding.generation = 7;
    binding.global_function_id = 32'h1234_0001;
    binding.host_id = 5;
    binding.rdma_vf_id = 8'h55;
    binding.pfvf_id = 32'h1234_0099;
    binding.pcie.bdf = '{segment:16'h1, bus:8'h20, device:5'h2,
                         function_num:3'h1};
    binding.pcie.parent_pf_bdf = binding.pcie.bdf;
    binding.pcie.mse = 1'b1;
    binding.pcie.bme = 1'b1;
    binding.pcie.bar[0].base.value = 64'h8000_0000;
    binding.pcie.bar[0].size = 64'h4000;
    binding.pcie.bar[0].enabled = 1'b1;
    binding.notify_bar_id = 0;
    binding.notify_base.value = 64'h8000_2000;
    binding.notify_size = 64'h2000;
    binding.queue_dma.requester_bdf = binding.pcie.bdf;
    binding.queue_dma.pasid_valid = 1'b1;
    binding.queue_dma.pasid = 20'h12345;
    binding.queue_dma.dma_domain_valid = 1'b1;
    binding.queue_dma.dma_domain_id = 9;
    binding.queue_caps.min_cq_depth = 16;
    binding.queue_caps.max_cq_depth = 32768;
    binding.queue_caps.min_srq_depth = 16;
    binding.queue_caps.max_srq_depth = 32768;
    binding.queue_caps.max_ceq_depth = 4096;
    binding.queue_caps.max_aeq_depth = 4096;
    binding.queue_caps.max_wq_sge = 8;
    binding.queue_caps.max_queue_ring_bytes = 2 * 1024 * 1024;
    binding.queue_caps.max_sgb_bytes = 2 * 1024 * 1024;
    vector = '{default:'0};
    vector.function_local_vector = 1;
    vector.hardware_eq_vector = 1;
    vector.msix_table_index = 1;
    vector.enabled = 1'b1;
    binding.interrupt_vectors.push_back(vector);
    binding.state = RDMA_BIND_ACTIVE;
    binding.owner_h = binding.make_handle();
    binding.notify_valid = 1'b1;
    binding.notify_ready = 1'b1;
    binding.dmi_valid = 1'b1;
    binding.dmi_ready = 1'b1;
    binding.vft_valid = 1'b1;
    binding.vft_ready = 1'b1;
    return binding;
  endfunction

  function automatic rdma_qp_context_attributes make_rc_attrs(string name);
    rdma_qp_context_attributes attrs;
    rdma_qpc_rc_ext ext;

    attrs = rdma_qp_context_attributes::type_id::create(name);
    attrs.path_mtu_bytes = 4096;
    attrs.pkey = 16'hbeef;
    attrs.address_vector = rdma_address_vector::type_id::create({name, "_av"});
    attrs.address_vector.destination_mac = 48'h1122_3344_5566;
    attrs.address_vector.traffic_class = 8'h02;
    attrs.behavior = rdma_qpc_behavior::type_id::create({name, "_behavior"});
    attrs.behavior.transport_version = 1;
    ext = rdma_qpc_rc_ext::type_id::create({name, "_rc"});
    ext.remote_qpn = 24'h456789;
    ext.send_psn = 24'h123456;
    ext.recv_psn = 24'h654321;
    ext.retry_count = 2;
    ext.rnr_retry_count = 2;
    attrs.transport_ext = ext;
    return attrs;
  endfunction

  function automatic rdma_qp_context_attributes make_urc_attrs(string name);
    rdma_qp_context_attributes attrs;
    rdma_qpc_urc_ext ext;

    attrs = make_rc_attrs(name);
    ext = rdma_qpc_urc_ext::type_id::create({name, "_urc"});
    ext.remote_qpn = 24'h765432;
    ext.rbsn = 24'h010203;
    ext.dbsn = 24'h040506;
    ext.rpsn = 24'h070809;
    ext.dpsn = 24'h0a0b0c;
    ext.queues.rsq_depth = 64;
    ext.queues.rdsq_depth = 64;
    ext.queues.rdsq_fetch_count = 8;
    ext.queues.dsq_fetch_count = 8;
    ext.queues.rq_sequence_threshold_entries = 64;
    ext.queues.sq_completion_threshold_entries = 128;
    attrs.transport_ext = ext;
    return attrs;
  endfunction

  function automatic rdma_qp_context_attributes make_ud_attrs(string name);
    rdma_qp_context_attributes attrs;
    rdma_qpc_ud_ext ext;
    attrs = make_rc_attrs(name);
    attrs.address_vector.traffic_class = 8'hac;
    ext = rdma_qpc_ud_ext::type_id::create({name, "_ud"});
    ext.qkey = 32'h1111_2222;
    attrs.transport_ext = ext;
    return attrs;
  endfunction

  function automatic rdma_create_qp_req make_request(
    string name, rdma_function_binding binding, rdma_pd pd, rdma_cq cq,
    rdma_transport_e transport
  );
    rdma_create_qp_req request;

    request = rdma_create_qp_req::type_id::create(name);
    request.owner = binding.make_handle();
    request.transport = transport;
    request.sq_depth = 128;
    request.rq_depth = 64;
    request.max_send_sge = 4;
    request.max_recv_sge = 4;
    request.pd_h = rdma_clone_handle_value(pd.handle, "test QP PD");
    request.send_cq_h = rdma_clone_handle_value(cq.handle, "test QP send CQ");
    request.recv_cq_h = rdma_clone_handle_value(cq.handle, "test QP receive CQ");
    request.context_attrs = transport == RDMA_TRANSPORT_URC ?
      make_urc_attrs({name, "_attrs"}) : transport == RDMA_TRANSPORT_UD ?
      make_ud_attrs({name, "_attrs"}) : make_rc_attrs({name, "_attrs"});
    return request;
  endfunction

  task automatic setup_qp_environment(
    string label,
    rdma_mock_host_mem mem,
    output rdma_function_binding binding,
    output rdma_resource_manager manager,
    output rdma_mock_context_backing contexts,
    output rdma_mock_cmq_port cmq,
    output rdma_qp_lifecycle_executor executor,
    output rdma_pd pd,
    output rdma_cq cq
  );
    rdma_function function_resource;

    binding = make_binding({label, "_binding"});
    manager = rdma_resource_manager::type_id::create({label, "_manager"});
    contexts = rdma_mock_context_backing::type_id::create({label, "_contexts"});
    cmq = rdma_mock_cmq_port::type_id::create({label, "_cmq"});
    executor = rdma_qp_lifecycle_executor::type_id::create({label, "_executor"});
    expect_ok({label, "_FUNCTION"}, manager.create_function(binding,
                                                              function_resource));
    expect_ok({label, "_PD"}, manager.create_pd(binding, pd));
    expect_ok({label, "_CQ"}, manager.create_cq(binding, null, cq));
    expect_ok({label, "_CONFIGURE"}, executor.configure(manager, cmq, mem,
                                                          contexts, 2us));
  endtask

  function automatic rdma_dma_request_context make_borrowed_context(
    string name,
    rdma_function_binding binding,
    rdma_handle owner_h,
    rdma_queue_backing_role_e role
  );
    rdma_dma_request_context request_context;

    request_context = rdma_dma_request_context::type_id::create(name);
    request_context.function_h = binding.make_handle();
    request_context.requester_bdf = binding.queue_dma.requester_bdf;
    request_context.pasid_valid = binding.queue_dma.pasid_valid;
    request_context.pasid = binding.queue_dma.pasid;
    request_context.dma_domain_valid = binding.queue_dma.dma_domain_valid;
    request_context.dma_domain_id = binding.queue_dma.dma_domain_id;
    request_context.owner_h = rdma_clone_handle_value(owner_h,
                                                       "borrowed caller owner");
    request_context.queue_role_valid = 1'b1;
    request_context.queue_role = int'(role);
    return request_context;
  endfunction

  task automatic allocate_borrowed_mapping(
    string label,
    rdma_mock_host_mem mem,
    rdma_function_binding binding,
    rdma_handle owner_h,
    rdma_queue_backing_role_e role,
    output rdma_dma_mapping mapping
  );
    rdma_dma_request_context request_context;
    request_context = make_borrowed_context({label, "_context"}, binding,
                                             owner_h, role);
    expect_ok(label, mem.allocate(request_context, 8192, 4096,
                                  RDMA_DMA_BIDIRECTIONAL, mapping));
  endtask

  function automatic rdma_queue_backing_slice make_borrowed_slice(
    string name,
    rdma_queue_backing_role_e role,
    rdma_dma_mapping mapping,
    longint unsigned mapping_offset,
    longint unsigned logical_queue_offset
  );
    rdma_queue_backing_slice slice;
    slice = rdma_queue_backing_slice::type_id::create(name);
    slice.role = role;
    slice.mapping = mapping;
    slice.mapping_offset = mapping_offset;
    slice.length = 4096;
    slice.logical_queue_offset = logical_queue_offset;
    return slice;
  endfunction

  task automatic create_qp_fixture(
    string label,
    rdma_transport_e transport,
    output rdma_mock_host_mem mem,
    output rdma_qp qp
  );
    rdma_function_binding binding;
    rdma_resource_manager manager;
    rdma_mock_context_backing contexts;
    rdma_mock_cmq_port cmq;
    rdma_qp_lifecycle_executor executor;
    rdma_function function_resource;
    rdma_pd pd;
    rdma_cq cq;
    rdma_create_qp_req request;
    rdma_control_result result;

    qp = null;
    binding = make_binding({label, "_binding"});
    manager = rdma_resource_manager::type_id::create({label, "_manager"});
    mem = rdma_mock_host_mem::type_id::create({label, "_mem"});
    contexts = rdma_mock_context_backing::type_id::create({label, "_contexts"});
    cmq = rdma_mock_cmq_port::type_id::create({label, "_cmq"});
    executor = rdma_qp_lifecycle_executor::type_id::create({label, "_executor"});
    expect_ok({label, "_FUNCTION"}, manager.create_function(binding, function_resource));
    expect_ok({label, "_PD"}, manager.create_pd(binding, pd));
    expect_ok({label, "_CQ"}, manager.create_cq(binding, null, cq));
    expect_ok({label, "_CONFIGURE"}, executor.configure(manager, cmq, mem,
                                                           contexts, 2us));
    request = make_request({label, "_request"}, binding, pd, cq, transport);
    executor.create_locked(binding, binding.make_handle(), request, 41, qp, result);
    if (result == null || result.status == null || !result.status.ok() || qp == null)
      `uvm_error(label, result == null || result.status == null ?
                 "QP create returned no successful result" : result.status.convert2string())
  endtask

  task automatic check_rc_plan_and_staging_authority();
    rdma_mock_host_mem mem;
    rdma_qp qp;
    rdma_dma_mapping staging_mapping;

    create_qp_fixture("RC_PLAN", RDMA_TRANSPORT_RC, mem, qp);
    if (qp == null || qp.qp_plan == null || qp.programmed_qpc == null)
      `uvm_error("RC_PLAN", "create did not retain plan and semantic QPC")
    else begin
      if (qp.qp_plan.sq_ring.logical_bytes != 8192 ||
          qp.qp_plan.sq_ring.storage_bytes != 8192 ||
          qp.qp_plan.rq_ring.logical_bytes != 4096 ||
          qp.qp_plan.rq_ring.storage_bytes != 4096)
        `uvm_error("RC_PLAN", "64-byte WQE geometry was not materialized")
      if (qp.sq_iova.value == qp.qp_plan.sq_pd_ref.mapping.iova.value ||
          qp.rq_iova.value == qp.qp_plan.rq_pd_ref.mapping.iova.value ||
          qp.programmed_qpc.sq_backing.value !=
            qp.qp_plan.sq_pd_ref.mapping.iova.value ||
          qp.programmed_qpc.rq_backing.value !=
            qp.qp_plan.rq_pd_ref.mapping.iova.value)
        `uvm_error("RC_PLAN", "payload IOVA and page-directory authority crossed")
      if ((qp.qp_plan.context_ref.shadow_pointer_base.value & 64'h1ff) != 0)
        `uvm_error("RC_PLAN", "QPC context is not 512-byte aligned")
    end
    staging_mapping = null;
    foreach (mem.regions[i])
      if (mem.regions[i].mapping != null && mem.regions[i].mapping.size == 512)
        staging_mapping = mem.regions[i].mapping;
    if (staging_mapping == null || qp == null || qp.qp_plan == null ||
        staging_mapping.iova.value == qp.qp_plan.context_ref.shadow_pointer_base.value)
      `uvm_error("RC_PLAN", "staging mapping was not distinct from QPC context")
    foreach (mem.calls[i])
      if (mem.calls[i].method_name == "allocate" && mem.calls[i].size == 512 &&
          (mem.calls[i].request_context == null ||
           mem.calls[i].request_context.owner_h == null || qp == null ||
           !mem.calls[i].request_context.owner_h.same_instance(qp.handle)))
        `uvm_error("RC_PLAN", "staging DMA owner was not the global QP handle")
  endtask

  task automatic check_ud_semantic_round_trip();
    rdma_mock_host_mem mem;
    rdma_qp qp;
    rdma_qpc_ud_ext ud_ext;
    create_qp_fixture("UD_QPC", RDMA_TRANSPORT_UD, mem, qp);
    ud_ext = null;
    if (qp == null || qp.programmed_qpc == null ||
        qp.programmed_qpc.transport != RDMA_TRANSPORT_UD ||
        !$cast(ud_ext, qp.programmed_qpc.transport_ext) ||
        ud_ext.qkey != 32'h1111_2222)
      `uvm_error("UD_QPC", "UD QPC was not materialized through its codec")
  endtask

  task automatic check_urc_internal_geometry();
    rdma_mock_host_mem mem;
    rdma_qp qp;
    bit seen_rsq, seen_rdsq, seen_dsq;

    create_qp_fixture("URC_PLAN", RDMA_TRANSPORT_URC, mem, qp);
    seen_rsq = 0; seen_rdsq = 0; seen_dsq = 0;
    if (qp != null && qp.qp_plan != null) begin
      foreach (qp.qp_plan.urc_refs[i]) begin
        if (qp.qp_plan.urc_refs[i].role == RDMA_QUEUE_ROLE_QP_URC_RSQ &&
            qp.qp_plan.urc_refs[i].length == 4096) seen_rsq = 1;
        if (qp.qp_plan.urc_refs[i].role == RDMA_QUEUE_ROLE_QP_URC_RDSQ &&
            qp.qp_plan.urc_refs[i].length == 4096) seen_rdsq = 1;
        if (qp.qp_plan.urc_refs[i].role == RDMA_QUEUE_ROLE_QP_URC_DSQ &&
            qp.qp_plan.urc_refs[i].length == 8192) seen_dsq = 1;
      end
    end
    if (!(seen_rsq && seen_rdsq && seen_dsq))
      `uvm_error("URC_PLAN", "URC RSQ/RDSQ/DSQ owned geometry is wrong")
  endtask

  task automatic check_allocate_error_cleanup();
    rdma_qp_allocate_error_host_mem mem;
    rdma_function_binding binding;
    rdma_resource_manager manager;
    rdma_mock_context_backing contexts;
    rdma_mock_cmq_port cmq;
    rdma_qp_lifecycle_executor executor;
    rdma_pd pd;
    rdma_cq cq;
    rdma_create_qp_req request;
    rdma_qp qp;
    rdma_control_result result;
    int unsigned release_count;

    mem = rdma_qp_allocate_error_host_mem::type_id::create("ALLOC_ERROR_mem");
    setup_qp_environment("ALLOC_ERROR", mem, binding, manager, contexts, cmq,
                         executor, pd, cq);
    request = make_request("ALLOC_ERROR_request", binding, pd, cq,
                           RDMA_TRANSPORT_RC);
    executor.create_locked(binding, binding.make_handle(), request, 201, qp,
                           result);
    expect_code("ALLOC_ERROR_STATUS",
      result == null ? null : result.status, RDMA_SC_RESOURCE_EXHAUSTED);
    release_count = 0;
    foreach (mem.calls[i])
      if (mem.calls[i].method_name == "release") release_count++;
    if (qp != null || mem.live_allocations() != 0 || release_count != 1)
      `uvm_error("ALLOC_ERROR_CLEANUP",
        "non-null failed allocation was not released exactly once")
  endtask

  task automatic check_authority_failure_cleanup(int unsigned ordinal);
    rdma_qp_authority_failure_host_mem mem;
    rdma_function_binding binding;
    rdma_resource_manager manager;
    rdma_mock_context_backing contexts;
    rdma_mock_cmq_port cmq;
    rdma_qp_lifecycle_executor executor;
    rdma_pd pd;
    rdma_cq cq;
    rdma_create_qp_req request;
    rdma_qp qp;
    rdma_control_result result;
    int unsigned release_count;
    string label;

    label = $sformatf("AUTHORITY_%0d", ordinal);
    mem = rdma_qp_authority_failure_host_mem::type_id::create({label, "_mem"});
    mem.fail_check_ordinal = ordinal;
    setup_qp_environment(label, mem, binding, manager, contexts, cmq, executor,
                         pd, cq);
    request = make_request({label, "_request"}, binding, pd, cq,
                           RDMA_TRANSPORT_RC);
    executor.create_locked(binding, binding.make_handle(), request, 202 + ordinal,
                           qp, result);
    expect_code({label, "_STATUS"}, result == null ? null : result.status,
                RDMA_SC_INVALID_STATE);
    release_count = 0;
    foreach (mem.calls[i])
      if (mem.calls[i].method_name == "release") release_count++;
    if (qp != null || mem.live_allocations() != 0 || release_count != 1)
      `uvm_error({label, "_CLEANUP"},
        "opaque authority failure did not release its allocation")
  endtask

  task automatic check_stale_rebind_blocks_attach();
    rdma_qp_rebind_host_mem mem;
    rdma_function_binding binding;
    rdma_resource_manager manager;
    rdma_mock_context_backing contexts;
    rdma_mock_cmq_port cmq;
    rdma_qp_lifecycle_executor executor;
    rdma_pd pd;
    rdma_cq cq;
    rdma_create_qp_req request;
    rdma_qp qp;
    rdma_control_result result;
    rdma_handle reserved_qp_h;
    rdma_resource reserved_resource;
    bit saw_staging_release;

    mem = rdma_qp_rebind_host_mem::type_id::create("STALE_REBIND_mem");
    setup_qp_environment("STALE_REBIND", mem, binding, manager, contexts, cmq,
                         executor, pd, cq);
    mem.binding_target = binding;
    request = make_request("STALE_REBIND_request", binding, pd, cq,
                           RDMA_TRANSPORT_RC);
    executor.create_locked(binding, binding.make_handle(), request, 205, qp,
                           result);
    expect_code("STALE_REBIND_STATUS",
      result == null ? null : result.status, RDMA_SC_STALE_GENERATION);
    reserved_qp_h = null;
    saw_staging_release = 1'b0;
    foreach (mem.calls[i]) begin
      if (reserved_qp_h == null && mem.calls[i].method_name == "allocate" &&
          mem.calls[i].request_context != null)
        reserved_qp_h = mem.calls[i].request_context.owner_h;
      if (mem.calls[i].method_name == "release" &&
          mem.calls[i].mapping != null && mem.calls[i].mapping.size == 512)
        saw_staging_release = 1'b1;
    end
    // Restore the registry's original Function generation only for the
    // read-only publication check.  The create result above already captured
    // the injected stale-generation outcome.
    if (mem.rebound) begin
      binding.generation--;
      binding.owner_h = binding.make_handle();
    end
    expect_ok("STALE_REBIND_LOOKUP",
              manager.lookup(reserved_qp_h, reserved_resource));
    if (!mem.rebound || qp != null || !saw_staging_release ||
        reserved_resource == null ||
        reserved_resource.state != RDMA_RESOURCE_ALLOCATED)
      `uvm_error("STALE_REBIND_ATTACH",
        "stale binding reached QP attachment or leaked staging")
  endtask

  task automatic check_urc_nonzero_rejected();
    rdma_mock_host_mem mem;
    rdma_function_binding binding;
    rdma_resource_manager manager;
    rdma_mock_context_backing contexts;
    rdma_mock_cmq_port cmq;
    rdma_qp_lifecycle_executor executor;
    rdma_pd pd;
    rdma_cq cq;
    rdma_create_qp_req request;
    rdma_qpc_urc_ext urc_ext;
    rdma_qp qp;
    rdma_control_result result;

    mem = rdma_mock_host_mem::type_id::create("URC_NONZERO_mem");
    setup_qp_environment("URC_NONZERO", mem, binding, manager, contexts, cmq,
                         executor, pd, cq);
    request = make_request("URC_NONZERO_request", binding, pd, cq,
                           RDMA_TRANSPORT_URC);
    if (!$cast(urc_ext, request.context_attrs.transport_ext))
      `uvm_fatal("URC_NONZERO", "URC fixture extension cast failed")
    urc_ext.queues.rsq_backing.value = 64'h1000;
    executor.create_locked(binding, binding.make_handle(), request, 206, qp,
                           result);
    expect_code("URC_NONZERO_STATUS",
      result == null ? null : result.status, RDMA_SC_INVALID_ARGUMENT);
    if (qp != null || mem.calls.size() != 0)
      `uvm_error("URC_NONZERO_SIDE_EFFECT",
        "caller URC backing reached allocation side effects")
  endtask

  task automatic expect_zero_page(
    string label, rdma_mock_host_mem mem, rdma_dma_mapping mapping,
    longint unsigned offset
  );
    byte data[];
    expect_ok(label, mem.read(mapping, offset, 4096, data));
    foreach (data[i])
      if (data[i] != 8'h00) begin
        `uvm_error(label, $sformatf("byte %0d was not zero", i))
        break;
      end
  endtask

  task automatic expect_pd_prefix(
    string label, rdma_mock_host_mem mem, rdma_dma_mapping mapping,
    byte expected[16]
  );
    byte data[];
    expect_ok(label, mem.read(mapping, 0, 16, data));
    if (data.size() != 16)
      `uvm_error(label, "PD prefix did not contain 16 bytes")
    else foreach (expected[i])
      if (data[i] != expected[i])
        `uvm_error(label, $sformatf(
          "PD byte %0d expected 0x%02x got 0x%02x", i, expected[i], data[i]))
  endtask

  task automatic check_borrowed_multislice_authority();
    rdma_mock_host_mem mem;
    rdma_function_binding binding;
    rdma_resource_manager manager;
    rdma_mock_context_backing contexts;
    rdma_mock_cmq_port cmq;
    rdma_qp_lifecycle_executor executor;
    rdma_pd pd;
    rdma_cq cq;
    rdma_create_qp_req request;
    rdma_dma_mapping sq0, sq1, rq0, rq1;
    rdma_qp qp, lookup_qp;
    rdma_resource looked_up;
    rdma_control_result result;
    byte fill[];
    byte sq_pd_expected[16];
    byte rq_pd_expected[16];
    bit borrowed_release;
    longint unsigned stored_segment_iova;
    rdma_status status;

    mem = rdma_mock_host_mem::type_id::create("BORROWED_MULTI_mem");
    mem.next_address = 64'h0000_0100_0000_0000;
    setup_qp_environment("BORROWED_MULTI", mem, binding, manager, contexts, cmq,
                         executor, pd, cq);
    allocate_borrowed_mapping("BORROWED_SQ0", mem, binding, pd.handle,
      RDMA_QUEUE_ROLE_QP_SQ_RING, sq0);
    allocate_borrowed_mapping("BORROWED_SQ1", mem, binding, pd.handle,
      RDMA_QUEUE_ROLE_QP_SQ_RING, sq1);
    allocate_borrowed_mapping("BORROWED_RQ0", mem, binding, pd.handle,
      RDMA_QUEUE_ROLE_QP_RQ_RING, rq0);
    allocate_borrowed_mapping("BORROWED_RQ1", mem, binding, pd.handle,
      RDMA_QUEUE_ROLE_QP_RQ_RING, rq1);
    fill = new[4096];
    foreach (fill[i]) fill[i] = 8'ha5;
    expect_ok("BORROWED_FILL_SQ0", mem.write(sq0, 4096, fill));
    expect_ok("BORROWED_FILL_SQ1", mem.write(sq1, 0, fill));
    expect_ok("BORROWED_FILL_RQ0", mem.write(rq0, 4096, fill));
    expect_ok("BORROWED_FILL_RQ1", mem.write(rq1, 0, fill));
    mem.calls.delete();
    mem.method_ordinals.delete();

    request = make_request("BORROWED_MULTI_request", binding, pd, cq,
                           RDMA_TRANSPORT_RC);
    request.rq_depth = 128;
    request.sq_backing.mode = RDMA_QUEUE_BACKING_BORROWED;
    request.sq_backing.slices.push_back(make_borrowed_slice(
      "BORROWED_SQ0_slice", RDMA_QUEUE_ROLE_QP_SQ_RING, sq0, 4096, 0));
    request.sq_backing.slices.push_back(make_borrowed_slice(
      "BORROWED_SQ1_slice", RDMA_QUEUE_ROLE_QP_SQ_RING, sq1, 0, 4096));
    request.rq_backing.mode = RDMA_QUEUE_BACKING_BORROWED;
    request.rq_backing.slices.push_back(make_borrowed_slice(
      "BORROWED_RQ0_slice", RDMA_QUEUE_ROLE_QP_RQ_RING, rq0, 4096, 0));
    request.rq_backing.slices.push_back(make_borrowed_slice(
      "BORROWED_RQ1_slice", RDMA_QUEUE_ROLE_QP_RQ_RING, rq1, 0, 4096));
    executor.create_locked(binding, binding.make_handle(), request, 207, qp,
                           result);
    if (result == null || !result.ok() || qp == null || qp.qp_plan == null) begin
      `uvm_error("BORROWED_MULTI_CREATE",
        result == null || result.status == null ? "null result" :
          result.status.convert2string())
      return;
    end
    if (qp.qp_plan.sq_ref.ownership != RDMA_OWNERSHIP_BORROWED ||
        qp.qp_plan.rq_ref.ownership != RDMA_OWNERSHIP_BORROWED ||
        qp.qp_plan.sq_ref.additional_segments.size() != 1 ||
        qp.qp_plan.rq_ref.additional_segments.size() != 1 ||
        qp.qp_plan.sq_ref.mapping == sq0 ||
        qp.qp_plan.sq_ref.additional_segments[0].mapping == sq1 ||
        qp.qp_plan.rq_ref.mapping == rq0 ||
        qp.qp_plan.rq_ref.additional_segments[0].mapping == rq1)
      `uvm_error("BORROWED_MULTI_DETACH",
        "persistent borrowed slices were missing or aliased caller mappings")
    if (qp.qp_plan.sq_ref.mapping.owner_h == null ||
        !qp.qp_plan.sq_ref.mapping.owner_h.same_instance(qp.handle) ||
        qp.qp_plan.sq_ref.additional_segments[0].mapping.owner_h == null ||
        !qp.qp_plan.sq_ref.additional_segments[0].mapping.owner_h.same_instance(
          qp.handle) ||
        qp.qp_plan.rq_ref.mapping.owner_h == null ||
        !qp.qp_plan.rq_ref.mapping.owner_h.same_instance(qp.handle) ||
        qp.qp_plan.rq_ref.additional_segments[0].mapping.owner_h == null ||
        !qp.qp_plan.rq_ref.additional_segments[0].mapping.owner_h.same_instance(
          qp.handle))
      `uvm_error("BORROWED_MULTI_OWNER",
        "detached borrowed mappings did not bind to the global QP")
    if (sq0.owner_h == null || !sq0.owner_h.same_instance(pd.handle) ||
        sq1.owner_h == null || !sq1.owner_h.same_instance(pd.handle) ||
        rq0.owner_h == null || !rq0.owner_h.same_instance(pd.handle) ||
        rq1.owner_h == null || !rq1.owner_h.same_instance(pd.handle))
      `uvm_error("BORROWED_CALLER_OWNER",
        "QP owner rebinding mutated caller mapping authority")

    borrowed_release = 1'b0;
    foreach (mem.calls[i])
      if (mem.calls[i].method_name == "release" &&
          mem.calls[i].mapping != null &&
          mem.calls[i].mapping.iova.value inside {
            sq0.iova.value, sq1.iova.value, rq0.iova.value, rq1.iova.value})
        borrowed_release = 1'b1;
    if (borrowed_release || sq0.state != RDMA_MAPPING_ACTIVE ||
        sq1.state != RDMA_MAPPING_ACTIVE || rq0.state != RDMA_MAPPING_ACTIVE ||
        rq1.state != RDMA_MAPPING_ACTIVE)
      `uvm_error("BORROWED_NON_RELEASE", "borrowed mapping was released")

    expect_zero_page("BORROWED_ZERO_SQ0", mem, sq0, 4096);
    expect_zero_page("BORROWED_ZERO_SQ1", mem, sq1, 0);
    expect_zero_page("BORROWED_ZERO_RQ0", mem, rq0, 4096);
    expect_zero_page("BORROWED_ZERO_RQ1", mem, rq1, 0);
    sq_pd_expected = '{8'h00, 8'h00, 8'h01, 8'h00, 8'h00, 8'h00, 8'h15, 8'h51,
                       8'h00, 8'h00, 8'h01, 8'h00, 8'h00, 8'h00, 8'h25, 8'h51};
    rq_pd_expected = '{8'h00, 8'h00, 8'h01, 8'h00, 8'h00, 8'h00, 8'h55, 8'h51,
                       8'h00, 8'h00, 8'h01, 8'h00, 8'h00, 8'h00, 8'h65, 8'h51};
    expect_pd_prefix("BORROWED_SQ_PD_LITERAL", mem,
                     qp.qp_plan.sq_pd_ref.mapping, sq_pd_expected);
    expect_pd_prefix("BORROWED_RQ_PD_LITERAL", mem,
                     qp.qp_plan.rq_pd_ref.mapping, rq_pd_expected);

    status = rdma_qp_recovery_ref_status(qp.qp_plan.sq_ref, 1'b0,
                                         "borrowed SQ");
    expect_code("BORROWED_RECOVERY_ACTIVE", status, RDMA_SC_OK);
    qp.qp_plan.sq_ref.additional_segments[0].mapping.state = RDMA_MAPPING_INVALID;
    status = rdma_qp_recovery_ref_status(qp.qp_plan.sq_ref, 1'b0,
                                         "borrowed SQ");
    expect_code("BORROWED_RECOVERY_SEGMENT_INVALID", status,
                RDMA_SC_INVALID_STATE);
    qp.qp_plan.sq_ref.additional_segments[0].mapping.state = RDMA_MAPPING_RELEASED;
    status = rdma_qp_recovery_ref_status(qp.qp_plan.sq_ref, 1'b1,
                                         "borrowed SQ");
    expect_code("BORROWED_RECOVERY_SEGMENT_COMPLETE", status, RDMA_SC_OK);
    if (qp.qp_plan.sq_ref.additional_segments[0].mapping.state !=
        RDMA_MAPPING_ACTIVE)
      `uvm_error("BORROWED_RECOVERY_SEGMENT_COMPLETE",
        "completed segment was not normalized for plan validation")

    stored_segment_iova = qp.qp_plan.sq_ref.additional_segments[0].mapping.iova.value;
    qp.qp_plan.sq_ref.additional_segments[0].mapping.iova.value += 64'h1000;
    expect_ok("BORROWED_MANAGER_LOOKUP", manager.lookup(qp.handle, looked_up));
    if (!$cast(lookup_qp, looked_up) || lookup_qp.qp_plan == null ||
        lookup_qp.qp_plan.sq_ref.additional_segments.size() != 1 ||
        lookup_qp.qp_plan.sq_ref.additional_segments[0].mapping.iova.value !=
          stored_segment_iova)
      `uvm_error("BORROWED_MANAGER_PROJECTION",
        "caller segment mutation reached manager authority")
  endtask

  task automatic check_rc_srq_geometry();
    rdma_function_binding binding;
    rdma_resource_manager manager;
    rdma_mock_host_mem mem;
    rdma_mock_context_backing contexts;
    rdma_mock_cmq_port cmq;
    rdma_queue_lifecycle_executor queue_executor;
    rdma_qp_lifecycle_executor qp_executor;
    rdma_function function_resource;
    rdma_pd pd;
    rdma_cq cq;
    rdma_create_srq_req srq_request;
    rdma_queue_resource queue_resource;
    rdma_srq srq;
    rdma_create_qp_req qp_request;
    rdma_qp qp;
    rdma_control_result result;
    rdma_queue_backing_ref srq_frfq_pd;
    rdma_create_qp_req depth_request;
    rdma_qp depth_qp;
    rdma_control_result depth_result;
    rdma_qp mismatched_qp, cloned_mismatch;
    uvm_object cloned_object;
    rdma_status status;

    binding = make_binding("RC_SRQ");
    manager = rdma_resource_manager::type_id::create("RC_SRQ_manager");
    mem = rdma_mock_host_mem::type_id::create("RC_SRQ_mem");
    contexts = rdma_mock_context_backing::type_id::create("RC_SRQ_contexts");
    cmq = rdma_mock_cmq_port::type_id::create("RC_SRQ_cmq");
    expect_ok("RC_SRQ_FUNCTION", manager.create_function(binding,
                                                           function_resource));
    expect_ok("RC_SRQ_PD", manager.create_pd(binding, pd));
    expect_ok("RC_SRQ_CQ", manager.create_cq(binding, null, cq));
    queue_executor = rdma_queue_lifecycle_executor::type_id::create(
      "RC_SRQ_queue_executor");
    expect_ok("RC_SRQ_QUEUE_CONFIGURE", queue_executor.configure(
      manager, cmq, mem, contexts, 2us));
    srq_request = rdma_create_srq_req::type_id::create("RC_SRQ_request");
    srq_request.owner = binding.make_handle();
    srq_request.depth = 64;
    srq_request.max_sge = 2;
    srq_request.limit_threshold = 16;
    srq_request.pd_h = rdma_clone_handle_value(pd.handle, "RC SRQ PD");
    queue_executor.create_locked(binding, binding.make_handle(), srq_request,
                                  101, queue_resource, result);
    if (result == null || !result.ok() || !$cast(srq, queue_resource) ||
        srq.queue_plan == null)
      `uvm_error("RC_SRQ", $sformatf("SRQ fixture did not become programmed: %s",
        result == null || result.status == null ? "null" :
          result.status.convert2string()))
    qp_executor = rdma_qp_lifecycle_executor::type_id::create(
      "RC_SRQ_qp_executor");
    expect_ok("RC_SRQ_QP_CONFIGURE", qp_executor.configure(
      manager, cmq, mem, contexts, 2us));
    qp_request = make_request("RC_SRQ_qp_request", binding, pd, cq,
                              RDMA_TRANSPORT_RC);
    qp_request.srq_h = rdma_clone_handle_value(srq.handle, "RC SRQ source");
    qp = null;
    result = null;
    qp_executor.create_locked(binding, binding.make_handle(), qp_request, 102,
                               qp, result);
    if (result == null || !result.ok() || qp == null || qp.qp_plan == null ||
        qp.programmed_qpc == null)
      `uvm_error("RC_SRQ", $sformatf("RC+SRQ QP create did not succeed: %s",
        result == null || result.status == null ? "null" :
          result.status.convert2string()))
    else begin
      if (qp.qp_plan.rq_source_h == null ||
          !qp.qp_plan.rq_source_h.same_instance(srq.handle) ||
          qp.qp_plan.rq_ring != null || qp.qp_plan.rq_ref != null ||
          qp.qp_plan.rq_pd_ref != null || qp.programmed_qpc.srq_h == null ||
          qp.rq_depth != 64 || qp.programmed_qpc.rq_depth != 64)
        `uvm_error("RC_SRQ", "RC+SRQ plan retained private RQ authority")
      srq_frfq_pd = null;
      foreach (srq.queue_plan.refs[i])
        if (srq.queue_plan.refs[i] != null &&
            srq.queue_plan.refs[i].role == RDMA_QUEUE_ROLE_SRFQ_PD)
          srq_frfq_pd = srq.queue_plan.refs[i];
      if (srq_frfq_pd == null ||
          qp.programmed_qpc.rq_backing.value !=
            srq_frfq_pd.mapping.iova.value + srq_frfq_pd.mapping_offset)
        `uvm_error("RC_SRQ", "QPC RQ backing did not use SRFQ page directory")

      cloned_object = qp.clone();
      if (!$cast(mismatched_qp, cloned_object) || mismatched_qp.qp_plan == null)
        `uvm_fatal("RC_SRQ_MISMATCH", "failed to clone SRQ QP fixture")
      mismatched_qp.qp_plan.rq_source_h.object_id++;
      expect_code("RC_SRQ_MISMATCH_SOURCE", mismatched_qp.validate(),
                  RDMA_SC_INVALID_STATE);
      cloned_object = mismatched_qp.clone();
      if (!$cast(cloned_mismatch, cloned_object) ||
          cloned_mismatch.qp_plan == null ||
          cloned_mismatch.qp_plan.rq_source_h == null ||
          !cloned_mismatch.qp_plan.rq_source_h.same_instance(
            mismatched_qp.qp_plan.rq_source_h) ||
          cloned_mismatch.qp_plan.rq_source_h.same_instance(
            cloned_mismatch.srq_h))
        `uvm_error("RC_SRQ_MISMATCH_CLONE",
          "QP clone sanitized mismatched resource/plan SRQ identity")
      status = cloned_mismatch.validate();
      expect_code("RC_SRQ_MISMATCH_CLONE_STATUS", status,
                  RDMA_SC_INVALID_STATE);
    end

    depth_request = make_request("RC_SRQ_depth_request", binding, pd, cq,
                                 RDMA_TRANSPORT_RC);
    depth_request.srq_h = rdma_clone_handle_value(srq.handle,
                                                  "RC SRQ depth source");
    depth_request.rq_depth = 128;
    depth_qp = null;
    depth_result = null;
    qp_executor.create_locked(binding, binding.make_handle(), depth_request, 103,
                              depth_qp, depth_result);
    expect_code("RC_SRQ_DEPTH_MISMATCH",
      depth_result == null ? null : depth_result.status,
      RDMA_SC_INVALID_ARGUMENT);
    if (depth_qp != null)
      `uvm_error("RC_SRQ_DEPTH_MISMATCH", "mismatched SRQ depth returned a QP")
  endtask

  task run_phase(uvm_phase phase);
    phase.raise_objection(this);
    check_rc_plan_and_staging_authority();
    check_ud_semantic_round_trip();
    check_rc_srq_geometry();
    check_urc_internal_geometry();
    check_urc_nonzero_rejected();
    check_allocate_error_cleanup();
    check_authority_failure_cleanup(1);
    check_authority_failure_cleanup(2);
    check_stale_rebind_blocks_attach();
    check_borrowed_multislice_authority();
    phase.drop_objection(this);
  endtask
endclass
