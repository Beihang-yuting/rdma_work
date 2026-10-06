// 目录：测试层 rdma_unit_test_pkg.sv。
// 职责：作为单元测试 package 的 import/include 注册入口，按依赖顺序组织 mock、
//   fixture 与 UVM test class 的可见域，不实现或驱动任何 runtime 事务。
// 依赖：依赖被测 package、UVM 基类以及被 include 的 mock/fixture 源文件。
// 所有权与生命周期：本 package 不拥有 runtime、queue、mapping 或 Host-memory；
//   被注册测试在各自 run_phase 中按自身 fixture 规则申请和释放资源。

`ifdef RDMA_HOST_MEM_TEST
  // 外部 host_mem_manager 原始文件以 compilation-unit 形式提供。把它包在
  // 本地命名 package 中只改变 SystemVerilog 可见域，不复制或修改外部源码，
  // 这样 package 内的测试可以通过显式 qualified name 使用同一个 concrete type。
  package rdma_host_mem_external_pkg;
    import uvm_pkg::*;
    import host_mem_pkg::*;
    `include "host_mem_manager.sv"
  endpackage
`endif

package rdma_unit_test_pkg;
  import uvm_pkg::*;
  import rdma_types_pkg::*;
  import rdma_model_pkg::*;
  import rdma_codec_pkg::*;
  import rdma_adapter_pkg::*;
  import rdma_dev_pkg::*;
  import rdma_drv_pkg::*;
  import rdma_tb_pkg::*;
  import dpu_resource_pkg::*;
  import rdma_dpu_adapter_pkg::*;
`ifdef RDMA_HOST_MEM_TEST
  import rdma_host_mem_external_pkg::*;
  import host_mem_pkg::*;
  import rdma_host_mem_adapter_pkg::*;
`endif
`ifdef RDMA_NET_PACKET
  import rdma_net_packet_adapter_pkg::*;
  import rdma_net_packet_bridge_pkg::*;
`endif
  `include "uvm_macros.svh"

  `include "mocks/rdma_mock_host_mem.sv"
  `include "support/rdma_golden_reader.sv"
  `include "support/rdma_dpu_test_bar.sv"
  `include "unit/rdma_smoke_test.sv"
  `include "unit/rdma_types_test.sv"
  `include "unit/rdma_dev_cmq_test.sv"
  `include "unit/rdma_drv_cmq_test.sv"
  `include "unit/rdma_drv_cmq_golden_test.sv"
  `include "unit/rdma_drv_dev_test.sv"
  `include "unit/rdma_drv_verbs_test.sv"
  `include "unit/rdma_drv_data_test.sv"
  `include "unit/rdma_drv_reliability_test.sv"
  `include "unit/rdma_multifunc_test.sv"
  `include "unit/rdma_defs_test.sv"
  `include "unit/rdma_tb_flow_test.sv"
  `include "unit/rdma_aeqe_route_test.sv"
  `include "unit/rdma_harness_expected_failure_probe.sv"
`ifdef RDMA_NET_PACKET
  `include "integration/rdma_net_packet_adapter_test.sv"
`endif
endpackage

`ifdef RDMA_HOST_MEM_TEST
  // 真实 host_mem suite 复用上方命名 package 中的外部 manager 类型；tb 主机内存/端到端测试共享
  // 同一 concrete type，但仍由各自的 run_phase 负责申请和释放资源。
  import uvm_pkg::*;
  import host_mem_pkg::*;
  import rdma_types_pkg::*;
  import rdma_model_pkg::*;
  import rdma_adapter_pkg::*;
  import rdma_dev_pkg::*;
  import rdma_drv_pkg::*;
  import rdma_host_mem_adapter_pkg::*;
  `include "uvm_macros.svh"
  import rdma_tb_pkg::*;
  // tb 主机内存/端到端测试继承 rdma_unit_test_pkg 中的 rdma_tb_flow_test 与驱动 BAR 支撑类。
  import rdma_unit_test_pkg::*;
  `include "integration/rdma_tb_host_mem_test.sv"
`ifdef RDMA_NET_PACKET
  // 端到端测试必须在命名 host_mem manager 和 net_packet 适配器都完成编译后再展开，
  // 避免把外部依赖复制进本仓库或形成循环 typedef。
  import rdma_net_packet_adapter_pkg::*;
  import rdma_net_packet_bridge_pkg::*;
  import rdma_tb_pkg::*;
  `include "integration/rdma_tb_e2e_test.sv"
  `include "integration/rdma_tb_e2e_high_traffic_test.sv"
`endif
`endif
