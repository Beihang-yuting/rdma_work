// 目录：模型层 model/rdma_cmq_execution_models.sv。
// 职责：定义 CMQ observed execution result、命令身份与 port adapter 使用的结果形状校验。
// 依赖：依赖 engine model、DMA context、hardware image 与提交证据枚举。
// 所有权与生命周期：值对象拥有显式 detached 子快照；外部 adapter capability 仍由 adapter 管理。

// 设计说明：completion phase 是结果证据，采用四态枚举保留 X/Z；
// rdma_cmq_completion_phase_valid 在比较前拒绝未知及 spare 编码。
typedef enum logic [2:0] {
  RDMA_CMQ_COMPLETION_NONE           = 3'd0,
  RDMA_CMQ_COMPLETION_PENDING        = 3'd1,
  RDMA_CMQ_COMPLETION_TERMINAL       = 3'd2,
  RDMA_CMQ_COMPLETION_TIMEOUT        = 3'd3,
  RDMA_CMQ_COMPLETION_RESET_CANCELLED = 3'd4,
  RDMA_CMQ_COMPLETION_DIAGNOSTIC_ONLY = 3'd5,
  RDMA_CMQ_COMPLETION_UNOBSERVED      = 3'd6
} rdma_cmq_completion_phase_e;

// 功能：直接构造一个完整 rdma_status，避免 recovery/snapshot 返回路径依赖 raw factory。
// 输入/输出及副作用：code 和 message 为输入；返回调用方拥有的新 status，无外部副作用。
// 失败/边界：未知 code 保守归类为 HARDWARE/ERROR；函数始终返回非空对象。
function automatic rdma_status rdma_cmq_direct_status(
  input rdma_status_code_e code,
  input string message = ""
);
  rdma_status status;

  status = new("rdma_cmq_status");
  case (code)
    RDMA_SC_OK:
      status.category = RDMA_STATUS_STATE;
    RDMA_SC_INVALID_ARGUMENT,
    RDMA_SC_UNSUPPORTED_OPCODE:
      status.category = RDMA_STATUS_CONFIGURATION;
    RDMA_SC_RESOURCE_EXHAUSTED,
    RDMA_SC_RESOURCE_BUSY:
      status.category = RDMA_STATUS_RESOURCE;
    RDMA_SC_INVALID_STATE,
    RDMA_SC_STALE_GENERATION,
    RDMA_SC_RECOVERY_REQUIRED:
      status.category = RDMA_STATUS_STATE;
    RDMA_SC_CODEC_ERROR:
      status.category = RDMA_STATUS_CODEC;
    RDMA_SC_TIMEOUT:
      status.category = RDMA_STATUS_TIMEOUT;
    RDMA_SC_PCIE_COMPLETION:
      status.category = RDMA_STATUS_PCIE;
    RDMA_SC_DMA_TRANSLATION,
    RDMA_SC_DMA_PERMISSION:
      status.category = RDMA_STATUS_DMA;
    RDMA_SC_QUEUE_FULL,
    RDMA_SC_QUEUE_EMPTY:
      status.category = RDMA_STATUS_QUEUE;
    RDMA_SC_RESET_CANCELLED:
      status.category = RDMA_STATUS_RESET;
    default:
      status.category = RDMA_STATUS_HARDWARE;
  endcase
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

