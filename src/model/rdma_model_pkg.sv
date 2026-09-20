// 目录：模型层 model/rdma_model_pkg.sv。
// 职责：汇编并导出 RDMA handle、上下文、提交证据、CMQ 及队列模型，固定源码可见顺序。
// 依赖：导入 uvm_pkg 与 rdma_types_pkg，并包含 model 目录中的公开类型和对象定义。
// 所有权与生命周期：package 只建立编译期命名空间，不创建或持有运行期对象与外部资源。

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
  `include "rdma_submission_evidence.sv"
  `include "rdma_cmq_engine_models.sv"
  `include "rdma_cmq_execution_models.sv"
  `include "rdma_cmq_value_contract.sv"
  `include "rdma_cmq_typed_snapshot_contract.sv"
  `include "rdma_control_plane_models.sv"
  `include "rdma_cmq_journal_value_contract.sv"
  `include "rdma_queue_models.sv"
  `include "rdma_cmq_body_value_contract.sv"
endpackage
