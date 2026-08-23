typedef enum bit {
  XTR_V1_SRQ_DB_PI    = 1'b0,
  XTR_V1_SRQ_DB_LIMIT = 1'b1
} rdma_xtr_v1_srq_doorbell_variant_e;

typedef enum bit {
  XTR_V1_CQ_DB_RC_UD = 1'b0,
  XTR_V1_CQ_DB_URC   = 1'b1
} rdma_xtr_v1_cq_doorbell_variant_e;

virtual class rdma_xtr_v1_doorbell_model_base extends rdma_hw_model;
  rdma_handle target_h;

  function new(string name = "rdma_xtr_v1_doorbell_model_base");
    super.new(name);
    target_h = null;
  endfunction

  virtual function void do_copy(uvm_object rhs);
    rdma_xtr_v1_doorbell_model_base rhs_model;
    super.do_copy(rhs);
    if (!$cast(rhs_model, rhs))
      `uvm_fatal("RDMA_COPY_TYPE", "doorbell model copy type mismatch")
    target_h = rdma_clone_handle_value(rhs_model.target_h,
                                       "xtr_v1 doorbell target");
  endfunction

  protected function rdma_status target_status(
    rdma_resource_kind_e expected_kind,
    string label
  );
    if (target_h == null)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               {label, " target handle is null"});
    if (target_h.kind != expected_kind)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               {label, " target kind is invalid"});
    if (target_h.generation == 0)
      return rdma_status::make(RDMA_SC_STALE_GENERATION,
                               {label, " target generation is stale"});
    return rdma_status::success();
  endfunction

  protected function rdma_status width_status(
    longint unsigned value,
    int unsigned width,
    string label
  );
    if (width < 64 && (value >> width) != 0)
      return rdma_status::make(
        RDMA_SC_INVALID_ARGUMENT,
        $sformatf("%s exceeds %0d bits", label, width)
      );
    return rdma_status::success();
  endfunction

  protected function rdma_status target_id_status(
    int unsigned expected_id,
    string label
  );
    if (target_h.object_id != expected_id)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               {label, " target object ID does not match"});
    return rdma_status::success();
  endfunction

  virtual function rdma_status validate();
    if (target_h == null)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "xtr_v1 doorbell target handle is null");
    if (target_h.generation == 0)
      return rdma_status::make(RDMA_SC_STALE_GENERATION,
                               "xtr_v1 doorbell target generation is stale");
    return rdma_status::success();
  endfunction

  pure virtual function rdma_doorbell_kind_e doorbell_kind();
  pure virtual function string codec_variant();
endclass

class rdma_xtr_v1_cmq_sq_doorbell_model
    extends rdma_xtr_v1_doorbell_model_base;
  `uvm_object_utils(rdma_xtr_v1_cmq_sq_doorbell_model)

  int unsigned pi;
  bit polarity;

  function new(string name = "rdma_xtr_v1_cmq_sq_doorbell_model");
    super.new(name);
    pi = 0;
    polarity = 1'b0;
  endfunction

  virtual function void do_copy(uvm_object rhs);
    rdma_xtr_v1_cmq_sq_doorbell_model rhs_model;
    super.do_copy(rhs);
    if (!$cast(rhs_model, rhs))
      `uvm_fatal("RDMA_COPY_TYPE", "CMQ doorbell copy type mismatch")
    pi = rhs_model.pi;
    polarity = rhs_model.polarity;
  endfunction

  virtual function rdma_status validate();
    rdma_status status;
    status = target_status(RDMA_RESOURCE_CMQ, "CMQ doorbell");
    if (!status.ok()) return status;
    return width_status(pi, XTR_V1_CMQ_DB_PI_WIDTH, "CMQ doorbell PI");
  endfunction

  virtual function rdma_doorbell_kind_e doorbell_kind();
    return RDMA_DOORBELL_CMQ_SQ;
  endfunction

  virtual function string codec_variant();
    return "cmq_sq";
  endfunction

  virtual function string describe();
    return $sformatf("xtr_v1 CMQ doorbell(pi=%0d polarity=%0b)",
                     pi, polarity);
  endfunction
endclass

class rdma_xtr_v1_sq_doorbell_model
    extends rdma_xtr_v1_doorbell_model_base;
  `uvm_object_utils(rdma_xtr_v1_sq_doorbell_model)

  byte unsigned sqe_header[$];

  function new(string name = "rdma_xtr_v1_sq_doorbell_model");
    super.new(name);
    sqe_header.delete();
  endfunction

  virtual function void do_copy(uvm_object rhs);
    rdma_xtr_v1_sq_doorbell_model rhs_model;
    super.do_copy(rhs);
    if (!$cast(rhs_model, rhs))
      `uvm_fatal("RDMA_COPY_TYPE", "SQ doorbell copy type mismatch")
    sqe_header = rhs_model.sqe_header;
  endfunction

  virtual function rdma_status validate();
    rdma_status status;
    status = target_status(RDMA_RESOURCE_QP, "SQ doorbell");
    if (!status.ok()) return status;
    if (sqe_header.size() != XTR_V1_DB_BYTES)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "SQ doorbell header is not exactly eight bytes");
    return rdma_status::success();
  endfunction

  virtual function rdma_doorbell_kind_e doorbell_kind();
    return RDMA_DOORBELL_SQ;
  endfunction

  virtual function string codec_variant();
    return "sq";
  endfunction

  virtual function string describe();
    return "xtr_v1 opaque SQ doorbell header";
  endfunction
endclass

class rdma_xtr_v1_rq_doorbell_model
    extends rdma_xtr_v1_doorbell_model_base;
  `uvm_object_utils(rdma_xtr_v1_rq_doorbell_model)

  int unsigned qpn;
  int unsigned icos;
  int unsigned pi;
  bit wrap;

  function new(string name = "rdma_xtr_v1_rq_doorbell_model");
    super.new(name);
    qpn = 0;
    icos = 0;
    pi = 0;
    wrap = 1'b0;
  endfunction

  virtual function void do_copy(uvm_object rhs);
    rdma_xtr_v1_rq_doorbell_model rhs_model;
    super.do_copy(rhs);
    if (!$cast(rhs_model, rhs))
      `uvm_fatal("RDMA_COPY_TYPE", "RQ doorbell copy type mismatch")
    qpn = rhs_model.qpn;
    icos = rhs_model.icos;
    pi = rhs_model.pi;
    wrap = rhs_model.wrap;
  endfunction

  virtual function rdma_status validate();
    rdma_status status;
    status = target_status(RDMA_RESOURCE_QP, "RQ doorbell");
    if (!status.ok()) return status;
    status = width_status(qpn, XTR_V1_NOTIFY_RQ_QPN_WIDTH,
                          "RQ doorbell QPN");
    if (!status.ok()) return status;
    status = width_status(icos, XTR_V1_NOTIFY_RQ_ICOS_WIDTH,
                          "RQ doorbell ICOS");
    if (!status.ok()) return status;
    status = width_status(pi, XTR_V1_NOTIFY_RQ_PI_WIDTH,
                          "RQ doorbell PI");
    if (!status.ok()) return status;
    return target_id_status(qpn, "RQ doorbell");
  endfunction

  virtual function rdma_doorbell_kind_e doorbell_kind();
    return RDMA_DOORBELL_RQ;
  endfunction

  virtual function string codec_variant();
    return "rq";
  endfunction

  virtual function string describe();
    return $sformatf("xtr_v1 RQ doorbell(qpn=%0d pi=%0d wrap=%0b)",
                     qpn, pi, wrap);
  endfunction
endclass

class rdma_xtr_v1_srq_doorbell_model
    extends rdma_xtr_v1_doorbell_model_base;
  `uvm_object_utils(rdma_xtr_v1_srq_doorbell_model)

  rdma_xtr_v1_srq_doorbell_variant_e variant;
  int unsigned srqn;
  int unsigned pi;
  bit wrap;
  int unsigned limit;
  int unsigned arm_sn;

  function new(string name = "rdma_xtr_v1_srq_doorbell_model");
    super.new(name);
    variant = XTR_V1_SRQ_DB_PI;
    srqn = 0;
    pi = 0;
    wrap = 1'b0;
    limit = 0;
    arm_sn = 0;
  endfunction

  virtual function void do_copy(uvm_object rhs);
    rdma_xtr_v1_srq_doorbell_model rhs_model;
    super.do_copy(rhs);
    if (!$cast(rhs_model, rhs))
      `uvm_fatal("RDMA_COPY_TYPE", "SRQ doorbell copy type mismatch")
    variant = rhs_model.variant;
    srqn = rhs_model.srqn;
    pi = rhs_model.pi;
    wrap = rhs_model.wrap;
    limit = rhs_model.limit;
    arm_sn = rhs_model.arm_sn;
  endfunction

  virtual function rdma_status validate();
    rdma_status status;
    status = target_status(RDMA_RESOURCE_SRQ, "SRQ doorbell");
    if (!status.ok()) return status;
    if (!(variant inside {XTR_V1_SRQ_DB_PI, XTR_V1_SRQ_DB_LIMIT}))
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "SRQ doorbell variant is invalid");
    status = width_status(srqn, XTR_V1_NOTIFY_SRFQN_WIDTH,
                          "SRQ doorbell SRQN");
    if (!status.ok()) return status;
    if (variant == XTR_V1_SRQ_DB_PI) begin
      status = width_status(pi, XTR_V1_NOTIFY_SRFQ_PI_WIDTH,
                            "SRQ doorbell PI");
      if (!status.ok()) return status;
    end
    else begin
      status = width_status(limit, XTR_V1_NOTIFY_SRQ_LIMIT_WIDTH,
                            "SRQ doorbell limit");
      if (!status.ok()) return status;
      status = width_status(arm_sn, XTR_V1_NOTIFY_SRQ_ARM_SN_WIDTH,
                            "SRQ doorbell arm sequence");
      if (!status.ok()) return status;
    end
    return target_id_status(srqn, "SRQ doorbell");
  endfunction

  virtual function rdma_doorbell_kind_e doorbell_kind();
    return RDMA_DOORBELL_SRQ;
  endfunction

  virtual function string codec_variant();
    return (variant == XTR_V1_SRQ_DB_PI) ? "srq_pi" : "srq_limit";
  endfunction

  virtual function string describe();
    return $sformatf("xtr_v1 SRQ doorbell(variant=%s srqn=%0d)",
                     codec_variant(), srqn);
  endfunction
endclass

class rdma_xtr_v1_cq_doorbell_model
    extends rdma_xtr_v1_doorbell_model_base;
  `uvm_object_utils(rdma_xtr_v1_cq_doorbell_model)

  rdma_xtr_v1_cq_doorbell_variant_e variant;
  int unsigned cqn;
  int unsigned host_id;
  int unsigned ci;
  bit wrap;
  int unsigned sq_ci;
  bit sq_wrap;
  int unsigned rq_ci;
  bit rq_wrap;
  bit arm;
  int unsigned arm_state;
  int unsigned arm_sn;

  function new(string name = "rdma_xtr_v1_cq_doorbell_model");
    super.new(name);
    variant = XTR_V1_CQ_DB_RC_UD;
    cqn = 0;
    host_id = 0;
    ci = 0;
    wrap = 1'b0;
    sq_ci = 0;
    sq_wrap = 1'b0;
    rq_ci = 0;
    rq_wrap = 1'b0;
    arm = 1'b0;
    arm_state = 0;
    arm_sn = 0;
  endfunction

  virtual function void do_copy(uvm_object rhs);
    rdma_xtr_v1_cq_doorbell_model rhs_model;
    super.do_copy(rhs);
    if (!$cast(rhs_model, rhs))
      `uvm_fatal("RDMA_COPY_TYPE", "CQ doorbell copy type mismatch")
    variant = rhs_model.variant;
    cqn = rhs_model.cqn;
    host_id = rhs_model.host_id;
    ci = rhs_model.ci;
    wrap = rhs_model.wrap;
    sq_ci = rhs_model.sq_ci;
    sq_wrap = rhs_model.sq_wrap;
    rq_ci = rhs_model.rq_ci;
    rq_wrap = rhs_model.rq_wrap;
    arm = rhs_model.arm;
    arm_state = rhs_model.arm_state;
    arm_sn = rhs_model.arm_sn;
  endfunction

  virtual function rdma_status validate();
    rdma_status status;
    status = target_status(RDMA_RESOURCE_CQ, "CQ doorbell");
    if (!status.ok()) return status;
    if (!(variant inside {XTR_V1_CQ_DB_RC_UD, XTR_V1_CQ_DB_URC}))
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "CQ doorbell variant is invalid");
    status = width_status(cqn, XTR_V1_NOTIFY_CQ_CQN_WIDTH,
                          "CQ doorbell CQN");
    if (!status.ok()) return status;
    status = width_status(host_id, XTR_V1_NOTIFY_CQ_HOST_ID_WIDTH,
                          "CQ doorbell host ID");
    if (!status.ok()) return status;
    status = width_status(arm_state, XTR_V1_NOTIFY_CQ_ARM_ST_WIDTH,
                          "CQ doorbell arm state");
    if (!status.ok()) return status;
    status = width_status(arm_sn, XTR_V1_NOTIFY_CQ_ARM_SN_WIDTH,
                          "CQ doorbell arm sequence");
    if (!status.ok()) return status;
    if (variant == XTR_V1_CQ_DB_RC_UD) begin
      status = width_status(ci, XTR_V1_NOTIFY_CQ_CI_WIDTH,
                            "CQ doorbell CI");
      if (!status.ok()) return status;
    end
    else begin
      status = width_status(sq_ci, XTR_V1_NOTIFY_CQ_URC_SQ_CI_WIDTH,
                            "CQ doorbell SQ CI");
      if (!status.ok()) return status;
      status = width_status(rq_ci, XTR_V1_NOTIFY_CQ_URC_RQ_CI_WIDTH,
                            "CQ doorbell RQ CI");
      if (!status.ok()) return status;
    end
    return target_id_status(cqn, "CQ doorbell");
  endfunction

  virtual function rdma_doorbell_kind_e doorbell_kind();
    return RDMA_DOORBELL_CQ;
  endfunction

  virtual function string codec_variant();
    return (variant == XTR_V1_CQ_DB_RC_UD) ? "cq_rc_ud" : "cq_urc";
  endfunction

  virtual function string describe();
    return $sformatf("xtr_v1 CQ doorbell(variant=%s cqn=%0d)",
                     codec_variant(), cqn);
  endfunction
endclass

class rdma_xtr_v1_ceq_doorbell_model
    extends rdma_xtr_v1_doorbell_model_base;
  `uvm_object_utils(rdma_xtr_v1_ceq_doorbell_model)

  int unsigned ceqn;
  int unsigned ci;
  bit wrap;

  function new(string name = "rdma_xtr_v1_ceq_doorbell_model");
    super.new(name);
    ceqn = 0;
    ci = 0;
    wrap = 1'b0;
  endfunction

  virtual function void do_copy(uvm_object rhs);
    rdma_xtr_v1_ceq_doorbell_model rhs_model;
    super.do_copy(rhs);
    if (!$cast(rhs_model, rhs))
      `uvm_fatal("RDMA_COPY_TYPE", "CEQ doorbell copy type mismatch")
    ceqn = rhs_model.ceqn;
    ci = rhs_model.ci;
    wrap = rhs_model.wrap;
  endfunction

  virtual function rdma_status validate();
    rdma_status status;
    status = target_status(RDMA_RESOURCE_CEQ, "CEQ doorbell");
    if (!status.ok()) return status;
    status = width_status(ceqn, XTR_V1_NOTIFY_CEQ_CEQN_WIDTH,
                          "CEQ doorbell CEQN");
    if (!status.ok()) return status;
    status = width_status(ci, XTR_V1_NOTIFY_CEQ_CI_WIDTH,
                          "CEQ doorbell CI");
    if (!status.ok()) return status;
    return target_id_status(ceqn, "CEQ doorbell");
  endfunction

  virtual function rdma_doorbell_kind_e doorbell_kind();
    return RDMA_DOORBELL_CEQ;
  endfunction

  virtual function string codec_variant();
    return "ceq";
  endfunction

  virtual function string describe();
    return $sformatf("xtr_v1 CEQ doorbell(ceqn=%0d ci=%0d wrap=%0b)",
                     ceqn, ci, wrap);
  endfunction
endclass

class rdma_xtr_v1_aeq_doorbell_model
    extends rdma_xtr_v1_doorbell_model_base;
  `uvm_object_utils(rdma_xtr_v1_aeq_doorbell_model)

  int unsigned aeqn;
  int unsigned ci;
  bit wrap;

  function new(string name = "rdma_xtr_v1_aeq_doorbell_model");
    super.new(name);
    aeqn = 0;
    ci = 0;
    wrap = 1'b0;
  endfunction

  virtual function void do_copy(uvm_object rhs);
    rdma_xtr_v1_aeq_doorbell_model rhs_model;
    super.do_copy(rhs);
    if (!$cast(rhs_model, rhs))
      `uvm_fatal("RDMA_COPY_TYPE", "AEQ doorbell copy type mismatch")
    aeqn = rhs_model.aeqn;
    ci = rhs_model.ci;
    wrap = rhs_model.wrap;
  endfunction

  virtual function rdma_status validate();
    rdma_status status;
    status = target_status(RDMA_RESOURCE_AEQ, "AEQ doorbell");
    if (!status.ok()) return status;
    status = width_status(aeqn, XTR_V1_NOTIFY_AEQ_AEQN_WIDTH,
                          "AEQ doorbell AEQN");
    if (!status.ok()) return status;
    status = width_status(ci, XTR_V1_NOTIFY_AEQ_CI_WIDTH,
                          "AEQ doorbell CI");
    if (!status.ok()) return status;
    return target_id_status(aeqn, "AEQ doorbell");
  endfunction

  virtual function rdma_doorbell_kind_e doorbell_kind();
    return RDMA_DOORBELL_AEQ;
  endfunction

  virtual function string codec_variant();
    return "aeq";
  endfunction

  virtual function string describe();
    return $sformatf("xtr_v1 AEQ doorbell(aeqn=%0d ci=%0d wrap=%0b)",
                     aeqn, ci, wrap);
  endfunction
endclass

class rdma_xtr_v1_qp_control_doorbell_model
    extends rdma_xtr_v1_doorbell_model_base;
  `uvm_object_utils(rdma_xtr_v1_qp_control_doorbell_model)

  rdma_doorbell_kind_e kind;
  int unsigned qpn;
  int unsigned dst_port;
  int unsigned qp_sn;
  int unsigned icos;

  function new(string name = "rdma_xtr_v1_qp_control_doorbell_model");
    super.new(name);
    kind = RDMA_DOORBELL_QP_FLUSH;
    qpn = 0;
    dst_port = 0;
    qp_sn = 0;
    icos = 0;
  endfunction

  virtual function void do_copy(uvm_object rhs);
    rdma_xtr_v1_qp_control_doorbell_model rhs_model;
    super.do_copy(rhs);
    if (!$cast(rhs_model, rhs))
      `uvm_fatal("RDMA_COPY_TYPE", "QP-control doorbell copy type mismatch")
    kind = rhs_model.kind;
    qpn = rhs_model.qpn;
    dst_port = rhs_model.dst_port;
    qp_sn = rhs_model.qp_sn;
    icos = rhs_model.icos;
  endfunction

  virtual function rdma_status validate();
    rdma_status status;
    status = target_status(RDMA_RESOURCE_QP, "QP-control doorbell");
    if (!status.ok()) return status;
    if (!(kind inside {RDMA_DOORBELL_RTS2SQD, RDMA_DOORBELL_SQD2RTS,
                       RDMA_DOORBELL_QP_FLUSH,
                       RDMA_DOORBELL_TX_FLUSH}))
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "QP-control doorbell kind is invalid");
    status = width_status(qpn, XTR_V1_NOTIFY_QP_QPN_WIDTH,
                          "QP-control doorbell QPN");
    if (!status.ok()) return status;
    status = width_status(dst_port, XTR_V1_NOTIFY_QP_DST_PORT_WIDTH,
                          "QP-control doorbell destination port");
    if (!status.ok()) return status;
    status = width_status(qp_sn, XTR_V1_NOTIFY_QP_SN_WIDTH,
                          "QP-control doorbell QP sequence");
    if (!status.ok()) return status;
    status = width_status(icos, XTR_V1_NOTIFY_QP_ICOS_WIDTH,
                          "QP-control doorbell ICOS");
    if (!status.ok()) return status;
    status = target_id_status(qpn, "QP-control doorbell");
    if (!status.ok()) return status;
    if (kind == RDMA_DOORBELL_TX_FLUSH &&
        (dst_port != XTR_V1_TX_FLUSH_DST_PORT || qp_sn != 0 || icos != 0))
      return rdma_status::make(
        RDMA_SC_INVALID_ARGUMENT,
        "TX-flush doorbell requires fixed destination, sequence, and ICOS"
      );
    return rdma_status::success();
  endfunction

  virtual function rdma_doorbell_kind_e doorbell_kind();
    return kind;
  endfunction

  virtual function string codec_variant();
    case (kind)
      RDMA_DOORBELL_RTS2SQD:  return "rts2sqd";
      RDMA_DOORBELL_SQD2RTS:  return "sqd2rts";
      RDMA_DOORBELL_QP_FLUSH: return "qp_flush";
      RDMA_DOORBELL_TX_FLUSH: return "tx_flush";
      default:                return "invalid";
    endcase
  endfunction

  virtual function string describe();
    return $sformatf("xtr_v1 QP-control doorbell(kind=%s qpn=%0d)",
                     kind.name(), qpn);
  endfunction
endclass

class rdma_xtr_v1_doorbell_codec extends rdma_codec_base;
  `uvm_object_utils(rdma_xtr_v1_doorbell_codec)

  protected string variant_name;

  function new(string name = "rdma_xtr_v1_doorbell_codec",
               string variant_name = "rq");
    super.new(name);
    this.variant_name = variant_name;
  endfunction

  protected function rdma_status invalid_argument(string message);
    return rdma_status::make(RDMA_SC_INVALID_ARGUMENT, message);
  endfunction

  protected function rdma_status codec_error(string message);
    return rdma_status::make(RDMA_SC_CODEC_ERROR, message);
  endfunction

  protected function bit supported_variant();
    return variant_name inside {
      "cmq_sq", "sq", "rq", "srq_pi", "srq_limit", "cq_rc_ud",
      "cq_urc", "ceq", "aeq", "rts2sqd", "sqd2rts", "qp_flush",
      "tx_flush"
    };
  endfunction

  protected function bit [63:0] expected_relative_offset();
    case (variant_name)
      "cmq_sq":   return XTR_V1_DB_CMQ_OFFSET;
      "sq":       return XTR_V1_DB_SQ_OFFSET;
      "rq":       return XTR_V1_DB_RQ_OFFSET;
      "srq_pi",
      "srq_limit":return XTR_V1_DB_SRFQ_OFFSET;
      "cq_rc_ud",
      "cq_urc":   return XTR_V1_DB_CQ_OFFSET;
      "ceq":      return XTR_V1_DB_CEQ_OFFSET;
      "aeq":      return XTR_V1_DB_AEQ_OFFSET;
      "rts2sqd":  return XTR_V1_DB_RTS2SQD_OFFSET;
      "sqd2rts":  return XTR_V1_DB_SQD2RTS_OFFSET;
      "qp_flush": return XTR_V1_DB_QP_FLUSH_OFFSET;
      "tx_flush": return XTR_V1_DB_TX_FLUSH_OFFSET;
      default:     return '1;
    endcase
  endfunction

  protected function bit [63:0] selected_mask();
    case (variant_name)
      "cmq_sq":   return 64'h0000_003f_0000_0000;
      "sq":       return 64'hffff_ffff_ffff_ffff;
      "rq":       return 64'h0000_ffff_00ff_ffff;
      "srq_pi":   return 64'h4000_ffff_0000_ffff;
      "srq_limit":return 64'h8000_0000_ffff_ffff;
      "cq_rc_ud": return 64'h3f00_ffff_ffff_ffff;
      "cq_urc":   return 64'h3fff_ffff_ffff_ffff;
      "ceq":      return 64'h0007_ffff_003f_ffff;
      "aeq":      return 64'h0007_ffff_0000_0fff;
      "rts2sqd",
      "sqd2rts",
      "qp_flush",
      "tx_flush": return 64'h000f_fff0_00ff_ffff;
      default:     return '0;
    endcase
  endfunction

  protected function rdma_resource_kind_e expected_target_kind();
    case (variant_name)
      "cmq_sq": return RDMA_RESOURCE_CMQ;
      "srq_pi", "srq_limit": return RDMA_RESOURCE_SRQ;
      "cq_rc_ud", "cq_urc": return RDMA_RESOURCE_CQ;
      "ceq": return RDMA_RESOURCE_CEQ;
      "aeq": return RDMA_RESOURCE_AEQ;
      default: return RDMA_RESOURCE_QP;
    endcase
  endfunction

  protected function rdma_doorbell_kind_e expected_doorbell_kind();
    case (variant_name)
      "cmq_sq": return RDMA_DOORBELL_CMQ_SQ;
      "sq": return RDMA_DOORBELL_SQ;
      "rq": return RDMA_DOORBELL_RQ;
      "srq_pi", "srq_limit": return RDMA_DOORBELL_SRQ;
      "cq_rc_ud", "cq_urc": return RDMA_DOORBELL_CQ;
      "ceq": return RDMA_DOORBELL_CEQ;
      "aeq": return RDMA_DOORBELL_AEQ;
      "rts2sqd": return RDMA_DOORBELL_RTS2SQD;
      "sqd2rts": return RDMA_DOORBELL_SQD2RTS;
      "qp_flush": return RDMA_DOORBELL_QP_FLUSH;
      default: return RDMA_DOORBELL_TX_FLUSH;
    endcase
  endfunction

  protected function int unsigned expected_db_type();
    case (variant_name)
      "rts2sqd":  return XTR_V1_DB_TYPE_RTS2SQD;
      "sqd2rts":  return XTR_V1_DB_TYPE_SQD2RTS;
      "qp_flush": return XTR_V1_DB_TYPE_QP_FLUSH;
      "tx_flush": return XTR_V1_DB_TYPE_TX_FLUSH;
      default:     return 0;
    endcase
  endfunction

  protected function rdma_status put(
    rdma_xtr_v1_qword_builder builder,
    int unsigned word_byte_offset,
    int unsigned lsb,
    int unsigned width,
    bit [63:0] value
  );
    rdma_status status;
    status = builder.put_field(word_byte_offset, lsb, width, value);
    if (!status.ok())
      return codec_error({"doorbell field authorship failed: ",
                          status.message});
    return status;
  endfunction

  protected function rdma_status get(
    rdma_xtr_v1_qword_builder builder,
    int unsigned word_byte_offset,
    int unsigned lsb,
    int unsigned width,
    output bit [63:0] value
  );
    rdma_status status;
    bit [63:0] extracted;
    extracted = '0;
    status = builder.get_field(word_byte_offset, lsb, width, extracted);
    if (!status.ok())
      return codec_error({"doorbell field extraction failed: ",
                          status.message});
    value = extracted;
    return status;
  endfunction

  protected function rdma_handle decoded_target(
    rdma_resource_kind_e kind,
    int unsigned object_id,
    int unsigned generation
  );
    rdma_handle handle;
    handle = rdma_handle::type_id::create("decoded_doorbell_target");
    handle.kind = kind;
    handle.function_uid = 0;
    handle.object_id = object_id;
    handle.generation = generation;
    return handle;
  endfunction

  virtual function rdma_status validate_model(rdma_hw_model model);
    rdma_xtr_v1_doorbell_model_base doorbell;
    rdma_xtr_v1_cmq_sq_doorbell_model cmq;
    rdma_xtr_v1_sq_doorbell_model sq;
    rdma_xtr_v1_rq_doorbell_model rq;
    rdma_xtr_v1_srq_doorbell_model srq;
    rdma_xtr_v1_cq_doorbell_model cq;
    rdma_xtr_v1_ceq_doorbell_model ceq;
    rdma_xtr_v1_aeq_doorbell_model aeq;
    rdma_xtr_v1_qp_control_doorbell_model qp;
    rdma_status status;

    if (!supported_variant())
      return rdma_status::make(RDMA_SC_UNSUPPORTED_OPCODE,
                               "xtr_v1 doorbell codec variant is unsupported");
    if (!$cast(doorbell, model))
      return invalid_argument("xtr_v1 doorbell codec requires typed model");
    case (variant_name)
      "cmq_sq": if (!$cast(cmq, model))
        return invalid_argument("cmq_sq codec requires CMQ doorbell model");
      "sq": if (!$cast(sq, model))
        return invalid_argument("sq codec requires SQ doorbell model");
      "rq": if (!$cast(rq, model))
        return invalid_argument("rq codec requires RQ doorbell model");
      "srq_pi", "srq_limit": if (!$cast(srq, model))
        return invalid_argument("SRQ codec requires SRQ doorbell model");
      "cq_rc_ud", "cq_urc": if (!$cast(cq, model))
        return invalid_argument("CQ codec requires CQ doorbell model");
      "ceq": if (!$cast(ceq, model))
        return invalid_argument("ceq codec requires CEQ doorbell model");
      "aeq": if (!$cast(aeq, model))
        return invalid_argument("aeq codec requires AEQ doorbell model");
      default: if (!$cast(qp, model))
        return invalid_argument("QP-control codec requires QP-control model");
    endcase
    if (doorbell.codec_variant() != variant_name ||
        doorbell.doorbell_kind() != expected_doorbell_kind())
      return invalid_argument("doorbell model variant does not match codec");
    status = doorbell.validate();
    if (!status.ok()) return status;
    return rdma_status::success();
  endfunction

  protected function rdma_status encode_fields(
    rdma_hw_model model,
    rdma_xtr_v1_qword_builder builder
  );
    rdma_xtr_v1_cmq_sq_doorbell_model cmq;
    rdma_xtr_v1_sq_doorbell_model sq;
    rdma_xtr_v1_rq_doorbell_model rq;
    rdma_xtr_v1_srq_doorbell_model srq;
    rdma_xtr_v1_cq_doorbell_model cq;
    rdma_xtr_v1_ceq_doorbell_model ceq;
    rdma_xtr_v1_aeq_doorbell_model aeq;
    rdma_xtr_v1_qp_control_doorbell_model qp;
    byte unsigned header[];
    rdma_status status;

