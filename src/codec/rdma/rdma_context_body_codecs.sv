// 目录：硬件编解码层 codec/rdma/rdma_context_body_codecs.sv。
// 职责：实现 CQC/MRT/SRQC/CEQC/AEQC 的 64 字节 context body 编解码，并注册到 codec registry。
// 依赖：本层公共 types/model/adapter 契约、qword builder 与 codec registry。
// 所有权与生命周期：codec 对象只持有值状态；输入模型只读，输出 image/model 为新建 detached 对象。

// 说明：所有 body 先经 qword builder 写入并校验 occupancy mask，失败路径不发布部分 image/model。

virtual class rdma_hw_context_body_codec_base extends rdma_codec_base;
  localparam int unsigned BODY_BYTES = 64;

  // 功能：构造 codec 对象。
  // 输入/输出及副作用：name 为对象名；仅调用 super.new。
  // 失败/边界：无。
  function new(string name = "rdma_hw_context_body_codec_base");
    super.new(name);
  endfunction

  // 功能：（纯虚）返回该 codec 对应的 image kind。
  // 输入/输出及副作用：无输入；返回 rdma_image_kind_e。
  // 失败/边界：无。
  protected pure virtual function rdma_image_kind_e expected_image_kind();
  // 功能：（纯虚）返回该 codec 对应的硬件 opcode。
  // 输入/输出及副作用：无输入；返回 bit [7:0]。
  // 失败/边界：无。
  protected pure virtual function bit [7:0] expected_opcode();
  // 功能：（纯虚）返回 model 对应的 PBL 编码模式。
  // 输入/输出及副作用：model 为输入；返回 rdma_mr_pbl_mode_e。
  // 失败/边界：无。
  protected pure virtual function rdma_mr_pbl_mode_e model_pbl_mode(
    rdma_hw_model model
  );
  // 功能：（纯虚）返回 model 绑定句柄的 generation。
  // 输入/输出及副作用：model 为输入；返回 int unsigned。
  // 失败/边界：无。
  protected pure virtual function int unsigned owner_generation(
    rdma_hw_model model
  );
  // 功能：（纯虚）把 model 的字段经 builder 写入 context body。
  // 输入/输出及副作用：model、builder 为输入；写入 builder。
  // 失败/边界：失败返回非 OK status，调用方不得发布 image。
  protected pure virtual function rdma_status encode_body(
    rdma_hw_model model,
    rdma_hw_qword_builder builder
  );
  // 功能：（纯虚）从 builder 中解码字段构造 model。
  // 输入/输出及副作用：builder 为输入，model 为输出。
  // 失败/边界：失败返回非 OK status。
  protected pure virtual function rdma_status decode_body(
    rdma_hw_qword_builder builder,
    output rdma_hw_model model
  );

  // 功能：构造 INVALID_ARGUMENT 状态。
  // 输入/输出及副作用：message 为诊断文本；返回新 status。
  // 失败/边界：无。
  protected function rdma_status invalid_argument(string message);
    return rdma_status::make(RDMA_SC_INVALID_ARGUMENT, message);
  endfunction

  // 功能：构造 CODEC_ERROR 状态。
  // 输入/输出及副作用：message 为诊断文本；返回新 status。
  // 失败/边界：无。
  protected function rdma_status codec_error(string message);
    return rdma_status::make(RDMA_SC_CODEC_ERROR, message);
  endfunction

  // 功能：把编码链中的 null status 归一化为 INVALID_STATE，保证调用方可安全解引用。
  // 输入/输出及副作用：status、label 为输入；非空原样返回，不改其他状态。
  // 失败/边界：status 为 null 时返回带 label 的 INVALID_STATE。
  protected function rdma_status context_status_or_error(
    rdma_status status,
    string label
  );
    if (status == null)
      return rdma_status::make(
        RDMA_SC_INVALID_STATE,
        {label, " returned null status"}
      );
    return status;
  endfunction

  // 功能：经 builder 写入一个位域。
  // 输入/输出及副作用：builder、word_byte_offset、lsb、width、value 为输入；写 builder 内部缓冲。
  // 失败/边界：builder 为空或 put_field 失败/返回 null 时返回 CODEC_ERROR。
  protected function rdma_status put(
    rdma_hw_qword_builder builder,
    int unsigned word_byte_offset,
    int unsigned lsb,
    int unsigned width,
    bit [63:0] value
  );
    rdma_status status;

    if (builder == null)
      return codec_error("context-body field authorship builder is null");

    status = builder.put_field(word_byte_offset, lsb, width, value);
    status = context_status_or_error(
      status, "context-body field authorship"
    );

    if (!status.ok())
      return codec_error({"context-body field authorship failed: ",
                          status.message});
    return status;
  endfunction

  // 功能：经 builder 读取一个位域。
  // 输入/输出及副作用：builder、word_byte_offset、lsb、width 为输入；value 为 inout 输出。
  // 失败/边界：builder 为空或 get_field 失败/返回 null 时返回 CODEC_ERROR。
  protected function rdma_status get(
    rdma_hw_qword_builder builder,
    int unsigned word_byte_offset,
    int unsigned lsb,
    int unsigned width,
    inout bit [63:0] value
  );
    rdma_status status;

    if (builder == null)
      return codec_error("context-body field extraction builder is null");

    status = builder.get_field(word_byte_offset, lsb, width, value);
    status = context_status_or_error(
      status, "context-body field extraction"
    );

    if (!status.ok())
      return codec_error({"context-body field extraction failed: ",
                          status.message});
    return status;
  endfunction

  // 功能：把 2 的幂 value 编码为 log2 码。
  // 输入/输出及副作用：value、width、label 为输入；code 为输出。
  // 失败/边界：value 非零 2 的幂或 log2 超出 width 位宽时返回 INVALID_ARGUMENT。
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

  // 功能：把 4KiB 对齐的 backing 地址编码为页号。
  // 输入/输出及副作用：backing、label 为输入；page 为输出（地址 [63:12]）。
  // 失败/边界：地址未 4KiB 对齐时返回 INVALID_ARGUMENT。
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

  // 功能：把 context 状态枚举编码为 2 位码。
  // 输入/输出及副作用：state 为输入；code 为输出（INVALID/VALID/ERROR 对应 0/1/2）。
  // 失败/边界：其他状态返回 INVALID_ARGUMENT。
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

  // 功能：把 2 位状态码解码为 context 状态枚举。
  // 输入/输出及副作用：code 为输入；state 为输出。
  // 失败/边界：码值非 0/1/2 时返回 CODEC_ERROR。
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

  // 功能：构造只含 kind/object_id 的句柄投影。
  // 输入/输出及副作用：name、kind、object_id 为输入；返回新 rdma_handle，function_uid 与 generation 置 0。
  // 失败/边界：无。
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

  // 功能：返回 image 的 PBL 模式；默认实现固定为 RDMA_MR_PBL0。
  // 输入/输出及副作用：builder 为输入；pbl_mode 为输出。
  // 失败/边界：无。
  protected virtual function rdma_status image_pbl_mode(
    rdma_hw_qword_builder builder,
    output rdma_mr_pbl_mode_e pbl_mode
  );
    pbl_mode = RDMA_MR_PBL0;
    return rdma_status::success();
  endfunction

  // 功能：校验 builder 已写位域与该 image/opcode/PBL 模式的允许 mask 完全一致。
  // 输入/输出及副作用：builder、pbl_mode 为输入；只读 builder 的 occupancy。
  // 失败/边界：builder 为空、mask 校验失败、occupancy 非 8 个 qword 或与 mask 不等时返回 CODEC_ERROR。
  protected function rdma_status validate_encode_mask(
    rdma_hw_qword_builder builder,
    rdma_mr_pbl_mode_e pbl_mode
  );
    bit [63:0] occupancy[];
    bit [63:0] allowed;
    rdma_status status;

    if (builder == null)
      return codec_error("context-body encode mask builder is null");

    status = builder.validate_allowed_mask(expected_image_kind(),
                                           expected_opcode(), pbl_mode);
    status = context_status_or_error(
      status, "context-body encode mask validation"
    );

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

  // 功能：校验 mask 并序列化 builder，发布 64 字节 detached image。
  // 输入/输出及副作用：builder、pbl_mode、owner_generation 为输入；image 为输出，失败时为 null。
  // 失败/边界：builder 为空、mask 校验或序列化失败时返回错误且不发布 image。
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
    if (builder == null)
      return codec_error("context-body finish builder is null");

    status = validate_encode_mask(builder, pbl_mode);
    status = context_status_or_error(
      status, "context-body encode mask validation"
    );

    if (!status.ok()) return status;
    payload = new[0];
    status = builder.serialize(payload);
    status = context_status_or_error(
      status, "context-body serialization"
    );

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

  // 功能：校验 model、写 body 并生成 image。
  // 输入/输出及副作用：model 为输入；image 为输出，失败时为 null；内部新建临时 builder。
  // 失败/边界：validate_model、builder reset 或 encode_body 失败时返回错误。
  virtual function rdma_status encode(
    rdma_hw_model model,
    output rdma_hw_image image
  );
    rdma_hw_qword_builder builder;
    rdma_status status;

    image = null;
    status = validate_model(model);
    status = context_status_or_error(
      status, "context-body model validation"
    );

    if (!status.ok())
      return status;
    builder = new("context_body_encode_builder");
    status = builder.reset(BODY_BYTES);
    status = context_status_or_error(
      status, "context-body encode builder reset"
    );

    if (!status.ok()) return codec_error(status.message);
    status = encode_body(model, builder);
    status = context_status_or_error(
      status, "context-body body encoder"
    );

    if (!status.ok())
      return status;
    return finish_body(builder, model_pbl_mode(model),
                       owner_generation(model), image);
  endfunction

  // 功能：校验 image 的长度、元数据、反序列化结果与保留位 mask。
  // 输入/输出及副作用：image 为输入；只读。
  // 失败/边界：image 为空、非 64 字节、元数据不符、反序列化或 mask 校验失败时返回 CODEC_ERROR。
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
    status = context_status_or_error(
      status, "context-body image deserialization"
    );

    if (!status.ok()) return codec_error(status.message);
    status = image_pbl_mode(builder, pbl_mode);
    status = context_status_or_error(
      status, "context-body image PBL mode"
    );

    if (!status.ok()) return codec_error(status.message);
    status = builder.validate_allowed_mask(expected_image_kind(),
                                           expected_opcode(), pbl_mode);
    status = context_status_or_error(
      status, "context-body image mask validation"
    );

    if (!status.ok())
      return codec_error({"context-body reserved/mask validation failed: ",
                          status.message});
    return rdma_status::success();
  endfunction

  // 功能：校验 image 后解码并验证 model。
  // 输入/输出及副作用：image 为输入；model 为输出，失败时为 null。
  // 失败/边界：validate_image、反序列化、decode_body 失败、候选为空或语义校验失败时返回错误。
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
    status = context_status_or_error(
      status, "context-body image validation"
    );

    if (!status.ok())
      return status;
    payload = new[BODY_BYTES];
    foreach (payload[i]) payload[i] = image.bytes[i];
    builder = new("context_body_decode_builder");
    status = builder.deserialize(payload);
    status = context_status_or_error(
      status, "context-body decode deserialization"
    );

    if (!status.ok()) return codec_error(status.message);
    candidate = null;
    status = decode_body(builder, candidate);
    status = context_status_or_error(
      status, "context-body body decoder"
    );

    if (!status.ok())
      return status;
    if (candidate == null)
      return codec_error("context-body decoder produced a null candidate");
    status = validate_model(candidate);
    status = context_status_or_error(
      status, "decoded context-body model validation"
    );

    if (!status.ok())
      return codec_error({"decoded context-body semantics are invalid: ",
                          status.message});
    model = candidate;
    return rdma_status::success();
  endfunction

  // 功能：编码两个 model 并逐字节比较序列化结果。
  // 输入/输出及副作用：lhs、rhs 为输入；equal、mismatch 为输出。
  // 失败/边界：任一侧编码失败时返回其状态并在 mismatch 标明哪一侧；字节差异时 equal=0 且 status OK。
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
    status = context_status_or_error(
      status, "left context-body serialization"
    );

    if (!status.ok()) begin
      mismatch = {"left model: ", status.message};
      return status;
    end
    status = encode(rhs, right_image);
    status = context_status_or_error(
      status, "right context-body serialization"
    );

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

  // 功能：返回硬件端序 RDMA_ENDIAN_BIG。
  // 输入/输出及副作用：无输入。
  // 失败/边界：无。
  virtual function rdma_byte_endian_e hardware_endian();
    return RDMA_ENDIAN_BIG;
  endfunction

  // 功能：返回描述 image kind 与 opcode 的稳定文本。
  // 输入/输出及副作用：无输入；返回 string。
  // 失败/边界：无。
  virtual function string describe_fields();
    return $sformatf("rdma 64-byte sparse body kind=%s opcode=%02x",
                     expected_image_kind().name(), expected_opcode());
  endfunction
