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
      make_urc_attrs({name, "_attrs"}) : make_rc_attrs({name, "_attrs"});
    return request;
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
          qp.qp_plan.rq_pd_ref != null || qp.programmed_qpc.srq_h == null)
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
    end
  endtask

  task run_phase(uvm_phase phase);
    phase.raise_objection(this);
    check_rc_plan_and_staging_authority();
    check_rc_srq_geometry();
    check_urc_internal_geometry();
    phase.drop_objection(this);
  endtask
endclass
