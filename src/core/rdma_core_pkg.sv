// 目录：核心执行层 core/rdma_core_pkg.sv。
// 职责：实现 rdma_core_pkg 在本层的职责和对外接口。
// 依赖：依赖本层公共 types/model/adapter 契约及其上游快照。
// 所有权与生命周期：对象只拥有显式创建的值快照；外部资源保存非拥有引用，生命周期由调用方管理。

// 中文说明：rdma_core_pkg.sv 属于核心执行层，负责队列、控制面、资源和恢复流程。
// 阅读提示：先看公开类型和接口，再看实现细节；失败路径应保持状态与资源所有权可追踪。

package rdma_core_pkg;
  import uvm_pkg::*;
  import rdma_types_pkg::*;
  import rdma_model_pkg::*;
  import rdma_adapter_pkg::*;
  import rdma_codec_pkg::*;
  `include "uvm_macros.svh"

  `include "rdma_stag_key_policy.sv"
  `include "rdma_hmc_allocator.sv"
  `include "rdma_resource_manager.sv"
  `include "rdma_queue_lifecycle_policy.sv"
  `include "rdma_queue_backing_planner.sv"
  `include "rdma_queue_runtime.sv"
  `include "rdma_queue_backing_access.sv"
  `include "rdma_doorbell_scheduler.sv"
  `include "rdma_queue_data_engine.sv"
  `include "rdma_cmq_port.sv"
  `include "rdma_queue_lifecycle_executor.sv"
  `include "rdma_qp_lifecycle_executor.sv"
  `include "rdma_control_plane.sv"
  `include "rdma_cmq_engine.sv"
  `include "rdma_cmq_engine_port_adapter.sv"
  `include "rdma_sq_payload_writer.sv"
endpackage
