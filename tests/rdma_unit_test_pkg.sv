// 目录：测试层 rdma_unit_test_pkg.sv。
// 职责：作为单元测试 package 的 import/include 注册入口，按依赖顺序组织 mock、
//   fixture 与 UVM test class 的可见域，不实现或驱动任何 runtime 事务。
// 依赖：依赖被测 package、UVM 基类以及被 include 的 mock/fixture 源文件。
// 所有权与生命周期：本 package 不拥有 runtime、queue、mapping 或 Host-memory；
//   被注册测试在各自 run_phase 中按自身 fixture 规则申请和释放资源。

`ifdef RDMA_HOST_MEM_TEST
  // 外部 host_mem_manager 原始文件以 compilation-unit 形式提供。把它包在
  // 本地命名 package 中只改变 SystemVerilog 可见域，不复制或修改外部源码，
  // 这样 package 内的测试可以通过显式 qualified name 使用同一个 concrete type。
  package rdma_host_mem_external_pkg;
    import uvm_pkg::*;
    import host_mem_pkg::*;
    `include "host_mem_manager.sv"
  endpackage
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
  import rdma_host_mem_external_pkg::*;
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
  `include "support/rdma_cmq_contract_reader.sv"
  `include "unit/rdma_smoke_test.sv"
  `include "unit/rdma_responder_registry_test.sv"
  `include "unit/rdma_env_composition_test.sv"
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
  `include "unit/rdma_doorbell_barrier_test.sv"
  `include "unit/rdma_doorbell_scheduler_authority_test.sv"
  `include "unit/rdma_cmq_journal_factory_fixture.sv"
  `include "unit/rdma_cmq_engine_test.sv"
  `include "unit/rdma_cmq_port_test.sv"
  `include "unit/rdma_control_plane_test.sv"
  `include "unit/rdma_control_plane_cmq_engine_test.sv"
  `include "unit/rdma_codec_registry_test.sv"
  `include "unit/rdma_defs_test.sv"
  `include "unit/rdma_qword_codec_test.sv"
  `include "unit/rdma_queue_page_codec_test.sv"
  `include "unit/rdma_sriov_enumerator_authority_test.sv"
  `include "unit/rdma_queue_codec_test.sv"
  `include "unit/rdma_cqe_size_codec_test.sv"
  `include "unit/rdma_sq_codec_test.sv"
  `include "unit/rdma_ud_urc_sqe_codec_test.sv"
  `include "unit/rdma_wqe_extended_opcode_test.sv"
  `include "unit/rdma_sqe_authority_test.sv"
  `include "unit/rdma_queue_host_mem_submitter_test.sv"
  `include "unit/rdma_queue_runtime_test.sv"
  `include "unit/rdma_runtime_commit_gate_test.sv"
  `include "unit/rdma_queue_runtime_projector_test.sv"
  `include "unit/rdma_queue_backing_access_test.sv"
  `include "unit/rdma_queue_data_engine_post_test.sv"
  `include "unit/rdma_queue_detached_snapshot_test.sv"
  `include "unit/rdma_queue_consumer_steps_test.sv"
  `include "unit/rdma_queue_data_engine_device_publish_test.sv"
  `include "unit/rdma_device_publish_exit_test.sv"
  `include "unit/rdma_device_publish_prepare_test.sv"
  `include "unit/rdma_queue_event_route_consume_test.sv"
  `include "unit/rdma_aeqe_f5_e2e_test.sv"
  `include "unit/rdma_aeqe_route_test.sv"
  // resource local lookup test reuses the manager-test fixture declared above.
  `include "unit/rdma_queue_data_engine_final_fix_test.sv"
  `include "unit/rdma_cq_engine_resize_test.sv"
  `include "unit/rdma_cq_resize_exit_test.sv"
  `include "unit/rdma_queue_data_engine_poll_test.sv"
  `include "unit/rdma_host_producer_exit_test.sv"
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
  `include "unit/rdma_cmq_driver_field_mutation_test.sv"
  `include "unit/rdma_context_cmq_regression_test.sv"
  `include "unit/rdma_harness_expected_failure_probe.sv"
  `include "unit/rdma_sq_payload_writer_test.sv"
  `include "unit/rdma_function_identity_test.sv"
  `include "unit/rdma_queue_txn_journal_test.sv"
  `include "unit/rdma_abi_v5_adapter_test.sv"
  `include "unit/rdma_umem_pbl_mw_test.sv"
  `include "unit/rdma_coverage_test.sv"
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
  `include "integration/rdma_multivf_recovery_test.sv"
`endif
endpackage

`ifdef RDMA_HOST_MEM_TEST
  // 真实 host_mem suite 复用上方命名 package 中的外部 manager 类型；下面三个测试
  // 共享同一 concrete type，但仍由各自的 run_phase 负责申请和释放资源。
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
  // 双 env 端到端测试必须在命名 host_mem manager 和 net_packet 适配器
  // 都完成编译后再展开，避免把外部依赖复制进本仓库或形成循环 typedef。
  import rdma_net_packet_adapter_pkg::*;
  import rdma_net_packet_bridge_pkg::*;
  `include "integration/rdma_end_to_end_dual_env_test.sv"
  `include "integration/rdma_end_to_end_transport_test.sv"
  `include "integration/rdma_end_to_end_high_traffic_test.sv"
`endif
`endif
