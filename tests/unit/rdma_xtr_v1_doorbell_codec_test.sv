// 目录：测试层 unit/rdma_xtr_v1_doorbell_codec_test.sv。
// 职责：验证 rdma_xtr_v1_doorbell_codec_test 对应模块的接口、错误路径和边界行为。
// 依赖：依赖被测 package、UVM 测试基类和必要的 mock/fixture。
// 所有权与生命周期：测试对象只拥有本地 fixture；外部后端句柄由测试环境提供并在测试结束释放。

// 中文说明：rdma_xtr_v1_doorbell_codec_test.sv 属于单元测试，覆盖对应模型、编码器或执行器契约。
// 阅读提示：先看公开类型和接口，再看实现细节；失败路径应保持状态与资源所有权可追踪。

class rdma_xtr_v1_wrong_doorbell_model
    extends rdma_xtr_v1_doorbell_model_base;
  `uvm_object_utils(rdma_xtr_v1_wrong_doorbell_model)

  // 功能：构造当前对象并初始化其字段、集合和 UVM 名称；不接管传入句柄的生命周期。
  // 输入/输出及副作用：name 仅用于 UVM 对象命名；内部字段被初始化为安全默认值，传入句柄不转移所有权。
  //   返回新对象实例；构造失败由 UVM 工厂或调用方处理。
  // 失败/边界：不创建外部资源；name 为空时仍允许构造，但所有字段必须保持可配置的初始值。
  function new(string name = "rdma_xtr_v1_wrong_doorbell_model");
    super.new(name);
  endfunction

  // 功能：处理 doorbell_kind：依据其参数完成所属层的具体协议动作，并保持返回状态、游标和资源所有权一致。
  // 输入/输出及副作用：参数 RDMA_DOORBELL_RQ 用于执行 doorbell_kind；返回值或 output/inout 交付处理结果，必要时更新本对象状态。
  //   调用方不获得内部集合或外部依赖的所有权。
  // 失败/边界：doorbell_kind 只接受其签名声明的输入；缺少必要字段时返回错误，成功路径不得隐式修改无关资源。
  virtual function rdma_doorbell_kind_e doorbell_kind();
    return RDMA_DOORBELL_RQ;
  endfunction

  // 功能：处理 codec_variant：依据其参数完成所属层的具体协议动作，并保持返回状态、游标和资源所有权一致。
  // 输入/输出及副作用：参数 rq 用于执行 codec_variant；返回值或 output/inout 交付处理结果，必要时更新本对象状态。
  //   调用方不获得内部集合或外部依赖的所有权。
  // 失败/边界：codec_variant 只接受其签名声明的输入；缺少必要字段时返回错误，成功路径不得隐式修改无关资源。
  virtual function string codec_variant();
    return "rq";
  endfunction

  // 功能：将当前对象的类型、状态或关键标识转换为调用方可消费的值，不产生外部副作用。
  // 输入/输出及副作用：输入为当前对象状态；返回字符串、枚举或只读派生值，不修改对象。
  //   对象未配置时返回可识别的 UNKNOWN/UNCONFIGURED 表示。
  // 失败/边界：未配置或字段无效时返回明确的 UNKNOWN 表示，不读取未初始化句柄。
  virtual function string describe();
    return "wrong dynamic doorbell model";
  endfunction
endclass

class rdma_xtr_v1_unknown_doorbell_model
    extends rdma_xtr_v1_doorbell_model_base;
  `uvm_object_utils(rdma_xtr_v1_unknown_doorbell_model)

  // 功能：构造当前对象并初始化其字段、集合和 UVM 名称；不接管传入句柄的生命周期。
  // 输入/输出及副作用：name 仅用于 UVM 对象命名；内部字段被初始化为安全默认值，传入句柄不转移所有权。
  //   返回新对象实例；构造失败由 UVM 工厂或调用方处理。
  // 失败/边界：不创建外部资源；name 为空时仍允许构造，但所有字段必须保持可配置的初始值。
  function new(string name = "rdma_xtr_v1_unknown_doorbell_model");
    super.new(name);
  endfunction

  // 功能：处理 doorbell_kind：依据其参数完成所属层的具体协议动作，并保持返回状态、游标和资源所有权一致。
  // 输入/输出及副作用：参数 RDMA_DOORBELL_RQ 用于执行 doorbell_kind；返回值或 output/inout 交付处理结果，必要时更新本对象状态。
  //   调用方不获得内部集合或外部依赖的所有权。
  // 失败/边界：doorbell_kind 只接受其签名声明的输入；缺少必要字段时返回错误，成功路径不得隐式修改无关资源。
  virtual function rdma_doorbell_kind_e doorbell_kind();
    return RDMA_DOORBELL_RQ;
  endfunction

  // 功能：处理 codec_variant：依据其参数完成所属层的具体协议动作，并保持返回状态、游标和资源所有权一致。
  // 输入/输出及副作用：参数 unknown 用于执行 codec_variant；返回值或 output/inout 交付处理结果，必要时更新本对象状态。
  //   调用方不获得内部集合或外部依赖的所有权。
  // 失败/边界：codec_variant 只接受其签名声明的输入；缺少必要字段时返回错误，成功路径不得隐式修改无关资源。
  virtual function string codec_variant();
    return "unknown";
  endfunction

  // 功能：将当前对象的类型、状态或关键标识转换为调用方可消费的值，不产生外部副作用。
  // 输入/输出及副作用：输入为当前对象状态；返回字符串、枚举或只读派生值，不修改对象。
  //   对象未配置时返回可识别的 UNKNOWN/UNCONFIGURED 表示。
  // 失败/边界：未配置或字段无效时返回明确的 UNKNOWN 表示，不读取未初始化句柄。
  virtual function string describe();
    return "unregistered doorbell model";
  endfunction
