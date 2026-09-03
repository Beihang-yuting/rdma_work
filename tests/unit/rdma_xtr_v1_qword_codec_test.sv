// 中文说明：rdma_xtr_v1_qword_codec_test.sv 属于单元测试，覆盖对应模型、编码器或执行器契约。
// 阅读提示：先看公开类型和接口，再看实现细节；失败路径应保持状态与资源所有权可追踪。

class rdma_xtr_v1_qword_codec_test extends uvm_test;
  `uvm_component_utils(rdma_xtr_v1_qword_codec_test)

  function new(string name = "rdma_xtr_v1_qword_codec_test",
               uvm_component parent = null);
    super.new(name, parent);
  endfunction

  function automatic void expect_status(
    string label,
    rdma_status status,
    rdma_status_code_e expected_code
  );
    if (status == null) begin
      `uvm_error(label, "qword codec returned a null status")
      return;
    end
    if (status.code != expected_code)
      `uvm_error(label,
                 $sformatf("expected %s, got %s (%s)",
                           expected_code.name(), status.code.name(),
                           status.convert2string()))
  endfunction

  function automatic void expect_ok(string label, rdma_status status);
    expect_status(label, status, RDMA_SC_OK);
  endfunction

  function automatic bit qwords_equal(
    bit [63:0] lhs[],
    bit [63:0] rhs[]
  );
    if (lhs.size() != rhs.size())
      return 1'b0;
    foreach (lhs[i]) begin
      if (lhs[i] != rhs[i])
        return 1'b0;
    end
    return 1'b1;
  endfunction

  function automatic bit bytes_equal(
    byte unsigned lhs[],
    byte unsigned rhs[]
  );
    if (lhs.size() != rhs.size())
      return 1'b0;
    foreach (lhs[i]) begin
      if (lhs[i] != rhs[i])
        return 1'b0;
    end
    return 1'b1;
  endfunction

  function automatic void snapshot_builder(
    rdma_xtr_v1_qword_builder builder,
    output bit [63:0] words[],
    output bit [63:0] occupancy[]
  );
    builder.get_words(words);
    builder.get_occupancy(occupancy);
  endfunction

  function automatic void expect_builder_unchanged(
    string label,
    rdma_xtr_v1_qword_builder builder,
    bit [63:0] expected_words[],
    bit [63:0] expected_occupancy[]
  );
    bit [63:0] actual_words[];
    bit [63:0] actual_occupancy[];

    snapshot_builder(builder, actual_words, actual_occupancy);
    if (!qwords_equal(actual_words, expected_words))
      `uvm_error(label, "failure changed logical qword size/content")
    if (!qwords_equal(actual_occupancy, expected_occupancy))
      `uvm_error(label, "failure changed qword occupancy")
  endfunction

  function automatic void check_supported_masks();
    rdma_image_kind_e image_kinds[8] = '{
      RDMA_IMAGE_CQC,
      RDMA_IMAGE_MRT, RDMA_IMAGE_MRT, RDMA_IMAGE_MRT, RDMA_IMAGE_MRT,
      RDMA_IMAGE_SRQC, RDMA_IMAGE_CEQC, RDMA_IMAGE_AEQC
    };
    bit [7:0] opcodes[8] = '{
      XTR_V1_OP_CQC_CREATE,
      XTR_V1_OP_KEY_ALLOC, XTR_V1_OP_MR_REGISTER,
      XTR_V1_OP_MR_REGISTER, XTR_V1_OP_MR_REGISTER,
      XTR_V1_OP_SRFQC_CREATE, XTR_V1_OP_CEQC_CREATE,
      XTR_V1_OP_AEQC_CREATE
    };
    rdma_mr_pbl_mode_e pbl_modes[8] = '{
      RDMA_MR_PBL0, RDMA_MR_PBL0, RDMA_MR_PBL0, RDMA_MR_PBL1,
      RDMA_MR_PBL2, RDMA_MR_PBL0, RDMA_MR_PBL0, RDMA_MR_PBL0
    };
    string labels[8] = '{
      "CQC_CREATE", "MRT_KEY_ALLOC_PBL0", "MRT_REGISTER_PBL0",
      "MRT_REGISTER_PBL1", "MRT_REGISTER_PBL2", "SRQC_CREATE",
      "CEQC_CREATE", "AEQC_CREATE"
    };
    rdma_xtr_v1_qword_builder builder;
    rdma_status status;
    bit [63:0] mask;

    foreach (image_kinds[case_index]) begin
      builder = new({"mask_builder_", labels[case_index]});
      expect_ok({labels[case_index], "_RESET"}, builder.reset(64));
      // Bit zero is body-owned for every supported identity.  Using it keeps
      // this a real state validation rather than a vacuous all-zero check.
      expect_ok({labels[case_index], "_BODY_BIT"},
                builder.put_field(0, 0, 1, 1));
      status = builder.validate_allowed_mask(image_kinds[case_index],
                                             opcodes[case_index],
                                             pbl_modes[case_index]);
      expect_ok({labels[case_index], "_VALIDATE"}, status);

      // Independently prove the complete body identity is disjoint from the
      // request envelope coordinates consumed by validate_allowed_mask().
      for (int unsigned qword_index = 0; qword_index < 8;
           qword_index++) begin
        mask = '1;
        if (!body_mask(image_kinds[case_index], opcodes[case_index],
                       pbl_modes[case_index], qword_index, mask)) begin
          `uvm_error("MASK_DISJOINT",
                     $sformatf("%s qword %0d lookup failed",
                               labels[case_index], qword_index))
        end else if ((mask & request_envelope_mask(qword_index)) != 0) begin
          `uvm_error("MASK_DISJOINT",
                     $sformatf("%s qword %0d overlaps request envelope",
                               labels[case_index], qword_index))
        end
      end
    end
  endfunction

  task run_phase(uvm_phase phase);
    rdma_xtr_v1_qword_builder builder;
    rdma_xtr_v1_qword_builder decoded;
    rdma_xtr_v1_qword_builder empty_builder;
    rdma_xtr_v1_qword_builder overwrite_builder;
    rdma_xtr_v1_qword_builder crossing_builder;
    rdma_xtr_v1_qword_builder late_overlap_builder;
    rdma_xtr_v1_qword_builder zero_field_builder;
    rdma_xtr_v1_qword_builder size_builder;
    rdma_xtr_v1_qword_builder clone_source;
    rdma_xtr_v1_qword_builder clone_copy;
    uvm_object cloned_object;
    rdma_status status;
    byte unsigned memcpy_bytes[];
    byte unsigned zero_byte[];
    byte unsigned overlap_byte[];
    byte unsigned bytes[];
    byte unsigned expected_bytes[];
    byte unsigned byte_snapshot[];
    byte unsigned invalid_bytes[];
    byte unsigned all_ff_bytes[];
    byte unsigned overwritten_bytes[];
    byte unsigned crossing_bytes[];
    byte unsigned crossing_serialized[];
    byte unsigned crossing_expected[];
    byte unsigned late_overlap_bytes[];
    byte unsigned late_serialized_before[];
    byte unsigned late_serialized_after[];
    byte unsigned oversized_bytes[];
    byte unsigned oversized_snapshot[];
    bit [63:0] words[];
    bit [63:0] occupancy[];
    bit [63:0] words_before[];
    bit [63:0] occupancy_before[];
    bit [63:0] decoded_words[];
    bit [63:0] decoded_occupancy[];
    bit [63:0] field_value;
    bit [63:0] mask_value;

    phase.raise_objection(this);

    // FIELD_PREP operates on logical qwords.  Serialization alone decides
    // their final big-endian byte order.
    builder = new("builder");
    expect_ok("RESET", builder.reset(16));
    expect_ok("LOW_FIELD", builder.put_field(0, 0, 16, 16'h1234));
    expect_ok("HIGH_FIELD", builder.put_field(0, 56, 8, 8'hab));
    memcpy_bytes = '{8'hde, 8'had, 8'hbe, 8'hef};
    expect_ok("MEMCPY", builder.put_memcpy(8, memcpy_bytes));
    expect_ok("SERIALIZE", builder.serialize(bytes));
    expected_bytes = '{
      8'hab,8'h00,8'h00,8'h00,8'h00,8'h00,8'h12,8'h34,
      8'hde,8'had,8'hbe,8'hef,8'h00,8'h00,8'h00,8'h00
    };
    if (!bytes_equal(bytes, expected_bytes))
      `uvm_error("BE_QWORD", "logical qword did not serialize big-endian")

    snapshot_builder(builder, words, occupancy);
    if (words.size() != 2 ||
        words[0] != 64'hab00_0000_0000_1234 ||
        words[1] != 64'hdead_beef_0000_0000)
      `uvm_error("LOGICAL_WORDS", "unexpected logical qword content")
    if (occupancy.size() != 2 ||
        occupancy[0] != 64'hff00_0000_0000_ffff ||
        occupancy[1] != 64'hffff_ffff_0000_0000)
      `uvm_error("LOGICAL_OCCUPANCY", "unexpected qword occupancy")

    // Returned arrays are copies, not aliases into builder state.
    words[0] = '1;
    occupancy[0] = '0;
    builder.get_words(decoded_words);
    builder.get_occupancy(decoded_occupancy);
    if (decoded_words[0] != 64'hab00_0000_0000_1234 ||
        decoded_occupancy[0] != 64'hff00_0000_0000_ffff)
      `uvm_error("COPY_ACCESSORS", "caller mutated builder through accessor")

    // Deserialize is the inverse of qword big-endian serialization.  Input
    // bytes are decoded data, so they do not claim authored occupancy.
    decoded = new("decoded");
    expect_ok("DESERIALIZE", decoded.deserialize(bytes));
    decoded.get_words(decoded_words);
    decoded.get_occupancy(decoded_occupancy);
    if (decoded_words.size() != 2 ||
        decoded_words[0] != 64'hab00_0000_0000_1234 ||
        decoded_words[1] != 64'hdead_beef_0000_0000)
      `uvm_error("DESERIALIZE_WORDS", "big-endian inverse mismatch")
    foreach (decoded_occupancy[i]) begin
      if (decoded_occupancy[i] != 0)
        `uvm_error("DESERIALIZE_OCCUPANCY",
                   "deserialized word unexpectedly reserved occupancy")
    end
    field_value = 64'hfeed_face_dead_beef;
    expect_ok("GET_LOW", decoded.get_field(0, 0, 16, field_value));
    if (field_value != 16'h1234)
      `uvm_error("GET_LOW", $sformatf("got 0x%016x", field_value))
    field_value = '0;
    expect_ok("GET_HIGH", decoded.get_field(0, 56, 8, field_value));
    if (field_value != 8'hab)
      `uvm_error("GET_HIGH", $sformatf("got 0x%016x", field_value))
    field_value = '0;
    expect_ok("GET_MEMCPY_WORD",
              decoded.get_field(8, 32, 32, field_value));
    if (field_value != 32'hdead_beef)
      `uvm_error("GET_MEMCPY_WORD",
                 $sformatf("got 0x%016x", field_value))

    // Each failed reset preserves complete prior content and occupancy.  Zero
    // length is intentionally rejected: an empty hardware image is not a
    // meaningful qword builder state.
    snapshot_builder(builder, words_before, occupancy_before);
    status = builder.reset(0);
    expect_status("RESET_ZERO", status, RDMA_SC_CODEC_ERROR);
    expect_builder_unchanged("RESET_ZERO", builder, words_before,
                             occupancy_before);
    snapshot_builder(builder, words_before, occupancy_before);
    status = builder.reset(10);
    expect_status("RESET_UNALIGNED", status, RDMA_SC_CODEC_ERROR);
    expect_builder_unchanged("RESET_UNALIGNED", builder, words_before,
                             occupancy_before);

    // All field failures use a fresh before-image for both state arrays.
    snapshot_builder(builder, words_before, occupancy_before);
    status = builder.put_field(0, 8, 16, 16'hffff);
    expect_status("FIELD_OVERLAP", status, RDMA_SC_CODEC_ERROR);
    expect_builder_unchanged("FIELD_OVERLAP", builder, words_before,
                             occupancy_before);
    snapshot_builder(builder, words_before, occupancy_before);
    status = builder.put_field(8, 0, 0, 0);
    expect_status("FIELD_WIDTH_ZERO", status, RDMA_SC_CODEC_ERROR);
    expect_builder_unchanged("FIELD_WIDTH_ZERO", builder, words_before,
                             occupancy_before);
    snapshot_builder(builder, words_before, occupancy_before);
    status = builder.put_field(8, 0, 65, 0);
    expect_status("FIELD_WIDTH_65", status, RDMA_SC_CODEC_ERROR);
    expect_builder_unchanged("FIELD_WIDTH_65", builder, words_before,
                             occupancy_before);
    snapshot_builder(builder, words_before, occupancy_before);
    status = builder.put_field(8, 4, 8, 64'h100);
    expect_status("FIELD_VALUE_OVERFLOW", status, RDMA_SC_CODEC_ERROR);
    expect_builder_unchanged("FIELD_VALUE_OVERFLOW", builder, words_before,
                             occupancy_before);
    snapshot_builder(builder, words_before, occupancy_before);
    status = builder.put_field(4, 0, 1, 1);
    expect_status("FIELD_UNALIGNED_OFFSET", status, RDMA_SC_CODEC_ERROR);
    expect_builder_unchanged("FIELD_UNALIGNED_OFFSET", builder, words_before,
                             occupancy_before);
    snapshot_builder(builder, words_before, occupancy_before);
    status = builder.put_field(16, 0, 1, 1);
    expect_status("FIELD_OFFSET_OOB", status, RDMA_SC_CODEC_ERROR);
    expect_builder_unchanged("FIELD_OFFSET_OOB", builder, words_before,
                             occupancy_before);
    snapshot_builder(builder, words_before, occupancy_before);
    status = builder.put_field(32'hffff_fff8, 0, 1, 1);
    expect_status("FIELD_INDEX_OOB", status, RDMA_SC_CODEC_ERROR);
    expect_builder_unchanged("FIELD_INDEX_OOB", builder, words_before,
                             occupancy_before);
    snapshot_builder(builder, words_before, occupancy_before);
    status = builder.put_field(8, 64, 1, 1);
    expect_status("FIELD_LSB_OOB", status, RDMA_SC_CODEC_ERROR);
    expect_builder_unchanged("FIELD_LSB_OOB", builder, words_before,
                             occupancy_before);
    snapshot_builder(builder, words_before, occupancy_before);
    status = builder.put_field(8, 63, 2, 1);
    expect_status("FIELD_RANGE_OOB", status, RDMA_SC_CODEC_ERROR);
    expect_builder_unchanged("FIELD_RANGE_OOB", builder, words_before,
                             occupancy_before);
    expect_ok("FIELD_WIDTH_64_RESET", builder.reset(8));
    expect_ok("FIELD_WIDTH_64",
              builder.put_field(0, 0, 64, 64'hfedc_ba98_7654_3210));
    builder.get_words(words);
    if (words.size() != 1 || words[0] != 64'hfedc_ba98_7654_3210)
      `uvm_error("FIELD_WIDTH_64", "full-width value was not retained")

    // A zero-valued field still owns its complete mask and blocks a later
    // author from overlapping it.
    zero_field_builder = new("zero_field_builder");
    expect_ok("ZERO_FIELD_RESET", zero_field_builder.reset(8));
    expect_ok("ZERO_FIELD_AUTHOR",
              zero_field_builder.put_field(0, 8, 8, 0));
    snapshot_builder(zero_field_builder, words_before, occupancy_before);
    status = zero_field_builder.put_field(0, 8, 8, 8'hff);
    expect_status("ZERO_FIELD_OVERLAP", status, RDMA_SC_CODEC_ERROR);
    expect_builder_unchanged("ZERO_FIELD_OVERLAP", zero_field_builder,
                             words_before, occupancy_before);

    // A zero memcpy byte reserves all eight target bits.  The overlapping
    // failure cannot reserve any additional bits or change prior words.
    expect_ok("MEMCPY_RESET", builder.reset(16));
    zero_byte = '{8'h00};
    overlap_byte = '{8'hff};
    expect_ok("MEMCPY_ZERO", builder.put_memcpy(4, zero_byte));
    snapshot_builder(builder, words_before, occupancy_before);
    status = builder.put_memcpy(4, overlap_byte);
    expect_status("MEMCPY_ZERO_OVERLAP", status, RDMA_SC_CODEC_ERROR);
    expect_builder_unchanged("MEMCPY_ZERO_OVERLAP", builder, words_before,
                             occupancy_before);
    snapshot_builder(builder, words_before, occupancy_before);
    status = builder.put_memcpy(15, memcpy_bytes);
    expect_status("MEMCPY_RANGE_OOB", status, RDMA_SC_CODEC_ERROR);
    expect_builder_unchanged("MEMCPY_RANGE_OOB", builder, words_before,
                             occupancy_before);
    snapshot_builder(builder, words_before, occupancy_before);
    status = builder.put_memcpy(32'hffff_fffe, memcpy_bytes);
    expect_status("MEMCPY_RANGE_OVERFLOW", status, RDMA_SC_CODEC_ERROR);
    expect_builder_unchanged("MEMCPY_RANGE_OVERFLOW", builder, words_before,
                             occupancy_before);
    invalid_bytes = new[0];
    snapshot_builder(builder, words_before, occupancy_before);
    status = builder.put_memcpy(0, invalid_bytes);
    expect_status("MEMCPY_EMPTY", status, RDMA_SC_CODEC_ERROR);
    expect_builder_unchanged("MEMCPY_EMPTY", builder, words_before,
                             occupancy_before);

    // A successful memcpy can cross the qword 7/8 byte boundary.  Exact
    // logical words, occupancy, and final byte order are all observable.
    crossing_builder = new("crossing_builder");
    expect_ok("MEMCPY_CROSS_RESET", crossing_builder.reset(16));
    crossing_bytes = '{8'ha1, 8'hb2, 8'hc3};
    expect_ok("MEMCPY_CROSS",
              crossing_builder.put_memcpy(7, crossing_bytes));
    snapshot_builder(crossing_builder, words, occupancy);
    if (words.size() != 2 || words[0] != 64'h0000_0000_0000_00a1 ||
        words[1] != 64'hb2c3_0000_0000_0000)
      `uvm_error("MEMCPY_CROSS_WORDS", "cross-qword logical words mismatch")
    if (occupancy.size() != 2 ||
        occupancy[0] != 64'h0000_0000_0000_00ff ||
        occupancy[1] != 64'hffff_0000_0000_0000)
      `uvm_error("MEMCPY_CROSS_OCCUPANCY",
                 "cross-qword occupancy mismatch")
    expect_ok("MEMCPY_CROSS_SERIALIZE",
              crossing_builder.serialize(crossing_serialized));
    crossing_expected = '{
      8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'ha1,
      8'hb2,8'hc3,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00
    };
    if (!bytes_equal(crossing_serialized, crossing_expected))
      `uvm_error("MEMCPY_CROSS_SERIALIZE", "cross-qword bytes mismatch")

    // The occupied target appears only after two free bytes.  Complete
    // preflight must reject without changing either qword, occupancy, or the
    // serialized before-image.
    late_overlap_builder = new("late_overlap_builder");
    expect_ok("MEMCPY_LATE_RESET", late_overlap_builder.reset(16));
    zero_byte = '{8'h00};
    expect_ok("MEMCPY_LATE_RESERVE",
              late_overlap_builder.put_memcpy(9, zero_byte));
    expect_ok("MEMCPY_LATE_BEFORE",
              late_overlap_builder.serialize(late_serialized_before));
    snapshot_builder(late_overlap_builder, words_before, occupancy_before);
    late_overlap_bytes = '{8'h11, 8'h22, 8'h33, 8'h44};
    status = late_overlap_builder.put_memcpy(7, late_overlap_bytes);
    expect_status("MEMCPY_LATE_OVERLAP", status, RDMA_SC_CODEC_ERROR);
    expect_builder_unchanged("MEMCPY_LATE_OVERLAP", late_overlap_builder,
                             words_before, occupancy_before);
    late_serialized_after = '{8'ha5};
    expect_ok("MEMCPY_LATE_AFTER",
              late_overlap_builder.serialize(late_serialized_after));
    if (!bytes_equal(late_serialized_after, late_serialized_before))
      `uvm_error("MEMCPY_LATE_SERIALIZE",
                 "late overlap changed serialized before-image")

    // Deserialization deliberately leaves occupancy clear, so a subsequent
    // author must replace decoded bits rather than OR into them.
    overwrite_builder = new("overwrite_builder");
    all_ff_bytes = new[16];
    foreach (all_ff_bytes[i])
      all_ff_bytes[i] = 8'hff;
    expect_ok("OVERWRITE_DESERIALIZE",
              overwrite_builder.deserialize(all_ff_bytes));
    expect_ok("OVERWRITE_ZERO_FIELD",
              overwrite_builder.put_field(0, 0, 8, 0));
    zero_byte = '{8'h00};
    expect_ok("OVERWRITE_ZERO_MEMCPY",
              overwrite_builder.put_memcpy(8, zero_byte));
    field_value = '1;
    expect_ok("OVERWRITE_GET_FIELD",
              overwrite_builder.get_field(0, 0, 8, field_value));
    if (field_value != 0)
      `uvm_error("OVERWRITE_GET_FIELD", "zero field did not clear decoded bits")
    field_value = '1;
    expect_ok("OVERWRITE_GET_MEMCPY",
              overwrite_builder.get_field(8, 56, 8, field_value));
    if (field_value != 0)
      `uvm_error("OVERWRITE_GET_MEMCPY", "zero memcpy did not clear decoded bits")
    snapshot_builder(overwrite_builder, words, occupancy);
    if (words.size() != 2 || words[0] != 64'hffff_ffff_ffff_ff00 ||
        words[1] != 64'h00ff_ffff_ffff_ffff)
      `uvm_error("OVERWRITE_WORDS", "decoded replacement words mismatch")
    if (occupancy.size() != 2 ||
        occupancy[0] != 64'h0000_0000_0000_00ff ||
        occupancy[1] != 64'hff00_0000_0000_0000)
      `uvm_error("OVERWRITE_OCCUPANCY",
                 "decoded replacement occupancy mismatch")
    expect_ok("OVERWRITE_SERIALIZE",
              overwrite_builder.serialize(overwritten_bytes));
    if (overwritten_bytes.size() != 16 || overwritten_bytes[7] != 0 ||
        overwritten_bytes[8] != 0)
      `uvm_error("OVERWRITE_SERIALIZE",
                 "decoded zero replacement did not reach serialized bytes")

    // Reject oversized xtr_v1 images before allocation.  The huge call is
    // deliberately gated on the small over-limit rejection so the RED build
    // can never attempt a multi-gigabyte allocation.
    size_builder = new("size_builder");
    expect_ok("SIZE_BASE_RESET", size_builder.reset(16));
    expect_ok("SIZE_BASE_FIELD", size_builder.put_field(0, 0, 8, 8'h5a));
    snapshot_builder(size_builder, words_before, occupancy_before);
    status = size_builder.reset(520);
    expect_status("RESET_OVER_MAX", status, RDMA_SC_INVALID_ARGUMENT);
    expect_builder_unchanged("RESET_OVER_MAX", size_builder, words_before,
                             occupancy_before);
    if (status != null && status.code == RDMA_SC_INVALID_ARGUMENT) begin
      snapshot_builder(size_builder, words_before, occupancy_before);
      status = size_builder.reset(32'hffff_fff8);
      expect_status("RESET_HUGE", status, RDMA_SC_INVALID_ARGUMENT);
      expect_builder_unchanged("RESET_HUGE", size_builder, words_before,
                               occupancy_before);
    end else begin
      `uvm_error("RESET_HUGE_GUARD",
                 "unsafe huge reset skipped because 520-byte bound failed")
    end

    expect_ok("SIZE_DESERIALIZE_BASE_RESET", size_builder.reset(16));
    expect_ok("SIZE_DESERIALIZE_BASE_FIELD",
              size_builder.put_field(0, 0, 8, 8'ha5));
    oversized_bytes = new[520];
    foreach (oversized_bytes[i])
      oversized_bytes[i] = byte'(i);
    oversized_snapshot = oversized_bytes;
    snapshot_builder(size_builder, words_before, occupancy_before);
    status = size_builder.deserialize(oversized_bytes);
    expect_status("DESERIALIZE_OVER_MAX", status,
                  RDMA_SC_INVALID_ARGUMENT);
    if (!bytes_equal(oversized_bytes, oversized_snapshot))
      `uvm_error("DESERIALIZE_OVER_MAX", "failure changed input bytes")
    expect_builder_unchanged("DESERIALIZE_OVER_MAX", size_builder,
                             words_before, occupancy_before);

    // Invalid deserialize calls preserve an already-populated builder.
    snapshot_builder(decoded, words_before, occupancy_before);
    invalid_bytes = new[0];
    status = decoded.deserialize(invalid_bytes);
    expect_status("DESERIALIZE_ZERO", status, RDMA_SC_CODEC_ERROR);
    expect_builder_unchanged("DESERIALIZE_ZERO", decoded, words_before,
                             occupancy_before);
    invalid_bytes = new[10];
    foreach (invalid_bytes[i])
      invalid_bytes[i] = 8'h5a;
    snapshot_builder(decoded, words_before, occupancy_before);
    status = decoded.deserialize(invalid_bytes);
    expect_status("DESERIALIZE_UNALIGNED", status, RDMA_SC_CODEC_ERROR);
    expect_builder_unchanged("DESERIALIZE_UNALIGNED", decoded, words_before,
                             occupancy_before);

    // get_field validates before assigning its output and never changes state.
    snapshot_builder(decoded, words_before, occupancy_before);
    field_value = 64'h0123_4567_89ab_cdef;
    status = decoded.get_field(4, 0, 1, field_value);
    expect_status("GET_UNALIGNED", status, RDMA_SC_CODEC_ERROR);
    if (field_value != 64'h0123_4567_89ab_cdef)
      `uvm_error("GET_UNALIGNED", "failure changed output argument")
    expect_builder_unchanged("GET_UNALIGNED", decoded, words_before,
                             occupancy_before);
    snapshot_builder(decoded, words_before, occupancy_before);
    field_value = 64'hfedc_ba98_7654_3210;
    status = decoded.get_field(16, 0, 1, field_value);
    expect_status("GET_OFFSET_OOB", status, RDMA_SC_CODEC_ERROR);
    if (field_value != 64'hfedc_ba98_7654_3210)
      `uvm_error("GET_OFFSET_OOB", "failure changed output argument")
    expect_builder_unchanged("GET_OFFSET_OOB", decoded, words_before,
                             occupancy_before);
    snapshot_builder(decoded, words_before, occupancy_before);
    field_value = 64'ha5a5_a5a5_a5a5_a5a5;
    status = decoded.get_field(0, 0, 0, field_value);
    expect_status("GET_WIDTH_ZERO", status, RDMA_SC_CODEC_ERROR);
    if (field_value != 64'ha5a5_a5a5_a5a5_a5a5)
      `uvm_error("GET_WIDTH_ZERO", "failure changed output argument")
    expect_builder_unchanged("GET_WIDTH_ZERO", decoded, words_before,
                             occupancy_before);
    snapshot_builder(decoded, words_before, occupancy_before);
    field_value = 64'h5a5a_5a5a_5a5a_5a5a;
    status = decoded.get_field(0, 0, 65, field_value);
    expect_status("GET_WIDTH_65", status, RDMA_SC_CODEC_ERROR);
    if (field_value != 64'h5a5a_5a5a_5a5a_5a5a)
      `uvm_error("GET_WIDTH_65", "failure changed output argument")
    expect_builder_unchanged("GET_WIDTH_65", decoded, words_before,
                             occupancy_before);
    snapshot_builder(decoded, words_before, occupancy_before);
    field_value = 64'hcafe_f00d_dead_beef;
    status = decoded.get_field(0, 63, 2, field_value);
    expect_status("GET_RANGE_OOB", status, RDMA_SC_CODEC_ERROR);
    if (field_value != 64'hcafe_f00d_dead_beef)
      `uvm_error("GET_RANGE_OOB", "failure changed output argument")
    expect_builder_unchanged("GET_RANGE_OOB", decoded, words_before,
                             occupancy_before);

    // An uninitialized builder has no valid serialized image.  Its failed
    // serialize call must preserve a caller's previously successful output.
    empty_builder = new("empty_builder");
    byte_snapshot = bytes;
    snapshot_builder(empty_builder, words_before, occupancy_before);
    status = empty_builder.serialize(bytes);
    expect_status("SERIALIZE_INVALID_STATE", status, RDMA_SC_INVALID_STATE);
    if (!bytes_equal(bytes, byte_snapshot))
      `uvm_error("SERIALIZE_INVALID_STATE", "failure changed output array")
    expect_builder_unchanged("SERIALIZE_INVALID_STATE", empty_builder,
                             words_before, occupancy_before);
    snapshot_builder(empty_builder, words_before, occupancy_before);
    field_value = 64'h1357_9bdf_2468_ace0;
    status = empty_builder.get_field(0, 0, 1, field_value);
    expect_status("GET_INVALID_STATE", status, RDMA_SC_INVALID_STATE);
    if (field_value != 64'h1357_9bdf_2468_ace0)
      `uvm_error("GET_INVALID_STATE", "failure changed output argument")
    expect_builder_unchanged("GET_INVALID_STATE", empty_builder,
                             words_before, occupancy_before);

    // UVM clone retains complete populated state, and later mutation of the
    // clone cannot reach the source's dynamic arrays or scalar metadata.
    clone_source = new("clone_source");
    expect_ok("CLONE_RESET", clone_source.reset(16));
    expect_ok("CLONE_FIELD", clone_source.put_field(0, 0, 8, 8'haa));
    zero_byte = '{8'h55};
    expect_ok("CLONE_MEMCPY", clone_source.put_memcpy(8, zero_byte));
    snapshot_builder(clone_source, words_before, occupancy_before);
    cloned_object = clone_source.clone();
    if (cloned_object == null || !$cast(clone_copy, cloned_object)) begin
      `uvm_error("BUILDER_CLONE", "clone lost qword builder dynamic type")
    end else begin
      snapshot_builder(clone_copy, words, occupancy);
      if (!qwords_equal(words, words_before) ||
          !qwords_equal(occupancy, occupancy_before))
        `uvm_error("BUILDER_CLONE", "clone did not retain populated state")
      expect_ok("BUILDER_CLONE_MUTATE",
                clone_copy.put_field(0, 8, 8, 8'hbb));
      expect_builder_unchanged("BUILDER_CLONE_INDEPENDENT", clone_source,
                               words_before, occupancy_before);
    end

    check_supported_masks();

    // Body validation is exact-size, rejects non-body bits, and never mutates
    // words or occupancy on either codec or dispatch errors.
    expect_ok("MASK_RESET", builder.reset(64));
    expect_ok("MASK_OUTSIDE_BIT", builder.put_field(0, 63, 1, 1));
    snapshot_builder(builder, words_before, occupancy_before);
    status = builder.validate_allowed_mask(RDMA_IMAGE_CQC,
                                           XTR_V1_OP_CQC_CREATE,
                                           RDMA_MR_PBL0);
    expect_status("MASK_OUTSIDE_ALLOWED", status, RDMA_SC_CODEC_ERROR);
    expect_builder_unchanged("MASK_OUTSIDE_ALLOWED", builder, words_before,
                             occupancy_before);

    expect_ok("MASK_UNSUPPORTED_RESET", builder.reset(64));
    snapshot_builder(builder, words_before, occupancy_before);
    status = builder.validate_allowed_mask(RDMA_IMAGE_QPC,
                                           XTR_V1_OP_QPC_CREATE,
                                           RDMA_MR_PBL0);
    expect_status("MASK_UNSUPPORTED_KIND", status,
                  RDMA_SC_UNSUPPORTED_OPCODE);
    expect_builder_unchanged("MASK_UNSUPPORTED_KIND", builder, words_before,
                             occupancy_before);
    snapshot_builder(builder, words_before, occupancy_before);
    status = builder.validate_allowed_mask(rdma_image_kind_e'(5'h1f),
                                           XTR_V1_OP_CQC_CREATE,
                                           RDMA_MR_PBL0);
    expect_status("MASK_UNKNOWN_KIND", status, RDMA_SC_UNSUPPORTED_OPCODE);
    expect_builder_unchanged("MASK_UNKNOWN_KIND", builder, words_before,
                             occupancy_before);
    snapshot_builder(builder, words_before, occupancy_before);
    status = builder.validate_allowed_mask(RDMA_IMAGE_CQC,
                                           XTR_V1_OP_AEQC_CREATE,
                                           RDMA_MR_PBL0);
    expect_status("MASK_UNSUPPORTED_OPCODE", status,
                  RDMA_SC_UNSUPPORTED_OPCODE);
    expect_builder_unchanged("MASK_UNSUPPORTED_OPCODE", builder,
                             words_before, occupancy_before);
    snapshot_builder(builder, words_before, occupancy_before);
    status = builder.validate_allowed_mask(
        RDMA_IMAGE_MRT, XTR_V1_OP_MR_REGISTER,
        rdma_mr_pbl_mode_e'(2'b11));
    expect_status("MASK_UNSUPPORTED_PBL", status,
                  RDMA_SC_UNSUPPORTED_OPCODE);
    expect_builder_unchanged("MASK_UNSUPPORTED_PBL", builder, words_before,
                             occupancy_before);

    expect_ok("MASK_SHORT_RESET", builder.reset(56));
    snapshot_builder(builder, words_before, occupancy_before);
    status = builder.validate_allowed_mask(RDMA_IMAGE_CQC,
                                           XTR_V1_OP_CQC_CREATE,
                                           RDMA_MR_PBL0);
    expect_status("MASK_SHORT_IMAGE", status, RDMA_SC_CODEC_ERROR);
    expect_builder_unchanged("MASK_SHORT_IMAGE", builder, words_before,
                             occupancy_before);
    expect_ok("MASK_LONG_RESET", builder.reset(72));
    snapshot_builder(builder, words_before, occupancy_before);
    status = builder.validate_allowed_mask(RDMA_IMAGE_CQC,
                                           XTR_V1_OP_CQC_CREATE,
                                           RDMA_MR_PBL0);
    expect_status("MASK_LONG_IMAGE", status, RDMA_SC_CODEC_ERROR);
    expect_builder_unchanged("MASK_LONG_IMAGE", builder, words_before,
                             occupancy_before);

    // Task 9.5 froze bad-qword lookup as false with a zero mask.  Confirm that
    // behavior without allowing the pure lookup to affect builder state.
    snapshot_builder(builder, words_before, occupancy_before);
    mask_value = '1;
    if (body_mask(RDMA_IMAGE_CQC, XTR_V1_OP_CQC_CREATE, 0, 8,
                  mask_value) || mask_value != 0)
      `uvm_error("MASK_BAD_QWORD", "bad qword lookup behavior changed")
    expect_builder_unchanged("MASK_BAD_QWORD", builder, words_before,
                             occupancy_before);

    phase.drop_objection(this);
  endtask
endclass
