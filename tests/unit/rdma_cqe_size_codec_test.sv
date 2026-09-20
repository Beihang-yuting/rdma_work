// 目录：测试层 unit/rdma_cqe_size_codec_test.sv。
// 职责：验证 32/64/128B CQE layout 的编码与解码往返契约。
// 依赖：rdma_codec_pkg；测试仅拥有本地字段和镜像数组。
// 所有权与生命周期：测试镜像由本地过程创建并在测试结束释放，不接管外部资源。

class rdma_cqe_size_codec_test extends uvm_test;
  `uvm_component_utils(rdma_cqe_size_codec_test)

  // 功能：构造 UVM 测试组件并建立默认名称。
  // 输入/输出及副作用：name/parent 为 UVM 输入；仅初始化组件层级。
  // 失败/边界：父组件为空时由 UVM 框架处理，测试不分配外部资源。
  function new(string name="rdma_cqe_size_codec_test", uvm_component parent=null);
    super.new(name,parent);
  endfunction

  // 功能：make_hw_cqe_model 构造一份可直接交给 rdma_hw_cqe_codec 编码的
  // 完整 CQE 模型，覆盖句柄代际、完成状态、opcode 和 ring 游标等关键字段。
  // 输入/输出及副作用：无输入；返回值是测试独占的 rdma_hw_cqe_model，内部
  // 新建 QP 值句柄和成功状态，不取得 resource manager 或 backing 的所有权。
  // 失败/边界：该辅助函数只构造本地值；若后续测试改动字段使 validate() 拒绝，
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
  // 输入/输出及副作用：本任务构造三个独立 image 并调用 decode_with_entry_bytes，输出仅用于断言，不修改生产账本。
  // 失败/边界：任一 profile 无法独立解码、返回模型类型错误或 API 依赖共享 active_bytes 即报告 UVM error。
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
  // 失败/边界：任一 profile 长度/对齐/端序/代际/类型不符、尾部非零、非法
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
        if (i >= 88 && image128.bytes[i] !== 8'h00)
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
  // 输入/输出及副作用：仅创建本地 codec、模型和 image，并通过
  //       decode_with_entry_bytes 返回校验状态；不修改共享 registry 或外部资源。
  // 失败/边界：若 qword2[30:28] 任一保留位被接受，或 image/模型准备失败导致
  //       无法执行断言，则报告 UVM error。
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
    // qword2[30:28] is the only gap between the three physical driver views.
    // Set one of those reserved bits without changing any declared field.
    image.bytes[20] = image.bytes[20] | 8'h40;
    decoded = null;
    st = codec.decode_with_entry_bytes(image, 32, decoded);
    if (st == null || st.ok())
      `uvm_error("CQE_RESERVED_QWORD2", "qword2 reserved bit was accepted")
  endtask

  // 功能：构造 128B CQE 的 profile-relative raw image，确认 qword8 起始的
  // header 能从非零 prefix 后正确解码，并把旧 byte0 坐标作为负向证据。
  // 输入/输出及副作用：仅创建本地 codec、source/image 和 detached decode
  // model；成功路径只读 raw bytes，失败通过 UVM error 记录，不修改生产资源。
  // 失败/边界：prefix、qword8/qword9/qword10 任一保留位不满足 profile，或
  // byte0 image 被误当作 128B header，均报告具体坐标错误。
  task automatic test_cqe_128b_profile_relative_header();
    rdma_hw_cqe_codec codec;
    rdma_hw_cqe_model source;
    rdma_hw_image base64;
    rdma_hw_image image128;
    rdma_hw_model decoded;
    rdma_hw_cqe_model decoded_cqe;
    rdma_status st;

    codec = rdma_hw_cqe_codec::type_id::create("profile_relative_codec");
    source = make_hw_cqe_model();
    st = codec.encode_with_entry_bytes(source, 64, base64);
    if (st == null || !st.ok() || base64 == null || base64.bytes.size() != 64) begin
      `uvm_error("CQE_PROFILE_RELATIVE_SETUP", "failed to build 64B CQE source")
      return;
    end

    image128 = rdma_hw_image::type_id::create("profile_relative_raw");
    foreach (image128.bytes[i]) image128.bytes[i] = 8'h00;
    // Prefix bytes are outside the active qword8..qword10 window and are
    // deliberately nonzero to prove that reserved checking is profile-relative.
    for (int unsigned i = 0; i < 64; i++)
      image128.bytes.push_back(8'hc3);
    foreach (base64.bytes[i]) image128.bytes.push_back(base64.bytes[i]);
    image128.length = 128;
    image128.alignment = 128;
    image128.endian = RDMA_ENDIAN_BIG;
    image128.image_kind = RDMA_IMAGE_CQE;
    image128.hardware_version = RDMA_HW_VERSION;
    image128.function_generation = source.qp_h.generation;
    image128.write_target_kind = RDMA_HW_TARGET_NONE;
    image128.backing_target = '0;
    image128.hmc_target = '0;
    image128.bar_target = '0;

    decoded = null;
    st = codec.decode_with_entry_bytes(image128, 128, decoded);
    if (st == null || !st.ok() || decoded == null || !$cast(decoded_cqe, decoded) ||
        decoded_cqe.qpn != source.qpn || decoded_cqe.wqe_index != source.wqe_index ||
        decoded_cqe.payload_len != source.payload_len || decoded_cqe.signature != source.signature)
      `uvm_error("CQE_PROFILE_RELATIVE_DECODE",
                 "128B CQE fields were not decoded from qword8 window")

    // A legacy byte0 header is outside the 128B active window.  It must not be
    // interpreted as the completion represented by qword8..qword10.
    foreach (base64.bytes[i]) image128.bytes[i] = base64.bytes[i];
    for (int unsigned i = 64; i < 128; i++)
      image128.bytes[i] = 8'h00;
    decoded = null;
    st = codec.decode_with_entry_bytes(image128, 128, decoded);
    if (st == null || !st.ok() || decoded == null || !$cast(decoded_cqe, decoded) ||
        decoded_cqe.qpn == source.qpn)
      `uvm_error("CQE_PROFILE_RELATIVE_BYTE0",
                 "128B byte0 header was incorrectly treated as active")
  endtask

  // 功能：验证 CQE detached decode 在 image 字节数短于声明 profile 时安全拒绝，
  //       不进入 qword 窗口索引或发布部分模型。
  // 输入/输出及副作用：任务构造 24B 的本地 CQE image 并调用 32B 显式解码，
  //       只产生 UVM 断言，不修改 codec active profile 或外部资源。
  // 失败/边界：长度、bytes 数组和 alignment 任一不满足 entry_size=32 时必须返回
  //       非成功状态；若短 image 被接受则报告 CQE_SHORT_IMAGE。
  task automatic test_cqe_short_image_rejected();
    rdma_hw_cqe_codec codec;
    rdma_hw_cqe_model source;
    rdma_hw_image short_image;
    rdma_hw_model decoded;
    rdma_status st;

    codec = rdma_hw_cqe_codec::type_id::create("short_image_codec");
    source = make_hw_cqe_model();
    short_image = rdma_hw_image::type_id::create("short_cqe_image");
    for (int unsigned i = 0; i < 24; i++)
      short_image.bytes.push_back(8'h00);
    short_image.length = 24;
    short_image.alignment = 24;
    short_image.endian = RDMA_ENDIAN_BIG;
    short_image.image_kind = RDMA_IMAGE_CQE;
    short_image.hardware_version = RDMA_HW_VERSION;
    short_image.function_generation = source.qp_h.generation;
    short_image.write_target_kind = RDMA_HW_TARGET_NONE;
    short_image.backing_target = '0;
    short_image.hmc_target = '0;
    short_image.bar_target = '0;
    decoded = null;
    st = codec.decode_with_entry_bytes(short_image, 32, decoded);
    if (st == null || st.ok())
      `uvm_error("CQE_SHORT_IMAGE", "short CQE image was accepted")
  endtask

  // 功能：验证极大 header offset 不会因 32 位无符号加法回绕而被误判为合法。
  // 输入/输出及副作用：仅创建本地 layout/image 并检查返回状态，不修改生产资源。
  // 失败/边界：构造函数、for_bytes() 或 encode_cqe() 任一路径接受回绕 offset
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

  // 功能：test_cqe_driver_fields_contract 构造驱动 wr.h 声明的 CQE
  //       header/qword2 字段，确认合法字段可被解码并保持物理坐标。
  // 输入/输出及副作用：只创建本地 builder、raw image 和 detached model；测试
  //       读取 0.1.34 wire 坐标并通过 UVM error 记录字段或 metadata 失配。
  // 失败/边界：签名字段必须先按驱动 complement-XOR 规则修补为有效值；若任一
  //       已声明字段仍被当作 reserved、模型类型错误或字段值丢失，测试失败。
  task automatic test_cqe_driver_fields_contract();
    rdma_hw_cqe_codec codec;
    rdma_hw_qword_builder builder;
    byte unsigned bytes[];
    rdma_hw_image image;
    rdma_hw_model decoded;
    rdma_hw_cqe_model decoded_cqe;
    rdma_status status;

    codec = rdma_hw_cqe_codec::type_id::create("driver_fields_red_codec");
    builder = new("driver_fields_red_builder");
    status = builder.reset(64);
    if (status == null || !status.ok()) begin
      `uvm_error("CQE_TYPED_FIELDS_SETUP", "failed to reset raw CQE builder")
      return;
    end

    // wr.h:123-141 qword0 fields; these are legal driver-owned bits that the
    // pre-Task3 mask intentionally did not claim.
    status = builder.put_field(0, 63, 1, 1'b1);
    status = builder.put_field(0, 60, 3, 3'h5);
    status = builder.put_field(0, 59, 1, 1'b1);
    status = builder.put_field(0, 58, 1, 1'b1);
    status = builder.put_field(0, 57, 1, 1'b1);
    status = builder.put_field(0, 56, 1, 1'b1);
    status = builder.put_field(0, 55, 1, 1'b1);
    status = builder.put_field(0, 40, 15, 15'h3456);
    status = builder.put_field(0, 32, 8, 8'h81);
    status = builder.put_field(0, 24, 8, 8'hf4);
    status = builder.put_field(0, 23, 1, 1'b1);
    status = builder.put_field(0, 22, 1, 1'b1);
    status = builder.put_field(0, 20, 2, 2'b10);
    status = builder.put_field(0, 19, 1, 1'b1);
    status = builder.put_field(0, 18, 1, 1'b1);
    status = builder.put_field(0, 0, 18, 18'h2a55);

    // wr.h:143-149 qword2 overlay; the RED image uses the RQ/SRFQ-owned
    // completion coordinates and a nonzero signature.
    status = builder.put_field(16, 56, 8, 8'ha5);
    status = builder.put_field(16, 31, 1, 1'b1);
    status = builder.put_field(16, 16, 12, 12'habc);
    status = builder.put_field(16, 15, 1, 1'b1);
    status = builder.put_field(16, 0, 15, 15'h1234);

    if (status == null || !status.ok()) begin
      `uvm_error("CQE_TYPED_FIELDS_SETUP", "failed to build raw CQE fields")
      return;
    end
    status = builder.serialize(bytes);
    if (status == null || !status.ok() || bytes.size() != 64) begin
      `uvm_error("CQE_TYPED_FIELDS_SETUP", "failed to serialize raw CQE fields")
      return;
    end

    image = rdma_hw_image::type_id::create("driver_fields_red_image");
    foreach (bytes[i])
      image.bytes.push_back(bytes[i]);
    image.length = 64;
    image.alignment = 64;
    image.endian = RDMA_ENDIAN_BIG;
    image.image_kind = RDMA_IMAGE_CQE;
    image.hardware_version = RDMA_HW_VERSION;
    image.function_generation = 1;
    image.write_target_kind = RDMA_HW_TARGET_NONE;
    image.backing_target = '0;
    image.hmc_target = '0;
    image.bar_target = '0;

    // The fixture sets SIGN_EN=1, so replace the arbitrary setup byte with the
    // exact signature the driver would derive from the completed 64B entry.
    image.bytes[16] = expected_cqe_signature(image, 16);

    decoded = null;
    status = codec.set_variant(RDMA_CQE_VARIANT_RQ_SRFQ);
    if (status == null || !status.ok()) begin
      `uvm_error("CQE_TYPED_FIELDS_SETUP", "failed to select RQ/SRFQ variant")
      return;
    end
    status = codec.decode_with_entry_bytes(image, 64, decoded);
    if (status == null || !status.ok() || decoded == null ||
        !$cast(decoded_cqe, decoded) ||
        decoded_cqe.qp_state != 3'h5 ||
        decoded_cqe.srfqn != 12'habc ||
        decoded_cqe.srfqe_wrap != 1'b1 ||
        decoded_cqe.srfqe_index != 15'h1234) begin
      `uvm_error("CQE_TYPED_FIELDS_CONTRACT",
                 "driver-owned CQE fields were rejected or lost")
    end
  endtask

  // 功能：test_cqe_qword2_union_accepts_driver_views 构造 wr.h 的 qword2
  //       union image，确认 RC/UD/RQ-SRFQ 物理重叠位只按 [30:28] 保留区检查，
  //       而不会因为当前 codec 选择了某一个语义 view 就拒绝真实 wire bits。
  // 输入/输出及副作用：任务创建本地 builder、CQE image 和 detached model；只读
  //       驱动坐标并通过 UVM 断言结果，不修改 registry、ring 或外部 backing。
  // 失败/边界：qword2 的 signature、UD source QPN、RQE_CPL、SRFQN、wrap/index
  //       任一合法 union 位被拒，或 [30:28] 保留区未保持零，均报告具体错误。
  task automatic test_cqe_qword2_union_accepts_driver_views();
    rdma_hw_cqe_codec codec;
    rdma_hw_qword_builder builder;
    byte unsigned bytes[];
    rdma_hw_image image;
    rdma_hw_model decoded;
    rdma_status status;

    codec = rdma_hw_cqe_codec::type_id::create("qword2_union_codec");
    builder = new("qword2_union_builder");
    status = builder.reset(64);
    if (status == null || !status.ok()) begin
      `uvm_error("CQE_QWORD2_UNION_SETUP", "failed to reset CQE builder")
      return;
    end

    // wr.h:143-149.  Bits [30:28] deliberately remain zero; every other
    // qword2 union region is populated so a variant-specific mask cannot pass
    // this case by accident.
    void'(builder.put_field(16, 56, 8, 8'ha5));
    void'(builder.put_field(16, 32, 24, 24'h12_3456));
    void'(builder.put_field(16, 31, 1, 1'b1));
    void'(builder.put_field(16, 16, 12, 12'hab0));
    void'(builder.put_field(16, 15, 1, 1'b1));
    void'(builder.put_field(16, 0, 15, 15'h1234));
    status = builder.serialize(bytes);
    if (status == null || !status.ok() || bytes.size() != 64) begin
      `uvm_error("CQE_QWORD2_UNION_SETUP", "failed to serialize CQE builder")
      return;
    end

    image = rdma_hw_image::type_id::create("qword2_union_image");
    foreach (bytes[i])
      image.bytes.push_back(bytes[i]);
    image.length = 64;
    image.alignment = 64;
    image.endian = RDMA_ENDIAN_BIG;
    image.image_kind = RDMA_IMAGE_CQE;
    image.hardware_version = RDMA_HW_VERSION;
    image.function_generation = 1;
    image.write_target_kind = RDMA_HW_TARGET_NONE;
    image.backing_target = '0;
    image.hmc_target = '0;
    image.bar_target = '0;

    decoded = null;
    status = codec.decode_with_entry_bytes(image, 64, decoded);
    if (status == null || !status.ok() || decoded == null)
      `uvm_error("CQE_QWORD2_UNION",
                 "legal driver qword2 union bits were rejected")
  endtask

  // 功能：test_cqe_128b_opaque_tail_is_preserved_as_input 验证 128B CQE 的
  //       header 之外字节不被模型凭空当作 zero/reserved，尤其覆盖 qword12 的
  //       非零 raw payload/tail 证据。
  // 输入/输出及副作用：任务先编码一份合法 128B image，再修改本地 raw bytes
  //       并调用 detached decode；不修改 source、codec profile 或外部资源。
  // 失败/边界：若驱动未声明的 zero-tail 假设导致合法 opaque bytes 被拒，报告
  //       CQE_128B_OPAQUE_TAIL；header/qword0..2 仍必须按现有保留位规则校验。
  task automatic test_cqe_128b_opaque_tail_is_preserved_as_input();
    rdma_hw_cqe_codec codec;
    rdma_hw_cqe_model source;
    rdma_hw_image image;
    rdma_hw_model decoded;
    rdma_status status;

    codec = rdma_hw_cqe_codec::type_id::create("opaque_tail_codec");
    source = make_hw_cqe_model();
    status = codec.encode_with_entry_bytes(source, 128, image);
    if (status == null || !status.ok() || image == null || image.bytes.size() != 128) begin
      `uvm_error("CQE_128B_OPAQUE_SETUP", "failed to build 128B CQE image")
      return;
    end

    // qword12 is outside the header-relative fields and has no zero assertion
    // in cq.h/wr.h; retain a nonzero byte as an opaque device-produced value.
    image.bytes[96] = 8'h5a;
    decoded = null;
    status = codec.decode_with_entry_bytes(image, 128, decoded);
    if (status == null || !status.ok() || decoded == null)
      `uvm_error("CQE_128B_OPAQUE_TAIL",
                 "nonzero 128B opaque tail was incorrectly rejected")
  endtask

  // 功能：test_cqe_qword2_raw_authority_round_trip 验证驱动 CQE qword2 的
  //       物理 union 在 decode/encode 间保持逐位保真，并阻止修改 detached
  //       字段后悄然复用过期 raw image。
  // 输入/输出及副作用：任务构造一个同时带 signature、RC syndrome、UD
  //       source QPN 和 RQ/SRFQ 坐标的本地 image，调用显式 variant API；只
  //       发布测试模型和断言，不取得 CQ、QP 或 host-memory 所有权。
  // 失败/边界：任一已声明 union 位丢失、raw authority 未保存、字段修改未被
  //       fail-closed，或 clear authority 后无法按显式 variant 重编码，均报告
  //       独立 UVM 错误。
  task automatic test_cqe_qword2_raw_authority_round_trip();
    rdma_hw_cqe_codec codec;
    rdma_hw_qword_builder builder;
    rdma_hw_image image;
    rdma_hw_image reencoded;
    rdma_hw_model decoded;
    rdma_hw_cqe_model decoded_cqe;
    rdma_status status;
    byte unsigned bytes[];
    bit [63:0] raw_qword2;

    codec = rdma_hw_cqe_codec::type_id::create("qword2_authority_codec");
    builder = new("qword2_authority_builder");
    status = builder.reset(32);
    if (status == null || !status.ok()) begin
      `uvm_error("CQE_QWORD2_AUTHORITY_SETUP",
                 "failed to reset raw qword2 builder")
      return;
    end

    void'(builder.put_field(0, 63, 1, 1'b1));
    void'(builder.put_field(0, 0, 18, 18'h12345));
    raw_qword2 = '0;
    raw_qword2[63:56] = 8'ha5;
    // RC syndrome is the upper byte of the overlapping UD source QPN view;
    // choose a physically consistent value instead of pretending the aliases
    // can carry two independent numbers on one wire.
    raw_qword2[55:32] = 24'h6b_3456;
    raw_qword2[31] = 1'b1;
    raw_qword2[27:16] = 12'hab0;
    raw_qword2[15] = 1'b1;
    raw_qword2[14:0] = 15'h1234;
    status = builder.put_field(16, 0, 64, raw_qword2);
    status = builder.serialize(bytes);
    if (status == null || !status.ok()) begin
      `uvm_error("CQE_QWORD2_AUTHORITY_SETUP",
                 "failed to serialize raw qword2 image")
      return;
    end

    image = rdma_hw_image::type_id::create("qword2_authority_image");
    foreach (bytes[i])
      image.bytes.push_back(bytes[i]);
    image.length = 32;
    image.alignment = 32;
    image.endian = RDMA_ENDIAN_BIG;
    image.image_kind = RDMA_IMAGE_CQE;
    image.hardware_version = RDMA_HW_VERSION;
    image.function_generation = 1;
    image.write_target_kind = RDMA_HW_TARGET_NONE;
    image.backing_target = '0;
    image.hmc_target = '0;
    image.bar_target = '0;

    decoded = null;
    status = codec.decode_with_entry_bytes_variant(
        image, 32, RDMA_CQE_VARIANT_RQ_SRFQ, decoded);
    if (status == null || !status.ok() || decoded == null ||
        !$cast(decoded_cqe, decoded)) begin
      `uvm_error("CQE_QWORD2_AUTHORITY_DECODE",
                 "explicit RQ/SRFQ raw decode failed")
      return;
    end

    if (!decoded_cqe.raw_qword2_valid ||
        decoded_cqe.raw_qword2 !== raw_qword2 ||
        decoded_cqe.signature !== 8'ha5 ||
        decoded_cqe.rc_remote_syndrome !== 8'h6b ||
        decoded_cqe.ud_src_qpn !== 24'h6b_3456 ||
        decoded_cqe.rqe_cpl !== 1'b1 ||
        decoded_cqe.srfqn !== 12'hab0 ||
        decoded_cqe.srfqe_wrap !== 1'b1 ||
        decoded_cqe.srfqe_index !== 15'h1234)
      `uvm_error("CQE_QWORD2_AUTHORITY_FIELDS",
                 "raw qword2 authority or union fields were lost")

    status = codec.encode_with_entry_bytes_variant(
        decoded_cqe, 32, RDMA_CQE_VARIANT_RQ_SRFQ, reencoded);
    if (status == null || !status.ok() || reencoded == null)
      `uvm_error("CQE_QWORD2_AUTHORITY_REENCODE",
                 "raw qword2 authority could not be reused")
    else begin
      foreach (image.bytes[i]) begin
        if (reencoded.bytes[i] !== image.bytes[i])
          `uvm_error("CQE_QWORD2_AUTHORITY_BYTES",
                     $sformatf("raw qword2 byte %0d changed", i))
      end
    end

    decoded_cqe.rc_remote_syndrome = 8'h6c;
    reencoded = null;
    status = codec.encode_with_entry_bytes_variant(
        decoded_cqe, 32, RDMA_CQE_VARIANT_RQ_SRFQ, reencoded);
    if (status == null || status.ok() || reencoded != null)
      `uvm_error("CQE_QWORD2_AUTHORITY_STALE",
                 "modified raw-authority model was silently encoded")

    decoded_cqe.clear_raw_qword2_authority();
    decoded_cqe.rc_remote_syndrome = 8'h00;
    decoded_cqe.ud_src_qpn = 24'h00;
    decoded_cqe.ud_smac = 48'h00;
    decoded_cqe.ud_vlan_tag = 16'h00;
    status = codec.encode_with_entry_bytes_variant(
        decoded_cqe, 32, RDMA_CQE_VARIANT_RQ_SRFQ, reencoded);
    if (status == null || !status.ok() || reencoded == null)
      `uvm_error("CQE_QWORD2_AUTHORITY_CLEAR",
                 "cleared raw authority did not permit typed re-encode")
  endtask

  // 功能：test_cqe_variant_api_is_interleaving_safe 交错调用 RC、UD 和
  //       RQ/SRFQ 的显式 profile API，确保一次调用的 variant 不污染下一次
  //       调用，也不依赖模型 overlay 非零值猜测 wire authority。
  // 输入/输出及副作用：任务创建三个独立 CQE model/image，并通过显式入口
  //       编码和解码；只读取 detached bytes，不修改共享 registry 或外部资源。
  // 失败/边界：任一交错调用使用了上一次 variant、隐式推断了 overlay 或在
  //       variant 与 typed 字段不一致时继续编码，均报告具体 UVM 错误。
  task automatic test_cqe_variant_api_is_interleaving_safe();
    rdma_hw_cqe_codec codec;
    rdma_hw_cqe_model rc_model;
    rdma_hw_cqe_model ud_model;
    rdma_hw_cqe_model rq_model;
    rdma_hw_cqe_model decoded_cqe;
    rdma_hw_image rc_image;
    rdma_hw_image ud_image;
    rdma_hw_image rq_image;
    rdma_hw_model decoded;
    rdma_function_handle qp_h;
    rdma_status status;

    codec = rdma_hw_cqe_codec::type_id::create("variant_interleave_codec");
    qp_h = rdma_function_handle::type_id::create("variant_interleave_qp");
    qp_h.kind = RDMA_RESOURCE_QP;
    qp_h.function_uid = 64'h2233_4455_6677_8899;
    qp_h.object_id = 32'h2000_0003;
    qp_h.generation = 3;

    rc_model = rdma_hw_cqe_model::type_id::create("rc_variant_model");
    rc_model.qp_h = qp_h;
    rc_model.qpn = 18'h12345;
    rc_model.rc_remote_syndrome = 8'hb9;
    rc_model.signature = 8'ha1;
    rc_model.variant = RDMA_CQE_VARIANT_RC;

    ud_model = rdma_hw_cqe_model::type_id::create("ud_variant_model");
    ud_model.qp_h = qp_h;
    ud_model.qpn = 18'h12345;
    ud_model.ud_src_qpn = 24'h654321;
    ud_model.ud_smac = 48'h1122_3344_5566;
    ud_model.ud_vlan_tag = 16'h7788;
    ud_model.signature = 8'ha2;
    ud_model.variant = RDMA_CQE_VARIANT_UD;

    rq_model = rdma_hw_cqe_model::type_id::create("rq_variant_model");
    rq_model.qp_h = qp_h;
    rq_model.qpn = 18'h12345;
    rq_model.rqe_cpl = 1'b1;
    rq_model.srfqn = 12'habc;
    rq_model.srfqe_wrap = 1'b1;
    rq_model.srfqe_index = 15'h4567;
    rq_model.signature = 8'ha3;
    rq_model.variant = RDMA_CQE_VARIANT_RQ_SRFQ;

    status = codec.encode_with_entry_bytes_variant(
        rc_model, 32, RDMA_CQE_VARIANT_RC, rc_image);
    if (status == null || !status.ok())
      `uvm_error("CQE_VARIANT_INTERLEAVE_RC", "RC explicit encode failed")

    status = codec.encode_with_entry_bytes_variant(
        ud_model, 32, RDMA_CQE_VARIANT_UD, ud_image);
    if (status == null || !status.ok())
      `uvm_error("CQE_VARIANT_INTERLEAVE_UD", "UD explicit encode failed")

    status = codec.encode_with_entry_bytes_variant(
        rq_model, 32, RDMA_CQE_VARIANT_RQ_SRFQ, rq_image);
    if (status == null || !status.ok())
      `uvm_error("CQE_VARIANT_INTERLEAVE_RQ", "RQ/SRFQ explicit encode failed")

    decoded = null;
    status = codec.decode_with_entry_bytes_variant(
        ud_image, 32, RDMA_CQE_VARIANT_UD, decoded);
    if (status == null || !status.ok() || decoded == null ||
        !$cast(decoded_cqe, decoded) ||
        decoded_cqe.variant != RDMA_CQE_VARIANT_UD ||
        decoded_cqe.ud_src_qpn != ud_model.ud_src_qpn)
      `uvm_error("CQE_VARIANT_INTERLEAVE_UD_DECODE",
                 "UD decode was contaminated by another variant")

    decoded = null;
    status = codec.decode_with_entry_bytes_variant(
        rc_image, 32, RDMA_CQE_VARIANT_RC, decoded);
    if (status == null || !status.ok() || decoded == null ||
        !$cast(decoded_cqe, decoded) ||
        decoded_cqe.variant != RDMA_CQE_VARIANT_RC ||
        decoded_cqe.rc_remote_syndrome != rc_model.rc_remote_syndrome)
      `uvm_error("CQE_VARIANT_INTERLEAVE_RC_DECODE",
                 "RC decode was contaminated by another variant")

    // A model explicitly marked RC may not smuggle a nonzero typed RQ view
    // through the RC encoder.  The raw-authority path above is the only legal
    // way to preserve simultaneous physical overlay bits.
    rc_model.rqe_cpl = 1'b1;
    status = codec.encode_with_entry_bytes_variant(
        rc_model, 32, RDMA_CQE_VARIANT_RC, rc_image);
    if (status == null || status.ok())
      `uvm_error("CQE_VARIANT_TYPED_CONFLICT",
                 "RC model with RQ fields was silently truncated")
  endtask

  // 功能：expected_cqe_signature 按驱动 xtrdma_check_cqe_signature 的全 entry
  //       XOR 规则，独立计算应写入 CQE signature byte 的补码值。
  // 输入/输出及副作用：image 与 signature_offset 为只读输入；返回值是排除
  //       signature byte 后所有 entry bytes 的 XOR 取反，不修改 image 或 codec。
  // 失败/边界：image 为空、offset 越界时返回 0；调用方必须先验证 image 长度，
  //       不能把该值单独当作签名有效性证明。
  function automatic bit [7:0] expected_cqe_signature(
      input rdma_hw_image image,
      input int unsigned signature_offset
  );
    bit [7:0] value;

    value = 8'h00;
    if (image == null || signature_offset >= image.bytes.size())
      return value;

    foreach (image.bytes[i]) begin
      if (i != signature_offset)
        value ^= image.bytes[i];
    end

    return ~value;
  endfunction

  // 功能：image_byte_xor 复现驱动对完整 CQE entry 执行的字节 XOR，供签名
  //       正向和负向断言共同使用。
  // 输入/输出及副作用：image 为只读输入；返回所有 bytes 的 8 位 XOR，不修改
  //       image、模型或外部资源。
  // 失败/边界：image 为空时返回 0；调用方必须同时检查 image 是否为空，避免把
  //       空输入与合法零 XOR 混为一谈。
  function automatic bit [7:0] image_byte_xor(input rdma_hw_image image);
    bit [7:0] value;

    value = 8'h00;
    if (image == null)
      return value;

    foreach (image.bytes[i])
      value ^= image.bytes[i];

    return value;
  endfunction

  // 功能：test_cqe_signature_contract 验证 CQE SIGN_EN=1 时 32/64/128B entry
  //       都由完整 raw bytes 派生 signature，并在任一字段或 opaque tail 被篡改
  //       后拒绝；该任务直接对应 wr.c 的 xtrdma_check_cqe_signature。
  // 输入/输出及副作用：任务创建本地 codec、模型和 detached images；成功路径
  //       只读取/修改测试独占 bytes，失败通过 UVM error 记录，不触碰 CQ ring。
  // 失败/边界：签名位置必须分别是 byte16、byte16、byte80；任何 profile 未能
  //       使完整 XOR 等于 8'hff、错误签名仍被接受或 128B opaque tail 未纳入校验
  //       均报告独立错误。
  task automatic test_cqe_signature_contract();
    rdma_hw_cqe_codec codec;
    rdma_hw_cqe_model source;
    rdma_hw_image image;
    rdma_hw_model decoded;
    rdma_status status;
    int unsigned sizes[3] = '{32, 64, 128};
    int unsigned bases[3] = '{0, 0, 64};
    int unsigned signature_offset;
    bit [7:0] expected;

    codec = rdma_hw_cqe_codec::type_id::create("cqe_signature_codec");
    source = make_hw_cqe_model();
    source.sign_en = 1'b1;
    source.signature = 8'h00;

    foreach (sizes[i]) begin
      image = null;
      status = codec.encode_with_entry_bytes(source, sizes[i], image);
      if (status == null || !status.ok() || image == null) begin
        `uvm_error("CQE_SIGNATURE_ENCODE",
                   $sformatf("%0dB signed CQE encode failed", sizes[i]))
        continue;
      end

      signature_offset = bases[i] + 16;
      expected = expected_cqe_signature(image, signature_offset);
      if (image.bytes[signature_offset] !== expected ||
          image_byte_xor(image) !== 8'hff)
        `uvm_error("CQE_SIGNATURE_DERIVE",
                   $sformatf("%0dB signature was not derived from full entry",
                             sizes[i]))

      decoded = null;
      status = codec.decode_with_entry_bytes(image, sizes[i], decoded);
      if (status == null || !status.ok() || decoded == null)
        `uvm_error("CQE_SIGNATURE_DECODE",
                   $sformatf("valid %0dB signed CQE was rejected", sizes[i]))

      // Mutating a declared header byte leaves reserved masks unchanged but
      // must invalidate the complete-entry parity check.
      image.bytes[bases[i] + 7] ^= 8'h01;
      decoded = null;
      status = codec.decode_with_entry_bytes(image, sizes[i], decoded);
      if (status == null || status.ok() || decoded != null)
        `uvm_error("CQE_SIGNATURE_MUTATION",
                   $sformatf("tampered %0dB CQE signature was accepted", sizes[i]))
    end

    // A nonzero 128B opaque tail is legal input.  Recompute the signature as
    // the driver would see it; a checker that only covers header bytes rejects
    // this valid image or ignores subsequent tail mutations.
    image = null;
    status = codec.encode_with_entry_bytes(source, 128, image);
    if (status == null || !status.ok() || image == null)
      `uvm_error("CQE_SIGNATURE_TAIL_SETUP", "failed to build 128B tail image")
    else begin
      image.bytes[120] = 8'h5a;
      signature_offset = 80;
      image.bytes[signature_offset] = expected_cqe_signature(
          image, signature_offset);
      decoded = null;
      status = codec.decode_with_entry_bytes(image, 128, decoded);
      if (status == null || !status.ok() || decoded == null)
        `uvm_error("CQE_SIGNATURE_TAIL_ACCEPT",
                   "signed 128B CQE with opaque tail was rejected")

      image.bytes[120] ^= 8'h01;
      decoded = null;
      status = codec.decode_with_entry_bytes(image, 128, decoded);
      if (status == null || status.ok() || decoded != null)
        `uvm_error("CQE_SIGNATURE_TAIL_MUTATION",
                   "opaque 128B tail mutation bypassed signature check")
    end
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
    test_cqe_128b_profile_relative_header();
    test_cqe_short_image_rejected();
    test_cqe_layout_rejects_offset_overflow();
    test_cqe_driver_fields_contract();
    test_cqe_qword2_union_accepts_driver_views();
    test_cqe_128b_opaque_tail_is_preserved_as_input();
    test_cqe_qword2_raw_authority_round_trip();
    test_cqe_variant_api_is_interleaving_safe();
    test_cqe_signature_contract();
    phase.drop_objection(this);
  endtask
endclass
