// 中文说明：rdma_xtr_v1_cmq_completion_test.sv 属于单元测试，覆盖对应模型、编码器或执行器契约。
// 阅读提示：先看公开类型和接口，再看实现细节；失败路径应保持状态与资源所有权可追踪。

class rdma_xtr_v1_cmq_completion_test extends uvm_test;
  `uvm_component_utils(rdma_xtr_v1_cmq_completion_test)

  rdma_xtr_v1_cmq_completion_codec codec;

  function new(string name = "rdma_xtr_v1_cmq_completion_test",
               uvm_component parent = null);
    super.new(name, parent);
  endfunction

  function automatic void expect_status(
    string label,
    rdma_status status,
    rdma_status_code_e expected
  );
    if (status == null)
      `uvm_error(label, "completion decoder returned a null status")
    else if (status.code != expected)
      `uvm_error(label,
                 $sformatf("expected %s, got %s (%s)", expected.name(),
                           status.code.name(), status.convert2string()))
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

  function automatic rdma_hw_image make_image(
    bit [7:0] opcode,
    bit [7:0] command_ecode = 8'h00,
    bit [4:0] wqe_index = 5'h1b,
    bit wrap = 1'b1,
    bit owner = 1'b1
  );
    rdma_hw_image image;
    bit [63:0] qword0;
    image = rdma_hw_image::type_id::create("cmq_completion_image");
    repeat (64) image.bytes.push_back(8'h00);
    image.length = 64;
    image.alignment = 64;
    image.endian = RDMA_ENDIAN_BIG;
    image.image_kind = RDMA_IMAGE_CMQ_CQE;
    image.hardware_version = 1;
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
    return image;
  endfunction

  function automatic rdma_hw_image clone_image(
    rdma_hw_image source,
    string name
  );
    rdma_hw_image clone;
    clone = rdma_hw_image::type_id::create(name);
    clone.copy(source);
    return clone;
  endfunction

  function automatic void expect_image_unchanged(
    string label,
    rdma_hw_image actual,
    rdma_hw_image expected
  );
    if (actual == null || expected == null) begin
      `uvm_error(label, "image comparison received null")
      return;
    end
    if (actual.length != expected.length ||
        actual.alignment != expected.alignment ||
        actual.endian != expected.endian ||
        actual.image_kind != expected.image_kind ||
        actual.hardware_version != expected.hardware_version ||
        actual.function_generation != expected.function_generation ||
        actual.write_target_kind != expected.write_target_kind ||
        actual.backing_target.value != expected.backing_target.value ||
        actual.hmc_target.value != expected.hmc_target.value ||
        actual.bar_target.value != expected.bar_target.value ||
        actual.bytes.size() != expected.bytes.size() ||
        actual.field_summary.size() != expected.field_summary.size()) begin
      `uvm_error(label, "completion decoder mutated image metadata")
      return;
    end
    foreach (actual.bytes[i])
      if (actual.bytes[i] != expected.bytes[i]) begin
        `uvm_error(label, $sformatf("image byte %0d changed", i))
        return;
      end
    foreach (actual.field_summary[i])
      if (actual.field_summary[i] != expected.field_summary[i]) begin
        `uvm_error(label, $sformatf("field summary %0d changed", i))
        return;
      end
  endfunction

  // Independent driver-derived oracle.  It intentionally does not call any
  // codec mask/helper: qword 0 owns owner bit 63 and bits 45:24;
  // returned-object bytes are opened only for admitted query opcodes.
  function automatic bit [63:0] literal_allowed_mask(
    bit [7:0] opcode,
    int unsigned qword_index
  );
    if (qword_index == 0)
      return 64'h8000_3fff_ff00_0000;
    case (opcode)
      8'h0f: return 64'hffff_ffff_ffff_ffff; // CQC bytes 8..63
      8'h09:
        if (qword_index inside {[2:7]})
          return 64'hffff_ffff_ffff_ffff; // MRT bytes 16..63
      8'h13, 8'h17, 8'h38:
        if (qword_index inside {[2:5]})
          return 64'hffff_ffff_ffff_ffff; // EQC/SRFQC bytes 16..47
      default: return 64'h0000_0000_0000_0000;
    endcase
    return 64'h0000_0000_0000_0000;
  endfunction

  function automatic void literal_payload_bounds(
    bit [7:0] opcode,
    output int unsigned first_byte,
    output int unsigned byte_count
  );
    first_byte = 0;
    byte_count = 0;
    case (opcode)
      8'h09: begin first_byte = 16; byte_count = 48; end
      8'h0f: begin first_byte = 8; byte_count = 56; end
      8'h13, 8'h17, 8'h38: begin
        first_byte = 16;
        byte_count = 32;
      end
      default: begin first_byte = 0; byte_count = 0; end
    endcase
  endfunction

  function automatic void expect_decode_success(
    string label,
    rdma_hw_image image,
    bit expected_owner,
    int unsigned expected_first_byte,
    int unsigned expected_payload_length
  );
    rdma_xtr_v1_cmq_completion completion;
    rdma_hw_image snapshot;
    rdma_status status;
    bit [63:0] qword0;
    bit ready;
    snapshot = clone_image(image, {label, "_snapshot"});
    completion = null;
    ready = 1'b0;
    status = codec.inspect_completion(image, expected_owner, ready,
                                      completion);
    expect_status({label, "_STATUS"}, status, RDMA_SC_OK);
    if (!ready)
      `uvm_error(label, "matching owner was not reported ready")
    else if (completion == null)
      `uvm_error(label, "successful decode published null")
    else begin
      qword0 = get_qword(image, 0);
      if (completion.owner != expected_owner ||
          completion.opcode != qword0[39:32] ||
          completion.command_ecode != qword0[31:24] ||
          completion.wqe_index != qword0[44:40] ||
          completion.wrap != qword0[45])
        `uvm_error(label, "successful decode changed a common field")
      if (completion.object_payload.size() != expected_payload_length)
        `uvm_error(label, $sformatf(
          "expected payload length %0d, got %0d", expected_payload_length,
          completion.object_payload.size()))
      else
        foreach (completion.object_payload[i])
          if (completion.object_payload[i] !=
              image.bytes[expected_first_byte + i]) begin
            `uvm_error(label, $sformatf("payload byte %0d changed", i))
            break;
          end
    end
    expect_image_unchanged({label, "_IMMUTABLE"}, image, snapshot);
  endfunction

  function automatic void expect_decode_failure(
    string label,
    rdma_hw_image image,
    bit expected_owner,
    rdma_status_code_e expected_status = RDMA_SC_CODEC_ERROR,
    bit expected_ready = 1'b0
  );
    rdma_xtr_v1_cmq_completion completion;
    rdma_hw_image snapshot;
    rdma_status status;
    bit ready;
    completion = rdma_xtr_v1_cmq_completion::type_id::create(
      {label, "_stale_completion"});
    snapshot = (image == null) ? null : clone_image(image, {label, "_snapshot"});
    ready = 1'b1;
    status = codec.inspect_completion(image, expected_owner, ready,
                                      completion);
    expect_status(label, status, expected_status);
    if (ready != expected_ready)
      `uvm_error(label, $sformatf(
        "failure ready mismatch: expected %0b got %0b",
        expected_ready, ready))
    if (completion != null)
      `uvm_error(label, "structural decode failure published completion")
    if (image != null)
      expect_image_unchanged({label, "_IMMUTABLE"}, image, snapshot);
  endfunction

  function automatic void check_common_fields_and_raw_ecode();
    rdma_hw_image image;
    rdma_hw_image snapshot;
    rdma_xtr_v1_cmq_completion completion;
    rdma_xtr_v1_cmq_completion copied;
    rdma_status status;
    bit ready;
    image = make_image(8'h00, 8'h45, 5'h1b, 1'b1);
    snapshot = clone_image(image, "common_snapshot");
    completion = null;
    ready = 1'b0;
    status = codec.inspect_completion(image, 1'b1, ready, completion);
    expect_status("CQE_COMMON_STATUS", status, RDMA_SC_OK);
    if (!ready || completion == null)
      `uvm_error("CQE_COMMON", "successful decode published null")
    else begin
      if (completion.owner != 1'b1 || completion.opcode != 8'h00 ||
          completion.command_ecode != 8'h45 ||
          completion.wqe_index != 5'h1b || completion.wrap != 1'b1)
        `uvm_error("CQE_COMMON", "common completion fields changed")
      if (completion.object_payload.size() != 0)
        `uvm_error("CQE_COMMON", "non-return command published payload")
      copied = rdma_xtr_v1_cmq_completion::type_id::create(
        "copied_completion");
      copied.copy(completion);
      if (copied.owner != completion.owner)
        `uvm_error("CQE_COMMON_COPY", "completion copy lost owner")
    end
    expect_image_unchanged("CQE_COMMON_IMMUTABLE", image, snapshot);
  endfunction

  function automatic void check_payload_slice(
    string label,
    bit [7:0] opcode,
    int unsigned first_byte,
    int unsigned last_byte
  );
    rdma_hw_image image;
    rdma_hw_image snapshot;
    rdma_xtr_v1_cmq_completion completion;
    rdma_status status;
    bit ready;
    int unsigned expected_length;
    image = make_image(opcode, 8'h00, 5'h03, 1'b0);
    for (int unsigned i = first_byte; i <= last_byte; i++)
      image.bytes[i] = i;
    snapshot = clone_image(image, {label, "_snapshot"});
    completion = null;
    ready = 1'b0;
    status = codec.inspect_completion(image, 1'b1, ready, completion);
    expect_status({label, "_STATUS"}, status, RDMA_SC_OK);
    if (!ready || completion == null) begin
      `uvm_error(label, "successful payload decode published null")
      return;
    end
    expected_length = last_byte - first_byte + 1;
    if (completion.object_payload.size() != expected_length)
      `uvm_error(label,
                 $sformatf("expected payload length %0d, got %0d",
                           expected_length, completion.object_payload.size()))
    else begin
      if (completion.object_payload[0] != first_byte[7:0])
        `uvm_error(label, "payload first-byte boundary is wrong")
      if (completion.object_payload[expected_length - 1] != last_byte[7:0])
        `uvm_error(label, "payload last-byte boundary is wrong")
      foreach (completion.object_payload[i])
        if (completion.object_payload[i] != (first_byte + i)) begin
          `uvm_error(label, $sformatf("payload byte %0d is not exact", i))
          break;
        end
    end
    expect_image_unchanged({label, "_IMMUTABLE"}, image, snapshot);
  endfunction

  function automatic void check_metadata_failures();
    rdma_hw_image image;
    expect_decode_failure("CQE_NULL", null, 1'b1, RDMA_SC_CODEC_ERROR,
                          1'b0);

    image = make_image(8'h00, 0, 0, 0);
    image.length = 63;
    expect_decode_failure("CQE_LENGTH", image, 1'b1, RDMA_SC_CODEC_ERROR,
                          1'b0);
    image = make_image(8'h00, 0, 0, 0);
    void'(image.bytes.pop_back());
    expect_decode_failure("CQE_BYTE_SIZE", image, 1'b1,
                          RDMA_SC_CODEC_ERROR, 1'b0);
    image = make_image(8'h00, 0, 0, 0);
    image.image_kind = RDMA_IMAGE_CMQ_SQE;
    expect_decode_failure("CQE_KIND", image, 1'b1, RDMA_SC_CODEC_ERROR,
                          1'b0);
    image = make_image(8'h00, 0, 0, 0);
    image.hardware_version = 2;
    expect_decode_failure("CQE_VERSION", image, 1'b1, RDMA_SC_CODEC_ERROR,
                          1'b0);
    image = make_image(8'h00, 0, 0, 0);
    image.endian = RDMA_ENDIAN_LITTLE;
    expect_decode_failure("CQE_ENDIAN", image, 1'b1, RDMA_SC_CODEC_ERROR,
                          1'b0);
    image = make_image(8'h00, 0, 0, 0);
    image.alignment = 8;
    expect_decode_failure("CQE_ALIGNMENT", image, 1'b1,
                          RDMA_SC_CODEC_ERROR, 1'b0);
    image = make_image(8'h00, 0, 0, 0);
    image.write_target_kind = RDMA_HW_TARGET_BAR;
    expect_decode_failure("CQE_TARGET_KIND", image, 1'b1,
                          RDMA_SC_CODEC_ERROR, 1'b0);
    image = make_image(8'h00, 0, 0, 0);
    image.backing_target.value = 64'h1000;
    expect_decode_failure("CQE_BACKING_TARGET", image, 1'b1,
                          RDMA_SC_CODEC_ERROR, 1'b0);
    image = make_image(8'h00, 0, 0, 0);
    image.hmc_target.value = 64'h2000;
    expect_decode_failure("CQE_HMC_TARGET", image, 1'b1,
                          RDMA_SC_CODEC_ERROR, 1'b0);
    image = make_image(8'h00, 0, 0, 0);
    image.bar_target.value = 64'h3000;
    expect_decode_failure("CQE_BAR_TARGET", image, 1'b1,
                          RDMA_SC_CODEC_ERROR, 1'b0);
  endfunction

  function automatic void check_owner_ready_ordering();
    rdma_hw_image image;
    rdma_xtr_v1_cmq_completion completion;
    rdma_status status;
    bit [63:0] word;
    bit ready;

    // A stale entry may contain arbitrary payload.  Once metadata/qword 0 are
    // readable, owner mismatch must return empty without interpreting it.
    image = make_image(8'hfe, 8'hff, 5'h1f, 1'b1, 1'b0);
    word = get_qword(image, 7);
    word[3] = 1'b1;
    set_qword(image, 7, word);
    completion = rdma_xtr_v1_cmq_completion::type_id::create(
      "stale_owner_completion");
    ready = 1'b1;
    status = codec.inspect_completion(image, 1'b1, ready, completion);
    expect_status("CQE_OWNER_MISMATCH_STATUS", status, RDMA_SC_OK);
    if (ready || completion != null)
      `uvm_error("CQE_OWNER_MISMATCH",
                 "stale owner published readiness or a completion")

    image = make_image(8'hfe, 0, 0, 0, 1'b1);
    expect_decode_failure("CQE_UNKNOWN_OPCODE", image, 1'b1,
                          RDMA_SC_UNSUPPORTED_OPCODE);
  endfunction

  function automatic void check_literal_admission_table();
    bit [7:0] supported[$] = '{
      8'h00, 8'h01, 8'h02, 8'h03, 8'h04, 8'h05, 8'h06,
      8'h0a, 8'h0c, 8'h0e, 8'h0f, 8'h10, 8'h12, 8'h13,
      8'h14, 8'h16, 8'h17, 8'h20, 8'h35, 8'h37, 8'h38,
      8'h09
    };
    bit [7:0] unsupported[$] = '{8'h07, 8'h1a, 8'hfe};
    rdma_hw_image image;
    int unsigned first_byte;
    int unsigned byte_count;
    foreach (supported[i]) begin
      image = make_image(supported[i], 0, 0, 0);
      literal_payload_bounds(supported[i], first_byte, byte_count);
      expect_decode_success(
        $sformatf("CQE_ADMISSION_%02x", supported[i]), image, 1'b1,
        first_byte, byte_count);
    end
    foreach (unsupported[i]) begin
      image = make_image(unsupported[i], 0, 0, 0);
      expect_decode_failure(
        $sformatf("CQE_UNSUPPORTED_%02x", unsupported[i]), image,
        1'b1, RDMA_SC_UNSUPPORTED_OPCODE);
    end
  endfunction

  function automatic void check_every_reserved_bit();
    bit [7:0] opcodes[$] = '{8'h00, 8'h0f, 8'h09,
                              8'h13, 8'h17, 8'h38};
    rdma_hw_image image;
    bit [63:0] allowed;
    bit [63:0] word;
    foreach (opcodes[o]) begin
      for (int unsigned q = 0; q < 8; q++) begin
        allowed = literal_allowed_mask(opcodes[o], q);
        for (int unsigned b = 0; b < 64; b++) begin
          if (allowed[b]) continue;
          image = make_image(opcodes[o], 0, 0, 0);
          word = get_qword(image, q);
          word[b] = 1'b1;
          set_qword(image, q, word);
          expect_decode_failure(
            $sformatf("CQE_RESERVED_%02x_Q%0d_B%0d", opcodes[o], q, b),
            image, 1'b1
          );
        end
      end
    end
  endfunction

  function automatic void check_every_allowed_data_bit();
    bit [7:0] payload_opcodes[$] = '{8'h09, 8'h0f,
                                      8'h13, 8'h17, 8'h38};
    rdma_hw_image image;
    bit [63:0] allowed;
    bit [63:0] word;
    int unsigned first_byte;
    int unsigned byte_count;

    for (int unsigned b = 24; b <= 31; b++) begin
      image = make_image(8'h00, 0, 0, 0);
      word = get_qword(image, 0);
      word[b] = 1'b1;
      set_qword(image, 0, word);
      expect_decode_success($sformatf("CQE_ALLOWED_ECODE_B%0d", b), image,
                            1'b1, 0, 0);
    end
    for (int unsigned b = 40; b <= 44; b++) begin
      image = make_image(8'h00, 0, 0, 0);
      word = get_qword(image, 0);
      word[b] = 1'b1;
      set_qword(image, 0, word);
      expect_decode_success($sformatf("CQE_ALLOWED_INDEX_B%0d", b), image,
                            1'b1, 0, 0);
    end
    image = make_image(8'h00, 0, 0, 0, 1'b1);
    expect_decode_success("CQE_ALLOWED_OWNER", image, 1'b1, 0, 0);

    foreach (payload_opcodes[o]) begin
      literal_payload_bounds(payload_opcodes[o], first_byte, byte_count);
      for (int unsigned q = 1; q < 8; q++) begin
        allowed = literal_allowed_mask(payload_opcodes[o], q);
        for (int unsigned b = 0; b < 64; b++) begin
          if (!allowed[b]) continue;
          image = make_image(payload_opcodes[o], 0, 0, 0);
          word = get_qword(image, q);
          word[b] = 1'b1;
          set_qword(image, q, word);
          expect_decode_success(
            $sformatf("CQE_ALLOWED_PAYLOAD_%02x_Q%0d_B%0d",
                      payload_opcodes[o], q, b),
            image, 1'b1, first_byte, byte_count);
        end
      end
    end
  endfunction

  virtual task run_phase(uvm_phase phase);
    phase.raise_objection(this);
    codec = rdma_xtr_v1_cmq_completion_codec::type_id::create(
      "cmq_completion_codec");
    check_common_fields_and_raw_ecode();
    check_payload_slice("CQE_MRT_QUERY_SLICE", 8'h09, 16, 63);
    check_payload_slice("CQE_CQC_QUERY_SLICE", 8'h0f, 8, 63);
    check_payload_slice("CQE_CEQC_QUERY_SLICE", 8'h13, 16, 47);
    check_payload_slice("CQE_AEQC_QUERY_SLICE", 8'h17, 16, 47);
    check_payload_slice("CQE_SRFQC_QUERY_SLICE", 8'h38, 16, 47);
    check_metadata_failures();
    check_owner_ready_ordering();
    check_literal_admission_table();
    check_every_reserved_bit();
    check_every_allowed_data_bit();
    phase.drop_objection(this);
  endtask
endclass
