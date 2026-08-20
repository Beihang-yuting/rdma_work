virtual class rdma_hw_model extends uvm_object;
  function new(string name = "rdma_hw_model");
    super.new(name);
  endfunction

  pure virtual function rdma_status validate();
  pure virtual function string describe();
endclass

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
  bit [7:0] retry_count;
  bit [7:0] rnr_retry_count;
  bit [7:0] path_mtu;

  function new(string name = "rdma_qpc_rc_ext");
    super.new(name);
    remote_qpn = '0;
    send_psn = '0;
    recv_psn = '0;
    retry_count = '0;
    rnr_retry_count = '0;
    path_mtu = '0;
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
    path_mtu = rhs_ext.path_mtu;
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
    return $sformatf("RC(remote_qpn=%0d send_psn=%0d recv_psn=%0d)",
                     remote_qpn, send_psn, recv_psn);
  endfunction
endclass

class rdma_qpc_ud_ext extends rdma_qpc_transport_ext;
  `uvm_object_utils(rdma_qpc_ud_ext)

  bit [31:0] qkey;
  int unsigned address_vector_id;
  bit address_vector_valid;
  bit [7:0] traffic_class;
  bit [19:0] flow_label;

  function new(string name = "rdma_qpc_ud_ext");
    super.new(name);
    qkey = '0;
    address_vector_id = '0;
    address_vector_valid = 1'b0;
    traffic_class = '0;
    flow_label = '0;
  endfunction

  virtual function void do_copy(uvm_object rhs);
    rdma_qpc_ud_ext rhs_ext;

    super.do_copy(rhs);
    if (!$cast(rhs_ext, rhs))
      `uvm_fatal("RDMA_COPY_TYPE", "UD QPC extension copy mismatch")
    qkey = rhs_ext.qkey;
    address_vector_id = rhs_ext.address_vector_id;
    address_vector_valid = rhs_ext.address_vector_valid;
    traffic_class = rhs_ext.traffic_class;
    flow_label = rhs_ext.flow_label;
  endfunction

  virtual function rdma_transport_e transport_kind();
    return RDMA_TRANSPORT_UD;
  endfunction

  virtual function rdma_status validate();
    if (qkey == 0 || !address_vector_valid)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "UD QPC lacks qkey or address vector");
    return rdma_status::success();
  endfunction

  virtual function string describe();
    return $sformatf("UD(qkey=0x%08x address_vector_id=%0d)",
                     qkey, address_vector_id);
  endfunction
endclass

