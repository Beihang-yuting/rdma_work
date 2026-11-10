// 目录/层次：integration/project/tests；真实Tcl/DPI模型命令测试顶层。
// 职责：启动显式模型test；脚本由simv -ucli -do选择。
// 依赖：AIP及command_test_pkg。
// 所有权：UVM test拥有运行期对象；top只启动测试并提供watchdog，不持有平台资源。
// 生命周期：run_loop等待命令，100ms仅作为挂起保护，不自动启动业务。
module rdma_project_command_top;
  timeunit 1ns;
  timeprecision 1ps;
  import uvm_pkg::*;
  import rdma_project_command_test_pkg::*;
  initial run_test("rdma_project_model_test");
  initial begin
    #100ms;
    $fatal(1, "project command watchdog expired");
  end
endmodule
