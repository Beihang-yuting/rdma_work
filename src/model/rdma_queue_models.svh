function automatic rdma_status rdma_clone_status_value(rdma_status source);
  rdma_status result;

  if (source == null)
    return null;
  result = rdma_status::type_id::create("status");
  result.category = source.category;
  result.code = source.code;
  result.hardware_code = source.hardware_code;
  result.hardware_code_valid = source.hardware_code_valid;
  result.source_engine = source.source_engine;
  result.function_uid = source.function_uid;
  result.generation = source.generation;
  result.resource_id = source.resource_id;
  result.command_id = source.command_id;
  result.wr_id = source.wr_id;
  result.severity = source.severity;
  result.retryable = source.retryable;
  result.message = source.message;
  return result;
endfunction

class rdma_cmq_sqe_model extends rdma_hw_model;
  `uvm_object_utils(rdma_cmq_sqe_model)

  rdma_cmq_opcode_e opcode;
  longint unsigned command_id;
  rdma_function_handle function_h;
  rdma_handle target_h;
  rdma_hw_model context_model;
  int unsigned flags;

  function new(string name = "rdma_cmq_sqe_model");
    super.new(name);
    opcode = RDMA_CMQ_QUERY;
    command_id = '0;
    function_h = null;
    target_h = null;
    context_model = null;
    flags = '0;
  endfunction

  virtual function void do_copy(uvm_object rhs);
    rdma_cmq_sqe_model rhs_sqe;
    uvm_object cloned_object;

    super.do_copy(rhs);
    if (!$cast(rhs_sqe, rhs))
      `uvm_fatal("RDMA_COPY_TYPE", "CMQ SQE model copy mismatch")
    opcode = rhs_sqe.opcode;
    command_id = rhs_sqe.command_id;
    function_h = rdma_clone_function_handle_value(rhs_sqe.function_h,
                                                  "CMQ SQE");
    target_h = rdma_clone_handle_value(rhs_sqe.target_h, "CMQ SQE target");
    flags = rhs_sqe.flags;
    if (rhs_sqe.context_model == null) begin
      context_model = null;
    end
    else begin
      cloned_object = rhs_sqe.context_model.clone();
      if (cloned_object == null || !$cast(context_model, cloned_object))
        `uvm_fatal("RDMA_COPY_TYPE", "CMQ context clone mismatch")
    end
  endfunction

  virtual function rdma_status validate();
    rdma_status context_status;
    rdma_qpc_model qpc_context;
    rdma_cqc_model cqc_context;
    rdma_mrt_model mrt_context;
    rdma_srqc_model srqc_context;
    rdma_ceqc_model ceqc_context;
    rdma_aeqc_model aeqc_context;

    if (!(opcode inside {RDMA_CMQ_CREATE_PD, RDMA_CMQ_REGISTER_MR,
                         RDMA_CMQ_CREATE_CQ, RDMA_CMQ_CREATE_QP,
                         RDMA_CMQ_CREATE_SRQ, RDMA_CMQ_CREATE_CEQ,
                         RDMA_CMQ_CREATE_AEQ, RDMA_CMQ_DESTROY,
                         RDMA_CMQ_MODIFY_QP, RDMA_CMQ_QUERY}))
      return rdma_status::make(RDMA_SC_UNSUPPORTED_OPCODE,
                               "CMQ opcode is unsupported");
    if (command_id == 0)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "CMQ command ID is zero");
    if (function_h == null || function_h.kind != RDMA_RESOURCE_FUNCTION)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "CMQ command lacks function identity");
    if (opcode inside {RDMA_CMQ_REGISTER_MR, RDMA_CMQ_CREATE_CQ,
                       RDMA_CMQ_CREATE_QP, RDMA_CMQ_CREATE_SRQ,
                       RDMA_CMQ_CREATE_CEQ, RDMA_CMQ_CREATE_AEQ,
                       RDMA_CMQ_MODIFY_QP} && context_model == null)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "CMQ command lacks required context");
    case (opcode)
      RDMA_CMQ_REGISTER_MR:
        if (!$cast(mrt_context, context_model))
          return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                                   "REGISTER_MR requires MRT context");
      RDMA_CMQ_CREATE_CQ:
        if (!$cast(cqc_context, context_model))
          return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                                   "CREATE_CQ requires CQC context");
      RDMA_CMQ_CREATE_QP:
        if (!$cast(qpc_context, context_model))
          return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                                   "CREATE_QP requires QPC context");
      RDMA_CMQ_CREATE_SRQ:
        if (!$cast(srqc_context, context_model))
          return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                                   "CREATE_SRQ requires SRQC context");
      RDMA_CMQ_CREATE_CEQ:
        if (!$cast(ceqc_context, context_model))
          return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                                   "CREATE_CEQ requires CEQC context");
      RDMA_CMQ_CREATE_AEQ:
        if (!$cast(aeqc_context, context_model))
          return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                                   "CREATE_AEQ requires AEQC context");
      RDMA_CMQ_MODIFY_QP: begin
        if (target_h == null || target_h.kind != RDMA_RESOURCE_QP)
          return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                                   "MODIFY_QP requires QP target");
        if (!$cast(qpc_context, context_model))
          return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                                   "MODIFY_QP requires QPC context");
      end
      RDMA_CMQ_DESTROY,
      RDMA_CMQ_QUERY:
        if (target_h == null)
          return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                                   "CMQ command requires target handle");
      default: begin
      end
    endcase
    if (context_model != null) begin
      context_status = context_model.validate();
      if (!context_status.ok())
        return context_status;
    end
    return rdma_status::success();
  endfunction

  virtual function string describe();
    return $sformatf("CMQ_SQE(opcode=%s command_id=%0d)",
                     opcode.name(), command_id);
  endfunction
endclass

class rdma_cmq_completion_model extends rdma_hw_model;
  `uvm_object_utils(rdma_cmq_completion_model)

  rdma_cmq_opcode_e opcode;
  longint unsigned command_id;
  rdma_status status;
  rdma_handle result_h;

  function new(string name = "rdma_cmq_completion_model");
    super.new(name);
    opcode = RDMA_CMQ_QUERY;
    command_id = '0;
    status = null;
    result_h = null;
  endfunction

  virtual function void do_copy(uvm_object rhs);
    rdma_cmq_completion_model rhs_completion;

    super.do_copy(rhs);
    if (!$cast(rhs_completion, rhs))
      `uvm_fatal("RDMA_COPY_TYPE", "CMQ completion copy mismatch")
    opcode = rhs_completion.opcode;
    command_id = rhs_completion.command_id;
    status = rdma_clone_status_value(rhs_completion.status);
    result_h = rdma_clone_handle_value(rhs_completion.result_h,
                                       "CMQ completion result");
  endfunction

  virtual function rdma_status validate();
    if (!(opcode inside {RDMA_CMQ_CREATE_PD, RDMA_CMQ_REGISTER_MR,
                         RDMA_CMQ_CREATE_CQ, RDMA_CMQ_CREATE_QP,
                         RDMA_CMQ_CREATE_SRQ, RDMA_CMQ_CREATE_CEQ,
                         RDMA_CMQ_CREATE_AEQ, RDMA_CMQ_DESTROY,
                         RDMA_CMQ_MODIFY_QP, RDMA_CMQ_QUERY}))
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "CMQ completion opcode is invalid");
    if (command_id == 0 || status == null)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "CMQ completion lacks command ID or status");
    return rdma_status::success();
  endfunction

  virtual function string describe();
    string status_text;

    status_text = (status == null) ? "null" : status.convert2string();
    return $sformatf("CMQ_CQE(opcode=%s command_id=%0d status=%s)",
                     opcode.name(), command_id, status_text);
  endfunction
endclass

virtual class rdma_sqe_transport_ext extends uvm_object;
  function new(string name = "rdma_sqe_transport_ext");
    super.new(name);
  endfunction

  pure virtual function rdma_transport_e transport_kind();
  pure virtual function rdma_status validate(rdma_work_opcode_e opcode);
  pure virtual function string describe();
endclass

class rdma_sqe_rc_ext extends rdma_sqe_transport_ext;
  `uvm_object_utils(rdma_sqe_rc_ext)

  rdma_iova_t remote_addr;
  bit [31:0] rkey;
  bit remote_access_valid;
  bit rkey_valid;
  longint unsigned compare_value;
  longint unsigned swap_add_value;

  function new(string name = "rdma_sqe_rc_ext");
    super.new(name);
    remote_addr = '0;
    rkey = '0;
    remote_access_valid = 1'b0;
    rkey_valid = 1'b0;
    compare_value = '0;
    swap_add_value = '0;
  endfunction

  virtual function void do_copy(uvm_object rhs);
    rdma_sqe_rc_ext rhs_ext;

    super.do_copy(rhs);
    if (!$cast(rhs_ext, rhs))
      `uvm_fatal("RDMA_COPY_TYPE", "RC SQE extension copy mismatch")
    remote_addr = rhs_ext.remote_addr;
    rkey = rhs_ext.rkey;
    remote_access_valid = rhs_ext.remote_access_valid;
    rkey_valid = rhs_ext.rkey_valid;
    compare_value = rhs_ext.compare_value;
    swap_add_value = rhs_ext.swap_add_value;
  endfunction

  virtual function rdma_transport_e transport_kind();
    return RDMA_TRANSPORT_RC;
  endfunction

  virtual function rdma_status validate(rdma_work_opcode_e opcode);
    if (opcode == RDMA_WR_LOCAL_INVALIDATE && !rkey_valid)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "RC local invalidate rkey is absent");
    if (opcode inside {RDMA_WR_RDMA_WRITE, RDMA_WR_WRITE_WITH_IMM,
                       RDMA_WR_RDMA_READ, RDMA_WR_ATOMIC_CMP_SWAP,
                       RDMA_WR_ATOMIC_FETCH_ADD}) begin
      if (!remote_access_valid || !rkey_valid)
        return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                                 "RC remote operation lacks address or rkey");
    end
    if (opcode inside {RDMA_WR_ATOMIC_CMP_SWAP,
                       RDMA_WR_ATOMIC_FETCH_ADD}) begin
      if ((remote_addr.value & 64'h7) != 0)
        return rdma_status::make(
          RDMA_SC_INVALID_ARGUMENT,
          "RC atomic remote address is not 8-byte aligned"
        );
    end
    return rdma_status::success();
  endfunction

  virtual function string describe();
    return $sformatf("RC_SQE(remote_addr=0x%016x rkey=0x%08x)",
                     remote_addr.value, rkey);
  endfunction
endclass

class rdma_sqe_ud_ext extends rdma_sqe_transport_ext;
  `uvm_object_utils(rdma_sqe_ud_ext)

  bit [23:0] destination_qpn;
  bit [31:0] qkey;
  int unsigned address_vector_id;
  bit address_vector_valid;

  function new(string name = "rdma_sqe_ud_ext");
    super.new(name);
    destination_qpn = '0;
    qkey = '0;
    address_vector_id = '0;
    address_vector_valid = 1'b0;
  endfunction

  virtual function void do_copy(uvm_object rhs);
    rdma_sqe_ud_ext rhs_ext;

    super.do_copy(rhs);
    if (!$cast(rhs_ext, rhs))
      `uvm_fatal("RDMA_COPY_TYPE", "UD SQE extension copy mismatch")
    destination_qpn = rhs_ext.destination_qpn;
    qkey = rhs_ext.qkey;
    address_vector_id = rhs_ext.address_vector_id;
    address_vector_valid = rhs_ext.address_vector_valid;
  endfunction

  virtual function rdma_transport_e transport_kind();
    return RDMA_TRANSPORT_UD;
  endfunction

  virtual function rdma_status validate(rdma_work_opcode_e opcode);
    if (!(opcode inside {RDMA_WR_SEND, RDMA_WR_SEND_WITH_IMM}))
      return rdma_status::make(RDMA_SC_UNSUPPORTED_OPCODE,
                               "UD SQE opcode is unsupported");
    if (destination_qpn == 0 || qkey == 0 || !address_vector_valid)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "UD SQE lacks destination QPN, qkey, or AV");
    return rdma_status::success();
  endfunction

  virtual function string describe();
    return $sformatf("UD_SQE(destination_qpn=%0d qkey=0x%08x)",
                     destination_qpn, qkey);
  endfunction
endclass

class rdma_sqe_urc_ext extends rdma_sqe_transport_ext;
  `uvm_object_utils(rdma_sqe_urc_ext)

  bit [23:0] destination_qpn;
  rdma_iova_t remote_addr;
  bit [31:0] rkey;
  bit remote_access_valid;
  bit rkey_valid;

  function new(string name = "rdma_sqe_urc_ext");
    super.new(name);
    destination_qpn = '0;
    remote_addr = '0;
    rkey = '0;
    remote_access_valid = 1'b0;
    rkey_valid = 1'b0;
  endfunction

  virtual function void do_copy(uvm_object rhs);
    rdma_sqe_urc_ext rhs_ext;

    super.do_copy(rhs);
    if (!$cast(rhs_ext, rhs))
      `uvm_fatal("RDMA_COPY_TYPE", "URC SQE extension copy mismatch")
    destination_qpn = rhs_ext.destination_qpn;
    remote_addr = rhs_ext.remote_addr;
    rkey = rhs_ext.rkey;
    remote_access_valid = rhs_ext.remote_access_valid;
    rkey_valid = rhs_ext.rkey_valid;
  endfunction

  virtual function rdma_transport_e transport_kind();
    return RDMA_TRANSPORT_URC;
  endfunction

  virtual function rdma_status validate(rdma_work_opcode_e opcode);
    if (opcode == RDMA_WR_LOCAL_INVALIDATE) begin
      if (!rkey_valid)
        return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                                 "URC local invalidate rkey is absent");
      return rdma_status::success();
    end
    if (destination_qpn == 0)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "URC SQE destination QPN is zero");
    if (opcode inside {RDMA_WR_RDMA_WRITE, RDMA_WR_WRITE_WITH_IMM,
                       RDMA_WR_RDMA_READ}) begin
      if (!remote_access_valid || !rkey_valid)
        return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                                 "URC remote operation lacks address or rkey");
    end
    return rdma_status::success();
  endfunction

  virtual function string describe();
    return $sformatf("URC_SQE(destination_qpn=%0d remote_addr=0x%016x)",
                     destination_qpn, remote_addr.value);
  endfunction
endclass

class rdma_sqe_model extends rdma_hw_model;
  `uvm_object_utils(rdma_sqe_model)

  rdma_transport_e transport;
  rdma_work_opcode_e opcode;
  rdma_handle qp_h;
  longint unsigned wr_id;
  rdma_sge sges[$];
  bit inline_data;
  byte unsigned payload[$];
  bit signaled;
  bit solicited;
  bit fence;
  bit [31:0] immediate_data;
  rdma_sqe_transport_ext transport_ext;

  function new(string name = "rdma_sqe_model");
    super.new(name);
    transport = RDMA_TRANSPORT_RC;
    opcode = RDMA_WR_SEND;
    qp_h = null;
    wr_id = '0;
    inline_data = 1'b0;
    signaled = 1'b0;
    solicited = 1'b0;
    fence = 1'b0;
    immediate_data = '0;
    transport_ext = null;
  endfunction

  virtual function void do_copy(uvm_object rhs);
    rdma_sqe_model rhs_sqe;
    uvm_object cloned_object;
    rdma_sge cloned_sge;

    super.do_copy(rhs);
    if (!$cast(rhs_sqe, rhs))
      `uvm_fatal("RDMA_COPY_TYPE", "data SQE model copy mismatch")
    transport = rhs_sqe.transport;
    opcode = rhs_sqe.opcode;
    qp_h = rdma_clone_handle_value(rhs_sqe.qp_h, "data SQE QP");
    wr_id = rhs_sqe.wr_id;
    inline_data = rhs_sqe.inline_data;
    payload = rhs_sqe.payload;
    signaled = rhs_sqe.signaled;
    solicited = rhs_sqe.solicited;
    fence = rhs_sqe.fence;
    immediate_data = rhs_sqe.immediate_data;
    sges.delete();
    foreach (rhs_sqe.sges[i]) begin
      if (rhs_sqe.sges[i] == null) begin
        sges.push_back(null);
      end
      else begin
        cloned_object = rhs_sqe.sges[i].clone();
        if (cloned_object == null || !$cast(cloned_sge, cloned_object))
          `uvm_fatal("RDMA_COPY_TYPE", "SQE SGE clone mismatch")
        sges.push_back(cloned_sge);
      end
    end
    if (rhs_sqe.transport_ext == null) begin
      transport_ext = null;
    end
    else begin
      cloned_object = rhs_sqe.transport_ext.clone();
      if (cloned_object == null || !$cast(transport_ext, cloned_object))
        `uvm_fatal("RDMA_COPY_TYPE", "SQE transport extension clone mismatch")
    end
  endfunction

  virtual function rdma_status validate();
    rdma_sqe_rc_ext rc_ext;
    rdma_sqe_ud_ext ud_ext;
    rdma_sqe_urc_ext urc_ext;

    if (qp_h == null || qp_h.kind != RDMA_RESOURCE_QP)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "SQE requires a QP handle");
    if (!rdma_send_opcode_valid_for_transport(transport, opcode))
      return rdma_status::make(RDMA_SC_UNSUPPORTED_OPCODE,
                               "SQE opcode is unsupported for transport");
    if (opcode == RDMA_WR_LOCAL_INVALIDATE) begin
      if (inline_data || sges.size() != 0 || payload.size() != 0)
        return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                                 "local invalidate SQE carries data");
    end
    else if (opcode inside {RDMA_WR_ATOMIC_CMP_SWAP,
                            RDMA_WR_ATOMIC_FETCH_ADD}) begin
      if (inline_data || payload.size() != 0 || sges.size() != 1)
        return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                                 "atomic SQE shape is invalid");
      if (sges[0] == null || sges[0].length != 8)
        return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                                 "atomic SQE requires one 8-byte SGE");
      if ((sges[0].iova.value & 64'h7) != 0)
        return rdma_status::make(
          RDMA_SC_INVALID_ARGUMENT,
          "atomic SQE local address is not 8-byte aligned"
        );
    end
    else if (opcode == RDMA_WR_RDMA_READ) begin
      if (inline_data || payload.size() != 0 || sges.size() == 0)
        return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                                 "RDMA read SQE shape is invalid");
      foreach (sges[i]) begin
        if (sges[i] == null || sges[i].length == 0)
          return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                                   "read SQE SGE is null or has zero length");
      end
    end
    else begin
      if (!inline_data && sges.size() == 0)
        return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                                 "non-inline SQE has no SGE");
      if (inline_data && payload.size() == 0)
        return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                                 "inline SQE has no payload");
      foreach (sges[i]) begin
        if (sges[i] == null || sges[i].length == 0)
          return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                                   "SQE SGE is null or has zero length");
      end
    end
    if (transport_ext == null || transport_ext.transport_kind() != transport)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "SQE transport extension does not match");
    case (transport)
      RDMA_TRANSPORT_RC:
        if (!$cast(rc_ext, transport_ext))
          return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                                   "RC SQE lacks RC extension");
      RDMA_TRANSPORT_UD:
        if (!$cast(ud_ext, transport_ext))
          return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                                   "UD SQE lacks UD extension");
      RDMA_TRANSPORT_URC:
        if (!$cast(urc_ext, transport_ext))
          return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                                   "URC SQE lacks URC extension");
      default:
        return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                                 "SQE transport is unsupported");
    endcase
    return transport_ext.validate(opcode);
  endfunction

  virtual function string describe();
    string extension_text;

    extension_text = (transport_ext == null) ? "null"
                                             : transport_ext.describe();
    return $sformatf("SQE(transport=%s opcode=%s wr_id=%0d %s)",
                     transport.name(), opcode.name(), wr_id, extension_text);
  endfunction
endclass

class rdma_rqe_model extends rdma_hw_model;
  `uvm_object_utils(rdma_rqe_model)

  rdma_handle target_h;
  longint unsigned wr_id;
  rdma_sge sges[$];

  function new(string name = "rdma_rqe_model");
    super.new(name);
    target_h = null;
    wr_id = '0;
  endfunction

  virtual function void do_copy(uvm_object rhs);
    rdma_rqe_model rhs_rqe;
    uvm_object cloned_object;
    rdma_sge cloned_sge;

    super.do_copy(rhs);
    if (!$cast(rhs_rqe, rhs))
      `uvm_fatal("RDMA_COPY_TYPE", "RQE model copy mismatch")
    target_h = rdma_clone_handle_value(rhs_rqe.target_h, "RQE target");
    wr_id = rhs_rqe.wr_id;
    sges.delete();
    foreach (rhs_rqe.sges[i]) begin
      if (rhs_rqe.sges[i] == null) begin
        sges.push_back(null);
      end
      else begin
        cloned_object = rhs_rqe.sges[i].clone();
        if (cloned_object == null || !$cast(cloned_sge, cloned_object))
          `uvm_fatal("RDMA_COPY_TYPE", "RQE SGE clone mismatch")
        sges.push_back(cloned_sge);
      end
    end
  endfunction

  virtual function rdma_status validate();
    if (target_h == null ||
        !(target_h.kind inside {RDMA_RESOURCE_QP, RDMA_RESOURCE_SRQ}))
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "RQE requires a QP or SRQ handle");
    if (sges.size() == 0)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "RQE has no SGE");
    foreach (sges[i]) begin
      if (sges[i] == null || sges[i].length == 0)
        return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                                 "RQE SGE is null or has zero length");
    end
    return rdma_status::success();
  endfunction

  virtual function string describe();
    return $sformatf("RQE(wr_id=%0d sge_count=%0d)", wr_id, sges.size());
  endfunction
