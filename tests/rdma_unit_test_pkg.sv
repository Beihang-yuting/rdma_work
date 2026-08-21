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
  `include "unit/rdma_smoke_test.svh"
  `include "unit/rdma_types_test.svh"
  `include "unit/rdma_model_test.svh"
  `include "unit/rdma_request_model_test.svh"
  `include "unit/rdma_adapter_contract_test.svh"
  `include "unit/rdma_resource_manager_test.svh"
  `include "unit/rdma_codec_registry_test.svh"
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