class rdma_qpc_urc_ext extends rdma_qpc_transport_ext;
  `uvm_object_utils(rdma_qpc_urc_ext)

  bit [23:0] remote_qpn;
  bit [23:0] send_psn;
  bit [7:0] path_mtu;

  function new(string name = "rdma_qpc_urc_ext");
    super.new(name);
    remote_qpn = '0;
    send_psn = '0;
    path_mtu = '0;
  endfunction

  virtual function void do_copy(uvm_object rhs);
    rdma_qpc_urc_ext rhs_ext;

    super.do_copy(rhs);
    if (!$cast(rhs_ext, rhs))
      `uvm_fatal("RDMA_COPY_TYPE", "URC QPC extension copy mismatch")
    remote_qpn = rhs_ext.remote_qpn;
    send_psn = rhs_ext.send_psn;
    path_mtu = rhs_ext.path_mtu;
  endfunction

  virtual function rdma_transport_e transport_kind();
    return RDMA_TRANSPORT_URC;
  endfunction

  virtual function rdma_status validate();
    if (remote_qpn == 0)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "URC QPC remote QPN is zero");
    return rdma_status::success();
  endfunction

  virtual function string describe();
    return $sformatf("URC(remote_qpn=%0d send_psn=%0d)",
                     remote_qpn, send_psn);
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
  int unsigned sq_depth;
  int unsigned rq_depth;
  rdma_hmc_fvm_addr_t sq_base;
  rdma_hmc_fvm_addr_t rq_base;
  int unsigned sq_producer_index;
  int unsigned sq_consumer_index;
  int unsigned rq_producer_index;
  int unsigned rq_consumer_index;
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
    sq_depth = '0;
    rq_depth = '0;
    sq_base = '0;
    rq_base = '0;
    sq_producer_index = '0;
    sq_consumer_index = '0;
    rq_producer_index = '0;
    rq_consumer_index = '0;
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
    sq_depth = rhs_qpc.sq_depth;
    rq_depth = rhs_qpc.rq_depth;
    sq_base = rhs_qpc.sq_base;
    rq_base = rhs_qpc.rq_base;
    sq_producer_index = rhs_qpc.sq_producer_index;
    sq_consumer_index = rhs_qpc.sq_consumer_index;
    rq_producer_index = rhs_qpc.rq_producer_index;
    rq_consumer_index = rhs_qpc.rq_consumer_index;
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
    rdma_qpc_rc_ext rc_ext;
    rdma_qpc_ud_ext ud_ext;
    rdma_qpc_urc_ext urc_ext;

    if (qp_h == null || qp_h.kind != RDMA_RESOURCE_QP ||
        pd_h == null || pd_h.kind != RDMA_RESOURCE_PD ||
        send_cq_h == null || send_cq_h.kind != RDMA_RESOURCE_CQ ||
        recv_cq_h == null || recv_cq_h.kind != RDMA_RESOURCE_CQ)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "QPC requires QP, PD, and CQ references");
    if (!rdma_is_power_of_two(sq_depth) ||
        !rdma_is_power_of_two(rq_depth))
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "QPC depth is not a nonzero power of two");
    if (!(state inside {RDMA_QPS_RESET, RDMA_QPS_INIT, RDMA_QPS_RTR,
                        RDMA_QPS_RTS, RDMA_QPS_SQD, RDMA_QPS_SQE,
                        RDMA_QPS_ERROR}))
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "QPC state is invalid");
    if (sq_producer_index >= sq_depth || sq_consumer_index >= sq_depth ||
        rq_producer_index >= rq_depth || rq_consumer_index >= rq_depth)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "QPC queue index is outside the queue depth");
    if ((sq_base.value & 64'h3f) != 0 || (rq_base.value & 64'h3f) != 0)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "QPC queue base is not 64-byte aligned");
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
  int unsigned depth;
  rdma_hmc_fvm_addr_t base_addr;
  int unsigned producer_index;
  int unsigned consumer_index;
  bit armed;

  function new(string name = "rdma_cqc_model");
    super.new(name);
    cq_h = null;
    ceq_h = null;
    depth = '0;
    base_addr = '0;
    producer_index = '0;
    consumer_index = '0;
    armed = 1'b0;
  endfunction

  virtual function void do_copy(uvm_object rhs);
    rdma_cqc_model rhs_cqc;

    super.do_copy(rhs);
    if (!$cast(rhs_cqc, rhs))
      `uvm_fatal("RDMA_COPY_TYPE", "CQC model copy mismatch")
    cq_h = rdma_clone_handle_value(rhs_cqc.cq_h, "CQC CQ");
    ceq_h = rdma_clone_handle_value(rhs_cqc.ceq_h, "CQC CEQ");
    depth = rhs_cqc.depth;
    base_addr = rhs_cqc.base_addr;
    producer_index = rhs_cqc.producer_index;
    consumer_index = rhs_cqc.consumer_index;
    armed = rhs_cqc.armed;
  endfunction

  virtual function rdma_status validate();
    if (cq_h == null || cq_h.kind != RDMA_RESOURCE_CQ)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "CQC requires a CQ handle");
    if (!rdma_is_power_of_two(depth) || (base_addr.value & 64'h3f) != 0)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "CQC depth or alignment is invalid");
    if (producer_index >= depth || consumer_index >= depth)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "CQC index is outside the queue depth");
    return rdma_status::success();
  endfunction

  virtual function string describe();
    return $sformatf("CQC(depth=%0d base=0x%016x)", depth, base_addr.value);
  endfunction
endclass

class rdma_mrt_model extends rdma_hw_model;
  `uvm_object_utils(rdma_mrt_model)

  rdma_handle mr_h;
  rdma_handle pd_h;
  rdma_iova_t iova;
  longint unsigned length;
  rdma_backing_addr_t backing_addr;
  bit [31:0] lkey;
  bit [31:0] rkey;
  rdma_dma_permission_t permissions;

  function new(string name = "rdma_mrt_model");
    super.new(name);
    mr_h = null;
    pd_h = null;
    iova = '0;
    length = '0;
    backing_addr = '0;
    lkey = '0;
    rkey = '0;
    permissions = '0;
  endfunction

  virtual function void do_copy(uvm_object rhs);
    rdma_mrt_model rhs_mrt;

    super.do_copy(rhs);
    if (!$cast(rhs_mrt, rhs))
      `uvm_fatal("RDMA_COPY_TYPE", "MRT model copy mismatch")
    mr_h = rdma_clone_handle_value(rhs_mrt.mr_h, "MRT MR");
    pd_h = rdma_clone_handle_value(rhs_mrt.pd_h, "MRT PD");
    iova = rhs_mrt.iova;
    length = rhs_mrt.length;
    backing_addr = rhs_mrt.backing_addr;
    lkey = rhs_mrt.lkey;
    rkey = rhs_mrt.rkey;
    permissions = rhs_mrt.permissions;
  endfunction

  virtual function rdma_status validate();
    if (mr_h == null || mr_h.kind != RDMA_RESOURCE_MR ||
        pd_h == null || pd_h.kind != RDMA_RESOURCE_PD)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "MRT requires MR and PD handles");
    if (length == 0)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "MRT length is zero");
    return rdma_status::success();
  endfunction

  virtual function string describe();
    return $sformatf("MRT(iova=0x%016x length=%0d)", iova.value, length);
  endfunction
endclass

class rdma_srqc_model extends rdma_hw_model;
  `uvm_object_utils(rdma_srqc_model)

  rdma_handle srq_h;
  rdma_handle pd_h;
  int unsigned depth;
  int unsigned max_sge;
  rdma_hmc_fvm_addr_t base_addr;
  int unsigned producer_index;
  int unsigned consumer_index;

  function new(string name = "rdma_srqc_model");
    super.new(name);
    srq_h = null;
    pd_h = null;
    depth = '0;
    max_sge = 1;
    base_addr = '0;
    producer_index = '0;
    consumer_index = '0;
  endfunction

  virtual function void do_copy(uvm_object rhs);
    rdma_srqc_model rhs_srqc;

    super.do_copy(rhs);
    if (!$cast(rhs_srqc, rhs))
      `uvm_fatal("RDMA_COPY_TYPE", "SRQC model copy mismatch")
    srq_h = rdma_clone_handle_value(rhs_srqc.srq_h, "SRQC SRQ");
    pd_h = rdma_clone_handle_value(rhs_srqc.pd_h, "SRQC PD");
    depth = rhs_srqc.depth;
    max_sge = rhs_srqc.max_sge;
    base_addr = rhs_srqc.base_addr;
    producer_index = rhs_srqc.producer_index;
    consumer_index = rhs_srqc.consumer_index;
  endfunction

  virtual function rdma_status validate();
    if (srq_h == null || srq_h.kind != RDMA_RESOURCE_SRQ ||
        pd_h == null || pd_h.kind != RDMA_RESOURCE_PD)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "SRQC requires SRQ and PD handles");
    if (!rdma_is_power_of_two(depth) || max_sge == 0 ||
        (base_addr.value & 64'h3f) != 0)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "SRQC depth, SGE count, or alignment is invalid");
    if (producer_index >= depth || consumer_index >= depth)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "SRQC index is outside the queue depth");
    return rdma_status::success();
  endfunction

  virtual function string describe();
    return $sformatf("SRQC(depth=%0d max_sge=%0d)", depth, max_sge);
  endfunction
endclass

class rdma_ceqc_model extends rdma_hw_model;
  `uvm_object_utils(rdma_ceqc_model)

  rdma_handle ceq_h;
  int unsigned depth;
  rdma_hmc_fvm_addr_t base_addr;
  int unsigned producer_index;
  int unsigned consumer_index;
  bit interrupt_enable;
  int unsigned vector_id;

  function new(string name = "rdma_ceqc_model");
    super.new(name);
    ceq_h = null;
    depth = '0;
    base_addr = '0;
    producer_index = '0;
    consumer_index = '0;
    interrupt_enable = 1'b0;
    vector_id = '0;
  endfunction

  virtual function void do_copy(uvm_object rhs);
    rdma_ceqc_model rhs_ceqc;

    super.do_copy(rhs);
    if (!$cast(rhs_ceqc, rhs))
      `uvm_fatal("RDMA_COPY_TYPE", "CEQC model copy mismatch")
    ceq_h = rdma_clone_handle_value(rhs_ceqc.ceq_h, "CEQC CEQ");
    depth = rhs_ceqc.depth;
    base_addr = rhs_ceqc.base_addr;
    producer_index = rhs_ceqc.producer_index;
    consumer_index = rhs_ceqc.consumer_index;
    interrupt_enable = rhs_ceqc.interrupt_enable;
    vector_id = rhs_ceqc.vector_id;
  endfunction

  virtual function rdma_status validate();
    if (ceq_h == null || ceq_h.kind != RDMA_RESOURCE_CEQ)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "CEQC requires a CEQ handle");
    if (!rdma_is_power_of_two(depth) || (base_addr.value & 64'h3f) != 0)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "CEQC depth or alignment is invalid");
    if (producer_index >= depth || consumer_index >= depth)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "CEQC index is outside the queue depth");
    return rdma_status::success();
  endfunction

  virtual function string describe();
    return $sformatf("CEQC(depth=%0d vector=%0d)", depth, vector_id);
  endfunction
endclass

class rdma_aeqc_model extends rdma_hw_model;
  `uvm_object_utils(rdma_aeqc_model)

  rdma_handle aeq_h;
  int unsigned depth;
  rdma_hmc_fvm_addr_t base_addr;
  int unsigned producer_index;
  int unsigned consumer_index;
  bit interrupt_enable;
  int unsigned vector_id;

  function new(string name = "rdma_aeqc_model");
    super.new(name);
    aeq_h = null;
    depth = '0;
    base_addr = '0;
    producer_index = '0;
    consumer_index = '0;
    interrupt_enable = 1'b0;
    vector_id = '0;
  endfunction

  virtual function void do_copy(uvm_object rhs);
    rdma_aeqc_model rhs_aeqc;

    super.do_copy(rhs);
    if (!$cast(rhs_aeqc, rhs))
      `uvm_fatal("RDMA_COPY_TYPE", "AEQC model copy mismatch")
    aeq_h = rdma_clone_handle_value(rhs_aeqc.aeq_h, "AEQC AEQ");
    depth = rhs_aeqc.depth;
    base_addr = rhs_aeqc.base_addr;
    producer_index = rhs_aeqc.producer_index;
    consumer_index = rhs_aeqc.consumer_index;
    interrupt_enable = rhs_aeqc.interrupt_enable;
    vector_id = rhs_aeqc.vector_id;
  endfunction

  virtual function rdma_status validate();
    if (aeq_h == null || aeq_h.kind != RDMA_RESOURCE_AEQ)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "AEQC requires an AEQ handle");
    if (!rdma_is_power_of_two(depth) || (base_addr.value & 64'h3f) != 0)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "AEQC depth or alignment is invalid");
    if (producer_index >= depth || consumer_index >= depth)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "AEQC index is outside the queue depth");
    return rdma_status::success();
  endfunction

  virtual function string describe();
    return $sformatf("AEQC(depth=%0d vector=%0d)", depth, vector_id);
  endfunction
endclass
