// 目录：驱动层 src/drv/rdma_drv_pkg.sv。
// 职责：按 rdma-driver-0.1.34 内核态路径编写的主机侧驱动模型 package，只经 BAR 寄存器写、
//   主机内存 DMA 缓冲区与 CMQ 和设备交互，设计见 docs/rdma-driver-shaped-arch.md。
// 依赖：rdma_types_pkg、rdma_model_pkg（status/mapping/DMA 请求上下文）、rdma_codec_pkg（字段常量、
//   rdma_be）、rdma_adapter_pkg（rdma_host_mem_api）。
// 所有权与生命周期：驱动对象拥有自己分配的 DMA 缓冲区并在 destroy/remove 时释放。
package rdma_drv_pkg;
  import uvm_pkg::*;
  `include "uvm_macros.svh"
  import rdma_types_pkg::*;
  import rdma_model_pkg::*;
  import rdma_codec_pkg::*;
  import rdma_adapter_pkg::*;

  // 按 rdma_defs.svh 字段三元组写字段（驱动 FIELD_PREP + set_64bit_val）。
  `define RDMA_DRV_SET(BYTES, STEM, VALUE) \
    rdma_be::set_field(BYTES, STEM``_WORD_BYTE_OFFSET, STEM``_LSB, STEM``_WIDTH, VALUE);

  `include "rdma_drv_hw.sv"
  `include "rdma_drv_cmq.sv"
  `include "rdma_drv_mem.sv"
  `include "rdma_drv_dev.sv"
endpackage