endclass

class rdma_cqe_model extends rdma_hw_model;
  `uvm_object_utils(rdma_cqe_model)

  rdma_handle qp_h;
  longint unsigned wr_id;
  rdma_work_opcode_e opcode;
  rdma_status status;
  int unsigned byte_len;
  bit [31:0] immediate_data;

  function new(string name = "rdma_cqe_model");
    super.new(name);
    qp_h = null;
    wr_id = '0;
    opcode = RDMA_WR_SEND;
    status = null;
    byte_len = '0;
    immediate_data = '0;
  endfunction

  virtual function void do_copy(uvm_object rhs);
    rdma_cqe_model rhs_cqe;

    super.do_copy(rhs);
    if (!$cast(rhs_cqe, rhs))
      `uvm_fatal("RDMA_COPY_TYPE", "CQE model copy mismatch")
    qp_h = rdma_clone_handle_value(rhs_cqe.qp_h, "CQE QP");
    wr_id = rhs_cqe.wr_id;
    opcode = rhs_cqe.opcode;
    status = rdma_clone_status_value(rhs_cqe.status);
    byte_len = rhs_cqe.byte_len;
    immediate_data = rhs_cqe.immediate_data;
  endfunction

  virtual function rdma_status validate();
    if (qp_h == null || qp_h.kind != RDMA_RESOURCE_QP || status == null)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "CQE requires QP handle and status");
    if (!(opcode inside {RDMA_WR_SEND, RDMA_WR_SEND_WITH_IMM,
                         RDMA_WR_RDMA_WRITE, RDMA_WR_WRITE_WITH_IMM,
                         RDMA_WR_RDMA_READ, RDMA_WR_ATOMIC_CMP_SWAP,
                         RDMA_WR_ATOMIC_FETCH_ADD,
                         RDMA_WR_LOCAL_INVALIDATE, RDMA_WR_RECV}))
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "CQE work opcode is invalid");
    return rdma_status::success();
  endfunction

  virtual function string describe();
    return $sformatf("CQE(wr_id=%0d opcode=%s byte_len=%0d)",
                     wr_id, opcode.name(), byte_len);
  endfunction
