// 目录：测试层 unit/rdma_codec_registry_test.sv。
// 职责：验证 rdma_codec_registry_test 对应模块的接口、错误路径和边界行为。
// 依赖：依赖被测 package、UVM 测试基类和必要的 mock/fixture。
// 所有权与生命周期：测试对象只拥有本地 fixture；外部后端句柄由测试环境提供并在测试结束释放。

// 中文说明：rdma_codec_registry_test.sv 属于单元测试，覆盖对应模型、编码器或执行器契约。
// 阅读提示：先看公开类型和接口，再看实现细节；失败路径应保持状态与资源所有权可追踪。

class rdma_codec_registry_test_codec extends rdma_codec_base;
  rdma_byte_endian_e endian_value;

  // 功能：构造当前对象并初始化其字段、集合和 UVM 名称；不接管传入句柄的生命周期。
  // 输入/输出及副作用：name 仅用于 UVM 对象命名；内部字段被初始化为安全默认值，传入句柄不转移所有权。
  //   返回新对象实例；构造失败由 UVM 工厂或调用方处理。
  // 失败/边界：不创建外部资源；name 为空时仍允许构造，但所有字段必须保持可配置的初始值。
  function new(
    string name = "rdma_codec_registry_test_codec",
    rdma_byte_endian_e endian_value = RDMA_ENDIAN_LITTLE
  );
    super.new(name);
    this.endian_value = endian_value;
  endfunction

  // 功能：把输入模型字段按硬件布局编码到目标 image/缓冲区，并在写入前检查范围、重叠和保留位。
  // 输入/输出及副作用：参数 model, image 用于执行 encode；返回值或 output/inout 交付处理结果，必要时更新本对象状态。
  //   调用方不获得内部集合或外部依赖的所有权。
  // 失败/边界：镜像长度、字段宽度、保留位或写入范围非法时不修改已写入字节。
  virtual function rdma_status encode(
    rdma_hw_model model,
    output rdma_hw_image image
  );
    image = null;
    return rdma_status::success();
  endfunction

  // 功能：从硬件 image/缓冲区解码请求字段，验证布局和完整性后向调用方返回值或状态。
  // 输入/输出及副作用：参数 image, model 用于执行 decode；返回值或 output/inout 交付处理结果，必要时更新本对象状态。
  //   调用方不获得内部集合或外部依赖的所有权。
  // 失败/边界：镜像为空、长度不足或校验失败时不发布部分模型字段。
  virtual function rdma_status decode(
    rdma_hw_image image,
    output rdma_hw_model model
  );
    model = null;
    return rdma_status::success();
  endfunction

  // 功能：检查输入字段、身份和生命周期约束，返回可诊断的校验状态；失败时不提交部分更新。
  // 输入/输出及副作用：输入为待校验字段或快照；返回 rdma_status，校验过程不提交资源和游标。
  //   空依赖、非法范围、身份不一致或非活动状态会返回错误。
  // 失败/边界：任何非法枚举、越界字段、缺失必需依赖或身份/代际不一致都必须返回非成功状态。
  virtual function rdma_status validate_model(rdma_hw_model model);
    if (model == null)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "test model is null");
    return rdma_status::success();
  endfunction

  // 功能：检查输入字段、身份和生命周期约束，返回可诊断的校验状态；失败时不提交部分更新。
  // 输入/输出及副作用：输入为待校验字段或快照；返回 rdma_status，校验过程不提交资源和游标。
  //   空依赖、非法范围、身份不一致或非活动状态会返回错误。
  // 失败/边界：任何非法枚举、越界字段、缺失必需依赖或身份/代际不一致都必须返回非成功状态。
  virtual function rdma_status validate_image(rdma_hw_image image);
    if (image == null)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "test image is null");
    return rdma_status::success();
  endfunction

  // 功能：处理 hardware_endian：依据其参数完成所属层的具体协议动作，并保持返回状态、游标和资源所有权一致。
  // 输入/输出及副作用：参数 endian_value 用于执行 hardware_endian；返回值或 output/inout 交付处理结果，必要时更新本对象状态。
  //   调用方不获得内部集合或外部依赖的所有权。
  // 失败/边界：hardware_endian 只接受其签名声明的输入；缺少必要字段时返回错误，成功路径不得隐式修改无关资源。
  virtual function rdma_byte_endian_e hardware_endian();
    return endian_value;
  endfunction

  // 功能：将当前对象的类型、状态或关键标识转换为调用方可消费的值，不产生外部副作用。
  // 输入/输出及副作用：输入为当前对象状态；返回字符串、枚举或只读派生值，不修改对象。
  //   对象未配置时返回可识别的 UNKNOWN/UNCONFIGURED 表示。
  // 失败/边界：未配置或字段无效时返回明确的 UNKNOWN 表示，不读取未初始化句柄。
  virtual function string describe_fields();
    return "test-only codec";
  endfunction
