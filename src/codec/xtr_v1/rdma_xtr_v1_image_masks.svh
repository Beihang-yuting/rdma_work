// 目录：硬件编解码层 codec/xtr_v1/rdma_xtr_v1_image_masks.svh。
// 职责：提供可文本包含的宏、固定字段或掩码定义；不持有运行期对象。
// 依赖：依赖对应 codec package 的字段约定和编译期常量。
// 所有权与生命周期：宏/常量由包含它的编译单元拥有，生命周期为编译期。

// Immutable xtr_v1 request ownership masks. Each entry is a logical qword
// mask before big-endian serialization; Task 10/11 consume this lookup API.
localparam bit [63:0] XTR_V1_CMQ_ENVELOPE_MASK [0:7] = '{
  64'h8fff3fff00000000, 64'h0, 64'h0, 64'h0,
  64'h0, 64'h0, 64'h0, 64'h0
};
localparam bit [63:0] XTR_V1_CQC_CREATE_BODY_MASK [0:7] = '{
  64'h00000000001fffff, 64'hff0fffffffffffff,
  64'hfffffffffffff8ff, 64'hfffffffffff8c701,
  64'hf000000000ffffff, 64'h0000000000000fff,
  64'hffffffffffffffc0, 64'h0000000f00ffffff
};
localparam bit [63:0] XTR_V1_MRT_REGISTER_PBL0_BODY_MASK [0:7] = '{
  64'h6000000000ffffff, 64'h00000000ff000000,
  64'hffffffffff000000, 64'hff00bfffffffffff,
  64'hffffffffffffffff, 64'hfffffffffffff000,
  64'h0000000000000fff, 64'h0000000000000000
};
localparam bit [63:0] XTR_V1_MRT_KEY_ALLOC_PBL0_BODY_MASK [0:7] = '{
  64'h6000000000ffffff, 64'h00000000ff000000,
  64'hffffffffffffffff, 64'hff00bfffffffffff,
  64'hffffffffffffffff, 64'hfffffffffffff000,
  64'h0000000000000fff, 64'h0000000000000000
};
localparam bit [63:0] XTR_V1_MRT_KEY_ALLOC_PBL1_BODY_MASK [0:7] = '{
  64'h6000000000ffffff, 64'h00000000ff000000,
  64'hffffffffffffffff, 64'hff00bfffffffffff,
  64'hffffffffffffffff, 64'hfffffffffffff000,
  64'hffffffffffffffff, 64'h0000000000000000
};
localparam bit [63:0] XTR_V1_MRT_KEY_ALLOC_PBL2_BODY_MASK [0:7] = '{
  64'h6000000000ffffff, 64'h00000000ff000000,
  64'hffffffffffffffff, 64'hff00bfffffffffff,
  64'hffffffffffffffff, 64'hfffffff000000000,
  64'h0000000000000fff, 64'h0000000000000000
};
localparam bit [63:0] XTR_V1_MRT_REGISTER_PBL1_BODY_MASK [0:7] = '{
  64'h6000000000ffffff, 64'h00000000ff000000,
  64'hffffffffff000000, 64'hff00bfffffffffff,
  64'hffffffffffffffff, 64'hfffffffffffff000,
  64'hffffffffffffffff, 64'h0000000000000000
};
localparam bit [63:0] XTR_V1_MRT_REGISTER_PBL2_BODY_MASK [0:7] = '{
  64'h6000000000ffffff, 64'h00000000ff000000,
  64'hffffffffff000000, 64'hff00bfffffffffff,
  64'hffffffffffffffff, 64'hfffffff000000000,
  64'h0000000000000fff, 64'h0000000000000000
};
localparam bit [63:0] XTR_V1_SRQC_CREATE_BODY_MASK [0:7] = '{
  64'h000000000000ffff, 64'h0000000000000000,
  64'hcfffffffffffffff, 64'hffff000000000000,
  64'hfffffffffffff0fc, 64'h00000000ffffffff,
  64'h0000000000000000, 64'h0000000000000000
};
localparam bit [63:0] XTR_V1_CEQC_CREATE_BODY_MASK [0:7] = '{
  64'h0000000000000fff, 64'h0000000000000000,
  64'hc1ffffffffffffff, 64'hfffffffffffff800,
  64'h0000007ffff0c000, 64'hffff00000007ffff,
  64'h0000000000000000, 64'h0000000000000000
};
localparam bit [63:0] XTR_V1_AEQC_CREATE_BODY_MASK [0:7] = '{
  64'h0000000000000fff, 64'h0000000000000000,
  64'hc1ffffffffffffff, 64'hfffffffffffff800,
  64'h0000007ffff0c000, 64'hffff00000007ffff,
  64'h0000000000000000, 64'h0000000000000000
};
localparam bit [63:0] XTR_V1_QPC_CREATE_BODY_OWNERSHIP [0:7] = '{
  64'h0000000000ffffff, 64'hfffff801ff1fffff,
  64'h0000000000000000, 64'hfffffffffffffe00,
  64'h0000000000000000, 64'h0000000000000000,
  64'h0000000000000000, 64'h0000000000000000
};
localparam bit [63:0] XTR_V1_QPC_MODIFY_BODY_OWNERSHIP [0:7] = '{
  64'h7000000000ffffff, 64'hfffff801ff1fffff,
  64'hffffffff3fff3fff, 64'hfffffffffffffe00,
  64'hffffffffffffffff, 64'hffffffffffffffff,
  64'hffffffffffffffff, 64'hffffffffffffffff
};
localparam bit [63:0] XTR_V1_QPC_DELETE_BODY_OWNERSHIP [0:7] = '{
  64'h0000000000ffffff, 64'hfffff800001fffff,
  64'h0000000000000000, 64'h0000000000000000,
  64'h0000000000000000, 64'h0000000000000000,
  64'h0000000000000000, 64'h0000000000000000
};
localparam bit [63:0] XTR_V1_QPC_QUERY_BODY_OWNERSHIP [0:7] = '{
  64'h0000000000ffffff, 64'h0000000000000000,
  64'h0000000000000000, 64'hfffffffffffffe00,
  64'h0000000000000000, 64'h0000000000000000,
  64'h0000000000000000, 64'h0000000000000000
};
localparam bit [63:0] XTR_V1_MRT_REGISTER_BODY_OWNERSHIP [0:7] = '{
  64'h6000000000ffffff, 64'h00000000ff000000,
  64'hffffffffff000000, 64'hff00bfffffffffff,
  64'hffffffffffffffff, 64'hfffffffffffff000,
  64'hffffffffffffffff, 64'h0000000000000000
};
localparam bit [63:0] XTR_V1_MRT_KEY_ALLOC_BODY_OWNERSHIP [0:7] = '{
  64'h6000000000ffffff, 64'h00000000ff000000,
  64'hffffffffffffffff, 64'hff00bfffffffffff,
  64'hffffffffffffffff, 64'hfffffffffffff000,
  64'hffffffffffffffff, 64'h0000000000000000
};
localparam bit [63:0] XTR_V1_MR_DEREGISTER_BODY_OWNERSHIP [0:7] = '{
  64'h6000000000ffffff, 64'h00000000ff000000,
  64'h0000000000000000, 64'h0000000000000000,
  64'h0000000000000000, 64'h0000000000000000,
  64'h0000000000000000, 64'h0000000000000000
};
localparam bit [63:0] XTR_V1_OCC_FLUSH_BODY_OWNERSHIP [0:7] = '{
  64'h30000000001fffff, 64'hffc00fff00000000,
  64'hfffffffffffff000, 64'h0000000000000000,
  64'h0000000000000000, 64'h0000000000000000,
  64'h0000000000000000, 64'h0000000000000000
};
localparam bit [63:0] XTR_V1_CQ_OBJECT_ID_BODY_OWNERSHIP [0:7] = '{
  64'h00000000001fffff, 64'h0, 64'h0, 64'h0,
  64'h0, 64'h0, 64'h0, 64'h0
};
localparam bit [63:0] XTR_V1_EQ_OBJECT_ID_BODY_OWNERSHIP [0:7] = '{
  64'h0000000000000fff, 64'h0, 64'h0, 64'h0,
  64'h0, 64'h0, 64'h0, 64'h0
};
localparam bit [63:0] XTR_V1_SRQ_OBJECT_ID_BODY_OWNERSHIP [0:7] = '{
  64'h000000000000ffff, 64'h0, 64'h0, 64'h0,
  64'h0, 64'h0, 64'h0, 64'h0
};
localparam bit [63:0] XTR_V1_EMPTY_BODY_OWNERSHIP [0:7] = '{
  64'h0, 64'h0, 64'h0, 64'h0, 64'h0, 64'h0, 64'h0, 64'h0
};

