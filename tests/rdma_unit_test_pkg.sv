// 目录：测试层 rdma_unit_test_pkg.sv。
// 职责：验证 rdma_unit_test_pkg 对应模块的接口、错误路径和边界行为。
// 依赖：依赖被测 package、UVM 测试基类和必要的 mock/fixture。
// 所有权与生命周期：测试对象只拥有本地 fixture；外部后端句柄由测试环境提供并在测试结束释放。

// 中文说明：rdma_unit_test_pkg.sv 属于仿真入口或测试包，负责注册并组织验证组件。
// 阅读提示：先看公开类型和接口，再看实现细节；失败路径应保持状态与资源所有权可追踪。

`ifdef RDMA_HOST_MEM_TEST
  // host_mem_manager is intentionally a $unit-scope class upstream.  Include
  // the pinned implementation at compilation-unit scope to preserve its
  // original type identity without changing or copying the dependency.
  `include "host_mem_manager.sv"
`endif

package rdma_unit_test_pkg;
  import uvm_pkg::*;
  import rdma_types_pkg::*;
  import rdma_model_pkg::*;
  import rdma_codec_pkg::*;
  import rdma_core_pkg::*;
  import rdma_adapter_pkg::*;
  // Disambiguate the shared recovery enum from the legacy core compatibility type.
  import rdma_model_pkg::rdma_queue_recovery_action_e;
`ifdef RDMA_DPU_INTEGRATION
  import rdma_dpu_env_pkg::*;
  // 测试夹具需要直接构造 dpu_common snapshot，以验证 integration 边界的
  // 查询语义；生产代码仍只依赖 rdma_dpu_env_pkg 的适配接口。
  import dpu_resource_pkg::*;
`endif
`ifdef RDMA_HOST_MEM_TEST
  import host_mem_pkg::*;
  import rdma_host_mem_adapter_pkg::*;
`endif
`ifdef RDMA_NET_PACKET
  import rdma_net_packet_adapter_pkg::*;
  import rdma_net_packet_bridge_pkg::*;
`endif
`ifdef RDMA_PCIE_WORK_TEST
  import pcie_tl_pkg::*;
  import pcie_tl_device_profile_pkg::*;
  import rdma_pcie_work_adapter_pkg::*;
