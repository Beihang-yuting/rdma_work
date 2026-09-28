// 目录：核心执行层 core/rdma_core_pkg.sv。
// 职责：按依赖顺序聚合核心执行类，使 scheduler、CMQ transport 与 engine
//   在同一 package 中形成稳定可见边界。
// 依赖：依赖 types/model/adapter/codec package 和 UVM；内部 include 必须
//   保持先定义后使用。
// 所有权与生命周期：package 不拥有运行资源；各对象按自身契约拥有快照/账本，
//   外部 adapter 保存为非拥有引用。

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
  `include "rdma_pcie_bar_allocator.sv"
  `include "rdma_sriov_enumerator.sv"
  `include "rdma_resource_allocator_policy.sv"
  `include "rdma_resource_transaction_models.sv"
  `include "rdma_resource_dependency_policy.sv"
  `include "rdma_queue_role_cardinality_policy.sv"
  `include "rdma_resource_manager.sv"
  `include "rdma_responder_registry.sv"
  `include "rdma_srq_preflight_value_policy.sv"
  `include "rdma_queue_borrowed_role_policy.sv"
  `include "rdma_queue_lifecycle_policy.sv"
  `include "rdma_queue_cleanup_recipe_policy.sv"
  `include "rdma_queue_lifecycle_opcode_policy.sv"
  `include "rdma_queue_backing_planner.sv"
  `include "rdma_queue_cursor_policy.sv"
  `include "rdma_queue_runtime_transaction_models.sv"
  `include "rdma_queue_release_order_policy.sv"
  `include "rdma_queue_mmio_transition_policy.sv"
  `include "rdma_queue_runtime.sv"
  `include "rdma_queue_backing_access.sv"
  `include "rdma_queue_data_transaction_models.sv"
  `include "rdma_queue_wq_target_policy.sv"
  `include "rdma_coverage.sv"
  `include "rdma_doorbell_scheduler.sv"
  `include "rdma_queue_data_engine.sv"
  `include "rdma_queue_facade_configuration.sv"
  `include "rdma_sq_engine.sv"
  `include "rdma_rq_engine.sv"
  `include "rdma_cq_shadow_replay_policy.sv"
  `include "rdma_cq_engine.sv"
  `include "rdma_eq_engine.sv"
  `include "rdma_cmq_port.sv"
  `include "rdma_cmq_ambiguity_policy.sv"
  `include "rdma_cmq_legacy_dispatch.sv"
  `include "rdma_queue_lifecycle_executor.sv"
  `include "rdma_qp_transition_policy.sv"
  `include "rdma_qp_urc_backing_policy.sv"
  `include "rdma_qp_lifecycle_executor.sv"
  `include "rdma_control_plane.sv"
  `include "rdma_cmq_transport.sv"
  `include "rdma_cmq_engine_transaction_models.sv"
  `include "rdma_cmq_transaction_kernel.sv"
  `include "rdma_cmq_engine.sv"
  `include "rdma_cmq_engine_port_adapter.sv"
  `include "rdma_sq_payload_writer.sv"
  `include "rdma_env_config.sv"
  `include "rdma_env.sv"
endpackage
