class rdma_xtr_v1_defs_test extends uvm_test;
  `uvm_component_utils(rdma_xtr_v1_defs_test)

  function new(string name = "rdma_xtr_v1_defs_test",
               uvm_component parent = null);
    super.new(name, parent);
  endfunction

  function void check_golden_contract(string path, int expected_bytes);
    int fd;
    int parsed_bytes;
    int first_byte;
    string line;
    string token;

    fd = $fopen(path, "r");
    if (fd == 0) begin
      `uvm_error("GOLDEN", $sformatf("cannot open %s", path))
      return;
    end

    if (!$fgets(line, fd) || $sscanf(line, "# %s", token) != 1 ||
        token != "xtr_v1-golden-v1")
      `uvm_error("GOLDEN", $sformatf("%s has no format marker", path))
    if (!$fgets(line, fd) || $sscanf(line, "# case: %s", token) != 1)
      `uvm_error("GOLDEN", $sformatf("%s has no case name", path))
    if (!$fgets(line, fd) || $sscanf(line, "# inputs: %s", token) != 1)
      `uvm_error("GOLDEN", $sformatf("%s has no input summary", path))
    if (!$fgets(line, fd) ||
        $sscanf(line, "# bytes: %d", parsed_bytes) != 1 ||
        parsed_bytes != expected_bytes)
      `uvm_error("GOLDEN", $sformatf("%s has wrong byte count", path))
    if (!$fgets(line, fd) || $sscanf(line, "%h", first_byte) != 1)
      `uvm_error("GOLDEN", $sformatf("%s has no hex payload", path))
    $fclose(fd);
  endfunction

  task run_phase(uvm_phase phase);
    phase.raise_objection(this);

    if (XTR_V1_QPC_BYTES != 512)
      `uvm_error("DEFS", "QPC size")
    if (XTR_V1_CQC_BYTES != 64)
      `uvm_error("DEFS", "CQC size")
    if (XTR_V1_CMQE_BYTES != 64 || XTR_V1_WQE_BYTES != 64)
      `uvm_error("DEFS", "entry size")
    if (XTR_V1_OP_QPC_CREATE != 8'h00 ||
        XTR_V1_OP_CQC_CREATE != 8'h0c ||
        XTR_V1_OP_SRFQC_CREATE != 8'h35)
      `uvm_error("DEFS", "CMQ opcode")
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

    check_golden_contract("../hw/xtr_v1/golden_vectors/context.hex", 512);
    check_golden_contract("../hw/xtr_v1/golden_vectors/cmq.hex", 64);
    check_golden_contract("../hw/xtr_v1/golden_vectors/queue.hex", 64);
    check_golden_contract("../hw/xtr_v1/golden_vectors/doorbell.hex", 8);

    phase.drop_objection(this);
  endtask
endclass
