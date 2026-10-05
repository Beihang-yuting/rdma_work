// 目录/层次：公共类型层 types/rdma_status.sv。
// 职责：定义完整诊断值、错误分类、值复制与无分配原位初始化；不承载业务状态机。
// 依赖：rdma_status/engine/severity 枚举和 UVM；不反向依赖 core、adapter 或 runtime。
// 所有权与生命周期：对象仅含标量和 string，由调用方持有；不拥有外部资源或 authority。

// 设计说明：make 走 typed factory，make_direct 直接构造；set/copy_fields_noalloc 不分配、
// 不调用虚拟 hook，可用于提交后的预建 slot。null/错型 fallback、枚举准入与 MMIO evidence
// 由各业务层负责，不能由诊断值推导提交结果。

class rdma_status extends uvm_object;
  `rdma_object_utils(rdma_status)

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

  // 功能：建立默认 OK/STATE/INFO 诊断，硬件码、身份字段与 retryable 清零，message 为空。
  // 输入/输出及副作用：name 透传 UVM 基类；只初始化本对象。
  // 失败/边界：不经 factory；默认 OK 不代表事务已提交或 authority 有效。
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

  // 设计说明：状态进入事务 evidence 后必须是 detached snapshot，clone 后须保留错误码、硬件上下文与文本。
  // 功能：UVM copy hook，先调基类复制，再逐字段复制 rhs 的完整诊断。
  // 输入/输出及副作用：rhs 为源对象；覆盖当前对象的标量/string 字段。
  // 失败/边界：错型触发 RDMA_COPY_TYPE fatal；传 null 不在契约内。需要 null 容忍/noalloc 时用
  //   copy_fields_noalloc。
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

  // 功能：逐字段复制完整诊断，供预建结果槽与 detached 快照共用。
  // 输入/输出及副作用：source、destination 为输入；成功覆盖 destination 全部诊断字段并返回 1。
  // 失败/边界：任一为空返回 0 且不写 destination；自复制值不变；不规范化 category/code，
  //   不调用虚拟 copy/clone。
  static function automatic bit copy_fields_noalloc(
    rdma_status source,
    rdma_status destination
  );
    if (source == null || destination == null)
      return 1'b0;
    destination.category = source.category;
    destination.code = source.code;
    destination.hardware_code = source.hardware_code;
    destination.hardware_code_valid = source.hardware_code_valid;
    destination.source_engine = source.source_engine;
    destination.function_uid = source.function_uid;
    destination.generation = source.generation;
    destination.resource_id = source.resource_id;
    destination.command_id = source.command_id;
    destination.wr_id = source.wr_id;
    destination.severity = source.severity;
    destination.retryable = source.retryable;
    destination.message = source.message;
    return 1'b1;
  endfunction

  // 功能：以 code/message 初始化 destination，并清除上一条诊断的硬件/身份字段。
  // 输入/输出及副作用：destination、code、message 为输入；成功覆盖全部诊断字段并返回 1；
  //   不创建对象，不改变 destination 的身份或名称。
  // 失败/边界：destination 为空返回 0；category 由 category_for 归类，仅 OK 用 INFO severity，
  //   其余为 ERROR。
  static function automatic bit set_fields_noalloc(
    rdma_status destination,
    rdma_status_code_e code,
    string message = ""
  );
    if (destination == null)
      return 1'b0;
    destination.category = rdma_status::category_for(code);
    destination.code = code;
    destination.hardware_code = '0;
    destination.hardware_code_valid = 1'b0;
    destination.source_engine = RDMA_ENGINE_NONE;
    destination.function_uid = '0;
    destination.generation = '0;
    destination.resource_id = '0;
    destination.command_id = '0;
    destination.wr_id = '0;
    destination.severity = code == RDMA_SC_OK ? RDMA_SEVERITY_INFO :
                                                RDMA_SEVERITY_ERROR;
    destination.retryable = 1'b0;
    destination.message = message;
    return 1'b1;
  endfunction

  // 功能：经 typed factory 创建 rdma_status，并覆盖 factory 预填的全部值字段。
  // 输入/输出及副作用：code/message 决定分类、严重性与消息，其余上下文清零；保留 factory 回调。
  // 失败/边界：沿用 typed-create 的错型 fatal；要求 factory 返回非空，无 null 降级。
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

  // 功能：绕过 UVM factory 直接构造完整 rdma_status，用于 delegate 返回 null 或 factory
  //   被 override 时的降级。
  // 输入/输出及副作用：code、message 为输入；new 一个独立 status 并经 set_fields_noalloc 填充后返回。
  // 失败/边界：始终返回非空对象；未知 code 由 category_for 保守归类。
  static function automatic rdma_status make_direct(
    rdma_status_code_e code,
    string message = ""
  );
    rdma_status status;

    status = new("rdma_status_direct");
    void'(set_fields_noalloc(status, code, message));
    return status;
  endfunction

  // 功能：source 非 null 时原样返回，否则经 make 返回 code/message 的新状态。
  // 输入/输出及副作用：source 只读不复制；仅 null 时分配。
  // 失败/边界：不判断 source 是否 OK，调用方仍需检查 ok()。
  static function automatic rdma_status nonnull(
    rdma_status source,
    string message,
    rdma_status_code_e code = RDMA_SC_INVALID_STATE
  );
    if (source != null)
      return source;
    return make(code, message);
  endfunction

  // 功能：创建 code=OK 的完整默认诊断。
  // 输入/输出及副作用：message 透传 make；返回 factory 状态对象。
  // 失败/边界：继承 make 的 factory 前提，不是无分配入口。
  static function automatic rdma_status success(string message = "");
    return make(RDMA_SC_OK, message);
  endfunction

  // 功能：仅按 code 是否为 RDMA_SC_OK 判断成功。
  // 输入/输出及副作用：读取 code，返回 bit，无副作用。
  // 失败/边界：非 OK 编码返回 0；调用方须先排除 null 对象。
  function bit ok();
    return code == RDMA_SC_OK;
  endfunction

  // 功能：把错误码映射为配置、资源、状态、codec、超时、PCIe、DMA、队列、硬件或复位类别。
  // 输入/输出及副作用：只读 code，返回对应 category。
  // 失败/边界：OK 归 STATE；未列出的编码保守归 HARDWARE，不改写为 OK。
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

  // 功能：输出分类、错误码、硬件码、引擎、身份、严重性、重试位与消息的诊断文本。
  // 输入/输出及副作用：读取本对象字段，返回 string，无副作用。
  // 失败/边界：枚举无名称时输出 UNKNOWN(数值)；hardware_code_valid=0 时省略硬件码文本。
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
