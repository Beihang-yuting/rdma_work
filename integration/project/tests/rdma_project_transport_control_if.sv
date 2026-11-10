// 目录/层次：integration/project/tests；独立测试拥有的双端口复位控制接口。
// 所有权/生命周期：测试顶层拥有时钟与复位状态；virtual interface 由测试借用至仿真结束。
// 职责：生成时钟、初始复位，并让测试注入真正 Intel 引脚复位；不实现 DUT 行为。
// 依赖：无；时钟与 rst_n 由本接口拥有，virtual interface 仅在本次仿真借用。
interface rdma_project_transport_control_if;
  timeunit 1ns;
  timeprecision 1ps;
  bit	clk = 0;
  bit [1:0]	rst_n = 0;
  always #1ns clk = ~clk;
  initial begin
    repeat (8) @(negedge clk);
    rst_n = '1;
  end
  // 功能：对选定物理端口施加五拍低有效复位，验证旧 DMA context 失效。
  // 输入/输出及副作用：port 必须为 0/1；修改 rst_n 后等待五拍并释放复位。
  // 失败/边界：非法端口立即 fatal；任务无取消，完成只表示复位释放，不表示信用重新就绪。
  task reset_port(int unsigned	port);
    if (port > 1)
      $fatal(1, "invalid reset port");
    @(negedge clk);
    rst_n[port] = 0;
    repeat (5) @(negedge clk);
    rst_n[port] = 1;
  endtask
endinterface
