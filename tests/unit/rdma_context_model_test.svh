class rdma_context_model_test extends uvm_test;
  `uvm_component_utils(rdma_context_model_test)

  localparam longint unsigned TEST_FUNCTION_UID = 64'h1122_3344_5566_7788;
  localparam int unsigned TEST_GENERATION = 32'd7;

  function new(string name = "rdma_context_model_test",
               uvm_component parent = null);
    super.new(name, parent);
  endfunction

  function rdma_handle make_handle(
    string name,
    rdma_resource_kind_e kind,
    int unsigned object_id,
    longint unsigned function_uid = TEST_FUNCTION_UID,
    int unsigned generation = TEST_GENERATION
  );
    rdma_handle handle;

    handle = rdma_handle::type_id::create(name);
    handle.kind = kind;
    handle.function_uid = function_uid;
    handle.object_id = object_id;
    handle.generation = generation;
    return handle;
  endfunction

  function void expect_ok(string label, rdma_status status);
    if (status == null || !status.ok())
      `uvm_error(label, (status == null) ? "status is null" : status.message)
  endfunction

  function void expect_invalid(string label, rdma_status status);
    if (status == null || status.ok())
      `uvm_error(label, "invalid context topology was accepted")
  endfunction

  function rdma_page_table_layout make_page_layout(string name);
    rdma_page_table_layout layout;

    layout = rdma_page_table_layout::type_id::create(name);
    layout.mode = RDMA_OBJECT_INDIRECT_4K;
    layout.sd_base.value = 64'h0000_0000_0100_0000;
    layout.current_base.value = 64'h0000_0000_0200_0000;
    layout.current_valid = 1'b1;
    layout.next_base.value = 64'h0000_0000_0300_0000;
    layout.next_valid = 1'b1;
    return layout;
  endfunction

  function rdma_ring_position make_ring(
    string name,
    int unsigned index,
    bit wrap
  );
    rdma_ring_position position;

    position = rdma_ring_position::type_id::create(name);
    position.index = index;
    position.wrap = wrap;
    return position;
  endfunction

  function rdma_address_vector make_address_vector(string name);
    rdma_address_vector vector;

    vector = rdma_address_vector::type_id::create(name);
    vector.source_address_index = 3;
    vector.source_vport = 4;
    vector.destination_vport = 5;
    vector.destination_port = 1;
    vector.destination_mac = 48'h02_11_22_33_44_55;
    foreach (vector.destination_ip[i])
      vector.destination_ip[i] = byte'(i + 1);
    vector.ipv6 = 1'b1;
    vector.vlan_enable = 1'b1;
    vector.cfi = 1'b0;
    vector.lag_enable = 1'b1;
    vector.tunnel_enable = 1'b0;
    vector.forwarding_enable = 1'b1;
    vector.vlan_id = 12'habc;
    vector.traffic_class = 8'haa;
    vector.flow_label = 20'h54321;
    vector.hop_limit = 8'd64;
    vector.udp_source_port = 16'hc123;
    return vector;
  endfunction

  function rdma_mr_page_layout make_mr_page_layout(string name);
    rdma_mr_page_layout layout;

    layout = rdma_mr_page_layout::type_id::create(name);
    layout.pbl_mode = RDMA_MR_PBL0;
    layout.host_page_size = RDMA_MR_PAGE_4K;
    layout.pba0.value = 64'h0000_0000_0400_0000;
    layout.pba1 = '0;
    layout.first_pbl_index = '0;
    layout.address_mode = RDMA_MR_ADDRESS_VA_BASED;
    layout.odp = 1'b0;
    layout.invalidate_enable = 1'b1;
    layout.payload_vf_enable = 1'b1;
    layout.payload_vf_id = 9;
    layout.mr_serial = 32'h1234;
    return layout;
  endfunction

  function rdma_qpc_model make_qpc(string name);
    rdma_qpc_model qpc;
    rdma_qpc_rc_ext rc_ext;

    qpc = rdma_qpc_model::type_id::create(name);
    qpc.qp_h = make_handle({name, "_qp"}, RDMA_RESOURCE_QP, 32'h101);
    qpc.pd_h = make_handle({name, "_pd"}, RDMA_RESOURCE_PD, 32'h202);
    qpc.send_cq_h = make_handle({name, "_scq"}, RDMA_RESOURCE_CQ,
                                32'h303);
    qpc.recv_cq_h = make_handle({name, "_rcq"}, RDMA_RESOURCE_CQ,
                                32'h304);
    qpc.srq_h = make_handle({name, "_srq"}, RDMA_RESOURCE_SRQ, 32'h405);
    qpc.transport = RDMA_TRANSPORT_RC;
    qpc.state = RDMA_QPS_RTS;
    qpc.host_id = 2;
    qpc.vf_id = 3;
    qpc.stat_index = 4;
    qpc.pkey = 16'hffff;
    qpc.qp_sequence = 8'h5a;
    qpc.access = '{local_write:1'b1, remote_read:1'b1,
                   remote_write:1'b1, memory_window_bind:1'b0,
                   remote_atomic:1'b1};
    qpc.sq_depth = 64;
    qpc.rq_depth = 32;
    qpc.sq_backing.value = 64'h0000_0000_1000_0000;
    qpc.rq_backing.value = 64'h0000_0000_1100_0000;
    qpc.context_backing.value = 64'h0000_0000_1200_0000;
    qpc.sq_mode = RDMA_OBJECT_DIRECT_4K;
    qpc.rq_mode = RDMA_OBJECT_INDIRECT_4K;
    qpc.address_vector = make_address_vector({name, "_av"});
    qpc.signature_enable = 1'b1;
    qpc.tx_flow_control = 1'b1;
    qpc.rx_flow_control = 1'b0;
    rc_ext = rdma_qpc_rc_ext::type_id::create({name, "_rc_ext"});
    rc_ext.remote_qpn = 24'h654321;
    rc_ext.send_psn = 24'habcdef;
    rc_ext.recv_psn = 24'h123456;
    rc_ext.retry_count = 3;
    rc_ext.rnr_retry_count = 4;
    rc_ext.path_mtu_bytes = 1024;
    qpc.transport_ext = rc_ext;
    return qpc;
  endfunction

  function rdma_cqc_model make_cqc(string name);
    rdma_cqc_model cqc;

    cqc = rdma_cqc_model::type_id::create(name);
    cqc.cq_h = make_handle({name, "_cq"}, RDMA_RESOURCE_CQ, 32'h301);
    cqc.ceq_h = make_handle({name, "_ceq"}, RDMA_RESOURCE_CEQ, 32'h701);
    cqc.state = RDMA_CONTEXT_VALID;
    cqc.depth = 64;
    cqc.cqe_size_bytes = 64;
    cqc.threshold = 8;
    cqc.page_layout = make_page_layout({name, "_layout"});
    cqc.producer = make_ring({name, "_producer"}, 9, 1'b0);
    cqc.consumer = make_ring({name, "_consumer"}, 3, 1'b0);
    cqc.urc_enable = 1'b1;
    cqc.load_ci_done = 1'b1;
    cqc.last_arm_sequence = 2'd1;
    cqc.arm_sequence = 2'd2;
    cqc.arm_state = 2'd3;
    cqc.shadow_backing.value = 64'h0000_0000_1300_0000;
    return cqc;
  endfunction

  function rdma_mrt_model make_mrt(string name);
    rdma_mrt_model mrt;

    mrt = rdma_mrt_model::type_id::create(name);
    mrt.mr_h = make_handle({name, "_mr"}, RDMA_RESOURCE_MR, 32'h000123);
    mrt.pd_h = make_handle({name, "_pd"}, RDMA_RESOURCE_PD, 32'h000202);
    mrt.state = RDMA_CONTEXT_VALID;
    mrt.iova.value = 64'h0000_0000_8000_0000;
    mrt.length = 64'h2000;
    mrt.lkey = 32'h0001_235a;
    mrt.rkey = mrt.lkey;
    mrt.access = '{local_write:1'b1, remote_read:1'b1,
                   remote_write:1'b1, memory_window_bind:1'b0,
                   remote_atomic:1'b0};
    mrt.object_type = 2'd1;
    mrt.page_layout = make_mr_page_layout({name, "_layout"});
    return mrt;
  endfunction

  function rdma_srqc_model make_srqc(string name);
    rdma_srqc_model srqc;

    srqc = rdma_srqc_model::type_id::create(name);
    srqc.srq_h = make_handle({name, "_srq"}, RDMA_RESOURCE_SRQ, 32'h501);
    srqc.pd_h = make_handle({name, "_pd"}, RDMA_RESOURCE_PD, 32'h202);
    srqc.state = RDMA_CONTEXT_VALID;
    srqc.depth = 32;
    srqc.load_pi_threshold = 4;
    srqc.limit_threshold = 8;
    srqc.object_mode = RDMA_OBJECT_DIRECT_4K;
    srqc.srfq_backing.value = 64'h0000_0000_1400_0000;
    srqc.shadow_backing.value = 64'h0000_0000_1500_0000;
    srqc.producer = make_ring({name, "_producer"}, 5, 1'b0);
    srqc.arm_sequence = 2'd2;
    return srqc;
  endfunction

  function rdma_ceqc_model make_ceqc(string name);
    rdma_ceqc_model ceqc;

    ceqc = rdma_ceqc_model::type_id::create(name);
    ceqc.ceq_h = make_handle({name, "_ceq"}, RDMA_RESOURCE_CEQ, 32'h701);
    ceqc.state = RDMA_CONTEXT_VALID;
    ceqc.depth = 32;
    ceqc.vector_id = 11;
    ceqc.page_layout = make_page_layout({name, "_layout"});
    ceqc.producer = make_ring({name, "_producer"}, 7, 1'b0);
    ceqc.consumer = make_ring({name, "_consumer"}, 2, 1'b0);
    return ceqc;
  endfunction

  function rdma_aeqc_model make_aeqc(string name);
    rdma_aeqc_model aeqc;

    aeqc = rdma_aeqc_model::type_id::create(name);
    aeqc.aeq_h = make_handle({name, "_aeq"}, RDMA_RESOURCE_AEQ, 32'h801);
    aeqc.state = RDMA_CONTEXT_VALID;
    aeqc.depth = 32;
    aeqc.vector_id = 12;
    aeqc.page_layout = make_page_layout({name, "_layout"});
    aeqc.producer = make_ring({name, "_producer"}, 8, 1'b0);
    aeqc.consumer = make_ring({name, "_consumer"}, 1, 1'b0);
    return aeqc;
  endfunction

  task run_phase(uvm_phase phase);
    rdma_rdma_access_t access;
    rdma_dma_permission_t dma_permission;
    uvm_object cloned_object;
    rdma_ring_position ring;
    rdma_ring_position ring_clone;
    rdma_page_table_layout page_layout;
    rdma_page_table_layout page_layout_clone;
    rdma_address_vector address_vector;
    rdma_address_vector address_vector_clone;
    rdma_mr_page_layout mr_page_layout;
    rdma_mr_page_layout mr_page_layout_clone;
    rdma_qpc_model qpc;
    rdma_qpc_model qpc_clone;
    rdma_cqc_model cqc;
    rdma_cqc_model cqc_clone;
    rdma_mrt_model mrt;
    rdma_mrt_model mrt_clone;
    rdma_srqc_model srqc;
    rdma_srqc_model srqc_clone;
    rdma_ceqc_model ceqc;
    rdma_ceqc_model ceqc_clone;
    rdma_aeqc_model aeqc;
    rdma_aeqc_model aeqc_clone;
    rdma_qpc_urc_ext urc_ext;
    rdma_qp qp;
    rdma_srq srq;

    phase.raise_objection(this);

    access = '{local_write:1, remote_read:1, remote_write:1,
               memory_window_bind:0, remote_atomic:1};
    dma_permission = '{device_read:1, device_write:0, atomic:0};
    if (!access.remote_write || dma_permission.device_write)
      `uvm_error("ACCESS_TYPES",
                 "RDMA rights leaked into PCIe DMA permission")

    ring = make_ring("ring", 7, 1'b1);
    expect_ok("RING_VALID", ring.validate());
    cloned_object = ring.clone();
    if (!$cast(ring_clone, cloned_object))
      `uvm_error("RING_CLONE", "ring clone lost dynamic type")
    else begin
      ring_clone.index = 8;
      if (ring.index != 7 || ring_clone.describe() == "")
        `uvm_error("RING_CLONE", "ring copy did not preserve value semantics")
    end

    page_layout = make_page_layout("page_layout");
    expect_ok("PAGE_LAYOUT_VALID", page_layout.validate());
    cloned_object = page_layout.clone();
    if (!$cast(page_layout_clone, cloned_object))
      `uvm_error("PAGE_LAYOUT_CLONE", "page layout clone lost dynamic type")
    else begin
      page_layout_clone.current_base.value += 64'h1000;
      if (page_layout.current_base.value != 64'h0000_0000_0200_0000 ||
          page_layout_clone.describe() == "")
        `uvm_error("PAGE_LAYOUT_CLONE", "page layout clone aliases source")
    end

    address_vector = make_address_vector("address_vector");
    expect_ok("ADDRESS_VECTOR_VALID", address_vector.validate());
    cloned_object = address_vector.clone();
    if (!$cast(address_vector_clone, cloned_object))
      `uvm_error("ADDRESS_VECTOR_CLONE", "address vector clone lost type")
    else begin
      address_vector_clone.destination_ip[0] = 8'hff;
      address_vector_clone.vlan_id++;
      if (address_vector.destination_ip[0] != 8'h01 ||
          address_vector.vlan_id != 12'habc ||
          address_vector_clone.describe() == "")
        `uvm_error("ADDRESS_VECTOR_CLONE", "address vector clone aliases source")
    end

    mr_page_layout = make_mr_page_layout("mr_page_layout");
    expect_ok("MR_PAGE_LAYOUT_VALID", mr_page_layout.validate());
    cloned_object = mr_page_layout.clone();
    if (!$cast(mr_page_layout_clone, cloned_object))
      `uvm_error("MR_PAGE_LAYOUT_CLONE", "MR page layout clone lost type")
    else begin
      mr_page_layout_clone.pba0.value += 64'h1000;
      if (mr_page_layout.pba0.value != 64'h0000_0000_0400_0000 ||
          mr_page_layout_clone.describe() == "")
        `uvm_error("MR_PAGE_LAYOUT_CLONE", "MR page layout clone aliases source")
    end

    qpc = make_qpc("qpc");
    expect_ok("QPC_VALID", qpc.validate());
    cloned_object = qpc.clone();
    if (!$cast(qpc_clone, cloned_object))
      `uvm_error("QPC_CLONE", "QPC clone lost dynamic type")
    else if (qpc_clone.address_vector == null ||
             qpc_clone.address_vector == qpc.address_vector ||
             qpc_clone.transport_ext == qpc.transport_ext ||
             qpc_clone.qp_h == qpc.qp_h)
      `uvm_error("QPC_CLONE", "QPC clone did not deep-copy nested values")
    else begin
      qpc_clone.address_vector.destination_mac++;
      qpc_clone.qp_h.object_id++;
      if (qpc.address_vector.destination_mac != 48'h02_11_22_33_44_55 ||
          qpc.qp_h.object_id != 32'h101)
        `uvm_error("QPC_CLONE", "QPC clone mutation reached source")
    end

    cqc = make_cqc("cqc");
    expect_ok("CQC_VALID", cqc.validate());
    cloned_object = cqc.clone();
    if (!$cast(cqc_clone, cloned_object))
      `uvm_error("CQC_CLONE", "CQC clone lost dynamic type")
    else if (cqc_clone.page_layout == cqc.page_layout ||
             cqc_clone.producer == cqc.producer ||
             cqc_clone.consumer == cqc.consumer)
      `uvm_error("CQC_CLONE", "CQC clone aliases nested layout or rings")
    else begin
      cqc_clone.page_layout.current_base.value += 64'h1000;
      cqc_clone.producer.index++;
      if (cqc.page_layout.current_base.value != 64'h0000_0000_0200_0000 ||
          cqc.producer.index != 9)
        `uvm_error("CQC_CLONE", "CQC clone mutation reached source")
    end

    mrt = make_mrt("mrt");
    expect_ok("MRT_VALID", mrt.validate());
    cloned_object = mrt.clone();
    if (!$cast(mrt_clone, cloned_object))
      `uvm_error("MRT_CLONE", "MRT clone lost dynamic type")
    else if (mrt_clone.page_layout == mrt.page_layout)
      `uvm_error("MRT_CLONE", "MRT clone aliases page layout")
    else begin
      mrt_clone.page_layout.pba0.value += 64'h1000;
      if (mrt.page_layout.pba0.value != 64'h0000_0000_0400_0000)
        `uvm_error("MRT_CLONE", "MRT clone mutation reached source")
    end

    srqc = make_srqc("srqc");
    expect_ok("SRQC_VALID", srqc.validate());
    cloned_object = srqc.clone();
    if (!$cast(srqc_clone, cloned_object))
      `uvm_error("SRQC_CLONE", "SRQC clone lost dynamic type")
    else if (srqc_clone.producer == srqc.producer)
      `uvm_error("SRQC_CLONE", "SRQC clone aliases producer position")
    else begin
      srqc_clone.producer.index++;
      if (srqc.producer.index != 5)
        `uvm_error("SRQC_CLONE", "SRQC clone mutation reached source")
    end

    ceqc = make_ceqc("ceqc");
    expect_ok("CEQC_VALID", ceqc.validate());
    cloned_object = ceqc.clone();
    if (!$cast(ceqc_clone, cloned_object))
      `uvm_error("CEQC_CLONE", "CEQC clone lost dynamic type")
    else if (ceqc_clone.page_layout == ceqc.page_layout ||
             ceqc_clone.producer == ceqc.producer ||
             ceqc_clone.consumer == ceqc.consumer)
      `uvm_error("CEQC_CLONE", "CEQC clone aliases nested values")
    else begin
      ceqc_clone.page_layout.next_base.value += 64'h1000;
      if (ceqc.page_layout.next_base.value != 64'h0000_0000_0300_0000)
        `uvm_error("CEQC_CLONE", "CEQC clone mutation reached source")
    end

    aeqc = make_aeqc("aeqc");
    expect_ok("AEQC_VALID", aeqc.validate());
    cloned_object = aeqc.clone();
    if (!$cast(aeqc_clone, cloned_object))
      `uvm_error("AEQC_CLONE", "AEQC clone lost dynamic type")
    else if (aeqc_clone.page_layout == aeqc.page_layout ||
             aeqc_clone.producer == aeqc.producer ||
             aeqc_clone.consumer == aeqc.consumer)
      `uvm_error("AEQC_CLONE", "AEQC clone aliases nested values")
    else begin
      aeqc_clone.consumer.index++;
      if (aeqc.consumer.index != 1)
        `uvm_error("AEQC_CLONE", "AEQC clone mutation reached source")
    end

    qpc.pd_h.kind = RDMA_RESOURCE_CQ;
    expect_invalid("HANDLE_KIND", qpc.validate());
    qpc.pd_h.kind = RDMA_RESOURCE_PD;
    qpc.recv_cq_h.function_uid++;
    expect_invalid("MIXED_FUNCTION_UID", qpc.validate());
    qpc.recv_cq_h.function_uid--;
    qpc.recv_cq_h.generation++;
    expect_invalid("MIXED_GENERATION", qpc.validate());
    qpc.recv_cq_h.generation--;

    qpc.sq_depth = 0;
    expect_invalid("ZERO_DEPTH", qpc.validate());
    qpc.sq_depth = 63;
    expect_invalid("NON_POWER_DEPTH", qpc.validate());
    qpc.sq_depth = 64;
    qpc.sq_backing.value++;
    expect_invalid("QUEUE_ALIGNMENT", qpc.validate());
    qpc.sq_backing.value--;
    qpc.context_backing.value += 64'h100;
    expect_invalid("CONTEXT_ALIGNMENT", qpc.validate());
    qpc.context_backing.value -= 64'h100;
    srqc.srfq_backing.value += 64;
    expect_invalid("SRQC_QUEUE_ALIGNMENT", srqc.validate());
    srqc.srfq_backing.value -= 64;

    urc_ext = rdma_qpc_urc_ext::type_id::create("urc_ext");
    urc_ext.remote_qpn = 24'h112233;
    urc_ext.rbsn = 24'h010203;
    urc_ext.dbsn = 24'h040506;
    urc_ext.rpsn = 24'h070809;
    urc_ext.dpsn = 24'h0a0b0c;
    urc_ext.path_mtu_bytes = 1024;
    urc_ext.rsq_backing.value = 64'h1600_0000;
    urc_ext.rdsq_backing.value = 64'h1700_0000;
    urc_ext.dsq_backing.value = 64'h1800_0000;
    urc_ext.fetch_threshold = 4;
    urc_ext.queue_threshold = 8;
    expect_ok("URC_EXT_VALID", urc_ext.validate());
    urc_ext.rsq_backing.value++;
    expect_invalid("URC_QUEUE_ALIGNMENT", urc_ext.validate());

    cqc.shadow_backing.value++;
    expect_invalid("SHADOW_ALIGNMENT", cqc.validate());
    cqc.shadow_backing.value--;
    cqc.producer.index = cqc.depth;
    expect_invalid("RING_INDEX", cqc.validate());
    cqc.producer.index = 9;
    cqc.state = rdma_context_state_e'(2'b11);
    expect_invalid("CONTEXT_STATE", cqc.validate());
    cqc.state = RDMA_CONTEXT_VALID;
    cqc.page_layout.current_base.value++;
    expect_invalid("NESTED_LAYOUT", cqc.validate());
    cqc.page_layout.current_base.value--;

    qpc.qp_h.object_id = 32'h001f_ffff;
    qpc.pd_h.object_id = 32'h0000_ffff;
    qpc.send_cq_h.object_id = 32'h000f_ffff;
    qpc.recv_cq_h.object_id = 32'h000f_ffff;
    qpc.srq_h.object_id = 32'h0000_7fff;
    expect_ok("QPC_ID_WIDTH_MAX", qpc.validate());
    qpc.qp_h.object_id = 32'h0020_0000;
    expect_invalid("QPC_QP_ID_WIDTH", qpc.validate());
    qpc.qp_h.object_id = 32'h001f_ffff;
    qpc.pd_h.object_id = 32'h0001_0000;
    expect_invalid("QPC_PD_ID_WIDTH", qpc.validate());
    qpc.pd_h.object_id = 32'h0000_ffff;
    qpc.send_cq_h.object_id = 32'h0010_0000;
    expect_invalid("QPC_SEND_CQ_ID_WIDTH", qpc.validate());
    qpc.send_cq_h.object_id = 32'h000f_ffff;
    qpc.recv_cq_h.object_id = 32'h0010_0000;
    expect_invalid("QPC_RECV_CQ_ID_WIDTH", qpc.validate());
    qpc.recv_cq_h.object_id = 32'h000f_ffff;
    qpc.srq_h.object_id = 32'h0000_8000;
    expect_invalid("QPC_SRQ_ID_WIDTH", qpc.validate());
    qpc.srq_h = null;
    expect_ok("QPC_OPTIONAL_SRQ", qpc.validate());
    qpc.qp_h.function_uid = '0;
    qpc.qp_h.generation = '0;
    expect_invalid("QPC_MIXED_ZERO_LIFECYCLE", qpc.validate());
    qpc.pd_h.function_uid = '0;
    qpc.pd_h.generation = '0;
    qpc.send_cq_h.function_uid = '0;
    qpc.send_cq_h.generation = '0;
    qpc.recv_cq_h.function_uid = '0;
    qpc.recv_cq_h.generation = '0;
    expect_ok("QPC_DECODE_LIFECYCLE", qpc.validate());

    cqc.cq_h.object_id = 32'h001f_ffff;
    cqc.ceq_h.object_id = 32'h0000_0fff;
    expect_ok("CQC_ID_WIDTH_MAX", cqc.validate());
    cqc.cq_h.object_id = 32'h0020_0000;
    expect_invalid("CQC_CQ_ID_WIDTH", cqc.validate());
    cqc.cq_h.object_id = 32'h001f_ffff;
    cqc.ceq_h.object_id = 32'h0000_1000;
    expect_invalid("CQC_CEQ_ID_WIDTH", cqc.validate());
    cqc.ceq_h = null;
    expect_ok("CQC_OPTIONAL_CEQ", cqc.validate());
    cqc.ceq_h = make_handle("cqc_decode_ceq", RDMA_RESOURCE_CEQ,
                            32'h0000_0fff);

    mrt.mr_h.object_id = 32'h00ff_ffff;
    mrt.pd_h.object_id = 32'h0000_ffff;
    mrt.lkey = 32'hffff_ff5a;
    mrt.rkey = mrt.lkey;
    expect_ok("MRT_ID_WIDTH_MAX", mrt.validate());
    mrt.mr_h.object_id = 32'h0100_0000;
    expect_invalid("MRT_MR_ID_WIDTH", mrt.validate());
    mrt.mr_h.object_id = 32'h00ff_ffff;
    mrt.pd_h.object_id = 32'h0001_0000;
    expect_invalid("MRT_PD_ID_WIDTH", mrt.validate());
    mrt.pd_h.object_id = 32'h0000_ffff;

    srqc.srq_h.object_id = 32'h0000_ffff;
    srqc.pd_h.object_id = 32'h0000_ffff;
    expect_ok("SRQC_ID_WIDTH_MAX", srqc.validate());
    srqc.srq_h.object_id = 32'h0001_0000;
    expect_invalid("SRQC_SRQ_ID_WIDTH", srqc.validate());
    srqc.srq_h.object_id = 32'h0000_ffff;
    srqc.pd_h.object_id = 32'h0001_0000;
    expect_invalid("SRQC_PD_ID_WIDTH", srqc.validate());
    srqc.pd_h.object_id = 32'h0000_ffff;

    ceqc.ceq_h.object_id = 32'h0000_0fff;
    expect_ok("CEQC_ID_WIDTH_MAX", ceqc.validate());
    ceqc.ceq_h.object_id = 32'h0000_1000;
    expect_invalid("CEQC_ID_WIDTH", ceqc.validate());
    ceqc.ceq_h.object_id = 32'h0000_0fff;
    aeqc.aeq_h.object_id = 32'h0000_0fff;
    expect_ok("AEQC_ID_WIDTH_MAX", aeqc.validate());
    aeqc.aeq_h.object_id = 32'h0000_1000;
    expect_invalid("AEQC_ID_WIDTH", aeqc.validate());
    aeqc.aeq_h.object_id = 32'h0000_0fff;

    mr_page_layout.pbl_mode = RDMA_MR_PBL1;
    mr_page_layout.pba1.value = 64'h5000_0000;
    expect_ok("PBL1_VALID", mr_page_layout.validate());
    mr_page_layout.pbl_mode = RDMA_MR_PBL2;
    mr_page_layout.pba0 = '0;
    mr_page_layout.pba1 = '0;
    mr_page_layout.first_pbl_index = 1;
    expect_ok("PBL2_VALID", mr_page_layout.validate());
    mr_page_layout.pbl_mode = rdma_mr_pbl_mode_e'(2'b11);
    expect_invalid("ILLEGAL_MODE", mr_page_layout.validate());
    mr_page_layout.pbl_mode = RDMA_MR_PBL0;
    mr_page_layout.pba0.value = 64'h4000_0000;
    mr_page_layout.first_pbl_index = 0;
    mr_page_layout.pba1.value = 64'h5000_0000;
    expect_invalid("CONTRADICTORY_PBL0", mr_page_layout.validate());
    mr_page_layout.pbl_mode = RDMA_MR_PBL1;
    mr_page_layout.first_pbl_index = 1;
    expect_invalid("CONTRADICTORY_PBL1", mr_page_layout.validate());
    mr_page_layout.pbl_mode = RDMA_MR_PBL2;
    mr_page_layout.pba0.value = 64'h4000_0000;
    mr_page_layout.pba1 = '0;
    mr_page_layout.first_pbl_index = 1;
    expect_invalid("CONTRADICTORY_PBL2", mr_page_layout.validate());

    mrt.length = 0;
    expect_invalid("MRT_ZERO_LENGTH", mrt.validate());
    mrt.length = 64'h0000_4000_0000_0000;
    expect_invalid("MRT_LENGTH_WIDTH", mrt.validate());
    mrt.length = 64'h2000;
    mrt.rkey ^= 32'h1;
    expect_invalid("MRT_KEYS", mrt.validate());
    mrt.rkey = mrt.lkey;
    mrt.mr_h.object_id--;
    expect_invalid("MRT_LKEY_INDEX", mrt.validate());
    mrt.mr_h.object_id++;
    mrt.access = '{local_write:1'b0, remote_read:1'b0,
                   remote_write:1'b1, memory_window_bind:1'b0,
                   remote_atomic:1'b0};
    mrt.rkey = mrt.lkey;
    expect_ok("MRT_REMOTE_WRITE", mrt.validate());
    if (mrt.access.local_write || !mrt.access.remote_write)
      `uvm_error("MRT_ACCESS_MUTATION", "MRT validation normalized access rights")
    mrt.access.remote_read = 1'b0;
    mrt.access.remote_write = 1'b0;
    mrt.access.remote_atomic = 1'b0;
    mrt.access.local_write = 1'b1;
    mrt.rkey = 0;
    expect_ok("MRT_LOCAL_ONLY", mrt.validate());
    if (!mrt.access.local_write || mrt.access.remote_write)
      `uvm_error("MRT_ACCESS_MUTATION", "MRT validation mutated access rights")

    cqc.cq_h.function_uid = '0;
    cqc.cq_h.generation = '0;
    cqc.ceq_h.function_uid = '0;
    cqc.ceq_h.generation = '0;
    expect_ok("DECODE_LIFECYCLE", cqc.validate());

    qp = rdma_qp::type_id::create("qp_runtime_owner");
    qp.sq_depth = 8;
    qp.rq_depth = 4;
    qp.sq_producer_index = 3;
    qp.sq_consumer_index = 1;
    qp.rq_producer_index = 2;
    qp.rq_consumer_index = 0;
    srq = rdma_srq::type_id::create("srq_runtime_owner");
    srq.depth = 8;
    srq.max_sge = 4;
    if (!qp.validate().ok() || !srq.validate().ok())
      `uvm_error("RUNTIME_OWNER", "QP/SRQ resources lost runtime state")

    if (qpc.describe() == "" || cqc.describe() == "" ||
        mrt.describe() == "" || srqc.describe() == "" ||
        ceqc.describe() == "" || aeqc.describe() == "")
      `uvm_error("CONTEXT_DESCRIBE", "context description is empty")

    phase.drop_objection(this);
  endtask
endclass
