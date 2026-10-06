// 目录：核心执行层 core/rdma_core_pkg.sv。
// 职责：CMQ 参考引擎（cmq.c 环/pending/watchdog 语义）及其 transport 与 doorbell 调度器，供 CMQ
//   golden 门禁与驱动契约测试使用；数据面与资源管理由 src/drv（驱动模型）与 src/dev（设备模型）承担。
// 依赖：依赖 types/model/adapter/codec package 和 UVM；内部 include 必须
//   保持先定义后使用。
// 所有权与生命周期：package 不拥有运行资源；各对象按自身契约拥有快照/账本，
//   外部 adapter 保存为非拥有引用。

package rdma_core_pkg;
  import uvm_pkg::*;
  import rdma_types_pkg::*;
  import rdma_model_pkg::*;
  import rdma_adapter_pkg::*;
  import rdma_codec_pkg::*;
  `include "uvm_macros.svh"

  `include "rdma_doorbell_scheduler.sv"
  `include "rdma_cmq_transport.sv"
  `include "rdma_cmq_engine.sv"
endpackage
