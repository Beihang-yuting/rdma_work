// 目录：模型层 model/rdma_cmq_execution_models.sv。
// 职责：定义 CMQ observed execution、journal、reset proof 与恢复请求值，并提供稳定 V1 canonical digest。
// 依赖：依赖 engine model、Function binding、DMA context/mapping、hardware image 与提交证据枚举。
// 所有权与生命周期：值对象拥有显式 detached 子快照；外部 adapter capability 仍由 adapter 管理，公开 digest 不取得其权限。

// 设计说明：completion phase 与 journal state 都是恢复证据，采用四态枚举保留
// X/Z；所有 reducer/classifier 在比较或索引前先拒绝未知及 spare 编码。
typedef enum logic [2:0] {
  RDMA_CMQ_COMPLETION_NONE           = 3'd0,
  RDMA_CMQ_COMPLETION_PENDING        = 3'd1,
  RDMA_CMQ_COMPLETION_TERMINAL       = 3'd2,
  RDMA_CMQ_COMPLETION_TIMEOUT        = 3'd3,
  RDMA_CMQ_COMPLETION_RESET_CANCELLED = 3'd4,
  RDMA_CMQ_COMPLETION_DIAGNOSTIC_ONLY = 3'd5,
  RDMA_CMQ_COMPLETION_UNOBSERVED      = 3'd6
} rdma_cmq_completion_phase_e;

typedef enum logic [3:0] {
  RDMA_CMQ_SUBMISSION_STAGED                     = 4'd0,
  RDMA_CMQ_SUBMISSION_PENDING_EFFECT             = 4'd1,
  RDMA_CMQ_SUBMISSION_HOST_VISIBLE_NOT_PUBLISHED = 4'd2,
  RDMA_CMQ_SUBMISSION_PUBLISH_AMBIGUOUS          = 4'd3,
  RDMA_CMQ_SUBMISSION_PUBLISH_CONFIRMED          = 4'd4,
  RDMA_CMQ_SUBMISSION_COMPLETED                  = 4'd5,
  RDMA_CMQ_SUBMISSION_TIMED_OUT_QUARANTINED      = 4'd6,
  RDMA_CMQ_SUBMISSION_LATE_COMPLETED             = 4'd7,
  RDMA_CMQ_SUBMISSION_RESET_QUARANTINED          = 4'd8
} rdma_cmq_submission_state_e;

typedef bit [255:0] rdma_cmq_journal_digest_t;
typedef class rdma_cmq_reset_isolation_proof;

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
  `uvm_object_utils(rdma_cmq_command_identity)

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
  // 输入/输出及副作用：command 为输入，failure_reason 为输出；成功时原子更新当前字段。
  // 失败/边界：command、Function 或 opcode key 为空/非法时返回 0、给出稳定原因并保留旧值。
  function bit capture_from(
    input rdma_cmq_command_desc command,
    output string failure_reason
  );
    rdma_status status;

    failure_reason = "";
    if (command == null || command.function_h == null ||
        command.opcode_key == null) begin
      failure_reason = "CMQ command identity source is incomplete";
      return 1'b0;
    end
    status = rdma_cmq_function_status(
      command.function_h, "CMQ command identity"
    );
    if (status == null || !status.ok()) begin
      failure_reason = "CMQ command identity Function is invalid";
      return 1'b0;
    end
    status = command.opcode_key.validate();
    if (status == null || !status.ok()) begin
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

// 功能：直接复制一个 handle 值并保留 exact base 或 Function runtime subtype。
// 输入/输出及副作用：source/allow_null 为输入，snapshot 为输出；成功发布新对象。
// 失败/边界：输出先清空；null 仅在 allow_null 时成功，未知 subtype 原子失败。
function automatic bit rdma_cmq_try_snapshot_handle_direct(
  input rdma_handle source,
  input bit allow_null,
  output rdma_handle snapshot
);
  rdma_function_handle function_snapshot;
  rdma_handle candidate;

  snapshot = null;
  if (source == null)
    return allow_null;
  if (!rdma_cmq_direct_handle_type_supported(source))
    return 1'b0;

  if (source.get_object_type() == rdma_function_handle::get_type()) begin
    function_snapshot = new("direct_function_handle_snapshot");
    candidate = function_snapshot;
  end
  else begin
    candidate = new("direct_handle_snapshot");
  end
  candidate.kind = source.kind;
  candidate.function_uid = source.function_uid;
  candidate.object_id = source.object_id;
  candidate.generation = source.generation;
  snapshot = candidate;
  return 1'b1;
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

// 功能：直接复制 Function identity 的全部稳定字段，形成 detached 值。
// 输入/输出及副作用：source 为输入，snapshot 为输出；成功时发布新 identity。
// 失败/边界：输出先清空；源 identity 形状非法时不发布部分结果。
function automatic bit rdma_cmq_try_snapshot_identity_direct(
  input rdma_function_identity source,
  output rdma_function_identity snapshot
);
  rdma_function_identity candidate;

  snapshot = null;
  if (!rdma_cmq_identity_shape_valid(source))
    return 1'b0;
  candidate = new("direct_function_identity_snapshot");
  candidate.key = source.key;
  candidate.global_function_id = source.global_function_id;
  candidate.function_uid = source.function_uid;
  candidate.generation = source.generation;
  candidate.reset_epoch = source.reset_epoch;
  snapshot = candidate;
  return 1'b1;
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

// 功能：直接复制 CMQ opcode key 的 profile、opcode 与 variant 值。
// 输入/输出及副作用：source 为输入，snapshot 为输出；成功发布 detached key。
// 失败/边界：输出先清空；非法 key 或 wrapper 不匹配的注册子类原子失败。
function automatic bit rdma_cmq_try_snapshot_opcode_key_direct(
  input rdma_cmq_opcode_key source,
  output rdma_cmq_opcode_key snapshot
);
  rdma_cmq_opcode_key candidate;

  snapshot = null;
  if (!rdma_cmq_opcode_key_shape_valid(source) ||
      source.get_object_type() != rdma_cmq_opcode_key::get_type())
    return 1'b0;
  candidate = new("direct_cmq_opcode_key_snapshot");
  candidate.profile_name = source.profile_name;
  candidate.opcode = source.opcode;
  candidate.variant = source.variant;
  snapshot = candidate;
  return 1'b1;
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

// 功能：直接复制 hardware image 的元数据、byte queue 与 field summary。
// 输入/输出及副作用：source/allow_null 为输入，snapshot 为输出；发布新 image。
// 失败/边界：输出先清空；null 仅在 allow_null 时成功，非法 image 原子失败。
function automatic bit rdma_cmq_try_snapshot_image_direct(
  input rdma_hw_image source,
  input bit allow_null,
  output rdma_hw_image snapshot
);
  rdma_hw_image candidate;

  snapshot = null;
  if (source == null)
    return allow_null;
  if (!rdma_cmq_image_shape_valid(source))
    return 1'b0;
  candidate = new("direct_hardware_image_snapshot");
  candidate.bytes = source.bytes;
  candidate.length = source.length;
  candidate.alignment = source.alignment;
  candidate.endian = source.endian;
  candidate.image_kind = source.image_kind;
  candidate.hardware_version = source.hardware_version;
  candidate.function_generation = source.function_generation;
  candidate.write_target_kind = source.write_target_kind;
  candidate.backing_target = source.backing_target;
  candidate.hmc_target = source.hmc_target;
  candidate.bar_target = source.bar_target;
  candidate.field_summary = source.field_summary;
  snapshot = candidate;
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

// 设计说明：context 以源对象身份作为 associative-array key，使同一 ticket、
// status 或 frozen owner 在 detached 图中仍只有一个 canonical node。
class rdma_cmq_nonfatal_snapshot_context;
  protected rdma_status status_snapshots[rdma_status];
  protected rdma_cmq_ticket ticket_snapshots[rdma_cmq_ticket];
  protected rdma_cmq_recovery_owner owner_snapshots[rdma_cmq_recovery_owner];

  // 功能：构造空的 nonfatal snapshot canonicalization context。
  // 输入/输出及副作用：无输入输出；清空三类 source-handle cache。
  // 失败/边界：构造不经过 UVM factory，也不取得 source graph 所有权。
  function new();
    status_snapshots.delete();
    ticket_snapshots.delete();
    owner_snapshots.delete();
  endfunction

  // 功能：直接复制必需 operation status，并复用同一 source 的 canonical snapshot。
  // 输入/输出及副作用：source 为输入，snapshot/reason 为输出；成功缓存新值。
  // 失败/边界：输出先清空；required source 为 null、wrapper 不匹配或含
  //   X/Z/spare category/code/source_engine 时在 cache lookup 前稳定非致命失败。
  function bit try_snapshot_required_status(
    input rdma_status source,
    output rdma_status snapshot,
    output string failure_reason
  );
    rdma_status candidate;

    snapshot = null;
    failure_reason = "";
    if (source == null) begin
      failure_reason = "required CMQ status is null";
      return 1'b0;
    end
    if (!rdma_cmq_status_shape_valid(source)) begin
      failure_reason = "required CMQ status source is invalid";
      return 1'b0;
    end
    if (status_snapshots.exists(source)) begin
      snapshot = status_snapshots[source];
      return 1'b1;
    end

    candidate = new("direct_status_snapshot");
    candidate.category = source.category;
    candidate.code = source.code;
    candidate.hardware_code = source.hardware_code;
    candidate.hardware_code_valid = source.hardware_code_valid;
    candidate.source_engine = source.source_engine;
    candidate.function_uid = source.function_uid;
    candidate.generation = source.generation;
    candidate.resource_id = source.resource_id;
    candidate.command_id = source.command_id;
    candidate.wr_id = source.wr_id;
    candidate.severity = source.severity;
    candidate.retryable = source.retryable;
    candidate.message = source.message;
    status_snapshots[source] = candidate;
    snapshot = candidate;
    return 1'b1;
  endfunction

  // 功能：直接复制可选 ticket，并在 context 内保留重复 source 的别名拓扑。
  // 输入/输出及副作用：source 为输入，snapshot/reason 为输出；成功可发布 null。
  // 失败/边界：null source 是干净成功；坏 ticket/subtype 不缓存且给出稳定原因。
  function bit try_snapshot_optional_ticket(
    input rdma_cmq_ticket source,
    output rdma_cmq_ticket snapshot,
    output string failure_reason
  );
    rdma_cmq_ticket candidate;
    rdma_handle function_snapshot_base;
    rdma_handle cmq_snapshot;
    rdma_cmq_opcode_key opcode_snapshot;

    snapshot = null;
    failure_reason = "";
    if (source == null)
      return 1'b1;
    if (ticket_snapshots.exists(source)) begin
      snapshot = ticket_snapshots[source];
      return 1'b1;
    end
    if (!rdma_cmq_ticket_shape_valid(source)) begin
      failure_reason = "CMQ ticket snapshot source is invalid";
      return 1'b0;
    end
    if (!rdma_cmq_try_snapshot_handle_direct(
          source.function_h, 1'b0, function_snapshot_base
        ) || !rdma_cmq_try_snapshot_handle_direct(
          source.cmq_h, 1'b0, cmq_snapshot
        ) || !rdma_cmq_try_snapshot_opcode_key_direct(
          source.opcode_key, opcode_snapshot
        )) begin
      failure_reason = "CMQ ticket nested value snapshot failed";
      return 1'b0;
    end

    candidate = new("direct_cmq_ticket_snapshot");
    if (!$cast(candidate.function_h, function_snapshot_base)) begin
      failure_reason = "CMQ ticket Function snapshot subtype is invalid";
      return 1'b0;
    end
    candidate.command_id = source.command_id;
    candidate.cmq_h = cmq_snapshot;
    candidate.slot_sequence = source.slot_sequence;
    candidate.sq_index = source.sq_index;
    candidate.sq_wrap = source.sq_wrap;
    candidate.opcode_key = opcode_snapshot;
    candidate.absolute_deadline = source.absolute_deadline;
    ticket_snapshots[source] = candidate;
    snapshot = candidate;
    return 1'b1;
  endfunction

  // 功能：直接复制 frozen recovery owner，并 canonicalize 重复 source node。
  // 输入/输出及副作用：source 为输入，snapshot/reason 为输出；成功缓存完整候选。
  // 失败/边界：null、legacy 以外的未冻结/坏矩阵或未知 subtype 原子失败。
  function bit try_snapshot_recovery_owner(
    input rdma_cmq_recovery_owner source,
    output rdma_cmq_recovery_owner snapshot,
    output string failure_reason
  );
    rdma_cmq_recovery_owner candidate;
    rdma_handle resource_snapshot;
    rdma_function_identity identity_snapshot;

    snapshot = null;
    failure_reason = "";
    if (source == null) begin
      failure_reason = "CMQ recovery owner source is null";
      return 1'b0;
    end
    if (owner_snapshots.exists(source)) begin
      snapshot = owner_snapshots[source];
      return 1'b1;
    end
    if (!rdma_cmq_frozen_owner_shape_valid(source)) begin
      failure_reason = "CMQ recovery owner source is not a valid frozen value";
      return 1'b0;
    end

    if (source.is_legacy_unmigrated()) begin
      candidate = rdma_cmq_recovery_owner::legacy_unmigrated();
    end
    else begin
      if (!rdma_cmq_try_snapshot_handle_direct(
            source.resource_h, 1'b0, resource_snapshot
          ) || !rdma_cmq_try_snapshot_identity_direct(
            source.function_identity, identity_snapshot
          )) begin
        failure_reason = "CMQ recovery owner nested snapshot failed";
        return 1'b0;
      end
      candidate = new("direct_recovery_owner_snapshot");
      candidate.workflow = source.workflow;
      candidate.resource_h = resource_snapshot;
      candidate.transaction_id = source.transaction_id;
      candidate.allowed_actions = source.allowed_actions;
      candidate.function_identity = identity_snapshot;
      candidate.admission_attempt_id = source.admission_attempt_id;
      candidate.frozen = source.frozen;
      if (!rdma_cmq_frozen_owner_shape_valid(candidate)) begin
        failure_reason = "CMQ recovery owner detached candidate is invalid";
        return 1'b0;
      end
    end

    owner_snapshots[source] = candidate;
    snapshot = candidate;
    return 1'b1;
  endfunction

  // 功能：用 caller 已分离的 typed payload 构造 completion shell snapshot。
  // 输入/输出及副作用：source/payload 为输入，snapshot/reason 为输出；复用
  //   context 中 ticket/status canonical nodes，并直接复制 raw CQE。
  // 失败/边界：null completion 可选成功；payload 缺失/自别名、坏 shell 或 raw
  //   image 或 wrapper 不匹配的注册子类时原子失败，绝不调用 clone/copy/factory。
  function bit try_snapshot_completion_shell(
    input rdma_cmq_completion source,
    input uvm_object detached_payload,
    output rdma_cmq_completion snapshot,
    output string failure_reason
  );
    rdma_cmq_completion candidate;
    rdma_cmq_ticket ticket_snapshot;
    rdma_status status_snapshot;
    rdma_hw_image raw_snapshot;
    string nested_reason;

    snapshot = null;
    failure_reason = "";
    if (source == null)
      return detached_payload == null;
    if (source.get_object_type() != rdma_cmq_completion::get_type()) begin
      failure_reason = "CMQ completion runtime subtype is unsupported";
      return 1'b0;
    end
    if ((source.decoded_response == null) != (detached_payload == null) ||
        (source.decoded_response != null &&
         detached_payload == source.decoded_response)) begin
      failure_reason = "CMQ completion payload is not a detached value";
      return 1'b0;
    end
    if (!rdma_cmq_ticket_shape_valid(source.ticket) ||
        source.status == null) begin
      failure_reason = "CMQ completion ticket or status is invalid";
      return 1'b0;
    end
    if (source.raw_cqe != null &&
        (!rdma_cmq_image_shape_valid(source.raw_cqe) ||
         source.raw_cqe.length != 64 ||
         source.raw_cqe.image_kind != RDMA_IMAGE_CMQ_CQE ||
         source.raw_cqe.write_target_kind != RDMA_HW_TARGET_NONE ||
         source.raw_cqe.backing_target.value != 0 ||
         source.raw_cqe.hmc_target.value != 0 ||
         source.raw_cqe.bar_target.value != 0 ||
         source.raw_cqe.function_generation !=
           source.ticket.function_h.generation)) begin
      failure_reason = "CMQ completion raw CQE is invalid";
      return 1'b0;
    end
    if (source.raw_cqe == null &&
        !(source.status.code inside {RDMA_SC_TIMEOUT,
                                     RDMA_SC_RESET_CANCELLED})) begin
      failure_reason = "CMQ hardware completion is missing its raw CQE";
      return 1'b0;
    end
    if (!try_snapshot_optional_ticket(
          source.ticket, ticket_snapshot, nested_reason
        )) begin
      failure_reason = nested_reason;
      return 1'b0;
    end
    if (!try_snapshot_required_status(
          source.status, status_snapshot, nested_reason
        )) begin
      failure_reason = nested_reason;
      return 1'b0;
    end
    if (!rdma_cmq_try_snapshot_image_direct(
          source.raw_cqe, 1'b1, raw_snapshot
        )) begin
      failure_reason = "CMQ completion raw CQE snapshot failed";
      return 1'b0;
    end

    candidate = new("direct_cmq_completion_snapshot");
    candidate.ticket = ticket_snapshot;
    candidate.status = status_snapshot;
    candidate.raw_cqe = raw_snapshot;
    candidate.decoded_response = detached_payload;
    snapshot = candidate;
    return 1'b1;
  endfunction
endclass

// 设计说明：执行结果把 operation outcome 与 observation health 分成两个 owned
// status，避免证据捕获失败覆盖真实命令结果，并保留调用方判断恢复所需的 detached 值。
class rdma_cmq_execution_result extends uvm_object;
  `uvm_object_utils(rdma_cmq_execution_result)

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

