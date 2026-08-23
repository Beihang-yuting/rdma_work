class rdma_xtr_v1_cmq_hw_profile extends rdma_cmq_hw_profile;
  `uvm_object_utils(rdma_xtr_v1_cmq_hw_profile)

  protected rdma_xtr_v1_cmq_request_composer request_composer;
  protected rdma_xtr_v1_cmq_completion_codec completion_codec;
  protected rdma_xtr_v1_error_codec error_codec;
  protected rdma_xtr_v1_doorbell_codec_registry doorbell_codecs;
  protected rdma_status doorbell_registration_status;

  function new(string name = "rdma_xtr_v1_cmq_hw_profile");
    rdma_status status;
    super.new(name);
    request_composer = rdma_xtr_v1_cmq_request_composer::type_id::create(
      "request_composer");
    completion_codec = rdma_xtr_v1_cmq_completion_codec::type_id::create(
      "completion_codec");
    error_codec = rdma_xtr_v1_error_codec::type_id::create("error_codec");
    doorbell_codecs =
      rdma_xtr_v1_doorbell_codec_registry::type_id::create(
        "doorbell_codecs");
    doorbell_registration_status = null;
    if (doorbell_codecs != null) begin
      status = doorbell_codecs.register_defaults();
      doorbell_registration_status = status;
    end
  endfunction

  virtual function string profile_name();
    return "xtr_v1";
  endfunction

  protected function rdma_status invalid_argument(string message);
    return rdma_status::make(RDMA_SC_INVALID_ARGUMENT, message);
  endfunction

  protected function rdma_status invalid_state(string message);
    return rdma_status::make(RDMA_SC_INVALID_STATE, message);
  endfunction

  protected function string command_handle_value_key(rdma_handle handle);
    if (handle == null)
      return "<null-handle>";
    return $sformatf("%0d:%016h:%08h:%08h", handle.kind,
                     handle.function_uid, handle.object_id,
                     handle.generation);
  endfunction

  protected function string command_body_value_key(rdma_hw_model body);
    rdma_xtr_v1_qpc_command_body qpc_body;
    rdma_xtr_v1_object_id_command_body object_body;
    rdma_xtr_v1_mr_deregister_body mr_body;
    rdma_xtr_v1_occ_flush_body occ_body;
    rdma_xtr_v1_cmq_empty_body empty_body;
    string result;

    if (body == null)
      return "<null-body>";
    if ($cast(qpc_body, body)) begin
      result = $sformatf(
        "qpc:%s:%s:%s:%016h:%0d:%0b:%0b:%0h",
        command_handle_value_key(qpc_body.qp_h),
        command_handle_value_key(qpc_body.send_cq_h),
        command_handle_value_key(qpc_body.recv_cq_h),
        qpc_body.qpc_buffer.value, qpc_body.next_state,
        qpc_body.full_modify, qpc_body.partial_modify,
        qpc_body.wbe_template_count
      );
      foreach (qpc_body.modify_start_qword[i])
        result = {result,
                  $sformatf(":%02h:%02h:%016h",
                            qpc_body.modify_start_qword[i],
                            qpc_body.modify_wbe[i],
                            qpc_body.modify_data[i])};
      return result;
    end
    if ($cast(object_body, body))
      return {"object:", command_handle_value_key(object_body.object_h)};
    if ($cast(mr_body, body))
      return $sformatf("mr:%s:%02h:%0d",
                       command_handle_value_key(mr_body.mr_h),
                       mr_body.stag_key, mr_body.next_state);
    if ($cast(occ_body, body))
      return $sformatf(
        "occ:%0b:%0b:%0b:%0b:%0b:%0b:%0b:%0b:%0b:%0b:%0b:%0b:%06h:%03h:%016h",
        occ_body.vf_flush, occ_body.mr_serial_flush, occ_body.qpc,
        occ_body.cqc, occ_body.mrt, occ_body.pble, occ_body.sqrqe,
        occ_body.sgb_irqe, occ_body.eirqe, occ_body.orqe, occ_body.uaqe,
        occ_body.pd, occ_body.qpn, occ_body.mr_serial,
        occ_body.pd_backing.value
      );
    if ($cast(empty_body, body))
      return "empty";
    return "";
  endfunction

  protected function void append_command_body_nodes(
    rdma_hw_model body,
    ref uvm_object nodes[$]
  );
    rdma_xtr_v1_qpc_command_body qpc_body;
    rdma_xtr_v1_object_id_command_body object_body;
    rdma_xtr_v1_mr_deregister_body mr_body;

    if (body == null)
      return;
    nodes.push_back(body);
    if ($cast(qpc_body, body)) begin
      if (qpc_body.qp_h != null) nodes.push_back(qpc_body.qp_h);
      if (qpc_body.send_cq_h != null) nodes.push_back(qpc_body.send_cq_h);
      if (qpc_body.recv_cq_h != null) nodes.push_back(qpc_body.recv_cq_h);
    end
    else if ($cast(object_body, body)) begin
      if (object_body.object_h != null) nodes.push_back(object_body.object_h);
    end
    else if ($cast(mr_body, body)) begin
      if (mr_body.mr_h != null) nodes.push_back(mr_body.mr_h);
    end
  endfunction

  virtual function bit same_command_body_value(
    rdma_hw_model lhs,
    rdma_hw_model rhs
  );
    string lhs_value;
    string rhs_value;

    if (lhs == null || rhs == null ||
        lhs.get_type_name() != rhs.get_type_name())
      return 1'b0;
    lhs_value = command_body_value_key(lhs);
    rhs_value = command_body_value_key(rhs);
    return lhs_value != "" && lhs_value == rhs_value;
  endfunction

  virtual function bit command_body_graph_detached(
    rdma_hw_model source,
    rdma_hw_model snapshot
  );
    uvm_object source_nodes[$];
    uvm_object snapshot_nodes[$];

    if (source == null || snapshot == null ||
        command_body_value_key(source) == "" ||
        command_body_value_key(snapshot) == "")
      return 1'b0;
    append_command_body_nodes(source, source_nodes);
    append_command_body_nodes(snapshot, snapshot_nodes);
    foreach (source_nodes[i])
      foreach (snapshot_nodes[j])
        if (source_nodes[i] == snapshot_nodes[j])
          return 1'b0;
    return 1'b1;
  endfunction

  protected function rdma_status checked_command_handle_snapshot(
    rdma_handle source,
    string label,
    output rdma_handle snapshot
  );
    uvm_object cloned_object;
    string source_type_name;
    rdma_resource_kind_e saved_kind;
    longint unsigned saved_function_uid;
    int unsigned saved_object_id;
    int unsigned saved_generation;

    snapshot = null;
    if (source == null)
      return invalid_argument({label, " handle is null"});
    source_type_name = source.get_type_name();
    saved_kind = source.kind;
    saved_function_uid = source.function_uid;
    saved_object_id = source.object_id;
    saved_generation = source.generation;
    cloned_object = source.clone();
    source.kind = saved_kind;
    source.function_uid = saved_function_uid;
    source.object_id = saved_object_id;
    source.generation = saved_generation;
    if (cloned_object == null || !$cast(snapshot, cloned_object) ||
        snapshot == source || snapshot.get_type_name() != source_type_name) begin
      snapshot = null;
      return invalid_argument({label, " handle clone contract failed"});
    end
    if (source.kind != saved_kind ||
        source.function_uid != saved_function_uid ||
        source.object_id != saved_object_id ||
        source.generation != saved_generation ||
        snapshot.kind != saved_kind ||
        snapshot.function_uid != saved_function_uid ||
        snapshot.object_id != saved_object_id ||
        snapshot.generation != saved_generation) begin
      snapshot = null;
      return invalid_argument({label, " handle clone changed its value"});
    end
    return rdma_status::success();
  endfunction

  protected function bit clear_command_body_references(
    rdma_hw_model body,
    ref uvm_object references[$]
  );
    rdma_xtr_v1_qpc_command_body qpc_body;
    rdma_xtr_v1_object_id_command_body object_body;
    rdma_xtr_v1_mr_deregister_body mr_body;
    rdma_xtr_v1_occ_flush_body occ_body;
    rdma_xtr_v1_cmq_empty_body empty_body;

    references.delete();
    if ($cast(qpc_body, body)) begin
      references.push_back(qpc_body.qp_h);
      references.push_back(qpc_body.send_cq_h);
      references.push_back(qpc_body.recv_cq_h);
      qpc_body.qp_h = null;
      qpc_body.send_cq_h = null;
      qpc_body.recv_cq_h = null;
      return 1'b1;
    end
    if ($cast(object_body, body)) begin
      references.push_back(object_body.object_h);
      object_body.object_h = null;
      return 1'b1;
    end
    if ($cast(mr_body, body)) begin
      references.push_back(mr_body.mr_h);
      mr_body.mr_h = null;
      return 1'b1;
    end
    return $cast(occ_body, body) || $cast(empty_body, body);
  endfunction

  protected function bit restore_command_body_references(
    rdma_hw_model body,
    ref uvm_object references[$]
  );
    rdma_xtr_v1_qpc_command_body qpc_body;
    rdma_xtr_v1_object_id_command_body object_body;
    rdma_xtr_v1_mr_deregister_body mr_body;
    rdma_xtr_v1_occ_flush_body occ_body;
    rdma_xtr_v1_cmq_empty_body empty_body;

    if ($cast(qpc_body, body) && references.size() == 3) begin
      if (!$cast(qpc_body.qp_h, references[0]) && references[0] != null)
        return 1'b0;
      if (!$cast(qpc_body.send_cq_h, references[1]) &&
          references[1] != null)
        return 1'b0;
      if (!$cast(qpc_body.recv_cq_h, references[2]) &&
          references[2] != null)
        return 1'b0;
      return 1'b1;
    end
    if ($cast(object_body, body) && references.size() == 1) begin
      if (!$cast(object_body.object_h, references[0]) &&
          references[0] != null)
        return 1'b0;
      return 1'b1;
    end
    if ($cast(mr_body, body) && references.size() == 1) begin
      if (!$cast(mr_body.mr_h, references[0]) && references[0] != null)
        return 1'b0;
      return 1'b1;
    end
    return references.size() == 0 &&
           ($cast(occ_body, body) || $cast(empty_body, body));
  endfunction

  protected function bit command_body_references_are_null(
    rdma_hw_model body
  );
    rdma_xtr_v1_qpc_command_body qpc_body;
    rdma_xtr_v1_object_id_command_body object_body;
    rdma_xtr_v1_mr_deregister_body mr_body;
    rdma_xtr_v1_occ_flush_body occ_body;
    rdma_xtr_v1_cmq_empty_body empty_body;

    if ($cast(qpc_body, body))
      return qpc_body.qp_h == null && qpc_body.send_cq_h == null &&
             qpc_body.recv_cq_h == null;
    if ($cast(object_body, body))
      return object_body.object_h == null;
    if ($cast(mr_body, body))
      return mr_body.mr_h == null;
    return $cast(occ_body, body) || $cast(empty_body, body);
  endfunction

  virtual function rdma_status snapshot_command_body(
    rdma_hw_model source,
    output rdma_hw_model snapshot
  );
    uvm_object cloned_object;
    rdma_status status;
    rdma_xtr_v1_qpc_command_body source_qpc;
    rdma_xtr_v1_qpc_command_body snapshot_qpc;
    rdma_xtr_v1_object_id_command_body source_object;
    rdma_xtr_v1_object_id_command_body snapshot_object;
    rdma_xtr_v1_mr_deregister_body source_mr;
    rdma_xtr_v1_mr_deregister_body snapshot_mr;
    rdma_xtr_v1_occ_flush_body source_occ;
    rdma_xtr_v1_cmq_empty_body source_empty;
    rdma_handle handle0_snapshot;
    rdma_handle handle1_snapshot;
    rdma_handle handle2_snapshot;
    string source_type_name;
    string saved_value;
    string saved_shell_value;
    uvm_object saved_object;
    uvm_object_wrapper source_wrapper;
    rdma_hw_model saved_body;
    uvm_object saved_references[$];

    snapshot = null;
    if (source == null)
      return invalid_argument("xtr_v1 CMQ command body is null");
    source_type_name = source.get_type_name();
    saved_value = command_body_value_key(source);
    if (saved_value == "" ||
        !($cast(source_qpc, source) || $cast(source_object, source) ||
          $cast(source_mr, source) || $cast(source_occ, source) ||
          $cast(source_empty, source)))
      return invalid_argument({"xtr_v1 CMQ command body type is unsupported: ",
                               source_type_name});
    status = source.validate();
    if (status == null)
      return invalid_argument("xtr_v1 CMQ body validation returned null");
    if (!status.ok())
      return status;
    handle0_snapshot = null;
    handle1_snapshot = null;
    handle2_snapshot = null;
    if (source_qpc != null) begin
      status = checked_command_handle_snapshot(
        source_qpc.qp_h, "xtr_v1 QPC command QP", handle0_snapshot
      );
      if (!status.ok()) return status;
      if (source_qpc.send_cq_h != null) begin
        status = checked_command_handle_snapshot(
          source_qpc.send_cq_h, "xtr_v1 QPC command send CQ",
          handle1_snapshot
        );
        if (!status.ok()) return status;
      end
      if (source_qpc.recv_cq_h != null) begin
        status = checked_command_handle_snapshot(
          source_qpc.recv_cq_h, "xtr_v1 QPC command receive CQ",
          handle2_snapshot
        );
        if (!status.ok()) return status;
      end
    end
    else if (source_object != null) begin
      status = checked_command_handle_snapshot(
        source_object.object_h, "xtr_v1 object-ID command",
        handle0_snapshot
      );
      if (!status.ok()) return status;
    end
    else if (source_mr != null) begin
      status = checked_command_handle_snapshot(
        source_mr.mr_h, "xtr_v1 MR deregister", handle0_snapshot
      );
      if (!status.ok()) return status;
    end
    if (!clear_command_body_references(source, saved_references))
      return invalid_argument("xtr_v1 CMQ body reference capture failed");
    source_wrapper = source.get_object_type();
    saved_object = (source_wrapper == null) ? null :
      source_wrapper.create_object("xtr_v1_saved_body_shell");
    if (saved_object == null || !$cast(saved_body, saved_object)) begin
      void'(restore_command_body_references(source, saved_references));
      return invalid_argument("xtr_v1 CMQ body value capture failed");
    end
    saved_body.copy(source);
    saved_shell_value = command_body_value_key(saved_body);
    cloned_object = source.clone();
    source.copy(saved_body);
    if (!restore_command_body_references(source, saved_references)) begin
      snapshot = null;
      return invalid_argument("xtr_v1 CMQ body source restoration failed");
    end
    if (cloned_object == null || !$cast(snapshot, cloned_object) ||
        snapshot == source || snapshot.get_type_name() != source_type_name) begin
      snapshot = null;
      return invalid_argument("xtr_v1 CMQ body clone contract failed");
    end
    if (command_body_value_key(source) != saved_value ||
        command_body_value_key(snapshot) != saved_shell_value ||
        !command_body_references_are_null(snapshot)) begin
      snapshot = null;
      return invalid_argument("xtr_v1 CMQ body clone changed its value");
    end
    if (source_qpc != null) begin
      if (!$cast(snapshot_qpc, snapshot)) begin
        snapshot = null;
        return invalid_argument("xtr_v1 QPC body snapshot type is invalid");
      end
      snapshot_qpc.qp_h = handle0_snapshot;
      snapshot_qpc.send_cq_h = handle1_snapshot;
      snapshot_qpc.recv_cq_h = handle2_snapshot;
    end
    else if (source_object != null) begin
      if (!$cast(snapshot_object, snapshot)) begin
        snapshot = null;
        return invalid_argument(
          "xtr_v1 object-ID body snapshot type is invalid"
        );
      end
      snapshot_object.object_h = handle0_snapshot;
    end
    else if (source_mr != null) begin
      if (!$cast(snapshot_mr, snapshot)) begin
        snapshot = null;
        return invalid_argument("xtr_v1 MR body snapshot type is invalid");
      end
      snapshot_mr.mr_h = handle0_snapshot;
    end
    if (!command_body_graph_detached(source, snapshot)) begin
      snapshot = null;
      return invalid_argument("xtr_v1 CMQ body snapshot aliases its source");
    end
    status = snapshot.validate();
    if (status == null) begin
      snapshot = null;
      return invalid_argument("xtr_v1 CMQ snapshot validation returned null");
    end
    if (!status.ok())
      snapshot = null;
    return status;
  endfunction

  protected function rdma_codec_key doorbell_key(string variant);
    rdma_codec_key key;
    key.hw_version = "xtr_v1";
    key.image_kind = RDMA_IMAGE_DOORBELL;
    key.object_type = "doorbell";
    key.variant = variant;
    key.opcode = 8'h00;
    return key;
  endfunction

  virtual function rdma_status validate_profile();
    string variants[13] = '{
      "cmq_sq", "sq", "rq", "srq_pi", "srq_limit", "cq_rc_ud",
      "cq_urc", "ceq", "aeq", "rts2sqd", "sqd2rts", "qp_flush",
      "tx_flush"
    };
    rdma_codec_base codec;
    rdma_status status;

    if (request_composer == null)
      return invalid_state("xtr_v1 CMQ request composer is not initialized");
    if (completion_codec == null)
      return invalid_state("xtr_v1 CMQ completion codec is not initialized");
    if (error_codec == null)
      return invalid_state("xtr_v1 error codec is not initialized");
    if (doorbell_codecs == null)
      return invalid_state("xtr_v1 doorbell registry is not initialized");
    if (doorbell_registration_status == null)
      return invalid_state("xtr_v1 doorbell default registration failed");
    if (!doorbell_registration_status.ok())
      return doorbell_registration_status;
    foreach (variants[i]) begin
      codec = null;
      status = doorbell_codecs.lookup(doorbell_key(variants[i]), codec);
      if (!status.ok() || codec == null)
        return invalid_state({"xtr_v1 doorbell defaults are incomplete: ",
                              variants[i]});
    end
    return rdma_status::success();
  endfunction

  protected function bit same_function(
    rdma_function_handle lhs,
    rdma_function_handle rhs
  );
    if (lhs == null || rhs == null)
      return 1'b0;
    return lhs.function_uid == rhs.function_uid &&
           lhs.object_id == rhs.object_id &&
           lhs.generation == rhs.generation;
  endfunction

  protected function bit generationless_opcode(bit [7:0] opcode);
    return opcode inside {XTR_V1_OP_OCC_FLUSH, XTR_V1_OP_TQ_FLUSH};
  endfunction

  protected function rdma_status validate_composed_sqe(
    rdma_hw_image image,
    bit [7:0] opcode,
    int unsigned function_generation
  );
    if (image == null)
      return invalid_state("xtr_v1 CMQ request composer published null");
    if (image.length != XTR_V1_CMQE_BYTES ||
        image.bytes.size() != XTR_V1_CMQE_BYTES ||
        image.alignment != XTR_V1_CMQE_BYTES ||
        image.endian != RDMA_ENDIAN_BIG ||
        image.image_kind != RDMA_IMAGE_CMQ_SQE ||
        image.hardware_version != XTR_V1_HW_VERSION ||
        image.write_target_kind != RDMA_HW_TARGET_NONE ||
        image.backing_target.value != 0 || image.hmc_target.value != 0 ||
        image.bar_target.value != 0)
      return rdma_status::make(
        RDMA_SC_CODEC_ERROR,
        "xtr_v1 CMQ request composer published invalid metadata"
      );
    if (generationless_opcode(opcode)) begin
      if (image.function_generation != 0)
        return rdma_status::make(
          RDMA_SC_CODEC_ERROR,
          "xtr_v1 generationless CMQ body published a generation"
        );
    end
    else if (image.function_generation != function_generation)
      return rdma_status::make(
        RDMA_SC_STALE_GENERATION,
        "xtr_v1 CMQ body generation does not match Function"
      );
    return rdma_status::success();
  endfunction

  virtual function rdma_status compose_sqe(
    rdma_cmq_command_desc command,
    rdma_cmq_slot_context slot,
    output rdma_hw_image sqe,
    output rdma_cmq_expected_response expected
  );
    rdma_status status;
    rdma_hw_image body;
    rdma_hw_image composed;
    rdma_hw_image detached;
    rdma_xtr_v1_cmq_envelope envelope;
    rdma_cmq_expected_response candidate_expected;
    bit [7:0] opcode;
    longint unsigned target_address;

    sqe = null;
    expected = null;
    status = validate_profile();
    if (!status.ok()) return status;
    if (command == null)
      return invalid_argument("xtr_v1 CMQ command is null");
    if (slot == null)
      return invalid_argument("xtr_v1 CMQ slot is null");
    status = command.validate();
    if (!status.ok()) return status;
    status = slot.validate();
    if (!status.ok()) return status;
    if (!same_function(command.function_h, slot.function_h))
      return invalid_argument(
        "xtr_v1 CMQ command and slot Functions do not match"
      );
    if (command.opcode_key.profile_name != profile_name())
      return invalid_argument("CMQ command selects a different profile");
    if (command.opcode_key.opcode[31:8] != 0)
      return invalid_argument("xtr_v1 CMQ opcode exceeds 8 bits");
    if (!command.vfid_override && command.use_vfid != 0)
      return invalid_argument("xtr_v1 CMQ VFID requires override");
    if (slot.backing_addr.value >
        (64'hffff_ffff_ffff_ffff - slot.relative_offset))
      return rdma_status::make(
        RDMA_SC_DMA_TRANSLATION,
        "xtr_v1 CMQ SQE backing target overflows"
      );

    opcode = command.opcode_key.opcode[7:0];
    body = null;
    status = request_composer.build_body(opcode, command.body, body);
    if (!status.ok()) return status;
    if (body == null)
      return invalid_state("xtr_v1 CMQ body composer published null");

    envelope = rdma_xtr_v1_cmq_envelope::type_id::create("envelope");
    envelope.valid = !slot.sq_wrap;
    envelope.vfid_override = command.vfid_override;
    envelope.use_vfid = command.use_vfid;
    envelope.wrap = slot.sq_wrap;
    envelope.wqe_index = slot.sq_index[4:0];
    envelope.opcode = opcode;
    composed = null;
    status = request_composer.compose_request(
      envelope, body, command.qpc_signature_source, composed
    );
    if (!status.ok()) return status;
    status = validate_composed_sqe(
      composed, opcode, command.function_h.generation
    );
    if (!status.ok()) return status;

    detached = rdma_hw_image::type_id::create("detached_sqe");
    detached.copy(composed);
    if (generationless_opcode(opcode))
      detached.function_generation = command.function_h.generation;
    target_address = slot.backing_addr.value + slot.relative_offset;
    detached.write_target_kind = RDMA_HW_TARGET_BACKING;
    detached.backing_target.value = target_address;
    detached.hmc_target = '0;
    detached.bar_target = '0;

    candidate_expected = rdma_cmq_expected_response::type_id::create(
      "expected_response");
    candidate_expected.hardware_opcode = {24'h0, opcode};
    candidate_expected.variant = command.opcode_key.variant;
    sqe = detached;
    expected = candidate_expected;
    return rdma_status::success();
  endfunction

  protected function rdma_status validate_raw_cqe(rdma_hw_image raw_cqe);
    if (raw_cqe == null)
      return rdma_status::make(RDMA_SC_CODEC_ERROR,
                               "CMQ raw CQE is null");
    if (raw_cqe.length != XTR_V1_CMQE_BYTES ||
        raw_cqe.bytes.size() != XTR_V1_CMQE_BYTES)
      return rdma_status::make(RDMA_SC_CODEC_ERROR,
                               "CMQ raw CQE length is invalid");
    if (raw_cqe.image_kind != RDMA_IMAGE_CMQ_CQE ||
        raw_cqe.write_target_kind != RDMA_HW_TARGET_NONE ||
        raw_cqe.backing_target.value != 0 ||
        raw_cqe.hmc_target.value != 0 || raw_cqe.bar_target.value != 0)
      return rdma_status::make(RDMA_SC_CODEC_ERROR,
                               "CMQ raw CQE metadata is invalid");
    return rdma_status::success();
  endfunction

  virtual function rdma_status inspect_cqe(
    rdma_hw_image raw_cqe,
    bit expected_owner,
    output bit ready,
    output rdma_cmq_decoded_cqe decoded
  );
    rdma_status status;
    rdma_status command_status;
    rdma_xtr_v1_cmq_completion completion;
    rdma_xtr_v1_cmq_completion payload;
    rdma_cmq_decoded_cqe candidate;
    uvm_object cloned_object;
    bit completion_ready;

    ready = 1'b0;
    decoded = null;
    status = validate_profile();
    if (!status.ok()) return status;
    status = validate_raw_cqe(raw_cqe);
    if (!status.ok()) return status;
    completion = null;
    completion_ready = 1'b0;
    status = completion_codec.inspect_completion(
      raw_cqe, expected_owner, completion_ready, completion
    );
    if (!status.ok()) return status;
    if (!completion_ready) return rdma_status::success();
    if (completion == null)
      return invalid_state("xtr_v1 completion codec published null");

    command_status = null;
    status = error_codec.decode_status(completion.command_ecode,
                                       RDMA_ENGINE_CMQ, command_status);
    if (!status.ok()) return status;
    if (command_status == null)
      return invalid_state("xtr_v1 error codec published null");
    cloned_object = completion.clone();
    if (cloned_object == null || !$cast(payload, cloned_object))
      return invalid_state("xtr_v1 completion payload clone failed");

    candidate = rdma_cmq_decoded_cqe::type_id::create("decoded_cqe");
    if (candidate == null)
      return invalid_state("xtr_v1 decoded CQE allocation failed");
    candidate.hardware_opcode = {24'h0, completion.opcode};
    candidate.wqe_index = completion.wqe_index;
    candidate.wqe_wrap = completion.wrap;
    candidate.hardware_ecode = {24'h0, completion.command_ecode};
    candidate.command_status = command_status;
    candidate.response_payload = payload;
    status = candidate.validate();
    if (!status.ok()) return status;
    decoded = candidate;
    ready = 1'b1;
    return rdma_status::success();
  endfunction

  virtual function rdma_status encode_doorbell(
    rdma_handle cmq_h,
    int unsigned final_pi,
    bit polarity,
    output rdma_hw_image image
  );
    rdma_status status;
    rdma_xtr_v1_cmq_sq_doorbell_model model;
    rdma_hw_image encoded;
    rdma_hw_image detached;
    uvm_object cloned_object;

    image = null;
    status = validate_profile();
    if (!status.ok()) return status;
    if (cmq_h == null || cmq_h.kind != RDMA_RESOURCE_CMQ)
      return invalid_argument("xtr_v1 CMQ doorbell handle is invalid");
    if (final_pi >= 32)
      return invalid_argument("xtr_v1 CMQ doorbell PI exceeds 5 bits");

    model = rdma_xtr_v1_cmq_sq_doorbell_model::type_id::create(
      "cmq_sq_doorbell");
    cloned_object = cmq_h.clone();
    if (cloned_object == null || !$cast(model.target_h, cloned_object))
      return invalid_state("xtr_v1 CMQ doorbell handle clone failed");
    model.pi = final_pi;
    model.polarity = polarity;
    encoded = null;
    status = doorbell_codecs.encode(model, encoded);
    if (!status.ok()) return status;
    if (encoded == null)
      return invalid_state("xtr_v1 doorbell codec published null");
    detached = rdma_hw_image::type_id::create("detached_doorbell");
    detached.copy(encoded);
    image = detached;
    return rdma_status::success();
  endfunction
endclass
