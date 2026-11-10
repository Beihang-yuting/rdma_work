// 目录/层次：integration/project/tests；配置契约回归的独立 UVM top。
// 职责：启动表/传输 fixture并提供超时；依赖 test package，无 DUT、driver 或平台复位模型。
// 所有权：UVM test拥有所有对象，top不发布资源、不注册 AIP命令。
// 生命周期：initial启动UVM；测试结束退出，1ms watchdog只在测试未完成时终止仿真。
module rdma_project_config_top;
  timeunit 1ns;
  timeprecision 1ps;
  import uvm_pkg::*;
  import rdma_project_config_test_pkg::*;
  initial run_test("rdma_project_config_test");
  initial begin
    #1ms;
    $fatal(1, "RDMA project configuration fixture timed out");
  end
endmodule
