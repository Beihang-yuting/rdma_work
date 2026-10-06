// 目录：硬件编解码层 codec/rdma_codec_pkg.sv。
// 职责：声明 codec 包：CQE layout、codec key，并按序 include 各 codec 实现。
// 依赖：依赖 uvm_pkg、rdma_types_pkg 与 rdma_model_pkg。
// 所有权与生命周期：layout 为独立值对象，由创建者持有；包本身不持有运行期资源。

package rdma_codec_pkg;
  import uvm_pkg::*;
  import rdma_types_pkg::*;
  import rdma_model_pkg::*;
  `include "uvm_macros.svh"
  `include "rdma/rdma_defs.svh"
  `include "rdma/rdma_be_bytes.sv"
  `include "rdma/rdma_cmq_request_fields.svh"
  `include "rdma/rdma_cmq_field_codec.sv"
endpackage