`define DB_PUT(STEM, VALUE) \
    status = put(builder, STEM``_WORD_BYTE_OFFSET, STEM``_LSB, \
                 STEM``_WIDTH, VALUE); \
    if (!status.ok()) return status;
    case (variant_name)
      "cmq_sq": begin
        void'($cast(cmq, model));
        `DB_PUT(XTR_V1_CMQ_DB_PI, cmq.pi)
        `DB_PUT(XTR_V1_CMQ_DB_POLARITY, cmq.polarity)
      end
      "sq": begin
        void'($cast(sq, model));
        header = new[XTR_V1_DB_BYTES];
        foreach (header[i]) header[i] = sq.sqe_header[i];
        status = builder.put_memcpy(0, header);
        if (!status.ok())
          return codec_error({"SQ header authorship failed: ", status.message});
      end
      "rq": begin
        void'($cast(rq, model));
        `DB_PUT(XTR_V1_NOTIFY_RQ_PI_WRAP, rq.wrap)
        `DB_PUT(XTR_V1_NOTIFY_RQ_PI, rq.pi)
        `DB_PUT(XTR_V1_NOTIFY_RQ_ICOS, rq.icos)
        `DB_PUT(XTR_V1_NOTIFY_RQ_QPN, rq.qpn)
      end
      "srq_pi": begin
        void'($cast(srq, model));
        `DB_PUT(XTR_V1_NOTIFY_SRQ_LIMIT_INVALID,
                XTR_V1_NOTIFY_SRQ_LIMIT_INVALID_VALUE)
        `DB_PUT(XTR_V1_NOTIFY_SRFQ_WRAP, srq.wrap)
        `DB_PUT(XTR_V1_NOTIFY_SRFQ_PI, srq.pi)
        `DB_PUT(XTR_V1_NOTIFY_SRFQN, srq.srqn)
      end
      "srq_limit": begin
        void'($cast(srq, model));
        `DB_PUT(XTR_V1_NOTIFY_SRQ_PI_INVALID,
                XTR_V1_NOTIFY_SRQ_PI_INVALID_VALUE)
        `DB_PUT(XTR_V1_NOTIFY_SRQ_LIMIT, srq.limit)
        `DB_PUT(XTR_V1_NOTIFY_SRQ_ARM_SN, srq.arm_sn)
        `DB_PUT(XTR_V1_NOTIFY_SRFQN, srq.srqn)
      end
      "cq_rc_ud", "cq_urc": begin
        void'($cast(cq, model));
        `DB_PUT(XTR_V1_NOTIFY_CQ_ARM, cq.arm)
        `DB_PUT(XTR_V1_NOTIFY_CQ_URC,
                (variant_name == "cq_urc"))
        `DB_PUT(XTR_V1_NOTIFY_CQ_ARM_ST, cq.arm_state)
        `DB_PUT(XTR_V1_NOTIFY_CQ_ARM_SN, cq.arm_sn)
        if (variant_name == "cq_rc_ud") begin
          `DB_PUT(XTR_V1_NOTIFY_CQ_CI_WRAP, cq.wrap)
          `DB_PUT(XTR_V1_NOTIFY_CQ_CI, cq.ci)
        end
        else begin
          `DB_PUT(XTR_V1_NOTIFY_CQ_URC_SQ_WRAP, cq.sq_wrap)
          `DB_PUT(XTR_V1_NOTIFY_CQ_URC_SQ_CI, cq.sq_ci)
          `DB_PUT(XTR_V1_NOTIFY_CQ_URC_RQ_WRAP, cq.rq_wrap)
          `DB_PUT(XTR_V1_NOTIFY_CQ_URC_RQ_CI, cq.rq_ci)
        end
        `DB_PUT(XTR_V1_NOTIFY_CQ_HOST_ID, cq.host_id)
        `DB_PUT(XTR_V1_NOTIFY_CQ_CQN, cq.cqn)
      end
      "ceq": begin
        void'($cast(ceq, model));
        `DB_PUT(XTR_V1_NOTIFY_CEQ_CI_WRAP, ceq.wrap)
        `DB_PUT(XTR_V1_NOTIFY_CEQ_CI, ceq.ci)
        `DB_PUT(XTR_V1_NOTIFY_CEQ_CEQN, ceq.ceqn)
      end
      "aeq": begin
        void'($cast(aeq, model));
        `DB_PUT(XTR_V1_NOTIFY_AEQ_CI_WRAP, aeq.wrap)
        `DB_PUT(XTR_V1_NOTIFY_AEQ_CI, aeq.ci)
        `DB_PUT(XTR_V1_NOTIFY_AEQ_AEQN, aeq.aeqn)
      end
      default: begin
        void'($cast(qp, model));
        `DB_PUT(XTR_V1_NOTIFY_QP_DST_PORT, qp.dst_port)
        `DB_PUT(XTR_V1_NOTIFY_QP_SN, qp.qp_sn)
        `DB_PUT(XTR_V1_NOTIFY_QP_DB_TYPE, expected_db_type())
        `DB_PUT(XTR_V1_NOTIFY_QP_ICOS, qp.icos)
        `DB_PUT(XTR_V1_NOTIFY_QP_QPN, qp.qpn)
      end
    endcase
