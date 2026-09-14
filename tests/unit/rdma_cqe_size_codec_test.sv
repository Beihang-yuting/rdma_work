// 目录：测试层 unit/rdma_cqe_size_codec_test.sv。
// 职责：验证 32/64/128B CQE layout 的编码与解码往返契约。
// 依赖：rdma_codec_pkg；测试仅拥有本地字段和镜像数组。
// 所有权与生命周期：测试镜像由本地过程创建并在测试结束释放，不接管外部资源。

class rdma_cqe_size_codec_test extends uvm_test;
  `uvm_component_utils(rdma_cqe_size_codec_test)

  // 功能：构造 UVM 测试组件并建立默认名称。
  // 输入/输出及副作用：name/parent 为 UVM 输入；仅初始化组件层级。
  // 失败边界：父组件为空时由 UVM 框架处理，测试不分配外部资源。
  function new(string name="rdma_cqe_size_codec_test", uvm_component parent=null);
    super.new(name,parent);
  endfunction

  // 功能：make_hw_cqe_model 构造一份可直接交给 rdma_hw_cqe_codec 编码的
  // 完整 CQE 模型，覆盖句柄代际、完成状态、opcode 和 ring 游标等关键字段。
  // 输入/输出及副作用：无输入；返回值是测试独占的 rdma_hw_cqe_model，内部
  // 新建 QP 值句柄和成功状态，不取得 resource manager 或 backing 的所有权。
  // 失败边界：该辅助函数只构造本地值；若后续测试改动字段使 validate() 拒绝，
  // 应由调用方报告具体 codec 状态，函数本身不隐式修复或重试。
  function automatic rdma_hw_cqe_model make_hw_cqe_model();
    rdma_hw_cqe_model model;
    rdma_handle qp_h;

    model = rdma_hw_cqe_model::type_id::create("explicit_profile_source");
    qp_h = rdma_handle::type_id::create("explicit_profile_qp");
    qp_h.kind = RDMA_RESOURCE_QP;
    qp_h.function_uid = 64'h0102_0304_0506_0708;
    qp_h.object_id = 32'h0000_0042;
    qp_h.generation = 11;

    model.qp_h = qp_h;
    model.wr_id = 64'h1122_3344_5566_7788;
    model.opcode = RDMA_WR_SEND;
    model.status = rdma_status::success("CQE completed");
    model.byte_len = 32'h0000_0040;
    model.immediate_data = 32'hcafe_beef;
    model.qpn = 18'h2a55;
    model.wqe_index = 15'h1234;
    model.wqe_wrap = 1'b1;
    model.rq_cqe = 1'b0;
    model.polarity = 1'b1;
    model.packet_opcode = 8'h04;
    model.ecode = 8'h00;
    model.payload_len = 32'h0000_0040;
    model.signature = 8'ha5;
    return model;
  endfunction

  // 功能：执行三种 CQE profile 的字段编码、解码和关键字段相等断言。
  // 输入/输出及副作用：无显式输入；失败通过 UVM error/fatal 报告，不修改生产状态。
  // 失败/边界：任一 profile layout 无效、codec 返回错误或 qpn/wr_id 不一致即测试失败。
  task automatic test_cqe_sizes_round_trip();
    int unsigned sizes[3] = '{32,64,128};
    rdma_cqe_fields source, decoded;
    byte unsigned image[];
    rdma_cqe_layout layout;
    rdma_status st;
    int unsigned header;
    source = '{qpn:32'h1234, wr_id:64'h56789a, valid:1'b1};
    foreach (sizes[i]) begin
      layout = rdma_cqe_layout::for_bytes(sizes[i],16);
      header = layout.header_offset;
      st = rdma_queue_codec::encode_cqe(source,layout,image);
      if (!st.ok())
        `uvm_fatal("CQE_RED","encode failed")
      if (image.size() != sizes[i])
        `uvm_error("CQE_RAW_SIZE", $sformatf(
          "profile %0dB emitted %0d bytes", sizes[i], image.size()))
      if (header != 16 || image[header] !== 8'h00 ||
          image[header+1] !== 8'h00 || image[header+2] !== 8'h12 ||
          image[header+3] !== 8'h34 || image[header+4] !== 8'h00 ||
          image[header+11] !== 8'h9a || image[header+12] !== 8'h01)
        `uvm_error("CQE_RAW_COORDINATE", $sformatf(
          "profile %0dB header offset/raw coordinates changed", sizes[i]))
      st = rdma_queue_codec::decode_cqe(image,layout,decoded);
      if (!st.ok() || decoded.qpn != source.qpn || decoded.wr_id != source.wr_id)
        `uvm_error("CQE_ROUNDTRIP","CQE size/layout round trip failed")
    end
  endtask

  // 功能：test_cqe_profile_offsets 冻结硬件 profile 的默认 header 坐标，覆盖
  // 32/64B 从 byte0 开始及 128B 从 byte64 开始的 raw qpn 字节。
  // 输入/输出及副作用：构造本地 layout/image 并编码固定字段，仅产生 UVM 断言。
  // 失败/边界：profile header offset 或 big-endian qpn 坐标改变时报告错误。
  task automatic test_cqe_profile_offsets();
    int unsigned sizes[3] = '{32, 64, 128};
    int unsigned offsets[3] = '{0, 0, 64};
    rdma_cqe_fields source;
    rdma_cqe_layout layout;
    byte unsigned image[];
    rdma_status st;
    source = '{qpn:32'h1234, wr_id:64'h56789, valid:1'b1};
    foreach (sizes[i]) begin
      layout = rdma_cqe_layout::for_bytes(sizes[i], offsets[i]);
      st = rdma_queue_codec::encode_cqe(source, layout, image);
      if (!st.ok() || image.size() != sizes[i] || layout.header_offset != offsets[i] ||
          image[offsets[i]+2] !== 8'h12 || image[offsets[i]+3] !== 8'h34)
        `uvm_error("CQE_PROFILE_OFFSET", $sformatf(
          "%0dB profile raw header offset/qpn mismatch", sizes[i]))
      if (sizes[i] == 128 && (image[0] !== 8'h00 || image[2] !== 8'h00 ||
                              image[3] !== 8'h00))
        `uvm_error("CQE_PROFILE_PREFIX", "128B CQE prefix was not preserved")
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

  // 功能：test_cqe_explicit_profile_is_stateless 交错使用 32/64/128B 显式
  // 编码入口，检查镜像 metadata、尾部清零和 active profile 不被污染。
  // 输入/输出及副作用：任务创建本地 codec、模型和镜像；成功调用只发布
  // detached image，失败通过 UVM error 记录，不修改 registry 或外部资源。
  // 失败边界：任一 profile 长度/对齐/端序/代际/类型不符、尾部非零、非法
  // 48B 被接受或默认 encode 长度被改变都会使测试失败。
  task automatic test_cqe_explicit_profile_is_stateless();
    rdma_hw_cqe_codec codec;
    rdma_hw_cqe_model source;
    rdma_hw_image image32;
    rdma_hw_image image64;
    rdma_hw_image image128;
    rdma_hw_image active_image;
    rdma_hw_image invalid_image;
    rdma_status status;
    int unsigned sizes[3] = '{32, 64, 128};
    rdma_hw_image images[3];

    codec = rdma_hw_cqe_codec::type_id::create("explicit_profile_codec");
    source = make_hw_cqe_model();

    // 保持 codec 的 active profile 为 64B，再由显式入口各自选择局部
    // builder；这样可以直接验证调用之间不存在共享 profile 状态污染。
    status = codec.set_entry_bytes(64);
    if (status == null || !status.ok()) begin
      `uvm_error("CQE_EXPLICIT_SETUP", "failed to set baseline 64B profile")
      return;
    end

    status = codec.encode_with_entry_bytes(source, 32, image32);
    if (status == null || !status.ok() || image32 == null ||
        image32.bytes.size() != 32 || image32.length != 32 ||
        image32.alignment != 32 || image32.endian != RDMA_ENDIAN_BIG ||
        image32.image_kind != RDMA_IMAGE_CQE ||
        image32.hardware_version != RDMA_HW_VERSION ||
        image32.function_generation != source.qp_h.generation ||
        image32.write_target_kind != RDMA_HW_TARGET_NONE)
      `uvm_error("CQE_EXPLICIT_32", "32B explicit CQE image metadata is invalid")
    else begin
      foreach (image32.bytes[i]) begin
        if (i >= 24 && image32.bytes[i] !== 8'h00)
          `uvm_error("CQE_EXPLICIT_32_TAIL",
                     $sformatf("32B CQE tail byte %0d is nonzero", i))
      end
    end

    status = codec.encode_with_entry_bytes(source, 128, image128);
    if (status == null || !status.ok() || image128 == null ||
        image128.bytes.size() != 128 || image128.length != 128 ||
        image128.alignment != 128 || image128.endian != RDMA_ENDIAN_BIG ||
        image128.image_kind != RDMA_IMAGE_CQE ||
        image128.hardware_version != RDMA_HW_VERSION ||
        image128.function_generation != source.qp_h.generation ||
        image128.write_target_kind != RDMA_HW_TARGET_NONE)
      `uvm_error("CQE_EXPLICIT_128", "128B explicit CQE image metadata is invalid")
    else begin
      foreach (image128.bytes[i]) begin
        if (i >= 24 && image128.bytes[i] !== 8'h00)
          `uvm_error("CQE_EXPLICIT_128_TAIL",
                     $sformatf("128B CQE tail byte %0d is nonzero", i))
      end
    end

    status = codec.encode_with_entry_bytes(source, 64, image64);
    if (status == null || !status.ok() || image64 == null ||
        image64.bytes.size() != 64 || image64.length != 64 ||
        image64.alignment != 64 || image64.endian != RDMA_ENDIAN_BIG ||
        image64.image_kind != RDMA_IMAGE_CQE ||
        image64.hardware_version != RDMA_HW_VERSION ||
        image64.function_generation != source.qp_h.generation ||
        image64.write_target_kind != RDMA_HW_TARGET_NONE)
      `uvm_error("CQE_EXPLICIT_64", "64B explicit CQE image metadata is invalid")
    else begin
      foreach (image64.bytes[i]) begin
        if (i >= 24 && image64.bytes[i] !== 8'h00)
          `uvm_error("CQE_EXPLICIT_64_TAIL",
                     $sformatf("64B CQE tail byte %0d is nonzero", i))
      end
    end

    // 上述显式调用不得改变 codec 原有的 64B active profile。
    status = codec.encode(source, active_image);
    if (status == null || !status.ok() || active_image == null ||
        active_image.bytes.size() != 64 || active_image.length != 64)
      `uvm_error("CQE_EXPLICIT_ACTIVE", "explicit encode changed active profile")

    status = codec.encode_with_entry_bytes(source, 48, invalid_image);
    if (status == null || status.ok() || invalid_image != null ||
        status.code != RDMA_SC_CODEC_ERROR)
      `uvm_error("CQE_EXPLICIT_INVALID", "invalid 48B profile was accepted")

    // 按交错顺序再次覆盖全部 profile，捕获错误缓存上一次显式尺寸的实现。
    foreach (sizes[i]) begin
      images[i] = null;
      status = codec.encode_with_entry_bytes(source, sizes[i], images[i]);
      if (status == null || !status.ok() || images[i] == null ||
          images[i].bytes.size() != sizes[i])
        `uvm_error("CQE_EXPLICIT_INTERLEAVE",
                   $sformatf("interleaved %0dB encode failed", sizes[i]))
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
  // 输入/输出及副作用：phase 为输入；驱动测试任务并发布 objection 结果。
  // 失败/边界：codec 断言失败由测试宏记录，任务仍释放 objection 以避免仿真悬挂。
  task run_phase(uvm_phase phase);
    phase.raise_objection(this);
    test_cqe_sizes_round_trip();
    test_cqe_profile_offsets();
    test_cqe_decode_profiles_are_stateless();
    test_cqe_explicit_profile_is_stateless();
    test_cqe_qword2_reserved_bits_rejected();
    test_cqe_layout_rejects_offset_overflow();
    phase.drop_objection(this);
  endtask
endclass
