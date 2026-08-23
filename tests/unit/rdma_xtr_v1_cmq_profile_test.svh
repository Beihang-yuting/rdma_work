class rdma_xtr_v1_cmq_profile_probe
    extends rdma_xtr_v1_cmq_hw_profile;
  `uvm_object_utils(rdma_xtr_v1_cmq_profile_probe)

  function new(string name = "rdma_xtr_v1_cmq_profile_probe");
    super.new(name);
  endfunction

  function void clear_request_composer();
    request_composer = null;
  endfunction

  function void clear_completion_codec();
    completion_codec = null;
  endfunction

  function void clear_error_codec();
    error_codec = null;
  endfunction

  function void clear_doorbell_registry();
    doorbell_codecs = null;
  endfunction

  function void clear_doorbell_defaults();
    doorbell_codecs.clear();
  endfunction

  function void force_doorbell_registration_failure();
    doorbell_registration_status = rdma_status::make(
      RDMA_SC_INVALID_STATE, "injected doorbell registration failure"
    );
  endfunction
endclass

class rdma_xtr_v1_cmq_profile_test extends uvm_test;
  `uvm_component_utils(rdma_xtr_v1_cmq_profile_test)

  localparam longint unsigned TEST_FUNCTION_UID =
    64'h1122_3344_5566_7788;
  localparam int unsigned TEST_GENERATION = 32'd7;

  function new(string name = "rdma_xtr_v1_cmq_profile_test",
               uvm_component parent = null);
    super.new(name, parent);
  endfunction

  function automatic void expect_status(
    string label,
    rdma_status status,
    rdma_status_code_e expected
  );
    if (status == null)
      `uvm_error(label, "profile returned a null status")
    else if (status.code != expected)
      `uvm_error(label,
                 $sformatf("expected %s, got %s (%s)", expected.name(),
                           status.code.name(), status.convert2string()))
  endfunction

  function automatic rdma_function_handle make_function(string name);
    rdma_function_handle function_h;
    function_h = rdma_function_handle::type_id::create(name);
    function_h.function_uid = TEST_FUNCTION_UID;
    function_h.object_id = 32'h1234;
    function_h.generation = TEST_GENERATION;
    return function_h;
  endfunction

  function automatic rdma_handle make_handle(
    string name,
    rdma_resource_kind_e kind,
    int unsigned object_id
  );
    rdma_handle handle;
    handle = rdma_handle::type_id::create(name);
    handle.kind = kind;
    handle.function_uid = TEST_FUNCTION_UID;
    handle.object_id = object_id;
    handle.generation = TEST_GENERATION;
    return handle;
  endfunction

  function automatic rdma_cmq_command_desc make_command(
    string name,
    rdma_function_handle function_h
  );
    rdma_cmq_command_desc command;
    rdma_cmq_opcode_key key;
    rdma_xtr_v1_object_id_command_body body;

    key = rdma_cmq_opcode_key::type_id::create({name, "_key"});
    key.profile_name = "xtr_v1";
    key.opcode = XTR_V1_OP_CQC_DELETE;
    key.variant = "delete";
    body = rdma_xtr_v1_object_id_command_body::type_id::create(
      {name, "_body"});
    body.object_h = make_handle({name, "_cq"}, RDMA_RESOURCE_CQ,
                                21'h12345);
    command = rdma_cmq_command_desc::type_id::create(name);
    command.function_h = function_h;
    command.opcode_key = key;
    command.body = body;
    command.qpc_signature_source = null;
    command.vfid_override = 1'b1;
    command.use_vfid = 11'h345;
    command.timeout = 100;
    return command;
  endfunction

  function automatic rdma_cmq_slot_context make_slot(
    string name,
    rdma_function_handle function_h,
    rdma_handle cmq_h
  );
    rdma_cmq_slot_context slot;
    slot = rdma_cmq_slot_context::type_id::create(name);
    slot.function_h = function_h;
    slot.cmq_h = cmq_h;
    slot.backing_addr.value = 64'h0000_0000_4000_0000;
    slot.relative_offset = 64'd320;
    slot.slot_sequence = 64'd37;
    slot.sq_index = 5;
    slot.sq_wrap = 1'b1;
    return slot;
  endfunction

  function automatic bit [63:0] get_qword(
    rdma_hw_image image,
    int unsigned qword_index
  );
    bit [63:0] value;
    int unsigned base;
    value = '0;
    base = qword_index * 8;
    for (int unsigned i = 0; i < 8; i++)
      value = {value[55:0], image.bytes[base + i]};
    return value;
  endfunction

  function automatic void set_qword(
    rdma_hw_image image,
    int unsigned qword_index,
    bit [63:0] value
  );
    int unsigned base;
    base = qword_index * 8;
    for (int unsigned i = 0; i < 8; i++)
      image.bytes[base + i] = value[63 - (i * 8) -: 8];
  endfunction

  function automatic rdma_hw_image clone_image(
    rdma_hw_image source,
    string name
  );
    rdma_hw_image result;
    result = rdma_hw_image::type_id::create(name);
    result.copy(source);
    return result;
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

  function automatic rdma_hw_image make_cqe(
    bit owner,
    bit [7:0] opcode,
    bit [7:0] command_ecode,
    bit [4:0] wqe_index,
    bit wrap
  );
    rdma_hw_image image;
    bit [63:0] qword0;
    image = rdma_hw_image::type_id::create("profile_cqe");
    repeat (64) image.bytes.push_back(8'h00);
    image.length = 64;
    image.alignment = 64;
    image.endian = RDMA_ENDIAN_BIG;
    image.image_kind = RDMA_IMAGE_CMQ_CQE;
    image.hardware_version = XTR_V1_HW_VERSION;
    image.function_generation = 0;
    image.write_target_kind = RDMA_HW_TARGET_NONE;
    image.backing_target = '0;
    image.hmc_target = '0;
    image.bar_target = '0;
    qword0 = '0;
    qword0[63] = owner;
    qword0[45] = wrap;
    qword0[44:40] = wqe_index;
    qword0[39:32] = opcode;
    qword0[31:24] = command_ecode;
    set_qword(image, 0, qword0);
    for (int unsigned i = 8; i < 64; i++)
      image.bytes[i] = i[7:0];
    return image;
  endfunction

  function automatic void check_profile_validation();
    rdma_xtr_v1_cmq_hw_profile profile;
    rdma_xtr_v1_cmq_profile_probe probe;

    profile = rdma_xtr_v1_cmq_hw_profile::type_id::create("profile");
    if (profile.profile_name() != "xtr_v1")
      `uvm_error("PROFILE_NAME", "xtr_v1 profile reported a wrong name")
    expect_status("PROFILE_VALID", profile.validate_profile(), RDMA_SC_OK);

    probe = rdma_xtr_v1_cmq_profile_probe::type_id::create(
      "missing_request_composer");
    probe.clear_request_composer();
    expect_status("PROFILE_MISSING_REQUEST", probe.validate_profile(),
                  RDMA_SC_INVALID_STATE);
    probe = rdma_xtr_v1_cmq_profile_probe::type_id::create(
      "missing_completion_codec");
    probe.clear_completion_codec();
    expect_status("PROFILE_MISSING_COMPLETION", probe.validate_profile(),
                  RDMA_SC_INVALID_STATE);
    probe = rdma_xtr_v1_cmq_profile_probe::type_id::create(
      "missing_error_codec");
    probe.clear_error_codec();
    expect_status("PROFILE_MISSING_ERROR", probe.validate_profile(),
                  RDMA_SC_INVALID_STATE);
    probe = rdma_xtr_v1_cmq_profile_probe::type_id::create(
      "missing_doorbell_registry");
    probe.clear_doorbell_registry();
    expect_status("PROFILE_MISSING_DOORBELL_REGISTRY",
                  probe.validate_profile(), RDMA_SC_INVALID_STATE);
    probe = rdma_xtr_v1_cmq_profile_probe::type_id::create(
      "missing_doorbell_defaults");
    probe.clear_doorbell_defaults();
    expect_status("PROFILE_MISSING_DOORBELLS", probe.validate_profile(),
                  RDMA_SC_INVALID_STATE);
    probe = rdma_xtr_v1_cmq_profile_probe::type_id::create(
      "failed_doorbell_registration");
    probe.force_doorbell_registration_failure();
    expect_status("PROFILE_FAILED_DOORBELL_REGISTRATION",
                  probe.validate_profile(), RDMA_SC_INVALID_STATE);
  endfunction

  function automatic void check_compose_sqe();
    rdma_xtr_v1_cmq_hw_profile profile;
    rdma_function_handle function_h;
    rdma_handle cmq_h;
    rdma_cmq_command_desc command;
    rdma_cmq_command_desc command_snapshot;
    rdma_cmq_slot_context slot;
    rdma_cmq_slot_context slot_snapshot;
    rdma_xtr_v1_object_id_command_body body;
    rdma_xtr_v1_object_id_command_body snapshot_body;
    rdma_hw_image sqe;
    rdma_hw_image second_sqe;
    rdma_cmq_expected_response expected;
    rdma_cmq_expected_response second_expected;
    rdma_status status;
    bit [63:0] qword0;

    profile = rdma_xtr_v1_cmq_hw_profile::type_id::create(
      "compose_profile");
    function_h = make_function("compose_function");
    cmq_h = make_handle("compose_cmq", RDMA_RESOURCE_CMQ, 32'h55);
    command = make_command("compose_command", function_h);
    slot = make_slot("compose_slot", function_h, cmq_h);
    command_snapshot = rdma_cmq_command_desc::type_id::create(
      "command_snapshot");
    command_snapshot.copy(command);
    slot_snapshot = rdma_cmq_slot_context::type_id::create("slot_snapshot");
    slot_snapshot.copy(slot);

    sqe = null;
    expected = null;
    status = profile.compose_sqe(command, slot, sqe, expected);
    expect_status("COMPOSE_STATUS", status, RDMA_SC_OK);
    if (sqe == null || expected == null) begin
      `uvm_error("COMPOSE_OUTPUT", "successful compose published null")
      return;
    end
    qword0 = get_qword(sqe, 0);
    if (sqe.length != 64 || sqe.bytes.size() != 64 ||
        sqe.alignment != 64 || sqe.endian != RDMA_ENDIAN_BIG ||
        sqe.image_kind != RDMA_IMAGE_CMQ_SQE ||
        sqe.hardware_version != XTR_V1_HW_VERSION ||
        sqe.function_generation != TEST_GENERATION ||
        sqe.write_target_kind != RDMA_HW_TARGET_BACKING ||
        sqe.backing_target.value != 64'h0000_0000_4000_0140 ||
        sqe.hmc_target.value != 0 || sqe.bar_target.value != 0)
      `uvm_error("COMPOSE_METADATA", "composed SQE metadata is wrong")
    if (qword0[63] != !slot.sq_wrap || qword0[59] != 1'b1 ||
        qword0[58:48] != 11'h345 || qword0[45] != slot.sq_wrap ||
        qword0[44:40] != slot.sq_index[4:0] ||
        qword0[39:32] != XTR_V1_OP_CQC_DELETE ||
        qword0[20:0] != 21'h12345)
      `uvm_error("COMPOSE_FIELDS", "composed SQE envelope/body is wrong")
    if (expected.hardware_opcode != XTR_V1_OP_CQC_DELETE ||
        expected.variant != "delete")
      `uvm_error("COMPOSE_EXPECTED", "expected response is wrong")

    if (command.function_h != function_h ||
        command.function_h.function_uid !=
          command_snapshot.function_h.function_uid ||
        command.function_h.object_id !=
          command_snapshot.function_h.object_id ||
        command.function_h.generation !=
          command_snapshot.function_h.generation ||
        command.opcode_key.profile_name !=
          command_snapshot.opcode_key.profile_name ||
        command.opcode_key.opcode != command_snapshot.opcode_key.opcode ||
        command.opcode_key.variant != command_snapshot.opcode_key.variant ||
        command.vfid_override != command_snapshot.vfid_override ||
        command.use_vfid != command_snapshot.use_vfid ||
        command.timeout != command_snapshot.timeout ||
        !$cast(body, command.body) ||
        !$cast(snapshot_body, command_snapshot.body) ||
        body.object_h.kind != snapshot_body.object_h.kind ||
        body.object_h.function_uid != snapshot_body.object_h.function_uid ||
        body.object_h.object_id != snapshot_body.object_h.object_id ||
        body.object_h.generation != snapshot_body.object_h.generation)
      `uvm_error("COMPOSE_COMMAND_IMMUTABLE", "compose mutated command")
    if (slot.function_h != function_h || slot.cmq_h != cmq_h ||
        slot.backing_addr.value != slot_snapshot.backing_addr.value ||
        slot.relative_offset != slot_snapshot.relative_offset ||
        slot.slot_sequence != slot_snapshot.slot_sequence ||
        slot.sq_index != slot_snapshot.sq_index ||
        slot.sq_wrap != slot_snapshot.sq_wrap)
      `uvm_error("COMPOSE_SLOT_IMMUTABLE", "compose mutated slot")

    sqe.bytes[0] ^= 8'hff;
    expected.variant = "mutated";
    second_sqe = null;
    second_expected = null;
    status = profile.compose_sqe(command, slot, second_sqe, second_expected);
    expect_status("COMPOSE_DETACHED_STATUS", status, RDMA_SC_OK);
    if (second_sqe == null || second_expected == null ||
        second_sqe == sqe || second_expected == expected ||
        get_qword(second_sqe, 0)[63] != !slot.sq_wrap ||
        second_expected.variant != "delete")
      `uvm_error("COMPOSE_DETACHED", "compose outputs alias profile state")

    sqe = rdma_hw_image::type_id::create("stale_bad_profile_sqe");
    expected = rdma_cmq_expected_response::type_id::create(
      "stale_bad_profile_expected");
    command.opcode_key.profile_name = "other_profile";
    status = profile.compose_sqe(command, slot, sqe, expected);
    expect_status("COMPOSE_OTHER_PROFILE", status, RDMA_SC_INVALID_ARGUMENT);
    if (sqe != null || expected != null)
      `uvm_error("COMPOSE_OTHER_PROFILE", "failure published outputs")
    command.opcode_key.profile_name = "xtr_v1";

    command.opcode_key.opcode = 32'h0100_000e;
    status = profile.compose_sqe(command, slot, sqe, expected);
    expect_status("COMPOSE_HIGH_OPCODE", status, RDMA_SC_INVALID_ARGUMENT);
    command.opcode_key.opcode = XTR_V1_OP_CQC_DELETE;

    command.vfid_override = 1'b0;
    status = profile.compose_sqe(command, slot, sqe, expected);
    expect_status("COMPOSE_INVALID_VFID", status, RDMA_SC_INVALID_ARGUMENT);
    command.vfid_override = 1'b1;

    command.opcode_key.opcode = XTR_V1_OP_TQ_FLUSH;
    command.opcode_key.variant = "flush";
    status = profile.compose_sqe(command, slot, sqe, expected);
    expect_status("COMPOSE_INCOMPATIBLE_BODY", status,
                  RDMA_SC_INVALID_ARGUMENT);
    command.opcode_key.opcode = XTR_V1_OP_CQC_DELETE;
    command.opcode_key.variant = "delete";

    slot.backing_addr.value = 64'hffff_ffff_ffff_ffc0;
    status = profile.compose_sqe(command, slot, sqe, expected);
    expect_status("COMPOSE_TARGET_OVERFLOW", status,
                  RDMA_SC_DMA_TRANSLATION);
    if (sqe != null || expected != null)
      `uvm_error("COMPOSE_TARGET_OVERFLOW", "failure published outputs")
  endfunction

  function automatic void check_inspect_cqe();
    rdma_xtr_v1_cmq_hw_profile profile;
    rdma_xtr_v1_error_codec oracle;
    rdma_hw_image raw_cqe;
    rdma_hw_image snapshot;
    rdma_cmq_decoded_cqe decoded;
    rdma_cmq_decoded_cqe second_decoded;
    rdma_xtr_v1_cmq_completion payload;
    rdma_status expected_status;
    rdma_status status;
    bit ready;
    bit [7:0] ecode;

    ecode = XTR_V1_ECODE_EC_RCE_CQ_FULL;
    profile = rdma_xtr_v1_cmq_hw_profile::type_id::create(
      "inspect_profile");
    oracle = rdma_xtr_v1_error_codec::type_id::create("error_oracle");
    raw_cqe = make_cqe(1'b1, XTR_V1_OP_CQC_QUERY, ecode, 5'h1b, 1'b1);
    snapshot = clone_image(raw_cqe, "raw_cqe_snapshot");
    ready = 1'b0;
    decoded = null;
    status = profile.inspect_cqe(raw_cqe, 1'b1, ready, decoded);
    expect_status("INSPECT_STATUS", status, RDMA_SC_OK);
    if (!ready || decoded == null) begin
      `uvm_error("INSPECT_OUTPUT", "ready CQE did not publish decoded data")
      return;
    end
    expected_status = null;
    status = oracle.decode_status(ecode, RDMA_ENGINE_CMQ, expected_status);
    expect_status("INSPECT_ORACLE", status, RDMA_SC_OK);
    if (decoded.hardware_opcode != XTR_V1_OP_CQC_QUERY ||
        decoded.wqe_index != 5'h1b || !decoded.wqe_wrap ||
        decoded.hardware_ecode != ecode || decoded.command_status == null ||
        expected_status == null ||
        decoded.command_status.code != expected_status.code ||
        decoded.command_status.category != expected_status.category ||
        decoded.command_status.source_engine != expected_status.source_engine ||
        decoded.command_status.hardware_code != expected_status.hardware_code ||
        decoded.command_status.hardware_code_valid !=
          expected_status.hardware_code_valid)
      `uvm_error("INSPECT_FIELDS", "decoded CQE/error mapping is wrong")
    if (!$cast(payload, decoded.response_payload))
      `uvm_error("INSPECT_PAYLOAD_TYPE", "response payload lost xtr type")
    else if (!payload.owner || payload.opcode != XTR_V1_OP_CQC_QUERY ||
             payload.object_payload.size() != 56 ||
             payload.object_payload[0] != 8'h08 ||
             payload.object_payload[55] != 8'h3f)
      `uvm_error("INSPECT_PAYLOAD", "typed response payload is wrong")
    if (decoded.command_status.function_uid != 0 ||
        decoded.command_status.generation != 0 ||
        decoded.command_status.resource_id != 0 ||
        decoded.command_status.command_id != 0)
      `uvm_error("INSPECT_IDENTITY", "profile invented ticket identity")
    if (!images_equal(raw_cqe, snapshot))
      `uvm_error("INSPECT_IMMUTABLE", "inspect mutated raw CQE")

    second_decoded = null;
    status = profile.inspect_cqe(raw_cqe, 1'b1, ready, second_decoded);
    expect_status("INSPECT_DETACHED_STATUS", status, RDMA_SC_OK);
    if (!ready || second_decoded == null || second_decoded == decoded ||
        second_decoded.response_payload == decoded.response_payload)
      `uvm_error("INSPECT_DETACHED", "decoded CQE outputs alias")

    raw_cqe = make_cqe(1'b0, 8'hfe, 8'hff, 5'h1f, 1'b1);
    raw_cqe.bytes[63] = 8'hff;
    decoded = rdma_cmq_decoded_cqe::type_id::create("stale_decoded");
    ready = 1'b1;
    status = profile.inspect_cqe(raw_cqe, 1'b1, ready, decoded);
    expect_status("INSPECT_OWNER_MISMATCH_STATUS", status, RDMA_SC_OK);
    if (ready || decoded != null)
      `uvm_error("INSPECT_OWNER_MISMATCH", "stale CQE was inspected")
  endfunction

  function automatic void check_encode_doorbell();
    rdma_xtr_v1_cmq_hw_profile profile;
    rdma_handle cmq_h;
    rdma_hw_image image;
    rdma_hw_image second_image;
    rdma_status status;
    bit [63:0] word;

    profile = rdma_xtr_v1_cmq_hw_profile::type_id::create(
      "doorbell_profile");
    cmq_h = make_handle("doorbell_cmq", RDMA_RESOURCE_CMQ, 32'h55);
    image = null;
    status = profile.encode_doorbell(cmq_h, 17, 1'b1, image);
    expect_status("DOORBELL_STATUS", status, RDMA_SC_OK);
    if (image == null) begin
      `uvm_error("DOORBELL_OUTPUT", "successful doorbell encode is null")
      return;
    end
    word = get_qword(image, 0);
    if (image.length != 8 || image.bytes.size() != 8 ||
        image.alignment != 8 || image.endian != RDMA_ENDIAN_BIG ||
        image.image_kind != RDMA_IMAGE_DOORBELL ||
        image.hardware_version != XTR_V1_HW_VERSION ||
        image.function_generation != TEST_GENERATION ||
        image.write_target_kind != RDMA_HW_TARGET_BAR ||
        image.bar_target.value != 64'h000 ||
        image.backing_target.value != 0 || image.hmc_target.value != 0 ||
        word[36:32] != 5'd17 || word[37] != 1'b1)
      `uvm_error("DOORBELL_FIELDS", "CMQ SQ doorbell is wrong")

    image.bytes[0] ^= 8'hff;
    second_image = null;
    status = profile.encode_doorbell(cmq_h, 17, 1'b1, second_image);
    expect_status("DOORBELL_DETACHED_STATUS", status, RDMA_SC_OK);
    if (second_image == null || second_image == image ||
        get_qword(second_image, 0)[37:32] != 6'b1_10001)
      `uvm_error("DOORBELL_DETACHED", "doorbell output aliases codec state")

    image = rdma_hw_image::type_id::create("stale_bad_doorbell");
    status = profile.encode_doorbell(null, 17, 1'b1, image);
    expect_status("DOORBELL_NULL_HANDLE", status, RDMA_SC_INVALID_ARGUMENT);
    if (image != null)
      `uvm_error("DOORBELL_NULL_HANDLE", "failure published image")
    cmq_h.kind = RDMA_RESOURCE_CQ;
    status = profile.encode_doorbell(cmq_h, 17, 1'b1, image);
    expect_status("DOORBELL_WRONG_HANDLE", status, RDMA_SC_INVALID_ARGUMENT);
    cmq_h.kind = RDMA_RESOURCE_CMQ;
    status = profile.encode_doorbell(cmq_h, 32, 1'b1, image);
    expect_status("DOORBELL_PI_RANGE", status, RDMA_SC_INVALID_ARGUMENT);
  endfunction

  virtual task run_phase(uvm_phase phase);
    phase.raise_objection(this);
    check_profile_validation();
    check_compose_sqe();
    check_inspect_cqe();
    check_encode_doorbell();
    phase.drop_objection(this);
  endtask
endclass
