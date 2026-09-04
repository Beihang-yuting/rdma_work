// 目录：测试层 unit/rdma_codec_registry_test.sv。
// 职责：验证 rdma_codec_registry_test 对应模块的接口、错误路径和边界行为。
// 依赖：依赖被测 package、UVM 测试基类和必要的 mock/fixture。
// 所有权与生命周期：测试对象只拥有本地 fixture；外部后端句柄由测试环境提供并在测试结束释放。

// 中文说明：rdma_codec_registry_test.sv 属于单元测试，覆盖对应模型、编码器或执行器契约。
// 阅读提示：先看公开类型和接口，再看实现细节；失败路径应保持状态与资源所有权可追踪。

class rdma_codec_registry_test_codec extends rdma_codec_base;
  rdma_byte_endian_e endian_value;

  // 功能：构造 rdma_codec_registry_test_codec，调用 super.new 建立 UVM 对象，并把构造体直接写入的默认值设为：this.endian_value=endian_value。
  // 输入/输出及副作用：name、endian_value（输入）；new 只写入构造体列出的默认字段并返回 void，外部依赖与资源所有权仍由上层管理。
  // 失败/边界：rdma_codec_registry_test_codec 构造只建立本地初始状态，不接管外部 Host-memory、PCIe 或 manager；未完成后续 configure/build/activate 时，业务入口必须返回 INVALID_STATE。
  function new(
    string name = "rdma_codec_registry_test_codec",
    rdma_byte_endian_e endian_value = RDMA_ENDIAN_LITTLE
  );
    super.new(name);
    this.endian_value = endian_value;
  endfunction

  // 功能：在 rdma_codec_registry_test_codec 中，encode 按硬件布局把输入模型编码到 image/缓冲区，并在写入前检查范围、重叠、端序和保留位。
  // 输入/输出及副作用：model（输入）、image（输出）；输入模型只读；成功时通过返回值或 output 发布完整 image/bytes，不修改源模型。
  // 失败/边界：encode 遇到 image/model 为空、长度/对齐/保留位非法或 codec 校验失败时不发布部分字段。
  virtual function rdma_status encode(
    rdma_hw_model model,
    output rdma_hw_image image
  );
    image = null;
    return rdma_status::success();
  endfunction

  // 功能：在 rdma_codec_registry_test_codec 中，decode 从硬件 image/缓冲区解码字段，验证长度、布局和完整性后返回模型或状态。
  // 输入/输出及副作用：image（输入）、model（输出）；输入 image/bytes 只读；成功时通过返回值或 output 发布 detached 解码快照，不接管调用方缓冲区。
  // 失败/边界：decode 遇到 image/model 为空、长度/对齐/保留位非法或 codec 校验失败时不发布部分字段。
  virtual function rdma_status decode(
    rdma_hw_image image,
    output rdma_hw_model model
  );
    model = null;
    return rdma_status::success();
  endfunction

  // 功能：validate_model 校验 model 与当前对象状态的一致性，并显式处理“test model is null”等拒绝条件，返回 rdma_status 供上层决定是否提交。
  // 输入/输出及副作用：model（输入）；validate_model 读取 model 并使用字段 rdma_status；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：必需对象/句柄/快照为空，或身份、范围、generation 和生命周期检查失败时返回非成功状态。
  virtual function rdma_status validate_model(rdma_hw_model model);
    if (model == null)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "test model is null");
    return rdma_status::success();
  endfunction

  // 功能：validate_image 校验 image 与当前对象状态的一致性，并显式处理“test image is null”等拒绝条件，返回 rdma_status 供上层决定是否提交。
  // 输入/输出及副作用：image（输入）；validate_image 读取 image 并使用字段 rdma_status；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：必需对象/句柄/快照为空，或身份、范围、generation 和生命周期检查失败时返回非成功状态。
  virtual function rdma_status validate_image(rdma_hw_image image);
    if (image == null)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "test image is null");
    return rdma_status::success();
  endfunction

  // 功能：hardware_endian 使用 当前对象字段 计算并返回 rdma_byte_endian_e 结果；不修改对象字段或外部资源。
  // 输入/输出及副作用：无显式参数；hardware_endian 读取固定返回值或局部计算结果，不使用对象成员字段；函数返回 rdma_byte_endian_e，不取得调用方资源所有权。
  // 失败/边界：hardware_endian 是只读访问器，返回 endian_value；未覆盖枚举沿 default/类型默认分支返回，不改变对象和外部资源。
  virtual function rdma_byte_endian_e hardware_endian();
    return endian_value;
  endfunction

  // 功能：describe_fields 把 当前对象字段 与当前对象的身份/状态字段编码为稳定文本，供日志、查找或恢复索引使用。
  // 输入/输出及副作用：无显式参数；describe_fields 读取固定返回值或局部计算结果，不使用对象成员字段；函数返回 string，不取得调用方资源所有权。
  // 失败/边界：枚举未定义或对象未配置时返回 UNKNOWN/UNCONFIGURED 表示，同时保留数值上下文。
  virtual function string describe_fields();
    return "test-only codec";
  endfunction
