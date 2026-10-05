// 目录：硬件编解码层 codec/rdma/rdma_error_codec.sv。
// 职责：把 8-bit 硬件 ecode 分类并解码为 rdma_status（code/category/来源引擎/符号名/severity/retryable）。
// 依赖：本层公共 types/model/adapter 契约及冻结驱动的 ecode 定义。
// 所有权与生命周期：对象只拥有显式创建的值快照；外部资源仅保存非拥有引用，生命周期由调用方管理。

// // 阅读提示：先看公开接口，再看 case 映射；失败路径应保持状态与资源所有权可追踪。

class rdma_hw_error_codec extends uvm_object;
  `uvm_object_utils(rdma_hw_error_codec)

  // 功能：构造硬件错误码 codec。
  // 输入/输出及副作用：name 传给 super.new。
  // 失败/边界：无。
  function new(string name = "rdma_hw_error_codec");
    super.new(name);
  endfunction

  // 功能：判断 engine 是否属于合法 rdma_engine_kind_e 枚举值。
  // 输入/输出及副作用：engine 只读；返回 bit。
  // 失败/边界：枚举外的值（含 X/Z）返回 0。
  local function bit valid_engine(rdma_engine_kind_e engine);
    return engine inside {
      RDMA_ENGINE_NONE, RDMA_ENGINE_RESOURCE, RDMA_ENGINE_CMQ,
      RDMA_ENGINE_SQ, RDMA_ENGINE_RQ, RDMA_ENGINE_CQ,
      RDMA_ENGINE_CEQ, RDMA_ENGINE_AEQ, RDMA_ENGINE_PCIE,
      RDMA_ENGINE_DMA, RDMA_ENGINE_NETWORK, RDMA_ENGINE_RESET
    };
  endfunction

  // 功能：把 8-bit 硬件 ecode 分类为 rdma_status_code_e。
  // 输入/输出及副作用：hardware_code 只读；返回状态码。
  // 失败/边界：按 case 映射，成功码返回 OK；未列出的码走默认分支。
  local function rdma_status_code_e classify(bit [7:0] hardware_code);
    case (hardware_code)
      RDMA_CMQ_SUCCESS_ECODE:
        return RDMA_SC_OK;
      RDMA_ECODE_EC_TME_PBL_INVLD, RDMA_ECODE_EC_RME_PBL_INVLD:
        return RDMA_SC_DMA_TRANSLATION;
      RDMA_ECODE_EC_TME_PKT_PD_ERR, RDMA_ECODE_EC_TME_PKT_KEY_ERR, RDMA_ECODE_EC_TME_LOINVLD_PD_ERR, RDMA_ECODE_EC_TME_LOINVLD_KEY_ERR,
      RDMA_ECODE_EC_TME_BIND_PD_ERR, RDMA_ECODE_EC_TME_BIND_PARENT_MR_KEY_ERR, RDMA_ECODE_EC_TME_BIND_PARENT_MR_RIGHT_B_ERR, RDMA_ECODE_EC_TME_BIND_PARENT_MR_RIGHT_LW_ERR,
      RDMA_ECODE_EC_RME_PKT_SRFQ_PD_ERR, RDMA_ECODE_EC_RME_PKT_PD_ERR, RDMA_ECODE_EC_RME_PKT_KEY_ERR, RDMA_ECODE_EC_RME_PKT_RIGHT_ERR,
      RDMA_ECODE_EC_RME_ROINVLD_PD_ERR, RDMA_ECODE_EC_RME_ROINVLD_KEY_ERR:
        return RDMA_SC_DMA_PERMISSION;
      RDMA_ECODE_EC_TDE_DMA_ERR, RDMA_ECODE_EC_GLB_MBUS_ERR:
        return RDMA_SC_PCIE_COMPLETION;
      RDMA_ECODE_EC_RCE_CQ_FULL, RDMA_ECODE_EC_RCE_CEQ_FULL, RDMA_ECODE_EC_RCE_AEQ_FULL:
        return RDMA_SC_QUEUE_FULL;
      default:
        return RDMA_SC_UNKNOWN_HW_ERROR;
    endcase
  endfunction

  // 功能：按 ecode 与状态码推断错误来源引擎。
  // 输入/输出及副作用：hardware_code、code 只读；返回 rdma_engine_kind_e。
  // 失败/边界：按 case 固定映射；未命中走默认分支。
  local function rdma_engine_kind_e inferred_engine(
    bit [7:0] hardware_code,
    rdma_status_code_e code
  );
    case (hardware_code)
      RDMA_ECODE_EC_RCE_CQ_FULL: return RDMA_ENGINE_CQ;
      RDMA_ECODE_EC_RCE_CEQ_FULL: return RDMA_ENGINE_CEQ;
      RDMA_ECODE_EC_RCE_AEQ_FULL: return RDMA_ENGINE_AEQ;
      RDMA_ECODE_EC_GLB_MBUS_ERR: return RDMA_ENGINE_PCIE;
      RDMA_ECODE_XTRDMA_CQE_ECODE_TX_RSP_NML: return RDMA_ENGINE_SQ;
      RDMA_ECODE_XTRDMA_CQE_ECODE_RX_REQ_NML, RDMA_ECODE_XTRDMA_CQE_ECODE_RX_RSP_NML: return RDMA_ENGINE_RQ;
      default: begin
        case (code)
          RDMA_SC_DMA_TRANSLATION,
          RDMA_SC_DMA_PERMISSION,
          RDMA_SC_PCIE_COMPLETION: return RDMA_ENGINE_DMA;
          default: return RDMA_ENGINE_CMQ;
        endcase
      end
    endcase
  endfunction

  // // 名称与成员抄自冻结驱动 defs.h/wr.h（commit 491faf2ba42627fffd4dd027607299c8bb591ec2）。
  // 功能：把 8-bit ecode 映射为稳定符号名，用于状态诊断文本。
  // 输入/输出及副作用：hardware_code 只读；返回字符串。
  // 失败/边界：按 case 固定映射；未列出的码走默认分支。
  local function string symbolic_name(bit [7:0] hardware_code);
    case (hardware_code)
      RDMA_CMQ_SUCCESS_ECODE: return "RDMA_CMQ_SUCCESS";
      RDMA_ECODE_XTRDMA_CQE_ECODE_TX_RSP_NML: return "XTRDMA_CQE_ECODE_TX_RSP_NML";
      RDMA_ECODE_EC_TPE_DB_TYPE_INVLD: return "EC_TPE_DB_TYPE_INVLD";
      RDMA_ECODE_EC_TPE_OCC_QPC_ERR: return "EC_TPE_OCC_QPC_ERR";
      RDMA_ECODE_EC_TPE_TX_FLUSH: return "EC_TPE_TX_FLUSH";
      RDMA_ECODE_EC_TPE_QP_FLUSH: return "EC_TPE_QP_FLUSH";
      RDMA_ECODE_EC_TPE_SQ_VF_QPN_UNMATCH: return "EC_TPE_SQ_VF_QPN_UNMATCH";
      RDMA_ECODE_EC_TPE_SQ_RTO_OVERTIME: return "EC_TPE_SQ_RTO_OVERTIME";
      RDMA_ECODE_EC_TPE_SQ_SIGN_ERR_OVERTIME: return "EC_TPE_SQ_SIGN_ERR_OVERTIME";
      RDMA_ECODE_EC_TPE_SQ_PSN_ERR_OVERTIME: return "EC_TPE_SQ_PSN_ERR_OVERTIME";
      RDMA_ECODE_EC_TPE_SQ_KEY_ERR: return "EC_TPE_SQ_KEY_ERR";
      RDMA_ECODE_EC_TPE_SQ_WQE_OPCODE_INVLD: return "EC_TPE_SQ_WQE_OPCODE_INVLD";
      RDMA_ECODE_EC_TPE_SQ_QP_ACCESS_ERR: return "EC_TPE_SQ_QP_ACCESS_ERR";
      RDMA_ECODE_EC_TPE_SQ_WQE_SIGN_ERR: return "EC_TPE_SQ_WQE_SIGN_ERR";
      RDMA_ECODE_EC_TPE_SQ_RETRY_FENCE_WQE: return "EC_TPE_SQ_RETRY_FENCE_WQE";
      RDMA_ECODE_EC_TPE_SQ_PAYLOAD_LEN_ABOVE: return "EC_TPE_SQ_PAYLOAD_LEN_ABOVE";
      RDMA_ECODE_EC_TPE_SQ_WRITE_LEN_UNMATCH: return "EC_TPE_SQ_WRITE_LEN_UNMATCH";
      RDMA_ECODE_EC_TPE_SGB_KEY_ERR: return "EC_TPE_SGB_KEY_ERR";
      RDMA_ECODE_EC_RTS2SQD_DB_QP_ST_UNMATCH: return "EC_RTS2SQD_DB_QP_ST_UNMATCH";
      RDMA_ECODE_EC_RTS2SQD_DONE: return "EC_RTS2SQD_DONE";
      RDMA_ECODE_EC_SQD2RTS_DB_QP_ST_UNMATCH: return "EC_SQD2RTS_DB_QP_ST_UNMATCH";
      RDMA_ECODE_EC_TPE_EIRQ_RDSQ_VF_QPN_UNMATCH: return "EC_TPE_EIRQ_RDSQ_VF_QPN_UNMATCH";
      RDMA_ECODE_EC_TPE_EIRQ_RDSQ_KEY_ERR: return "EC_TPE_EIRQ_RDSQ_KEY_ERR";
      RDMA_ECODE_EC_TPE_EIRQ_RDSQ_WQE_OPCODE_INVLD: return "EC_TPE_EIRQ_RDSQ_WQE_OPCODE_INVLD";
      RDMA_ECODE_EC_TPE_URC_RSQ_RTO_OVERTIME: return "EC_TPE_URC_RSQ_RTO_OVERTIME";
      RDMA_ECODE_EC_TPE_TX_LOCAL_WQE_RTO_OVERTIME: return "EC_TPE_TX_LOCAL_WQE_RTO_OVERTIME";
      RDMA_ECODE_EC_TPE_SQ_SGE_PLD_LEN_UNMATCH: return "EC_TPE_SQ_SGE_PLD_LEN_UNMATCH";
      RDMA_ECODE_EC_TME_OCC_MR_ABNORMAL_RSLT: return "EC_TME_OCC_MR_ABNORMAL_RSLT";
      RDMA_ECODE_EC_TME_PBL_INVLD: return "EC_TME_PBL_INVLD";
      RDMA_ECODE_EC_TME_PKT_LEN_ZERO: return "EC_TME_PKT_LEN_ZERO";
      RDMA_ECODE_EC_TME_PKT_ST_ERR: return "EC_TME_PKT_ST_ERR";
      RDMA_ECODE_EC_TME_PKT_TYPE_ERR: return "EC_TME_PKT_TYPE_ERR";
      RDMA_ECODE_EC_TME_PKT_PD_ERR: return "EC_TME_PKT_PD_ERR";
      RDMA_ECODE_EC_TME_PKT_KEY_ERR: return "EC_TME_PKT_KEY_ERR";
      RDMA_ECODE_EC_TME_PKT_TYPE1_NOT_VA: return "EC_TME_PKT_TYPE1_NOT_VA";
      RDMA_ECODE_EC_TME_PKT_MR_LEN_ZERO: return "EC_TME_PKT_MR_LEN_ZERO";
      RDMA_ECODE_EC_TME_PKT_LEN_ERR: return "EC_TME_PKT_LEN_ERR";
      RDMA_ECODE_EC_TME_PKT_TYPE2B_QPN_ERR: return "EC_TME_PKT_TYPE2B_QPN_ERR";
      RDMA_ECODE_EC_TME_PLD_LEN_CHK_ERR: return "EC_TME_PLD_LEN_CHK_ERR";
      RDMA_ECODE_EC_TME_LOINVLD_NOT_PERMIT: return "EC_TME_LOINVLD_NOT_PERMIT";
      RDMA_ECODE_EC_TME_LOINVLD_ST_INVLD: return "EC_TME_LOINVLD_ST_INVLD";
      RDMA_ECODE_EC_TME_LOINVLD_TYPE1_MW: return "EC_TME_LOINVLD_TYPE1_MW";
      RDMA_ECODE_EC_TME_LOINVLD_PD_ERR: return "EC_TME_LOINVLD_PD_ERR";
      RDMA_ECODE_EC_TME_LOINVLD_KEY_ERR: return "EC_TME_LOINVLD_KEY_ERR";
      RDMA_ECODE_EC_TME_LOINVLD_MR_WITH_MW: return "EC_TME_LOINVLD_MR_WITH_MW";
      RDMA_ECODE_EC_TME_LOINVLD_TYPE2B_QPN_ERR: return "EC_TME_LOINVLD_TYPE2B_QPN_ERR";
      RDMA_ECODE_EC_TME_BIND_PARENT_MR_ST_NOT_VLD: return "EC_TME_BIND_PARENT_MR_ST_NOT_VLD";
      RDMA_ECODE_EC_TME_BIND_MW_ST_INVLD: return "EC_TME_BIND_MW_ST_INVLD";
      RDMA_ECODE_EC_TME_BIND_MW_ST_NOT_FREE: return "EC_TME_BIND_MW_ST_NOT_FREE";
      RDMA_ECODE_EC_TME_BIND_PARENT_MR_TYPE_ERR: return "EC_TME_BIND_PARENT_MR_TYPE_ERR";
      RDMA_ECODE_EC_TME_BIND_MW_TYPE_ERR: return "EC_TME_BIND_MW_TYPE_ERR";
      RDMA_ECODE_EC_TME_BIND_WQE_TYPE_ERR: return "EC_TME_BIND_WQE_TYPE_ERR";
      RDMA_ECODE_EC_TME_BIND_PD_ERR: return "EC_TME_BIND_PD_ERR";
      RDMA_ECODE_EC_TME_BIND_PARENT_MR_KEY_ERR: return "EC_TME_BIND_PARENT_MR_KEY_ERR";
      RDMA_ECODE_EC_TME_BIND_PARENT_MR_RIGHT_B_ERR: return "EC_TME_BIND_PARENT_MR_RIGHT_B_ERR";
      RDMA_ECODE_EC_TME_BIND_PARENT_MR_RIGHT_LW_ERR: return "EC_TME_BIND_PARENT_MR_RIGHT_LW_ERR";
      RDMA_ECODE_EC_TME_BIND_PARENT_MR_NOT_VA: return "EC_TME_BIND_PARENT_MR_NOT_VA";
      RDMA_ECODE_EC_TME_BIND_MW_LEN_ERR: return "EC_TME_BIND_MW_LEN_ERR";
      RDMA_ECODE_EC_TME_BIND_MW_TYPE1_OP_ERR: return "EC_TME_BIND_MW_TYPE1_OP_ERR";
      RDMA_ECODE_EC_TME_BIND_MW_TYPE2B_ZERO_BIND: return "EC_TME_BIND_MW_TYPE2B_ZERO_BIND";
      RDMA_ECODE_EC_TME_BIND_PARENT_MR_BIND_NUM_ERR: return "EC_TME_BIND_PARENT_MR_BIND_NUM_ERR";
      RDMA_ECODE_EC_TME_FMR_ST_ERR: return "EC_TME_FMR_ST_ERR";
      RDMA_ECODE_EC_TME_FMR_TYPE_ERR: return "EC_TME_FMR_TYPE_ERR";
      RDMA_ECODE_EC_TME_FMR_PD_ERR: return "EC_TME_FMR_PD_ERR";
      RDMA_ECODE_EC_TDE_DMA_ERR: return "EC_TDE_DMA_ERR";
      RDMA_ECODE_EC_TDE_SRC_ADDR_TBL_INVLD: return "EC_TDE_SRC_ADDR_TBL_INVLD";
      RDMA_ECODE_EC_CCE_RC_CCREQ: return "EC_CCE_RC_CCREQ";
      RDMA_ECODE_EC_CCE_RC_ACK: return "EC_CCE_RC_ACK";
      RDMA_ECODE_EC_CCE_URC_ACK: return "EC_CCE_URC_ACK";
      RDMA_ECODE_EC_RPE_REQ_SRFQ_OVER_LIMIT_TH: return "EC_RPE_REQ_SRFQ_OVER_LIMIT_TH";
      RDMA_ECODE_EC_RPE_REQ_SRFQ_PKT_LEN_UNMATCH_SGE: return "EC_RPE_REQ_SRFQ_PKT_LEN_UNMATCH_SGE";
      RDMA_ECODE_EC_RPE_REQ_SRFQ_WQE_ERR: return "EC_RPE_REQ_SRFQ_WQE_ERR";
      RDMA_ECODE_EC_RPE_REQ_SRFQ_ST_INVLD: return "EC_RPE_REQ_SRFQ_ST_INVLD";
      RDMA_ECODE_EC_RPE_REQ_DUP_DR_NML_URC: return "EC_RPE_REQ_DUP_DR_NML_URC";
      RDMA_ECODE_EC_RPE_REQ_DR_OWN_URC: return "EC_RPE_REQ_DR_OWN_URC";
      RDMA_ECODE_EC_RPE_RC_URC_ACCESS_INVLD: return "EC_RPE_RC_URC_ACCESS_INVLD";
      RDMA_ECODE_EC_RPE_ICRC_ERR_TRIM_PKT: return "EC_RPE_ICRC_ERR_TRIM_PKT";
      RDMA_ECODE_XTRDMA_CQE_ECODE_RX_REQ_NML: return "XTRDMA_CQE_ECODE_RX_REQ_NML";
      RDMA_ECODE_XTRDMA_CQE_ECODE_RX_RSP_NML: return "XTRDMA_CQE_ECODE_RX_RSP_NML";
      RDMA_ECODE_EC_RPE_OCC_QPC_ERR: return "EC_RPE_OCC_QPC_ERR";
      RDMA_ECODE_EC_RPE_RC_URC_OPCODE_INVLD: return "EC_RPE_RC_URC_OPCODE_INVLD";
      RDMA_ECODE_EC_RPE_RX_FLUSH: return "EC_RPE_RX_FLUSH";
      RDMA_ECODE_EC_RPE_REQ_RQ_WQE_ERR_UD: return "EC_RPE_REQ_RQ_WQE_ERR_UD";
      RDMA_ECODE_EC_RPE_REQ_ATOMIC_OCTBYTE_ALIGN_ERR: return "EC_RPE_REQ_ATOMIC_OCTBYTE_ALIGN_ERR";
      RDMA_ECODE_EC_RPE_REQ_OPCODE_MIS_LAST: return "EC_RPE_REQ_OPCODE_MIS_LAST";
      RDMA_ECODE_EC_RPE_REQ_OPCODE_MIS_FST: return "EC_RPE_REQ_OPCODE_MIS_FST";
      RDMA_ECODE_EC_RPE_REQ_PKT_LEN_UNMATCH_PMTU_PAD: return "EC_RPE_REQ_PKT_LEN_UNMATCH_PMTU_PAD";
      RDMA_ECODE_EC_RPE_REQ_PKT_LEN_UNMATCH_RETH: return "EC_RPE_REQ_PKT_LEN_UNMATCH_RETH";
      RDMA_ECODE_EC_RPE_REQ_PKT_LEN_UNMATCH_SGE_RC_URC: return "EC_RPE_REQ_PKT_LEN_UNMATCH_SGE_RC_URC";
      RDMA_ECODE_EC_RPE_REQ_RQ_WQE_ERR_RC_URC: return "EC_RPE_REQ_RQ_WQE_ERR_RC_URC";
      RDMA_ECODE_EC_RPE_RSP_ORQ_WQE_ERR: return "EC_RPE_RSP_ORQ_WQE_ERR";
      RDMA_ECODE_EC_RPE_RSP_OPCODE_MIS_LAST: return "EC_RPE_RSP_OPCODE_MIS_LAST";
      RDMA_ECODE_EC_RPE_RSP_OPCODE_MIS_FST: return "EC_RPE_RSP_OPCODE_MIS_FST";
      RDMA_ECODE_EC_RPE_RSP_PKT_LEN_UNMATCH_SGE_RC: return "EC_RPE_RSP_PKT_LEN_UNMATCH_SGE_RC";
      RDMA_ECODE_EC_RPE_RSP_PKT_LEN_UNMATCH_PMTU_PAD: return "EC_RPE_RSP_PKT_LEN_UNMATCH_PMTU_PAD";
      RDMA_ECODE_EC_RPE_RSP_PSN_UNMATCH_ORQ_LAST_PSN: return "EC_RPE_RSP_PSN_UNMATCH_ORQ_LAST_PSN";
      RDMA_ECODE_EC_RPE_RSP_ORQE_PSN_ERR: return "EC_RPE_RSP_ORQE_PSN_ERR";
      RDMA_ECODE_EC_RPE_RSP_NAK_RNR_ERR_OVERTIME: return "EC_RPE_RSP_NAK_RNR_ERR_OVERTIME";
      RDMA_ECODE_EC_RPE_NAK_FATAL_ERR: return "EC_RPE_NAK_FATAL_ERR";
      RDMA_ECODE_EC_RPE_RX_FLUSH_QP_INVLD: return "EC_RPE_RX_FLUSH_QP_INVLD";
      RDMA_ECODE_EC_RPE_URC_DR_TCIE: return "EC_RPE_URC_DR_TCIE";
      RDMA_ECODE_EC_RPE_NACK_CIE: return "EC_RPE_NACK_CIE";
      RDMA_ECODE_EC_RME_OCC_MR_ABNORMAL_RSLT: return "EC_RME_OCC_MR_ABNORMAL_RSLT";
      RDMA_ECODE_EC_RME_PBL_INVLD: return "EC_RME_PBL_INVLD";
      RDMA_ECODE_EC_RME_PKT_SRFQ_PD_ERR: return "EC_RME_PKT_SRFQ_PD_ERR";
      RDMA_ECODE_EC_RME_PKT_LEN_ZERO: return "EC_RME_PKT_LEN_ZERO";
      RDMA_ECODE_EC_RME_PKT_ST_ERR: return "EC_RME_PKT_ST_ERR";
      RDMA_ECODE_EC_RME_PKT_TYPE_ERR: return "EC_RME_PKT_TYPE_ERR";
      RDMA_ECODE_EC_RME_PKT_PD_ERR: return "EC_RME_PKT_PD_ERR";
      RDMA_ECODE_EC_RME_PKT_KEY_ERR: return "EC_RME_PKT_KEY_ERR";
      RDMA_ECODE_EC_RME_PKT_RIGHT_ERR: return "EC_RME_PKT_RIGHT_ERR";
      RDMA_ECODE_EC_RME_PKT_TYPE1_NOT_VA: return "EC_RME_PKT_TYPE1_NOT_VA";
      RDMA_ECODE_EC_RME_PKT_MR_LEN_ZERO: return "EC_RME_PKT_MR_LEN_ZERO";
      RDMA_ECODE_EC_RME_PKT_LEN_ERR: return "EC_RME_PKT_LEN_ERR";
      RDMA_ECODE_EC_RME_PKT_SRFQ_MR_ERR: return "EC_RME_PKT_SRFQ_MR_ERR";
      RDMA_ECODE_EC_RME_ROINVLD_NOT_PERMIT: return "EC_RME_ROINVLD_NOT_PERMIT";
      RDMA_ECODE_EC_RME_ROINVLD_ST_INVLD: return "EC_RME_ROINVLD_ST_INVLD";
      RDMA_ECODE_EC_RME_ROINVLD_TYPE1_MW: return "EC_RME_ROINVLD_TYPE1_MW";
      RDMA_ECODE_EC_RME_ROINVLD_PD_ERR: return "EC_RME_ROINVLD_PD_ERR";
      RDMA_ECODE_EC_RME_ROINVLD_KEY_ERR: return "EC_RME_ROINVLD_KEY_ERR";
      RDMA_ECODE_EC_RME_ROINVLD_MR_WITH_MW: return "EC_RME_ROINVLD_MR_WITH_MW";
      RDMA_ECODE_EC_RME_ROINVLD_TYPE2B_QPN_ERR: return "EC_RME_ROINVLD_TYPE2B_QPN_ERR";
      RDMA_ECODE_EC_RME_PKT_TYPE2B_QPN_ERR: return "EC_RME_PKT_TYPE2B_QPN_ERR";
      RDMA_ECODE_EC_RME_PLD_LEN_CHK_ERR: return "EC_RME_PLD_LEN_CHK_ERR";
      RDMA_ECODE_EC_RCE_OCC_EIRQ_RDSQ_ERR: return "EC_RCE_OCC_EIRQ_RDSQ_ERR";
      RDMA_ECODE_EC_RCE_OCC_UAQ_ERR: return "EC_RCE_OCC_UAQ_ERR";
      RDMA_ECODE_EC_RCE_URC_TACK_RBM_DUP_PKT: return "EC_RCE_URC_TACK_RBM_DUP_PKT";
      RDMA_ECODE_XTRDMA_CQE_ECODE_TX_EC_RCE_URC_SQ_CPL_SRBM_DUP_PKT: return
        "XTRDMA_CQE_ECODE_TX_EC_RCE_URC_SQ_CPL_SRBM_DUP_PKT";
      RDMA_ECODE_EC_RCE_OCC_CQC_ERR: return "EC_RCE_OCC_CQC_ERR";
      RDMA_ECODE_EC_RCE_CQC_INVLD: return "EC_RCE_CQC_INVLD";
      RDMA_ECODE_EC_RCE_CQ_FULL: return "EC_RCE_CQ_FULL";
      RDMA_ECODE_EC_RCE_CQ_LOAD_PBA_ERR: return "EC_RCE_CQ_LOAD_PBA_ERR";
      RDMA_ECODE_EC_RCE_COM_EST: return "EC_RCE_COM_EST";
      RDMA_ECODE_EC_RCE_CEQC_INVLD: return "EC_RCE_CEQC_INVLD";
      RDMA_ECODE_EC_RCE_CEQ_FULL: return "EC_RCE_CEQ_FULL";
      RDMA_ECODE_EC_RCE_AEQC_INVLD: return "EC_RCE_AEQC_INVLD";
      RDMA_ECODE_EC_RCE_AEQ_FULL: return "EC_RCE_AEQ_FULL";
      RDMA_ECODE_EC_GLB_MBUS_ERR: return "EC_GLB_MBUS_ERR";
      default: return $sformatf("RDMA_UNKNOWN_ECODE_0x%02x",
                                hardware_code);
    endcase
  endfunction

  // 功能：把 8-bit ecode 分类为 rdma_status code，选定来源引擎（可信 observed_engine，否则推断），组装 status。
  // 输入/输出及副作用：hardware_code、observed_engine 输入；decoded 输出，入口置 null；写 code/category/
  //  source/message、硬件码有效位、severity、retryable。
  // 失败/边界：observed_engine 为 NONE/非法时用 inferred_engine；未知码仍返回成功 wrapper，不能当作码合法的证明。
  function rdma_status decode_status(
    bit [7:0] hardware_code,
    rdma_engine_kind_e observed_engine,
    output rdma_status decoded
  );
    rdma_status candidate;
    rdma_status_code_e code;
    rdma_engine_kind_e source_engine;

    decoded = null;
    code = classify(hardware_code);
    if (valid_engine(observed_engine) && observed_engine != RDMA_ENGINE_NONE)
      source_engine = observed_engine;
    else
      source_engine = inferred_engine(hardware_code, code);

    candidate = new("rdma_decoded_hardware_status");
    candidate.code = code;
    candidate.category = rdma_status::category_for(code);
    candidate.source_engine = source_engine;
    candidate.message = symbolic_name(hardware_code);
    candidate.retryable = code inside {
      RDMA_SC_DMA_TRANSLATION, RDMA_SC_PCIE_COMPLETION, RDMA_SC_QUEUE_FULL
    };
    if (hardware_code == RDMA_CMQ_SUCCESS_ECODE) begin
      candidate.hardware_code = '0;
      candidate.hardware_code_valid = 1'b0;
      candidate.severity = RDMA_SEVERITY_INFO;
      candidate.retryable = 1'b0;
    end
    else begin
      candidate.hardware_code = {24'h0, hardware_code};
      candidate.hardware_code_valid = 1'b1;
      candidate.severity = RDMA_SEVERITY_ERROR;
    end
    decoded = candidate;
    return rdma_status::success("rdma hardware ecode decoded");
  endfunction
endclass
