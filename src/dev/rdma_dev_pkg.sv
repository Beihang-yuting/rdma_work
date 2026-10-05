// 目录：设备层 src/dev/rdma_dev_pkg.sv。
// 职责：NIC 设备侧模型的 package：只经由真实硬件边界（CMQ 环、MMIO doorbell、主机内存 DMA）
//   与主机侧驱动模型交互，设计见 docs/rdma-driver-shaped-arch.md。
// 依赖：rdma_types_pkg、rdma_model_pkg（status/mapping）、rdma_codec_pkg（rdma_defs 字段常量）、
//   rdma_adapter_pkg（rdma_host_mem_api 设备 DMA）。
// 所有权与生命周期：本层对象只借用 host_mem，设备状态归设备实例所有，随实例 reset 清空。
package rdma_dev_pkg;
  import uvm_pkg::*;
  `include "uvm_macros.svh"
  import rdma_types_pkg::*;
  import rdma_model_pkg::*;
  import rdma_codec_pkg::*;
  import rdma_adapter_pkg::*;

  typedef class rdma_dev_nic;

  `include "rdma_dev_cmq.sv"
  `include "rdma_dev_nic.sv"
  `include "rdma_dev.sv"
endpackage
