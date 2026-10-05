// 目录：硬件编解码层 codec/rdma/rdma_cmq_request_fields.svh（生成文件，勿手改）。
// 职责：由 tools/gen_cmq_request_fields.py 从驱动 cmq.c 填充函数生成的通用 CMQ 请求字段表。
// 依赖：rdma_defs.svh 的 RDMA_OP_* 常量。
// 所有权与生命周期：编译期常量函数，无运行期状态。

typedef struct {
  string param;
  int unsigned qword_byte;
  int unsigned lsb;
  int unsigned width;
  string transform;
} rdma_cmq_field_spec_t;

// 功能：返回 opcode 的驱动字段布局；不在表内返回 0。
// 输入/输出及副作用：specs 输出字段规格 {param, qword_byte, lsb, width, transform}（按驱动写入顺序）。
// 失败/边界：opcode 有专用编码器或驱动无该 opcode 时返回 0。
function automatic bit rdma_cmq_request_field_specs(
  input bit [7:0] opcode,
  output rdma_cmq_field_spec_t specs[$]
);
  specs.delete();
  case (opcode)
    RDMA_OP_MW_ALLOC: begin
      specs.push_back('{"mw_stag_key", 24, 56, 8, "value"});
      specs.push_back('{"pd_idx", 16, 24, 16, "value"});
      specs.push_back('{"pld_vf_id", 16, 40, 8, "value"});
      specs.push_back('{"pld_vf_en", 16, 48, 1, "value"});
      specs.push_back('{"type", 16, 54, 2, "value"});
      specs.push_back('{"invalidate_en", 16, 61, 1, "value"});
      specs.push_back('{"states", 16, 62, 2, "value"});
      specs.push_back('{"mw_stag_key", 8, 24, 8, "value"});
      specs.push_back('{"mw_stag_index", 0, 0, 24, "value"});
      specs.push_back('{"states", 0, 61, 2, "value"});
    end
    RDMA_OP_MW_DEALLOC: begin
      specs.push_back('{"mw_stag_key", 24, 56, 8, "value"});
      specs.push_back('{"pd_idx", 16, 24, 16, "value"});
      specs.push_back('{"pld_vf_id", 16, 40, 8, "value"});
      specs.push_back('{"pld_vf_en", 16, 48, 1, "value"});
      specs.push_back('{"states", 16, 62, 2, "value"});
      specs.push_back('{"mw_stag_key", 8, 24, 8, "value"});
      specs.push_back('{"mw_stag_index", 0, 0, 24, "value"});
      specs.push_back('{"states", 0, 61, 2, "value"});
    end
    RDMA_OP_KEY_QUERY: begin
      specs.push_back('{"stag_idx", 0, 0, 24, "value"});
    end
    RDMA_OP_CQC_RESIZE: begin
      specs.push_back('{"cq_size", 16, 59, 5, "value"});
      specs.push_back('{"cq_om", 16, 54, 2, "value"});
      specs.push_back('{"hw_load_cq_ci_threshold", 16, 51, 3, "value"});
      specs.push_back('{"old_cq_ci_wrap", 16, 47, 1, "value"});
      specs.push_back('{"old_cq_ci", 16, 24, 23, "value"});
      specs.push_back('{"cq_sd_or_pd_pba", 8, 12, 52, "value"});
      specs.push_back('{"vf_host_id", 0, 24, 4, "value"});
      specs.push_back('{"cqn", 0, 0, 21, "value"});
    end
    RDMA_OP_CQC_MODIFY: begin
      specs.push_back('{"nxt_cq_st", 0, 61, 2, "value"});
      specs.push_back('{"urc_flag", 0, 60, 1, "value"});
      specs.push_back('{"rq_size_factor", 0, 28, 4, "value"});
      specs.push_back('{"sq_size_factor", 0, 24, 4, "value"});
      specs.push_back('{"urc_sq_ceqe_flag", 0, 23, 1, "value"});
      specs.push_back('{"urc_rq_ceqe_flag", 0, 22, 1, "value"});
      specs.push_back('{"cqn", 0, 0, 21, "value"});
    end
    RDMA_OP_SD_UPDATE: begin
      specs.push_back('{"sd_num", 0, 0, 8, "value"});
      specs.push_back('{"sd_data", 32, 0, 256, "bytes:32"});
      specs.push_back('{"sd_buf_addr", 24, 0, 64, "sd_extended"});
      specs.push_back('{"", 8, 24, 8, "sd_signature"});
      specs.push_back('{"", 8, 32, 1, "sd_sign_en"});
    end
    RDMA_OP_SRC_ADDR_UPDATE: begin
      specs.push_back('{"src_addr_idx", 8, 52, 12, "value"});
      specs.push_back('{"", 8, 48, 1, "const:1"});
      specs.push_back('{"src_mac", 8, 0, 48, "mac48"});
      specs.push_back('{"src_ip", 16, 0, 128, "bytes:16"});
    end
    RDMA_OP_SRC_ADDR_QUERY: begin
      specs.push_back('{"src_addr_idx", 8, 52, 12, "value"});
      specs.push_back('{"", 8, 48, 1, "const:1"});
    end
    RDMA_OP_STAT_QUERY: begin
      specs.push_back('{"buf_pa", 24, 0, 64, "value"});
      specs.push_back('{"query_type", 0, 61, 2, "value"});
      specs.push_back('{"clear", 0, 16, 1, "value"});
      specs.push_back('{"port_or_stat_id", 0, 0, 8, "value"});
    end
    RDMA_OP_OCC_QPC, RDMA_OP_OCC_CQC, RDMA_OP_OCC_MRT,
    RDMA_OP_OCC_PBLE, RDMA_OP_OCC_SQRQE, RDMA_OP_OCC_SGB,
    RDMA_OP_OCC_IRQE, RDMA_OP_OCC_EIRQE, RDMA_OP_OCC_ORQE,
    RDMA_OP_OCC_UAQE: begin
      specs.push_back('{"buf_pa", 24, 0, 64, "value"});
      specs.push_back('{"key", 8, 0, 40, "value"});
    end
    RDMA_OP_IDX_OCC_QPC, RDMA_OP_IDX_OCC_CQC, RDMA_OP_IDX_OCC_MRT,
    RDMA_OP_IDX_OCC_PBLE, RDMA_OP_IDX_OCC_SQRQE, RDMA_OP_IDX_OCC_SGB,
    RDMA_OP_IDX_OCC_IRQE, RDMA_OP_IDX_OCC_EIRQE, RDMA_OP_IDX_OCC_ORQE,
    RDMA_OP_IDX_OCC_UAQE: begin
      specs.push_back('{"buf_pa", 24, 0, 64, "value"});
      specs.push_back('{"start_idx", 0, 0, 12, "value"});
      specs.push_back('{"num", 0, 16, 8, "minus_one"});
    end
    RDMA_OP_IFA_UPDATE: begin
      specs.push_back('{"data", 8, 0, 64, "value"});
      specs.push_back('{"obj_type", 0, 60, 2, "value"});
    end
    RDMA_OP_IFA_QUERY: begin
      specs.push_back('{"obj_type", 0, 60, 2, "value"});
    end
    RDMA_OP_OCC_QPC_KICKOUT, RDMA_OP_OCC_CQC_KICKOUT, RDMA_OP_OCC_MRT_KICKOUT,
    RDMA_OP_OCC_PBLE_KICKOUT, RDMA_OP_OCC_SQRQE_KICKOUT, RDMA_OP_OCC_SGB_KICKOUT,
    RDMA_OP_OCC_IRQE_KICKOUT, RDMA_OP_OCC_EIRQE_KICKOUT, RDMA_OP_OCC_ORQE_KICKOUT,
    RDMA_OP_OCC_UAQE_KICKOUT: begin
      specs.push_back('{"key", 8, 0, 40, "value"});
    end
    RDMA_OP_OCC_PD_KICKOUT: begin
      specs.push_back('{"pd_pba", 8, 0, 64, "value"});
    end
    RDMA_OP_CEQC_MODIFY: begin
    end
    RDMA_OP_AEQC_MODIFY: begin
    end
    RDMA_OP_SD_QUERY: begin
    end
    RDMA_OP_QPC_FORCE_DELETE: begin
    end
    RDMA_OP_CQC_FORCE_DELETE: begin
    end
    RDMA_OP_SRFQC_MODIFY: begin
    end
    RDMA_OP_NOP: begin
    end
    default: return 1'b0;
  endcase
  return 1'b1;
endfunction
