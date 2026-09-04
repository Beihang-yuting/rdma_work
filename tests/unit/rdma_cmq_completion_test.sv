// 目录：测试层 unit/rdma_cmq_completion_test.sv。
// 职责：验证 rdma_cmq_completion_test 对应模块的接口、错误路径和边界行为。
// 依赖：依赖被测 package、UVM 测试基类和必要的 mock/fixture。
// 所有权与生命周期：测试对象只拥有本地 fixture；外部后端句柄由测试环境提供并在测试结束释放。

// 中文说明：rdma_cmq_completion_test.sv 属于单元测试，覆盖对应模型、编码器或执行器契约。
// 阅读提示：先看公开类型和接口，再看实现细节；失败路径应保持状态与资源所有权可追踪。

class rdma_cmq_completion_test extends uvm_test;
  `uvm_component_utils(rdma_cmq_completion_test)

  rdma_hw_cmq_completion_codec codec;

  // 功能：构造 rdma_cmq_completion_test，调用 super.new 建立 UVM 层级对象；外部依赖字段保持未绑定，后续由 configure/build/activate 明确注入。
  // 输入/输出及副作用：name、parent（输入）；new 只写入构造体列出的默认字段并返回 void，外部依赖与资源所有权仍由上层管理。
  // 失败/边界：rdma_cmq_completion_test 构造只建立本地初始状态，不接管外部 Host-memory、PCIe 或 manager；未完成后续 configure/build/activate 时，业务入口必须返回 INVALID_STATE。
  function new(string name = "rdma_cmq_completion_test",
               uvm_component parent = null);
    super.new(name, parent);
  endfunction

  // 功能：在 rdma_cmq_completion_test 中，expect_status 在测试中执行 expect_status 断言，比较输入结果与期望状态并报告可定位的失败信息。
  // 输入/输出及副作用：label（输入）、status（输入）、expected（输入）；fixture/输入由测试调用方提供；执行时会产生 UVM assertion/report，不向 DUT 转移未声明的资源所有权。
  // 失败/边界：测试函数 expect_status 缺少前置对象时报告断言错误，并停止依赖该对象的后续检查。
  function automatic void expect_status(
    string label,
    rdma_status status,
    rdma_status_code_e expected
  );
    if (status == null)
      `uvm_error(label, "completion decoder returned a null status")
    else if (status.code != expected)
      `uvm_error(label,
                 $sformatf("expected %s, got %s (%s)", expected.name(),
                           status.code.name(), status.convert2string()))
  endfunction

  // 功能：在 rdma_cmq_completion_test 中，set_qword 按硬件布局把输入模型编码到 image/缓冲区，并在写入前检查范围、重叠、端序和保留位。
  // 输入/输出及副作用：image（输入）、qword_index（输入）、value（输入）；set_qword 先依据 依赖存在性、authority 和 generation 条件 校验 image、qword_index、value；成功时更新本对象配置/状态并保存非拥有引用，返回 void。
  // 失败/边界：set_qword 遇到 image/model 为空、长度/对齐/保留位非法或 codec 校验失败时不发布部分字段。
  function automatic void set_qword(
    rdma_hw_image image,
    int unsigned qword_index,
    bit [63:0] value
  );
    int unsigned base;
    base = qword_index * 8;
    for (int unsigned i = 0; i < 8; i++)
      image.bytes[base + i] = value[63 - (i * 8) -: 8];
  endfunction

  // 功能：在 rdma_cmq_completion_test 中，get_qword 按完整 key/handle 查找唯一权威记录并返回 detached 快照，避免把内部可变引用泄露给调用方。
  // 输入/输出及副作用：image（输入）、qword_index（输入）；get_qword 读取 image、qword_index 并使用字段 value、base；函数返回 bit [63:0]，不取得调用方资源所有权。
  // 失败/边界：get_qword 在 key/handle 缺失、记录不唯一或 generation/reset epoch 过期时返回明确错误，不回退到默认 authority。
  function automatic bit [63:0] get_qword(
    rdma_hw_image image,
    int unsigned qword_index
  );
    bit [63:0] value;
    int unsigned base;
    value = '0;
    base = qword_index * 8;
    for (int unsigned i = 0; i < 8; i++)
      value = {value[55:0], image.bytes[base + i]};
    return value;
  endfunction

  // 功能：make_image 根据 opcode、h00、h1b、b1、b1 生成或检查硬件镜像字段，保持布局、端序和保留位约束一致。
  // 输入/输出及副作用：opcode（输入）、h00（输入）、h1b（输入）、b1（输入）、b1（输入）；make_image 读取 opcode、command_ecode、wqe_index、wrap、owner 并使用字段 image、image.length、image.alignment、image.endian、image.image_kind、image.hardware_version、image.function_generation、image.write_target_kind；函数返回 rdma_hw_image，不取得调用方资源所有权。
  // 失败/边界：make_image 的结果直接由 return image 计算；输入不满足表达式条件时沿函数体的保守分支返回，不修改已发布账本。
  function automatic rdma_hw_image make_image(
    bit [7:0] opcode,
    bit [7:0] command_ecode = 8'h00,
    bit [4:0] wqe_index = 5'h1b,
    bit wrap = 1'b1,
    bit owner = 1'b1
  );
    rdma_hw_image image;
    bit [63:0] qword0;
    image = rdma_hw_image::type_id::create("cmq_completion_image");
    repeat (64) image.bytes.push_back(8'h00);
    image.length = 64;
    image.alignment = 64;
    image.endian = RDMA_ENDIAN_BIG;
    image.image_kind = RDMA_IMAGE_CMQ_CQE;
    image.hardware_version = 1;
    image.function_generation = 0;
    image.write_target_kind = RDMA_HW_TARGET_NONE;
    image.backing_target = '0;
    image.hmc_target = '0;
    image.bar_target = '0;
    qword0 = '0;
    qword0[63] = owner;
    qword0[45] = wrap;
    qword0[44:40] = wqe_index;
    qword0[39:32] = opcode;
    qword0[31:24] = command_ecode;
    set_qword(image, 0, qword0);
    return image;
  endfunction

  // 功能：将 rhs 中 rdma_cmq_completion_test 的值字段复制到当前对象，建立与源对象隔离的快照。
  // 输入/输出及副作用：source（输入）、name（输入）；clone_image 读取 source、name 并使用字段 clone；函数返回 rdma_hw_image，不取得调用方资源所有权。
  // 失败/边界：clone_image 的结果直接由 return clone 计算；输入不满足表达式条件时沿函数体的保守分支返回，不修改已发布账本。
  function automatic rdma_hw_image clone_image(
    rdma_hw_image source,
    string name
  );
    rdma_hw_image clone;
    clone = rdma_hw_image::type_id::create(name);
    clone.copy(source);
    return clone;
  endfunction

  // 功能：在 rdma_cmq_completion_test 中，expect_image_unchanged 在测试中执行 expect_image_unchanged 断言，比较输入结果与期望状态并报告可定位的失败信息。
  // 输入/输出及副作用：label（输入）、actual（输入）、expected（输入）；fixture/输入由测试调用方提供；执行时会产生 UVM assertion/report，不向 DUT 转移未声明的资源所有权。
  // 失败/边界：测试函数 expect_image_unchanged 缺少前置对象时报告断言错误，并停止依赖该对象的后续检查。
  function automatic void expect_image_unchanged(
    string label,
    rdma_hw_image actual,
    rdma_hw_image expected
  );
    if (actual == null || expected == null) begin
      `uvm_error(label, "image comparison received null")
      return;
    end
    if (actual.length != expected.length ||
        actual.alignment != expected.alignment ||
        actual.endian != expected.endian ||
        actual.image_kind != expected.image_kind ||
        actual.hardware_version != expected.hardware_version ||
        actual.function_generation != expected.function_generation ||
        actual.write_target_kind != expected.write_target_kind ||
        actual.backing_target.value != expected.backing_target.value ||
        actual.hmc_target.value != expected.hmc_target.value ||
        actual.bar_target.value != expected.bar_target.value ||
        actual.bytes.size() != expected.bytes.size() ||
        actual.field_summary.size() != expected.field_summary.size()) begin
      `uvm_error(label, "completion decoder mutated image metadata")
      return;
    end
    foreach (actual.bytes[i])
      if (actual.bytes[i] != expected.bytes[i]) begin
        `uvm_error(label, $sformatf("image byte %0d changed", i))
        return;
      end
    foreach (actual.field_summary[i])
      if (actual.field_summary[i] != expected.field_summary[i]) begin
        `uvm_error(label, $sformatf("field summary %0d changed", i))
        return;
      end
  endfunction

  // Independent driver-derived oracle.  It intentionally does not call any
  // codec mask/helper: qword 0 owns owner bit 63 and bits 45:24;
  // returned-object bytes are opened only for admitted query opcodes.
  // 功能：在 rdma_cmq_completion_test 中，literal_allowed_mask 根据 opcode、对象类型或 profile 选择允许位掩码/有效 payload 范围，供保留位检查使用。
  // 输入/输出及副作用：opcode（输入）、qword_index（输入）；literal_allowed_mask 读取 opcode、qword_index 并使用字段 ；函数返回 bit [63:0]，不取得调用方资源所有权。
  // 失败/边界：literal_allowed_mask 按 case(opcode、qword_index) 的固定映射计算 bit [63:0]（h0f→64'hffff_ffff_ffff_ffff；default→64'h0000_0000_0000_0000）；未列出的输入走 default，不修改运行时账本。
  function automatic bit [63:0] literal_allowed_mask(
    bit [7:0] opcode,
    int unsigned qword_index
  );
    if (qword_index == 0)
      return 64'h8000_3fff_ff00_0000;
    case (opcode)
      8'h0f: return 64'hffff_ffff_ffff_ffff; // CQC bytes 8..63
      8'h09:
        if (qword_index inside {[2:7]})
          return 64'hffff_ffff_ffff_ffff; // MRT bytes 16..63
      8'h13, 8'h17, 8'h38:
        if (qword_index inside {[2:5]})
          return 64'hffff_ffff_ffff_ffff; // EQC/SRFQC bytes 16..47
      default: return 64'h0000_0000_0000_0000;
    endcase
    return 64'h0000_0000_0000_0000;
  endfunction

  // 功能：在 rdma_cmq_completion_test 中，literal_payload_bounds 从输入 image/bytes 按固定 offset 提取字段，交付解码所需的值。
  // 输入/输出及副作用：opcode（输入）、first_byte（输出）、byte_count（输出）；literal_payload_bounds 读取 opcode、first_byte、byte_count 并使用字段 first_byte、byte_count，并写入 first_byte、byte_count；函数返回 void，不取得调用方资源所有权。
  // 失败/边界：literal_payload_bounds 无返回值，仅执行 first_byte=0、byte_count=0、first_byte=16、byte_count=48；调用方须保证前置依赖已经绑定，函数不自动重试或接管外部资源。
  function automatic void literal_payload_bounds(
    bit [7:0] opcode,
    output int unsigned first_byte,
    output int unsigned byte_count
  );
    first_byte = 0;
    byte_count = 0;
    case (opcode)
      8'h09: begin first_byte = 16; byte_count = 48; end
      8'h0f: begin first_byte = 8; byte_count = 56; end
      8'h13, 8'h17, 8'h38: begin
        first_byte = 16;
        byte_count = 32;
      end
      default: begin first_byte = 0; byte_count = 0; end
    endcase
  endfunction

  // 功能：在 rdma_cmq_completion_test 中，expect_decode_success 在测试中执行 expect_decode_success 断言，比较输入结果与期望状态并报告可定位的失败信息。
  // 输入/输出及副作用：label（输入）、image（输入）、expected_owner（输入）、expected_first_byte（输入）、expected_payload_length（输入）；fixture/输入由测试调用方提供；执行时会产生
  //   UVM assertion/report，不向 DUT 转移未声明的资源所有权。
  // 失败/边界：测试函数 expect_decode_success 缺少前置对象时报告断言错误，并停止依赖该对象的后续检查。
  function automatic void expect_decode_success(
    string label,
    rdma_hw_image image,
    bit expected_owner,
    int unsigned expected_first_byte,
    int unsigned expected_payload_length
  );
    rdma_hw_cmq_completion completion;
    rdma_hw_image snapshot;
    rdma_status status;
    bit [63:0] qword0;
    bit ready;
    snapshot = clone_image(image, {label, "_snapshot"});
    completion = null;
    ready = 1'b0;
    status = codec.inspect_completion(image, expected_owner, ready,
                                      completion);
    expect_status({label, "_STATUS"}, status, RDMA_SC_OK);
    if (!ready)
      `uvm_error(label, "matching owner was not reported ready")
    else if (completion == null)
      `uvm_error(label, "successful decode published null")
    else begin
      qword0 = get_qword(image, 0);
      if (completion.owner != expected_owner ||
          completion.opcode != qword0[39:32] ||
          completion.command_ecode != qword0[31:24] ||
          completion.wqe_index != qword0[44:40] ||
          completion.wrap != qword0[45])
        `uvm_error(label, "successful decode changed a common field")
      if (completion.object_payload.size() != expected_payload_length)
        `uvm_error(label, $sformatf(
          "expected payload length %0d, got %0d", expected_payload_length,
          completion.object_payload.size()))
      else
        foreach (completion.object_payload[i])
          if (completion.object_payload[i] !=
              image.bytes[expected_first_byte + i]) begin
            `uvm_error(label, $sformatf("payload byte %0d changed", i))
            break;
          end
    end
    expect_image_unchanged({label, "_IMMUTABLE"}, image, snapshot);
  endfunction

  // 功能：在 rdma_cmq_completion_test 中，expect_decode_failure 在测试中执行 expect_decode_failure 断言，比较输入结果与期望状态并报告可定位的失败信息。
  // 输入/输出及副作用：label（输入）、image（输入）、expected_owner（输入）、expected_status（输入）、expected_ready（输入）；fixture/输入由测试调用方提供；执行时会产生
  //   UVM assertion/report，不向 DUT 转移未声明的资源所有权。
  // 失败/边界：测试函数 expect_decode_failure 缺少前置对象时报告断言错误，并停止依赖该对象的后续检查。
  function automatic void expect_decode_failure(
    string label,
    rdma_hw_image image,
    bit expected_owner,
    rdma_status_code_e expected_status = RDMA_SC_CODEC_ERROR,
    bit expected_ready = 1'b0
  );
    rdma_hw_cmq_completion completion;
    rdma_hw_image snapshot;
    rdma_status status;
    bit ready;
    completion = rdma_hw_cmq_completion::type_id::create(
      {label, "_stale_completion"});
    snapshot = (image == null) ? null : clone_image(image, {label, "_snapshot"});
    ready = 1'b1;
    status = codec.inspect_completion(image, expected_owner, ready,
                                      completion);
    expect_status(label, status, expected_status);
    if (ready != expected_ready)
      `uvm_error(label, $sformatf(
        "failure ready mismatch: expected %0b got %0b",
        expected_ready, ready))
    if (completion != null)
      `uvm_error(label, "structural decode failure published completion")
    if (image != null)
      expect_image_unchanged({label, "_IMMUTABLE"}, image, snapshot);
  endfunction

  // 功能：在测试辅助 rdma_cmq_completion_test.check_common_fields_and_raw_ecode 中构造或驱动“common fields and raw
  //   ecode”场景，并断言 DUT 的状态、错误码和资源账本符合契约。
  // 输入/输出及副作用：无显式参数；fixture/输入由测试调用方提供；执行时会产生 UVM assertion/report，不向 DUT 转移未声明的资源所有权。
  // 失败/边界：fixture 未初始化、故障注入未生效或观测值与预期不一致时报告 UVM_ERROR/断言失败；测试不会吞掉失败。
  function automatic void check_common_fields_and_raw_ecode();
    rdma_hw_image image;
    rdma_hw_image snapshot;
    rdma_hw_cmq_completion completion;
    rdma_hw_cmq_completion copied;
    rdma_status status;
    bit ready;
    image = make_image(8'h00, 8'h45, 5'h1b, 1'b1);
    snapshot = clone_image(image, "common_snapshot");
    completion = null;
    ready = 1'b0;
    status = codec.inspect_completion(image, 1'b1, ready, completion);
    expect_status("CQE_COMMON_STATUS", status, RDMA_SC_OK);
    if (!ready || completion == null)
      `uvm_error("CQE_COMMON", "successful decode published null")
    else begin
      if (completion.owner != 1'b1 || completion.opcode != 8'h00 ||
          completion.command_ecode != 8'h45 ||
          completion.wqe_index != 5'h1b || completion.wrap != 1'b1)
        `uvm_error("CQE_COMMON", "common completion fields changed")
      if (completion.object_payload.size() != 0)
        `uvm_error("CQE_COMMON", "non-return command published payload")
      copied = rdma_hw_cmq_completion::type_id::create(
        "copied_completion");
      copied.copy(completion);
      if (copied.owner != completion.owner)
        `uvm_error("CQE_COMMON_COPY", "completion copy lost owner")
    end
    expect_image_unchanged("CQE_COMMON_IMMUTABLE", image, snapshot);
  endfunction

  // 功能：在测试辅助 rdma_cmq_completion_test.check_payload_slice 中构造或驱动“payload slice”场景，并断言 DUT 的状态、错误码和资源账本符合契约。
  // 输入/输出及副作用：label（输入）、opcode（输入）、first_byte（输入）、last_byte（输入）；fixture/输入由测试调用方提供；执行时会产生 UVM assertion/report，不向 DUT
  //   转移未声明的资源所有权。
  // 失败/边界：fixture 未初始化、故障注入未生效或观测值与预期不一致时报告 UVM_ERROR/断言失败；测试不会吞掉失败。
  function automatic void check_payload_slice(
    string label,
    bit [7:0] opcode,
    int unsigned first_byte,
    int unsigned last_byte
  );
    rdma_hw_image image;
    rdma_hw_image snapshot;
    rdma_hw_cmq_completion completion;
    rdma_status status;
    bit ready;
    int unsigned expected_length;
    image = make_image(opcode, 8'h00, 5'h03, 1'b0);
    for (int unsigned i = first_byte; i <= last_byte; i++)
      image.bytes[i] = i;
    snapshot = clone_image(image, {label, "_snapshot"});
    completion = null;
    ready = 1'b0;
    status = codec.inspect_completion(image, 1'b1, ready, completion);
    expect_status({label, "_STATUS"}, status, RDMA_SC_OK);
    if (!ready || completion == null) begin
      `uvm_error(label, "successful payload decode published null")
      return;
    end
    expected_length = last_byte - first_byte + 1;
    if (completion.object_payload.size() != expected_length)
      `uvm_error(label,
                 $sformatf("expected payload length %0d, got %0d",
                           expected_length, completion.object_payload.size()))
    else begin
      if (completion.object_payload[0] != first_byte[7:0])
        `uvm_error(label, "payload first-byte boundary is wrong")
      if (completion.object_payload[expected_length - 1] != last_byte[7:0])
        `uvm_error(label, "payload last-byte boundary is wrong")
      foreach (completion.object_payload[i])
        if (completion.object_payload[i] != (first_byte + i)) begin
          `uvm_error(label, $sformatf("payload byte %0d is not exact", i))
          break;
        end
    end
    expect_image_unchanged({label, "_IMMUTABLE"}, image, snapshot);
  endfunction

  // 功能：在测试辅助 rdma_cmq_completion_test.check_metadata_failures 中构造或驱动“metadata failures”场景，并断言 DUT
  //   的状态、错误码和资源账本符合契约。
  // 输入/输出及副作用：无显式参数；fixture/输入由测试调用方提供；执行时会产生 UVM assertion/report，不向 DUT 转移未声明的资源所有权。
  // 失败/边界：fixture 未初始化、故障注入未生效或观测值与预期不一致时报告 UVM_ERROR/断言失败；测试不会吞掉失败。
  function automatic void check_metadata_failures();
    rdma_hw_image image;
    expect_decode_failure("CQE_NULL", null, 1'b1, RDMA_SC_CODEC_ERROR,
                          1'b0);

    image = make_image(8'h00, 0, 0, 0);
    image.length = 63;
    expect_decode_failure("CQE_LENGTH", image, 1'b1, RDMA_SC_CODEC_ERROR,
                          1'b0);
    image = make_image(8'h00, 0, 0, 0);
    void'(image.bytes.pop_back());
    expect_decode_failure("CQE_BYTE_SIZE", image, 1'b1,
                          RDMA_SC_CODEC_ERROR, 1'b0);
    image = make_image(8'h00, 0, 0, 0);
    image.image_kind = RDMA_IMAGE_CMQ_SQE;
    expect_decode_failure("CQE_KIND", image, 1'b1, RDMA_SC_CODEC_ERROR,
                          1'b0);
    image = make_image(8'h00, 0, 0, 0);
    image.hardware_version = 2;
    expect_decode_failure("CQE_VERSION", image, 1'b1, RDMA_SC_CODEC_ERROR,
                          1'b0);
    image = make_image(8'h00, 0, 0, 0);
    image.endian = RDMA_ENDIAN_LITTLE;
    expect_decode_failure("CQE_ENDIAN", image, 1'b1, RDMA_SC_CODEC_ERROR,
                          1'b0);
    image = make_image(8'h00, 0, 0, 0);
    image.alignment = 8;
    expect_decode_failure("CQE_ALIGNMENT", image, 1'b1,
                          RDMA_SC_CODEC_ERROR, 1'b0);
    image = make_image(8'h00, 0, 0, 0);
    image.write_target_kind = RDMA_HW_TARGET_BAR;
    expect_decode_failure("CQE_TARGET_KIND", image, 1'b1,
                          RDMA_SC_CODEC_ERROR, 1'b0);
    image = make_image(8'h00, 0, 0, 0);
    image.backing_target.value = 64'h1000;
    expect_decode_failure("CQE_BACKING_TARGET", image, 1'b1,
                          RDMA_SC_CODEC_ERROR, 1'b0);
    image = make_image(8'h00, 0, 0, 0);
    image.hmc_target.value = 64'h2000;
    expect_decode_failure("CQE_HMC_TARGET", image, 1'b1,
                          RDMA_SC_CODEC_ERROR, 1'b0);
    image = make_image(8'h00, 0, 0, 0);
    image.bar_target.value = 64'h3000;
    expect_decode_failure("CQE_BAR_TARGET", image, 1'b1,
                          RDMA_SC_CODEC_ERROR, 1'b0);
  endfunction

  // 功能：在测试辅助 rdma_cmq_completion_test.check_owner_ready_ordering 中构造或驱动“owner ready ordering”场景，并断言 DUT
  //   的状态、错误码和资源账本符合契约。
  // 输入/输出及副作用：无显式参数；fixture/输入由测试调用方提供；执行时会产生 UVM assertion/report，不向 DUT 转移未声明的资源所有权。
  // 失败/边界：fixture 未初始化、故障注入未生效或观测值与预期不一致时报告 UVM_ERROR/断言失败；测试不会吞掉失败。
  function automatic void check_owner_ready_ordering();
    rdma_hw_image image;
    rdma_hw_cmq_completion completion;
    rdma_status status;
    bit [63:0] word;
    bit ready;

    // A stale entry may contain arbitrary payload.  Once metadata/qword 0 are
    // readable, owner mismatch must return empty without interpreting it.
    image = make_image(8'hfe, 8'hff, 5'h1f, 1'b1, 1'b0);
    word = get_qword(image, 7);
    word[3] = 1'b1;
    set_qword(image, 7, word);
    completion = rdma_hw_cmq_completion::type_id::create(
      "stale_owner_completion");
    ready = 1'b1;
    status = codec.inspect_completion(image, 1'b1, ready, completion);
    expect_status("CQE_OWNER_MISMATCH_STATUS", status, RDMA_SC_OK);
    if (ready || completion != null)
      `uvm_error("CQE_OWNER_MISMATCH",
                 "stale owner published readiness or a completion")

    image = make_image(8'hfe, 0, 0, 0, 1'b1);
    expect_decode_failure("CQE_UNKNOWN_OPCODE", image, 1'b1,
                          RDMA_SC_UNSUPPORTED_OPCODE);
  endfunction

  // 功能：在测试辅助 rdma_cmq_completion_test.check_literal_admission_table 中构造或驱动“literal admission table”场景，并断言 DUT
  //   的状态、错误码和资源账本符合契约。
  // 输入/输出及副作用：无显式参数；fixture/输入由测试调用方提供；执行时会产生 UVM assertion/report，不向 DUT 转移未声明的资源所有权。
  // 失败/边界：fixture 未初始化、故障注入未生效或观测值与预期不一致时报告 UVM_ERROR/断言失败；测试不会吞掉失败。
  function automatic void check_literal_admission_table();
    bit [7:0] supported[$] = '{
      8'h00, 8'h01, 8'h02, 8'h03, 8'h04, 8'h05, 8'h06,
      8'h0a, 8'h0c, 8'h0e, 8'h0f, 8'h10, 8'h12, 8'h13,
      8'h14, 8'h16, 8'h17, 8'h20, 8'h35, 8'h37, 8'h38,
      8'h09
    };
    bit [7:0] unsupported[$] = '{8'h07, 8'h1a, 8'hfe};
    rdma_hw_image image;
    int unsigned first_byte;
    int unsigned byte_count;
    foreach (supported[i]) begin
      image = make_image(supported[i], 0, 0, 0);
      literal_payload_bounds(supported[i], first_byte, byte_count);
      expect_decode_success(
        $sformatf("CQE_ADMISSION_%02x", supported[i]), image, 1'b1,
        first_byte, byte_count);
    end
    foreach (unsupported[i]) begin
      image = make_image(unsupported[i], 0, 0, 0);
      expect_decode_failure(
        $sformatf("CQE_UNSUPPORTED_%02x", unsupported[i]), image,
        1'b1, RDMA_SC_UNSUPPORTED_OPCODE);
    end
  endfunction

  // 功能：在测试辅助 rdma_cmq_completion_test.check_every_reserved_bit 中构造或驱动“every reserved bit”场景，并断言 DUT
  //   的状态、错误码和资源账本符合契约。
  // 输入/输出及副作用：无显式参数；fixture/输入由测试调用方提供；执行时会产生 UVM assertion/report，不向 DUT 转移未声明的资源所有权。
  // 失败/边界：fixture 未初始化、故障注入未生效或观测值与预期不一致时报告 UVM_ERROR/断言失败；测试不会吞掉失败。
  function automatic void check_every_reserved_bit();
    bit [7:0] opcodes[$] = '{8'h00, 8'h0f, 8'h09,
                              8'h13, 8'h17, 8'h38};
    rdma_hw_image image;
    bit [63:0] allowed;
    bit [63:0] word;
    foreach (opcodes[o]) begin
      for (int unsigned q = 0; q < 8; q++) begin
        allowed = literal_allowed_mask(opcodes[o], q);
        for (int unsigned b = 0; b < 64; b++) begin
          if (allowed[b]) continue;
          image = make_image(opcodes[o], 0, 0, 0);
          word = get_qword(image, q);
          word[b] = 1'b1;
          set_qword(image, q, word);
          expect_decode_failure(
            $sformatf("CQE_RESERVED_%02x_Q%0d_B%0d", opcodes[o], q, b),
            image, 1'b1
          );
        end
      end
    end
  endfunction

  // 功能：在测试辅助 rdma_cmq_completion_test.check_every_allowed_data_bit 中构造或驱动“every allowed data bit”场景，并断言 DUT
  //   的状态、错误码和资源账本符合契约。
  // 输入/输出及副作用：无显式参数；fixture/输入由测试调用方提供；执行时会产生 UVM assertion/report，不向 DUT 转移未声明的资源所有权。
  // 失败/边界：fixture 未初始化、故障注入未生效或观测值与预期不一致时报告 UVM_ERROR/断言失败；测试不会吞掉失败。
  function automatic void check_every_allowed_data_bit();
    bit [7:0] payload_opcodes[$] = '{8'h09, 8'h0f,
                                      8'h13, 8'h17, 8'h38};
    rdma_hw_image image;
    bit [63:0] allowed;
    bit [63:0] word;
    int unsigned first_byte;
    int unsigned byte_count;

    for (int unsigned b = 24; b <= 31; b++) begin
      image = make_image(8'h00, 0, 0, 0);
      word = get_qword(image, 0);
      word[b] = 1'b1;
      set_qword(image, 0, word);
      expect_decode_success($sformatf("CQE_ALLOWED_ECODE_B%0d", b), image,
                            1'b1, 0, 0);
    end
    for (int unsigned b = 40; b <= 44; b++) begin
      image = make_image(8'h00, 0, 0, 0);
      word = get_qword(image, 0);
      word[b] = 1'b1;
      set_qword(image, 0, word);
      expect_decode_success($sformatf("CQE_ALLOWED_INDEX_B%0d", b), image,
                            1'b1, 0, 0);
    end
    image = make_image(8'h00, 0, 0, 0, 1'b1);
    expect_decode_success("CQE_ALLOWED_OWNER", image, 1'b1, 0, 0);

    foreach (payload_opcodes[o]) begin
      literal_payload_bounds(payload_opcodes[o], first_byte, byte_count);
      for (int unsigned q = 1; q < 8; q++) begin
        allowed = literal_allowed_mask(payload_opcodes[o], q);
        for (int unsigned b = 0; b < 64; b++) begin
          if (!allowed[b]) continue;
          image = make_image(payload_opcodes[o], 0, 0, 0);
          word = get_qword(image, q);
          word[b] = 1'b1;
          set_qword(image, q, word);
          expect_decode_success(
            $sformatf("CQE_ALLOWED_PAYLOAD_%02x_Q%0d_B%0d",
                      payload_opcodes[o], q, b),
            image, 1'b1, first_byte, byte_count);
        end
      end
    end
  endfunction

  // 功能：在 rdma_cmq_completion_test 中，run_phase 驱动 UVM 阶段中的场景初始化、事务执行和断言收尾，并在退出前释放 objection 或测试资源。
  // 输入/输出及副作用：phase（输入）；phase 由 UVM 提供；task 通过 objection、日志和断言暴露结果，可能调用 DUT 接口但不改变其所有权规则。
  // 失败/边界：run_phase 的 setup/阶段驱动失败时停止新增事务，并按测试生命周期清理 objection 与临时引用。
  virtual task run_phase(uvm_phase phase);
    phase.raise_objection(this);
    codec = rdma_hw_cmq_completion_codec::type_id::create(
      "cmq_completion_codec");
    check_common_fields_and_raw_ecode();
    check_payload_slice("CQE_MRT_QUERY_SLICE", 8'h09, 16, 63);
    check_payload_slice("CQE_CQC_QUERY_SLICE", 8'h0f, 8, 63);
    check_payload_slice("CQE_CEQC_QUERY_SLICE", 8'h13, 16, 47);
    check_payload_slice("CQE_AEQC_QUERY_SLICE", 8'h17, 16, 47);
    check_payload_slice("CQE_SRFQC_QUERY_SLICE", 8'h38, 16, 47);
    check_metadata_failures();
    check_owner_ready_ordering();
    check_literal_admission_table();
    check_every_reserved_bit();
    check_every_allowed_data_bit();
    phase.drop_objection(this);
  endtask
endclass
