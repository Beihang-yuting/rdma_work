class rdma_xtr_v1_cmq_test_overlap_registry
    extends rdma_xtr_v1_cmq_body_registry;
  function new(string name = "rdma_xtr_v1_cmq_test_overlap_registry");
    super.new(name);
  endfunction

  function void force_body(
    bit [7:0] opcode,
    rdma_image_kind_e input_kind,
    bit [63:0] masks[8]
  );
    set_entry_unchecked(opcode, input_kind, masks);
  endfunction
endclass

typedef enum int unsigned {
  RDMA_CMQ_TEST_ENVELOPE_OUTSIDE_MASK,
  RDMA_CMQ_TEST_ENVELOPE_VALID,
  RDMA_CMQ_TEST_ENVELOPE_VFID_OVERRIDE,
  RDMA_CMQ_TEST_ENVELOPE_VFID,
  RDMA_CMQ_TEST_ENVELOPE_WRAP,
  RDMA_CMQ_TEST_ENVELOPE_INDEX,
  RDMA_CMQ_TEST_ENVELOPE_MUTATE_INPUT
} rdma_xtr_v1_cmq_test_envelope_attack_e;

class rdma_xtr_v1_cmq_test_bad_envelope_codec
    extends rdma_xtr_v1_cmq_envelope_codec;
  rdma_xtr_v1_cmq_test_envelope_attack_e attack;

  function new(
    string name = "rdma_xtr_v1_cmq_test_bad_envelope_codec",
    rdma_xtr_v1_cmq_test_envelope_attack_e attack =
      RDMA_CMQ_TEST_ENVELOPE_OUTSIDE_MASK
  );
    super.new(name);
    this.attack = attack;
  endfunction

  virtual function rdma_status encode(
    rdma_xtr_v1_cmq_envelope envelope,
    output rdma_hw_image image
  );
    rdma_status status;
    status = super.encode(envelope, image);
    if (status.ok() && image != null) begin
      case (attack)
        RDMA_CMQ_TEST_ENVELOPE_OUTSIDE_MASK:
          image.bytes[0] |= 8'h40; // logical qword-0 bit 62
        RDMA_CMQ_TEST_ENVELOPE_VALID:
          image.bytes[0] ^= 8'h80;
        RDMA_CMQ_TEST_ENVELOPE_VFID_OVERRIDE:
          image.bytes[0] ^= 8'h08;
        RDMA_CMQ_TEST_ENVELOPE_VFID:
          image.bytes[1] ^= 8'h01;
        RDMA_CMQ_TEST_ENVELOPE_WRAP:
          image.bytes[2] ^= 8'h20;
        RDMA_CMQ_TEST_ENVELOPE_INDEX:
          image.bytes[2] ^= 8'h01;
        RDMA_CMQ_TEST_ENVELOPE_MUTATE_INPUT:
          envelope.wrap ^= 1'b1;
      endcase
    end
    return status;
  endfunction
endclass

