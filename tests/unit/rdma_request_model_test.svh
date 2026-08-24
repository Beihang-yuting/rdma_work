class rdma_request_model_test extends uvm_test;
  `uvm_component_utils(rdma_request_model_test)

  function new(string name = "rdma_request_model_test",
               uvm_component parent = null);
    super.new(name, parent);
  endfunction

  function automatic rdma_handle make_handle(
    string name,
    rdma_resource_kind_e kind,
    int unsigned object_id
  );
    rdma_handle handle;

    handle = rdma_handle::type_id::create(name);
    handle.kind = kind;
    handle.function_uid = 64'h1234_5678_9abc_def0;
    handle.object_id = object_id;
    handle.generation = 32'd9;
    return handle;
  endfunction

  function automatic rdma_function_handle make_function_handle(string name);
    rdma_function_handle handle;

    handle = rdma_function_handle::type_id::create(name);
    handle.function_uid = 64'h1234_5678_9abc_def0;
    handle.object_id = 32'h1020_3040;
    handle.generation = 32'd9;
    return handle;
  endfunction

  function automatic void expect_status(
    string check_name,
    rdma_status status,
    rdma_status_code_e expected_code
  );
    if (status == null) begin
      `uvm_error(check_name, "model returned a null status")
      return;
    end
    if (status.code != expected_code)
      `uvm_error(check_name,
                 $sformatf("expected %s, got %s (%s)",
                           expected_code.name(), status.code.name(),
                           status.convert2string()))
  endfunction

  task run_phase(uvm_phase phase);
    rdma_create_qp_req req;
    rdma_function_handle function_h;
    rdma_handle pd_h;
    rdma_handle mr_h;
    rdma_handle cq_h;
    rdma_handle qp_h;
    rdma_handle srq_h;
    rdma_handle ceq_h;
    rdma_handle aeq_h;
    rdma_handle cmq_h;
    rdma_handle mismatched_h;
    rdma_create_pd_req create_pd;
    rdma_register_mr_req register_mr;
    rdma_register_mr_req register_mr_clone;
    rdma_create_cq_req create_cq;
    rdma_create_srq_req create_srq;
    rdma_create_ceq_req create_ceq;
    rdma_create_aeq_req create_aeq;
    rdma_destroy_resource_req destroy_resource;
    rdma_modify_qp_req modify_qp;
    rdma_post_send_req post_send;
    rdma_post_send_req post_send_clone;
    rdma_post_recv_req post_recv;
    rdma_sge sge;
    rdma_sge atomic_sge;
    rdma_sge extra_sge;
    rdma_sge recv_sge;
    rdma_function function_resource;
    rdma_pd pd_resource;
    rdma_mr mr_resource;
    rdma_mr mr_resource_clone;
    rdma_cq cq_resource;
    rdma_cq cq_resource_clone;
    rdma_qp qp_resource;
    rdma_qp qp_resource_clone;
    rdma_srq srq_resource;
    rdma_ceq ceq_resource;
    rdma_aeq aeq_resource;
    rdma_cmq cmq_resource;
    rdma_dma_mapping mapping;
    rdma_backing_ref backing_ref;
    rdma_hmc_ref hmc_ref;
    rdma_qpc_model qpc;
    rdma_qpc_model qpc_clone;
    rdma_qpc_rc_ext rc_ext;
    rdma_qpc_rc_ext rc_ext_clone;
    rdma_qpc_ud_ext ud_ext;
    rdma_qpc_urc_ext urc_ext;
    rdma_qpc_urc_ext urc_ext_clone;
    rdma_cqc_model cqc;
    rdma_mrt_model mrt;
    rdma_srqc_model srqc;
    rdma_ceqc_model ceqc;
    rdma_aeqc_model aeqc;
    rdma_cmq_sqe_model cmq_create_qp;
    rdma_cmq_sqe_model cmq_modify_qp;
    rdma_cmq_sqe_model cmq_clone;
    rdma_cmq_completion_model cmq_completion;
    rdma_sqe_model rc_sqe;
    rdma_sqe_model ud_sqe;
    rdma_sqe_model urc_sqe;
    rdma_sqe_model urc_sqe_clone;
    rdma_sqe_model sqe_clone;
    rdma_sqe_model ud_sqe_clone;
    rdma_sqe_rc_ext sqe_rc_ext;
    rdma_sqe_rc_ext sqe_rc_ext_clone;
    rdma_sqe_ud_ext sqe_ud_ext;
    rdma_sqe_ud_ext sqe_ud_ext_clone;
    rdma_sqe_urc_ext sqe_urc_ext;
    rdma_sqe_urc_ext sqe_urc_ext_clone;
    rdma_rqe_model rqe;
    rdma_cqe_model cqe;
    rdma_ceqe_model ceqe;
    rdma_aeqe_model aeqe;
    rdma_doorbell_model doorbell;
    rdma_doorbell_model doorbell_clone;
    rdma_packet packet;
    rdma_packet packet_clone;
    rdma_net_response_policy policy;
    rdma_net_response_policy policy_clone;
    rdma_net_fault fault;
    rdma_net_fault fault_clone;
    uvm_object cloned_object;
    string iova_type_name;
    string hmc_type_name;

    phase.raise_objection(this);

    function_h = make_function_handle("function_h");
    pd_h = make_handle("pd_h", RDMA_RESOURCE_PD, 32'h101);
    mr_h = make_handle("mr_h", RDMA_RESOURCE_MR, 32'h202);
    cq_h = make_handle("cq_h", RDMA_RESOURCE_CQ, 32'h303);
    qp_h = make_handle("qp_h", RDMA_RESOURCE_QP, 32'h404);
    srq_h = make_handle("srq_h", RDMA_RESOURCE_SRQ, 32'h505);
    ceq_h = make_handle("ceq_h", RDMA_RESOURCE_CEQ, 32'h606);
    aeq_h = make_handle("aeq_h", RDMA_RESOURCE_AEQ, 32'h707);
    cmq_h = make_handle("cmq_h", RDMA_RESOURCE_CMQ, 32'h808);

    req = rdma_create_qp_req::type_id::create("req");
    req.owner = function_h;
    req.transport = RDMA_TRANSPORT_RC;
    req.sq_depth = 1024;
    req.rq_depth = 512;
    req.max_send_sge = 4;
    req.pd_h = pd_h;
    req.send_cq_h = cq_h;
    req.recv_cq_h = cq_h;
    expect_status("CREATE_QP", req.validate(), RDMA_SC_OK);
    req.owner = null;
    expect_status("CREATE_QP_OWNER", req.validate(), RDMA_SC_INVALID_ARGUMENT);
    req.owner = function_h;
    req.pd_h = cq_h;
    expect_status("CREATE_QP_PD", req.validate(), RDMA_SC_INVALID_ARGUMENT);
    req.pd_h = pd_h;
    req.send_cq_h = qp_h;
    expect_status("CREATE_QP_SEND_CQ", req.validate(),
                  RDMA_SC_INVALID_ARGUMENT);
    req.send_cq_h = cq_h;
    req.recv_cq_h = qp_h;
    expect_status("CREATE_QP_RECV_CQ", req.validate(),
                  RDMA_SC_INVALID_ARGUMENT);
    req.recv_cq_h = cq_h;
    mismatched_h = make_handle("qp_cross_pd_h", RDMA_RESOURCE_PD, 32'h901);
    mismatched_h.function_uid++;
    req.pd_h = mismatched_h;
    expect_status("CREATE_QP_PD_OWNER", req.validate(),
                  RDMA_SC_INVALID_ARGUMENT);
    req.pd_h = pd_h;
    mismatched_h = make_handle("qp_stale_cq_h", RDMA_RESOURCE_CQ, 32'h902);
    mismatched_h.generation++;
    req.send_cq_h = mismatched_h;
    expect_status("CREATE_QP_CQ_GENERATION", req.validate(),
                  RDMA_SC_STALE_GENERATION);
    req.send_cq_h = cq_h;
    req.srq_h = srq_h;
    expect_status("CREATE_QP_SRQ", req.validate(), RDMA_SC_OK);
    mismatched_h = make_handle("qp_cross_srq_h", RDMA_RESOURCE_SRQ,
                               32'h903);
    mismatched_h.function_uid++;
    req.srq_h = mismatched_h;
    expect_status("CREATE_QP_SRQ_OWNER", req.validate(),
                  RDMA_SC_INVALID_ARGUMENT);
    req.srq_h = null;
    req.sq_depth = 1000;
    if (req.validate().ok()) `uvm_error("REQ", "non-power-of-two depth accepted")
    expect_status("QP_DEPTH", req.validate(), RDMA_SC_INVALID_ARGUMENT);
    req.sq_depth = 1024;

    create_pd = rdma_create_pd_req::type_id::create("create_pd");
    create_pd.owner = function_h;
    create_pd.request_id = 64'h10;
    expect_status("CREATE_PD", create_pd.validate(), RDMA_SC_OK);

    register_mr = rdma_register_mr_req::type_id::create("register_mr");
    if (register_mr.access != '0)
      `uvm_error("REGISTER_MR_ACCESS_DEFAULT",
                 "new register MR request access is not zero")
    register_mr.owner = function_h;
    register_mr.pd_h = pd_h;
    register_mr.iova.value = 64'h1111_0000;
    register_mr.length = 64'h4000;
    register_mr.access = '{local_write:1'b1, remote_read:1'b1,
                           remote_write:1'b1, memory_window_bind:1'b0,
                           remote_atomic:1'b0};
    expect_status("REGISTER_MR", register_mr.validate(), RDMA_SC_OK);
    register_mr.access.remote_atomic = 1'b1;
    cloned_object = register_mr.clone();
    if (!$cast(register_mr_clone, cloned_object))
      `uvm_error("REGISTER_MR_ACCESS_COPY",
                 "register MR clone lost dynamic type")
    else if (!register_mr_clone.access.remote_atomic)
      `uvm_error("REGISTER_MR_ACCESS_COPY",
                 "register MR clone lost remote atomic access")
    else if (register_mr_clone.access != register_mr.access)
      `uvm_error("REGISTER_MR_ACCESS_COPY",
                 $sformatf("register MR clone changed access from 0x%0h to 0x%0h",
                           register_mr.access, register_mr_clone.access))
    register_mr.owner = null;
    expect_status("REGISTER_MR_OWNER", register_mr.validate(),
                  RDMA_SC_INVALID_ARGUMENT);
    register_mr.owner = function_h;
    register_mr.length = 0;
    expect_status("REGISTER_MR_LENGTH", register_mr.validate(),
                  RDMA_SC_INVALID_ARGUMENT);
    register_mr.length = 64'h4000;
    register_mr.pd_h = null;
    expect_status("REGISTER_MR_PD", register_mr.validate(),
                  RDMA_SC_INVALID_ARGUMENT);
    mismatched_h = make_handle("mr_cross_pd_h", RDMA_RESOURCE_PD, 32'h904);
    mismatched_h.function_uid++;
    register_mr.pd_h = mismatched_h;
    expect_status("REGISTER_MR_PD_OWNER", register_mr.validate(),
                  RDMA_SC_INVALID_ARGUMENT);
    mismatched_h = make_handle("mr_stale_pd_h", RDMA_RESOURCE_PD, 32'h905);
    mismatched_h.generation++;
    register_mr.pd_h = mismatched_h;
    expect_status("REGISTER_MR_PD_GENERATION", register_mr.validate(),
                  RDMA_SC_STALE_GENERATION);
    register_mr.pd_h = pd_h;

    create_cq = rdma_create_cq_req::type_id::create("create_cq");
    create_cq.owner = function_h;
    create_cq.depth = 256;
    create_cq.ceq_h = ceq_h;
    expect_status("CREATE_CQ", create_cq.validate(), RDMA_SC_OK);
    create_cq.owner = null;
    expect_status("CREATE_CQ_OWNER", create_cq.validate(),
                  RDMA_SC_INVALID_ARGUMENT);
    create_cq.owner = function_h;
    create_cq.ceq_h = null;
    expect_status("CREATE_CQ_OPTIONAL_CEQ", create_cq.validate(), RDMA_SC_OK);
    mismatched_h = make_handle("cq_cross_ceq_h", RDMA_RESOURCE_CEQ, 32'h906);
    mismatched_h.function_uid++;
    create_cq.ceq_h = mismatched_h;
    expect_status("CREATE_CQ_CEQ_OWNER", create_cq.validate(),
                  RDMA_SC_INVALID_ARGUMENT);
    create_cq.ceq_h = ceq_h;
    create_cq.depth = 0;
    expect_status("CREATE_CQ_DEPTH", create_cq.validate(),
                  RDMA_SC_INVALID_ARGUMENT);

    create_srq = rdma_create_srq_req::type_id::create("create_srq");
    create_srq.owner = function_h;
    create_srq.depth = 128;
    create_srq.max_sge = 2;
    create_srq.pd_h = pd_h;
    expect_status("CREATE_SRQ", create_srq.validate(), RDMA_SC_OK);
    create_srq.owner = null;
    expect_status("CREATE_SRQ_OWNER", create_srq.validate(),
                  RDMA_SC_INVALID_ARGUMENT);
    create_srq.owner = function_h;
    create_srq.pd_h = cq_h;
    expect_status("CREATE_SRQ_PD", create_srq.validate(),
                  RDMA_SC_INVALID_ARGUMENT);
    mismatched_h = make_handle("srq_stale_pd_h", RDMA_RESOURCE_PD, 32'h907);
    mismatched_h.generation++;
    create_srq.pd_h = mismatched_h;
    expect_status("CREATE_SRQ_PD_GENERATION", create_srq.validate(),
                  RDMA_SC_STALE_GENERATION);
    create_srq.pd_h = pd_h;
    create_srq.max_sge = 0;
    expect_status("CREATE_SRQ_SGE", create_srq.validate(),
                  RDMA_SC_INVALID_ARGUMENT);

    create_ceq = rdma_create_ceq_req::type_id::create("create_ceq");
    create_ceq.depth = 64;
    expect_status("CREATE_CEQ", create_ceq.validate(), RDMA_SC_OK);
    create_aeq = rdma_create_aeq_req::type_id::create("create_aeq");
    create_aeq.depth = 64;
    expect_status("CREATE_AEQ", create_aeq.validate(), RDMA_SC_OK);

    destroy_resource =
      rdma_destroy_resource_req::type_id::create("destroy_resource");
    expect_status("DESTROY_NULL", destroy_resource.validate(),
                  RDMA_SC_INVALID_ARGUMENT);
    destroy_resource.target_h = mr_h;
    expect_status("DESTROY", destroy_resource.validate(), RDMA_SC_OK);

    modify_qp = rdma_modify_qp_req::type_id::create("modify_qp");
    modify_qp.new_state = RDMA_QPS_RTS;
    expect_status("MODIFY_NULL", modify_qp.validate(),
                  RDMA_SC_INVALID_ARGUMENT);
    modify_qp.qp_h = qp_h;
    expect_status("MODIFY", modify_qp.validate(), RDMA_SC_OK);

    post_send = rdma_post_send_req::type_id::create("post_send");
    post_send.owner = function_h;
    post_send.request_id = 64'h8877_6655_4433_2211;
    post_send.correlation_id = 64'h0102_0304_0506_0708;
    post_send.timeout_policy = RDMA_TIMEOUT_CYCLES;
    post_send.timeout_value = 64'd12345;
    post_send.expected_status_code = RDMA_SC_QUEUE_FULL;
    post_send.qp_h = qp_h;
    post_send.wr_id = 64'hdead_beef_cafe_1234;
    post_send.opcode = RDMA_WR_SEND;
    sge = rdma_sge::type_id::create("sge");
    sge.iova.value = 64'h2000_4000;
    sge.length = 32'h345;
    sge.lkey = 32'h1234_abcd;
    post_send.sges.push_back(sge);
    post_send.opcode = RDMA_WR_RECV;
    expect_status("POST_SEND_RECV_OPCODE", post_send.validate(),
                  RDMA_SC_INVALID_ARGUMENT);
    post_send.opcode = RDMA_WR_RDMA_WRITE;
    expect_status("POST_SEND_REMOTE_FIELDS", post_send.validate(),
                  RDMA_SC_INVALID_ARGUMENT);
    post_send.remote_access_valid = 1'b1;
    post_send.rkey_valid = 1'b1;
    expect_status("POST_SEND_ZERO_REMOTE_FIELDS", post_send.validate(),
                  RDMA_SC_OK);
    post_send.remote_addr.value = 64'h1234_0000;
    post_send.rkey = 32'h1357_2468;
    expect_status("POST_SEND_RDMA_WRITE", post_send.validate(), RDMA_SC_OK);
    post_send.transport = RDMA_TRANSPORT_UD;
    expect_status("POST_SEND_UD_OPCODE", post_send.validate(),
                  RDMA_SC_INVALID_ARGUMENT);
    post_send.opcode = RDMA_WR_SEND;
    post_send.destination_qpn = 24'h102030;
    post_send.qkey = 32'h8001_0000;
    post_send.address_vector_id = 32'h5566_7788;
    expect_status("POST_SEND_UD_AV_MISSING", post_send.validate(),
                  RDMA_SC_INVALID_ARGUMENT);
    post_send.address_vector_valid = 1'b1;
    post_send.address_vector_id = '0;
    expect_status("POST_SEND_UD_ZERO_AV_ID", post_send.validate(), RDMA_SC_OK);
    post_send.address_vector_id = 32'h5566_7788;
    expect_status("POST_SEND_UD", post_send.validate(), RDMA_SC_OK);
    post_send.transport = RDMA_TRANSPORT_RC;
    post_send.opcode = RDMA_WR_RDMA_WRITE;
    post_send.compare_value = 64'h0123_4567_89ab_cdef;
    post_send.swap_add_value = 64'hfedc_ba98_7654_3210;
    post_send.payload.push_back(8'ha5);
    post_send.payload.push_back(8'h5a);
    expect_status("POST_SEND", post_send.validate(), RDMA_SC_OK);
    cloned_object = post_send.clone();
    if (!$cast(post_send_clone, cloned_object))
      `uvm_error("REQ_CLONE", "post-send clone lost dynamic type")
    else if (post_send_clone.owner == null ||
             post_send_clone.qp_h == null ||
             post_send_clone.sges.size() != 1)
      `uvm_error("REQ_CLONE", "post-send clone lost nested objects")
    else if (post_send_clone.sges[0] == null)
      `uvm_error("REQ_CLONE", "post-send clone contains a null SGE")
    else if (post_send_clone.owner == post_send.owner ||
             post_send_clone.qp_h == post_send.qp_h ||
             post_send_clone.sges[0] == post_send.sges[0] ||
             post_send_clone.sges[0].iova != post_send.sges[0].iova ||
             post_send_clone.payload != post_send.payload ||
             post_send_clone.request_id != 64'h8877_6655_4433_2211 ||
             post_send_clone.correlation_id != 64'h0102_0304_0506_0708 ||
             post_send_clone.timeout_value != post_send.timeout_value ||
             post_send_clone.timeout_policy != RDMA_TIMEOUT_CYCLES ||
             post_send_clone.expected_status_code != RDMA_SC_QUEUE_FULL ||
             post_send_clone.transport != RDMA_TRANSPORT_RC ||
             post_send_clone.opcode != RDMA_WR_RDMA_WRITE ||
             post_send_clone.remote_addr.value != 64'h1234_0000 ||
             post_send_clone.rkey != 32'h1357_2468 ||
             !post_send_clone.remote_access_valid ||
             !post_send_clone.rkey_valid ||
             post_send_clone.destination_qpn != 24'h102030 ||
             post_send_clone.qkey != 32'h8001_0000 ||
             post_send_clone.address_vector_id != 32'h5566_7788 ||
             !post_send_clone.address_vector_valid ||
             post_send_clone.compare_value != 64'h0123_4567_89ab_cdef ||
             post_send_clone.swap_add_value != 64'hfedc_ba98_7654_3210)
      `uvm_error("REQ_CLONE", "post-send clone lost or aliased fields")
    else begin
      post_send_clone.owner.function_uid++;
      post_send_clone.qp_h.object_id++;
      post_send_clone.sges[0].length++;
      post_send_clone.payload[0] = 8'hff;
      if (post_send.owner.function_uid != 64'h1234_5678_9abc_def0 ||
          post_send.qp_h.object_id != 32'h404 ||
          post_send.sges[0].length != 32'h345 ||
          post_send.payload[0] != 8'ha5)
        `uvm_error("REQ_CLONE", "post-send clone mutation reached source")
    end

    post_send.inline_data = 1'b0;
    post_send.sges.delete();
    expect_status("POST_SEND_EMPTY", post_send.validate(),
                  RDMA_SC_INVALID_ARGUMENT);
    post_send.sges.push_back(sge);
    sge.length = 0;
    expect_status("POST_SEND_ZERO_SGE", post_send.validate(),
                  RDMA_SC_INVALID_ARGUMENT);
    sge.length = 32'h345;

    atomic_sge = rdma_sge::type_id::create("atomic_sge");
    atomic_sge.iova.value = 64'h2222_0000;
    atomic_sge.length = 8;
    atomic_sge.lkey = 32'h2222_3333;
    extra_sge = rdma_sge::type_id::create("extra_sge");
    extra_sge.iova.value = 64'h3333_0000;
    extra_sge.length = 8;
    extra_sge.lkey = 32'h3333_4444;
    post_send.opcode = RDMA_WR_ATOMIC_CMP_SWAP;
    post_send.inline_data = 1'b1;
    expect_status("POST_SEND_ATOMIC_INLINE", post_send.validate(),
                  RDMA_SC_INVALID_ARGUMENT);
    post_send.inline_data = 1'b0;
    post_send.payload.delete();
    post_send.sges.delete();
    post_send.sges.push_back(atomic_sge);
    post_send.remote_addr.value = 64'h4444_0000;
    post_send.rkey = 32'h4444_5555;
    expect_status("POST_SEND_ATOMIC", post_send.validate(), RDMA_SC_OK);
    post_send.sges.push_back(extra_sge);
    expect_status("POST_SEND_ATOMIC_COUNT", post_send.validate(),
                  RDMA_SC_INVALID_ARGUMENT);
    void'(post_send.sges.pop_back());
    atomic_sge.length = 4;
    expect_status("POST_SEND_ATOMIC_LENGTH", post_send.validate(),
                  RDMA_SC_INVALID_ARGUMENT);
    atomic_sge.length = 8;
    atomic_sge.iova.value = 64'h2222_0004;
    expect_status("POST_SEND_ATOMIC_LOCAL_ALIGN", post_send.validate(),
                  RDMA_SC_INVALID_ARGUMENT);
    atomic_sge.iova.value = 64'h2222_0000;
    post_send.remote_addr.value = 64'h4444_0004;
    expect_status("POST_SEND_ATOMIC_REMOTE_ALIGN", post_send.validate(),
                  RDMA_SC_INVALID_ARGUMENT);
    post_send.remote_addr.value = 64'h4444_0000;
    post_send.opcode = RDMA_WR_ATOMIC_FETCH_ADD;
    expect_status("POST_SEND_FETCH_ADD", post_send.validate(), RDMA_SC_OK);

    post_send.opcode = RDMA_WR_RDMA_READ;
    atomic_sge.length = 64;
    expect_status("POST_SEND_READ", post_send.validate(), RDMA_SC_OK);
    post_send.inline_data = 1'b1;
    post_send.payload.push_back(8'h5c);
    expect_status("POST_SEND_READ_INLINE", post_send.validate(),
                  RDMA_SC_INVALID_ARGUMENT);
    post_send.inline_data = 1'b0;
    expect_status("POST_SEND_READ_PAYLOAD", post_send.validate(),
                  RDMA_SC_INVALID_ARGUMENT);
    post_send.payload.delete();

    post_send.opcode = RDMA_WR_LOCAL_INVALIDATE;
    expect_status("POST_SEND_INVALIDATE_SGE", post_send.validate(),
                  RDMA_SC_INVALID_ARGUMENT);
    post_send.sges.delete();
    post_send.payload.delete();
    post_send.rkey_valid = 1'b0;
    post_send.rkey = 0;
    expect_status("POST_SEND_INVALIDATE_RKEY_MISSING", post_send.validate(),
                  RDMA_SC_INVALID_ARGUMENT);
    post_send.rkey_valid = 1'b1;
    expect_status("POST_SEND_INVALIDATE_ZERO_RKEY", post_send.validate(),
                  RDMA_SC_OK);

    post_recv = rdma_post_recv_req::type_id::create("post_recv");
    post_recv.target_h = srq_h;
    post_recv.wr_id = 64'h1122;
    recv_sge = rdma_sge::type_id::create("recv_sge");
    recv_sge.iova.value = 64'h3000_0000;
    recv_sge.length = 512;
    recv_sge.lkey = 32'h5566;
    post_recv.sges.push_back(recv_sge);
    expect_status("POST_RECV", post_recv.validate(), RDMA_SC_OK);
    post_recv.target_h = null;
    expect_status("POST_RECV_NULL", post_recv.validate(),
                  RDMA_SC_INVALID_ARGUMENT);

    function_resource = rdma_function::type_id::create("function_resource");
    pd_resource = rdma_pd::type_id::create("pd_resource");
    mr_resource = rdma_mr::type_id::create("mr_resource");
    cq_resource = rdma_cq::type_id::create("cq_resource");
    qp_resource = rdma_qp::type_id::create("qp_resource");
    srq_resource = rdma_srq::type_id::create("srq_resource");
    ceq_resource = rdma_ceq::type_id::create("ceq_resource");
    aeq_resource = rdma_aeq::type_id::create("aeq_resource");
    cmq_resource = rdma_cmq::type_id::create("cmq_resource");
    if (function_resource == null || pd_resource == null ||
        mr_resource == null || cq_resource == null || srq_resource == null ||
        ceq_resource == null || aeq_resource == null || cmq_resource == null)
      `uvm_error("RESOURCES", "one or more concrete resources are absent")

    function_resource.handle = make_function_handle("function_resource_h");
    function_resource.owner =
      make_function_handle("function_resource_owner_h");
    function_resource.state = RDMA_RESOURCE_ALLOCATED;
    expect_status("FUNCTION_RESOURCE", function_resource.validate(),
                  RDMA_SC_OK);
    function_resource.handle.object_id++;
    expect_status("FUNCTION_RESOURCE_OBJECT_ID", function_resource.validate(),
                  RDMA_SC_INVALID_ARGUMENT);
    function_resource.handle.object_id--;
    function_resource.handle.generation++;
    expect_status("FUNCTION_RESOURCE_GENERATION", function_resource.validate(),
                  RDMA_SC_STALE_GENERATION);
    function_resource.handle.generation--;

    expect_status("RESOURCE_NEW_IDENTITY_OPTIONAL", pd_resource.validate(),
                  RDMA_SC_OK);
    pd_resource.state = RDMA_RESOURCE_ALLOCATED;
    expect_status("RESOURCE_ALLOCATED_IDENTITY", pd_resource.validate(),
                  RDMA_SC_INVALID_ARGUMENT);
    pd_resource.handle = cq_h;
    pd_resource.owner = function_h;
    expect_status("RESOURCE_HANDLE_KIND", pd_resource.validate(),
                  RDMA_SC_INVALID_ARGUMENT);
    pd_resource.handle = pd_h;
    expect_status("RESOURCE_ALLOCATED", pd_resource.validate(), RDMA_SC_OK);
    pd_resource.handle.function_uid++;
    expect_status("RESOURCE_HANDLE_OWNER", pd_resource.validate(),
                  RDMA_SC_INVALID_ARGUMENT);
    pd_resource.handle.function_uid--;
    pd_resource.handle.generation++;
    expect_status("RESOURCE_HANDLE_GENERATION", pd_resource.validate(),
                  RDMA_SC_STALE_GENERATION);
    pd_resource.handle.generation--;
    pd_resource.dependencies.push_back(null);
    expect_status("RESOURCE_NULL_DEPENDENCY", pd_resource.validate(),
                  RDMA_SC_INVALID_ARGUMENT);
    pd_resource.dependencies.delete();
    mismatched_h = make_handle("cross_dependency_h", RDMA_RESOURCE_CQ,
                               32'h908);
    mismatched_h.function_uid++;
    pd_resource.dependencies.push_back(mismatched_h);
    expect_status("RESOURCE_CROSS_DEPENDENCY", pd_resource.validate(),
                  RDMA_SC_INVALID_ARGUMENT);
    pd_resource.dependencies.delete();
    mismatched_h = make_handle("stale_dependency_h", RDMA_RESOURCE_CQ,
                               32'h90e);
    mismatched_h.generation++;
    pd_resource.dependencies.push_back(mismatched_h);
    expect_status("RESOURCE_STALE_DEPENDENCY", pd_resource.validate(),
                  RDMA_SC_STALE_GENERATION);
    pd_resource.dependencies.delete();
    function_h.kind = RDMA_RESOURCE_PD;
    expect_status("RESOURCE_OWNER_KIND", pd_resource.validate(),
                  RDMA_SC_INVALID_ARGUMENT);
    function_h.kind = RDMA_RESOURCE_FUNCTION;

    if (mr_resource.access != '0 || mr_resource.mr_serial != '0)
      `uvm_error("MR_RESOURCE_DEFAULT", "MR access or serial default is nonzero")
    mr_resource.handle = mr_h;
    mr_resource.owner = function_h;
    mr_resource.state = RDMA_RESOURCE_PROGRAMMED;
    mr_resource.pd_h = pd_h;
    mr_resource.length = 64'h1000;
    mr_resource.local_mr_id = 24'h12_3456;
    mr_resource.lkey = 32'h1234_56a5;
    mr_resource.rkey = 0;
    mr_resource.access.local_write = 1'b1;
    mr_resource.mr_serial = 12'habc;
    expect_status("MR_RESOURCE", mr_resource.validate(), RDMA_SC_OK);
    mr_resource.state = RDMA_RESOURCE_ACTIVE;
    expect_status("MR_RESOURCE_ACTIVE_KEY", mr_resource.validate(),
                  RDMA_SC_OK);
    mr_resource.state = RDMA_RESOURCE_QUIESCING;
    expect_status("MR_RESOURCE_QUIESCING_KEY", mr_resource.validate(),
                  RDMA_SC_OK);
    mr_resource.state = RDMA_RESOURCE_ERROR;
    expect_status("MR_RESOURCE_ERROR_KEY", mr_resource.validate(),
                  RDMA_SC_OK);
    mr_resource.local_mr_id++;
    mr_resource.state = RDMA_RESOURCE_PROGRAMMED;
    expect_status("MR_RESOURCE_PROGRAMMED_INDEX", mr_resource.validate(),
                  RDMA_SC_INVALID_ARGUMENT);
    mr_resource.state = RDMA_RESOURCE_ACTIVE;
    expect_status("MR_RESOURCE_ACTIVE_INDEX", mr_resource.validate(),
                  RDMA_SC_INVALID_ARGUMENT);
    mr_resource.state = RDMA_RESOURCE_QUIESCING;
    expect_status("MR_RESOURCE_QUIESCING_INDEX", mr_resource.validate(),
                  RDMA_SC_INVALID_ARGUMENT);
    mr_resource.state = RDMA_RESOURCE_ERROR;
    expect_status("MR_RESOURCE_ERROR_INDEX", mr_resource.validate(),
                  RDMA_SC_INVALID_ARGUMENT);
    mr_resource.local_mr_id = 32'h0112_3456;
    expect_status("MR_RESOURCE_INDEX_WIDTH", mr_resource.validate(),
                  RDMA_SC_OK);
    mr_resource.local_mr_id = 24'h12_3456;
    mr_resource.state = RDMA_RESOURCE_PROGRAMMED;
    mr_resource.access.remote_read = 1'b1;
    expect_status("MR_RESOURCE_REMOTE_RKEY", mr_resource.validate(),
                  RDMA_SC_INVALID_ARGUMENT);
    mr_resource.state = RDMA_RESOURCE_ACTIVE;
    expect_status("MR_RESOURCE_ACTIVE_REMOTE_RKEY", mr_resource.validate(),
                  RDMA_SC_INVALID_ARGUMENT);
    mr_resource.state = RDMA_RESOURCE_QUIESCING;
    expect_status("MR_RESOURCE_QUIESCING_REMOTE_RKEY",
                  mr_resource.validate(), RDMA_SC_INVALID_ARGUMENT);
    mr_resource.state = RDMA_RESOURCE_ERROR;
    expect_status("MR_RESOURCE_ERROR_REMOTE_RKEY", mr_resource.validate(),
                  RDMA_SC_INVALID_ARGUMENT);
    mr_resource.state = RDMA_RESOURCE_PROGRAMMED;
    mr_resource.rkey = mr_resource.lkey;
    expect_status("MR_RESOURCE_REMOTE_RKEY_MATCH", mr_resource.validate(),
                  RDMA_SC_OK);
    mr_resource.access.remote_read = 1'b0;
    mr_resource.access.remote_write = 1'b1;
    mr_resource.rkey = 0;
    expect_status("MR_RESOURCE_REMOTE_WRITE_RKEY", mr_resource.validate(),
                  RDMA_SC_INVALID_ARGUMENT);
    mr_resource.access.remote_write = 1'b0;
    mr_resource.access.remote_atomic = 1'b1;
    expect_status("MR_RESOURCE_REMOTE_ATOMIC_RKEY", mr_resource.validate(),
                  RDMA_SC_INVALID_ARGUMENT);
    mr_resource.access.remote_atomic = 1'b0;
    mr_resource.access.memory_window_bind = 1'b1;
    mr_resource.rkey = 32'hffff_ffff;
    expect_status("MR_RESOURCE_LOCAL_RKEY", mr_resource.validate(),
                  RDMA_SC_INVALID_ARGUMENT);
    mr_resource.state = RDMA_RESOURCE_ACTIVE;
    expect_status("MR_RESOURCE_ACTIVE_LOCAL_RKEY", mr_resource.validate(),
                  RDMA_SC_INVALID_ARGUMENT);
    mr_resource.state = RDMA_RESOURCE_QUIESCING;
    expect_status("MR_RESOURCE_QUIESCING_LOCAL_RKEY",
                  mr_resource.validate(), RDMA_SC_INVALID_ARGUMENT);
    mr_resource.state = RDMA_RESOURCE_ERROR;
    expect_status("MR_RESOURCE_ERROR_LOCAL_RKEY", mr_resource.validate(),
                  RDMA_SC_INVALID_ARGUMENT);
    mr_resource.state = RDMA_RESOURCE_PROGRAMMED;
    mr_resource.rkey = mr_resource.lkey;
    expect_status("MR_RESOURCE_LOCAL_MATCHING_RKEY", mr_resource.validate(),
                  RDMA_SC_OK);
    mr_resource.rkey = 0;
    expect_status("MR_RESOURCE_LOCAL_ZERO_RKEY", mr_resource.validate(),
                  RDMA_SC_OK);
    cloned_object = mr_resource.clone();
    if (!$cast(mr_resource_clone, cloned_object))
      `uvm_error("MR_RESOURCE_COPY", "MR clone lost dynamic type")
    else if (mr_resource_clone.handle == null ||
             mr_resource_clone.pd_h == null ||
             mr_resource_clone.handle == mr_resource.handle ||
             mr_resource_clone.pd_h == mr_resource.pd_h ||
             mr_resource_clone.access != mr_resource.access ||
             mr_resource_clone.mr_serial != 12'habc ||
             mr_resource_clone.local_mr_id != 24'h12_3456 ||
             mr_resource_clone.lkey != 32'h1234_56a5 ||
             mr_resource_clone.rkey != 0)
      `uvm_error("MR_RESOURCE_COPY", "MR clone lost or aliased state")
    mismatched_h = make_handle("mr_resource_cross_pd_h", RDMA_RESOURCE_PD,
                               32'h909);
    mismatched_h.function_uid++;
    mr_resource.pd_h = mismatched_h;
    expect_status("MR_RESOURCE_PD_OWNER", mr_resource.validate(),
                  RDMA_SC_INVALID_ARGUMENT);
    mr_resource.pd_h = cq_h;
    expect_status("MR_RESOURCE_PD_KIND", mr_resource.validate(),
                  RDMA_SC_INVALID_ARGUMENT);
    mr_resource.pd_h = pd_h;
    mr_resource.length = 0;
    expect_status("MR_RESOURCE_LENGTH", mr_resource.validate(),
                  RDMA_SC_INVALID_ARGUMENT);
    mr_resource.state = RDMA_RESOURCE_RELEASED;
    mr_resource.pd_h = null;
    expect_status("MR_RESOURCE_RELEASED", mr_resource.validate(), RDMA_SC_OK);

    cq_resource.handle = cq_h;
    cq_resource.owner = function_h;
    cq_resource.state = RDMA_RESOURCE_ACTIVE;
    cq_resource.local_cq_id = 32'h3131;
    cq_resource.global_cq_id = 32'h9191_3131;
    cq_resource.ceq_h = ceq_h;
    cq_resource.depth = 256;
    cq_resource.producer_index = 32'h81;
    cq_resource.consumer_index = 32'h42;
    cq_resource.producer_wrap = 1'b1;
    cq_resource.consumer_wrap = 1'b1;
    cq_resource.queue_iova.value = 64'h4100_0000;
    expect_status("CQ_RESOURCE", cq_resource.validate(), RDMA_SC_OK);
    cq_resource.ceq_h = null;
    expect_status("CQ_RESOURCE_CEQ", cq_resource.validate(),
                  RDMA_SC_INVALID_ARGUMENT);
    mismatched_h = make_handle("cq_resource_stale_ceq_h", RDMA_RESOURCE_CEQ,
                               32'h90a);
    mismatched_h.generation++;
    cq_resource.ceq_h = mismatched_h;
    expect_status("CQ_RESOURCE_CEQ_GENERATION", cq_resource.validate(),
                  RDMA_SC_STALE_GENERATION);
    cq_resource.ceq_h = cq_h;
    expect_status("CQ_RESOURCE_CEQ_KIND", cq_resource.validate(),
                  RDMA_SC_INVALID_ARGUMENT);
    cq_resource.state = RDMA_RESOURCE_RELEASED;
    cq_resource.ceq_h = null;
    expect_status("CQ_RESOURCE_RELEASED", cq_resource.validate(), RDMA_SC_OK);
    cq_resource.state = RDMA_RESOURCE_ACTIVE;
    cq_resource.ceq_h = ceq_h;
    cloned_object = cq_resource.clone();
    if (!$cast(cq_resource_clone, cloned_object))
      `uvm_error("CQ_RESOURCE_CLONE", "CQ clone lost dynamic type")
    else if (cq_resource_clone.handle == null ||
             cq_resource_clone.owner == null ||
             cq_resource_clone.ceq_h == null)
      `uvm_error("CQ_RESOURCE_CLONE", "CQ clone lost nested handles")
    else if (cq_resource_clone.handle == cq_resource.handle ||
             cq_resource_clone.owner == cq_resource.owner ||
             cq_resource_clone.ceq_h == cq_resource.ceq_h ||
             cq_resource_clone.state != RDMA_RESOURCE_ACTIVE ||
             cq_resource_clone.local_cq_id != 32'h3131 ||
             cq_resource_clone.global_cq_id != 32'h9191_3131 ||
             cq_resource_clone.depth != 256 ||
             cq_resource_clone.producer_index != 32'h81 ||
             cq_resource_clone.consumer_index != 32'h42 ||
             !cq_resource_clone.producer_wrap ||
             !cq_resource_clone.consumer_wrap ||
             cq_resource_clone.queue_iova.value != 64'h4100_0000)
      `uvm_error("CQ_RESOURCE_CLONE", "CQ clone lost or aliased fields")
    cq_resource.producer_index = 32'h20;
    expect_status("CQ_RESOURCE_SAME_WRAP_ORDER", cq_resource.validate(),
                  RDMA_SC_INVALID_ARGUMENT);
    cq_resource.producer_index = 32'h81;
    cq_resource.consumer_wrap = 1'b0;
    expect_status("CQ_RESOURCE_DIFFERENT_WRAP_ORDER", cq_resource.validate(),
                  RDMA_SC_INVALID_ARGUMENT);
    cq_resource.producer_index = 32'h42;
    expect_status("CQ_RESOURCE_FULL_RING", cq_resource.validate(), RDMA_SC_OK);
    cq_resource.producer_index = 32'h81;
    cq_resource.consumer_wrap = 1'b1;
    cq_resource.depth = 0;
    expect_status("CQ_RESOURCE_ZERO_DEPTH", cq_resource.validate(),
                  RDMA_SC_INVALID_ARGUMENT);
    cq_resource.depth = 100;
    expect_status("CQ_RESOURCE_POWER_TWO", cq_resource.validate(),
                  RDMA_SC_INVALID_ARGUMENT);
    cq_resource.depth = 256;
    cq_resource.producer_index = 256;
    expect_status("CQ_RESOURCE_PI", cq_resource.validate(),
                  RDMA_SC_INVALID_ARGUMENT);
    cq_resource.producer_index = 32'h81;
    cq_resource.consumer_index = 256;
    expect_status("CQ_RESOURCE_CI", cq_resource.validate(),
                  RDMA_SC_INVALID_ARGUMENT);
    cq_resource.consumer_index = 32'h42;

    qp_resource.handle = qp_h;
    qp_resource.owner = function_h;
    qp_resource.state = RDMA_RESOURCE_ACTIVE;
    qp_resource.local_qp_id = 32'h1111;
    qp_resource.global_qp_id = 32'h9999_1111;
    qp_resource.transport = RDMA_TRANSPORT_URC;
    qp_resource.qp_state = RDMA_QPS_RTS;
    qp_resource.sq_depth = 1024;
    qp_resource.rq_depth = 512;
    qp_resource.sq_producer_index = 32'h81;
    qp_resource.sq_consumer_index = 32'h42;
    qp_resource.sq_wrap = 1'b1;
    qp_resource.sq_consumer_wrap = 1'b1;
    qp_resource.rq_producer_index = 32'h24;
    qp_resource.rq_consumer_index = 32'h12;
    qp_resource.rq_wrap = 1'b0;
    qp_resource.rq_consumer_wrap = 1'b0;
    qp_resource.sq_iova.value = 64'h4200_0000;
    qp_resource.rq_iova.value = 64'h4300_0000;
    qp_resource.pd_h = pd_h;
    qp_resource.send_cq_h = cq_h;
    qp_resource.recv_cq_h = cq_h;
    qp_resource.dependencies.push_back(pd_h);
    qp_resource.outstanding_ids.push_back(64'hface_0001);
    qp_resource.hmc_fvm_addr_valid = 1'b1;
    qp_resource.hmc_fvm_addr.value = 64'h4444_0000;
    mapping = rdma_dma_mapping::type_id::create("mapping");
    mapping.function_h = function_h;
    mapping.owner_h = qp_h;
    mapping.iova.value = 64'h5000_0000;
    mapping.size = 64'h2000;
    mapping.state = RDMA_MAPPING_ACTIVE;
    backing_ref = rdma_backing_ref::type_id::create("backing_ref");
    backing_ref.mapping = mapping;
    backing_ref.ownership = RDMA_OWNERSHIP_CONTROL_PLANE;
    qp_resource.backing_refs.push_back(backing_ref);
    hmc_ref = rdma_hmc_ref::type_id::create("hmc_ref");
    hmc_ref.owner = function_h;
    hmc_ref.object_kind = RDMA_RESOURCE_MR;
    hmc_ref.address.value = 64'h6000_0000;
    hmc_ref.size = 64'h1000;
    hmc_ref.first_pbl_index = 32'h80;
    hmc_ref.ownership = RDMA_OWNERSHIP_CONTROL_PLANE;
    qp_resource.hmc_refs.push_back(hmc_ref);
    expect_status("QP_RESOURCE", qp_resource.validate(), RDMA_SC_OK);
    qp_resource.srq_h = srq_h;
    expect_status("QP_RESOURCE_SRQ", qp_resource.validate(), RDMA_SC_OK);
    mismatched_h = make_handle("qp_resource_cross_srq_h", RDMA_RESOURCE_SRQ,
                               32'h90b);
    mismatched_h.function_uid++;
    qp_resource.srq_h = mismatched_h;
    expect_status("QP_RESOURCE_SRQ_OWNER", qp_resource.validate(),
                  RDMA_SC_INVALID_ARGUMENT);
    qp_resource.srq_h = null;
    mismatched_h = make_handle("qp_resource_stale_cq_h", RDMA_RESOURCE_CQ,
                               32'h90c);
    mismatched_h.generation++;
    qp_resource.recv_cq_h = mismatched_h;
    expect_status("QP_RESOURCE_CQ_GENERATION", qp_resource.validate(),
                  RDMA_SC_STALE_GENERATION);
    qp_resource.recv_cq_h = cq_h;
    cloned_object = qp_resource.clone();
    if (!$cast(qp_resource_clone, cloned_object))
      `uvm_error("RESOURCE_CLONE", "QP clone lost dynamic type")
    else if (qp_resource_clone.handle == null ||
             qp_resource_clone.owner == null ||
             qp_resource_clone.pd_h == null ||
             qp_resource_clone.send_cq_h == null ||
             qp_resource_clone.recv_cq_h == null ||
             qp_resource_clone.backing_refs.size() != 1 ||
             qp_resource_clone.hmc_refs.size() != 1 ||
             qp_resource_clone.dependencies.size() != 1 ||
             qp_resource_clone.outstanding_ids.size() != 1)
      `uvm_error("RESOURCE_CLONE", "QP clone lost nested objects")
    else if (qp_resource_clone.backing_refs[0] == null ||
             qp_resource_clone.backing_refs[0].mapping == null ||
             qp_resource_clone.hmc_refs[0] == null ||
             qp_resource_clone.hmc_refs[0].owner == null ||
             qp_resource_clone.dependencies[0] == null)
      `uvm_error("RESOURCE_CLONE", "QP clone contains a null nested object")
    else if (qp_resource_clone.handle == qp_resource.handle ||
             qp_resource_clone.owner == qp_resource.owner ||
             qp_resource_clone.backing_refs[0] ==
               qp_resource.backing_refs[0] ||
             qp_resource_clone.backing_refs[0].mapping ==
               qp_resource.backing_refs[0].mapping ||
             qp_resource_clone.backing_refs[0].mapping.function_h ==
               qp_resource.backing_refs[0].mapping.function_h ||
             qp_resource_clone.backing_refs[0].mapping.owner_h ==
               qp_resource.backing_refs[0].mapping.owner_h ||
             qp_resource_clone.hmc_refs[0] == qp_resource.hmc_refs[0] ||
             qp_resource_clone.hmc_refs[0].owner ==
               qp_resource.hmc_refs[0].owner ||
             qp_resource_clone.dependencies[0] ==
               qp_resource.dependencies[0] ||
             qp_resource_clone.pd_h == qp_resource.pd_h ||
             qp_resource_clone.send_cq_h == qp_resource.send_cq_h ||
             qp_resource_clone.recv_cq_h == qp_resource.recv_cq_h ||
             qp_resource_clone.state != RDMA_RESOURCE_ACTIVE ||
             qp_resource_clone.local_qp_id != 32'h1111 ||
             qp_resource_clone.global_qp_id != 32'h9999_1111 ||
             qp_resource_clone.transport != RDMA_TRANSPORT_URC ||
             qp_resource_clone.qp_state != RDMA_QPS_RTS ||
             qp_resource_clone.sq_depth != 1024 ||
             qp_resource_clone.rq_depth != 512 ||
             qp_resource_clone.sq_producer_index != 32'h81 ||
             qp_resource_clone.sq_consumer_index != 32'h42 ||
             !qp_resource_clone.sq_wrap ||
             !qp_resource_clone.sq_consumer_wrap ||
             qp_resource_clone.rq_producer_index != 32'h24 ||
             qp_resource_clone.rq_consumer_index != 32'h12 ||
             qp_resource_clone.rq_wrap ||
             qp_resource_clone.rq_consumer_wrap ||
             qp_resource_clone.sq_iova.value != 64'h4200_0000 ||
             qp_resource_clone.rq_iova.value != 64'h4300_0000 ||
             qp_resource_clone.outstanding_ids[0] != 64'hface_0001)
      `uvm_error("RESOURCE_CLONE", "QP clone lost or aliased state")
    else begin
      qp_resource_clone.handle.object_id++;
      qp_resource_clone.owner.function_uid++;
      qp_resource_clone.backing_refs[0].mapping.iova.value++;
      qp_resource_clone.backing_refs[0].mapping.owner_h.object_id++;
      qp_resource_clone.hmc_refs[0].owner.function_uid++;
      qp_resource_clone.dependencies[0].object_id++;
      if (qp_resource.handle.object_id != 32'h404 ||
          qp_resource.owner.function_uid != 64'h1234_5678_9abc_def0 ||
          qp_resource.backing_refs[0].mapping.iova.value !=
            64'h5000_0000 ||
          qp_resource.backing_refs[0].mapping.owner_h.object_id !=
            32'h404 ||
          qp_resource.hmc_refs[0].owner.function_uid !=
            64'h1234_5678_9abc_def0 ||
          qp_resource.dependencies[0].object_id != 32'h101)
        `uvm_error("RESOURCE_CLONE", "QP clone mutation reached source")
      qp_resource_clone.backing_refs.push_back(backing_ref);
      qp_resource_clone.hmc_refs.push_back(hmc_ref);
      qp_resource_clone.copy(qp_resource);
      if (qp_resource_clone.backing_refs.size() != 1 ||
          qp_resource_clone.hmc_refs.size() != 1 ||
          qp_resource_clone.backing_refs[0] == backing_ref ||
          qp_resource_clone.hmc_refs[0] == hmc_ref)
        `uvm_error("RESOURCE_REF_REPLACE",
                   "resource copy retained or aliased prior backing graph")
    end

    qp_resource.sq_producer_index = 32'h20;
    expect_status("QP_RESOURCE_SQ_SAME_WRAP_ORDER", qp_resource.validate(),
                  RDMA_SC_INVALID_ARGUMENT);
    qp_resource.sq_producer_index = 32'h81;
    qp_resource.sq_consumer_wrap = 1'b0;
    expect_status("QP_RESOURCE_SQ_DIFFERENT_WRAP_ORDER", qp_resource.validate(),
                  RDMA_SC_INVALID_ARGUMENT);
    qp_resource.sq_consumer_wrap = 1'b1;
    qp_resource.rq_producer_index = 32'h08;
    expect_status("QP_RESOURCE_RQ_SAME_WRAP_ORDER", qp_resource.validate(),
                  RDMA_SC_INVALID_ARGUMENT);
    qp_resource.rq_producer_index = 32'h24;
    qp_resource.rq_wrap = 1'b1;
    expect_status("QP_RESOURCE_RQ_DIFFERENT_WRAP_ORDER", qp_resource.validate(),
                  RDMA_SC_INVALID_ARGUMENT);
    qp_resource.rq_wrap = 1'b0;

    qp_resource.pd_h = cq_h;
    expect_status("QP_RESOURCE_PD", qp_resource.validate(),
                  RDMA_SC_INVALID_ARGUMENT);
    qp_resource.pd_h = pd_h;
    qp_resource.send_cq_h = qp_h;
    expect_status("QP_RESOURCE_SEND_CQ", qp_resource.validate(),
                  RDMA_SC_INVALID_ARGUMENT);
    qp_resource.send_cq_h = cq_h;
    qp_resource.recv_cq_h = null;
    expect_status("QP_RESOURCE_RECV_CQ", qp_resource.validate(),
                  RDMA_SC_INVALID_ARGUMENT);
    qp_resource.recv_cq_h = cq_h;

    qp_resource.sq_depth = 0;
    expect_status("QP_RESOURCE_ZERO_DEPTH", qp_resource.validate(),
                  RDMA_SC_INVALID_ARGUMENT);
    qp_resource.sq_depth = 1000;
    expect_status("QP_RESOURCE_POWER_TWO", qp_resource.validate(),
                  RDMA_SC_INVALID_ARGUMENT);
    qp_resource.sq_depth = 1024;
    qp_resource.sq_producer_index = 1024;
    expect_status("QP_RESOURCE_SQ_PI", qp_resource.validate(),
                  RDMA_SC_INVALID_ARGUMENT);
    qp_resource.sq_producer_index = 32'h81;
    qp_resource.rq_consumer_index = 512;
    expect_status("QP_RESOURCE_RQ_CI", qp_resource.validate(),
                  RDMA_SC_INVALID_ARGUMENT);
    qp_resource.rq_consumer_index = 32'h12;
    qp_resource.transport = rdma_transport_e'(3'b111);
    expect_status("QP_RESOURCE_TRANSPORT", qp_resource.validate(),
                  RDMA_SC_INVALID_ARGUMENT);
    qp_resource.transport = RDMA_TRANSPORT_URC;
    qp_resource.qp_state = rdma_qp_state_e'(4'hf);
    expect_status("QP_RESOURCE_QP_STATE", qp_resource.validate(),
                  RDMA_SC_INVALID_ARGUMENT);
    qp_resource.qp_state = RDMA_QPS_RTS;
    qp_resource.state = rdma_resource_state_e'(3'b111);
    expect_status("QP_RESOURCE_STATE", qp_resource.validate(),
                  RDMA_SC_INVALID_ARGUMENT);
    qp_resource.state = RDMA_RESOURCE_ACTIVE;

    srq_resource.handle = srq_h;
    srq_resource.owner = function_h;
    srq_resource.state = RDMA_RESOURCE_PROGRAMMED;
    srq_resource.depth = 128;
    srq_resource.max_sge = 2;
    srq_resource.pd_h = pd_h;
    expect_status("SRQ_RESOURCE", srq_resource.validate(), RDMA_SC_OK);
    mismatched_h = make_handle("srq_resource_cross_pd_h", RDMA_RESOURCE_PD,
                               32'h90d);
    mismatched_h.function_uid++;
    srq_resource.pd_h = mismatched_h;
    expect_status("SRQ_RESOURCE_PD_OWNER", srq_resource.validate(),
                  RDMA_SC_INVALID_ARGUMENT);
    srq_resource.pd_h = cq_h;
    expect_status("SRQ_RESOURCE_PD_KIND", srq_resource.validate(),
                  RDMA_SC_INVALID_ARGUMENT);
    srq_resource.pd_h = pd_h;
    srq_resource.max_sge = 0;
    expect_status("SRQ_RESOURCE_MAX_SGE", srq_resource.validate(),
                  RDMA_SC_INVALID_ARGUMENT);
    srq_resource.state = RDMA_RESOURCE_RELEASED;
    srq_resource.pd_h = null;
    expect_status("SRQ_RESOURCE_RELEASED", srq_resource.validate(),
                  RDMA_SC_OK);

    cmq_resource.handle = cmq_h;
    cmq_resource.owner = function_h;
    cmq_resource.state = RDMA_RESOURCE_PROGRAMMED;
    cmq_resource.depth = 64;
    cmq_resource.producer_index = 11;
    cmq_resource.consumer_index = 7;
    cmq_resource.producer_wrap = 1'b1;
    cmq_resource.consumer_wrap = 1'b1;
    cmq_resource.completion_producer_index = 23;
    cmq_resource.completion_consumer_index = 19;
    cmq_resource.completion_wrap = 1'b1;
    cmq_resource.completion_consumer_wrap = 1'b1;
    expect_status("CMQ_RESOURCE", cmq_resource.validate(), RDMA_SC_OK);
    cmq_resource.completion_producer_index = 11;
    expect_status("CMQ_RESOURCE_COMPLETION_SAME_WRAP_ORDER",
                  cmq_resource.validate(), RDMA_SC_INVALID_ARGUMENT);
    cmq_resource.completion_producer_index = 23;
    cmq_resource.completion_consumer_wrap = 1'b0;
    expect_status("CMQ_RESOURCE_COMPLETION_DIFFERENT_WRAP_ORDER",
                  cmq_resource.validate(), RDMA_SC_INVALID_ARGUMENT);
    cmq_resource.completion_consumer_wrap = 1'b1;
    cmq_resource.completion_producer_index = 64;
    expect_status("CMQ_RESOURCE_COMPLETION_PI", cmq_resource.validate(),
                  RDMA_SC_INVALID_ARGUMENT);
    cmq_resource.completion_producer_index = 23;
    cmq_resource.completion_consumer_index = 64;
    expect_status("CMQ_RESOURCE_COMPLETION_CI", cmq_resource.validate(),
                  RDMA_SC_INVALID_ARGUMENT);
    cmq_resource.completion_consumer_index = 19;

    iova_type_name = $typename(mr_resource.iova);
    hmc_type_name = $typename(qp_resource.hmc_fvm_addr);
    if (iova_type_name == hmc_type_name ||
        function_resource.binding == null)
      `uvm_error("IDENTITY_TYPES",
                 "identity/address wrapper separation was lost")

    qpc = rdma_qpc_model::type_id::create("qpc");
    qpc.behavior.transport_version = 1;
    qpc.behavior.migration_enable = 1'b1;
    qpc.behavior.\priority = 5;
    qpc.transport = RDMA_TRANSPORT_RC;
    qpc.qp_h = qp_h;
    qpc.pd_h = pd_h;
    qpc.send_cq_h = cq_h;
    qpc.recv_cq_h = cq_h;
    qpc.state = RDMA_QPS_RTS;
    qpc.sq_depth = 1024;
    qpc.rq_depth = 512;
    qpc.sq_backing.value = 64'h6000_0000;
    qpc.rq_backing.value = 64'h6001_0000;
    qpc.context_backing.value = 64'h6002_0000;
    qpc.address_vector.destination_mac = 48'h02_11_22_33_44_55;
    qpc.path_mtu_bytes = 4096;
    rc_ext = rdma_qpc_rc_ext::type_id::create("rc_ext");
    rc_ext.remote_qpn = 24'habc123;
    rc_ext.send_psn = 24'h102030;
    rc_ext.recv_psn = 24'h405060;
    rc_ext.retry_count = 3;
    rc_ext.rnr_retry_count = 5;
    qpc.transport_ext = rc_ext;
    expect_status("QPC_RC", qpc.validate(), RDMA_SC_OK);
    cloned_object = qpc.clone();
    if (!$cast(qpc_clone, cloned_object))
      `uvm_error("QPC_CLONE", "QPC clone lost dynamic type")
    else if (qpc_clone.qp_h == null ||
        qpc_clone.pd_h == null ||
        qpc_clone.send_cq_h == null ||
        qpc_clone.recv_cq_h == null ||
        qpc_clone.behavior == null ||
        qpc_clone.transport_ext == null)
      `uvm_error("QPC_CLONE", "QPC clone lost nested objects")
    else if (qpc_clone.behavior == qpc.behavior ||
        qpc_clone.transport_ext == qpc.transport_ext ||
        qpc_clone.qp_h == qpc.qp_h ||
        qpc_clone.pd_h == qpc.pd_h ||
        qpc_clone.send_cq_h == qpc.send_cq_h ||
        qpc_clone.recv_cq_h == qpc.recv_cq_h ||
        qpc_clone.transport != RDMA_TRANSPORT_RC ||
        qpc_clone.state != RDMA_QPS_RTS ||
        qpc_clone.path_mtu_bytes != 4096 ||
        qpc_clone.sq_depth != 1024 || qpc_clone.rq_depth != 512 ||
        qpc_clone.sq_backing.value != 64'h6000_0000 ||
        qpc_clone.rq_backing.value != 64'h6001_0000 ||
        qpc_clone.context_backing.value != 64'h6002_0000 ||
        qpc_clone.behavior.transport_version != 1 ||
        qpc_clone.behavior.migration_enable != 1'b1 ||
        qpc_clone.behavior.\priority != 5 ||
        qpc_clone.address_vector == qpc.address_vector)
      `uvm_error("QPC_CLONE", "QPC clone lost or aliased common fields")
    else if (!$cast(rc_ext_clone, qpc_clone.transport_ext))
      `uvm_error("QPC_CLONE", "QPC clone lost RC extension type")
    else if (rc_ext_clone.remote_qpn != 24'habc123 ||
        rc_ext_clone.send_psn != 24'h102030 ||
        rc_ext_clone.recv_psn != 24'h405060 ||
        rc_ext_clone.retry_count != 3 ||
        rc_ext_clone.rnr_retry_count != 5)
      `uvm_error("QPC_CLONE", "QPC clone lost nested RC extension")
    else begin
      qpc_clone.behavior.\priority = 6;
      qpc_clone.qp_h.object_id++;
      qpc_clone.sq_depth = 2048;
      qpc_clone.path_mtu_bytes = 2048;
      rc_ext_clone.remote_qpn++;
      if (qpc.behavior.\priority != 5 ||
          qpc.qp_h.object_id != 32'h404 || qpc.sq_depth != 1024 ||
          qpc.path_mtu_bytes != 4096 ||
          rc_ext.remote_qpn != 24'habc123)
        `uvm_error("QPC_CLONE", "QPC clone mutation reached source")
    end

    ud_ext = rdma_qpc_ud_ext::type_id::create("ud_ext");
    ud_ext.qkey = 32'h8001_0000;
    qpc.transport_ext = ud_ext;
    expect_status("QPC_MISMATCH", qpc.validate(), RDMA_SC_INVALID_ARGUMENT);
    qpc.transport = RDMA_TRANSPORT_UD;
    qpc.address_vector = null;
    expect_status("QPC_UD_AV_MISSING", qpc.validate(),
                  RDMA_SC_INVALID_ARGUMENT);
    qpc.address_vector = rdma_address_vector::type_id::create("qpc_ud_av");
    if (qpc.path_mtu_bytes != 4096)
      `uvm_error("QPC_UD_PATH_MTU",
                 "QPC common path MTU changed during UD transition")
    expect_status("QPC_UD", qpc.validate(), RDMA_SC_OK);
    urc_ext = rdma_qpc_urc_ext::type_id::create("urc_ext");
    urc_ext.remote_qpn = 24'h765432;
    urc_ext.rbsn = 24'h112244;
    urc_ext.dbsn = 24'h223355;
    urc_ext.rpsn = 24'h334466;
    urc_ext.dpsn = 24'h445577;
    urc_ext.queues.rsq_backing.value = 64'h6100_0000;
    urc_ext.queues.rdsq_backing.value = 64'h6200_0000;
    urc_ext.queues.dsq_backing.value = 64'h6300_0000;
    urc_ext.queues.rsq_depth = 64;
    urc_ext.queues.rdsq_depth = 128;
    urc_ext.queues.rdsq_fetch_count = 8;
    urc_ext.queues.dsq_fetch_count = 16;
    urc_ext.queues.rq_sequence_threshold_entries = 128;
    urc_ext.queues.sq_completion_threshold_entries = 256;
    qpc.path_mtu_bytes = 8192;
    qpc.transport = RDMA_TRANSPORT_URC;
    qpc.transport_ext = urc_ext;
    expect_status("QPC_URC", qpc.validate(), RDMA_SC_OK);
    qpc.state = rdma_qp_state_e'(4'hf);
    expect_status("QPC_STATE", qpc.validate(), RDMA_SC_INVALID_ARGUMENT);
    qpc.state = RDMA_QPS_RTS;

    cqc = rdma_cqc_model::type_id::create("cqc");
    cqc.cq_h = cq_h;
    cqc.state = RDMA_CONTEXT_VALID;
    cqc.depth = 256;
    cqc.cqe_size_bytes = 64;
    cqc.page_layout.current_valid = 1'b1;
    cqc.page_layout.current_base.value = 64'h7000_0000;
    expect_status("CQC", cqc.validate(), RDMA_SC_OK);
    cqc.producer.index = cqc.depth;
    expect_status("CQC_PI", cqc.validate(), RDMA_SC_INVALID_ARGUMENT);
    cqc.producer.index = 0;
    cqc.consumer.index = cqc.depth;
    expect_status("CQC_CI", cqc.validate(), RDMA_SC_INVALID_ARGUMENT);
    cqc.consumer.index = 0;
    mrt = rdma_mrt_model::type_id::create("mrt");
    mrt.mr_h = mr_h;
    mrt.pd_h = pd_h;
    mrt.state = RDMA_CONTEXT_VALID;
    mrt.iova.value = 64'h8000_0000;
    mrt.length = 64'h1000;
    mrt.lkey = 32'h0002_025a;
    mrt.rkey = 0;
    mrt.access.local_write = 1'b1;
    expect_status("MRT", mrt.validate(), RDMA_SC_OK);
    srqc = rdma_srqc_model::type_id::create("srqc");
    srqc.srq_h = srq_h;
    srqc.pd_h = pd_h;
    srqc.state = RDMA_CONTEXT_VALID;
    srqc.depth = 128;
    srqc.srfq_backing.value = 64'h9000_0000;
    expect_status("SRQC", srqc.validate(), RDMA_SC_OK);
    srqc.producer.index = srqc.depth;
    expect_status("SRQC_PI", srqc.validate(), RDMA_SC_INVALID_ARGUMENT);
    srqc.producer.index = 0;
    ceqc = rdma_ceqc_model::type_id::create("ceqc");
    ceqc.ceq_h = ceq_h;
    ceqc.state = RDMA_CONTEXT_VALID;
    ceqc.depth = 64;
    ceqc.page_layout.current_valid = 1'b1;
    ceqc.page_layout.current_base.value = 64'ha000_0000;
    expect_status("CEQC", ceqc.validate(), RDMA_SC_OK);
    ceqc.producer.index = ceqc.depth;
    expect_status("CEQC_PI", ceqc.validate(), RDMA_SC_INVALID_ARGUMENT);
    ceqc.producer.index = 0;
    ceqc.consumer.index = ceqc.depth;
    expect_status("CEQC_CI", ceqc.validate(), RDMA_SC_INVALID_ARGUMENT);
    ceqc.consumer.index = 0;
    aeqc = rdma_aeqc_model::type_id::create("aeqc");
    aeqc.aeq_h = aeq_h;
    aeqc.state = RDMA_CONTEXT_VALID;
    aeqc.depth = 64;
    aeqc.page_layout.current_valid = 1'b1;
    aeqc.page_layout.current_base.value = 64'hb000_0000;
    expect_status("AEQC", aeqc.validate(), RDMA_SC_OK);
    aeqc.producer.index = aeqc.depth;
    expect_status("AEQC_PI", aeqc.validate(), RDMA_SC_INVALID_ARGUMENT);
    aeqc.producer.index = 0;
    aeqc.consumer.index = aeqc.depth;
    expect_status("AEQC_CI", aeqc.validate(), RDMA_SC_INVALID_ARGUMENT);
    aeqc.consumer.index = 0;
    if (qpc.describe() == "" || cqc.describe() == "")
      `uvm_error("HW_MODEL", "hardware models lack semantic descriptions")

    cmq_create_qp = rdma_cmq_sqe_model::type_id::create("cmq_create_qp");
    cmq_create_qp.opcode = RDMA_CMQ_CREATE_QP;
    cmq_create_qp.command_id = 64'h1111_2222;
    cmq_create_qp.function_h = function_h;
    cmq_create_qp.target_h = qp_h;
    cmq_create_qp.context_model = qpc;
    expect_status("CMQ_CREATE_QP", cmq_create_qp.validate(), RDMA_SC_OK);
    cmq_create_qp.context_model = cqc;
    expect_status("CMQ_CONTEXT_TYPE", cmq_create_qp.validate(),
                  RDMA_SC_INVALID_ARGUMENT);
    cmq_create_qp.context_model = qpc;
    cmq_create_qp.function_h = null;
    expect_status("CMQ_FUNCTION", cmq_create_qp.validate(),
                  RDMA_SC_INVALID_ARGUMENT);
    cmq_create_qp.function_h = function_h;
    cmq_modify_qp = rdma_cmq_sqe_model::type_id::create("cmq_modify_qp");
    cmq_modify_qp.opcode = RDMA_CMQ_MODIFY_QP;
    cmq_modify_qp.command_id = 64'h3333_4444;
    cmq_modify_qp.function_h = function_h;
    cmq_modify_qp.target_h = qp_h;
    expect_status("CMQ_MODIFY_CONTEXT", cmq_modify_qp.validate(),
                  RDMA_SC_INVALID_ARGUMENT);
    cmq_modify_qp.context_model = qpc;
    expect_status("CMQ_MODIFY_QP", cmq_modify_qp.validate(), RDMA_SC_OK);
    if (cmq_create_qp.opcode == cmq_modify_qp.opcode ||
        cmq_create_qp.command_id == cmq_modify_qp.command_id)
      `uvm_error("CMQ_OPCODES", "CMQ operations are not independent")
    cloned_object = cmq_create_qp.clone();
    if (!$cast(cmq_clone, cloned_object))
      `uvm_error("CMQ_CLONE", "CMQ SQE clone lost dynamic type")
    else if (cmq_clone.function_h == null ||
        cmq_clone.target_h == null ||
        cmq_clone.context_model == null)
      `uvm_error("CMQ_CLONE", "CMQ SQE clone lost nested objects")
    else if (cmq_clone.context_model == cmq_create_qp.context_model ||
        cmq_clone.function_h == cmq_create_qp.function_h ||
        cmq_clone.target_h == cmq_create_qp.target_h ||
        cmq_clone.opcode != RDMA_CMQ_CREATE_QP ||
        cmq_clone.command_id != 64'h1111_2222)
      `uvm_error("CMQ_CLONE", "CMQ SQE clone lost or aliased fields")
    else if (!$cast(qpc_clone, cmq_clone.context_model))
      `uvm_error("CMQ_CLONE", "CMQ SQE clone lost QPC context type")
    else if (qpc_clone.transport_ext == null)
      `uvm_error("CMQ_CLONE", "CMQ QPC clone lost its extension")
    else if (qpc_clone.transport_ext == qpc.transport_ext ||
        qpc_clone.transport != RDMA_TRANSPORT_URC ||
        qpc_clone.path_mtu_bytes != 8192 ||
        qpc_clone.sq_depth != 1024)
      `uvm_error("CMQ_CLONE", "CMQ QPC clone lost or aliased fields")
    else if (!$cast(urc_ext_clone, qpc_clone.transport_ext))
      `uvm_error("CMQ_CLONE", "CMQ QPC clone lost URC extension type")
    else if (urc_ext_clone.queues == null ||
        urc_ext_clone.queues == urc_ext.queues ||
        urc_ext_clone.remote_qpn != 24'h765432 ||
        urc_ext_clone.rbsn != 24'h112244 ||
        urc_ext_clone.dbsn != 24'h223355 ||
        urc_ext_clone.rpsn != 24'h334466 ||
        urc_ext_clone.dpsn != 24'h445577 ||
        urc_ext_clone.queues.rsq_backing.value != 64'h6100_0000 ||
        urc_ext_clone.queues.rdsq_backing.value != 64'h6200_0000 ||
        urc_ext_clone.queues.dsq_backing.value != 64'h6300_0000 ||
        urc_ext_clone.queues.rsq_depth != 64 ||
        urc_ext_clone.queues.rdsq_depth != 128 ||
        urc_ext_clone.queues.rdsq_fetch_count != 8 ||
        urc_ext_clone.queues.dsq_fetch_count != 16 ||
        urc_ext_clone.queues.rq_sequence_threshold_entries != 128 ||
        urc_ext_clone.queues.sq_completion_threshold_entries != 256)
      `uvm_error("CMQ_CLONE", "CMQ SQE clone lost nested context")
    else begin
      cmq_clone.function_h.function_uid++;
      cmq_clone.target_h.object_id++;
      qpc_clone.sq_depth = 2048;
      urc_ext_clone.remote_qpn++;
      urc_ext_clone.queues.rsq_backing.value += 64'h1000;
      urc_ext_clone.queues.rdsq_fetch_count = 24;
      if (cmq_create_qp.function_h.function_uid !=
            64'h1234_5678_9abc_def0 ||
          cmq_create_qp.target_h.object_id != 32'h404 ||
          qpc.sq_depth != 1024 || urc_ext.remote_qpn != 24'h765432 ||
          urc_ext.queues.rsq_backing.value != 64'h6100_0000 ||
          urc_ext.queues.rdsq_fetch_count != 8)
        `uvm_error("CMQ_CLONE", "CMQ clone mutation reached source")
    end

    cmq_completion =
      rdma_cmq_completion_model::type_id::create("cmq_completion");
    cmq_completion.opcode = RDMA_CMQ_CREATE_QP;
    cmq_completion.command_id = cmq_create_qp.command_id;
    cmq_completion.status = rdma_status::success("created");
    cmq_completion.result_h = qp_h;
    expect_status("CMQ_COMPLETION", cmq_completion.validate(), RDMA_SC_OK);
    cmq_completion.opcode = rdma_cmq_opcode_e'(6'h3f);
    expect_status("CMQ_COMPLETION_OPCODE", cmq_completion.validate(),
                  RDMA_SC_INVALID_ARGUMENT);
    cmq_completion.opcode = RDMA_CMQ_CREATE_QP;

    rc_sqe = rdma_sqe_model::type_id::create("rc_sqe");
    rc_sqe.transport = RDMA_TRANSPORT_RC;
    rc_sqe.opcode = RDMA_WR_ATOMIC_CMP_SWAP;
    rc_sqe.qp_h = qp_h;
    rc_sqe.wr_id = 64'ha1;
    rc_sqe.inline_data = 1'b0;
    atomic_sge.iova.value = 64'h2222_0000;
    atomic_sge.length = 8;
    rc_sqe.sges.push_back(atomic_sge);
    sqe_rc_ext = rdma_sqe_rc_ext::type_id::create("sqe_rc_ext");
    sqe_rc_ext.remote_addr.value = 64'hc000_0000;
    sqe_rc_ext.rkey = 32'h1234_5678;
    sqe_rc_ext.compare_value = 64'h1111_2222_3333_4444;
    sqe_rc_ext.swap_add_value = 64'haaaa_bbbb_cccc_dddd;
    rc_sqe.transport_ext = sqe_rc_ext;
    expect_status("RC_SQE_REMOTE_PRESENCE", rc_sqe.validate(),
                  RDMA_SC_INVALID_ARGUMENT);
    sqe_rc_ext.remote_access_valid = 1'b1;
    sqe_rc_ext.rkey_valid = 1'b1;
    sqe_rc_ext.remote_addr.value = '0;
    sqe_rc_ext.rkey = '0;
    expect_status("RC_SQE_ZERO_REMOTE_FIELDS", rc_sqe.validate(), RDMA_SC_OK);
    sqe_rc_ext.remote_addr.value = 64'hc000_0000;
    sqe_rc_ext.rkey = 32'h1234_5678;
    expect_status("RC_SQE", rc_sqe.validate(), RDMA_SC_OK);

    cloned_object = rc_sqe.clone();
    if (!$cast(sqe_clone, cloned_object))
      `uvm_error("SQE_CLONE", "SQE clone lost dynamic type")
    else if (sqe_clone.qp_h == null || sqe_clone.transport_ext == null ||
             sqe_clone.sges.size() != 1)
      `uvm_error("SQE_CLONE", "SQE clone lost nested objects")
    else if (sqe_clone.sges[0] == null)
      `uvm_error("SQE_CLONE", "SQE clone contains a null SGE")
    else if (sqe_clone.qp_h == rc_sqe.qp_h ||
             sqe_clone.transport_ext == rc_sqe.transport_ext ||
             sqe_clone.sges[0] == rc_sqe.sges[0] ||
             sqe_clone.transport != RDMA_TRANSPORT_RC ||
             sqe_clone.opcode != RDMA_WR_ATOMIC_CMP_SWAP ||
             sqe_clone.wr_id != 64'ha1 ||
             sqe_clone.sges[0].iova.value != 64'h2222_0000 ||
             sqe_clone.sges[0].length != 8)
      `uvm_error("SQE_CLONE", "SQE clone lost or aliased common fields")
    else if (!$cast(sqe_rc_ext_clone, sqe_clone.transport_ext))
      `uvm_error("SQE_CLONE", "SQE clone lost RC extension type")
    else if (sqe_rc_ext_clone.remote_addr.value != 64'hc000_0000 ||
             sqe_rc_ext_clone.rkey != 32'h1234_5678 ||
             !sqe_rc_ext_clone.remote_access_valid ||
             !sqe_rc_ext_clone.rkey_valid ||
             sqe_rc_ext_clone.compare_value != 64'h1111_2222_3333_4444 ||
             sqe_rc_ext_clone.swap_add_value != 64'haaaa_bbbb_cccc_dddd)
      `uvm_error("SQE_CLONE", "SQE clone lost nested atomic fields")
    else begin
      sqe_clone.qp_h.object_id++;
      sqe_clone.sges[0].length++;
      sqe_rc_ext_clone.compare_value++;
      if (rc_sqe.qp_h.object_id != 32'h404 ||
          rc_sqe.sges[0].length != 8 ||
          sqe_rc_ext.compare_value != 64'h1111_2222_3333_4444)
        `uvm_error("SQE_CLONE", "SQE clone mutation reached source")
    end

    rc_sqe.inline_data = 1'b1;
    rc_sqe.payload.push_back(8'hc3);
    expect_status("RC_SQE_ATOMIC_INLINE", rc_sqe.validate(),
                  RDMA_SC_INVALID_ARGUMENT);
    rc_sqe.inline_data = 1'b0;
    rc_sqe.payload.delete();
    rc_sqe.sges.push_back(extra_sge);
    expect_status("RC_SQE_ATOMIC_COUNT", rc_sqe.validate(),
                  RDMA_SC_INVALID_ARGUMENT);
    void'(rc_sqe.sges.pop_back());
    atomic_sge.length = 4;
    expect_status("RC_SQE_ATOMIC_LENGTH", rc_sqe.validate(),
                  RDMA_SC_INVALID_ARGUMENT);
    atomic_sge.length = 8;
    atomic_sge.iova.value = 64'h2222_0004;
    expect_status("RC_SQE_ATOMIC_LOCAL_ALIGN", rc_sqe.validate(),
                  RDMA_SC_INVALID_ARGUMENT);
    atomic_sge.iova.value = 64'h2222_0000;
    sqe_rc_ext.remote_addr.value = 64'hc000_0004;
    expect_status("RC_SQE_ATOMIC_REMOTE_ALIGN", rc_sqe.validate(),
                  RDMA_SC_INVALID_ARGUMENT);
    sqe_rc_ext.remote_addr.value = 64'hc000_0000;
    rc_sqe.opcode = RDMA_WR_ATOMIC_FETCH_ADD;
    expect_status("RC_SQE_FETCH_ADD", rc_sqe.validate(), RDMA_SC_OK);

    rc_sqe.opcode = RDMA_WR_RDMA_READ;
    atomic_sge.length = 64;
    expect_status("RC_SQE_READ", rc_sqe.validate(), RDMA_SC_OK);
    rc_sqe.inline_data = 1'b1;
    rc_sqe.payload.push_back(8'hc4);
    expect_status("RC_SQE_READ_INLINE", rc_sqe.validate(),
                  RDMA_SC_INVALID_ARGUMENT);
    rc_sqe.inline_data = 1'b0;
    expect_status("RC_SQE_READ_PAYLOAD", rc_sqe.validate(),
                  RDMA_SC_INVALID_ARGUMENT);
    rc_sqe.payload.delete();

    ud_sqe = rdma_sqe_model::type_id::create("ud_sqe");
    ud_sqe.transport = RDMA_TRANSPORT_UD;
    ud_sqe.opcode = RDMA_WR_SEND_WITH_IMM;
    ud_sqe.qp_h = qp_h;
    ud_sqe.wr_id = 64'hb2;
    ud_sqe.inline_data = 1'b1;
    ud_sqe.payload.push_back(8'hd4);
    sqe_ud_ext = rdma_sqe_ud_ext::type_id::create("sqe_ud_ext");
    sqe_ud_ext.destination_qpn = 24'h010203;
    sqe_ud_ext.qkey = 32'h1111_2222;
    sqe_ud_ext.address_vector_id = 32'h89ab_cdef;
    ud_sqe.transport_ext = sqe_ud_ext;
    expect_status("UD_SQE_AV_MISSING", ud_sqe.validate(),
                  RDMA_SC_INVALID_ARGUMENT);
    sqe_ud_ext.address_vector_valid = 1'b1;
    sqe_ud_ext.address_vector_id = '0;
    expect_status("UD_SQE_ZERO_AV_ID", ud_sqe.validate(), RDMA_SC_OK);
    sqe_ud_ext.address_vector_id = 32'h89ab_cdef;
    expect_status("UD_SQE", ud_sqe.validate(), RDMA_SC_OK);
    if (rc_sqe.transport == ud_sqe.transport ||
        rc_sqe.opcode == ud_sqe.opcode)
      `uvm_error("SQE_VARIANTS", "SQE variants are not independent")
    cloned_object = ud_sqe.clone();
    if (!$cast(ud_sqe_clone, cloned_object))
      `uvm_error("UD_SQE_CLONE", "UD SQE clone lost dynamic type")
    else if (ud_sqe_clone.qp_h == null ||
             ud_sqe_clone.transport_ext == null ||
             ud_sqe_clone.payload.size() != 1)
      `uvm_error("UD_SQE_CLONE", "UD SQE clone lost nested objects")
    else if (ud_sqe_clone.qp_h == ud_sqe.qp_h ||
             ud_sqe_clone.transport_ext == ud_sqe.transport_ext ||
             ud_sqe_clone.payload != ud_sqe.payload)
      `uvm_error("UD_SQE_CLONE", "UD SQE clone lost or aliased fields")
    else if (!$cast(sqe_ud_ext_clone, ud_sqe_clone.transport_ext))
      `uvm_error("UD_SQE_CLONE", "UD SQE clone lost UD extension type")
    else if (sqe_ud_ext_clone.destination_qpn != 24'h010203 ||
             sqe_ud_ext_clone.qkey != 32'h1111_2222 ||
             sqe_ud_ext_clone.address_vector_id != 32'h89ab_cdef ||
             !sqe_ud_ext_clone.address_vector_valid)
      `uvm_error("UD_SQE_CLONE", "UD SQE clone lost fields")
    else begin
      ud_sqe_clone.qp_h.object_id++;
      ud_sqe_clone.payload[0] = 8'h00;
      sqe_ud_ext_clone.address_vector_id++;
      if (ud_sqe.qp_h.object_id != 32'h404 ||
          ud_sqe.payload[0] != 8'hd4 ||
          sqe_ud_ext.address_vector_id != 32'h89ab_cdef)
        `uvm_error("UD_SQE_CLONE", "UD SQE clone mutation reached source")
    end

    rc_sqe.opcode = RDMA_WR_RECV;
    expect_status("RC_SQE_RECV_OPCODE", rc_sqe.validate(),
                  RDMA_SC_UNSUPPORTED_OPCODE);
    rc_sqe.opcode = RDMA_WR_LOCAL_INVALIDATE;
    rc_sqe.inline_data = 1'b0;
    rc_sqe.payload.delete();
    rc_sqe.sges.delete();
    sqe_rc_ext.rkey_valid = 1'b0;
    sqe_rc_ext.rkey = 0;
    expect_status("RC_SQE_INVALIDATE_RKEY_MISSING", rc_sqe.validate(),
                  RDMA_SC_INVALID_ARGUMENT);
    sqe_rc_ext.rkey_valid = 1'b1;
    expect_status("RC_SQE_INVALIDATE_ZERO_RKEY", rc_sqe.validate(),
                  RDMA_SC_OK);
    rc_sqe.sges.push_back(sge);
    expect_status("RC_SQE_INVALIDATE_SGE", rc_sqe.validate(),
                  RDMA_SC_INVALID_ARGUMENT);
    rc_sqe.sges.delete();

    urc_sqe = rdma_sqe_model::type_id::create("urc_sqe");
    urc_sqe.transport = RDMA_TRANSPORT_URC;
    urc_sqe.opcode = RDMA_WR_RDMA_WRITE;
    urc_sqe.qp_h = qp_h;
    urc_sqe.wr_id = 64'hc4;
    urc_sqe.inline_data = 1'b0;
    urc_sqe.sges.push_back(sge);
    sqe_urc_ext = rdma_sqe_urc_ext::type_id::create("sqe_urc_ext");
    sqe_urc_ext.destination_qpn = 24'h506070;
    urc_sqe.transport_ext = sqe_urc_ext;
    expect_status("URC_SQE_REMOTE_PRESENCE", urc_sqe.validate(),
                  RDMA_SC_INVALID_ARGUMENT);
    sqe_urc_ext.remote_access_valid = 1'b1;
    sqe_urc_ext.rkey_valid = 1'b1;
    expect_status("URC_SQE_ZERO_REMOTE_FIELDS", urc_sqe.validate(), RDMA_SC_OK);
    cloned_object = urc_sqe.clone();
    if (!$cast(urc_sqe_clone, cloned_object))
      `uvm_error("URC_SQE_CLONE", "URC SQE clone lost dynamic type")
    else if (urc_sqe_clone.transport_ext == null)
      `uvm_error("URC_SQE_CLONE", "URC SQE clone lost its extension")
    else if (!$cast(sqe_urc_ext_clone, urc_sqe_clone.transport_ext))
      `uvm_error("URC_SQE_CLONE", "URC SQE clone lost extension type")
    else if (sqe_urc_ext_clone.remote_addr.value != 0 ||
             sqe_urc_ext_clone.rkey != 0 ||
             !sqe_urc_ext_clone.remote_access_valid ||
             !sqe_urc_ext_clone.rkey_valid)
      `uvm_error("URC_SQE_CLONE", "URC SQE clone lost presence fields")
    urc_sqe.opcode = RDMA_WR_ATOMIC_FETCH_ADD;
    expect_status("URC_SQE_ATOMIC_OPCODE", urc_sqe.validate(),
                  RDMA_SC_UNSUPPORTED_OPCODE);

    cmq_modify_qp.opcode = RDMA_CMQ_QUERY;
    cmq_modify_qp.context_model = null;
    cmq_modify_qp.target_h = null;
    expect_status("CMQ_QUERY_TARGET", cmq_modify_qp.validate(),
                  RDMA_SC_INVALID_ARGUMENT);

    rqe = rdma_rqe_model::type_id::create("rqe");
    rqe.target_h = qp_h;
    rqe.wr_id = 64'hc3;
    rqe.sges.push_back(recv_sge);
    expect_status("RQE", rqe.validate(), RDMA_SC_OK);
    cqe = rdma_cqe_model::type_id::create("cqe");
    cqe.qp_h = qp_h;
    cqe.wr_id = 64'hd4;
    cqe.opcode = RDMA_WR_RECV;
    cqe.status = rdma_status::success();
    expect_status("CQE", cqe.validate(), RDMA_SC_OK);
    cqe.opcode = rdma_work_opcode_e'(5'h1f);
    expect_status("CQE_OPCODE", cqe.validate(), RDMA_SC_INVALID_ARGUMENT);
    cqe.opcode = RDMA_WR_RECV;
    ceqe = rdma_ceqe_model::type_id::create("ceqe");
    ceqe.cq_h = cq_h;
    ceqe.producer_index = 32'h55;
    expect_status("CEQE", ceqe.validate(), RDMA_SC_OK);
    aeqe = rdma_aeqe_model::type_id::create("aeqe");
    aeqe.target_h = qp_h;
    aeqe.event_code = 32'h66;
    expect_status("AEQE", aeqe.validate(), RDMA_SC_OK);
    aeqe.severity = RDMA_SEVERITY_WARNING;
    expect_status("AEQE_SEVERITY_WARNING", aeqe.validate(), RDMA_SC_OK);
    aeqe.severity = RDMA_SEVERITY_ERROR;
    expect_status("AEQE_SEVERITY_ERROR", aeqe.validate(), RDMA_SC_OK);
    aeqe.severity = RDMA_SEVERITY_FATAL;
    expect_status("AEQE_SEVERITY_FATAL", aeqe.validate(), RDMA_SC_OK);
    aeqe.severity = RDMA_SEVERITY_INFO;
    doorbell = rdma_doorbell_model::type_id::create("doorbell");
    doorbell.kind = RDMA_DOORBELL_SQ;
    doorbell.target_h = qp_h;
    doorbell.producer_index = 32'h77;
    doorbell.wrap = 1'b1;
    expect_status("DOORBELL_SQ", doorbell.validate(), RDMA_SC_OK);
    doorbell.target_h = cq_h;
    expect_status("DOORBELL_SQ_TARGET", doorbell.validate(),
                  RDMA_SC_INVALID_ARGUMENT);
    doorbell.kind = RDMA_DOORBELL_RQ;
    doorbell.target_h = qp_h;
    expect_status("DOORBELL_RQ", doorbell.validate(), RDMA_SC_OK);
    doorbell.target_h = srq_h;
    expect_status("DOORBELL_RQ_TARGET", doorbell.validate(),
                  RDMA_SC_INVALID_ARGUMENT);
    doorbell.kind = RDMA_DOORBELL_QP_FLUSH;
    doorbell.target_h = qp_h;
    expect_status("DOORBELL_QP_FLUSH", doorbell.validate(), RDMA_SC_OK);
    doorbell.target_h = cq_h;
    expect_status("DOORBELL_QP_FLUSH_TARGET", doorbell.validate(),
                  RDMA_SC_INVALID_ARGUMENT);
    doorbell.kind = RDMA_DOORBELL_SRQ;
    doorbell.target_h = srq_h;
    expect_status("DOORBELL_SRQ", doorbell.validate(), RDMA_SC_OK);
    doorbell.target_h = qp_h;
    expect_status("DOORBELL_SRQ_TARGET", doorbell.validate(),
                  RDMA_SC_INVALID_ARGUMENT);
    doorbell.kind = RDMA_DOORBELL_CQ;
    doorbell.target_h = cq_h;
    expect_status("DOORBELL_CQ", doorbell.validate(), RDMA_SC_OK);
    doorbell.target_h = qp_h;
    expect_status("DOORBELL_CQ_TARGET", doorbell.validate(),
                  RDMA_SC_INVALID_ARGUMENT);
    doorbell.kind = RDMA_DOORBELL_CEQ;
    doorbell.target_h = ceq_h;
    expect_status("DOORBELL_CEQ", doorbell.validate(), RDMA_SC_OK);
    doorbell.target_h = cq_h;
    expect_status("DOORBELL_CEQ_TARGET", doorbell.validate(),
                  RDMA_SC_INVALID_ARGUMENT);
    doorbell.kind = RDMA_DOORBELL_AEQ;
    doorbell.target_h = aeq_h;
    expect_status("DOORBELL_AEQ", doorbell.validate(), RDMA_SC_OK);
    doorbell.target_h = ceq_h;
    expect_status("DOORBELL_AEQ_TARGET", doorbell.validate(),
                  RDMA_SC_INVALID_ARGUMENT);
    doorbell.kind = RDMA_DOORBELL_CMQ_SQ;
    doorbell.target_h = cmq_h;
    expect_status("DOORBELL_CMQ", doorbell.validate(), RDMA_SC_OK);
    doorbell.target_h = qp_h;
    expect_status("DOORBELL_CMQ_TARGET", doorbell.validate(),
                  RDMA_SC_INVALID_ARGUMENT);
    doorbell.kind = RDMA_DOORBELL_RTS2SQD;
    doorbell.target_h = qp_h;
    expect_status("DOORBELL_RTS2SQD", doorbell.validate(), RDMA_SC_OK);
    doorbell.target_h = function_h;
    expect_status("DOORBELL_RTS2SQD_TARGET", doorbell.validate(),
                  RDMA_SC_INVALID_ARGUMENT);
    doorbell.kind = RDMA_DOORBELL_SQD2RTS;
    doorbell.target_h = qp_h;
    expect_status("DOORBELL_SQD2RTS", doorbell.validate(), RDMA_SC_OK);
    doorbell.target_h = function_h;
    expect_status("DOORBELL_SQD2RTS_TARGET", doorbell.validate(),
                  RDMA_SC_INVALID_ARGUMENT);
    doorbell.kind = RDMA_DOORBELL_TX_FLUSH;
    doorbell.target_h = qp_h;
    expect_status("DOORBELL_TX_FLUSH", doorbell.validate(), RDMA_SC_OK);
    cloned_object = doorbell.clone();
    if (!$cast(doorbell_clone, cloned_object))
      `uvm_error("DOORBELL_TX_CLONE", "doorbell clone lost dynamic type")
    else if (doorbell_clone.target_h == null ||
             doorbell_clone.target_h == doorbell.target_h ||
             doorbell_clone.target_h.kind != RDMA_RESOURCE_QP)
      `uvm_error("DOORBELL_TX_CLONE", "doorbell clone lost TX identity")
    doorbell.target_h = function_h;
    expect_status("DOORBELL_TX_TARGET", doorbell.validate(),
                  RDMA_SC_INVALID_ARGUMENT);

    packet = rdma_packet::type_id::create("packet");
    packet.transport = RDMA_TRANSPORT_URC;
    packet.opcode = RDMA_NET_RDMA_WRITE;
    packet.destination_qpn = 24'h112233;
    packet.source_qpn = 24'h445566;
    packet.psn = 24'h778899;
    packet.header_bytes.push_back(8'hde);
    packet.header_bytes.push_back(8'had);
    packet.metadata.push_back("flow=primary");
    packet.payload.push_back(8'hbe);
    packet.payload.push_back(8'hef);
    cloned_object = packet.clone();
    if (!$cast(packet_clone, cloned_object) ||
        packet_clone.transport != RDMA_TRANSPORT_URC ||
        packet_clone.opcode != RDMA_NET_RDMA_WRITE ||
        packet_clone.destination_qpn != 24'h112233 ||
        packet_clone.header_bytes != packet.header_bytes ||
        packet_clone.metadata != packet.metadata ||
        packet_clone.payload != packet.payload)
      `uvm_error("PACKET_CLONE", "packet clone lost semantic fields")
    else begin
      packet_clone.header_bytes[0] = 8'h00;
      packet_clone.metadata[0] = "changed";
      if (packet.header_bytes[0] != 8'hde ||
          packet.metadata[0] != "flow=primary")
        `uvm_error("PACKET_CLONE", "packet clone mutation reached source")
    end

    policy = rdma_net_response_policy::type_id::create("policy");
    policy.responder_mode = RDMA_RESPONDER_VIP;
    policy.drop_every_n = 17;
    policy.corrupt_every_n = 19;
    policy.delay_cycles = 23;
    policy.deterministic_seed = 32'h1357_9bdf;
    cloned_object = policy.clone();
    if (!$cast(policy_clone, cloned_object) ||
        policy_clone.responder_mode != RDMA_RESPONDER_VIP ||
        policy_clone.drop_every_n != 17 ||
        policy_clone.corrupt_every_n != 19 ||
        policy_clone.delay_cycles != 23 ||
        policy_clone.deterministic_seed != 32'h1357_9bdf)
      `uvm_error("POLICY_CLONE", "response policy lost deterministic fields")

    fault = rdma_net_fault::type_id::create("fault");
    fault.kind = RDMA_FAULT_PACKET_DROP;
    fault.drop_packet = 1'b1;
    fault.corrupt_byte = 1'b1;
    fault.corrupt_byte_index = 13;
    fault.corrupt_xor_mask = 8'h81;
    fault.delay_cycles = 29;
    fault.deterministic_seed = 32'h2468_ace0;
    cloned_object = fault.clone();
    if (!$cast(fault_clone, cloned_object) ||
        fault_clone.kind != RDMA_FAULT_PACKET_DROP ||
        !fault_clone.drop_packet || !fault_clone.corrupt_byte ||
        fault_clone.corrupt_byte_index != 13 ||
        fault_clone.corrupt_xor_mask != 8'h81 ||
        fault_clone.delay_cycles != 29 ||
        fault_clone.deterministic_seed != 32'h2468_ace0)
      `uvm_error("FAULT_CLONE", "network fault lost deterministic fields")

    phase.drop_objection(this);
  endtask
endclass