endclass

class rdma_hw_cqc_create_body_codec
    extends rdma_hw_context_body_codec_base;
  `rdma_object_utils(rdma_hw_cqc_create_body_codec)

  // 功能：构造 codec 对象。
  // 输入/输出及副作用：name 为对象名；仅调用 super.new。
  // 失败/边界：无。
  function new(string name = "rdma_hw_cqc_create_body_codec");
    super.new(name);
  endfunction

  // 功能：返回固定的 RDMA_IMAGE_CQC。
  // 输入/输出及副作用：无输入；不读取对象字段。
  // 失败/边界：无。
  protected virtual function rdma_image_kind_e expected_image_kind();
    return RDMA_IMAGE_CQC;
  endfunction

  // 功能：返回固定的 RDMA_OP_CQC_CREATE。
  // 输入/输出及副作用：无输入；不读取对象字段。
  // 失败/边界：无。
  protected virtual function bit [7:0] expected_opcode();
    return RDMA_OP_CQC_CREATE;
  endfunction

  // 功能：返回 RDMA_MR_PBL0（该类 context 不使用 PBL）。
  // 输入/输出及副作用：model 为输入但未使用。
  // 失败/边界：无。
  protected virtual function rdma_mr_pbl_mode_e model_pbl_mode(
    rdma_hw_model model
  );
    return RDMA_MR_PBL0;
  endfunction

  // 功能：返回 model.cq_h.generation，用作 image 的 function_generation。
  // 输入/输出及副作用：model 为输入；只读。
  // 失败/边界：cast 失败或 cq_h 为空时返回 0。
  protected virtual function int unsigned owner_generation(
    rdma_hw_model model
  );
    rdma_cqc_model cqc;
    if (!$cast(cqc, model) || cqc.cq_h == null) return 0;
    return cqc.cq_h.generation;
  endfunction

  // 功能：把 CQE 字节数（32/64/128）编码为 2 位码。
  // 输入/输出及副作用：bytes 为输入；code 为输出。
  // 失败/边界：其他大小返回 INVALID_ARGUMENT。
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

  // 功能：把 2 位码解码为 CQE 字节数。
  // 输入/输出及副作用：code 为输入；bytes 为输出。
  // 失败/边界：码值非 0/1/2 时返回 CODEC_ERROR。
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

  // 功能：校验 CQC model 能被硬件字段表示。
  // 输入/输出及副作用：model 为输入；只读。
  // 失败/边界：cast 失败、model.validate 失败、对象模式不支持、深度/CQE 大小/页对齐/标量越界时返回 INVALID_ARGUMENT。
  virtual function rdma_status validate_model(rdma_hw_model model);
    rdma_cqc_model cqc;
    rdma_status status;
    int unsigned depth_code;
    bit [1:0] cqe_code;
    bit [51:0] page;

    if (!$cast(cqc, model))
      return invalid_argument("rdma CQC codec requires rdma_cqc_model");
    status = context_status_or_error(
      cqc.validate(), "CQC model validation"
    );
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

  // 功能：把 CQC model 的 CQN、SD/当前/下一页 PBA、深度、CQE 大小、producer/consumer、arm 状态等 字段按硬件位域写入 builder。
  // 输入/输出及副作用：model、builder 为输入；经 put() 写 builder，不改 model。
  // 失败/边界：cast 失败、字段编码失败或 put 失败时返回错误，不继续写后续字段。
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

  // 功能：从 builder 解码 CQC model：CQ/CEQ 句柄、深度、页地址、CQE 大小、producer/consumer、arm 状态。
  // 输入/输出及副作用：builder 为输入，model 为输出，失败时保持 null；get() 读字段。
  // 失败/边界：字段码非法或 get 失败时返回错误且不发布 model。
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

  // 功能：构造 codec 对象。
  // 输入/输出及副作用：name 为对象名；仅调用 super.new。
  // 失败/边界：无。
  function new(string name = "rdma_hw_mrt_body_codec_base");
    super.new(name);
  endfunction

  // 功能：（纯虚）区分 KEY_ALLOC 与 MR_REGISTER 两种 MRT body。
  // 输入/输出及副作用：无输入；返回 bit。
  // 失败/边界：无。
  protected pure virtual function bit is_key_alloc();

  // 功能：返回固定的 RDMA_IMAGE_MRT。
  // 输入/输出及副作用：无输入；不读取对象字段。
  // 失败/边界：无。
  protected virtual function rdma_image_kind_e expected_image_kind();
    return RDMA_IMAGE_MRT;
  endfunction

  // 功能：返回 MRT 的 page_layout.pbl_mode。
  // 输入/输出及副作用：model 为输入；只读。
  // 失败/边界：cast 失败或 page_layout 为空时返回 RDMA_MR_PBL0。
  protected virtual function rdma_mr_pbl_mode_e model_pbl_mode(
    rdma_hw_model model
  );
    rdma_mrt_model mrt;
    if (!$cast(mrt, model) || mrt.page_layout == null) return RDMA_MR_PBL0;
    return mrt.page_layout.pbl_mode;
  endfunction

  // 功能：返回 model.mr_h.generation，用作 image 的 function_generation。
  // 输入/输出及副作用：model 为输入；只读。
  // 失败/边界：cast 失败或 mr_h 为空时返回 0。
  protected virtual function int unsigned owner_generation(
    rdma_hw_model model
  );
    rdma_mrt_model mrt;
    if (!$cast(mrt, model) || mrt.mr_h == null) return 0;
    return mrt.mr_h.generation;
  endfunction

  // 功能：从 MRT body 的 PBL_MODE 字段读取 PBL 模式。
  // 输入/输出及副作用：builder 为输入；pbl_mode 为输出（先置 PBL0）；经 get() 读字段。
  // 失败/边界：get 失败返回其错误；码值大于 PBL2 时返回 CODEC_ERROR。
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

  // 功能：把 MRT 状态枚举编码为驱动 mr.h 的 0/1/2 状态码。
  // 输入/输出及副作用：state 为输入；code 为输出。
  // 失败/边界：未定义状态返回 INVALID_ARGUMENT。
  protected function rdma_status encode_mr_state(
    rdma_mr_state_e state,
    output bit [1:0] code
  );
    case (state)
      RDMA_MR_STATE_INVALID: code = RDMA_MR_ST_INVALID;
      RDMA_MR_STATE_FREE:    code = RDMA_MR_ST_FREE;
      RDMA_MR_STATE_VALID:   code = RDMA_MR_ST_VALID;
      default: return invalid_argument("rdma MRT state is unsupported");
    endcase
    return rdma_status::success();
  endfunction

  // 功能：把 0/1/2 状态码还原为 MRT 状态枚举。
  // 输入/输出及副作用：code 为输入；state 为输出。
  // 失败/边界：未定义码值（含 2'b11）返回 CODEC_ERROR，不发布伪造状态。
  protected function rdma_status decode_mr_state(
    bit [1:0] code,
    output rdma_mr_state_e state
  );
    case (code)
      RDMA_MR_ST_INVALID: state = RDMA_MR_STATE_INVALID;
      RDMA_MR_ST_FREE:    state = RDMA_MR_STATE_FREE;
      RDMA_MR_ST_VALID:   state = RDMA_MR_STATE_VALID;
      default: return codec_error("rdma MRT state code is invalid");
    endcase
    return rdma_status::success();
  endfunction

  // 功能：把 host page 大小（4K/2M/1G）编码为 2 位码。
  // 输入/输出及副作用：page_size 为输入；code 为输出。
  // 失败/边界：其他大小返回 INVALID_ARGUMENT。
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

  // 功能：把 2 位码解码为 host page 大小。
  // 输入/输出及副作用：code 为输入；page_size 为输出。
  // 失败/边界：未定义码值返回 CODEC_ERROR。
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

  // 功能：把地址模式（VA-based/zero-based）编码为 1 位码。
  // 输入/输出及副作用：address_mode 为输入；code 为输出。
  // 失败/边界：其他模式返回 INVALID_ARGUMENT。
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

  // 功能：把 1 位码解码为地址模式。
  // 输入/输出及副作用：code 为输入；address_mode 为输出。
  // 失败/边界：未定义码值返回 CODEC_ERROR。
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

  // 功能：把访问权限规整为硬件 rights 位图。
  // 输入/输出及副作用：access 为输入；返回 5 位 rights；remote write/atomic 隐含 LOCAL_WRITE。
  // 失败/边界：无。
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

  // 功能：校验 MRT model 能被硬件字段表示。
  // 输入/输出及副作用：model 为输入；只读。
  // 失败/边界：cast 失败、model.validate 失败、状态/页大小/地址模式不支持、标量越界或 PBA 未对齐时返回错误。
  virtual function rdma_status validate_model(rdma_hw_model model);
    rdma_mrt_model mrt;
    rdma_status status;
    bit [1:0] state_code;
    bit [1:0] page_code;
    bit address_code;
    bit [51:0] page;

    if (!$cast(mrt, model))
      return invalid_argument("rdma MRT codec requires rdma_mrt_model");
    status = context_status_or_error(
      mrt.validate(), "MRT model validation"
    );
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

  // 功能：把 MRT model 的 MR 状态、host page、地址模式、访问权限、PBA0/PBA1 或 first PBL 等 字段按硬件位域写入 builder。
  // 输入/输出及副作用：model、builder 为输入；经 put() 写 builder，不改 model。
  // 失败/边界：cast 失败、字段编码失败或 put 失败时返回错误，不继续写后续字段。
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

  // 功能：从 builder 解码 MRT model：STAG、PD 句柄、权限、host page、PBL 模式、状态镜像及 PBA/first PBL。
  // 输入/输出及副作用：builder 为输入，model 为输出，失败时保持 null；get() 读字段。
  // 失败/边界：字段码非法或 get 失败时返回错误且不发布 model。
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
    // 非零的 self-parent 用于区分 KEY_ALLOC 与 MR_REGISTER；孤立 body 中 STAG 0 有歧义，
    // 调用方须按精确的 opcode/registry 身份认证 codec。
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
  `rdma_object_utils(rdma_hw_mrt_key_alloc_body_codec)

  // 功能：构造 codec 对象。
  // 输入/输出及副作用：name 为对象名；仅调用 super.new。
  // 失败/边界：无。
  function new(string name = "rdma_hw_mrt_key_alloc_body_codec");
    super.new(name);
  endfunction
  // 功能：返回 1：本 codec 为 KEY_ALLOC。
  // 输入/输出及副作用：无输入。
  // 失败/边界：无。
  protected virtual function bit is_key_alloc(); return 1'b1; endfunction
  // 功能：返回固定的 RDMA_OP_KEY_ALLOC。
  // 输入/输出及副作用：无输入；不读取对象字段。
  // 失败/边界：无。
  protected virtual function bit [7:0] expected_opcode();
    return RDMA_OP_KEY_ALLOC;
  endfunction