// 设计说明：每个 journal item 独立保留命令 authority、两层 effect 和生命周期
// completion，使 FIFO 投递或批次聚合不会销毁单命令的等待与恢复证据。
class rdma_cmq_batch_submission_item_record extends uvm_object;
  `uvm_object_utils(rdma_cmq_batch_submission_item_record)

  int unsigned request_index;
  rdma_cmq_command_desc command;
  rdma_cmq_ticket ticket;
  rdma_cmq_recovery_owner recovery_owner;
  rdma_dma_request_context dma_context;
  rdma_hw_image sqe_image;
  rdma_dma_mapping dependency_mapping;
  longint unsigned dependency_offset;
  rdma_hw_image dependency_image;
  longint unsigned slot_sequence;
  int unsigned slot_index;
  bit slot_wrap;
  bit [4:0] command_token;
  bit [58:0] token_incarnation;
  string entry_key;
  rdma_cmq_journal_digest_t image_digest;
  rdma_cmq_journal_digest_t authority_digest;
  bit dependency_replay_safe;
  rdma_cmq_submission_state_e state;
  rdma_submission_effect_e submission_effect;
  rdma_submission_effect_e attempt_effect;
  rdma_cmq_completion_phase_e completion_phase;
  bit reset_isolation_confirmed;
  bit recovery_required;
  rdma_cmq_completion completion;
  rdma_status status;

  // 功能：构造空 journal item，生命周期停在 STAGED 且 status 明确 fail-closed。
  // 输入/输出及副作用：name 传给 uvm_object；清空所有拥有引用、digest 和 token。
  // 失败/边界：默认 item 未取得 journal authority；不得解释为成功或已发布。
  function new(string name = "rdma_cmq_batch_submission_item_record");
    super.new(name);
    request_index = 0;
    command = null;
    ticket = null;
    recovery_owner = null;
    dma_context = null;
    sqe_image = null;
    dependency_mapping = null;
    dependency_offset = 0;
    dependency_image = null;
    slot_sequence = 0;
    slot_index = 0;
    slot_wrap = 1'b0;
    command_token = '0;
    token_incarnation = '0;
    entry_key = "";
    image_digest = '0;
    authority_digest = '0;
    dependency_replay_safe = 1'b0;
    state = RDMA_CMQ_SUBMISSION_STAGED;
    submission_effect = RDMA_SUBMIT_EFFECT_UNOBSERVED;
    attempt_effect = RDMA_SUBMIT_EFFECT_UNOBSERVED;
    completion_phase = RDMA_CMQ_COMPLETION_NONE;
    reset_isolation_confirmed = 1'b0;
    recovery_required = 1'b1;
    completion = null;
    status = rdma_cmq_direct_status(
      RDMA_SC_INVALID_STATE, "CMQ journal item is uninitialized"
    );
  endfunction
endclass

// 设计说明：batch record 把一次共享 doorbell 的稳定 authority 投影与有序 items
// 绑定在同一账本值中，供后续 CAS attempt 和 reset proof 对照原始提交边界。
class rdma_cmq_batch_submission_record extends uvm_object;
  `uvm_object_utils(rdma_cmq_batch_submission_record)

  string batch_key;
  longint unsigned batch_id;
  longint unsigned attempt_id;
  longint unsigned engine_instance_id;
  longint unsigned engine_incarnation;
  rdma_function_identity function_identity;
  rdma_function_binding binding;
  rdma_handle cmq_h;
  longint unsigned start_sequence;
  longint unsigned end_sequence;
  rdma_hw_image doorbell_image;
  int unsigned final_pi;
  bit final_polarity;
  rdma_cmq_journal_digest_t batch_digest;
  rdma_cmq_submission_state_e state;
  rdma_submission_effect_e submission_effect;
  rdma_submission_effect_e attempt_effect;
  bit observer_armed;
  bit publication_retry_safe;
  rdma_cmq_batch_submission_item_record items[$];
  rdma_cmq_reset_isolation_proof reset_isolation_proof;

  // 功能：构造空 batch journal value，清除 authority 投影、items 与 reset proof。
  // 输入/输出及副作用：name 传给 uvm_object；只初始化本对象拥有字段。
  // 失败/边界：零 ID/空 key 的默认记录不能用于恢复或 digest authority。
  function new(string name = "rdma_cmq_batch_submission_record");
    super.new(name);
    batch_key = "";
    batch_id = 0;
    attempt_id = 0;
    engine_instance_id = 0;
    engine_incarnation = 0;
    function_identity = null;
    binding = null;
    cmq_h = null;
    start_sequence = 0;
    end_sequence = 0;
    doorbell_image = null;
    final_pi = 0;
    final_polarity = 1'b0;
    batch_digest = '0;
    state = RDMA_CMQ_SUBMISSION_STAGED;
    submission_effect = RDMA_SUBMIT_EFFECT_UNOBSERVED;
    attempt_effect = RDMA_SUBMIT_EFFECT_UNOBSERVED;
    observer_armed = 1'b0;
    publication_retry_safe = 1'b0;
    items.delete();
    reset_isolation_proof = null;
  endfunction
