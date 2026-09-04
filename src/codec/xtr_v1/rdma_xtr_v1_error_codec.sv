// 目录：硬件编解码层 codec/xtr_v1/rdma_xtr_v1_error_codec.sv。
// 职责：实现 rdma_xtr_v1_error_codec 在本层的职责和对外接口。
// 依赖：依赖本层公共 types/model/adapter 契约及其上游快照。
// 所有权与生命周期：对象只拥有显式创建的值快照；外部资源保存非拥有引用，生命周期由调用方管理。

// 中文说明：rdma_xtr_v1_error_codec.sv 属于编码层，将模型字段转换为硬件图像并执行反向校验。
// 阅读提示：先看公开类型和接口，再看实现细节；失败路径应保持状态与资源所有权可追踪。

class rdma_xtr_v1_error_codec extends uvm_object;
  `uvm_object_utils(rdma_xtr_v1_error_codec)

  // 功能：构造当前对象并初始化其字段、集合和 UVM 名称；不接管传入句柄的生命周期。
  // 输入/输出及副作用：name 仅用于 UVM 对象命名；内部字段被初始化为安全默认值，传入句柄不转移所有权。
  //   返回新对象实例；构造失败由 UVM 工厂或调用方处理。
  // 失败/边界：不创建外部资源；name 为空时仍允许构造，但所有字段必须保持可配置的初始值。
  function new(string name = "rdma_xtr_v1_error_codec");
    super.new(name);
  endfunction

  // 功能：判断 valid_engine 对应的状态、能力或账本条件，并返回确定的布尔/计数结果，不修改状态。
  // 输入/输出及副作用：参数 inside 用于执行 valid_engine；返回值或 output/inout 交付处理结果，必要时更新本对象状态。
  //   调用方不获得内部集合或外部依赖的所有权。
  // 失败/边界：valid_engine 只读取现有账本；输入未初始化时返回保守结果，不得借助默认 Function/root 猜测。
  local function bit valid_engine(rdma_engine_kind_e engine);
    return engine inside {
      RDMA_ENGINE_NONE, RDMA_ENGINE_RESOURCE, RDMA_ENGINE_CMQ,
      RDMA_ENGINE_SQ, RDMA_ENGINE_RQ, RDMA_ENGINE_CQ,
      RDMA_ENGINE_CEQ, RDMA_ENGINE_AEQ, RDMA_ENGINE_PCIE,
      RDMA_ENGINE_DMA, RDMA_ENGINE_NETWORK, RDMA_ENGINE_RESET
    };
  endfunction

  // 功能：处理 classify：依据其参数完成所属层的具体协议动作，并保持返回状态、游标和资源所有权一致。
  // 输入/输出及副作用：参数 hardware_code 用于执行 classify；返回值或 output/inout 交付处理结果，必要时更新本对象状态。
  //   调用方不获得内部集合或外部依赖的所有权。
  // 失败/边界：classify 只接受其签名声明的输入；缺少必要字段时返回错误，成功路径不得隐式修改无关资源。
  local function rdma_status_code_e classify(bit [7:0] hardware_code);
    case (hardware_code)
      XTR_V1_CMQ_SUCCESS_ECODE:
        return RDMA_SC_OK;
      XTR_V1_ECODE_EC_TME_PBL_INVLD, XTR_V1_ECODE_EC_RME_PBL_INVLD:
        return RDMA_SC_DMA_TRANSLATION;
      XTR_V1_ECODE_EC_TME_PKT_PD_ERR, XTR_V1_ECODE_EC_TME_PKT_KEY_ERR, XTR_V1_ECODE_EC_TME_LOINVLD_PD_ERR, XTR_V1_ECODE_EC_TME_LOINVLD_KEY_ERR,
      XTR_V1_ECODE_EC_TME_BIND_PD_ERR, XTR_V1_ECODE_EC_TME_BIND_PARENT_MR_KEY_ERR, XTR_V1_ECODE_EC_TME_BIND_PARENT_MR_RIGHT_B_ERR, XTR_V1_ECODE_EC_TME_BIND_PARENT_MR_RIGHT_LW_ERR,
      XTR_V1_ECODE_EC_RME_PKT_SRFQ_PD_ERR, XTR_V1_ECODE_EC_RME_PKT_PD_ERR, XTR_V1_ECODE_EC_RME_PKT_KEY_ERR, XTR_V1_ECODE_EC_RME_PKT_RIGHT_ERR,
      XTR_V1_ECODE_EC_RME_ROINVLD_PD_ERR, XTR_V1_ECODE_EC_RME_ROINVLD_KEY_ERR:
        return RDMA_SC_DMA_PERMISSION;
      XTR_V1_ECODE_EC_TDE_DMA_ERR, XTR_V1_ECODE_EC_GLB_MBUS_ERR:
        return RDMA_SC_PCIE_COMPLETION;
      XTR_V1_ECODE_EC_RCE_CQ_FULL, XTR_V1_ECODE_EC_RCE_CEQ_FULL, XTR_V1_ECODE_EC_RCE_AEQ_FULL:
        return RDMA_SC_QUEUE_FULL;
      default:
        return RDMA_SC_UNKNOWN_HW_ERROR;
    endcase
  endfunction

  // 功能：处理 inferred_engine：依据其参数完成所属层的具体协议动作，并保持返回状态、游标和资源所有权一致。
  // 输入/输出及副作用：参数 hardware_code, code 用于执行 inferred_engine；返回值或 output/inout 交付处理结果，必要时更新本对象状态。
  //   调用方不获得内部集合或外部依赖的所有权。
  // 失败/边界：inferred_engine 只接受其签名声明的输入；缺少必要字段时返回错误，成功路径不得隐式修改无关资源。
  local function rdma_engine_kind_e inferred_engine(
    bit [7:0] hardware_code,
    rdma_status_code_e code
  );
    case (hardware_code)
      XTR_V1_ECODE_EC_RCE_CQ_FULL: return RDMA_ENGINE_CQ;
      XTR_V1_ECODE_EC_RCE_CEQ_FULL: return RDMA_ENGINE_CEQ;
      XTR_V1_ECODE_EC_RCE_AEQ_FULL: return RDMA_ENGINE_AEQ;
      XTR_V1_ECODE_EC_GLB_MBUS_ERR: return RDMA_ENGINE_PCIE;
      XTR_V1_ECODE_XTRDMA_CQE_ECODE_TX_RSP_NML: return RDMA_ENGINE_SQ;
      XTR_V1_ECODE_XTRDMA_CQE_ECODE_RX_REQ_NML, XTR_V1_ECODE_XTRDMA_CQE_ECODE_RX_RSP_NML: return RDMA_ENGINE_RQ;
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

  // Names and membership are transcribed from the frozen driver defs.h/wr.h
  // at commit 491faf2ba42627fffd4dd027607299c8bb591ec2.
  // 功能：处理 symbolic_name：依据其参数完成所属层的具体协议动作，并保持返回状态、游标和资源所有权一致。
  // 输入/输出及副作用：参数 hardware_code 用于执行 symbolic_name；返回值或 output/inout 交付处理结果，必要时更新本对象状态。
  //   调用方不获得内部集合或外部依赖的所有权。
  // 失败/边界：symbolic_name 只接受其签名声明的输入；缺少必要字段时返回错误，成功路径不得隐式修改无关资源。
  local function string symbolic_name(bit [7:0] hardware_code);
    case (hardware_code)
      XTR_V1_CMQ_SUCCESS_ECODE: return "XTR_V1_CMQ_SUCCESS";
      XTR_V1_ECODE_XTRDMA_CQE_ECODE_TX_RSP_NML: return "XTRDMA_CQE_ECODE_TX_RSP_NML";
      XTR_V1_ECODE_EC_TPE_DB_TYPE_INVLD: return "EC_TPE_DB_TYPE_INVLD";
      XTR_V1_ECODE_EC_TPE_OCC_QPC_ERR: return "EC_TPE_OCC_QPC_ERR";
      XTR_V1_ECODE_EC_TPE_TX_FLUSH: return "EC_TPE_TX_FLUSH";
      XTR_V1_ECODE_EC_TPE_QP_FLUSH: return "EC_TPE_QP_FLUSH";
      XTR_V1_ECODE_EC_TPE_SQ_VF_QPN_UNMATCH: return "EC_TPE_SQ_VF_QPN_UNMATCH";
      XTR_V1_ECODE_EC_TPE_SQ_RTO_OVERTIME: return "EC_TPE_SQ_RTO_OVERTIME";
      XTR_V1_ECODE_EC_TPE_SQ_SIGN_ERR_OVERTIME: return "EC_TPE_SQ_SIGN_ERR_OVERTIME";
      XTR_V1_ECODE_EC_TPE_SQ_PSN_ERR_OVERTIME: return "EC_TPE_SQ_PSN_ERR_OVERTIME";
      XTR_V1_ECODE_EC_TPE_SQ_KEY_ERR: return "EC_TPE_SQ_KEY_ERR";
      XTR_V1_ECODE_EC_TPE_SQ_WQE_OPCODE_INVLD: return "EC_TPE_SQ_WQE_OPCODE_INVLD";
      XTR_V1_ECODE_EC_TPE_SQ_QP_ACCESS_ERR: return "EC_TPE_SQ_QP_ACCESS_ERR";
      XTR_V1_ECODE_EC_TPE_SQ_WQE_SIGN_ERR: return "EC_TPE_SQ_WQE_SIGN_ERR";
      XTR_V1_ECODE_EC_TPE_SQ_RETRY_FENCE_WQE: return "EC_TPE_SQ_RETRY_FENCE_WQE";
      XTR_V1_ECODE_EC_TPE_SQ_PAYLOAD_LEN_ABOVE: return "EC_TPE_SQ_PAYLOAD_LEN_ABOVE";
      XTR_V1_ECODE_EC_TPE_SQ_WRITE_LEN_UNMATCH: return "EC_TPE_SQ_WRITE_LEN_UNMATCH";
      XTR_V1_ECODE_EC_TPE_SGB_KEY_ERR: return "EC_TPE_SGB_KEY_ERR";
      XTR_V1_ECODE_EC_RTS2SQD_DB_QP_ST_UNMATCH: return "EC_RTS2SQD_DB_QP_ST_UNMATCH";
      XTR_V1_ECODE_EC_RTS2SQD_DONE: return "EC_RTS2SQD_DONE";
      XTR_V1_ECODE_EC_SQD2RTS_DB_QP_ST_UNMATCH: return "EC_SQD2RTS_DB_QP_ST_UNMATCH";
      XTR_V1_ECODE_EC_TPE_EIRQ_RDSQ_VF_QPN_UNMATCH: return "EC_TPE_EIRQ_RDSQ_VF_QPN_UNMATCH";
      XTR_V1_ECODE_EC_TPE_EIRQ_RDSQ_KEY_ERR: return "EC_TPE_EIRQ_RDSQ_KEY_ERR";
      XTR_V1_ECODE_EC_TPE_EIRQ_RDSQ_WQE_OPCODE_INVLD: return "EC_TPE_EIRQ_RDSQ_WQE_OPCODE_INVLD";
      XTR_V1_ECODE_EC_TPE_URC_RSQ_RTO_OVERTIME: return "EC_TPE_URC_RSQ_RTO_OVERTIME";
      XTR_V1_ECODE_EC_TPE_TX_LOCAL_WQE_RTO_OVERTIME: return "EC_TPE_TX_LOCAL_WQE_RTO_OVERTIME";
      XTR_V1_ECODE_EC_TPE_SQ_SGE_PLD_LEN_UNMATCH: return "EC_TPE_SQ_SGE_PLD_LEN_UNMATCH";
      XTR_V1_ECODE_EC_TME_OCC_MR_ABNORMAL_RSLT: return "EC_TME_OCC_MR_ABNORMAL_RSLT";
      XTR_V1_ECODE_EC_TME_PBL_INVLD: return "EC_TME_PBL_INVLD";
      XTR_V1_ECODE_EC_TME_PKT_LEN_ZERO: return "EC_TME_PKT_LEN_ZERO";
      XTR_V1_ECODE_EC_TME_PKT_ST_ERR: return "EC_TME_PKT_ST_ERR";
      XTR_V1_ECODE_EC_TME_PKT_TYPE_ERR: return "EC_TME_PKT_TYPE_ERR";
      XTR_V1_ECODE_EC_TME_PKT_PD_ERR: return "EC_TME_PKT_PD_ERR";
      XTR_V1_ECODE_EC_TME_PKT_KEY_ERR: return "EC_TME_PKT_KEY_ERR";
      XTR_V1_ECODE_EC_TME_PKT_TYPE1_NOT_VA: return "EC_TME_PKT_TYPE1_NOT_VA";
      XTR_V1_ECODE_EC_TME_PKT_MR_LEN_ZERO: return "EC_TME_PKT_MR_LEN_ZERO";
      XTR_V1_ECODE_EC_TME_PKT_LEN_ERR: return "EC_TME_PKT_LEN_ERR";
      XTR_V1_ECODE_EC_TME_PKT_TYPE2B_QPN_ERR: return "EC_TME_PKT_TYPE2B_QPN_ERR";
      XTR_V1_ECODE_EC_TME_PLD_LEN_CHK_ERR: return "EC_TME_PLD_LEN_CHK_ERR";
      XTR_V1_ECODE_EC_TME_LOINVLD_NOT_PERMIT: return "EC_TME_LOINVLD_NOT_PERMIT";
      XTR_V1_ECODE_EC_TME_LOINVLD_ST_INVLD: return "EC_TME_LOINVLD_ST_INVLD";
      XTR_V1_ECODE_EC_TME_LOINVLD_TYPE1_MW: return "EC_TME_LOINVLD_TYPE1_MW";
      XTR_V1_ECODE_EC_TME_LOINVLD_PD_ERR: return "EC_TME_LOINVLD_PD_ERR";
      XTR_V1_ECODE_EC_TME_LOINVLD_KEY_ERR: return "EC_TME_LOINVLD_KEY_ERR";
      XTR_V1_ECODE_EC_TME_LOINVLD_MR_WITH_MW: return "EC_TME_LOINVLD_MR_WITH_MW";
      XTR_V1_ECODE_EC_TME_LOINVLD_TYPE2B_QPN_ERR: return "EC_TME_LOINVLD_TYPE2B_QPN_ERR";
      XTR_V1_ECODE_EC_TME_BIND_PARENT_MR_ST_NOT_VLD: return "EC_TME_BIND_PARENT_MR_ST_NOT_VLD";
      XTR_V1_ECODE_EC_TME_BIND_MW_ST_INVLD: return "EC_TME_BIND_MW_ST_INVLD";
      XTR_V1_ECODE_EC_TME_BIND_MW_ST_NOT_FREE: return "EC_TME_BIND_MW_ST_NOT_FREE";
      XTR_V1_ECODE_EC_TME_BIND_PARENT_MR_TYPE_ERR: return "EC_TME_BIND_PARENT_MR_TYPE_ERR";
      XTR_V1_ECODE_EC_TME_BIND_MW_TYPE_ERR: return "EC_TME_BIND_MW_TYPE_ERR";
      XTR_V1_ECODE_EC_TME_BIND_WQE_TYPE_ERR: return "EC_TME_BIND_WQE_TYPE_ERR";
      XTR_V1_ECODE_EC_TME_BIND_PD_ERR: return "EC_TME_BIND_PD_ERR";
      XTR_V1_ECODE_EC_TME_BIND_PARENT_MR_KEY_ERR: return "EC_TME_BIND_PARENT_MR_KEY_ERR";
      XTR_V1_ECODE_EC_TME_BIND_PARENT_MR_RIGHT_B_ERR: return "EC_TME_BIND_PARENT_MR_RIGHT_B_ERR";
      XTR_V1_ECODE_EC_TME_BIND_PARENT_MR_RIGHT_LW_ERR: return "EC_TME_BIND_PARENT_MR_RIGHT_LW_ERR";
      XTR_V1_ECODE_EC_TME_BIND_PARENT_MR_NOT_VA: return "EC_TME_BIND_PARENT_MR_NOT_VA";
      XTR_V1_ECODE_EC_TME_BIND_MW_LEN_ERR: return "EC_TME_BIND_MW_LEN_ERR";
      XTR_V1_ECODE_EC_TME_BIND_MW_TYPE1_OP_ERR: return "EC_TME_BIND_MW_TYPE1_OP_ERR";
      XTR_V1_ECODE_EC_TME_BIND_MW_TYPE2B_ZERO_BIND: return "EC_TME_BIND_MW_TYPE2B_ZERO_BIND";
      XTR_V1_ECODE_EC_TME_BIND_PARENT_MR_BIND_NUM_ERR: return "EC_TME_BIND_PARENT_MR_BIND_NUM_ERR";
      XTR_V1_ECODE_EC_TME_FMR_ST_ERR: return "EC_TME_FMR_ST_ERR";
      XTR_V1_ECODE_EC_TME_FMR_TYPE_ERR: return "EC_TME_FMR_TYPE_ERR";
      XTR_V1_ECODE_EC_TME_FMR_PD_ERR: return "EC_TME_FMR_PD_ERR";
      XTR_V1_ECODE_EC_TDE_DMA_ERR: return "EC_TDE_DMA_ERR";
      XTR_V1_ECODE_EC_TDE_SRC_ADDR_TBL_INVLD: return "EC_TDE_SRC_ADDR_TBL_INVLD";
      XTR_V1_ECODE_EC_CCE_RC_CCREQ: return "EC_CCE_RC_CCREQ";
      XTR_V1_ECODE_EC_CCE_RC_ACK: return "EC_CCE_RC_ACK";
      XTR_V1_ECODE_EC_CCE_URC_ACK: return "EC_CCE_URC_ACK";
      XTR_V1_ECODE_EC_RPE_REQ_SRFQ_OVER_LIMIT_TH: return "EC_RPE_REQ_SRFQ_OVER_LIMIT_TH";
      XTR_V1_ECODE_EC_RPE_REQ_SRFQ_PKT_LEN_UNMATCH_SGE: return "EC_RPE_REQ_SRFQ_PKT_LEN_UNMATCH_SGE";
      XTR_V1_ECODE_EC_RPE_REQ_SRFQ_WQE_ERR: return "EC_RPE_REQ_SRFQ_WQE_ERR";
      XTR_V1_ECODE_EC_RPE_REQ_SRFQ_ST_INVLD: return "EC_RPE_REQ_SRFQ_ST_INVLD";
      XTR_V1_ECODE_EC_RPE_REQ_DUP_DR_NML_URC: return "EC_RPE_REQ_DUP_DR_NML_URC";
      XTR_V1_ECODE_EC_RPE_REQ_DR_OWN_URC: return "EC_RPE_REQ_DR_OWN_URC";
      XTR_V1_ECODE_EC_RPE_RC_URC_ACCESS_INVLD: return "EC_RPE_RC_URC_ACCESS_INVLD";
      XTR_V1_ECODE_EC_RPE_ICRC_ERR_TRIM_PKT: return "EC_RPE_ICRC_ERR_TRIM_PKT";
      XTR_V1_ECODE_XTRDMA_CQE_ECODE_RX_REQ_NML: return "XTRDMA_CQE_ECODE_RX_REQ_NML";
      XTR_V1_ECODE_XTRDMA_CQE_ECODE_RX_RSP_NML: return "XTRDMA_CQE_ECODE_RX_RSP_NML";
      XTR_V1_ECODE_EC_RPE_OCC_QPC_ERR: return "EC_RPE_OCC_QPC_ERR";
      XTR_V1_ECODE_EC_RPE_RC_URC_OPCODE_INVLD: return "EC_RPE_RC_URC_OPCODE_INVLD";
      XTR_V1_ECODE_EC_RPE_RX_FLUSH: return "EC_RPE_RX_FLUSH";
      XTR_V1_ECODE_EC_RPE_REQ_RQ_WQE_ERR_UD: return "EC_RPE_REQ_RQ_WQE_ERR_UD";
      XTR_V1_ECODE_EC_RPE_REQ_ATOMIC_OCTBYTE_ALIGN_ERR: return "EC_RPE_REQ_ATOMIC_OCTBYTE_ALIGN_ERR";
      XTR_V1_ECODE_EC_RPE_REQ_OPCODE_MIS_LAST: return "EC_RPE_REQ_OPCODE_MIS_LAST";
      XTR_V1_ECODE_EC_RPE_REQ_OPCODE_MIS_FST: return "EC_RPE_REQ_OPCODE_MIS_FST";
      XTR_V1_ECODE_EC_RPE_REQ_PKT_LEN_UNMATCH_PMTU_PAD: return "EC_RPE_REQ_PKT_LEN_UNMATCH_PMTU_PAD";
      XTR_V1_ECODE_EC_RPE_REQ_PKT_LEN_UNMATCH_RETH: return "EC_RPE_REQ_PKT_LEN_UNMATCH_RETH";
      XTR_V1_ECODE_EC_RPE_REQ_PKT_LEN_UNMATCH_SGE_RC_URC: return "EC_RPE_REQ_PKT_LEN_UNMATCH_SGE_RC_URC";
      XTR_V1_ECODE_EC_RPE_REQ_RQ_WQE_ERR_RC_URC: return "EC_RPE_REQ_RQ_WQE_ERR_RC_URC";
      XTR_V1_ECODE_EC_RPE_RSP_ORQ_WQE_ERR: return "EC_RPE_RSP_ORQ_WQE_ERR";
      XTR_V1_ECODE_EC_RPE_RSP_OPCODE_MIS_LAST: return "EC_RPE_RSP_OPCODE_MIS_LAST";
      XTR_V1_ECODE_EC_RPE_RSP_OPCODE_MIS_FST: return "EC_RPE_RSP_OPCODE_MIS_FST";
      XTR_V1_ECODE_EC_RPE_RSP_PKT_LEN_UNMATCH_SGE_RC: return "EC_RPE_RSP_PKT_LEN_UNMATCH_SGE_RC";
      XTR_V1_ECODE_EC_RPE_RSP_PKT_LEN_UNMATCH_PMTU_PAD: return "EC_RPE_RSP_PKT_LEN_UNMATCH_PMTU_PAD";
      XTR_V1_ECODE_EC_RPE_RSP_PSN_UNMATCH_ORQ_LAST_PSN: return "EC_RPE_RSP_PSN_UNMATCH_ORQ_LAST_PSN";
      XTR_V1_ECODE_EC_RPE_RSP_ORQE_PSN_ERR: return "EC_RPE_RSP_ORQE_PSN_ERR";
      XTR_V1_ECODE_EC_RPE_RSP_NAK_RNR_ERR_OVERTIME: return "EC_RPE_RSP_NAK_RNR_ERR_OVERTIME";
      XTR_V1_ECODE_EC_RPE_NAK_FATAL_ERR: return "EC_RPE_NAK_FATAL_ERR";
      XTR_V1_ECODE_EC_RPE_RX_FLUSH_QP_INVLD: return "EC_RPE_RX_FLUSH_QP_INVLD";
      XTR_V1_ECODE_EC_RPE_URC_DR_TCIE: return "EC_RPE_URC_DR_TCIE";
      XTR_V1_ECODE_EC_RPE_NACK_CIE: return "EC_RPE_NACK_CIE";
      XTR_V1_ECODE_EC_RME_OCC_MR_ABNORMAL_RSLT: return "EC_RME_OCC_MR_ABNORMAL_RSLT";
      XTR_V1_ECODE_EC_RME_PBL_INVLD: return "EC_RME_PBL_INVLD";
      XTR_V1_ECODE_EC_RME_PKT_SRFQ_PD_ERR: return "EC_RME_PKT_SRFQ_PD_ERR";
      XTR_V1_ECODE_EC_RME_PKT_LEN_ZERO: return "EC_RME_PKT_LEN_ZERO";
      XTR_V1_ECODE_EC_RME_PKT_ST_ERR: return "EC_RME_PKT_ST_ERR";
      XTR_V1_ECODE_EC_RME_PKT_TYPE_ERR: return "EC_RME_PKT_TYPE_ERR";
      XTR_V1_ECODE_EC_RME_PKT_PD_ERR: return "EC_RME_PKT_PD_ERR";
      XTR_V1_ECODE_EC_RME_PKT_KEY_ERR: return "EC_RME_PKT_KEY_ERR";
      XTR_V1_ECODE_EC_RME_PKT_RIGHT_ERR: return "EC_RME_PKT_RIGHT_ERR";
      XTR_V1_ECODE_EC_RME_PKT_TYPE1_NOT_VA: return "EC_RME_PKT_TYPE1_NOT_VA";
      XTR_V1_ECODE_EC_RME_PKT_MR_LEN_ZERO: return "EC_RME_PKT_MR_LEN_ZERO";
      XTR_V1_ECODE_EC_RME_PKT_LEN_ERR: return "EC_RME_PKT_LEN_ERR";
      XTR_V1_ECODE_EC_RME_PKT_SRFQ_MR_ERR: return "EC_RME_PKT_SRFQ_MR_ERR";
      XTR_V1_ECODE_EC_RME_ROINVLD_NOT_PERMIT: return "EC_RME_ROINVLD_NOT_PERMIT";
      XTR_V1_ECODE_EC_RME_ROINVLD_ST_INVLD: return "EC_RME_ROINVLD_ST_INVLD";
      XTR_V1_ECODE_EC_RME_ROINVLD_TYPE1_MW: return "EC_RME_ROINVLD_TYPE1_MW";
      XTR_V1_ECODE_EC_RME_ROINVLD_PD_ERR: return "EC_RME_ROINVLD_PD_ERR";
      XTR_V1_ECODE_EC_RME_ROINVLD_KEY_ERR: return "EC_RME_ROINVLD_KEY_ERR";
      XTR_V1_ECODE_EC_RME_ROINVLD_MR_WITH_MW: return "EC_RME_ROINVLD_MR_WITH_MW";
      XTR_V1_ECODE_EC_RME_ROINVLD_TYPE2B_QPN_ERR: return "EC_RME_ROINVLD_TYPE2B_QPN_ERR";
      XTR_V1_ECODE_EC_RME_PKT_TYPE2B_QPN_ERR: return "EC_RME_PKT_TYPE2B_QPN_ERR";
      XTR_V1_ECODE_EC_RME_PLD_LEN_CHK_ERR: return "EC_RME_PLD_LEN_CHK_ERR";
      XTR_V1_ECODE_EC_RCE_OCC_EIRQ_RDSQ_ERR: return "EC_RCE_OCC_EIRQ_RDSQ_ERR";
      XTR_V1_ECODE_EC_RCE_OCC_UAQ_ERR: return "EC_RCE_OCC_UAQ_ERR";
      XTR_V1_ECODE_EC_RCE_URC_TACK_RBM_DUP_PKT: return "EC_RCE_URC_TACK_RBM_DUP_PKT";
      XTR_V1_ECODE_XTRDMA_CQE_ECODE_TX_EC_RCE_URC_SQ_CPL_SRBM_DUP_PKT: return
        "XTRDMA_CQE_ECODE_TX_EC_RCE_URC_SQ_CPL_SRBM_DUP_PKT";
      XTR_V1_ECODE_EC_RCE_OCC_CQC_ERR: return "EC_RCE_OCC_CQC_ERR";
      XTR_V1_ECODE_EC_RCE_CQC_INVLD: return "EC_RCE_CQC_INVLD";
      XTR_V1_ECODE_EC_RCE_CQ_FULL: return "EC_RCE_CQ_FULL";
      XTR_V1_ECODE_EC_RCE_CQ_LOAD_PBA_ERR: return "EC_RCE_CQ_LOAD_PBA_ERR";
      XTR_V1_ECODE_EC_RCE_COM_EST: return "EC_RCE_COM_EST";
      XTR_V1_ECODE_EC_RCE_CEQC_INVLD: return "EC_RCE_CEQC_INVLD";
      XTR_V1_ECODE_EC_RCE_CEQ_FULL: return "EC_RCE_CEQ_FULL";
      XTR_V1_ECODE_EC_RCE_AEQC_INVLD: return "EC_RCE_AEQC_INVLD";
      XTR_V1_ECODE_EC_RCE_AEQ_FULL: return "EC_RCE_AEQ_FULL";
      XTR_V1_ECODE_EC_GLB_MBUS_ERR: return "EC_GLB_MBUS_ERR";
      default: return $sformatf("XTR_V1_UNKNOWN_ECODE_0x%02x",
                                hardware_code);
    endcase
  endfunction

  // 功能：从硬件 image/缓冲区解码请求字段，验证布局和完整性后向调用方返回值或状态。
  // 输入/输出及副作用：参数 hardware_code, observed_engine, decoded 用于执行 decode_status；返回值或 output/inout 交付处理结果，必要时更新本对象状态。
  //   调用方不获得内部集合或外部依赖的所有权。
  // 失败/边界：镜像为空、长度不足或校验失败时不发布部分模型字段。
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

    candidate = new("xtr_v1_decoded_hardware_status");
    candidate.code = code;
    candidate.category = rdma_status::category_for(code);
    candidate.source_engine = source_engine;
    candidate.message = symbolic_name(hardware_code);
    candidate.retryable = code inside {
      RDMA_SC_DMA_TRANSLATION, RDMA_SC_PCIE_COMPLETION, RDMA_SC_QUEUE_FULL
    };
    if (hardware_code == XTR_V1_CMQ_SUCCESS_ECODE) begin
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
    return rdma_status::success("xtr_v1 hardware ecode decoded");
  endfunction
endclass