`undef DB_PUT
    return rdma_status::success();
  endfunction

  protected function rdma_status validate_encode_mask(
    rdma_xtr_v1_qword_builder builder
  );
    bit [63:0] occupancy[];
    builder.get_occupancy(occupancy);
    if (occupancy.size() != 1 || occupancy[0] != selected_mask())
      return codec_error("doorbell field authorship differs from selected mask");
    return rdma_status::success();
  endfunction

  virtual function rdma_status encode(
    rdma_hw_model model,
    output rdma_hw_image image
  );
    rdma_xtr_v1_doorbell_model_base doorbell;
    rdma_xtr_v1_qword_builder builder;
    rdma_hw_image candidate;
    byte unsigned payload[];
    rdma_status status;

    image = null;
    status = validate_model(model);
    if (!status.ok()) return status;
    if (!$cast(doorbell, model))
      return invalid_argument("typed doorbell model cast failed");
    builder = new("doorbell_encode_builder");
    status = builder.reset(XTR_V1_DB_BYTES);
    if (!status.ok()) return codec_error(status.message);
    status = encode_fields(model, builder);
    if (!status.ok()) return status;
    status = validate_encode_mask(builder);
    if (!status.ok()) return status;
    payload = new[0];
    status = builder.serialize(payload);
    if (!status.ok()) return codec_error(status.message);

    candidate = rdma_hw_image::type_id::create("xtr_v1_doorbell_image");
    foreach (payload[i]) candidate.bytes.push_back(payload[i]);
    candidate.length = XTR_V1_DB_BYTES;
    candidate.alignment = XTR_V1_DB_BYTES;
    candidate.endian = RDMA_ENDIAN_BIG;
    candidate.image_kind = RDMA_IMAGE_DOORBELL;
    candidate.hardware_version = XTR_V1_HW_VERSION;
    candidate.function_generation = doorbell.target_h.generation;
    candidate.write_target_kind = RDMA_HW_TARGET_BAR;
    candidate.backing_target = '0;
    candidate.hmc_target = '0;
    candidate.bar_target.value = expected_relative_offset();
    image = candidate;
    return rdma_status::success();
  endfunction

  virtual function rdma_status validate_image(rdma_hw_image image);
    rdma_xtr_v1_qword_builder builder;
    byte unsigned payload[];
    bit [63:0] words[];
    rdma_status status;

    if (!supported_variant())
      return rdma_status::make(RDMA_SC_UNSUPPORTED_OPCODE,
                               "xtr_v1 doorbell codec variant is unsupported");
    if (image == null)
      return codec_error("doorbell image is null");
    if (image.length != XTR_V1_DB_BYTES ||
        image.bytes.size() != XTR_V1_DB_BYTES)
      return codec_error("doorbell image length is not eight bytes");
    if (image.function_generation == 0)
      return rdma_status::make(RDMA_SC_STALE_GENERATION,
                               "doorbell image generation is stale");
    if (image.alignment != XTR_V1_DB_BYTES ||
        image.endian != RDMA_ENDIAN_BIG ||
        image.image_kind != RDMA_IMAGE_DOORBELL ||
        image.hardware_version != XTR_V1_HW_VERSION ||
        image.write_target_kind != RDMA_HW_TARGET_BAR ||
        image.backing_target.value != 0 || image.hmc_target.value != 0 ||
        image.bar_target.value != expected_relative_offset())
      return codec_error("doorbell image metadata is invalid");
    payload = new[XTR_V1_DB_BYTES];
    foreach (payload[i]) payload[i] = image.bytes[i];
    builder = new("doorbell_validate_builder");
    status = builder.deserialize(payload);
    if (!status.ok()) return codec_error(status.message);
    builder.get_words(words);
    if (words.size() != 1 || (words[0] & ~selected_mask()) != 0)
      return codec_error("doorbell image contains a selected-variant reserved bit");
    return rdma_status::success();
  endfunction

  virtual function rdma_status decode(
    rdma_hw_image image,
    output rdma_hw_model model
  );
    rdma_xtr_v1_qword_builder builder;
    rdma_xtr_v1_doorbell_model_base candidate;
    rdma_xtr_v1_cmq_sq_doorbell_model cmq;
    rdma_xtr_v1_sq_doorbell_model sq;
    rdma_xtr_v1_rq_doorbell_model rq;
    rdma_xtr_v1_srq_doorbell_model srq;
    rdma_xtr_v1_cq_doorbell_model cq;
    rdma_xtr_v1_ceq_doorbell_model ceq;
    rdma_xtr_v1_aeq_doorbell_model aeq;
    rdma_xtr_v1_qp_control_doorbell_model qp;
    byte unsigned payload[];
    bit [63:0] value;
    rdma_status status;

    model = null;
    status = validate_image(image);
    if (!status.ok()) return status;
    payload = new[XTR_V1_DB_BYTES];
    foreach (payload[i]) payload[i] = image.bytes[i];
    builder = new("doorbell_decode_builder");
    status = builder.deserialize(payload);
    if (!status.ok()) return codec_error(status.message);

`define DB_GET(STEM, DEST) \
    status = get(builder, STEM``_WORD_BYTE_OFFSET, STEM``_LSB, \
                 STEM``_WIDTH, value); \
    if (!status.ok()) return status; \
    DEST = value;
    case (variant_name)
      "cmq_sq": begin
        cmq = rdma_xtr_v1_cmq_sq_doorbell_model::type_id::create(
            "decoded_cmq_doorbell");
        `DB_GET(XTR_V1_CMQ_DB_PI, cmq.pi)
        `DB_GET(XTR_V1_CMQ_DB_POLARITY, cmq.polarity)
        cmq.target_h = decoded_target(RDMA_RESOURCE_CMQ, 0,
                                      image.function_generation);
        candidate = cmq;
      end
      "sq": begin
        sq = rdma_xtr_v1_sq_doorbell_model::type_id::create(
            "decoded_sq_doorbell");
        foreach (image.bytes[i]) sq.sqe_header.push_back(image.bytes[i]);
        sq.target_h = decoded_target(RDMA_RESOURCE_QP, 0,
                                     image.function_generation);
        candidate = sq;
      end
      "rq": begin
        rq = rdma_xtr_v1_rq_doorbell_model::type_id::create(
            "decoded_rq_doorbell");
        `DB_GET(XTR_V1_NOTIFY_RQ_PI_WRAP, rq.wrap)
        `DB_GET(XTR_V1_NOTIFY_RQ_PI, rq.pi)
        `DB_GET(XTR_V1_NOTIFY_RQ_ICOS, rq.icos)
        `DB_GET(XTR_V1_NOTIFY_RQ_QPN, rq.qpn)
        rq.target_h = decoded_target(RDMA_RESOURCE_QP, rq.qpn,
                                     image.function_generation);
        candidate = rq;
      end
      "srq_pi", "srq_limit": begin
        srq = rdma_xtr_v1_srq_doorbell_model::type_id::create(
            "decoded_srq_doorbell");
        if (variant_name == "srq_pi") begin
          srq.variant = XTR_V1_SRQ_DB_PI;
          `DB_GET(XTR_V1_NOTIFY_SRQ_LIMIT_INVALID, value)
          if (value != XTR_V1_NOTIFY_SRQ_LIMIT_INVALID_VALUE)
            return codec_error("SRQ PI doorbell limit-invalid bit is not set");
          `DB_GET(XTR_V1_NOTIFY_SRFQ_WRAP, srq.wrap)
          `DB_GET(XTR_V1_NOTIFY_SRFQ_PI, srq.pi)
        end
        else begin
          srq.variant = XTR_V1_SRQ_DB_LIMIT;
          `DB_GET(XTR_V1_NOTIFY_SRQ_PI_INVALID, value)
          if (value != XTR_V1_NOTIFY_SRQ_PI_INVALID_VALUE)
            return codec_error("SRQ limit doorbell PI-invalid bit is not set");
          `DB_GET(XTR_V1_NOTIFY_SRQ_LIMIT, srq.limit)
          `DB_GET(XTR_V1_NOTIFY_SRQ_ARM_SN, srq.arm_sn)
        end
        `DB_GET(XTR_V1_NOTIFY_SRFQN, srq.srqn)
        srq.target_h = decoded_target(RDMA_RESOURCE_SRQ, srq.srqn,
                                      image.function_generation);
        candidate = srq;
      end
      "cq_rc_ud", "cq_urc": begin
        cq = rdma_xtr_v1_cq_doorbell_model::type_id::create(
            "decoded_cq_doorbell");
        cq.variant = (variant_name == "cq_rc_ud") ?
                     XTR_V1_CQ_DB_RC_UD : XTR_V1_CQ_DB_URC;
        `DB_GET(XTR_V1_NOTIFY_CQ_ARM, cq.arm)
        `DB_GET(XTR_V1_NOTIFY_CQ_URC, value)
        if (value != (variant_name == "cq_urc"))
          return codec_error("CQ doorbell URC selector mismatches variant");
        `DB_GET(XTR_V1_NOTIFY_CQ_ARM_ST, cq.arm_state)
        `DB_GET(XTR_V1_NOTIFY_CQ_ARM_SN, cq.arm_sn)
        if (variant_name == "cq_rc_ud") begin
          `DB_GET(XTR_V1_NOTIFY_CQ_CI_WRAP, cq.wrap)
          `DB_GET(XTR_V1_NOTIFY_CQ_CI, cq.ci)
        end
        else begin
          `DB_GET(XTR_V1_NOTIFY_CQ_URC_SQ_WRAP, cq.sq_wrap)
          `DB_GET(XTR_V1_NOTIFY_CQ_URC_SQ_CI, cq.sq_ci)
          `DB_GET(XTR_V1_NOTIFY_CQ_URC_RQ_WRAP, cq.rq_wrap)
          `DB_GET(XTR_V1_NOTIFY_CQ_URC_RQ_CI, cq.rq_ci)
        end
        `DB_GET(XTR_V1_NOTIFY_CQ_HOST_ID, cq.host_id)
        `DB_GET(XTR_V1_NOTIFY_CQ_CQN, cq.cqn)
        cq.target_h = decoded_target(RDMA_RESOURCE_CQ, cq.cqn,
                                     image.function_generation);
        candidate = cq;
      end
      "ceq": begin
        ceq = rdma_xtr_v1_ceq_doorbell_model::type_id::create(
            "decoded_ceq_doorbell");
        `DB_GET(XTR_V1_NOTIFY_CEQ_CI_WRAP, ceq.wrap)
        `DB_GET(XTR_V1_NOTIFY_CEQ_CI, ceq.ci)
        `DB_GET(XTR_V1_NOTIFY_CEQ_CEQN, ceq.ceqn)
        ceq.target_h = decoded_target(RDMA_RESOURCE_CEQ, ceq.ceqn,
                                      image.function_generation);
        candidate = ceq;
      end
      "aeq": begin
        aeq = rdma_xtr_v1_aeq_doorbell_model::type_id::create(
            "decoded_aeq_doorbell");
        `DB_GET(XTR_V1_NOTIFY_AEQ_CI_WRAP, aeq.wrap)
        `DB_GET(XTR_V1_NOTIFY_AEQ_CI, aeq.ci)
        `DB_GET(XTR_V1_NOTIFY_AEQ_AEQN, aeq.aeqn)
        aeq.target_h = decoded_target(RDMA_RESOURCE_AEQ, aeq.aeqn,
                                      image.function_generation);
        candidate = aeq;
      end
      default: begin
        qp = rdma_xtr_v1_qp_control_doorbell_model::type_id::create(
            "decoded_qp_control_doorbell");
        qp.kind = expected_doorbell_kind();
        `DB_GET(XTR_V1_NOTIFY_QP_DST_PORT, qp.dst_port)
        `DB_GET(XTR_V1_NOTIFY_QP_SN, qp.qp_sn)
        `DB_GET(XTR_V1_NOTIFY_QP_DB_TYPE, value)
        if (value != expected_db_type())
          return codec_error("QP-control DB type mismatches selected variant");
        `DB_GET(XTR_V1_NOTIFY_QP_ICOS, qp.icos)
        `DB_GET(XTR_V1_NOTIFY_QP_QPN, qp.qpn)
        qp.target_h = decoded_target(RDMA_RESOURCE_QP, qp.qpn,
                                     image.function_generation);
        candidate = qp;
      end
    endcase
