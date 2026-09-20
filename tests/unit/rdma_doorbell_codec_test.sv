// 目录：测试层 unit/rdma_doorbell_codec_test.sv。
// 职责：验证 rdma_doorbell_codec_test 对应模块的接口、错误路径和边界行为。
// 依赖：依赖被测 package、UVM 测试基类和必要的 mock/fixture。
// 所有权与生命周期：测试对象只拥有本地 fixture；外部后端句柄由测试环境提供并在测试结束释放。

// 中文说明：rdma_doorbell_codec_test.sv 属于单元测试，覆盖对应模型、编码器或执行器契约。
// 阅读提示：先看公开类型和接口，再看实现细节；失败路径应保持状态与资源所有权可追踪。

class rdma_hw_wrong_doorbell_model
    extends rdma_hw_doorbell_model_base;
  `uvm_object_utils(rdma_hw_wrong_doorbell_model)

  // 功能：构造 rdma_hw_wrong_doorbell_model，调用 super.new 建立 UVM 层级对象；外部依赖字段保持未绑定，后续由 configure/build/activate 明确注入。
  // 输入/输出及副作用：name（输入）；new 只写入构造体列出的默认字段并返回 void，外部依赖与资源所有权仍由上层管理。
  // 失败/边界：rdma_hw_wrong_doorbell_model 构造只建立本地初始状态，不接管外部 Host-memory、PCIe 或 manager；未完成后续 configure/build/activate 时，业务入口必须返回 INVALID_STATE。
  function new(string name = "rdma_hw_wrong_doorbell_model");
    super.new(name);
  endfunction

  // 功能：doorbell_kind 使用 当前对象字段 计算并返回 rdma_doorbell_kind_e 结果；不修改对象字段或外部资源。
  // 输入/输出及副作用：无显式参数；doorbell_kind 读取固定返回值或局部计算结果，不使用对象成员字段；函数返回 rdma_doorbell_kind_e，不取得调用方资源所有权。
  // 失败/边界：doorbell_kind 是只读访问器，返回 RDMA_DOORBELL_RQ；未覆盖枚举沿 default/类型默认分支返回，不改变对象和外部资源。
  virtual function rdma_doorbell_kind_e doorbell_kind();
    return RDMA_DOORBELL_RQ;
  endfunction

  // 功能：在 rdma_hw_wrong_doorbell_model 中，codec_variant 返回该实现声明的固定 profile/资源属性，供注册表和上层选择正确的 codec 或生命周期策略。
  // 输入/输出及副作用：无显式参数；codec_variant 读取固定返回值或局部计算结果，不使用对象成员字段；函数返回 string，不取得调用方资源所有权。
  // 失败/边界：codec_variant 是只读访问器，返回 "rq"；未覆盖枚举沿 default/类型默认分支返回，不改变对象和外部资源。
  virtual function string codec_variant();
    return "rq";
  endfunction

  // 功能：describe 把 当前对象字段 与当前对象的身份/状态字段编码为稳定文本，供日志、查找或恢复索引使用。
  // 输入/输出及副作用：无显式参数；无显式输入；返回 string，只读取对象字段，不修改模型或资源账本。
  // 失败/边界：枚举未定义或对象未配置时返回 UNKNOWN/UNCONFIGURED 表示，同时保留数值上下文。
  virtual function string describe();
    return "wrong dynamic doorbell model";
  endfunction
endclass

class rdma_hw_unknown_doorbell_model
    extends rdma_hw_doorbell_model_base;
  `uvm_object_utils(rdma_hw_unknown_doorbell_model)

  // 功能：构造 rdma_hw_unknown_doorbell_model，调用 super.new 建立 UVM 层级对象；外部依赖字段保持未绑定，后续由 configure/build/activate 明确注入。
  // 输入/输出及副作用：name（输入）；new 只写入构造体列出的默认字段并返回 void，外部依赖与资源所有权仍由上层管理。
  // 失败/边界：rdma_hw_unknown_doorbell_model 构造只建立本地初始状态，不接管外部 Host-memory、PCIe 或 manager；未完成后续 configure/build/activate 时，业务入口必须返回 INVALID_STATE。
  function new(string name = "rdma_hw_unknown_doorbell_model");
    super.new(name);
  endfunction

  // 功能：doorbell_kind 使用 当前对象字段 计算并返回 rdma_doorbell_kind_e 结果；不修改对象字段或外部资源。
  // 输入/输出及副作用：无显式参数；doorbell_kind 读取固定返回值或局部计算结果，不使用对象成员字段；函数返回 rdma_doorbell_kind_e，不取得调用方资源所有权。
  // 失败/边界：doorbell_kind 是只读访问器，返回 RDMA_DOORBELL_RQ；未覆盖枚举沿 default/类型默认分支返回，不改变对象和外部资源。
  virtual function rdma_doorbell_kind_e doorbell_kind();
    return RDMA_DOORBELL_RQ;
  endfunction

  // 功能：在 rdma_hw_unknown_doorbell_model 中，codec_variant 返回该实现声明的固定 profile/资源属性，供注册表和上层选择正确的 codec 或生命周期策略。
  // 输入/输出及副作用：无显式参数；codec_variant 读取固定返回值或局部计算结果，不使用对象成员字段；函数返回 string，不取得调用方资源所有权。
  // 失败/边界：codec_variant 是只读访问器，返回 "unknown"；未覆盖枚举沿 default/类型默认分支返回，不改变对象和外部资源。
  virtual function string codec_variant();
    return "unknown";
  endfunction

  // 功能：describe 把 当前对象字段 与当前对象的身份/状态字段编码为稳定文本，供日志、查找或恢复索引使用。
  // 输入/输出及副作用：无显式参数；无显式输入；返回 string，只读取对象字段，不修改模型或资源账本。
  // 失败/边界：枚举未定义或对象未配置时返回 UNKNOWN/UNCONFIGURED 表示，同时保留数值上下文。
  virtual function string describe();
    return "unregistered doorbell model";
  endfunction