`endif
  `include "uvm_macros.svh"

  `include "rdma_mock_adapters.sv"
  `include "mocks/rdma_mock_control_plane.sv"
  `include "mocks/rdma_mock_context_backing.sv"
  `include "support/rdma_golden_reader.sv"
  `include "unit/rdma_smoke_test.sv"
  `include "unit/rdma_responder_registry_test.sv"
  `include "unit/rdma_types_test.sv"
  `include "unit/rdma_model_test.sv"
  `include "unit/rdma_cmq_engine_models_test.sv"
  `include "unit/rdma_control_plane_models_test.sv"
  `include "unit/rdma_context_model_test.sv"
  `include "unit/rdma_request_model_test.sv"
  `include "unit/rdma_sq_models_test.sv"
  `include "unit/rdma_queue_model_test.sv"
  `include "unit/rdma_adapter_contract_test.sv"
  `include "unit/rdma_resource_manager_test.sv"
  `include "unit/rdma_queue_lifecycle_models_test.sv"
  `include "unit/rdma_queue_lifecycle_test.sv"
  `include "unit/rdma_qp_lifecycle_test.sv"
  `include "unit/rdma_qp_recovery_test.sv"
  `include "unit/rdma_queue_recovery_test.sv"
  `include "unit/rdma_context_backing_contract_test.sv"
  `include "unit/rdma_doorbell_scheduler_test.sv"
  `include "unit/rdma_cmq_engine_test.sv"
  `include "unit/rdma_cmq_port_test.sv"
  `include "unit/rdma_control_plane_test.sv"
  `include "unit/rdma_control_plane_cmq_engine_test.sv"
  `include "unit/rdma_codec_registry_test.sv"
  `include "unit/rdma_defs_test.sv"
  `include "unit/rdma_qword_codec_test.sv"
  `include "unit/rdma_queue_page_codec_test.sv"
  `include "unit/rdma_queue_codec_test.sv"
  `include "unit/rdma_cqe_size_codec_test.sv"
  `include "unit/rdma_sq_codec_test.sv"
  `include "unit/rdma_ud_urc_sqe_codec_test.sv"
  `include "unit/rdma_wqe_extended_opcode_test.sv"
  `include "unit/rdma_sqe_authority_test.sv"
  `include "unit/rdma_queue_host_mem_submitter_test.sv"
  `include "unit/rdma_queue_runtime_test.sv"
  `include "unit/rdma_queue_backing_access_test.sv"
  `include "unit/rdma_queue_data_engine_post_test.sv"
  `include "unit/rdma_cq_engine_resize_test.sv"
  `include "unit/rdma_queue_data_engine_poll_test.sv"
  `include "unit/rdma_queue_data_engine_recovery_test.sv"
  `include "unit/rdma_sq_engine_test.sv"
  `include "unit/rdma_rq_engine_test.sv"
  `include "unit/rdma_cq_engine_test.sv"
  `include "unit/rdma_cq_shadow_flush_test.sv"
  `include "unit/rdma_eq_engine_test.sv"
  `include "unit/rdma_doorbell_codec_test.sv"
  `include "unit/rdma_qpc_codec_test.sv"
  `include "unit/rdma_context_body_codec_test.sv"
  `include "unit/rdma_cmq_codec_test.sv"
  `include "unit/rdma_error_codec_test.sv"
  `include "unit/rdma_cmq_completion_test.sv"
  `include "unit/rdma_cmq_profile_test.sv"
  `include "unit/rdma_context_cmq_regression_test.sv"
  `include "unit/rdma_harness_expected_failure_probe.sv"
  `include "unit/rdma_sq_payload_writer_test.sv"
  `include "unit/rdma_function_identity_test.sv"
  `include "unit/rdma_queue_txn_journal_test.sv"
  `include "unit/rdma_abi_v5_adapter_test.sv"
  `include "unit/rdma_umem_pbl_mw_test.sv"
`ifdef RDMA_NET_PACKET
  `include "integration/rdma_net_packet_adapter_test.sv"
`endif
`ifdef RDMA_PCIE_WORK_TEST
  `include "integration/rdma_pcie_work_adapter_test.sv"
  `include "integration/rdma_sriov_enumeration_test.sv"
`endif
`ifdef RDMA_DPU_INTEGRATION
  `include "integration/rdma_dpu_integration_test.sv"
  `include "unit/rdma_host_mem_router_test.sv"
  `include "unit/rdma_pcie_router_test.sv"
  `include "unit/rdma_reset_coordinator_test.sv"
  `include "integration/rdma_function_context_test.sv"
  `include "integration/rdma_device_env_test.sv"
  `include "integration/rdma_reset_cascade_test.sv"
`endif
endpackage

`ifdef RDMA_HOST_MEM_TEST
  // 真实 host_mem suite 在 package 外编译 host_mem_manager；下面三个测试
  // 共享同一外部 manager 类型，但仍由各自的 run_phase 负责申请和释放资源。
  import uvm_pkg::*;
  import host_mem_pkg::*;
  import rdma_types_pkg::*;
  import rdma_model_pkg::*;
  import rdma_core_pkg::*;
  import rdma_adapter_pkg::*;
  import rdma_host_mem_adapter_pkg::*;
  `include "uvm_macros.svh"
  `include "integration/rdma_host_mem_adapter_test.sv"
  `include "integration/rdma_queue_data_engine_host_mem_test.sv"
  `include "integration/rdma_host_mem_umem_test.sv"
`ifdef RDMA_NET_PACKET
  // 双 env 端到端测试必须在 host_mem 的 $unit 类型和 net_packet 适配器
  // 都完成编译后再展开，避免把外部依赖复制进本仓库或形成循环 typedef。
  import rdma_net_packet_adapter_pkg::*;
  import rdma_net_packet_bridge_pkg::*;
  `include "integration/rdma_end_to_end_dual_env_test.sv"
`endif
`endif
