// 目录/层次：integration/project/tests；双 Host 的 Intel wire fixture。
// 所有权/生命周期：顶层拥有接口与两个Host链路，bind实例覆盖整个仿真；UVM仅借用接口。
// 职责：两个独立 HARD_IP/APPLICATION wrapper 通过真实解析网连接，测试拥有时钟/复位。
// 依赖：产品 Intel wrapper、transport 测试包；无模型 EP、无共享 VIF 或 TLM 旁路。
// 生命周期：所有引脚到仿真结束；watchdog 对死锁报错，不能以测试未完成视为通过。
`include "intel_pcie_params.svh"
module rdma_project_transport_link #(
  parameter string	RC_ADAPTER_PATH = "uvm_test_top.env.rc_adapter_0",
  parameter string	APP_ADAPTER_PATH = "uvm_test_top.env.ep_adapter"
 ) (input wire clk, input wire rst_n);
  timeunit 1ns;
  timeprecision 1ps;
  localparam int	DATA_WIDTH = `INTEL_PCIE_DATA_WIDTH;
  localparam int	SEGMENTS = `INTEL_PCIE_SEGMENTS;
  localparam int	DATA_PARITY_WORDS = DATA_WIDTH / 32;

  wire [SEGMENTS-1:0][DATA_WIDTH-1:0]		rx_data;
  wire [SEGMENTS-1:0][127:0]			rx_hdr;
  wire [SEGMENTS-1:0][31:0]			rx_prefix;
  wire [SEGMENTS-1:0]				rx_sop;
  wire [SEGMENTS-1:0]				rx_eop;
  wire [SEGMENTS-1:0]				rx_dvalid;
  wire [SEGMENTS-1:0]				rx_hvalid;
  wire [SEGMENTS-1:0]				rx_pvalid;
  wire [SEGMENTS-1:0][2:0]			rx_empty;
  wire [SEGMENTS-1:0][2:0]			rx_bar;
  wire [SEGMENTS-1:0][2:0]			rx_pfnum;
  wire [SEGMENTS-1:0]				rx_vfactive;
  wire [SEGMENTS-1:0][10:0]			rx_vfnum;
  wire [SEGMENTS-1:0][DATA_PARITY_WORDS-1:0]	rx_data_par;
  wire [SEGMENTS-1:0][3:0]			rx_hdr_par;
  wire [SEGMENTS-1:0]				rx_prefix_par;
  wire [SEGMENTS-1:0][DATA_WIDTH-1:0]		tx_data;
  wire [SEGMENTS-1:0][127:0]			tx_hdr;
  wire [SEGMENTS-1:0][31:0]			tx_prefix;
  wire [SEGMENTS-1:0]				tx_sop;
  wire [SEGMENTS-1:0]				tx_eop;
  wire [SEGMENTS-1:0]				tx_dvalid;
  wire [SEGMENTS-1:0]				tx_hvalid;
  wire [SEGMENTS-1:0]				tx_pvalid;
  wire [SEGMENTS-1:0][DATA_PARITY_WORDS-1:0]	tx_data_par;
  wire [SEGMENTS-1:0][3:0]			tx_hdr_par;
  wire [SEGMENTS-1:0]				tx_prefix_par;
  wire						rx_ready;
  wire						tx_ready;
  wire [2:0]					rx_hcrdt_init;
  wire [2:0]					rx_hcrdt_init_ack;
  wire [2:0]					rx_hcrdt_update;
  wire [5:0]					rx_hcrdt_update_cnt;
  wire [2:0]					rx_dcrdt_init;
  wire [2:0]					rx_dcrdt_init_ack;
  wire [2:0]					rx_dcrdt_update;
  wire [11:0]					rx_dcrdt_update_cnt;
  wire [2:0]					tx_hcrdt_init;
  wire [2:0]					tx_hcrdt_init_ack;
  wire [2:0]					tx_hcrdt_update;
  wire [5:0]					tx_hcrdt_update_cnt;
  wire [2:0]					tx_dcrdt_init;
  wire [2:0]					tx_dcrdt_init_ack;
  wire [2:0]					tx_dcrdt_update;
  wire [11:0]					tx_dcrdt_update_cnt;
endmodule

bind rdma_project_transport_link intel_pcie_bind_wrapper_inout #(
  .ADAPTER_PATH(RC_ADAPTER_PATH),
  .SIDE("HARD_IP")
) hard_bind (.*);

bind rdma_project_transport_link intel_pcie_bind_wrapper_inout #(
  .ADAPTER_PATH(APP_ADAPTER_PATH),
  .SIDE("APPLICATION")
) application_bind (.*);

module rdma_project_transport_top;
  timeunit 1ns;
  timeprecision 1ps;
  import uvm_pkg::*;
  import rdma_project_transport_test_pkg::*;
  rdma_project_transport_control_if control();
  rdma_project_transport_link #(
    .RC_ADAPTER_PATH("uvm_test_top.env.rc_adapter_0"),
    .APP_ADAPTER_PATH("uvm_test_top.app0")
  ) host0(control.clk, control.rst_n[0]);
  rdma_project_transport_link #(
    .RC_ADAPTER_PATH("uvm_test_top.env.rc_adapter_1"),
    .APP_ADAPTER_PATH("uvm_test_top.app1")
  ) host1(control.clk, control.rst_n[1]);
  initial begin
    #0;
    uvm_config_db#(virtual rdma_project_transport_control_if)::set(null, "uvm_test_top", "control", control);
    run_test("rdma_project_transport_test");
  end
  initial begin
    #1ms;
    $fatal(1, "project transport watchdog expired");
  end
endmodule
