// 目录：硬件编解码层 codec/rdma/rdma_qword_codec.sv。
// 职责：按 qword 布局构造/解析 64 位字硬件 image，并检查字段范围、重叠与允许位掩码。
// 依赖：rdma_status、RDMA_QPC_BYTES、body_mask/request_envelope_mask 等 codec 常量。
// 所有权与生命周期：builder 独占 words/occupancy 副本；对外只输出拷贝，生命周期由调用方管理。

// 功能：校验 raw qword 只含 allowed_mask 允许的位。
// 输入/输出及副作用：raw_word、allowed_mask 为 logic[63:0]；纯函数，返回 1 通过。
// 失败/边界：任一输入含 X/Z 返回 0（fail-closed）；(raw_word & ~allowed_mask) 非零返回 0。
function automatic bit rdma_raw_qword_mask_is_valid(
  input logic [63:0] raw_word,
  input logic [63:0] allowed_mask
);
  if ($isunknown(raw_word) || $isunknown(allowed_mask))
    return 1'b0;

  return (raw_word & ~allowed_mask) === 64'b0;
endfunction

class rdma_hw_qword_builder extends uvm_object;
  `rdma_object_utils(rdma_hw_qword_builder)

  localparam int unsigned MAX_IMAGE_BYTES = RDMA_QPC_BYTES;

  protected bit [63:0] words[];
  protected bit [63:0] occupancy[];
  protected int unsigned byte_count;
  protected bit initialized;

  // 功能：构造未初始化的 builder。
  // 输入/输出及副作用：name 为对象名；清空 words/occupancy。
  // 失败/边界：未 reset/deserialize 前字段操作返回 INVALID_STATE。
  function new(string name = "rdma_hw_qword_builder");
    super.new(name);
    words = new[0];
    occupancy = new[0];
    byte_count = 0;
    initialized = 1'b0;
  endfunction

  // 功能：复制 rhs 的 words/occupancy/byte_count/initialized。
  // 输入/输出及副作用：覆盖当前字段，rhs 不变。
  // 失败/边界：类型不匹配触发 uvm_fatal。
  virtual function void do_copy(uvm_object rhs);
    rdma_hw_qword_builder rhs_builder;

    super.do_copy(rhs);
    if (!$cast(rhs_builder, rhs))
      `uvm_fatal("RDMA_COPY_TYPE", "qword builder copy type mismatch")
    words = rhs_builder.words;
    occupancy = rhs_builder.occupancy;
    byte_count = rhs_builder.byte_count;
    initialized = rhs_builder.initialized;
  endfunction

  // 功能：生成“builder 未初始化”的 INVALID_STATE 状态。
  // 输入/输出及副作用：返回新 status。
  // 失败/边界：无。
  protected function rdma_status invalid_state_status();
    return rdma_status::make(RDMA_SC_INVALID_STATE,
                             "qword builder is not initialized");
  endfunction

  // 功能：生成 CODEC_ERROR 状态。
  // 输入/输出及副作用：message 为诊断文本；返回新 status。
  // 失败/边界：无。
  protected function rdma_status codec_error(string message);
    return rdma_status::make(RDMA_SC_CODEC_ERROR, message);
  endfunction

  // 功能：把 byte offset/lsb/width 映射为 qword 索引并做范围检查。
  // 输入/输出及副作用：qword_index 先清零后输出；只读 words/initialized。
  // 失败/边界：未初始化返回 INVALID_STATE；offset 未 8 字节对齐/越界、width 不在 1..64、lsb>=64、字段跨 qword 返回 CODEC_ERROR。
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

  // 功能：以全零 words/occupancy 重新初始化 image。
  // 输入/输出及副作用：byte_count 为 image 字节数；成功后替换 words/occupancy 并置 initialized。
  // 失败/边界：长度为零或非 8 的倍数返回 CODEC_ERROR；超过 MAX_IMAGE_BYTES 返回 INVALID_ARGUMENT；失败不改状态。
  function rdma_status reset(int unsigned byte_count);
    bit [63:0] replacement_words[];
    bit [63:0] replacement_occupancy[];
    int unsigned qword_count;

    if (byte_count == 0)
      return codec_error("qword image length must be nonzero");
    if (byte_count > MAX_IMAGE_BYTES)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "qword image exceeds rdma maximum length");
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

  // 功能：把 value 写入指定位段并登记 occupancy。
  // 输入/输出及副作用：成功时更新 words/occupancy。
  // 失败/边界：几何非法、value 超出 width 或与已写位重叠返回错误；检查先于写入，失败不改状态。
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

  // 功能：读取指定位段的值。
  // 输入/输出及副作用：value 为 inout，成功时写入解码值；不改 builder。
  // 失败/边界：几何非法或未初始化返回错误，value 保持调用方原值。
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

  // 功能：按大端字节序把 value 写入 image 的 final_byte_offset 起始处并登记 occupancy。
  // 输入/输出及副作用：成功时更新 words/occupancy。
  // 失败/边界：未初始化、value 为空、范围越界或与已写字节重叠返回错误；先预检再写入，失败不改状态。
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
  // 功能：把 words 序列化为大端字节数组。
  // 输入/输出及副作用：value 为 inout，成功时被替换。
  // 失败/边界：未初始化返回 INVALID_STATE，value 不变。
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

  // 功能：从字节数组加载 words 并清空 occupancy。
  // 输入/输出及副作用：成功时替换 words/occupancy/byte_count 并置 initialized。
  // 失败/边界：为空或长度非 8 的倍数返回 CODEC_ERROR；超过 MAX_IMAGE_BYTES 返回 INVALID_ARGUMENT；失败不改状态。
  function rdma_status deserialize(byte unsigned value[]);
    bit [63:0] decoded_words[];
    bit [63:0] decoded_occupancy[];
    int unsigned qword_count;

    if (value.size() == 0)
      return codec_error("serialized qword image must be nonempty");
    if (value.size() > MAX_IMAGE_BYTES)
      return rdma_status::make(
          RDMA_SC_INVALID_ARGUMENT,
          "serialized qword image exceeds rdma maximum length");
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

  // 功能：按 image kind/opcode/PBL 模式的 body mask 校验 8 个 qword 的位使用。
  // 输入/输出及副作用：只读 words；返回 status。
  // 失败/边界：未初始化返回 INVALID_STATE；qword 数不为 8、mask 与 envelope 重叠、含掩码外的位返回 CODEC_ERROR；无 mask 返回
  //   UNSUPPORTED_OPCODE。
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
            "image kind, opcode, and PBL mode have no rdma body mask");
      if ((mask & request_envelope_mask(qword_index)) !== 64'b0)
        return codec_error("body mask overlaps request envelope ownership");
      if (!rdma_raw_qword_mask_is_valid(words[qword_index], mask))
        return codec_error("body image contains a bit outside its allowed mask");
    end
    return rdma_status::success();
  endfunction

  // 功能：输出 words 副本。
  // 输入/输出及副作用：value 为输出。
  // 失败/边界：无。
  function void get_words(output bit [63:0] value[]);
    value = words;
  endfunction

  // 功能：输出 occupancy 副本。
  // 输入/输出及副作用：value 为输出。
  // 失败/边界：无。
  function void get_occupancy(output bit [63:0] value[]);
    value = occupancy;
  endfunction
endclass
