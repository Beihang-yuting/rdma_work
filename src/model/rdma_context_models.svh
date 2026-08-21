virtual class rdma_hw_model extends uvm_object;
  function new(string name = "rdma_hw_model");
    super.new(name);
  endfunction

  pure virtual function rdma_status validate();
  pure virtual function string describe();
endclass

// Context handles carry hardware-projection/local IDs.  Resource-manager
// incarnation IDs remain opaque registry identities and are not used here.
function automatic rdma_status rdma_context_handle_status(
  rdma_handle handle,
  rdma_resource_kind_e expected_kind,
  int unsigned object_id_width,
  string label
);
  longint unsigned object_id_limit;

  if (handle == null)
    return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                             {label, " handle is null"});
  if (handle.kind != expected_kind)
    return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                             {label, " handle kind is invalid"});
  object_id_limit = 64'h1 << object_id_width;
  if ({32'b0, handle.object_id} >= object_id_limit)
    return rdma_status::make(
      RDMA_SC_INVALID_ARGUMENT,
      $sformatf("%s object ID exceeds %0d bits", label, object_id_width)
    );
  return rdma_status::success();
endfunction

function automatic rdma_status rdma_context_lifecycle_status(
  rdma_handle reference,
  rdma_handle candidate,
  string label
);
  if (reference == null || candidate == null)
    return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                             {label, " lifecycle handle is null"});
  if (candidate.function_uid != reference.function_uid)
    return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                             {label, " function UID does not match"});
  if (candidate.generation != reference.generation)
    return rdma_status::make(RDMA_SC_STALE_GENERATION,
                             {label, " generation does not match"});
  return rdma_status::success();
endfunction

function automatic rdma_status rdma_context_state_status(
  rdma_context_state_e state,
  string label
);
  if (!(state inside {RDMA_CONTEXT_INVALID, RDMA_CONTEXT_VALID,
                      RDMA_CONTEXT_ERROR}))
    return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                             {label, " context state is invalid"});
  return rdma_status::success();
endfunction

function automatic rdma_status rdma_object_mode_status(
  rdma_object_mode_e mode,
  string label
);
  if (!(mode inside {RDMA_OBJECT_DIRECT_4K, RDMA_OBJECT_INDIRECT_4K,
                     RDMA_OBJECT_HUGE_2M,
                     RDMA_OBJECT_L3_INDIRECT_4K}))
    return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                             {label, " object mode is invalid"});
  return rdma_status::success();
endfunction

function automatic rdma_page_table_layout rdma_clone_page_layout_value(
  rdma_page_table_layout source,
  string label
);
  uvm_object cloned_object;
  rdma_page_table_layout cloned_layout;

  if (source == null)
    return null;
  cloned_object = source.clone();
  if (cloned_object == null || !$cast(cloned_layout, cloned_object))
    `uvm_fatal("RDMA_COPY_TYPE", {label, " page layout clone mismatch"})
  return cloned_layout;
endfunction

function automatic rdma_ring_position rdma_clone_ring_position_value(
  rdma_ring_position source,
  string label
);
  uvm_object cloned_object;
  rdma_ring_position cloned_position;

  if (source == null)
    return null;
  cloned_object = source.clone();
  if (cloned_object == null || !$cast(cloned_position, cloned_object))
    `uvm_fatal("RDMA_COPY_TYPE", {label, " ring position clone mismatch"})
  return cloned_position;
endfunction

function automatic rdma_address_vector rdma_clone_address_vector_value(
  rdma_address_vector source,
  string label
);
  uvm_object cloned_object;
  rdma_address_vector cloned_vector;

  if (source == null)
    return null;
  cloned_object = source.clone();
  if (cloned_object == null || !$cast(cloned_vector, cloned_object))
    `uvm_fatal("RDMA_COPY_TYPE", {label, " address vector clone mismatch"})
  return cloned_vector;
endfunction

function automatic rdma_mr_page_layout rdma_clone_mr_page_layout_value(
  rdma_mr_page_layout source,
  string label
);
  uvm_object cloned_object;
  rdma_mr_page_layout cloned_layout;

  if (source == null)
    return null;
  cloned_object = source.clone();
  if (cloned_object == null || !$cast(cloned_layout, cloned_object))
    `uvm_fatal("RDMA_COPY_TYPE", {label, " MR page layout clone mismatch"})
  return cloned_layout;
