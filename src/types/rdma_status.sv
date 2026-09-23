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

  // 功能：构造 rdma_status，调用 super.new 建立 UVM 对象，并把构造体直接写入的默认值设为：category=RDMA_STATUS_STATE；code=RDMA_SC_OK；hardware_code='0；hardware_code_valid=1'b0；source_engine=RDMA_ENGINE_NONE；function_uid='0；generation='0；resource_id='0；其余字段按实现默认值初始化。
  // 输入/输出及副作用：name（输入）；new 只写入构造体列出的默认字段并返回 void，外部依赖与资源所有权仍由上层管理。
  // 失败/边界：rdma_status 构造只建立本地初始状态，不接管外部 Host-memory、PCIe 或 manager；未完成后续 configure/build/activate 时，业务入口必须返回 INVALID_STATE。
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
  // 功能：将 rhs 中 rdma_status 的值字段复制到当前对象，建立与源对象隔离的快照。
  // 输入/输出及副作用：rhs（输入）；rhs 是源对象；当前对象字段会被覆盖，嵌套句柄按实现执行 clone 或保持非拥有引用，源对象不被修改。
  // 失败/边界：do_copy 在源对象为空、clone/cast 失败或类型不匹配时触发 UVM fatal（rdma_status copy type mismatch），不保留部分有效快照。
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

  // 功能：在 rdma_status 中，make 创建新的 rdma_status 值并填充 category、code、severity 和诊断消息，不修改调用方对象。
  // 输入/输出及副作用：code（输入）、message（输入）；make 读取 code、message 并使用字段 status、status.category、status.code、status.hardware_code、status.hardware_code_valid、status.source_engine、status.function_uid、status.generation；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：make 下游操作失败时原样传播其 status/result，不伪造成功；该路径不隐式重试，也不转移未声明资源。
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

  // 功能：在不经过 UVM factory 的情况下直接构造完整 rdma_status，供
  //       外部 delegate 返回 null 或 factory 被 hostile override 时的边界降级使用。
  // 输入/输出及副作用：code、message 为输入；函数直接 new 一个独立 status，
  //       填充 category、severity、硬件/身份诊断默认值并返回，不修改调用方对象。
  // 失败/边界：该函数故意绕过 type_id::create，因此始终返回非空对象；未知 code
  //       由 category_for 保守归类，调用方仍须按 code 处理失败语义。
  static function automatic rdma_status make_direct(
    rdma_status_code_e code,
    string message = ""
  );
    rdma_status status;

    status = new("rdma_status_direct");
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

  // 功能：在 rdma_status 中，success 把错误消息、硬件码或注入故障封装为统一 rdma_status，保留原事务的诊断证据。
  // 输入/输出及副作用：message（输入）；success 读取 message 并使用输入参数和固定枚举/常量；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：success 的结果直接由 return make(RDMA_SC_OK, message) 计算；输入不满足表达式条件时沿函数体的保守分支返回，不修改已发布账本。
  static function automatic rdma_status success(string message = "");
    return make(RDMA_SC_OK, message);
  endfunction

  // 功能：ok 按函数体读取当前字段并生成 bit 结果，供调用方进行诊断或分支决策；不修改外部资源。
  // 输入/输出及副作用：无显式参数；ok 读取固定返回值或局部计算结果，不使用对象成员字段；函数返回 bit，不取得调用方资源所有权。
  // 失败/边界：枚举未定义或对象未配置时返回 UNKNOWN/UNCONFIGURED 表示，同时保留数值上下文。
  function bit ok();
    return code == RDMA_SC_OK;
  endfunction

  // 功能：在 rdma_status 中，category_for 把输入枚举或资源类型映射成对应的状态类别、执行引擎、opcode 或生命周期策略。
  // 输入/输出及副作用：code（输入）；category_for 读取 code 并使用输入参数和固定枚举/常量；函数返回 rdma_status_category_e，不取得调用方资源所有权。
  // 失败/边界：category_for 的结果直接由 return RDMA_STATUS_STATE 计算；输入不满足表达式条件时沿函数体的保守分支返回，不修改已发布账本。
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

  // 功能：convert2string 把 当前对象字段 与当前对象的身份/状态字段编码为稳定文本，供日志、查找或恢复索引使用。
  // 输入/输出及副作用：无显式参数；无显式输入；返回 string，只读取对象字段，不修改模型或资源账本。
  // 失败/边界：枚举未定义或对象未配置时返回 UNKNOWN/UNCONFIGURED 表示，同时保留数值上下文。
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
