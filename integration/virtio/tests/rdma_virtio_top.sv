// 目录/层次：integration/virtio/tests；参照 virtio project_env_tb 的空闲结构 top。
// 职责：只提供两组 Intel VIF 和协议 VIF；依赖生产 adapter，没有 DUT/Completion responder。
// 所有权/生命周期：HDL 拥有接口，UVM 借用；#0 等所有接口登记后才启动 UVM，1ms 为挂起保护。
`timescale 1ns/1ps
module rdma_virtio_top;
    import uvm_pkg::*;
    import rdma_virtio_test_pkg::*;
    import intel_pcie_adapter_pkg::*;
    `include "uvm_macros.svh"

    logic			clk = 0;
    logic			rst_n = 0;
    intel_pcie_if #(INTEL_DATA_WIDTH, INTEL_SEGMENTS)	intel_ifs[2](clk, rst_n);
    virtio_protocol_event_if	protocol_ifs[32](clk, rst_n);

    always #2ns clk = ~clk;
    initial #20ns rst_n = 1;

    for (genvar	h = 0; h < 2; h++) begin : g_intel
        initial begin
            // 只驱应用侧的空闲输入；HARD_IP 侧信号完全由 UVM Intel adapter 驱动。
            intel_ifs[h].tx_data = '0;
            intel_ifs[h].tx_hdr = '0;
            intel_ifs[h].tx_prefix = '0;
            intel_ifs[h].tx_sop = '0;
            intel_ifs[h].tx_eop = '0;
            intel_ifs[h].tx_dvalid = '0;
            intel_ifs[h].tx_hvalid = '0;
            intel_ifs[h].tx_pvalid = '0;
            intel_ifs[h].tx_data_par = '0;
            intel_ifs[h].tx_hdr_par = '0;
            intel_ifs[h].tx_prefix_par = '0;
            intel_ifs[h].rx_ready = 1;
            intel_ifs[h].rx_hcrdt_init = '0;
            intel_ifs[h].rx_hcrdt_update = '0;
            intel_ifs[h].rx_hcrdt_update_cnt = '0;
            intel_ifs[h].rx_dcrdt_init = '0;
            intel_ifs[h].rx_dcrdt_update = '0;
            intel_ifs[h].rx_dcrdt_update_cnt = '0;
            intel_ifs[h].tx_hcrdt_init_ack = '0;
            intel_ifs[h].tx_dcrdt_init_ack = '0;
            uvm_config_db#(intel_pcie_vif_t)::set(null, "uvm_test_top",
                $sformatf("intel_vif_%0d", h), intel_ifs[h]);

        end
    end
    for (genvar	i = 0; i < 32; i++) begin : g_protocol
        initial uvm_config_db#(virtual virtio_protocol_event_if)::set(null, "uvm_test_top",
            $sformatf("protocol_event_vif_%0d", i), protocol_ifs[i]);
    end

    initial begin
        #0;
        run_test("rdma_virtio_smoke_test");
    end
    initial begin
        #1ms;
        `uvm_fatal("PROJECT_TOP", "assembly test timeout")
    end
endmodule
