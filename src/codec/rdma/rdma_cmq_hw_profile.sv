// 目录/层次：codec/rdma 层的 X722/0.1.34 CMQ hardware profile 实现。
// 职责：组合 CMQ request/completion/error/doorbell codec，实现 RDMA SQE/CQE/doorbell 编解码。
// 主要依赖：rdma_cmq_hw_profile 抽象契约、RDMA CMQ body/completion codec；不直接执行 DMA 或 MMIO。
// 所有权与生命周期：profile 拥有构造的四类 codec/registry 句柄及注册 status；
// command/body/image 为非拥有输入，编码 image 由调用方拥有。

class rdma_hw_cmq_hw_profile extends rdma_cmq_hw_profile;
  `rdma_object_utils(rdma_hw_cmq_hw_profile)

  protected rdma_hw_cmq_request_composer request_composer;
  protected rdma_hw_cmq_completion_codec completion_codec;
  protected rdma_hw_error_codec error_codec;
  protected rdma_hw_doorbell_codec_registry doorbell_codecs;
  protected rdma_status doorbell_registration_status;

  // 功能：构造 CMQ profile 的 request/completion/error codec 与 doorbell registry，并注册默认 doorbell variants。
  // 输入/输出及副作用：name 为 UVM 实例名；四个 child 经 factory 创建；registry 非空时执行 register_defaults() 并保留其 status。
  // 失败/边界：child 缺失或默认注册失败时构造仍完成，validate_profile() 之后会拒绝使用。
  function new(string name = "rdma_hw_cmq_hw_profile");
    rdma_status status;
    super.new(name);
    request_composer = rdma_hw_cmq_request_composer::type_id::create(
      "request_composer");
    completion_codec = rdma_hw_cmq_completion_codec::type_id::create(
      "completion_codec");
    error_codec = rdma_hw_error_codec::type_id::create("error_codec");
    doorbell_codecs =
      rdma_hw_doorbell_codec_registry::type_id::create(
        "doorbell_codecs");
    doorbell_registration_status = null;
    if (doorbell_codecs != null) begin
      status = doorbell_codecs.register_defaults();
      doorbell_registration_status = status;
    end
  endfunction

  // 功能：返回 opcode key 和 codec registry 共用的稳定 profile 名“rdma”。
  // 输入/输出及副作用：无参数；返回 string literal 值，不读写对象字段。
  // 失败/边界：无失败分支；名称不随 hardware version 或具体 opcode 变化。
  virtual function string profile_name();
    return "rdma";
  endfunction

  // 功能：为 profile 输入契约违例构造 RDMA_SC_INVALID_ARGUMENT status。
  // 输入/输出及副作用：message 原样写入新 status；返回对象由调用方持有，不修改 profile。
  // 失败/边界：空 message 仍生成有效 INVALID_ARGUMENT status；本 helper 不包装硬件 ecode。
  protected function rdma_status invalid_argument(string message);
    return rdma_status::make(RDMA_SC_INVALID_ARGUMENT, message);
  endfunction

  // 功能：为 profile/codec 未就绪或输出违反内部契约构造 INVALID_STATE status。
  // 输入/输出及副作用：message 原样写入新 status；不修改 registry 或 codec 状态。
  // 失败/边界：空 message 仍返回非 OK INVALID_STATE；本 helper 不将错误降级或重试。
  protected function rdma_status invalid_state(string message);
    return rdma_status::make(RDMA_SC_INVALID_STATE, message);
  endfunction

  // 功能：构造 doorbell registry 查找键，variant 置于固定域。
  // 输入/输出及副作用：variant 输入；返回 hw_version="rdma"、DOORBELL、object_type="doorbell"、opcode=0 的 key。
  // 失败/边界：不校验空/未知 variant，lookup 是否命中由调用方检查。
  protected function rdma_codec_key doorbell_key(string variant);
    rdma_codec_key key;
    key.hw_version = "rdma";
    key.image_kind = RDMA_IMAGE_DOORBELL;
    key.object_type = "doorbell";
    key.variant = variant;
    key.opcode = 8'h00;
    return key;
  endfunction

  // 功能：确认三个 CMQ codec、doorbell registry 及其注册 status、CMQ opcode registry 与 13 个 doorbell variant
  //   均就绪。
  // 输入/输出及副作用：只读 child/status；调用全局 CMQ registry validate() 并逐个 lookup doorbell key；返回首个失败或 OK。
  // 失败/边界：任一 child/status 为 null、默认注册失败、registry 无效或 variant lookup 失败时拒绝；不自动重新注册。
  virtual function rdma_status validate_profile();
    string variants[13] = '{
      "cmq_sq", "sq", "rq", "srq_pi", "srq_limit", "cq_rc_ud",
      "cq_urc", "ceq", "aeq", "rts2sqd", "sqd2rts", "qp_flush",
      "tx_flush"
    };
    rdma_codec_base codec;
    rdma_status status;

    if (request_composer == null)
      return invalid_state("rdma CMQ request composer is not initialized");
    if (completion_codec == null)
      return invalid_state("rdma CMQ completion codec is not initialized");
    if (error_codec == null)
      return invalid_state("rdma error codec is not initialized");
    if (doorbell_codecs == null)
      return invalid_state("rdma doorbell registry is not initialized");
    if (doorbell_registration_status == null)
      return invalid_state("rdma doorbell default registration failed");
    if (!doorbell_registration_status.ok())
      return doorbell_registration_status;
    status = rdma_cmq_codec_registry::validate();
    if (!status.ok())
      return status;
    foreach (variants[i]) begin
      codec = null;
      status = doorbell_codecs.lookup(doorbell_key(variants[i]), codec);
      if (!status.ok() || codec == null)
        return invalid_state({"rdma doorbell defaults are incomplete: ",
                              variants[i]});
    end
    return rdma_status::success();
  endfunction

  // 功能：比较 command 与 slot 的 Function handle 是否指向同一 UID/global-ID/generation。
  // 输入/输出及副作用：lhs/rhs 为非拥有只读句柄；返回三个身份字段是否全等，不修改句柄。
  // 失败/边界：任一句柄为 null 返回 0；kind 已由两个上游 validate() 检查，本 helper 不重复报错。
  protected function bit same_function(
    rdma_function_handle lhs,
    rdma_function_handle rhs
  );
    if (lhs == null || rhs == null)
      return 1'b0;
    return lhs.function_uid == rhs.function_uid &&
           lhs.object_id == rhs.object_id &&
           lhs.generation == rhs.generation;
  endfunction

  // 功能：判断 opcode 的 body 是否按协议不携带 Function generation。
  // 输入/输出及副作用：opcode 输入；OCC_FLUSH/TQ_FLUSH 或 registry 标记的 generationless opcode 返回 1。
  // 失败/边界：未知/未注册 opcode 通常返回 0；该结果只决定 generation 校验，不表示 opcode 受支持。
  protected function bit generationless_opcode(bit [7:0] opcode);
    return opcode inside {RDMA_OP_OCC_FLUSH, RDMA_OP_TQ_FLUSH} ||
           rdma_cmq_codec_registry::is_generationless(opcode);
  endfunction

  // 功能：验证 composer 生成的未定址标准 64B 大端 CMQ SQE 及 generation 规则。
  // 输入/输出及副作用：image/opcode/function_generation 只读；检查 metadata 与 generationless 约束，不改 image target。
  // 失败/边界：image 为 null 返回 INVALID_STATE；长度/对齐/端序/kind/version/target 不符返回 CODEC_ERROR；
  //   generationless 非零返回 CODEC_ERROR，其余 generation 不符返回 STALE_GENERATION。
  protected function rdma_status validate_composed_sqe(
    rdma_hw_image image,
    bit [7:0] opcode,
    int unsigned function_generation
  );
    if (image == null)
      return invalid_state("rdma CMQ request composer published null");
    if (image.length != RDMA_CMQE_BYTES ||
        image.bytes.size() != RDMA_CMQE_BYTES ||
        image.alignment != RDMA_CMQE_BYTES ||
        image.endian != RDMA_ENDIAN_BIG ||
        image.image_kind != RDMA_IMAGE_CMQ_SQE ||
        image.hardware_version != RDMA_HW_VERSION ||
        image.write_target_kind != RDMA_HW_TARGET_NONE ||
        image.backing_target.value != 0 || image.hmc_target.value != 0 ||
        image.bar_target.value != 0)
      return rdma_status::make(
        RDMA_SC_CODEC_ERROR,
        "rdma CMQ request composer published invalid metadata"
      );
    if (generationless_opcode(opcode)) begin
      if (image.function_generation != 0)
        return rdma_status::make(
          RDMA_SC_CODEC_ERROR,
          "rdma generationless CMQ body published a generation"
        );
    end
    else if (image.function_generation != function_generation)
      return rdma_status::make(
        RDMA_SC_STALE_GENERATION,
        "rdma CMQ body generation does not match Function"
      );
    return rdma_status::success();
  endfunction

  // 功能：把受支持的 command body 包进 CMQ envelope，定位到 slot backing，并产生 CQE 期望键。
  // 输入/输出及副作用：command/slot 只读；sqe/expected 入口清空；成功发布 detached 64B SQE（BACKING target）与期望响应。
  // 失败/边界：profile/command/slot 无效、Function/opcode/VFID 不符、target 溢出或 codec 失败时原子拒绝；QPC_CREATE 的
  //   VFID 须为 0。
  virtual function rdma_status compose_sqe(
    rdma_cmq_command_desc command,
    rdma_cmq_slot_context slot,
    output rdma_hw_image sqe,
    output rdma_cmq_expected_response expected
  );
    rdma_status status;
    rdma_hw_image body;
    rdma_hw_image composed;
    rdma_hw_image detached;
    rdma_hw_cmq_envelope envelope;
    rdma_cmq_expected_response candidate_expected;
    bit [7:0] opcode;
    longint unsigned target_address;

    sqe = null;
    expected = null;
    status = validate_profile();
    if (!status.ok())
      return status;
    if (command == null)
      return invalid_argument("rdma CMQ command is null");
    if (slot == null)
      return invalid_argument("rdma CMQ slot is null");
    status = command.validate();
    if (!status.ok())
      return status;
    status = slot.validate();
    if (!status.ok())
      return status;
    if (!same_function(command.function_h, slot.function_h))
      return invalid_argument(
        "rdma CMQ command and slot Functions do not match"
      );
    if (command.opcode_key.profile_name != profile_name())
      return invalid_argument("CMQ command selects a different profile");
    if (command.opcode_key.opcode[31:8] != 0)
      return invalid_argument("rdma CMQ opcode exceeds 8 bits");

    // 驱动在 QPC_CREATE 路径把 VFID_OVERRIDE 与 USE_VFID 固定为零；
    // 非零输入必须在 body/image 构造前拒绝，避免发布不可达请求。
    if (command.opcode_key.opcode[7:0] == RDMA_OP_QPC_CREATE &&
        (command.vfid_override || command.use_vfid != 0))
      return invalid_argument(
        "QPC_CREATE driver-fixed VFID fields must remain zero"
      );

    if (!command.vfid_override && command.use_vfid != 0)
      return invalid_argument("rdma CMQ VFID requires override");
    if (slot.backing_addr.value >
        (64'hffff_ffff_ffff_ffff - slot.relative_offset))
      return rdma_status::make(
        RDMA_SC_DMA_TRANSLATION,
        "rdma CMQ SQE backing target overflows"
      );

    opcode = command.opcode_key.opcode[7:0];
    body = null;
    status = request_composer.build_body(opcode, command.body, body);
    if (!status.ok())
      return status;
    if (body == null)
      return invalid_state("rdma CMQ body composer published null");

    envelope = rdma_hw_cmq_envelope::type_id::create("envelope");
    envelope.valid = !slot.sq_wrap;
    envelope.vfid_override = command.vfid_override;
    envelope.use_vfid = command.use_vfid;
    envelope.wrap = slot.sq_wrap;
    envelope.wqe_index = slot.sq_index[4:0];
    envelope.opcode = opcode;
    composed = null;
    status = request_composer.compose_request(
      envelope, body, command.qpc_signature_source, composed
    );
    if (!status.ok())
      return status;
    status = validate_composed_sqe(
      composed, opcode, command.function_h.generation
    );
    if (!status.ok())
      return status;

    detached = rdma_hw_image::type_id::create("detached_sqe");
    detached.copy(composed);
    if (generationless_opcode(opcode))
      detached.function_generation = command.function_h.generation;
    target_address = slot.backing_addr.value + slot.relative_offset;
    detached.write_target_kind = RDMA_HW_TARGET_BACKING;
    detached.backing_target.value = target_address;
    detached.hmc_target = '0;
    detached.bar_target = '0;

    candidate_expected = rdma_cmq_expected_response::type_id::create(
      "expected_response");
    candidate_expected.hardware_opcode = {24'h0, opcode};
    candidate_expected.variant = command.opcode_key.variant;
    sqe = detached;
    expected = candidate_expected;
    return rdma_status::success();
  endfunction

  // 功能：解码前校验 raw image 是未定址的 64B CMQ CQE。
  // 输入/输出及副作用：raw_cqe 只读；检查 length/bytes、image_kind 与 NONE/零 target metadata。
  // 失败/边界：null、非 64B 或 kind/target metadata 非法统一返回 CODEC_ERROR；
  //   alignment/endian/version/generation 由下游约束。
  protected function rdma_status validate_raw_cqe(rdma_hw_image raw_cqe);
    if (raw_cqe == null)
      return rdma_status::make(RDMA_SC_CODEC_ERROR,
                               "CMQ raw CQE is null");
    if (raw_cqe.length != RDMA_CMQE_BYTES ||
        raw_cqe.bytes.size() != RDMA_CMQE_BYTES)
      return rdma_status::make(RDMA_SC_CODEC_ERROR,
                               "CMQ raw CQE length is invalid");
    if (raw_cqe.image_kind != RDMA_IMAGE_CMQ_CQE ||
        raw_cqe.write_target_kind != RDMA_HW_TARGET_NONE ||
        raw_cqe.backing_target.value != 0 ||
        raw_cqe.hmc_target.value != 0 || raw_cqe.bar_target.value != 0)
      return rdma_status::make(RDMA_SC_CODEC_ERROR,
                               "CMQ raw CQE metadata is invalid");
    return rdma_status::success();
  endfunction

  // 功能：经 completion/error codec 解码一个 owner-ready CQE，并组装 decoded CQE 值。
  // 输入/输出及副作用：raw_cqe/expected_owner 只读；ready 先置 0、decoded 先置 null；not-ready 返回 OK 且 ready=0。
  // 失败/边界：profile/image/codec 失败、ready 却返回 null、payload 克隆或 candidate 构造/校验失败时保持
  //   ready=0/decoded=null；operation 失败 status 作为数据保留。
  virtual function rdma_status inspect_cqe(
    rdma_hw_image raw_cqe,
    bit expected_owner,
    output bit ready,
    output rdma_cmq_decoded_cqe decoded
  );
    rdma_status status;
    rdma_status command_status;
    rdma_hw_cmq_completion completion;
    rdma_hw_cmq_completion payload;
    rdma_cmq_decoded_cqe candidate;
    bit completion_ready;

    ready = 1'b0;
    decoded = null;
    status = validate_profile();
    if (!status.ok())
      return status;
    status = validate_raw_cqe(raw_cqe);
    if (!status.ok())
      return status;
    completion = null;
    completion_ready = 1'b0;
    status = completion_codec.inspect_completion(
      raw_cqe, expected_owner, completion_ready, completion
    );
    if (!status.ok())
      return status;
    if (!completion_ready)
      return rdma_status::success();
    if (completion == null)
      return invalid_state("rdma completion codec published null");

    command_status = null;
    status = error_codec.decode_status(completion.command_ecode,
                                       RDMA_ENGINE_CMQ, command_status);
    if (!status.ok())
      return status;
    if (command_status == null)
      return invalid_state("rdma error codec published null");
    if (!rdma_deep_copy#(rdma_hw_cmq_completion)::try_of(completion, payload))
      return invalid_state("rdma completion payload clone failed");

    candidate = rdma_cmq_decoded_cqe::type_id::create("decoded_cqe");
    if (candidate == null)
      return invalid_state("rdma decoded CQE allocation failed");
    candidate.hardware_opcode = {24'h0, completion.opcode};
    candidate.wqe_index = completion.wqe_index;
    candidate.wqe_wrap = completion.wrap;
    candidate.hardware_ecode = {24'h0, completion.command_ecode};
    candidate.command_status = command_status;
    candidate.response_payload = payload;
    status = candidate.validate();
    if (!status.ok())
      return status;
    decoded = candidate;
    ready = 1'b1;
    return rdma_status::success();
  endfunction

  // 功能：构造 CMQ-SQ doorbell model，经 registry 编码 final PI/polarity，发布 detached image。
  // 输入/输出及副作用：cmq_h/final_pi/polarity 只读；image 入口清空；不写 MMIO。
  // 失败/边界：profile 无效、cmq_h 为 null/非 CMQ、final_pi>=32、克隆或 registry 编码失败时不发布部分输出。
  virtual function rdma_status encode_doorbell(
    rdma_handle cmq_h,
    int unsigned final_pi,
    bit polarity,
    output rdma_hw_image image
  );
    rdma_status status;
    rdma_hw_cmq_sq_doorbell_model model;
    rdma_hw_image encoded;
    rdma_hw_image detached;
    uvm_object cloned_object;

    image = null;
    status = validate_profile();
    if (!status.ok())
      return status;
    if (cmq_h == null || cmq_h.kind != RDMA_RESOURCE_CMQ)
      return invalid_argument("rdma CMQ doorbell handle is invalid");
    if (final_pi >= 32)
      return invalid_argument("rdma CMQ doorbell PI exceeds 5 bits");

    model = rdma_hw_cmq_sq_doorbell_model::type_id::create(
      "cmq_sq_doorbell");
    cloned_object = cmq_h.clone();
    if (cloned_object == null || !$cast(model.target_h, cloned_object))
      return invalid_state("rdma CMQ doorbell handle clone failed");
    model.pi = final_pi;
    model.polarity = polarity;
    encoded = null;
    status = doorbell_codecs.encode(model, encoded);
    if (!status.ok())
      return status;
    if (encoded == null)
      return invalid_state("rdma doorbell codec published null");
    detached = rdma_hw_image::type_id::create("detached_doorbell");
    detached.copy(encoded);
    image = detached;
    return rdma_status::success();
  endfunction
endclass