// SQE logical-qword ownership masks. Reserved bits are zero and are rejected
// by consumers before serialization.
localparam bit [63:0] XTR_V1_SQ_WQE_HEADER_MASK [0:7] = '{
  64'hefffffffffffffff, 64'h0, 64'h0, 64'h0,
  64'h0, 64'h0, 64'h0, 64'h0
};
// Inline mode owns the selector bit (bit 60) that is reserved in the
// transport-neutral header mask above.
localparam bit [63:0] XTR_V1_SQ_WQE_INLINE_HEADER_MASK [0:7] = '{
  64'hffffffffffffffff, 64'h0, 64'h0, 64'h0,
  64'h0, 64'h0, 64'h0, 64'h0
};
localparam bit [63:0] XTR_V1_SQ_WQE_RC_BODY_MASK [0:7] = '{
  64'h0, 64'hffffffffffffffff, 64'hff00ffff00000000,
  64'hffffffffffffffff, 64'hfffffffffffffe00, 64'h0, 64'h0, 64'h0
};
localparam bit [63:0] XTR_V1_SQ_WQE_RC_INLINE_BODY_MASK [0:7] = '{
  64'h0, 64'hffffffffffffffff, 64'hff00ffff00000000,
  64'hffffffffffffffff, 64'hffffffffffffffff, 64'hffffffffffffffff,
  64'hffffffffffffffff, 64'hffffffffffffffff
};
localparam bit [63:0] XTR_V1_SQ_WQE_RC_DIRECT_SGE_BODY_MASK [0:7] = '{
  64'h0, 64'hffffffffffffffff, 64'hff00ffff00000000,
  64'hffffffffffffffff, 64'hffffffffffffffff, 64'hffffffffffffffff,
  64'hffffffffffffffff, 64'hffffffffffffffff
};
localparam bit [63:0] XTR_V1_SQ_WQE_UD_BODY_MASK [0:7] = '{
  64'h0, 64'hfffffffffeffffff, 64'hffffffffffffffff,
  64'hffffffffffffffff, 64'hffffffffffffffff, 64'hffffffffffffffff,
  64'hffffffffffffffff, 64'hffffffffffffffff
};
localparam bit [63:0] XTR_V1_SQ_WQE_ATOMIC_BODY_MASK [0:7] = '{
  64'h0, 64'h00000000ffffffff, 64'hff00ffff00000000,
  64'hffffffffffffffff, 64'hffffffffffffffff, 64'hffffffffffffffff,
  64'hffffffffffffffff, 64'hffffffffffffffff
};
localparam bit [63:0] XTR_V1_SQ_WQE_ATOMIC_FAA_BODY_MASK [0:7] = '{
  64'h0, 64'h00000000ffffffff, 64'hff00ffff00000000,
  64'hffffffffffffffff, 64'hffffffffffffffff, 64'hffffffffffffffff,
  64'hffffffffffffffff, 64'h0
};

  // 功能：处理 request_envelope_mask：依据其参数完成所属层的具体协议动作，并保持返回状态、游标和资源所有权一致。
  // 输入/输出及副作用：参数 qword_index 用于执行 request_envelope_mask；返回值或 output/inout 交付处理结果，必要时更新本对象状态。
  //   调用方不获得内部集合或外部依赖的所有权。
  // 失败/边界：request_envelope_mask 只接受其签名声明的输入；缺少必要字段时返回错误，成功路径不得隐式修改无关资源。