endclass

class rdma_ceqe_model extends rdma_hw_model;
  `uvm_object_utils(rdma_ceqe_model)

  rdma_handle cq_h;
  int unsigned producer_index;
  bit wrap;
  bit solicited;

  function new(string name = "rdma_ceqe_model");
    super.new(name);
    cq_h = null;
    producer_index = '0;
    wrap = 1'b0;
    solicited = 1'b0;
  endfunction

  virtual function void do_copy(uvm_object rhs);
    rdma_ceqe_model rhs_ceqe;

    super.do_copy(rhs);
    if (!$cast(rhs_ceqe, rhs))
      `uvm_fatal("RDMA_COPY_TYPE", "CEQE model copy mismatch")
    cq_h = rdma_clone_handle_value(rhs_ceqe.cq_h, "CEQE CQ");
    producer_index = rhs_ceqe.producer_index;
    wrap = rhs_ceqe.wrap;
    solicited = rhs_ceqe.solicited;
  endfunction

  virtual function rdma_status validate();
    if (cq_h == null || cq_h.kind != RDMA_RESOURCE_CQ)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "CEQE requires a CQ handle");
    return rdma_status::success();
  endfunction

  virtual function string describe();
    return $sformatf("CEQE(producer_index=%0d wrap=%0b)",
                     producer_index, wrap);
  endfunction
