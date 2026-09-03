// 中文说明：tb_top.sv 属于仿真入口或测试包，负责注册并组织验证组件。
// 阅读提示：先看公开类型和接口，再看实现细节；失败路径应保持状态与资源所有权可追踪。

module tb_top;
  import uvm_pkg::*;
  import rdma_unit_test_pkg::*;

  initial begin
    run_test();
  end
endmodule
