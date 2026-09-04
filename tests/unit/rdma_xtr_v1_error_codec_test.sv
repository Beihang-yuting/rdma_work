// 目录：测试层 unit/rdma_xtr_v1_error_codec_test.sv。
// 职责：验证 rdma_xtr_v1_error_codec_test 对应模块的接口、错误路径和边界行为。
// 依赖：依赖被测 package、UVM 测试基类和必要的 mock/fixture。
// 所有权与生命周期：测试对象只拥有本地 fixture；外部后端句柄由测试环境提供并在测试结束释放。

// 中文说明：rdma_xtr_v1_error_codec_test.sv 属于单元测试，覆盖对应模型、编码器或执行器契约。
// 阅读提示：先看公开类型和接口，再看实现细节；失败路径应保持状态与资源所有权可追踪。

class rdma_xtr_v1_error_codec_test extends uvm_test;
  `uvm_component_utils(rdma_xtr_v1_error_codec_test)

  rdma_xtr_v1_error_codec codec;

  // 功能：构造当前对象并初始化其字段、集合和 UVM 名称；不接管传入句柄的生命周期。
  // 输入/输出及副作用：name 仅用于 UVM 对象命名；内部字段被初始化为安全默认值，传入句柄不转移所有权。
  //   返回新对象实例；构造失败由 UVM 工厂或调用方处理。
  // 失败/边界：不创建外部资源；name 为空时仍允许构造，但所有字段必须保持可配置的初始值。
  function new(string name = "rdma_xtr_v1_error_codec_test",
               uvm_component parent = null);
    super.new(name, parent);
  endfunction

  // 功能：检查输入字段、身份和生命周期约束，返回可诊断的校验状态；失败时不提交部分更新。
  // 输入/输出及副作用：输入为待校验字段或快照；返回 rdma_status，校验过程不提交资源和游标。
  //   空依赖、非法范围、身份不一致或非活动状态会返回错误。
  // 失败/边界：任何非法枚举、越界字段、缺失必需依赖或身份/代际不一致都必须返回非成功状态。
  function automatic void check_error(
    string label,
    bit [7:0] hardware_code,
    rdma_engine_kind_e observed_engine,
    rdma_status_code_e expected_code,
    rdma_status_category_e expected_category,
    rdma_engine_kind_e expected_engine,
    bit expected_retryable,
    string expected_symbol = ""
  );
    rdma_status stale;
    rdma_status decoded;
    rdma_status operation;
    stale = rdma_status::make(RDMA_SC_INVALID_STATE, "stale output");
    stale.hardware_code = 32'hdead_beef;
    stale.hardware_code_valid = 1'b1;
    stale.source_engine = RDMA_ENGINE_RESET;
    decoded = stale;
    operation = codec.decode_status(hardware_code, observed_engine, decoded);
    if (operation == null || operation.code != RDMA_SC_OK)
      `uvm_error(label,
                 (operation == null) ? "decode returned null operation status" :
                 {"decode operation failed: ", operation.convert2string()})
    if (decoded == null) begin
      `uvm_error(label, "decode published null status")
      return;
    end
    if (decoded == stale)
      `uvm_error(label, "decode failed to overwrite the output object")
    if (decoded.code != expected_code || decoded.category != expected_category)
      `uvm_error(label,
                 $sformatf("classification mismatch: %s",
                           decoded.convert2string()))
    if (decoded.source_engine != expected_engine)
      `uvm_error(label,
                 $sformatf("expected engine %s, got %s",
                           expected_engine.name(), decoded.source_engine.name()))
    if (decoded.retryable != expected_retryable)
      `uvm_error(label, "retryable classification mismatch")
    if (hardware_code == 0) begin
      if (decoded.hardware_code_valid || decoded.hardware_code != 0 ||
          decoded.severity != RDMA_SEVERITY_INFO)
        `uvm_error(label, "zero ecode claimed a hardware error")
    end
    else begin
      if (!decoded.hardware_code_valid ||
          decoded.hardware_code != {24'h0, hardware_code})
        `uvm_error(label, "raw hardware ecode was not preserved exactly")
      if (decoded.source_engine == RDMA_ENGINE_NONE)
        `uvm_error(label, "nonzero ecode retained NONE source engine")
      if (decoded.severity != RDMA_SEVERITY_ERROR)
        `uvm_error(label, "nonzero ecode has inconsistent severity")
      if (decoded.message.len() == 0)
        `uvm_error(label, "nonzero ecode has an empty symbolic message")
    end
    if (expected_symbol != "" && decoded.message != expected_symbol)
      `uvm_error(label,
                 $sformatf("expected message %s, got %s",
                           expected_symbol, decoded.message))
  endfunction

  // 功能：检查输入字段、身份和生命周期约束，返回可诊断的校验状态；失败时不提交部分更新。
  // 输入/输出及副作用：输入为待校验字段或快照；返回 rdma_status，校验过程不提交资源和游标。
  //   空依赖、非法范围、身份不一致或非活动状态会返回错误。
  // 失败/边界：任何非法枚举、越界字段、缺失必需依赖或身份/代际不一致都必须返回非成功状态。
  function automatic void check_fixed_classifications();
    bit [7:0] translation[$] = '{8'h45, 8'hc5};
    bit [7:0] permission[$] = '{8'h4b, 8'h4c, 8'h55, 8'h56,
                                8'h60, 8'h61, 8'h62, 8'h63,
                                8'hc7, 8'hcb, 8'hcc, 8'hcd,
                                8'hd7, 8'hd8};
    foreach (translation[i])
      check_error($sformatf("TRANSLATION_%02x", translation[i]),
                  translation[i], RDMA_ENGINE_DMA,
                  RDMA_SC_DMA_TRANSLATION, RDMA_STATUS_DMA,
                  RDMA_ENGINE_DMA, 1'b1);
    foreach (permission[i])
      check_error($sformatf("PERMISSION_%02x", permission[i]), permission[i],
                  RDMA_ENGINE_DMA, RDMA_SC_DMA_PERMISSION, RDMA_STATUS_DMA,
                  RDMA_ENGINE_DMA, 1'b0);
    check_error("PCIE_70", 8'h70, RDMA_ENGINE_DMA,
                RDMA_SC_PCIE_COMPLETION, RDMA_STATUS_PCIE,
                RDMA_ENGINE_DMA, 1'b1, "EC_TDE_DMA_ERR");
    check_error("PCIE_FF", 8'hff, RDMA_ENGINE_PCIE,
                RDMA_SC_PCIE_COMPLETION, RDMA_STATUS_PCIE,
                RDMA_ENGINE_PCIE, 1'b1, "EC_GLB_MBUS_ERR");
    check_error("QUEUE_F4", 8'hf4, RDMA_ENGINE_CQ,
                RDMA_SC_QUEUE_FULL, RDMA_STATUS_QUEUE,
                RDMA_ENGINE_CQ, 1'b1, "EC_RCE_CQ_FULL");
    check_error("QUEUE_F8", 8'hf8, RDMA_ENGINE_CEQ,
                RDMA_SC_QUEUE_FULL, RDMA_STATUS_QUEUE,
                RDMA_ENGINE_CEQ, 1'b1, "EC_RCE_CEQ_FULL");
    check_error("QUEUE_FB", 8'hfb, RDMA_ENGINE_AEQ,
                RDMA_SC_QUEUE_FULL, RDMA_STATUS_QUEUE,
                RDMA_ENGINE_AEQ, 1'b1, "EC_RCE_AEQ_FULL");
  endfunction

  // 功能：检查输入字段、身份和生命周期约束，返回可诊断的校验状态；失败时不提交部分更新。
  // 输入/输出及副作用：输入为待校验字段或快照；返回 rdma_status，校验过程不提交资源和游标。
  //   空依赖、非法范围、身份不一致或非活动状态会返回错误。
  // 失败/边界：任何非法枚举、越界字段、缺失必需依赖或身份/代际不一致都必须返回非成功状态。
  function automatic void check_holes_and_unknown_families();
    bit [7:0] unknown_codes[$] = '{
      8'h01, 8'h80, 8'h81, // data-plane normal is not CMQ success
      8'h02,               // TPE
      8'h44,               // TME
      8'h72,               // TDE
      8'h74,               // CCE
      8'h78,               // RPE
      8'hc4,               // RME
      8'he0, 8'he7, 8'hf2, // RCE
      8'h42,               // unassigned raw code
      8'h44, 8'h46, 8'h4a, 8'h4d,
      8'h54, 8'h57, 8'h5f, 8'h64,
      8'h6f, 8'h71,
      8'hc4, 8'hc6, 8'hc8, 8'hca, 8'hce,
      8'hd6, 8'hd9,
      8'hf3, 8'hf5, 8'hf7, 8'hf9, 8'hfa, 8'hfc, 8'hfe
    };
    foreach (unknown_codes[i])
      check_error($sformatf("UNKNOWN_OR_HOLE_%02x_%0d", unknown_codes[i], i),
                  unknown_codes[i], RDMA_ENGINE_CQ,
                  RDMA_SC_UNKNOWN_HW_ERROR, RDMA_STATUS_HARDWARE,
                  RDMA_ENGINE_CQ, 1'b0);
    check_error("UNKNOWN_E7_SYMBOL", 8'he7, RDMA_ENGINE_CQ,
                RDMA_SC_UNKNOWN_HW_ERROR, RDMA_STATUS_HARDWARE,
                RDMA_ENGINE_CQ, 1'b0, "EC_RCE_OCC_UAQ_ERR");
    check_error("UNKNOWN_42_SYMBOL", 8'h42, RDMA_ENGINE_CQ,
                RDMA_SC_UNKNOWN_HW_ERROR, RDMA_STATUS_HARDWARE,
                RDMA_ENGINE_CQ, 1'b0, "XTR_V1_UNKNOWN_ECODE_0x42");
    check_error(
      "UNKNOWN_F0_SYMBOL",
      XTR_V1_ECODE_XTRDMA_CQE_ECODE_TX_EC_RCE_URC_SQ_CPL_SRBM_DUP_PKT,
      RDMA_ENGINE_SQ,
      RDMA_SC_UNKNOWN_HW_ERROR, RDMA_STATUS_HARDWARE,
      RDMA_ENGINE_SQ, 1'b0,
      "XTRDMA_CQE_ECODE_TX_EC_RCE_URC_SQ_CPL_SRBM_DUP_PKT");
  endfunction

  // 功能：检查输入字段、身份和生命周期约束，返回可诊断的校验状态；失败时不提交部分更新。
  // 输入/输出及副作用：输入为待校验字段或快照；返回 rdma_status，校验过程不提交资源和游标。
  //   空依赖、非法范围、身份不一致或非活动状态会返回错误。
  // 失败/边界：任何非法枚举、越界字段、缺失必需依赖或身份/代际不一致都必须返回非成功状态。
  function automatic void check_engine_policy_and_success();
    check_error("ZERO_RETAINS_ENGINE", 8'h00, RDMA_ENGINE_CMQ,
                RDMA_SC_OK, RDMA_STATUS_STATE, RDMA_ENGINE_CMQ, 1'b0,
                "XTR_V1_CMQ_SUCCESS");
    check_error("ZERO_NONE_CANONICAL", 8'h00, RDMA_ENGINE_NONE,
                RDMA_SC_OK, RDMA_STATUS_STATE, RDMA_ENGINE_CMQ, 1'b0,
                "XTR_V1_CMQ_SUCCESS");
    check_error("NONE_TRANSLATION_INFER", 8'h45, RDMA_ENGINE_NONE,
                RDMA_SC_DMA_TRANSLATION, RDMA_STATUS_DMA,
                RDMA_ENGINE_DMA, 1'b1, "EC_TME_PBL_INVLD");
    check_error("NONE_QUEUE_INFER", 8'hf8, RDMA_ENGINE_NONE,
                RDMA_SC_QUEUE_FULL, RDMA_STATUS_QUEUE,
                RDMA_ENGINE_CEQ, 1'b1, "EC_RCE_CEQ_FULL");
    check_error("INVALID_ENGINE_INFER", 8'hfb,
                rdma_engine_kind_e'(4'hf),
                RDMA_SC_QUEUE_FULL, RDMA_STATUS_QUEUE,
                RDMA_ENGINE_AEQ, 1'b1, "EC_RCE_AEQ_FULL");
    check_error("EXPLICIT_ENGINE_RETAIN", 8'hf4, RDMA_ENGINE_RESET,
                RDMA_SC_QUEUE_FULL, RDMA_STATUS_QUEUE,
                RDMA_ENGINE_RESET, 1'b1, "EC_RCE_CQ_FULL");
  endfunction

  // 功能：驱动 UVM 阶段中的场景初始化、事务执行和断言收尾，并在退出前释放 objection 或测试资源。
  // 输入/输出及副作用：phase 控制 UVM 调度；task 驱动事务、断言和 objection，测试 fixture 由本层负责清理。
  //   阶段提前结束或前置 setup 失败时必须释放 objection 并停止后续访问。
  // 失败/边界：setup 失败或阶段被终止时停止新增事务，确保 objection、临时对象和外部引用按测试生命周期收尾。
  virtual task run_phase(uvm_phase phase);
    phase.raise_objection(this);
    codec = rdma_xtr_v1_error_codec::type_id::create("xtr_v1_error_codec");
    check_fixed_classifications();
    check_holes_and_unknown_families();
    check_engine_policy_and_success();
    phase.drop_objection(this);
  endtask
endclass
