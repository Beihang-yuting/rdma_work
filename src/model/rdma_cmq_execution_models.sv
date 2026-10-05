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

// 功能：按唯一 UVM wrapper 判断 handle 是否为可复制的 base/Function 注册值类型。
// 输入/输出及副作用：source 为只读输入；返回类型是否受支持，不修改对象。
// 失败/边界：null、wrapper 不匹配的注册子类以及把非 Function kind 放入
//   Function 类型时返回 0；不信任可覆盖的 get_type_name 字符串。
function automatic bit rdma_cmq_direct_handle_type_supported(
  input rdma_handle source
);
  uvm_object_wrapper source_type;

  if (source == null)
    return 1'b0;
  source_type = source.get_object_type();
  if (source_type == rdma_function_handle::get_type())
    return source.kind == RDMA_RESOURCE_FUNCTION;
  return source_type == rdma_handle::get_type();
endfunction

// 功能：检查 Function identity 的完整 route、UID 与 generation 形状。
// 输入/输出及副作用：identity 为只读输入；返回确定 bit，无对象分配或状态写回。
// 失败/边界：null、零 UID/generation 或非法 PF/VF route 返回 0。
function automatic bit rdma_cmq_identity_shape_valid(
  input rdma_function_identity identity
);
  return identity != null && identity.function_uid != 0 &&
         identity.generation != 0 &&
         rdma_function_key_route_valid(identity.key);
endfunction

// 功能：检查 opcode key 的 profile/variant 文本是否满足既有 CMQ 值约束。
// 输入/输出及副作用：key 为只读输入；返回 bit，不调用 factory-backed validate。
// 失败/边界：null、空文本或任一文本含竖线分隔符时返回 0。
function automatic bit rdma_cmq_opcode_key_shape_valid(
  input rdma_cmq_opcode_key key
);
  return key != null && key.profile_name.len() != 0 &&
         key.variant.len() != 0 &&
         !rdma_cmq_string_has_separator(key.profile_name) &&
         !rdma_cmq_string_has_separator(key.variant);
endfunction

// 功能：不经 factory 检查 ticket 的句柄、位置、deadline 与 opcode 值关系。
// 输入/输出及副作用：ticket 为只读输入；返回形状是否完整，不保留其引用。
// 失败/边界：null/wrapper 不匹配的注册子类、零 ID/deadline、坏句柄或
//   SQ 序列不一致返回 0。
function automatic bit rdma_cmq_ticket_shape_valid(
  input rdma_cmq_ticket ticket
);
  if (ticket == null ||
      ticket.get_object_type() != rdma_cmq_ticket::get_type() ||
      ticket.command_id == 0 || ticket.absolute_deadline == 0 ||
      ticket.function_h == null || ticket.cmq_h == null ||
      !rdma_cmq_direct_handle_type_supported(ticket.function_h) ||
      ticket.function_h.get_object_type() != rdma_function_handle::get_type() ||
      !rdma_cmq_direct_handle_type_supported(ticket.cmq_h) ||
      ticket.function_h.kind != RDMA_RESOURCE_FUNCTION ||
      ticket.function_h.generation == 0 ||
      ticket.cmq_h.kind != RDMA_RESOURCE_CMQ ||
      ticket.cmq_h.function_uid != ticket.function_h.function_uid ||
      ticket.cmq_h.generation != ticket.function_h.generation ||
      !rdma_cmq_opcode_key_shape_valid(ticket.opcode_key) ||
      ticket.sq_index >= 32)
    return 1'b0;
  return ticket.sq_index == (ticket.slot_sequence % 32) &&
         ticket.sq_wrap == ((ticket.slot_sequence / 32) % 2);
endfunction

// 功能：检查通用 hardware image 的 V1 可序列化元数据与 byte length。
// 输入/输出及副作用：image 为只读输入；返回 bit，不修改 bytes/summary。
// 失败/边界：null、wrapper 不匹配的注册子类、长度不符、零
//   alignment/version/generation 或未支持 endian/image/target 编码时返回 0。
function automatic bit rdma_cmq_image_shape_valid(input rdma_hw_image image);
  if (image == null ||
      image.get_object_type() != rdma_hw_image::get_type() ||
      image.length != image.bytes.size() || image.alignment == 0 ||
      image.hardware_version == 0 || image.function_generation == 0)
    return 1'b0;
  if (!(image.endian inside {RDMA_ENDIAN_LITTLE, RDMA_ENDIAN_BIG}) ||
      !(image.image_kind inside {
        RDMA_IMAGE_QPC, RDMA_IMAGE_CQC, RDMA_IMAGE_MRT,
        RDMA_IMAGE_SRQC, RDMA_IMAGE_CEQC, RDMA_IMAGE_AEQC,
        RDMA_IMAGE_CMQ_SQE, RDMA_IMAGE_CMQ_CQE, RDMA_IMAGE_SQE,
        RDMA_IMAGE_RQE, RDMA_IMAGE_CQE, RDMA_IMAGE_CEQE,
        RDMA_IMAGE_AEQE, RDMA_IMAGE_DOORBELL
      }) || !(image.write_target_kind inside {
        RDMA_HW_TARGET_NONE, RDMA_HW_TARGET_BACKING,
        RDMA_HW_TARGET_HMC_FVM, RDMA_HW_TARGET_BAR
      }))
    return 1'b0;
  return 1'b1;
