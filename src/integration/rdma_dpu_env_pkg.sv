// 目录：src/integration/，为 dpu_common→RDMA 集成层提供单一 package 入口。
// 职责：导入 UVM、RDMA 基础类型/模型/适配器/核心类型和 dpu_common 资源类型，
//       按依赖顺序包含 identity、Host-memory、PCIe、reset、Function context 与 device env。
// 依赖：外部 dpu_common/src/dpu_resource_pkg.sv；本 package 不拥有外部环境对象。
// 所有权与生命周期：package 类型在编译单元生命周期内可见；其中各 env/router 的对象
//       所有权仍由调用方和外部 PCIe/Host-memory 环境分别承担。
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