endfunction

virtual class rdma_qpc_transport_ext extends uvm_object;
  function new(string name = "rdma_qpc_transport_ext");
    super.new(name);
  endfunction

  pure virtual function rdma_transport_e transport_kind();
  pure virtual function rdma_status validate();
  pure virtual function string describe();
endclass

class rdma_qpc_rc_ext extends rdma_qpc_transport_ext;
  `uvm_object_utils(rdma_qpc_rc_ext)

  bit [23:0] remote_qpn;
  bit [23:0] send_psn;
  bit [23:0] recv_psn;
  int unsigned retry_count;
  int unsigned rnr_retry_count;
  int unsigned path_mtu_bytes;

  function new(string name = "rdma_qpc_rc_ext");
    super.new(name);
    remote_qpn = '0;
    send_psn = '0;
    recv_psn = '0;
    retry_count = '0;
    rnr_retry_count = '0;
    path_mtu_bytes = '0;
  endfunction

  virtual function void do_copy(uvm_object rhs);
    rdma_qpc_rc_ext rhs_ext;

    super.do_copy(rhs);
    if (!$cast(rhs_ext, rhs))
      `uvm_fatal("RDMA_COPY_TYPE", "RC QPC extension copy mismatch")
    remote_qpn = rhs_ext.remote_qpn;
    send_psn = rhs_ext.send_psn;
    recv_psn = rhs_ext.recv_psn;
    retry_count = rhs_ext.retry_count;
    rnr_retry_count = rhs_ext.rnr_retry_count;
    path_mtu_bytes = rhs_ext.path_mtu_bytes;
  endfunction

  virtual function rdma_transport_e transport_kind();
    return RDMA_TRANSPORT_RC;
  endfunction

  virtual function rdma_status validate();
    if (remote_qpn == 0)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "RC QPC remote QPN is zero");
    return rdma_status::success();
  endfunction

  virtual function string describe();
    return $sformatf("RC(remote_qpn=%0d send_psn=%0d recv_psn=%0d mtu=%0d)",
                     remote_qpn, send_psn, recv_psn, path_mtu_bytes);
  endfunction
endclass

class rdma_qpc_ud_ext extends rdma_qpc_transport_ext;
  `uvm_object_utils(rdma_qpc_ud_ext)

  bit [31:0] qkey;

  function new(string name = "rdma_qpc_ud_ext");
    super.new(name);
    qkey = '0;
  endfunction

  virtual function void do_copy(uvm_object rhs);
    rdma_qpc_ud_ext rhs_ext;

    super.do_copy(rhs);
    if (!$cast(rhs_ext, rhs))
      `uvm_fatal("RDMA_COPY_TYPE", "UD QPC extension copy mismatch")
    qkey = rhs_ext.qkey;
  endfunction

  virtual function rdma_transport_e transport_kind();
    return RDMA_TRANSPORT_UD;
  endfunction

  virtual function rdma_status validate();
    if (qkey == 0)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "UD QPC qkey is zero");
    return rdma_status::success();
  endfunction

  virtual function string describe();
    return $sformatf("UD(qkey=0x%08x)", qkey);
  endfunction
endclass