endclass

class rdma_codec_duplicate_catcher extends uvm_report_catcher;
  bit duplicate_fatal_caught;

  // 功能：构造 rdma_codec_duplicate_catcher，调用 super.new 建立 UVM 对象，并把构造体直接写入的默认值设为：duplicate_fatal_caught=1'b0。
  // 输入/输出及副作用：name（输入）；new 只写入构造体列出的默认字段并返回 void，外部依赖与资源所有权仍由上层管理。
  // 失败/边界：rdma_codec_duplicate_catcher 构造只建立本地初始状态，不接管外部 Host-memory、PCIe 或 manager；未完成后续 configure/build/activate 时，业务入口必须返回 INVALID_STATE。
  function new(string name = "rdma_codec_duplicate_catcher");
    super.new(name);
    duplicate_fatal_caught = 1'b0;
  endfunction

  // 功能：在 rdma_codec_duplicate_catcher 中，catch 控制 catch 对应的等待、异常或同步边界，按超时/捕获结果返回状态，不吞掉原始错误。
  // 输入/输出及副作用：无显式参数；catch 读取 对象字段：duplicate_fatal_caught 并使用字段 duplicate_fatal_caught；函数返回 action_e，不取得调用方资源所有权。
  // 失败/边界：catch 超时或异常必须返回原始错误证据；不得无限等待或跳过同步边界。
  virtual function action_e catch();
    if (get_severity() == UVM_FATAL &&
        get_id() == "RDMA_CODEC_DUPLICATE") begin
      duplicate_fatal_caught = 1'b1;
      return CAUGHT;
    end
    return THROW;
  endfunction
endclass

