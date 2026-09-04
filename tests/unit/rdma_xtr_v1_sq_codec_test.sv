// 目录：tests/unit/，验证 XTR v1 SQE 编解码、签名和边界约束。
// 职责：驱动 SQE 编解码的正常、异常和边界向量，保证镜像布局保持稳定。
// 依赖：rdma_codec_pkg 及 SQE 模型；测试只创建并持有本地 fixture，不拥有外部后端资源。
// 所有权与生命周期：UVM build/run 阶段构造本地输入，断言完成后释放 objection；失败通过 UVM 报告上报。
class rdma_xtr_v1_sq_codec_test extends uvm_test;
  `uvm_component_utils(rdma_xtr_v1_sq_codec_test)

  // 功能：构造当前对象并初始化其字段、集合和 UVM 名称；不接管传入句柄的生命周期。
  // 输入/输出及副作用：name 仅用于 UVM 对象命名；内部字段被初始化为安全默认值，传入句柄不转移所有权。
  //   返回新对象实例；构造失败由 UVM 工厂或调用方处理。
  // 失败/边界：不创建外部资源；name 为空时仍允许构造，但所有字段必须保持可配置的初始值。
  function new(string name = "rdma_xtr_v1_sq_codec_test",
               uvm_component parent = null);
    super.new(name, parent);
  endfunction

  // 功能：处理 test_qp_handle：依据其参数完成所属层的具体协议动作，并保持返回状态、游标和资源所有权一致。
  // 输入/输出及副作用：参数 h 用于执行 test_qp_handle；返回值或 output/inout 交付处理结果，必要时更新本对象状态。
  //   调用方不获得内部集合或外部依赖的所有权。
  // 失败/边界：test_qp_handle 只接受其签名声明的输入；缺少必要字段时返回错误，成功路径不得隐式修改无关资源。
  function automatic rdma_handle test_qp_handle();
    rdma_handle h;
    h = rdma_handle::type_id::create("sq_test_qp");
    h.kind = RDMA_RESOURCE_QP;
    h.function_uid = 64'h1122_3344;
    h.object_id = 21'h12;
    h.generation = 7;
    return h;
  endfunction

  // 功能：把输入模型字段按硬件布局编码到目标 image/缓冲区，并在写入前检查范围、重叠和保留位。
  // 输入/输出及副作用：参数 sq, image 用于执行 encode_rc_sqe；返回值或 output/inout 交付处理结果，必要时更新本对象状态。
  //   调用方不获得内部集合或外部依赖的所有权。
  // 失败/边界：镜像长度、字段宽度、保留位或写入范围非法时不修改已写入字节。
  function automatic rdma_status encode_rc_sqe(
      rdma_xtr_v1_sqe_model sq,
      output rdma_hw_image image);
    rdma_codec_registry registry;
    rdma_codec_base codec;
    rdma_status status;

    image = null;
    registry = rdma_codec_registry::type_id::create("sq_codec_registry");
    status = rdma_xtr_v1_register_queue_codecs(registry);
    if (status == null || !status.ok())
      return status;
    status = registry.lookup(
      '{hw_version:"xtr_v1", image_kind:RDMA_IMAGE_SQE,
        object_type:"sqe", variant:"rc", opcode:8'h00}, codec);
    if (status == null || !status.ok())
      return status;
    return codec.encode(sq, image);
  endfunction

  // 功能：处理 signature_is_ff：依据其参数完成所属层的具体协议动作，并保持返回状态、游标和资源所有权一致。
  // 输入/输出及副作用：参数 image, sgb 用于执行 signature_is_ff；返回值或 output/inout 交付处理结果，必要时更新本对象状态。
  //   调用方不获得内部集合或外部依赖的所有权。
  // 失败/边界：signature_is_ff 只接受其签名声明的输入；缺少必要字段时返回错误，成功路径不得隐式修改无关资源。
  function automatic bit signature_is_ff(
      rdma_hw_image image,
      byte unsigned sgb[$]);
    bit valid;
    rdma_status status;
    status = validate_sq_signature(image, sgb, valid);
    return status != null && status.ok() && valid;
  endfunction

  // 功能：依据输入请求创建对应的值对象或资源计划，并校验依赖、所有权和生命周期后返回结果。
  // 输入/输出及副作用：输入请求、容量和依赖用于构造/预留资源；返回独立对象或状态，不暴露内部可变集合。
  //   参数越界、容量不足或构造中途失败时回滚已登记的局部状态。
  // 失败/边界：依赖为空、参数越界、容量不足或构造步骤失败时清理局部结果并返回明确错误。
  function automatic rdma_xtr_v1_sqe_model make_rc_inline_request(
      int unsigned n);
    rdma_xtr_v1_sqe_model x;
    x = rdma_xtr_v1_sqe_model::type_id::create("rc_inline");
    x.transport = RDMA_TRANSPORT_RC;
    x.qp_h = test_qp_handle();
    x.opcode = RDMA_WR_SEND;
    x.hw_opcode = XTR_V1_SQ_OPCODE_SEND;
    x.qpn = 21'h12;
    x.valid = 1'b1;
    x.sign_en = 1'b1;
    x.payload_mode = n <= 32 ? RDMA_SQ_PAYLOAD_INLINE_WQE :
                               RDMA_SQ_PAYLOAD_INLINE_SGB;
    x.inline_bytes = new[n];
    foreach (x.inline_bytes[i])
      x.inline_bytes[i] = i;
    x.total_payload_len = n;
    return x;
  endfunction

  // 功能：依据输入请求创建对应的值对象或资源计划，并校验依赖、所有权和生命周期后返回结果。
  // 输入/输出及副作用：输入请求、容量和依赖用于构造/预留资源；返回独立对象或状态，不暴露内部可变集合。
  //   参数越界、容量不足或构造中途失败时回滚已登记的局部状态。
  // 失败/边界：依赖为空、参数越界、容量不足或构造步骤失败时清理局部结果并返回明确错误。
  function automatic rdma_xtr_v1_sqe_model make_rc_atomic_request(
      rdma_work_opcode_e opcode);
    rdma_xtr_v1_sqe_model x;
    x = rdma_xtr_v1_sqe_model::type_id::create("rc_atomic");
    x.transport = RDMA_TRANSPORT_RC;
    x.qp_h = test_qp_handle();
    x.opcode = opcode;
    x.hw_opcode = opcode == RDMA_WR_ATOMIC_CMP_SWAP ?
                  XTR_V1_SQ_OPCODE_ATOMIC_CMP_AND_SWP :
                  XTR_V1_SQ_OPCODE_ATOMIC_FETCH_AND_ADD;
    x.payload_mode = RDMA_SQ_PAYLOAD_ATOMIC_FIXED;
    x.atomic_local_iova.value = 64'h8000;
    x.atomic_local_lkey = 32'h8765_4321;
    begin
      rdma_sge local_sge;
      local_sge = rdma_sge::type_id::create("atomic_local_sge");
      local_sge.length = 8;
      local_sge.lkey = x.atomic_local_lkey;
      local_sge.iova.value = x.atomic_local_iova.value;
      x.sges.push_back(local_sge);
    end
    x.atomic_value = 64'h1122;
    x.atomic_compare = 64'h3344;
    x.total_payload_len = 8;
    x.rkey = 32'h1234_5678;
    x.remote_va.value = 64'h2000;
    return x;
  endfunction

  // 功能：驱动 UVM 阶段中的场景初始化、事务执行和断言收尾，并在退出前释放 objection 或测试资源。
  // 输入/输出及副作用：phase 控制 UVM 调度；task 驱动事务、断言和 objection，测试 fixture 由本层负责清理。
  //   阶段提前结束或前置 setup 失败时必须释放 objection 并停止后续访问。
  // 失败/边界：setup 失败或阶段被终止时停止新增事务，确保 objection、临时对象和外部引用按测试生命周期收尾。
  task run_phase(uvm_phase phase);
    rdma_xtr_v1_sqe_model sq, decoded;
    rdma_hw_image image, image2;
    rdma_status status;
    rdma_codec_registry registry;
    rdma_codec_base codec;
    rdma_hw_model model;
    byte unsigned sgb[$];

    phase.raise_objection(this);

    sq = make_rc_inline_request(32);
    status = encode_rc_sqe(sq, image);
    if (status == null || !status.ok() || image == null ||
        image.bytes.size() != 64)
      `uvm_error("RC_INLINE", $sformatf("32-byte RC inline SQE did not encode: %s",
                 status == null ? "null" : status.convert2string()))
    if (image != null && image.bytes[32] !== 8'h00 ||
        image != null && image.bytes[63] !== 8'h1f)
      `uvm_error("RC_INLINE_BYTES", "inline payload is not raw byte ordered")
    if (image != null && !signature_is_ff(image, sgb))
      `uvm_error("RC_SIG", "RC signature XOR is not 8'hff")

    sq = make_rc_inline_request(33);
    sq.sgb_iova.value = 64'h4000;
    status = encode_rc_sqe(sq, image);
    if (status == null || !status.ok() || image == null || image.bytes[32] !== 8'h00)
      `uvm_error("RC_INLINE_SGB", $sformatf("33-byte RC inline-SGB SQE did not encode: %s",
                 status == null ? "null" : status.convert2string()))
    sgb.delete();
    for (int unsigned i = 0; i < 512; i++)
      sgb.push_back(i < 33 ? i : 0);
    if (image != null && !signature_is_ff(image, sgb))
      `uvm_error("RC_SGB_SIG", "RC SGB signature XOR is not 8'hff")
    begin
      byte unsigned malformed_sgb[$];
      bit malformed_valid;
      malformed_sgb.push_back(8'h00);
      status = validate_sq_signature(image, malformed_sgb, malformed_valid);
      if (status == null || status.ok())
        `uvm_error("RC_SGB_SIZE", "non-512-byte SGB was accepted")
    end
    registry = rdma_codec_registry::type_id::create("sgb_decode_registry");
    status = rdma_xtr_v1_register_queue_codecs(registry);
    status = registry.lookup(
      '{hw_version:"xtr_v1", image_kind:RDMA_IMAGE_SQE,
        object_type:"sqe", variant:"rc", opcode:8'h00}, codec);
    model = null;
    status = codec.decode(image, model);
    if (status == null || !status.ok() || !$cast(decoded, model) ||
        decoded.payload_mode != RDMA_SQ_PAYLOAD_INLINE_SGB ||
        decoded.sgb_iova.value != sq.sgb_iova.value)
      `uvm_error("RC_SGB_DECODE", "RC inline-SGB decode lost SGB pointer or mode")

    sq = rdma_xtr_v1_sqe_model::type_id::create("rc_direct");
    sq.transport = RDMA_TRANSPORT_RC;
    sq.qp_h = test_qp_handle();
    sq.opcode = RDMA_WR_SEND;
    sq.hw_opcode = XTR_V1_SQ_OPCODE_SEND;
    sq.qpn = 21'h12;
    sq.payload_mode = RDMA_SQ_PAYLOAD_SGE_WQE;
    sq.total_payload_len = 8;
    for (int unsigned i = 0; i < 1; i++) begin
      rdma_sge sge;
      sge = rdma_sge::type_id::create($sformatf("sge%0d", i));
      sge.length = 8;
      sge.lkey = 32'h1000;
      sge.iova.value = 64'h1000;
      sq.sges.push_back(sge);
    end
    status = encode_rc_sqe(sq, image);
    if (status == null || !status.ok() || image == null || image.bytes[32] !== 8'h00 ||
        image.bytes[35] !== 8'h08 || image.bytes[36] !== 8'h00 ||
        image.bytes[39] !== 8'h00)
      `uvm_error("RC_DIRECT", "direct SGE descriptor did not encode")

    sq = make_rc_atomic_request(RDMA_WR_ATOMIC_CMP_SWAP);
    status = encode_rc_sqe(sq, image);
    if (image != null)
      `uvm_info("RC_ATOMIC_DBG", $sformatf("status=%s bytes32-39=%02x %02x %02x %02x %02x %02x %02x %02x",
                 status.convert2string(), image.bytes[32], image.bytes[33],
                 image.bytes[34], image.bytes[35], image.bytes[36],
                 image.bytes[37], image.bytes[38], image.bytes[39]), UVM_LOW)
    if (status == null || !status.ok() || image == null || image.bytes[32] !== 8'h00 ||
        image.bytes[35] !== 8'h08)
      `uvm_error("RC_ATOMIC", $sformatf("atomic fixed body was not emitted: %s",
                 status == null ? "null" : status.convert2string()))
    sgb.delete();
    if (image != null && !signature_is_ff(image, sgb))
      `uvm_error("RC_ATOMIC_SIG", "atomic signature XOR is not 8'hff")

    // Local invalidate carries its key through the RC transport extension;
    // the codec must project that detached semantic value into qword 1.
    sq = rdma_xtr_v1_sqe_model::type_id::create("rc_local_invalidate");
    sq.transport = RDMA_TRANSPORT_RC;
    sq.qp_h = test_qp_handle();
    sq.opcode = RDMA_WR_LOCAL_INVALIDATE;
    sq.payload_mode = RDMA_SQ_PAYLOAD_NONE;
    sq.valid = 1'b1;
    begin
      rdma_sqe_rc_ext ext;
      ext = rdma_sqe_rc_ext::type_id::create("local_invalidate_ext");
      ext.rkey_valid = 1'b1;
      ext.rkey = 32'hca_fe_babe;
      sq.transport_ext = ext;
    end
    status = encode_rc_sqe(sq, image);
    if (status == null || !status.ok() || image == null ||
        image.bytes[8] !== 8'hca || image.bytes[9] !== 8'hfe ||
        image.bytes[10] !== 8'hba || image.bytes[11] !== 8'hbe)
      `uvm_error("RC_LOCAL_INV_KEY", "RC local-invalidate key was not encoded")

    // SGB-backed direct SGEs contribute their serialized descriptors to the
    // signature, just like inline SGB payload bytes do.
    sq = rdma_xtr_v1_sqe_model::type_id::create("rc_sgb_sges");
    sq.transport = RDMA_TRANSPORT_RC;
    sq.qp_h = test_qp_handle();
    sq.opcode = RDMA_WR_SEND;
    sq.hw_opcode = XTR_V1_SQ_OPCODE_SEND;
    sq.payload_mode = RDMA_SQ_PAYLOAD_SGE_SGB;
    sq.sgb_iova.value = 64'h8000;
    sq.total_payload_len = 24;
    for (int unsigned i = 0; i < 3; i++) begin
      rdma_sge sge;
      sge = rdma_sge::type_id::create($sformatf("sgb_sge%0d", i));
      sge.length = 8;
      sge.lkey = 32'h1000 + i;
      sge.iova.value = 64'h1000 + i * 8;
      sq.sges.push_back(sge);
    end
    status = encode_rc_sqe(sq, image);
    if (status == null || !status.ok() || image == null)
      `uvm_error("RC_SGE_SGB", "RC SGE-SGB descriptor did not encode")
    sgb.delete();
    for (int unsigned i = 0; i < 512; i++)
      sgb.push_back(8'h00);
    for (int unsigned i = 0; i < 3; i++) begin
      int unsigned base;
      base = i * 16;
      sgb[base + 3] = 8'h08;
      sgb[base + 4] = 8'h00;
      sgb[base + 5] = 8'h00;
      sgb[base + 6] = 8'h10;
      sgb[base + 7] = 8'h00 + i;
      sgb[base + 12] = 8'h00;
      sgb[base + 13] = 8'h00;
      sgb[base + 14] = 8'h10;
      sgb[base + 15] = 8'h00 + i * 8;
    end
    if (image != null && !signature_is_ff(image, sgb))
      `uvm_error("RC_SGE_SGB_SIG", "RC SGE-SGB signature omitted descriptors")

    sq = make_rc_inline_request(513);
    sq.sgb_iova.value = 64'h4000;
    status = encode_rc_sqe(sq, image);
    if (status == null || status.ok())
      `uvm_error("RC_INLINE_MAX", "inline payload larger than one SGB was accepted")

    // Use a complete inline-WQE image for the decode/re-encode round trip;
    // SGB-backed payload bytes live outside the 64-byte image and therefore
    // cannot be reconstructed by a decoder that only receives the WQE.
    sq = make_rc_inline_request(1);
    status = encode_rc_sqe(sq, image);
    if (status == null || !status.ok() || image == null)
      `uvm_error("RC_REENCODE_FIXTURE", "valid RC inline fixture did not encode")

    registry = rdma_codec_registry::type_id::create("sq_decode_registry");
    status = rdma_xtr_v1_register_queue_codecs(registry);
    status = registry.lookup(
      '{hw_version:"xtr_v1", image_kind:RDMA_IMAGE_SQE,
        object_type:"sqe", variant:"rc", opcode:8'h00}, codec);
    status = codec.decode(image, model);
    if (status == null || !status.ok() || !$cast(decoded, model))
      `uvm_error("RC_DECODE", "RC inline SQE did not decode")
    status = codec.encode(decoded, image2);
    if (status == null || !status.ok())
      `uvm_error("RC_REENCODE", $sformatf("decoded RC SQE did not re-encode: %s",
                 status == null ? "null" : status.convert2string()))

    // The queue-data engine supplies semantic opcode enum values.  The codec
    // must project those values onto the pinned XTR hardware opcode map.
    sq = make_rc_inline_request(1);
    sq.hw_opcode = RDMA_WR_SEND;
    status = encode_rc_sqe(sq, image);
    if (status == null || !status.ok() || image == null ||
        (image.bytes[3] & 8'h0f) != XTR_V1_SQ_OPCODE_SEND)
      `uvm_error("RC_OPCODE_MAP", "semantic SEND opcode was not projected")

    // Signature corruption must be rejected when the payload is wholly in the
    // 64-byte WQE and therefore available to the decoder.
    if (image2 != null) begin
      image2.bytes[16] ^= 8'h01;
      model = null;
      status = codec.decode(image2, model);
      if (status == null || status.ok())
        `uvm_error("RC_BAD_SIG", "corrupted RC signature was accepted")
    end

    // Ordinary RC operations cannot use an empty payload mode, and direct SGE
    // lengths must agree with the descriptor sum and the reserved bit rule.
    sq = make_rc_inline_request(1);
    sq.payload_mode = RDMA_SQ_PAYLOAD_NONE;
    sq.inline_data = 1'b0;
    sq.inline_bytes.delete();
    sq.total_payload_len = 0;
    status = encode_rc_sqe(sq, image);
    if (status == null || status.ok())
      `uvm_error("RC_EMPTY_SHAPE", "empty ordinary RC payload was accepted")

    sq = rdma_xtr_v1_sqe_model::type_id::create("rc_bad_sge_len");
    sq.transport = RDMA_TRANSPORT_RC;
    sq.qp_h = test_qp_handle();
    sq.opcode = RDMA_WR_SEND;
    sq.hw_opcode = XTR_V1_SQ_OPCODE_SEND;
    sq.payload_mode = RDMA_SQ_PAYLOAD_SGE_WQE;
    sq.total_payload_len = 7;
    begin
      rdma_sge sge;
      sge = rdma_sge::type_id::create("bad_len_sge");
      sge.length = 8;
      sge.lkey = 32'h1000;
      sge.iova.value = 64'h1000;
      sq.sges.push_back(sge);
    end
    status = encode_rc_sqe(sq, image);
    if (status == null || status.ok())
      `uvm_error("RC_SGE_LEN", "inconsistent RC SGE payload length was accepted")
    sq.total_payload_len = 8;
    sq.sges[0].length = 32'h8000_0001;
    status = encode_rc_sqe(sq, image);
    if (status == null || status.ok())
      `uvm_error("RC_SGE_RESERVED", "SGE reserved length bit was accepted")

    // Atomic shape is selected by opcode, not by a caller-supplied alternate
    // mode that would otherwise emit an ordinary SGE body.
    sq = make_rc_atomic_request(RDMA_WR_ATOMIC_CMP_SWAP);
    sq.payload_mode = RDMA_SQ_PAYLOAD_SGE_WQE;
    status = encode_rc_sqe(sq, image);
    if (status == null || status.ok())
      `uvm_error("RC_ATOMIC_MODE", "atomic opcode accepted a non-atomic mode")

    // Decode must preserve completion and solicited header semantics.
    sq = make_rc_inline_request(1);
    sq.signaled = 1'b1;
    sq.se = 1'b1;
    sq.fence = 1'b1;
    status = encode_rc_sqe(sq, image);
    model = null;
    status = codec.decode(image, model);
    if (status == null || !status.ok() || model == null)
      `uvm_error("RC_SIGNALED_DECODE", "signaled RC SQE did not decode")
    else begin
      decoded = null;
      if (!$cast(decoded, model))
        `uvm_error("RC_SIGNALED_TYPE", "decoded signaled RC SQE type mismatch")
      else begin
        status = codec.encode(decoded, image2);
        if (status == null || !status.ok() || image2 == null ||
            image2.bytes.size() != image.bytes.size())
          `uvm_error("RC_SIGNALED_REENCODE", "signaled RC SQE did not re-encode")
        else foreach (image.bytes[i])
          if (image2.bytes[i] !== image.bytes[i]) begin
            `uvm_error("RC_SIGNALED_BYTES", "signaled RC decode/re-encode drifted")
            break;
          end
      end
    end

    phase.drop_objection(this);
  endtask
endclass
