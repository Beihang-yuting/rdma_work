package rdma_codec_pkg;
  import uvm_pkg::*;
  import rdma_types_pkg::*;
  import rdma_model_pkg::*;
  `include "uvm_macros.svh"

  typedef struct {
    string hw_version;
    rdma_image_kind_e image_kind;
    string object_type;
    string variant;
    bit [7:0] opcode;
  } rdma_codec_key;

  `include "rdma_codec_base.svh"
  `include "rdma_codec_registry.svh"
  `include "rdma_bit_packer.svh"
endpackage
