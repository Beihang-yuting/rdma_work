// 目录：公共类型层 types/rdma_status.sv。
// 职责：实现 rdma_status 在本层的职责和对外接口。
// 依赖：依赖本层公共 types/model/adapter 契约及其上游快照。
// 所有权与生命周期：对象只拥有显式创建的值快照；外部资源保存非拥有引用，生命周期由调用方管理。

// 中文说明：rdma_status.sv 属于基础类型层，集中定义 RDMA 枚举、地址、身份和状态契约。
// 阅读提示：先看公开类型和接口，再看实现细节；失败路径应保持状态与资源所有权可追踪。

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

  // 功能：构造当前对象并初始化其字段、集合和 UVM 名称；不接管传入句柄的生命周期。
  // 输入/输出及副作用：name 仅用于 UVM 对象命名；内部字段被初始化为安全默认值，传入句柄不转移所有权。
  //   返回新对象实例；构造失败由 UVM 工厂或调用方处理。
  // 失败/边界：不创建外部资源；name 为空时仍允许构造，但所有字段必须保持可配置的初始值。
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

  // 中文：状态进入事务 evidence 后必须是 detached snapshot，保留错误码、
  // 硬件上下文与诊断文本，避免 clone 后只剩默认 OK 状态。
  // 功能：从源对象复制可变字段并生成独立值快照；源对象保持不变，类型不匹配时报告复制错误。
  // 输入/输出及副作用：source/rhs 是源对象；返回或写入独立副本，不修改源对象。
  //   source/rhs 为空或类型不匹配时返回空值或触发既定复制错误。
  // 失败/边界：空源对象不应解引用；类型不匹配必须拒绝复制或按既定 UVM 规则报告 fatal。
  virtual function void do_copy(uvm_object rhs);
    rdma_status source;
    super.do_copy(rhs);
    if (!$cast(source, rhs))
      `uvm_fatal("RDMA_COPY_TYPE", "rdma_status copy type mismatch")
    category = source.category;
    code = source.code;
    hardware_code = source.hardware_code;
    hardware_code_valid = source.hardware_code_valid;
    source_engine = source.source_engine;
    function_uid = source.function_uid;
    generation = source.generation;
    resource_id = source.resource_id;
    command_id = source.command_id;
    wr_id = source.wr_id;
    severity = source.severity;
    retryable = source.retryable;
    message = source.message;
  endfunction

  // 功能：处理 make：依据其参数完成所属层的具体协议动作，并保持返回状态、游标和资源所有权一致。
  // 输入/输出及副作用：参数 code, message 用于执行 make；返回值或 output/inout 交付处理结果，必要时更新本对象状态。
  //   调用方不获得内部集合或外部依赖的所有权。
  // 失败/边界：make 只接受其签名声明的输入；缺少必要字段时返回错误，成功路径不得隐式修改无关资源。
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

  // 功能：把输入错误或注入故障转换成统一的 rdma_status，供上层沿原事务路径处理。
  // 输入/输出及副作用：输入为错误消息、错误码或故障证据；返回统一 rdma_status，不推进事务游标。
  //   空消息仍需保留错误类别；未知错误码不得被静默转换为成功。
  // 失败/边界：错误路径不能返回成功状态；消息和错误码缺失时仍须保留可诊断类别。
  static function automatic rdma_status success(string message = "");
    return make(RDMA_SC_OK, message);
  endfunction

  // 功能：将当前对象的类型、状态或关键标识转换为调用方可消费的值，不产生外部副作用。
  // 输入/输出及副作用：输入为当前对象状态；返回字符串、枚举或只读派生值，不修改对象。
  //   对象未配置时返回可识别的 UNKNOWN/UNCONFIGURED 表示。
  // 失败/边界：未配置或字段无效时返回明确的 UNKNOWN 表示，不读取未初始化句柄。
  function bit ok();
    return code == RDMA_SC_OK;
  endfunction

  // 功能：处理 category_for：依据其参数完成所属层的具体协议动作，并保持返回状态、游标和资源所有权一致。
  // 输入/输出及副作用：参数 code 用于执行 category_for；返回值或 output/inout 交付处理结果，必要时更新本对象状态。
  //   调用方不获得内部集合或外部依赖的所有权。
  // 失败/边界：category_for 只接受其签名声明的输入；缺少必要字段时返回错误，成功路径不得隐式修改无关资源。
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

  // 功能：将当前对象的类型、状态或关键标识转换为调用方可消费的值，不产生外部副作用。
  // 输入/输出及副作用：输入为当前对象状态；返回字符串、枚举或只读派生值，不修改对象。
  //   对象未配置时返回可识别的 UNKNOWN/UNCONFIGURED 表示。
  // 失败/边界：未配置或字段无效时返回明确的 UNKNOWN 表示，不读取未初始化句柄。
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