endclass

// 设计说明：recovery item 只携带重算单项 digest 所需的不可变 authority，刻意
// 排除会随完成或重试变化的 lifecycle 字段，便于与 journal-owned 图独立比对。
class rdma_cmq_submission_recovery_item extends uvm_object;
  `uvm_object_utils(rdma_cmq_submission_recovery_item)

  int unsigned request_index;
  rdma_cmq_command_desc command;
  rdma_cmq_ticket ticket;
  rdma_cmq_recovery_owner recovery_owner;
  rdma_dma_request_context dma_context;
  rdma_hw_image sqe_image;
  rdma_dma_mapping dependency_mapping;
  longint unsigned dependency_offset;
  rdma_hw_image dependency_image;
  rdma_cmq_journal_digest_t image_digest;
  rdma_cmq_journal_digest_t authority_digest;

  // 功能：构造空的单项 recovery authority 投影。
  // 输入/输出及副作用：name 传给 uvm_object；清除引用、offset 与 digest。
  // 失败/边界：默认值没有 command/owner/mapping authority，不能触发恢复 I/O。
  function new(string name = "rdma_cmq_submission_recovery_item");
    super.new(name);
    request_index = 0;
    command = null;
    ticket = null;
    recovery_owner = null;
    dma_context = null;
    sqe_image = null;
    dependency_mapping = null;
    dependency_offset = 0;
    dependency_image = null;
    image_digest = '0;
    authority_digest = '0;
  endfunction
endclass

typedef enum logic [1:0] {
  RDMA_CMQ_RESET_PROOF_INVALID         = 2'd0,
  RDMA_CMQ_RESET_PROOF_AWAITING_REBIND = 2'd1,
  RDMA_CMQ_RESET_PROOF_READY           = 2'd2
} rdma_cmq_reset_isolation_proof_state_e;

// 设计说明：reset proof 是 engine mint 的旧 incarnation 隔离证据；稳定 digest
// 覆盖原 identity 与 owner tuple，而 replacement/state 由独立合法迁移规则验证。
class rdma_cmq_reset_isolation_proof extends uvm_object;
  `uvm_object_utils(rdma_cmq_reset_isolation_proof)

  string proof_key;
  longint unsigned proof_id;
  string batch_key;
  longint unsigned batch_id;
  longint unsigned attempt_id;
  longint unsigned engine_instance_id;
  longint unsigned engine_incarnation;
  rdma_function_identity isolated_identity;
  rdma_function_identity replacement_identity;
  rdma_cmq_journal_digest_t batch_digest;
  int unsigned isolated_request_indices[$];
  rdma_cmq_journal_digest_t isolated_image_digests[$];
  rdma_cmq_journal_digest_t isolated_authority_digests[$];
  rdma_cmq_recovery_owner isolated_recovery_owners[$];
  rdma_cmq_journal_digest_t proof_digest;
  rdma_cmq_reset_isolation_proof_state_e state;
  bit backing_release_confirmed;

  // 功能：构造 INVALID reset-isolation proof，并清空稳定四字段 item tuple。
  // 输入/输出及副作用：name 传给 uvm_object；只初始化本地 proof 值。
  // 失败/边界：公开构造对象不具备 engine-minted authority，不能伪造 READY。
  function new(string name = "rdma_cmq_reset_isolation_proof");
    super.new(name);
    proof_key = "";
    proof_id = 0;
    batch_key = "";
    batch_id = 0;
    attempt_id = 0;
    engine_instance_id = 0;
    engine_incarnation = 0;
    isolated_identity = null;
    replacement_identity = null;
    batch_digest = '0;
    isolated_request_indices.delete();
    isolated_image_digests.delete();
    isolated_authority_digests.delete();
    isolated_recovery_owners.delete();
    proof_digest = '0;
    state = RDMA_CMQ_RESET_PROOF_INVALID;
    backing_release_confirmed = 1'b0;
  endfunction
endclass

