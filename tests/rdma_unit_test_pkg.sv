// 目录：测试层 rdma_unit_test_pkg.sv。
// 职责：作为单元测试 package 的 import/include 注册入口，按依赖顺序组织 fixture 与 UVM test class
//   的可见域，不实现或驱动任何 runtime 事务。
// 依赖：依赖被测 package、UVM 基类以及被 include 的 fixture 源文件。
// 所有权与生命周期：本 package 不拥有 runtime、queue、mapping 或 Host-memory；
//   被注册测试在各自 run_phase 中按自身 fixture 规则申请和释放资源。

package rdma_unit_test_pkg;
  import uvm_pkg::*;
  import rdma_types_pkg::*;
  import rdma_model_pkg::*;
  import rdma_codec_pkg::*;
  import rdma_host_mem_pkg::*;
  import rdma_dev_pkg::*;
  import rdma_drv_pkg::*;
  import dpu_resource_pkg::*;
  import rdma_dpu_adapter_pkg::*;
  import rdma_netpkt_pkg::*;
`ifdef RDMA_PCIE_WORK_TEST
  import pcie_tl_pkg::*;
  import rdma_pcie_work_pkg::*;
`endif
`ifdef RDMA_RXE_TEST
  import rdma_rxe_pkg::*;
`endif
  `include "uvm_macros.svh"

  `include "support/rdma_golden_reader.sv"
  `include "support/rdma_dpu_test_system.sv"
  `include "unit/rdma_smoke_test.sv"
  `include "unit/rdma_types_test.sv"
  `include "unit/rdma_dev_cmq_test.sv"
  `include "unit/rdma_drv_cmq_test.sv"
  `include "unit/rdma_drv_cmq_golden_test.sv"
  `include "unit/rdma_drv_dev_test.sv"
  `include "unit/rdma_drv_verbs_test.sv"
  `include "unit/rdma_drv_data_test.sv"
  `include "unit/rdma_drv_reliability_test.sv"
  `include "unit/rdma_drv_qp_lifecycle_test.sv"
  `include "unit/rdma_multifunc_test.sv"
  `include "unit/rdma_defs_test.sv"
  `include "unit/rdma_aeqe_route_test.sv"
  `include "unit/rdma_harness_expected_failure_probe.sv"
  `include "unit/rdma_netpkt_codec_test.sv"
`ifdef RDMA_RXE_TEST
  `include "integration/rdma_rxe_test.sv"
  `include "integration/rdma_rxe_fault_test.sv"
`endif
endpackage
