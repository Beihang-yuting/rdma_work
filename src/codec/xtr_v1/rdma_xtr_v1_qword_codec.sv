// 中文说明：rdma_xtr_v1_qword_codec.sv 属于编码层，将模型字段转换为硬件图像并执行反向校验。
// 阅读提示：先看公开类型和接口，再看实现细节；失败路径应保持状态与资源所有权可追踪。

class rdma_xtr_v1_qword_builder extends uvm_object;
  `uvm_object_utils(rdma_xtr_v1_qword_builder)

  localparam int unsigned MAX_IMAGE_BYTES = XTR_V1_QPC_BYTES;

  protected bit [63:0] words[];
  protected bit [63:0] occupancy[];
  protected int unsigned byte_count;
  protected bit initialized;

  function new(string name = "rdma_xtr_v1_qword_builder");
    super.new(name);
    words = new[0];
    occupancy = new[0];
    byte_count = 0;
    initialized = 1'b0;
  endfunction

  virtual function void do_copy(uvm_object rhs);
    rdma_xtr_v1_qword_builder rhs_builder;

    super.do_copy(rhs);
    if (!$cast(rhs_builder, rhs))
      `uvm_fatal("RDMA_COPY_TYPE", "qword builder copy type mismatch")
    words = rhs_builder.words;
    occupancy = rhs_builder.occupancy;
    byte_count = rhs_builder.byte_count;
    initialized = rhs_builder.initialized;
  endfunction

  protected function rdma_status invalid_state_status();
    return rdma_status::make(RDMA_SC_INVALID_STATE,
                             "qword builder is not initialized");
  endfunction

  protected function rdma_status codec_error(string message);
    return rdma_status::make(RDMA_SC_CODEC_ERROR, message);
  endfunction

  protected function rdma_status validate_field_access(
    int unsigned word_byte_offset,
    int unsigned lsb,
    int unsigned width,
    output int unsigned qword_index
  );
    qword_index = 0;
    if (!initialized)
      return invalid_state_status();
    if ((word_byte_offset & 7) != 0)
      return codec_error("field word byte offset is not qword aligned");

    qword_index = word_byte_offset >> 3;
    if (qword_index >= words.size())
      return codec_error("field word byte offset is outside the image");
    if (width < 1 || width > 64)
      return codec_error("field width must be in the range 1..64");
    if (lsb >= 64)
      return codec_error("field lsb is outside a logical qword");
    if (width > (64 - lsb))
      return codec_error("field extends beyond its logical qword");
    return rdma_status::success();
  endfunction

  function rdma_status reset(int unsigned byte_count);
    bit [63:0] replacement_words[];
    bit [63:0] replacement_occupancy[];
    int unsigned qword_count;

    if (byte_count == 0)
      return codec_error("qword image length must be nonzero");
    if (byte_count > MAX_IMAGE_BYTES)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "qword image exceeds xtr_v1 maximum length");
    if ((byte_count & 7) != 0)
      return codec_error("qword image length must be divisible by eight");

    qword_count = byte_count >> 3;
    replacement_words = new[qword_count];
    replacement_occupancy = new[qword_count];
    foreach (replacement_words[i]) begin
      replacement_words[i] = '0;
      replacement_occupancy[i] = '0;
    end

    words = replacement_words;
    occupancy = replacement_occupancy;
    this.byte_count = byte_count;
    initialized = 1'b1;
    return rdma_status::success();
  endfunction

  function rdma_status put_field(
    int unsigned word_byte_offset,
    int unsigned lsb,
    int unsigned width,
    bit [63:0] value
  );
    rdma_status status;
    int unsigned qword_index;
    bit [63:0] width_mask;
    bit [63:0] field_mask;

    status = validate_field_access(word_byte_offset, lsb, width,
                                   qword_index);
    if (!status.ok())
      return status;
    if (width < 64 && (value >> width) != 0)
      return codec_error("field value does not fit requested width");

    width_mask = (width == 64) ? '1 : ((64'h1 << width) - 1);
    field_mask = width_mask << lsb;
    if ((occupancy[qword_index] & field_mask) != 0)
      return codec_error("field overlaps an earlier qword write");

    words[qword_index] = (words[qword_index] & ~field_mask) |
                         ((value << lsb) & field_mask);
    occupancy[qword_index] |= field_mask;
    return rdma_status::success();
  endfunction

  function rdma_status get_field(
    int unsigned word_byte_offset,
    int unsigned lsb,
    int unsigned width,
    // inout preserves the caller's prior value on every validation error;
    // SystemVerilog output formals are default-initialized before the body.
    inout bit [63:0] value
  );
    rdma_status status;
    int unsigned qword_index;
    bit [63:0] width_mask;
    bit [63:0] decoded;

    status = validate_field_access(word_byte_offset, lsb, width,
                                   qword_index);
    if (!status.ok())
      return status;

    width_mask = (width == 64) ? '1 : ((64'h1 << width) - 1);
    decoded = (words[qword_index] >> lsb) & width_mask;
    value = decoded;
    return rdma_status::success();
  endfunction

  function rdma_status put_memcpy(
    int unsigned final_byte_offset,
    byte unsigned value[]
  );
    int unsigned absolute_byte;
    int unsigned qword_index;
    int unsigned byte_in_qword;
    int unsigned shift;
    bit [63:0] byte_mask;
    bit [63:0] byte_value;

    if (!initialized)
      return invalid_state_status();
    if (value.size() == 0)
      return codec_error("memcpy value must be nonempty");
    if (final_byte_offset >= byte_count ||
        value.size() > (byte_count - final_byte_offset))
      return codec_error("memcpy range extends beyond the image");

    // Preflight the complete range before changing words or occupancy.
    foreach (value[i]) begin
      absolute_byte = final_byte_offset + i;
      qword_index = absolute_byte >> 3;
      byte_in_qword = absolute_byte & 7;
      shift = 56 - (byte_in_qword << 3);
      byte_mask = 64'hff << shift;
      if ((occupancy[qword_index] & byte_mask) != 0)
        return codec_error("memcpy overlaps an earlier qword write");
    end

    foreach (value[i]) begin
      absolute_byte = final_byte_offset + i;
      qword_index = absolute_byte >> 3;
      byte_in_qword = absolute_byte & 7;
      shift = 56 - (byte_in_qword << 3);
      byte_mask = 64'hff << shift;
      byte_value = value[i];
      words[qword_index] = (words[qword_index] & ~byte_mask) |
                           ((byte_value << shift) & byte_mask);
      occupancy[qword_index] |= byte_mask;
    end
    return rdma_status::success();
  endfunction

  // inout is required for caller-output atomicity on an invalid builder state.
  function rdma_status serialize(inout byte unsigned value[]);
    byte unsigned encoded[];

    if (!initialized)
      return invalid_state_status();

    encoded = new[byte_count];
    foreach (words[qword_index]) begin
      for (int unsigned byte_index = 0; byte_index < 8; byte_index++)
        encoded[(qword_index << 3) + byte_index] =
            words[qword_index][63 - (byte_index << 3) -: 8];
    end
    value = encoded;
    return rdma_status::success();
  endfunction

  function rdma_status deserialize(byte unsigned value[]);
    bit [63:0] decoded_words[];
    bit [63:0] decoded_occupancy[];
    int unsigned qword_count;

    if (value.size() == 0)
      return codec_error("serialized qword image must be nonempty");
    if (value.size() > MAX_IMAGE_BYTES)
      return rdma_status::make(
          RDMA_SC_INVALID_ARGUMENT,
          "serialized qword image exceeds xtr_v1 maximum length");
    if ((value.size() & 7) != 0)
      return codec_error(
          "serialized qword image length must be divisible by eight");

    qword_count = value.size() >> 3;
    decoded_words = new[qword_count];
    decoded_occupancy = new[qword_count];
    foreach (decoded_words[qword_index]) begin
      decoded_words[qword_index] = '0;
      decoded_occupancy[qword_index] = '0;
      for (int unsigned byte_index = 0; byte_index < 8; byte_index++)
        decoded_words[qword_index][63 - (byte_index << 3) -: 8] =
            value[(qword_index << 3) + byte_index];
    end

    words = decoded_words;
    occupancy = decoded_occupancy;
    byte_count = value.size();
    initialized = 1'b1;
    return rdma_status::success();
  endfunction

  function rdma_status validate_allowed_mask(
    rdma_image_kind_e image_kind,
    bit [7:0] opcode,
    rdma_mr_pbl_mode_e pbl_mode
  );
    bit [63:0] mask;

    if (!initialized)
      return invalid_state_status();
    if (words.size() != 8)
      return codec_error("body mask validation requires exactly eight qwords");

    foreach (words[qword_index]) begin
      if (!body_mask(image_kind, opcode, pbl_mode, qword_index, mask))
        return rdma_status::make(
            RDMA_SC_UNSUPPORTED_OPCODE,
            "image kind, opcode, and PBL mode have no xtr_v1 body mask");
      if ((mask & request_envelope_mask(qword_index)) != 0)
        return codec_error("body mask overlaps request envelope ownership");
      if ((words[qword_index] & ~mask) != 0)
        return codec_error("body image contains a bit outside its allowed mask");
    end
    return rdma_status::success();
  endfunction

  function void get_words(output bit [63:0] value[]);
    value = words;
  endfunction

  function void get_occupancy(output bit [63:0] value[]);
    value = occupancy;
  endfunction
endclass