class rdma_qpc_urc_ext extends rdma_qpc_transport_ext;
  `uvm_object_utils(rdma_qpc_urc_ext)

  bit [23:0] remote_qpn;
  bit [23:0] rbsn;
  bit [23:0] dbsn;
  bit [23:0] rpsn;
  bit [23:0] dpsn;
  int unsigned path_mtu_bytes;
  rdma_backing_addr_t rsq_backing;
  rdma_backing_addr_t rdsq_backing;
  rdma_backing_addr_t dsq_backing;
  int unsigned fetch_threshold;
  int unsigned queue_threshold;

  function new(string name = "rdma_qpc_urc_ext");
    super.new(name);
    remote_qpn = '0;
    rbsn = '0;
    dbsn = '0;
    rpsn = '0;
    dpsn = '0;
    path_mtu_bytes = '0;
    rsq_backing = '0;
    rdsq_backing = '0;
    dsq_backing = '0;
    fetch_threshold = '0;
    queue_threshold = '0;
  endfunction

  virtual function void do_copy(uvm_object rhs);
    rdma_qpc_urc_ext rhs_ext;

    super.do_copy(rhs);
    if (!$cast(rhs_ext, rhs))
      `uvm_fatal("RDMA_COPY_TYPE", "URC QPC extension copy mismatch")
    remote_qpn = rhs_ext.remote_qpn;
    rbsn = rhs_ext.rbsn;
    dbsn = rhs_ext.dbsn;
    rpsn = rhs_ext.rpsn;
    dpsn = rhs_ext.dpsn;
    path_mtu_bytes = rhs_ext.path_mtu_bytes;
    rsq_backing = rhs_ext.rsq_backing;
    rdsq_backing = rhs_ext.rdsq_backing;
    dsq_backing = rhs_ext.dsq_backing;
    fetch_threshold = rhs_ext.fetch_threshold;
    queue_threshold = rhs_ext.queue_threshold;
  endfunction

  virtual function rdma_transport_e transport_kind();
    return RDMA_TRANSPORT_URC;
  endfunction

  virtual function rdma_status validate();
    if (remote_qpn == 0)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "URC QPC remote QPN is zero");
    if ((rsq_backing.value & 64'hfff) != 0 ||
        (rdsq_backing.value & 64'hfff) != 0 ||
        (dsq_backing.value & 64'hfff) != 0)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "URC queue backing is not 4 KiB aligned");
    return rdma_status::success();
  endfunction

  virtual function string describe();
    return $sformatf("URC(remote_qpn=%0d rbsn=%0d dbsn=%0d mtu=%0d)",
                     remote_qpn, rbsn, dbsn, path_mtu_bytes);
  endfunction
endclass

class rdma_qpc_model extends rdma_hw_model;
  `uvm_object_utils(rdma_qpc_model)

  rdma_handle qp_h;
  rdma_handle pd_h;
  rdma_handle send_cq_h;
  rdma_handle recv_cq_h;
  rdma_handle srq_h;
  rdma_transport_e transport;
  rdma_qp_state_e state;
  int unsigned host_id;
  int unsigned vf_id;
  int unsigned stat_index;
  bit [15:0] pkey;
  bit [7:0] qp_sequence;
  rdma_rdma_access_t access;
  int unsigned sq_depth;
  int unsigned rq_depth;
  rdma_backing_addr_t sq_backing;
  rdma_backing_addr_t rq_backing;
  rdma_backing_addr_t context_backing;
  rdma_object_mode_e sq_mode;
  rdma_object_mode_e rq_mode;
  rdma_address_vector address_vector;
  bit signature_enable;
  bit tx_flow_control;
  bit rx_flow_control;
  rdma_qpc_transport_ext transport_ext;

  function new(string name = "rdma_qpc_model");
    super.new(name);
    qp_h = null;
    pd_h = null;
    send_cq_h = null;
    recv_cq_h = null;
    srq_h = null;
    transport = RDMA_TRANSPORT_RC;
    state = RDMA_QPS_RESET;
    host_id = '0;
    vf_id = '0;
    stat_index = '0;
    pkey = '0;
    qp_sequence = '0;
    access = '0;
    sq_depth = '0;
    rq_depth = '0;
    sq_backing = '0;
    rq_backing = '0;
    context_backing = '0;
    sq_mode = RDMA_OBJECT_DIRECT_4K;
    rq_mode = RDMA_OBJECT_DIRECT_4K;
    address_vector = rdma_address_vector::type_id::create("address_vector");
    signature_enable = 1'b0;
    tx_flow_control = 1'b0;
    rx_flow_control = 1'b0;
    transport_ext = null;
  endfunction

  virtual function void do_copy(uvm_object rhs);
    rdma_qpc_model rhs_qpc;
    uvm_object cloned_object;

    super.do_copy(rhs);
    if (!$cast(rhs_qpc, rhs))
      `uvm_fatal("RDMA_COPY_TYPE", "QPC model copy mismatch")
    qp_h = rdma_clone_handle_value(rhs_qpc.qp_h, "QPC QP");
    pd_h = rdma_clone_handle_value(rhs_qpc.pd_h, "QPC PD");
    send_cq_h = rdma_clone_handle_value(rhs_qpc.send_cq_h, "QPC send CQ");
    recv_cq_h = rdma_clone_handle_value(rhs_qpc.recv_cq_h,
                                        "QPC receive CQ");
    srq_h = rdma_clone_handle_value(rhs_qpc.srq_h, "QPC SRQ");
    transport = rhs_qpc.transport;
    state = rhs_qpc.state;
    host_id = rhs_qpc.host_id;
    vf_id = rhs_qpc.vf_id;
    stat_index = rhs_qpc.stat_index;
    pkey = rhs_qpc.pkey;
    qp_sequence = rhs_qpc.qp_sequence;
    access = rhs_qpc.access;
    sq_depth = rhs_qpc.sq_depth;
    rq_depth = rhs_qpc.rq_depth;
    sq_backing = rhs_qpc.sq_backing;
    rq_backing = rhs_qpc.rq_backing;
    context_backing = rhs_qpc.context_backing;
    sq_mode = rhs_qpc.sq_mode;
    rq_mode = rhs_qpc.rq_mode;
    address_vector = rdma_clone_address_vector_value(rhs_qpc.address_vector,
                                                     "QPC");
    signature_enable = rhs_qpc.signature_enable;
    tx_flow_control = rhs_qpc.tx_flow_control;
    rx_flow_control = rhs_qpc.rx_flow_control;
    if (rhs_qpc.transport_ext == null) begin
      transport_ext = null;
    end
    else begin
      cloned_object = rhs_qpc.transport_ext.clone();
      if (cloned_object == null || !$cast(transport_ext, cloned_object))
        `uvm_fatal("RDMA_COPY_TYPE", "QPC extension clone mismatch")
    end
  endfunction

  virtual function rdma_status validate();
    rdma_status status;
    rdma_qpc_rc_ext rc_ext;
    rdma_qpc_ud_ext ud_ext;
    rdma_qpc_urc_ext urc_ext;

    status = rdma_context_handle_status(qp_h, RDMA_RESOURCE_QP, 21,
                                        "QPC QP");
    if (!status.ok()) return status;
    status = rdma_context_handle_status(pd_h, RDMA_RESOURCE_PD, 16,
                                        "QPC PD");
    if (!status.ok()) return status;
    status = rdma_context_handle_status(send_cq_h, RDMA_RESOURCE_CQ, 20,
                                        "QPC send CQ");
    if (!status.ok()) return status;
    status = rdma_context_handle_status(recv_cq_h, RDMA_RESOURCE_CQ, 20,
                                        "QPC receive CQ");
    if (!status.ok()) return status;
    if (srq_h != null) begin
      status = rdma_context_handle_status(srq_h, RDMA_RESOURCE_SRQ, 15,
                                          "QPC SRQ");
      if (!status.ok()) return status;
    end
    status = rdma_context_lifecycle_status(qp_h, pd_h, "QPC PD");
    if (!status.ok()) return status;
    status = rdma_context_lifecycle_status(qp_h, send_cq_h, "QPC send CQ");
    if (!status.ok()) return status;
    status = rdma_context_lifecycle_status(qp_h, recv_cq_h,
                                           "QPC receive CQ");
    if (!status.ok()) return status;
    if (srq_h != null) begin
      status = rdma_context_lifecycle_status(qp_h, srq_h, "QPC SRQ");
      if (!status.ok()) return status;
    end
    if (!rdma_is_power_of_two(sq_depth) ||
        !rdma_is_power_of_two(rq_depth))
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "QPC depth is not a nonzero power of two");
    if (!(state inside {RDMA_QPS_RESET, RDMA_QPS_INIT, RDMA_QPS_RTR,
                        RDMA_QPS_RTS, RDMA_QPS_SQD, RDMA_QPS_SQE,
                        RDMA_QPS_ERROR}))
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "QPC state is invalid");
    if ((sq_backing.value & 64'hfff) != 0 ||
        (rq_backing.value & 64'hfff) != 0)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "QPC queue backing is not 4 KiB aligned");
    if ((context_backing.value & 64'h1ff) != 0)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "QPC context backing is not 512-byte aligned");
    status = rdma_object_mode_status(sq_mode, "QPC SQ");
    if (!status.ok()) return status;
    status = rdma_object_mode_status(rq_mode, "QPC RQ");
    if (!status.ok()) return status;
    if (address_vector == null)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "QPC address vector is null");
    status = address_vector.validate();
    if (!status.ok()) return status;
    if (transport_ext == null || transport_ext.transport_kind() != transport)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "QPC transport extension does not match");
    case (transport)
      RDMA_TRANSPORT_RC:
        if (!$cast(rc_ext, transport_ext))
          return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                                   "RC QPC lacks an RC extension");
      RDMA_TRANSPORT_UD:
        if (!$cast(ud_ext, transport_ext))
          return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                                   "UD QPC lacks a UD extension");
      RDMA_TRANSPORT_URC:
        if (!$cast(urc_ext, transport_ext))
          return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                                   "URC QPC lacks a URC extension");
      default:
        return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                                 "QPC transport is unsupported");
    endcase
    return transport_ext.validate();
  endfunction

  virtual function string describe();
    string extension_text;

    extension_text = (transport_ext == null) ? "null"
                                             : transport_ext.describe();
    return $sformatf("QPC(transport=%s sq_depth=%0d rq_depth=%0d %s)",
                     transport.name(), sq_depth, rq_depth, extension_text);
  endfunction
endclass

class rdma_cqc_model extends rdma_hw_model;
  `uvm_object_utils(rdma_cqc_model)

  rdma_handle cq_h;
  rdma_handle ceq_h;
  rdma_context_state_e state;
  int unsigned depth;
  int unsigned cqe_size_bytes;
  int unsigned threshold;
  rdma_page_table_layout page_layout;
  rdma_ring_position producer;
  rdma_ring_position consumer;
  bit urc_enable;
  bit load_ci_done;
  bit [1:0] last_arm_sequence;
  bit [1:0] arm_sequence;
  bit [1:0] arm_state;
  rdma_backing_addr_t shadow_backing;

  function new(string name = "rdma_cqc_model");
    super.new(name);
    cq_h = null;
    ceq_h = null;
    state = RDMA_CONTEXT_INVALID;
    depth = '0;
    cqe_size_bytes = '0;
    threshold = '0;
    page_layout = rdma_page_table_layout::type_id::create("page_layout");
    producer = rdma_ring_position::type_id::create("producer");
    consumer = rdma_ring_position::type_id::create("consumer");
    urc_enable = 1'b0;
    load_ci_done = 1'b0;
    last_arm_sequence = '0;
    arm_sequence = '0;
    arm_state = '0;
    shadow_backing = '0;
  endfunction

  virtual function void do_copy(uvm_object rhs);
    rdma_cqc_model rhs_cqc;

    super.do_copy(rhs);
    if (!$cast(rhs_cqc, rhs))
      `uvm_fatal("RDMA_COPY_TYPE", "CQC model copy mismatch")
    cq_h = rdma_clone_handle_value(rhs_cqc.cq_h, "CQC CQ");
    ceq_h = rdma_clone_handle_value(rhs_cqc.ceq_h, "CQC CEQ");
    state = rhs_cqc.state;
    depth = rhs_cqc.depth;
    cqe_size_bytes = rhs_cqc.cqe_size_bytes;
    threshold = rhs_cqc.threshold;
    page_layout = rdma_clone_page_layout_value(rhs_cqc.page_layout, "CQC");
    producer = rdma_clone_ring_position_value(rhs_cqc.producer,
                                              "CQC producer");
    consumer = rdma_clone_ring_position_value(rhs_cqc.consumer,
                                              "CQC consumer");
    urc_enable = rhs_cqc.urc_enable;
    load_ci_done = rhs_cqc.load_ci_done;
    last_arm_sequence = rhs_cqc.last_arm_sequence;
    arm_sequence = rhs_cqc.arm_sequence;
    arm_state = rhs_cqc.arm_state;
    shadow_backing = rhs_cqc.shadow_backing;
  endfunction

  virtual function rdma_status validate();
    rdma_status status;

    status = rdma_context_handle_status(cq_h, RDMA_RESOURCE_CQ, 21,
                                        "CQC CQ");
    if (!status.ok()) return status;
    if (ceq_h != null) begin
      status = rdma_context_handle_status(ceq_h, RDMA_RESOURCE_CEQ, 12,
                                          "CQC CEQ");
      if (!status.ok()) return status;
      status = rdma_context_lifecycle_status(cq_h, ceq_h, "CQC CEQ");
      if (!status.ok()) return status;
    end
    status = rdma_context_state_status(state, "CQC");
    if (!status.ok()) return status;
    if (!rdma_is_power_of_two(depth))
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "CQC depth is not a nonzero power of two");
    if (page_layout == null || producer == null || consumer == null)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "CQC nested layout or ring is null");
    status = page_layout.validate();
    if (!status.ok()) return status;
    status = producer.validate();
    if (!status.ok()) return status;
    status = consumer.validate();
    if (!status.ok()) return status;
    if (producer.index >= depth || consumer.index >= depth)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "CQC ring position is outside the depth");
    if ((shadow_backing.value & 64'h3f) != 0)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "CQC shadow backing is not 64-byte aligned");
    return rdma_status::success();
  endfunction

  virtual function string describe();
    return $sformatf("CQC(depth=%0d cqe_size=%0d shadow=0x%016x)",
                     depth, cqe_size_bytes, shadow_backing.value);
  endfunction
endclass

class rdma_mrt_model extends rdma_hw_model;
  `uvm_object_utils(rdma_mrt_model)

  rdma_handle mr_h;
  rdma_handle pd_h;
  rdma_context_state_e state;
  rdma_iova_t iova;
  longint unsigned length;
  bit [31:0] lkey;
  bit [31:0] rkey;
  rdma_rdma_access_t access;
  bit [1:0] object_type;
  rdma_mr_page_layout page_layout;

  function new(string name = "rdma_mrt_model");
    super.new(name);
    mr_h = null;
    pd_h = null;
    state = RDMA_CONTEXT_INVALID;
    iova = '0;
    length = '0;
    lkey = '0;
    rkey = '0;
    access = '0;
    object_type = '0;
    page_layout = rdma_mr_page_layout::type_id::create("page_layout");
  endfunction

  virtual function void do_copy(uvm_object rhs);
    rdma_mrt_model rhs_mrt;

    super.do_copy(rhs);
    if (!$cast(rhs_mrt, rhs))
      `uvm_fatal("RDMA_COPY_TYPE", "MRT model copy mismatch")
    mr_h = rdma_clone_handle_value(rhs_mrt.mr_h, "MRT MR");
    pd_h = rdma_clone_handle_value(rhs_mrt.pd_h, "MRT PD");
    state = rhs_mrt.state;
    iova = rhs_mrt.iova;
    length = rhs_mrt.length;
    lkey = rhs_mrt.lkey;
    rkey = rhs_mrt.rkey;
    access = rhs_mrt.access;
    object_type = rhs_mrt.object_type;
    page_layout = rdma_clone_mr_page_layout_value(rhs_mrt.page_layout,
                                                  "MRT");
  endfunction

  virtual function rdma_status validate();
    rdma_status status;
    bit has_remote_right;

    status = rdma_context_handle_status(mr_h, RDMA_RESOURCE_MR, 24,
                                        "MRT MR");
    if (!status.ok()) return status;
    status = rdma_context_handle_status(pd_h, RDMA_RESOURCE_PD, 16,
                                        "MRT PD");
    if (!status.ok()) return status;
    status = rdma_context_lifecycle_status(mr_h, pd_h, "MRT PD");
    if (!status.ok()) return status;
    status = rdma_context_state_status(state, "MRT");
    if (!status.ok()) return status;
    if (length == 0)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "MRT length is zero");
    if (length[63:46] != 0)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "MRT length exceeds 46 bits");
    if (mr_h.object_id != {8'b0, lkey[31:8]})
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "MRT object ID does not match lkey index");
    has_remote_right = access.remote_read || access.remote_write ||
                       access.remote_atomic;
    if ((has_remote_right && rkey != lkey) ||
        (!has_remote_right && !(rkey == 0 || rkey == lkey)))
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "MRT lkey and rkey are inconsistent");
    if (page_layout == null)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "MRT page layout is null");
    status = page_layout.validate();
    if (!status.ok()) return status;
    return rdma_status::success();
  endfunction

  virtual function string describe();
    return $sformatf("MRT(iova=0x%016x length=%0d lkey=0x%08x)",
                     iova.value, length, lkey);
  endfunction
endclass

class rdma_srqc_model extends rdma_hw_model;
  `uvm_object_utils(rdma_srqc_model)

  rdma_handle srq_h;
  rdma_handle pd_h;
  rdma_context_state_e state;
  int unsigned depth;
  int unsigned load_pi_threshold;
  int unsigned limit_threshold;
  rdma_object_mode_e object_mode;
  rdma_backing_addr_t srfq_backing;
  rdma_backing_addr_t shadow_backing;
  rdma_ring_position producer;
  bit [1:0] arm_sequence;

  function new(string name = "rdma_srqc_model");
    super.new(name);
    srq_h = null;
    pd_h = null;
    state = RDMA_CONTEXT_INVALID;
    depth = '0;
    load_pi_threshold = '0;
    limit_threshold = '0;
    object_mode = RDMA_OBJECT_DIRECT_4K;
    srfq_backing = '0;
    shadow_backing = '0;
    producer = rdma_ring_position::type_id::create("producer");
    arm_sequence = '0;
  endfunction

  virtual function void do_copy(uvm_object rhs);
    rdma_srqc_model rhs_srqc;

    super.do_copy(rhs);
    if (!$cast(rhs_srqc, rhs))
      `uvm_fatal("RDMA_COPY_TYPE", "SRQC model copy mismatch")
    srq_h = rdma_clone_handle_value(rhs_srqc.srq_h, "SRQC SRQ");
    pd_h = rdma_clone_handle_value(rhs_srqc.pd_h, "SRQC PD");
    state = rhs_srqc.state;
    depth = rhs_srqc.depth;
    load_pi_threshold = rhs_srqc.load_pi_threshold;
    limit_threshold = rhs_srqc.limit_threshold;
    object_mode = rhs_srqc.object_mode;
    srfq_backing = rhs_srqc.srfq_backing;
    shadow_backing = rhs_srqc.shadow_backing;
    producer = rdma_clone_ring_position_value(rhs_srqc.producer,
                                              "SRQC producer");
    arm_sequence = rhs_srqc.arm_sequence;
  endfunction

  virtual function rdma_status validate();
    rdma_status status;

    status = rdma_context_handle_status(srq_h, RDMA_RESOURCE_SRQ, 16,
                                        "SRQC SRQ");
    if (!status.ok()) return status;
    status = rdma_context_handle_status(pd_h, RDMA_RESOURCE_PD, 16,
                                        "SRQC PD");
    if (!status.ok()) return status;
    status = rdma_context_lifecycle_status(srq_h, pd_h, "SRQC PD");
    if (!status.ok()) return status;
    status = rdma_context_state_status(state, "SRQC");
    if (!status.ok()) return status;
    if (!rdma_is_power_of_two(depth))
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "SRQC depth is not a nonzero power of two");
    status = rdma_object_mode_status(object_mode, "SRQC");
    if (!status.ok()) return status;
    if (producer == null)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "SRQC producer position is null");
    status = producer.validate();
    if (!status.ok()) return status;
    if (producer.index >= depth)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "SRQC producer position exceeds depth");
    return rdma_status::success();
  endfunction

  virtual function string describe();
    return $sformatf("SRQC(depth=%0d producer=%0d)", depth,
                     (producer == null) ? 0 : producer.index);
  endfunction
endclass

class rdma_ceqc_model extends rdma_hw_model;
  `uvm_object_utils(rdma_ceqc_model)

  rdma_handle ceq_h;
  rdma_context_state_e state;
  int unsigned depth;
  int unsigned vector_id;
  rdma_page_table_layout page_layout;
  rdma_ring_position producer;
  rdma_ring_position consumer;

  function new(string name = "rdma_ceqc_model");
    super.new(name);
    ceq_h = null;
    state = RDMA_CONTEXT_INVALID;
    depth = '0;
    vector_id = '0;
    page_layout = rdma_page_table_layout::type_id::create("page_layout");
    producer = rdma_ring_position::type_id::create("producer");
    consumer = rdma_ring_position::type_id::create("consumer");
  endfunction

  virtual function void do_copy(uvm_object rhs);
    rdma_ceqc_model rhs_ceqc;

    super.do_copy(rhs);
    if (!$cast(rhs_ceqc, rhs))
      `uvm_fatal("RDMA_COPY_TYPE", "CEQC model copy mismatch")
    ceq_h = rdma_clone_handle_value(rhs_ceqc.ceq_h, "CEQC CEQ");
    state = rhs_ceqc.state;
    depth = rhs_ceqc.depth;
    vector_id = rhs_ceqc.vector_id;
    page_layout = rdma_clone_page_layout_value(rhs_ceqc.page_layout,
                                               "CEQC");
    producer = rdma_clone_ring_position_value(rhs_ceqc.producer,
                                              "CEQC producer");
    consumer = rdma_clone_ring_position_value(rhs_ceqc.consumer,
                                              "CEQC consumer");
  endfunction

  virtual function rdma_status validate();
    rdma_status status;

    status = rdma_context_handle_status(ceq_h, RDMA_RESOURCE_CEQ, 12,
                                        "CEQC CEQ");
    if (!status.ok()) return status;
    status = rdma_context_state_status(state, "CEQC");
    if (!status.ok()) return status;
    if (!rdma_is_power_of_two(depth))
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "CEQC depth is not a nonzero power of two");
    if (page_layout == null || producer == null || consumer == null)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "CEQC nested layout or ring is null");
    status = page_layout.validate();
    if (!status.ok()) return status;
    status = producer.validate();
    if (!status.ok()) return status;
    status = consumer.validate();
    if (!status.ok()) return status;
    if (producer.index >= depth || consumer.index >= depth)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "CEQC ring position is outside the depth");
    return rdma_status::success();
  endfunction

  virtual function string describe();
    return $sformatf("CEQC(depth=%0d vector=%0d)", depth, vector_id);
  endfunction
endclass

class rdma_aeqc_model extends rdma_hw_model;
  `uvm_object_utils(rdma_aeqc_model)

  rdma_handle aeq_h;
  rdma_context_state_e state;
  int unsigned depth;
  int unsigned vector_id;
  rdma_page_table_layout page_layout;
  rdma_ring_position producer;
  rdma_ring_position consumer;

  function new(string name = "rdma_aeqc_model");
    super.new(name);
    aeq_h = null;
    state = RDMA_CONTEXT_INVALID;
    depth = '0;
    vector_id = '0;
    page_layout = rdma_page_table_layout::type_id::create("page_layout");
    producer = rdma_ring_position::type_id::create("producer");
    consumer = rdma_ring_position::type_id::create("consumer");
  endfunction

  virtual function void do_copy(uvm_object rhs);
    rdma_aeqc_model rhs_aeqc;

    super.do_copy(rhs);
    if (!$cast(rhs_aeqc, rhs))
      `uvm_fatal("RDMA_COPY_TYPE", "AEQC model copy mismatch")
    aeq_h = rdma_clone_handle_value(rhs_aeqc.aeq_h, "AEQC AEQ");
    state = rhs_aeqc.state;
    depth = rhs_aeqc.depth;
    vector_id = rhs_aeqc.vector_id;
    page_layout = rdma_clone_page_layout_value(rhs_aeqc.page_layout,
                                               "AEQC");
    producer = rdma_clone_ring_position_value(rhs_aeqc.producer,
                                              "AEQC producer");
    consumer = rdma_clone_ring_position_value(rhs_aeqc.consumer,
                                              "AEQC consumer");
  endfunction

  virtual function rdma_status validate();
    rdma_status status;

    status = rdma_context_handle_status(aeq_h, RDMA_RESOURCE_AEQ, 12,
                                        "AEQC AEQ");
    if (!status.ok()) return status;
    status = rdma_context_state_status(state, "AEQC");
    if (!status.ok()) return status;
    if (!rdma_is_power_of_two(depth))
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "AEQC depth is not a nonzero power of two");
    if (page_layout == null || producer == null || consumer == null)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "AEQC nested layout or ring is null");
    status = page_layout.validate();
    if (!status.ok()) return status;
    status = producer.validate();
    if (!status.ok()) return status;
    status = consumer.validate();
    if (!status.ok()) return status;
    if (producer.index >= depth || consumer.index >= depth)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "AEQC ring position is outside the depth");
    return rdma_status::success();
  endfunction

  virtual function string describe();
    return $sformatf("AEQC(depth=%0d vector=%0d)", depth, vector_id);
  endfunction
endclass
