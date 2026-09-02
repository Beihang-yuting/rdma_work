class rdma_types_test extends uvm_test;
  `uvm_component_utils(rdma_types_test)

  function new(string name = "rdma_types_test", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  function automatic bit status_has_defaults(
    rdma_status status,
    rdma_status_category_e expected_category,
    rdma_status_code_e expected_code,
    rdma_severity_e expected_severity,
    string expected_message
  );
    return status.category == expected_category &&
           status.code == expected_code &&
           status.hardware_code == 32'h0 &&
           !status.hardware_code_valid &&
           status.source_engine == RDMA_ENGINE_NONE &&
           status.function_uid == 64'h0 &&
           status.generation == 32'h0 &&
           status.resource_id == 64'h0 &&
           status.command_id == 64'h0 &&
           status.wr_id == 64'h0 &&
           status.severity == expected_severity &&
           !status.retryable &&
           status.message == expected_message;
  endfunction

  function automatic void check_enum_code(
    string enum_name,
    bit [31:0] actual,
    bit [31:0] expected
  );
    if (actual != expected)
      `uvm_error("ENUM_CODE",
                 $sformatf("%s is %0d instead of %0d",
                           enum_name, actual, expected))
  endfunction

  function automatic void expect_status_category(
    string check_name,
    rdma_status_code_e code,
    rdma_status_category_e expected_category
  );
    rdma_status_category_e actual_category;

    actual_category = rdma_status::category_for(code);
    if (actual_category != expected_category)
      `uvm_error(check_name,
                 $sformatf("expected %s, got %s",
                           expected_category.name(), actual_category.name()))
  endfunction

  task run_phase(uvm_phase phase);
    rdma_bdf_t bdf = '{segment:16'h0, bus:8'h42, device:5'h03,
                       function_num:3'h5};
    rdma_backing_addr_t backing = '{value:64'h1_0000_1000};
    rdma_iova_t iova = '{value:64'h2_0000_1000};
    rdma_hmc_fvm_addr_t hmc_fvm = '{value:64'h3_0000_1000};
    rdma_bar_addr_t bar = '{value:64'h4_0000_1000};
    rdma_cfg_offset_t cfg_offset = '{value:12'habc};
    rdma_function_key_t function_key;
    rdma_status status;
    rdma_status ok_status;
    rdma_status message_status;
    rdma_status default_status;
    rdma_status direct_status;
    string address_type_names[5];
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
      RDMA_SC_RESET_CANCELLED,
      RDMA_SC_RESOURCE_BUSY,
      RDMA_SC_RECOVERY_REQUIRED
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
      RDMA_STATUS_RESET,
      RDMA_STATUS_RESOURCE,
      RDMA_STATUS_STATE
    };

    phase.raise_objection(this);

    if (rdma_bdf_requester_id(bdf) != 16'h421d)
      `uvm_error("BDF", "requester ID mismatch")

    if ($bits(backing) != 64 ||
        $bits(iova) != 64 ||
        $bits(hmc_fvm) != 64 ||
        $bits(bar) != 64 ||
        $bits(cfg_offset) != 12)
      `uvm_error("ADDR_BITS", "address wrapper width mismatch")
    address_type_names[0] = $typename(backing);
    address_type_names[1] = $typename(iova);
    address_type_names[2] = $typename(hmc_fvm);
    address_type_names[3] = $typename(bar);
    address_type_names[4] = $typename(cfg_offset);
    for (int unsigned i = 0; i < 5; i++) begin
      for (int unsigned j = i + 1; j < 5; j++) begin
        if (address_type_names[i] == address_type_names[j])
          `uvm_error("ADDR_TYPE",
                     $sformatf("address types %0d and %0d both report %s",
                               i, j, address_type_names[i]))
      end
    end

    check_enum_code("RDMA_SC_OK", RDMA_SC_OK, 5'd0);
    check_enum_code("RDMA_SC_INVALID_ARGUMENT", RDMA_SC_INVALID_ARGUMENT, 5'd1);
    check_enum_code("RDMA_SC_INVALID_STATE", RDMA_SC_INVALID_STATE, 5'd2);
    check_enum_code("RDMA_SC_STALE_GENERATION", RDMA_SC_STALE_GENERATION, 5'd3);
    check_enum_code("RDMA_SC_RESOURCE_EXHAUSTED", RDMA_SC_RESOURCE_EXHAUSTED, 5'd4);
    check_enum_code("RDMA_SC_UNSUPPORTED_OPCODE", RDMA_SC_UNSUPPORTED_OPCODE, 5'd5);
    check_enum_code("RDMA_SC_CODEC_ERROR", RDMA_SC_CODEC_ERROR, 5'd6);
    check_enum_code("RDMA_SC_TIMEOUT", RDMA_SC_TIMEOUT, 5'd7);
    check_enum_code("RDMA_SC_PCIE_COMPLETION", RDMA_SC_PCIE_COMPLETION, 5'd8);
    check_enum_code("RDMA_SC_DMA_TRANSLATION", RDMA_SC_DMA_TRANSLATION, 5'd9);
    check_enum_code("RDMA_SC_DMA_PERMISSION", RDMA_SC_DMA_PERMISSION, 5'd10);
    check_enum_code("RDMA_SC_QUEUE_FULL", RDMA_SC_QUEUE_FULL, 5'd11);
    check_enum_code("RDMA_SC_QUEUE_EMPTY", RDMA_SC_QUEUE_EMPTY, 5'd12);
    check_enum_code("RDMA_SC_UNKNOWN_HW_ERROR", RDMA_SC_UNKNOWN_HW_ERROR, 5'd13);
    check_enum_code("RDMA_SC_RESET_CANCELLED", RDMA_SC_RESET_CANCELLED, 5'd14);
    check_enum_code("RDMA_SC_RESOURCE_BUSY", RDMA_SC_RESOURCE_BUSY, 5'd15);
    check_enum_code("RDMA_SC_RECOVERY_REQUIRED", RDMA_SC_RECOVERY_REQUIRED,
                    5'd16);

    check_enum_code("RDMA_STATUS_CONFIGURATION", RDMA_STATUS_CONFIGURATION, 4'd0);
    check_enum_code("RDMA_STATUS_RESOURCE", RDMA_STATUS_RESOURCE, 4'd1);
    check_enum_code("RDMA_STATUS_STATE", RDMA_STATUS_STATE, 4'd2);
    check_enum_code("RDMA_STATUS_CODEC", RDMA_STATUS_CODEC, 4'd3);
    check_enum_code("RDMA_STATUS_TIMEOUT", RDMA_STATUS_TIMEOUT, 4'd4);
    check_enum_code("RDMA_STATUS_PCIE", RDMA_STATUS_PCIE, 4'd5);
    check_enum_code("RDMA_STATUS_DMA", RDMA_STATUS_DMA, 4'd6);
    check_enum_code("RDMA_STATUS_QUEUE", RDMA_STATUS_QUEUE, 4'd7);
    check_enum_code("RDMA_STATUS_HARDWARE", RDMA_STATUS_HARDWARE, 4'd8);
    check_enum_code("RDMA_STATUS_NETWORK", RDMA_STATUS_NETWORK, 4'd9);
    check_enum_code("RDMA_STATUS_RESET", RDMA_STATUS_RESET, 4'd10);

    check_enum_code("RDMA_BIND_DISCOVERED", RDMA_BIND_DISCOVERED, 4'd0);
    check_enum_code("RDMA_BIND_PCIE_CONFIGURED", RDMA_BIND_PCIE_CONFIGURED, 4'd1);
    check_enum_code("RDMA_BIND_BOUND", RDMA_BIND_BOUND, 4'd2);
    check_enum_code("RDMA_BIND_PREPARED", RDMA_BIND_PREPARED, 4'd3);
    check_enum_code("RDMA_BIND_ACTIVE", RDMA_BIND_ACTIVE, 4'd4);
    check_enum_code("RDMA_BIND_QUIESCING", RDMA_BIND_QUIESCING, 4'd5);
    check_enum_code("RDMA_BIND_RESETTING", RDMA_BIND_RESETTING, 4'd6);
    check_enum_code("RDMA_BIND_RELEASED", RDMA_BIND_RELEASED, 4'd7);
    check_enum_code("RDMA_BIND_ERROR", RDMA_BIND_ERROR, 4'd8);

    check_enum_code("RDMA_RESOURCE_FUNCTION", RDMA_RESOURCE_FUNCTION, 4'd0);
    check_enum_code("RDMA_RESOURCE_PD", RDMA_RESOURCE_PD, 4'd1);
    check_enum_code("RDMA_RESOURCE_MR", RDMA_RESOURCE_MR, 4'd2);
    check_enum_code("RDMA_RESOURCE_CQ", RDMA_RESOURCE_CQ, 4'd3);
    check_enum_code("RDMA_RESOURCE_QP", RDMA_RESOURCE_QP, 4'd4);
    check_enum_code("RDMA_RESOURCE_SRQ", RDMA_RESOURCE_SRQ, 4'd5);
    check_enum_code("RDMA_RESOURCE_CMQ", RDMA_RESOURCE_CMQ, 4'd6);
    check_enum_code("RDMA_RESOURCE_CEQ", RDMA_RESOURCE_CEQ, 4'd7);
    check_enum_code("RDMA_RESOURCE_AEQ", RDMA_RESOURCE_AEQ, 4'd8);

    check_enum_code("RDMA_TRANSPORT_RC", RDMA_TRANSPORT_RC, 3'd0);
    check_enum_code("RDMA_TRANSPORT_UD", RDMA_TRANSPORT_UD, 3'd1);
    check_enum_code("RDMA_TRANSPORT_URC", RDMA_TRANSPORT_URC, 3'd2);
    check_enum_code("RDMA_TRANSPORT_CUSTOM", RDMA_TRANSPORT_CUSTOM, 3'd3);
    check_enum_code("RDMA_TRANSPORT_RESERVED", RDMA_TRANSPORT_RESERVED, 3'd4);

    check_enum_code("RDMA_DMA_DEVICE_READ", RDMA_DMA_DEVICE_READ, 2'd0);
    check_enum_code("RDMA_DMA_DEVICE_WRITE", RDMA_DMA_DEVICE_WRITE, 2'd1);
    check_enum_code("RDMA_DMA_BIDIRECTIONAL", RDMA_DMA_BIDIRECTIONAL, 2'd2);

    check_enum_code("RDMA_MAPPING_INVALID", RDMA_MAPPING_INVALID, 2'd0);
    check_enum_code("RDMA_MAPPING_ACTIVE", RDMA_MAPPING_ACTIVE, 2'd1);
    check_enum_code("RDMA_MAPPING_FROZEN", RDMA_MAPPING_FROZEN, 2'd2);
    check_enum_code("RDMA_MAPPING_RELEASED", RDMA_MAPPING_RELEASED, 2'd3);

    check_enum_code("RDMA_IMAGE_NONE", RDMA_IMAGE_NONE, 5'd0);
    check_enum_code("RDMA_IMAGE_QPC", RDMA_IMAGE_QPC, 5'd1);
    check_enum_code("RDMA_IMAGE_CQC", RDMA_IMAGE_CQC, 5'd2);
    check_enum_code("RDMA_IMAGE_MRT", RDMA_IMAGE_MRT, 5'd3);
    check_enum_code("RDMA_IMAGE_SRQC", RDMA_IMAGE_SRQC, 5'd4);
    check_enum_code("RDMA_IMAGE_CEQC", RDMA_IMAGE_CEQC, 5'd5);
    check_enum_code("RDMA_IMAGE_AEQC", RDMA_IMAGE_AEQC, 5'd6);
    check_enum_code("RDMA_IMAGE_CMQ_SQE", RDMA_IMAGE_CMQ_SQE, 5'd7);
    check_enum_code("RDMA_IMAGE_CMQ_CQE", RDMA_IMAGE_CMQ_CQE, 5'd8);
    check_enum_code("RDMA_IMAGE_SQE", RDMA_IMAGE_SQE, 5'd9);
    check_enum_code("RDMA_IMAGE_RQE", RDMA_IMAGE_RQE, 5'd10);
    check_enum_code("RDMA_IMAGE_CQE", RDMA_IMAGE_CQE, 5'd11);
    check_enum_code("RDMA_IMAGE_CEQE", RDMA_IMAGE_CEQE, 5'd12);
    check_enum_code("RDMA_IMAGE_AEQE", RDMA_IMAGE_AEQE, 5'd13);
    check_enum_code("RDMA_IMAGE_DOORBELL", RDMA_IMAGE_DOORBELL, 5'd14);

    check_enum_code("RDMA_DOORBELL_CMQ_SQ", RDMA_DOORBELL_CMQ_SQ, 4'd0);
    check_enum_code("RDMA_DOORBELL_SQ", RDMA_DOORBELL_SQ, 4'd1);
    check_enum_code("RDMA_DOORBELL_RQ", RDMA_DOORBELL_RQ, 4'd2);
    check_enum_code("RDMA_DOORBELL_SRQ", RDMA_DOORBELL_SRQ, 4'd3);
    check_enum_code("RDMA_DOORBELL_CQ", RDMA_DOORBELL_CQ, 4'd4);
    check_enum_code("RDMA_DOORBELL_CEQ", RDMA_DOORBELL_CEQ, 4'd5);
    check_enum_code("RDMA_DOORBELL_AEQ", RDMA_DOORBELL_AEQ, 4'd6);
    check_enum_code("RDMA_DOORBELL_QP_FLUSH", RDMA_DOORBELL_QP_FLUSH, 4'd7);
    check_enum_code("RDMA_DOORBELL_TX_FLUSH", RDMA_DOORBELL_TX_FLUSH, 4'd8);
    check_enum_code("RDMA_DOORBELL_RTS2SQD", RDMA_DOORBELL_RTS2SQD, 4'd9);
    check_enum_code("RDMA_DOORBELL_SQD2RTS", RDMA_DOORBELL_SQD2RTS, 4'd10);

    check_enum_code("RDMA_ENGINE_NONE", RDMA_ENGINE_NONE, 4'd0);
    check_enum_code("RDMA_ENGINE_RESOURCE", RDMA_ENGINE_RESOURCE, 4'd1);
    check_enum_code("RDMA_ENGINE_CMQ", RDMA_ENGINE_CMQ, 4'd2);
    check_enum_code("RDMA_ENGINE_SQ", RDMA_ENGINE_SQ, 4'd3);
    check_enum_code("RDMA_ENGINE_RQ", RDMA_ENGINE_RQ, 4'd4);
    check_enum_code("RDMA_ENGINE_CQ", RDMA_ENGINE_CQ, 4'd5);
    check_enum_code("RDMA_ENGINE_CEQ", RDMA_ENGINE_CEQ, 4'd6);
    check_enum_code("RDMA_ENGINE_AEQ", RDMA_ENGINE_AEQ, 4'd7);
    check_enum_code("RDMA_ENGINE_PCIE", RDMA_ENGINE_PCIE, 4'd8);
    check_enum_code("RDMA_ENGINE_DMA", RDMA_ENGINE_DMA, 4'd9);
    check_enum_code("RDMA_ENGINE_NETWORK", RDMA_ENGINE_NETWORK, 4'd10);
    check_enum_code("RDMA_ENGINE_RESET", RDMA_ENGINE_RESET, 4'd11);

    check_enum_code("RDMA_SEVERITY_INFO", RDMA_SEVERITY_INFO, 2'd0);
    check_enum_code("RDMA_SEVERITY_WARNING", RDMA_SEVERITY_WARNING, 2'd1);
    check_enum_code("RDMA_SEVERITY_ERROR", RDMA_SEVERITY_ERROR, 2'd2);
    check_enum_code("RDMA_SEVERITY_FATAL", RDMA_SEVERITY_FATAL, 2'd3);
    if ($bits(rdma_severity_e) != 2)
      `uvm_error("RDMA_SEVERITY_WIDTH", "rdma_severity_e is not two bits")

    check_enum_code("RDMA_RESPONDER_DUT", RDMA_RESPONDER_DUT, 2'd0);
    check_enum_code("RDMA_RESPONDER_VIP", RDMA_RESPONDER_VIP, 2'd1);
    check_enum_code("RDMA_RESPONDER_MONITOR_ONLY", RDMA_RESPONDER_MONITOR_ONLY, 2'd2);

    check_enum_code("RDMA_RESET_FLR", RDMA_RESET_FLR, 2'd0);
    check_enum_code("RDMA_RESET_VF_DISABLE", RDMA_RESET_VF_DISABLE, 2'd1);
    check_enum_code("RDMA_RESET_FUNCTION_RESET", RDMA_RESET_FUNCTION_RESET, 2'd2);
    check_enum_code("RDMA_RESET_DUT_RESET", RDMA_RESET_DUT_RESET, 2'd3);

    check_enum_code("RDMA_FAULT_WRONG_REQUESTER", RDMA_FAULT_WRONG_REQUESTER, 3'd0);
    check_enum_code("RDMA_FAULT_IOVA_PERMISSION", RDMA_FAULT_IOVA_PERMISSION, 3'd1);
    check_enum_code("RDMA_FAULT_CMQ_TIMEOUT", RDMA_FAULT_CMQ_TIMEOUT, 3'd2);
    check_enum_code("RDMA_FAULT_CQE_ERROR", RDMA_FAULT_CQE_ERROR, 3'd3);
    check_enum_code("RDMA_FAULT_PACKET_DROP", RDMA_FAULT_PACKET_DROP, 3'd4);
    check_enum_code("RDMA_FAULT_VF_FLR", RDMA_FAULT_VF_FLR, 3'd5);

    check_enum_code("RDMA_FUNCTION_PF", RDMA_FUNCTION_PF, 1'd0);
    check_enum_code("RDMA_FUNCTION_VF", RDMA_FUNCTION_VF, 1'd1);
    check_enum_code("RDMA_ENDIAN_LITTLE", RDMA_ENDIAN_LITTLE, 1'd0);
    check_enum_code("RDMA_ENDIAN_BIG", RDMA_ENDIAN_BIG, 1'd1);

    message_status = rdma_status::make(RDMA_SC_DMA_PERMISSION,
                                       "wrong DMA domain");
    if (!status_has_defaults(message_status,
                             RDMA_STATUS_DMA,
                             RDMA_SC_DMA_PERMISSION,
                             RDMA_SEVERITY_ERROR,
                             "wrong DMA domain"))
      `uvm_error("STATUS", "make() initialized fields incorrectly")

    status = rdma_status::make(RDMA_SC_DMA_PERMISSION);
    if (!status_has_defaults(status,
                             RDMA_STATUS_DMA,
                             RDMA_SC_DMA_PERMISSION,
                             RDMA_SEVERITY_ERROR,
                             ""))
      `uvm_error("STATUS", "make() empty-message defaults are incorrect")

    ok_status = rdma_status::success();
    if (!status_has_defaults(ok_status,
                             RDMA_STATUS_STATE,
                             RDMA_SC_OK,
                             RDMA_SEVERITY_INFO,
                             "") ||
        !ok_status.ok())
      `uvm_error("STATUS", "success() defaults are incorrect")

    ok_status = rdma_status::success("ready");
    if (!status_has_defaults(ok_status,
                             RDMA_STATUS_STATE,
                             RDMA_SC_OK,
                             RDMA_SEVERITY_INFO,
                             "ready"))
      `uvm_error("STATUS", "success(message) defaults are incorrect")

    default_status = rdma_status::type_id::create("default_status");
    if (!status_has_defaults(default_status,
                             RDMA_STATUS_STATE,
                             RDMA_SC_OK,
                             RDMA_SEVERITY_INFO,
                             "") ||
        !default_status.ok())
      `uvm_error("STATUS", "factory defaults are incorrect")

    direct_status = new("direct_status");
    if (!status_has_defaults(direct_status,
                             RDMA_STATUS_STATE,
                             RDMA_SC_OK,
                             RDMA_SEVERITY_INFO,
                             "") ||
        !direct_status.ok())
      `uvm_error("STATUS", "direct constructor defaults are incorrect")

    if (codes.size() != categories.size())
      `uvm_error("STATUS_MAP", "code/category table lengths differ")
    if (codes.size() != codes[0].num())
      `uvm_error("STATUS_MAP",
                 $sformatf("table covers %0d of %0d status codes",
                           codes.size(), codes[0].num()))

    foreach (codes[i]) begin
      if (rdma_status::category_for(codes[i]) != categories[i])
        `uvm_error("STATUS_MAP",
                   $sformatf("code %s mapped to %s instead of %s",
                             codes[i].name(),
                             rdma_status::category_for(codes[i]).name(),
                             categories[i].name()))
    end

    expect_status_category("RESOURCE_BUSY", RDMA_SC_RESOURCE_BUSY,
                           RDMA_STATUS_RESOURCE);
    expect_status_category("RECOVERY_REQUIRED", RDMA_SC_RECOVERY_REQUIRED,
                           RDMA_STATUS_STATE);

    message_status.hardware_code_valid = 1'b1;
    message_status.hardware_code = 32'hdead_beef;
    message_status.source_engine = RDMA_ENGINE_DMA;
    message_status.function_uid = 64'h0123_4567_89ab_cdef;
    message_status.generation = 32'd17;
    message_status.resource_id = 64'h1111_2222_3333_4444;
    message_status.command_id = 64'h5555_6666_7777_8888;
    message_status.wr_id = 64'h9999_aaaa_bbbb_cccc;
    message_status.retryable = 1'b1;
    status_text = message_status.convert2string();
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

    status = rdma_status::success();
    status.category = rdma_status_category_e'(4'hf);
    status.code = rdma_status_code_e'(5'h1f);
    status.source_engine = rdma_engine_kind_e'(4'hf);
    status_text = status.convert2string();
    if (status_text != {"rdma_status(category=UNKNOWN(15) ",
                        "code=UNKNOWN(31) ",
                        "hardware_code_valid=0 ",
                        "source_engine=UNKNOWN(15) ",
                        "function_uid=0x0000000000000000 ",
                        "generation=0 ",
                        "resource_id=0x0000000000000000 ",
                        "command_id=0x0000000000000000 ",
                        "wr_id=0x0000000000000000 ",
                        "severity=RDMA_SEVERITY_INFO ",
                        "retryable=0 message=\"\")"})
      `uvm_error("STATUS_STRING",
                 $sformatf("invalid enum fallback missing: %s", status_text))

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
