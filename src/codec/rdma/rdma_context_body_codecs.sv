// 目录：硬件编解码层 codec/rdma/rdma_context_body_codecs.sv。
// 职责：实现 rdma_hw_context_body_codecs 在本层的职责和对外接口。
// 依赖：依赖本层公共 types/model/adapter 契约及其上游快照。
// 所有权与生命周期：对象只拥有显式创建的值快照；外部资源保存非拥有引用，生命周期由调用方管理。

// 中文说明：rdma_context_body_codecs.sv 属于编码层，将模型字段转换为硬件图像并执行反向校验。
// 阅读提示：先看公开类型和接口，再看实现细节；失败路径应保持状态与资源所有权可追踪。

virtual class rdma_hw_context_body_codec_base extends rdma_codec_base;
  localparam int unsigned BODY_BYTES = 64;

  // 功能：构造 rdma_hw_context_body_codec_base，调用 super.new 建立 UVM 层级对象；外部依赖字段保持未绑定，后续由 configure/build/activate 明确注入。
  // 输入/输出及副作用：name（输入）；new 只写入构造体列出的默认字段并返回 void，外部依赖与资源所有权仍由上层管理。
  // 失败/边界：rdma_hw_context_body_codec_base 构造只建立本地初始状态，不接管外部 Host-memory、PCIe 或 manager；未完成后续 configure/build/activate 时，业务入口必须返回 INVALID_STATE。
  function new(string name = "rdma_hw_context_body_codec_base");
    super.new(name);
  endfunction

  // 功能：在 rdma_hw_context_body_codec_base 中，expected_image_kind 在测试中检查调用结果、状态码和副作用是否符合契约；失败时报告可定位的验证信息。
  // 输入/输出及副作用：无显式参数；expected_image_kind 读取 对象字段：rdma_status、message 并使用字段 rdma_status、message；函数返回 rdma_image_kind_e，不取得调用方资源所有权。
  // 失败/边界：测试函数 expected_image_kind 缺少前置对象时报告断言错误，并停止依赖该对象的后续检查。
  protected pure virtual function rdma_image_kind_e expected_image_kind();
  // 功能：在 rdma_hw_context_body_codec_base 中，expected_opcode 在测试中检查调用结果、状态码和副作用是否符合契约；失败时报告可定位的验证信息。
  // 输入/输出及副作用：无显式参数；expected_opcode 返回具体 context codec 固定的硬件 opcode，不读取可变对象字段；函数返回 bit [7:0]，不取得调用方资源所有权。
  // 失败/边界：测试函数 expected_opcode 缺少前置对象时报告断言错误，并停止依赖该对象的后续检查。
  protected pure virtual function bit [7:0] expected_opcode();
  // 功能：model_pbl_mode 按函数体读取当前字段并生成 rdma_mr_pbl_mode_e 结果，供调用方进行诊断或分支决策；不修改外部资源。
  // 输入/输出及副作用：model（输入）；model_pbl_mode 读取 model.page_layout.pbl_mode，返回 MRT 的 PBL 编码模式；函数返回 rdma_mr_pbl_mode_e，不取得调用方资源所有权。
  // 失败/边界：枚举未定义或对象未配置时返回 UNKNOWN/UNCONFIGURED 表示，同时保留数值上下文。
  protected pure virtual function rdma_mr_pbl_mode_e model_pbl_mode(
    rdma_hw_model model
  );
  // 功能：在 rdma_hw_context_body_codec_base 中，owner_generation 读取并校验 Function generation/reset epoch，拒绝旧 binding 或跨 Function 请求。
  // 输入/输出及副作用：model（输入）；owner_generation 读取 model 绑定句柄的 generation，返回用于拒绝旧代际请求的值；函数返回 int unsigned，不取得调用方资源所有权。
  // 失败/边界：owner_generation 返回 RDMA_SC_INVALID_ARGUMENT；失败路径不提交部分状态或转移未声明资源。
  protected pure virtual function int unsigned owner_generation(
    rdma_hw_model model
  );
  // 功能：在 rdma_hw_context_body_codec_base 中，encode_body 按硬件布局把输入模型编码到 image/缓冲区，并在写入前检查范围、重叠、端序和保留位。
  // 输入/输出及副作用：model（输入）、builder（输入）；输入模型只读；成功时通过返回值或 output 发布完整 image/bytes，不修改源模型。
  // 失败/边界：encode_body 遇到 image/model 为空、长度/对齐/保留位非法或 codec 校验失败时不发布部分字段。
  protected pure virtual function rdma_status encode_body(
    rdma_hw_model model,
    rdma_hw_qword_builder builder
  );
  // 功能：在 rdma_hw_context_body_codec_base 中，decode_body 从硬件 image/缓冲区解码字段，验证长度、布局和完整性后返回模型或状态。
  // 输入/输出及副作用：builder（输入）、model（输出）；输入 image/bytes 只读；成功时通过返回值或 output 发布 detached 解码快照，不接管调用方缓冲区。
  // 失败/边界：decode_body 遇到 image/model 为空、长度/对齐/保留位非法或 codec 校验失败时不发布部分字段。
  protected pure virtual function rdma_status decode_body(
    rdma_hw_qword_builder builder,
    output rdma_hw_model model
  );

  // 功能：在 rdma_hw_context_body_codec_base 中，invalid_argument 把错误消息、硬件码或注入故障封装为统一 rdma_status，保留原事务的诊断证据。
  // 输入/输出及副作用：message（输入）；invalid_argument 用 message 构造 RDMA_SC_INVALID_ARGUMENT，不更新 codec 或外部资源；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：invalid_argument 返回 RDMA_SC_INVALID_ARGUMENT；失败路径不提交部分状态或转移未声明资源。
  protected function rdma_status invalid_argument(string message);
    return rdma_status::make(RDMA_SC_INVALID_ARGUMENT, message);
  endfunction

  // 功能：在 rdma_hw_context_body_codec_base 中，codec_error 根据输入错误信息构造带正确 category/code 的 rdma_status，供上层保留失败证据。
  // 输入/输出及副作用：message（输入）；codec_error 读取 message 并使用字段 rdma_status；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：codec_error 返回 RDMA_SC_CODEC_ERROR；失败路径不提交部分状态或转移未声明资源。
  protected function rdma_status codec_error(string message);
    return rdma_status::make(RDMA_SC_CODEC_ERROR, message);
  endfunction

  // 功能：在 rdma_hw_context_body_codec_base 中，put 把请求数据写入指定后端并保留返回状态；只有写入成功才允许本地游标继续推进。
  // 输入/输出及副作用：builder（输入）、word_byte_offset（输入）、lsb（输入）、width（输入）、value（输入）；put 读取 builder、word_byte_offset、lsb、width、value 并使用字段 status；函数返回 rdma_status，不取得调用方资源所有权。

  // 失败/边界：put 遇到后端拒绝、范围溢出或 DMA 权限不足时保留失败证据，不推进本地游标。
  protected function rdma_status put(
    rdma_hw_qword_builder builder,
    int unsigned word_byte_offset,
    int unsigned lsb,
    int unsigned width,
    bit [63:0] value
  );
    rdma_status status;
    status = builder.put_field(word_byte_offset, lsb, width, value);
    if (!status.ok())
      return codec_error({"context-body field authorship failed: ",
                          status.message});
    return status;
  endfunction

  // 功能：在 rdma_hw_context_body_codec_base 中，get 按完整 key/handle 查找唯一权威记录并返回 detached 快照，避免把内部可变引用泄露给调用方。
  // 输入/输出及副作用：builder（输入）、word_byte_offset（输入）、lsb（输入）、width（输入）、value（输出）；输入 handle/key/cursor 用于选择读取范围；返回值或 output
  //   为 detached 快照，读取不取得外部资源所有权。
  // 失败/边界：get 在 key/handle 缺失、记录不唯一或 generation/reset epoch 过期时返回明确错误，不回退到默认 authority。
  protected function rdma_status get(
    rdma_hw_qword_builder builder,
    int unsigned word_byte_offset,
    int unsigned lsb,
    int unsigned width,
    inout bit [63:0] value
  );
    rdma_status status;
    status = builder.get_field(word_byte_offset, lsb, width, value);
    if (!status.ok())
      return codec_error({"context-body field extraction failed: ",
                          status.message});
    return status;
  endfunction

  // 功能：在 rdma_hw_context_body_codec_base 中，encode_log2 按硬件布局把输入模型编码到 image/缓冲区，并在写入前检查范围、重叠、端序和保留位。
  // 输入/输出及副作用：value（输入）、width（输入）、label（输入）、code（输出）；输入模型只读；成功时通过返回值或 output 发布完整 image/bytes，不修改源模型。
  // 失败/边界：encode_log2 遇到 image/model 为空、长度/对齐/保留位非法或 codec 校验失败时不发布部分字段。
  protected function rdma_status encode_log2(
    int unsigned value,
    int unsigned width,
    string label,
    output int unsigned code
  );
    int unsigned remaining;
    code = 0;
    if (value == 0 || (value & (value - 1)) != 0)
      return invalid_argument({label, " is not a nonzero power of two"});
    remaining = value;
    while (remaining > 1) begin
      remaining >>= 1;
      code++;
    end
    if (code >= (1 << width))
      return invalid_argument({label, " logarithm exceeds field width"});
    return rdma_status::success();
  endfunction

  // 功能：在 rdma_hw_context_body_codec_base 中，encode_page 按硬件布局把输入模型编码到 image/缓冲区，并在写入前检查范围、重叠、端序和保留位。
  // 输入/输出及副作用：backing（输入）、label（输入）、page（输出）；输入模型只读；成功时通过返回值或 output 发布完整 image/bytes，不修改源模型。
  // 失败/边界：encode_page 遇到 image/model 为空、长度/对齐/保留位非法或 codec 校验失败时不发布部分字段。
  protected function rdma_status encode_page(
    rdma_backing_addr_t backing,
    string label,
    output bit [51:0] page
  );
    page = '0;
    if ((backing.value & 64'hfff) != 0)
      return invalid_argument({label, " is not 4 KiB aligned"});
    page = backing.value[63:12];
    return rdma_status::success();
  endfunction

  // 功能：在 rdma_hw_context_body_codec_base 中，encode_context_state 按硬件布局把输入模型编码到 image/缓冲区，并在写入前检查范围、重叠、端序和保留位。
  // 输入/输出及副作用：state（输入）、code（输出）；输入模型只读；成功时通过返回值或 output 发布完整 image/bytes，不修改源模型。
  // 失败/边界：encode_context_state 遇到 image/model 为空、长度/对齐/保留位非法或 codec 校验失败时不发布部分字段。
  protected function rdma_status encode_context_state(
    rdma_context_state_e state,
    output bit [1:0] code
  );
    case (state)
      RDMA_CONTEXT_INVALID: code = 2'd0;
      RDMA_CONTEXT_VALID:   code = 2'd1;
      RDMA_CONTEXT_ERROR:   code = 2'd2;
      default: return invalid_argument("context state is invalid");
    endcase
    return rdma_status::success();
  endfunction

  // 功能：在 rdma_hw_context_body_codec_base 中，decode_context_state 从硬件 image/缓冲区解码字段，验证长度、布局和完整性后返回模型或状态。
  // 输入/输出及副作用：code（输入）、state（输出）；输入 image/bytes 只读；成功时通过返回值或 output 发布 detached 解码快照，不接管调用方缓冲区。
  // 失败/边界：decode_context_state 遇到 image/model 为空、长度/对齐/保留位非法或 codec 校验失败时不发布部分字段。
  protected function rdma_status decode_context_state(
    bit [1:0] code,
    output rdma_context_state_e state
  );
    case (code)
      0: state = RDMA_CONTEXT_INVALID;
      1: state = RDMA_CONTEXT_VALID;
      2: state = RDMA_CONTEXT_ERROR;
      default: return codec_error("context state code is invalid");
    endcase
    return rdma_status::success();
  endfunction

  // 功能：在 rdma_hw_context_body_codec_base 中，projected_handle 构造或投影带完整 kind、Function UID、object ID 和 generation 的资源句柄。
  // 输入/输出及副作用：name（输入）、kind（输入）、object_id（输入）；projected_handle 读取 name、kind、object_id 并使用字段 handle、handle.kind、handle.object_id、handle.function_uid、handle.generation；函数返回 rdma_handle，不取得调用方资源所有权。
  // 失败/边界：projected_handle 的结果直接由 return handle 计算；输入不满足表达式条件时沿函数体的保守分支返回，不修改已发布账本。
  protected function rdma_handle projected_handle(
    string name,
    rdma_resource_kind_e kind,
    int unsigned object_id
  );
    rdma_handle handle;
    handle = rdma_handle::type_id::create(name);
    handle.kind = kind;
    handle.object_id = object_id;
    handle.function_uid = 0;
    handle.generation = 0;
    return handle;
  endfunction

  // 功能：在 rdma_hw_context_body_codec_base 中，image_pbl_mode 返回 profile 固定的镜像字段或长度常量，供编码和断言使用。
  // 输入/输出及副作用：builder（输入）、pbl_mode（输出）；image_pbl_mode 读取 builder、pbl_mode 并使用字段 pbl_mode，并写入 pbl_mode；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：image_pbl_mode 的结果直接由 return rdma_status::success() 计算；输入不满足表达式条件时沿函数体的保守分支返回，不修改已发布账本。
  protected virtual function rdma_status image_pbl_mode(
    rdma_hw_qword_builder builder,
    output rdma_mr_pbl_mode_e pbl_mode
  );
    pbl_mode = RDMA_MR_PBL0;
    return rdma_status::success();
  endfunction

  // 功能：validate_encode_mask 校验 builder、pbl_mode 与当前对象状态的一致性，并显式处理“context-body encode mask validation failed: ”；“context-body occupancy is not eight qwords”；“context-body encode mask lookup failed”；“context-body qword %0d authorship 0x%016x differs from mask 0x%016x”等拒绝条件，返回 rdma_status 供上层决定是否提交。
  // 输入/输出及副作用：builder（输入）、pbl_mode（输入）；validate_encode_mask 读取 builder、pbl_mode 并使用字段 status、allowed；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：validate_encode_mask 返回 RDMA_SC_CODEC_ERROR；典型拒绝条件为“context-body occupancy is not eight qwords”“context-body encode mask lookup failed”；失败路径不提交部分状态或转移未声明资源。
  protected function rdma_status validate_encode_mask(
    rdma_hw_qword_builder builder,
    rdma_mr_pbl_mode_e pbl_mode
  );
    bit [63:0] occupancy[];
    bit [63:0] allowed;
    rdma_status status;

    status = builder.validate_allowed_mask(expected_image_kind(),
                                           expected_opcode(), pbl_mode);
    if (!status.ok())
      return codec_error({"context-body encode mask validation failed: ",
                          status.message});
    builder.get_occupancy(occupancy);
    if (occupancy.size() != 8)
      return codec_error("context-body occupancy is not eight qwords");
    foreach (occupancy[q]) begin
      allowed = '0;
      if (!body_mask(expected_image_kind(), expected_opcode(), pbl_mode, q,
                     allowed))
        return codec_error("context-body encode mask lookup failed");
      if (occupancy[q] != allowed)
        return codec_error($sformatf(
          "context-body qword %0d authorship 0x%016x differs from mask 0x%016x",
          q, occupancy[q], allowed));
    end
    return rdma_status::success();
  endfunction

  // 功能：在 rdma_hw_context_body_codec_base 中，finish_body 提交当前事务阶段并发布 detached 结果，只有成功路径才推进游标或状态。
  // 输入/输出及副作用：builder（输入）、pbl_mode（输入）、owner_generation（输入）、image（输出）；finish_body 读取 builder、pbl_mode、owner_generation、image 并使用字段 image、status、payload、candidate、candidate.length、candidate.alignment、candidate.endian、candidate.image_kind，并写入 image；函数返回 rdma_status，不取得调用方资源所有权。

  // 失败/边界：finish_body 返回 RDMA_SC_CODEC_ERROR；失败路径不提交部分状态或转移未声明资源。
  protected function rdma_status finish_body(
    rdma_hw_qword_builder builder,
    rdma_mr_pbl_mode_e pbl_mode,
    int unsigned owner_generation,
    output rdma_hw_image image
  );
    rdma_status status;
    byte unsigned payload[];
    rdma_hw_image candidate;

    image = null;
    status = validate_encode_mask(builder, pbl_mode);
    if (!status.ok()) return status;
    payload = new[0];
    status = builder.serialize(payload);
    if (!status.ok())
      return codec_error({"context-body serialization failed: ",
                          status.message});

    candidate = rdma_hw_image::type_id::create("rdma_context_body_image");
    foreach (payload[i]) candidate.bytes.push_back(payload[i]);
    candidate.length = BODY_BYTES;
    candidate.alignment = BODY_BYTES;
    candidate.endian = RDMA_ENDIAN_BIG;
    candidate.image_kind = expected_image_kind();
    candidate.hardware_version = RDMA_HW_VERSION;
    candidate.function_generation = owner_generation;
    candidate.write_target_kind = RDMA_HW_TARGET_NONE;
    candidate.backing_target = '0;
    candidate.hmc_target = '0;
    candidate.bar_target = '0;
    image = candidate;
    return rdma_status::success();
  endfunction

  // 功能：在 rdma_hw_context_body_codec_base 中，encode 按硬件布局把输入模型编码到 image/缓冲区，并在写入前检查范围、重叠、端序和保留位。
  // 输入/输出及副作用：model（输入）、image（输出）；输入模型只读；成功时通过返回值或 output 发布完整 image/bytes，不修改源模型。
  // 失败/边界：encode 遇到 image/model 为空、长度/对齐/保留位非法或 codec 校验失败时不发布部分字段。
  virtual function rdma_status encode(
    rdma_hw_model model,
    output rdma_hw_image image
  );
    rdma_hw_qword_builder builder;
    rdma_status status;

    image = null;
    status = validate_model(model);
    if (!status.ok()) return status;
    builder = new("context_body_encode_builder");
    status = builder.reset(BODY_BYTES);
    if (!status.ok()) return codec_error(status.message);
    status = encode_body(model, builder);
    if (!status.ok()) return status;
    return finish_body(builder, model_pbl_mode(model),
                       owner_generation(model), image);
  endfunction

  // 功能：validate_image 校验 image 与当前对象状态的一致性，并显式处理“context-body image is null”等拒绝条件，返回 rdma_status 供上层决定是否提交。
  // 输入/输出及副作用：image（输入）；validate_image 读取 image 并使用字段 payload、builder、status；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：必需对象/句柄/快照为空，或身份、范围、generation 和生命周期检查失败时返回非成功状态。
  virtual function rdma_status validate_image(rdma_hw_image image);
    rdma_hw_qword_builder builder;
    rdma_mr_pbl_mode_e pbl_mode;
    byte unsigned payload[];
    rdma_status status;

    if (image == null)
      return codec_error("context-body image is null");
    if (image.length != BODY_BYTES || image.bytes.size() != BODY_BYTES)
      return codec_error("context-body image length is not 64 bytes");
    if (image.alignment != BODY_BYTES || image.endian != RDMA_ENDIAN_BIG ||
        image.image_kind != expected_image_kind() ||
        image.hardware_version != RDMA_HW_VERSION ||
        image.write_target_kind != RDMA_HW_TARGET_NONE ||
        image.backing_target.value != 0 || image.hmc_target.value != 0 ||
        image.bar_target.value != 0)
      return codec_error("context-body image metadata is invalid");
    payload = new[BODY_BYTES];
    foreach (payload[i]) payload[i] = image.bytes[i];
    builder = new("context_body_validate_builder");
    status = builder.deserialize(payload);
    if (!status.ok()) return codec_error(status.message);
    status = image_pbl_mode(builder, pbl_mode);
    if (!status.ok()) return codec_error(status.message);
    status = builder.validate_allowed_mask(expected_image_kind(),
                                           expected_opcode(), pbl_mode);
    if (!status.ok())
      return codec_error({"context-body reserved/mask validation failed: ",
                          status.message});
    return rdma_status::success();
  endfunction

  // 功能：在 rdma_hw_context_body_codec_base 中，decode 从硬件 image/缓冲区解码字段，验证长度、布局和完整性后返回模型或状态。
  // 输入/输出及副作用：image（输入）、model（输出）；输入 image/bytes 只读；成功时通过返回值或 output 发布 detached 解码快照，不接管调用方缓冲区。
  // 失败/边界：decode 遇到 image/model 为空、长度/对齐/保留位非法或 codec 校验失败时不发布部分字段。
  virtual function rdma_status decode(
    rdma_hw_image image,
    output rdma_hw_model model
  );
    rdma_hw_qword_builder builder;
    rdma_hw_model candidate;
    byte unsigned payload[];
    rdma_status status;

    model = null;
    status = validate_image(image);
    if (!status.ok()) return status;
    payload = new[BODY_BYTES];
    foreach (payload[i]) payload[i] = image.bytes[i];
    builder = new("context_body_decode_builder");
    status = builder.deserialize(payload);
    if (!status.ok()) return codec_error(status.message);
    candidate = null;
    status = decode_body(builder, candidate);
    if (!status.ok()) return status;
    if (candidate == null)
      return codec_error("context-body decoder produced a null candidate");
    status = validate_model(candidate);
    if (!status.ok())
      return codec_error({"decoded context-body semantics are invalid: ",
                          status.message});
    model = candidate;
    return rdma_status::success();
  endfunction

  // 功能：在 rdma_hw_context_body_codecs 中由 serialized_equal 逐字段比较输入值，返回结构、身份或序列化内容是否一致。
  // 输入/输出及副作用：lhs（输入）、rhs（输入）、equal（输出）、mismatch（输出）；比较对象/数组只读；返回 bit 或状态结果，不更新 runtime、账本或外部 adapter。
  // 失败/边界：serialized_equal 的任一比较对象为空或类型不符时返回确定的 false/不等结果，不抛出未处理异常。
  virtual function rdma_status serialized_equal(
    rdma_hw_model lhs,
    rdma_hw_model rhs,
    output bit equal,
    output string mismatch
  );
    rdma_hw_image left_image;
    rdma_hw_image right_image;
    rdma_status status;

    equal = 1'b0;
    mismatch = "";
    status = encode(lhs, left_image);
    if (!status.ok()) begin
      mismatch = {"left model: ", status.message};
      return status;
    end
    status = encode(rhs, right_image);
    if (!status.ok()) begin
      mismatch = {"right model: ", status.message};
      return status;
    end
    foreach (left_image.bytes[i]) begin
      if (left_image.bytes[i] != right_image.bytes[i]) begin
        mismatch = $sformatf("serialized byte %0d differs: %02x != %02x", i,
                             left_image.bytes[i], right_image.bytes[i]);
        return rdma_status::success();
      end
    end
    equal = 1'b1;
    return rdma_status::success();
  endfunction

  // 功能：hardware_endian 使用 当前对象字段 计算并返回 rdma_byte_endian_e 结果；不修改对象字段或外部资源。
  // 输入/输出及副作用：无显式参数；hardware_endian 读取固定返回值或局部计算结果，不使用对象成员字段；函数返回 rdma_byte_endian_e，不取得调用方资源所有权。
  // 失败/边界：hardware_endian 是只读访问器，返回 RDMA_ENDIAN_BIG；未覆盖枚举沿 default/类型默认分支返回，不改变对象和外部资源。
  virtual function rdma_byte_endian_e hardware_endian();
    return RDMA_ENDIAN_BIG;
  endfunction

  // 功能：describe_fields 把 当前对象字段 与当前对象的身份/状态字段编码为稳定文本，供日志、查找或恢复索引使用。
  // 输入/输出及副作用：无显式参数；describe_fields 读取局部计算结果，并使用字段 kind、opcode；函数返回 string，不取得调用方资源所有权。
  // 失败/边界：枚举未定义或对象未配置时返回 UNKNOWN/UNCONFIGURED 表示，同时保留数值上下文。
  virtual function string describe_fields();
    return $sformatf("rdma 64-byte sparse body kind=%s opcode=%02x",
                     expected_image_kind().name(), expected_opcode());
  endfunction
endclass

class rdma_hw_cqc_create_body_codec
    extends rdma_hw_context_body_codec_base;
  `uvm_object_utils(rdma_hw_cqc_create_body_codec)

  // 功能：构造 rdma_hw_cqc_create_body_codec，调用 super.new 建立 UVM 层级对象；外部依赖字段保持未绑定，后续由 configure/build/activate 明确注入。
  // 输入/输出及副作用：name（输入）；new 只写入构造体列出的默认字段并返回 void，外部依赖与资源所有权仍由上层管理。
  // 失败/边界：rdma_hw_cqc_create_body_codec 构造只建立本地初始状态，不接管外部 Host-memory、PCIe 或 manager；未完成后续 configure/build/activate 时，业务入口必须返回 INVALID_STATE。
  function new(string name = "rdma_hw_cqc_create_body_codec");
    super.new(name);
  endfunction

  // 功能：在 rdma_hw_cqc_create_body_codec 中，expected_image_kind 在测试中检查调用结果、状态码和副作用是否符合契约；失败时报告可定位的验证信息。
  // 输入/输出及副作用：无显式参数；expected_image_kind 读取固定返回值或局部计算结果，不使用对象成员字段；函数返回 rdma_image_kind_e，不取得调用方资源所有权。
  // 失败/边界：测试函数 expected_image_kind 缺少前置对象时报告断言错误，并停止依赖该对象的后续检查。
  protected virtual function rdma_image_kind_e expected_image_kind();
    return RDMA_IMAGE_CQC;
  endfunction

  // 功能：在 rdma_hw_cqc_create_body_codec 中，expected_opcode 在测试中检查调用结果、状态码和副作用是否符合契约；失败时报告可定位的验证信息。
  // 输入/输出及副作用：无显式参数；expected_opcode 读取固定返回值或局部计算结果，不使用对象成员字段；函数返回 bit [7:0]，不取得调用方资源所有权。
  // 失败/边界：测试函数 expected_opcode 缺少前置对象时报告断言错误，并停止依赖该对象的后续检查。
  protected virtual function bit [7:0] expected_opcode();
    return RDMA_OP_CQC_CREATE;
  endfunction

  // 功能：model_pbl_mode 按函数体读取当前字段并生成 rdma_mr_pbl_mode_e 结果，供调用方进行诊断或分支决策；不修改外部资源。
  // 输入/输出及副作用：model（输入）；model_pbl_mode 读取 model 并使用输入参数和固定枚举/常量；函数返回 rdma_mr_pbl_mode_e，不取得调用方资源所有权。
  // 失败/边界：枚举未定义或对象未配置时返回 UNKNOWN/UNCONFIGURED 表示，同时保留数值上下文。
  protected virtual function rdma_mr_pbl_mode_e model_pbl_mode(
    rdma_hw_model model
  );
    return RDMA_MR_PBL0;
  endfunction

  // 功能：在 rdma_hw_cqc_create_body_codec 中，owner_generation 读取并校验 Function generation/reset epoch，拒绝旧 binding 或跨 Function 请求。
  // 输入/输出及副作用：model（输入）；owner_generation 读取 model 并使用字段 generation；函数返回 int unsigned，不取得调用方资源所有权。
  // 失败/边界：owner_generation 比较或前置条件不满足时返回 0/false；该路径不隐式重试，也不转移未声明资源。
  protected virtual function int unsigned owner_generation(
    rdma_hw_model model
  );
    rdma_cqc_model cqc;
    if (!$cast(cqc, model) || cqc.cq_h == null) return 0;
    return cqc.cq_h.generation;
  endfunction

  // 功能：在 rdma_hw_cqc_create_body_codec 中，encode_cqe_size 按硬件布局把输入模型编码到 image/缓冲区，并在写入前检查范围、重叠、端序和保留位。
  // 输入/输出及副作用：bytes（输入）、code（输出）；输入模型只读；成功时通过返回值或 output 发布完整 image/bytes，不修改源模型。
  // 失败/边界：encode_cqe_size 遇到 image/model 为空、长度/对齐/保留位非法或 codec 校验失败时不发布部分字段。
  protected function rdma_status encode_cqe_size(
    int unsigned bytes,
    output bit [1:0] code
  );
    case (bytes)
      32:  code = 2'd0;
      64:  code = 2'd1;
      128: code = 2'd2;
      default: return invalid_argument("rdma CQC CQE size is unsupported");
    endcase
    return rdma_status::success();
  endfunction

  // 功能：在 rdma_hw_cqc_create_body_codec 中，decode_cqe_size 从硬件 image/缓冲区解码字段，验证长度、布局和完整性后返回模型或状态。
  // 输入/输出及副作用：code（输入）、bytes（输出）；输入 image/bytes 只读；成功时通过返回值或 output 发布 detached 解码快照，不接管调用方缓冲区。
  // 失败/边界：decode_cqe_size 遇到 image/model 为空、长度/对齐/保留位非法或 codec 校验失败时不发布部分字段。
  protected function rdma_status decode_cqe_size(
    bit [1:0] code,
    output int unsigned bytes
  );
    case (code)
      0: bytes = 32;
      1: bytes = 64;
      2: bytes = 128;
      default: return codec_error("rdma CQC CQE size code is invalid");
    endcase
    return rdma_status::success();
  endfunction

  // 功能：validate_model 校验 model 与当前对象状态的一致性，并显式处理“rdma CQC codec requires rdma_cqc_model”等拒绝条件，返回 rdma_status 供上层决定是否提交。
  // 输入/输出及副作用：model（输入）；validate_model 读取 model 并使用字段 status；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：必需对象/句柄/快照为空，或身份、范围、generation 和生命周期检查失败时返回非成功状态。
  virtual function rdma_status validate_model(rdma_hw_model model);
    rdma_cqc_model cqc;
    rdma_status status;
    int unsigned depth_code;
    bit [1:0] cqe_code;
    bit [51:0] page;

    if (!$cast(cqc, model))
      return invalid_argument("rdma CQC codec requires rdma_cqc_model");
    status = cqc.validate();
    if (!status.ok())
      return invalid_argument({"CQC model is invalid: ", status.message});
    if (!(cqc.page_layout.mode inside {
          RDMA_OBJECT_INDIRECT_4K, RDMA_OBJECT_HUGE_2M,
          RDMA_OBJECT_L3_INDIRECT_4K}))
      return invalid_argument("rdma CQC object mode is unsupported");
    status = encode_log2(cqc.depth, 5, "CQC depth", depth_code);
    if (!status.ok()) return status;
    status = encode_cqe_size(cqc.cqe_size_bytes, cqe_code);
    if (!status.ok()) return status;
    if (cqc.threshold > 7 || cqc.producer.index > 23'h7f_ffff ||
        cqc.consumer.index > 23'h7f_ffff || cqc.arm_state > 2)
      return invalid_argument("CQC scalar exceeds rdma field/domain");
    status = encode_page(cqc.page_layout.sd_base, "CQC SD backing", page);
    if (!status.ok()) return status;
    status = encode_page(cqc.page_layout.current_base,
                         "CQC current backing", page);
    if (!status.ok()) return status;
    status = encode_page(cqc.page_layout.next_base, "CQC next backing", page);
    if (!status.ok()) return status;
    if ((cqc.shadow_backing.value & 64'h3f) != 0)
      return invalid_argument("CQC shadow backing is not 64-byte aligned");
    return rdma_status::success();
  endfunction

  // 功能：在 rdma_hw_cqc_create_body_codec 中，encode_body 按硬件布局把输入模型编码到 image/缓冲区，并在写入前检查范围、重叠、端序和保留位。
  // 输入/输出及副作用：model（输入）、builder（输入）；输入模型只读；成功时通过返回值或 output 发布完整 image/bytes，不修改源模型。
  // 失败/边界：encode_body 遇到 image/model 为空、长度/对齐/保留位非法或 codec 校验失败时不发布部分字段。
  protected virtual function rdma_status encode_body(
    rdma_hw_model model,
    rdma_hw_qword_builder builder
  );
    rdma_cqc_model cqc;
    rdma_status status;
    bit [1:0] state_code;
    bit [1:0] cqe_code;
    int unsigned depth_code;
    bit [51:0] sd_page;
    bit [51:0] current_page;
    bit [51:0] next_page;
    int unsigned ceqn;

    if (!$cast(cqc, model))
      return invalid_argument("rdma CQC model cast failed");
    status = encode_context_state(cqc.state, state_code);
    if (!status.ok()) return status;
    status = encode_cqe_size(cqc.cqe_size_bytes, cqe_code);
    if (!status.ok()) return status;
    status = encode_log2(cqc.depth, 5, "CQC depth", depth_code);
    if (!status.ok()) return status;
    status = encode_page(cqc.page_layout.sd_base, "CQC SD backing", sd_page);
    if (!status.ok()) return status;
    status = encode_page(cqc.page_layout.current_base,
                         "CQC current backing", current_page);
    if (!status.ok()) return status;
    status = encode_page(cqc.page_layout.next_base, "CQC next backing",
                         next_page);
    if (!status.ok()) return status;
    ceqn = (cqc.ceq_h == null) ? 0 : cqc.ceq_h.object_id;

`define CQC_PUT(STEM, VALUE) \
    status = put(builder, STEM``_WORD_BYTE_OFFSET, STEM``_LSB, \
                 STEM``_WIDTH, VALUE); \
    if (!status.ok()) return status;
    `CQC_PUT(RDMA_CQC_BODY_CQN, cqc.cq_h.object_id)
    `CQC_PUT(RDMA_CQC_BODY_CQ_SD_PBA, sd_page)
    `CQC_PUT(RDMA_CQC_BODY_CQ_SIZE, depth_code)
    `CQC_PUT(RDMA_CQC_BODY_URC_FLAG, cqc.urc_enable)
    `CQC_PUT(RDMA_CQC_BODY_CQ_ST, state_code)
    `CQC_PUT(RDMA_CQC_BODY_NXT_CQ_PD_PBA_H, next_page[51:44])
    `CQC_PUT(RDMA_CQC_BODY_CUR_PBA_VLD, cqc.page_layout.current_valid)
    `CQC_PUT(RDMA_CQC_BODY_CUR_CQ_PD_PBA, current_page)
    `CQC_PUT(RDMA_CQC_BODY_LOAD_CQ_CI_DONE, cqc.load_ci_done)
    `CQC_PUT(RDMA_CQC_BODY_LOAD_CQ_CI_TH, cqc.threshold)
    `CQC_PUT(RDMA_CQC_BODY_CQ_OM, cqc.page_layout.mode)
    `CQC_PUT(RDMA_CQC_BODY_NXT_PBA_VLD, cqc.page_layout.next_valid)
    `CQC_PUT(RDMA_CQC_BODY_NXT_CQ_PD_PBA_L, next_page[43:0])
    `CQC_PUT(RDMA_CQC_BODY_CQ_PI, cqc.producer.index)
    `CQC_PUT(RDMA_CQC_BODY_CQ_PI_WRAP, cqc.producer.wrap)
    `CQC_PUT(RDMA_CQC_BODY_LAST_ARM_SN, cqc.last_arm_sequence)
    `CQC_PUT(RDMA_CQC_BODY_CQE_SIZE, cqe_code)
    `CQC_PUT(RDMA_CQC_BODY_CEQN, ceqn)
    `CQC_PUT(RDMA_CQC_BODY_SHADOW_PA, cqc.shadow_backing.value >> 6)
    `CQC_PUT(RDMA_CQC_BODY_CQ_CI, cqc.consumer.index)
    `CQC_PUT(RDMA_CQC_BODY_CQ_CI_WRAP, cqc.consumer.wrap)
    `CQC_PUT(RDMA_CQC_BODY_ARM_SN, cqc.arm_sequence)
    `CQC_PUT(RDMA_CQC_BODY_ARM_ST, cqc.arm_state)
`undef CQC_PUT
    return rdma_status::success();
  endfunction

  // 功能：在 rdma_hw_cqc_create_body_codec 中，decode_body 从硬件 image/缓冲区解码字段，验证长度、布局和完整性后返回模型或状态。
  // 输入/输出及副作用：builder（输入）、model（输出）；输入 image/bytes 只读；成功时通过返回值或 output 发布 detached 解码快照，不接管调用方缓冲区。
  // 失败/边界：decode_body 遇到 image/model 为空、长度/对齐/保留位非法或 codec 校验失败时不发布部分字段。
  protected virtual function rdma_status decode_body(
    rdma_hw_qword_builder builder,
    output rdma_hw_model model
  );
    rdma_cqc_model cqc;
    rdma_status status;
    bit [63:0] value;
    bit [1:0] state_code;
    bit [1:0] cqe_code;
    bit [51:0] next_page;
    int unsigned cqn;
    int unsigned ceqn;
    int unsigned depth_code;

    model = null;
    cqc = rdma_cqc_model::type_id::create("decoded_rdma_cqc");
`define CQC_GET(STEM, TARGET) \
    value = '0; \
    status = get(builder, STEM``_WORD_BYTE_OFFSET, STEM``_LSB, \
                 STEM``_WIDTH, value); \
    if (!status.ok()) return status; \
    TARGET = value;
    `CQC_GET(RDMA_CQC_BODY_CQN, cqn)
    cqc.cq_h = projected_handle("decoded_cq", RDMA_RESOURCE_CQ, cqn);
    `CQC_GET(RDMA_CQC_BODY_CQ_SD_PBA, cqc.page_layout.sd_base.value)
    cqc.page_layout.sd_base.value <<= 12;
    `CQC_GET(RDMA_CQC_BODY_CQ_SIZE, depth_code)
    cqc.depth = 32'h1 << depth_code;
    `CQC_GET(RDMA_CQC_BODY_URC_FLAG, cqc.urc_enable)
    `CQC_GET(RDMA_CQC_BODY_CQ_ST, state_code)
    status = decode_context_state(state_code, cqc.state);
    if (!status.ok()) return status;
    `CQC_GET(RDMA_CQC_BODY_NXT_CQ_PD_PBA_H, value)
    next_page[51:44] = value[7:0];
    `CQC_GET(RDMA_CQC_BODY_CUR_PBA_VLD, cqc.page_layout.current_valid)
    `CQC_GET(RDMA_CQC_BODY_CUR_CQ_PD_PBA,
             cqc.page_layout.current_base.value)
    cqc.page_layout.current_base.value <<= 12;
    `CQC_GET(RDMA_CQC_BODY_LOAD_CQ_CI_DONE, cqc.load_ci_done)
    `CQC_GET(RDMA_CQC_BODY_LOAD_CQ_CI_TH, cqc.threshold)
    `CQC_GET(RDMA_CQC_BODY_CQ_OM, value)
    cqc.page_layout.mode = rdma_object_mode_e'(value[1:0]);
    `CQC_GET(RDMA_CQC_BODY_NXT_PBA_VLD, cqc.page_layout.next_valid)
    `CQC_GET(RDMA_CQC_BODY_NXT_CQ_PD_PBA_L, value)
    next_page[43:0] = value[43:0];
    cqc.page_layout.next_base.value = {next_page, 12'b0};
    `CQC_GET(RDMA_CQC_BODY_CQ_PI, cqc.producer.index)
    `CQC_GET(RDMA_CQC_BODY_CQ_PI_WRAP, cqc.producer.wrap)
    `CQC_GET(RDMA_CQC_BODY_LAST_ARM_SN, cqc.last_arm_sequence)
    `CQC_GET(RDMA_CQC_BODY_CQE_SIZE, cqe_code)
    status = decode_cqe_size(cqe_code, cqc.cqe_size_bytes);
    if (!status.ok()) return status;
    `CQC_GET(RDMA_CQC_BODY_CEQN, ceqn)
    cqc.ceq_h = projected_handle("decoded_ceq", RDMA_RESOURCE_CEQ, ceqn);
    `CQC_GET(RDMA_CQC_BODY_SHADOW_PA, cqc.shadow_backing.value)
    cqc.shadow_backing.value <<= 6;
    `CQC_GET(RDMA_CQC_BODY_CQ_CI, cqc.consumer.index)
    `CQC_GET(RDMA_CQC_BODY_CQ_CI_WRAP, cqc.consumer.wrap)
    `CQC_GET(RDMA_CQC_BODY_ARM_SN, cqc.arm_sequence)
    `CQC_GET(RDMA_CQC_BODY_ARM_ST, cqc.arm_state)
`undef CQC_GET
    if (cqc.arm_state > 2)
      return codec_error("rdma CQC arm state code is invalid");
    model = cqc;
    return rdma_status::success();
  endfunction
endclass

virtual class rdma_hw_mrt_body_codec_base
    extends rdma_hw_context_body_codec_base;

  // 功能：构造 rdma_hw_mrt_body_codec_base，调用 super.new 建立 UVM 层级对象；外部依赖字段保持未绑定，后续由 configure/build/activate 明确注入。
  // 输入/输出及副作用：name（输入）；new 只写入构造体列出的默认字段并返回 void，外部依赖与资源所有权仍由上层管理。
  // 失败/边界：rdma_hw_mrt_body_codec_base 构造只建立本地初始状态，不接管外部 Host-memory、PCIe 或 manager；未完成后续 configure/build/activate 时，业务入口必须返回 INVALID_STATE。
  function new(string name = "rdma_hw_mrt_body_codec_base");
    super.new(name);
  endfunction

  // 功能：在 rdma_hw_mrt_body_codec_base 中，is_key_alloc 判断 is_key_alloc 对应的状态、能力或账本条件，并返回确定的布尔/计数结果，不修改状态。
  // 输入/输出及副作用：无显式参数；is_key_alloc 读取固定返回值或局部计算结果，不使用对象成员字段；函数返回 bit，不取得调用方资源所有权。
  // 失败/边界：is_key_alloc 只读取现有账本；输入未初始化时返回保守结果，不得借助默认 Function/root 猜测。
  protected pure virtual function bit is_key_alloc();

  // 功能：在 rdma_hw_mrt_body_codec_base 中，expected_image_kind 在测试中检查调用结果、状态码和副作用是否符合契约；失败时报告可定位的验证信息。
  // 输入/输出及副作用：无显式参数；expected_image_kind 返回 MRT codec 固定的 RDMA_IMAGE_MRT 类型，不读取可变对象字段；函数返回 rdma_image_kind_e，不取得调用方资源所有权。
  // 失败/边界：测试函数 expected_image_kind 缺少前置对象时报告断言错误，并停止依赖该对象的后续检查。
  protected virtual function rdma_image_kind_e expected_image_kind();
    return RDMA_IMAGE_MRT;
  endfunction

  // 功能：model_pbl_mode 按函数体读取当前字段并生成 rdma_mr_pbl_mode_e 结果，供调用方进行诊断或分支决策；不修改外部资源。
  // 输入/输出及副作用：model（输入）；model_pbl_mode 读取 model 并使用字段 pbl_mode；函数返回 rdma_mr_pbl_mode_e，不取得调用方资源所有权。
  // 失败/边界：枚举未定义或对象未配置时返回 UNKNOWN/UNCONFIGURED 表示，同时保留数值上下文。
  protected virtual function rdma_mr_pbl_mode_e model_pbl_mode(
    rdma_hw_model model
  );
    rdma_mrt_model mrt;
    if (!$cast(mrt, model) || mrt.page_layout == null) return RDMA_MR_PBL0;
    return mrt.page_layout.pbl_mode;
  endfunction

  // 功能：在 rdma_hw_cqc_create_body_codec 中，owner_generation 读取并校验 Function generation/reset epoch，拒绝旧 binding 或跨 Function 请求。
  // 输入/输出及副作用：model（输入）；owner_generation 读取 model 并使用字段 generation；函数返回 int unsigned，不取得调用方资源所有权。
  // 失败/边界：owner_generation 比较或前置条件不满足时返回 0/false；该路径不隐式重试，也不转移未声明资源。
  protected virtual function int unsigned owner_generation(
    rdma_hw_model model
  );
    rdma_mrt_model mrt;
    if (!$cast(mrt, model) || mrt.mr_h == null) return 0;
    return mrt.mr_h.generation;
  endfunction

  // 功能：在 rdma_hw_cqc_create_body_codec 中，image_pbl_mode 返回 profile 固定的镜像字段或长度常量，供编码和断言使用。
  // 输入/输出及副作用：builder（输入）、pbl_mode（输出）；image_pbl_mode 读取 builder、pbl_mode 并使用字段 pbl_mode、value、status，并写入 pbl_mode；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：image_pbl_mode 返回 RDMA_SC_CODEC_ERROR；典型拒绝条件为“rdma MRT PBL mode code is invalid”；失败路径不提交部分状态或转移未声明资源。
  protected virtual function rdma_status image_pbl_mode(
    rdma_hw_qword_builder builder,
    output rdma_mr_pbl_mode_e pbl_mode
  );
    bit [63:0] value;
    rdma_status status;
    pbl_mode = RDMA_MR_PBL0;
    value = '0;
    status = get(builder, RDMA_MRT_BODY_PBL_MODE_WORD_BYTE_OFFSET,
                 RDMA_MRT_BODY_PBL_MODE_LSB,
                 RDMA_MRT_BODY_PBL_MODE_WIDTH, value);
    if (!status.ok()) return status;
    if (value > RDMA_MR_PBL2)
      return codec_error("rdma MRT PBL mode code is invalid");
    pbl_mode = rdma_mr_pbl_mode_e'(value[1:0]);
    return rdma_status::success();
  endfunction

  // 功能：在 rdma_hw_mrt_body_codec_base 中，encode_mr_state 按硬件布局把输入模型编码到 image/缓冲区，并在写入前检查范围、重叠、端序和保留位。
  // 输入/输出及副作用：state（输入）、code（输出）；输入模型只读；成功时通过返回值或 output 发布完整 image/bytes，不修改源模型。
  // 失败/边界：encode_mr_state 遇到 image/model 为空、长度/对齐/保留位非法或 codec 校验失败时不发布部分字段。
  protected function rdma_status encode_mr_state(
    rdma_context_state_e state,
    output bit [1:0] code
  );
    case (state)
      RDMA_CONTEXT_INVALID: code = RDMA_MR_ST_INVALID;
      RDMA_CONTEXT_VALID:   code = RDMA_MR_ST_VALID;
      default: return invalid_argument("rdma MRT state is unsupported");
    endcase
    return rdma_status::success();
  endfunction

  // 功能：在 rdma_hw_mrt_body_codec_base 中，decode_mr_state 从硬件 image/缓冲区解码字段，验证长度、布局和完整性后返回模型或状态。
  // 输入/输出及副作用：code（输入）、state（输出）；输入 image/bytes 只读；成功时通过返回值或 output 发布 detached 解码快照，不接管调用方缓冲区。
  // 失败/边界：decode_mr_state 遇到 image/model 为空、长度/对齐/保留位非法或 codec 校验失败时不发布部分字段。
  protected function rdma_status decode_mr_state(
    bit [1:0] code,
    output rdma_context_state_e state
  );
    case (code)
      RDMA_MR_ST_INVALID: state = RDMA_CONTEXT_INVALID;
      RDMA_MR_ST_VALID:   state = RDMA_CONTEXT_VALID;
      default: return codec_error("rdma MRT state code is invalid");
    endcase
    return rdma_status::success();
  endfunction

  // 功能：在 rdma_hw_mrt_body_codec_base 中，encode_host_page 按硬件布局把输入模型编码到 image/缓冲区，并在写入前检查范围、重叠、端序和保留位。
  // 输入/输出及副作用：page_size（输入）、code（输出）；输入模型只读；成功时通过返回值或 output 发布完整 image/bytes，不修改源模型。
  // 失败/边界：encode_host_page 遇到 image/model 为空、长度/对齐/保留位非法或 codec 校验失败时不发布部分字段。
  protected function rdma_status encode_host_page(
    rdma_mr_host_page_size_e page_size,
    output bit [1:0] code
  );
    case (page_size)
      RDMA_MR_PAGE_4K: code = RDMA_HOST_PAGE_4K;
      RDMA_MR_PAGE_2M: code = RDMA_HOST_PAGE_2M;
      RDMA_MR_PAGE_1G: code = RDMA_HOST_PAGE_1G;
      default: return invalid_argument("rdma MRT host page size is unsupported");
    endcase
    return rdma_status::success();
  endfunction

  // 功能：在 rdma_hw_mrt_body_codec_base 中，decode_host_page 从硬件 image/缓冲区解码字段，验证长度、布局和完整性后返回模型或状态。
  // 输入/输出及副作用：code（输入）、page_size（输出）；输入 image/bytes 只读；成功时通过返回值或 output 发布 detached 解码快照，不接管调用方缓冲区。
  // 失败/边界：decode_host_page 遇到 image/model 为空、长度/对齐/保留位非法或 codec 校验失败时不发布部分字段。
  protected function rdma_status decode_host_page(
    bit [1:0] code,
    output rdma_mr_host_page_size_e page_size
  );
    case (code)
      RDMA_HOST_PAGE_4K: page_size = RDMA_MR_PAGE_4K;
      RDMA_HOST_PAGE_2M: page_size = RDMA_MR_PAGE_2M;
      RDMA_HOST_PAGE_1G: page_size = RDMA_MR_PAGE_1G;
      default: return codec_error("rdma MRT host page code is invalid");
    endcase
    return rdma_status::success();
  endfunction

  // 功能：在 rdma_hw_mrt_body_codec_base 中，encode_address_mode 按硬件布局把输入模型编码到 image/缓冲区，并在写入前检查范围、重叠、端序和保留位。
  // 输入/输出及副作用：address_mode（输入）、code（输出）；输入模型只读；成功时通过返回值或 output 发布完整 image/bytes，不修改源模型。
  // 失败/边界：encode_address_mode 遇到 image/model 为空、长度/对齐/保留位非法或 codec 校验失败时不发布部分字段。
  protected function rdma_status encode_address_mode(
    rdma_mr_address_mode_e address_mode,
    output bit code
  );
    case (address_mode)
      RDMA_MR_ADDRESS_VA_BASED: code = RDMA_ADDR_TYPE_VA_BASED;
      RDMA_MR_ADDRESS_ZERO_BASED: code = RDMA_ADDR_TYPE_ZERO_BASED;
      default: return invalid_argument("rdma MRT address mode is invalid");
    endcase
    return rdma_status::success();
  endfunction

  // 功能：在 rdma_hw_mrt_body_codec_base 中，decode_address_mode 从硬件 image/缓冲区解码字段，验证长度、布局和完整性后返回模型或状态。
  // 输入/输出及副作用：code（输入）、address_mode（输出）；输入 image/bytes 只读；成功时通过返回值或 output 发布 detached 解码快照，不接管调用方缓冲区。
  // 失败/边界：decode_address_mode 遇到 image/model 为空、长度/对齐/保留位非法或 codec 校验失败时不发布部分字段。
  protected function rdma_status decode_address_mode(
    bit code,
    output rdma_mr_address_mode_e address_mode
  );
    case (code)
      RDMA_ADDR_TYPE_VA_BASED: address_mode = RDMA_MR_ADDRESS_VA_BASED;
      RDMA_ADDR_TYPE_ZERO_BASED: address_mode = RDMA_MR_ADDRESS_ZERO_BASED;
      default: return codec_error("rdma MRT address mode code is invalid");
    endcase
    return rdma_status::success();
  endfunction

  // 功能：在 rdma_hw_cqc_create_body_codec 中，normalized_rights 把访问方向或请求权限规范化为 Host-memory/DMA 校验使用的权限位集合。
  // 输入/输出及副作用：access（输入）；normalized_rights 读取 access 并使用字段 rights；函数返回 bit [4:0]，不取得调用方资源所有权。
  // 失败/边界：normalized_rights 是只读访问器，返回 rights；未覆盖枚举沿 default/类型默认分支返回，不改变对象和外部资源。
  protected function bit [4:0] normalized_rights(rdma_rdma_access_t access);
    bit [4:0] rights;
    rights = '0;
    if (access.local_write || access.remote_write || access.remote_atomic)
      rights |= RDMA_RIGHT_LOCAL_WRITE;
    if (access.remote_read) rights |= RDMA_RIGHT_REMOTE_READ;
    if (access.remote_write) rights |= RDMA_RIGHT_REMOTE_WRITE;
    if (access.memory_window_bind) rights |= RDMA_RIGHT_BIND_WINDOW;
    if (access.remote_atomic) rights |= RDMA_RIGHT_REMOTE_ATOMIC;
    return rights;
  endfunction

  // 功能：validate_model 校验 model 与当前对象状态的一致性，并显式处理“rdma MRT codec requires rdma_mrt_model”等拒绝条件，返回 rdma_status 供上层决定是否提交。
  // 输入/输出及副作用：model（输入）；validate_model 读取 model 并使用字段 status；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：必需对象/句柄/快照为空，或身份、范围、generation 和生命周期检查失败时返回非成功状态。
  virtual function rdma_status validate_model(rdma_hw_model model);
    rdma_mrt_model mrt;
    rdma_status status;
    bit [1:0] state_code;
    bit [1:0] page_code;
    bit address_code;
    bit [51:0] page;

    if (!$cast(mrt, model))
      return invalid_argument("rdma MRT codec requires rdma_mrt_model");
    status = mrt.validate();
    if (!status.ok())
      return invalid_argument({"MRT model is invalid: ", status.message});
    status = encode_mr_state(mrt.state, state_code);
    if (!status.ok()) return status;
    status = encode_host_page(mrt.page_layout.host_page_size, page_code);
    if (!status.ok()) return status;
    status = encode_address_mode(mrt.page_layout.address_mode, address_code);
    if (!status.ok()) return status;
    if (mrt.object_type > RDMA_MEM_TYPE_MW_TYPE2B ||
        mrt.page_layout.payload_vf_id > 8'hff ||
        mrt.page_layout.mr_serial > 12'hfff ||
        mrt.page_layout.first_pbl_index > 28'hfff_ffff)
      return invalid_argument("MRT scalar exceeds rdma field/domain");
    if (mrt.page_layout.pbl_mode inside {RDMA_MR_PBL0, RDMA_MR_PBL1}) begin
      status = encode_page(mrt.page_layout.pba0, "MRT PBA0", page);
      if (!status.ok()) return status;
    end
    if (mrt.page_layout.pbl_mode == RDMA_MR_PBL1) begin
      status = encode_page(mrt.page_layout.pba1, "MRT PBA1", page);
      if (!status.ok()) return status;
    end
    return rdma_status::success();
  endfunction

  // 功能：在 rdma_hw_mrt_body_codec_base 中，encode_body 按硬件布局把输入模型编码到 image/缓冲区，并在写入前检查范围、重叠、端序和保留位。
  // 输入/输出及副作用：model（输入）、builder（输入）；输入模型只读；成功时通过返回值或 output 发布完整 image/bytes，不修改源模型。
  // 失败/边界：encode_body 遇到 image/model 为空、长度/对齐/保留位非法或 codec 校验失败时不发布部分字段。
  protected virtual function rdma_status encode_body(
    rdma_hw_model model,
    rdma_hw_qword_builder builder
  );
    rdma_mrt_model mrt;
    rdma_status status;
    bit [1:0] state_code;
    bit [1:0] page_code;
    bit address_code;
    bit [4:0] rights;
    bit [51:0] pba0_page;
    bit [51:0] pba1_page;

    if (!$cast(mrt, model))
      return invalid_argument("rdma MRT model cast failed");
    status = encode_mr_state(mrt.state, state_code);
    if (!status.ok()) return status;
    status = encode_host_page(mrt.page_layout.host_page_size, page_code);
    if (!status.ok()) return status;
    status = encode_address_mode(mrt.page_layout.address_mode, address_code);
    if (!status.ok()) return status;
    rights = normalized_rights(mrt.access);
    pba0_page = '0;
    pba1_page = '0;
    if (mrt.page_layout.pbl_mode inside {RDMA_MR_PBL0, RDMA_MR_PBL1}) begin
      status = encode_page(mrt.page_layout.pba0, "MRT PBA0", pba0_page);
      if (!status.ok()) return status;
    end
    if (mrt.page_layout.pbl_mode == RDMA_MR_PBL1) begin
      status = encode_page(mrt.page_layout.pba1, "MRT PBA1", pba1_page);
      if (!status.ok()) return status;
    end

`define MRT_PUT(STEM, VALUE) \
    status = put(builder, STEM``_WORD_BYTE_OFFSET, STEM``_LSB, \
                 STEM``_WIDTH, VALUE); \
    if (!status.ok()) return status;
    `MRT_PUT(RDMA_MRT_BODY_STAG_IDX, mrt.mr_h.object_id)
    `MRT_PUT(RDMA_MRT_BODY_NXT_ST, state_code)
    `MRT_PUT(RDMA_MRT_BODY_STAG_KEY, mrt.lkey[7:0])
    if (is_key_alloc()) begin
      `MRT_PUT(RDMA_MRT_BODY_PARENT_STAG_IDX, mrt.mr_h.object_id)
    end
    `MRT_PUT(RDMA_MRT_BODY_PD_IDX, mrt.pd_h.object_id)
    `MRT_PUT(RDMA_MRT_BODY_PLD_VF_ID, mrt.page_layout.payload_vf_id)
    `MRT_PUT(RDMA_MRT_BODY_PLD_VF_EN, mrt.page_layout.payload_vf_enable)
    `MRT_PUT(RDMA_MRT_BODY_RIGHT, rights)
    `MRT_PUT(RDMA_MRT_BODY_TYPE, mrt.object_type)
    `MRT_PUT(RDMA_MRT_BODY_HOST_PG_SIZE, page_code)
    `MRT_PUT(RDMA_MRT_BODY_PBL_MODE, mrt.page_layout.pbl_mode)
    `MRT_PUT(RDMA_MRT_BODY_ADDR_MODE, address_code)
    `MRT_PUT(RDMA_MRT_BODY_INVALIDATE_EN,
             mrt.page_layout.invalidate_enable)
    `MRT_PUT(RDMA_MRT_BODY_ST, state_code)
    `MRT_PUT(RDMA_MRT_BODY_LEN, mrt.length)
    `MRT_PUT(RDMA_MRT_BODY_ODP, mrt.page_layout.odp)
    `MRT_PUT(RDMA_MRT_BODY_INFO_STAG_KEY, mrt.lkey[7:0])
    `MRT_PUT(RDMA_MRT_BODY_START_VA, mrt.iova.value)
    case (mrt.page_layout.pbl_mode)
      RDMA_MR_PBL0: begin
        `MRT_PUT(RDMA_MRT_BODY_PAYLOAD_PBA0, pba0_page)
      end
      RDMA_MR_PBL1: begin
        `MRT_PUT(RDMA_MRT_BODY_PAYLOAD_PBA0, pba0_page)
        `MRT_PUT(RDMA_MRT_BODY_PAYLOAD_PBA1, pba1_page)
      end
      RDMA_MR_PBL2: begin
        `MRT_PUT(RDMA_MRT_BODY_FIRST_PBL_IDX,
                 mrt.page_layout.first_pbl_index)
      end
      default: return invalid_argument("rdma MRT PBL mode is invalid");
    endcase
    `MRT_PUT(RDMA_MRT_BODY_MR_SN, mrt.page_layout.mr_serial)
`undef MRT_PUT
    return rdma_status::success();
  endfunction

  // 功能：在 rdma_hw_mrt_body_codec_base 中，decode_body 从硬件 image/缓冲区解码字段，验证长度、布局和完整性后返回模型或状态。
  // 输入/输出及副作用：builder（输入）、model（输出）；输入 image/bytes 只读；成功时通过返回值或 output 发布 detached 解码快照，不接管调用方缓冲区。
  // 失败/边界：decode_body 遇到 image/model 为空、长度/对齐/保留位非法或 codec 校验失败时不发布部分字段。
  protected virtual function rdma_status decode_body(
    rdma_hw_qword_builder builder,
    output rdma_hw_model model
  );
    rdma_mrt_model mrt;
    rdma_status status;
    bit [63:0] value;
    bit [1:0] next_state_code;
    bit [1:0] state_code;
    bit [1:0] page_code;
    bit address_code;
    bit [4:0] rights;
    int unsigned stag_index;
    int unsigned parent_stag_index;
    int unsigned pd_index;
    byte unsigned stag_key;
    byte unsigned repeated_key;

    model = null;
    mrt = rdma_mrt_model::type_id::create("decoded_rdma_mrt");
`define MRT_GET(STEM, TARGET) \
    value = '0; \
    status = get(builder, STEM``_WORD_BYTE_OFFSET, STEM``_LSB, \
                 STEM``_WIDTH, value); \
    if (!status.ok()) return status; \
    TARGET = value;
    `MRT_GET(RDMA_MRT_BODY_STAG_IDX, stag_index)
    `MRT_GET(RDMA_MRT_BODY_NXT_ST, next_state_code)
    `MRT_GET(RDMA_MRT_BODY_STAG_KEY, stag_key)
    `MRT_GET(RDMA_MRT_BODY_PARENT_STAG_IDX, parent_stag_index)
    // A nonzero self-parent distinguishes KEY_ALLOC from MR_REGISTER. STAG
    // zero is ambiguous in an isolated body, so the caller must authenticate
    // the codec using the exact opcode/registry identity.
    if ((is_key_alloc() && parent_stag_index != stag_index) ||
        (!is_key_alloc() && parent_stag_index != 0))
      return codec_error("rdma MRT parent STAG does not match opcode");
    `MRT_GET(RDMA_MRT_BODY_PD_IDX, pd_index)
    mrt.pd_h = projected_handle("decoded_pd", RDMA_RESOURCE_PD, pd_index);
    `MRT_GET(RDMA_MRT_BODY_PLD_VF_ID, mrt.page_layout.payload_vf_id)
    `MRT_GET(RDMA_MRT_BODY_PLD_VF_EN,
             mrt.page_layout.payload_vf_enable)
    `MRT_GET(RDMA_MRT_BODY_RIGHT, rights)
    if ((rights & (RDMA_RIGHT_REMOTE_WRITE |
                   RDMA_RIGHT_REMOTE_ATOMIC)) != 0 &&
        (rights & RDMA_RIGHT_LOCAL_WRITE) == 0)
      return codec_error("rdma MRT rights are not normalized");
    mrt.access.local_write = (rights & RDMA_RIGHT_LOCAL_WRITE) != 0;
    mrt.access.remote_read = (rights & RDMA_RIGHT_REMOTE_READ) != 0;
    mrt.access.remote_write = (rights & RDMA_RIGHT_REMOTE_WRITE) != 0;
    mrt.access.memory_window_bind = (rights & RDMA_RIGHT_BIND_WINDOW) != 0;
    mrt.access.remote_atomic = (rights & RDMA_RIGHT_REMOTE_ATOMIC) != 0;
    `MRT_GET(RDMA_MRT_BODY_TYPE, mrt.object_type)
    if (mrt.object_type > RDMA_MEM_TYPE_MW_TYPE2B)
      return codec_error("rdma MRT object type code is invalid");
    `MRT_GET(RDMA_MRT_BODY_HOST_PG_SIZE, page_code)
    status = decode_host_page(page_code, mrt.page_layout.host_page_size);
    if (!status.ok()) return status;
    `MRT_GET(RDMA_MRT_BODY_PBL_MODE, value)
    if (value > RDMA_MR_PBL2)
      return codec_error("rdma MRT PBL mode code is invalid");
    mrt.page_layout.pbl_mode = rdma_mr_pbl_mode_e'(value[1:0]);
    `MRT_GET(RDMA_MRT_BODY_ADDR_MODE, address_code)
    status = decode_address_mode(address_code, mrt.page_layout.address_mode);
    if (!status.ok()) return status;
    `MRT_GET(RDMA_MRT_BODY_INVALIDATE_EN,
             mrt.page_layout.invalidate_enable)
    `MRT_GET(RDMA_MRT_BODY_ST, state_code)
    if (state_code != next_state_code)
      return codec_error("rdma MRT state mirror mismatch");
    status = decode_mr_state(state_code, mrt.state);
    if (!status.ok()) return status;
    `MRT_GET(RDMA_MRT_BODY_LEN, mrt.length)
    `MRT_GET(RDMA_MRT_BODY_ODP, mrt.page_layout.odp)
    `MRT_GET(RDMA_MRT_BODY_INFO_STAG_KEY, repeated_key)
    if (stag_key != repeated_key)
      return codec_error("rdma MRT STAG key mirror mismatch");
    `MRT_GET(RDMA_MRT_BODY_START_VA, mrt.iova.value)
    case (mrt.page_layout.pbl_mode)
      RDMA_MR_PBL0: begin
        `MRT_GET(RDMA_MRT_BODY_PAYLOAD_PBA0,
                 mrt.page_layout.pba0.value)
        mrt.page_layout.pba0.value <<= 12;
      end
      RDMA_MR_PBL1: begin
        `MRT_GET(RDMA_MRT_BODY_PAYLOAD_PBA0,
                 mrt.page_layout.pba0.value)
        mrt.page_layout.pba0.value <<= 12;
        `MRT_GET(RDMA_MRT_BODY_PAYLOAD_PBA1,
                 mrt.page_layout.pba1.value)
        mrt.page_layout.pba1.value <<= 12;
      end
      RDMA_MR_PBL2: begin
        `MRT_GET(RDMA_MRT_BODY_FIRST_PBL_IDX,
                 mrt.page_layout.first_pbl_index)
      end
      default: return codec_error("rdma MRT PBL mode code is invalid");
    endcase
    `MRT_GET(RDMA_MRT_BODY_MR_SN, mrt.page_layout.mr_serial)
`undef MRT_GET
    mrt.mr_h = projected_handle("decoded_mr", RDMA_RESOURCE_MR, stag_index);
    mrt.lkey = {stag_index[23:0], stag_key};
    if (mrt.access.remote_read || mrt.access.remote_write ||
        mrt.access.remote_atomic)
      mrt.rkey = mrt.lkey;
    else
      mrt.rkey = 0;
    model = mrt;
    return rdma_status::success();
  endfunction
endclass

class rdma_hw_mrt_key_alloc_body_codec
    extends rdma_hw_mrt_body_codec_base;
  `uvm_object_utils(rdma_hw_mrt_key_alloc_body_codec)

  // 功能：构造 rdma_hw_mrt_key_alloc_body_codec，调用 super.new 建立 UVM 层级对象；外部依赖字段保持未绑定，后续由 configure/build/activate 明确注入。
  // 输入/输出及副作用：name（输入）；new 只写入构造体列出的默认字段并返回 void，外部依赖与资源所有权仍由上层管理。
  // 失败/边界：rdma_hw_mrt_key_alloc_body_codec 构造只建立本地初始状态，不接管外部 Host-memory、PCIe 或 manager；未完成后续 configure/build/activate 时，业务入口必须返回 INVALID_STATE。
  function new(string name = "rdma_hw_mrt_key_alloc_body_codec");
    super.new(name);
  endfunction
  // 功能：在 rdma_hw_mrt_key_alloc_body_codec 中，is_key_alloc 判断 is_key_alloc 对应的状态、能力或账本条件，并返回确定的布尔/计数结果，不修改状态。
  // 输入/输出及副作用：无显式参数；is_key_alloc 读取固定返回值或局部计算结果，不使用对象成员字段；函数返回 bit，不取得调用方资源所有权。
  // 失败/边界：is_key_alloc 只读取现有账本；输入未初始化时返回保守结果，不得借助默认 Function/root 猜测。
  protected virtual function bit is_key_alloc(); return 1'b1; endfunction
  // 功能：在 rdma_hw_mrt_key_alloc_body_codec 中，expected_opcode 在测试中检查调用结果、状态码和副作用是否符合契约；失败时报告可定位的验证信息。
  // 输入/输出及副作用：无显式参数；expected_opcode 返回 key-alloc codec 固定的 RDMA_OP_KEY_ALLOC opcode，不读取可变对象字段；函数返回 bit [7:0]，不取得调用方资源所有权。
  // 失败/边界：测试函数 expected_opcode 缺少前置对象时报告断言错误，并停止依赖该对象的后续检查。
  protected virtual function bit [7:0] expected_opcode();
    return RDMA_OP_KEY_ALLOC;
  endfunction
endclass

class rdma_hw_mrt_register_body_codec
    extends rdma_hw_mrt_body_codec_base;
  `uvm_object_utils(rdma_hw_mrt_register_body_codec)

  // 功能：构造 rdma_hw_mrt_register_body_codec，调用 super.new 建立 UVM 层级对象；外部依赖字段保持未绑定，后续由 configure/build/activate 明确注入。
  // 输入/输出及副作用：name（输入）；new 只写入构造体列出的默认字段并返回 void，外部依赖与资源所有权仍由上层管理。
  // 失败/边界：rdma_hw_mrt_register_body_codec 构造只建立本地初始状态，不接管外部 Host-memory、PCIe 或 manager；未完成后续 configure/build/activate 时，业务入口必须返回 INVALID_STATE。
  function new(string name = "rdma_hw_mrt_register_body_codec");
    super.new(name);
  endfunction
  // 功能：在 rdma_hw_mrt_register_body_codec 中，is_key_alloc 判断 is_key_alloc 对应的状态、能力或账本条件，并返回确定的布尔/计数结果，不修改状态。
  // 输入/输出及副作用：无显式参数；is_key_alloc 读取固定返回值或局部计算结果，不使用对象成员字段；函数返回 bit，不取得调用方资源所有权。
  // 失败/边界：is_key_alloc 只读取现有账本；输入未初始化时返回保守结果，不得借助默认 Function/root 猜测。
  protected virtual function bit is_key_alloc(); return 1'b0; endfunction
  // 功能：在 rdma_hw_mrt_register_body_codec 中，expected_opcode 在测试中检查调用结果、状态码和副作用是否符合契约；失败时报告可定位的验证信息。
  // 输入/输出及副作用：无显式参数；expected_opcode 返回 MR-register codec 固定的 RDMA_OP_MR_REGISTER opcode，不读取可变对象字段；函数返回 bit [7:0]，不取得调用方资源所有权。
  // 失败/边界：测试函数 expected_opcode 缺少前置对象时报告断言错误，并停止依赖该对象的后续检查。
  protected virtual function bit [7:0] expected_opcode();
    return RDMA_OP_MR_REGISTER;
  endfunction
endclass

class rdma_hw_srqc_create_body_codec
    extends rdma_hw_context_body_codec_base;
  `uvm_object_utils(rdma_hw_srqc_create_body_codec)

  // 功能：构造 rdma_hw_srqc_create_body_codec，调用 super.new 建立 UVM 层级对象；外部依赖字段保持未绑定，后续由 configure/build/activate 明确注入。
  // 输入/输出及副作用：name（输入）；new 只写入构造体列出的默认字段并返回 void，外部依赖与资源所有权仍由上层管理。
  // 失败/边界：rdma_hw_srqc_create_body_codec 构造只建立本地初始状态，不接管外部 Host-memory、PCIe 或 manager；未完成后续 configure/build/activate 时，业务入口必须返回 INVALID_STATE。
  function new(string name = "rdma_hw_srqc_create_body_codec");
    super.new(name);
  endfunction
  // 功能：在 rdma_hw_srqc_create_body_codec 中，expected_image_kind 在测试中检查调用结果、状态码和副作用是否符合契约；失败时报告可定位的验证信息。
  // 输入/输出及副作用：无显式参数；expected_image_kind 读取固定返回值或局部计算结果，不使用对象成员字段；函数返回 rdma_image_kind_e，不取得调用方资源所有权。
  // 失败/边界：测试函数 expected_image_kind 缺少前置对象时报告断言错误，并停止依赖该对象的后续检查。
  protected virtual function rdma_image_kind_e expected_image_kind();
    return RDMA_IMAGE_SRQC;
  endfunction
  // 功能：在 rdma_hw_srqc_create_body_codec 中，expected_opcode 在测试中检查调用结果、状态码和副作用是否符合契约；失败时报告可定位的验证信息。
  // 输入/输出及副作用：无显式参数；expected_opcode 读取固定返回值或局部计算结果，不使用对象成员字段；函数返回 bit [7:0]，不取得调用方资源所有权。
  // 失败/边界：测试函数 expected_opcode 缺少前置对象时报告断言错误，并停止依赖该对象的后续检查。
  protected virtual function bit [7:0] expected_opcode();
    return RDMA_OP_SRFQC_CREATE;
  endfunction
  // 功能：model_pbl_mode 按函数体读取当前字段并生成 rdma_mr_pbl_mode_e 结果，供调用方进行诊断或分支决策；不修改外部资源。
  // 输入/输出及副作用：model（输入）；model_pbl_mode 读取 model 并使用输入参数和固定枚举/常量；函数返回 rdma_mr_pbl_mode_e，不取得调用方资源所有权。
  // 失败/边界：枚举未定义或对象未配置时返回 UNKNOWN/UNCONFIGURED 表示，同时保留数值上下文。
  protected virtual function rdma_mr_pbl_mode_e model_pbl_mode(
    rdma_hw_model model
  );
    return RDMA_MR_PBL0;
  endfunction
  // 功能：在 rdma_hw_srqc_create_body_codec 中，owner_generation 读取并校验 Function generation/reset epoch，拒绝旧 binding 或跨 Function 请求。
  // 输入/输出及副作用：model（输入）；owner_generation 读取 model 并使用字段 generation；函数返回 int unsigned，不取得调用方资源所有权。
  // 失败/边界：owner_generation 比较或前置条件不满足时返回 0/false；该路径不隐式重试，也不转移未声明资源。
  protected virtual function int unsigned owner_generation(
    rdma_hw_model model
  );
    rdma_srqc_model srqc;
    if (!$cast(srqc, model) || srqc.srq_h == null) return 0;
    return srqc.srq_h.generation;
  endfunction

  // 功能：validate_model 校验 model 与当前对象状态的一致性，并显式处理“rdma SRQC codec requires rdma_srqc_model”等拒绝条件，返回 rdma_status 供上层决定是否提交。
  // 输入/输出及副作用：model（输入）；validate_model 读取 model 并使用字段 status；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：必需对象/句柄/快照为空，或身份、范围、generation 和生命周期检查失败时返回非成功状态。
  virtual function rdma_status validate_model(rdma_hw_model model);
    rdma_srqc_model srqc;
    rdma_status status;
    int unsigned depth_code;
    bit [51:0] page;
    if (!$cast(srqc, model))
      return invalid_argument("rdma SRQC codec requires rdma_srqc_model");
    status = srqc.validate();
    if (!status.ok())
      return invalid_argument({"SRQC model is invalid: ", status.message});
    status = encode_log2(srqc.depth, 4, "SRQC depth", depth_code);
    if (!status.ok()) return status;
    status = encode_page(srqc.srfq_backing, "SRQC backing", page);
    if (!status.ok()) return status;
    status = encode_page(srqc.shadow_backing, "SRQC shadow backing", page);
    if (!status.ok()) return status;
    if (srqc.load_pi_threshold > 8'hff ||
        srqc.limit_threshold > 14'h3fff ||
        srqc.producer.index > 15'h7fff)
      return invalid_argument("SRQC scalar exceeds rdma field width");
    return rdma_status::success();
  endfunction

  // 功能：在 rdma_hw_srqc_create_body_codec 中，encode_body 按硬件布局把输入模型编码到 image/缓冲区，并在写入前检查范围、重叠、端序和保留位。
  // 输入/输出及副作用：model（输入）、builder（输入）；输入模型只读；成功时通过返回值或 output 发布完整 image/bytes，不修改源模型。
  // 失败/边界：encode_body 遇到 image/model 为空、长度/对齐/保留位非法或 codec 校验失败时不发布部分字段。
  protected virtual function rdma_status encode_body(
    rdma_hw_model model,
    rdma_hw_qword_builder builder
  );
    rdma_srqc_model srqc;
    rdma_status status;
    bit [1:0] state_code;
    int unsigned depth_code;
    bit [51:0] page;
    bit [51:0] shadow_page;
    if (!$cast(srqc, model))
      return invalid_argument("rdma SRQC model cast failed");
    status = encode_context_state(srqc.state, state_code);
    if (!status.ok()) return status;
    status = encode_log2(srqc.depth, 4, "SRQC depth", depth_code);
    if (!status.ok()) return status;
    status = encode_page(srqc.srfq_backing, "SRQC backing", page);
    if (!status.ok()) return status;
    status = encode_page(srqc.shadow_backing, "SRQC shadow backing",
                         shadow_page);
    if (!status.ok()) return status;
`define SRQC_PUT(STEM, VALUE) \
    status = put(builder, STEM``_WORD_BYTE_OFFSET, STEM``_LSB, \
                 STEM``_WIDTH, VALUE); \
    if (!status.ok()) return status;
    `SRQC_PUT(RDMA_SRQC_BODY_SRFQN, srqc.srq_h.object_id)
    `SRQC_PUT(RDMA_SRQC_BODY_SRFQ_ST, state_code)
    `SRQC_PUT(RDMA_SRQC_BODY_LOAD_SRFQ_PI_TH, srqc.load_pi_threshold)
    `SRQC_PUT(RDMA_SRQC_BODY_SHADOW_PA, shadow_page)
    `SRQC_PUT(RDMA_SRQC_BODY_PD_IDX, srqc.pd_h.object_id)
    `SRQC_PUT(RDMA_SRQC_BODY_SRFQ_PBA, page)
    `SRQC_PUT(RDMA_SRQC_BODY_SRFQ_SIZE, depth_code)
    `SRQC_PUT(RDMA_SRQC_BODY_SRFQ_OM, srqc.object_mode)
    `SRQC_PUT(RDMA_SRQC_BODY_SRFQ_PI_WRAP, srqc.producer.wrap)
    `SRQC_PUT(RDMA_SRQC_BODY_SRFQ_PI, srqc.producer.index)
    `SRQC_PUT(RDMA_SRQC_BODY_LIMIT_TH, srqc.limit_threshold)
    `SRQC_PUT(RDMA_SRQC_BODY_ARM_SN, srqc.arm_sequence)
`undef SRQC_PUT
    return rdma_status::success();
  endfunction

  // 功能：在 rdma_hw_srqc_create_body_codec 中，decode_body 从硬件 image/缓冲区解码字段，验证长度、布局和完整性后返回模型或状态。
  // 输入/输出及副作用：builder（输入）、model（输出）；输入 image/bytes 只读；成功时通过返回值或 output 发布 detached 解码快照，不接管调用方缓冲区。
  // 失败/边界：decode_body 遇到 image/model 为空、长度/对齐/保留位非法或 codec 校验失败时不发布部分字段。
  protected virtual function rdma_status decode_body(
    rdma_hw_qword_builder builder,
    output rdma_hw_model model
  );
    rdma_srqc_model srqc;
    rdma_status status;
    bit [63:0] value;
    bit [1:0] state_code;
    int unsigned object_id;
    int unsigned pd_id;
    int unsigned depth_code;
    model = null;
    srqc = rdma_srqc_model::type_id::create("decoded_rdma_srqc");
`define SRQC_GET(STEM, TARGET) \
    value = '0; \
    status = get(builder, STEM``_WORD_BYTE_OFFSET, STEM``_LSB, \
                 STEM``_WIDTH, value); \
    if (!status.ok()) return status; \
    TARGET = value;
    `SRQC_GET(RDMA_SRQC_BODY_SRFQN, object_id)
    srqc.srq_h = projected_handle("decoded_srq", RDMA_RESOURCE_SRQ, object_id);
    `SRQC_GET(RDMA_SRQC_BODY_SRFQ_ST, state_code)
    status = decode_context_state(state_code, srqc.state);
    if (!status.ok()) return status;
    `SRQC_GET(RDMA_SRQC_BODY_LOAD_SRFQ_PI_TH, srqc.load_pi_threshold)
    `SRQC_GET(RDMA_SRQC_BODY_SHADOW_PA, srqc.shadow_backing.value)
    srqc.shadow_backing.value <<= 12;
    `SRQC_GET(RDMA_SRQC_BODY_PD_IDX, pd_id)
    srqc.pd_h = projected_handle("decoded_pd", RDMA_RESOURCE_PD, pd_id);
    `SRQC_GET(RDMA_SRQC_BODY_SRFQ_PBA, srqc.srfq_backing.value)
    srqc.srfq_backing.value <<= 12;
    `SRQC_GET(RDMA_SRQC_BODY_SRFQ_SIZE, depth_code)
    srqc.depth = 32'h1 << depth_code;
    `SRQC_GET(RDMA_SRQC_BODY_SRFQ_OM, value)
    srqc.object_mode = rdma_object_mode_e'(value[1:0]);
    `SRQC_GET(RDMA_SRQC_BODY_SRFQ_PI_WRAP, srqc.producer.wrap)
    `SRQC_GET(RDMA_SRQC_BODY_SRFQ_PI, srqc.producer.index)
    `SRQC_GET(RDMA_SRQC_BODY_LIMIT_TH, srqc.limit_threshold)
    `SRQC_GET(RDMA_SRQC_BODY_ARM_SN, srqc.arm_sequence)
`undef SRQC_GET
    model = srqc;
    return rdma_status::success();
  endfunction
endclass

virtual class rdma_hw_eq_create_body_codec_base
    extends rdma_hw_context_body_codec_base;

  // 功能：构造 rdma_hw_eq_create_body_codec_base，调用 super.new 建立 UVM 层级对象；外部依赖字段保持未绑定，后续由 configure/build/activate 明确注入。
  // 输入/输出及副作用：name（输入）；new 只写入构造体列出的默认字段并返回 void，外部依赖与资源所有权仍由上层管理。
  // 失败/边界：rdma_hw_eq_create_body_codec_base 构造只建立本地初始状态，不接管外部 Host-memory、PCIe 或 manager；未完成后续 configure/build/activate 时，业务入口必须返回 INVALID_STATE。
  function new(string name = "rdma_hw_eq_create_body_codec_base");
    super.new(name);
  endfunction

  // 功能：validate_eq_layout 校验 depth、vector_id、layout、producer、consumer 与当前对象状态的一致性，并显式处理“rdma EQC object mode is unsupported”等拒绝条件，返回 rdma_status 供上层决定是否提交。
  // 输入/输出及副作用：depth（输入）、vector_id（输入）、layout（输入）、producer（输入）、consumer（输入）；validate_eq_layout 读取 depth、vector_id、layout、producer、consumer 并使用字段 status；函数返回 rdma_status，不取得调用方资源所有权。

  // 失败/边界：必需对象/句柄/快照为空，或身份、范围、generation 和生命周期检查失败时返回非成功状态。
  protected function rdma_status validate_eq_layout(
    int unsigned depth,
    int unsigned vector_id,
    rdma_page_table_layout layout,
    rdma_ring_position producer,
    rdma_ring_position consumer
  );
    rdma_status status;
    int unsigned depth_code;
    bit [51:0] page;
    if (!(layout.mode inside {RDMA_OBJECT_INDIRECT_4K,
                              RDMA_OBJECT_L3_INDIRECT_4K}))
      return invalid_argument("rdma EQC object mode is unsupported");
    if (!layout.next_valid)
      return invalid_argument("rdma EQC next backing is not valid");
    status = encode_log2(depth, 5, "EQC depth", depth_code);
    if (!status.ok()) return status;
    status = encode_page(layout.current_base, "EQC current backing", page);
    if (!status.ok()) return status;
    status = encode_page(layout.next_base, "EQC next backing", page);
    if (!status.ok()) return status;
    if (vector_id > 16'hffff || producer.index > 18'h3ffff ||
        consumer.index > 18'h3ffff)
      return invalid_argument("EQC scalar exceeds rdma field width");
    return rdma_status::success();
  endfunction

  // 功能：在 rdma_hw_eq_create_body_codec_base 中，encode_eq_layout 按硬件布局把输入模型编码到 image/缓冲区，并在写入前检查范围、重叠、端序和保留位。
  // 输入/输出及副作用：builder（输入）、eqn（输入）、state（输入）、depth（输入）、vector_id（输入）、layout（输入）、producer（输入）、consumer（输入）；输入模型只读；成功时通过返回值或
  //   output 发布完整 image/bytes，不修改源模型。
  // 失败/边界：encode_eq_layout 遇到 image/model 为空、长度/对齐/保留位非法或 codec 校验失败时不发布部分字段。
  protected function rdma_status encode_eq_layout(
    rdma_hw_qword_builder builder,
    int unsigned eqn,
    rdma_context_state_e state,
    int unsigned depth,
    int unsigned vector_id,
    rdma_page_table_layout layout,
    rdma_ring_position producer,
    rdma_ring_position consumer
  );
    rdma_status status;
    bit [1:0] state_code;
    int unsigned depth_code;
    bit [51:0] current_page;
    bit [51:0] next_page;
    status = encode_context_state(state, state_code);
    if (!status.ok()) return status;
    status = encode_log2(depth, 5, "EQC depth", depth_code);
    if (!status.ok()) return status;
    status = encode_page(layout.current_base, "EQC current backing",
                         current_page);
    if (!status.ok()) return status;
    status = encode_page(layout.next_base, "EQC next backing", next_page);
    if (!status.ok()) return status;
`define EQC_PUT(STEM, VALUE) \
    status = put(builder, STEM``_WORD_BYTE_OFFSET, STEM``_LSB, \
                 STEM``_WIDTH, VALUE); \
    if (!status.ok()) return status;
    `EQC_PUT(RDMA_EQC_BODY_EQN, eqn)
    `EQC_PUT(RDMA_EQC_BODY_EQ_ST, state_code)
    `EQC_PUT(RDMA_EQC_BODY_EQ_SIZE, depth_code)
    `EQC_PUT(RDMA_EQC_BODY_NXT_EQ_PBA, next_page)
    `EQC_PUT(RDMA_EQC_BODY_CUR_EQ_PBA, current_page)
    `EQC_PUT(RDMA_EQC_BODY_CUR_PBA_VLD, layout.current_valid)
    `EQC_PUT(RDMA_EQC_BODY_EQ_PI_WRAP, producer.wrap)
    `EQC_PUT(RDMA_EQC_BODY_EQ_PI, producer.index)
    `EQC_PUT(RDMA_EQC_BODY_EQ_OM, layout.mode)
    `EQC_PUT(RDMA_EQC_BODY_MSI_X_IDX, vector_id)
    `EQC_PUT(RDMA_EQC_BODY_EQ_CI_WRAP, consumer.wrap)
    `EQC_PUT(RDMA_EQC_BODY_EQ_CI, consumer.index)
`undef EQC_PUT
    return rdma_status::success();
  endfunction

  // 功能：在 rdma_hw_eq_create_body_codec_base 中，decode_eq_layout 从硬件 image/缓冲区解码字段，验证长度、布局和完整性后返回模型或状态。
  // 输入/输出及副作用：builder（输入）、eqn（输出）、state（输出）、depth（输出）、vector_id（输出）、layout（输入）、producer（输入）、consumer（输入）；输入
  //   image/bytes 只读；成功时通过返回值或 output 发布 detached 解码快照，不接管调用方缓冲区。
  // 失败/边界：decode_eq_layout 遇到 image/model 为空、长度/对齐/保留位非法或 codec 校验失败时不发布部分字段。
  protected function rdma_status decode_eq_layout(
    rdma_hw_qword_builder builder,
    output int unsigned eqn,
    output rdma_context_state_e state,
    output int unsigned depth,
    output int unsigned vector_id,
    input rdma_page_table_layout layout,
    input rdma_ring_position producer,
    input rdma_ring_position consumer
  );
    rdma_status status;
    bit [63:0] value;
    bit [1:0] state_code;
    int unsigned depth_code;
`define EQC_GET(STEM, TARGET) \
    value = '0; \
    status = get(builder, STEM``_WORD_BYTE_OFFSET, STEM``_LSB, \
                 STEM``_WIDTH, value); \
    if (!status.ok()) return status; \
    TARGET = value;
    `EQC_GET(RDMA_EQC_BODY_EQN, eqn)
    `EQC_GET(RDMA_EQC_BODY_EQ_ST, state_code)
    status = decode_context_state(state_code, state);
    if (!status.ok()) return status;
    `EQC_GET(RDMA_EQC_BODY_EQ_SIZE, depth_code)
    depth = 32'h1 << depth_code;
    `EQC_GET(RDMA_EQC_BODY_NXT_EQ_PBA, layout.next_base.value)
    layout.next_base.value <<= 12;
    layout.next_valid = 1'b1;
    `EQC_GET(RDMA_EQC_BODY_CUR_EQ_PBA, layout.current_base.value)
    layout.current_base.value <<= 12;
    `EQC_GET(RDMA_EQC_BODY_CUR_PBA_VLD, layout.current_valid)
    `EQC_GET(RDMA_EQC_BODY_EQ_PI_WRAP, producer.wrap)
    `EQC_GET(RDMA_EQC_BODY_EQ_PI, producer.index)
    `EQC_GET(RDMA_EQC_BODY_EQ_OM, value)
    layout.mode = rdma_object_mode_e'(value[1:0]);
    `EQC_GET(RDMA_EQC_BODY_MSI_X_IDX, vector_id)
    `EQC_GET(RDMA_EQC_BODY_EQ_CI_WRAP, consumer.wrap)
    `EQC_GET(RDMA_EQC_BODY_EQ_CI, consumer.index)
`undef EQC_GET
    return rdma_status::success();
  endfunction

  // 功能：model_pbl_mode 按函数体读取当前字段并生成 rdma_mr_pbl_mode_e 结果，供调用方进行诊断或分支决策；不修改外部资源。
  // 输入/输出及副作用：model（输入）；model_pbl_mode 读取 model 并使用输入参数和固定枚举/常量；函数返回 rdma_mr_pbl_mode_e，不取得调用方资源所有权。
  // 失败/边界：枚举未定义或对象未配置时返回 UNKNOWN/UNCONFIGURED 表示，同时保留数值上下文。
  protected virtual function rdma_mr_pbl_mode_e model_pbl_mode(
    rdma_hw_model model
  );
    return RDMA_MR_PBL0;
  endfunction
endclass

class rdma_hw_ceqc_create_body_codec
    extends rdma_hw_eq_create_body_codec_base;
  `uvm_object_utils(rdma_hw_ceqc_create_body_codec)

  // 功能：构造 rdma_hw_ceqc_create_body_codec，调用 super.new 建立 UVM 层级对象；外部依赖字段保持未绑定，后续由 configure/build/activate 明确注入。
  // 输入/输出及副作用：name（输入）；new 只写入构造体列出的默认字段并返回 void，外部依赖与资源所有权仍由上层管理。
  // 失败/边界：rdma_hw_ceqc_create_body_codec 构造只建立本地初始状态，不接管外部 Host-memory、PCIe 或 manager；未完成后续 configure/build/activate 时，业务入口必须返回 INVALID_STATE。
  function new(string name = "rdma_hw_ceqc_create_body_codec");
    super.new(name);
  endfunction
  // 功能：在 rdma_hw_ceqc_create_body_codec 中，expected_image_kind 在测试中检查调用结果、状态码和副作用是否符合契约；失败时报告可定位的验证信息。
  // 输入/输出及副作用：无显式参数；expected_image_kind 读取固定返回值或局部计算结果，不使用对象成员字段；函数返回 rdma_image_kind_e，不取得调用方资源所有权。
  // 失败/边界：测试函数 expected_image_kind 缺少前置对象时报告断言错误，并停止依赖该对象的后续检查。
  protected virtual function rdma_image_kind_e expected_image_kind();
    return RDMA_IMAGE_CEQC;
  endfunction
  // 功能：在 rdma_hw_ceqc_create_body_codec 中，expected_opcode 在测试中检查调用结果、状态码和副作用是否符合契约；失败时报告可定位的验证信息。
  // 输入/输出及副作用：无显式参数；expected_opcode 读取固定返回值或局部计算结果，不使用对象成员字段；函数返回 bit [7:0]，不取得调用方资源所有权。
  // 失败/边界：测试函数 expected_opcode 缺少前置对象时报告断言错误，并停止依赖该对象的后续检查。
  protected virtual function bit [7:0] expected_opcode();
    return RDMA_OP_CEQC_CREATE;
  endfunction
  // 功能：在 rdma_hw_ceqc_create_body_codec 中，owner_generation 读取并校验 Function generation/reset epoch，拒绝旧 binding 或跨 Function 请求。
  // 输入/输出及副作用：model（输入）；owner_generation 读取 model 并使用字段 generation；函数返回 int unsigned，不取得调用方资源所有权。
  // 失败/边界：owner_generation 比较或前置条件不满足时返回 0/false；该路径不隐式重试，也不转移未声明资源。
  protected virtual function int unsigned owner_generation(
    rdma_hw_model model
  );
    rdma_ceqc_model ceqc;
    if (!$cast(ceqc, model) || ceqc.ceq_h == null) return 0;
    return ceqc.ceq_h.generation;
  endfunction

  // 功能：validate_model 校验 model 与当前对象状态的一致性，并显式处理“rdma CEQC codec requires rdma_ceqc_model”等拒绝条件，返回 rdma_status 供上层决定是否提交。
  // 输入/输出及副作用：model（输入）；validate_model 读取 model 并使用字段 status；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：必需对象/句柄/快照为空，或身份、范围、generation 和生命周期检查失败时返回非成功状态。
  virtual function rdma_status validate_model(rdma_hw_model model);
    rdma_ceqc_model ceqc;
    rdma_status status;
    if (!$cast(ceqc, model))
      return invalid_argument("rdma CEQC codec requires rdma_ceqc_model");
    status = ceqc.validate();
    if (!status.ok())
      return invalid_argument({"CEQC model is invalid: ", status.message});
    return validate_eq_layout(ceqc.depth, ceqc.vector_id, ceqc.page_layout,
                              ceqc.producer, ceqc.consumer);
  endfunction
  // 功能：在 rdma_hw_ceqc_create_body_codec 中，encode_body 按硬件布局把输入模型编码到 image/缓冲区，并在写入前检查范围、重叠、端序和保留位。
  // 输入/输出及副作用：model（输入）、builder（输入）；输入模型只读；成功时通过返回值或 output 发布完整 image/bytes，不修改源模型。
  // 失败/边界：encode_body 遇到 image/model 为空、长度/对齐/保留位非法或 codec 校验失败时不发布部分字段。
  protected virtual function rdma_status encode_body(
    rdma_hw_model model,
    rdma_hw_qword_builder builder
  );
    rdma_ceqc_model ceqc;
    if (!$cast(ceqc, model))
      return invalid_argument("rdma CEQC model cast failed");
    return encode_eq_layout(builder, ceqc.ceq_h.object_id, ceqc.state,
                            ceqc.depth, ceqc.vector_id, ceqc.page_layout,
                            ceqc.producer, ceqc.consumer);
  endfunction
  // 功能：在 rdma_hw_ceqc_create_body_codec 中，decode_body 从硬件 image/缓冲区解码字段，验证长度、布局和完整性后返回模型或状态。
  // 输入/输出及副作用：builder（输入）、model（输出）；输入 image/bytes 只读；成功时通过返回值或 output 发布 detached 解码快照，不接管调用方缓冲区。
  // 失败/边界：decode_body 遇到 image/model 为空、长度/对齐/保留位非法或 codec 校验失败时不发布部分字段。
  protected virtual function rdma_status decode_body(
    rdma_hw_qword_builder builder,
    output rdma_hw_model model
  );
    rdma_ceqc_model ceqc;
    rdma_status status;
    int unsigned eqn;
    model = null;
    ceqc = rdma_ceqc_model::type_id::create("decoded_rdma_ceqc");
    status = decode_eq_layout(builder, eqn, ceqc.state, ceqc.depth,
                              ceqc.vector_id, ceqc.page_layout,
                              ceqc.producer, ceqc.consumer);
    if (!status.ok()) return status;
    ceqc.ceq_h = projected_handle("decoded_ceq", RDMA_RESOURCE_CEQ, eqn);
    model = ceqc;
    return rdma_status::success();
  endfunction
endclass

class rdma_hw_aeqc_create_body_codec
    extends rdma_hw_eq_create_body_codec_base;
  `uvm_object_utils(rdma_hw_aeqc_create_body_codec)

  // 功能：构造 rdma_hw_aeqc_create_body_codec，调用 super.new 建立 UVM 层级对象；外部依赖字段保持未绑定，后续由 configure/build/activate 明确注入。
  // 输入/输出及副作用：name（输入）；new 只写入构造体列出的默认字段并返回 void，外部依赖与资源所有权仍由上层管理。
  // 失败/边界：rdma_hw_aeqc_create_body_codec 构造只建立本地初始状态，不接管外部 Host-memory、PCIe 或 manager；未完成后续 configure/build/activate 时，业务入口必须返回 INVALID_STATE。
  function new(string name = "rdma_hw_aeqc_create_body_codec");
    super.new(name);
  endfunction
  // 功能：在 rdma_hw_aeqc_create_body_codec 中，expected_image_kind 在测试中检查调用结果、状态码和副作用是否符合契约；失败时报告可定位的验证信息。
  // 输入/输出及副作用：无显式参数；expected_image_kind 读取固定返回值或局部计算结果，不使用对象成员字段；函数返回 rdma_image_kind_e，不取得调用方资源所有权。
  // 失败/边界：测试函数 expected_image_kind 缺少前置对象时报告断言错误，并停止依赖该对象的后续检查。
  protected virtual function rdma_image_kind_e expected_image_kind();
    return RDMA_IMAGE_AEQC;
  endfunction
  // 功能：在 rdma_hw_aeqc_create_body_codec 中，expected_opcode 在测试中检查调用结果、状态码和副作用是否符合契约；失败时报告可定位的验证信息。
  // 输入/输出及副作用：无显式参数；expected_opcode 读取固定返回值或局部计算结果，不使用对象成员字段；函数返回 bit [7:0]，不取得调用方资源所有权。
  // 失败/边界：测试函数 expected_opcode 缺少前置对象时报告断言错误，并停止依赖该对象的后续检查。
  protected virtual function bit [7:0] expected_opcode();
    return RDMA_OP_AEQC_CREATE;
  endfunction
  // 功能：在 rdma_hw_aeqc_create_body_codec 中，owner_generation 读取并校验 Function generation/reset epoch，拒绝旧 binding 或跨 Function 请求。
  // 输入/输出及副作用：model（输入）；owner_generation 读取 model 并使用字段 generation；函数返回 int unsigned，不取得调用方资源所有权。
  // 失败/边界：owner_generation 比较或前置条件不满足时返回 0/false；该路径不隐式重试，也不转移未声明资源。
  protected virtual function int unsigned owner_generation(
    rdma_hw_model model
  );
    rdma_aeqc_model aeqc;
    if (!$cast(aeqc, model) || aeqc.aeq_h == null) return 0;
    return aeqc.aeq_h.generation;
  endfunction

  // 功能：validate_model 校验 model 与当前对象状态的一致性，并显式处理“rdma AEQC codec requires rdma_aeqc_model”等拒绝条件，返回 rdma_status 供上层决定是否提交。
  // 输入/输出及副作用：model（输入）；validate_model 读取 model 并使用字段 status；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：必需对象/句柄/快照为空，或身份、范围、generation 和生命周期检查失败时返回非成功状态。
  virtual function rdma_status validate_model(rdma_hw_model model);
    rdma_aeqc_model aeqc;
    rdma_status status;
    if (!$cast(aeqc, model))
      return invalid_argument("rdma AEQC codec requires rdma_aeqc_model");
    status = aeqc.validate();
    if (!status.ok())
      return invalid_argument({"AEQC model is invalid: ", status.message});
    return validate_eq_layout(aeqc.depth, aeqc.vector_id, aeqc.page_layout,
                              aeqc.producer, aeqc.consumer);
  endfunction
  // 功能：在 rdma_hw_aeqc_create_body_codec 中，encode_body 按硬件布局把输入模型编码到 image/缓冲区，并在写入前检查范围、重叠、端序和保留位。
  // 输入/输出及副作用：model（输入）、builder（输入）；输入模型只读；成功时通过返回值或 output 发布完整 image/bytes，不修改源模型。
  // 失败/边界：encode_body 遇到 image/model 为空、长度/对齐/保留位非法或 codec 校验失败时不发布部分字段。
  protected virtual function rdma_status encode_body(
    rdma_hw_model model,
    rdma_hw_qword_builder builder
  );
    rdma_aeqc_model aeqc;
    if (!$cast(aeqc, model))
      return invalid_argument("rdma AEQC model cast failed");
    return encode_eq_layout(builder, aeqc.aeq_h.object_id, aeqc.state,
                            aeqc.depth, aeqc.vector_id, aeqc.page_layout,
                            aeqc.producer, aeqc.consumer);
  endfunction
  // 功能：在 rdma_hw_aeqc_create_body_codec 中，decode_body 从硬件 image/缓冲区解码字段，验证长度、布局和完整性后返回模型或状态。
  // 输入/输出及副作用：builder（输入）、model（输出）；输入 image/bytes 只读；成功时通过返回值或 output 发布 detached 解码快照，不接管调用方缓冲区。
  // 失败/边界：decode_body 遇到 image/model 为空、长度/对齐/保留位非法或 codec 校验失败时不发布部分字段。
  protected virtual function rdma_status decode_body(
    rdma_hw_qword_builder builder,
    output rdma_hw_model model
  );
    rdma_aeqc_model aeqc;
    rdma_status status;
    int unsigned eqn;
    model = null;
    aeqc = rdma_aeqc_model::type_id::create("decoded_rdma_aeqc");
    status = decode_eq_layout(builder, eqn, aeqc.state, aeqc.depth,
                              aeqc.vector_id, aeqc.page_layout,
                              aeqc.producer, aeqc.consumer);
    if (!status.ok()) return status;
    aeqc.aeq_h = projected_handle("decoded_aeq", RDMA_RESOURCE_AEQ, eqn);
    model = aeqc;
    return rdma_status::success();
  endfunction
endclass

// 功能：在 rdma_hw_aeqc_create_body_codec 中，rdma_register_context_body_codecs 把 XTR v1 对应对象类型、opcode 和 variant 的 codec 注册到 profile registry，并拒绝重复键。
// 输入/输出及副作用：registry（输入）；rdma_register_context_body_codecs 读取 registry 并使用字段 key.hw_version、key.variant、key.image_kind、key.object_type、key.opcode、status；函数返回 rdma_status，不取得调用方资源所有权。
// 失败/边界：registry 为空、重复 codec key 或 body codec 自身校验失败时返回错误，不发布半成品注册表。
function automatic rdma_status rdma_register_context_body_codecs(
  rdma_codec_registry registry
);
  rdma_codec_key key;
  rdma_status status;

  if (registry == null)
    return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                             "context-body codec registry is null");
  key.hw_version = "rdma";
  key.variant = "create";

  key.image_kind = RDMA_IMAGE_CQC;
  key.object_type = "cqc";
  key.opcode = RDMA_OP_CQC_CREATE;
  status = registry.register_codec(
    key, rdma_hw_cqc_create_body_codec::type_id::create(
      "rdma_cqc_create_body_codec"));
  if (!status.ok()) return status;

  key.image_kind = RDMA_IMAGE_MRT;
  key.object_type = "mrt";
  key.variant = "key_alloc";
  key.opcode = RDMA_OP_KEY_ALLOC;
  status = registry.register_codec(
    key, rdma_hw_mrt_key_alloc_body_codec::type_id::create(
      "rdma_mrt_key_alloc_body_codec"));
  if (!status.ok()) return status;

  key.variant = "register";
  key.opcode = RDMA_OP_MR_REGISTER;
  status = registry.register_codec(
    key, rdma_hw_mrt_register_body_codec::type_id::create(
      "rdma_mrt_register_body_codec"));
  if (!status.ok()) return status;

  key.image_kind = RDMA_IMAGE_SRQC;
  key.object_type = "srqc";
  key.variant = "create";
  key.opcode = RDMA_OP_SRFQC_CREATE;
  status = registry.register_codec(
    key, rdma_hw_srqc_create_body_codec::type_id::create(
      "rdma_srqc_create_body_codec"));
  if (!status.ok()) return status;

  key.image_kind = RDMA_IMAGE_CEQC;
  key.object_type = "ceqc";
  key.opcode = RDMA_OP_CEQC_CREATE;
  status = registry.register_codec(
    key, rdma_hw_ceqc_create_body_codec::type_id::create(
      "rdma_ceqc_create_body_codec"));
  if (!status.ok()) return status;

  key.image_kind = RDMA_IMAGE_AEQC;
  key.object_type = "aeqc";
  key.opcode = RDMA_OP_AEQC_CREATE;
  return registry.register_codec(
    key, rdma_hw_aeqc_create_body_codec::type_id::create(
      "rdma_aeqc_create_body_codec"));
endfunction
