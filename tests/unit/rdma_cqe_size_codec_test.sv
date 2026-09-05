// 目录：测试层 unit/rdma_cqe_size_codec_test.sv。
// 职责：验证 32/64/128B CQE layout 的编码与解码往返契约。
// 依赖：rdma_codec_pkg；测试仅拥有本地字段和镜像数组。
// 所有权与生命周期：测试镜像由本地过程创建并在测试结束释放，不接管外部资源。

class rdma_cqe_size_codec_test extends uvm_test;
  `uvm_component_utils(rdma_cqe_size_codec_test)

  // 功能：构造 UVM 测试组件并建立默认名称。
  // 输入输出及副作用：name/parent 为 UVM 输入；仅初始化组件层级。
  // 失败边界：父组件为空时由 UVM 框架处理，测试不分配外部资源。
  function new(string name="rdma_cqe_size_codec_test", uvm_component parent=null);
    super.new(name,parent);
  endfunction

  // 功能：执行三种 CQE profile 的字段编码、解码和关键字段相等断言。
  // 输入输出及副作用：无显式输入；失败通过 UVM error/fatal 报告，不修改生产状态。
  // 失败边界：任一 profile layout 无效、codec 返回错误或 qpn/wr_id 不一致即测试失败。
  task automatic test_cqe_sizes_round_trip();
    int unsigned sizes[3] = '{32,64,128};
    rdma_cqe_fields source, decoded;
    byte unsigned image[];
    rdma_cqe_layout layout;
    rdma_status st;
    source = '{qpn:32'h1234, wr_id:64'h56789a, valid:1'b1};
    foreach (sizes[i]) begin
      layout = rdma_cqe_layout::for_bytes(sizes[i],16);
      st = rdma_queue_codec::encode_cqe(source,layout,image);
      if (!st.ok())
        `uvm_fatal("CQE_RED","encode failed")
      st = rdma_queue_codec::decode_cqe(image,layout,decoded);
      if (!st.ok() || decoded.qpn != source.qpn || decoded.wr_id != source.wr_id)
        `uvm_error("CQE_ROUNDTRIP","CQE size/layout round trip failed")
    end
  endtask

  // 功能：验证共享 registry 中的 CQE codec 可按调用传入的 32/64/128B profile 无状态解码。
  // 输入输出及副作用：本任务构造三个独立 image 并调用 decode_with_entry_bytes，输出仅用于断言，不修改生产账本。
  // 失败边界：任一 profile 无法独立解码、返回模型类型错误或 API 依赖共享 active_bytes 即报告 UVM error。
  task automatic test_cqe_decode_profiles_are_stateless();
    rdma_hw_cqe_codec codec;
    rdma_hw_image images[3];
    rdma_hw_model decoded;
    rdma_hw_cqe_model decoded_cqe;
    rdma_hw_cqe_model source;
    rdma_function_handle qp_h;
    rdma_status st;
    int unsigned sizes[3] = '{32, 64, 128};

    codec = rdma_hw_cqe_codec::type_id::create("stateless_cqe_codec");
    qp_h = rdma_function_handle::type_id::create("stateless_qp");
    qp_h.kind = RDMA_RESOURCE_QP;
    qp_h.function_uid = 64'h1122_3344_5566_7788;
    qp_h.object_id = 32'h2000_0001;
    qp_h.generation = 7;
    source = rdma_hw_cqe_model::type_id::create("stateless_source");
    source.qp_h = qp_h;
    source.qpn = 18'h12345;
    source.wqe_index = 15'h3456;
    source.wqe_wrap = 1'b1;
    source.rq_cqe = 1'b0;
    source.polarity = 1'b1;
    source.packet_opcode = 8'h04;
    source.ecode = 8'h00;
    source.payload_len = 32'h40;
    source.immediate_data = 32'habcdef01;
    source.signature = 16'h1234;
    foreach (sizes[i]) begin
      st = codec.set_entry_bytes(sizes[i]);
      if (st == null || !st.ok()) begin
        `uvm_error("CQE_PROFILE_SETUP", $sformatf("profile %0d setup failed", sizes[i]))
        continue;
      end
      st = codec.encode(source, images[i]);
      if (st == null || !st.ok()) begin
        `uvm_error("CQE_PROFILE_ENCODE", $sformatf("profile %0d encode failed", sizes[i]))
        continue;
      end
    end
    // Deliberately leave the shared codec at 64B before decoding all three
    // images. A correct implementation takes the profile as per-call input.
    st = codec.set_entry_bytes(64);
    if (st == null || !st.ok()) begin
      `uvm_error("CQE_PROFILE_RESET", "failed to set baseline profile")
      return;
    end
    foreach (sizes[i]) begin
      decoded = null;
      st = codec.decode_with_entry_bytes(images[i], sizes[i], decoded);
      if (st == null || !st.ok() || decoded == null)
        `uvm_error("CQE_PROFILE_DECODE", $sformatf("stateless decode failed for %0dB", sizes[i]))
      else if (!$cast(decoded_cqe, decoded) || decoded_cqe.qpn != 18'h12345 ||
               decoded_cqe.wqe_index != 15'h3456)
        `uvm_error("CQE_PROFILE_FIELDS", $sformatf("decoded fields changed for %0dB", sizes[i]))
    end
  endtask

  // 功能：构造含 qword2 保留位的 32B CQE image，确认 codec 不会把签名字段之外的位误当作有效数据。
  // 输入输出及副作用：仅创建本地 codec、模型和 image，并通过 decode_with_entry_bytes 返回校验状态；不修改共享 registry 或外部资源。
  // 失败边界：若 qword2[55:0] 任一保留位被接受，或 image/模型准备失败导致无法执行断言，则报告 UVM error。
  task automatic test_cqe_qword2_reserved_bits_rejected();
    rdma_hw_cqe_codec codec;
    rdma_hw_cqe_model source;
    rdma_hw_image image;
    rdma_hw_model decoded;
    rdma_function_handle qp_h;
    rdma_status st;

    codec = rdma_hw_cqe_codec::type_id::create("qword2_reserved_codec");
    qp_h = rdma_function_handle::type_id::create("qword2_reserved_qp");
    qp_h.kind = RDMA_RESOURCE_QP;
    qp_h.function_uid = 64'h8877_6655_4433_2211;
    qp_h.object_id = 32'h2000_0002;
    qp_h.generation = 9;
    source = rdma_hw_cqe_model::type_id::create("qword2_reserved_source");
    source.qp_h = qp_h;
    source.qpn = 18'h12345;
    source.polarity = 1'b1;
    st = codec.set_entry_bytes(32);
    if (st == null || !st.ok()) begin
      `uvm_error("CQE_RESERVED_SETUP", "failed to select 32B CQE profile")
      return;
    end
    st = codec.encode(source, image);
    if (st == null || !st.ok() || image == null || image.bytes.size() != 32) begin
      `uvm_error("CQE_RESERVED_SETUP", "failed to encode baseline CQE image")
      return;
    end
    // qword2[63:56] is the signature; qword2[55:0] is reserved.  Set the
    // least-significant reserved bit without changing any defined field.
    image.bytes[23] = image.bytes[23] | 8'h01;
    decoded = null;
    st = codec.decode_with_entry_bytes(image, 32, decoded);
    if (st == null || st.ok())
      `uvm_error("CQE_RESERVED_QWORD2", "qword2 reserved bit was accepted")
  endtask

  // 功能：验证极大 header offset 不会因 32 位无符号加法回绕而被误判为合法。
  // 输入输出及副作用：仅创建本地 layout/image 并检查返回状态，不修改生产资源。
  // 失败边界：构造函数、for_bytes() 或 encode_cqe() 任一路径接受回绕 offset
  //       都报告 UVM error，防止后续数组索引越界。
  task automatic test_cqe_layout_rejects_offset_overflow();
    rdma_cqe_fields source;
    rdma_cqe_layout direct_layout;
    rdma_cqe_layout factory_layout;
    byte unsigned image[];
    rdma_status st;

    source = '{qpn:32'h1, wr_id:64'h2, valid:1'b1};
    direct_layout = new("overflow_layout", RDMA_CQE_32B, 32'hffff_fff0);
    factory_layout = rdma_cqe_layout::for_bytes(32, 32'hffff_fff0);
    if (direct_layout == null || direct_layout.valid() ||
        factory_layout == null || factory_layout.valid())
      `uvm_error("CQE_OFFSET_OVERFLOW",
                 "overflowing CQE header offset was accepted")
    st = rdma_queue_codec::encode_cqe(source, factory_layout, image);
    if (st == null || st.ok() || image.size() != 0)
      `uvm_error("CQE_OFFSET_OVERFLOW",
                 "encode accepted an invalid overflowing layout")
  endtask

  // 功能：在 run_phase 中启动 CQE 往返测试并完成 UVM objection 生命周期。
  // 输入输出及副作用：phase 为输入；驱动测试任务并发布 objection 结果。
  // 失败边界：codec 断言失败由测试宏记录，任务仍释放 objection 以避免仿真悬挂。
  task run_phase(uvm_phase phase);
    phase.raise_objection(this);
    test_cqe_sizes_round_trip();
    test_cqe_decode_profiles_are_stateless();
    test_cqe_qword2_reserved_bits_rejected();
    test_cqe_layout_rejects_offset_overflow();
    phase.drop_objection(this);
  endtask
endclass
