// 中文说明：integration package 是 dpu_common 与 RDMA 之间唯一的组合边界。
`ifndef RDMA_DPU_ENV_PKG_SV
`define RDMA_DPU_ENV_PKG_SV
package rdma_dpu_env_pkg;
  import uvm_pkg::*;
  import rdma_types_pkg::*;
  import rdma_model_pkg::*;
  import rdma_adapter_pkg::*;
  import rdma_core_pkg::*;
  import dpu_resource_pkg::*;
  `include "uvm_macros.svh"
  typedef class rdma_reset_coordinator;
  `include "rdma_dpu_identity_adapter.sv"
  `include "rdma_host_mem_router.sv"
  `include "rdma_pcie_router.sv"
  `include "rdma_reset_coordinator.sv"
  `include "rdma_function_context.sv"
  `include "rdma_device_env.sv"
endpackage
`endif