class rdma_codec_registry_test extends uvm_test;
  `uvm_component_utils(rdma_codec_registry_test)

  // 功能：构造 rdma_codec_registry_test，调用 super.new 建立 UVM 层级对象；外部依赖字段保持未绑定，后续由 configure/build/activate 明确注入。
  // 输入/输出及副作用：name、parent（输入）；new 只写入构造体列出的默认字段并返回 void，外部依赖与资源所有权仍由上层管理。
  // 失败/边界：rdma_codec_registry_test 构造只建立本地初始状态，不接管外部 Host-memory、PCIe 或 manager；未完成后续 configure/build/activate 时，业务入口必须返回 INVALID_STATE。
  function new(string name = "rdma_codec_registry_test",
               uvm_component parent = null);
    super.new(name, parent);
  endfunction

  // 功能：在 rdma_codec_registry_test 中，expect_status 在测试中执行 expect_status 断言，比较输入结果与期望状态并报告可定位的失败信息。
  // 输入/输出及副作用：check_name（输入）、status（输入）、expected_code（输入）；fixture/输入由测试调用方提供；执行时会产生 UVM assertion/report，不向 DUT
  //   转移未声明的资源所有权。
  // 失败/边界：测试函数 expect_status 缺少前置对象时报告断言错误，并停止依赖该对象的后续检查。
  function automatic void expect_status(
    string check_name,
    rdma_status status,
    rdma_status_code_e expected_code
  );
    if (status == null) begin
      `uvm_error(check_name, "codec API returned a null status")
      return;
    end
    if (status.code != expected_code)
      `uvm_error(check_name,
                 $sformatf("expected %s, got %s (%s)",
                           expected_code.name(), status.code.name(),
                           status.convert2string()))
  endfunction

  // 功能：在 rdma_codec_registry_test 中由 bytes_equal 逐字段比较输入值，返回结构、身份或序列化内容是否一致。
  // 输入/输出及副作用：lhs（输入）、rhs（输入）；比较对象/数组只读；返回 bit 或状态结果，不更新 runtime、账本或外部 adapter。
  // 失败/边界：bytes_equal 的任一比较对象为空或类型不符时返回确定的 false/不等结果，不抛出未处理异常。
  function automatic bit bytes_equal(
    byte unsigned lhs[],
    byte unsigned rhs[]
  );
    if (lhs.size() != rhs.size())
      return 1'b0;
    foreach (lhs[i]) begin
      if (lhs[i] != rhs[i])
        return 1'b0;
    end
    return 1'b1;
  endfunction

  // 功能：在 rdma_codec_registry_test 中，run_phase 驱动 UVM 阶段中的场景初始化、事务执行和断言收尾，并在退出前释放 objection 或测试资源。
  // 输入/输出及副作用：phase（输入）；phase 由 UVM 提供；task 通过 objection、日志和断言暴露结果，可能调用 DUT 接口但不改变其所有权规则。
  // 失败/边界：run_phase 的 setup/阶段驱动失败时停止新增事务，并按测试生命周期清理 objection 与临时引用。
  task run_phase(uvm_phase phase);
    rdma_codec_registry registry;
    rdma_codec_registry_test_codec rc_codec;
    rdma_codec_registry_test_codec second_codec;
    rdma_codec_base found_codec;
    rdma_codec_key k_rc;
    rdma_codec_key k_ud;
    rdma_codec_key miss_key;
    rdma_codec_key invalid_key;
    rdma_codec_duplicate_catcher duplicate_catcher;
    rdma_bit_packer packer;
    rdma_status status;
    string keys[$];
    byte unsigned bytes[];
    byte unsigned snapshot[];
    byte unsigned short_bytes[];
    byte unsigned long_bytes[];
    bit [63:0] value;

    phase.raise_objection(this);

    registry = new("registry");
    rc_codec = new("rc_codec", RDMA_ENDIAN_LITTLE);
    second_codec = new("second_codec", RDMA_ENDIAN_BIG);
    k_rc = '{hw_version:"rdma", image_kind:RDMA_IMAGE_QPC,
             object_type:"qpc", variant:"rc", opcode:8'h00};
    k_ud = '{hw_version:"rdma", image_kind:RDMA_IMAGE_QPC,
             object_type:"qpc", variant:"ud", opcode:8'h00};

    if (rc_codec.hardware_endian() != RDMA_ENDIAN_LITTLE ||
        second_codec.hardware_endian() != RDMA_ENDIAN_BIG)
      `uvm_error("CODEC_ENDIAN", "codec endian declaration was not retained")

    status = registry.register_codec(k_rc, rc_codec);
    expect_status("REG_REGISTER", status, RDMA_SC_OK);
    status = registry.lookup(k_rc, found_codec);
    expect_status("REG_LOOKUP", status, RDMA_SC_OK);
    if (found_codec != rc_codec)
      `uvm_error("REG_LOOKUP", "lookup did not return the registered codec")

    // Every key component participates in lookup identity.
    miss_key = k_rc;
    miss_key.hw_version = "xtr_v2";
    status = registry.lookup(miss_key, found_codec);
    expect_status("REG_HW_VERSION_ISOLATION", status,
                  RDMA_SC_UNSUPPORTED_OPCODE);
    if (found_codec != null)
      `uvm_error("REG_HW_VERSION_ISOLATION", "miss returned a codec")

    miss_key = k_rc;
    miss_key.image_kind = RDMA_IMAGE_CQC;
    status = registry.lookup(miss_key, found_codec);
    expect_status("REG_IMAGE_KIND_ISOLATION", status,
                  RDMA_SC_UNSUPPORTED_OPCODE);

    miss_key = k_rc;
    miss_key.object_type = "cqc";
    status = registry.lookup(miss_key, found_codec);
    expect_status("REG_OBJECT_TYPE_ISOLATION", status,
                  RDMA_SC_UNSUPPORTED_OPCODE);

    status = registry.lookup(k_ud, found_codec);
    expect_status("REG_RC_UD_ISOLATION", status,
                  RDMA_SC_UNSUPPORTED_OPCODE);
    if (found_codec != null)
      `uvm_error("REG_RC_UD_ISOLATION", "RC codec leaked into UD lookup")

    miss_key = k_rc;
    miss_key.opcode = 8'h01;
    status = registry.lookup(miss_key, found_codec);
    expect_status("REG_OPCODE_ISOLATION", status,
                  RDMA_SC_UNSUPPORTED_OPCODE);

    status = registry.register_codec(k_ud, second_codec);
    expect_status("REG_REGISTER_UD", status, RDMA_SC_OK);
    registry.list_keys(keys);
    if (keys.size() != 2 ||
        keys[0] != "rdma|1|qpc|rc|00" ||
        keys[1] != "rdma|1|qpc|ud|00")
      `uvm_error("REG_KEYS",
                 $sformatf("unexpected canonical key list size=%0d", keys.size()))

    // A duplicate is a fatal structural error.  The catcher proves the fatal
    // occurred while allowing this negative unit test to keep a clean summary.
    duplicate_catcher = new("duplicate_catcher");
    uvm_report_cb::add(null, duplicate_catcher);
    status = registry.register_codec(k_rc, second_codec);
    uvm_report_cb::delete(null, duplicate_catcher);
    if (!duplicate_catcher.duplicate_fatal_caught)
      `uvm_error("REG_DUPLICATE", "duplicate registration did not issue fatal")
    expect_status("REG_DUPLICATE", status, RDMA_SC_INVALID_STATE);
    status = registry.lookup(k_rc, found_codec);
    expect_status("REG_DUPLICATE_ORIGINAL", status, RDMA_SC_OK);
    if (found_codec != rc_codec)
      `uvm_error("REG_DUPLICATE_ORIGINAL", "duplicate replaced original codec")

    invalid_key = k_rc;
    invalid_key.hw_version = "";
    status = registry.register_codec(invalid_key, rc_codec);
    expect_status("REG_EMPTY_HW", status, RDMA_SC_INVALID_ARGUMENT);
    invalid_key = k_rc;
    invalid_key.object_type = "";
    status = registry.lookup(invalid_key, found_codec);
    expect_status("REG_EMPTY_OBJECT", status, RDMA_SC_INVALID_ARGUMENT);
    invalid_key = k_rc;
    invalid_key.variant = "";
    status = registry.register_codec(invalid_key, rc_codec);
    expect_status("REG_EMPTY_VARIANT", status, RDMA_SC_INVALID_ARGUMENT);
    invalid_key = k_rc;
    invalid_key.image_kind = RDMA_IMAGE_NONE;
    status = registry.register_codec(invalid_key, rc_codec);
    expect_status("REG_NONE_IMAGE", status, RDMA_SC_INVALID_ARGUMENT);
    invalid_key = k_rc;
    invalid_key.variant = "r|c";
    status = registry.register_codec(invalid_key, rc_codec);
    expect_status("REG_DELIMITER", status, RDMA_SC_INVALID_ARGUMENT);
    status = registry.register_codec(k_rc, null);
    expect_status("REG_NULL_CODEC", status, RDMA_SC_INVALID_ARGUMENT);

    registry.clear();
    registry.list_keys(keys);
    if (keys.size() != 0)
      `uvm_error("REG_CLEAR", "clear retained canonical keys")
    status = registry.lookup(k_rc, found_codec);
    expect_status("REG_CLEAR_LOOKUP", status, RDMA_SC_UNSUPPORTED_OPCODE);
    status = registry.register_codec(k_rc, second_codec);
    expect_status("REG_REREGISTER", status, RDMA_SC_OK);

    packer = new("packer");
    status = packer.initialize(8);
    expect_status("PACK_INITIALIZE", status, RDMA_SC_OK);
    bytes = new[8];
    foreach (bytes[i])
      bytes[i] = 8'h00;

    status = packer.put_u64(bytes, 5, 20, 64'h0000_0000_000a_bcde);
    expect_status("PACK_CROSS_BYTE", status, RDMA_SC_OK);
    if (bytes[0] != 8'hc0 || bytes[1] != 8'h9b ||
        bytes[2] != 8'h57 || bytes[3] != 8'h01)
      `uvm_error("PACK_LAYOUT", "byte0/bit0 low-address layout mismatch")
    status = packer.get_u64(bytes, 5, 20, value);
    expect_status("PACK_GET", status, RDMA_SC_OK);
    if (value != 64'h0000_0000_000a_bcde)
      `uvm_error("PACK_ROUNDTRIP", $sformatf("got 0x%016x", value))

    snapshot = bytes;
    status = packer.put_u64(bytes, 62, 4, 64'hf);
    expect_status("PACK_BOUNDS", status, RDMA_SC_CODEC_ERROR);
    if (!bytes_equal(bytes, snapshot))
      `uvm_error("PACK_BOUNDS", "out-of-range put partially modified image")
    status = packer.put_u64(bytes, 0, 4, 64'h10);
    expect_status("PACK_VALUE_WIDTH", status, RDMA_SC_CODEC_ERROR);
    if (!bytes_equal(bytes, snapshot))
      `uvm_error("PACK_VALUE_WIDTH", "wide value partially modified image")
    status = packer.put_u64(bytes, 0, 0, 64'h0);
    expect_status("PACK_ZERO_WIDTH", status, RDMA_SC_CODEC_ERROR);
    status = packer.put_u64(bytes, 0, 65, 64'h0);
    expect_status("PACK_WIDTH_65", status, RDMA_SC_CODEC_ERROR);
    status = packer.put_u64(bytes, 64'hffff_ffff_ffff_fffe, 4, 64'h0);
    expect_status("PACK_OFFSET_OVERFLOW", status, RDMA_SC_CODEC_ERROR);

    short_bytes = new[7];
    foreach (short_bytes[i])
      short_bytes[i] = 8'h5a;
    snapshot = short_bytes;
    status = packer.put_u64(short_bytes, 0, 1, 64'h1);
    expect_status("PACK_SHORT_IMAGE", status, RDMA_SC_CODEC_ERROR);
    if (!bytes_equal(short_bytes, snapshot))
      `uvm_error("PACK_SHORT_IMAGE", "length failure modified image")
    status = packer.get_u64(short_bytes, 0, 1, value);
    expect_status("GET_SHORT_IMAGE", status, RDMA_SC_CODEC_ERROR);
    long_bytes = new[9];
    status = packer.get_u64(long_bytes, 0, 1, value);
    expect_status("GET_LONG_IMAGE", status, RDMA_SC_CODEC_ERROR);

    // The failed overlapping write spans occupied and unoccupied bits.  A
    // following adjacent write proves the rejected call changed no occupancy.
    status = packer.reset(8);
    expect_status("PACK_RESET", status, RDMA_SC_OK);
    foreach (bytes[i])
      bytes[i] = 8'h00;
    status = packer.put_u64(bytes, 8, 8, 64'h00);
    expect_status("PACK_ZERO_FIELD", status, RDMA_SC_OK);
    snapshot = bytes;
    status = packer.put_u64(bytes, 12, 8, 64'hff);
    expect_status("PACK_OVERLAP", status, RDMA_SC_CODEC_ERROR);
    if (!bytes_equal(bytes, snapshot))
      `uvm_error("PACK_OVERLAP", "overlap failure partially modified image")
    status = packer.put_u64(bytes, 16, 4, 64'hf);
    expect_status("PACK_OCCUPANCY_ROLLBACK", status, RDMA_SC_OK);
    status = packer.reset(8);
    expect_status("PACK_RESET_CLEAR", status, RDMA_SC_OK);
    status = packer.put_u64(bytes, 8, 8, 64'haa);
    expect_status("PACK_RESET_REUSE", status, RDMA_SC_OK);

    phase.drop_objection(this);
  endtask
endclass
