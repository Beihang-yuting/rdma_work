class rdma_xtr_v1_error_codec extends uvm_object;
  `uvm_object_utils(rdma_xtr_v1_error_codec)

  function new(string name = "rdma_xtr_v1_error_codec");
    super.new(name);
  endfunction

  local function bit valid_engine(rdma_engine_kind_e engine);
    return engine inside {
      RDMA_ENGINE_NONE, RDMA_ENGINE_RESOURCE, RDMA_ENGINE_CMQ,
      RDMA_ENGINE_SQ, RDMA_ENGINE_RQ, RDMA_ENGINE_CQ,
      RDMA_ENGINE_CEQ, RDMA_ENGINE_AEQ, RDMA_ENGINE_PCIE,
      RDMA_ENGINE_DMA, RDMA_ENGINE_NETWORK, RDMA_ENGINE_RESET
    };
  endfunction

  local function rdma_status_code_e classify(bit [7:0] hardware_code);
    case (hardware_code)
      8'h00:
        return RDMA_SC_OK;
      8'h45, 8'hc5:
        return RDMA_SC_DMA_TRANSLATION;
      8'h4b, 8'h4c, 8'h55, 8'h56,
      8'h60, 8'h61, 8'h62, 8'h63,
      8'hc7, 8'hcb, 8'hcc, 8'hcd,
      8'hd7, 8'hd8:
        return RDMA_SC_DMA_PERMISSION;
      8'h70, 8'hff:
        return RDMA_SC_PCIE_COMPLETION;
      8'hf4, 8'hf8, 8'hfb:
        return RDMA_SC_QUEUE_FULL;
      default:
        return RDMA_SC_UNKNOWN_HW_ERROR;
    endcase
  endfunction

  local function rdma_engine_kind_e inferred_engine(
    bit [7:0] hardware_code,
    rdma_status_code_e code
  );
    case (hardware_code)
      8'hf4: return RDMA_ENGINE_CQ;
      8'hf8: return RDMA_ENGINE_CEQ;
      8'hfb: return RDMA_ENGINE_AEQ;
      8'hff: return RDMA_ENGINE_PCIE;
      8'h01: return RDMA_ENGINE_SQ;
      8'h80, 8'h81: return RDMA_ENGINE_RQ;
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
  local function string symbolic_name(bit [7:0] hardware_code);
    case (hardware_code)
      8'h00: return "XTR_V1_CMQ_SUCCESS";
      8'h01: return "XTRDMA_CQE_ECODE_TX_RSP_NML";
      8'h02: return "EC_TPE_DB_TYPE_INVLD";
      8'h05: return "EC_TPE_OCC_QPC_ERR";
      8'h07: return "EC_TPE_TX_FLUSH";
      8'h08: return "EC_TPE_QP_FLUSH";
      8'h10: return "EC_TPE_SQ_VF_QPN_UNMATCH";
      8'h16: return "EC_TPE_SQ_RTO_OVERTIME";
      8'h17: return "EC_TPE_SQ_SIGN_ERR_OVERTIME";
      8'h18: return "EC_TPE_SQ_PSN_ERR_OVERTIME";
      8'h19: return "EC_TPE_SQ_KEY_ERR";
      8'h1b: return "EC_TPE_SQ_WQE_OPCODE_INVLD";
      8'h1e: return "EC_TPE_SQ_QP_ACCESS_ERR";
      8'h1f: return "EC_TPE_SQ_WQE_SIGN_ERR";
      8'h20: return "EC_TPE_SQ_RETRY_FENCE_WQE";
      8'h29: return "EC_TPE_SQ_PAYLOAD_LEN_ABOVE";
      8'h2a: return "EC_TPE_SQ_WRITE_LEN_UNMATCH";
      8'h2b: return "EC_TPE_SGB_KEY_ERR";
      8'h2c: return "EC_RTS2SQD_DB_QP_ST_UNMATCH";
      8'h2e: return "EC_RTS2SQD_DONE";
      8'h2f: return "EC_SQD2RTS_DB_QP_ST_UNMATCH";
      8'h30: return "EC_TPE_EIRQ_RDSQ_VF_QPN_UNMATCH";
      8'h36: return "EC_TPE_EIRQ_RDSQ_KEY_ERR";
      8'h38: return "EC_TPE_EIRQ_RDSQ_WQE_OPCODE_INVLD";
      8'h3a: return "EC_TPE_URC_RSQ_RTO_OVERTIME";
      8'h3b: return "EC_TPE_TX_LOCAL_WQE_RTO_OVERTIME";
      8'h3d: return "EC_TPE_SQ_SGE_PLD_LEN_UNMATCH";
      8'h44: return "EC_TME_OCC_MR_ABNORMAL_RSLT";
      8'h45: return "EC_TME_PBL_INVLD";
      8'h48: return "EC_TME_PKT_LEN_ZERO";
      8'h49: return "EC_TME_PKT_ST_ERR";
      8'h4a: return "EC_TME_PKT_TYPE_ERR";
      8'h4b: return "EC_TME_PKT_PD_ERR";
      8'h4c: return "EC_TME_PKT_KEY_ERR";
      8'h4d: return "EC_TME_PKT_TYPE1_NOT_VA";
      8'h4e: return "EC_TME_PKT_MR_LEN_ZERO";
      8'h4f: return "EC_TME_PKT_LEN_ERR";
      8'h50: return "EC_TME_PKT_TYPE2B_QPN_ERR";
      8'h51: return "EC_TME_PLD_LEN_CHK_ERR";
      8'h52: return "EC_TME_LOINVLD_NOT_PERMIT";
      8'h53: return "EC_TME_LOINVLD_ST_INVLD";
      8'h54: return "EC_TME_LOINVLD_TYPE1_MW";
      8'h55: return "EC_TME_LOINVLD_PD_ERR";
      8'h56: return "EC_TME_LOINVLD_KEY_ERR";
      8'h57: return "EC_TME_LOINVLD_MR_WITH_MW";
      8'h58: return "EC_TME_LOINVLD_TYPE2B_QPN_ERR";
      8'h5a: return "EC_TME_BIND_PARENT_MR_ST_NOT_VLD";
      8'h5b: return "EC_TME_BIND_MW_ST_INVLD";
      8'h5c: return "EC_TME_BIND_MW_ST_NOT_FREE";
      8'h5d: return "EC_TME_BIND_PARENT_MR_TYPE_ERR";
      8'h5e: return "EC_TME_BIND_MW_TYPE_ERR";
      8'h5f: return "EC_TME_BIND_WQE_TYPE_ERR";
      8'h60: return "EC_TME_BIND_PD_ERR";
      8'h61: return "EC_TME_BIND_PARENT_MR_KEY_ERR";
      8'h62: return "EC_TME_BIND_PARENT_MR_RIGHT_B_ERR";
      8'h63: return "EC_TME_BIND_PARENT_MR_RIGHT_LW_ERR";
      8'h64: return "EC_TME_BIND_PARENT_MR_NOT_VA";
      8'h65: return "EC_TME_BIND_MW_LEN_ERR";
      8'h66: return "EC_TME_BIND_MW_TYPE1_OP_ERR";
      8'h67: return "EC_TME_BIND_MW_TYPE2B_ZERO_BIND";
      8'h68: return "EC_TME_BIND_PARENT_MR_BIND_NUM_ERR";
      8'h6c: return "EC_TME_FMR_ST_ERR";
      8'h6d: return "EC_TME_FMR_TYPE_ERR";
      8'h6e: return "EC_TME_FMR_PD_ERR";
      8'h70: return "EC_TDE_DMA_ERR";
      8'h72: return "EC_TDE_SRC_ADDR_TBL_INVLD";
      8'h74: return "EC_CCE_RC_CCREQ";
      8'h75: return "EC_CCE_RC_ACK";
      8'h76: return "EC_CCE_URC_ACK";
      8'h78: return "EC_RPE_REQ_SRFQ_OVER_LIMIT_TH";
      8'h79: return "EC_RPE_REQ_SRFQ_PKT_LEN_UNMATCH_SGE";
      8'h7a: return "EC_RPE_REQ_SRFQ_WQE_ERR";
      8'h7b: return "EC_RPE_REQ_SRFQ_ST_INVLD";
      8'h7c: return "EC_RPE_REQ_DUP_DR_NML_URC";
      8'h7d: return "EC_RPE_REQ_DR_OWN_URC";
      8'h7e: return "EC_RPE_RC_URC_ACCESS_INVLD";
      8'h7f: return "EC_RPE_ICRC_ERR_TRIM_PKT";
      8'h80: return "XTRDMA_CQE_ECODE_RX_REQ_NML";
      8'h81: return "XTRDMA_CQE_ECODE_RX_RSP_NML";
      8'h85: return "EC_RPE_OCC_QPC_ERR";
      8'h8d: return "EC_RPE_RC_URC_OPCODE_INVLD";
      8'h8f: return "EC_RPE_RX_FLUSH";
      8'h91: return "EC_RPE_REQ_RQ_WQE_ERR_UD";
      8'h94: return "EC_RPE_REQ_ATOMIC_OCTBYTE_ALIGN_ERR";
      8'h95: return "EC_RPE_REQ_OPCODE_MIS_LAST";
      8'h96: return "EC_RPE_REQ_OPCODE_MIS_FST";
      8'h97: return "EC_RPE_REQ_PKT_LEN_UNMATCH_PMTU_PAD";
      8'h98: return "EC_RPE_REQ_PKT_LEN_UNMATCH_RETH";
      8'h9c: return "EC_RPE_REQ_PKT_LEN_UNMATCH_SGE_RC_URC";
      8'ha3: return "EC_RPE_REQ_RQ_WQE_ERR_RC_URC";
      8'ha4: return "EC_RPE_RSP_ORQ_WQE_ERR";
      8'ha8: return "EC_RPE_RSP_OPCODE_MIS_LAST";
      8'ha9: return "EC_RPE_RSP_OPCODE_MIS_FST";
      8'hab: return "EC_RPE_RSP_PKT_LEN_UNMATCH_SGE_RC";
      8'had: return "EC_RPE_RSP_PKT_LEN_UNMATCH_PMTU_PAD";
      8'hae: return "EC_RPE_RSP_PSN_UNMATCH_ORQ_LAST_PSN";
      8'hb3: return "EC_RPE_RSP_ORQE_PSN_ERR";
      8'hb7: return "EC_RPE_RSP_NAK_RNR_ERR_OVERTIME";
      8'hb9: return "EC_RPE_NAK_FATAL_ERR";
      8'hba: return "EC_RPE_RX_FLUSH_QP_INVLD";
      8'hbb: return "EC_RPE_URC_DR_TCIE";
      8'hbc: return "EC_RPE_NACK_CIE";
      8'hc4: return "EC_RME_OCC_MR_ABNORMAL_RSLT";
      8'hc5: return "EC_RME_PBL_INVLD";
      8'hc7: return "EC_RME_PKT_SRFQ_PD_ERR";
      8'hc8: return "EC_RME_PKT_LEN_ZERO";
      8'hc9: return "EC_RME_PKT_ST_ERR";
      8'hca: return "EC_RME_PKT_TYPE_ERR";
      8'hcb: return "EC_RME_PKT_PD_ERR";
      8'hcc: return "EC_RME_PKT_KEY_ERR";
      8'hcd: return "EC_RME_PKT_RIGHT_ERR";
      8'hce: return "EC_RME_PKT_TYPE1_NOT_VA";
      8'hcf: return "EC_RME_PKT_MR_LEN_ZERO";
      8'hd0: return "EC_RME_PKT_LEN_ERR";
      8'hd3: return "EC_RME_PKT_SRFQ_MR_ERR";
      8'hd4: return "EC_RME_ROINVLD_NOT_PERMIT";
      8'hd5: return "EC_RME_ROINVLD_ST_INVLD";
      8'hd6: return "EC_RME_ROINVLD_TYPE1_MW";
      8'hd7: return "EC_RME_ROINVLD_PD_ERR";
      8'hd8: return "EC_RME_ROINVLD_KEY_ERR";
      8'hd9: return "EC_RME_ROINVLD_MR_WITH_MW";
      8'hda: return "EC_RME_ROINVLD_TYPE2B_QPN_ERR";
      8'hdb: return "EC_RME_PKT_TYPE2B_QPN_ERR";
      8'hdc: return "EC_RME_PLD_LEN_CHK_ERR";
      8'he0: return "EC_RCE_OCC_EIRQ_RDSQ_ERR";
      8'he7: return "EC_RCE_OCC_UAQ_ERR";
      8'he8: return "EC_RCE_URC_TACK_RBM_DUP_PKT";
      8'hf0: return
        "XTRDMA_CQE_ECODE_TX_EC_RCE_URC_SQ_CPL_SRBM_DUP_PKT";
      8'hf2: return "EC_RCE_OCC_CQC_ERR";
      8'hf3: return "EC_RCE_CQC_INVLD";
      8'hf4: return "EC_RCE_CQ_FULL";
      8'hf5: return "EC_RCE_CQ_LOAD_PBA_ERR";
      8'hf6: return "EC_RCE_COM_EST";
      8'hf7: return "EC_RCE_CEQC_INVLD";
      8'hf8: return "EC_RCE_CEQ_FULL";
      8'hfa: return "EC_RCE_AEQC_INVLD";
      8'hfb: return "EC_RCE_AEQ_FULL";
      8'hff: return "EC_GLB_MBUS_ERR";
      default: return $sformatf("XTR_V1_UNKNOWN_ECODE_0x%02x",
                                hardware_code);
    endcase
  endfunction

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
    if (hardware_code == 0) begin
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