endfunction

// 功能：不经 status/factory 校验具体 frozen owner 或精确 legacy sentinel。
// 输入/输出及副作用：owner 为只读输入；返回稳定 shape 结果，不冻结或改写。
// 失败/边界：未知 workflow/mask、非法矩阵、坏 identity/attempt 或 wrapper
//   不匹配的注册子类返回 0。
function automatic bit rdma_cmq_frozen_owner_shape_valid(
  input rdma_cmq_recovery_owner owner
);
  if (owner == null ||
      owner.get_object_type() != rdma_cmq_recovery_owner::get_type())
    return 1'b0;
  if (owner.is_legacy_unmigrated())
    return 1'b1;
  if ($isunknown(owner.workflow) || $isunknown(owner.allowed_actions) ||
      !(owner.workflow inside {RDMA_CMQ_WORKFLOW_MR,
                               RDMA_CMQ_WORKFLOW_QUEUE,
                               RDMA_CMQ_WORKFLOW_QP}) ||
      owner.resource_h == null ||
      !rdma_cmq_direct_handle_type_supported(owner.resource_h) ||
      owner.resource_h.get_object_type() != rdma_handle::get_type() ||
      owner.resource_h.function_uid == 0 ||
      owner.resource_h.object_id == 0 ||
      owner.resource_h.generation == 0 || owner.transaction_id == 0 ||
      owner.allowed_actions[0] !== 1'b0 ||
      (owner.allowed_actions & 3'b110) == 3'b000 || !owner.frozen ||
      owner.admission_attempt_id == 0 ||
      !rdma_cmq_identity_shape_valid(owner.function_identity) ||
      owner.resource_h.function_uid != owner.function_identity.function_uid ||
      owner.resource_h.generation != owner.function_identity.generation)
    return 1'b0;
  case (owner.workflow)
    RDMA_CMQ_WORKFLOW_MR:
      return owner.resource_h.kind == RDMA_RESOURCE_MR;
    RDMA_CMQ_WORKFLOW_QUEUE:
      return owner.resource_h.kind inside {RDMA_RESOURCE_CQ,
                                           RDMA_RESOURCE_SRQ,
                                           RDMA_RESOURCE_CEQ,
                                           RDMA_RESOURCE_AEQ};
    RDMA_CMQ_WORKFLOW_QP:
      return owner.resource_h.kind == RDMA_RESOURCE_QP;
    default:
      return 1'b0;
  endcase
endfunction

// 功能：检查 required status 是否为精确 rdma_status 注册值且枚举均在冻结范围内。
// 输入/输出及副作用：source 为只读输入；返回 shape bit，不缓存、复制或修改对象。
// 失败/边界：null、wrapper 不匹配的注册子类、category X/Z 或 11..15、code X/Z
//   或 17..31、source_engine X/Z 或 12..15 时返回 0。
function automatic bit rdma_cmq_status_shape_valid(input rdma_status source);
  if (source == null ||
      source.get_object_type() != rdma_status::get_type())
    return 1'b0;
  if ($isunknown(source.category) || $isunknown(source.code) ||
      $isunknown(source.source_engine))
    return 1'b0;
  return source.category <= RDMA_STATUS_RESET &&
         source.code <= RDMA_SC_RECOVERY_REQUIRED &&
         source.source_engine <= RDMA_ENGINE_RESET;
endfunction

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

// 功能：判断 completion phase 是否为 NONE 到 UNOBSERVED 的七个冻结编码。
// 输入/输出及副作用：phase 为只读输入；返回 bit，无外部副作用。
// 失败/边界：含 X/Z 或 spare 3'b111 时返回 0，NONE 与 UNOBSERVED 不混同。
function automatic bit rdma_cmq_completion_phase_valid(
  input rdma_cmq_completion_phase_e phase
);
  if ($isunknown(phase))
    return 1'b0;
  return phase inside {
    RDMA_CMQ_COMPLETION_NONE,
    RDMA_CMQ_COMPLETION_PENDING,
    RDMA_CMQ_COMPLETION_TERMINAL,
    RDMA_CMQ_COMPLETION_TIMEOUT,
    RDMA_CMQ_COMPLETION_RESET_CANCELLED,
    RDMA_CMQ_COMPLETION_DIAGNOSTIC_ONLY,
    RDMA_CMQ_COMPLETION_UNOBSERVED
  };
endfunction

// 功能：判断 submission effect 是否为 Task 8 冻结的七个编码之一。
// 输入/输出及副作用：effect 为只读输入；返回 bit，不折叠或改写证据。
// 失败/边界：含 X/Z 或 spare 3'b111 时返回 0。
function automatic bit rdma_cmq_submission_effect_valid(
  input rdma_submission_effect_e effect
);
  if ($isunknown(effect))
    return 1'b0;
  return effect inside {
    RDMA_SUBMIT_EFFECT_UNOBSERVED,
    RDMA_SUBMIT_EFFECT_PRE_SUBMIT_REJECTED,
    RDMA_SUBMIT_EFFECT_HOST_MEMORY_MAYBE_VISIBLE,
    RDMA_SUBMIT_EFFECT_HOST_MEMORY_WRITTEN,
    RDMA_SUBMIT_EFFECT_HOST_MEMORY_ORDERED,
    RDMA_SUBMIT_EFFECT_MMIO_MAYBE_VISIBLE,
    RDMA_SUBMIT_EFFECT_MMIO_VISIBLE
  };
endfunction

// 功能：判断 effect 是否属于可按证据 high-water 排序的五个 Host/MMIO 值。
// 输入/输出及副作用：effect 为只读输入；返回 bit，不读取 journal 状态。
// 失败/边界：UNOBSERVED、PRE_SUBMIT_REJECTED、X/Z 与 spare 均返回 0。
function automatic bit rdma_cmq_concrete_submission_effect(
  input rdma_submission_effect_e effect
);
  if ($isunknown(effect))
    return 1'b0;
  return effect inside {
    RDMA_SUBMIT_EFFECT_HOST_MEMORY_MAYBE_VISIBLE,
    RDMA_SUBMIT_EFFECT_HOST_MEMORY_WRITTEN,
    RDMA_SUBMIT_EFFECT_HOST_MEMORY_ORDERED,
    RDMA_SUBMIT_EFFECT_MMIO_MAYBE_VISIBLE,
    RDMA_SUBMIT_EFFECT_MMIO_VISIBLE
  };
endfunction

// 功能：判断 observed result 是否完全没有提交身份图。
// 输入/输出及副作用：value 只读；返回 bit。
// 失败/边界：null 返回 0；ticket/completion/identity/owner/DMA 任一存在或 batch/attempt 非零即非空。
function automatic bit rdma_cmq_result_identity_graph_empty(
  input rdma_cmq_execution_result value
);
  if (value == null)
    return 1'b0;
  return value.ticket == null && value.completion == null &&
         value.command_identity == null && value.recovery_owner == null &&
         value.dma_context == null && value.batch_key.len() == 0 &&
         value.batch_id == 0 && value.attempt_id == 0;
endfunction

// 功能：判断 observed result 能否证明命令在提交前就被拒绝（确定未提交）。
// 输入/输出及副作用：value 只读；返回 bit，供 caller 做歧义分类。
// 失败/边界：status 为 OK 或 shape 非法、observation 失败、任一 effect 非 PRE_SUBMIT_REJECTED、
//   completion phase 非 NONE、要求恢复或身份图非空时返回 0。
function automatic bit rdma_cmq_result_no_submit_proven(
  input rdma_cmq_execution_result value
);
  return value != null && value.status != null &&
         value.observation_status != null &&
         rdma_cmq_status_shape_valid(value.status) &&
         rdma_cmq_status_shape_valid(value.observation_status) &&
         value.status.code != RDMA_SC_OK &&
         value.observation_status.code == RDMA_SC_OK &&
         value.submission_effect == RDMA_SUBMIT_EFFECT_PRE_SUBMIT_REJECTED &&
         value.attempt_effect == RDMA_SUBMIT_EFFECT_PRE_SUBMIT_REJECTED &&
         value.completion_phase == RDMA_CMQ_COMPLETION_NONE &&
         value.recovery_required == 1'b0 &&
         rdma_cmq_result_identity_graph_empty(value);
endfunction