endclass

class rdma_codec_duplicate_catcher extends uvm_report_catcher;
  bit duplicate_fatal_caught;

  // 功能：构造当前对象并初始化其字段、集合和 UVM 名称；不接管传入句柄的生命周期。
  // 输入/输出及副作用：name 仅用于 UVM 对象命名；内部字段被初始化为安全默认值，传入句柄不转移所有权。
  //   返回新对象实例；构造失败由 UVM 工厂或调用方处理。
  // 失败/边界：不创建外部资源；name 为空时仍允许构造，但所有字段必须保持可配置的初始值。
  function new(string name = "rdma_codec_duplicate_catcher");
    super.new(name);
    duplicate_fatal_caught = 1'b0;
  endfunction

  // 功能：控制 catch 对应的等待、异常或同步边界，按超时/捕获结果返回状态，不吞掉原始错误。
  // 输入/输出及副作用：参数 get_severity 用于执行 catch；返回值或 output/inout 交付处理结果，必要时更新本对象状态。
  //   调用方不获得内部集合或外部依赖的所有权。
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

  // 功能：构造当前对象并初始化其字段、集合和 UVM 名称；不接管传入句柄的生命周期。
  // 输入/输出及副作用：name 仅用于 UVM 对象命名；内部字段被初始化为安全默认值，传入句柄不转移所有权。
  //   返回新对象实例；构造失败由 UVM 工厂或调用方处理。
  // 失败/边界：不创建外部资源；name 为空时仍允许构造，但所有字段必须保持可配置的初始值。
  function new(string name = "rdma_codec_registry_test",
               uvm_component parent = null);
    super.new(name, parent);
  endfunction

  // 功能：在测试中检查调用结果、状态码和副作用是否符合契约；失败时报告可定位的验证信息。
  // 输入/输出及副作用：参数 check_name, status, expected_code 用于执行 expect_status；返回值或 output/inout 交付处理结果，必要时更新本对象状态。
  //   调用方不获得内部集合或外部依赖的所有权。
  // 失败/边界：测试前置对象缺失时应报告断言错误并停止依赖该对象的后续检查。
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

  // 功能：比较两个输入对象的协议字段或身份快照并返回确定的相等性结果，不修改任一输入。
  // 输入/输出及副作用：输入为待比较的两个值对象；返回 bit/状态结果，不修改任一输入或外部账本。
  //   任一对象为空、类型不符或字段未初始化时按接口约定返回不相等或错误。
  // 失败/边界：比较输入为空或类型不符时不得抛出未处理异常；结果必须保持确定且无副作用。
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

  // 功能：驱动 UVM 阶段中的场景初始化、事务执行和断言收尾，并在退出前释放 objection 或测试资源。
  // 输入/输出及副作用：phase 控制 UVM 调度；task 驱动事务、断言和 objection，测试 fixture 由本层负责清理。
  //   阶段提前结束或前置 setup 失败时必须释放 objection 并停止后续访问。
  // 失败/边界：setup 失败或阶段被终止时停止新增事务，确保 objection、临时对象和外部引用按测试生命周期收尾。
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
    k_rc = '{hw_version:"xtr_v1", image_kind:RDMA_IMAGE_QPC,
             object_type:"qpc", variant:"rc", opcode:8'h00};
    k_ud = '{hw_version:"xtr_v1", image_kind:RDMA_IMAGE_QPC,
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
        keys[0] != "xtr_v1|1|qpc|rc|00" ||
        keys[1] != "xtr_v1|1|qpc|ud|00")
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