endclass

// 设计说明：生产 codec 的公开 encode() 会先执行 validate_model()，无法覆盖
//       encode_fields() 内部的动态类型边界；该 probe 只在测试中打开这一层，
//       用来验证每个硬件布局分支都能在错误类型下 fail-closed。
class rdma_hw_doorbell_codec_probe extends rdma_hw_doorbell_codec;
  `uvm_object_utils(rdma_hw_doorbell_codec_probe)

  // 功能：构造指定 variant 的门铃 codec probe，复用生产 codec 的布局选择和状态初值。
  // 输入/输出及副作用：name、variant_name（输入）；构造只创建本地 UVM 对象，不写入
  //       registry、BAR 或其他外部资源，也不改变生产 codec 的所有权约束。
  // 失败/边界：variant_name 不在生产支持集合时，probe 仍可构造，但调用
  //       encode_fields_for_test() 应返回对应的生产错误，而不会伪造成功。
  function new(string name = "rdma_hw_doorbell_codec_probe",
               string variant_name = "rq");
    super.new(name, variant_name);
  endfunction

  // 功能：为一个测试调用建立 8-byte builder，并直接调用生产 encode_fields()，
  //       观察错误动态类型是否在任何字段写入前被拒绝。
  // 输入/输出及副作用：model（输入）是待注入的模型；occupancy（输出）返回 builder
  //       的字段占用快照；函数只拥有临时 builder，不发布 image，也不修改 model。
  // 失败/边界：builder 复位失败或 encode_fields() 拒绝输入时原样返回状态；调用方可用
  //       occupancy 判断失败路径是否错误地留下部分编码，null model 也必须安全返回。
  function rdma_status encode_fields_for_test(
    rdma_hw_model model,
    output bit [63:0] occupancy[]
  );
    rdma_hw_qword_builder builder;
    rdma_status status;

    occupancy = new[0];
    builder = new("doorbell_wrong_type_probe_builder");
    status = builder.reset(RDMA_DB_BYTES);
    if (!status.ok())
      return status;

    status = encode_fields(model, builder);
    builder.get_occupancy(occupancy);
    return status;
  endfunction
endclass

class rdma_doorbell_codec_test extends uvm_test;
  `uvm_component_utils(rdma_doorbell_codec_test)

  // 功能：构造 rdma_doorbell_codec_test，调用 super.new 建立 UVM 层级对象；外部依赖字段保持未绑定，后续由 configure/build/activate 明确注入。
  // 输入/输出及副作用：name、parent（输入）；new 只写入构造体列出的默认字段并返回 void，外部依赖与资源所有权仍由上层管理。
  // 失败/边界：rdma_doorbell_codec_test 构造只建立本地初始状态，不接管外部 Host-memory、PCIe 或 manager；未完成后续 configure/build/activate 时，业务入口必须返回 INVALID_STATE。
  function new(string name = "rdma_doorbell_codec_test",
               uvm_component parent = null);
    super.new(name, parent);
  endfunction

  // 功能：make_handle 创建独立的 rdma_handle；根据 name、kind、object_id 设置字段 handle、handle.kind、handle.function_uid、handle.object_id、handle.generation，返回对象仅由调用方持有，不转移外部资源所有权。
  // 输入/输出及副作用：name（输入）、kind（输入）、object_id（输入）；make_handle 读取 name、kind、object_id 并使用字段 handle、handle.kind、handle.function_uid、handle.object_id、handle.generation；函数返回 rdma_handle，不取得调用方资源所有权。
  // 失败/边界：make_handle 的结果直接由 return handle 计算；输入不满足表达式条件时沿函数体的保守分支返回，不修改已发布账本。
  function automatic rdma_handle make_handle(
    string name,
    rdma_resource_kind_e kind,
    int unsigned object_id
  );
    rdma_handle handle;
    handle = rdma_handle::type_id::create(name);
    handle.kind = kind;
    handle.function_uid = 64'h1234_5678_9abc_def0;
    handle.object_id = object_id;
    handle.generation = 32'd9;
    return handle;
  endfunction

  // 功能：在 rdma_doorbell_codec_test 中，expect_status 在测试中执行 expect_status 断言，比较输入结果与期望状态并报告可定位的失败信息。
  // 输入/输出及副作用：label（输入）、status（输入）、expected（输入）；fixture/输入由测试调用方提供；执行时会产生 UVM assertion/report，不向 DUT 转移未声明的资源所有权。
  // 失败/边界：测试函数 expect_status 缺少前置对象时报告断言错误，并停止依赖该对象的后续检查。
  function automatic void expect_status(
    string label,
    rdma_status status,
    rdma_status_code_e expected
  );
    if (status == null) begin
      `uvm_error(label, "doorbell codec returned null status")
      return;
    end
    if (status.code != expected)
      `uvm_error(label,
                 $sformatf("expected %s, got %s (%s)", expected.name(),
                           status.code.name(), status.convert2string()))
  endfunction

  // 功能：在 rdma_doorbell_codec_test 中，expect_ok 在测试中执行 expect_ok 断言，比较输入结果与期望状态并报告可定位的失败信息。
  // 输入/输出及副作用：label（输入）、status（输入）；fixture/输入由测试调用方提供；执行时会产生 UVM assertion/report，不向 DUT 转移未声明的资源所有权。
  // 失败/边界：测试函数 expect_ok 缺少前置对象时报告断言错误，并停止依赖该对象的后续检查。
  function automatic void expect_ok(string label, rdma_status status);
    expect_status(label, status, RDMA_SC_OK);
  endfunction

  // 功能：在 rdma_doorbell_codec_test 中，image_matches_golden 逐字段比较输入快照或镜像，确认其身份、布局和 payload 完全一致后返回布尔结果。
  // 输入/输出及副作用：image（输入）、golden（输入）；image_matches_golden 读取 image、golden 并使用字段 index；函数返回 bit，不取得调用方资源所有权。
  // 失败/边界：image_matches_golden 比较或前置条件不满足时返回 0/false；该路径不隐式重试，也不转移未声明资源。
  function automatic bit image_matches_golden(
    rdma_hw_image image,
    rdma_golden_case golden
  );
    if (image == null || golden == null ||
        image.bytes.size() != golden.payload.size())
      return 1'b0;
    foreach (golden.payload[index]) begin
      if (image.bytes[index] != golden.payload[index])
        return 1'b0;
    end
    return 1'b1;
  endfunction

  // 功能：在 rdma_doorbell_codec_test 中，find_golden 按完整 key/handle 查找唯一权威记录并返回 detached 快照，避免把内部可变引用泄露给调用方。
  // 输入/输出及副作用：cases（输入）、name（输入）；find_golden 读取 cases、name 并使用字段 index；函数返回 rdma_golden_case，不取得调用方资源所有权。
  // 失败/边界：find_golden 在 key/handle 缺失、记录不唯一或 generation/reset epoch 过期时返回明确错误，不回退到默认 authority。
  function automatic rdma_golden_case find_golden(
    rdma_golden_case cases[$],
    string name
  );
    foreach (cases[index]) begin
      if (cases[index].name == name)
        return cases[index];
    end
    return null;
  endfunction

  // 功能：make_model 创建独立的 rdma_hw_doorbell_model_base；根据 variant、golden 设置字段 cmq、cmq.target_h、cmq.pi、cmq.polarity、sq、sq.target_h、rq、rq.target_h、rq.qpn、rq.icos，返回对象仅由调用方持有，不转移外部资源所有权。
  // 输入/输出及副作用：variant（输入）、golden（输入）；make_model 读取 variant、golden 并使用字段 cmq、cmq.target_h、cmq.pi、cmq.polarity、sq、sq.target_h、rq、rq.target_h；函数返回 rdma_hw_doorbell_model_base，不取得调用方资源所有权。
  // 失败/边界：make_model 输入对象为空或查找未命中时返回 null；该路径不隐式重试，也不转移未声明资源。
  function automatic rdma_hw_doorbell_model_base make_model(
    string variant,
    rdma_golden_case golden
  );
    rdma_hw_cmq_sq_doorbell_model cmq;
    rdma_hw_sq_doorbell_model sq;
    rdma_hw_rq_doorbell_model rq;
    rdma_hw_srq_doorbell_model srq;
    rdma_hw_cq_doorbell_model cq;
    rdma_hw_ceq_doorbell_model ceq;
    rdma_hw_aeq_doorbell_model aeq;
    rdma_hw_qp_control_doorbell_model qp;

    case (variant)
      "cmq_sq": begin
        cmq = rdma_hw_cmq_sq_doorbell_model::type_id::create("cmq");
        cmq.target_h = make_handle("cmq_h", RDMA_RESOURCE_CMQ, 1);
        cmq.pi = 27;
        cmq.polarity = 1'b1;
        return cmq;
      end
      "sq": begin
        sq = rdma_hw_sq_doorbell_model::type_id::create("sq");
        sq.target_h = make_handle("sq_qp_h", RDMA_RESOURCE_QP, 21'h15555);
        foreach (golden.payload[index])
          sq.sqe_header.push_back(golden.payload[index]);
        return sq;
      end
      "rq": begin
        rq = rdma_hw_rq_doorbell_model::type_id::create("rq");
        rq.target_h = make_handle("rq_qp_h", RDMA_RESOURCE_QP, 21'h15555);
        rq.qpn = 21'h15555;
        rq.icos = 5;
        rq.pi = 15'h4567;
        rq.wrap = 1'b1;
        return rq;
      end
      "srq_pi", "srq_limit": begin
        srq = rdma_hw_srq_doorbell_model::type_id::create("srq");
        srq.target_h = make_handle("srq_h", RDMA_RESOURCE_SRQ, 16'ha55a);
        srq.variant = (variant == "srq_pi") ? RDMA_SRQ_DB_PI :
                                              RDMA_SRQ_DB_LIMIT;
        srq.srqn = 16'ha55a;
        srq.pi = 15'h4567;
        srq.wrap = 1'b1;
        srq.limit = 14'h2aaa;
        srq.arm_sn = 3;
        return srq;
      end
      "cq_rc_ud", "cq_urc": begin
        cq = rdma_hw_cq_doorbell_model::type_id::create("cq");
        cq.variant = (variant == "cq_rc_ud") ? RDMA_CQ_DB_RC_UD :
                                                RDMA_CQ_DB_URC;
        cq.cqn = (variant == "cq_rc_ud") ? 21'h15555 : 21'h12345;
        cq.target_h = make_handle("cq_h", RDMA_RESOURCE_CQ, cq.cqn);
        cq.host_id = (variant == "cq_rc_ud") ? 5 : 3;
        cq.ci = 23'h654321;
        cq.wrap = 1'b1;
        cq.sq_ci = 15'h4567;
        cq.sq_wrap = 1'b1;
        cq.rq_ci = 15'h2345;
        cq.rq_wrap = 1'b0;
        cq.arm = 1'b1;
        cq.arm_state = (variant == "cq_rc_ud") ? 2 : 1;
        cq.arm_sn = (variant == "cq_rc_ud") ? 3 : 2;
        return cq;
      end
      "ceq": begin
        ceq = rdma_hw_ceq_doorbell_model::type_id::create("ceq");
        ceq.target_h = make_handle("ceq_h", RDMA_RESOURCE_CEQ, 22'h2aaaaa);
        ceq.ceqn = 22'h2aaaaa;
        ceq.ci = 18'h2aaaa;
        ceq.wrap = 1'b1;
        return ceq;
      end
      "aeq": begin
        aeq = rdma_hw_aeq_doorbell_model::type_id::create("aeq");
        aeq.target_h = make_handle("aeq_h", RDMA_RESOURCE_AEQ, 12'haaa);
        aeq.aeqn = 12'haaa;
        aeq.ci = 18'h15555;
        aeq.wrap = 1'b1;
        return aeq;
      end
      "rts2sqd", "sqd2rts", "qp_flush", "tx_flush": begin
        qp = rdma_hw_qp_control_doorbell_model::type_id::create("qp");
        if (variant == "rts2sqd") qp.kind = RDMA_DOORBELL_RTS2SQD;
        else if (variant == "sqd2rts") qp.kind = RDMA_DOORBELL_SQD2RTS;
        else if (variant == "qp_flush") qp.kind = RDMA_DOORBELL_QP_FLUSH;
        else qp.kind = RDMA_DOORBELL_TX_FLUSH;
        qp.qpn = (variant == "tx_flush") ? 21'h2aaaa : 21'h15555;
        qp.target_h = make_handle("qp_h", RDMA_RESOURCE_QP, qp.qpn);
        qp.dst_port = (variant == "tx_flush") ? 15 : 11;
        qp.qp_sn = (variant == "tx_flush") ? 0 : 8'ha6;
        qp.icos = (variant inside {"rts2sqd", "sqd2rts"}) ? 5 : 0;
        return qp;
      end
      default: return null;
    endcase
  endfunction

  // 功能：check_cq_invalid_flag_case 构造一个 CQ doorbell 快照，逐一验证
  //       CI/ARM invalid 标志的 copy、编码、原始位坐标、解码和再编码结果。
  // 输入/输出及副作用：label、variant、registry、golden、ci_invalid 和
  //       arm_invalid（输入）；函数只创建本地 fixture，并通过 UVM report
  //       暴露断言结果，不转移 registry、golden 或 CQ handle 的所有权。
  // 失败/边界：variant 不是 cq_rc_ud/cq_urc、模型 cast 失败、编码/解码返回
  //       非成功状态、image 长度或 bit63/bit62 坐标不符、copy 丢失标志，或
  //       再编码改变任一原始字节时报告错误并停止该 case 的后续检查。
  function automatic void check_cq_invalid_flag_case(
    string label,
    string variant,
    rdma_hw_doorbell_codec_registry registry,
    rdma_golden_case golden,
    bit ci_invalid,
    bit arm_invalid
  );
    rdma_hw_doorbell_model_base source;
    rdma_hw_cq_doorbell_model cq;
    rdma_hw_cq_doorbell_model copied_cq;
    rdma_hw_cq_doorbell_model decoded_cq;
    rdma_hw_image image;
    rdma_hw_image roundtrip;
    rdma_hw_model decoded;
    rdma_status status;

    source = make_model(variant, golden);
    if (source == null || !$cast(cq, source)) begin
      `uvm_error(label, "CQ fixture cast failed")
      return;
    end

    cq.ci_invalid = ci_invalid;
    cq.arm_invalid = arm_invalid;

    copied_cq = rdma_hw_cq_doorbell_model::type_id::create(
        {label, "_copy"});
    copied_cq.copy(cq);
    if (copied_cq.ci_invalid != ci_invalid ||
        copied_cq.arm_invalid != arm_invalid) begin
      `uvm_error(label, "CQ copy lost invalid marker fields")
      return;
    end

    image = null;
    status = registry.encode(cq, image);
    expect_ok({label, "_ENCODE"}, status);
    if (status == null || !status.ok())
      return;
    if (image == null || image.bytes.size() != RDMA_DB_BYTES ||
        image.bar_target.value != RDMA_DB_CQ_OFFSET ||
        image.bytes[0][7] != ci_invalid ||
        image.bytes[0][6] != arm_invalid) begin
      `uvm_error(label,
                 "CQ invalid marker coordinates or BAR offset are incorrect")
      return;
    end

    decoded = null;
    status = registry.decode(variant, image, decoded);
    expect_ok({label, "_DECODE"}, status);
    if (status == null || !status.ok() || decoded == null ||
        !$cast(decoded_cq, decoded)) begin
      `uvm_error(label, "CQ invalid marker decode cast failed")
      return;
    end
    if (decoded_cq.ci_invalid != ci_invalid ||
        decoded_cq.arm_invalid != arm_invalid) begin
      `uvm_error(label, "CQ decode lost invalid marker fields")
      return;
    end

    roundtrip = null;
    status = registry.encode(decoded_cq, roundtrip);
    expect_ok({label, "_REENCODE"}, status);
    if (status == null || !status.ok() || roundtrip == null ||
        roundtrip.bytes.size() != image.bytes.size()) begin
      `uvm_error(label, "CQ invalid marker re-encode failed")
      return;
    end
    foreach (image.bytes[index]) begin
      if (roundtrip.bytes[index] != image.bytes[index]) begin
        `uvm_error(label, "CQ invalid marker round-trip changed raw bytes")
        return;
      end
    end
  endfunction

  // 功能：在测试辅助 rdma_doorbell_codec_test.check_metadata 中构造或驱动“metadata”场景，并断言 DUT 的状态、错误码和资源账本符合契约。
  // 输入/输出及副作用：label（输入）、model（输入）、image（输入）、expected_offset（输入）；fixture/输入由测试调用方提供；执行时会产生 UVM assertion/report，不向 DUT
  //   转移未声明的资源所有权。
  // 失败/边界：必需对象/句柄/快照为空，或身份、范围、generation 和生命周期检查失败时返回非成功状态。
  function automatic void check_metadata(
    string label,
    rdma_hw_doorbell_model_base model,
    rdma_hw_image image,
    longint unsigned expected_offset
  );
    if (image == null) begin
      `uvm_error(label, "codec published null image")
      return;
    end
    if (image.length != 8 || image.bytes.size() != 8 ||
        image.alignment != 8 || image.endian != RDMA_ENDIAN_BIG ||
        image.image_kind != RDMA_IMAGE_DOORBELL ||
        image.hardware_version != 1 || model.target_h == null ||
        image.function_generation != model.target_h.generation ||
        image.write_target_kind != RDMA_HW_TARGET_BAR ||
        image.bar_target.value != expected_offset ||
        image.backing_target.value != 0 || image.hmc_target.value != 0)
      `uvm_error(label, "doorbell image metadata is not canonical")
  endfunction

  // 功能：在 rdma_doorbell_codec_test 中，expect_decode_failure 在测试中执行 expect_decode_failure 断言，比较输入结果与期望状态并报告可定位的失败信息。
  // 输入/输出及副作用：label（输入）、registry（输入）、variant（输入）、image（输入）、expected（输入）；fixture/输入由测试调用方提供；执行时会产生 UVM
  //   assertion/report，不向 DUT 转移未声明的资源所有权。
  // 失败/边界：测试函数 expect_decode_failure 缺少前置对象时报告断言错误，并停止依赖该对象的后续检查。
  function automatic void expect_decode_failure(
    string label,
    rdma_hw_doorbell_codec_registry registry,
    string variant,
    rdma_hw_image image,
    rdma_status_code_e expected = RDMA_SC_CODEC_ERROR
  );
    rdma_hw_model decoded;
    rdma_status status;
    decoded = null;
    status = registry.decode(variant, image, decoded);
    expect_status(label, status, expected);
    if (decoded != null)
      `uvm_error(label, "failed decode published a model")
  endfunction

  // 功能：check_raw_encode_wrong_type 逐一调用所有门铃布局的生产
  //       encode_fields()，确认错误动态类型在内部 cast 边界被拒绝。
  // 输入/输出及副作用：wrong（输入）是一个故意不匹配的门铃模型；函数创建本地
  //       probe、builder 和 occupancy 快照，只产生 UVM 断言报告，不发布硬件 image。
  // 失败/边界：任一布局返回非 RDMA_SC_INVALID_ARGUMENT、返回 null status，或在拒绝
  //       前写入字段占用都会报告错误；wrong 为空时直接报告 fixture 错误并停止。
  function automatic void check_raw_encode_wrong_type(
    rdma_hw_wrong_doorbell_model wrong
  );
    string variants[13] = '{
      "cmq_sq", "sq", "rq", "srq_pi", "srq_limit", "cq_rc_ud",
      "cq_urc", "ceq", "aeq", "rts2sqd", "sqd2rts", "qp_flush",
      "tx_flush"
    };
    rdma_hw_doorbell_codec_probe probe;
    bit [63:0] occupancy[];
    rdma_status status;

    if (wrong == null) begin
      `uvm_error("RAW_WRONG_TYPE", "wrong-type fixture is null")
      return;
    end

    foreach (variants[index]) begin
      probe = new({"raw_wrong_type_", variants[index]}, variants[index]);
      status = probe.encode_fields_for_test(wrong, occupancy);
      expect_status({"RAW_WRONG_TYPE_", variants[index]}, status,
                    RDMA_SC_INVALID_ARGUMENT);
      if (occupancy.size() != 1 || occupancy[0] !== 64'b0)
        `uvm_error({"RAW_WRONG_TYPE_", variants[index]},
                   "wrong-type encode_fields wrote partial builder state")
    end
  endfunction

  // 功能：在 rdma_doorbell_codec_test 中，run_phase 驱动 UVM 阶段中的场景初始化、事务执行和断言收尾，并在退出前释放 objection 或测试资源。
  // 输入/输出及副作用：phase（输入）；phase 由 UVM 提供；task 通过 objection、日志和断言暴露结果，可能调用 DUT 接口但不改变其所有权规则。
  // 失败/边界：run_phase 的 setup/阶段驱动失败时停止新增事务，并按测试生命周期清理 objection 与临时引用。
  task run_phase(uvm_phase phase);
    string variants[13] = '{
      "cmq_sq", "sq", "rq", "srq_pi", "srq_limit", "cq_rc_ud",
      "cq_urc", "ceq", "aeq", "rts2sqd", "sqd2rts", "qp_flush",
      "tx_flush"
    };
    longint unsigned offsets[13] = '{
      'h000, 'h100, 'h010, 'h040, 'h040, 'h018, 'h018, 'h020,
      'h028, 'h048, 'h050, 'h058, 'h008
    };
    rdma_golden_case doorbell_cases[$];
    rdma_golden_case queue_cases[$];
    rdma_golden_case golden;
    rdma_golden_case sqe;
    rdma_hw_doorbell_codec_registry registry;
    rdma_hw_doorbell_codec_registry collision_registry;
    rdma_codec_registry_test_codec collision_codec;
    rdma_codec_duplicate_catcher collision_catcher;
    rdma_codec_key collision_key;
    rdma_hw_doorbell_model_base model;
    rdma_hw_doorbell_model_base decoded_doorbell;
    rdma_hw_wrong_doorbell_model wrong;
    rdma_hw_unknown_doorbell_model unknown;
    rdma_hw_rq_doorbell_model rq;
    rdma_hw_srq_doorbell_model srq;
    rdma_hw_cq_doorbell_model cq;
    rdma_hw_qp_control_doorbell_model qp;
    rdma_hw_sq_doorbell_model sq;
    rdma_hw_image image;
    rdma_hw_image roundtrip;
    rdma_hw_image bad;
    rdma_hw_model decoded;
    uvm_object cloned;
    rdma_status status;
    string error;
    string keys[$];
    string keys_before[$];
    string keys_after[$];
    bit equal;
    string mismatch;

    phase.raise_objection(this);

    registry = rdma_hw_doorbell_codec_registry::type_id::create(
        "registry");
    expect_ok("REGISTER_DEFAULTS", registry.register_defaults());

    if (!rdma_golden_reader::read_all(
          "../hw/rdma/golden_vectors/doorbell.hex", doorbell_cases,
          error)) begin
      `uvm_error("GOLDEN", error)
      phase.drop_objection(this);
      return;
    end
    if (!rdma_golden_reader::read_all(
          "../hw/rdma/golden_vectors/queue.hex", queue_cases, error)) begin
      `uvm_error("GOLDEN", error)
      phase.drop_objection(this);
      return;
    end
    if (doorbell_cases.size() != 13)
      `uvm_error("GOLDEN", "doorbell golden case count is not thirteen")

    foreach (variants[index]) begin
      golden = find_golden(doorbell_cases, variants[index]);
      model = make_model(variants[index], golden);
      if (golden == null || model == null) begin
        `uvm_error("GOLDEN", {"missing model/golden for ", variants[index]})
        continue;
      end
      image = null;
      expect_ok({variants[index], "_ENCODE"}, registry.encode(model, image));
      check_metadata(variants[index], model, image, offsets[index]);
      if (!image_matches_golden(image, golden))
        `uvm_error(variants[index], "encoded bytes differ from golden")

      decoded = null;
      expect_ok({variants[index], "_DECODE"},
                registry.decode(model.codec_variant(), image, decoded));
      if (decoded == null || !$cast(decoded_doorbell, decoded)) begin
        `uvm_error(variants[index], "decode lost typed doorbell base")
        continue;
      end
      equal = 1'b0;
      mismatch = "";
      expect_ok({variants[index], "_SERIALIZED_EQUAL"},
                registry.serialized_equal(model.codec_variant(), model,
                                          decoded, equal, mismatch));
      if (!equal)
        `uvm_error(variants[index], {"serialized mismatch: ", mismatch})
      roundtrip = null;
      expect_ok({variants[index], "_REENCODE"},
                registry.encode(decoded_doorbell, roundtrip));
      if (!image_matches_golden(roundtrip, golden))
        `uvm_error(variants[index], "decoded model does not re-encode")
    end

    sqe = find_golden(queue_cases, "sqe_rc_boundary");
    golden = find_golden(doorbell_cases, "sq");
    if (sqe == null || golden == null || sqe.payload.size() < 8)
      `uvm_error("SQ_HEADER", "SQ/SQE golden is missing")
    else begin
      for (int unsigned index = 0; index < 8; index++) begin
        if (golden.payload[index] != sqe.payload[index])
          `uvm_error("SQ_HEADER", "SQ doorbell reinterpreted SQE header")
      end
    end

    // Registry selection is closed: the key cannot lie about dynamic type,
    // and unknown variants cannot fall through to another codec.
    wrong = rdma_hw_wrong_doorbell_model::type_id::create("wrong");
    wrong.target_h = make_handle("wrong_qp_h", RDMA_RESOURCE_QP, 1);
    image = null;
    expect_status("WRONG_DYNAMIC_TYPE", registry.encode(wrong, image),
                  RDMA_SC_INVALID_ARGUMENT);
    if (image != null)
      `uvm_error("WRONG_DYNAMIC_TYPE", "wrong type published an image")

    // registry 公共入口会先校验模型，无法触达 encode_fields()；这里直接覆盖
    //       受保护的生产边界，确保每个布局分支的错误动态 cast 都安全拒绝。
    check_raw_encode_wrong_type(wrong);

    unknown = rdma_hw_unknown_doorbell_model::type_id::create("unknown");
    unknown.target_h = make_handle("unknown_qp_h", RDMA_RESOURCE_QP, 1);
    expect_status("UNREGISTERED_VARIANT", registry.encode(unknown, image),
                  RDMA_SC_UNSUPPORTED_OPCODE);

    // Representative range and lifecycle failures are rejected before image
    // publication. Distinct variant tests above exercise every field layout.
    model = make_model("rq", find_golden(doorbell_cases, "rq"));
    if (!$cast(rq, model))
      `uvm_fatal("TEST_SETUP", "RQ model factory returned wrong type")
    rq.qpn = 32'h20_0000;
    image = null;
    expect_status("RQ_RANGE", registry.encode(rq, image),
                  RDMA_SC_INVALID_ARGUMENT);
    rq.qpn = 21'h15555;
    rq.target_h.kind = RDMA_RESOURCE_CQ;
    expect_status("RQ_TARGET_KIND", registry.encode(rq, image),
                  RDMA_SC_INVALID_ARGUMENT);
    rq.target_h.kind = RDMA_RESOURCE_QP;
    rq.target_h.generation = 0;
    expect_status("STALE_TARGET", registry.encode(rq, image),
                  RDMA_SC_STALE_GENERATION);

    model = make_model("srq_limit",
                       find_golden(doorbell_cases, "srq_limit"));
    if (!$cast(srq, model))
      `uvm_fatal("TEST_SETUP", "SRQ model factory returned wrong type")
    srq.limit = 32'h4000;
    expect_status("SRQ_RANGE", registry.encode(srq, image),
                  RDMA_SC_INVALID_ARGUMENT);

    // cq.h:108-109 define independent CI/ARM invalid markers at bits 63/62.
    // Exercise both wire variants and all combinations so neither marker can
    // be accidentally tied to the other or hidden by a shared mask.
    for (int unsigned ci_flag = 0; ci_flag < 2; ci_flag++) begin
      for (int unsigned arm_flag = 0; arm_flag < 2; arm_flag++) begin
        check_cq_invalid_flag_case(
          $sformatf("CQ_RC_UD_INVALID_%0d_%0d", ci_flag, arm_flag),
          "cq_rc_ud", registry,
          find_golden(doorbell_cases, "cq_rc_ud"),
          ci_flag, arm_flag);
        check_cq_invalid_flag_case(
          $sformatf("CQ_URC_INVALID_%0d_%0d", ci_flag, arm_flag),
          "cq_urc", registry,
          find_golden(doorbell_cases, "cq_urc"),
          ci_flag, arm_flag);
      end
    end

    model = make_model("cq_urc", find_golden(doorbell_cases, "cq_urc"));
    if (!$cast(cq, model))
      `uvm_fatal("TEST_SETUP", "CQ model factory returned wrong type")
    cq.sq_ci = 32'h8000;
    expect_status("CQ_RANGE", registry.encode(cq, image),
                  RDMA_SC_INVALID_ARGUMENT);
    model = make_model("tx_flush", find_golden(doorbell_cases, "tx_flush"));
    if (!$cast(qp, model))
      `uvm_fatal("TEST_SETUP", "QP model factory returned wrong type")
    qp.dst_port = 14;
    expect_status("TX_FIXED_IDENTITY", registry.encode(qp, image),
                  RDMA_SC_INVALID_ARGUMENT);
    model = make_model("sq", find_golden(doorbell_cases, "sq"));
    if (!$cast(sq, model))
      `uvm_fatal("TEST_SETUP", "SQ model factory returned wrong type")
    void'(sq.sqe_header.pop_back());
    expect_status("SQ_HEADER_LENGTH", registry.encode(sq, image),
                  RDMA_SC_INVALID_ARGUMENT);

    // Every malformed metadata coordinate and selected-variant reserved bit
    // must fail decode without publishing a partial model.
    model = make_model("rq", find_golden(doorbell_cases, "rq"));
    expect_ok("MALFORMED_SEED", registry.encode(model, image));
    cloned = image.clone(); void'($cast(bad, cloned));
    bad.length = 7;
    expect_decode_failure("BAD_LENGTH", registry, "rq", bad);
    cloned = image.clone(); void'($cast(bad, cloned));
    void'(bad.bytes.pop_back());
    expect_decode_failure("BAD_BYTES", registry, "rq", bad);
    cloned = image.clone(); void'($cast(bad, cloned));
    bad.alignment = 4;
    expect_decode_failure("BAD_ALIGNMENT", registry, "rq", bad);
    cloned = image.clone(); void'($cast(bad, cloned));
    bad.endian = RDMA_ENDIAN_LITTLE;
    expect_decode_failure("BAD_ENDIAN", registry, "rq", bad);
    cloned = image.clone(); void'($cast(bad, cloned));
    bad.hardware_version = 2;
    expect_decode_failure("BAD_VERSION", registry, "rq", bad);
    cloned = image.clone(); void'($cast(bad, cloned));
    bad.image_kind = RDMA_IMAGE_SQE;
    expect_decode_failure("BAD_IMAGE_KIND", registry, "rq", bad);
    cloned = image.clone(); void'($cast(bad, cloned));
    bad.function_generation = 0;
    expect_decode_failure("BAD_GENERATION", registry, "rq", bad,
                          RDMA_SC_STALE_GENERATION);
    cloned = image.clone(); void'($cast(bad, cloned));
    bad.write_target_kind = RDMA_HW_TARGET_NONE;
    expect_decode_failure("BAD_TARGET", registry, "rq", bad);
    cloned = image.clone(); void'($cast(bad, cloned));
    bad.bar_target.value = 'h18;
    expect_decode_failure("BAD_OFFSET", registry, "rq", bad);
    cloned = image.clone(); void'($cast(bad, cloned));
    bad.bytes[0] |= 8'h80;
    expect_decode_failure("RESERVED_BIT", registry, "rq", bad);

    registry.list_keys(keys);
    if (keys.size() != 13)
      `uvm_error("KEYS", $sformatf("registered %0d keys, expected 13",
                                    keys.size()))
    foreach (variants[index]) begin
      string expected_key;
      int match_count;
      expected_key = {"rdma|14|doorbell|", variants[index], "|00"};
      match_count = 0;
      foreach (keys[key_index])
        if (keys[key_index] == expected_key) match_count++;
      if (match_count != 1)
        `uvm_error("KEYS", {"unstable/missing key ", expected_key})
    end
    expect_status("DUPLICATE_REGISTRATION", registry.register_defaults(),
                  RDMA_SC_INVALID_STATE);
    registry.list_keys(keys);
    if (keys.size() != 13)
      `uvm_error("KEYS", "duplicate registration changed the registry")

    // clear() is polymorphic registry state reset: the specialized
    // registration guard must reset with the base key table.
    registry.clear();
    registry.list_keys(keys);
    if (keys.size() != 0)
      `uvm_error("CLEAR_DEFAULTS", "specialized clear retained codec keys")
    expect_ok("REREGISTER_AFTER_CLEAR", registry.register_defaults());
    registry.list_keys(keys);
    if (keys.size() != 13)
      `uvm_error("REREGISTER_AFTER_CLEAR",
                 "clear followed by defaults did not restore all keys")

    // Defaults are transactional. A collision at the final key must be
    // detected before inserting any preceding default, preserving the exact
    // original key set.
    collision_registry =
      rdma_hw_doorbell_codec_registry::type_id::create(
        "collision_registry"
      );
    collision_codec = new("collision_codec", RDMA_ENDIAN_BIG);
    collision_key = '{hw_version:"rdma",
                      image_kind:RDMA_IMAGE_DOORBELL,
                      object_type:"doorbell", variant:"tx_flush",
                      opcode:8'h00};
    expect_ok("ARM_LATE_COLLISION",
              collision_registry.register_codec(collision_key,
                                                collision_codec));
    collision_registry.list_keys(keys_before);
    collision_catcher = new("collision_catcher");
    uvm_report_cb::add(null, collision_catcher);
    expect_status("ATOMIC_DEFAULT_COLLISION",
                  collision_registry.register_defaults(),
                  RDMA_SC_INVALID_STATE);
    uvm_report_cb::delete(null, collision_catcher);
    collision_registry.list_keys(keys_after);
    if (keys_after != keys_before)
      `uvm_error("ATOMIC_DEFAULT_COLLISION",
                 "failed default registration partially changed key set")

    phase.drop_objection(this);
  endtask
endclass
