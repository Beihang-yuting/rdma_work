// 目录：硬件编解码层 codec/rdma/rdma_qword_codec.sv。
// 职责：实现 rdma_hw_qword_codec 在本层的职责和对外接口。
// 依赖：依赖本层公共 types/model/adapter 契约及其上游快照。
// 所有权与生命周期：对象只拥有显式创建的值快照；外部资源保存非拥有引用，生命周期由调用方管理。

// 中文说明：rdma_qword_codec.sv 属于编码层，将模型字段转换为硬件图像并执行反向校验。
// 阅读提示：先看公开类型和接口，再看实现细节；失败路径应保持状态与资源所有权可追踪。

// 功能：rdma_raw_qword_mask_is_valid 在所有原始 qword ownership/reserved 检查前，
//       以四态语义确认 raw word 和允许掩码均为确定值，再判断 raw word 是否只包含
//       驱动声明的位。
// 输入/输出及副作用：raw_word、allowed_mask（输入）均按 logic[63:0] 接收；函数只读
//       两个输入，不修改 builder、image 或模型，返回 1 表示检查通过、0 表示拒绝。
// 失败/边界：raw_word 或 allowed_mask 任一包含 X/Z 时 fail-closed；二态输入仅在
//       (raw_word & ~allowed_mask) 精确等于零时通过，因此不会扩大任何原始驱动 mask。
function automatic bit rdma_raw_qword_mask_is_valid(
  input logic [63:0] raw_word,
  input logic [63:0] allowed_mask
);
  if ($isunknown(raw_word) || $isunknown(allowed_mask))
    return 1'b0;

  return (raw_word & ~allowed_mask) === 64'b0;
endfunction

