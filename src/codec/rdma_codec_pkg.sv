// 目录：硬件编解码层 codec/rdma_codec_pkg.sv。
// 职责：实现 rdma_codec_pkg 在本层的职责和对外接口。
// 依赖：依赖本层公共 types/model/adapter 契约及其上游快照。
// 所有权与生命周期：对象只拥有显式创建的值快照；外部资源保存非拥有引用，生命周期由调用方管理。

// 中文说明：rdma_codec_pkg.sv 属于编码层，将模型字段转换为硬件图像并执行反向校验。
// 阅读提示：先看公开类型和接口，再看实现细节；失败路径应保持状态与资源所有权可追踪。

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

  `include "rdma_codec_base.sv"
  `include "rdma_codec_registry.sv"
  `include "rdma_bit_packer.sv"
  `include "rdma_cmq_hw_profile.sv"
  `include "xtr_v1/rdma_xtr_v1_qword_codec.sv"
  `include "xtr_v1/rdma_xtr_v1_queue_page_codec.sv"
  `include "xtr_v1/rdma_xtr_v1_queue_codecs.sv"
  `include "xtr_v1/rdma_xtr_v1_doorbell_codecs.sv"
  `include "xtr_v1/rdma_xtr_v1_qpc_codecs.sv"
  `include "xtr_v1/rdma_xtr_v1_context_body_codecs.sv"
  `include "xtr_v1/rdma_xtr_v1_cmq_codecs.sv"
  `include "xtr_v1/rdma_xtr_v1_error_codec.sv"
  `include "xtr_v1/rdma_xtr_v1_cmq_hw_profile.sv"
endpackage