endclass

class rdma_hw_mrt_register_body_codec
    extends rdma_hw_mrt_body_codec_base;
  `rdma_object_utils(rdma_hw_mrt_register_body_codec)

  // 功能：构造 codec 对象。
  // 输入/输出及副作用：name 为对象名；仅调用 super.new。
  // 失败/边界：无。
  function new(string name = "rdma_hw_mrt_register_body_codec");
    super.new(name);
  endfunction
  // 功能：返回 0：本 codec 为 MR_REGISTER。
  // 输入/输出及副作用：无输入。
  // 失败/边界：无。
  protected virtual function bit is_key_alloc(); return 1'b0; endfunction
  // 功能：返回固定的 RDMA_OP_MR_REGISTER。
  // 输入/输出及副作用：无输入；不读取对象字段。
  // 失败/边界：无。
  protected virtual function bit [7:0] expected_opcode();
    return RDMA_OP_MR_REGISTER;
  endfunction
endclass

class rdma_hw_srqc_create_body_codec
    extends rdma_hw_context_body_codec_base;
  `rdma_object_utils(rdma_hw_srqc_create_body_codec)

  // 功能：构造 codec 对象。
  // 输入/输出及副作用：name 为对象名；仅调用 super.new。
  // 失败/边界：无。
  function new(string name = "rdma_hw_srqc_create_body_codec");
    super.new(name);
  endfunction
  // 功能：返回固定的 RDMA_IMAGE_SRQC。
  // 输入/输出及副作用：无输入；不读取对象字段。
  // 失败/边界：无。
  protected virtual function rdma_image_kind_e expected_image_kind();
    return RDMA_IMAGE_SRQC;
  endfunction
  // 功能：返回固定的 RDMA_OP_SRFQC_CREATE。
  // 输入/输出及副作用：无输入；不读取对象字段。
  // 失败/边界：无。
  protected virtual function bit [7:0] expected_opcode();
    return RDMA_OP_SRFQC_CREATE;
  endfunction
  // 功能：返回 RDMA_MR_PBL0（该类 context 不使用 PBL）。
  // 输入/输出及副作用：model 为输入但未使用。
  // 失败/边界：无。
  protected virtual function rdma_mr_pbl_mode_e model_pbl_mode(
    rdma_hw_model model
  );
    return RDMA_MR_PBL0;
  endfunction
  // 功能：返回 model.srq_h.generation，用作 image 的 function_generation。
  // 输入/输出及副作用：model 为输入；只读。
  // 失败/边界：cast 失败或 srq_h 为空时返回 0。
  protected virtual function int unsigned owner_generation(
    rdma_hw_model model
  );
    rdma_srqc_model srqc;
    if (!$cast(srqc, model) || srqc.srq_h == null) return 0;
    return srqc.srq_h.generation;
  endfunction

  // 功能：校验 SRQC model 能被硬件字段表示。
  // 输入/输出及副作用：model 为输入；只读。
  // 失败/边界：cast 失败、model.validate 失败、深度或页对齐不合法、阈值/producer 越界时返回 INVALID_ARGUMENT。
  virtual function rdma_status validate_model(rdma_hw_model model);
    rdma_srqc_model srqc;
    rdma_status status;
    int unsigned depth_code;
    bit [51:0] page;
    if (!$cast(srqc, model))
      return invalid_argument("rdma SRQC codec requires rdma_srqc_model");
    status = context_status_or_error(
      srqc.validate(), "SRQC model validation"
    );
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

  // 功能：把 SRQC model 的 SRQ 状态、深度、backing/shadow 页、阈值、producer 等 字段按硬件位域写入 builder。
  // 输入/输出及副作用：model、builder 为输入；经 put() 写 builder，不改 model。
  // 失败/边界：cast 失败、字段编码失败或 put 失败时返回错误，不继续写后续字段。
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

  // 功能：从 builder 解码 SRQC model：SRQ/PD 句柄、状态、深度、backing/shadow 页和阈值。
  // 输入/输出及副作用：builder 为输入，model 为输出，失败时保持 null；get() 读字段。
  // 失败/边界：字段码非法或 get 失败时返回错误且不发布 model。
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

  // 功能：构造 codec 对象。
  // 输入/输出及副作用：name 为对象名；仅调用 super.new。
  // 失败/边界：无。
  function new(string name = "rdma_hw_eq_create_body_codec_base");
    super.new(name);
  endfunction

  // 功能：校验 EQC 的页表模式、next backing、深度、页对齐及 vector/环指针位宽。
  // 输入/输出及副作用：depth、vector_id、layout、producer、consumer 为输入；只读。
  // 失败/边界：模式不支持、next_valid 为假、编码失败或字段越界时返回 INVALID_ARGUMENT/helper 错误。
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

  // 功能：把 EQ 通用字段经 builder 写入 EQC body。
  // 输入/输出及副作用：builder、eqn、state、depth、vector_id、layout、producer、consumer 为输入；经 put() 写 builder。
  // 失败/边界：状态/深度/页编码或 put 失败时返回错误。
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

  // 功能：从 builder 解码 EQC 通用字段。
  // 输入/输出及副作用：builder 为输入；eqn、state、depth、vector_id 为输出，layout/producer/consumer 为就地填充的 input 句柄。
  // 失败/边界：get、状态码或模式解码失败时返回错误。
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

  // 功能：返回 RDMA_MR_PBL0（该类 context 不使用 PBL）。
  // 输入/输出及副作用：model 为输入但未使用。
  // 失败/边界：无。
  protected virtual function rdma_mr_pbl_mode_e model_pbl_mode(
    rdma_hw_model model
  );
    return RDMA_MR_PBL0;
  endfunction