// 设计说明：command identity 只投影不可变标量；它不保留 command/body/handle
// 引用，因此可作为结果中的稳定诊断身份，而不能充当资源 authority。
class rdma_cmq_command_identity extends uvm_object;
  `rdma_object_utils(rdma_cmq_command_identity)

  rdma_resource_kind_e function_kind;
  longint unsigned function_uid;
  int unsigned global_function_id;
  int unsigned generation;
  string profile_name;
  bit [31:0] opcode;
  string variant;

  // 功能：构造空的 command identity，所有标量置零且文本置空。
  // 输入/输出及副作用：name 传给 uvm_object；只初始化本对象字段。
  // 失败/边界：默认值不是有效命令身份，须由 capture_from 成功填充。
  function new(string name = "rdma_cmq_command_identity");
    super.new(name);
    function_kind = RDMA_RESOURCE_FUNCTION;
    function_uid = 0;
    global_function_id = 0;
    generation = 0;
    profile_name = "";
    opcode = '0;
    variant = "";
  endfunction

  // 功能：从 command 捕获 Function/opcode 的不可变标量身份，不保留任何源对象引用。
  // 输入/输出及副作用：command 为非拥有输入，failure_reason 为输出；成功时原子更新
  //   Function/opcode 标量，不调用 status factory，也不保留 command 的嵌套引用。
  // 失败/边界：command、Function 或 opcode key 为空，Function kind/generation 不合法，
  //   或 profile/variant 为空或含分隔符时返回 0、给出稳定原因并保留旧值。
  function bit capture_from(
    input rdma_cmq_command_desc command,
    output string failure_reason
  );
    failure_reason = "";
    if (command == null || command.function_h == null ||
        command.opcode_key == null) begin
      failure_reason = "CMQ command identity source is incomplete";
      return 1'b0;
    end
    if (command.function_h.kind != RDMA_RESOURCE_FUNCTION ||
        command.function_h.generation == 0) begin
      failure_reason = "CMQ command identity Function is invalid";
      return 1'b0;
    end
    if (command.opcode_key.profile_name.len() == 0 ||
        command.opcode_key.variant.len() == 0 ||
        rdma_cmq_string_has_separator(command.opcode_key.profile_name) ||
        rdma_cmq_string_has_separator(command.opcode_key.variant)) begin
      failure_reason = "CMQ command identity opcode key is invalid";
      return 1'b0;
    end

    function_kind = command.function_h.kind;
    function_uid = command.function_h.function_uid;
    global_function_id = command.function_h.object_id;
    generation = command.function_h.generation;
    profile_name = command.opcode_key.profile_name;
    opcode = command.opcode_key.opcode;
    variant = command.opcode_key.variant;
    return 1'b1;
  endfunction
endclass

// 设计说明：以下 pure-shape helper 只读取公开值字段，不调用会经过 UVM
// factory 的 validate()/clone()/copy()。nonfatal snapshot 由此可在 hostile
// factory 窗口内先完整拒绝坏图，再直接构造候选值。

// 设计说明：执行结果把 operation outcome 与 observation health 分成两个 owned
// status，避免证据捕获失败覆盖真实命令结果，并保留调用方判断恢复所需的 detached 值。
class rdma_cmq_execution_result extends uvm_object;
  `rdma_object_utils(rdma_cmq_execution_result)

  rdma_cmq_ticket ticket;
  rdma_cmq_completion completion;
  rdma_status status;
  rdma_status observation_status;
  rdma_cmq_command_identity command_identity;
  rdma_cmq_recovery_owner recovery_owner;
  rdma_dma_request_context dma_context;
  rdma_submission_effect_e submission_effect;
  rdma_submission_effect_e attempt_effect;
  rdma_cmq_completion_phase_e completion_phase;
  string batch_key;
  longint unsigned batch_id;
  longint unsigned attempt_id;
  bit recovery_required;

  // 功能：构造 fail-closed execution result，并为 operation/observation 各建独立状态值。
  // 输入/输出及副作用：name 传给 uvm_object；直接构造两个 INVALID_STATE status。
  // 失败/边界：默认对象不代表完成或已观测操作；所有证据引用为空且 recovery 保守置位。
  function new(string name = "rdma_cmq_execution_result");
    super.new(name);
    ticket = null;
    completion = null;
    status = rdma_cmq_direct_status(
      RDMA_SC_INVALID_STATE, "CMQ execution result is uninitialized"
    );
    observation_status = rdma_cmq_direct_status(
      RDMA_SC_INVALID_STATE, "CMQ execution observation is uninitialized"
    );
    command_identity = null;
    recovery_owner = null;
    dma_context = null;
    submission_effect = RDMA_SUBMIT_EFFECT_UNOBSERVED;
    attempt_effect = RDMA_SUBMIT_EFFECT_UNOBSERVED;
    completion_phase = RDMA_CMQ_COMPLETION_UNOBSERVED;
    batch_key = "";
    batch_id = 0;
    attempt_id = 0;
    recovery_required = 1'b1;
  endfunction
endclass
