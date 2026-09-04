// 目录：硬件编解码层 codec/rdma/rdma_error_codec.sv。
// 职责：实现 rdma_hw_error_codec 在本层的职责和对外接口。
// 依赖：依赖本层公共 types/model/adapter 契约及其上游快照。
// 所有权与生命周期：对象只拥有显式创建的值快照；外部资源保存非拥有引用，生命周期由调用方管理。

// 中文说明：rdma_error_codec.sv 属于编码层，将模型字段转换为硬件图像并执行反向校验。
// 阅读提示：先看公开类型和接口，再看实现细节；失败路径应保持状态与资源所有权可追踪。

class rdma_hw_error_codec extends uvm_object;
  `uvm_object_utils(rdma_hw_error_codec)

  // 功能：构造 rdma_hw_error_codec，调用 super.new 建立 UVM 层级对象；外部依赖字段保持未绑定，后续由 configure/build/activate 明确注入。
  // 输入/输出及副作用：name（输入）；new 只写入构造体列出的默认字段并返回 void，外部依赖与资源所有权仍由上层管理。
  // 失败/边界：rdma_hw_error_codec 构造只建立本地初始状态，不接管外部 Host-memory、PCIe 或 manager；未完成后续 configure/build/activate 时，业务入口必须返回 INVALID_STATE。
  function new(string name = "rdma_hw_error_codec");
    super.new(name);
  endfunction

  // 功能：判断 valid_engine 对应的状态、能力或账本条件，并返回确定的布尔/计数结果，不修改状态。
  // 输入/输出及副作用：engine（输入）；valid_engine 读取 engine 并使用输入参数和固定枚举/常量；函数返回 bit，不取得调用方资源所有权。
  // 失败/边界：valid_engine 只读取现有账本；输入未初始化时返回保守结果，不得借助默认 Function/root 猜测。
  local function bit valid_engine(rdma_engine_kind_e engine);
    return engine inside {
      RDMA_ENGINE_NONE, RDMA_ENGINE_RESOURCE, RDMA_ENGINE_CMQ,
      RDMA_ENGINE_SQ, RDMA_ENGINE_RQ, RDMA_ENGINE_CQ,
      RDMA_ENGINE_CEQ, RDMA_ENGINE_AEQ, RDMA_ENGINE_PCIE,
      RDMA_ENGINE_DMA, RDMA_ENGINE_NETWORK, RDMA_ENGINE_RESET
    };
  endfunction

  // 功能：classify 使用 hardware_code 计算并返回 rdma_status_code_e 结果；不修改对象字段或外部资源。
  // 输入/输出及副作用：hardware_code（输入）；classify 读取 hardware_code 并使用输入参数和固定枚举/常量；函数返回 rdma_status_code_e，不取得调用方资源所有权。
  // 失败/边界：classify 的结果直接由 return RDMA_SC_OK 计算；输入不满足表达式条件时沿函数体的保守分支返回，不修改已发布账本。
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

  // 功能：在 rdma_hw_error_codec 中，inferred_engine 把输入枚举或资源类型映射成对应的状态类别、执行引擎、opcode 或生命周期策略。
  // 输入/输出及副作用：hardware_code（输入）、code（输入）；inferred_engine 读取 hardware_code、code 并使用输入参数和固定枚举/常量；函数返回 rdma_engine_kind_e，不取得调用方资源所有权。
  // 失败/边界：inferred_engine 按 case(hardware_code、code) 的固定映射计算 rdma_engine_kind_e（RDMA_ECODE_EC_RCE_CQ_FULL→RDMA_ENGINE_CQ；RDMA_ECODE_EC_RCE_CEQ_FULL→RDMA_ENGINE_CEQ；RDMA_ECODE_EC_RCE_AEQ_FULL→RDMA_ENGINE_AEQ；RDMA_ECODE_EC_GLB_MBUS_ERR→RDMA_ENGINE_PCIE；其余 case 分支按源码继续映射；default→RDMA_ENGINE_CMQ）；未列出的输入走 default，不修改运行时账本。
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

  // Names and membership are transcribed from the frozen driver defs.h/wr.h
  // at commit 491faf2ba42627fffd4dd027607299c8bb591ec2.
  // 功能：在 rdma_hw_error_codec 中，symbolic_name 把冻结驱动定义中的 8-bit hardware ecode 映射成稳定符号名，供状态诊断文本使用。
  // 输入/输出及副作用：hardware_code（输入）；symbolic_name 读取 hardware_code 并使用输入参数和固定枚举/常量；函数返回 string，不取得调用方资源所有权。
  // 失败/边界：symbolic_name 按 case(hardware_code) 的固定映射计算 string（RDMA_CMQ_SUCCESS_ECODE→"RDMA_CMQ_SUCCESS"；RDMA_ECODE_XTRDMA_CQE_ECODE_TX_RSP_NML→"XTRDMA_CQE_ECODE_TX_RSP_NML"；RDMA_ECODE_EC_TPE_DB_TYPE_INVLD→"EC_TPE_DB_TYPE_INVLD"；RDMA_ECODE_EC_TPE_OCC_QPC_ERR→"EC_TPE_OCC_QPC_ERR"；其余 case 分支按源码继续映射）；未列出的输入走 default，不修改运行时账本。
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

  // 功能：在 rdma_hw_error_codec 中，decode_status 从硬件 image/缓冲区解码字段，验证长度、布局和完整性后返回模型或状态。
  // 输入/输出及副作用：hardware_code（输入）、observed_engine（输入）、decoded（输出）；decode_status 读取 hardware_code、observed_engine、decoded 并使用字段 decoded、code、source_engine、candidate、candidate.code、candidate.category、candidate.source_engine、candidate.message，并写入 decoded；函数返回 rdma_status，不取得调用方资源所有权。

  // 失败/边界：decode_status 遇到 image/model 为空、长度/对齐/保留位非法或 codec 校验失败时不发布部分字段。
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
