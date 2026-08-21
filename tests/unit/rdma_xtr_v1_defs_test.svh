class rdma_xtr_v1_defs_test extends uvm_test;
  `uvm_component_utils(rdma_xtr_v1_defs_test)

  function new(string name = "rdma_xtr_v1_defs_test",
               uvm_component parent = null);
    super.new(name, parent);
  endfunction

  function void check_context_golden();
    rdma_xtr_v1_golden_case cases[$];
    string error;
    string expected_names[11] = '{
      "qpc_rc_boundary", "qpc_ud_boundary", "qpc_urc_boundary",
      "cqc_create_body_boundary", "mrt_register_pbl0_boundary",
      "mrt_register_pbl1_boundary", "mrt_register_pbl2_boundary",
      "mrt_key_alloc_pbl0_boundary", "srqc_create_body_boundary",
      "ceqc_create_body_boundary", "aeqc_create_body_boundary"
    };

    if (!rdma_xtr_v1_golden_reader::read_all(
          "../hw/xtr_v1/golden_vectors/context.hex", cases, error)) begin
      `uvm_error("GOLDEN", error)
      return;
    end
    if (cases.size() != 11) begin
      `uvm_error("GOLDEN", $sformatf("context case count %0d, expected 11",
                                     cases.size()))
      return;
    end
    foreach (cases[index]) begin
      int expected_bytes = (index < 3) ? 512 : 64;
      if (cases[index].name != expected_names[index])
        `uvm_error("GOLDEN", $sformatf("case %0d name %s", index,
                                       cases[index].name))
      if (cases[index].inputs.len() == 0)
        `uvm_error("GOLDEN", $sformatf("case %s has empty inputs",
                                       cases[index].name))
      if (cases[index].byte_count != expected_bytes ||
          cases[index].payload.size() != expected_bytes)
        `uvm_error("GOLDEN", $sformatf("case %s byte count mismatch",
                                       cases[index].name))
      foreach (cases[index].payload[byte_index]) begin
        if (!$isunknown(cases[index].payload[byte_index])) begin
          // Walking every byte is deliberate: truncated or malformed payloads
          // must not be hidden by a first-byte-only smoke check.
        end else begin
          `uvm_error("GOLDEN", $sformatf("case %s byte %0d is unknown",
                                         cases[index].name, byte_index))
        end
      end
    end
  endfunction

  function void check_golden_reader_rejections();
    byte unsigned payload[];
    string parsed_name;
    string error;

    if (rdma_xtr_v1_golden_reader::parse_payload_line(
          "AA\n", 1, payload, error))
      `uvm_error("GOLDEN_GRAMMAR", "uppercase hex was accepted")
    if (rdma_xtr_v1_golden_reader::parse_payload_line(
          "0g\n", 1, payload, error))
      `uvm_error("GOLDEN_GRAMMAR", "partial hex token was accepted")
    if (rdma_xtr_v1_golden_reader::parse_payload_line(
          "00  01\n", 2, payload, error))
      `uvm_error("GOLDEN_GRAMMAR", "noncanonical byte spacing was accepted")
    if (rdma_xtr_v1_golden_reader::parse_case_line(
          "# case: Qpc_rc_boundary\n", parsed_name, error))
      `uvm_error("GOLDEN_GRAMMAR", "uppercase case name was accepted")
    if (rdma_xtr_v1_golden_reader::parse_case_line(
          "# case: qpc-rc-boundary\n", parsed_name, error))
      `uvm_error("GOLDEN_GRAMMAR", "punctuated case name was accepted")
  endfunction

  function void check_mask_lookup_api();
    bit [63:0] mask_value;

    if (request_envelope_mask(0) != 64'h8fff3fff00000000 ||
        request_envelope_mask(1) != 0 || request_envelope_mask(8) != 0)
      `uvm_error("MASK_API", "request envelope qword lookup")
    if (!body_mask(RDMA_IMAGE_CQC, XTR_V1_OP_CQC_CREATE, 0, 0,
                   mask_value) || mask_value != 64'h00000000001fffff)
      `uvm_error("MASK_API", "CQC lookup")
    if (!body_mask(RDMA_IMAGE_MRT, XTR_V1_OP_KEY_ALLOC, 0, 2,
                   mask_value) || mask_value != 64'hffffffffffffffff)
      `uvm_error("MASK_API", "MRT key lookup")
    if (!body_mask(RDMA_IMAGE_SRQC, XTR_V1_OP_SRFQC_CREATE, 0, 2,
                   mask_value) || mask_value != 64'hcfffffffffffffff)
      `uvm_error("MASK_API", "SRQC lookup")
    if (!body_mask(RDMA_IMAGE_CEQC, XTR_V1_OP_CEQC_CREATE, 0, 3,
                   mask_value) || mask_value != 64'hfffffffffffff800)
      `uvm_error("MASK_API", "CEQC lookup")
    if (!body_mask(RDMA_IMAGE_AEQC, XTR_V1_OP_AEQC_CREATE, 0, 5,
                   mask_value) || mask_value != 64'hffff00000007ffff)
      `uvm_error("MASK_API", "AEQC lookup")

    mask_value = '1;
    if (body_mask(RDMA_IMAGE_CQC, XTR_V1_OP_AEQC_CREATE, 0, 0,
                  mask_value) || mask_value != 0)
      `uvm_error("MASK_API", "kind/opcode mismatch was accepted")
    mask_value = '1;
    if (body_mask(RDMA_IMAGE_MRT, XTR_V1_OP_MR_REGISTER, 0, 8,
                  mask_value) || mask_value != 0)
      `uvm_error("MASK_API", "out-of-range qword was accepted")
  endfunction

  task run_phase(uvm_phase phase);
    phase.raise_objection(this);

    if (XTR_V1_HW_VERSION != 1 || XTR_V1_QPC_BYTES != 512)
      `uvm_error("DEFS", "QPC size")
    if (XTR_V1_CQC_BYTES != 64)
      `uvm_error("DEFS", "CQC size")
    if (XTR_V1_CMQE_BYTES != 64 || XTR_V1_WQE_BYTES != 64)
      `uvm_error("DEFS", "entry size")
    if (XTR_V1_OP_QPC_CREATE != 8'h00 ||
        XTR_V1_OP_KEY_ALLOC != 8'h04 ||
        XTR_V1_OP_OCC_FLUSH != 8'h0a ||
        XTR_V1_OP_CQC_CREATE != 8'h0c ||
        XTR_V1_OP_CEQC_DELETE != 8'h12 ||
        XTR_V1_OP_CEQC_QUERY != 8'h13 ||
        XTR_V1_OP_AEQC_DELETE != 8'h16 ||
        XTR_V1_OP_AEQC_QUERY != 8'h17 ||
        XTR_V1_OP_TQ_FLUSH != 8'h20 ||
        XTR_V1_OP_SRFQC_CREATE != 8'h35)
      `uvm_error("DEFS", "CMQ opcode")
    if (XTR_V1_ALLOC_TYPE_DIRECT != 0 ||
        XTR_V1_ALLOC_TYPE_INDIRECT != 1 ||
        XTR_V1_ALLOC_TYPE_HUGE != 2 ||
        XTR_V1_ALLOC_TYPE_L3_INDIRECT != 3 ||
        XTR_V1_ADDR_TYPE_VA_BASED != 0 ||
        XTR_V1_ADDR_TYPE_ZERO_BASED != 1 ||
        XTR_V1_MR_ST_INVALID != 0 || XTR_V1_MR_ST_FREE != 1 ||
        XTR_V1_MR_ST_VALID != 2 || XTR_V1_HOST_PAGE_4K != 0 ||
        XTR_V1_HOST_PAGE_2M != 1 || XTR_V1_HOST_PAGE_1G != 2 ||
        XTR_V1_PBL_MODE_0 != 0 || XTR_V1_PBL_MODE_1 != 1 ||
        XTR_V1_PBL_MODE_2 != 2 || XTR_V1_MEM_TYPE_MR != 0 ||
        XTR_V1_MEM_TYPE_MW_TYPE1 != 1 || XTR_V1_MEM_TYPE_MW_TYPE2B != 2 ||
        XTR_V1_RIGHT_LOCAL_WRITE != 5'h01 ||
        XTR_V1_RIGHT_REMOTE_READ != 5'h02 ||
        XTR_V1_RIGHT_REMOTE_WRITE != 5'h04 ||
        XTR_V1_RIGHT_BIND_WINDOW != 5'h08 ||
        XTR_V1_RIGHT_REMOTE_ATOMIC != 5'h10)
      `uvm_error("DEFS", "context object/state/mode/right values")
    if (XTR_V1_NOTIFY_WINDOW_OFFSET != 64'h2000 ||
        XTR_V1_NOTIFY_WINDOW_SIZE != 64'h2000)
      `uvm_error("DEFS", "notify window")

    if (XTR_V1_QPC_QPN_OFFSET != 16 || XTR_V1_QPC_QPN_WIDTH != 21)
      `uvm_error("DEFS", "QPC QPN field")
    if (XTR_V1_CMQ_OPCODE_OFFSET != 32 ||
        XTR_V1_CMQ_OPCODE_WIDTH != 8)
      `uvm_error("DEFS", "CMQ opcode field")
    if (XTR_V1_SQ_WQE_OPCODE_OFFSET != 32 ||
        XTR_V1_SQ_WQE_OPCODE_WIDTH != 4 ||
        XTR_V1_CQE_QPN_OFFSET != 0 || XTR_V1_CQE_QPN_WIDTH != 18)
      `uvm_error("DEFS", "queue representative fields")
    if (XTR_V1_CMQ_DB_PI_OFFSET != 32 || XTR_V1_CMQ_DB_PI_WIDTH != 5 ||
        XTR_V1_NOTIFY_CQ_CQN_OFFSET != 0 ||
        XTR_V1_NOTIFY_CQ_CQN_WIDTH != 21)
      `uvm_error("DEFS", "doorbell representative fields")

    if (XTR_V1_CMQ_ENVELOPE_MASK[0] != 64'h8fff3fff00000000 ||
        XTR_V1_CQC_CREATE_BODY_MASK[0] != 64'h00000000001fffff ||
        XTR_V1_MRT_KEY_ALLOC_PBL0_BODY_MASK[2] != 64'hffffffffffffffff)
      `uvm_error("DEFS", "image masks")

    check_mask_lookup_api();
    check_golden_reader_rejections();
    check_context_golden();

    phase.drop_objection(this);
  endtask
endclass
