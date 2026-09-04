// 目录：协议与资源模型层 model/rdma_model_pkg.sv。
// 职责：实现 rdma_model_pkg 在本层的职责和对外接口。
// 依赖：依赖本层公共 types/model/adapter 契约及其上游快照。
// 所有权与生命周期：对象只拥有显式创建的值快照；外部资源保存非拥有引用，生命周期由调用方管理。

// 中文说明：rdma_model_pkg.sv 属于模型层，描述语义请求、资源快照、DMA 映射及生命周期数据。
// 阅读提示：先看公开类型和接口，再看实现细节；失败路径应保持状态与资源所有权可追踪。

package rdma_model_pkg;
  import uvm_pkg::*;
  import rdma_types_pkg::*;
  `include "uvm_macros.svh"

  `include "rdma_handle.sv"
  `include "rdma_function_identity.sv"
  `include "rdma_function_binding.sv"
  `include "rdma_dma_request_context.sv"
  `include "rdma_dma_mapping.sv"
  `include "rdma_resource_refs.sv"
  `include "rdma_context_types.sv"
  `include "rdma_queue_lifecycle_models.sv"
  `include "rdma_hw_image.sv"
  `include "rdma_semantic_requests.sv"
  `include "rdma_queue_txn_types.sv"
  `include "rdma_resources.sv"
  `include "rdma_context_layouts.sv"
  `include "rdma_context_models.sv"
  `include "rdma_cmq_engine_models.sv"
  `include "rdma_control_plane_models.sv"
  `include "rdma_queue_models.sv"
endpackage
