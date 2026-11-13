// 目录/层次：integration/virtio；virtio_work project_env 的 RDMA 组合入口。
// 职责：导出独立项目配置入口、组合写表 sequence 和 Tcl test；cfg/env 由本地 project_env_pkg 提供。
// 依赖：integration project_env_pkg overlay、RDMA 核心/AIP/DPU 和配置 sequence 包。
// 所有权/生命周期：package 只定义类型；命令由平台直接注册或示例 test 在 EOE 注册，资源由 env/平台拥有。
package rdma_virtio_pkg;
  timeunit 1ns;
  timeprecision 1ps;

  import uvm_pkg::*;
  import aip_core_pkg::*;
  import host_mem_pkg::*;
  import dpu_resource_pkg::*;
  import dpu_pcie_pkg::*;
  import pcie_tl_pkg::*;
  import project_env_pkg::*;
  import virtio_net_pkg::*;
  import virtio_dpu_pkg::*;
  import rdma_types_pkg::*;
  import rdma_env_pkg::*;
  import rdma_aip_cfg_pkg::*;
  import rdma_dpu_adapter_pkg::*;
  import rdma_project_pkg::*;
  import rdma_aip_pkg::*;
  `include "uvm_macros.svh"

  `include "rdma_virtio_cfg_seq.sv"
  `include "project_dut_config_seq.sv"
  `include "rdma_virtio_test.sv"
endpackage
