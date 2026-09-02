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
`ifdef RDMA_HOST_MEM_TEST
  import host_mem_pkg::*;
  import rdma_host_mem_adapter_pkg::*;
`endif
  `include "uvm_macros.svh"

  `include "rdma_mock_adapters.svh"
  `include "mocks/rdma_mock_control_plane.svh"
  `include "mocks/rdma_mock_context_backing.svh"
  `include "support/rdma_xtr_v1_golden_reader.svh"
  `include "unit/rdma_smoke_test.svh"
  `include "unit/rdma_types_test.svh"
  `include "unit/rdma_model_test.svh"
  `include "unit/rdma_cmq_engine_models_test.svh"
  `include "unit/rdma_control_plane_models_test.svh"
  `include "unit/rdma_context_model_test.svh"
  `include "unit/rdma_request_model_test.svh"
  `include "unit/rdma_xtr_v1_queue_model_test.svh"
  `include "unit/rdma_adapter_contract_test.svh"
  `include "unit/rdma_resource_manager_test.svh"
  `include "unit/rdma_queue_lifecycle_models_test.svh"
  `include "unit/rdma_queue_lifecycle_test.svh"
  `include "unit/rdma_qp_lifecycle_test.svh"
  `include "unit/rdma_qp_recovery_test.svh"
  `include "unit/rdma_queue_recovery_test.svh"
  `include "unit/rdma_context_backing_contract_test.svh"
  `include "unit/rdma_doorbell_scheduler_test.svh"
  `include "unit/rdma_cmq_engine_test.svh"
  `include "unit/rdma_cmq_port_test.svh"
  `include "unit/rdma_control_plane_test.svh"
  `include "unit/rdma_control_plane_cmq_engine_test.svh"
  `include "unit/rdma_codec_registry_test.svh"
  `include "unit/rdma_xtr_v1_defs_test.svh"
  `include "unit/rdma_xtr_v1_qword_codec_test.svh"
  `include "unit/rdma_xtr_v1_queue_page_codec_test.svh"
  `include "unit/rdma_xtr_v1_queue_codec_test.svh"
  `include "unit/rdma_xtr_v1_queue_host_mem_submitter_test.svh"
  `include "unit/rdma_queue_runtime_test.svh"
  `include "unit/rdma_xtr_v1_doorbell_codec_test.svh"
  `include "unit/rdma_xtr_v1_qpc_codec_test.svh"
  `include "unit/rdma_xtr_v1_context_body_codec_test.svh"
  `include "unit/rdma_xtr_v1_cmq_codec_test.svh"
  `include "unit/rdma_xtr_v1_error_codec_test.svh"
  `include "unit/rdma_xtr_v1_cmq_completion_test.svh"
  `include "unit/rdma_xtr_v1_cmq_profile_test.svh"
  `include "unit/rdma_xtr_v1_context_cmq_regression_test.svh"
  `include "unit/rdma_harness_expected_failure_probe.svh"
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
  `include "integration/rdma_host_mem_adapter_test.svh"
`endif
