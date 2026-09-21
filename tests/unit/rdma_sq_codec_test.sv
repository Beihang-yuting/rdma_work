// 目录/层次：tests/unit/ 单元测试层，验证 XTR v1 SQE 编解码、签名和边界约束。
// 职责：驱动 SQE 编解码的正常、异常和边界向量，保证镜像布局保持稳定。
// 依赖：rdma_codec_pkg 及 SQE 模型；测试只创建并持有本地 fixture，不拥有外部后端资源。
// 所有权与生命周期：UVM build/run 阶段构造本地输入，断言完成后释放 objection；失败通过 UVM 报告上报。
class rdma_sq_codec_test extends uvm_test;
  `uvm_component_utils(rdma_sq_codec_test)

  // 功能：构造 rdma_sq_codec_test，调用 super.new 建立 UVM 层级对象；外部依赖字段保持未绑定，后续由 configure/build/activate 明确注入。
  // 输入/输出及副作用：name、parent（输入）；new 只写入构造体列出的默认字段并返回 void，外部依赖与资源所有权仍由上层管理。
  // 失败/边界：rdma_sq_codec_test 构造只建立本地初始状态，不接管外部 Host-memory、PCIe 或 manager；未完成后续 configure/build/activate 时，业务入口必须返回 INVALID_STATE。
  function new(string name = "rdma_sq_codec_test",
               uvm_component parent = null);
    super.new(name, parent);
  endfunction

  // 功能：在 rdma_sq_codec_test 中，test_qp_handle 从测试 fixture 返回预先构造的 Function/队列句柄或 DMA 上下文，保持调用方与 fixture 使用同一实例。
  // 输入/输出及副作用：无显式参数；test_qp_handle 读取局部计算结果，并使用字段 h、h.kind、h.function_uid、h.object_id、h.generation；函数返回 rdma_handle，不取得调用方资源所有权。
  // 失败/边界：test_qp_handle 的结果直接由 return h 计算；输入不满足表达式条件时沿函数体的保守分支返回，不修改已发布账本。
  function automatic rdma_handle test_qp_handle();
    rdma_handle h;
    h = rdma_handle::type_id::create("sq_test_qp");
    h.kind = RDMA_RESOURCE_QP;
    h.function_uid = 64'h1122_3344;
    h.object_id = 21'h12;
    h.generation = 7;
    return h;
  endfunction

  // 功能：在 rdma_sq_codec_test 中，encode_rc_sqe 按硬件布局把输入模型编码到 image/缓冲区，并在写入前检查范围、重叠、端序和保留位。
  // 输入/输出及副作用：sq（输入）、image（输出）；输入模型只读；成功时通过返回值或 output 发布完整 image/bytes，不修改源模型。
  // 失败/边界：encode_rc_sqe 遇到 image/model 为空、长度/对齐/保留位非法或 codec 校验失败时不发布部分字段。
  function automatic rdma_status encode_rc_sqe(
      rdma_hw_sqe_model sq,
      output rdma_hw_image image);
    rdma_codec_registry registry;
    rdma_codec_base codec;
    rdma_status status;

    image = null;
    registry = rdma_codec_registry::type_id::create("sq_codec_registry");
    status = rdma_register_queue_codecs(registry);
    if (status == null || !status.ok())
      return status;
    status = registry.lookup(
      '{hw_version:"rdma", image_kind:RDMA_IMAGE_SQE,
        object_type:"sqe", variant:"rc", opcode:8'h00}, codec);
    if (status == null || !status.ok())
      return status;
    return codec.encode(sq, image);
  endfunction

  // 功能：在 rdma_sq_codec_test 中，signature_is_ff 检查当前事务或测试证据是否满足指定布尔条件，供恢复分类和断言选择后续路径。
  // 输入/输出及副作用：image（输入）、sgb（输入）；signature_is_ff 读取 image、sgb 并使用字段 status；函数返回 bit，不取得调用方资源所有权。
  // 失败/边界：signature_is_ff 是只读访问器，返回 status != null && status.ok() && valid；未覆盖枚举沿 default/类型默认分支返回，不改变对象和外部资源。
  function automatic bit signature_is_ff(
      rdma_hw_image image,
      byte unsigned sgb[$]);
    bit valid;
    rdma_status status;
    status = validate_sq_signature(image, sgb, valid);
    return status != null && status.ok() && valid;
  endfunction

  // 功能：make_rc_inline_request 构造 RC SEND inline fixture，以 n 个递增
  //   literal byte 选择 32-byte 内 WQE 或外部 SGB mode，并把 canonical
  //   sge_num 明确设为 ceil(n/16)，供 wire byte 17 与 mismatch 合约断言使用。
  // 输入/输出及副作用：n 指定 inline_bytes 与 total_payload_len；函数分配并
  //   返回调用方持有的 rdma_hw_sqe_model，不修改 registry 或外部资源。
  // 失败/边界：n=0 时 count 为 0；n>512 仍可构造用于 codec 上限负例，helper
  //   本身不执行合法性校验，动态数组分配失败则无法形成可运行 fixture。
  function automatic rdma_hw_sqe_model make_rc_inline_request(
      int unsigned n);
    rdma_hw_sqe_model x;
    x = rdma_hw_sqe_model::type_id::create("rc_inline");
    x.transport = RDMA_TRANSPORT_RC;
    x.qp_h = test_qp_handle();
    x.opcode = RDMA_WR_SEND;
    x.hw_opcode = RDMA_SQ_OPCODE_SEND;
    x.qpn = 21'h12;
    x.valid = 1'b1;
    x.sign_en = 1'b1;
    x.payload_mode = n <= 32 ? RDMA_SQ_PAYLOAD_INLINE_WQE :
                               RDMA_SQ_PAYLOAD_INLINE_SGB;
    x.inline_bytes = new[n];
    foreach (x.inline_bytes[i])
      x.inline_bytes[i] = i;
    x.total_payload_len = n;
    x.sge_num = (n + 15) / 16;
    return x;
  endfunction

  // 功能：make_rc_atomic_request 构造 RC compare-swap/fetch-add fixed-body
  //   fixture，绑定唯一 8-byte local SGE、远端 key/address 与操作数，并把
  //   atomic canonical sge_num 固定为 1，而不是按 total_payload_len 重算。
  // 输入/输出及副作用：opcode 选择 semantic/hardware atomic opcode；函数新建
  //   model 与 local_sge 并返回给调用方，不转移 QP 或 memory-region 所有权。
  // 失败/边界：helper 只为两种 atomic opcode 设计；其他枚举落入 fetch-add
  //   hardware fixture 分支并应由 codec 拒绝，helper 自身不返回 rdma_status。
  function automatic rdma_hw_sqe_model make_rc_atomic_request(
      rdma_work_opcode_e opcode);
    rdma_hw_sqe_model x;
    x = rdma_hw_sqe_model::type_id::create("rc_atomic");
    x.transport = RDMA_TRANSPORT_RC;
    x.qp_h = test_qp_handle();
    x.opcode = opcode;
    x.hw_opcode = opcode == RDMA_WR_ATOMIC_CMP_SWAP ?
                  RDMA_SQ_OPCODE_ATOMIC_CMP_AND_SWP :
                  RDMA_SQ_OPCODE_ATOMIC_FETCH_AND_ADD;
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
    x.sge_num = 1;
    x.rkey = 32'h1234_5678;
    x.remote_va.value = 64'h2000;
    return x;
  endfunction

  // 功能：run_phase 验证 RC inline/direct/external/atomic 的 raw 布局、signature
  //   与 canonical SGE_NUM，并覆盖 512B/32-chunk 正向边界及 513B/33-chunk
  //   raw capacity 拒绝、zero-byte inline round-trip、null-SGE 拒绝和
  //   extension 投影失败时 caller model/嵌套对象保持不变。
  // 输入/输出及副作用：phase 为 UVM 阶段输入；task 管理 objection，创建本地
  //   model/image/SGE 快照并发布 contract ID，不写真实 Host-memory 或队列 runtime。
  // 失败/边界：encode/decode、literal raw 字段、signature、raw mode、容量边界、
  //   输入原子性或 payload shape 任一不符时报告 UVM_ERROR；所有路径最终释放
  //   objection。
  task run_phase(uvm_phase phase);
    rdma_hw_sqe_model sq, decoded;
    rdma_hw_image image, image2;
    rdma_hw_image malformed_direct_length;
    rdma_hw_image malformed_atomic_length;
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
    if (status == null || !status.ok() || image == null ||
        image.bytes[17] !== 8'd3 || image.bytes[32] !== 8'h00)
      `uvm_error("RC_INLINE_SGB", $sformatf("33-byte RC inline-SGB SQE did not encode: %s",
                 status == null ? "null" : status.convert2string()))
    // F2 RED：33 个 literal inline bytes 占三个 16-byte chunk；caller-visible
    // sge_num 若声明为 2，codec 必须拒绝且不能发布按自身重算值 3 生成的 image。
    sq.sge_num = 8'd2;
    status = encode_rc_sqe(sq, image);
    if (status == null || status.ok() || image != null)
      `uvm_error("SQE_SGE_NUM_INLINE_MISMATCH",
                 "33-byte inline SQE accepted caller sge_num other than three")
    sq.sge_num = 8'd3;
    status = encode_rc_sqe(sq, image);
    sgb.delete();
    for (int unsigned i = 0; i < 512; i++)
      sgb.push_back(i < 33 ? i : 0);
    if (image != null && !signature_is_ff(image, sgb))
      `uvm_error("RC_SGB_SIG", "RC SGB signature XOR is not 8'hff")

    // F2 RED/GREEN：inline_bytes 与通用 payload 都是 detached 输入时，codec 和
    // queue-data writer 必须共享同一份字节 authority；冲突不得由其中一路静默
    // 覆盖，恢复一致后则应继续生成同一份 512B SGB signature。
    // 功能：先注入首字节分叉验证拒绝，再恢复逐字节一致并验证 33-byte inline-SGB
    //       的 signature 覆盖 literal bytes 与零填充，而不是只读取 payload。
    // 输入/输出及副作用：authority_sqe、authority_image 和 authority_sgb 都是
    //       本地 fixture；encode 只发布 detached image，不写 Host-memory 或外部资源。
    // 失败/边界：双源非空且任一长度/byte 不一致时必须返回 INVALID_ARGUMENT 并把
    //       image 保持 null；恢复一致后编码失败或 signature 非 8'hff 均报告回归。
    begin
      rdma_hw_sqe_model authority_sqe;
      rdma_hw_image authority_image;
      rdma_status authority_status;
      byte unsigned authority_sgb[$];

      authority_sqe = make_rc_inline_request(33);
      authority_sqe.sgb_iova.value = 64'h4000;
      foreach (authority_sqe.inline_bytes[i])
        authority_sqe.payload.push_back(authority_sqe.inline_bytes[i]);
      authority_sqe.payload[0] = authority_sqe.payload[0] ^ 8'hff;
      authority_image = null;
      authority_status = encode_rc_sqe(authority_sqe, authority_image);
      if (authority_status == null || authority_status.ok() ||
          authority_image != null)
        `uvm_error("RC_INLINE_AUTHORITY_CONFLICT",
                   "conflicting inline_bytes/payload sources were accepted")

      authority_sqe.payload[0] = authority_sqe.inline_bytes[0];
      authority_status = encode_rc_sqe(authority_sqe, authority_image);
      authority_sgb.delete();
      for (int unsigned i = 0; i < 512; i++)
        authority_sgb.push_back(i < 33 ? i : 0);
      if (authority_status == null || !authority_status.ok() ||
          authority_image == null ||
          !signature_is_ff(authority_image, authority_sgb))
        `uvm_error("RC_INLINE_AUTHORITY_MATCH",
                   "matching inline sources did not produce shared SGB signature")
    end

    begin
      byte unsigned malformed_sgb[$];
      bit malformed_valid;
      malformed_sgb.push_back(8'h00);
      status = validate_sq_signature(image, malformed_sgb, malformed_valid);
      if (status == null || status.ok())
        `uvm_error("RC_SGB_SIZE", "non-512-byte SGB was accepted")
    end
    registry = rdma_codec_registry::type_id::create("sgb_decode_registry");
    status = rdma_register_queue_codecs(registry);
    status = registry.lookup(
      '{hw_version:"rdma", image_kind:RDMA_IMAGE_SQE,
        object_type:"sqe", variant:"rc", opcode:8'h00}, codec);
    model = null;
    status = codec.decode(image, model);
    if (status == null || !status.ok() || !$cast(decoded, model) ||
        decoded.payload_mode != RDMA_SQ_PAYLOAD_INLINE_SGB ||
        decoded.sgb_iova.value != sq.sgb_iova.value)
      `uvm_error("RC_SGB_DECODE", "RC inline-SGB decode lost SGB pointer or mode")

    // F2 RED/GREEN：驱动的单个 SQ-SGB backing slot 固定为 512B，最多容纳
    // 32 个 16-byte chunk。先用真实 512B/32-chunk image 锁定正向边界，再
    // 只改动 raw TPL=513 与 SGE_NUM=33，并重算外部 512B SGB 签名，使这个
    // fixture 只测试容量契约，而不会被 stale signature 或未对齐地址干扰。
    // 功能：验证 RC raw inline-SGB 的固定 slot 容量和 chunk 数上限，防止
    //       detached decode 把越界 payload 发布成可继续消费的模型。
    // 输入/输出及副作用：boundary_512/valid_boundary 是本地编码 fixture；
    //       malformed_capacity 是其 raw 副本，codec.validate_image/decode
    //       只读它们，成功边界应保持可验证，伪造边界不得发布 model。
    // 失败/边界：512B/32-chunk 若被拒绝说明合法驱动边界回归；513B/33-chunk
    //       若 validate 或 decode 返回 OK，说明 RC check_reserved 仍放宽容量，
    //       或 decode 在结构拒绝后错误保留了输出对象。
    begin
      rdma_hw_sqe_model boundary_512;
      rdma_hw_image valid_boundary;
      rdma_hw_image malformed_capacity;
      byte unsigned capacity_sgb[$];

      boundary_512 = make_rc_inline_request(512);
      boundary_512.sgb_iova.value = 64'h4000;
      status = encode_rc_sqe(boundary_512, valid_boundary);
      if (status == null || !status.ok() || valid_boundary == null ||
          valid_boundary.bytes[12] !== 8'h00 ||
          valid_boundary.bytes[13] !== 8'h00 ||
          valid_boundary.bytes[14] !== 8'h02 ||
          valid_boundary.bytes[15] !== 8'h00 ||
          valid_boundary.bytes[17] !== 8'd32)
        `uvm_error("RC_INLINE_SGB_512_BOUNDARY",
                   "512-byte/32-chunk RC inline-SGB boundary did not encode")
      else begin
        malformed_capacity = rdma_hw_image::type_id::create(
            "rc_inline_sgb_capacity_overflow");
        malformed_capacity.copy(valid_boundary);
        malformed_capacity.bytes[12] = 8'h00;
        malformed_capacity.bytes[13] = 8'h00;
        malformed_capacity.bytes[14] = 8'h02;
        malformed_capacity.bytes[15] = 8'h01;
        malformed_capacity.bytes[17] = 8'd33;
        for (int unsigned i = 0; i < 512; i++)
          capacity_sgb.push_back(i);
        malformed_capacity.bytes[16] = ~rdma_hw_sq_signature_xor(
            malformed_capacity, capacity_sgb);

        status = codec.validate_image(malformed_capacity);
        if (status == null || status.ok())
          `uvm_error("RC_INLINE_SGB_CAPACITY_VALIDATE",
                     "RC raw TPL=513/SGE_NUM=33 passed structural validation")
        model = null;
        status = codec.decode(malformed_capacity, model);
        if (status == null || status.ok() || model != null)
          `uvm_error("RC_INLINE_SGB_CAPACITY_DECODE",
                     "RC raw TPL=513/SGE_NUM=33 was published by decode")
      end
    end

    sq = rdma_hw_sqe_model::type_id::create("rc_direct");
    sq.transport = RDMA_TRANSPORT_RC;
    sq.qp_h = test_qp_handle();
    sq.opcode = RDMA_WR_SEND;
    sq.hw_opcode = RDMA_SQ_OPCODE_SEND;
    sq.qpn = 21'h12;
    sq.payload_mode = RDMA_SQ_PAYLOAD_SGE_WQE;
    sq.total_payload_len = 8;
    sq.sge_num = 1;
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

    // M-1 oracle：canonical 数值派生会排除 null，但 shape gate 必须独立
    // fail closed。fixture 同时保留一个 literal 有效 SGE，并把 sge_num 设为 1，
    // 确保拒绝原因不是 count mismatch。
    begin
      rdma_hw_sqe_model null_sge_model;
      rdma_sqe_rc_ext null_sge_ext;
      rdma_sge null_sge_valid;
      rdma_hw_image null_sge_image;

      null_sge_model = rdma_hw_sqe_model::type_id::create(
          "rc_null_sge_model");
      null_sge_model.transport = RDMA_TRANSPORT_RC;
      null_sge_model.qp_h = test_qp_handle();
      null_sge_model.opcode = RDMA_WR_SEND;
      null_sge_model.hw_opcode = RDMA_SQ_OPCODE_SEND;
      null_sge_model.qpn = 21'h12;
      null_sge_model.payload_mode = RDMA_SQ_PAYLOAD_SGE_WQE;
      null_sge_model.total_payload_len = 8;
      null_sge_model.sge_num = 1;
      null_sge_model.sges.push_back(null);
      null_sge_valid = rdma_sge::type_id::create("rc_null_sge_valid");
      null_sge_valid.length = 8;
      null_sge_valid.lkey = 32'h1234_5678;
      null_sge_valid.iova.value = 64'h2000;
      null_sge_model.sges.push_back(null_sge_valid);
      null_sge_ext = rdma_sqe_rc_ext::type_id::create("rc_null_sge_ext");
      null_sge_model.transport_ext = null_sge_ext;

      null_sge_image = rdma_hw_image::type_id::create(
          "rc_null_sge_rejected_sentinel");
      status = encode_rc_sqe(null_sge_model, null_sge_image);
      if (status == null || status.ok() || null_sge_image != null)
        `uvm_error("SQE_NULL_SGE_REJECT",
                   "RC writer accepted a null SGE or published an image")
    end

    // RED：wr.h 只定义 SGE length[30:0]；qword4 bit63 是 descriptor
    // length bit31 的 reserved 位。即使把签名按变异后的完整 WQE 重算，
    // raw validate/decode 仍必须拒绝该镜像，不能把 0x8000_0001 发布成模型。
    malformed_direct_length = rdma_hw_image::type_id::create(
        "rc_direct_reserved_length");
    malformed_direct_length.copy(image);
    malformed_direct_length.bytes[32] |= 8'h80;
    sgb.delete();
    malformed_direct_length.bytes[16] =
        ~rdma_hw_sq_signature_xor(malformed_direct_length, sgb);
    status = codec.validate_image(malformed_direct_length);
    if (status == null || status.ok())
      `uvm_error("RC_DIRECT_LENGTH_VALIDATE",
                 "direct-SGE length bit31 was accepted by raw validation")
    model = null;
    status = codec.decode(malformed_direct_length, model);
    if (status == null || status.ok() || model != null)
      `uvm_error("RC_DIRECT_LENGTH_DECODE",
                 "direct-SGE length bit31 was accepted by raw decode")

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

    // RED：驱动 wr.c 对 atomic local SGE 的 length 固定写 8。qword4
    // 的 [63:32] 是该 local length；raw 校验必须检查 wire 证据，而不能
    // 在 decode 时无条件制造 length=8 覆盖损坏字段。
    malformed_atomic_length = rdma_hw_image::type_id::create(
        "rc_atomic_invalid_local_length");
    malformed_atomic_length.copy(image);
    malformed_atomic_length.bytes[32] = 8'h00;
    malformed_atomic_length.bytes[33] = 8'h00;
    malformed_atomic_length.bytes[34] = 8'h00;
    malformed_atomic_length.bytes[35] = 8'h04;
    malformed_atomic_length.bytes[16] =
        ~rdma_hw_sq_signature_xor(malformed_atomic_length, sgb);
    status = codec.validate_image(malformed_atomic_length);
    if (status == null || status.ok())
      `uvm_error("RC_ATOMIC_LENGTH_VALIDATE",
                 "atomic local length other than eight was accepted")
    model = null;
    status = codec.decode(malformed_atomic_length, model);
    if (status == null || status.ok() || model != null)
      `uvm_error("RC_ATOMIC_LENGTH_DECODE",
                 "atomic local length other than eight was accepted")

    // Local invalidate carries its key through the RC transport extension;
    // the codec must project that detached semantic value into qword 1.
    sq = rdma_hw_sqe_model::type_id::create("rc_local_invalidate");
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

    // I-2 RED：合法 model gate 之后由 RC extension 投影 key/address，随后
    // body 因 local-invalidate 携带显式 inline mode 而拒绝。无论失败发生在哪个
    // body 分支，codec 都不得改写 caller model、extension 或嵌套输入身份。
    begin
      rdma_hw_sqe_model immutable_model;
      rdma_sqe_rc_ext immutable_ext;
      rdma_handle immutable_qp;
      rdma_hw_image immutable_image;

      immutable_model = rdma_hw_sqe_model::type_id::create(
          "rc_immutable_failure_model");
      immutable_qp = test_qp_handle();
      immutable_model.transport = RDMA_TRANSPORT_RC;
      immutable_model.qp_h = immutable_qp;
      immutable_model.opcode = RDMA_WR_LOCAL_INVALIDATE;
      immutable_model.hw_opcode = RDMA_SQ_OPCODE_LOCAL_INV;
      immutable_model.qpn = 21'h12;
      immutable_model.payload_mode = RDMA_SQ_PAYLOAD_INLINE_SGB;
      immutable_model.inline_bytes = new[1];
      immutable_model.inline_bytes[0] = 8'h5a;
      immutable_model.total_payload_len = 1;
      immutable_model.sge_num = 1;
      immutable_model.rkey = 32'h1111_2222;
      immutable_model.remote_va.value = 64'h2222_3333_4444_5555;
      immutable_model.invalidate_key = 32'h3333_4444;

      immutable_ext = rdma_sqe_rc_ext::type_id::create(
          "rc_immutable_failure_ext");
      immutable_ext.rkey_valid = 1'b1;
      immutable_ext.rkey = 32'hdead_beef;
      immutable_ext.remote_access_valid = 1'b1;
      immutable_ext.remote_addr.value = 64'h4000;
      immutable_model.transport_ext = immutable_ext;

      immutable_image = rdma_hw_image::type_id::create(
          "rc_immutable_failure_sentinel");
      status = encode_rc_sqe(immutable_model, immutable_image);
      if (status == null || status.ok() || immutable_image != null ||
          immutable_model.rkey != 32'h1111_2222 ||
          immutable_model.remote_va.value != 64'h2222_3333_4444_5555 ||
          immutable_model.invalidate_key != 32'h3333_4444 ||
          immutable_model.qp_h != immutable_qp ||
          immutable_model.transport_ext != immutable_ext ||
          immutable_ext.rkey != 32'hdead_beef ||
          !immutable_ext.rkey_valid ||
          immutable_ext.remote_addr.value != 64'h4000 ||
          !immutable_ext.remote_access_valid ||
          immutable_model.inline_bytes.size() != 1 ||
          immutable_model.inline_bytes[0] != 8'h5a ||
          immutable_model.payload.size() != 0 ||
          immutable_model.sges.size() != 0)
        `uvm_error("RC_ENCODE_INPUT_IMMUTABLE",
                   "failed RC encode modified caller-owned model state")
    end

    // SGB-backed direct SGEs contribute their serialized descriptors to the
    // signature, just like inline SGB payload bytes do.
    sq = rdma_hw_sqe_model::type_id::create("rc_sgb_sges");
    sq.transport = RDMA_TRANSPORT_RC;
    sq.qp_h = test_qp_handle();
    sq.opcode = RDMA_WR_SEND;
    sq.hw_opcode = RDMA_SQ_OPCODE_SEND;
    sq.payload_mode = RDMA_SQ_PAYLOAD_SGE_SGB;
    sq.sgb_iova.value = 64'h8000;
    sq.total_payload_len = 24;
    sq.sge_num = 3;
    for (int unsigned i = 0; i < 3; i++) begin
      rdma_sge sge;
      sge = rdma_sge::type_id::create($sformatf("sgb_sge%0d", i));
      sge.length = 8;
      sge.lkey = 32'h1000 + i;
      sge.iova.value = 64'h1000 + i * 8;
      sq.sges.push_back(sge);
    end
    status = encode_rc_sqe(sq, image);
    if (status == null || !status.ok() || image == null ||
        image.bytes[17] !== 8'd3)
      `uvm_error("RC_SGE_SGB", "RC SGE-SGB descriptor did not encode")
    // F2 RED：三个 literal nonzero descriptor 选择 external SGB，模型字段
    // 必须同样为 3；旧实现会忽略错误的 2 并把重新统计的 3 写上 wire。
    sq.sge_num = 8'd2;
    status = encode_rc_sqe(sq, image);
    if (status == null || status.ok() || image != null)
      `uvm_error("SQE_SGE_NUM_EXTERNAL_MISMATCH",
                 "external-SGB SQE accepted caller sge_num other than three")
    sq.sge_num = 8'd3;
    status = encode_rc_sqe(sq, image);
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

    // 驱动 wr.c 仅在 URC RDMA_READ 的 external-SGB WQE 写入 qword5[63:40]
    // TOTAL_PKT_NUM；RC external-SGB READ 的同一坐标必须保持 reserved。该
    // raw image 不依赖外部 descriptor authority，结构校验应直接拒绝非零位。
    begin
      rdma_hw_image malformed_rc_read_pkt_num;
      rdma_hw_sqe_model rc_read_sgb;
      rdma_sge read_sge;

      rc_read_sgb = rdma_hw_sqe_model::type_id::create("rc_read_sgb");
      rc_read_sgb.transport = RDMA_TRANSPORT_RC;
      rc_read_sgb.qp_h = test_qp_handle();
      rc_read_sgb.opcode = RDMA_WR_RDMA_READ;
      rc_read_sgb.hw_opcode = RDMA_SQ_OPCODE_READ;
      rc_read_sgb.payload_mode = RDMA_SQ_PAYLOAD_SGE_SGB;
      rc_read_sgb.sgb_iova.value = 64'h8000;
      rc_read_sgb.sge_num = 3;
      for (int unsigned i = 0; i < 3; i++) begin
        read_sge = rdma_sge::type_id::create($sformatf("rc_read_sgb_sge%0d", i));
        read_sge.length = 16;
        read_sge.lkey = 32'h1234 + i;
        read_sge.iova.value = 64'h2000 + i * 16;
        rc_read_sgb.sges.push_back(read_sge);
      end
      rc_read_sgb.total_payload_len = 48;
      status = encode_rc_sqe(rc_read_sgb, malformed_rc_read_pkt_num);
      if (status == null || !status.ok() || malformed_rc_read_pkt_num == null)
        `uvm_error("RC_READ_SGB_FIXTURE", "RC external-SGB READ fixture did not encode")
      else begin
        // qword5 starts at byte 40; bit 63 is byte 40 bit 7.
        malformed_rc_read_pkt_num.bytes[40] |= 8'h80;
        model = null;
        status = codec.decode(malformed_rc_read_pkt_num, model);
        if (status == null || status.ok() || model != null)
          `uvm_error("RC_READ_SGB_TOTAL_PKT_RESERVED",
                     "RC external-SGB READ accepted URC TOTAL_PKT_NUM bits")
      end
    end

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
    status = rdma_register_queue_codecs(registry);
    status = registry.lookup(
      '{hw_version:"rdma", image_kind:RDMA_IMAGE_SQE,
        object_type:"sqe", variant:"rc", opcode:8'h00}, codec);
    status = codec.decode(image, model);
    if (status == null || !status.ok() || !$cast(decoded, model))
      `uvm_error("RC_DECODE", "RC inline SQE did not decode")
    status = codec.encode(decoded, image2);
    if (status == null || !status.ok())
      `uvm_error("RC_REENCODE", $sformatf("decoded RC SQE did not re-encode: %s",
                 status == null ? "null" : status.convert2string()))

    // RED：wr.h opcode 3 是 SEND_WITH_INV，qword1[63:32] 同时承载
    // invalidate_rkey。RC raw decode 必须恢复这两个语义字段，不能落入
    // default SEND 分支后在 re-encode 时改变 ABI。
    begin
      rdma_hw_sqe_model send_inv;
      rdma_hw_sqe_model send_inv_decoded;
      rdma_hw_image send_inv_image;
      rdma_hw_image send_inv_image2;
      bit raw_same;

      send_inv = rdma_hw_sqe_model::type_id::create("rc_send_inv_roundtrip");
      send_inv.transport = RDMA_TRANSPORT_RC;
      send_inv.qp_h = test_qp_handle();
      send_inv.opcode = RDMA_WR_SEND_WITH_INV;
      send_inv.hw_opcode = RDMA_SQ_OPCODE_SEND_WITH_INV;
      send_inv.qpn = 21'h12;
      send_inv.valid = 1'b1;
      send_inv.sign_en = 1'b1;
      send_inv.payload_mode = RDMA_SQ_PAYLOAD_NONE;
      send_inv.invalidate_key = 32'hcafe_1357;
      status = encode_rc_sqe(send_inv, send_inv_image);
      if (status == null || !status.ok())
        `uvm_error("RC_SEND_INV_FIXTURE", "SEND_WITH_INV fixture did not encode")
      else begin
        model = null;
        status = codec.decode(send_inv_image, model);
        if (status == null || !status.ok() || !$cast(send_inv_decoded, model) ||
            send_inv_decoded.opcode != RDMA_WR_SEND_WITH_INV ||
            send_inv_decoded.invalidate_key != 32'hcafe_1357)
          `uvm_error("RC_SEND_INV_DECODE",
                     "SEND_WITH_INV decode lost opcode or invalidate key")
        else begin
          status = codec.encode(send_inv_decoded, send_inv_image2);
          raw_same = send_inv_image2 != null &&
                     send_inv_image2.bytes.size() == send_inv_image.bytes.size();
          if (raw_same)
            foreach (send_inv_image.bytes[i])
              raw_same = raw_same &&
                         send_inv_image2.bytes[i] == send_inv_image.bytes[i];
          if (status == null || !status.ok() || !raw_same)
            `uvm_error("RC_SEND_INV_REENCODE",
                       "SEND_WITH_INV decode/re-encode changed raw ABI")
        end
      end
    end

    // The queue-data engine supplies semantic opcode enum values.  The codec
    // must project those values onto the pinned XTR hardware opcode map.
    sq = make_rc_inline_request(1);
    sq.hw_opcode = RDMA_WR_SEND;
    status = encode_rc_sqe(sq, image);
    if (status == null || !status.ok() || image == null ||
        (image.bytes[3] & 8'h0f) != RDMA_SQ_OPCODE_SEND)
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

    // Ordinary RC SEND/WRITE operations may use the driver's zero-payload
    // shape (num_sge=0, length=0).  Direct SGE lengths must still agree with
    // the descriptor sum and obey the reserved bit rule.
    sq = make_rc_inline_request(1);
    sq.payload_mode = RDMA_SQ_PAYLOAD_NONE;
    sq.inline_data = 1'b0;
    sq.inline_bytes.delete();
    sq.total_payload_len = 0;
    sq.sge_num = 0;
    status = encode_rc_sqe(sq, image);
    if (status == null || !status.ok() || image == null ||
        image.bytes[17] !== 8'd0)
      `uvm_error("RC_EMPTY_SHAPE", $sformatf(
                 "empty ordinary RC payload was rejected: %s",
                 status == null ? "null" : status.convert2string()))
    // F2 RED：empty payload 的 hand-derived canonical count 是零。错误的
    // caller-visible count 1 不得被 wire-only recount 静默覆盖。
    sq.sge_num = 8'd1;
    status = encode_rc_sqe(sq, image);
    if (status == null || status.ok() || image != null)
      `uvm_error("SQE_SGE_NUM_EMPTY_MISMATCH",
                 "empty SQE accepted nonzero caller sge_num")
    sq.sge_num = 8'd0;

    // RED：wr.c 的普通 SEND 路径只填 qword0..2；qword3（offset 24）没有
    // 任何 SEND 字段，属于 reserved。RC reserved mask 不能因为 READ/WRITE
    // 复用同一个 qword3 而把普通 SEND 的 remote-VA 空间整字放开。
    begin
      rdma_hw_image malformed_remote_va;
      rdma_hw_image malformed_remote_key;
      byte unsigned no_sgb[$];

      sq = make_rc_inline_request(1);
      status = encode_rc_sqe(sq, image);
      if (status == null || !status.ok())
        `uvm_error("RC_RESERVED_QWORD3_FIXTURE",
                   "inline RC fixture did not encode")
      malformed_remote_va = rdma_hw_image::type_id::create(
          "rc_send_reserved_qword3");
      malformed_remote_va.copy(image);
      malformed_remote_va.bytes[24] = 8'h01;
      malformed_remote_va.bytes[16] =
          ~rdma_hw_sq_signature_xor(malformed_remote_va, no_sgb);
      model = null;
      status = codec.decode(malformed_remote_va, model);
      if (status == null || status.ok() || model != null)
        `uvm_error("RC_RESERVED_QWORD3",
                   "ordinary RC SEND accepted reserved qword3 bits")

      // xtrdma_set_rc_send_wqe() 对 qword2 的 REMOTE_KEY 也固定写零；只有
      // READ/WRITE/atomic 操作拥有该坐标。
      malformed_remote_key = rdma_hw_image::type_id::create(
          "rc_send_reserved_remote_key");
      malformed_remote_key.copy(image);
      malformed_remote_key.bytes[23] = 8'h01;
      malformed_remote_key.bytes[16] =
          ~rdma_hw_sq_signature_xor(malformed_remote_key, no_sgb);
      model = null;
      status = codec.decode(malformed_remote_key, model);
      if (status == null || status.ok() || model != null)
        `uvm_error("RC_RESERVED_REMOTE_KEY",
                   "ordinary RC SEND accepted reserved remote-key bits")
    end

    // RED：wr.c 只为 SEND_WITH_IMM、SEND_WITH_INV 和 WRITE_WITH_IMM 写入
    // qword1[63:32]。普通 SEND 的同一位域属于 reserved；重算签名后仍应由
    // opcode-specific reserved mask 拒绝，不能因为 qword1 其他 payload 字段
    // 合法就整字放行。
    begin
      rdma_hw_image malformed_immediate;
      byte unsigned no_sgb[$];

      malformed_immediate = rdma_hw_image::type_id::create(
        "rc_send_reserved_immediate");
      malformed_immediate.copy(image);
      malformed_immediate.bytes[8] = 8'hde;
      malformed_immediate.bytes[9] = 8'had;
      malformed_immediate.bytes[10] = 8'hbe;
      malformed_immediate.bytes[11] = 8'hef;
      malformed_immediate.bytes[16] =
        ~rdma_hw_sq_signature_xor(malformed_immediate, no_sgb);
      model = null;
      status = codec.decode(malformed_immediate, model);
      if (status == null || status.ok() || model != null)
        `uvm_error("RC_RESERVED_IMMEDIATE",
                   "ordinary RC SEND accepted a reserved immediate field")
    end

    // RED：wr.c 过滤零长度 SGE 后，把后续有效 descriptor 压紧到 slot 0；
    // 当前 codec 若直接遍历原始队列，会在 slot 0 拒绝空项或把有效 SGE
    // 留在 slot 1。该 fixture 锁定驱动的有效计数、TPL 和 descriptor 坐标。
    sq = rdma_hw_sqe_model::type_id::create("rc_mixed_zero_sge");
    sq.transport = RDMA_TRANSPORT_RC;
    sq.qp_h = test_qp_handle();
    sq.opcode = RDMA_WR_SEND;
    sq.hw_opcode = RDMA_SQ_OPCODE_SEND;
    sq.payload_mode = RDMA_SQ_PAYLOAD_NONE;
    sq.sge_num = 1;
    begin
      rdma_sge zero_sge;
      rdma_sge valid_sge;

      zero_sge = rdma_sge::type_id::create("rc_mixed_zero_sge_zero");
      zero_sge.length = 0;
      zero_sge.lkey = 32'hdead_beef;
      zero_sge.iova.value = 64'h1111_0000;
      sq.sges.push_back(zero_sge);

      valid_sge = rdma_sge::type_id::create("rc_mixed_zero_sge_valid");
      valid_sge.length = 8;
      valid_sge.lkey = 32'h1234_5678;
      valid_sge.iova.value = 64'h2222_0000;
      sq.sges.push_back(valid_sge);
    end
    status = encode_rc_sqe(sq, image);
    if (status == null || !status.ok())
      `uvm_error("RC_ZERO_SGE_FILTER",
                 $sformatf("mixed zero-length SGE was rejected: %s",
                           status == null ? "null" : status.convert2string()))
    else begin
      if (image.bytes[17] !== 8'd1)
        `uvm_error("RC_ZERO_SGE_COUNT",
                   "filtered direct SQE did not publish one literal descriptor")
      status = codec.decode(image, model);
      if (status == null || !status.ok() || !$cast(decoded, model) ||
          decoded.sges.size() != 1 || decoded.sges[0] == null ||
          decoded.sges[0].length != 8 ||
          decoded.sges[0].lkey != 32'h1234_5678 ||
          decoded.sges[0].iova.value != 64'h2222_0000)
        `uvm_error("RC_ZERO_SGE_COMPACT",
                   "valid RC SGE was not compacted to descriptor slot 0")
    end
    // F2 RED：队列包含一个 zero-length 和一个 8-byte literal descriptor，
    // 过滤后的 canonical count 是 1；声明 2 必须失败且 image 保持 null。
    sq.sge_num = 8'd2;
    status = encode_rc_sqe(sq, image);
    if (status == null || status.ok() || image != null)
      `uvm_error("SQE_SGE_NUM_DIRECT_FILTERED_MISMATCH",
                 "filtered direct SQE accepted unfiltered caller sge_num")
    sq.sge_num = 8'd1;

    // RED：驱动在新 SQ slot 上允许 IB_SEND_INLINE 且 payload_len=0；
    // 该镜像仍携带 INLINE_LOCAL_QPC_RD=1、TPL=0、SGE_NUM=0。codec 不应
    // 把“inline 模式但无有效字节”误判为 malformed payload。
    sq = make_rc_inline_request(0);
    sq.inline_data = 1'b1;
    status = encode_rc_sqe(sq, image);
    if (status == null || !status.ok())
      `uvm_error("RC_INLINE_ZERO_PAYLOAD",
                 $sformatf("zero-byte inline RC SEND was rejected: %s",
                           status == null ? "null" : status.convert2string()))
    else if ((image.bytes[0] & 8'h10) == 0)
      `uvm_error("RC_INLINE_ZERO_FLAG",
                 "zero-byte inline RC SEND did not set inline header flag")

    // I-3 RED：raw inline bit 对 zero-byte WQE 仍是 mode authority。decode 必须
    // 恢复 INLINE_WQE/inline_data，随后不借助任何生产 helper 逐字节重放 64B。
    begin
      rdma_hw_model zero_model;
      rdma_hw_sqe_model zero_decoded;
      rdma_hw_image zero_image2;
      bit zero_raw_same;

      zero_model = null;
      zero_decoded = null;
      status = codec.decode(image, zero_model);
      if (status == null || !status.ok() ||
          !$cast(zero_decoded, zero_model) || zero_decoded == null ||
          zero_decoded.payload_mode != RDMA_SQ_PAYLOAD_INLINE_WQE ||
          !zero_decoded.inline_data)
        `uvm_error("RC_INLINE_ZERO_DECODE_MODE",
                   "zero-byte inline decode lost raw inline authority")

      zero_image2 = null;
      if (zero_decoded != null)
        status = codec.encode(zero_decoded, zero_image2);
      else
        status = null;
      zero_raw_same = image != null && zero_image2 != null &&
                      image.bytes.size() == zero_image2.bytes.size();
      if (zero_raw_same) begin
        foreach (image.bytes[i])
          zero_raw_same = zero_raw_same &&
                          image.bytes[i] === zero_image2.bytes[i];
      end
      if (status == null || !status.ok() || !zero_raw_same)
        `uvm_error("RC_INLINE_ZERO_REENCODE",
                   "zero-byte inline decode/re-encode changed the 64B image")
    end

    sq = rdma_hw_sqe_model::type_id::create("rc_bad_sge_len");
    sq.transport = RDMA_TRANSPORT_RC;
    sq.qp_h = test_qp_handle();
    sq.opcode = RDMA_WR_SEND;
    sq.hw_opcode = RDMA_SQ_OPCODE_SEND;
    sq.payload_mode = RDMA_SQ_PAYLOAD_SGE_WQE;
    sq.total_payload_len = 7;
    sq.sge_num = 1;
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

    // F2 RED：atomic fixed body 始终只有一个 8-byte local descriptor；模型
    // 字段为零时旧实现仍会把常量 1 写上 wire，形成 model/wire 双事实源。
    sq = make_rc_atomic_request(RDMA_WR_ATOMIC_CMP_SWAP);
    status = encode_rc_sqe(sq, image);
    if (status == null || !status.ok() || image == null ||
        image.bytes[17] !== 8'd1)
      `uvm_error("RC_ATOMIC_COUNT", "atomic SQE did not publish count one")
    sq.sge_num = 8'd0;
    status = encode_rc_sqe(sq, image);
    if (status == null || status.ok() || image != null)
      `uvm_error("SQE_SGE_NUM_ATOMIC_MISMATCH",
                 "atomic SQE accepted caller sge_num other than one")

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