endclass

class rdma_hw_ceqc_create_body_codec
    extends rdma_hw_eq_create_body_codec_base;
  `rdma_object_utils(rdma_hw_ceqc_create_body_codec)

  // 功能：构造 codec 对象。
  // 输入/输出及副作用：name 为对象名；仅调用 super.new。
  // 失败/边界：无。
  function new(string name = "rdma_hw_ceqc_create_body_codec");
    super.new(name);
  endfunction
  // 功能：返回固定的 RDMA_IMAGE_CEQC。
  // 输入/输出及副作用：无输入；不读取对象字段。
  // 失败/边界：无。
  protected virtual function rdma_image_kind_e expected_image_kind();
    return RDMA_IMAGE_CEQC;
  endfunction
  // 功能：返回固定的 RDMA_OP_CEQC_CREATE。
  // 输入/输出及副作用：无输入；不读取对象字段。
  // 失败/边界：无。
  protected virtual function bit [7:0] expected_opcode();
    return RDMA_OP_CEQC_CREATE;
  endfunction
  // 功能：返回 model.ceq_h.generation，用作 image 的 function_generation。
  // 输入/输出及副作用：model 为输入；只读。
  // 失败/边界：cast 失败或 ceq_h 为空时返回 0。
  protected virtual function int unsigned owner_generation(
    rdma_hw_model model
  );
    rdma_ceqc_model ceqc;
    if (!$cast(ceqc, model) || ceqc.ceq_h == null) return 0;
    return ceqc.ceq_h.generation;
  endfunction

  // 功能：校验 CEQC model，并复用 validate_eq_layout。
  // 输入/输出及副作用：model 为输入；只读。
  // 失败/边界：cast 失败、model.validate 失败或 EQ 布局校验失败时返回 INVALID_ARGUMENT。
  virtual function rdma_status validate_model(rdma_hw_model model);
    rdma_ceqc_model ceqc;
    rdma_status status;
    if (!$cast(ceqc, model))
      return invalid_argument("rdma CEQC codec requires rdma_ceqc_model");
    status = context_status_or_error(
      ceqc.validate(), "CEQC model validation"
    );
    if (!status.ok())
      return invalid_argument({"CEQC model is invalid: ", status.message});
    return validate_eq_layout(ceqc.depth, ceqc.vector_id, ceqc.page_layout,
                              ceqc.producer, ceqc.consumer);
  endfunction
  // 功能：把 CEQC model 经 encode_eq_layout 写入 builder。
  // 输入/输出及副作用：model、builder 为输入；不改 model。
  // 失败/边界：cast 失败或 encode_eq_layout 失败时返回错误。
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
  // 功能：经 decode_eq_layout 解码 CEQC model 并投影 EQ 句柄。
  // 输入/输出及副作用：builder 为输入，model 为输出，失败时保持 null。
  // 失败/边界：decode_eq_layout 失败时返回错误且不发布 model。
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
  `rdma_object_utils(rdma_hw_aeqc_create_body_codec)

  // 功能：构造 codec 对象。
  // 输入/输出及副作用：name 为对象名；仅调用 super.new。
  // 失败/边界：无。
  function new(string name = "rdma_hw_aeqc_create_body_codec");
    super.new(name);
  endfunction
  // 功能：返回固定的 RDMA_IMAGE_AEQC。
  // 输入/输出及副作用：无输入；不读取对象字段。
  // 失败/边界：无。
  protected virtual function rdma_image_kind_e expected_image_kind();
    return RDMA_IMAGE_AEQC;
  endfunction
  // 功能：返回固定的 RDMA_OP_AEQC_CREATE。
  // 输入/输出及副作用：无输入；不读取对象字段。
  // 失败/边界：无。
  protected virtual function bit [7:0] expected_opcode();
    return RDMA_OP_AEQC_CREATE;
  endfunction
  // 功能：返回 model.aeq_h.generation，用作 image 的 function_generation。
  // 输入/输出及副作用：model 为输入；只读。
  // 失败/边界：cast 失败或 aeq_h 为空时返回 0。
  protected virtual function int unsigned owner_generation(
    rdma_hw_model model
  );
    rdma_aeqc_model aeqc;
    if (!$cast(aeqc, model) || aeqc.aeq_h == null) return 0;
    return aeqc.aeq_h.generation;
  endfunction

  // 功能：校验 AEQC model，并复用 validate_eq_layout。
  // 输入/输出及副作用：model 为输入；只读。
  // 失败/边界：cast 失败、model.validate 失败或 EQ 布局校验失败时返回 INVALID_ARGUMENT。
  virtual function rdma_status validate_model(rdma_hw_model model);
    rdma_aeqc_model aeqc;
    rdma_status status;
    if (!$cast(aeqc, model))
      return invalid_argument("rdma AEQC codec requires rdma_aeqc_model");
    status = context_status_or_error(
      aeqc.validate(), "AEQC model validation"
    );
    if (!status.ok())
      return invalid_argument({"AEQC model is invalid: ", status.message});
    return validate_eq_layout(aeqc.depth, aeqc.vector_id, aeqc.page_layout,
                              aeqc.producer, aeqc.consumer);
  endfunction
  // 功能：把 AEQC model 经 encode_eq_layout 写入 builder。
  // 输入/输出及副作用：model、builder 为输入；不改 model。
  // 失败/边界：cast 失败或 encode_eq_layout 失败时返回错误。
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
  // 功能：经 decode_eq_layout 解码 AEQC model 并投影 EQ 句柄。
  // 输入/输出及副作用：builder 为输入，model 为输出，失败时保持 null。
  // 失败/边界：decode_eq_layout 失败时返回错误且不发布 model。
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

