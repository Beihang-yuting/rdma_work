class rdma_xtr_v1_cmq_hw_profile extends rdma_cmq_hw_profile;
  `uvm_object_utils(rdma_xtr_v1_cmq_hw_profile)

  protected rdma_xtr_v1_cmq_request_composer request_composer;
  protected rdma_xtr_v1_cmq_completion_codec completion_codec;
  protected rdma_xtr_v1_error_codec error_codec;
  protected rdma_xtr_v1_doorbell_codec_registry doorbell_codecs;
  protected rdma_status doorbell_registration_status;

  function new(
    string name = "rdma_xtr_v1_cmq_hw_profile",
    rdma_xtr_v1_doorbell_codec_registry injected_doorbell_codecs = null
  );
    rdma_status status;
    super.new(name);
    request_composer = rdma_xtr_v1_cmq_request_composer::type_id::create(
      "request_composer");
    completion_codec = rdma_xtr_v1_cmq_completion_codec::type_id::create(
      "completion_codec");
    error_codec = rdma_xtr_v1_error_codec::type_id::create("error_codec");
    if (injected_doorbell_codecs == null)
      doorbell_codecs =
        rdma_xtr_v1_doorbell_codec_registry::type_id::create(
          "doorbell_codecs");
    else
      doorbell_codecs = injected_doorbell_codecs;
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
    if (composed == null)
      return invalid_state("xtr_v1 CMQ request composer published null");

    detached = rdma_hw_image::type_id::create("detached_sqe");
    detached.copy(composed);
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