`undef DB_GET
    if (candidate == null)
      return codec_error("doorbell decoder produced a null model");
    status = validate_model(candidate);
    if (!status.ok())
      return codec_error({"decoded doorbell semantics are invalid: ",
                          status.message});
    model = candidate;
    return rdma_status::success();
  endfunction

  virtual function rdma_status serialized_equal(
    rdma_hw_model lhs,
    rdma_hw_model rhs,
    output bit equal,
    output string mismatch
  );
    rdma_hw_image lhs_image;
    rdma_hw_image rhs_image;
    rdma_status status;

    equal = 1'b0;
    mismatch = "";
    status = encode(lhs, lhs_image);
    if (!status.ok()) begin
      mismatch = {"left model: ", status.message};
      return status;
    end
    status = encode(rhs, rhs_image);
    if (!status.ok()) begin
      mismatch = {"right model: ", status.message};
      return status;
    end
    foreach (lhs_image.bytes[i]) begin
      if (lhs_image.bytes[i] != rhs_image.bytes[i]) begin
        mismatch = $sformatf("serialized byte %0d differs: %02x != %02x",
                             i, lhs_image.bytes[i], rhs_image.bytes[i]);
        return rdma_status::success();
      end
    end
    equal = 1'b1;
    return rdma_status::success();
  endfunction

  virtual function rdma_byte_endian_e hardware_endian();
    return RDMA_ENDIAN_BIG;
  endfunction

  virtual function string describe_fields();
    return {"xtr_v1 8-byte doorbell variant ", variant_name};
  endfunction
endclass

class rdma_xtr_v1_doorbell_codec_registry extends rdma_codec_registry;
  `uvm_object_utils(rdma_xtr_v1_doorbell_codec_registry)

  protected bit defaults_registered;

  function new(string name = "rdma_xtr_v1_doorbell_codec_registry");
    super.new(name);
    defaults_registered = 1'b0;
  endfunction

  protected function rdma_codec_key make_key(string variant);
    rdma_codec_key key;
    key.hw_version = "xtr_v1";
    key.image_kind = RDMA_IMAGE_DOORBELL;
    key.object_type = "doorbell";
    key.variant = variant;
    key.opcode = 8'h00;
    return key;
  endfunction

  function rdma_status register_defaults();
    string variants[13] = '{
      "cmq_sq", "sq", "rq", "srq_pi", "srq_limit", "cq_rc_ud",
      "cq_urc", "ceq", "aeq", "rts2sqd", "sqd2rts", "qp_flush",
      "tx_flush"
    };
    rdma_xtr_v1_doorbell_codec codec;
    rdma_status status;

    if (defaults_registered)
      return rdma_status::make(RDMA_SC_INVALID_STATE,
                               "xtr_v1 doorbell codecs are already registered");
    foreach (variants[i]) begin
      codec = new({"doorbell_codec_", variants[i]}, variants[i]);
      status = register_codec(make_key(variants[i]), codec);
      if (!status.ok()) return status;
    end
    defaults_registered = 1'b1;
    return rdma_status::success();
  endfunction

  protected function rdma_status find_codec(
    string variant,
    output rdma_codec_base codec
  );
    return lookup(make_key(variant), codec);
  endfunction

  function rdma_status encode(
    rdma_xtr_v1_doorbell_model_base model,
    output rdma_hw_image image
  );
    rdma_codec_base codec;
    rdma_status status;
    image = null;
    if (model == null)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "doorbell registry model is null");
    status = find_codec(model.codec_variant(), codec);
    if (!status.ok()) return status;
    return codec.encode(model, image);
  endfunction

  function rdma_status decode(
    string variant,
    rdma_hw_image image,
    output rdma_hw_model model
  );
    rdma_codec_base codec;
    rdma_status status;
    model = null;
    status = find_codec(variant, codec);
    if (!status.ok()) return status;
    return codec.decode(image, model);
  endfunction

  function rdma_status serialized_equal(
    string variant,
    rdma_hw_model lhs,
    rdma_hw_model rhs,
    output bit equal,
    output string mismatch
  );
    rdma_codec_base codec;
    rdma_status status;
    equal = 1'b0;
    mismatch = "";
    status = find_codec(variant, codec);
    if (!status.ok()) return status;
    return codec.serialized_equal(lhs, rhs, equal, mismatch);
  endfunction
endclass
