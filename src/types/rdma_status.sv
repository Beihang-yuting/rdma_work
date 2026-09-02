class rdma_status extends uvm_object;
  `uvm_object_utils(rdma_status)

  rdma_status_category_e category;
  rdma_status_code_e code;
  bit [31:0] hardware_code;
  bit hardware_code_valid;
  rdma_engine_kind_e source_engine;
  bit [63:0] function_uid;
  bit [31:0] generation;
  bit [63:0] resource_id;
  bit [63:0] command_id;
  bit [63:0] wr_id;
  rdma_severity_e severity;
  bit retryable;
  string message;

  function new(string name = "rdma_status");
    super.new(name);
    category = RDMA_STATUS_STATE;
    code = RDMA_SC_OK;
    hardware_code = '0;
    hardware_code_valid = 1'b0;
    source_engine = RDMA_ENGINE_NONE;
    function_uid = '0;
    generation = '0;
    resource_id = '0;
    command_id = '0;
    wr_id = '0;
    severity = RDMA_SEVERITY_INFO;
    retryable = 1'b0;
    message = "";
  endfunction

  static function automatic rdma_status make(
    rdma_status_code_e code,
    string message = ""
  );
    rdma_status status;

    status = rdma_status::type_id::create("rdma_status");
    status.category = category_for(code);
    status.code = code;
    status.hardware_code = '0;
    status.hardware_code_valid = 1'b0;
    status.source_engine = RDMA_ENGINE_NONE;
    status.function_uid = '0;
    status.generation = '0;
    status.resource_id = '0;
    status.command_id = '0;
    status.wr_id = '0;
    status.severity = (code == RDMA_SC_OK) ? RDMA_SEVERITY_INFO
                                           : RDMA_SEVERITY_ERROR;
    status.retryable = 1'b0;
    status.message = message;
    return status;
  endfunction

  static function automatic rdma_status success(string message = "");
    return make(RDMA_SC_OK, message);
  endfunction

  function bit ok();
    return code == RDMA_SC_OK;
  endfunction

  static function automatic rdma_status_category_e category_for(
    rdma_status_code_e code
  );
    case (code)
      RDMA_SC_OK:
        return RDMA_STATUS_STATE;
      RDMA_SC_INVALID_ARGUMENT,
      RDMA_SC_UNSUPPORTED_OPCODE:
        return RDMA_STATUS_CONFIGURATION;
      RDMA_SC_RESOURCE_EXHAUSTED,
      RDMA_SC_RESOURCE_BUSY:
        return RDMA_STATUS_RESOURCE;
      RDMA_SC_INVALID_STATE,
      RDMA_SC_STALE_GENERATION,
      RDMA_SC_RECOVERY_REQUIRED:
        return RDMA_STATUS_STATE;
      RDMA_SC_CODEC_ERROR:
        return RDMA_STATUS_CODEC;
      RDMA_SC_TIMEOUT:
        return RDMA_STATUS_TIMEOUT;
      RDMA_SC_PCIE_COMPLETION:
        return RDMA_STATUS_PCIE;
      RDMA_SC_DMA_TRANSLATION,
      RDMA_SC_DMA_PERMISSION:
        return RDMA_STATUS_DMA;
      RDMA_SC_QUEUE_FULL,
      RDMA_SC_QUEUE_EMPTY:
        return RDMA_STATUS_QUEUE;
      RDMA_SC_UNKNOWN_HW_ERROR:
        return RDMA_STATUS_HARDWARE;
      RDMA_SC_RESET_CANCELLED:
        return RDMA_STATUS_RESET;
      default:
        return RDMA_STATUS_HARDWARE;
    endcase
  endfunction

  virtual function string convert2string();
    string category_text;
    string code_text;
    string hardware_text;
    string source_engine_text;
    string severity_text;

    category_text = category.name();
    if (category_text == "")
      category_text = $sformatf("UNKNOWN(%0d)", category);

    code_text = code.name();
    if (code_text == "")
      code_text = $sformatf("UNKNOWN(%0d)", code);

    source_engine_text = source_engine.name();
    if (source_engine_text == "")
      source_engine_text = $sformatf("UNKNOWN(%0d)", source_engine);

    severity_text = severity.name();
    if (severity_text == "")
      severity_text = $sformatf("UNKNOWN(%0d)", severity);

    if (hardware_code_valid)
      hardware_text = $sformatf(" hardware_code=0x%08x", hardware_code);
    else
      hardware_text = "";

    return $sformatf(
      {"rdma_status(category=%s code=%s hardware_code_valid=%0b%s ",
       "source_engine=%s function_uid=0x%016x generation=%0d ",
       "resource_id=0x%016x command_id=0x%016x wr_id=0x%016x ",
       "severity=%s retryable=%0b message=\"%s\")"},
      category_text,
      code_text,
      hardware_code_valid,
      hardware_text,
      source_engine_text,
      function_uid,
      generation,
      resource_id,
      command_id,
      wr_id,
      severity_text,
      retryable,
      message
    );
  endfunction
endclass