class rdma_hw_qword_builder extends uvm_object;
  `uvm_object_utils(rdma_hw_qword_builder)

  localparam int unsigned MAX_IMAGE_BYTES = RDMA_QPC_BYTES;

  protected bit [63:0] words[];
  protected bit [63:0] occupancy[];
  protected int unsigned byte_count;
  protected bit initialized;

  // 功能：构造 rdma_hw_qword_builder，调用 super.new 建立 UVM 对象，并把构造体直接写入的默认值设为：words=new[0]；occupancy=new[0]；byte_count=0；initialized=1'b0。
  // 输入/输出及副作用：name（输入）；new 只写入构造体列出的默认字段并返回 void，外部依赖与资源所有权仍由上层管理。
  // 失败/边界：rdma_hw_qword_builder 构造只建立本地初始状态，不接管外部 Host-memory、PCIe 或 manager；未完成后续 configure/build/activate 时，业务入口必须返回 INVALID_STATE。
  function new(string name = "rdma_hw_qword_builder");
    super.new(name);
    words = new[0];
    occupancy = new[0];
    byte_count = 0;
    initialized = 1'b0;
  endfunction

  // 功能：将 rhs 中 rdma_hw_qword_builder 的值字段复制到当前对象，建立与源对象隔离的快照。
  // 输入/输出及副作用：rhs（输入）；rhs 是源对象；当前对象字段会被覆盖，嵌套句柄按实现执行 clone 或保持非拥有引用，源对象不被修改。
  // 失败/边界：do_copy 在源对象为空、clone/cast 失败或类型不匹配时触发 UVM fatal（qword builder copy type mismatch），不保留部分有效快照。
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

  // 功能：在 rdma_hw_qword_builder 中，invalid_state_status 把错误消息、硬件码或注入故障封装为统一 rdma_status，保留原事务的诊断证据。
  // 输入/输出及副作用：无显式参数；invalid_state_status 读取 对象字段：rdma_status 并使用字段 rdma_status；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：invalid_state_status 返回 RDMA_SC_INVALID_STATE；典型拒绝条件为“qword builder is not initialized”；失败路径不提交部分状态或转移未声明资源。
  protected function rdma_status invalid_state_status();
    return rdma_status::make(RDMA_SC_INVALID_STATE,
                             "qword builder is not initialized");
  endfunction

  // 功能：在 rdma_hw_qword_builder 中，codec_error 根据输入错误信息构造带正确 category/code 的 rdma_status，供上层保留失败证据。
  // 输入/输出及副作用：message（输入）；codec_error 读取 message 并使用字段 rdma_status；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：codec_error 返回 RDMA_SC_CODEC_ERROR；失败路径不提交部分状态或转移未声明资源。
  protected function rdma_status codec_error(string message);
    return rdma_status::make(RDMA_SC_CODEC_ERROR, message);
  endfunction

  // 功能：validate_field_access 将 byte offset/bit slice 映射到已初始化 qword builder 的合法
  //   索引，并在任何字段读写前完成范围检查。
  // 输入/输出及副作用：word_byte_offset、lsb、width（输入），qword_index（输出）；先把
  //   qword_index 清零，只读 words/initialized，不修改 words 或 occupancy。
  // 失败/边界：builder 未初始化、offset 未按 8 字节对齐、qword 超出 image、width 不在
  //   1..64、lsb 超出 63 或字段跨 qword 时返回 INVALID_STATE/CODEC_ERROR。
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

  // 功能：在 rdma_hw_qword_builder 中，reset reset 清理当前运行状态并建立新的复位/代际边界，使旧句柄或旧事务不能继续生效。
  // 输入/输出及副作用：byte_count（输入）；输入 action/epoch/handle 决定迁移目标；成功时更新状态或恢复证据，外部资源仍由其拥有者管理。
  // 失败/边界：复位参数为零、代际回退或存在未处理 pending 事务时拒绝更新 authority。
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

  // 功能：put_field 在通过 validate_field_access 后，把 value 按 qword 位布局写入 words，并
  //   登记对应 occupancy 以阻止后续字段重叠。
  // 输入/输出及副作用：word_byte_offset、lsb、width、value（输入）；成功时更新当前 builder
  //   的 words/occupancy，函数不修改外部 image 或取得资源所有权。
  // 失败/边界：builder 未初始化、字段几何非法、value 超出 width 或 occupancy 已占用该位时
  //   返回错误；所有检查先于写入，失败保持 words/occupancy 不变。
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

  // 功能：在 rdma_hw_qword_builder 中，get_field 从硬件 image/缓冲区解码字段，验证长度、布局和完整性后返回模型或状态。
  // 输入/输出及副作用：word_byte_offset（输入）、lsb（输入）、width（输入）；get_field 读取 对象字段：rdma_status、value 并使用字段 status、width_mask、decoded、value；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：get_field 遇到 image/model 为空、长度/对齐/保留位非法或 codec 校验失败时不发布部分字段。
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

  // 功能：在 rdma_hw_qword_builder 中，put_memcpy 按硬件布局把输入模型编码到 image/缓冲区，并在写入前检查范围、重叠、端序和保留位。
  // 输入/输出及副作用：final_byte_offset（输入）、value（输入）；put_memcpy 读取 final_byte_offset、value 并使用字段 absolute_byte、qword_index、byte_in_qword、shift、byte_mask、byte_value；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：put_memcpy 遇到 image/model 为空、长度/对齐/保留位非法或 codec 校验失败时不发布部分字段。
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
  // 功能：在 rdma_hw_qword_builder 中，serialize 按 profile 的字段布局和端序把语义模型编码为硬件镜像，并在发布前检查长度与对齐。
  // 输入/输出及副作用：value（输出）；输入模型只读；成功时通过返回值或 output 发布完整 image/bytes，不修改源模型。
  // 失败/边界：模型为空、字段越界、保留位非零或输出长度不足时返回编码错误，不发布部分图像。
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

  // 功能：在 rdma_hw_qword_builder 中，deserialize 从输入 image/bytes 按固定 offset 提取字段，交付解码所需的值。
  // 输入/输出及副作用：value（输入）；输入 image/bytes 只读；成功时通过返回值或 output 发布 detached 解码快照，不接管调用方缓冲区。
  // 失败/边界：deserialize 返回 RDMA_SC_INVALID_ARGUMENT；具体拒绝条件包括 “serialized qword image must be nonempty”；“serialized qword image exceeds rdma maximum length”；“serialized qword image length must be divisible by eight”；失败路径不提交部分状态、不隐式重试，也不转移未声明资源。
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

  // 功能：validate_allowed_mask 校验 image_kind、opcode、pbl_mode 与当前对象状态的一致性，并显式处理“body mask validation requires exactly eight qwords”；“body mask overlaps request envelope ownership”；“body image contains a bit outside its allowed mask”；“image kind, opcode, and PBL mode have no rdma body mask”等拒绝条件，返回 rdma_status 供上层决定是否提交。
  // 输入/输出及副作用：image_kind（输入）、opcode（输入）、pbl_mode（输入）；validate_allowed_mask 读取 image_kind、opcode、pbl_mode 并使用字段 rdma_status、initialized、qword_index、words；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：validate_allowed_mask 返回 RDMA_SC_UNSUPPORTED_OPCODE；具体拒绝条件包括 “body mask validation requires exactly eight qwords”；“body mask overlaps request envelope ownership”；“body image contains a bit outside its allowed mask”；“image kind, opcode, and PBL mode have no rdma body mask”；失败路径不提交部分状态、不隐式重试，也不转移未声明资源。
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

  // 功能：在 rdma_hw_qword_builder 中，get_words 按完整 key/handle 查找唯一权威记录并返回 detached 快照，避免把内部可变引用泄露给调用方。
  // 输入/输出及副作用：value（输出）；get_words 读取 value 并使用字段 value，并写入 value；函数返回 void，不取得调用方资源所有权。
  // 失败/边界：get_words 在 key/handle 缺失、记录不唯一或 generation/reset epoch 过期时返回明确错误，不回退到默认 authority。
  function void get_words(output bit [63:0] value[]);
    value = words;
  endfunction

  // 功能：在 rdma_hw_qword_builder 中，get_occupancy 按完整 key/handle 查找唯一权威记录并返回 detached 快照，避免把内部可变引用泄露给调用方。
  // 输入/输出及副作用：value（输出）；get_occupancy 读取 value 并使用字段 value，并写入 value；函数返回 void，不取得调用方资源所有权。
  // 失败/边界：get_occupancy 在 key/handle 缺失、记录不唯一或 generation/reset epoch 过期时返回明确错误，不回退到默认 authority。
  function void get_occupancy(output bit [63:0] value[]);
    value = occupancy;
  endfunction
endclass