endclass

class rdma_aeqe_model extends rdma_hw_model;
  `uvm_object_utils(rdma_aeqe_model)

  rdma_handle target_h;
  int unsigned event_code;
  int unsigned syndrome;
  rdma_severity_e severity;

  function new(string name = "rdma_aeqe_model");
    super.new(name);
    target_h = null;
    event_code = '0;
    syndrome = '0;
    severity = RDMA_SEVERITY_INFO;
  endfunction

  virtual function void do_copy(uvm_object rhs);
    rdma_aeqe_model rhs_aeqe;

    super.do_copy(rhs);
    if (!$cast(rhs_aeqe, rhs))
      `uvm_fatal("RDMA_COPY_TYPE", "AEQE model copy mismatch")
    target_h = rdma_clone_handle_value(rhs_aeqe.target_h, "AEQE target");
    event_code = rhs_aeqe.event_code;
    syndrome = rhs_aeqe.syndrome;
    severity = rhs_aeqe.severity;
  endfunction

  virtual function rdma_status validate();
    if (target_h == null)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "AEQE target handle is null");
    if (!(severity inside {RDMA_SEVERITY_INFO, RDMA_SEVERITY_WARNING,
                           RDMA_SEVERITY_ERROR, RDMA_SEVERITY_FATAL}))
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "AEQE severity is invalid");
    return rdma_status::success();
  endfunction

  virtual function string describe();
    return $sformatf("AEQE(event_code=%0d syndrome=%0d severity=%s)",
                     event_code, syndrome, severity.name());
  endfunction
