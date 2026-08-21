package rdma_unit_test_pkg;
  import uvm_pkg::*;
  import rdma_types_pkg::*;
  import rdma_model_pkg::*;
  import rdma_core_pkg::*;
  import rdma_adapter_pkg::*;
`ifdef RDMA_HOST_MEM_TEST
  import host_mem_pkg::*;
  import rdma_host_mem_adapter_pkg::*;
  // host_mem_manager is intentionally a $unit-scope class upstream.  Include
  // the pinned implementation here so the dedicated test package can use the
  // real manager without changing or copying the external dependency.
  `include "host_mem_manager.sv"
`endif
  `include "uvm_macros.svh"

  `include "rdma_mock_adapters.svh"
  `include "unit/rdma_smoke_test.svh"
  `include "unit/rdma_types_test.svh"
  `include "unit/rdma_model_test.svh"
  `include "unit/rdma_request_model_test.svh"
  `include "unit/rdma_adapter_contract_test.svh"
  `include "unit/rdma_resource_manager_test.svh"
  `include "unit/rdma_harness_expected_failure_probe.svh"
`ifdef RDMA_HOST_MEM_TEST
  `include "integration/rdma_host_mem_adapter_test.svh"
`endif
endpackage
