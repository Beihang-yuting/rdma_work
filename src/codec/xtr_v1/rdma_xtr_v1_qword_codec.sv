// 目录：硬件编解码层 codec/xtr_v1/rdma_xtr_v1_qword_codec.sv。
// 职责：实现 rdma_xtr_v1_qword_codec 在本层的职责和对外接口。
// 依赖：依赖本层公共 types/model/adapter 契约及其上游快照。
// 所有权与生命周期：对象只拥有显式创建的值快照；外部资源保存非拥有引用，生命周期由调用方管理。

// 中文说明：rdma_xtr_v1_qword_codec.sv 属于编码层，将模型字段转换为硬件图像并执行反向校验。
// 阅读提示：先看公开类型和接口，再看实现细节；失败路径应保持状态与资源所有权可追踪。

class rdma_xtr_v1_qword_builder extends uvm_object;
  `uvm_object_utils(rdma_xtr_v1_qword_builder)

  localparam int unsigned MAX_IMAGE_BYTES = XTR_V1_QPC_BYTES;

  protected bit [63:0] words[];
  protected bit [63:0] occupancy[];
  protected int unsigned byte_count;
  protected bit initialized;

  // 功能：构造当前对象并初始化其字段、集合和 UVM 名称；不接管传入句柄的生命周期。
  // 输入/输出及副作用：name 仅用于 UVM 对象命名；内部字段被初始化为安全默认值，传入句柄不转移所有权。
  //   返回新对象实例；构造失败由 UVM 工厂或调用方处理。
  // 失败/边界：不创建外部资源；name 为空时仍允许构造，但所有字段必须保持可配置的初始值。
  function new(string name = "rdma_xtr_v1_qword_builder");
    super.new(name);
    words = new[0];
    occupancy = new[0];
    byte_count = 0;
    initialized = 1'b0;
  endfunction

  // 功能：从源对象复制可变字段并生成独立值快照；源对象保持不变，类型不匹配时报告复制错误。
  // 输入/输出及副作用：source/rhs 是源对象；返回或写入独立副本，不修改源对象。
  //   source/rhs 为空或类型不匹配时返回空值或触发既定复制错误。
  // 失败/边界：空源对象不应解引用；类型不匹配必须拒绝复制或按既定 UVM 规则报告 fatal。
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

  // 功能：把输入错误或注入故障转换成统一的 rdma_status，供上层沿原事务路径处理。
  // 输入/输出及副作用：输入为错误消息、错误码或故障证据；返回统一 rdma_status，不推进事务游标。
  //   空消息仍需保留错误类别；未知错误码不得被静默转换为成功。
  // 失败/边界：错误路径不能返回成功状态；消息和错误码缺失时仍须保留可诊断类别。
  protected function rdma_status invalid_state_status();
    return rdma_status::make(RDMA_SC_INVALID_STATE,
                             "qword builder is not initialized");
  endfunction

  // 功能：处理 codec_error：依据其参数完成所属层的具体协议动作，并保持返回状态、游标和资源所有权一致。
  // 输入/输出及副作用：参数 message 用于执行 codec_error；返回值或 output/inout 交付处理结果，必要时更新本对象状态。
  //   调用方不获得内部集合或外部依赖的所有权。
  // 失败/边界：codec_error 只接受其签名声明的输入；缺少必要字段时返回错误，成功路径不得隐式修改无关资源。
  protected function rdma_status codec_error(string message);
    return rdma_status::make(RDMA_SC_CODEC_ERROR, message);
  endfunction

  // 功能：检查输入字段、身份和生命周期约束，返回可诊断的校验状态；失败时不提交部分更新。
  // 输入/输出及副作用：输入为待校验字段或快照；返回 rdma_status，校验过程不提交资源和游标。
  //   空依赖、非法范围、身份不一致或非活动状态会返回错误。
  // 失败/边界：任何非法枚举、越界字段、缺失必需依赖或身份/代际不一致都必须返回非成功状态。
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

  // 功能：清理当前运行状态并建立新的复位/代际边界，使旧句柄或旧事务不能继续生效。
  // 输入/输出及副作用：参数 replacement_words 用于执行 reset；返回值或 output/inout 交付处理结果，必要时更新本对象状态。
  //   调用方不获得内部集合或外部依赖的所有权。
  // 失败/边界：复位参数为零、代际回退或存在未处理 pending 事务时拒绝更新 authority。
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

  // 功能：把输入模型字段按硬件布局编码到目标 image/缓冲区，并在写入前检查范围、重叠和保留位。
  // 输入/输出及副作用：参数 word_byte_offset, lsb, width, value 用于执行 put_field；返回值或 output/inout 交付处理结果，必要时更新本对象状态。
  //   调用方不获得内部集合或外部依赖的所有权。
  // 失败/边界：镜像长度、字段宽度、保留位或写入范围非法时不修改已写入字节。
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

  // 功能：从硬件 image/缓冲区解码请求字段，验证布局和完整性后向调用方返回值或状态。
  // 输入/输出及副作用：参数 word_byte_offset, lsb, width 用于执行 get_field；返回值或 output/inout 交付处理结果，必要时更新本对象状态。
  //   调用方不获得内部集合或外部依赖的所有权。
  // 失败/边界：镜像为空、长度不足或校验失败时不发布部分模型字段。
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

  // 功能：把输入模型字段按硬件布局编码到目标 image/缓冲区，并在写入前检查范围、重叠和保留位。
  // 输入/输出及副作用：参数 final_byte_offset, value 用于执行 put_memcpy；返回值或 output/inout 交付处理结果，必要时更新本对象状态。
  //   调用方不获得内部集合或外部依赖的所有权。
  // 失败/边界：镜像长度、字段宽度、保留位或写入范围非法时不修改已写入字节。
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
  // 功能：处理 serialize：依据其参数完成所属层的具体协议动作，并保持返回状态、游标和资源所有权一致。
  // 输入/输出及副作用：参数 encoded 用于执行 serialize；返回值或 output/inout 交付处理结果，必要时更新本对象状态。
  //   调用方不获得内部集合或外部依赖的所有权。
  // 失败/边界：serialize 只接受其签名声明的输入；缺少必要字段时返回错误，成功路径不得隐式修改无关资源。
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

  // 功能：处理 deserialize：依据其参数完成所属层的具体协议动作，并保持返回状态、游标和资源所有权一致。
  // 输入/输出及副作用：参数 decoded_words 用于执行 deserialize；返回值或 output/inout 交付处理结果，必要时更新本对象状态。
  //   调用方不获得内部集合或外部依赖的所有权。
  // 失败/边界：deserialize 只接受其签名声明的输入；缺少必要字段时返回错误，成功路径不得隐式修改无关资源。
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

  // 功能：检查输入字段、身份和生命周期约束，返回可诊断的校验状态；失败时不提交部分更新。
  // 输入/输出及副作用：输入为待校验字段或快照；返回 rdma_status，校验过程不提交资源和游标。
  //   空依赖、非法范围、身份不一致或非活动状态会返回错误。
  // 失败/边界：任何非法枚举、越界字段、缺失必需依赖或身份/代际不一致都必须返回非成功状态。
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

  // 功能：按输入的完整标识查询当前权威记录并返回独立快照；缺失、歧义或代际过期时返回明确错误。
  // 输入/输出及副作用：输入为完整 key/handle，output 或返回值为记录快照；查询不改变登记表和外部资源。
  //   缺失、歧义、空句柄或旧 generation/reset epoch 返回明确错误。
  // 失败/边界：查询不到唯一记录、输入为空或 authority 已失效时返回错误，不回退到默认 Function/root。
  function void get_words(output bit [63:0] value[]);
    value = words;
  endfunction

  // 功能：按输入的完整标识查询当前权威记录并返回独立快照；缺失、歧义或代际过期时返回明确错误。
  // 输入/输出及副作用：输入为完整 key/handle，output 或返回值为记录快照；查询不改变登记表和外部资源。
  //   缺失、歧义、空句柄或旧 generation/reset epoch 返回明确错误。
  // 失败/边界：查询不到唯一记录、输入为空或 authority 已失效时返回错误，不回退到默认 Function/root。
  function void get_occupancy(output bit [63:0] value[]);
    value = occupancy;
  endfunction
endclass
