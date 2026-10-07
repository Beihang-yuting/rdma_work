// 目录：测试层 tb_top.sv。
// 职责：验证 tb_top 对应模块的接口、错误路径和边界行为。
// 依赖：依赖被测 package、UVM 测试基类和必要的 mock/fixture。
// 所有权与生命周期：测试对象只拥有本地 fixture；外部后端句柄由测试环境提供并在测试结束释放。

// 中文说明：tb_top.sv 属于仿真入口或测试包，负责注册并组织验证组件。
// 阅读提示：先看公开类型和接口，再看实现细节；失败路径应保持状态与资源所有权可追踪。

module tb_top;
  import uvm_pkg::*;
  import rdma_unit_test_pkg::*;
`ifdef RDMA_ENV_TEST
  import rdma_env_test_pkg::*;
`endif

  initial begin
    run_test();
  end
endmodule
