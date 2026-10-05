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

  typedef enum bit [1:0] {
    RDMA_CQE_32B = 2'd0,
    RDMA_CQE_64B = 2'd1,
    RDMA_CQE_128B = 2'd2
  } rdma_cqe_size_e;

  typedef struct {
    bit [31:0] qpn;
    bit [63:0] wr_id;
    bit valid;
  } rdma_cqe_fields;

  // CQE layout is an immutable value object describing profile size and the
  // byte offset at which the common completion header starts.
  class rdma_cqe_layout extends uvm_object;
    `uvm_object_utils(rdma_cqe_layout)
    rdma_cqe_size_e size_profile;
    int unsigned bytes;
    int unsigned header_offset;

    // 功能：构造 CQE layout，保存 profile 大小与 header 起始偏移。
    // 输入/输出及副作用：name/profile/offset 为输入；对象字段被初始化，不拥有外部资源。
    // 失败/边界：非法 profile、非 16B 对齐偏移或偏移超出 entry 会生成 bytes=0 的无效布局。
    function new(string name="rdma_cqe_layout", rdma_cqe_size_e profile=RDMA_CQE_64B, int unsigned offset=0);
      super.new(name); size_profile=profile; header_offset=offset; bytes=0;
      case (profile)
        RDMA_CQE_32B: bytes=RDMA_CQE_32B_BYTES;
        RDMA_CQE_64B: bytes=RDMA_CQE_64B_BYTES;
        RDMA_CQE_128B: bytes=RDMA_CQE_128B_BYTES;
        default: bytes=0;
      endcase
      if ((offset % 16) != 0 || offset > bytes ||
          (bytes - offset) < 16) bytes=0;
    endfunction

    // 功能：验证 layout 的 profile、字节数和 header 偏移共同描述受支持的 CQE entry。
    // 输入/输出及副作用：无显式输入；返回验证结果，不修改 layout 或外部资源。
    // 失败/边界：profile 非法、bytes 被篡改、header 未按 16B 对齐或公共 header 越界时返回 0。
    function bit valid();
      int unsigned expected;
      case (size_profile)
        RDMA_CQE_32B: expected = RDMA_CQE_32B_BYTES;
        RDMA_CQE_64B: expected = RDMA_CQE_64B_BYTES;
        RDMA_CQE_128B: expected = RDMA_CQE_128B_BYTES;
        default: expected = 0;
      endcase
      if (expected == 0 || bytes != expected ||
          (header_offset % 16) != 0 || header_offset > bytes)
        return 1'b0;
      return (bytes - header_offset) >= 16;
    endfunction

    // 功能：按字节数和 header 偏移创建 CQE layout。
    // 输入/输出及副作用：entry_bytes/header 为输入；返回独立 layout 值对象。
    // 失败/边界：entry_bytes 不是 32/64/128 或 header 未对齐时返回 bytes=0 的无效对象。
    static function rdma_cqe_layout for_bytes(int unsigned entry_bytes, int unsigned header=0);
      rdma_cqe_size_e p;
      rdma_cqe_layout result;
      rdma_cqe_layout invalid_layout;
      case (entry_bytes)
        32: p=RDMA_CQE_32B;
        64: p=RDMA_CQE_64B;
        128: p=RDMA_CQE_128B;
        default: begin
          invalid_layout = rdma_cqe_layout::type_id::create("invalid_cqe_layout");
          invalid_layout.size_profile = RDMA_CQE_64B;
          invalid_layout.header_offset = 1;
          invalid_layout.bytes = 0;
          return invalid_layout;
        end
      endcase
      result = rdma_cqe_layout::type_id::create("cqe_layout");
      result.size_profile = p;
      result.header_offset = header;
      case (p)
        RDMA_CQE_32B: result.bytes = RDMA_CQE_32B_BYTES;
        RDMA_CQE_64B: result.bytes = RDMA_CQE_64B_BYTES;
        RDMA_CQE_128B: result.bytes = RDMA_CQE_128B_BYTES;
        default: result.bytes = 0;
      endcase
      if ((header % 16) != 0 || header > result.bytes ||
          (result.bytes - header) < 16)
        result.bytes = 0;
      return result;
    endfunction
  endclass

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
  `include "rdma/rdma_qword_codec.sv"
  `include "rdma/rdma_queue_page_codec.sv"
  `include "rdma/rdma_sge_authority.sv"
  `include "rdma/rdma_queue_codecs.sv"
  `include "rdma/rdma_doorbell_codecs.sv"
  `include "rdma/rdma_qpc_codecs.sv"
  `include "rdma/rdma_context_body_codecs.sv"
  `include "rdma/rdma_cmq_codecs.sv"
  `include "rdma/rdma_error_codec.sv"
  `include "rdma/rdma_cmq_hw_profile.sv"
endpackage
