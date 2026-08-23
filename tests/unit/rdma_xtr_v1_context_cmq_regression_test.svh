class rdma_xtr_v1_context_cmq_regression_test extends uvm_test;
  `uvm_component_utils(rdma_xtr_v1_context_cmq_regression_test)

  typedef enum int unsigned {
    E2E_BODY_QPC_CREATE,
    E2E_BODY_CQC_CREATE,
    E2E_BODY_MRT_KEY_ALLOC_PBL0,
    E2E_BODY_MRT_REGISTER_PBL0,
    E2E_BODY_MRT_REGISTER_PBL1,
    E2E_BODY_MRT_REGISTER_PBL2,
    E2E_BODY_SRQC_CREATE,
    E2E_BODY_CEQC_CREATE,
    E2E_BODY_AEQC_CREATE
  } rdma_xtr_v1_e2e_body_case_e;

  rdma_codec_registry qpc_registry;
  rdma_codec_registry context_registry;
  rdma_xtr_v1_cmq_request_composer composer;
  rdma_xtr_v1_cmq_completion_codec completion_codec;
  rdma_hw_image artifact_actual[$];
  rdma_hw_image artifact_snapshot[$];
  string artifact_label[$];

  function new(string name = "rdma_xtr_v1_context_cmq_regression_test",
               uvm_component parent = null);
    super.new(name, parent);
  endfunction

  function automatic void expect_status(
    string label,
    rdma_status status,
    rdma_status_code_e expected
  );
    if (status == null)
      `uvm_error(label, "operation returned a null status")
    else if (status.code != expected)
      `uvm_error(label,
                 $sformatf("expected %s, got %s (%s)", expected.name(),
                           status.code.name(), status.convert2string()))
  endfunction

  function automatic void expect_ok(string label, rdma_status status);
    expect_status(label, status, RDMA_SC_OK);
  endfunction

  function automatic bit require_ok(string label, rdma_status status);
    expect_ok(label, status);
    return status != null && status.ok();
  endfunction

  function automatic bit require_status(
    string label,
    rdma_status status,
    rdma_status_code_e expected
  );
    expect_status(label, status, expected);
    return status != null && status.code == expected;
  endfunction

  function automatic rdma_handle make_handle(
    string name,
    rdma_resource_kind_e kind,
    int unsigned object_id,
    longint unsigned function_uid = 64'h1122_3344_5566_7788,
    int unsigned generation = 9
  );
    rdma_handle handle;
    handle = rdma_handle::type_id::create(name);
    handle.kind = kind;
    handle.object_id = object_id;
    handle.function_uid = function_uid;
    handle.generation = generation;
    return handle;
  endfunction

  function automatic rdma_page_table_layout make_boundary_page_layout(
    string name,
    rdma_object_mode_e mode
  );
    rdma_page_table_layout layout;
    layout = rdma_page_table_layout::type_id::create(name);
    layout.mode = mode;
    layout.sd_base.value = 64'hffff_ffff_ffff_f000;
    layout.current_base.value = 64'hffff_ffff_ffff_f000;
    layout.current_valid = 1'b1;
    layout.next_base.value = 64'hffff_ffff_ffff_f000;
    layout.next_valid = 1'b1;
    return layout;
  endfunction

  function automatic rdma_ring_position make_ring(
    string name,
    int unsigned index,
    bit wrap
  );
    rdma_ring_position ring;
    ring = rdma_ring_position::type_id::create(name);
    ring.index = index;
    ring.wrap = wrap;
    return ring;
  endfunction

  function automatic void set_common_qpc_handles(
    rdma_qpc_model qpc,
    int unsigned qpn,
    int unsigned pd_id,
    int unsigned send_cq_id,
    int unsigned recv_cq_id,
    int signed srq_id = -1
  );
    qpc.qp_h = make_handle({qpc.get_name(), "_qp"}, RDMA_RESOURCE_QP, qpn);
    qpc.pd_h = make_handle({qpc.get_name(), "_pd"}, RDMA_RESOURCE_PD,
                           pd_id);
    qpc.send_cq_h = make_handle({qpc.get_name(), "_scq"}, RDMA_RESOURCE_CQ,
                                send_cq_id);
    qpc.recv_cq_h = make_handle({qpc.get_name(), "_rcq"}, RDMA_RESOURCE_CQ,
                                recv_cq_id);
    if (srq_id >= 0)
      qpc.srq_h = make_handle({qpc.get_name(), "_srq"}, RDMA_RESOURCE_SRQ,
                              int'(srq_id));
    else
      qpc.srq_h = null;
  endfunction

  function automatic rdma_qpc_model make_rc(string name = "e2e_rc_qpc");
    rdma_qpc_model qpc;
    rdma_qpc_rc_ext ext;
    qpc = rdma_qpc_model::type_id::create(name);
    set_common_qpc_handles(qpc, 21'h15555, 16'ha55a, 20'habcde,
                           20'h54321, 15'h4567);
    qpc.transport = RDMA_TRANSPORT_RC;
    qpc.state = RDMA_QPS_RTS;
    qpc.host_id = 5;
    qpc.vf_id = 12'habc;
    qpc.stat_index = 8'ha5;
    qpc.pkey = 16'hbeef;
    qpc.qp_sequence = 8'hc3;
    qpc.access = '{local_write:1'b1, remote_read:1'b1,
                   remote_write:1'b1, memory_window_bind:1'b1,
                   remote_atomic:1'b1};
    qpc.path_mtu_bytes = 8192;
    qpc.sq_depth = 1 << 11;
    qpc.rq_depth = 1 << 10;
    qpc.sq_backing.value = 64'h1234_5678_9abcd000;
    qpc.rq_backing.value = 64'h0fed_cba9_8765_4000;
    qpc.context_backing.value = 64'h123_4567_89ab << 9;
    qpc.sq_mode = RDMA_OBJECT_HUGE_2M;
    qpc.rq_mode = RDMA_OBJECT_INDIRECT_4K;
    qpc.signature_enable = 1'b1;
    qpc.tx_flow_control = 1'b1;
    qpc.rx_flow_control = 1'b1;
    qpc.behavior.transport_version = 1;
    qpc.behavior.migration_enable = 1'b1;
    qpc.behavior.tx_endian_swap = 1'b1;
    qpc.behavior.rx_endian_swap = 1'b1;
    qpc.behavior.read_after_write_fence = 1'b1;
    qpc.behavior.atomic_after_atomic_fence = 1'b1;
    qpc.behavior.\priority = 0;
    qpc.address_vector.traffic_class = 8'haa;
    qpc.address_vector.destination_mac = 48'h1122_3344_5566;
    qpc.address_vector.vlan_id = 12'habc;
    qpc.address_vector.flow_label = 20'habcde;
    qpc.address_vector.hop_limit = 8'h40;
    qpc.address_vector.udp_source_port = 16'hc123;
    ext = rdma_qpc_rc_ext::type_id::create({name, "_ext"});
    ext.remote_qpn = 24'h654321;
    ext.send_psn = 24'habcdef;
    ext.recv_psn = 24'h123456;
    ext.retry_count = 7;
    ext.rnr_retry_count = 7;
    qpc.transport_ext = ext;
    return qpc;
  endfunction

  function automatic rdma_qpc_model make_ud(string name = "e2e_ud_qpc");
    rdma_qpc_model qpc;
    rdma_qpc_ud_ext ext;
    byte unsigned ip[16] = '{8'h20,8'h01,8'h0d,8'hb8,
                              8'h00,8'h00,8'h00,8'h00,
                              8'h00,8'h00,8'h00,8'h00,
                              8'h00,8'h00,8'h00,8'h01};
    qpc = rdma_qpc_model::type_id::create(name);
    set_common_qpc_handles(qpc, 21'h2aaaa, 16'h5aa5, 20'h13579,
                           20'h2468a);
    qpc.transport = RDMA_TRANSPORT_UD;
    qpc.state = RDMA_QPS_RTS;
    qpc.host_id = 6;
    qpc.vf_id = 12'h345;
    qpc.stat_index = 8'h5a;
    qpc.pkey = 16'h1234;
    qpc.qp_sequence = 8'h7e;
    qpc.path_mtu_bytes = 4096;
    qpc.sq_depth = 1 << 9;
    qpc.rq_depth = 1 << 8;
    qpc.sq_backing.value = 64'h1111_1222_2233_3000;
    qpc.rq_backing.value = 64'h4444_4555_5566_6000;
    qpc.context_backing.value = 64'h0fed_cba9_876 << 9;
    qpc.sq_mode = RDMA_OBJECT_L3_INDIRECT_4K;
    qpc.rq_mode = RDMA_OBJECT_HUGE_2M;
    qpc.signature_enable = 1'b0;
    qpc.tx_flow_control = 1'b0;
    qpc.rx_flow_control = 1'b0;
    qpc.behavior.transport_version = 1;
    qpc.behavior.migration_enable = 1'b0;
    qpc.behavior.tx_endian_swap = 1'b1;
    qpc.behavior.rx_endian_swap = 1'b1;
    qpc.behavior.read_after_write_fence = 1'b0;
    qpc.behavior.atomic_after_atomic_fence = 1'b0;
    qpc.behavior.\priority = 5;
    qpc.address_vector.traffic_class = 8'hac;
    qpc.address_vector.vlan_enable = 1'b1;
    qpc.address_vector.ipv6 = 1'b1;
    qpc.address_vector.tunnel_enable = 1'b1;
    qpc.address_vector.lag_enable = 1'b1;
    qpc.address_vector.forwarding_enable = 1'b1;
    qpc.address_vector.destination_vport = 11'h456;
    qpc.address_vector.source_address_index = 12'habc;
    qpc.address_vector.destination_port = 4'hb;
    qpc.address_vector.destination_mac = 48'ha1b2_c3d4_e5f6;
    qpc.address_vector.cfi = 1'b1;
    qpc.address_vector.vlan_id = 12'h789;
    qpc.address_vector.source_vport = 11'h345;
    qpc.address_vector.flow_label = 20'h54321;
    qpc.address_vector.hop_limit = 8'h7f;
    qpc.address_vector.udp_source_port = 16'hbeef;
    foreach (ip[i]) qpc.address_vector.destination_ip[i] = ip[i];
    ext = rdma_qpc_ud_ext::type_id::create({name, "_ext"});
    ext.qkey = 32'h89abcdef;
    qpc.transport_ext = ext;
    return qpc;
  endfunction

  function automatic rdma_qpc_model make_urc(string name = "e2e_urc_qpc");
    rdma_qpc_model qpc;
    rdma_qpc_urc_ext ext;
    qpc = rdma_qpc_model::type_id::create(name);
    set_common_qpc_handles(qpc, 21'h3ffff, 16'hffff, 20'hfffff,
                           20'habcde);
    qpc.transport = RDMA_TRANSPORT_URC;
    qpc.state = RDMA_QPS_RTS;
    qpc.host_id = 7;
    qpc.vf_id = 12'h789;
    qpc.stat_index = 8'hff;
    qpc.pkey = 16'habcd;
    qpc.qp_sequence = 8'hfe;
    qpc.access = '0;
    qpc.path_mtu_bytes = 8192;
    qpc.sq_depth = 32768;
    qpc.rq_depth = 16384;
    qpc.sq_backing.value = 64'h4567_89ab_cdef_0000;
    qpc.rq_backing.value = 64'h5678_9abc_def0_1000;
    qpc.context_backing.value = 64'h2468_acf1_35600;
    qpc.sq_mode = RDMA_OBJECT_L3_INDIRECT_4K;
    qpc.rq_mode = RDMA_OBJECT_HUGE_2M;
    qpc.signature_enable = 1'b0;
    qpc.tx_flow_control = 1'b0;
    qpc.rx_flow_control = 1'b0;
    qpc.behavior.transport_version = 1;
    qpc.behavior.migration_enable = 1'b1;
    qpc.behavior.tx_endian_swap = 1'b0;
    qpc.behavior.rx_endian_swap = 1'b0;
    qpc.behavior.read_after_write_fence = 1'b0;
    qpc.behavior.atomic_after_atomic_fence = 1'b0;
    qpc.behavior.\priority = 0;
    qpc.address_vector.traffic_class = 8'hfe;
    ext = rdma_qpc_urc_ext::type_id::create({name, "_ext"});
    ext.remote_qpn = 24'h654321;
    ext.rbsn = 24'habcdef;
    ext.dbsn = 24'h654321;
    ext.rpsn = 24'h56789a;
    ext.dpsn = 24'h456789;
    ext.queues.rsq_backing.value = 64'h1234_5678_9abcd000;
    ext.queues.rdsq_backing.value = 64'h2345_6789_abcde000;
    ext.queues.dsq_backing.value = 64'h3456_789a_bcdef000;
    ext.queues.rsq_depth = 64;
    ext.queues.rdsq_depth = 64;
    ext.queues.rdsq_fetch_count = 8;
    ext.queues.dsq_fetch_count = 8;
    ext.queues.rq_sequence_threshold_entries = 2048;
    ext.queues.sq_completion_threshold_entries = 4096;
    qpc.transport_ext = ext;
    return qpc;
  endfunction

  function automatic rdma_cqc_model make_cqc(string name = "e2e_cqc");
    rdma_cqc_model cqc;
    cqc = rdma_cqc_model::type_id::create(name);
    cqc.cq_h = make_handle({name, "_cq"}, RDMA_RESOURCE_CQ, 21'h1f_ffff);
    cqc.ceq_h = make_handle({name, "_ceq"}, RDMA_RESOURCE_CEQ, 12'hfff);
    cqc.state = RDMA_CONTEXT_ERROR;
    cqc.depth = 32'h8000_0000;
    cqc.cqe_size_bytes = 128;
    cqc.threshold = 7;
    cqc.page_layout = make_boundary_page_layout({name, "_layout"},
                                                RDMA_OBJECT_L3_INDIRECT_4K);
    cqc.producer = make_ring({name, "_producer"}, 23'h7f_ffff, 1'b1);
    cqc.consumer = make_ring({name, "_consumer"}, 23'h7f_ffff, 1'b1);
    cqc.urc_enable = 1'b1;
    cqc.load_ci_done = 1'b1;
    cqc.last_arm_sequence = 2'd3;
    cqc.arm_sequence = 2'd3;
    cqc.arm_state = 2'd2;
    cqc.shadow_backing.value = 64'hffff_ffff_ffff_ffc0;
    return cqc;
  endfunction

  function automatic rdma_mrt_model make_mrt(
    string name,
    rdma_mr_pbl_mode_e pbl_mode
  );
    rdma_mrt_model mrt;
    mrt = rdma_mrt_model::type_id::create(name);
    mrt.mr_h = make_handle({name, "_mr"}, RDMA_RESOURCE_MR, 24'hff_ffff);
    mrt.pd_h = make_handle({name, "_pd"}, RDMA_RESOURCE_PD, 16'hffff);
    mrt.state = RDMA_CONTEXT_VALID;
    mrt.iova.value = 64'hffff_ffff_ffff_ffff;
    mrt.length = 64'h0000_3fff_ffff_ffff;
    mrt.lkey = 32'hffff_ffff;
    mrt.rkey = mrt.lkey;
    mrt.access = '{local_write:1'b1, remote_read:1'b1,
                   remote_write:1'b1, memory_window_bind:1'b1,
                   remote_atomic:1'b1};
    mrt.object_type = 2'd2;
    mrt.page_layout.pbl_mode = pbl_mode;
    mrt.page_layout.host_page_size = RDMA_MR_PAGE_1G;
    mrt.page_layout.address_mode = RDMA_MR_ADDRESS_ZERO_BASED;
    mrt.page_layout.odp = 1'b1;
    mrt.page_layout.invalidate_enable = 1'b1;
    mrt.page_layout.payload_vf_enable = 1'b1;
    mrt.page_layout.payload_vf_id = 8'hff;
    mrt.page_layout.mr_serial = 12'hfff;
    case (pbl_mode)
      RDMA_MR_PBL0:
        mrt.page_layout.pba0.value = 64'hffff_ffff_ffff_f000;
      RDMA_MR_PBL1: begin
        mrt.page_layout.pba0.value = 64'hffff_ffff_ffff_f000;
        mrt.page_layout.pba1.value = 64'hffff_ffff_ffff_f000;
      end
      RDMA_MR_PBL2:
        mrt.page_layout.first_pbl_index = 28'hfff_ffff;
    endcase
    return mrt;
  endfunction

  function automatic rdma_srqc_model make_srqc(string name = "e2e_srqc");
    rdma_srqc_model srqc;
    srqc = rdma_srqc_model::type_id::create(name);
    srqc.srq_h = make_handle({name, "_srq"}, RDMA_RESOURCE_SRQ, 16'hffff);
    srqc.pd_h = make_handle({name, "_pd"}, RDMA_RESOURCE_PD, 16'hffff);
    srqc.state = RDMA_CONTEXT_ERROR;
    srqc.depth = 1 << 15;
    srqc.load_pi_threshold = 8'hff;
    srqc.limit_threshold = 14'h3fff;
    srqc.object_mode = RDMA_OBJECT_L3_INDIRECT_4K;
    srqc.srfq_backing.value = 64'hffff_ffff_ffff_f000;
    srqc.shadow_backing.value = 64'hffff_ffff_ffff_f000;
    srqc.producer = make_ring({name, "_producer"}, 15'h7fff, 1'b1);
    srqc.arm_sequence = 2'd3;
    return srqc;
  endfunction

  function automatic rdma_ceqc_model make_ceqc(string name = "e2e_ceqc");
    rdma_ceqc_model ceqc;
    ceqc = rdma_ceqc_model::type_id::create(name);
    ceqc.ceq_h = make_handle({name, "_ceq"}, RDMA_RESOURCE_CEQ, 12'hfff);
    ceqc.state = RDMA_CONTEXT_ERROR;
    ceqc.depth = 32'h8000_0000;
    ceqc.vector_id = 16'hffff;
    ceqc.page_layout = make_boundary_page_layout({name, "_layout"},
                                                 RDMA_OBJECT_L3_INDIRECT_4K);
    ceqc.page_layout.sd_base = '0;
    ceqc.producer = make_ring({name, "_producer"}, 18'h3ffff, 1'b1);
    ceqc.consumer = make_ring({name, "_consumer"}, 18'h3ffff, 1'b1);
    return ceqc;
  endfunction

  function automatic rdma_aeqc_model make_aeqc(string name = "e2e_aeqc");
    rdma_aeqc_model aeqc;
    aeqc = rdma_aeqc_model::type_id::create(name);
    aeqc.aeq_h = make_handle({name, "_aeq"}, RDMA_RESOURCE_AEQ, 12'hfff);
    aeqc.state = RDMA_CONTEXT_ERROR;
    aeqc.depth = 32'h8000_0000;
    aeqc.vector_id = 16'hffff;
    aeqc.page_layout = make_boundary_page_layout({name, "_layout"},
                                                 RDMA_OBJECT_L3_INDIRECT_4K);
    aeqc.page_layout.sd_base = '0;
    aeqc.producer = make_ring({name, "_producer"}, 18'h3ffff, 1'b1);
    aeqc.consumer = make_ring({name, "_consumer"}, 18'h3ffff, 1'b1);
    return aeqc;
  endfunction

  function automatic rdma_codec_key qpc_key(string variant);
    rdma_codec_key key;
    key.hw_version = "xtr_v1";
    key.image_kind = RDMA_IMAGE_QPC;
    key.object_type = "qpc";
    key.variant = variant;
    key.opcode = XTR_V1_OP_QPC_CREATE;
    return key;
  endfunction

  function automatic rdma_codec_key body_key(
    rdma_image_kind_e image_kind,
    string object_type,
    string variant,
    bit [7:0] opcode
  );
    rdma_codec_key key;
    key.hw_version = "xtr_v1";
    key.image_kind = image_kind;
    key.object_type = object_type;
    key.variant = variant;
    key.opcode = opcode;
    return key;
  endfunction

  function automatic rdma_xtr_v1_golden_case find_golden(
    rdma_xtr_v1_golden_case cases[$],
    string name
  );
    foreach (cases[i])
      if (cases[i].name == name) return cases[i];
    return null;
  endfunction

  function automatic rdma_hw_model clone_model(
    rdma_hw_model source,
    string label
  );
    uvm_object cloned;
    rdma_hw_model copy;
    if (source == null) begin
      `uvm_error(label, "cannot clone a null model")
      return null;
    end
    cloned = source.clone();
    if (cloned == null || !$cast(copy, cloned)) begin
      `uvm_error(label, "model clone failed")
      return null;
    end
    return copy;
  endfunction

  function automatic rdma_hw_image clone_image(
    rdma_hw_image source,
    string label
  );
    uvm_object cloned;
    rdma_hw_image copy;
    if (source == null) begin
      `uvm_error(label, "cannot clone a null image")
      return null;
    end
    cloned = source.clone();
    if (cloned == null || !$cast(copy, cloned)) begin
      `uvm_error(label, "image clone failed")
      return null;
    end
    return copy;
  endfunction

  function automatic bit handles_equal(rdma_handle lhs, rdma_handle rhs);
    if (lhs == null || rhs == null) return lhs == rhs;
    return lhs.same_instance(rhs);
  endfunction

  function automatic bit rings_equal(
    rdma_ring_position lhs,
    rdma_ring_position rhs
  );
    if (lhs == null || rhs == null) return lhs == rhs;
    return lhs.index == rhs.index && lhs.wrap == rhs.wrap;
  endfunction

  function automatic bit page_layouts_equal(
    rdma_page_table_layout lhs,
    rdma_page_table_layout rhs
  );
    if (lhs == null || rhs == null) return lhs == rhs;
    return lhs.mode == rhs.mode && lhs.sd_base.value == rhs.sd_base.value &&
           lhs.current_base.value == rhs.current_base.value &&
           lhs.current_valid == rhs.current_valid &&
           lhs.next_base.value == rhs.next_base.value &&
           lhs.next_valid == rhs.next_valid;
  endfunction

  function automatic bit mr_layouts_equal(
    rdma_mr_page_layout lhs,
    rdma_mr_page_layout rhs
  );
    if (lhs == null || rhs == null) return lhs == rhs;
    return lhs.pbl_mode == rhs.pbl_mode &&
           lhs.host_page_size == rhs.host_page_size &&
           lhs.pba0.value == rhs.pba0.value &&
           lhs.pba1.value == rhs.pba1.value &&
           lhs.first_pbl_index == rhs.first_pbl_index &&
           lhs.address_mode == rhs.address_mode && lhs.odp == rhs.odp &&
           lhs.invalidate_enable == rhs.invalidate_enable &&
           lhs.payload_vf_enable == rhs.payload_vf_enable &&
           lhs.payload_vf_id == rhs.payload_vf_id &&
           lhs.mr_serial == rhs.mr_serial;
  endfunction

  function automatic bit address_vectors_equal(
    rdma_address_vector lhs,
    rdma_address_vector rhs
  );
    if (lhs == null || rhs == null) return lhs == rhs;
    if (lhs.source_address_index != rhs.source_address_index ||
        lhs.source_vport != rhs.source_vport ||
        lhs.destination_vport != rhs.destination_vport ||
        lhs.destination_port != rhs.destination_port ||
        lhs.destination_mac != rhs.destination_mac || lhs.ipv6 != rhs.ipv6 ||
        lhs.vlan_enable != rhs.vlan_enable || lhs.cfi != rhs.cfi ||
        lhs.lag_enable != rhs.lag_enable ||
        lhs.tunnel_enable != rhs.tunnel_enable ||
        lhs.forwarding_enable != rhs.forwarding_enable ||
        lhs.vlan_id != rhs.vlan_id ||
        lhs.traffic_class != rhs.traffic_class ||
        lhs.flow_label != rhs.flow_label || lhs.hop_limit != rhs.hop_limit ||
        lhs.udp_source_port != rhs.udp_source_port)
      return 1'b0;
    foreach (lhs.destination_ip[i])
      if (lhs.destination_ip[i] != rhs.destination_ip[i]) return 1'b0;
    return 1'b1;
  endfunction

  function automatic bit qpc_extensions_equal(
    rdma_qpc_transport_ext lhs,
    rdma_qpc_transport_ext rhs
  );
    rdma_qpc_rc_ext lhs_rc;
    rdma_qpc_rc_ext rhs_rc;
    rdma_qpc_ud_ext lhs_ud;
    rdma_qpc_ud_ext rhs_ud;
    rdma_qpc_urc_ext lhs_urc;
    rdma_qpc_urc_ext rhs_urc;
    if (lhs == null || rhs == null) return lhs == rhs;
    if ($cast(lhs_rc, lhs) && $cast(rhs_rc, rhs))
      return lhs_rc.remote_qpn == rhs_rc.remote_qpn &&
             lhs_rc.send_psn == rhs_rc.send_psn &&
             lhs_rc.recv_psn == rhs_rc.recv_psn &&
             lhs_rc.retry_count == rhs_rc.retry_count &&
             lhs_rc.rnr_retry_count == rhs_rc.rnr_retry_count;
    if ($cast(lhs_ud, lhs) && $cast(rhs_ud, rhs))
      return lhs_ud.qkey == rhs_ud.qkey;
    if ($cast(lhs_urc, lhs) && $cast(rhs_urc, rhs)) begin
      if (lhs_urc.queues == null || rhs_urc.queues == null)
        return lhs_urc.queues == rhs_urc.queues;
      return lhs_urc.remote_qpn == rhs_urc.remote_qpn &&
             lhs_urc.rbsn == rhs_urc.rbsn &&
             lhs_urc.dbsn == rhs_urc.dbsn &&
             lhs_urc.rpsn == rhs_urc.rpsn &&
             lhs_urc.dpsn == rhs_urc.dpsn &&
             lhs_urc.queues.rsq_backing.value ==
               rhs_urc.queues.rsq_backing.value &&
             lhs_urc.queues.rdsq_backing.value ==
               rhs_urc.queues.rdsq_backing.value &&
             lhs_urc.queues.dsq_backing.value ==
               rhs_urc.queues.dsq_backing.value &&
             lhs_urc.queues.rsq_depth == rhs_urc.queues.rsq_depth &&
             lhs_urc.queues.rdsq_depth == rhs_urc.queues.rdsq_depth &&
             lhs_urc.queues.rdsq_fetch_count ==
               rhs_urc.queues.rdsq_fetch_count &&
             lhs_urc.queues.dsq_fetch_count ==
               rhs_urc.queues.dsq_fetch_count &&
             lhs_urc.queues.rq_sequence_threshold_entries ==
               rhs_urc.queues.rq_sequence_threshold_entries &&
             lhs_urc.queues.sq_completion_threshold_entries ==
               rhs_urc.queues.sq_completion_threshold_entries;
    end
    return 1'b0;
  endfunction

  function automatic bit qpcs_equal(rdma_qpc_model lhs,
                                      rdma_qpc_model rhs);
    if (lhs == null || rhs == null) return lhs == rhs;
    if (!handles_equal(lhs.qp_h, rhs.qp_h) ||
        !handles_equal(lhs.pd_h, rhs.pd_h) ||
        !handles_equal(lhs.send_cq_h, rhs.send_cq_h) ||
        !handles_equal(lhs.recv_cq_h, rhs.recv_cq_h) ||
        !handles_equal(lhs.srq_h, rhs.srq_h) ||
        lhs.transport != rhs.transport || lhs.state != rhs.state ||
        lhs.host_id != rhs.host_id || lhs.vf_id != rhs.vf_id ||
        lhs.stat_index != rhs.stat_index || lhs.pkey != rhs.pkey ||
        lhs.qp_sequence != rhs.qp_sequence || lhs.access != rhs.access ||
        lhs.path_mtu_bytes != rhs.path_mtu_bytes ||
        lhs.sq_depth != rhs.sq_depth || lhs.rq_depth != rhs.rq_depth ||
        lhs.sq_backing.value != rhs.sq_backing.value ||
        lhs.rq_backing.value != rhs.rq_backing.value ||
        lhs.context_backing.value != rhs.context_backing.value ||
        lhs.sq_mode != rhs.sq_mode || lhs.rq_mode != rhs.rq_mode ||
        !address_vectors_equal(lhs.address_vector, rhs.address_vector) ||
        lhs.signature_enable != rhs.signature_enable ||
        lhs.tx_flow_control != rhs.tx_flow_control ||
        lhs.rx_flow_control != rhs.rx_flow_control ||
        lhs.behavior == null || rhs.behavior == null)
      return 1'b0;
    if (lhs.behavior.transport_version != rhs.behavior.transport_version ||
        lhs.behavior.migration_enable != rhs.behavior.migration_enable ||
        lhs.behavior.tx_endian_swap != rhs.behavior.tx_endian_swap ||
        lhs.behavior.rx_endian_swap != rhs.behavior.rx_endian_swap ||
        lhs.behavior.read_after_write_fence !=
          rhs.behavior.read_after_write_fence ||
        lhs.behavior.atomic_after_atomic_fence !=
          rhs.behavior.atomic_after_atomic_fence ||
        lhs.behavior.\priority != rhs.behavior.\priority )
      return 1'b0;
    return qpc_extensions_equal(lhs.transport_ext, rhs.transport_ext);
  endfunction

  function automatic bit models_equal(rdma_hw_model lhs,
                                        rdma_hw_model rhs);
    rdma_qpc_model lhs_qpc;
    rdma_qpc_model rhs_qpc;
    rdma_cqc_model lhs_cqc;
    rdma_cqc_model rhs_cqc;
    rdma_mrt_model lhs_mrt;
    rdma_mrt_model rhs_mrt;
    rdma_srqc_model lhs_srqc;
    rdma_srqc_model rhs_srqc;
    rdma_ceqc_model lhs_ceqc;
    rdma_ceqc_model rhs_ceqc;
    rdma_aeqc_model lhs_aeqc;
    rdma_aeqc_model rhs_aeqc;
    rdma_xtr_v1_qpc_command_body lhs_cmd;
    rdma_xtr_v1_qpc_command_body rhs_cmd;

    if (lhs == null || rhs == null) return lhs == rhs;
    if ($cast(lhs_qpc, lhs) && $cast(rhs_qpc, rhs))
      return qpcs_equal(lhs_qpc, rhs_qpc);
    if ($cast(lhs_cqc, lhs) && $cast(rhs_cqc, rhs))
      return handles_equal(lhs_cqc.cq_h, rhs_cqc.cq_h) &&
             handles_equal(lhs_cqc.ceq_h, rhs_cqc.ceq_h) &&
             lhs_cqc.state == rhs_cqc.state &&
             lhs_cqc.depth == rhs_cqc.depth &&
             lhs_cqc.cqe_size_bytes == rhs_cqc.cqe_size_bytes &&
             lhs_cqc.threshold == rhs_cqc.threshold &&
             page_layouts_equal(lhs_cqc.page_layout, rhs_cqc.page_layout) &&
             rings_equal(lhs_cqc.producer, rhs_cqc.producer) &&
             rings_equal(lhs_cqc.consumer, rhs_cqc.consumer) &&
             lhs_cqc.urc_enable == rhs_cqc.urc_enable &&
             lhs_cqc.load_ci_done == rhs_cqc.load_ci_done &&
             lhs_cqc.last_arm_sequence == rhs_cqc.last_arm_sequence &&
             lhs_cqc.arm_sequence == rhs_cqc.arm_sequence &&
             lhs_cqc.arm_state == rhs_cqc.arm_state &&
             lhs_cqc.shadow_backing.value == rhs_cqc.shadow_backing.value;
    if ($cast(lhs_mrt, lhs) && $cast(rhs_mrt, rhs))
      return handles_equal(lhs_mrt.mr_h, rhs_mrt.mr_h) &&
             handles_equal(lhs_mrt.pd_h, rhs_mrt.pd_h) &&
             lhs_mrt.state == rhs_mrt.state &&
             lhs_mrt.iova.value == rhs_mrt.iova.value &&
             lhs_mrt.length == rhs_mrt.length &&
             lhs_mrt.lkey == rhs_mrt.lkey && lhs_mrt.rkey == rhs_mrt.rkey &&
             lhs_mrt.access == rhs_mrt.access &&
             lhs_mrt.object_type == rhs_mrt.object_type &&
             mr_layouts_equal(lhs_mrt.page_layout, rhs_mrt.page_layout);
    if ($cast(lhs_srqc, lhs) && $cast(rhs_srqc, rhs))
      return handles_equal(lhs_srqc.srq_h, rhs_srqc.srq_h) &&
             handles_equal(lhs_srqc.pd_h, rhs_srqc.pd_h) &&
             lhs_srqc.state == rhs_srqc.state &&
             lhs_srqc.depth == rhs_srqc.depth &&
             lhs_srqc.load_pi_threshold == rhs_srqc.load_pi_threshold &&
             lhs_srqc.limit_threshold == rhs_srqc.limit_threshold &&
             lhs_srqc.object_mode == rhs_srqc.object_mode &&
             lhs_srqc.srfq_backing.value == rhs_srqc.srfq_backing.value &&
             lhs_srqc.shadow_backing.value ==
               rhs_srqc.shadow_backing.value &&
             rings_equal(lhs_srqc.producer, rhs_srqc.producer) &&
             lhs_srqc.arm_sequence == rhs_srqc.arm_sequence;
    if ($cast(lhs_ceqc, lhs) && $cast(rhs_ceqc, rhs))
      return handles_equal(lhs_ceqc.ceq_h, rhs_ceqc.ceq_h) &&
             lhs_ceqc.state == rhs_ceqc.state &&
             lhs_ceqc.depth == rhs_ceqc.depth &&
             lhs_ceqc.vector_id == rhs_ceqc.vector_id &&
             page_layouts_equal(lhs_ceqc.page_layout,
                                rhs_ceqc.page_layout) &&
             rings_equal(lhs_ceqc.producer, rhs_ceqc.producer) &&
             rings_equal(lhs_ceqc.consumer, rhs_ceqc.consumer);
    if ($cast(lhs_aeqc, lhs) && $cast(rhs_aeqc, rhs))
      return handles_equal(lhs_aeqc.aeq_h, rhs_aeqc.aeq_h) &&
             lhs_aeqc.state == rhs_aeqc.state &&
             lhs_aeqc.depth == rhs_aeqc.depth &&
             lhs_aeqc.vector_id == rhs_aeqc.vector_id &&
             page_layouts_equal(lhs_aeqc.page_layout,
                                rhs_aeqc.page_layout) &&
             rings_equal(lhs_aeqc.producer, rhs_aeqc.producer) &&
             rings_equal(lhs_aeqc.consumer, rhs_aeqc.consumer);
    if ($cast(lhs_cmd, lhs) && $cast(rhs_cmd, rhs)) begin
      if (!handles_equal(lhs_cmd.qp_h, rhs_cmd.qp_h) ||
          !handles_equal(lhs_cmd.send_cq_h, rhs_cmd.send_cq_h) ||
          !handles_equal(lhs_cmd.recv_cq_h, rhs_cmd.recv_cq_h) ||
          lhs_cmd.qpc_buffer.value != rhs_cmd.qpc_buffer.value ||
          lhs_cmd.next_state != rhs_cmd.next_state ||
          lhs_cmd.full_modify != rhs_cmd.full_modify ||
          lhs_cmd.partial_modify != rhs_cmd.partial_modify ||
          lhs_cmd.wbe_template_count != rhs_cmd.wbe_template_count)
        return 1'b0;
      foreach (lhs_cmd.modify_start_qword[i])
        if (lhs_cmd.modify_start_qword[i] !=
              rhs_cmd.modify_start_qword[i] ||
            lhs_cmd.modify_wbe[i] != rhs_cmd.modify_wbe[i] ||
            lhs_cmd.modify_data[i] != rhs_cmd.modify_data[i])
          return 1'b0;
      return 1'b1;
    end
    return 1'b0;
  endfunction

  function automatic bit expect_model_unchanged(
    string label,
    rdma_hw_model actual,
    rdma_hw_model snapshot
  );
    if (actual == null || snapshot == null) begin
      `uvm_error(label, "model immutable check received null")
      return 1'b0;
    end
    if (actual == snapshot) begin
      `uvm_error(label, "model snapshot aliases the input")
      return 1'b0;
    end
    if (!models_equal(actual, snapshot)) begin
      `uvm_error(label, "operation mutated an input model value")
      return 1'b0;
    end
    return 1'b1;
  endfunction

  function automatic bit images_equal(rdma_hw_image lhs, rdma_hw_image rhs);
    if (lhs == null || rhs == null || lhs == rhs ||
        lhs.length != rhs.length || lhs.alignment != rhs.alignment ||
        lhs.endian != rhs.endian || lhs.image_kind != rhs.image_kind ||
        lhs.hardware_version != rhs.hardware_version ||
        lhs.function_generation != rhs.function_generation ||
        lhs.write_target_kind != rhs.write_target_kind ||
        lhs.backing_target.value != rhs.backing_target.value ||
        lhs.hmc_target.value != rhs.hmc_target.value ||
        lhs.bar_target.value != rhs.bar_target.value ||
        lhs.bytes.size() != rhs.bytes.size() ||
        lhs.field_summary.size() != rhs.field_summary.size())
      return 1'b0;
    foreach (lhs.bytes[i])
      if (lhs.bytes[i] != rhs.bytes[i]) return 1'b0;
    foreach (lhs.field_summary[i])
      if (lhs.field_summary[i] != rhs.field_summary[i]) return 1'b0;
    return 1'b1;
  endfunction

  function automatic bit expect_image_unchanged(
    string label,
    rdma_hw_image actual,
    rdma_hw_image snapshot
  );
    if (!images_equal(actual, snapshot)) begin
      `uvm_error(label, "operation mutated an input or prior artifact")
      return 1'b0;
    end
    return 1'b1;
  endfunction

  function automatic bit verify_artifact_ledger(string checkpoint);
    if (artifact_actual.size() != artifact_snapshot.size() ||
        artifact_actual.size() != artifact_label.size()) begin
      `uvm_error(checkpoint, "artifact ledger queue sizes do not match")
      return 1'b0;
    end
    foreach (artifact_actual[i]) begin
      if (artifact_actual[i] == null || artifact_snapshot[i] == null) begin
        `uvm_error(checkpoint,
                   $sformatf("artifact ledger entry %0d (%s) is null", i,
                             artifact_label[i]))
        return 1'b0;
      end
      if (!expect_image_unchanged(
            {checkpoint, "_", artifact_label[i]}, artifact_actual[i],
            artifact_snapshot[i]))
        return 1'b0;
    end
    return 1'b1;
  endfunction

  function automatic bit publish_artifact(
    string label,
    rdma_hw_image image
  );
    rdma_hw_image snapshot;
    if (!verify_artifact_ledger({label, "_PRIOR_LEDGER"})) return 1'b0;
    if (image == null) begin
      `uvm_error(label, "cannot publish a null artifact")
      return 1'b0;
    end
    snapshot = clone_image(image, {label, "_LEDGER_SNAPSHOT"});
    if (snapshot == null) return 1'b0;
    artifact_actual.push_back(image);
    artifact_snapshot.push_back(snapshot);
    artifact_label.push_back(label);
    return 1'b1;
  endfunction

  function automatic bit expect_golden(
    string label,
    rdma_hw_image image,
    rdma_xtr_v1_golden_case golden,
    int unsigned expected_bytes,
    rdma_image_kind_e expected_kind,
    int unsigned expected_generation
  );
    if (image == null || golden == null ||
        image.bytes.size() != expected_bytes ||
        golden.payload.size() != expected_bytes) begin
      `uvm_error(label, "golden/image byte count is invalid")
      return 1'b0;
    end
    if (image.length != expected_bytes ||
        image.alignment != expected_bytes ||
        image.endian != RDMA_ENDIAN_BIG ||
        image.image_kind != expected_kind ||
        image.hardware_version != 1 ||
        image.function_generation != expected_generation ||
        image.write_target_kind != RDMA_HW_TARGET_NONE ||
        image.backing_target.value != 0 || image.hmc_target.value != 0 ||
        image.bar_target.value != 0) begin
      `uvm_error(label, "golden image metadata/targets are not canonical")
      return 1'b0;
    end
    foreach (golden.payload[i])
      if (image.bytes[i] != golden.payload[i]) begin
        `uvm_error(label,
                   $sformatf("byte %0d got %02x expected %02x", i,
                             image.bytes[i], golden.payload[i]))
        return 1'b0;
      end
    return 1'b1;
  endfunction

  function automatic bit [63:0] image_word(
    rdma_hw_image image,
    int unsigned qword_index
  );
    bit [63:0] word;
    word = '0;
    for (int unsigned i = 0; i < 8; i++)
      word = {word[55:0], image.bytes[(qword_index * 8) + i]};
    return word;
  endfunction

  // Independent driver-derived request-envelope oracle.  Do not source this
  // mask from the codec under test.
  function automatic bit [63:0] literal_envelope_mask(int unsigned qword);
    return (qword == 0) ? 64'h8fff_3fff_0000_0000 : 64'h0;
  endfunction

  // Independent fixed-driver body-ownership oracle.  These literals are
  // deliberately not sourced from body_mask() or the composer's registry.
  function automatic bit [63:0] literal_body_mask(
    rdma_xtr_v1_e2e_body_case_e body_case,
    int unsigned qword
  );
    if (qword > 7) return 64'h0;
    case (body_case)
      E2E_BODY_QPC_CREATE:
        case (qword)
          0: return 64'h0000000000ffffff;
          1: return 64'hfffff801ff1fffff;
          3: return 64'hfffffffffffffe00;
          default: return 64'h0;
        endcase
      E2E_BODY_CQC_CREATE:
        case (qword)
          0: return 64'h00000000001fffff;
          1: return 64'hff0fffffffffffff;
          2: return 64'hfffffffffffff8ff;
          3: return 64'hfffffffffff8c701;
          4: return 64'hf000000000ffffff;
          5: return 64'h0000000000000fff;
          6: return 64'hffffffffffffffc0;
          7: return 64'h0000000f00ffffff;
          default: return 64'h0;
        endcase
      E2E_BODY_MRT_KEY_ALLOC_PBL0:
        case (qword)
          0: return 64'h6000000000ffffff;
          1: return 64'h00000000ff000000;
          2: return 64'hffffffffffffffff;
          3: return 64'hff00bfffffffffff;
          4: return 64'hffffffffffffffff;
          5: return 64'hfffffffffffff000;
          6: return 64'h0000000000000fff;
          default: return 64'h0;
        endcase
      E2E_BODY_MRT_REGISTER_PBL0:
        case (qword)
          0: return 64'h6000000000ffffff;
          1: return 64'h00000000ff000000;
          2: return 64'hffffffffff000000;
          3: return 64'hff00bfffffffffff;
          4: return 64'hffffffffffffffff;
          5: return 64'hfffffffffffff000;
          6: return 64'h0000000000000fff;
          default: return 64'h0;
        endcase
      E2E_BODY_MRT_REGISTER_PBL1:
        case (qword)
          0: return 64'h6000000000ffffff;
          1: return 64'h00000000ff000000;
          2: return 64'hffffffffff000000;
          3: return 64'hff00bfffffffffff;
          4: return 64'hffffffffffffffff;
          5: return 64'hfffffffffffff000;
          6: return 64'hffffffffffffffff;
          default: return 64'h0;
        endcase
      E2E_BODY_MRT_REGISTER_PBL2:
        case (qword)
          0: return 64'h6000000000ffffff;
          1: return 64'h00000000ff000000;
          2: return 64'hffffffffff000000;
          3: return 64'hff00bfffffffffff;
          4: return 64'hffffffffffffffff;
          5: return 64'hfffffff000000000;
          6: return 64'h0000000000000fff;
          default: return 64'h0;
        endcase
      E2E_BODY_SRQC_CREATE:
        case (qword)
          0: return 64'h000000000000ffff;
          2: return 64'hcfffffffffffffff;
          3: return 64'hffff000000000000;
          4: return 64'hfffffffffffff0fc;
          5: return 64'h00000000ffffffff;
          default: return 64'h0;
        endcase
      E2E_BODY_CEQC_CREATE, E2E_BODY_AEQC_CREATE:
        case (qword)
          0: return 64'h0000000000000fff;
          2: return 64'hc1ffffffffffffff;
          3: return 64'hfffffffffffff800;
          4: return 64'h0000007ffff0c000;
          5: return 64'hffff00000007ffff;
          default: return 64'h0;
        endcase
      default: return 64'h0;
    endcase
  endfunction

  function automatic bit [63:0] literal_envelope_word(
    bit [7:0] opcode,
    bit alternate_vf,
    int unsigned qword
  );
    bit [63:0] word;
    word = '0;
    if (qword == 0) begin
      word[63] = 1'b1;
      word[59] = alternate_vf;
      word[58:48] = alternate_vf ? 11'h008 : 11'h000;
      word[45] = 1'b1;
      word[44:40] = 5'h1b;
      word[39:32] = opcode;
    end
    return word;
  endfunction

  function automatic bit [63:0] literal_qpc_create_body_word(
    rdma_xtr_v1_qpc_command_body command,
    int unsigned qword
  );
    bit [63:0] word;
    word = '0;
    case (qword)
      0: word[23:0] = command.qp_h.object_id[23:0];
      1: begin
        word[63:43] = command.send_cq_h.object_id[20:0];
        word[32] = 1'b1;
        word[20:0] = command.recv_cq_h.object_id[20:0];
      end
      3: word[63:9] = command.qpc_buffer.value[63:9];
      default: word = '0;
    endcase
    return word;
  endfunction

  function automatic bit check_qpc_create_body_oracle(
    string label,
    rdma_xtr_v1_qpc_command_body command,
    rdma_hw_image body
  );
    bit [63:0] actual;
    bit [63:0] expected;
    if (command == null || command.qp_h == null ||
        command.send_cq_h == null || command.recv_cq_h == null ||
        body == null) begin
      `uvm_error(label, "QPC body oracle received a null prerequisite")
      return 1'b0;
    end
    if (body.length != 64 || body.bytes.size() != 64 ||
        body.alignment != 64 || body.endian != RDMA_ENDIAN_BIG ||
        body.image_kind != RDMA_IMAGE_CMQ_SQE ||
        body.hardware_version != 1 ||
        body.function_generation != command.qp_h.generation ||
        body.write_target_kind != RDMA_HW_TARGET_NONE ||
        body.backing_target.value != 0 || body.hmc_target.value != 0 ||
        body.bar_target.value != 0) begin
      `uvm_error(label, "QPC create body metadata/targets are not canonical")
      return 1'b0;
    end
    for (int unsigned q = 0; q < 8; q++) begin
      actual = image_word(body, q);
      expected = literal_qpc_create_body_word(command, q);
      if (actual != expected) begin
        `uvm_error(label,
                   $sformatf("QPC create body qword %0d got %016x expected %016x",
                             q, actual, expected))
        return 1'b0;
      end
    end
    return 1'b1;
  endfunction

  function automatic byte unsigned literal_qpc_signature(
    bit [7:0] opcode,
    bit alternate_vf,
    rdma_xtr_v1_qpc_command_body command,
    rdma_hw_image qpc_source
  );
    bit [63:0] unsigned_word;
    byte unsigned signature;
    signature = 8'h00;
    for (int unsigned q = 0; q < 8; q++) begin
      unsigned_word = literal_envelope_word(opcode, alternate_vf, q) |
        literal_qpc_create_body_word(command, q);
      if (q == 1) unsigned_word[31:24] = 8'h00;
      for (int unsigned i = 0; i < 8; i++)
        signature ^= unsigned_word[63 - (i * 8) -: 8];
    end
    foreach (qpc_source.bytes[i]) signature ^= qpc_source.bytes[i];
    return ~signature;
  endfunction

  function automatic bit check_final_sqe_oracle(
    string label,
    bit [7:0] opcode,
    bit alternate_vf,
    rdma_xtr_v1_e2e_body_case_e body_case,
    rdma_hw_image body,
    rdma_hw_image qpc_source,
    rdma_xtr_v1_qpc_command_body qpc_command,
    rdma_hw_image request
  );
    bit [63:0] actual;
    bit [63:0] body_owned;
    bit [63:0] expected;
    bit [63:0] envelope_owned;
    bit [63:0] body_ownership;
    byte unsigned expected_signature;
    int unsigned expected_generation;

    if (body == null || body.bytes.size() != 64 || request == null) begin
      `uvm_error(label, "final-SQE oracle received a null artifact")
      return 1'b0;
    end
    if (body_case == E2E_BODY_QPC_CREATE) begin
      if (qpc_source == null || qpc_command == null ||
          qpc_command.qp_h == null || qpc_command.send_cq_h == null ||
          qpc_command.recv_cq_h == null ||
          qpc_source.bytes.size() != 512) begin
        `uvm_error(label, "QPC final-SQE oracle has a null prerequisite")
        return 1'b0;
      end
      expected_generation = qpc_command.qp_h.generation;
      expected_signature = literal_qpc_signature(
        opcode, alternate_vf, qpc_command, qpc_source);
    end
    else begin
      expected_generation = body.function_generation;
      if (qpc_source != null || qpc_command != null) begin
        `uvm_error(label,
                   "non-QPC final-SQE oracle received a QPC prerequisite")
        return 1'b0;
      end
    end
    if (request.length != 64 || request.bytes.size() != 64 ||
        request.alignment != 64 || request.endian != RDMA_ENDIAN_BIG ||
        request.image_kind != RDMA_IMAGE_CMQ_SQE ||
        request.hardware_version != 1 ||
        request.function_generation != expected_generation ||
        request.write_target_kind != RDMA_HW_TARGET_NONE ||
        request.backing_target.value != 0 ||
        request.hmc_target.value != 0 || request.bar_target.value != 0 ||
        request.field_summary.size() != 0) begin
      `uvm_error(label, "final CMQ SQE metadata/targets are not canonical")
      return 1'b0;
    end
    for (int unsigned q = 0; q < 8; q++) begin
      actual = image_word(request, q);
      envelope_owned = literal_envelope_word(opcode, alternate_vf, q);
      body_ownership = literal_body_mask(body_case, q);
      if (body_case == E2E_BODY_QPC_CREATE)
        body_owned = literal_qpc_create_body_word(qpc_command, q);
      else
        body_owned = image_word(body, q) & body_ownership;
      expected = envelope_owned | body_owned;
      if (body_case == E2E_BODY_QPC_CREATE && q == 1)
        expected[31:24] = expected_signature;
      if ((actual & literal_envelope_mask(q)) != envelope_owned) begin
        `uvm_error(label,
                   $sformatf("qword %0d envelope fields are not exact", q))
        return 1'b0;
      end
      if (body_case == E2E_BODY_QPC_CREATE && q == 1) begin
        if ((actual & body_ownership & ~64'h00000000ff000000) !=
            (body_owned & ~64'h00000000ff000000)) begin
          `uvm_error(label,
                     "composer changed a non-signature QPC body bit")
          return 1'b0;
        end
        if (actual[31:24] != expected_signature) begin
          `uvm_error(label,
                     "composer signature differs from independent oracle")
          return 1'b0;
        end
      end
      else if ((actual & body_ownership) != body_owned) begin
        `uvm_error(label,
                   $sformatf("composer changed body-owned qword %0d", q))
        return 1'b0;
      end
      if ((actual & ~(literal_envelope_mask(q) | body_ownership)) != 0) begin
        `uvm_error(label,
                   $sformatf("qword %0d sets an unowned bit", q))
        return 1'b0;
      end
      if (actual != expected) begin
        `uvm_error(label,
                   $sformatf("qword %0d got %016x expected %016x",
                             q, actual, expected))
        return 1'b0;
      end
    end
    return 1'b1;
  endfunction

  function automatic rdma_xtr_v1_cmq_envelope make_envelope(
    string name,
    bit [7:0] opcode,
    bit alternate_vf
  );
    rdma_xtr_v1_cmq_envelope envelope;
    envelope = rdma_xtr_v1_cmq_envelope::type_id::create(name);
    envelope.valid = 1'b1;
    envelope.vfid_override = alternate_vf;
    // override bit 59 and use_vfid bit 3 (CMQ bit 51) have equal byte XORs.
    // This keeps the QPC checksum signature stable while changing both
    // requested VF controls.
    envelope.use_vfid = alternate_vf ? 11'h008 : 11'h000;
    envelope.wrap = 1'b1;
    envelope.wqe_index = 5'h1b;
    envelope.opcode = opcode;
    return envelope;
  endfunction

  function automatic rdma_hw_image make_completion(
    bit [7:0] opcode,
    bit wrap
  );
    rdma_hw_image image;
    bit [63:0] word;
    image = rdma_hw_image::type_id::create("e2e_completion");
    repeat (64) image.bytes.push_back(8'h00);
    image.length = 64;
    image.alignment = 64;
    image.endian = RDMA_ENDIAN_BIG;
    image.image_kind = RDMA_IMAGE_CMQ_CQE;
    image.hardware_version = XTR_V1_HW_VERSION;
    image.write_target_kind = RDMA_HW_TARGET_NONE;
    word = '0;
    word[63] = 1'b1;
    word[45] = wrap;
    word[44:40] = 5'h1b;
    word[39:32] = opcode;
    word[31:24] = 8'h00;
    for (int unsigned i = 0; i < 8; i++)
      image.bytes[i] = word[63 - (i * 8) -: 8];
    return image;
  endfunction

  function automatic bit check_completion(
    string label,
    bit [7:0] opcode
  );
    rdma_hw_image image;
    rdma_hw_image snapshot;
    rdma_xtr_v1_cmq_completion completion;
    rdma_status status;
    bit ready;
    image = make_completion(opcode, 1'b1);
    if (image == null || completion_codec == null) begin
      `uvm_error(label, "completion check has a null prerequisite")
      return 1'b0;
    end
    snapshot = clone_image(image, {label, "_CQE_SNAPSHOT"});
    if (snapshot == null) return 1'b0;
    completion = null;
    ready = 1'b0;
    status = completion_codec.inspect_completion(image, 1'b1, ready,
                                                  completion);
    if (status != null && status.ok() &&
        !expect_image_unchanged({label, "_COMPLETION_INPUT"}, image,
                                snapshot))
      return 1'b0;
    if (!require_ok({label, "_COMPLETION_DECODE"}, status)) return 1'b0;
    if (!ready || completion == null) begin
      `uvm_error(label, "successful completion decode published null")
      return 1'b0;
    end
    if (!completion.owner || completion.opcode != opcode ||
        completion.command_ecode != 0 ||
        completion.wqe_index != 5'h1b || !completion.wrap ||
        completion.object_payload.size() != 0) begin
      `uvm_error(label, "create/register completion fields are incorrect")
      return 1'b0;
    end
    return 1'b1;
  endfunction

  function automatic bit compose_two_envelopes(
    string label,
    bit [7:0] opcode,
    rdma_xtr_v1_e2e_body_case_e body_case,
    rdma_hw_image body,
    rdma_hw_image qpc_source,
    rdma_xtr_v1_qpc_command_body qpc_command,
    output rdma_hw_image request
  );
    rdma_xtr_v1_cmq_envelope envelope_a;
    rdma_xtr_v1_cmq_envelope envelope_b;
    rdma_hw_image body_snapshot;
    rdma_hw_image qpc_snapshot;
    rdma_hw_image request_a;
    rdma_hw_image request_a_snapshot;
    rdma_hw_image request_b;
    rdma_status status;
    bit [63:0] diff;
    bit saw_difference;

    request = null;
    if (composer == null || body == null ||
        (body_case == E2E_BODY_QPC_CREATE &&
         (qpc_source == null || qpc_command == null))) begin
      `uvm_error(label, "composition has a null prerequisite")
      return 1'b0;
    end
    body_snapshot = clone_image(body, {label, "_BODY_SNAPSHOT"});
    if (body_snapshot == null) return 1'b0;
    if (qpc_source != null)
      qpc_snapshot = clone_image(qpc_source, {label, "_QPC_SNAPSHOT"});
    if (qpc_source != null && qpc_snapshot == null) return 1'b0;
    envelope_a = make_envelope({label, "_ENV_A"}, opcode, 1'b0);
    envelope_b = make_envelope({label, "_ENV_B"}, opcode, 1'b1);
    if (envelope_a == null || envelope_b == null) begin
      `uvm_error(label, "composition envelope creation failed")
      return 1'b0;
    end
    status = composer.compose_request(envelope_a, body, qpc_source,
                                      request_a);
    if (status != null && status.ok()) begin
      if (!expect_image_unchanged({label, "_BODY_AFTER_COMPOSE_A"}, body,
                                  body_snapshot))
        return 1'b0;
      if (qpc_source != null &&
          !expect_image_unchanged({label, "_QPC_AFTER_COMPOSE_A"},
                                  qpc_source, qpc_snapshot))
        return 1'b0;
    end
    if (!require_ok({label, "_COMPOSE_A"}, status)) return 1'b0;
    if (request_a == null) begin
      `uvm_error(label, "first checked composition published null")
      return 1'b0;
    end
    if (!publish_artifact({label, "_REQUEST_A"}, request_a)) return 1'b0;
    if (!check_final_sqe_oracle({label, "_FINAL_A"}, opcode, 1'b0,
                                body_case, body, qpc_source, qpc_command,
                                request_a))
      return 1'b0;
    request_a_snapshot = clone_image(request_a, {label, "_REQ_A_SNAPSHOT"});
    if (request_a_snapshot == null) return 1'b0;
    status = composer.compose_request(envelope_b, body, qpc_source,
                                      request_b);
    if (status != null && status.ok()) begin
      if (!expect_image_unchanged({label, "_BODY_IMMUTABLE"}, body,
                                  body_snapshot))
        return 1'b0;
      if (qpc_source != null &&
          !expect_image_unchanged({label, "_QPC_IMMUTABLE"}, qpc_source,
                                  qpc_snapshot))
        return 1'b0;
      if (!expect_image_unchanged({label, "_REQ_A_PRESERVED"}, request_a,
                                  request_a_snapshot))
        return 1'b0;
    end
    if (!require_ok({label, "_COMPOSE_B"}, status)) return 1'b0;
    if (request_b == null) begin
      `uvm_error(label, "second checked composition published null")
      return 1'b0;
    end
    if (!publish_artifact({label, "_REQUEST_B"}, request_b)) return 1'b0;
    if (!check_final_sqe_oracle({label, "_FINAL_B"}, opcode, 1'b1,
                                body_case, body, qpc_source, qpc_command,
                                request_b))
      return 1'b0;
    saw_difference = 1'b0;
    for (int unsigned q = 0; q < 8; q++) begin
      diff = image_word(request_a, q) ^ image_word(request_b, q);
      if ((diff & ~literal_envelope_mask(q)) != 0)
        begin
          `uvm_error(label,
                     $sformatf("qword %0d changed outside envelope ownership",
                               q))
          return 1'b0;
        end
      saw_difference |= diff != 0;
      if (q == 0 && diff != 64'h0808_0000_0000_0000) begin
        `uvm_error(label,
                   $sformatf("VF envelope delta is %016x", diff))
        return 1'b0;
      end
      if (q != 0 && diff != 0) begin
        `uvm_error(label,
                   $sformatf("non-envelope qword %0d changed", q))
        return 1'b0;
      end
    end
    if (!saw_difference) begin
      `uvm_error(label, "two VF envelopes produced identical SQEs")
      return 1'b0;
    end
    request = request_b;
    if (!check_completion(label, opcode)) return 1'b0;
    if (!verify_artifact_ledger({label, "_COMPOSE_EXIT"})) return 1'b0;
    return 1'b1;
  endfunction

  function automatic rdma_xtr_v1_qpc_command_body make_qpc_create_command(
    string name,
    rdma_qpc_model qpc
  );
    rdma_xtr_v1_qpc_command_body body;
    body = rdma_xtr_v1_qpc_command_body::type_id::create(name);
    body.qp_h = make_handle({name, "_qp"}, RDMA_RESOURCE_QP,
                            qpc.qp_h.object_id,
                            qpc.qp_h.function_uid, qpc.qp_h.generation);
    body.send_cq_h = make_handle({name, "_scq"}, RDMA_RESOURCE_CQ,
                                 qpc.send_cq_h.object_id,
                                 qpc.qp_h.function_uid, qpc.qp_h.generation);
    body.recv_cq_h = make_handle({name, "_rcq"}, RDMA_RESOURCE_CQ,
                                 qpc.recv_cq_h.object_id,
                                 qpc.qp_h.function_uid, qpc.qp_h.generation);
    body.qpc_buffer = qpc.context_backing;
    return body;
  endfunction

  function automatic bit run_qpc_workflow(
    string label,
    string variant,
    rdma_qpc_model source,
    rdma_xtr_v1_golden_case golden,
    output rdma_hw_image context_image,
    output rdma_hw_image command_body,
    output rdma_hw_image request
  );
    rdma_codec_base codec;
    rdma_hw_model source_snapshot;
    rdma_hw_image context_snapshot;
    rdma_hw_image decode_input_snapshot;
    rdma_hw_model decoded;
    rdma_hw_model equal_source_snapshot;
    rdma_hw_model equal_decoded_snapshot;
    rdma_xtr_v1_qpc_command_body command;
    rdma_hw_model build_command_snapshot;
    rdma_status status;
    bit equal;
    string mismatch;

    context_image = null;
    command_body = null;
    request = null;
    if (source == null || golden == null || qpc_registry == null ||
        composer == null) begin
      `uvm_error(label, "QPC workflow has a null prerequisite")
      return 1'b0;
    end
    source_snapshot = clone_model(source, {label, "_MODEL_SNAPSHOT"});
    if (source_snapshot == null) return 1'b0;
    if (!require_ok({label, "_MODEL_VALIDATE"}, source.validate()))
      return 1'b0;
    if (!require_ok({label, "_LOOKUP"},
                    qpc_registry.lookup(qpc_key(variant), codec)))
      return 1'b0;
    if (codec == null) begin
      `uvm_error(label, "QPC codec lookup published null")
      return 1'b0;
    end
    status = codec.encode(source, context_image);
    if (!require_ok({label, "_CONTEXT_ENCODE"}, status)) return 1'b0;
    if (context_image == null) begin
      `uvm_error(label, "QPC context encode published null")
      return 1'b0;
    end
    context_snapshot = clone_image(context_image,
                                   {label, "_CONTEXT_INITIAL_SNAPSHOT"});
    if (context_snapshot == null) return 1'b0;
    if (!publish_artifact({label, "_STANDALONE_CONTEXT"}, context_image))
      return 1'b0;
    if (!expect_model_unchanged({label, "_MODEL_AFTER_ENCODE"}, source,
                                source_snapshot))
      return 1'b0;
    if (!expect_golden({label, "_CONTEXT_GOLDEN"}, context_image, golden,
                       512, RDMA_IMAGE_QPC, source.qp_h.generation))
      return 1'b0;
    decoded = null;
    decode_input_snapshot = clone_image(
      context_image, {label, "_DECODE_INPUT_SNAPSHOT"});
    if (decode_input_snapshot == null) return 1'b0;
    status = codec.decode(context_image, decoded);
    if (status != null && status.ok()) begin
      if (!expect_image_unchanged({label, "_DECODE_INPUT_IMMUTABLE"},
                                  context_image, decode_input_snapshot))
        return 1'b0;
    end
    if (!require_ok({label, "_CONTEXT_DECODE"}, status)) return 1'b0;
    if (decoded == null) begin
      `uvm_error(label, "QPC context decode published null")
      return 1'b0;
    end
    equal_source_snapshot = clone_model(
      source, {label, "_EQUAL_SOURCE_SNAPSHOT"});
    equal_decoded_snapshot = clone_model(
      decoded, {label, "_EQUAL_DECODED_SNAPSHOT"});
    if (equal_source_snapshot == null || equal_decoded_snapshot == null)
      return 1'b0;
    status = codec.serialized_equal(source, decoded, equal, mismatch);
    if (status != null && status.ok()) begin
      if (!expect_model_unchanged({label, "_EQUAL_SOURCE_IMMUTABLE"}, source,
                                  equal_source_snapshot) ||
          !expect_model_unchanged({label, "_EQUAL_DECODED_IMMUTABLE"},
                                  decoded, equal_decoded_snapshot))
        return 1'b0;
    end
    if (!require_ok({label, "_SERIALIZED_EQUAL_STATUS"}, status))
      return 1'b0;
    if (!equal) begin
      `uvm_error(label, {"standalone QPC mismatch: ", mismatch})
      return 1'b0;
    end

    // QPC has a standalone 512-byte context, not a Task 10 sparse body.
    // The following is the real lightweight create command required for the
    // final CMQ SQE; it is never treated as a sparse context body.
    command = make_qpc_create_command({label, "_COMMAND"}, source);
    if (command == null) begin
      `uvm_error(label, "QPC command creation published null")
      return 1'b0;
    end
    if (!require_ok({label, "_COMMAND_VALIDATE"}, command.validate()))
      return 1'b0;
    build_command_snapshot = clone_model(
      command, {label, "_BUILD_COMMAND_SNAPSHOT"});
    if (build_command_snapshot == null) return 1'b0;
    status = composer.build_body(XTR_V1_OP_QPC_CREATE, command,
                                 command_body);
    if (status != null && status.ok() &&
        !expect_model_unchanged({label, "_BUILD_COMMAND_IMMUTABLE"}, command,
                                build_command_snapshot))
      return 1'b0;
    if (!require_ok({label, "_COMMAND_ENCODE"}, status)) return 1'b0;
    if (command_body == null) begin
      `uvm_error(label, "QPC command body build published null")
      return 1'b0;
    end
    if (!publish_artifact({label, "_COMMAND_BODY"}, command_body))
      return 1'b0;
    if (!check_qpc_create_body_oracle({label, "_COMMAND_BODY_ORACLE"},
                                      command, command_body))
      return 1'b0;
    if (!compose_two_envelopes(label, XTR_V1_OP_QPC_CREATE,
                               E2E_BODY_QPC_CREATE, command_body,
                               context_image, command, request))
      return 1'b0;
    if (!expect_model_unchanged({label, "_MODEL_FINAL"}, source,
                                source_snapshot) ||
        !expect_image_unchanged({label, "_CONTEXT_FINAL"}, context_image,
                                context_snapshot) ||
        !expect_model_unchanged({label, "_COMMAND_FINAL"}, command,
                                build_command_snapshot))
      return 1'b0;
    if (!verify_artifact_ledger({label, "_WORKFLOW_EXIT"})) return 1'b0;
    return 1'b1;
  endfunction

  function automatic bit run_context_workflow(
    string label,
    bit [7:0] opcode,
    rdma_xtr_v1_e2e_body_case_e body_case,
    rdma_image_kind_e expected_kind,
    int unsigned expected_generation,
    rdma_codec_base codec,
    rdma_hw_model source,
    rdma_xtr_v1_golden_case golden,
    output rdma_hw_image body,
    output rdma_hw_image request
  );
    rdma_hw_model source_snapshot;
    rdma_hw_model decoded;
    rdma_hw_model equal_source_snapshot;
    rdma_hw_model equal_decoded_snapshot;
    rdma_hw_model build_source_snapshot;
    rdma_hw_image direct_body;
    rdma_hw_image direct_body_snapshot;
    rdma_hw_image decode_input_snapshot;
    rdma_status status;
    bit equal;
    string mismatch;

    body = null;
    request = null;
    if (codec == null || source == null || golden == null ||
        composer == null) begin
      `uvm_error(label, "context workflow has a null prerequisite")
      return 1'b0;
    end
    source_snapshot = clone_model(source, {label, "_MODEL_SNAPSHOT"});
    if (source_snapshot == null) return 1'b0;
    if (!require_ok({label, "_MODEL_VALIDATE"}, source.validate()))
      return 1'b0;
    status = codec.encode(source, direct_body);
    if (!require_ok({label, "_BODY_ENCODE"}, status)) return 1'b0;
    if (direct_body == null) begin
      `uvm_error(label, "sparse-body encode published null")
      return 1'b0;
    end
    direct_body_snapshot = clone_image(
      direct_body, {label, "_DIRECT_BODY_INITIAL_SNAPSHOT"});
    if (direct_body_snapshot == null) return 1'b0;
    if (!publish_artifact({label, "_DIRECT_BODY"}, direct_body)) return 1'b0;
    if (!expect_model_unchanged({label, "_MODEL_AFTER_ENCODE"}, source,
                                source_snapshot))
      return 1'b0;
    if (!expect_golden({label, "_BODY_GOLDEN"}, direct_body, golden, 64,
                       expected_kind, expected_generation))
      return 1'b0;
    decoded = null;
    decode_input_snapshot = clone_image(
      direct_body, {label, "_DECODE_INPUT_SNAPSHOT"});
    if (decode_input_snapshot == null) return 1'b0;
    status = codec.decode(direct_body, decoded);
    if (status != null && status.ok() &&
        !expect_image_unchanged({label, "_DECODE_INPUT_IMMUTABLE"},
                                direct_body, decode_input_snapshot))
      return 1'b0;
    if (!require_ok({label, "_BODY_DECODE"}, status)) return 1'b0;
    if (decoded == null) begin
      `uvm_error(label, "sparse-body decode published null")
      return 1'b0;
    end
    equal_source_snapshot = clone_model(
      source, {label, "_EQUAL_SOURCE_SNAPSHOT"});
    equal_decoded_snapshot = clone_model(
      decoded, {label, "_EQUAL_DECODED_SNAPSHOT"});
    if (equal_source_snapshot == null || equal_decoded_snapshot == null)
      return 1'b0;
    status = codec.serialized_equal(source, decoded, equal, mismatch);
    if (status != null && status.ok()) begin
      if (!expect_model_unchanged({label, "_EQUAL_SOURCE_IMMUTABLE"}, source,
                                  equal_source_snapshot) ||
          !expect_model_unchanged({label, "_EQUAL_DECODED_IMMUTABLE"},
                                  decoded, equal_decoded_snapshot))
        return 1'b0;
    end
    if (!require_ok({label, "_SERIALIZED_EQUAL_STATUS"}, status))
      return 1'b0;
    if (!equal) begin
      `uvm_error(label, {"sparse-body mismatch: ", mismatch})
      return 1'b0;
    end

    build_source_snapshot = clone_model(
      source, {label, "_BUILD_SOURCE_SNAPSHOT"});
    if (build_source_snapshot == null) return 1'b0;
    status = composer.build_body(opcode, source, body);
    if (status != null && status.ok() &&
        !expect_model_unchanged({label, "_BUILD_SOURCE_IMMUTABLE"}, source,
                                build_source_snapshot))
      return 1'b0;
    if (!require_ok({label, "_CHECKED_BODY_ENCODE"}, status)) return 1'b0;
    if (body == null) begin
      `uvm_error(label, "checked body build published null")
      return 1'b0;
    end
    if (!publish_artifact({label, "_CHECKED_BODY"}, body)) return 1'b0;
    if (!expect_golden({label, "_CHECKED_BODY_GOLDEN"}, body, golden, 64,
                       expected_kind, expected_generation))
      return 1'b0;
    if (direct_body == null || body == null ||
        direct_body.bytes.size() != body.bytes.size()) begin
      `uvm_error(label, "direct/checked body is unavailable")
      return 1'b0;
    end
    foreach (direct_body.bytes[i])
      if (direct_body.bytes[i] != body.bytes[i]) begin
        `uvm_error(label,
                   $sformatf("checked body byte %0d differs", i))
        return 1'b0;
      end
    if (!compose_two_envelopes(label, opcode, body_case, body, null, null,
                               request))
      return 1'b0;
    if (!expect_model_unchanged({label, "_MODEL_FINAL"}, source,
                                source_snapshot) ||
        !expect_image_unchanged({label, "_DIRECT_BODY_FINAL"}, direct_body,
                                direct_body_snapshot))
      return 1'b0;
    if (!verify_artifact_ledger({label, "_WORKFLOW_EXIT"})) return 1'b0;
    return 1'b1;
  endfunction

  function automatic bit check_failure_contracts(
    rdma_codec_base qpc_codec,
    rdma_qpc_model qpc,
    rdma_hw_image qpc_image,
    rdma_codec_base cqc_codec,
    rdma_cqc_model cqc,
    rdma_hw_image cqc_body,
    rdma_hw_image prior_request
  );
    rdma_qpc_model invalid_qpc;
    rdma_cqc_model invalid_cqc;
    rdma_hw_model model_snapshot;
    rdma_hw_model decoded;
    rdma_hw_image image;
    rdma_hw_image corrupt;
    rdma_hw_image input_snapshot;
    rdma_hw_image qpc_snapshot;
    rdma_hw_image cqc_snapshot;
    rdma_hw_image request_snapshot;
    rdma_xtr_v1_cmq_envelope bad_envelope;
    rdma_xtr_v1_cmq_completion completion;
    rdma_status status;
    bit ready;

    if (qpc_codec == null || qpc == null || qpc_image == null ||
        cqc_codec == null || cqc == null || cqc_body == null ||
        prior_request == null || composer == null || completion_codec == null) begin
      `uvm_error("FAIL_PREREQUISITES", "failure-contract prerequisite is null")
      return 1'b0;
    end
    qpc_snapshot = clone_image(qpc_image, "FAIL_QPC_ARTIFACT_SNAPSHOT");
    cqc_snapshot = clone_image(cqc_body, "FAIL_CQC_ARTIFACT_SNAPSHOT");
    request_snapshot = clone_image(prior_request,
                                   "FAIL_REQUEST_ARTIFACT_SNAPSHOT");
    if (qpc_snapshot == null || cqc_snapshot == null ||
        request_snapshot == null)
      return 1'b0;

    if (!$cast(invalid_qpc, clone_model(qpc, "FAIL_QPC_MODEL_CLONE")))
      return 1'b0;
    invalid_qpc.sq_backing.value++;
    model_snapshot = clone_model(invalid_qpc, "FAIL_QPC_MODEL_SNAPSHOT");
    if (model_snapshot == null) return 1'b0;
    image = rdma_hw_image::type_id::create("stale_failed_qpc_encode");
    if (image == null) begin
      `uvm_error("FAIL_QPC_ENCODE", "stale image creation failed")
      return 1'b0;
    end
    status = qpc_codec.encode(invalid_qpc, image);
    if (!verify_artifact_ledger("AFTER_FAIL_QPC_ENCODE")) return 1'b0;
    if (!require_status("FAIL_QPC_ENCODE", status,
                        RDMA_SC_INVALID_ARGUMENT))
      return 1'b0;
    if (image != null) begin
      `uvm_error("FAIL_QPC_ENCODE", "failed encode published an image")
      return 1'b0;
    end
    if (!expect_model_unchanged("FAIL_QPC_ENCODE_MODEL", invalid_qpc,
                                model_snapshot))
      return 1'b0;

    corrupt = clone_image(qpc_image, "FAIL_QPC_DECODE_INPUT");
    if (corrupt == null) return 1'b0;
    corrupt.length = 511;
    input_snapshot = clone_image(corrupt, "FAIL_QPC_DECODE_SNAPSHOT");
    if (input_snapshot == null) return 1'b0;
    decoded = rdma_qpc_model::type_id::create("stale_failed_qpc_decode");
    if (decoded == null) begin
      `uvm_error("FAIL_QPC_DECODE", "stale model creation failed")
      return 1'b0;
    end
    status = qpc_codec.decode(corrupt, decoded);
    if (!verify_artifact_ledger("AFTER_FAIL_QPC_DECODE")) return 1'b0;
    if (!require_status("FAIL_QPC_DECODE", status, RDMA_SC_CODEC_ERROR))
      return 1'b0;
    if (decoded != null) begin
      `uvm_error("FAIL_QPC_DECODE", "failed decode published a model")
      return 1'b0;
    end
    if (!expect_image_unchanged("FAIL_QPC_DECODE_INPUT_IMMUTABLE", corrupt,
                                input_snapshot))
      return 1'b0;

    if (!$cast(invalid_cqc, clone_model(cqc, "FAIL_CQC_MODEL_CLONE")))
      return 1'b0;
    invalid_cqc.depth = 3;
    model_snapshot = clone_model(invalid_cqc, "FAIL_CQC_MODEL_SNAPSHOT");
    if (model_snapshot == null) return 1'b0;
    image = rdma_hw_image::type_id::create("stale_failed_cqc_encode");
    if (image == null) begin
      `uvm_error("FAIL_CQC_ENCODE", "stale image creation failed")
      return 1'b0;
    end
    status = cqc_codec.encode(invalid_cqc, image);
    if (!verify_artifact_ledger("AFTER_FAIL_CQC_ENCODE")) return 1'b0;
    if (!require_status("FAIL_CQC_ENCODE", status,
                        RDMA_SC_INVALID_ARGUMENT))
      return 1'b0;
    if (image != null) begin
      `uvm_error("FAIL_CQC_ENCODE", "failed encode published an image")
      return 1'b0;
    end
    if (!expect_model_unchanged("FAIL_CQC_ENCODE_MODEL", invalid_cqc,
                                model_snapshot))
      return 1'b0;

    corrupt = clone_image(cqc_body, "FAIL_CQC_DECODE_INPUT");
    if (corrupt == null) return 1'b0;
    corrupt.length = 63;
    input_snapshot = clone_image(corrupt, "FAIL_CQC_DECODE_SNAPSHOT");
    if (input_snapshot == null) return 1'b0;
    decoded = rdma_cqc_model::type_id::create("stale_failed_cqc_decode");
    if (decoded == null) begin
      `uvm_error("FAIL_CQC_DECODE", "stale model creation failed")
      return 1'b0;
    end
    status = cqc_codec.decode(corrupt, decoded);
    if (!verify_artifact_ledger("AFTER_FAIL_CQC_DECODE")) return 1'b0;
    if (!require_status("FAIL_CQC_DECODE", status, RDMA_SC_CODEC_ERROR))
      return 1'b0;
    if (decoded != null) begin
      `uvm_error("FAIL_CQC_DECODE", "failed decode published a model")
      return 1'b0;
    end
    if (!expect_image_unchanged("FAIL_CQC_DECODE_INPUT_IMMUTABLE", corrupt,
                                input_snapshot))
      return 1'b0;

    model_snapshot = clone_model(invalid_cqc,
                                 "FAIL_BUILD_BODY_MODEL_SNAPSHOT");
    if (model_snapshot == null) return 1'b0;
    image = rdma_hw_image::type_id::create("stale_failed_build_body");
    if (image == null) begin
      `uvm_error("FAIL_BUILD_BODY", "stale image creation failed")
      return 1'b0;
    end
    status = composer.build_body(XTR_V1_OP_CQC_CREATE, invalid_cqc, image);
    if (!verify_artifact_ledger("AFTER_FAIL_BUILD_BODY")) return 1'b0;
    if (!require_status("FAIL_BUILD_BODY", status,
                        RDMA_SC_INVALID_ARGUMENT))
      return 1'b0;
    if (image != null) begin
      `uvm_error("FAIL_BUILD_BODY", "failed body build published an image")
      return 1'b0;
    end
    if (!expect_model_unchanged("FAIL_BUILD_BODY_MODEL", invalid_cqc,
                                model_snapshot))
      return 1'b0;

    bad_envelope = make_envelope("FAIL_COMPOSE_ENVELOPE",
                                 XTR_V1_OP_CQC_CREATE, 1'b0);
    if (bad_envelope == null) begin
      `uvm_error("FAIL_COMPOSE", "envelope creation failed")
      return 1'b0;
    end
    bad_envelope.use_vfid = 11'h001;
    input_snapshot = clone_image(cqc_body, "FAIL_COMPOSE_BODY_SNAPSHOT");
    if (input_snapshot == null) return 1'b0;
    image = rdma_hw_image::type_id::create("stale_failed_composition");
    if (image == null) begin
      `uvm_error("FAIL_COMPOSE", "stale image creation failed")
      return 1'b0;
    end
    status = composer.compose_request(bad_envelope, cqc_body, null, image);
    if (!verify_artifact_ledger("AFTER_FAIL_COMPOSE")) return 1'b0;
    if (!require_status("FAIL_COMPOSE", status, RDMA_SC_INVALID_ARGUMENT))
      return 1'b0;
    if (image != null) begin
      `uvm_error("FAIL_COMPOSE", "failed composition published an image")
      return 1'b0;
    end
    if (bad_envelope.vfid_override != 0 ||
        bad_envelope.use_vfid != 11'h001) begin
      `uvm_error("FAIL_COMPOSE", "failed composition mutated envelope")
      return 1'b0;
    end
    if (!expect_image_unchanged("FAIL_COMPOSE_BODY", cqc_body,
                                input_snapshot))
      return 1'b0;

    corrupt = make_completion(XTR_V1_OP_CQC_CREATE, 1'b1);
    if (corrupt == null) begin
      `uvm_error("FAIL_COMPLETION_DECODE", "completion image creation failed")
      return 1'b0;
    end
    corrupt.bytes[7] |= 8'h01;
    input_snapshot = clone_image(corrupt, "FAIL_COMPLETION_SNAPSHOT");
    if (input_snapshot == null) return 1'b0;
    completion = rdma_xtr_v1_cmq_completion::type_id::create(
      "stale_failed_completion");
    if (completion == null) begin
      `uvm_error("FAIL_COMPLETION_DECODE", "stale completion creation failed")
      return 1'b0;
    end
    ready = 1'b1;
    status = completion_codec.inspect_completion(
      corrupt, 1'b1, ready, completion);
    if (!verify_artifact_ledger("AFTER_FAIL_COMPLETION_DECODE"))
      return 1'b0;
    if (!require_status("FAIL_COMPLETION_DECODE", status,
                        RDMA_SC_CODEC_ERROR))
      return 1'b0;
    if (completion != null) begin
      `uvm_error("FAIL_COMPLETION_DECODE",
                 "failed completion decode published an object")
      return 1'b0;
    end
    if (ready) begin
      `uvm_error("FAIL_COMPLETION_DECODE",
                 "malformed completion published partial ready")
      return 1'b0;
    end
    if (!expect_image_unchanged("FAIL_COMPLETION_INPUT", corrupt,
                                input_snapshot))
      return 1'b0;

    if (!expect_image_unchanged("FAIL_QPC_ARTIFACT_PRESERVED", qpc_image,
                                qpc_snapshot) ||
        !expect_image_unchanged("FAIL_CQC_ARTIFACT_PRESERVED", cqc_body,
                                cqc_snapshot) ||
        !expect_image_unchanged("FAIL_REQUEST_ARTIFACT_PRESERVED",
                                prior_request, request_snapshot))
      return 1'b0;
    if (!verify_artifact_ledger("FAILURE_CONTRACTS_EXIT")) return 1'b0;
    return 1'b1;
  endfunction

  task run_phase(uvm_phase phase);
    rdma_xtr_v1_golden_case cases[$];
    string error;
    rdma_codec_base rc_codec;
    rdma_codec_base ud_codec;
    rdma_codec_base urc_codec;
    rdma_codec_base cqc_codec;
    rdma_codec_base mrt_key_codec;
    rdma_codec_base mrt_register_codec;
    rdma_codec_base srqc_codec;
    rdma_codec_base ceqc_codec;
    rdma_codec_base aeqc_codec;
    rdma_qpc_model rc;
    rdma_qpc_model ud;
    rdma_qpc_model urc;
    rdma_cqc_model cqc;
    rdma_mrt_model mrt0;
    rdma_mrt_model mrt1;
    rdma_mrt_model mrt2;
    rdma_srqc_model srqc;
    rdma_ceqc_model ceqc;
    rdma_aeqc_model aeqc;
    rdma_hw_image rc_image;
    rdma_hw_image ud_image;
    rdma_hw_image urc_image;
    rdma_hw_image rc_command;
    rdma_hw_image ud_command;
    rdma_hw_image urc_command;
    rdma_hw_image cqc_body;
    rdma_hw_image mrt_key_body;
    rdma_hw_image mrt0_body;
    rdma_hw_image mrt1_body;
    rdma_hw_image mrt2_body;
    rdma_hw_image srqc_body;
    rdma_hw_image ceqc_body;
    rdma_hw_image aeqc_body;
    rdma_hw_image request;
    rdma_hw_image prior_request;

    phase.raise_objection(this);
    artifact_actual.delete();
    artifact_snapshot.delete();
    artifact_label.delete();
    qpc_registry = rdma_codec_registry::type_id::create("e2e_qpc_registry");
    if (qpc_registry == null)
      `uvm_fatal("E2E_QPC_REGISTRY", "QPC registry creation failed")
    qpc_registry.clear();
    if (!require_ok("E2E_REGISTER_QPC",
                    rdma_xtr_v1_register_qpc_codecs(qpc_registry)))
      `uvm_fatal("E2E_REGISTER_QPC", "QPC codec registration failed")
    context_registry = rdma_codec_registry::type_id::create(
      "e2e_context_registry");
    if (context_registry == null)
      `uvm_fatal("E2E_CONTEXT_REGISTRY",
                 "context registry creation failed")
    context_registry.clear();
    if (!require_ok(
          "E2E_REGISTER_CONTEXT",
          rdma_xtr_v1_register_context_body_codecs(context_registry)))
      `uvm_fatal("E2E_REGISTER_CONTEXT",
                 "context codec registration failed")
    composer = rdma_xtr_v1_cmq_request_composer::type_id::create(
      "e2e_composer");
    completion_codec = rdma_xtr_v1_cmq_completion_codec::type_id::create(
      "e2e_completion_codec");
    if (composer == null || completion_codec == null)
      `uvm_fatal("E2E_CMQ_HELPERS", "CMQ helper creation failed")

    if (!rdma_xtr_v1_golden_reader::read_all(
          "../hw/xtr_v1/golden_vectors/context.hex", cases, error))
      `uvm_fatal("E2E_GOLDEN_READ", error)
    if (cases.size() != 11)
      `uvm_fatal("E2E_GOLDEN_COUNT",
                 $sformatf("expected 11 context cases, got %0d",
                           cases.size()))

    if (!require_ok("E2E_LOOKUP_RC",
                    qpc_registry.lookup(qpc_key("rc"), rc_codec)) ||
        !require_ok("E2E_LOOKUP_UD",
                    qpc_registry.lookup(qpc_key("ud"), ud_codec)) ||
        !require_ok("E2E_LOOKUP_URC",
                    qpc_registry.lookup(qpc_key("urc"), urc_codec)) ||
        !require_ok("E2E_LOOKUP_CQC", context_registry.lookup(
          body_key(RDMA_IMAGE_CQC, "cqc", "create", XTR_V1_OP_CQC_CREATE),
          cqc_codec)) ||
        !require_ok("E2E_LOOKUP_MRT_KEY", context_registry.lookup(
          body_key(RDMA_IMAGE_MRT, "mrt", "key_alloc", XTR_V1_OP_KEY_ALLOC),
          mrt_key_codec)) ||
        !require_ok("E2E_LOOKUP_MRT_REGISTER", context_registry.lookup(
          body_key(RDMA_IMAGE_MRT, "mrt", "register", XTR_V1_OP_MR_REGISTER),
          mrt_register_codec)) ||
        !require_ok("E2E_LOOKUP_SRQC", context_registry.lookup(
          body_key(RDMA_IMAGE_SRQC, "srqc", "create", XTR_V1_OP_SRFQC_CREATE),
          srqc_codec)) ||
        !require_ok("E2E_LOOKUP_CEQC", context_registry.lookup(
          body_key(RDMA_IMAGE_CEQC, "ceqc", "create", XTR_V1_OP_CEQC_CREATE),
          ceqc_codec)) ||
        !require_ok("E2E_LOOKUP_AEQC", context_registry.lookup(
          body_key(RDMA_IMAGE_AEQC, "aeqc", "create", XTR_V1_OP_AEQC_CREATE),
          aeqc_codec)))
      `uvm_fatal("E2E_LOOKUP", "required codec lookup failed")
    if (rc_codec == null || ud_codec == null || urc_codec == null ||
        cqc_codec == null || mrt_key_codec == null ||
        mrt_register_codec == null || srqc_codec == null ||
        ceqc_codec == null || aeqc_codec == null)
      `uvm_fatal("E2E_LOOKUP_NULL", "required codec lookup published null")

    rc = make_rc();
    ud = make_ud();
    urc = make_urc();
    if (rc == null || ud == null || urc == null)
      `uvm_fatal("E2E_QPC_MODELS", "QPC model creation failed")
    if (!run_qpc_workflow("E2E_QPC_RC", "rc", rc,
                          find_golden(cases, "qpc_rc_boundary"), rc_image,
                          rc_command, request))
      `uvm_fatal("E2E_QPC_RC", "RC QPC workflow failed")
    if (!run_qpc_workflow("E2E_QPC_UD", "ud", ud,
                          find_golden(cases, "qpc_ud_boundary"), ud_image,
                          ud_command, request))
      `uvm_fatal("E2E_QPC_UD", "UD QPC workflow failed")
    if (!run_qpc_workflow("E2E_QPC_URC", "urc", urc,
                          find_golden(cases, "qpc_urc_boundary"), urc_image,
                          urc_command, request))
      `uvm_fatal("E2E_QPC_URC", "URC QPC workflow failed")

    cqc = make_cqc();
    mrt0 = make_mrt("e2e_mrt_pbl0", RDMA_MR_PBL0);
    mrt1 = make_mrt("e2e_mrt_pbl1", RDMA_MR_PBL1);
    mrt2 = make_mrt("e2e_mrt_pbl2", RDMA_MR_PBL2);
    srqc = make_srqc();
    ceqc = make_ceqc();
    aeqc = make_aeqc();
    if (cqc == null || cqc.cq_h == null || mrt0 == null ||
        mrt0.mr_h == null || mrt1 == null || mrt1.mr_h == null ||
        mrt2 == null || mrt2.mr_h == null || srqc == null ||
        srqc.srq_h == null || ceqc == null || ceqc.ceq_h == null ||
        aeqc == null || aeqc.aeq_h == null)
      `uvm_fatal("E2E_CONTEXT_MODELS", "context model creation failed")
    if (!run_context_workflow(
          "E2E_CQC_CREATE", XTR_V1_OP_CQC_CREATE, E2E_BODY_CQC_CREATE,
          RDMA_IMAGE_CQC, cqc.cq_h.generation, cqc_codec, cqc,
          find_golden(cases, "cqc_create_body_boundary"), cqc_body, request))
      `uvm_fatal("E2E_CQC_CREATE", "CQC workflow failed")
    prior_request = request;
    if (prior_request == null)
      `uvm_fatal("E2E_PRIOR_REQUEST", "CQC workflow returned null request")
    if (!run_context_workflow(
          "E2E_MRT_KEY_ALLOC_PBL0", XTR_V1_OP_KEY_ALLOC,
          E2E_BODY_MRT_KEY_ALLOC_PBL0, RDMA_IMAGE_MRT,
          mrt0.mr_h.generation, mrt_key_codec, mrt0,
          find_golden(cases, "mrt_key_alloc_pbl0_boundary"), mrt_key_body,
          request))
      `uvm_fatal("E2E_MRT_KEY_ALLOC_PBL0", "MRT key workflow failed")
    if (!run_context_workflow(
          "E2E_MRT_REGISTER_PBL0", XTR_V1_OP_MR_REGISTER,
          E2E_BODY_MRT_REGISTER_PBL0, RDMA_IMAGE_MRT,
          mrt0.mr_h.generation, mrt_register_codec, mrt0,
          find_golden(cases, "mrt_register_pbl0_boundary"), mrt0_body,
          request))
      `uvm_fatal("E2E_MRT_REGISTER_PBL0", "MRT PBL0 workflow failed")
    if (!run_context_workflow(
          "E2E_MRT_REGISTER_PBL1", XTR_V1_OP_MR_REGISTER,
          E2E_BODY_MRT_REGISTER_PBL1, RDMA_IMAGE_MRT,
          mrt1.mr_h.generation, mrt_register_codec, mrt1,
          find_golden(cases, "mrt_register_pbl1_boundary"), mrt1_body,
          request))
      `uvm_fatal("E2E_MRT_REGISTER_PBL1", "MRT PBL1 workflow failed")
    if (!run_context_workflow(
          "E2E_MRT_REGISTER_PBL2", XTR_V1_OP_MR_REGISTER,
          E2E_BODY_MRT_REGISTER_PBL2, RDMA_IMAGE_MRT,
          mrt2.mr_h.generation, mrt_register_codec, mrt2,
          find_golden(cases, "mrt_register_pbl2_boundary"), mrt2_body,
          request))
      `uvm_fatal("E2E_MRT_REGISTER_PBL2", "MRT PBL2 workflow failed")
    if (!run_context_workflow(
          "E2E_SRQC_CREATE", XTR_V1_OP_SRFQC_CREATE, E2E_BODY_SRQC_CREATE,
          RDMA_IMAGE_SRQC, srqc.srq_h.generation, srqc_codec, srqc,
          find_golden(cases, "srqc_create_body_boundary"), srqc_body,
          request))
      `uvm_fatal("E2E_SRQC_CREATE", "SRQC workflow failed")
    if (!run_context_workflow(
          "E2E_CEQC_CREATE", XTR_V1_OP_CEQC_CREATE, E2E_BODY_CEQC_CREATE,
          RDMA_IMAGE_CEQC, ceqc.ceq_h.generation, ceqc_codec, ceqc,
          find_golden(cases, "ceqc_create_body_boundary"), ceqc_body,
          request))
      `uvm_fatal("E2E_CEQC_CREATE", "CEQC workflow failed")
    if (!run_context_workflow(
          "E2E_AEQC_CREATE", XTR_V1_OP_AEQC_CREATE, E2E_BODY_AEQC_CREATE,
          RDMA_IMAGE_AEQC, aeqc.aeq_h.generation, aeqc_codec, aeqc,
          find_golden(cases, "aeqc_create_body_boundary"), aeqc_body,
          request))
      `uvm_fatal("E2E_AEQC_CREATE", "AEQC workflow failed")

    if (!check_failure_contracts(rc_codec, rc, rc_image, cqc_codec, cqc,
                                 cqc_body, prior_request))
      `uvm_fatal("E2E_FAILURE_CONTRACTS", "failure-contract checks failed")
    if (!verify_artifact_ledger("E2E_FINAL_LEDGER"))
      `uvm_fatal("E2E_FINAL_LEDGER", "final artifact ledger check failed")
    phase.drop_objection(this);
  endtask
endclass
