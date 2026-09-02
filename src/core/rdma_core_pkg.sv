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
endpackage
