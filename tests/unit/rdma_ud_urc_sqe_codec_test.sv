// 目录：测试层 unit/rdma_ud_urc_sqe_codec_test.sv。
// 职责：验证 UD/URC SQE 编解码的 opcode、目的 QP/Q_Key、payload 和拒绝边界。
// 依赖：rdma_model_pkg、rdma_codec_pkg 与 UVM；不拥有外部 DMA/PCIe 资源。
// 功能：暴露 UD codec 的保留位校验入口，供本文件验证 opcode 相关的动态掩码。
// 输入/输出及副作用：payload_qword 与 hw_opcode 为输入；在 detached builder 上执行只读校验，不写入外部内存。
// 失败/边界：builder 初始化或字段写入失败时原样返回错误；保留位非法时返回 CODEC_ERROR。
class rdma_ud_codec_probe extends rdma_hw_sqe_ud_codec;
  `uvm_object_utils(rdma_ud_codec_probe)
  // 功能：构造保留位探针对象。
  // 输入/输出及副作用：name 为输入；仅建立 UVM 对象，不绑定队列或 DMA 资源。
  // 失败/边界：构造不执行硬件访问；后续 probe_payload 仍需使用合法 opcode。
  function new(string name="rdma_ud_codec_probe"); super.new(name); endfunction
  // 功能：把指定 qword1 与硬件 opcode 交给 UD 保留位检查器。
  // 输入/输出及副作用：payload_qword、hw_opcode 为输入；临时 builder 被初始化并读取，last_hw_opcode 被设置为探针值。
  // 失败/边界：非 64B builder 或字段写入失败立即返回；不修改请求模型或外部 backing。
  function rdma_status probe_payload(bit [63:0] payload_qword, bit [3:0] hw_opcode);
    rdma_hw_qword_builder b;
    rdma_status s;
    b = new("ud_reserved_probe");
    s = b.reset(RDMA_WQE_BYTES); if (!s.ok()) return s;
    s = b.put_field(8, 0, 64, payload_qword); if (!s.ok()) return s;
    last_hw_opcode = hw_opcode;
    return check_reserved(b);
  endfunction
endclass

class rdma_ud_urc_sqe_codec_test extends uvm_test;
  `uvm_component_utils(rdma_ud_urc_sqe_codec_test)
  // 功能：构造 focused UD/URC codec 测试组件。
  // 输入/输出及副作用：name、parent 为输入；建立 UVM 测试节点，不拥有 DUT 资源。
  // 失败/边界：构造不执行仿真；依赖缺失在 run_phase 中报告。
  function new(string name="rdma_ud_urc_sqe_codec_test", uvm_component parent=null); super.new(name,parent); endfunction
  // 功能：创建带 Function authority 的 QP 测试句柄。
  // 输入/输出及副作用：无参数；返回本地句柄快照，不接管资源管理器。
  // 失败/边界：句柄仅用于 codec 字段校验，不能代表已 attach 的运行时 QP。
  function automatic rdma_handle qp_handle(); rdma_handle h=rdma_handle::type_id::create("qp"); h.kind=RDMA_RESOURCE_QP; h.object_id=1; h.function_uid=64'h1122; h.generation=1; return h; endfunction
  // 功能：运行 UD SEND_WITH_INV 编解码及关键字段断言。
  // 输入/输出及副作用：phase 为 UVM 阶段输入；产生错误报告，不修改外部资源。
  // 失败/边界：编码失败、opcode/QPN/Q_Key/IETH 不匹配时报告 UVM error。
  task run_phase(uvm_phase phase);
    rdma_post_send_req req; byte unsigned image[]; rdma_status s; rdma_ud_codec_probe probe;
    rdma_hw_rqe_codec rqe_codec;
    rdma_hw_rqe_model rqe_model;
    rdma_hw_image rqe_image;
    rdma_hw_qword_builder rqe_builder;
    byte unsigned rqe_bytes[];
    rdma_hw_model decoded_model;
    phase.raise_objection(this);
    probe = rdma_ud_codec_probe::type_id::create("ud_reserved_probe");
    s = probe.probe_payload(64'h0000_0001_0000_0000, RDMA_SQ_OPCODE_SEND);
    if (s == null || s.ok()) `uvm_error("UD_RESERVED", "UD SEND accepted qword1 immediate/reserved high bits")
    s = probe.probe_payload(64'h0000_0001_0000_0000, RDMA_SQ_OPCODE_SEND_WITH_IMM);
    if (s == null || !s.ok()) `uvm_error("UD_IMM", "UD SEND_WITH_IMM rejected valid immediate field")
    s = probe.probe_payload(64'h0000_0000_0200_0000, RDMA_SQ_OPCODE_SEND_WITH_IMM);
    if (s == null || s.ok()) `uvm_error("UD_RESERVED", "UD accepted qword1 reserved bit25")
    req=rdma_post_send_req::type_id::create("ud_send_inv"); req.qp_h=qp_handle(); req.transport=RDMA_TRANSPORT_UD; req.opcode=RDMA_WR_SEND_WITH_INV; req.destination_qpn=24'h12345; req.qkey=32'h11112222; req.invalidate_rkey=32'hdeadbeef; req.address_vector_valid=1; req.address_vector=rdma_address_vector::type_id::create("av");
    // 驱动对 UD 非空 payload 始终使用每个 SQ slot 对应的 512B SGB，不能把数据内联到
    // 与 AH 元数据重叠的 WQE 字节区；这里故意提供非零、512B 对齐的 SGB IOVA。
    req.sgb_iova.value = 64'h2000; req.inline_data=1; req.payload.push_back(8'h5a);
    s=rdma_queue_codec::encode_sqe(req,image);
    if (s==null || !s.ok() || image.size()!=RDMA_WQE_BYTES) begin
      `uvm_error("SQE_RED",$sformatf("UD SEND_WITH_INV codec did not encode: %s", s == null ? "null status" : s.message))
    end
    if (image.size()>3 && image[3] != RDMA_SQ_OPCODE_SEND_WITH_INV) `uvm_error("SQE_OPCODE","UD opcode mismatch")
    if (image.size() < 12 || {image[8],image[9],image[10],image[11]} != req.invalidate_rkey)
      `uvm_error("SQE_IETH","invalidate_rkey was not encoded")
    // 目的 QPN 位于 offset=40 qword 的 bits[55:32]，大端序列化后落在 41..43 字节。
    if (image.size() < 44 || {image[41],image[42],image[43]} != req.destination_qpn[23:0])
      `uvm_error("SQE_DQPN","destination QPN was not encoded")
    if (image.size() < 40 || image[32] == 0 && image[33] == 0 && image[34] == 0 &&
        image[35] == 0 && image[36] == 0 && image[37] == 0 && image[38] == 0 && image[39] == 0)
      `uvm_error("SQE_SGB","UD payload did not select SGB")

    req.sgb_iova.value = 64'h2100;
    s = rdma_queue_codec::encode_sqe(req,image);
    if (s == null || s.ok())
      `uvm_error("SQE_ALIGN","UD accepted an unaligned SGB IOVA")

    req.sgb_iova.value = 64'h2000;
    req.payload.delete();
    for (int unsigned i = 0; i < 16384; i++) req.payload.push_back(8'h00);
    s = rdma_queue_codec::encode_sqe(req,image);
    if (s == null || s.ok())
      `uvm_error("SQE_LEN","UD accepted payload beyond the 14-bit length field")

    req=rdma_post_send_req::type_id::create("urc_send"); req.qp_h=qp_handle();
    req.transport=RDMA_TRANSPORT_URC; req.opcode=RDMA_WR_SEND; req.destination_qpn=24'h55;
    req.completion_qp_h=qp_handle(); req.inline_data=0;
    begin
      rdma_sge sg; sg=rdma_sge::type_id::create("urc_sge"); sg.length=16; sg.lkey=32'h1234; sg.iova.value=64'h4000; req.sges.push_back(sg);
    end
    s=rdma_queue_codec::encode_sqe(req,image);
    if (s == null || !s.ok())
      `uvm_error("URC_ENCODE", $sformatf("URC SEND codec did not encode: %s", s == null ? "null status" : s.message))

    // RQE qword4[63:9] 是驱动定义的 SGB_PA；该跨 transport 的 raw image
    // 断言确保 UD/URC suite 也不会把 RQE 的字段误判为保留位。
    rqe_codec = rdma_hw_rqe_codec::type_id::create("ud_suite_rqe_codec");
    rqe_model = rdma_hw_rqe_model::type_id::create("ud_suite_rqe_model");
    rqe_model.target_h = qp_handle();
    begin
      rdma_sge rqe_sge;
      rqe_sge = rdma_sge::type_id::create("ud_suite_rqe_sge");
      rqe_sge.length = 16;
      rqe_model.sges.push_back(rqe_sge);
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
        s = rqe_builder.put_field(32, 9, 55, 55'h0012_3456_789a_bcde);
        if (s == null || !s.ok())
          `uvm_error("RQE_SGB_RAW", "RQE SGB raw field setup failed")
        else begin
          s = rqe_builder.serialize(rqe_bytes);
          if (s == null || !s.ok())
            `uvm_error("RQE_SGB_RAW", "RQE SGB raw field serialization failed")
          else begin
            foreach (rqe_image.bytes[i]) rqe_image.bytes[i] = rqe_bytes[i];
            s = rqe_codec.decode(rqe_image, decoded_model);
            if (s == null || !s.ok())
              `uvm_error("RQE_SGB_RAW", "RQE SGB raw field was rejected")
          end
        end
      end
    end
    phase.drop_objection(this);
  endtask
endclass