endclass

class rdma_xtr_v1_doorbell_codec_test extends uvm_test;
  `uvm_component_utils(rdma_xtr_v1_doorbell_codec_test)

  // 功能：构造当前对象并初始化其字段、集合和 UVM 名称；不接管传入句柄的生命周期。
  // 输入/输出及副作用：name 仅用于 UVM 对象命名；内部字段被初始化为安全默认值，传入句柄不转移所有权。
  //   返回新对象实例；构造失败由 UVM 工厂或调用方处理。
  // 失败/边界：不创建外部资源；name 为空时仍允许构造，但所有字段必须保持可配置的初始值。
  function new(string name = "rdma_xtr_v1_doorbell_codec_test",
               uvm_component parent = null);
    super.new(name, parent);
  endfunction

  // 功能：依据输入请求创建对应的值对象或资源计划，并校验依赖、所有权和生命周期后返回结果。
  // 输入/输出及副作用：输入请求、容量和依赖用于构造/预留资源；返回独立对象或状态，不暴露内部可变集合。
  //   参数越界、容量不足或构造中途失败时回滚已登记的局部状态。
  // 失败/边界：依赖为空、参数越界、容量不足或构造步骤失败时清理局部结果并返回明确错误。
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

  // 功能：在测试中检查调用结果、状态码和副作用是否符合契约；失败时报告可定位的验证信息。
  // 输入/输出及副作用：参数 label, status, expected 用于执行 expect_status；返回值或 output/inout 交付处理结果，必要时更新本对象状态。
  //   调用方不获得内部集合或外部依赖的所有权。
  // 失败/边界：测试前置对象缺失时应报告断言错误并停止依赖该对象的后续检查。
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

  // 功能：在测试中检查调用结果、状态码和副作用是否符合契约；失败时报告可定位的验证信息。
  // 输入/输出及副作用：参数 label, RDMA_SC_OK 用于执行 expect_ok；返回值或 output/inout 交付处理结果，必要时更新本对象状态。
  //   调用方不获得内部集合或外部依赖的所有权。
  // 失败/边界：测试前置对象缺失时应报告断言错误并停止依赖该对象的后续检查。
  function automatic void expect_ok(string label, rdma_status status);
    expect_status(label, status, RDMA_SC_OK);
  endfunction

  // 功能：处理 image_matches_golden：依据其参数完成所属层的具体协议动作，并保持返回状态、游标和资源所有权一致。
  // 输入/输出及副作用：参数 image, golden 用于执行 image_matches_golden；返回值或 output/inout 交付处理结果，必要时更新本对象状态。
  //   调用方不获得内部集合或外部依赖的所有权。
  // 失败/边界：image_matches_golden 只接受其签名声明的输入；缺少必要字段时返回错误，成功路径不得隐式修改无关资源。
  function automatic bit image_matches_golden(
    rdma_hw_image image,
    rdma_xtr_v1_golden_case golden
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

  // 功能：按输入的完整标识查询当前权威记录并返回独立快照；缺失、歧义或代际过期时返回明确错误。
  // 输入/输出及副作用：输入为完整 key/handle，output 或返回值为记录快照；查询不改变登记表和外部资源。
  //   缺失、歧义、空句柄或旧 generation/reset epoch 返回明确错误。
  // 失败/边界：查询不到唯一记录、输入为空或 authority 已失效时返回错误，不回退到默认 Function/root。
  function automatic rdma_xtr_v1_golden_case find_golden(
    rdma_xtr_v1_golden_case cases[$],
    string name
  );
    foreach (cases[index]) begin
      if (cases[index].name == name)
        return cases[index];
    end
    return null;
  endfunction

  // 功能：依据输入请求创建对应的值对象或资源计划，并校验依赖、所有权和生命周期后返回结果。
  // 输入/输出及副作用：输入请求、容量和依赖用于构造/预留资源；返回独立对象或状态，不暴露内部可变集合。
  //   参数越界、容量不足或构造中途失败时回滚已登记的局部状态。
  // 失败/边界：依赖为空、参数越界、容量不足或构造步骤失败时清理局部结果并返回明确错误。
  function automatic rdma_xtr_v1_doorbell_model_base make_model(
    string variant,
    rdma_xtr_v1_golden_case golden
  );
    rdma_xtr_v1_cmq_sq_doorbell_model cmq;
    rdma_xtr_v1_sq_doorbell_model sq;
    rdma_xtr_v1_rq_doorbell_model rq;
    rdma_xtr_v1_srq_doorbell_model srq;
    rdma_xtr_v1_cq_doorbell_model cq;
    rdma_xtr_v1_ceq_doorbell_model ceq;
    rdma_xtr_v1_aeq_doorbell_model aeq;
    rdma_xtr_v1_qp_control_doorbell_model qp;

    case (variant)
      "cmq_sq": begin
        cmq = rdma_xtr_v1_cmq_sq_doorbell_model::type_id::create("cmq");
        cmq.target_h = make_handle("cmq_h", RDMA_RESOURCE_CMQ, 1);
        cmq.pi = 27;
        cmq.polarity = 1'b1;
        return cmq;
      end
      "sq": begin
        sq = rdma_xtr_v1_sq_doorbell_model::type_id::create("sq");
        sq.target_h = make_handle("sq_qp_h", RDMA_RESOURCE_QP, 21'h15555);
        foreach (golden.payload[index])
          sq.sqe_header.push_back(golden.payload[index]);
        return sq;
      end
      "rq": begin
        rq = rdma_xtr_v1_rq_doorbell_model::type_id::create("rq");
        rq.target_h = make_handle("rq_qp_h", RDMA_RESOURCE_QP, 21'h15555);
        rq.qpn = 21'h15555;
        rq.icos = 5;
        rq.pi = 15'h4567;
        rq.wrap = 1'b1;
        return rq;
      end
      "srq_pi", "srq_limit": begin
        srq = rdma_xtr_v1_srq_doorbell_model::type_id::create("srq");
        srq.target_h = make_handle("srq_h", RDMA_RESOURCE_SRQ, 16'ha55a);
        srq.variant = (variant == "srq_pi") ? XTR_V1_SRQ_DB_PI :
                                              XTR_V1_SRQ_DB_LIMIT;
        srq.srqn = 16'ha55a;
        srq.pi = 15'h4567;
        srq.wrap = 1'b1;
        srq.limit = 14'h2aaa;
        srq.arm_sn = 3;
        return srq;
      end
      "cq_rc_ud", "cq_urc": begin
        cq = rdma_xtr_v1_cq_doorbell_model::type_id::create("cq");
        cq.variant = (variant == "cq_rc_ud") ? XTR_V1_CQ_DB_RC_UD :
                                                XTR_V1_CQ_DB_URC;
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
        ceq = rdma_xtr_v1_ceq_doorbell_model::type_id::create("ceq");
        ceq.target_h = make_handle("ceq_h", RDMA_RESOURCE_CEQ, 22'h2aaaaa);
        ceq.ceqn = 22'h2aaaaa;
        ceq.ci = 18'h2aaaa;
        ceq.wrap = 1'b1;
        return ceq;
      end
      "aeq": begin
        aeq = rdma_xtr_v1_aeq_doorbell_model::type_id::create("aeq");
        aeq.target_h = make_handle("aeq_h", RDMA_RESOURCE_AEQ, 12'haaa);
        aeq.aeqn = 12'haaa;
        aeq.ci = 18'h15555;
        aeq.wrap = 1'b1;
        return aeq;
      end
      "rts2sqd", "sqd2rts", "qp_flush", "tx_flush": begin
        qp = rdma_xtr_v1_qp_control_doorbell_model::type_id::create("qp");
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

  // 功能：检查输入字段、身份和生命周期约束，返回可诊断的校验状态；失败时不提交部分更新。
  // 输入/输出及副作用：输入为待校验字段或快照；返回 rdma_status，校验过程不提交资源和游标。
  //   空依赖、非法范围、身份不一致或非活动状态会返回错误。
  // 失败/边界：任何非法枚举、越界字段、缺失必需依赖或身份/代际不一致都必须返回非成功状态。
  function automatic void check_metadata(
    string label,
    rdma_xtr_v1_doorbell_model_base model,
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

  // 功能：在测试中检查调用结果、状态码和副作用是否符合契约；失败时报告可定位的验证信息。
  // 输入/输出及副作用：参数 label, registry, variant, image, expected 用于执行 expect_decode_failure；返回值或 output/inout 交付处理结果，必要时更新本对象状态。
  //   调用方不获得内部集合或外部依赖的所有权。
  // 失败/边界：测试前置对象缺失时应报告断言错误并停止依赖该对象的后续检查。
  function automatic void expect_decode_failure(
    string label,
    rdma_xtr_v1_doorbell_codec_registry registry,
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

  // 功能：驱动 UVM 阶段中的场景初始化、事务执行和断言收尾，并在退出前释放 objection 或测试资源。
  // 输入/输出及副作用：phase 控制 UVM 调度；task 驱动事务、断言和 objection，测试 fixture 由本层负责清理。
  //   阶段提前结束或前置 setup 失败时必须释放 objection 并停止后续访问。
  // 失败/边界：setup 失败或阶段被终止时停止新增事务，确保 objection、临时对象和外部引用按测试生命周期收尾。
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
    rdma_xtr_v1_golden_case doorbell_cases[$];
    rdma_xtr_v1_golden_case queue_cases[$];
    rdma_xtr_v1_golden_case golden;
    rdma_xtr_v1_golden_case sqe;
    rdma_xtr_v1_doorbell_codec_registry registry;
    rdma_xtr_v1_doorbell_codec_registry collision_registry;
    rdma_codec_registry_test_codec collision_codec;
    rdma_codec_duplicate_catcher collision_catcher;
    rdma_codec_key collision_key;
    rdma_xtr_v1_doorbell_model_base model;
    rdma_xtr_v1_doorbell_model_base decoded_doorbell;
    rdma_xtr_v1_wrong_doorbell_model wrong;
    rdma_xtr_v1_unknown_doorbell_model unknown;
    rdma_xtr_v1_rq_doorbell_model rq;
    rdma_xtr_v1_srq_doorbell_model srq;
    rdma_xtr_v1_cq_doorbell_model cq;
    rdma_xtr_v1_qp_control_doorbell_model qp;
    rdma_xtr_v1_sq_doorbell_model sq;
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

    registry = rdma_xtr_v1_doorbell_codec_registry::type_id::create(
        "registry");
    expect_ok("REGISTER_DEFAULTS", registry.register_defaults());

    if (!rdma_xtr_v1_golden_reader::read_all(
          "../hw/xtr_v1/golden_vectors/doorbell.hex", doorbell_cases,
          error)) begin
      `uvm_error("GOLDEN", error)
      phase.drop_objection(this);
      return;
    end
    if (!rdma_xtr_v1_golden_reader::read_all(
          "../hw/xtr_v1/golden_vectors/queue.hex", queue_cases, error)) begin
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
    wrong = rdma_xtr_v1_wrong_doorbell_model::type_id::create("wrong");
    wrong.target_h = make_handle("wrong_qp_h", RDMA_RESOURCE_QP, 1);
    image = null;
    expect_status("WRONG_DYNAMIC_TYPE", registry.encode(wrong, image),
                  RDMA_SC_INVALID_ARGUMENT);
    if (image != null)
      `uvm_error("WRONG_DYNAMIC_TYPE", "wrong type published an image")

    unknown = rdma_xtr_v1_unknown_doorbell_model::type_id::create("unknown");
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
      expected_key = {"xtr_v1|14|doorbell|", variants[index], "|00"};
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
      rdma_xtr_v1_doorbell_codec_registry::type_id::create(
        "collision_registry"
      );
    collision_codec = new("collision_codec", RDMA_ENDIAN_BIG);
    collision_key = '{hw_version:"xtr_v1",
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