// 设计说明：recovery request 承载调用方 detached authority 图和期望 attempt；engine
// 必须分别重算它与 retained journal，再以完整值相等决定是否允许恢复动作。
class rdma_cmq_submission_recovery_request extends uvm_object;
  `uvm_object_utils(rdma_cmq_submission_recovery_request)

  string batch_key;
  longint unsigned batch_id;
  longint unsigned expected_attempt_id;
  rdma_function_identity expected_function_identity;
  rdma_function_binding binding;
  rdma_handle cmq_h;
  longint unsigned start_sequence;
  longint unsigned end_sequence;
  rdma_hw_image doorbell_image;
  int unsigned final_pi;
  bit final_polarity;
  rdma_cmq_journal_digest_t batch_digest;
  rdma_cmq_submission_recovery_action_e action;
  rdma_cmq_reset_isolation_proof reset_isolation_proof;
  rdma_cmq_submission_recovery_item items[$];

  // 功能：构造 fail-closed recovery request，action 为 INVALID 且无 items/authority。
  // 输入/输出及副作用：name 传给 uvm_object；清空所有 owned value 引用。
  // 失败/边界：默认请求不能授权 retry 或 reset confirmation。
  function new(string name = "rdma_cmq_submission_recovery_request");
    super.new(name);
    batch_key = "";
    batch_id = 0;
    expected_attempt_id = 0;
    expected_function_identity = null;
    binding = null;
    cmq_h = null;
    start_sequence = 0;
    end_sequence = 0;
    doorbell_image = null;
    final_pi = 0;
    final_polarity = 1'b0;
    batch_digest = '0;
    action = RDMA_CMQ_RECOVERY_INVALID;
    reset_isolation_proof = null;
    items.delete();
  endfunction
endclass

// 设计说明：canonical writer 只接受显式宽度和稳定字节顺序；每个失败入口
// 先验证完整输入，随后一次性附加，保证父 stream 不出现部分字段。
class rdma_cmq_canonical_writer;
  protected byte unsigned buffer[$];

  // 功能：构造空 canonical byte stream。
  // 输入/输出及副作用：无输入；初始化私有 buffer 为空。
  // 失败/边界：构造不分配外部资源，也不经过 UVM factory。
  function new();
    buffer.delete();
  endfunction

  // 功能：清空当前 canonical stream，供同一 writer 重用。
  // 输入/输出及副作用：无输入输出；删除 buffer 中全部字节。
  // 失败/边界：对空 writer 重复调用幂等，不影响既有 snapshot 数组。
  function void clear();
    buffer.delete();
  endfunction

  // 功能：以单字节 big-endian 形式附加一个无未知位的 u8。
  // 输入/输出及副作用：value 为输入；成功向 buffer 尾部附加一字节并返回 1。
  // 失败/边界：value 含 X/Z 时返回 0 且 buffer 不变。
  function bit append_u8(input logic [7:0] value);
    if ($isunknown(value))
      return 1'b0;
    buffer.push_back(byte'(value));
    return 1'b1;
  endfunction

  // 功能：按高字节在前顺序附加无未知位的 u16。
  // 输入/输出及副作用：value 为输入；成功追加两字节。
  // 失败/边界：任一位含 X/Z 时返回 0，追加前完成校验所以 buffer 不变。
  function bit append_u16(input logic [15:0] value);
    if ($isunknown(value))
      return 1'b0;
    buffer.push_back(byte'(value[15:8]));
    buffer.push_back(byte'(value[7:0]));
    return 1'b1;
  endfunction

  // 功能：按高字节在前顺序附加无未知位的 u32。
  // 输入/输出及副作用：value 为输入；成功追加四字节。
  // 失败/边界：value 含 X/Z 时返回 0 且 buffer 不变。
  function bit append_u32(input logic [31:0] value);
    if ($isunknown(value))
      return 1'b0;
    for (int shift = 24; shift >= 0; shift -= 8)
      buffer.push_back(byte'(value[shift +: 8]));
    return 1'b1;
  endfunction

  // 功能：按高字节在前顺序附加无未知位的 u64。
  // 输入/输出及副作用：value 为输入；成功追加八字节。
  // 失败/边界：value 含 X/Z 时返回 0 且 buffer 不变。
  function bit append_u64(input logic [63:0] value);
    if ($isunknown(value))
      return 1'b0;
    for (int shift = 56; shift >= 0; shift -= 8)
      buffer.push_back(byte'(value[shift +: 8]));
    return 1'b1;
  endfunction

  // 功能：从 bit255 到 bit0 以 32 个大端字节附加 journal digest。
  // 输入/输出及副作用：value 为输入；成功追加固定 32 字节。
  // 失败/边界：digest 含 X/Z 时返回 0 且 buffer 不变。
  function bit append_digest(input logic [255:0] value);
    if ($isunknown(value))
      return 1'b0;
    for (int shift = 248; shift >= 0; shift -= 8)
      buffer.push_back(byte'(value[shift +: 8]));
    return 1'b1;
  endfunction

  // 功能：不加长度前缀地按数组索引顺序附加原始字节。
  // 输入/输出及副作用：value 为输入；逐字节追加到 buffer。
  // 失败/边界：byte unsigned 为二态；空数组合法且不改变 buffer。
  function bit append_raw(input byte unsigned value[]);
    foreach (value[i])
      buffer.push_back(value[i]);
    return 1'b1;
  endfunction

  // 功能：以 u32 元素数前缀附加 byte 数组。
  // 输入/输出及副作用：value 为输入；成功追加计数和全部字节。
  // 失败/边界：元素数超过 32'hffff_ffff 时返回 0 且不部分追加。
  function bit append_counted_bytes(input byte unsigned value[]);
    rdma_cmq_canonical_writer child;
    byte unsigned child_bytes[];

    if (longint'(value.size()) > 64'h0000_0000_ffff_ffff)
      return 1'b0;
    child = new();
    if (!child.append_u32(value.size()) || !child.append_raw(value))
      return 1'b0;
    child.snapshot(child_bytes);
    return append_raw(child_bytes);
  endfunction

  // 功能：验证 UTF-8 后，以 u32 byte_count 加原始 getc 字节编码 string。
  // 输入/输出及副作用：value 为输入；成功时一次性追加计数与 UTF-8 bytes。
  // 失败/边界：拒绝 truncated、overlong、surrogate、非法 continuation 及
  //   U+10FFFF 以上序列；失败时 buffer 完全不变。
  function bit append_string(input string value);
    byte unsigned bytes[];
    int unsigned index;
    int unsigned count;
    byte unsigned first;
    byte unsigned second;

    count = value.len();
    if (longint'(count) > 64'h0000_0000_ffff_ffff)
      return 1'b0;
    index = 0;
    while (index < count) begin
      first = byte'(value.getc(index));
      if (first <= 8'h7f) begin
        index++;
      end
      else if (first inside {[8'hc2:8'hdf]}) begin
        if (index + 1 >= count ||
            !(byte'(value.getc(index + 1)) inside {[8'h80:8'hbf]}))
          return 1'b0;
        index += 2;
      end
      else if (first inside {[8'he0:8'hef]}) begin
        if (index + 2 >= count)
          return 1'b0;
        second = byte'(value.getc(index + 1));
        if ((first == 8'he0 && !(second inside {[8'ha0:8'hbf]})) ||
            (first == 8'hed && !(second inside {[8'h80:8'h9f]})) ||
            (first != 8'he0 && first != 8'hed &&
             !(second inside {[8'h80:8'hbf]})) ||
            !(byte'(value.getc(index + 2)) inside {[8'h80:8'hbf]}))
          return 1'b0;
        index += 3;
      end
      else if (first inside {[8'hf0:8'hf4]}) begin
        if (index + 3 >= count)
          return 1'b0;
        second = byte'(value.getc(index + 1));
        if ((first == 8'hf0 && !(second inside {[8'h90:8'hbf]})) ||
            (first == 8'hf4 && !(second inside {[8'h80:8'h8f]})) ||
            (first != 8'hf0 && first != 8'hf4 &&
             !(second inside {[8'h80:8'hbf]})) ||
            !(byte'(value.getc(index + 2)) inside {[8'h80:8'hbf]}) ||
            !(byte'(value.getc(index + 3)) inside {[8'h80:8'hbf]}))
          return 1'b0;
        index += 4;
      end
      else begin
        return 1'b0;
      end
    end

    bytes = new[count];
    foreach (bytes[i])
      bytes[i] = byte'(value.getc(i));
    return append_counted_bytes(bytes);
  endfunction

  // 功能：编码 object presence，并在 present 时追加稳定、计数型 schema tag。
  // 输入/输出及副作用：present 和 schema_tag 为输入；成功原子追加 header。
  // 失败/边界：present 含 X/Z、absent 带 tag 或 present 空 tag 时返回 0 且不改 buffer。
  function bit append_object_header(
    input logic present,
    input string schema_tag
  );
    rdma_cmq_canonical_writer child;
    byte unsigned child_bytes[];

    if ($isunknown(present) ||
        (present === 1'b0 && schema_tag.len() != 0) ||
        (present === 1'b1 && schema_tag.len() == 0))
      return 1'b0;
    child = new();
    if (!child.append_u8({7'b0, present}))
      return 1'b0;
    if (present === 1'b1 && !child.append_string(schema_tag))
      return 1'b0;
    child.snapshot(child_bytes);
    return append_raw(child_bytes);
  endfunction

  // 功能：返回当前 buffer 的 detached dynamic-array snapshot，且不清空 writer。
  // 输入/输出及副作用：value 为输出；分配并逐字节复制 buffer。
  // 失败/边界：空 stream 返回长度零数组；调用方修改 snapshot 不影响 writer。
  function void snapshot(output byte unsigned value[]);
    value = new[buffer.size()];
    foreach (buffer[i])
      value[i] = buffer[i];
  endfunction
endclass

// 功能：把完整 child writer 的 snapshot 一次性提交到 parent，供复合 schema 原子编码。
// 输入/输出及副作用：parent/child 为输入；成功时向 parent 追加 child 全部字节。
// 失败/边界：任一 writer 为空时返回 0；child 为空合法且不改变 parent。
function automatic bit rdma_cmq_commit_child_writer(
  input rdma_cmq_canonical_writer parent,
  input rdma_cmq_canonical_writer child
);
  byte unsigned bytes[];

  if (parent == null || child == null)
    return 1'b0;
  child.snapshot(bytes);
  return parent.append_raw(bytes);
endfunction

// 功能：追加一个无长度前缀、以 NUL 结尾的 ASCII digest domain tag。
// 输入/输出及副作用：writer/domain_tag 为输入；成功向 stream 追加 literal 与 00。
// 失败/边界：writer/null、空 tag、内含 NUL 或非 ASCII byte 时原子失败。
function automatic bit rdma_cmq_append_domain_tag(
  input rdma_cmq_canonical_writer writer,
  input string domain_tag
);
  byte unsigned bytes[];

  if (writer == null || domain_tag.len() == 0)
    return 1'b0;
  bytes = new[domain_tag.len() + 1];
  for (int unsigned i = 0; i < domain_tag.len(); i++) begin
    bytes[i] = byte'(domain_tag.getc(i));
    if (bytes[i] == 0 || bytes[i] > 8'h7f)
      return 1'b0;
  end
  bytes[domain_tag.len()] = 8'h00;
  return writer.append_raw(bytes);
endfunction

// 功能：按 HANDLE-V1 编码 nullable/required handle 及其四个公开身份字段。
// 输入/输出及副作用：writer/value/allow_null 为输入；成功原子追加 object bytes。
// 失败/边界：required null、未知 runtime subtype、非法 kind 或零 UID/generation 拒绝。
function automatic bit rdma_cmq_append_handle_v1(
  input rdma_cmq_canonical_writer writer,
  input rdma_handle value,
  input bit allow_null
);
  rdma_cmq_canonical_writer child;

  if (writer == null || (value == null && !allow_null))
    return 1'b0;
  child = new();
  if (value == null)
    return child.append_object_header(1'b0, "") &&
           rdma_cmq_commit_child_writer(writer, child);
  if (!rdma_cmq_direct_handle_type_supported(value) ||
      !(value.kind inside {RDMA_RESOURCE_FUNCTION, RDMA_RESOURCE_PD,
                           RDMA_RESOURCE_MR, RDMA_RESOURCE_CQ,
                           RDMA_RESOURCE_QP, RDMA_RESOURCE_SRQ,
                           RDMA_RESOURCE_CMQ, RDMA_RESOURCE_CEQ,
                           RDMA_RESOURCE_AEQ, RDMA_RESOURCE_MW}) ||
      value.function_uid == 0 || value.generation == 0)
    return 1'b0;
  if (!child.append_object_header(1'b1, "HANDLE-V1") ||
      !child.append_u8(value.kind) ||
      !child.append_u64(value.function_uid) ||
      !child.append_u32(value.object_id) ||
      !child.append_u32(value.generation))
    return 1'b0;
  return rdma_cmq_commit_child_writer(writer, child);
endfunction

// 功能：按 BDF-V1 编码 segment、bus、device 与 function_num。
// 输入/输出及副作用：writer/bdf 为输入；成功原子追加带 schema header 的 BDF。
// 失败/边界：writer 为空时失败；全零 BDF 仍可表示 PF 的空 parent 值。
function automatic bit rdma_cmq_append_bdf_v1(
  input rdma_cmq_canonical_writer writer,
  input rdma_bdf_t bdf
);
  rdma_cmq_canonical_writer child;

  if (writer == null)
    return 1'b0;
  child = new();
  if (!child.append_object_header(1'b1, "BDF-V1") ||
      !child.append_u16(bdf.segment) || !child.append_u8(bdf.bus) ||
      !child.append_u8(bdf.device) ||
      !child.append_u8(bdf.function_num))
    return 1'b0;
  return rdma_cmq_commit_child_writer(writer, child);
endfunction

// 功能：按 ROUTE-V1 编码 Host/root/segment 与嵌套 BDF 路由值。
// 输入/输出及副作用：writer/route 为输入；成功原子追加完整 route object。
// 失败/边界：BDF 缺失或 route.segment 与 BDF segment 不一致时拒绝。
function automatic bit rdma_cmq_append_route_v1(
  input rdma_cmq_canonical_writer writer,
  input rdma_route_key_t route
);
  rdma_cmq_canonical_writer child;

  if (writer == null || !rdma_route_key_valid(route))
    return 1'b0;
  child = new();
  if (!child.append_object_header(1'b1, "ROUTE-V1") ||
      !child.append_u32(route.host_topology_key) ||
      !child.append_u16(route.root_id) ||
      !child.append_u16(route.segment) ||
      !rdma_cmq_append_bdf_v1(child, route.bdf))
    return 1'b0;
  return rdma_cmq_commit_child_writer(writer, child);
endfunction

// 功能：按 FUNCTION-IDENTITY-V1 编码完整 topology、global ID 与 incarnation。
// 输入/输出及副作用：writer/identity/allow_null 为输入；成功原子追加 identity。
// 失败/边界：required null 或 route/UID/generation 非法时拒绝且 parent 不变。
function automatic bit rdma_cmq_append_function_identity_v1(
  input rdma_cmq_canonical_writer writer,
  input rdma_function_identity identity,
  input bit allow_null
);
  rdma_cmq_canonical_writer child;

  if (writer == null || (identity == null && !allow_null))
    return 1'b0;
  child = new();
  if (identity == null)
    return child.append_object_header(1'b0, "") &&
           rdma_cmq_commit_child_writer(writer, child);
  if (!rdma_cmq_identity_shape_valid(identity))
    return 1'b0;
  if (!child.append_object_header(1'b1, "FUNCTION-IDENTITY-V1") ||
      !child.append_u16(identity.key.root_id) ||
      !child.append_u32(identity.key.host_topology_key) ||
      !child.append_u8(identity.key.function_kind) ||
      !rdma_cmq_append_bdf_v1(child, identity.key.parent_pf_bdf) ||
      !child.append_u16(identity.key.vf_index) ||
      !rdma_cmq_append_bdf_v1(child, identity.key.bdf) ||
      !child.append_u32(identity.global_function_id) ||
      !child.append_u64(identity.function_uid) ||
      !child.append_u32(identity.generation) ||
      !child.append_u64(identity.reset_epoch))
    return 1'b0;
  return rdma_cmq_commit_child_writer(writer, child);
endfunction

// 功能：按 OPCODE-KEY-V1 编码 profile、opcode 与 variant。
// 输入/输出及副作用：writer/key 为输入；成功原子追加 stable opcode object。
// 失败/边界：key 为空、文本为空/含分隔符或 UTF-8 非法时拒绝。
function automatic bit rdma_cmq_append_opcode_key_v1(
  input rdma_cmq_canonical_writer writer,
  input rdma_cmq_opcode_key key
);
  rdma_cmq_canonical_writer child;

  if (writer == null || !rdma_cmq_opcode_key_shape_valid(key))
    return 1'b0;
  child = new();
  if (!child.append_object_header(1'b1, "OPCODE-KEY-V1") ||
      !child.append_string(key.profile_name) ||
      !child.append_u32(key.opcode) ||
      !child.append_string(key.variant))
    return 1'b0;
  return rdma_cmq_commit_child_writer(writer, child);
endfunction

// 功能：按 RECOVERY-OWNER-V1 编码 exact legacy 或具体 frozen owner。
// 输入/输出及副作用：writer/owner 为输入；成功追加完整 immutable provenance。
// 失败/边界：null、被篡改 sentinel、未冻结 concrete owner、X/Z mask/matrix 拒绝。
function automatic bit rdma_cmq_append_recovery_owner_v1(
  input rdma_cmq_canonical_writer writer,
  input rdma_cmq_recovery_owner owner
);
  rdma_cmq_canonical_writer child;
  bit legacy;

  if (writer == null || !rdma_cmq_frozen_owner_shape_valid(owner))
    return 1'b0;
  legacy = owner.is_legacy_unmigrated();
  child = new();
  if (!child.append_object_header(1'b1, "RECOVERY-OWNER-V1") ||
      !child.append_u8(owner.workflow) ||
      !rdma_cmq_append_handle_v1(child, owner.resource_h, legacy) ||
      !child.append_u64(owner.transaction_id) ||
      !child.append_u8({5'b0, owner.allowed_actions}) ||
      !rdma_cmq_append_function_identity_v1(
        child, owner.function_identity, legacy
      ) || !child.append_u64(owner.admission_attempt_id) ||
      !child.append_u8({7'b0, owner.frozen}))
    return 1'b0;
  return rdma_cmq_commit_child_writer(writer, child);
endfunction

// 功能：按 IMAGE-V1 编码 image metadata、raw bytes 与 field-summary queue。
// 输入/输出及副作用：writer/image/allow_null 为输入；成功原子追加完整 image。
// 失败/边界：required null、runtime subtype/长度/枚举 metadata 非法或 UTF-8
//   summary 非法时拒绝，不向 parent 提交半个 image。
function automatic bit rdma_cmq_append_image_v1(
  input rdma_cmq_canonical_writer writer,
  input rdma_hw_image image,
  input bit allow_null
);
  rdma_cmq_canonical_writer child;

  if (writer == null || (image == null && !allow_null))
    return 1'b0;
  child = new();
  if (image == null)
    return child.append_object_header(1'b0, "") &&
           rdma_cmq_commit_child_writer(writer, child);
  if (!rdma_cmq_image_shape_valid(image))
    return 1'b0;
  if (!child.append_object_header(1'b1, "IMAGE-V1") ||
      !child.append_u64(image.length) ||
      !child.append_u32(image.alignment) ||
      !child.append_u8(image.endian) ||
      !child.append_u8(image.image_kind) ||
      !child.append_u32(image.hardware_version) ||
      !child.append_u32(image.function_generation) ||
      !child.append_u8(image.write_target_kind) ||
      !child.append_u64(image.backing_target.value) ||
      !child.append_u64(image.hmc_target.value) ||
      !child.append_u64(image.bar_target.value) ||
      !child.append_counted_bytes(image.bytes) ||
      !child.append_u32(image.field_summary.size()))
    return 1'b0;
  foreach (image.field_summary[i]) begin
    if (!child.append_string(image.field_summary[i]))
      return 1'b0;
  end
  return rdma_cmq_commit_child_writer(writer, child);
endfunction

// 功能：按 CMQ-TICKET-V1 编码 command、slot、opcode 与 deadline identity。
// 输入/输出及副作用：writer/ticket 为输入；成功原子追加完整 ticket object。
// 失败/边界：ticket 形状、Function/CMQ subtype 或 SQ sequence 非法时拒绝。
function automatic bit rdma_cmq_append_ticket_v1(
  input rdma_cmq_canonical_writer writer,
  input rdma_cmq_ticket ticket
);
  rdma_cmq_canonical_writer child;

  if (writer == null || !rdma_cmq_ticket_shape_valid(ticket))
    return 1'b0;
  child = new();
  if (!child.append_object_header(1'b1, "CMQ-TICKET-V1") ||
      !child.append_u64(ticket.command_id) ||
      !rdma_cmq_append_handle_v1(child, ticket.function_h, 1'b0) ||
      !rdma_cmq_append_handle_v1(child, ticket.cmq_h, 1'b0) ||
      !child.append_u64(ticket.slot_sequence) ||
      !child.append_u32(ticket.sq_index) ||
      !child.append_u8({7'b0, ticket.sq_wrap}) ||
      !rdma_cmq_append_opcode_key_v1(child, ticket.opcode_key) ||
      !child.append_u64(ticket.absolute_deadline))
    return 1'b0;
  return rdma_cmq_commit_child_writer(writer, child);
endfunction

// 功能：按 DMA-CONTEXT-V1 编码 requester authority、route/epoch 与 owner hint。
// 输入/输出及副作用：writer/dma_context 为输入；成功原子追加公开 DMA context。
// 失败/边界：null、坏 Function/owner wrapper、非法 route 或无效 PASID 非零时拒绝。
function automatic bit rdma_cmq_append_dma_context_v1(
  input rdma_cmq_canonical_writer writer,
  input rdma_dma_request_context dma_context
);
  rdma_cmq_canonical_writer child;

  if (writer == null || dma_context == null ||
      dma_context.function_h == null ||
      dma_context.function_h.get_object_type() !=
        rdma_function_handle::get_type() ||
      !rdma_cmq_direct_handle_type_supported(dma_context.function_h) ||
      dma_context.function_h.kind != RDMA_RESOURCE_FUNCTION ||
      dma_context.function_h.generation == 0 ||
      (!dma_context.pasid_valid && dma_context.pasid != 0) ||
      (dma_context.route_valid && !rdma_route_key_valid(dma_context.route)) ||
      (dma_context.owner_h != null &&
       (!rdma_cmq_direct_handle_type_supported(dma_context.owner_h) ||
        dma_context.owner_h.function_uid !=
          dma_context.function_h.function_uid ||
        dma_context.owner_h.generation != dma_context.function_h.generation)))
    return 1'b0;
  child = new();
  if (!child.append_object_header(1'b1, "DMA-CONTEXT-V1") ||
      !rdma_cmq_append_handle_v1(child, dma_context.function_h, 1'b0) ||
      !rdma_cmq_append_bdf_v1(child, dma_context.requester_bdf) ||
      !child.append_u8({7'b0, dma_context.pasid_valid}) ||
      !child.append_u32(dma_context.pasid) ||
      !child.append_u8({7'b0, dma_context.dma_domain_valid}) ||
      !child.append_u32(dma_context.dma_domain_id) ||
      !rdma_cmq_append_route_v1(child, dma_context.route) ||
      !child.append_u64(dma_context.reset_epoch) ||
      !child.append_u8({7'b0, dma_context.route_valid}) ||
      !child.append_u8({7'b0, dma_context.epoch_valid}) ||
      !rdma_cmq_append_handle_v1(child, dma_context.owner_h, 1'b1) ||
      !child.append_u8({7'b0, dma_context.queue_role_valid}) ||
      !child.append_u32(dma_context.queue_role))
    return 1'b0;
  return rdma_cmq_commit_child_writer(writer, child);
endfunction

// 功能：按 DMA-MAPPING-PUBLIC-V1 编码公开 DMA projection，排除 opaque token。
// 输入/输出及副作用：writer/mapping 为输入；成功仅追加列明的 public 字段。
// 失败/边界：null/坏句柄、route/PASID、零 size 或非法 direction/state 拒绝；
//   umem/pbl/mw 引用、concrete subtype 与 allocation identity 永不读取。
function automatic bit rdma_cmq_append_dma_mapping_public_v1(
  input rdma_cmq_canonical_writer writer,
  input rdma_dma_mapping mapping
);
  rdma_cmq_canonical_writer child;

  if (writer == null || mapping == null || mapping.function_h == null ||
      mapping.function_h.get_object_type() !=
        rdma_function_handle::get_type() ||
      !rdma_cmq_direct_handle_type_supported(mapping.function_h) ||
      mapping.function_h.kind != RDMA_RESOURCE_FUNCTION ||
      mapping.function_h.generation == 0 || mapping.size == 0 ||
      (!mapping.pasid_valid && mapping.pasid != 0) ||
      (mapping.route_valid && !rdma_route_key_valid(mapping.route)) ||
      !(mapping.direction inside {RDMA_DMA_DEVICE_READ,
                                  RDMA_DMA_DEVICE_WRITE,
                                  RDMA_DMA_BIDIRECTIONAL}) ||
      !(mapping.state inside {RDMA_MAPPING_INVALID, RDMA_MAPPING_ACTIVE,
                              RDMA_MAPPING_FROZEN,
                              RDMA_MAPPING_RELEASED}) ||
      (mapping.owner_h != null &&
       (!rdma_cmq_direct_handle_type_supported(mapping.owner_h) ||
        mapping.owner_h.function_uid != mapping.function_h.function_uid ||
        mapping.owner_h.generation != mapping.function_h.generation)))
    return 1'b0;
  child = new();
  if (!child.append_object_header(1'b1, "DMA-MAPPING-PUBLIC-V1") ||
      !rdma_cmq_append_handle_v1(child, mapping.function_h, 1'b0) ||
      !rdma_cmq_append_bdf_v1(child, mapping.requester_bdf) ||
      !child.append_u8({7'b0, mapping.pasid_valid}) ||
      !child.append_u32(mapping.pasid) ||
      !child.append_u8({7'b0, mapping.dma_domain_valid}) ||
      !child.append_u32(mapping.dma_domain_id) ||
      !rdma_cmq_append_route_v1(child, mapping.route) ||
      !child.append_u64(mapping.reset_epoch) ||
      !child.append_u8({7'b0, mapping.route_valid}) ||
      !child.append_u8({7'b0, mapping.epoch_valid}) ||
      !child.append_u64(mapping.backing_addr.value) ||
      !child.append_u64(mapping.iova.value) ||
      !child.append_u64(mapping.size) ||
      !child.append_u8(mapping.direction) ||
      !child.append_u8({7'b0, mapping.permissions.device_read}) ||
      !child.append_u8({7'b0, mapping.permissions.device_write}) ||
      !child.append_u8({7'b0, mapping.permissions.atomic}) ||
      !child.append_u8(mapping.state) ||
      !rdma_cmq_append_handle_v1(child, mapping.owner_h, 1'b1) ||
      !child.append_u8({7'b0, mapping.umem_backed}) ||
      !child.append_u32(mapping.umem_page_count))
    return 1'b0;
  return rdma_cmq_commit_child_writer(writer, child);
endfunction

// 功能：按 FUNCTION-BINDING-V1 编码已 detached binding 的全部公开 authority projection。
// 输入/输出及副作用：writer/binding 为输入；内部取得 detached identity 后追加值。
// 失败/边界：binding/PCIe/BAR/identity 缺失、state 含 X/Z 或大于 RDMA_BIND_ERROR、
//   snapshot status 非 OK 或 owner subtype 非法时拒绝；不读取 protected identity 引用本身。
function automatic bit rdma_cmq_append_function_binding_v1(
  input rdma_cmq_canonical_writer writer,
  input rdma_function_binding binding
);
  rdma_cmq_canonical_writer child;
  rdma_function_identity identity;
  rdma_status status;

  if (writer == null || binding == null || binding.pcie == null ||
      $isunknown(binding.state) || binding.state > RDMA_BIND_ERROR)
    return 1'b0;
  status = binding.snapshot_identity_nonfatal(identity);
  if (status == null || !status.ok() || identity == null)
    return 1'b0;
  foreach (binding.pcie.bar[i]) begin
    if (binding.pcie.bar[i] == null)
      return 1'b0;
  end
  if (binding.owner_h != null &&
      !rdma_cmq_direct_handle_type_supported(binding.owner_h))
    return 1'b0;

  child = new();
  if (!child.append_object_header(1'b1, "FUNCTION-BINDING-V1") ||
      !child.append_u64(binding.function_uid) ||
      !rdma_cmq_append_function_identity_v1(child, identity, 1'b0) ||
      !rdma_cmq_append_bdf_v1(child, binding.pcie.bdf) ||
      !rdma_cmq_append_bdf_v1(child, binding.pcie.parent_pf_bdf) ||
      !child.append_u32(binding.pcie.vf_index) ||
      !child.append_u8({7'b0, binding.pcie.mse}) ||
      !child.append_u8({7'b0, binding.pcie.bme}))
    return 1'b0;
  foreach (binding.pcie.bar[i]) begin
    if (!child.append_u8(binding.pcie.bar[i].bar_id) ||
        !child.append_u64(binding.pcie.bar[i].base.value) ||
        !child.append_u64(binding.pcie.bar[i].size) ||
        !child.append_u8({7'b0, binding.pcie.bar[i].enabled}))
      return 1'b0;
  end
  if (!child.append_u8(binding.notify_bar_id) ||
      !child.append_u64(binding.notify_base.value) ||
      !child.append_u64(binding.notify_size) ||
      !child.append_u32(binding.notify_table_sel) ||
      !child.append_u32(binding.notify_table_index) ||
      !child.append_u32(binding.host_id) ||
      !child.append_u32(binding.pfvf_id) ||
      !child.append_u32(binding.rdma_vf_id) ||
      !child.append_u32(binding.global_function_id) ||
      !child.append_u32(binding.vsi_id) ||
      !rdma_cmq_append_bdf_v1(child, binding.queue_dma.requester_bdf) ||
      !child.append_u8({7'b0, binding.queue_dma.pasid_valid}) ||
      !child.append_u32(binding.queue_dma.pasid) ||
      !child.append_u8({7'b0, binding.queue_dma.dma_domain_valid}) ||
      !child.append_u32(binding.queue_dma.dma_domain_id) ||
      !child.append_u32(binding.queue_caps.min_cq_depth) ||
      !child.append_u32(binding.queue_caps.max_cq_depth) ||
      !child.append_u32(binding.queue_caps.min_srq_depth) ||
      !child.append_u32(binding.queue_caps.max_srq_depth) ||
      !child.append_u32(binding.queue_caps.max_ceq_depth) ||
      !child.append_u32(binding.queue_caps.max_aeq_depth) ||
      !child.append_u32(binding.queue_caps.max_wq_sge) ||
      !child.append_u64(binding.queue_caps.max_queue_ring_bytes) ||
      !child.append_u64(binding.queue_caps.max_sgb_bytes) ||
      !child.append_u32(binding.interrupt_vectors.size()))
    return 1'b0;
  foreach (binding.interrupt_vectors[i]) begin
    if (!child.append_u32(
          binding.interrupt_vectors[i].function_local_vector
        ) || !child.append_u32(
          binding.interrupt_vectors[i].hardware_eq_vector
        ) || !child.append_u32(
          binding.interrupt_vectors[i].msix_table_index
        ) || !child.append_u8({
          7'b0, binding.interrupt_vectors[i].enabled
        }))
      return 1'b0;
  end
  if (!child.append_u8(binding.state) ||
      !child.append_u32(binding.generation) ||
      !rdma_cmq_append_handle_v1(child, binding.owner_h, 1'b1) ||
      !child.append_u8({7'b0, binding.notify_valid}) ||
      !child.append_u8({7'b0, binding.notify_ready}) ||
      !child.append_u8({7'b0, binding.dmi_valid}) ||
      !child.append_u8({7'b0, binding.dmi_ready}) ||
      !child.append_u8({7'b0, binding.vft_valid}) ||
      !child.append_u8({7'b0, binding.vft_ready}))
    return 1'b0;
  return rdma_cmq_commit_child_writer(writer, child);
endfunction

// 功能：按 CMQ-COMMAND-V1 编码命令 shell，并在 body 位置插入 profile 输出。
// 输入/输出及副作用：writer/command/body tag/field bytes 为输入；成功原子追加。
// 失败/边界：未知 body tag、无效 Function/opcode/owner/image 或空 body 拒绝；
//   model 层不 cast codec 具体 body，且只信任唯一注册 wrapper 身份而非类型名字符串。
function automatic bit rdma_cmq_append_command_v1(
  input rdma_cmq_canonical_writer writer,
  input rdma_cmq_command_desc command,
  input string command_body_schema_tag,
  input byte unsigned command_body_field_bytes[]
);
  rdma_cmq_canonical_writer child;

  if (writer == null || command == null || command.body == null ||
      command.function_h == null ||
      command.function_h.get_object_type() !=
        rdma_function_handle::get_type() ||
      !rdma_cmq_direct_handle_type_supported(command.function_h) ||
      command.function_h.kind != RDMA_RESOURCE_FUNCTION ||
      command.function_h.generation == 0 ||
      !rdma_cmq_opcode_key_shape_valid(command.opcode_key) ||
      command.timeout == 0 ||
      !rdma_cmq_frozen_owner_shape_valid(command.recovery_owner) ||
      !((command_body_schema_tag == "CMQ-BODY-QPC-V1") ||
        (command_body_schema_tag == "CMQ-BODY-OBJECT-ID-V1") ||
        (command_body_schema_tag == "CMQ-BODY-MR-DEREGISTER-V1") ||
        (command_body_schema_tag == "CMQ-BODY-OCC-FLUSH-V1") ||
        (command_body_schema_tag == "CMQ-BODY-EMPTY-V1")) ||
      (command.qpc_signature_source != null &&
       (!rdma_cmq_image_shape_valid(command.qpc_signature_source) ||
        command.qpc_signature_source.function_generation !=
          command.function_h.generation)))
    return 1'b0;
  child = new();
  if (!child.append_object_header(1'b1, "CMQ-COMMAND-V1") ||
      !rdma_cmq_append_handle_v1(child, command.function_h, 1'b0) ||
      !rdma_cmq_append_opcode_key_v1(child, command.opcode_key) ||
      !child.append_object_header(1'b1, command_body_schema_tag) ||
      !child.append_raw(command_body_field_bytes) ||
      !rdma_cmq_append_image_v1(
        child, command.qpc_signature_source, 1'b1
      ) || !child.append_u8({7'b0, command.vfid_override}) ||
      !child.append_u16(command.use_vfid) ||
      !child.append_u64(command.timeout) ||
      !rdma_cmq_append_recovery_owner_v1(child, command.recovery_owner))
    return 1'b0;
  return rdma_cmq_commit_child_writer(writer, child);
endfunction

// 功能：对 canonical bytes 运行四条独立 64-bit FNV-1a lane 并固定打包顺序。
// 输入/输出及副作用：canonical_bytes 为输入；返回 {lane3,lane2,lane1,lane0}。
// 失败/边界：空数组返回四个 seed；byte 为二态，不存在 X/Z 或外部状态。
function automatic rdma_cmq_journal_digest_t rdma_cmq_digest_bytes(
  input byte unsigned canonical_bytes[]
);
  longint unsigned lane0;
  longint unsigned lane1;
  longint unsigned lane2;
  longint unsigned lane3;
  longint unsigned prime;

  lane0 = 64'hcbf2_9ce4_8422_2325;
  lane1 = 64'h8422_2325_cbf2_9ce4;
  lane2 = 64'h9e37_79b9_7f4a_7c15;
  lane3 = 64'hd6e8_feb8_6659_fd93;
  prime = 64'h0000_0100_0000_01b3;
  foreach (canonical_bytes[i]) begin
    lane0 = (lane0 ^ canonical_bytes[i]) * prime;
    lane1 = (lane1 ^ canonical_bytes[i]) * prime;
    lane2 = (lane2 ^ canonical_bytes[i]) * prime;
    lane3 = (lane3 ^ canonical_bytes[i]) * prime;
  end
  return {lane3, lane2, lane1, lane0};
endfunction

// 功能：分别计算 CMQ image 与 authority 两个 V1 domain digest。
// 输入/输出及副作用：读取 command/body projection、ticket、owner、Function、DMA
//   与两份 image；成功同时发布 image_digest/authority_digest，不保留源引用。
// 失败/边界：输出先清零；required value 缺失、owner 非同一 canonical source、
//   frozen provenance/身份/metadata 非法或编码失败时不发布任一 digest。
function automatic rdma_status rdma_cmq_compute_item_digests(
  input rdma_cmq_command_desc command,
  input string command_body_schema_tag,
  input byte unsigned command_body_field_bytes[],
  input rdma_cmq_ticket ticket,
  input rdma_cmq_recovery_owner recovery_owner,
  input rdma_function_identity function_identity,
  input rdma_dma_request_context dma_context,
  input rdma_hw_image sqe_image,
  input rdma_dma_mapping dependency_mapping,
  input longint unsigned dependency_offset,
  input rdma_hw_image dependency_image,
  output rdma_cmq_journal_digest_t image_digest,
  output rdma_cmq_journal_digest_t authority_digest
);
  rdma_cmq_canonical_writer image_writer;
  rdma_cmq_canonical_writer authority_writer;
  byte unsigned image_bytes[];
  byte unsigned authority_bytes[];
  rdma_status status;
  longint unsigned admission_attempt_id;

  image_digest = '0;
  authority_digest = '0;
  if (command == null || ticket == null || recovery_owner == null ||
      function_identity == null || dma_context == null || sqe_image == null ||
      dependency_mapping == null || dependency_image == null ||
      command.recovery_owner != recovery_owner ||
      !rdma_cmq_identity_shape_valid(function_identity) ||
      !rdma_cmq_frozen_owner_shape_valid(recovery_owner) ||
      !rdma_cmq_ticket_shape_valid(ticket) ||
      !rdma_cmq_image_shape_valid(sqe_image) ||
      !rdma_cmq_image_shape_valid(dependency_image))
    return rdma_cmq_direct_status(
      RDMA_SC_INVALID_ARGUMENT,
      "CMQ item digest source graph is null, malformed or non-canonical"
    );

  admission_attempt_id = recovery_owner.is_legacy_unmigrated() ? 0 :
                         recovery_owner.admission_attempt_id;
  status = command.validate_for_journal(
    function_identity, admission_attempt_id
  );
  if (status == null || !status.ok())
    return (status == null) ? rdma_cmq_direct_status(
      RDMA_SC_INVALID_STATE,
      "CMQ item command journal validation returned null"
    ) : status;
  if (!recovery_owner.is_legacy_unmigrated() &&
      !recovery_owner.function_identity.same_incarnation(function_identity))
    return rdma_cmq_direct_status(
      RDMA_SC_INVALID_ARGUMENT,
      "CMQ item recovery owner Function incarnation does not match"
    );
  if (command.function_h.function_uid != function_identity.function_uid ||
      command.function_h.object_id != function_identity.global_function_id ||
      command.function_h.generation != function_identity.generation ||
      ticket.function_h.function_uid != function_identity.function_uid ||
      ticket.function_h.object_id != function_identity.global_function_id ||
      ticket.function_h.generation != function_identity.generation ||
      dma_context.function_h == null ||
      dma_context.function_h.function_uid != function_identity.function_uid ||
      dma_context.function_h.object_id != function_identity.global_function_id ||
      dma_context.function_h.generation != function_identity.generation ||
      dependency_mapping.function_h == null ||
      dependency_mapping.function_h.function_uid !=
        function_identity.function_uid ||
      dependency_mapping.function_h.object_id !=
        function_identity.global_function_id ||
      dependency_mapping.function_h.generation !=
        function_identity.generation ||
      sqe_image.function_generation != function_identity.generation ||
      dependency_image.function_generation != function_identity.generation)
    return rdma_cmq_direct_status(
      RDMA_SC_STALE_GENERATION,
      "CMQ item digest Function authority projections disagree"
    );

  image_writer = new();
  if (!rdma_cmq_append_domain_tag(image_writer, "CMQ-IMAGE-V1") ||
      !rdma_cmq_append_image_v1(image_writer, sqe_image, 1'b0) ||
      !rdma_cmq_append_image_v1(
        image_writer, dependency_image, 1'b0
      ))
    return rdma_cmq_direct_status(
      RDMA_SC_INVALID_ARGUMENT,
      "CMQ item image domain canonicalization failed"
    );

  authority_writer = new();
  if (!rdma_cmq_append_domain_tag(authority_writer, "CMQ-AUTH-V1") ||
      !rdma_cmq_append_command_v1(
        authority_writer, command, command_body_schema_tag,
        command_body_field_bytes
      ) || !rdma_cmq_append_ticket_v1(authority_writer, ticket) ||
      !rdma_cmq_append_recovery_owner_v1(
        authority_writer, recovery_owner
      ) || !rdma_cmq_append_function_identity_v1(
        authority_writer, function_identity, 1'b0
      ) || !rdma_cmq_append_dma_context_v1(
        authority_writer, dma_context
      ) || !rdma_cmq_append_dma_mapping_public_v1(
        authority_writer, dependency_mapping
      ) || !authority_writer.append_u64(dependency_offset))
    return rdma_cmq_direct_status(
      RDMA_SC_INVALID_ARGUMENT,
      "CMQ item authority domain canonicalization failed"
    );

  image_writer.snapshot(image_bytes);
  authority_writer.snapshot(authority_bytes);
  image_digest = rdma_cmq_digest_bytes(image_bytes);
  authority_digest = rdma_cmq_digest_bytes(authority_bytes);
  return rdma_cmq_direct_status(RDMA_SC_OK);
endfunction

// 功能：计算跨 record/recovery request 共用的 CMQ-BATCH-V1 authority digest。
// 输入/输出及副作用：读取 Function、binding、CMQ、doorbell、sequence 与有序
//   item digest tuple；成功发布 batch_digest，并只使用 detached binding snapshot。
// 失败/边界：输出先清零；空/不等长 tuple、无效 snapshot/identity/image/sequence
//   或 canonicalization 失败时不发布 partial digest。
function automatic rdma_status rdma_cmq_compute_batch_digest(
  input rdma_function_identity function_identity,
  input rdma_function_binding binding,
  input rdma_handle cmq_h,
  input rdma_hw_image doorbell_image,
  input int unsigned final_pi,
  input bit final_polarity,
  input longint unsigned start_sequence,
  input longint unsigned end_sequence,
  input int unsigned request_indices[$],
  input rdma_cmq_journal_digest_t image_digests[$],
  input rdma_cmq_journal_digest_t authority_digests[$],
  output rdma_cmq_journal_digest_t batch_digest
);
  rdma_function_binding binding_snapshot;
  rdma_function_identity binding_identity;
  rdma_cmq_canonical_writer writer;
  byte unsigned canonical_bytes[];
  rdma_status status;

  batch_digest = '0;
  if (!rdma_cmq_identity_shape_valid(function_identity) || binding == null ||
      cmq_h == null || doorbell_image == null ||
      request_indices.size() == 0 ||
      request_indices.size() != image_digests.size() ||
      request_indices.size() != authority_digests.size() ||
      start_sequence >= end_sequence ||
      !rdma_cmq_direct_handle_type_supported(cmq_h) ||
      cmq_h.kind != RDMA_RESOURCE_CMQ ||
      cmq_h.function_uid != function_identity.function_uid ||
      cmq_h.generation != function_identity.generation ||
      !rdma_cmq_image_shape_valid(doorbell_image) ||
      doorbell_image.image_kind != RDMA_IMAGE_DOORBELL ||
      doorbell_image.function_generation != function_identity.generation)
    return rdma_cmq_direct_status(
      RDMA_SC_INVALID_ARGUMENT,
      "CMQ batch digest projection is incomplete or inconsistent"
    );

  status = binding.snapshot_complete_nonfatal(binding_snapshot);
  if (status == null || !status.ok() || binding_snapshot == null)
    return (status == null) ? rdma_cmq_direct_status(
      RDMA_SC_INVALID_STATE,
      "CMQ batch binding snapshot returned null status"
    ) : status;
  status = binding_snapshot.snapshot_identity_nonfatal(binding_identity);
  if (status == null || !status.ok() || binding_identity == null)
    return (status == null) ? rdma_cmq_direct_status(
      RDMA_SC_INVALID_STATE,
      "CMQ batch binding identity snapshot returned null status"
    ) : status;
  if (!binding_identity.same_incarnation(function_identity))
    return rdma_cmq_direct_status(
      RDMA_SC_INVALID_ARGUMENT,
      "CMQ batch binding and Function identity disagree"
    );

  writer = new();
  if (!rdma_cmq_append_domain_tag(writer, "CMQ-BATCH-V1") ||
      !rdma_cmq_append_function_identity_v1(
        writer, function_identity, 1'b0
      ) || !rdma_cmq_append_function_binding_v1(
        writer, binding_snapshot
      ) || !rdma_cmq_append_handle_v1(writer, cmq_h, 1'b0) ||
      !rdma_cmq_append_image_v1(writer, doorbell_image, 1'b0) ||
      !writer.append_u32(final_pi) ||
      !writer.append_u8({7'b0, final_polarity}) ||
      !writer.append_u64(start_sequence) ||
      !writer.append_u64(end_sequence) ||
      !writer.append_u32(request_indices.size()))
    return rdma_cmq_direct_status(
      RDMA_SC_INVALID_ARGUMENT,
      "CMQ batch fixed projection canonicalization failed"
    );
  foreach (request_indices[i]) begin
    if (!writer.append_u32(request_indices[i]) ||
        !writer.append_digest(image_digests[i]) ||
        !writer.append_digest(authority_digests[i]))
      return rdma_cmq_direct_status(
        RDMA_SC_INVALID_ARGUMENT,
        "CMQ batch item tuple canonicalization failed"
      );
  end

  writer.snapshot(canonical_bytes);
  batch_digest = rdma_cmq_digest_bytes(canonical_bytes);
  return rdma_cmq_direct_status(RDMA_SC_OK);
endfunction

// 功能：计算 CMQ-RESET-PROOF-V1 的稳定 isolation tuple digest。
// 输入/输出及副作用：读取 proof/batch/attempt/engine identity、isolated Function、
//   batch digest 与有序四字段 item tuple；成功发布 proof_digest。
// 失败/边界：输出先清零；任一 ID/键为零空、tuple 空/不等长、identity/owner
//   非法或编码失败时拒绝；replacement/state/release 不在本接口输入中。
function automatic rdma_status rdma_cmq_compute_reset_proof_digest(
  input string proof_key,
  input longint unsigned proof_id,
  input string batch_key,
  input longint unsigned batch_id,
  input longint unsigned attempt_id,
  input longint unsigned engine_instance_id,
  input longint unsigned engine_incarnation,
  input rdma_function_identity isolated_identity,
  input rdma_cmq_journal_digest_t batch_digest,
  input int unsigned request_indices[$],
  input rdma_cmq_journal_digest_t image_digests[$],
  input rdma_cmq_journal_digest_t authority_digests[$],
  input rdma_cmq_recovery_owner recovery_owners[$],
  output rdma_cmq_journal_digest_t proof_digest
);
  rdma_cmq_canonical_writer writer;
  byte unsigned canonical_bytes[];

  proof_digest = '0;
  if (proof_key.len() == 0 || batch_key.len() == 0 || proof_id == 0 ||
      batch_id == 0 || attempt_id == 0 || engine_instance_id == 0 ||
      engine_incarnation == 0 || batch_digest == '0 ||
      !rdma_cmq_identity_shape_valid(isolated_identity) ||
      request_indices.size() == 0 ||
      request_indices.size() != image_digests.size() ||
      request_indices.size() != authority_digests.size() ||
      request_indices.size() != recovery_owners.size())
    return rdma_cmq_direct_status(
      RDMA_SC_INVALID_ARGUMENT,
      "CMQ reset proof fixed fields or item tuple are invalid"
    );
  foreach (recovery_owners[i]) begin
    if (!rdma_cmq_frozen_owner_shape_valid(recovery_owners[i]) ||
        (!recovery_owners[i].is_legacy_unmigrated() &&
         !recovery_owners[i].function_identity.same_incarnation(
           isolated_identity
         )))
      return rdma_cmq_direct_status(
        RDMA_SC_INVALID_ARGUMENT,
        "CMQ reset proof recovery owner is invalid"
      );
  end

  writer = new();
  if (!rdma_cmq_append_domain_tag(writer, "CMQ-RESET-PROOF-V1") ||
      !writer.append_string(proof_key) || !writer.append_u64(proof_id) ||
      !writer.append_string(batch_key) || !writer.append_u64(batch_id) ||
      !writer.append_u64(attempt_id) ||
      !writer.append_u64(engine_instance_id) ||
      !writer.append_u64(engine_incarnation) ||
      !rdma_cmq_append_function_identity_v1(
        writer, isolated_identity, 1'b0
      ) || !writer.append_digest(batch_digest) ||
      !writer.append_u32(request_indices.size()))
    return rdma_cmq_direct_status(
      RDMA_SC_INVALID_ARGUMENT,
      "CMQ reset proof fixed projection canonicalization failed"
    );
  foreach (request_indices[i]) begin
    if (!writer.append_u32(request_indices[i]) ||
        !writer.append_digest(image_digests[i]) ||
        !writer.append_digest(authority_digests[i]) ||
        !rdma_cmq_append_recovery_owner_v1(writer, recovery_owners[i]))
      return rdma_cmq_direct_status(
        RDMA_SC_INVALID_ARGUMENT,
        "CMQ reset proof item tuple canonicalization failed"
      );
  end

  writer.snapshot(canonical_bytes);
  proof_digest = rdma_cmq_digest_bytes(canonical_bytes);
  return rdma_cmq_direct_status(RDMA_SC_OK);
endfunction

// 功能：判断 submission state 是否为 Task 9 冻结的九个有效编码之一。
// 输入/输出及副作用：state 为只读输入；返回 bit，不更新 journal。
// 失败/边界：任何 X/Z 或 9..15 spare 编码返回 0。
function automatic bit rdma_cmq_submission_state_valid(
  input rdma_cmq_submission_state_e state
);
  if ($isunknown(state))
    return 1'b0;
  return state inside {
    RDMA_CMQ_SUBMISSION_STAGED,
    RDMA_CMQ_SUBMISSION_PENDING_EFFECT,
    RDMA_CMQ_SUBMISSION_HOST_VISIBLE_NOT_PUBLISHED,
    RDMA_CMQ_SUBMISSION_PUBLISH_AMBIGUOUS,
    RDMA_CMQ_SUBMISSION_PUBLISH_CONFIRMED,
    RDMA_CMQ_SUBMISSION_COMPLETED,
    RDMA_CMQ_SUBMISSION_TIMED_OUT_QUARANTINED,
    RDMA_CMQ_SUBMISSION_LATE_COMPLETED,
    RDMA_CMQ_SUBMISSION_RESET_QUARANTINED
  };
endfunction

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

// 功能：从 item lifetime states 保守归约 batch 的诊断 aggregate state。
// 输入/输出及副作用：items 为输入，state 为输出；成功时一次性发布归约结果。
// 失败/边界：空/null item、X/Z/spare state 或 pre-MMIO 与 published 混合时
//   返回非 OK 且保持 caller 预置 state 不变；不授权任何状态迁移。
function automatic rdma_status rdma_cmq_reduce_batch_state(
  input rdma_cmq_batch_submission_item_record items[$],
  output rdma_cmq_submission_state_e state
);
  bit has_staged;
  bit has_pending_effect;
  bit has_host_visible;
  bit has_ambiguous;
  bit has_published;
  bit has_completed;
  bit has_timeout;
  bit has_late;
  bit has_reset;
  bit has_pre_mmio;
  bit has_post_mmio;
  rdma_cmq_submission_state_e candidate;

  if (items.size() == 0)
    return rdma_cmq_direct_status(
      RDMA_SC_INVALID_ARGUMENT, "CMQ batch reducer item queue is empty"
    );
  foreach (items[i]) begin
    if (items[i] == null || !rdma_cmq_submission_state_valid(items[i].state))
      return rdma_cmq_direct_status(
        RDMA_SC_INVALID_ARGUMENT,
        "CMQ batch reducer encountered null or invalid item state"
      );
    case (items[i].state)
      RDMA_CMQ_SUBMISSION_STAGED: has_staged = 1'b1;
      RDMA_CMQ_SUBMISSION_PENDING_EFFECT: has_pending_effect = 1'b1;
      RDMA_CMQ_SUBMISSION_HOST_VISIBLE_NOT_PUBLISHED:
        has_host_visible = 1'b1;
      RDMA_CMQ_SUBMISSION_PUBLISH_AMBIGUOUS: has_ambiguous = 1'b1;
      RDMA_CMQ_SUBMISSION_PUBLISH_CONFIRMED: has_published = 1'b1;
      RDMA_CMQ_SUBMISSION_COMPLETED: has_completed = 1'b1;
      RDMA_CMQ_SUBMISSION_TIMED_OUT_QUARANTINED: has_timeout = 1'b1;
      RDMA_CMQ_SUBMISSION_LATE_COMPLETED: has_late = 1'b1;
      RDMA_CMQ_SUBMISSION_RESET_QUARANTINED: has_reset = 1'b1;
      default: return rdma_cmq_direct_status(
        RDMA_SC_INVALID_ARGUMENT, "CMQ batch reducer state is unsupported"
      );
    endcase
  end

  has_pre_mmio = has_staged || has_pending_effect || has_host_visible;
  has_post_mmio = has_ambiguous || has_published || has_completed ||
                  has_timeout || has_late || has_reset;
  if (has_pre_mmio && has_post_mmio)
    return rdma_cmq_direct_status(
      RDMA_SC_INVALID_STATE,
      "CMQ batch mixes pre-MMIO and published item states"
    );

  if (has_reset)
    candidate = RDMA_CMQ_SUBMISSION_RESET_QUARANTINED;
  else if (has_host_visible)
    candidate = RDMA_CMQ_SUBMISSION_HOST_VISIBLE_NOT_PUBLISHED;
  else if (has_ambiguous)
    candidate = RDMA_CMQ_SUBMISSION_PUBLISH_AMBIGUOUS;
  else if (has_timeout)
    candidate = RDMA_CMQ_SUBMISSION_TIMED_OUT_QUARANTINED;
  else if (has_pending_effect)
    candidate = RDMA_CMQ_SUBMISSION_PENDING_EFFECT;
  else if (has_staged)
    candidate = RDMA_CMQ_SUBMISSION_STAGED;
  else if (has_published)
    candidate = RDMA_CMQ_SUBMISSION_PUBLISH_CONFIRMED;
  else if (has_late)
    candidate = RDMA_CMQ_SUBMISSION_LATE_COMPLETED;
  else if (has_completed)
    candidate = RDMA_CMQ_SUBMISSION_COMPLETED;
  else
    return rdma_cmq_direct_status(
      RDMA_SC_INVALID_STATE, "CMQ batch reducer found no state"
    );

  state = candidate;
  return rdma_cmq_direct_status(RDMA_SC_OK);
endfunction

// 功能：把 current attempt evidence 折入跨 attempt cumulative high-water。
// 输入/输出及副作用：prior/current 为输入，cumulative 为输出；成功一次性赋值。
// 失败/边界：prior PRE、任一 X/Z/spare 编码返回 0 且不改 caller 预置输出；
//   UNOBSERVED/PRE current 不会擦除 prior concrete evidence。
function automatic bit rdma_cmq_fold_attempt_effect(
  input rdma_submission_effect_e prior_cumulative,
  input rdma_submission_effect_e current_attempt,
  output rdma_submission_effect_e cumulative
);
  rdma_submission_effect_e candidate;

  if (!rdma_cmq_submission_effect_valid(prior_cumulative) ||
      !rdma_cmq_submission_effect_valid(current_attempt) ||
      prior_cumulative == RDMA_SUBMIT_EFFECT_PRE_SUBMIT_REJECTED)
    return 1'b0;

  if (rdma_cmq_concrete_submission_effect(prior_cumulative)) begin
    if (rdma_cmq_concrete_submission_effect(current_attempt))
      candidate = (current_attempt > prior_cumulative) ? current_attempt :
                  prior_cumulative;
    else
      candidate = prior_cumulative;
  end
  else begin
    if (rdma_cmq_concrete_submission_effect(current_attempt))
      candidate = current_attempt;
    else
      candidate = RDMA_SUBMIT_EFFECT_UNOBSERVED;
  end
  cumulative = candidate;
  return 1'b1;
endfunction

// 功能：按冻结 lifetime state/phase/effect/proof 表推导 conservative recovery bit。
// 输入/输出及副作用：五个证据输入只读，recovery_required 成功时一次性更新。
// 失败/边界：X/Z/spare 或不可能的 state/phase/effect 组合返回非 OK 且保持
//   预置输出；UNOBSERVED 接受未观测或既有 Host/MMIO 累积证据并始终需要
//   reconcile，只有可靠终态/确认 reset 才清零。
function automatic rdma_status rdma_cmq_classify_recovery_required(
  input rdma_cmq_submission_state_e state,
  input rdma_cmq_completion_phase_e completion_phase,
  input rdma_submission_effect_e submission_effect,
  input bit reset_isolation_confirmed,
  input bit legacy_unmigrated,
  output bit recovery_required
);
  bit candidate;
  bit combination_valid;

  if (!rdma_cmq_submission_state_valid(state) ||
      !rdma_cmq_completion_phase_valid(completion_phase) ||
      !rdma_cmq_submission_effect_valid(submission_effect))
    return rdma_cmq_direct_status(
      RDMA_SC_INVALID_ARGUMENT,
      "CMQ recovery classifier received unknown or spare evidence"
    );

  if (completion_phase == RDMA_CMQ_COMPLETION_UNOBSERVED) begin
    candidate = 1'b1;
    combination_valid = submission_effect !=
                          RDMA_SUBMIT_EFFECT_PRE_SUBMIT_REJECTED;
  end
  else begin
    combination_valid = 1'b0;
    candidate = 1'b1;
    case (state)
      RDMA_CMQ_SUBMISSION_STAGED: begin
        combination_valid = completion_phase == RDMA_CMQ_COMPLETION_NONE &&
                            submission_effect ==
                              RDMA_SUBMIT_EFFECT_UNOBSERVED &&
                            !reset_isolation_confirmed;
      end
      RDMA_CMQ_SUBMISSION_PENDING_EFFECT: begin
        combination_valid = completion_phase == RDMA_CMQ_COMPLETION_NONE &&
                            rdma_cmq_concrete_submission_effect(
                              submission_effect
                            ) && !reset_isolation_confirmed;
      end
      RDMA_CMQ_SUBMISSION_HOST_VISIBLE_NOT_PUBLISHED: begin
        combination_valid = completion_phase == RDMA_CMQ_COMPLETION_NONE &&
                            submission_effect inside {
                              RDMA_SUBMIT_EFFECT_HOST_MEMORY_MAYBE_VISIBLE,
                              RDMA_SUBMIT_EFFECT_HOST_MEMORY_WRITTEN,
                              RDMA_SUBMIT_EFFECT_HOST_MEMORY_ORDERED
                            } && !reset_isolation_confirmed;
      end
      RDMA_CMQ_SUBMISSION_PUBLISH_AMBIGUOUS: begin
        combination_valid = completion_phase == RDMA_CMQ_COMPLETION_PENDING &&
                            submission_effect inside {
                              RDMA_SUBMIT_EFFECT_MMIO_MAYBE_VISIBLE,
                              RDMA_SUBMIT_EFFECT_MMIO_VISIBLE
                            } && !reset_isolation_confirmed;
      end
      RDMA_CMQ_SUBMISSION_PUBLISH_CONFIRMED: begin
        combination_valid = completion_phase == RDMA_CMQ_COMPLETION_PENDING &&
                            submission_effect ==
                              RDMA_SUBMIT_EFFECT_MMIO_VISIBLE &&
                            !reset_isolation_confirmed;
      end
      RDMA_CMQ_SUBMISSION_COMPLETED: begin
        combination_valid = completion_phase == RDMA_CMQ_COMPLETION_TERMINAL &&
                            rdma_cmq_concrete_submission_effect(
                              submission_effect
                            ) && !reset_isolation_confirmed;
        candidate = 1'b0;
      end
      RDMA_CMQ_SUBMISSION_TIMED_OUT_QUARANTINED: begin
        combination_valid = completion_phase == RDMA_CMQ_COMPLETION_TIMEOUT &&
                            rdma_cmq_concrete_submission_effect(
                              submission_effect
                            ) && !reset_isolation_confirmed;
      end
      RDMA_CMQ_SUBMISSION_LATE_COMPLETED: begin
        combination_valid = completion_phase ==
                              RDMA_CMQ_COMPLETION_DIAGNOSTIC_ONLY &&
                            rdma_cmq_concrete_submission_effect(
                              submission_effect
                            ) && !reset_isolation_confirmed;
        candidate = 1'b0;
      end
      RDMA_CMQ_SUBMISSION_RESET_QUARANTINED: begin
        combination_valid = completion_phase ==
                              RDMA_CMQ_COMPLETION_RESET_CANCELLED &&
                            rdma_cmq_concrete_submission_effect(
                              submission_effect
                            );
        candidate = !reset_isolation_confirmed;
      end
      default: combination_valid = 1'b0;
    endcase
  end

  // legacy_unmigrated 不授予自动恢复能力，但在该纯分类器中与 concrete owner
  // 共用 unresolved/resolved bit；真正 action authority 由 owner/proof 再校验。
  if (!combination_valid)
    return rdma_cmq_direct_status(
      RDMA_SC_INVALID_STATE,
      "CMQ recovery classifier evidence combination is impossible"
    );
  recovery_required = candidate;
  return rdma_cmq_direct_status(RDMA_SC_OK);
endfunction
