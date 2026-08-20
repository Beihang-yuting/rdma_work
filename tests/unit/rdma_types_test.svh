class rdma_types_test extends uvm_test;
  `uvm_component_utils(rdma_types_test)

  function new(string name = "rdma_types_test", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  task run_phase(uvm_phase phase);
    rdma_bdf_t bdf = '{segment:16'h0, bus:8'h42, device:5'h03,
                       function_num:3'h5};
    rdma_backing_addr_t backing = '{value:64'h1_0000_1000};
    rdma_iova_t iova = '{value:64'h2_0000_1000};
    rdma_function_key_t function_key;
    rdma_status status;
    rdma_status ok_status;
    rdma_status default_status;
    string status_text;
    rdma_status_code_e codes[$] = '{
      RDMA_SC_OK,
      RDMA_SC_INVALID_ARGUMENT,
      RDMA_SC_INVALID_STATE,
      RDMA_SC_STALE_GENERATION,
      RDMA_SC_RESOURCE_EXHAUSTED,
      RDMA_SC_UNSUPPORTED_OPCODE,
      RDMA_SC_CODEC_ERROR,
      RDMA_SC_TIMEOUT,
      RDMA_SC_PCIE_COMPLETION,
      RDMA_SC_DMA_TRANSLATION,
      RDMA_SC_DMA_PERMISSION,
      RDMA_SC_QUEUE_FULL,
      RDMA_SC_QUEUE_EMPTY,
      RDMA_SC_UNKNOWN_HW_ERROR,
      RDMA_SC_RESET_CANCELLED
    };
    rdma_status_category_e categories[$] = '{
      RDMA_STATUS_STATE,
      RDMA_STATUS_CONFIGURATION,
      RDMA_STATUS_STATE,
      RDMA_STATUS_STATE,
      RDMA_STATUS_RESOURCE,
      RDMA_STATUS_CONFIGURATION,
      RDMA_STATUS_CODEC,
      RDMA_STATUS_TIMEOUT,
      RDMA_STATUS_PCIE,
      RDMA_STATUS_DMA,
      RDMA_STATUS_DMA,
      RDMA_STATUS_QUEUE,
      RDMA_STATUS_QUEUE,
      RDMA_STATUS_HARDWARE,
      RDMA_STATUS_RESET
    };

    phase.raise_objection(this);

    status = rdma_status::make(RDMA_SC_DMA_PERMISSION, "wrong DMA domain");
    if (rdma_bdf_requester_id(bdf) != 16'h421d)
      `uvm_error("BDF", "requester ID mismatch")
    if (backing.value == iova.value)
      `uvm_error("ADDR", "address spaces collapsed")
    if (status.ok() || status.category != RDMA_STATUS_DMA)
      `uvm_error("STATUS", "bad status")

    ok_status = rdma_status::success("ready");
    if (!ok_status.ok())
      `uvm_error("STATUS", "success() did not return an OK status")
    if (ok_status.code != RDMA_SC_OK ||
        ok_status.category != RDMA_STATUS_STATE ||
        ok_status.severity != RDMA_SEVERITY_INFO ||
        ok_status.message != "ready")
      `uvm_error("STATUS", "success() initialized fields incorrectly")

    default_status = rdma_status::type_id::create("default_status");
    if (!default_status.ok() ||
        default_status.category != RDMA_STATUS_STATE ||
        default_status.severity != RDMA_SEVERITY_INFO)
      `uvm_error("STATUS", "constructor defaults are not successful")

    foreach (codes[i]) begin
      if (rdma_status::category_for(codes[i]) != categories[i])
        `uvm_error("STATUS_MAP",
                   $sformatf("code %s mapped to %s instead of %s",
                             codes[i].name(),
                             rdma_status::category_for(codes[i]).name(),
                             categories[i].name()))
    end

    status.hardware_code_valid = 1'b1;
    status.hardware_code = 32'hdead_beef;
    status.source_engine = RDMA_ENGINE_DMA;
    status.function_uid = 64'h0123_4567_89ab_cdef;
    status.generation = 32'd17;
    status.resource_id = 64'h1111_2222_3333_4444;
    status.command_id = 64'h5555_6666_7777_8888;
    status.wr_id = 64'h9999_aaaa_bbbb_cccc;
    status.retryable = 1'b1;
    status_text = status.convert2string();
    if (status_text != {"rdma_status(category=RDMA_STATUS_DMA ",
                        "code=RDMA_SC_DMA_PERMISSION ",
                        "hardware_code_valid=1 ",
                        "hardware_code=0xdeadbeef ",
                        "source_engine=RDMA_ENGINE_DMA ",
                        "function_uid=0x0123456789abcdef ",
                        "generation=17 ",
                        "resource_id=0x1111222233334444 ",
                        "command_id=0x5555666677778888 ",
                        "wr_id=0x9999aaaabbbbcccc ",
                        "severity=RDMA_SEVERITY_ERROR ",
                        "retryable=1 ",
                        "message=\"wrong DMA domain\")"})
      `uvm_error("STATUS_STRING",
                 $sformatf("unexpected status string: %s", status_text))

    status = rdma_status::make(RDMA_SC_UNKNOWN_HW_ERROR);
    if (status.ok())
      `uvm_error("STATUS", "unknown hardware error reported success")

    function_key = '{
      root_id:16'h1001,
      host_topology_key:32'h2002_0002,
      function_kind:RDMA_FUNCTION_VF,
      parent_pf_bdf:'{segment:16'h3003, bus:8'h30, device:5'h03,
                      function_num:3'h3},
      vf_index:16'h4004,
      bdf:'{segment:16'h5005, bus:8'h50, device:5'h05,
            function_num:3'h5}
    };
    if (function_key.root_id != 16'h1001 ||
        function_key.host_topology_key != 32'h2002_0002 ||
        function_key.function_kind != RDMA_FUNCTION_VF ||
        function_key.parent_pf_bdf.segment != 16'h3003 ||
        function_key.parent_pf_bdf.bus != 8'h30 ||
        function_key.parent_pf_bdf.device != 5'h03 ||
        function_key.parent_pf_bdf.function_num != 3'h3 ||
        function_key.vf_index != 16'h4004 ||
        function_key.bdf.segment != 16'h5005 ||
        function_key.bdf.bus != 8'h50 ||
        function_key.bdf.device != 5'h05 ||
        function_key.bdf.function_num != 3'h5)
      `uvm_error("FUNCTION_KEY", "function identity fields are not independent")

    phase.drop_objection(this);
  endtask
endclass
