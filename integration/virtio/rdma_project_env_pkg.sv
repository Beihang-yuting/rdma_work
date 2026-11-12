// 目录/层次：integration/virtio；RDMA 组合专用的 project_env_pkg 编译入口。
// 职责：用本地 project_env_cfg/project_env 替换外部环境入口，继续复用 virtio_work 的 seq 和 base_test。
// 依赖：virtio_work integration/project 的实现文件、RDMA env/AIP/适配器和 Intel/VIO 公共包。
// 所有权/生命周期：package 只定义类型；组件、快照、pool、VIF 和外部硬件仍由 project_env/平台拥有。
// 该入口只由 rdma_virtio.f 编译，原 virtio_work 的 project_env_pkg 不会被重复编译或改写。
package project_env_pkg;
  timeunit 1ns;
  timeprecision 1ps;

  import uvm_pkg::*;
  import aip_core_pkg::*;
  import host_mem_pkg::*;
  import dpu_resource_pkg::*;
  import dpu_pcie_pkg::*;
  import virtio_dpu_pkg::*;
  import pcie_tl_pkg::*;
  import virtio_net_pkg::*;
  import virtio_aip_pkg::*;
  import intel_pcie_adapter_pkg::*;
  import rdma_types_pkg::*;
  import rdma_env_pkg::*;
  import rdma_aip_cfg_pkg::*;
  import rdma_dpu_adapter_pkg::*;
  import rdma_project_pkg::*;
  `include "uvm_macros.svh"

  `include "project_env_cfg.sv"
  `include "project_single_queue_config_seq.sv"
  `include "project_env.sv"
  `include "project_base_test.sv"
endpackage