class rdma_xtr_v1_cmq_test_forged_body
    extends rdma_xtr_v1_cmq_body_image;
  `uvm_object_utils(rdma_xtr_v1_cmq_test_forged_body)

  function new(string name = "rdma_xtr_v1_cmq_test_forged_body");
    super.new(name);
  endfunction

  function void copy_and_relabel_attempt(rdma_hw_image source);
    copy(source);
  endfunction
endclass

class rdma_xtr_v1_cmq_duplicate_catcher extends uvm_report_catcher;
  bit caught;

  function new(string name = "rdma_xtr_v1_cmq_duplicate_catcher");
    super.new(name);
    caught = 1'b0;
  endfunction

  virtual function action_e catch();
    if (get_severity() == UVM_FATAL &&
        get_id() == "RDMA_CMQ_BODY_DUPLICATE") begin
      caught = 1'b1;
      return CAUGHT;
    end
    return THROW;
  endfunction
endclass

class rdma_xtr_v1_cmq_codec_test extends uvm_test;
  `uvm_component_utils(rdma_xtr_v1_cmq_codec_test)

  rdma_xtr_v1_cmq_body_registry ownership;
  rdma_xtr_v1_cmq_light_body_codec light;
  rdma_xtr_v1_cmq_request_composer composer;
  rdma_codec_registry context_registry;
  rdma_codec_registry qpc_registry;

  function new(string name = "rdma_xtr_v1_cmq_codec_test",
               uvm_component parent = null);
    super.new(name, parent);
  endfunction

  function automatic void expect_status(
    string label,
    rdma_status status,
    rdma_status_code_e expected
  );
    if (status == null)
      `uvm_error(label, "codec returned a null status")
    else if (status.code != expected)
      `uvm_error(label,
                 $sformatf("expected %s, got %s (%s)", expected.name(),
                           status.code.name(), status.convert2string()))
  endfunction

  function automatic void expect_ok(string label, rdma_status status);
    expect_status(label, status, RDMA_SC_OK);
  endfunction

  function automatic rdma_handle make_handle(
    string name,
    rdma_resource_kind_e kind,
    int unsigned object_id
  );
    rdma_handle handle;
    handle = rdma_handle::type_id::create(name);
    handle.kind = kind;
    handle.object_id = object_id;
    handle.function_uid = 64'h1111_2222_3333_4444;
    handle.generation = 7;
    return handle;
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

  function automatic rdma_page_table_layout make_page_layout(string name);
    rdma_page_table_layout layout;
    layout = rdma_page_table_layout::type_id::create(name);
    layout.mode = RDMA_OBJECT_INDIRECT_4K;
    layout.sd_base.value = 64'h0000_0000_0200_0000;
    layout.current_base.value = 64'h0000_0000_0200_1000;
    layout.current_valid = 1'b1;
    layout.next_base.value = 64'h0000_0000_0200_2000;
    layout.next_valid = 1'b1;
    return layout;
  endfunction

  function automatic rdma_cqc_model make_cqc();
    rdma_cqc_model cqc;
    cqc = rdma_cqc_model::type_id::create("cmq_cqc");
    cqc.cq_h = make_handle("cmq_cq", RDMA_RESOURCE_CQ, 21'h12_345);
    cqc.ceq_h = make_handle("cmq_cq_ceq", RDMA_RESOURCE_CEQ, 12'h234);
    cqc.state = RDMA_CONTEXT_VALID;
    cqc.depth = 1024;
    cqc.cqe_size_bytes = 64;
    cqc.threshold = 5;
    cqc.page_layout = make_page_layout("cmq_cqc_layout");
    cqc.producer = make_ring("cmq_cqc_pi", 17, 1'b1);
    cqc.consumer = make_ring("cmq_cqc_ci", 9, 1'b0);
    cqc.urc_enable = 1'b1;
    cqc.load_ci_done = 1'b1;
    cqc.last_arm_sequence = 2'd2;
    cqc.arm_sequence = 2'd1;
    cqc.arm_state = 2'd2;
    cqc.shadow_backing.value = 64'h0000_0000_0300_0040;
    return cqc;
  endfunction

  function automatic rdma_mrt_model make_mrt(
    string name,
    int unsigned stag_index,
    rdma_mr_pbl_mode_e pbl_mode = RDMA_MR_PBL0
  );
    rdma_mrt_model mrt;
    mrt = rdma_mrt_model::type_id::create(name);
    mrt.mr_h = make_handle({name, "_mr"}, RDMA_RESOURCE_MR, stag_index);
    mrt.pd_h = make_handle({name, "_pd"}, RDMA_RESOURCE_PD, 16'h3456);
    mrt.state = RDMA_CONTEXT_VALID;
    mrt.iova.value = 64'h0000_1000_2000_3000;
    mrt.length = 64'h12345;
    mrt.lkey = {stag_index[23:0], 8'ha5};
    mrt.rkey = mrt.lkey;
    mrt.access = '{local_write:1'b1, remote_read:1'b1,
                   remote_write:1'b0, memory_window_bind:1'b0,
                   remote_atomic:1'b0};
    mrt.object_type = 2'd0;
    mrt.page_layout.pbl_mode = pbl_mode;
    mrt.page_layout.host_page_size = RDMA_MR_PAGE_4K;
    mrt.page_layout.address_mode = RDMA_MR_ADDRESS_VA_BASED;
    mrt.page_layout.pba0.value = 64'h0000_0000_0400_0000;
    if (pbl_mode == RDMA_MR_PBL1)
      mrt.page_layout.pba1.value = 64'h0000_0000_0400_1000;
    else if (pbl_mode == RDMA_MR_PBL2) begin
      mrt.page_layout.pba0.value = 0;
      mrt.page_layout.first_pbl_index = 28'h123_4567;
    end
    mrt.page_layout.payload_vf_enable = 1'b1;
    mrt.page_layout.payload_vf_id = 8'h5a;
    mrt.page_layout.mr_serial = 12'h678;
    return mrt;
  endfunction

  function automatic rdma_srqc_model make_srqc();
    rdma_srqc_model srqc;
    srqc = rdma_srqc_model::type_id::create("cmq_srqc");
    srqc.srq_h = make_handle("cmq_srq", RDMA_RESOURCE_SRQ, 16'hcdef);
    srqc.pd_h = make_handle("cmq_srq_pd", RDMA_RESOURCE_PD, 16'h3456);
    srqc.state = RDMA_CONTEXT_VALID;
    srqc.depth = 256;
    srqc.load_pi_threshold = 8'h12;
    srqc.limit_threshold = 14'h234;
    srqc.object_mode = RDMA_OBJECT_INDIRECT_4K;
    srqc.srfq_backing.value = 64'h0000_0000_0500_0000;
    srqc.shadow_backing.value = 64'h0000_0000_0500_1000;
    srqc.producer = make_ring("cmq_srqc_pi", 8'h7f, 1'b1);
    srqc.arm_sequence = 2'd3;
    return srqc;
  endfunction

  function automatic rdma_ceqc_model make_ceqc();
    rdma_ceqc_model ceqc;
    ceqc = rdma_ceqc_model::type_id::create("cmq_ceqc");
    ceqc.ceq_h = make_handle("cmq_ceq", RDMA_RESOURCE_CEQ, 12'habc);
    ceqc.state = RDMA_CONTEXT_VALID;
    ceqc.depth = 1024;
    ceqc.vector_id = 16'h4321;
    ceqc.page_layout = make_page_layout("cmq_ceqc_layout");
    ceqc.page_layout.sd_base.value = 0;
    ceqc.producer = make_ring("cmq_ceqc_pi", 18'h123, 1'b1);
    ceqc.consumer = make_ring("cmq_ceqc_ci", 18'h45, 1'b0);
    return ceqc;
  endfunction

  function automatic rdma_aeqc_model make_aeqc();
    rdma_aeqc_model aeqc;
    aeqc = rdma_aeqc_model::type_id::create("cmq_aeqc");
    aeqc.aeq_h = make_handle("cmq_aeq", RDMA_RESOURCE_AEQ, 12'h789);
    aeqc.state = RDMA_CONTEXT_VALID;
    aeqc.depth = 1024;
    aeqc.vector_id = 16'h5678;
    aeqc.page_layout = make_page_layout("cmq_aeqc_layout");
    aeqc.page_layout.sd_base.value = 0;
    aeqc.producer = make_ring("cmq_aeqc_pi", 18'h67, 1'b0);
    aeqc.consumer = make_ring("cmq_aeqc_ci", 18'h89, 1'b1);
    return aeqc;
  endfunction

  function automatic rdma_codec_key context_key(bit [7:0] opcode);
    rdma_codec_key key;
    key.hw_version = "xtr_v1";
    key.opcode = opcode;
    case (opcode)
      XTR_V1_OP_KEY_ALLOC: begin
        key.image_kind = RDMA_IMAGE_MRT;
        key.object_type = "mrt";
        key.variant = "key_alloc";
      end
      XTR_V1_OP_MR_REGISTER: begin
        key.image_kind = RDMA_IMAGE_MRT;
        key.object_type = "mrt";
        key.variant = "register";
      end
      XTR_V1_OP_CQC_CREATE: begin
        key.image_kind = RDMA_IMAGE_CQC;
        key.object_type = "cqc";
        key.variant = "create";
      end
      XTR_V1_OP_CEQC_CREATE: begin
        key.image_kind = RDMA_IMAGE_CEQC;
        key.object_type = "ceqc";
        key.variant = "create";
      end
      XTR_V1_OP_AEQC_CREATE: begin
        key.image_kind = RDMA_IMAGE_AEQC;
        key.object_type = "aeqc";
        key.variant = "create";
      end
      XTR_V1_OP_SRFQC_CREATE: begin
        key.image_kind = RDMA_IMAGE_SRQC;
        key.object_type = "srqc";
        key.variant = "create";
      end
      default: begin
        key.image_kind = RDMA_IMAGE_NONE;
        key.object_type = "invalid";
        key.variant = "invalid";
      end
    endcase
    return key;
  endfunction

  function automatic rdma_hw_image encode_context(
    string label,
    bit [7:0] opcode,
    rdma_hw_model model
  );
    rdma_hw_image image;
    rdma_status status;
    status = composer.build_body(opcode, model, image);
    expect_ok({label, "_ENCODE"}, status);
    return image;
  endfunction

  function automatic bit [63:0] image_word(
    rdma_hw_image image,
    int unsigned qword_index
  );
    bit [63:0] word;
    word = '0;
    for (int unsigned i = 0; i < 8; i++)
      word[63 - (i * 8) -: 8] = image.bytes[(qword_index * 8) + i];
    return word;
  endfunction

  function automatic void expect_word(
    string label,
    rdma_hw_image image,
    int unsigned qword_index,
    bit [63:0] expected
  );
    bit [63:0] actual;
    if (image == null) begin
      `uvm_error(label, "image is null")
      return;
    end
    actual = image_word(image, qword_index);
    if (actual != expected)
      `uvm_error(label,
                 $sformatf("qword %0d expected %016x, got %016x",
                           qword_index, expected, actual))
  endfunction

  function automatic void set_image_word(
    rdma_hw_image image,
    int unsigned qword_index,
    bit [63:0] word
  );
    for (int unsigned i = 0; i < 8; i++)
      image.bytes[(qword_index * 8) + i] = word[63 - (i * 8) -: 8];
  endfunction

  function automatic bit [63:0] image_field(
    rdma_hw_image image,
    int unsigned word_byte_offset,
    int unsigned lsb,
    int unsigned width
  );
    bit [63:0] mask;
    mask = (width == 64) ? '1 : ((64'h1 << width) - 1);
    return (image_word(image, word_byte_offset >> 3) >> lsb) & mask;
  endfunction

  function automatic rdma_hw_image clone_image(
    rdma_hw_image source,
    string label
  );
    uvm_object cloned;
    rdma_hw_image copy;
    cloned = source.clone();
    if (cloned == null || !$cast(copy, cloned)) begin
      `uvm_error(label, "image clone failed")
      return null;
    end
    return copy;
  endfunction

  function automatic bit images_equal(
    rdma_hw_image lhs,
    rdma_hw_image rhs
  );
    if (lhs == null || rhs == null ||
        lhs.bytes.size() != rhs.bytes.size() ||
        lhs.field_summary.size() != rhs.field_summary.size())
      return 1'b0;
    if (lhs.length != rhs.length || lhs.alignment != rhs.alignment ||
        lhs.endian != rhs.endian || lhs.image_kind != rhs.image_kind ||
        lhs.hardware_version != rhs.hardware_version ||
        lhs.function_generation != rhs.function_generation ||
        lhs.write_target_kind != rhs.write_target_kind ||
        lhs.backing_target.value != rhs.backing_target.value ||
        lhs.hmc_target.value != rhs.hmc_target.value ||
        lhs.bar_target.value != rhs.bar_target.value)
      return 1'b0;
    foreach (lhs.bytes[i])
      if (lhs.bytes[i] != rhs.bytes[i]) return 1'b0;
    foreach (lhs.field_summary[i])
      if (lhs.field_summary[i] != rhs.field_summary[i]) return 1'b0;
    return 1'b1;
  endfunction

  function automatic rdma_xtr_v1_cmq_envelope snapshot_envelope(
    rdma_xtr_v1_cmq_envelope source,
    string label
  );
    rdma_xtr_v1_cmq_envelope snapshot;
    if (source == null) return null;
    snapshot = rdma_xtr_v1_cmq_envelope::type_id::create(label);
    snapshot.valid = source.valid;
    snapshot.vfid_override = source.vfid_override;
    snapshot.use_vfid = source.use_vfid;
    snapshot.wrap = source.wrap;
    snapshot.wqe_index = source.wqe_index;
    snapshot.opcode = source.opcode;
    return snapshot;
  endfunction

  function automatic bit envelopes_equal(
    rdma_xtr_v1_cmq_envelope lhs,
    rdma_xtr_v1_cmq_envelope rhs
  );
    if (lhs == null || rhs == null) return lhs == rhs;
    return lhs.valid == rhs.valid &&
           lhs.vfid_override == rhs.vfid_override &&
           lhs.use_vfid == rhs.use_vfid &&
           lhs.wrap == rhs.wrap &&
           lhs.wqe_index == rhs.wqe_index &&
           lhs.opcode == rhs.opcode;
  endfunction

  function automatic rdma_xtr_v1_cmq_envelope make_envelope(
    bit [7:0] opcode
  );
    rdma_xtr_v1_cmq_envelope envelope;
    envelope = rdma_xtr_v1_cmq_envelope::type_id::create("cmq_envelope");
    envelope.valid = 1'b1;
    envelope.vfid_override = 1'b1;
    envelope.use_vfid = 11'h345;
    envelope.wrap = 1'b1;
    envelope.wqe_index = 5'h1b;
    envelope.opcode = opcode;
    return envelope;
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

  function automatic rdma_qpc_model make_signature_qpc(
    int unsigned qpn = 21'h12345
  );
    rdma_qpc_model qpc;
    rdma_qpc_rc_ext ext;
    qpc = rdma_qpc_model::type_id::create("cmq_signature_qpc");
    qpc.qp_h = make_handle("cmq_signature_qp", RDMA_RESOURCE_QP, qpn);
    qpc.pd_h = make_handle("cmq_signature_pd", RDMA_RESOURCE_PD, 16'ha55a);
    qpc.send_cq_h = make_handle("cmq_signature_scq", RDMA_RESOURCE_CQ,
                                20'h15555);
    qpc.recv_cq_h = make_handle("cmq_signature_rcq", RDMA_RESOURCE_CQ,
                                20'h0aaaa);
    qpc.srq_h = make_handle("cmq_signature_srq", RDMA_RESOURCE_SRQ,
                            15'h4567);
    qpc.transport = RDMA_TRANSPORT_RC;
    qpc.state = RDMA_QPS_RTS;
    qpc.host_id = 5;
    qpc.vf_id = 12'habc;
    qpc.stat_index = 8'ha5;
    qpc.pkey = 16'hbeef;
    qpc.qp_sequence = 8'hc3;
    qpc.access.local_write = 1'b1;
    qpc.access.remote_read = 1'b1;
    qpc.access.remote_write = 1'b1;
    qpc.access.memory_window_bind = 1'b1;
    qpc.access.remote_atomic = 1'b1;
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
    qpc.behavior.\priority  = 0;
    qpc.address_vector.traffic_class = 8'haa;
    qpc.address_vector.destination_mac = 48'h1122_3344_5566;
    qpc.address_vector.vlan_id = 12'habc;
    qpc.address_vector.flow_label = 20'habcde;
    qpc.address_vector.hop_limit = 8'h40;
    qpc.address_vector.udp_source_port = 16'hc123;
    ext = rdma_qpc_rc_ext::type_id::create("cmq_signature_rc_ext");
    ext.remote_qpn = 24'h654321;
    ext.send_psn = 24'habcdef;
    ext.recv_psn = 24'h123456;
    ext.retry_count = 7;
    ext.rnr_retry_count = 7;
    qpc.transport_ext = ext;
    return qpc;
  endfunction

  function automatic rdma_qpc_model make_signature_ud_qpc(
    int unsigned qpn = 21'h12345
  );
    rdma_qpc_model qpc;
    rdma_qpc_ud_ext ext;
    byte unsigned ip[16] = '{8'h20,8'h01,8'h0d,8'hb8,
                              8'h00,8'h00,8'h00,8'h00,
                              8'h00,8'h00,8'h00,8'h00,
                              8'h00,8'h00,8'h00,8'h01};

    qpc = rdma_qpc_model::type_id::create("cmq_signature_ud_qpc");
    qpc.qp_h = make_handle("cmq_signature_ud_qp", RDMA_RESOURCE_QP, qpn);
    qpc.pd_h = make_handle("cmq_signature_ud_pd", RDMA_RESOURCE_PD,
                           16'h5aa5);
    qpc.send_cq_h = make_handle("cmq_signature_ud_scq", RDMA_RESOURCE_CQ,
                                20'h13579);
    qpc.recv_cq_h = make_handle("cmq_signature_ud_rcq", RDMA_RESOURCE_CQ,
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
    qpc.behavior.\priority  = 5;
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
    ext = rdma_qpc_ud_ext::type_id::create("cmq_signature_ud_ext");
    ext.qkey = 32'h89abcdef;
    qpc.transport_ext = ext;
    return qpc;
  endfunction

  function automatic rdma_qpc_model make_signature_urc_qpc(
    int unsigned qpn = 21'h12345
  );
    rdma_qpc_model qpc;
    rdma_qpc_urc_ext ext;

    qpc = rdma_qpc_model::type_id::create("cmq_signature_urc_qpc");
    qpc.qp_h = make_handle("cmq_signature_urc_qp", RDMA_RESOURCE_QP, qpn);
    qpc.pd_h = make_handle("cmq_signature_urc_pd", RDMA_RESOURCE_PD,
                           16'hffff);
    qpc.send_cq_h = make_handle("cmq_signature_urc_scq", RDMA_RESOURCE_CQ,
                                20'hfffff);
    qpc.recv_cq_h = make_handle("cmq_signature_urc_rcq", RDMA_RESOURCE_CQ,
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
    qpc.behavior.\priority  = 0;
    qpc.address_vector.traffic_class = 8'hfe;
    ext = rdma_qpc_urc_ext::type_id::create("cmq_signature_urc_ext");
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

  function automatic rdma_hw_image make_qpc_signature_source(
    int unsigned qpn = 21'h12345,
    string variant = "rc"
  );
    rdma_codec_base codec;
    rdma_qpc_model qpc;
    rdma_hw_image image;
    rdma_status status;
    status = qpc_registry.lookup(qpc_key(variant), codec);
    expect_ok("QPC_SIGNATURE_SOURCE_LOOKUP", status);
    if (codec == null) begin
      `uvm_error("QPC_SIGNATURE_SOURCE", "QPC codec lookup returned null")
      return null;
    end
    case (variant)
      "rc": qpc = make_signature_qpc(qpn);
      "ud": qpc = make_signature_ud_qpc(qpn);
      "urc": qpc = make_signature_urc_qpc(qpn);
      default: qpc = null;
    endcase
    status = codec.encode(qpc, image);
    expect_ok("QPC_SIGNATURE_SOURCE_ENCODE", status);
    if (image == null)
      `uvm_error("QPC_SIGNATURE_SOURCE", "QPC codec published null")
    return image;
  endfunction

  function automatic rdma_xtr_v1_qpc_command_body make_qpc_body(
    string name,
    bit [7:0] opcode,
    bit [1:0] modify_mode = XTR_V1_QPC_MODIFY_STATE_ONLY
  );
    rdma_xtr_v1_qpc_command_body body;
    body = rdma_xtr_v1_qpc_command_body::type_id::create(name);
    body.qp_h = make_handle({name, "_qp"}, RDMA_RESOURCE_QP, 21'h12345);
    case (opcode)
      XTR_V1_OP_QPC_CREATE: begin
        body.send_cq_h = make_handle({name, "_scq"}, RDMA_RESOURCE_CQ,
                                     21'h15555);
        body.recv_cq_h = make_handle({name, "_rcq"}, RDMA_RESOURCE_CQ,
                                     21'h0aaaa);
        body.qpc_buffer.value = 64'h0000_2468_ace0_0000;
      end
      XTR_V1_OP_QPC_MODIFY: begin
        body.send_cq_h = make_handle({name, "_scq"}, RDMA_RESOURCE_CQ,
                                     21'h15555);
        body.recv_cq_h = make_handle({name, "_rcq"}, RDMA_RESOURCE_CQ,
                                     21'h0aaaa);
        body.next_state = RDMA_QPS_RTS;
        if (modify_mode == XTR_V1_QPC_MODIFY_FULL) begin
          body.full_modify = 1'b1;
          body.qpc_buffer.value = 64'h0000_2468_ace0_0000;
        end
        else if (modify_mode == XTR_V1_QPC_MODIFY_PARTIAL) begin
          body.partial_modify = 1'b1;
          body.wbe_template_count = 2'd1;
          for (int unsigned i = 0; i < 4; i++) begin
            body.modify_start_qword[i] = 6'(i * 7 + 2);
            body.modify_wbe[i] = 8'h81 >> i;
            body.modify_data[i] = 64'h1020_3040_5060_7080 ^ i;
          end
        end
      end
      XTR_V1_OP_QPC_DELETE: begin
        body.send_cq_h = make_handle({name, "_scq"}, RDMA_RESOURCE_CQ,
                                     21'h15555);
        body.recv_cq_h = make_handle({name, "_rcq"}, RDMA_RESOURCE_CQ,
                                     21'h0aaaa);
      end
      XTR_V1_OP_QPC_QUERY:
        body.qpc_buffer.value = 64'h0000_2468_ace0_0000;
      default: ;
    endcase
    return body;
  endfunction

  function automatic rdma_xtr_v1_object_id_command_body make_object_body(
    string name,
    rdma_resource_kind_e kind,
    int unsigned object_id
  );
    rdma_xtr_v1_object_id_command_body body;
    body = rdma_xtr_v1_object_id_command_body::type_id::create(name);
    body.object_h = make_handle({name, "_handle"}, kind, object_id);
    return body;
  endfunction

  function automatic rdma_xtr_v1_occ_flush_body make_occ_vf(string name);
    rdma_xtr_v1_occ_flush_body body;
    body = rdma_xtr_v1_occ_flush_body::type_id::create(name);
    body.vf_flush = 1'b1;
    body.qpc = 1'b1;
    body.cqc = 1'b1;
    body.mrt = 1'b1;
    body.pble = 1'b1;
    body.sqrqe = 1'b1;
    body.sgb_irqe = 1'b1;
    body.eirqe = 1'b1;
    body.orqe = 1'b1;
    body.uaqe = 1'b1;
    return body;
  endfunction

  function automatic rdma_xtr_v1_occ_flush_body make_occ_serial(
    string name
  );
    rdma_xtr_v1_occ_flush_body body;
    body = rdma_xtr_v1_occ_flush_body::type_id::create(name);
    body.mr_serial_flush = 1'b1;
    body.pble = 1'b1;
    body.mr_serial = 12'habc;
    return body;
  endfunction

  function automatic rdma_xtr_v1_occ_flush_body make_occ_qpn(string name);
    rdma_xtr_v1_occ_flush_body body;
    body = rdma_xtr_v1_occ_flush_body::type_id::create(name);
    body.qpn = 21'h12345;
    body.eirqe = 1'b1;
    body.orqe = 1'b1;
    body.uaqe = 1'b1;
    return body;
  endfunction

  function automatic rdma_xtr_v1_occ_flush_body make_occ_qpn_pd(
    string name
  );
    rdma_xtr_v1_occ_flush_body body;
    body = rdma_xtr_v1_occ_flush_body::type_id::create(name);
    body.qpn = 21'h12345;
    body.pd = 1'b1;
    body.pd_backing.value = 64'h0000_0000_0600_0000;
    return body;
  endfunction

  function automatic rdma_xtr_v1_occ_flush_body make_occ_pd(string name);
    rdma_xtr_v1_occ_flush_body body;
    body = rdma_xtr_v1_occ_flush_body::type_id::create(name);
    body.pd = 1'b1;
    body.pd_backing.value = 64'h0000_0000_0600_0000;
    return body;
  endfunction

  function automatic rdma_hw_image encode_light(
    string label,
    bit [7:0] opcode,
    rdma_hw_model model
  );
    rdma_hw_image image;
    rdma_status status;
    status = composer.build_body(opcode, model, image);
    expect_ok({label, "_ENCODE"}, status);
    if (image == null)
      `uvm_error(label, "successful light encode published null")
    return image;
  endfunction

  function automatic void expect_light_failure(
    string label,
    bit [7:0] opcode,
    rdma_hw_model model,
    rdma_status_code_e expected
  );
    rdma_hw_image image;
    rdma_status status;
    image = rdma_hw_image::type_id::create({label, "_sentinel"});
    status = light.encode(opcode, model, image);
    expect_status(label, status, expected);
    if (image != null)
      `uvm_error(label, "failed light encode published an image")
  endfunction

  function automatic void check_envelope_oracle();
    rdma_xtr_v1_cmq_envelope envelope;
    rdma_xtr_v1_cmq_envelope_codec envelope_codec;
    rdma_hw_image image;
    rdma_status status;
    bit [63:0] expected;

    envelope = make_envelope(XTR_V1_OP_OCC_FLUSH);
    envelope_codec = rdma_xtr_v1_cmq_envelope_codec::type_id::create(
      "envelope_oracle_codec");
    status = envelope_codec.encode(envelope, image);
    expect_ok("ENVELOPE_ORACLE_ENCODE", status);
    expected = (64'h1 << 63) | (64'h1 << 59) | (64'h345 << 48) |
               (64'h1 << 45) | (64'h1b << 40) |
               (64'(XTR_V1_OP_OCC_FLUSH) << 32);
    expect_word("ENVELOPE_ORACLE", image, 0, expected);
    for (int unsigned q = 1; q < 8; q++)
      expect_word("ENVELOPE_ORACLE", image, q, 0);
  endfunction

  function automatic void check_ownership_oracles();
    bit [7:0] opcodes[12] = '{
      XTR_V1_OP_QPC_CREATE,
      XTR_V1_OP_QPC_MODIFY,
      XTR_V1_OP_QPC_DELETE,
      XTR_V1_OP_QPC_QUERY,
      XTR_V1_OP_KEY_ALLOC,
      XTR_V1_OP_MR_REGISTER,
      XTR_V1_OP_MR_DEREGISTER,
      XTR_V1_OP_OCC_FLUSH,
      XTR_V1_OP_CQC_DELETE,
      XTR_V1_OP_CEQC_DELETE,
      XTR_V1_OP_SRFQC_DELETE,
      XTR_V1_OP_TQ_FLUSH
    };
    rdma_image_kind_e expected_kinds[12] = '{
      RDMA_IMAGE_CMQ_SQE,
      RDMA_IMAGE_CMQ_SQE,
      RDMA_IMAGE_CMQ_SQE,
      RDMA_IMAGE_CMQ_SQE,
      RDMA_IMAGE_MRT,
      RDMA_IMAGE_MRT,
      RDMA_IMAGE_CMQ_SQE,
      RDMA_IMAGE_CMQ_SQE,
      RDMA_IMAGE_CMQ_SQE,
      RDMA_IMAGE_CMQ_SQE,
      RDMA_IMAGE_CMQ_SQE,
      RDMA_IMAGE_CMQ_SQE
    };
    string labels[12] = '{
      "QPC create", "QPC modify", "QPC delete", "QPC query",
      "MRT key allocate", "MRT register", "MR deregister", "OCC flush",
      "CQ object ID",
      "EQ object ID", "SRQ object ID", "empty body"
    };
    bit [63:0] expected_masks[12][8] = '{
      '{64'h0000000000ffffff, 64'hfffff801ff1fffff,
        64'h0000000000000000, 64'hfffffffffffffe00,
        64'h0000000000000000, 64'h0000000000000000,
        64'h0000000000000000, 64'h0000000000000000},
      '{64'h7000000000ffffff, 64'hfffff801ff1fffff,
        64'hffffffff3fff3fff, 64'hfffffffffffffe00,
        64'hffffffffffffffff, 64'hffffffffffffffff,
        64'hffffffffffffffff, 64'hffffffffffffffff},
      '{64'h0000000000ffffff, 64'hfffff800001fffff,
        64'h0000000000000000, 64'h0000000000000000,
        64'h0000000000000000, 64'h0000000000000000,
        64'h0000000000000000, 64'h0000000000000000},
      '{64'h0000000000ffffff, 64'h0000000000000000,
        64'h0000000000000000, 64'hfffffffffffffe00,
        64'h0000000000000000, 64'h0000000000000000,
        64'h0000000000000000, 64'h0000000000000000},
      '{64'h6000000000ffffff, 64'h00000000ff000000,
        64'hffffffffffffffff, 64'hff00bfffffffffff,
        64'hffffffffffffffff, 64'hfffffffffffff000,
        64'hffffffffffffffff, 64'h0000000000000000},
      '{64'h6000000000ffffff, 64'h00000000ff000000,
        64'hffffffffff000000, 64'hff00bfffffffffff,
        64'hffffffffffffffff, 64'hfffffffffffff000,
        64'hffffffffffffffff, 64'h0000000000000000},
      '{64'h6000000000ffffff, 64'h00000000ff000000,
        64'h0000000000000000, 64'h0000000000000000,
        64'h0000000000000000, 64'h0000000000000000,
        64'h0000000000000000, 64'h0000000000000000},
      '{64'h30000000001fffff, 64'hffc00fff00000000,
        64'hfffffffffffff000, 64'h0000000000000000,
        64'h0000000000000000, 64'h0000000000000000,
        64'h0000000000000000, 64'h0000000000000000},
      '{64'h00000000001fffff, 64'h0000000000000000,
        64'h0000000000000000, 64'h0000000000000000,
        64'h0000000000000000, 64'h0000000000000000,
        64'h0000000000000000, 64'h0000000000000000},
      '{64'h0000000000000fff, 64'h0000000000000000,
        64'h0000000000000000, 64'h0000000000000000,
        64'h0000000000000000, 64'h0000000000000000,
        64'h0000000000000000, 64'h0000000000000000},
      '{64'h000000000000ffff, 64'h0000000000000000,
        64'h0000000000000000, 64'h0000000000000000,
        64'h0000000000000000, 64'h0000000000000000,
        64'h0000000000000000, 64'h0000000000000000},
      '{64'h0000000000000000, 64'h0000000000000000,
        64'h0000000000000000, 64'h0000000000000000,
        64'h0000000000000000, 64'h0000000000000000,
        64'h0000000000000000, 64'h0000000000000000}
    };
    rdma_image_kind_e actual_kind;
    bit [63:0] actual_masks[8];
    rdma_status status;

    foreach (opcodes[case_index]) begin
      status = ownership.lookup(opcodes[case_index], actual_kind,
                                actual_masks);
      expect_ok({"OWNERSHIP_ORACLE_", labels[case_index]}, status);
      if (!status.ok()) continue;
      if (actual_kind != expected_kinds[case_index])
        `uvm_error("OWNERSHIP_ORACLE",
                   $sformatf("%s kind %s, expected %s",
                             labels[case_index], actual_kind.name(),
                             expected_kinds[case_index].name()))
      foreach (actual_masks[q]) begin
        if (actual_masks[q] != expected_masks[case_index][q])
          `uvm_error("OWNERSHIP_ORACLE",
                     $sformatf(
                       "%s qword %0d mask 0x%016x, expected 0x%016x",
                       labels[case_index], q, actual_masks[q],
                       expected_masks[case_index][q]))
      end
    end
  endfunction

  function automatic void check_canonical_result(
    string label,
    bit [7:0] opcode,
    rdma_hw_image body,
    rdma_hw_image result,
    bit signature_changes = 1'b0
  );
    rdma_image_kind_e input_kind;
    bit [63:0] masks[8];
    bit [63:0] body_expected;
    bit [63:0] actual;
    bit [63:0] signature_mask;
    rdma_status status;

    if (result == null) begin
      `uvm_error(label, "composition published null")
      return;
    end
    if (result.length != 64 || result.bytes.size() != 64 ||
        result.alignment != 64 || result.endian != RDMA_ENDIAN_BIG ||
        result.image_kind != RDMA_IMAGE_CMQ_SQE ||
        result.hardware_version != XTR_V1_HW_VERSION ||
        result.function_generation != body.function_generation ||
        result.write_target_kind != RDMA_HW_TARGET_NONE ||
        result.backing_target.value != 0 || result.hmc_target.value != 0 ||
        result.bar_target.value != 0)
      `uvm_error(label, "composed image metadata is not canonical")
    if (image_field(result, XTR_V1_CMQ_OPCODE_WORD_BYTE_OFFSET,
                    XTR_V1_CMQ_OPCODE_LSB,
                    XTR_V1_CMQ_OPCODE_WIDTH) != opcode)
      `uvm_error(label, "final request does not contain the exact opcode")

    status = ownership.lookup(opcode, input_kind, masks);
    expect_ok({label, "_OWNERSHIP_LOOKUP"}, status);
    signature_mask = 64'hff << XTR_V1_CMQ_SIGNATURE_LSB;
    for (int unsigned q = 0; q < 8; q++) begin
      actual = image_word(result, q);
      if ((actual & ~(request_envelope_mask(q) | masks[q])) != 0)
        `uvm_error(label,
                   $sformatf("qword %0d sets an unowned bit", q))
      body_expected = image_word(body, q) & masks[q];
      if (signature_changes && q == 1) begin
        if ((actual & masks[q] & ~signature_mask) !=
            (body_expected & ~signature_mask))
          `uvm_error(label, "composer changed non-signature body bits")
      end
      else if ((actual & masks[q]) != body_expected)
        `uvm_error(label,
                   $sformatf("composer changed body-owned qword %0d", q))
    end
  endfunction

  function automatic rdma_hw_image compose_ok(
    string label,
    bit [7:0] opcode,
    rdma_hw_image body,
    rdma_hw_image qpc_source = null,
    bit signature_changes = 1'b0
  );
    rdma_xtr_v1_cmq_envelope envelope;
    rdma_xtr_v1_cmq_envelope envelope_snapshot;
    rdma_hw_image result;
    rdma_hw_image body_snapshot;
    rdma_hw_image qpc_snapshot;
    rdma_status status;

    envelope = make_envelope(opcode);
    envelope_snapshot = snapshot_envelope(
      envelope, {label, "_ENVELOPE_SNAPSHOT"});
    body_snapshot = clone_image(body, {label, "_BODY_SNAPSHOT"});
    if (qpc_source != null)
      qpc_snapshot = clone_image(qpc_source, {label, "_QPC_SNAPSHOT"});
    result = rdma_hw_image::type_id::create({label, "_sentinel"});
    status = composer.compose_request(envelope, body, qpc_source, result);
    expect_ok({label, "_COMPOSE"}, status);
    check_canonical_result(label, opcode, body, result, signature_changes);
    if (!envelopes_equal(envelope, envelope_snapshot))
      `uvm_error(label, "composer mutated the envelope input")
    if (!images_equal(body, body_snapshot))
      `uvm_error(label, "composer mutated the body input")
    if (qpc_source != null && !images_equal(qpc_source, qpc_snapshot))
      `uvm_error(label, "composer mutated the QPC signature source")
    return result;
  endfunction

  function automatic void expect_compose_failure(
    string label,
    rdma_xtr_v1_cmq_request_composer selected_composer,
    rdma_xtr_v1_cmq_envelope envelope,
    rdma_hw_image body,
    rdma_hw_image qpc_source,
    rdma_status_code_e expected
  );
    rdma_xtr_v1_cmq_envelope envelope_snapshot;
    rdma_hw_image result;
    rdma_hw_image body_snapshot;
    rdma_hw_image qpc_snapshot;
    rdma_status status;
    envelope_snapshot = snapshot_envelope(
      envelope, {label, "_ENVELOPE_SNAPSHOT"});
    body_snapshot = clone_image(body, {label, "_BODY_SNAPSHOT"});
    if (qpc_source != null)
      qpc_snapshot = clone_image(qpc_source, {label, "_QPC_SNAPSHOT"});
    result = rdma_hw_image::type_id::create({label, "_sentinel"});
    status = selected_composer.compose_request(envelope, body, qpc_source,
                                               result);
    expect_status(label, status, expected);
    if (result != null)
      `uvm_error(label, "failed composition published a result")
    if (!envelopes_equal(envelope, envelope_snapshot))
      `uvm_error(label, "failed composition mutated envelope input")
    if (!images_equal(body, body_snapshot))
      `uvm_error(label, "failed composition mutated body input")
    if (qpc_source != null && !images_equal(qpc_source, qpc_snapshot))
      `uvm_error(label, "failed composition mutated QPC input")
  endfunction

  function automatic void check_signature(
    string label,
    bit [7:0] opcode,
    rdma_hw_image body,
    rdma_hw_image qpc_source
  );
    rdma_xtr_v1_cmq_envelope envelope;
    rdma_xtr_v1_cmq_envelope_codec envelope_codec;
    rdma_hw_image envelope_image;
    rdma_hw_image result;
    rdma_status status;
    byte unsigned expected_signature;
    byte unsigned final_xor;
    bit [63:0] unsigned_word;

    envelope = make_envelope(opcode);
    envelope_codec = rdma_xtr_v1_cmq_envelope_codec::type_id::create(
      {label, "_envelope_codec"});
    status = envelope_codec.encode(envelope, envelope_image);
    expect_ok({label, "_ENVELOPE"}, status);
    expected_signature = 8'h00;
    for (int unsigned q = 0; q < 8; q++) begin
      unsigned_word = image_word(envelope_image, q) | image_word(body, q);
      if (q == 1)
        unsigned_word &= ~(64'hff << XTR_V1_CMQ_SIGNATURE_LSB);
      for (int unsigned i = 0; i < 8; i++)
        expected_signature ^= unsigned_word[63 - (i * 8) -: 8];
    end
    foreach (qpc_source.bytes[i])
      expected_signature ^= qpc_source.bytes[i];
    expected_signature = ~expected_signature;

    result = compose_ok(label, opcode, body, qpc_source, 1'b1);
    if (image_field(result, XTR_V1_CMQ_SIGNATURE_WORD_BYTE_OFFSET,
                    XTR_V1_CMQ_SIGNATURE_LSB,
                    XTR_V1_CMQ_SIGNATURE_WIDTH) != expected_signature)
      `uvm_error(label, "composer signature differs from independent oracle")
    final_xor = 8'h00;
    foreach (result.bytes[i]) final_xor ^= result.bytes[i];
    foreach (qpc_source.bytes[i]) final_xor ^= qpc_source.bytes[i];
    if (final_xor != 8'hff)
      `uvm_error(label,
                 $sformatf("final WQE+QPC XOR is %02x, expected ff",
                           final_xor))
  endfunction

  function automatic void check_all_supported();
    rdma_xtr_v1_qpc_command_body qpc_body;
    rdma_xtr_v1_object_id_command_body object_body;
    rdma_xtr_v1_mr_deregister_body dereg_body;
    rdma_xtr_v1_occ_flush_body occ_body;
    rdma_hw_image body;
    rdma_hw_image key_zero_image;
    rdma_hw_image register_zero_image;
    rdma_hw_image key_nonzero_image;
    rdma_hw_image key_pbl1_image;
    rdma_hw_image key_pbl2_image;
    rdma_hw_image qpc_source;
    rdma_hw_image result;
    rdma_status status;
    rdma_xtr_v1_cmq_envelope envelope;
    rdma_mrt_model mrt_zero;

    qpc_source = make_qpc_signature_source();

    qpc_body = make_qpc_body("qpc_create_body", XTR_V1_OP_QPC_CREATE);
    body = encode_light("QPC_CREATE", XTR_V1_OP_QPC_CREATE, qpc_body);
    expect_word("QPC_CREATE_BODY", body, 0, 64'h0000_0000_0001_2345);
    expect_word("QPC_CREATE_BODY", body, 1,
                (64'h15555 << 43) | (64'h1 << 32) | 64'h0aaaa);
    expect_word("QPC_CREATE_BODY", body, 2, 0);
    expect_word("QPC_CREATE_BODY", body, 3,
                64'h0000_2468_ace0_0000);
    for (int unsigned q = 4; q < 8; q++)
      expect_word("QPC_CREATE_BODY", body, q, 0);
    if (image_field(body, XTR_V1_CMQ_SIGNATURE_WORD_BYTE_OFFSET,
                    XTR_V1_CMQ_SIGNATURE_LSB,
                    XTR_V1_CMQ_SIGNATURE_WIDTH) != 0)
      `uvm_error("QPC_CREATE", "unsigned body signature is not zero")
    check_signature("QPC_CREATE", XTR_V1_OP_QPC_CREATE, body, qpc_source);

    qpc_body = make_qpc_body("qpc_full_modify_body",
                             XTR_V1_OP_QPC_MODIFY,
                             XTR_V1_QPC_MODIFY_FULL);
    body = encode_light("QPC_MODIFY_FULL", XTR_V1_OP_QPC_MODIFY,
                        qpc_body);
    expect_word("QPC_MODIFY_FULL_BODY", body, 0,
                (64'h3 << 60) | 64'h12345);
    expect_word("QPC_MODIFY_FULL_BODY", body, 1,
                (64'h15555 << 43) | (64'h1 << 32) | 64'h0aaaa);
    expect_word("QPC_MODIFY_FULL_BODY", body, 2,
                64'h1 << 62);
    expect_word("QPC_MODIFY_FULL_BODY", body, 3,
                64'h0000_2468_ace0_0000);
    for (int unsigned q = 4; q < 8; q++)
      expect_word("QPC_MODIFY_FULL_BODY", body, q, 0);
    check_signature("QPC_MODIFY_FULL", XTR_V1_OP_QPC_MODIFY, body,
                    qpc_source);

    qpc_body = make_qpc_body("qpc_state_modify_body",
                             XTR_V1_OP_QPC_MODIFY);
    body = encode_light("QPC_MODIFY_STATE", XTR_V1_OP_QPC_MODIFY,
                        qpc_body);
    expect_word("QPC_MODIFY_STATE_BODY", body, 0,
                (64'h3 << 60) | 64'h12345);
    expect_word("QPC_MODIFY_STATE_BODY", body, 1,
                (64'h15555 << 43) | 64'h0aaaa);
    expect_word("QPC_MODIFY_STATE_BODY", body, 2, 0);
    for (int unsigned q = 3; q < 8; q++)
      expect_word("QPC_MODIFY_STATE_BODY", body, q, 0);
    void'(compose_ok("QPC_MODIFY_STATE", XTR_V1_OP_QPC_MODIFY, body));

    qpc_body = make_qpc_body("qpc_partial_modify_body",
                             XTR_V1_OP_QPC_MODIFY,
                             XTR_V1_QPC_MODIFY_PARTIAL);
    body = encode_light("QPC_MODIFY_PARTIAL", XTR_V1_OP_QPC_MODIFY,
                        qpc_body);
    expect_word("QPC_MODIFY_PARTIAL_BODY", body, 0,
                (64'h3 << 60) | 64'h12345);
    expect_word("QPC_MODIFY_PARTIAL_BODY", body, 1,
                (64'h15555 << 43) | 64'h0aaaa);
    expect_word("QPC_MODIFY_PARTIAL_BODY", body, 2,
                (64'h2 << 62) | (64'h2 << 56) | (64'h81 << 48) |
                (64'h1 << 46) | (64'h9 << 40) | (64'h40 << 32) |
                (64'h10 << 24) | (64'h20 << 16) | (64'h17 << 8) |
                64'h10);
    expect_word("QPC_MODIFY_PARTIAL_BODY", body, 3, 0);
    for (int unsigned q = 4; q < 8; q++)
      expect_word("QPC_MODIFY_PARTIAL_BODY", body, q,
                  64'h1020_3040_5060_7080 ^ (q - 4));
    if (image_field(body, XTR_V1_CMQ_SIGN_EN_WORD_BYTE_OFFSET,
                    XTR_V1_CMQ_SIGN_EN_LSB,
                    XTR_V1_CMQ_SIGN_EN_WIDTH) != 0 ||
        image_field(body, XTR_V1_CMQ_SIGNATURE_WORD_BYTE_OFFSET,
                    XTR_V1_CMQ_SIGNATURE_LSB,
                    XTR_V1_CMQ_SIGNATURE_WIDTH) != 0)
      `uvm_error("QPC_MODIFY_PARTIAL",
                 "partial modify unexpectedly enables a signature")
    envelope = make_envelope(XTR_V1_OP_QPC_MODIFY);
    expect_compose_failure("PARTIAL_REJECTS_QPC_SOURCE", composer, envelope,
                           body, qpc_source, RDMA_SC_CODEC_ERROR);
    void'(compose_ok("QPC_MODIFY_PARTIAL", XTR_V1_OP_QPC_MODIFY, body));

    qpc_body = make_qpc_body("qpc_delete_body", XTR_V1_OP_QPC_DELETE);
    body = encode_light("QPC_DELETE", XTR_V1_OP_QPC_DELETE, qpc_body);
    expect_word("QPC_DELETE_BODY", body, 0, 64'h12345);
    expect_word("QPC_DELETE_BODY", body, 1,
                (64'h15555 << 43) | 64'h0aaaa);
    for (int unsigned q = 2; q < 8; q++)
      expect_word("QPC_DELETE_BODY", body, q, 0);
    void'(compose_ok("QPC_DELETE", XTR_V1_OP_QPC_DELETE, body));

    qpc_body = make_qpc_body("qpc_query_body", XTR_V1_OP_QPC_QUERY);
    body = encode_light("QPC_QUERY", XTR_V1_OP_QPC_QUERY, qpc_body);
    void'(compose_ok("QPC_QUERY", XTR_V1_OP_QPC_QUERY, body));

    qpc_body = make_qpc_body("qpc_minimal_query_body",
                             XTR_V1_OP_QPC_QUERY);
    body = encode_light("QPC_MINIMAL_QUERY", XTR_V1_OP_QPC_QUERY,
                        qpc_body);
    if (body == null)
      `uvm_error("QPC_MINIMAL_QUERY", "valid minimal query published null")
    else begin
      expect_word("QPC_MINIMAL_QUERY_BODY", body, 0, 64'h0000_0000_0001_2345);
      expect_word("QPC_MINIMAL_QUERY_BODY", body, 1, 64'h0);
      expect_word("QPC_MINIMAL_QUERY_BODY", body, 2, 64'h0);
      expect_word("QPC_MINIMAL_QUERY_BODY", body, 3,
                  64'h0000_2468_ace0_0000);
      for (int unsigned q = 4; q < 8; q++)
        expect_word("QPC_MINIMAL_QUERY_BODY", body, q, 64'h0);
      void'(compose_ok("QPC_MINIMAL_QUERY", XTR_V1_OP_QPC_QUERY, body));
    end

    mrt_zero = make_mrt("mrt_zero", 0);
    key_zero_image = encode_context("KEY_ALLOC_ZERO", XTR_V1_OP_KEY_ALLOC,
                                    mrt_zero);
    register_zero_image = encode_context("MR_REGISTER_ZERO",
                                         XTR_V1_OP_MR_REGISTER, mrt_zero);
    if (!images_equal(key_zero_image, register_zero_image))
      `uvm_error("STAG0_PROVENANCE",
                 "STAG0 key/register precondition is not byte-identical")
    void'(compose_ok("KEY_ALLOC_ZERO", XTR_V1_OP_KEY_ALLOC,
                     key_zero_image));
    void'(compose_ok("MR_REGISTER_ZERO", XTR_V1_OP_MR_REGISTER,
                     register_zero_image));
    key_nonzero_image = encode_context("KEY_ALLOC_NONZERO",
                                       XTR_V1_OP_KEY_ALLOC,
                                       make_mrt("mrt_nonzero", 1));
    key_pbl1_image = encode_context(
      "KEY_ALLOC_PBL1", XTR_V1_OP_KEY_ALLOC,
      make_mrt("mrt_key_pbl1", 24'h123456, RDMA_MR_PBL1));
    if (key_pbl1_image != null)
      void'(compose_ok("KEY_ALLOC_PBL1", XTR_V1_OP_KEY_ALLOC,
                       key_pbl1_image));
    key_pbl2_image = encode_context(
      "KEY_ALLOC_PBL2", XTR_V1_OP_KEY_ALLOC,
      make_mrt("mrt_key_pbl2", 24'h654321, RDMA_MR_PBL2));
    if (key_pbl2_image != null)
      void'(compose_ok("KEY_ALLOC_PBL2", XTR_V1_OP_KEY_ALLOC,
                       key_pbl2_image));
    envelope = make_envelope(XTR_V1_OP_MR_REGISTER);
    expect_compose_failure("KEY_ALLOC_NONZERO_AS_REGISTER", composer,
                           envelope, key_nonzero_image, null,
                           RDMA_SC_CODEC_ERROR);

    dereg_body = rdma_xtr_v1_mr_deregister_body::type_id::create(
      "mr_deregister_body");
    dereg_body.mr_h = make_handle("dereg_mr", RDMA_RESOURCE_MR, 24'h654321);
    dereg_body.stag_key = 8'hd3;
    dereg_body.next_state = RDMA_CONTEXT_VALID;
    body = encode_light("MR_DEREGISTER", XTR_V1_OP_MR_DEREGISTER,
                        dereg_body);
    expect_word("MR_DEREGISTER_BODY", body, 0, 64'h4000_0000_0065_4321);
    expect_word("MR_DEREGISTER_BODY", body, 1, 64'h0000_0000_d300_0000);
    for (int unsigned q = 2; q < 8; q++)
      expect_word("MR_DEREGISTER_BODY", body, q, 0);
    void'(compose_ok("MR_DEREGISTER", XTR_V1_OP_MR_DEREGISTER, body));

    occ_body = make_occ_vf("occ_vf_flush");
    body = encode_light("OCC_VF_FLUSH", XTR_V1_OP_OCC_FLUSH, occ_body);
    expect_word("OCC_VF_FLUSH", body, 0, 64'h2000_0000_0000_0000);
    expect_word("OCC_VF_FLUSH", body, 1, 64'hff80_0000_0000_0000);
    void'(compose_ok("OCC_VF_FLUSH", XTR_V1_OP_OCC_FLUSH, body));

    occ_body = make_occ_serial("occ_serial_flush");
    body = encode_light("OCC_SERIAL_FLUSH", XTR_V1_OP_OCC_FLUSH, occ_body);
    expect_word("OCC_SERIAL_FLUSH", body, 0, 64'h1000_0000_0000_0000);
    expect_word("OCC_SERIAL_FLUSH", body, 1, 64'h1000_0abc_0000_0000);
    void'(compose_ok("OCC_SERIAL_FLUSH", XTR_V1_OP_OCC_FLUSH, body));

    occ_body = make_occ_qpn("occ_qpn_flush");
    body = encode_light("OCC_QPN_FLUSH", XTR_V1_OP_OCC_FLUSH, occ_body);
    expect_word("OCC_QPN_FLUSH", body, 0, 64'h0000_0000_0001_2345);
    expect_word("OCC_QPN_FLUSH", body, 1, 64'h0380_0000_0000_0000);
    void'(compose_ok("OCC_QPN_FLUSH", XTR_V1_OP_OCC_FLUSH, body));

    occ_body = make_occ_qpn_pd("occ_qpn_pd_flush");
    body = encode_light("OCC_QPN_PD_FLUSH", XTR_V1_OP_OCC_FLUSH, occ_body);
    expect_word("OCC_QPN_PD_FLUSH", body, 0, 64'h0000_0000_0001_2345);
    expect_word("OCC_QPN_PD_FLUSH", body, 1, 64'h0040_0000_0000_0000);
    expect_word("OCC_QPN_PD_FLUSH", body, 2,
                64'h0000_0000_0600_0000);
    void'(compose_ok("OCC_QPN_PD_FLUSH", XTR_V1_OP_OCC_FLUSH, body));

    occ_body = make_occ_pd("occ_pd_flush");
    body = encode_light("OCC_PD_FLUSH", XTR_V1_OP_OCC_FLUSH, occ_body);
    expect_word("OCC_PD_FLUSH", body, 0, 0);
    expect_word("OCC_PD_FLUSH", body, 1, 64'h0040_0000_0000_0000);
    expect_word("OCC_PD_FLUSH", body, 2, 64'h0000_0000_0600_0000);
    void'(compose_ok("OCC_PD_FLUSH", XTR_V1_OP_OCC_FLUSH, body));

    body = encode_context("CQC_CREATE", XTR_V1_OP_CQC_CREATE, make_cqc());
    void'(compose_ok("CQC_CREATE", XTR_V1_OP_CQC_CREATE, body));
    object_body = make_object_body("cqc_delete", RDMA_RESOURCE_CQ,
                                   21'h12345);
    body = encode_light("CQC_DELETE", XTR_V1_OP_CQC_DELETE, object_body);
    expect_word("CQC_DELETE_BODY", body, 0, 64'h12345);
    for (int unsigned q = 1; q < 8; q++)
      expect_word("CQC_DELETE_BODY", body, q, 0);
    void'(compose_ok("CQC_DELETE", XTR_V1_OP_CQC_DELETE, body));
    body = encode_light("CQC_QUERY", XTR_V1_OP_CQC_QUERY, object_body);
    void'(compose_ok("CQC_QUERY", XTR_V1_OP_CQC_QUERY, body));

    body = encode_context("CEQC_CREATE", XTR_V1_OP_CEQC_CREATE, make_ceqc());
    void'(compose_ok("CEQC_CREATE", XTR_V1_OP_CEQC_CREATE, body));
    object_body = make_object_body("ceqc_delete", RDMA_RESOURCE_CEQ,
                                   12'habc);
    body = encode_light("CEQC_DELETE", XTR_V1_OP_CEQC_DELETE, object_body);
    expect_word("CEQC_DELETE_BODY", body, 0, 64'habc);
    for (int unsigned q = 1; q < 8; q++)
      expect_word("CEQC_DELETE_BODY", body, q, 0);
    void'(compose_ok("CEQC_DELETE", XTR_V1_OP_CEQC_DELETE, body));
    body = encode_light("CEQC_QUERY", XTR_V1_OP_CEQC_QUERY, object_body);
    void'(compose_ok("CEQC_QUERY", XTR_V1_OP_CEQC_QUERY, body));

    body = encode_context("AEQC_CREATE", XTR_V1_OP_AEQC_CREATE, make_aeqc());
    void'(compose_ok("AEQC_CREATE", XTR_V1_OP_AEQC_CREATE, body));
    object_body = make_object_body("aeqc_delete", RDMA_RESOURCE_AEQ,
                                   12'h789);
    body = encode_light("AEQC_DELETE", XTR_V1_OP_AEQC_DELETE, object_body);
    expect_word("AEQC_DELETE_BODY", body, 0, 64'h789);
    for (int unsigned q = 1; q < 8; q++)
      expect_word("AEQC_DELETE_BODY", body, q, 0);
    void'(compose_ok("AEQC_DELETE", XTR_V1_OP_AEQC_DELETE, body));
    body = encode_light("AEQC_QUERY", XTR_V1_OP_AEQC_QUERY, object_body);
    void'(compose_ok("AEQC_QUERY", XTR_V1_OP_AEQC_QUERY, body));

    body = encode_light("TQ_FLUSH", XTR_V1_OP_TQ_FLUSH, null);
    for (int unsigned q = 0; q < 8; q++)
      expect_word("TQ_FLUSH_BODY", body, q, 0);
    void'(compose_ok("TQ_FLUSH", XTR_V1_OP_TQ_FLUSH, body));

    body = encode_context("SRFQC_CREATE", XTR_V1_OP_SRFQC_CREATE,
                          make_srqc());
    void'(compose_ok("SRFQC_CREATE", XTR_V1_OP_SRFQC_CREATE, body));
    object_body = make_object_body("srfqc_delete", RDMA_RESOURCE_SRQ,
                                   16'hcdef);
    body = encode_light("SRFQC_DELETE", XTR_V1_OP_SRFQC_DELETE, object_body);
    expect_word("SRFQC_DELETE_BODY", body, 0, 64'hcdef);
    for (int unsigned q = 1; q < 8; q++)
      expect_word("SRFQC_DELETE_BODY", body, q, 0);
    void'(compose_ok("SRFQC_DELETE", XTR_V1_OP_SRFQC_DELETE, body));
    body = encode_light("SRFQC_QUERY", XTR_V1_OP_SRFQC_QUERY, object_body);
    void'(compose_ok("SRFQC_QUERY", XTR_V1_OP_SRFQC_QUERY, body));
  endfunction

  function automatic void check_qpc_full_modify_templates();
    rdma_xtr_v1_qpc_command_body qpc_body;
    rdma_xtr_v1_cmq_envelope envelope;
    rdma_hw_image body;
    rdma_hw_image rc_source;
    rdma_hw_image ud_source;
    rdma_hw_image urc_source;

    rc_source = make_qpc_signature_source(21'h12345, "rc");
    ud_source = make_qpc_signature_source(21'h12345, "ud");
    urc_source = make_qpc_signature_source(21'h12345, "urc");

    qpc_body = make_qpc_body("full_modify_rc",
                             XTR_V1_OP_QPC_MODIFY,
                             XTR_V1_QPC_MODIFY_FULL);
    qpc_body.wbe_template_count = 0;
    body = encode_light("QPC_FULL_RC_TEMPLATE_0",
                        XTR_V1_OP_QPC_MODIFY, qpc_body);
    check_signature("QPC_FULL_RC_TEMPLATE_0", XTR_V1_OP_QPC_MODIFY,
                    body, rc_source);

    qpc_body = make_qpc_body("full_modify_ud",
                             XTR_V1_OP_QPC_MODIFY,
                             XTR_V1_QPC_MODIFY_FULL);
    qpc_body.wbe_template_count = 0;
    body = encode_light("QPC_FULL_UD_TEMPLATE_0",
                        XTR_V1_OP_QPC_MODIFY, qpc_body);
    check_signature("QPC_FULL_UD_TEMPLATE_0", XTR_V1_OP_QPC_MODIFY,
                    body, ud_source);

    qpc_body = make_qpc_body("full_modify_urc",
                             XTR_V1_OP_QPC_MODIFY,
                             XTR_V1_QPC_MODIFY_FULL);
    qpc_body.wbe_template_count = 1;
    body = encode_light("QPC_FULL_URC_TEMPLATE_1",
                        XTR_V1_OP_QPC_MODIFY, qpc_body);
    check_signature("QPC_FULL_URC_TEMPLATE_1", XTR_V1_OP_QPC_MODIFY,
                    body, urc_source);

    envelope = make_envelope(XTR_V1_OP_QPC_MODIFY);
    qpc_body = make_qpc_body("full_modify_rc_bad_template",
                             XTR_V1_OP_QPC_MODIFY,
                             XTR_V1_QPC_MODIFY_FULL);
    qpc_body.wbe_template_count = 1;
    body = encode_light("QPC_FULL_RC_TEMPLATE_1",
                        XTR_V1_OP_QPC_MODIFY, qpc_body);
    expect_compose_failure("QPC_FULL_REJECTS_RC_TEMPLATE_1", composer,
                           envelope, body, rc_source, RDMA_SC_CODEC_ERROR);

    qpc_body = make_qpc_body("full_modify_ud_bad_template",
                             XTR_V1_OP_QPC_MODIFY,
                             XTR_V1_QPC_MODIFY_FULL);
    qpc_body.wbe_template_count = 1;
    body = encode_light("QPC_FULL_UD_TEMPLATE_1",
                        XTR_V1_OP_QPC_MODIFY, qpc_body);
    expect_compose_failure("QPC_FULL_REJECTS_UD_TEMPLATE_1", composer,
                           envelope, body, ud_source, RDMA_SC_CODEC_ERROR);

    qpc_body = make_qpc_body("full_modify_urc_bad_template",
                             XTR_V1_OP_QPC_MODIFY,
                             XTR_V1_QPC_MODIFY_FULL);
    qpc_body.wbe_template_count = 0;
    body = encode_light("QPC_FULL_URC_TEMPLATE_0",
                        XTR_V1_OP_QPC_MODIFY, qpc_body);
    expect_compose_failure("QPC_FULL_REJECTS_URC_TEMPLATE_0", composer,
                           envelope, body, urc_source, RDMA_SC_CODEC_ERROR);
  endfunction

  function automatic void check_provenance_cross_pairs();
    rdma_xtr_v1_object_id_command_body object_body;
    rdma_hw_image cqc_query;
    rdma_hw_image ceqc_delete;
    rdma_hw_image tq_empty;
    rdma_hw_image key_zero;
    rdma_hw_image register_zero;
    rdma_xtr_v1_cmq_envelope envelope;
    rdma_status status;

    object_body = make_object_body("cross_cqc_query", RDMA_RESOURCE_CQ,
                                   21'h12345);
    cqc_query = encode_light("CROSS_CQC_QUERY", XTR_V1_OP_CQC_QUERY,
                             object_body);
    envelope = make_envelope(XTR_V1_OP_CQC_DELETE);
    expect_compose_failure("CQC_QUERY_AS_DELETE", composer, envelope,
                           cqc_query, null, RDMA_SC_CODEC_ERROR);

    object_body = make_object_body("cross_ceqc_delete", RDMA_RESOURCE_CEQ,
                                   12'h789);
    ceqc_delete = encode_light("CROSS_CEQC_DELETE", XTR_V1_OP_CEQC_DELETE,
                               object_body);
    envelope = make_envelope(XTR_V1_OP_AEQC_DELETE);
    expect_compose_failure("CEQC_DELETE_AS_AEQC_DELETE", composer, envelope,
                           ceqc_delete, null, RDMA_SC_CODEC_ERROR);

    status = light.encode(XTR_V1_OP_TQ_FLUSH, null, tq_empty);
    expect_ok("CROSS_TQ_EMPTY_ENCODE", status);
    envelope = make_envelope(XTR_V1_OP_QPC_QUERY);
    expect_compose_failure("TQ_EMPTY_AS_QPC_QUERY", composer, envelope,
                           tq_empty, null, RDMA_SC_CODEC_ERROR);

    key_zero = encode_context("CROSS_KEY_ALLOC", XTR_V1_OP_KEY_ALLOC,
                              make_mrt("cross_key_zero", 0));
    register_zero = encode_context("CROSS_MR_REGISTER",
                                   XTR_V1_OP_MR_REGISTER,
                                   make_mrt("cross_register_zero", 0));
    envelope = make_envelope(XTR_V1_OP_MR_REGISTER);
    expect_compose_failure("KEY_ALLOC_AS_MR_REGISTER", composer, envelope,
                           key_zero, null, RDMA_SC_CODEC_ERROR);
    envelope = make_envelope(XTR_V1_OP_KEY_ALLOC);
    expect_compose_failure("MR_REGISTER_AS_KEY_ALLOC", composer, envelope,
                           register_zero, null, RDMA_SC_CODEC_ERROR);
  endfunction

  function automatic void check_artifact_contract();
    rdma_xtr_v1_qpc_command_body qpc_body;
    rdma_xtr_v1_object_id_command_body object_body;
    rdma_xtr_v1_cmq_request_composer foreign_composer;
    rdma_xtr_v1_cmq_envelope envelope;
    rdma_xtr_v1_cmq_test_forged_body forged;
    rdma_hw_image base;
    rdma_hw_image raw;
    rdma_hw_image foreign_body;
    rdma_hw_image query_body;
    rdma_hw_image bad;
    rdma_hw_image qpc_source;
    rdma_hw_image result;
    rdma_status status;

    qpc_body = make_qpc_body("artifact_qpc", XTR_V1_OP_QPC_CREATE);
    base = encode_light("ARTIFACT_BASE", XTR_V1_OP_QPC_CREATE, qpc_body);
    qpc_source = make_qpc_signature_source();
    envelope = make_envelope(XTR_V1_OP_QPC_CREATE);

    raw = rdma_hw_image::type_id::create("artifact_raw_copy");
    raw.copy(base);
    expect_compose_failure("ARTIFACT_REJECTS_RAW", composer, envelope,
                           raw, qpc_source, RDMA_SC_CODEC_ERROR);

    foreign_composer = new("foreign_artifact_composer", ownership);
    status = foreign_composer.build_body(XTR_V1_OP_QPC_CREATE, qpc_body,
                                         foreign_body);
    expect_ok("ARTIFACT_FOREIGN_ENCODE", status);
    expect_compose_failure("ARTIFACT_REJECTS_FOREIGN", composer, envelope,
                           foreign_body, qpc_source, RDMA_SC_CODEC_ERROR);

    bad = clone_image(base, "artifact_exact_clone");
    expect_compose_failure("ARTIFACT_REJECTS_EXACT_CLONE", composer,
                           envelope, bad, qpc_source, RDMA_SC_CODEC_ERROR);

    object_body = make_object_body("artifact_relabel_query",
                                   RDMA_RESOURCE_CQ, 21'h12345);
    query_body = encode_light("ARTIFACT_RELABEL_QUERY",
                              XTR_V1_OP_CQC_QUERY, object_body);
    forged = new("artifact_forged_delete");
    forged.copy_and_relabel_attempt(query_body);
    envelope = make_envelope(XTR_V1_OP_CQC_DELETE);
    expect_compose_failure("ARTIFACT_REJECTS_COPY_RELABEL", composer,
                           envelope, forged, null, RDMA_SC_CODEC_ERROR);
    envelope = make_envelope(XTR_V1_OP_QPC_CREATE);

    bad = encode_light("ARTIFACT_MUTABLE_BYTES", XTR_V1_OP_QPC_CREATE,
                       qpc_body);
    bad.bytes[0] ^= 8'h01;
    expect_compose_failure("ARTIFACT_REJECTS_BYTE_MUTATION", composer,
                           envelope, bad, qpc_source, RDMA_SC_CODEC_ERROR);

    bad = encode_light("ARTIFACT_MUTABLE_GENERATION",
                       XTR_V1_OP_QPC_CREATE, qpc_body);
    bad.function_generation++;
    expect_compose_failure("ARTIFACT_REJECTS_METADATA_MUTATION", composer,
                           envelope, bad, qpc_source, RDMA_SC_CODEC_ERROR);

    bad = encode_light("ARTIFACT_MUTABLE_LENGTH", XTR_V1_OP_QPC_CREATE,
                       qpc_body);
    bad.length++;
    expect_compose_failure("ARTIFACT_REJECTS_LENGTH_MUTATION", composer,
                           envelope, bad, qpc_source, RDMA_SC_CODEC_ERROR);

    bad = encode_light("ARTIFACT_MUTABLE_ALIGNMENT", XTR_V1_OP_QPC_CREATE,
                       qpc_body);
    bad.alignment = 8;
    expect_compose_failure("ARTIFACT_REJECTS_ALIGNMENT_MUTATION", composer,
                           envelope, bad, qpc_source, RDMA_SC_CODEC_ERROR);

    bad = encode_light("ARTIFACT_MUTABLE_ENDIAN", XTR_V1_OP_QPC_CREATE,
                       qpc_body);
    bad.endian = RDMA_ENDIAN_LITTLE;
    expect_compose_failure("ARTIFACT_REJECTS_ENDIAN_MUTATION", composer,
                           envelope, bad, qpc_source, RDMA_SC_CODEC_ERROR);

    bad = encode_light("ARTIFACT_MUTABLE_KIND", XTR_V1_OP_QPC_CREATE,
                       qpc_body);
    bad.image_kind = RDMA_IMAGE_CQC;
    expect_compose_failure("ARTIFACT_REJECTS_KIND_MUTATION", composer,
                           envelope, bad, qpc_source, RDMA_SC_CODEC_ERROR);

    bad = encode_light("ARTIFACT_MUTABLE_VERSION", XTR_V1_OP_QPC_CREATE,
                       qpc_body);
    bad.hardware_version++;
    expect_compose_failure("ARTIFACT_REJECTS_VERSION_MUTATION", composer,
                           envelope, bad, qpc_source, RDMA_SC_CODEC_ERROR);

    bad = encode_light("ARTIFACT_MUTABLE_SUMMARY", XTR_V1_OP_QPC_CREATE,
                       qpc_body);
    bad.field_summary.push_back("mutated after exact encode");
    if (images_equal(base, bad))
      `uvm_error("IMAGES_EQUAL_FIELD_SUMMARY",
                 "image comparison ignored field_summary")
    expect_compose_failure("ARTIFACT_REJECTS_SUMMARY_MUTATION", composer,
                           envelope, bad, qpc_source, RDMA_SC_CODEC_ERROR);

    bad = encode_light("ARTIFACT_MUTABLE_SIZE", XTR_V1_OP_QPC_CREATE,
                       qpc_body);
    void'(bad.bytes.pop_back());
    expect_compose_failure("BODY_REJECTS_BYTE_COUNT", composer, envelope,
                           bad, qpc_source, RDMA_SC_CODEC_ERROR);

    bad = encode_light("ARTIFACT_MUTABLE_TARGET_KIND",
                       XTR_V1_OP_QPC_CREATE, qpc_body);
    bad.write_target_kind = RDMA_HW_TARGET_BACKING;
    expect_compose_failure("BODY_REJECTS_TARGET_KIND", composer, envelope,
                           bad, qpc_source, RDMA_SC_CODEC_ERROR);

    bad = encode_light("ARTIFACT_MUTABLE_BACKING",
                       XTR_V1_OP_QPC_CREATE, qpc_body);
    bad.backing_target.value = 64'h1000;
    expect_compose_failure("BODY_REJECTS_BACKING_TARGET", composer,
                           envelope, bad, qpc_source, RDMA_SC_CODEC_ERROR);

    bad = encode_light("ARTIFACT_MUTABLE_HMC", XTR_V1_OP_QPC_CREATE,
                       qpc_body);
    bad.hmc_target.value = 64'h1000;
    expect_compose_failure("BODY_REJECTS_HMC_TARGET", composer, envelope,
                           bad, qpc_source, RDMA_SC_CODEC_ERROR);

    bad = encode_light("ARTIFACT_MUTABLE_BAR", XTR_V1_OP_QPC_CREATE,
                       qpc_body);
    bad.bar_target.value = 64'h1000;
    expect_compose_failure("BODY_REJECTS_BAR_TARGET", composer, envelope,
                           bad, qpc_source, RDMA_SC_CODEC_ERROR);

    result = compose_ok("ARTIFACT_CANONICAL_GENERATION",
                        XTR_V1_OP_QPC_CREATE, base, qpc_source, 1'b1);
    if (result != null &&
        result.function_generation != base.function_generation)
      `uvm_error("ARTIFACT_CANONICAL_GENERATION",
                 "composed request did not preserve body generation")
  endfunction

  function automatic void check_artifact_lifecycle();
    rdma_xtr_v1_cmq_envelope envelope;
    rdma_hw_image body;
    rdma_hw_image result;
    rdma_status status;

    for (int unsigned i = 0; i < 256; i++) begin
      body = null;
      status = composer.build_body(XTR_V1_OP_TQ_FLUSH, null, body);
      expect_ok("ARTIFACT_LIFECYCLE_BUILD", status);
      envelope = make_envelope(XTR_V1_OP_TQ_FLUSH);
      envelope.wqe_index = i[4:0];
      result = null;
      status = composer.compose_request(envelope, body, null, result);
      expect_ok("ARTIFACT_LIFECYCLE_COMPOSE", status);
      if (result == null)
        `uvm_error("ARTIFACT_LIFECYCLE_COMPOSE",
                   "successful repeated composition published null")
    end
  endfunction

  function automatic void check_qpc_light_semantics();
    rdma_xtr_v1_qpc_command_body qpc_body;
    rdma_xtr_v1_object_id_command_body wrong_model;

    qpc_body = make_qpc_body("create_with_state", XTR_V1_OP_QPC_CREATE);
    qpc_body.next_state = RDMA_QPS_RTS;
    expect_light_failure("QPC_CREATE_REJECTS_STATE", XTR_V1_OP_QPC_CREATE,
                         qpc_body, RDMA_SC_INVALID_ARGUMENT);
    qpc_body = make_qpc_body("create_with_wbe", XTR_V1_OP_QPC_CREATE);
    qpc_body.wbe_template_count = 1;
    expect_light_failure("QPC_CREATE_REJECTS_WBE", XTR_V1_OP_QPC_CREATE,
                         qpc_body, RDMA_SC_INVALID_ARGUMENT);
    qpc_body = make_qpc_body("create_with_pair", XTR_V1_OP_QPC_CREATE);
    qpc_body.modify_start_qword[0] = 1;
    qpc_body.modify_wbe[0] = 8'hff;
    expect_light_failure("QPC_CREATE_REJECTS_PAIR", XTR_V1_OP_QPC_CREATE,
                         qpc_body, RDMA_SC_INVALID_ARGUMENT);
    qpc_body = make_qpc_body("create_with_data", XTR_V1_OP_QPC_CREATE);
    qpc_body.modify_data[0] = 64'h1;
    expect_light_failure("QPC_CREATE_REJECTS_DATA", XTR_V1_OP_QPC_CREATE,
                         qpc_body, RDMA_SC_INVALID_ARGUMENT);

    qpc_body = make_qpc_body("full_with_urc_wbe", XTR_V1_OP_QPC_MODIFY,
                             XTR_V1_QPC_MODIFY_FULL);
    qpc_body.wbe_template_count = 1;
    void'(encode_light("QPC_FULL_ACCEPTS_URC_WBE",
                       XTR_V1_OP_QPC_MODIFY, qpc_body));
    qpc_body = make_qpc_body("full_with_invalid_wbe",
                             XTR_V1_OP_QPC_MODIFY,
                             XTR_V1_QPC_MODIFY_FULL);
    qpc_body.wbe_template_count = 2;
    expect_light_failure("QPC_FULL_REJECTS_INVALID_WBE",
                         XTR_V1_OP_QPC_MODIFY,
                         qpc_body, RDMA_SC_INVALID_ARGUMENT);
    qpc_body = make_qpc_body("full_with_pair", XTR_V1_OP_QPC_MODIFY,
                             XTR_V1_QPC_MODIFY_FULL);
    qpc_body.modify_start_qword[0] = 1;
    expect_light_failure("QPC_FULL_REJECTS_PAIR", XTR_V1_OP_QPC_MODIFY,
                         qpc_body, RDMA_SC_INVALID_ARGUMENT);
    qpc_body = make_qpc_body("full_with_data", XTR_V1_OP_QPC_MODIFY,
                             XTR_V1_QPC_MODIFY_FULL);
    qpc_body.modify_data[0] = 64'h1;
    expect_light_failure("QPC_FULL_REJECTS_DATA", XTR_V1_OP_QPC_MODIFY,
                         qpc_body, RDMA_SC_INVALID_ARGUMENT);

    qpc_body = make_qpc_body("partial_with_buffer", XTR_V1_OP_QPC_MODIFY,
                             XTR_V1_QPC_MODIFY_PARTIAL);
    qpc_body.qpc_buffer.value = 64'h200;
    expect_light_failure("QPC_PARTIAL_REJECTS_BUFFER",
                         XTR_V1_OP_QPC_MODIFY, qpc_body,
                         RDMA_SC_INVALID_ARGUMENT);

    qpc_body = make_qpc_body("state_with_wbe", XTR_V1_OP_QPC_MODIFY);
    qpc_body.wbe_template_count = 1;
    expect_light_failure("QPC_STATE_REJECTS_WBE", XTR_V1_OP_QPC_MODIFY,
                         qpc_body, RDMA_SC_INVALID_ARGUMENT);
    qpc_body = make_qpc_body("state_with_pair", XTR_V1_OP_QPC_MODIFY);
    qpc_body.modify_wbe[0] = 8'h1;
    expect_light_failure("QPC_STATE_REJECTS_PAIR", XTR_V1_OP_QPC_MODIFY,
                         qpc_body, RDMA_SC_INVALID_ARGUMENT);
    qpc_body = make_qpc_body("state_with_data", XTR_V1_OP_QPC_MODIFY);
    qpc_body.modify_data[0] = 64'h1;
    expect_light_failure("QPC_STATE_REJECTS_DATA", XTR_V1_OP_QPC_MODIFY,
                         qpc_body, RDMA_SC_INVALID_ARGUMENT);
    qpc_body = make_qpc_body("state_with_buffer", XTR_V1_OP_QPC_MODIFY);
    qpc_body.qpc_buffer.value = 64'h1;
    expect_light_failure("QPC_STATE_REJECTS_BUFFER", XTR_V1_OP_QPC_MODIFY,
                         qpc_body, RDMA_SC_INVALID_ARGUMENT);

    qpc_body = make_qpc_body("delete_with_buffer", XTR_V1_OP_QPC_DELETE);
    qpc_body.qpc_buffer.value = 64'h200;
    expect_light_failure("QPC_DELETE_REJECTS_BUFFER", XTR_V1_OP_QPC_DELETE,
                         qpc_body, RDMA_SC_INVALID_ARGUMENT);
    qpc_body = make_qpc_body("delete_with_modify", XTR_V1_OP_QPC_DELETE);
    qpc_body.next_state = RDMA_QPS_RTS;
    qpc_body.wbe_template_count = 1;
    qpc_body.modify_wbe[0] = 1;
    qpc_body.modify_data[0] = 1;
    expect_light_failure("QPC_DELETE_REJECTS_MODIFY_FIELDS",
                         XTR_V1_OP_QPC_DELETE, qpc_body,
                         RDMA_SC_INVALID_ARGUMENT);

    qpc_body = make_qpc_body("query_with_cqs", XTR_V1_OP_QPC_QUERY);
    qpc_body.send_cq_h = make_handle("query_scq", RDMA_RESOURCE_CQ,
                                     21'h15555);
    qpc_body.recv_cq_h = make_handle("query_rcq", RDMA_RESOURCE_CQ,
                                     21'h0aaaa);
    expect_light_failure("QPC_QUERY_REJECTS_CQS", XTR_V1_OP_QPC_QUERY,
                         qpc_body, RDMA_SC_INVALID_ARGUMENT);
    qpc_body = make_qpc_body("query_with_modify", XTR_V1_OP_QPC_QUERY);
    qpc_body.next_state = RDMA_QPS_RTS;
    qpc_body.wbe_template_count = 1;
    qpc_body.modify_start_qword[0] = 1;
    qpc_body.modify_data[0] = 1;
    expect_light_failure("QPC_QUERY_REJECTS_MODIFY_FIELDS",
                         XTR_V1_OP_QPC_QUERY, qpc_body,
                         RDMA_SC_INVALID_ARGUMENT);

    qpc_body = make_qpc_body("mutually_exclusive_modify",
                             XTR_V1_OP_QPC_MODIFY,
                             XTR_V1_QPC_MODIFY_FULL);
    qpc_body.partial_modify = 1'b1;
    expect_light_failure("QPC_MODES_MUTUALLY_EXCLUSIVE",
                         XTR_V1_OP_QPC_MODIFY, qpc_body,
                         RDMA_SC_INVALID_ARGUMENT);
    wrong_model = make_object_body("wrong_qpc_model", RDMA_RESOURCE_QP,
                                   21'h12345);
    expect_light_failure("QPC_WRONG_MODEL", XTR_V1_OP_QPC_CREATE,
                         wrong_model, RDMA_SC_INVALID_ARGUMENT);
    expect_light_failure("LIGHT_UNSUPPORTED_OPCODE", 8'hff, null,
                         RDMA_SC_UNSUPPORTED_OPCODE);
  endfunction

  function automatic void check_occ_semantics();
    rdma_xtr_v1_occ_flush_body occ_body;

    occ_body = rdma_xtr_v1_occ_flush_body::type_id::create("occ_empty");
    expect_light_failure("OCC_REJECTS_EMPTY", XTR_V1_OP_OCC_FLUSH,
                         occ_body, RDMA_SC_INVALID_ARGUMENT);

    occ_body = make_occ_vf("occ_vf_with_serial_selector");
    occ_body.mr_serial_flush = 1'b1;
    expect_light_failure("OCC_REJECTS_VF_SERIAL_SELECTORS",
                         XTR_V1_OP_OCC_FLUSH, occ_body,
                         RDMA_SC_INVALID_ARGUMENT);
    occ_body = make_occ_vf("occ_vf_missing_object");
    occ_body.qpc = 1'b0;
    expect_light_failure("OCC_VF_REQUIRES_OBJECTS", XTR_V1_OP_OCC_FLUSH,
                         occ_body, RDMA_SC_INVALID_ARGUMENT);
    occ_body = make_occ_vf("occ_vf_with_qpn");
    occ_body.qpn = 1;
    expect_light_failure("OCC_VF_REJECTS_QPN", XTR_V1_OP_OCC_FLUSH,
                         occ_body, RDMA_SC_INVALID_ARGUMENT);
    occ_body = make_occ_vf("occ_vf_with_serial");
    occ_body.mr_serial = 1;
    expect_light_failure("OCC_VF_REJECTS_SERIAL", XTR_V1_OP_OCC_FLUSH,
                         occ_body, RDMA_SC_INVALID_ARGUMENT);
    occ_body = make_occ_vf("occ_vf_with_backing");
    occ_body.pd_backing.value = 64'h1000;
    expect_light_failure("OCC_VF_REJECTS_BACKING", XTR_V1_OP_OCC_FLUSH,
                         occ_body, RDMA_SC_INVALID_ARGUMENT);

    occ_body = make_occ_serial("occ_serial_missing_pble");
    occ_body.pble = 1'b0;
    expect_light_failure("OCC_SERIAL_REQUIRES_PBLE", XTR_V1_OP_OCC_FLUSH,
                         occ_body, RDMA_SC_INVALID_ARGUMENT);
    occ_body = make_occ_serial("occ_serial_with_pd");
    occ_body.pd = 1'b1;
    occ_body.pd_backing.value = 64'h1000;
    expect_light_failure("OCC_REJECTS_SERIAL_PD_SELECTORS",
                         XTR_V1_OP_OCC_FLUSH, occ_body,
                         RDMA_SC_INVALID_ARGUMENT);
    occ_body = make_occ_serial("occ_serial_with_qpn");
    occ_body.qpn = 1;
    expect_light_failure("OCC_SERIAL_REJECTS_QPN", XTR_V1_OP_OCC_FLUSH,
                         occ_body, RDMA_SC_INVALID_ARGUMENT);

    occ_body = make_occ_qpn("occ_qpn_missing_object");
    occ_body.eirqe = 1'b0;
    expect_light_failure("OCC_QPN_REQUIRES_OBJECTS", XTR_V1_OP_OCC_FLUSH,
                         occ_body, RDMA_SC_INVALID_ARGUMENT);
    occ_body = make_occ_qpn("occ_qpn_extra_object");
    occ_body.qpc = 1'b1;
    expect_light_failure("OCC_QPN_REJECTS_EXTRA_OBJECT",
                         XTR_V1_OP_OCC_FLUSH, occ_body,
                         RDMA_SC_INVALID_ARGUMENT);
    occ_body = make_occ_qpn("occ_qpn_with_serial");
    occ_body.mr_serial = 1;
    expect_light_failure("OCC_QPN_REJECTS_SERIAL", XTR_V1_OP_OCC_FLUSH,
                         occ_body, RDMA_SC_INVALID_ARGUMENT);
    occ_body = make_occ_qpn("occ_qpn_with_backing");
    occ_body.pd_backing.value = 64'h1000;
    expect_light_failure("OCC_QPN_REJECTS_BACKING", XTR_V1_OP_OCC_FLUSH,
                         occ_body, RDMA_SC_INVALID_ARGUMENT);

    occ_body = make_occ_qpn_pd("occ_qpn_pd_without_backing");
    occ_body.pd_backing.value = 0;
    expect_light_failure("OCC_QPN_PD_REQUIRES_BACKING",
                         XTR_V1_OP_OCC_FLUSH, occ_body,
                         RDMA_SC_INVALID_ARGUMENT);
    occ_body = make_occ_qpn_pd("occ_qpn_pd_unaligned");
    occ_body.pd_backing.value |= 1;
    expect_light_failure("OCC_QPN_PD_REJECTS_UNALIGNED",
                         XTR_V1_OP_OCC_FLUSH, occ_body,
                         RDMA_SC_INVALID_ARGUMENT);
    occ_body = make_occ_qpn_pd("occ_qpn_pd_with_object");
    occ_body.eirqe = 1'b1;
    expect_light_failure("OCC_QPN_PD_REJECTS_OBJECT",
                         XTR_V1_OP_OCC_FLUSH, occ_body,
                         RDMA_SC_INVALID_ARGUMENT);

    occ_body = make_occ_pd("occ_pd_without_backing");
    occ_body.pd_backing.value = 0;
    expect_light_failure("OCC_PD_REQUIRES_BACKING", XTR_V1_OP_OCC_FLUSH,
                         occ_body, RDMA_SC_INVALID_ARGUMENT);
    occ_body = make_occ_pd("occ_pd_with_serial");
    occ_body.mr_serial = 1;
    expect_light_failure("OCC_PD_REJECTS_SERIAL", XTR_V1_OP_OCC_FLUSH,
                         occ_body, RDMA_SC_INVALID_ARGUMENT);
  endfunction

  function automatic void check_negatives();
    rdma_xtr_v1_qpc_command_body qpc_body;
    rdma_hw_image base;
    rdma_hw_image bad;
    rdma_hw_image empty_body;
    rdma_hw_image qpc_source;
    rdma_xtr_v1_cmq_envelope envelope;
    rdma_xtr_v1_cmq_test_bad_envelope_codec bad_envelope_codec;
    rdma_xtr_v1_cmq_request_composer bad_envelope_composer;
    rdma_xtr_v1_cmq_test_overlap_registry overlap_registry;
    rdma_image_kind_e ignored_kind;
    bit [63:0] masks[8];
    rdma_status status;

    qpc_body = make_qpc_body("negative_qpc_create",
                             XTR_V1_OP_QPC_CREATE);
    base = encode_light("NEGATIVE_BASE", XTR_V1_OP_QPC_CREATE, qpc_body);
    qpc_source = make_qpc_signature_source();
    envelope = make_envelope(XTR_V1_OP_QPC_CREATE);

    bad = clone_image(base, "BAD_KIND_CLONE");
    bad.image_kind = RDMA_IMAGE_CQC;
    expect_compose_failure("BODY_KIND", composer, envelope, bad, qpc_source,
                           RDMA_SC_CODEC_ERROR);
    bad = clone_image(base, "BAD_VERSION_CLONE");
    bad.hardware_version++;
    expect_compose_failure("BODY_VERSION", composer, envelope, bad,
                           qpc_source, RDMA_SC_CODEC_ERROR);
    bad = clone_image(base, "BAD_ENDIAN_CLONE");
    bad.endian = RDMA_ENDIAN_LITTLE;
    expect_compose_failure("BODY_ENDIAN", composer, envelope, bad,
                           qpc_source, RDMA_SC_CODEC_ERROR);
    bad = clone_image(base, "BAD_LENGTH_CLONE");
    bad.length = 63;
    expect_compose_failure("BODY_LENGTH", composer, envelope, bad,
                           qpc_source, RDMA_SC_CODEC_ERROR);
    bad = clone_image(base, "BAD_ALIGNMENT_CLONE");
    bad.alignment = 8;
    expect_compose_failure("BODY_ALIGNMENT", composer, envelope, bad,
                           qpc_source, RDMA_SC_CODEC_ERROR);

    bad = clone_image(base, "BAD_RESERVED_CLONE");
    set_image_word(bad, 7, image_word(bad, 7) | 64'h1);
    expect_compose_failure("BODY_OUTSIDE_MASK", composer, envelope, bad,
                           qpc_source, RDMA_SC_CODEC_ERROR);

    envelope = make_envelope(XTR_V1_OP_QPC_DELETE);
    expect_compose_failure("OPCODE_BODY_PAIRING", composer, envelope, base,
                           null, RDMA_SC_CODEC_ERROR);

    status = light.encode(XTR_V1_OP_TQ_FLUSH, null, empty_body);
    expect_ok("NEG_EMPTY_BODY", status);
    envelope = make_envelope(8'hff);
    expect_compose_failure("UNREGISTERED_OPCODE", composer, envelope,
                           empty_body, null, RDMA_SC_UNSUPPORTED_OPCODE);
    envelope = make_envelope(XTR_V1_OP_QP_FLUSH);
    expect_compose_failure("QP_FLUSH_UNREGISTERED", composer, envelope,
                           empty_body, null, RDMA_SC_UNSUPPORTED_OPCODE);
    envelope = make_envelope(8'h11);
    expect_compose_failure("CEQC_MODIFY_UNREGISTERED", composer, envelope,
                           empty_body, null, RDMA_SC_UNSUPPORTED_OPCODE);
    envelope = make_envelope(8'h15);
    expect_compose_failure("AEQC_MODIFY_UNREGISTERED", composer, envelope,
                           empty_body, null, RDMA_SC_UNSUPPORTED_OPCODE);
    envelope = make_envelope(8'h36);
    expect_compose_failure("SRFQC_MODIFY_UNREGISTERED", composer, envelope,
                           empty_body, null, RDMA_SC_UNSUPPORTED_OPCODE);

    bad_envelope_codec = new("bad_envelope_codec");
    bad_envelope_composer = new("bad_envelope_composer", ownership,
                                bad_envelope_codec);
    envelope = make_envelope(XTR_V1_OP_TQ_FLUSH);
    expect_compose_failure("ENVELOPE_OUTSIDE_MASK", bad_envelope_composer,
                           envelope, empty_body, null, RDMA_SC_CODEC_ERROR);

    for (int unsigned attack = RDMA_CMQ_TEST_ENVELOPE_VALID;
         attack <= RDMA_CMQ_TEST_ENVELOPE_MUTATE_INPUT; attack++) begin
      rdma_xtr_v1_cmq_test_envelope_attack_e selected_attack;
      string label;
      if (!$cast(selected_attack, attack))
        `uvm_fatal("ENVELOPE_ATTACK_CAST", "invalid test attack")
      label = $sformatf("ENVELOPE_ATTACK_%0d", attack);
      bad_envelope_codec = new({label, "_codec"}, selected_attack);
      bad_envelope_composer = new({label, "_composer"}, ownership,
                                  bad_envelope_codec);
      status = bad_envelope_composer.build_body(XTR_V1_OP_TQ_FLUSH, null,
                                                empty_body);
      expect_ok({label, "_BODY"}, status);
      envelope = make_envelope(XTR_V1_OP_TQ_FLUSH);
      expect_compose_failure(label, bad_envelope_composer, envelope,
                             empty_body, null, RDMA_SC_CODEC_ERROR);
    end

    status = composer.build_body(XTR_V1_OP_TQ_FLUSH, null, empty_body);
    expect_ok("NULL_ENVELOPE_BODY", status);
    expect_compose_failure("NULL_ENVELOPE", composer, null, empty_body,
                           null, RDMA_SC_CODEC_ERROR);

    overlap_registry = new("overlap_registry");
    foreach (masks[i]) masks[i] = '0;
    masks[0] = 64'h8000_0000_0000_0000;
    status = overlap_registry.register_body(8'hfe, RDMA_IMAGE_CMQ_SQE,
                                            masks);
    expect_status("REGISTER_OVERLAP_REJECTED", status,
                  RDMA_SC_CODEC_ERROR);

    bad = clone_image(qpc_source, "BAD_QPC_KIND");
    bad.image_kind = RDMA_IMAGE_CMQ_SQE;
    envelope = make_envelope(XTR_V1_OP_QPC_CREATE);
    expect_compose_failure("QPC_SIGNATURE_SOURCE_KIND", composer, envelope,
                           base, bad, RDMA_SC_CODEC_ERROR);
    bad = clone_image(qpc_source, "STALE_QPC_GENERATION");
    bad.function_generation++;
    expect_compose_failure("QPC_SIGNATURE_SOURCE_GENERATION", composer,
                           envelope, base, bad, RDMA_SC_CODEC_ERROR);
    bad = clone_image(qpc_source, "RESERVED_QPC_SIGNATURE_SOURCE");
    set_image_word(bad, 63, image_word(bad, 63) | 64'h1);
    expect_compose_failure("QPC_SIGNATURE_SOURCE_RESERVED", composer,
                           envelope, base, bad, RDMA_SC_CODEC_ERROR);
    bad = make_qpc_signature_source(21'h12346);
    expect_compose_failure("QPC_SIGNATURE_SOURCE_QPN", composer, envelope,
                           base, bad, RDMA_SC_CODEC_ERROR);
    bad = clone_image(base, "NONZERO_SIGNATURE_BODY");
    set_image_word(bad, 1, image_word(bad, 1) |
                   (64'h5a << XTR_V1_CMQ_SIGNATURE_LSB));
    expect_compose_failure("NONZERO_SOURCE_SIGNATURE", composer, envelope,
                           bad, qpc_source, RDMA_SC_CODEC_ERROR);
  endfunction

  function automatic void check_registry_contract();
    rdma_xtr_v1_cmq_body_registry registry;
    rdma_xtr_v1_cmq_body_registry replacement;
    rdma_xtr_v1_cmq_body_registry validated_snapshot;
    rdma_xtr_v1_cmq_test_overlap_registry invalid_source;
    rdma_xtr_v1_cmq_duplicate_catcher catcher;
    rdma_status status;
    rdma_image_kind_e kind;
    bit [63:0] masks[8];
    bit [63:0] duplicate_masks[8];
    bit [63:0] replacement_masks[8];

    registry = rdma_xtr_v1_cmq_body_registry::type_id::create(
      "contract_registry");
    foreach (masks[i]) masks[i] = '0;
    masks[0] = 64'h1;
    status = registry.register_body(8'hee, RDMA_IMAGE_CMQ_SQE, masks);
    expect_ok("REGISTRY_FIRST", status);
    catcher = new("cmq_duplicate_catcher");
    uvm_report_cb::add(null, catcher);
    foreach (duplicate_masks[i]) duplicate_masks[i] = masks[i];
    duplicate_masks[0] |= request_envelope_mask(0);
    status = registry.register_body(8'hee, RDMA_IMAGE_CMQ_SQE,
                                    duplicate_masks);
    uvm_report_cb::delete(null, catcher);
    expect_status("REGISTRY_DUPLICATE", status, RDMA_SC_INVALID_STATE);
    if (!catcher.caught)
      `uvm_error("REGISTRY_DUPLICATE", "duplicate fatal was not reported")
    registry.seal();
    status = registry.register_body(8'hef, RDMA_IMAGE_CMQ_SQE, masks);
    expect_status("REGISTRY_SEALED", status, RDMA_SC_INVALID_STATE);
    status = registry.lookup(8'hee, kind, masks);
    expect_ok("REGISTRY_LOOKUP", status);
    if (kind != RDMA_IMAGE_CMQ_SQE || masks[0] != 64'h1)
      `uvm_error("REGISTRY_LOOKUP", "registered identity was not retained")
    status = registry.lookup(8'hef, kind, masks);
    expect_status("REGISTRY_MISSING", status, RDMA_SC_UNSUPPORTED_OPCODE);

    replacement = rdma_xtr_v1_cmq_body_registry::type_id::create(
      "contract_replacement_registry");
    foreach (replacement_masks[i]) replacement_masks[i] = '0;
    replacement_masks[1] = 64'h2;
    status = replacement.register_body(8'hef, RDMA_IMAGE_CMQ_SQE,
                                       replacement_masks);
    expect_ok("REGISTRY_REPLACEMENT_REGISTER", status);
    registry.copy(replacement);
    status = registry.lookup(8'hee, kind, masks);
    expect_ok("SEALED_COPY_RETAINS_ORIGINAL", status);
    if (kind != RDMA_IMAGE_CMQ_SQE || masks[0] != 64'h1)
      `uvm_error("SEALED_COPY_RETAINS_ORIGINAL",
                 "sealed registry entry changed after copy")
    status = registry.lookup(8'hef, kind, masks);
    expect_status("SEALED_COPY_REJECTS_REPLACEMENT", status,
                  RDMA_SC_UNSUPPORTED_OPCODE);
    status = registry.register_body(8'hf0, RDMA_IMAGE_CMQ_SQE,
                                    replacement_masks);
    expect_status("SEALED_COPY_RETAINS_SEAL", status,
                  RDMA_SC_INVALID_STATE);

    status = replacement.validated_snapshot(validated_snapshot);
    expect_ok("VALIDATED_SNAPSHOT", status);
    if (validated_snapshot == null)
      `uvm_error("VALIDATED_SNAPSHOT", "snapshot was not published")
    else begin
      status = validated_snapshot.lookup(8'hef, kind, masks);
      expect_ok("VALIDATED_SNAPSHOT_LOOKUP", status);
      status = validated_snapshot.register_body(8'hf1, RDMA_IMAGE_CMQ_SQE,
                                                replacement_masks);
      expect_status("VALIDATED_SNAPSHOT_SEALED", status,
                    RDMA_SC_INVALID_STATE);
    end

    invalid_source = new("invalid_snapshot_source");
    foreach (replacement_masks[i]) replacement_masks[i] = '0;
    replacement_masks[0] = request_envelope_mask(0);
    invalid_source.force_body(8'hf2, RDMA_IMAGE_CMQ_SQE,
                              replacement_masks);
    status = invalid_source.validated_snapshot(validated_snapshot);
    expect_status("VALIDATED_SNAPSHOT_REVALIDATES", status,
                  RDMA_SC_CODEC_ERROR);
    if (validated_snapshot != null)
      `uvm_error("VALIDATED_SNAPSHOT_REVALIDATES",
                 "invalid source published a snapshot")
  endfunction

  function automatic void check_injected_registry_snapshot();
    rdma_xtr_v1_cmq_body_registry injected;
    rdma_xtr_v1_cmq_body_registry replacement;
    rdma_xtr_v1_cmq_request_composer snapshot_composer;
    rdma_xtr_v1_cmq_envelope envelope;
    rdma_hw_image empty_body;
    rdma_hw_image result;
    bit [63:0] masks[8];
    rdma_status status;

    injected = rdma_xtr_v1_cmq_body_registry::type_id::create(
      "snapshot_injected_registry");
    replacement = rdma_xtr_v1_cmq_body_registry::type_id::create(
      "snapshot_replacement_registry");
    foreach (masks[i]) masks[i] = '0;
    status = injected.register_body(XTR_V1_OP_TQ_FLUSH,
                                    RDMA_IMAGE_CMQ_SQE, masks);
    expect_ok("SNAPSHOT_REGISTER_ORIGINAL", status);
    injected.seal();
    snapshot_composer = new("snapshot_composer", injected);

    status = replacement.register_body(8'he1, RDMA_IMAGE_CMQ_SQE, masks);
    expect_ok("SNAPSHOT_REGISTER_REPLACEMENT", status);
    injected.copy(replacement);

    status = snapshot_composer.build_body(XTR_V1_OP_TQ_FLUSH, null,
                                          empty_body);
    expect_ok("SNAPSHOT_EMPTY_BODY", status);
    envelope = make_envelope(XTR_V1_OP_TQ_FLUSH);
    result = rdma_hw_image::type_id::create("snapshot_sentinel");
    status = snapshot_composer.compose_request(envelope, empty_body, null,
                                               result);
    expect_ok("SNAPSHOT_COMPOSE_ORIGINAL", status);
    if (result == null)
      `uvm_error("SNAPSHOT_COMPOSE_ORIGINAL",
                 "composer did not preserve injected ownership snapshot")
  endfunction

  task run_phase(uvm_phase phase);
    rdma_status status;

    phase.raise_objection(this);
    ownership = rdma_xtr_v1_cmq_body_registry::type_id::create(
      "cmq_ownership");
    status = rdma_xtr_v1_register_cmq_request_bodies(ownership);
    expect_ok("OWNERSHIP_REGISTER", status);
    ownership.seal();
    light = rdma_xtr_v1_cmq_light_body_codec::type_id::create(
      "cmq_light_codec");
    composer = new("cmq_composer", ownership);
    context_registry = rdma_codec_registry::type_id::create(
      "cmq_context_registry");
    status = rdma_xtr_v1_register_context_body_codecs(context_registry);
    expect_ok("CONTEXT_REGISTER", status);
    qpc_registry = rdma_codec_registry::type_id::create("cmq_qpc_registry");
    status = rdma_xtr_v1_register_qpc_codecs(qpc_registry);
    expect_ok("QPC_REGISTER", status);

    check_registry_contract();
    check_injected_registry_snapshot();
    check_envelope_oracle();
    check_ownership_oracles();
    check_provenance_cross_pairs();
    check_artifact_contract();
    check_artifact_lifecycle();
    check_qpc_light_semantics();
    check_occ_semantics();
    check_all_supported();
    check_qpc_full_modify_templates();
    check_negatives();
    phase.drop_objection(this);
  endtask
endclass
