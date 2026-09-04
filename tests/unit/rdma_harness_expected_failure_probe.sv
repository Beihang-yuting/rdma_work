// 目录：测试层 unit/rdma_harness_expected_failure_probe.sv。
// 职责：验证 rdma_harness_expected_failure_probe 对应模块的接口、错误路径和边界行为。
// 依赖：依赖被测 package、UVM 测试基类和必要的 mock/fixture。
// 所有权与生命周期：测试对象只拥有本地 fixture；外部后端句柄由测试环境提供并在测试结束释放。

// 中文说明：rdma_harness_expected_failure_probe.sv 属于单元测试，覆盖对应模型、编码器或执行器契约。
// 阅读提示：先看公开类型和接口，再看实现细节；失败路径应保持状态与资源所有权可追踪。

// Deliberately excluded from normal regressions.  This probe verifies that the
// simulation harness rejects a pristine compile/run containing one UVM error.
class rdma_harness_expected_failure_probe extends uvm_test;
  `uvm_component_utils(rdma_harness_expected_failure_probe)

  // 功能：构造 rdma_harness_expected_failure_probe，调用 super.new 建立 UVM 层级对象；外部依赖字段保持未绑定，后续由 configure/build/activate 明确注入。
  // 输入/输出及副作用：name、parent（输入）；new 只写入构造体列出的默认字段并返回 void，外部依赖与资源所有权仍由上层管理。
  // 失败/边界：rdma_harness_expected_failure_probe 构造只建立本地初始状态，不接管外部 Host-memory、PCIe 或 manager；未完成后续 configure/build/activate 时，业务入口必须返回 INVALID_STATE。
  function new(string name = "rdma_harness_expected_failure_probe",
               uvm_component parent = null);
    super.new(name, parent);
  endfunction

  // 功能：在 rdma_harness_expected_failure_probe 中，run_phase 驱动 UVM 阶段中的场景初始化、事务执行和断言收尾，并在退出前释放 objection 或测试资源。
  // 输入/输出及副作用：phase（输入）；phase 由 UVM 提供；task 通过 objection、日志和断言暴露结果，可能调用 DUT 接口但不改变其所有权规则。
  // 失败/边界：run_phase 的 setup/阶段驱动失败时停止新增事务，并按测试生命周期清理 objection 与临时引用。
  task run_phase(uvm_phase phase);
    phase.raise_objection(this);
    `uvm_error("HARNESS_EXPECTED_FAILURE",
               "intentional single-error runner status probe")
    phase.drop_objection(this);
  endtask
endclass
