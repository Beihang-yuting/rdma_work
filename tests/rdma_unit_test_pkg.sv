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
`endif
`ifdef RDMA_HOST_MEM_TEST
  import host_mem_pkg::*;
  import rdma_host_mem_adapter_pkg::*;
`endif
  `include "uvm_macros.svh"

  `include "rdma_mock_adapters.sv"
  `include "mocks/rdma_mock_control_plane.sv"
  `include "mocks/rdma_mock_context_backing.sv"
  `include "support/rdma_xtr_v1_golden_reader.sv"
  `include "unit/rdma_smoke_test.sv"
  `include "unit/rdma_types_test.sv"
  `include "unit/rdma_model_test.sv"
  `include "unit/rdma_cmq_engine_models_test.sv"
  `include "unit/rdma_control_plane_models_test.sv"
  `include "unit/rdma_context_model_test.sv"
  `include "unit/rdma_request_model_test.sv"
  `include "unit/rdma_sq_models_test.sv"
  `include "unit/rdma_xtr_v1_queue_model_test.sv"
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
  `include "unit/rdma_xtr_v1_defs_test.sv"
  `include "unit/rdma_xtr_v1_qword_codec_test.sv"
  `include "unit/rdma_xtr_v1_queue_page_codec_test.sv"
  `include "unit/rdma_xtr_v1_queue_codec_test.sv"
  `include "unit/rdma_xtr_v1_sq_codec_test.sv"
  `include "unit/rdma_xtr_v1_queue_host_mem_submitter_test.sv"
  `include "unit/rdma_queue_runtime_test.sv"
  `include "unit/rdma_queue_backing_access_test.sv"
  `include "unit/rdma_queue_data_engine_post_test.sv"
  `include "unit/rdma_queue_data_engine_poll_test.sv"
  `include "unit/rdma_queue_data_engine_recovery_test.sv"
  `include "unit/rdma_xtr_v1_doorbell_codec_test.sv"
  `include "unit/rdma_xtr_v1_qpc_codec_test.sv"
  `include "unit/rdma_xtr_v1_context_body_codec_test.sv"
  `include "unit/rdma_xtr_v1_cmq_codec_test.sv"
  `include "unit/rdma_xtr_v1_error_codec_test.sv"
  `include "unit/rdma_xtr_v1_cmq_completion_test.sv"
  `include "unit/rdma_xtr_v1_cmq_profile_test.sv"
  `include "unit/rdma_xtr_v1_context_cmq_regression_test.sv"
  `include "unit/rdma_harness_expected_failure_probe.sv"
  `include "unit/rdma_sq_payload_writer_test.sv"
  `include "unit/rdma_function_identity_test.sv"
  `include "unit/rdma_queue_txn_journal_test.sv"
`ifdef RDMA_DPU_INTEGRATION
  `include "integration/rdma_dpu_integration_test.sv"
  `include "unit/rdma_host_mem_router_test.sv"
  `include "unit/rdma_pcie_router_test.sv"
`endif
endpackage

`ifdef RDMA_HOST_MEM_TEST
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
`endif
