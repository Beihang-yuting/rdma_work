package rdma_codec_pkg;
  import uvm_pkg::*;
  import rdma_types_pkg::*;
  import rdma_model_pkg::*;
  `include "uvm_macros.svh"
  `include "xtr_v1/rdma_xtr_v1_defs.svh"

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
  `include "xtr_v1/rdma_xtr_v1_qword_codec.svh"
  `include "xtr_v1/rdma_xtr_v1_doorbell_codecs.svh"
  `include "xtr_v1/rdma_xtr_v1_qpc_codecs.svh"
  `include "xtr_v1/rdma_xtr_v1_context_body_codecs.svh"
  `include "xtr_v1/rdma_xtr_v1_cmq_codecs.svh"
  `include "xtr_v1/rdma_xtr_v1_error_codec.svh"
endpackage
