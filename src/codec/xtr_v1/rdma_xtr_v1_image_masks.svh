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

function automatic bit [63:0] request_envelope_mask(
    int unsigned qword_index);
  if (qword_index > 7)
    return '0;
  return XTR_V1_CMQ_ENVELOPE_MASK[qword_index];
endfunction

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
          if (pbl_mode != 0)
            return 0;
          mask = XTR_V1_MRT_KEY_ALLOC_PBL0_BODY_MASK[qword_index];
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