function automatic bit [63:0] request_envelope_mask(
    int unsigned qword_index);
  if (qword_index > 7)
    return '0;
  return XTR_V1_CMQ_ENVELOPE_MASK[qword_index];
endfunction

  // 功能：处理 body_mask：依据其参数完成所属层的具体协议动作，并保持返回状态、游标和资源所有权一致。
  // 输入/输出及副作用：参数 image_kind, opcode, pbl_mode, qword_index, mask 用于执行 body_mask；返回值或 output/inout 交付处理结果，必要时更新本对象状态。
  //   调用方不获得内部集合或外部依赖的所有权。
  // 失败/边界：body_mask 只接受其签名声明的输入；缺少必要字段时返回错误，成功路径不得隐式修改无关资源。
function automatic bit body_mask(
    rdma_image_kind_e image_kind,
    bit [7:0] opcode,
    int unsigned pbl_mode,
    int unsigned qword_index,
    output bit [63:0] mask);
  mask = '0;
  if (qword_index > 7)
    return 0;

  case (image_kind)
    RDMA_IMAGE_CMQ_SQE: begin
      case (opcode)
        XTR_V1_OP_QPC_CREATE:
          mask = XTR_V1_QPC_CREATE_BODY_OWNERSHIP[qword_index];
        XTR_V1_OP_QPC_MODIFY:
          mask = XTR_V1_QPC_MODIFY_BODY_OWNERSHIP[qword_index];
        XTR_V1_OP_QPC_DELETE:
          mask = XTR_V1_QPC_DELETE_BODY_OWNERSHIP[qword_index];
        XTR_V1_OP_QPC_QUERY:
          mask = XTR_V1_QPC_QUERY_BODY_OWNERSHIP[qword_index];
        XTR_V1_OP_MR_DEREGISTER:
          mask = XTR_V1_MR_DEREGISTER_BODY_OWNERSHIP[qword_index];
        XTR_V1_OP_OCC_FLUSH:
          mask = XTR_V1_OCC_FLUSH_BODY_OWNERSHIP[qword_index];
        XTR_V1_OP_CQC_DELETE, XTR_V1_OP_CQC_QUERY:
          mask = XTR_V1_CQ_OBJECT_ID_BODY_OWNERSHIP[qword_index];
        XTR_V1_OP_CEQC_DELETE, XTR_V1_OP_CEQC_QUERY,
        XTR_V1_OP_AEQC_DELETE, XTR_V1_OP_AEQC_QUERY:
          mask = XTR_V1_EQ_OBJECT_ID_BODY_OWNERSHIP[qword_index];
        XTR_V1_OP_SRFQC_DELETE, XTR_V1_OP_SRFQC_QUERY:
          mask = XTR_V1_SRQ_OBJECT_ID_BODY_OWNERSHIP[qword_index];
        XTR_V1_OP_TQ_FLUSH:
          mask = XTR_V1_EMPTY_BODY_OWNERSHIP[qword_index];
        default: return 0;
      endcase
    end
    RDMA_IMAGE_CQC: begin
      if (opcode != XTR_V1_OP_CQC_CREATE || pbl_mode != 0)
        return 0;
      mask = XTR_V1_CQC_CREATE_BODY_MASK[qword_index];
    end
    RDMA_IMAGE_MRT: begin
      case (opcode)
        XTR_V1_OP_KEY_ALLOC: begin
          case (pbl_mode)
            0: mask = XTR_V1_MRT_KEY_ALLOC_PBL0_BODY_MASK[qword_index];
            1: mask = XTR_V1_MRT_KEY_ALLOC_PBL1_BODY_MASK[qword_index];
            2: mask = XTR_V1_MRT_KEY_ALLOC_PBL2_BODY_MASK[qword_index];
            default: return 0;
          endcase
        end
        XTR_V1_OP_MR_REGISTER: begin
          case (pbl_mode)
            0: mask = XTR_V1_MRT_REGISTER_PBL0_BODY_MASK[qword_index];
            1: mask = XTR_V1_MRT_REGISTER_PBL1_BODY_MASK[qword_index];
            2: mask = XTR_V1_MRT_REGISTER_PBL2_BODY_MASK[qword_index];
            default: return 0;
          endcase
        end
        default: return 0;
      endcase
    end
    RDMA_IMAGE_SRQC: begin
      if (opcode != XTR_V1_OP_SRFQC_CREATE || pbl_mode != 0)
        return 0;
      mask = XTR_V1_SRQC_CREATE_BODY_MASK[qword_index];
    end
    RDMA_IMAGE_CEQC: begin
      if (opcode != XTR_V1_OP_CEQC_CREATE || pbl_mode != 0)
        return 0;
      mask = XTR_V1_CEQC_CREATE_BODY_MASK[qword_index];
    end
    RDMA_IMAGE_AEQC: begin
      if (opcode != XTR_V1_OP_AEQC_CREATE || pbl_mode != 0)
        return 0;
      mask = XTR_V1_AEQC_CREATE_BODY_MASK[qword_index];
    end
    default: return 0;
  endcase
  return 1;
endfunction
