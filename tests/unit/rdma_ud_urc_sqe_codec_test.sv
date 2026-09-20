// 目录：测试层 unit/rdma_ud_urc_sqe_codec_test.sv。
// 职责：验证 UD/URC SQE 编解码的 opcode、目的 QP/Q_Key、payload 和拒绝边界。
// 依赖：rdma_model_pkg、rdma_codec_pkg 与 UVM。
// 所有权与生命周期：测试只持有本地 fixture；外部 DMA/PCIe 资源由环境管理，
//   fixture 随 UVM test 生命周期释放。
// 功能：暴露 UD codec 的保留位校验入口，供本文件验证 opcode 相关的动态
//   掩码。
// 输入/输出及副作用：payload_qword 与 hw_opcode 为输入；在 detached builder
//   上执行只读校验，不写入外部内存。
// 失败/边界：builder 初始化或字段写入失败时原样返回错误；保留位非法时返回
//   CODEC_ERROR。
class rdma_ud_codec_probe extends rdma_hw_sqe_ud_codec;
  `uvm_object_utils(rdma_ud_codec_probe)

  // 功能：构造保留位探针对象。
  // 输入/输出及副作用：name 为输入；仅建立 UVM 对象，不绑定队列或 DMA
  //   资源。
  // 失败/边界：构造不执行硬件访问；后续 probe_payload 仍需使用合法 opcode。
  function new(string name = "rdma_ud_codec_probe");
    super.new(name);
  endfunction

  // 功能：把指定 qword1 与硬件 opcode 交给 UD 保留位检查器。
  // 输入/输出及副作用：payload_qword、hw_opcode 为输入；临时 builder 被初始化
  //   并读取，last_hw_opcode 被设置为探针值。
  // 失败/边界：非 64B builder 或字段写入失败立即返回；不修改请求模型或外部
  //   backing。
  function rdma_status probe_payload(
      bit [63:0] payload_qword,
      bit [3:0] hw_opcode);
    rdma_hw_qword_builder b;
    rdma_status s;

    b = new("ud_reserved_probe");
    s = b.reset(RDMA_WQE_BYTES);
    if (!s.ok())
      return s;

    s = b.put_field(0, 32, 4, hw_opcode);
    if (!s.ok())
      return s;

    s = b.put_field(0, 56, 1, 1'b1);
    if (!s.ok())
      return s;

    s = b.put_field(8, 0, 64, payload_qword);
    if (!s.ok())
      return s;

    last_hw_opcode = hw_opcode;
    return check_reserved(b);
  endfunction
endclass

// 功能：暴露 URC codec 的动态保留位检查入口，验证 external-SGB READ 的
//       qword5 只有 TOTAL_PKT_NUM 可由驱动写入。
// 输入/输出及副作用：builder、mode、hw_opcode 为输入；probe_reserved 只读取
//       builder 并临时设置 codec 的模式快照，不修改请求或外部 backing。
// 失败/边界：builder 不是完整 64B SQE、模式或 opcode 不匹配时返回 codec 错误；
//       不绕过正式 encode 流程，也不放宽未被驱动定义的位。
class rdma_urc_codec_probe extends rdma_hw_sqe_urc_codec;
  `uvm_object_utils(rdma_urc_codec_probe)

  // 功能：构造 URC 保留位探针对象。
  // 输入/输出及副作用：name 为输入；仅建立本地 UVM 对象，不绑定 QP 或 DMA。
  // 失败/边界：构造不访问硬件；后续 probe_reserved 仍需提供完整 builder。
  function new(string name = "rdma_urc_codec_probe");
    super.new(name);
  endfunction

  // 功能：按指定 payload mode/opcode 执行 URC SQE 保留位检查。
  // 输入/输出及副作用：builder 为输入；设置 last_mode/last_hw_opcode 后返回
  //       check_reserved 的状态，不发布 image 或改变外部资源。
  // 失败/边界：qword5 的 reserved bits 非零时必须返回 CODEC_ERROR；未知 mode
  //       由父级检查器拒绝，不能把测试探针变成第二套 ABI。
  function rdma_status probe_reserved(
      rdma_hw_qword_builder builder,
      rdma_sq_payload_mode_e mode,
      bit [3:0] hw_opcode);
    last_mode = mode;
    last_hw_opcode = hw_opcode;
    return check_reserved(builder);
  endfunction

  // 功能：probe_raw_reserved 在不写入 codec 历史状态的条件下，直接对
  //       builder 内的 raw opcode、payload mode 和 reserved bits 执行检查，
  //       模拟 fresh decode 或 codec reuse 后的结构校验入口。
  // 输入/输出及副作用：builder 为完整的 64B SQE 输入；函数只读取 builder，
  //       不修改 last_mode、last_hw_opcode、模型或外部 backing，并返回检查状态。
  // 失败/边界：builder 不是完整 SQE、raw 字段非法或 reserved 位非零时返回
  //       CODEC_ERROR；本探针不得通过预置 protected 状态掩盖 raw image 问题。
  function rdma_status probe_raw_reserved(rdma_hw_qword_builder builder);
    return check_reserved(builder);
  endfunction
endclass