// 功能：把 CQC/MRT(key_alloc、register)/SRQC/CEQC/AEQC codec 注册到 registry。
// 输入/输出及副作用：registry 为输入；按 key 逐个注册新建 codec 对象。
// 失败/边界：registry 为空返回 INVALID_ARGUMENT；任一注册返回 null 或失败时立即返回该错误。
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
  status = rdma_status::nonnull(
    registry.register_codec(
      key, rdma_hw_cqc_create_body_codec::type_id::create(
        "rdma_cqc_create_body_codec")),
    "CQC codec registration returned null status"
  );
  if (!status.ok())
    return status;

  key.image_kind = RDMA_IMAGE_MRT;
  key.object_type = "mrt";
  key.variant = "key_alloc";
  key.opcode = RDMA_OP_KEY_ALLOC;
  status = rdma_status::nonnull(
    registry.register_codec(
      key, rdma_hw_mrt_key_alloc_body_codec::type_id::create(
        "rdma_mrt_key_alloc_body_codec")),
    "MRT key-alloc codec registration returned null status"
  );
  if (!status.ok())
    return status;

  key.variant = "register";
  key.opcode = RDMA_OP_MR_REGISTER;
  status = rdma_status::nonnull(
    registry.register_codec(
      key, rdma_hw_mrt_register_body_codec::type_id::create(
        "rdma_mrt_register_body_codec")),
    "MRT register codec registration returned null status"
  );
  if (!status.ok())
    return status;

  key.image_kind = RDMA_IMAGE_SRQC;
  key.object_type = "srqc";
  key.variant = "create";
  key.opcode = RDMA_OP_SRFQC_CREATE;
  status = rdma_status::nonnull(
    registry.register_codec(
      key, rdma_hw_srqc_create_body_codec::type_id::create(
        "rdma_srqc_create_body_codec")),
    "SRQC codec registration returned null status"
  );
  if (!status.ok())
    return status;

  key.image_kind = RDMA_IMAGE_CEQC;
  key.object_type = "ceqc";
  key.opcode = RDMA_OP_CEQC_CREATE;
  status = rdma_status::nonnull(
    registry.register_codec(
      key, rdma_hw_ceqc_create_body_codec::type_id::create(
        "rdma_ceqc_create_body_codec")),
    "CEQC codec registration returned null status"
  );
  if (!status.ok())
    return status;

  key.image_kind = RDMA_IMAGE_AEQC;
  key.object_type = "aeqc";
  key.opcode = RDMA_OP_AEQC_CREATE;
  status = registry.register_codec(
    key, rdma_hw_aeqc_create_body_codec::type_id::create(
      "rdma_aeqc_create_body_codec"));
  if (status == null)
    return rdma_status::make(
      RDMA_SC_INVALID_STATE,
      "AEQC codec registration returned null status"
    );
  return status;
endfunction