endclass

class rdma_doorbell_model extends rdma_hw_model;
  `uvm_object_utils(rdma_doorbell_model)

  rdma_doorbell_kind_e kind;
  rdma_handle target_h;
  int unsigned queue_id;
  bit queue_id_valid;
  int unsigned producer_index;
  bit wrap;
  bit arm;
  bit solicited_only;

  function new(string name = "rdma_doorbell_model");
    super.new(name);
    kind = RDMA_DOORBELL_CMQ_SQ;
    target_h = null;
    queue_id = '0;
    queue_id_valid = 1'b0;
    producer_index = '0;
    wrap = 1'b0;
    arm = 1'b0;
    solicited_only = 1'b0;
  endfunction

  virtual function void do_copy(uvm_object rhs);
    rdma_doorbell_model rhs_doorbell;

    super.do_copy(rhs);
    if (!$cast(rhs_doorbell, rhs))
      `uvm_fatal("RDMA_COPY_TYPE", "doorbell model copy mismatch")
    kind = rhs_doorbell.kind;
    target_h = rdma_clone_handle_value(rhs_doorbell.target_h,
                                       "doorbell target");
    queue_id = rhs_doorbell.queue_id;
    queue_id_valid = rhs_doorbell.queue_id_valid;
    producer_index = rhs_doorbell.producer_index;
    wrap = rhs_doorbell.wrap;
    arm = rhs_doorbell.arm;
    solicited_only = rhs_doorbell.solicited_only;
  endfunction

  virtual function rdma_status validate();
    if (!(kind inside {RDMA_DOORBELL_CMQ_SQ, RDMA_DOORBELL_SQ,
                       RDMA_DOORBELL_RQ, RDMA_DOORBELL_SRQ,
                       RDMA_DOORBELL_CQ, RDMA_DOORBELL_CEQ,
                       RDMA_DOORBELL_AEQ, RDMA_DOORBELL_QP_FLUSH,
                       RDMA_DOORBELL_TQ_FLUSH}))
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "doorbell kind is invalid");
    if (target_h == null)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "doorbell target handle is null");
    case (kind)
      RDMA_DOORBELL_CMQ_SQ:
        if (target_h.kind != RDMA_RESOURCE_CMQ)
          return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                                   "CMQ doorbell requires a CMQ target");
      RDMA_DOORBELL_SQ,
      RDMA_DOORBELL_RQ,
      RDMA_DOORBELL_QP_FLUSH:
        if (target_h.kind != RDMA_RESOURCE_QP)
          return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                                   "QP doorbell requires a QP target");
      RDMA_DOORBELL_SRQ:
        if (target_h.kind != RDMA_RESOURCE_SRQ)
          return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                                   "SRQ doorbell requires an SRQ target");
      RDMA_DOORBELL_CQ:
        if (target_h.kind != RDMA_RESOURCE_CQ)
          return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                                   "CQ doorbell requires a CQ target");
      RDMA_DOORBELL_CEQ:
        if (target_h.kind != RDMA_RESOURCE_CEQ)
          return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                                   "CEQ doorbell requires a CEQ target");
      RDMA_DOORBELL_AEQ:
        if (target_h.kind != RDMA_RESOURCE_AEQ)
          return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                                   "AEQ doorbell requires an AEQ target");
      RDMA_DOORBELL_TQ_FLUSH:
        if (target_h.kind != RDMA_RESOURCE_FUNCTION || !queue_id_valid)
          return rdma_status::make(
            RDMA_SC_INVALID_ARGUMENT,
            "TQ doorbell requires a function target and queue ID"
          );
      default: begin
      end
    endcase
    return rdma_status::success();
  endfunction

  virtual function string describe();
    return $sformatf("DOORBELL(kind=%s queue_id=%0d producer=%0d wrap=%0b)",
                     kind.name(), queue_id, producer_index, wrap);
  endfunction
endclass