class rdma_ud_urc_sqe_codec_test extends uvm_test;
  `uvm_component_utils(rdma_ud_urc_sqe_codec_test)
  // 功能：构造 focused UD/URC SQE、URC READ packet count 与跨 transport RQE 测试组件。
  // 输入/输出及副作用：name、parent 为输入；只建立 UVM 层级节点，不创建
  //   queue backing、DMA mapping 或运行时 QP。
  // 失败/边界：构造不执行 codec 操作；factory 依赖或 fixture 缺失由 run_phase
  //   的具体 contract ID 报告，不在构造阶段伪造成功状态。
  function new(
      string name = "rdma_ud_urc_sqe_codec_test",
      uvm_component parent = null);
    super.new(name, parent);
  endfunction

  // 功能：qp_handle 创建固定 Function incarnation 的 QP handle，供 UD/URC/RC
  //   direct-model 与 facade fixture 共享同一 literal authority。
  // 输入/输出及副作用：无参数；返回测试拥有的新句柄，写入 kind、object_id、
  //   function_uid 与 generation，不登记 resource manager。
  // 失败/边界：factory 返回 null 时直接返回 null，随后 codec/request validation
  //   必须拒绝；该 handle 仅用于纯 codec，不代表已 attach 的 queue runtime。
  function automatic rdma_handle qp_handle();
    rdma_handle h;

    h = rdma_handle::type_id::create("qp");
    if (h == null)
      return null;
    h.kind = RDMA_RESOURCE_QP;
    h.object_id = 1;
    h.function_uid = 64'h1122;
    h.generation = 1;
    return h;
  endfunction

  // 功能：run_phase 覆盖 UD SEND/SEND_WITH_INV 的 raw authority、显式 inline
  //   bytes、512B SGB 容量、SGE 过滤与 mismatch gate，并验证 URC external READ
  //   packet count、fresh raw reserved mask 及 RQE external-SGB 坐标。
  // 输入/输出及副作用：phase 为 UVM 阶段输入；task 管理 objection、创建本地
  //   model/image/builder 并发布 contract ID，不写真实 Host-memory 或 PCIe。
  // 失败/边界：任一 encode/decode、literal raw field、signature、capacity、opcode
  //   或 reserved-mask 契约不符时报告 UVM_ERROR；所有路径最终释放 objection。
  task run_phase(uvm_phase phase);
    rdma_post_send_req req;
    byte unsigned image[];
    rdma_status s;
    rdma_ud_codec_probe probe;
    rdma_hw_qword_builder sq_builder;
    bit [63:0] sq_field;
    rdma_hw_rqe_codec rqe_codec;
    rdma_hw_rqe_model rqe_model;
    rdma_hw_image rqe_image;
    rdma_hw_qword_builder rqe_builder;
    byte unsigned rqe_bytes[];
    byte unsigned rqe_descriptor_bytes[$];
    rdma_hw_model decoded_model;
    phase.raise_objection(this);

    probe = rdma_ud_codec_probe::type_id::create("ud_reserved_probe");
    s = probe.probe_payload(
        64'h0000_0001_0000_0000, RDMA_SQ_OPCODE_SEND);
    if (s == null || s.ok())
      `uvm_error("UD_RESERVED",
                 "UD SEND accepted qword1 immediate/reserved high bits")

    s = probe.probe_payload(
        64'h0000_0001_0000_0000, RDMA_SQ_OPCODE_SEND_WITH_IMM);
    if (s == null || !s.ok())
      `uvm_error("UD_IMM",
                 "UD SEND_WITH_IMM rejected valid immediate field")

    s = probe.probe_payload(
        64'h0000_0000_0200_0000, RDMA_SQ_OPCODE_SEND_WITH_IMM);
    if (s == null || s.ok())
      `uvm_error("UD_RESERVED", "UD accepted qword1 reserved bit25")

    req = rdma_post_send_req::type_id::create("ud_send_inv");
    req.qp_h = qp_handle();
    req.transport = RDMA_TRANSPORT_UD;
    req.opcode = RDMA_WR_SEND_WITH_INV;
    req.destination_qpn = 24'h12345;
    req.qkey = 32'h1111_2222;
    req.invalidate_rkey = 32'hdead_beef;
    req.address_vector_valid = 1'b1;
    req.address_vector = rdma_address_vector::type_id::create("av");

    // 驱动对 UD 非空 payload 始终使用每个 SQ slot 对应的 512B SGB，不能把数据内联到
    // 与 AH 元数据重叠的 WQE 字节区；这里故意提供非零、512B 对齐的 SGB IOVA。
    req.sgb_iova.value = 64'h2000;
    req.inline_data = 1'b1;
    req.payload.push_back(8'h5a);
    s = rdma_queue_codec::encode_sqe(req, image);
    if (s == null || !s.ok() || image.size() != RDMA_WQE_BYTES) begin
      `uvm_error("SQE_RED",
                 $sformatf("UD SEND_WITH_INV codec did not encode: %s",
                           s == null ? "null status" : s.message))
    end

    if (image.size() > 3 && image[3] != RDMA_SQ_OPCODE_SEND_WITH_INV)
      `uvm_error("SQE_OPCODE", "UD opcode mismatch")
    if (image.size() < 12 ||
        {image[8], image[9], image[10], image[11]} != req.invalidate_rkey)
      `uvm_error("SQE_IETH", "invalidate_rkey was not encoded")

    // 目的 QPN 位于 offset=40 qword 的 bits[55:32]，大端序列化后落在 41..43 字节。
    if (image.size() < 44 ||
        {image[41], image[42], image[43]} != req.destination_qpn[23:0])
      `uvm_error("SQE_DQPN", "destination QPN was not encoded")
    if (image.size() < 40 ||
        image[32] == 0 && image[33] == 0 && image[34] == 0 &&
        image[35] == 0 && image[36] == 0 && image[37] == 0 &&
        image[38] == 0 && image[39] == 0)
      `uvm_error("SQE_SGB", "UD payload did not select SGB")

    // RED：53 上的 0.1.34 内核驱动在 wr.c:735 对
    // XTRDMA_SQ_WQE_UD_TUNNEL 固定写 0；模型若接受 AV.tunnel_enable=1，
    // 就会生成内核路径永远不会产生的 wire image。codec 必须先拒绝该请求。
    req.address_vector.tunnel_enable = 1'b1;
    s = rdma_queue_codec::encode_sqe(req, image);
    if (s == null || s.code != RDMA_SC_UNSUPPORTED_OPCODE)
      `uvm_error("UD_TUNNEL_ABI",
                 $sformatf("UD tunnel_enable was not rejected: %s",
                           s == null ? "null status" : s.message))
    req.address_vector.tunnel_enable = 1'b0;
    s = rdma_queue_codec::encode_sqe(req, image);
    if (s == null || !s.ok() || image.size() != RDMA_WQE_BYTES)
      `uvm_error("UD_TUNNEL_RECOVERY",
                 $sformatf("UD baseline image was not restored: %s",
                           s == null ? "null status" : s.message))

    // 驱动即使把非零 inline payload 放入外部 SGB，也会在 SQ header
    // 设置 INLINE_LOCAL_QPC_RD；该位描述 inline 语义，不是 WQE 内存位置。
    sq_builder = new("ud_inline_sgb_header_builder");
    s = sq_builder.deserialize(image);
    if (s == null || !s.ok())
      `uvm_error("UD_INLINE_SGB_HEADER", "UD inline-SGB image was not readable")
    else begin
      s = sq_builder.get_field(0, 60, 1, sq_field);
      if (s == null || !s.ok() || sq_field != 1'b1)
        `uvm_error("UD_INLINE_SGB_FLAG",
                   "UD nonzero inline payload did not set INLINE_LOCAL_QPC_RD")
    end

    // I-1 RED：hardware-model authoring 的显式 inline mode、inline_bytes、TPL、
    // count 与 signature 必须共享一个 authority。inline_data 故意为零，确保
    // UD writer 不能退回旧的 payload/flag 私有公式。
    begin
      rdma_hw_sqe_model inline_authority_model;
      rdma_sqe_ud_ext inline_authority_ext;
      rdma_hw_sqe_ud_codec inline_authority_codec;
      rdma_hw_image inline_authority_image;
      rdma_hw_qword_builder inline_authority_builder;
      byte unsigned expected_sgb[$];
      bit signature_valid;
      bit fields_valid;
      bit [63:0] inline_field;
      bit [63:0] length_field;
      bit [63:0] count_field;
      rdma_status signature_status;

      inline_authority_model = rdma_hw_sqe_model::type_id::create(
          "ud_inline_authority_model");
      inline_authority_model.transport = RDMA_TRANSPORT_UD;
      inline_authority_model.opcode = RDMA_WR_SEND;
      inline_authority_model.qp_h = qp_handle();
      inline_authority_model.qpn = 21'h1;
      inline_authority_model.valid = 1'b1;
      inline_authority_model.sign_en = 1'b1;
      inline_authority_model.payload_mode = RDMA_SQ_PAYLOAD_INLINE_SGB;
      inline_authority_model.inline_data = 1'b0;
      inline_authority_model.inline_bytes = new[33];
      foreach (inline_authority_model.inline_bytes[i])
        inline_authority_model.inline_bytes[i] = 8'ha0 + i;
      inline_authority_model.total_payload_len = 33;
      inline_authority_model.sge_num = 3;
      inline_authority_model.sgb_iova.value = 64'h2000;

      inline_authority_ext = rdma_sqe_ud_ext::type_id::create(
          "ud_inline_authority_ext");
      inline_authority_ext.destination_qpn = 24'h55;
      inline_authority_ext.qkey = 32'h1111_2222;
      inline_authority_ext.address_vector_valid = 1'b1;
      inline_authority_ext.address_vector =
          rdma_address_vector::type_id::create("ud_inline_authority_av");
      inline_authority_model.transport_ext = inline_authority_ext;
      inline_authority_codec = rdma_hw_sqe_ud_codec::type_id::create(
          "ud_inline_authority_codec");

      s = inline_authority_codec.encode(
          inline_authority_model, inline_authority_image);
      fields_valid = s != null && s.ok() &&
                     inline_authority_image != null;
      if (fields_valid) begin
        inline_authority_builder = new("ud_inline_authority_builder");
        s = inline_authority_builder.deserialize(
            inline_authority_image.bytes);
        fields_valid = s != null && s.ok();
      end
      if (fields_valid) begin
        s = inline_authority_builder.get_field(
            RDMA_SQ_WQE_INLINE_LOCAL_QPC_RD_WORD_BYTE_OFFSET,
            RDMA_SQ_WQE_INLINE_LOCAL_QPC_RD_LSB,
            RDMA_SQ_WQE_INLINE_LOCAL_QPC_RD_WIDTH,
            inline_field);
        fields_valid = s != null && s.ok();
      end
      if (fields_valid) begin
        s = inline_authority_builder.get_field(
            RDMA_SQ_WQE_UD_TOTAL_PAYLOAD_LEN_WORD_BYTE_OFFSET,
            RDMA_SQ_WQE_UD_TOTAL_PAYLOAD_LEN_LSB,
            RDMA_SQ_WQE_UD_TOTAL_PAYLOAD_LEN_WIDTH,
            length_field);
        fields_valid = s != null && s.ok();
      end
      if (fields_valid) begin
        s = inline_authority_builder.get_field(
            RDMA_SQ_WQE_UD_SGE_NUM_WORD_BYTE_OFFSET,
            RDMA_SQ_WQE_UD_SGE_NUM_LSB,
            RDMA_SQ_WQE_UD_SGE_NUM_WIDTH,
            count_field);
        fields_valid = s != null && s.ok();
      end
      if (!fields_valid || inline_field !== 64'd1 ||
          length_field !== 64'd33 || count_field !== 64'd3)
        `uvm_error("UD_INLINE_MODE_AUTHORITY",
                   "explicit inline_bytes did not drive INLINE=1/TPL=33/count=3")

      expected_sgb.delete();
      for (int unsigned i = 0; i < 512; i++)
        expected_sgb.push_back(i < 33 ? 8'ha0 + i : 8'h00);
      signature_status = validate_sq_signature(
          inline_authority_image, expected_sgb, signature_valid);
      if (signature_status == null || !signature_status.ok() ||
          !signature_valid)
        `uvm_error("UD_INLINE_BYTES_AUTHORITY",
                   "UD signature did not cover 33 literal inline bytes plus zero pad")

      // 同一合法 UD SEND 若显式声明 atomic payload mode，必须在 image 发布前
      // fail closed；当前 writer 会把它误写为空 body + count one。
      inline_authority_model.payload_mode = RDMA_SQ_PAYLOAD_ATOMIC_FIXED;
      inline_authority_model.inline_bytes.delete();
      inline_authority_model.total_payload_len = 0;
      inline_authority_model.sge_num = 1;
      inline_authority_image = rdma_hw_image::type_id::create(
          "ud_atomic_mode_rejected_sentinel");
      s = inline_authority_codec.encode(
          inline_authority_model, inline_authority_image);
      if (s == null || s.ok() || inline_authority_image != null)
        `uvm_error("UD_PAYLOAD_MODE_OPCODE_MISMATCH",
                   "UD SEND accepted ATOMIC_FIXED payload mode")
    end

    // RED：wr.c 过滤零长度 SGE，并把有效 descriptor 数写入 UD SGE_NUM；
    // 外部 SGB 中的 descriptor 同样按有效项压紧。request facade、UD codec
    // 和 header count 必须共同反映这一真实驱动语义。
    req.opcode = RDMA_WR_SEND;
    req.invalidate_rkey = '0;
    req.inline_data = 1'b0;
    req.payload.delete();
    req.sges.delete();
    req.sgb_iova.value = 64'h2000;
    begin
      rdma_sge zero_sge;
      rdma_sge valid_sge;

      zero_sge = rdma_sge::type_id::create("ud_mixed_zero_sge_zero");
      zero_sge.length = 0;
      zero_sge.lkey = 32'hdead_beef;
      zero_sge.iova.value = 64'h1111_0000;
      req.sges.push_back(zero_sge);

      valid_sge = rdma_sge::type_id::create("ud_mixed_zero_sge_valid");
      valid_sge.length = 8;
      valid_sge.lkey = 32'h1234_5678;
      valid_sge.iova.value = 64'h2222_0000;
      req.sges.push_back(valid_sge);
    end
    s = rdma_queue_codec::encode_sqe(req, image);
    if (s == null || !s.ok())
      `uvm_error("UD_ZERO_SGE_FILTER",
                 $sformatf("mixed zero-length UD SGE was rejected: %s",
                           s == null ? "null" : s.message))
    else begin
      sq_builder = new("ud_mixed_zero_sge_builder");
      s = sq_builder.deserialize(image);
      if (s == null || !s.ok())
        `uvm_error("UD_ZERO_SGE_IMAGE", "UD mixed SGE image was not readable")
      else begin
        s = sq_builder.get_field(16, 48, 8, sq_field);
        if (s == null || !s.ok() || sq_field != 8'd1)
          `uvm_error("UD_ZERO_SGE_COUNT",
                     "UD SGE_NUM did not equal the one valid SGE")
        s = sq_builder.get_field(8, 0, 14, sq_field);
        if (s == null || !s.ok() || sq_field != 14'd8)
          `uvm_error("UD_ZERO_SGE_LENGTH",
                     "UD total payload length did not equal the valid SGE")
      end
    end

    // F2 transport gate：UD direct fixture 只有一个 8-byte literal SGE，
    // caller-visible count=0 必须在 writer 写字段前失败并保持 image=null；
    // 恢复 canonical 1 后同一模型应编码并在 byte17 发布 literal 1。
    begin
      rdma_hw_sqe_model ud_count_model;
      rdma_sqe_ud_ext ud_count_ext;
      rdma_hw_sqe_ud_codec ud_count_codec;
      rdma_hw_image ud_count_image;
      rdma_sge ud_count_sge;

      ud_count_model = rdma_hw_sqe_model::type_id::create(
          "ud_count_model");
      ud_count_model.transport = RDMA_TRANSPORT_UD;
      ud_count_model.opcode = RDMA_WR_SEND;
      ud_count_model.qp_h = qp_handle();
      ud_count_model.qpn = 21'h1;
      ud_count_model.valid = 1'b1;
      ud_count_model.sign_en = 1'b1;
      ud_count_model.sgb_iova.value = 64'h2000;
      ud_count_sge = rdma_sge::type_id::create("ud_count_sge");
      ud_count_sge.length = 8;
      ud_count_sge.lkey = 32'h1234_5678;
      ud_count_sge.iova.value = 64'h4000;
      ud_count_model.sges.push_back(ud_count_sge);

      ud_count_ext = rdma_sqe_ud_ext::type_id::create("ud_count_ext");
      ud_count_ext.destination_qpn = 24'h55;
      ud_count_ext.qkey = 32'h1111_2222;
      ud_count_ext.address_vector_valid = 1'b1;
      ud_count_ext.address_vector = rdma_address_vector::type_id::create(
          "ud_count_av");
      ud_count_model.transport_ext = ud_count_ext;
      ud_count_codec = rdma_hw_sqe_ud_codec::type_id::create(
          "ud_count_codec");

      ud_count_model.sge_num = 8'd0;
      ud_count_image = rdma_hw_image::type_id::create(
          "ud_count_rejected_sentinel");
      s = ud_count_codec.encode(ud_count_model, ud_count_image);
      if (s == null || s.ok() || ud_count_image != null)
        `uvm_error("UD_SGE_NUM_DIRECT_MISMATCH",
                   "UD direct writer accepted count zero for one SGE")

      ud_count_model.sge_num = 8'd1;
      s = ud_count_codec.encode(ud_count_model, ud_count_image);
      if (s == null || !s.ok() || ud_count_image == null ||
          ud_count_image.bytes[17] !== 8'd1)
        `uvm_error("UD_SGE_NUM_DIRECT_POSITIVE",
                   "UD direct writer did not publish literal count one")
    end

    // RED：53 驱动的 max_send_sge/XTRDMA_MAX_SGE_NUM 上限为 32；外部
    // SQ-SGB 每个 descriptor 占 16B，33 个有效 SGE 会超过固定 512B 槽位。
    // codec 必须在写入 image 或签名之前 fail closed，不能仅依赖 8-bit 字段宽度。
    req.sges.delete();
    req.inline_data = 1'b0;
    req.payload.delete();
    req.sgb_iova.value = 64'h2000;
    for (int unsigned i = 0; i < 33; i++) begin
      rdma_sge too_many_sge;
      too_many_sge = rdma_sge::type_id::create($sformatf("ud_sge_%0d", i));
      too_many_sge.length = 1;
      too_many_sge.lkey = i;
      too_many_sge.iova.value = 64'h1000 + i;
      req.sges.push_back(too_many_sge);
    end
    // Bypass request.validate() so this guard proves the UD codec itself
    // rejects an over-capacity external SGB before descriptor serialization.
    begin
      rdma_hw_sqe_model too_many_model;
      rdma_sqe_ud_ext too_many_ext;
      rdma_hw_sqe_ud_codec too_many_codec;
      rdma_hw_image too_many_image;

      too_many_model = rdma_hw_sqe_model::type_id::create("ud_too_many_model");
      too_many_model.transport = RDMA_TRANSPORT_UD;
      too_many_model.opcode = RDMA_WR_SEND;
      too_many_model.qp_h = qp_handle();
      too_many_model.qpn = 21'h1;
      too_many_model.valid = 1'b1;
      too_many_model.sign_en = 1'b1;
      too_many_model.inline_data = 1'b0;
      too_many_model.sgb_iova.value = 64'h2000;
      too_many_model.sge_num = 8'd33;
      too_many_ext = rdma_sqe_ud_ext::type_id::create("ud_too_many_ext");
      too_many_ext.destination_qpn = 24'h77;
      too_many_ext.qkey = 32'h3333_4444;
      too_many_ext.address_vector_valid = 1'b1;
      too_many_ext.address_vector = rdma_address_vector::type_id::create(
          "ud_too_many_av");
      too_many_model.transport_ext = too_many_ext;
      foreach (req.sges[i])
        too_many_model.sges.push_back(req.sges[i]);
      too_many_codec = rdma_hw_sqe_ud_codec::type_id::create(
          "ud_too_many_codec");
      s = too_many_codec.encode(too_many_model, too_many_image);
    end
    if (s == null || s.ok())
      `uvm_error("UD_SGE_COUNT_LIMIT",
                 "UD external SGB accepted more than 32 valid SGEs")

    // RED：驱动在 IB_SEND_INLINE 且有效 payload_len=0 时仍发布一个合法
    // inline header（INLINE_LOCAL_QPC_RD=1、TPL=0、SGE_NUM=0）。模型不能
    // 因 payload 数组为空而拒绝该请求或清掉驱动实际写入的 inline flag。
    req.sges.delete();
    req.inline_data = 1'b1;
    req.payload.delete();
    req.sgb_iova.value = '0;
    s = rdma_queue_codec::encode_sqe(req, image);
    if (s == null || !s.ok())
      `uvm_error("UD_INLINE_ZERO_PAYLOAD",
                 $sformatf("zero-byte inline UD SEND was rejected: %s",
                           s == null ? "null" : s.message))
    else begin
      sq_builder = new("ud_inline_zero_builder");
      s = sq_builder.deserialize(image);
      if (s == null || !s.ok())
        `uvm_error("UD_INLINE_ZERO_IMAGE",
                   "zero-byte inline UD image was not readable")
      else begin
        s = sq_builder.get_field(0, 60, 1, sq_field);
        if (s == null || !s.ok() || sq_field != 1'b1)
          `uvm_error("UD_INLINE_ZERO_FLAG",
                     "zero-byte inline UD SEND did not set inline header flag")
        s = sq_builder.get_field(16, 48, 8, sq_field);
        if (s == null || !s.ok() || sq_field != 8'd0)
          `uvm_error("UD_INLINE_ZERO_COUNT",
                     "zero-byte inline UD SEND did not clear SGE_NUM")
      end
    end

    // Alignment is required only once the inline payload has a nonzero
    // length and therefore needs an external SGB.  Restore a one-byte inline
    // payload before exercising the unaligned-address rejection.
    req.payload.push_back(8'h5a);
    req.sgb_iova.value = 64'h2100;
    s = rdma_queue_codec::encode_sqe(req, image);
    if (s == null || s.ok())
      `uvm_error("SQE_ALIGN","UD accepted an unaligned SGB IOVA")

    // I-4 RED：固定 SQ-SGB 只有 512B。正边界必须按 literal TPL=512、
    // count=32、INLINE=1 发布；追加第 513 byte 后 facade 必须参数拒绝并清空 image。
    begin
      rdma_post_send_req capacity_request;
      rdma_hw_qword_builder capacity_builder;
      byte unsigned capacity_image[];
      bit boundary_valid;
      bit [63:0] capacity_inline;
      bit [63:0] capacity_length;
      bit [63:0] capacity_count;

      capacity_request = rdma_post_send_req::type_id::create(
          "ud_inline_capacity_request");
      capacity_request.qp_h = qp_handle();
      capacity_request.transport = RDMA_TRANSPORT_UD;
      capacity_request.opcode = RDMA_WR_SEND;
      capacity_request.inline_data = 1'b1;
      capacity_request.destination_qpn = 24'h123;
      capacity_request.qkey = 32'h8001_0000;
      capacity_request.address_vector_valid = 1'b1;
      capacity_request.address_vector = rdma_address_vector::type_id::create(
          "ud_inline_capacity_av");
      capacity_request.sgb_iova.value = 64'h2000;
      for (int unsigned i = 0; i < 512; i++)
        capacity_request.payload.push_back(i[7:0]);

      s = rdma_queue_codec::encode_sqe(
          capacity_request, capacity_image);
      boundary_valid = s != null && s.ok() &&
                       capacity_image.size() == RDMA_WQE_BYTES;
      if (boundary_valid) begin
        capacity_builder = new("ud_inline_capacity_builder");
        s = capacity_builder.deserialize(capacity_image);
        boundary_valid = s != null && s.ok();
      end
      if (boundary_valid) begin
        s = capacity_builder.get_field(
            RDMA_SQ_WQE_INLINE_LOCAL_QPC_RD_WORD_BYTE_OFFSET,
            RDMA_SQ_WQE_INLINE_LOCAL_QPC_RD_LSB,
            RDMA_SQ_WQE_INLINE_LOCAL_QPC_RD_WIDTH,
            capacity_inline);
        boundary_valid = s != null && s.ok();
      end
      if (boundary_valid) begin
        s = capacity_builder.get_field(
            RDMA_SQ_WQE_UD_TOTAL_PAYLOAD_LEN_WORD_BYTE_OFFSET,
            RDMA_SQ_WQE_UD_TOTAL_PAYLOAD_LEN_LSB,
            RDMA_SQ_WQE_UD_TOTAL_PAYLOAD_LEN_WIDTH,
            capacity_length);
        boundary_valid = s != null && s.ok();
      end
      if (boundary_valid) begin
        s = capacity_builder.get_field(
            RDMA_SQ_WQE_UD_SGE_NUM_WORD_BYTE_OFFSET,
            RDMA_SQ_WQE_UD_SGE_NUM_LSB,
            RDMA_SQ_WQE_UD_SGE_NUM_WIDTH,
            capacity_count);
        boundary_valid = s != null && s.ok();
      end
      if (!boundary_valid || capacity_inline !== 64'd1 ||
          capacity_length !== 64'd512 || capacity_count !== 64'd32)
        `uvm_error("UD_INLINE_SGB_512_BOUNDARY",
                   "512-byte UD inline boundary did not publish literal fields")

      capacity_request.payload.push_back(8'hff);
      s = rdma_queue_codec::encode_sqe(
          capacity_request, capacity_image);
      if (s == null || s.code != RDMA_SC_INVALID_ARGUMENT ||
          capacity_image.size() != 0)
        `uvm_error("UD_INLINE_SGB_CAPACITY",
                   "513-byte UD inline request was not rejected before image publication")
    end

    req.sgb_iova.value = 64'h2000;
    req.payload.delete();
    for (int unsigned i = 0; i < 16384; i++)
      req.payload.push_back(8'h00);
    s = rdma_queue_codec::encode_sqe(req, image);
    if (s == null || s.ok())
      `uvm_error("SQE_LEN","UD accepted payload beyond the 14-bit length field")

    // RED：真实 wr.c 将 RC SEND_WITH_INV 的 invalidate_rkey 写入 qword1[63:32]，
    // 与 SEND_WITH_IMM 共用 immediate 字段；该独立 raw-word 断言使用固定字面量，
    // 防止 codec 通过自洽读取掩盖字段遗漏。
    begin
      rdma_post_send_req rc_send_inv;
      byte unsigned rc_image[];
      bit [31:0] expected_invalidate_rkey;

      rc_send_inv = rdma_post_send_req::type_id::create("rc_send_inv_raw_word");
      rc_send_inv.qp_h = qp_handle();
      rc_send_inv.transport = RDMA_TRANSPORT_RC;
      rc_send_inv.opcode = RDMA_WR_SEND_WITH_INV;
      rc_send_inv.invalidate_rkey = 32'hcafe_1357;
      expected_invalidate_rkey = 32'hcafe_1357;
      s = rdma_queue_codec::encode_sqe(rc_send_inv, rc_image);
      if (s == null || !s.ok())
        `uvm_error("RC_SEND_INV_ENCODE",
                   $sformatf("RC SEND_WITH_INV codec rejected request: %s",
                             s == null ? "null status" : s.message))
      else if (rc_image.size() < 12 ||
               {rc_image[8], rc_image[9], rc_image[10], rc_image[11]} !=
               expected_invalidate_rkey)
        `uvm_error("RC_SEND_INV_RAW_WORD",
                   $sformatf("qword1[63:32] expected %08h, got %02h%02h%02h%02h",
                             expected_invalidate_rkey,
                             rc_image.size() > 8 ? rc_image[8] : 0,
                             rc_image.size() > 9 ? rc_image[9] : 0,
                             rc_image.size() > 10 ? rc_image[10] : 0,
                             rc_image.size() > 11 ? rc_image[11] : 0))
    end

    req = rdma_post_send_req::type_id::create("urc_send");
    req.qp_h = qp_handle();
    req.transport = RDMA_TRANSPORT_URC;
    req.opcode = RDMA_WR_SEND;
    req.destination_qpn = 24'h55;
    req.completion_qp_h = qp_handle();
    req.inline_data = 1'b0;
    begin
      rdma_sge sg;

      sg = rdma_sge::type_id::create("urc_sge");
      sg.length = 16;
      sg.lkey = 32'h1234;
      sg.iova.value = 64'h4000;
      req.sges.push_back(sg);
    end
    s = rdma_queue_codec::encode_sqe(req, image);
    if (s == null || !s.ok())
      `uvm_error("URC_ENCODE",
                 $sformatf("URC SEND codec did not encode: %s",
                           s == null ? "null status" : s.message))

    // RED：wr.c 只在 URC RDMA_READ 走 external SGB 时写入 qword5[63:40]。
    // 三个 SGE 按 PMTU=1024 切分后应得到 1+2+3 个 packet；旧 codec 没有
    // 这个 driver-owned 字段，因此该断言在修复前必须失败。
    begin
      rdma_hw_sqe_urc_codec urc_codec;
      rdma_hw_sqe_model urc_read;
      rdma_sqe_urc_ext urc_ext;
      rdma_hw_image urc_image;
      rdma_hw_qword_builder urc_builder;
      bit [63:0] total_packet_num;
      rdma_sge read_sge;
      byte unsigned urc_bytes[];
      int unsigned read_lengths[3];
      rdma_urc_codec_probe urc_probe;

      read_lengths[0] = 1024;
      read_lengths[1] = 2048;
      read_lengths[2] = 3072;

      urc_codec = rdma_hw_sqe_urc_codec::type_id::create("urc_read_codec");
      urc_read = rdma_hw_sqe_model::type_id::create("urc_read_model");
      urc_read.transport = RDMA_TRANSPORT_URC;
      urc_read.opcode = RDMA_WR_RDMA_READ;
      urc_read.qp_h = qp_handle();
      urc_read.qpn = 24'h21;
      urc_read.valid = 1'b1;
      urc_read.sign_en = 1'b1;
      urc_read.payload_mode = RDMA_SQ_PAYLOAD_SGE_SGB;
      urc_read.sge_num = 8'd3;
      // PMTU 必须来自已编程 QPC 的冻结 authority；测试用 1024 代表驱动
      // qp.h/wr.c 支持的最小合法值，不能让 codec 猜默认 MTU。
      urc_read.path_mtu_bytes = 1024;
      urc_read.sgb_iova.value = 64'h8000;
      urc_ext = rdma_sqe_urc_ext::type_id::create("urc_read_ext");
      urc_ext.completion_qp_h = qp_handle();
      urc_ext.destination_qpn = 24'h66;
      urc_ext.remote_addr.value = 64'h1000_0000;
      urc_ext.rkey = 32'h1234_5678;
      urc_ext.remote_access_valid = 1'b1;
      urc_ext.rkey_valid = 1'b1;
      urc_read.transport_ext = urc_ext;

      foreach (read_lengths[length_index]) begin
        read_sge = rdma_sge::type_id::create(
          $sformatf("urc_read_sge_%0d", length_index));
        read_sge.length = read_lengths[length_index];
        read_sge.iova.value = 64'h2000 + length_index * 64'h1000;
        read_sge.lkey = 32'h1000 + length_index;
        urc_read.sges.push_back(read_sge);
      end

      // F2 transport gate：三个 literal external descriptors 的 canonical
      // count 是 3；错误的 caller count 2 必须 non-OK 且不发布 image。
      urc_read.sge_num = 8'd2;
      urc_image = rdma_hw_image::type_id::create(
          "urc_count_rejected_sentinel");
      s = urc_codec.encode(urc_read, urc_image);
      if (s == null || s.ok() || urc_image != null)
        `uvm_error("URC_SGE_NUM_EXTERNAL_MISMATCH",
                   "URC external writer accepted count two for three SGEs")
      urc_read.sge_num = 8'd3;
      s = urc_codec.encode(urc_read, urc_image);
      if (s == null || !s.ok()) begin
        `uvm_error("URC_READ_TOTAL_PKT",
                   $sformatf("URC READ external-SGB encode failed: %s",
                             s == null ? "null status" : s.message))
      end
      else begin
        urc_builder = new("urc_read_builder");
        s = urc_builder.deserialize(urc_image.bytes);
        if (s == null || !s.ok()) begin
          `uvm_error("URC_READ_TOTAL_PKT", "URC READ image deserialize failed")
        end
        else begin
          s = urc_builder.get_field(
            40, 40, 24,
            total_packet_num);
          if (s == null || !s.ok() || total_packet_num != 64'd6)
            `uvm_error("URC_READ_TOTAL_PKT",
                       $sformatf("expected 6 packets, got %0d",
                                 total_packet_num))

          // RED/GREEN contract: a fresh probe must derive TOTAL_PKT_NUM
          // ownership from this valid raw image, not from a previous encode.
          urc_probe = rdma_urc_codec_probe::type_id::create(
            "urc_read_fresh_raw_probe");
          s = urc_probe.probe_raw_reserved(urc_builder);
          if (s == null || !s.ok())
            `uvm_error("URC_READ_FRESH_RAW",
                       $sformatf("fresh raw URC READ rejected driver TOTAL_PKT_NUM: %s",
                                 s == null ? "null status" : s.message))

          s = urc_builder.put_field(40, 0, 40, 64'h1);
          if (s == null || !s.ok())
            `uvm_error("URC_READ_RESERVED", "URC qword5 reserved setup failed")
          else begin
            s = urc_builder.serialize(urc_bytes);
            if (s == null || !s.ok()) begin
              `uvm_error("URC_READ_RESERVED", "URC reserved setup serialization failed")
            end
            else begin
              urc_probe = rdma_urc_codec_probe::type_id::create(
                "urc_read_reserved_probe");
              s = urc_probe.probe_reserved(
                urc_builder, RDMA_SQ_PAYLOAD_SGE_SGB, RDMA_SQ_OPCODE_READ);
            end
            if (s != null && s.ok())
              `uvm_error("URC_READ_RESERVED",
                         "URC READ accepted qword5[39:0] nonzero")
          end

        end
      end
    end

    // RQE qword4[63:9] 是驱动定义的 SGB_PA；该跨 transport 的 raw image
    // 断言确保 UD/URC suite 也不会把 RQE 的字段误判为保留位。
    rqe_codec = rdma_hw_rqe_codec::type_id::create("ud_suite_rqe_codec");
    rqe_model = rdma_hw_rqe_model::type_id::create("ud_suite_rqe_model");
    rqe_model.target_h = qp_handle();
    // wr.c fixes the receive-WQE opcode to XTRDMA_OP_TYPE_RQ_WQE (0x9).
    rqe_model.hw_opcode = 4'h9;
    // 53 上 wr.c 只有有效 SGE 数大于两个时才选择 external SGB：
    // SGE_NUM、SGB_PA 和 SGB 中的描述符必须同时呈现，不能用一个
    // direct-inline SGE 的默认模型去制造 SGB raw 坐标测试。
    rqe_model.sge_num = 8'd3;
    rqe_model.payload_len = 32'd48;
    s = rqe_model.set_sgb_pa_encoded(55'h1234_5678_9abc_de);
    if (s == null || !s.ok())
      `uvm_error("RQE_SGB_RAW", "RQE external SGB fixture setup failed")
    begin
      rdma_sge rqe_sge0;
      rdma_sge rqe_sge1;
      rdma_sge rqe_sge2;

      rqe_sge0 = rdma_sge::type_id::create("ud_suite_rqe_sge0");
      rqe_sge0.length = 16;
      rqe_model.sges.push_back(rqe_sge0);

      rqe_sge1 = rdma_sge::type_id::create("ud_suite_rqe_sge1");
      rqe_sge1.length = 16;
      rqe_model.sges.push_back(rqe_sge1);

      rqe_sge2 = rdma_sge::type_id::create("ud_suite_rqe_sge2");
      rqe_sge2.length = 16;
      rqe_model.sges.push_back(rqe_sge2);
    end
    s = rqe_codec.encode(rqe_model, rqe_image);
    if (s == null || !s.ok())
      `uvm_error("RQE_SGB_RAW", "RQE fixture encode failed")
    else begin
      rqe_builder = new("ud_suite_rqe_builder");
      s = rqe_builder.deserialize(rqe_image.bytes);
      if (s == null || !s.ok())
        `uvm_error("RQE_SGB_RAW", "RQE fixture deserialize failed")
      else begin
        s = rqe_builder.put_field(32, 9, 55, 55'h1234_5678_9abc_de);
        if (s == null || !s.ok())
          `uvm_error("RQE_SGB_RAW", "RQE SGB raw field setup failed")
        else begin
          s = rqe_builder.serialize(rqe_bytes);
          if (s == null || !s.ok())
            `uvm_error("RQE_SGB_RAW", "RQE SGB raw field serialization failed")
          else begin
            foreach (rqe_image.bytes[i]) rqe_image.bytes[i] = rqe_bytes[i];
            // External-SGB RQE signatures cover the detached descriptors; build
            // the same 3x16-byte descriptors emitted by the zero-lkey/iova SGEs.
            rqe_descriptor_bytes.delete();
            for (int unsigned i = 0; i < 3; i++) begin
              for (int unsigned j = 0; j < 16; j++)
                rqe_descriptor_bytes.push_back(j < 3 ? 8'h00 :
                                                  (j == 3 ? 8'h10 : 8'h00));
            end
            rqe_image.bytes[16] = ~rdma_hw_sq_signature_xor(
                rqe_image, rqe_descriptor_bytes);
            s = rqe_codec.decode_with_sgb_descriptor_bytes(
                rqe_image, rqe_descriptor_bytes, decoded_model);
            if (s == null || !s.ok())
              `uvm_error("RQE_SGB_RAW",
                         $sformatf("RQE SGB raw field was rejected: %s",
                                   s == null ? "null status" : s.message))
          end
        end
      end
    end
    phase.drop_objection(this);
  endtask
endclass
