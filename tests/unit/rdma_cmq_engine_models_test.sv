// 中文说明：rdma_cmq_engine_models_test.sv 属于单元测试，覆盖对应模型、编码器或执行器契约。
// 阅读提示：先看公开类型和接口，再看实现细节；失败路径应保持状态与资源所有权可追踪。

class rdma_cmq_null_status_body extends rdma_hw_model;
  `uvm_object_utils(rdma_cmq_null_status_body)

  function new(string name = "rdma_cmq_null_status_body");
    super.new(name);
  endfunction

  virtual function rdma_status validate();
    return null;
  endfunction

  virtual function string describe();
    return "CMQ test body returning null validation status";
  endfunction
endclass

class rdma_cmq_engine_models_test extends uvm_test;
  `uvm_component_utils(rdma_cmq_engine_models_test)

  localparam longint unsigned TEST_FUNCTION_UID =
    64'h1122_3344_5566_7788;
  localparam int unsigned TEST_GENERATION = 32'd7;

  function new(string name = "rdma_cmq_engine_models_test",
               uvm_component parent = null);
    super.new(name, parent);
  endfunction

  function automatic void expect_status(
    string check_name,
    rdma_status status,
    rdma_status_code_e expected_code
  );
    if (status == null) begin
      `uvm_error(check_name, "model returned a null status")
      return;
    end
    if (status.code != expected_code)
      `uvm_error(check_name,
                 $sformatf("expected %s, got %s (%s)",
                           expected_code.name(), status.code.name(),
                           status.convert2string()))
  endfunction

  function automatic rdma_function_handle make_function(string name);
    rdma_function_handle function_h;

    function_h = rdma_function_handle::type_id::create(name);
    function_h.function_uid = TEST_FUNCTION_UID;
    function_h.object_id = 32'h1234;
    function_h.generation = TEST_GENERATION;
    return function_h;
  endfunction

  function automatic rdma_handle make_cmq(
    string name,
    rdma_function_handle function_h
  );
    rdma_handle cmq_h;

    cmq_h = rdma_handle::type_id::create(name);
    cmq_h.kind = RDMA_RESOURCE_CMQ;
    cmq_h.function_uid = function_h.function_uid;
    cmq_h.object_id = 32'h55;
    cmq_h.generation = function_h.generation;
    return cmq_h;
  endfunction

  function automatic rdma_cmq_opcode_key make_key(string name);
    rdma_cmq_opcode_key key;

    key = rdma_cmq_opcode_key::type_id::create(name);
    key.profile_name = "generic_profile";
    key.opcode = 32'hff00_abcd;
    key.variant = "query";
    return key;
  endfunction

  function automatic rdma_cmq_sqe_model make_body(
    string name,
    rdma_function_handle function_h,
    rdma_handle target_h
  );
    rdma_cmq_sqe_model body;

    body = rdma_cmq_sqe_model::type_id::create(name);
    body.opcode = RDMA_CMQ_QUERY;
    body.command_id = 64'h111;
    body.function_h = function_h;
    body.target_h = target_h;
    return body;
  endfunction

  function automatic rdma_hw_image make_image(
    string name,
    rdma_image_kind_e image_kind,
    int unsigned byte_count,
    int unsigned generation
  );
    rdma_hw_image image;

    image = rdma_hw_image::type_id::create(name);
    repeat (byte_count)
      image.bytes.push_back(8'h5a);
    image.length = byte_count;
    image.alignment = 64;
    image.endian = RDMA_ENDIAN_BIG;
    image.image_kind = image_kind;
    image.hardware_version = 1;
    image.function_generation = generation;
    image.write_target_kind = RDMA_HW_TARGET_NONE;
    image.backing_target = '0;
    image.hmc_target = '0;
    image.bar_target = '0;
    return image;
  endfunction

  function automatic rdma_cmq_ticket make_ticket(
    string name,
    rdma_function_handle function_h,
    rdma_handle cmq_h,
    rdma_cmq_opcode_key opcode_key
  );
    rdma_cmq_ticket ticket;

    ticket = rdma_cmq_ticket::type_id::create(name);
    ticket.command_id = 64'h1234_0005;
    ticket.function_h = function_h;
    ticket.cmq_h = cmq_h;
    ticket.slot_sequence = 64'd37;
    ticket.sq_index = 5;
    ticket.sq_wrap = 1'b1;
    ticket.opcode_key = opcode_key;
    ticket.absolute_deadline = 64'd1000;
    return ticket;
  endfunction

  task run_phase(uvm_phase phase);
    rdma_function_handle function_h;
    rdma_handle cmq_h;
    rdma_cmq_opcode_key key;
    rdma_cmq_command_desc command;
    rdma_cmq_slot_context slot;
    rdma_cmq_expected_response expected;
    rdma_cmq_decoded_cqe decoded;
    rdma_cmq_ticket ticket;
    rdma_cmq_completion completion;
    rdma_cmq_diagnostic diagnostic;
    rdma_cmq_runtime_desc runtime_desc;

    rdma_cmq_opcode_key key_snapshot;
    rdma_cmq_command_desc command_snapshot;
    rdma_cmq_slot_context slot_snapshot;
    rdma_cmq_expected_response expected_snapshot;
    rdma_cmq_decoded_cqe decoded_snapshot;
    rdma_cmq_ticket ticket_snapshot;
    rdma_cmq_completion completion_snapshot;
    rdma_cmq_diagnostic diagnostic_snapshot;
    rdma_cmq_runtime_desc runtime_snapshot;

    rdma_cmq_sqe_model body;
    rdma_cmq_sqe_model body_snapshot;
    rdma_cmq_null_status_body null_status_body;
    rdma_qpc_behavior response_payload;
    rdma_qpc_behavior response_payload_snapshot;
    rdma_qpc_behavior decoded_response;
    rdma_qpc_behavior decoded_response_snapshot;
    uvm_object cloned_object;

    phase.raise_objection(this);

    function_h = make_function("function_h");
    cmq_h = make_cmq("cmq_h", function_h);
    key = make_key("key");
    body = make_body("body", function_h, cmq_h);

    command = rdma_cmq_command_desc::type_id::create("command");
    command.function_h = function_h;
    command.opcode_key = key;
    command.body = body;
    command.qpc_signature_source = make_image(
      "qpc_signature_source", RDMA_IMAGE_QPC, 512, TEST_GENERATION
    );
    command.vfid_override = 1'b1;
    command.use_vfid = 11'h345;
    command.timeout = 100;

    slot = rdma_cmq_slot_context::type_id::create("slot");
    slot.function_h = function_h;
    slot.cmq_h = cmq_h;
    slot.backing_addr.value = 64'h0000_0000_4000_0000;
    slot.relative_offset = 64'd320;
    slot.slot_sequence = 64'd37;
    slot.sq_index = 5;
    slot.sq_wrap = 1'b1;

    expected = rdma_cmq_expected_response::type_id::create("expected");
    expected.hardware_opcode = 32'hff00_abcd;
    expected.variant = "query";

    response_payload = rdma_qpc_behavior::type_id::create(
      "response_payload"
    );
    response_payload.transport_version = 1;
    response_payload.\priority = 3;
    decoded = rdma_cmq_decoded_cqe::type_id::create("decoded");
    decoded.hardware_opcode = 32'hff00_abcd;
    decoded.wqe_index = 5;
    decoded.wqe_wrap = 1'b1;
    decoded.hardware_ecode = 32'ha5;
    decoded.command_status = rdma_status::success("decoded success");
    decoded.command_status.hardware_code = 32'ha5;
    decoded.command_status.hardware_code_valid = 1'b1;
    decoded.response_payload = response_payload;

    ticket = make_ticket("ticket", function_h, cmq_h, key);

    decoded_response = rdma_qpc_behavior::type_id::create(
      "decoded_response"
    );
    decoded_response.transport_version = 2;
    decoded_response.\priority = 4;
    completion = rdma_cmq_completion::type_id::create("completion");
    completion.ticket = ticket;
    completion.status = rdma_status::success("hardware completion");
    completion.raw_cqe = make_image(
      "completion_raw_cqe", RDMA_IMAGE_CMQ_CQE, 64, TEST_GENERATION
    );
    completion.decoded_response = decoded_response;

    diagnostic = rdma_cmq_diagnostic::type_id::create("diagnostic");
    diagnostic.kind = RDMA_CMQ_DIAG_LATE_COMPLETION;
    diagnostic.ticket = ticket;
    diagnostic.status = rdma_status::make(
      RDMA_SC_TIMEOUT, "late completion"
    );
    diagnostic.raw_cqe = completion.raw_cqe;

    runtime_desc = rdma_cmq_runtime_desc::type_id::create("runtime_desc");
    runtime_desc.function_h = function_h;
    runtime_desc.cmq_h = cmq_h;
    runtime_desc.sq_iova.value = 64'h0000_0001_2000_0000;
    runtime_desc.cq_iova.value = 64'h0000_0001_2000_0800;
    runtime_desc.sq_depth = 32;
    runtime_desc.cq_depth = 32;
    runtime_desc.entry_bytes = 64;
    runtime_desc.initial_sq_valid = 1'b1;
    runtime_desc.initial_cq_owner = 1'b1;
    runtime_desc.initial_doorbell_polarity = 1'b0;

    expect_status("KEY_VALID", key.validate(), RDMA_SC_OK);
    expect_status("COMMAND_VALID", command.validate(), RDMA_SC_OK);
    expect_status("SLOT_VALID", slot.validate(), RDMA_SC_OK);
    expect_status("EXPECTED_VALID", expected.validate(), RDMA_SC_OK);
    expect_status("DECODED_VALID", decoded.validate(), RDMA_SC_OK);
    expect_status("TICKET_VALID", ticket.validate(), RDMA_SC_OK);
    expect_status("COMPLETION_VALID", completion.validate(), RDMA_SC_OK);
    expect_status("DIAGNOSTIC_VALID", diagnostic.validate(), RDMA_SC_OK);
    expect_status("RUNTIME_VALID", runtime_desc.validate(), RDMA_SC_OK);

    key.profile_name = "";
    expect_status("KEY_EMPTY_PROFILE", key.validate(),
                  RDMA_SC_INVALID_ARGUMENT);
    key.profile_name = "generic_profile";
    key.variant = "";
    expect_status("KEY_EMPTY_VARIANT", key.validate(),
                  RDMA_SC_INVALID_ARGUMENT);
    key.variant = "query";
    key.profile_name = "generic|profile";
    expect_status("KEY_PROFILE_SEPARATOR", key.validate(),
                  RDMA_SC_INVALID_ARGUMENT);
    key.profile_name = "generic_profile";
    key.variant = "query|fast";
    expect_status("KEY_VARIANT_SEPARATOR", key.validate(),
                  RDMA_SC_INVALID_ARGUMENT);
    key.variant = "query";

    command.body = null;
    expect_status("COMMAND_NULL_BODY", command.validate(),
                  RDMA_SC_INVALID_ARGUMENT);
    command.body = body;
    body.command_id = 0;
    expect_status("COMMAND_INVALID_BODY", command.validate(),
                  RDMA_SC_INVALID_ARGUMENT);
    body.command_id = 64'h111;
    null_status_body = rdma_cmq_null_status_body::type_id::create(
      "null_status_body"
    );
    command.body = null_status_body;
    expect_status("COMMAND_NULL_BODY_STATUS", command.validate(),
                  RDMA_SC_INVALID_STATE);
    command.body = body;
    command.timeout = 0;
    expect_status("COMMAND_ZERO_TIMEOUT", command.validate(),
                  RDMA_SC_INVALID_ARGUMENT);
    command.timeout = 100;
    command.qpc_signature_source.function_generation++;
    expect_status("COMMAND_STALE_SIGNATURE", command.validate(),
                  RDMA_SC_STALE_GENERATION);
    command.qpc_signature_source.function_generation--;

    slot.sq_index = 32;
    expect_status("SLOT_INDEX", slot.validate(), RDMA_SC_INVALID_ARGUMENT);
    slot.sq_index = 5;
    slot.relative_offset = 64'd321;
    expect_status("SLOT_OFFSET", slot.validate(), RDMA_SC_INVALID_ARGUMENT);
    slot.relative_offset = 64'd320;
    slot.backing_addr.value++;
    expect_status("SLOT_ALIGNMENT", slot.validate(),
                  RDMA_SC_INVALID_ARGUMENT);
    slot.backing_addr.value--;
    slot.slot_sequence = 38;
    expect_status("SLOT_SEQUENCE", slot.validate(),
                  RDMA_SC_INVALID_ARGUMENT);
    slot.slot_sequence = 37;
    slot.cmq_h.generation++;
    expect_status("SLOT_STALE_CMQ", slot.validate(),
                  RDMA_SC_STALE_GENERATION);
    slot.cmq_h.generation--;
    slot.backing_addr.value = 64'hffff_ffff_ffff_ffc0;
    slot.relative_offset = 64'd320;
    expect_status("SLOT_ADDRESS_OVERFLOW", slot.validate(),
                  RDMA_SC_DMA_TRANSLATION);
    slot.backing_addr.value = 64'h0000_0000_4000_0000;

    expected.variant = "";
    expect_status("EXPECTED_EMPTY_VARIANT", expected.validate(),
                  RDMA_SC_INVALID_ARGUMENT);
    expected.variant = "query|fast";
    expect_status("EXPECTED_SEPARATOR", expected.validate(),
                  RDMA_SC_INVALID_ARGUMENT);
    expected.variant = "query";

    decoded.command_status = null;
    expect_status("DECODED_NULL_STATUS", decoded.validate(),
                  RDMA_SC_INVALID_ARGUMENT);
    decoded.command_status = rdma_status::success("decoded success");
    decoded.wqe_index = 32;
    expect_status("DECODED_INDEX", decoded.validate(),
                  RDMA_SC_INVALID_ARGUMENT);
    decoded.wqe_index = 5;

    ticket.command_id = 0;
    expect_status("TICKET_ZERO_ID", ticket.validate(),
                  RDMA_SC_INVALID_ARGUMENT);
    ticket.command_id = 64'h1234_0005;
    ticket.absolute_deadline = 0;
    expect_status("TICKET_ZERO_DEADLINE", ticket.validate(),
                  RDMA_SC_INVALID_ARGUMENT);
    ticket.absolute_deadline = 1000;
    ticket.sq_index = 32;
    expect_status("TICKET_INDEX", ticket.validate(),
                  RDMA_SC_INVALID_ARGUMENT);
    ticket.sq_index = 5;
    ticket.sq_wrap = 1'b0;
    expect_status("TICKET_WRAP", ticket.validate(),
                  RDMA_SC_INVALID_ARGUMENT);
    ticket.sq_wrap = 1'b1;

    completion.ticket = null;
    expect_status("COMPLETION_NULL_TICKET", completion.validate(),
                  RDMA_SC_INVALID_ARGUMENT);
    completion.ticket = ticket;
    completion.status = null;
    expect_status("COMPLETION_NULL_STATUS", completion.validate(),
                  RDMA_SC_INVALID_ARGUMENT);
    completion.status = rdma_status::success("hardware completion");
    completion.raw_cqe = null;
    expect_status("COMPLETION_SUCCESS_WITHOUT_CQE", completion.validate(),
                  RDMA_SC_INVALID_ARGUMENT);
    completion.status = rdma_status::make(RDMA_SC_TIMEOUT, "timed out");
    expect_status("COMPLETION_TIMEOUT_WITHOUT_CQE", completion.validate(),
                  RDMA_SC_OK);
    completion.status = rdma_status::make(
      RDMA_SC_RESET_CANCELLED, "reset cancellation"
    );
    expect_status("COMPLETION_RESET_WITHOUT_CQE", completion.validate(),
                  RDMA_SC_OK);
    completion.status = rdma_status::success("hardware completion");
    completion.raw_cqe = make_image(
      "completion_raw_cqe_restored", RDMA_IMAGE_CMQ_CQE, 64,
      TEST_GENERATION
    );
    completion.raw_cqe.alignment = 32;
    expect_status("COMPLETION_CQE_ALIGNMENT", completion.validate(),
                  RDMA_SC_INVALID_ARGUMENT);
    completion.raw_cqe.alignment = 64;
    completion.raw_cqe.function_generation++;
    expect_status("COMPLETION_CQE_GENERATION", completion.validate(),
                  RDMA_SC_STALE_GENERATION);
    completion.raw_cqe.function_generation--;

    diagnostic.status = null;
    expect_status("DIAGNOSTIC_NULL_STATUS", diagnostic.validate(),
                  RDMA_SC_INVALID_ARGUMENT);
    diagnostic.status = rdma_status::make(RDMA_SC_TIMEOUT,
                                          "late completion");
    diagnostic.raw_cqe = null;
    expect_status("DIAGNOSTIC_NULL_CQE", diagnostic.validate(),
                  RDMA_SC_INVALID_ARGUMENT);
    diagnostic.raw_cqe = completion.raw_cqe;
    diagnostic.kind = RDMA_CMQ_DIAG_UNKNOWN_CQE;
    diagnostic.ticket = null;
    expect_status("DIAGNOSTIC_UNKNOWN_WITHOUT_TICKET",
                  diagnostic.validate(), RDMA_SC_OK);
    diagnostic.kind = RDMA_CMQ_DIAG_LATE_COMPLETION;
    diagnostic.ticket = ticket;

    runtime_desc.sq_depth = 31;
    expect_status("RUNTIME_SQ_DEPTH", runtime_desc.validate(),
                  RDMA_SC_INVALID_ARGUMENT);
    runtime_desc.sq_depth = 32;
    runtime_desc.cq_depth = 31;
    expect_status("RUNTIME_CQ_DEPTH", runtime_desc.validate(),
                  RDMA_SC_INVALID_ARGUMENT);
    runtime_desc.cq_depth = 32;
    runtime_desc.entry_bytes = 32;
    expect_status("RUNTIME_ENTRY_BYTES", runtime_desc.validate(),
                  RDMA_SC_INVALID_ARGUMENT);
    runtime_desc.entry_bytes = 64;
    runtime_desc.cq_iova.value++;
    expect_status("RUNTIME_LAYOUT", runtime_desc.validate(),
                  RDMA_SC_INVALID_ARGUMENT);
    runtime_desc.cq_iova.value--;
    runtime_desc.sq_iova.value = 64'hffff_ffff_ffff_ffc0;
    expect_status("RUNTIME_SQ_ADD_OVERFLOW", runtime_desc.validate(),
                  RDMA_SC_DMA_TRANSLATION);
    runtime_desc.sq_iova.value = 64'h0000_0001_2000_0000;
    runtime_desc.cq_iova.value = 64'hffff_ffff_ffff_ffc0;
    expect_status("RUNTIME_CQ_ADD_OVERFLOW", runtime_desc.validate(),
                  RDMA_SC_DMA_TRANSLATION);
    runtime_desc.cq_iova.value = 64'h0000_0001_2000_0800;

    cloned_object = key.clone();
    if (!$cast(key_snapshot, cloned_object))
      `uvm_error("KEY_CLONE", "opcode key clone has wrong type")

    cloned_object = command.clone();
    if (!$cast(command_snapshot, cloned_object))
      `uvm_error("COMMAND_CLONE", "command clone has wrong type")

    cloned_object = slot.clone();
    if (!$cast(slot_snapshot, cloned_object))
      `uvm_error("SLOT_CLONE", "slot clone has wrong type")

    cloned_object = expected.clone();
    if (!$cast(expected_snapshot, cloned_object))
      `uvm_error("EXPECTED_CLONE", "expected response clone has wrong type")

    cloned_object = decoded.clone();
    if (!$cast(decoded_snapshot, cloned_object))
      `uvm_error("DECODED_CLONE", "decoded CQE clone has wrong type")

    cloned_object = ticket.clone();
    if (!$cast(ticket_snapshot, cloned_object))
      `uvm_error("TICKET_CLONE", "ticket clone has wrong type")

    cloned_object = completion.clone();
    if (!$cast(completion_snapshot, cloned_object))
      `uvm_error("COMPLETION_CLONE", "completion clone has wrong type")

    cloned_object = diagnostic.clone();
    if (!$cast(diagnostic_snapshot, cloned_object))
      `uvm_error("DIAGNOSTIC_CLONE", "diagnostic clone has wrong type")

    cloned_object = runtime_desc.clone();
    if (!$cast(runtime_snapshot, cloned_object))
      `uvm_error("RUNTIME_CLONE", "runtime descriptor clone has wrong type")

    if (command_snapshot != null) begin
      if (command_snapshot.function_h == command.function_h ||
          command_snapshot.opcode_key == command.opcode_key ||
          command_snapshot.body == command.body ||
          command_snapshot.qpc_signature_source ==
            command.qpc_signature_source)
        `uvm_error("COMMAND_DEEP_COPY",
                   "command nested objects alias the source")
      if (!$cast(body_snapshot, command_snapshot.body))
        `uvm_error("COMMAND_DEEP_COPY", "command body clone lost type")
    end
    if (slot_snapshot != null &&
        (slot_snapshot.function_h == slot.function_h ||
         slot_snapshot.cmq_h == slot.cmq_h))
      `uvm_error("SLOT_DEEP_COPY", "slot handles alias the source")
    if (decoded_snapshot != null) begin
      if (decoded_snapshot.command_status == decoded.command_status ||
          decoded_snapshot.response_payload == decoded.response_payload)
        `uvm_error("DECODED_DEEP_COPY",
                   "decoded CQE nested objects alias the source")
      if (!$cast(response_payload_snapshot,
                 decoded_snapshot.response_payload))
        `uvm_error("DECODED_DEEP_COPY",
                   "decoded response payload clone lost type")
    end
    if (ticket_snapshot != null &&
        (ticket_snapshot.function_h == ticket.function_h ||
         ticket_snapshot.cmq_h == ticket.cmq_h ||
         ticket_snapshot.opcode_key == ticket.opcode_key))
      `uvm_error("TICKET_DEEP_COPY", "ticket nested objects alias source")
    if (completion_snapshot != null) begin
      if (completion_snapshot.ticket == completion.ticket ||
          completion_snapshot.status == completion.status ||
          completion_snapshot.raw_cqe == completion.raw_cqe ||
          completion_snapshot.decoded_response ==
            completion.decoded_response)
        `uvm_error("COMPLETION_DEEP_COPY",
                   "completion nested objects alias the source")
      if (!$cast(decoded_response_snapshot,
                 completion_snapshot.decoded_response))
        `uvm_error("COMPLETION_DEEP_COPY",
                   "completion decoded response clone lost type")
    end
    if (diagnostic_snapshot != null &&
        (diagnostic_snapshot.ticket == diagnostic.ticket ||
         diagnostic_snapshot.status == diagnostic.status ||
         diagnostic_snapshot.raw_cqe == diagnostic.raw_cqe))
      `uvm_error("DIAGNOSTIC_DEEP_COPY",
                 "diagnostic nested objects alias the source")
    if (runtime_snapshot != null &&
        (runtime_snapshot.function_h == runtime_desc.function_h ||
         runtime_snapshot.cmq_h == runtime_desc.cmq_h))
      `uvm_error("RUNTIME_DEEP_COPY",
                 "runtime descriptor handles alias the source")

    function_h.generation++;
    cmq_h.object_id++;
    key.profile_name = "mutated_profile";
    key.variant = "mutated_variant";
    body.command_id++;
    command.qpc_signature_source.bytes[0] = 8'h00;
    decoded.command_status.message = "mutated decoded status";
    response_payload.transport_version++;
    completion.status.message = "mutated completion status";
    completion.raw_cqe.bytes[0] = 8'h00;
    decoded_response.transport_version++;
    diagnostic.status.message = "mutated diagnostic status";

    if (key_snapshot == null ||
        key_snapshot.profile_name != "generic_profile" ||
        key_snapshot.variant != "query" ||
        key_snapshot.opcode != 32'hff00_abcd)
      `uvm_error("KEY_SNAPSHOT", "opcode key snapshot changed")
    if (command_snapshot == null ||
        command_snapshot.function_h.generation != TEST_GENERATION ||
        command_snapshot.opcode_key.profile_name != "generic_profile" ||
        command_snapshot.qpc_signature_source.bytes[0] != 8'h5a ||
        body_snapshot == null || body_snapshot.command_id != 64'h111 ||
        command_snapshot.vfid_override != 1'b1 ||
        command_snapshot.use_vfid != 11'h345 ||
        command_snapshot.timeout != 100)
      `uvm_error("COMMAND_SNAPSHOT", "command snapshot changed")
    if (slot_snapshot == null ||
        slot_snapshot.function_h.generation != TEST_GENERATION ||
        slot_snapshot.cmq_h.object_id != 32'h55 ||
        slot_snapshot.backing_addr.value != 64'h0000_0000_4000_0000 ||
        slot_snapshot.relative_offset != 320 ||
        slot_snapshot.slot_sequence != 37 || slot_snapshot.sq_index != 5 ||
        slot_snapshot.sq_wrap != 1'b1)
      `uvm_error("SLOT_SNAPSHOT", "slot snapshot changed")
    if (expected_snapshot == null ||
        expected_snapshot.hardware_opcode != 32'hff00_abcd ||
        expected_snapshot.variant != "query")
      `uvm_error("EXPECTED_SNAPSHOT",
                 "expected response snapshot changed")
    if (decoded_snapshot == null ||
        decoded_snapshot.command_status.message != "decoded success" ||
        response_payload_snapshot == null ||
        response_payload_snapshot.transport_version != 1 ||
        decoded_snapshot.hardware_opcode != 32'hff00_abcd ||
        decoded_snapshot.wqe_index != 5 ||
        decoded_snapshot.wqe_wrap != 1'b1 ||
        decoded_snapshot.hardware_ecode != 32'ha5)
      `uvm_error("DECODED_SNAPSHOT", "decoded CQE snapshot changed")
    if (ticket_snapshot == null ||
        ticket_snapshot.function_h.generation != TEST_GENERATION ||
        ticket_snapshot.cmq_h.object_id != 32'h55 ||
        ticket_snapshot.opcode_key.variant != "query" ||
        ticket_snapshot.command_id != 64'h1234_0005 ||
        ticket_snapshot.absolute_deadline != 1000)
      `uvm_error("TICKET_SNAPSHOT", "ticket snapshot changed")
    if (completion_snapshot == null ||
        completion_snapshot.ticket.function_h.generation !=
          TEST_GENERATION ||
        completion_snapshot.status.message != "hardware completion" ||
        completion_snapshot.raw_cqe.bytes[0] != 8'h5a ||
        decoded_response_snapshot == null ||
        decoded_response_snapshot.transport_version != 2)
      `uvm_error("COMPLETION_SNAPSHOT", "completion snapshot changed")
    if (diagnostic_snapshot == null ||
        diagnostic_snapshot.ticket.function_h.generation !=
          TEST_GENERATION ||
        diagnostic_snapshot.status.message != "late completion" ||
        diagnostic_snapshot.raw_cqe.bytes[0] != 8'h5a ||
        diagnostic_snapshot.kind != RDMA_CMQ_DIAG_LATE_COMPLETION)
      `uvm_error("DIAGNOSTIC_SNAPSHOT", "diagnostic snapshot changed")
    if (runtime_snapshot == null ||
        runtime_snapshot.function_h.generation != TEST_GENERATION ||
        runtime_snapshot.cmq_h.object_id != 32'h55 ||
        runtime_snapshot.sq_iova.value != 64'h0000_0001_2000_0000 ||
        runtime_snapshot.cq_iova.value != 64'h0000_0001_2000_0800 ||
        runtime_snapshot.sq_depth != 32 || runtime_snapshot.cq_depth != 32 ||
        runtime_snapshot.entry_bytes != 64 ||
        runtime_snapshot.initial_sq_valid != 1'b1 ||
        runtime_snapshot.initial_cq_owner != 1'b1 ||
        runtime_snapshot.initial_doorbell_polarity != 1'b0)
      `uvm_error("RUNTIME_SNAPSHOT", "runtime descriptor snapshot changed")

    phase.drop_objection(this);
  endtask
endclass
