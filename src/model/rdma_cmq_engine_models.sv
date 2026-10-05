// 目录/层次：model 层 CMQ 共享值模型。
// 职责：定义 CMQ opcode、recovery owner、command、slot、ticket、completion、
// diagnostic 和 runtime 描述，并在进入 engine/codec 前统一校验句柄归属与代际。
// 主要依赖：rdma_status、rdma_handle/function_handle、rdma_hw_image/model 以及
// rdma_submission_evidence 的公共类型；不依赖具体 RDMA codec body。
// 所有权与生命周期：值对象通过构造或 do_copy 拥有嵌套快照；句柄仅表示
// 外部资源身份，不接管对应硬件/Host-memory 生命周期。

typedef enum bit [2:0] {
  RDMA_CMQ_ENGINE_UNCONFIGURED,
  RDMA_CMQ_ENGINE_PREPARED,
  RDMA_CMQ_ENGINE_ACTIVE,
  RDMA_CMQ_ENGINE_QUIESCED,
  RDMA_CMQ_ENGINE_POISONED
} rdma_cmq_engine_state_e;

typedef enum bit [1:0] {
  RDMA_CMQ_DIAG_LATE_COMPLETION,
  RDMA_CMQ_DIAG_MALFORMED_CQE,
  RDMA_CMQ_DIAG_UNKNOWN_CQE,
  RDMA_CMQ_DIAG_POISON
} rdma_cmq_diagnostic_kind_e;

// 设计说明：workflow 是恢复权限的业务域，不允许由 opcode 或完成状态反推。
// 四态基类型保留 X/Z，所有校验入口都必须在 case/index 前显式拒绝未知值。
typedef enum logic [2:0] {
  RDMA_CMQ_WORKFLOW_INVALID           = 3'd0,
  RDMA_CMQ_WORKFLOW_LEGACY_UNMIGRATED = 3'd1,
  RDMA_CMQ_WORKFLOW_MR                = 3'd2,
  RDMA_CMQ_WORKFLOW_QUEUE             = 3'd3,
  RDMA_CMQ_WORKFLOW_QP                = 3'd4
} rdma_cmq_recovery_workflow_e;

// 设计说明：allowed_actions 的位号与该枚举编码一一对应；编码 0 保留为
// INVALID，编码 3 为 spare，二者以及任何 X/Z 都不得参与 mask 索引。
typedef enum logic [1:0] {
  RDMA_CMQ_RECOVERY_INVALID                 = 2'd0,
  RDMA_CMQ_RECOVERY_RETRY_PUBLISH           = 2'd1,
  RDMA_CMQ_RECOVERY_CONFIRM_RESET_ISOLATION = 2'd2
} rdma_cmq_submission_recovery_action_e;

// 功能：判断 CMQ profile/variant 文本是否含作为组合 key 分隔符的竖线。
// 输入/输出及副作用：只读扫描 value 的 getc() 字节；命中 8'h7c 返回 1，
// 否则返回 0，不修改输入或全局状态。
// 失败/边界：空字符串没有可扫描字节并返回 0；函数不解析 UTF-8 码点。
function automatic bit rdma_cmq_string_has_separator(string value);
  for (int unsigned i = 0; i < value.len(); i++) begin
    if (value.getc(i) == 8'h7c)
      return 1'b1;
  end
  return 1'b0;
endfunction

// 功能：校验 CMQ 值中的 Function handle 是否具有 Function kind 和非零代际。
// 输入/输出及副作用：function_h 为非拥有输入，label 仅加入诊断文本；
// 返回新 rdma_status，不修改 handle。
// 失败/边界：null 或非 RDMA_RESOURCE_FUNCTION 返回 INVALID_ARGUMENT；
// generation==0 返回 STALE_GENERATION，其余返回 OK。
function automatic rdma_status rdma_cmq_function_status(
  rdma_function_handle function_h,
  string label
);
  if (function_h == null || function_h.kind != RDMA_RESOURCE_FUNCTION)
    return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                             {label, " Function handle is invalid"});
  if (function_h.generation == 0)
    return rdma_status::make(RDMA_SC_STALE_GENERATION,
                             {label, " Function generation is zero"});
  return rdma_status::success();
endfunction

// 功能：校验 CMQ handle 的 kind，并复用通用 owner 契约确认其归属指定 Function。
// 输入/输出及副作用：cmq_h/function_h 为非拥有输入，label 用于拒绝信息；
// 返回 owner 校验结果，不修改任一句柄。
// 失败/边界：cmq_h 为 null/非 CMQ 时返回 INVALID_ARGUMENT；Function UID
// 或 generation 不匹配时透传 rdma_handle_owner_status() 的错误。
function automatic rdma_status rdma_cmq_handle_status(
  rdma_handle cmq_h,
  rdma_function_handle function_h,
  string label
);
  rdma_status status;

  if (cmq_h == null || cmq_h.kind != RDMA_RESOURCE_CMQ)
    return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                             {label, " CMQ handle is invalid"});
  status = rdma_handle_owner_status(cmq_h, function_h);
  if (!status.ok())
    return status;
  return rdma_status::success();
endfunction

// 功能：为传统 UVM do_copy 路径深拷贝可选 hardware image。
// 输入/输出及副作用：source 为只读源，label 标识调用者；null 返回 null，
// 非空时返回 source.clone() 的 rdma_hw_image 句柄，调用方拥有该快照。
// 失败/边界：factory clone 返回 null 或不能 cast 为 rdma_hw_image 时发布
// RDMA_COPY_TYPE fatal；该 helper 不是 nonfatal snapshot 边界。
function automatic rdma_hw_image rdma_cmq_clone_image_value(
  rdma_hw_image source,
  string label
);
  uvm_object cloned_object;
  rdma_hw_image result;

  if (source == null)
    return null;
  cloned_object = source.clone();
  if (cloned_object == null || !$cast(result, cloned_object))
    `uvm_fatal("RDMA_COPY_TYPE", {label, " image clone mismatch"})
  return result;
endfunction

// 功能：为传统 UVM do_copy 路径克隆可选 polymorphic CMQ body。
// 输入/输出及副作用：source 为只读源，label 只用于诊断；null 返回 null，
// 非空返回新 rdma_hw_model 快照，不改写源 body。
// 失败/边界：factory clone 失败或动态类型不兼容时发布 RDMA_COPY_TYPE
// fatal；需要 profile-aware/nonfatal 复制的生产路径不得调用本 helper。
function automatic rdma_hw_model rdma_cmq_clone_hw_model_value(
  rdma_hw_model source,
  string label
);
  uvm_object cloned_object;
  rdma_hw_model result;

  if (source == null)
    return null;
  cloned_object = source.clone();
  if (cloned_object == null || !$cast(result, cloned_object))
    `uvm_fatal("RDMA_COPY_TYPE", {label, " hardware model clone mismatch"})
  return result;
endfunction

// 功能：为传统 completion do_copy 克隆未知动态类型的 decoded payload。
// 输入/输出及副作用：source 为只读源，label 用于 fatal 文本；null 返回 null，
// 非空返回 clone 产生的新 uvm_object。
// 失败/边界：clone 返回 null 时发布 RDMA_COPY_TYPE fatal；因无 profile 参数和
// status 返回值，本 helper 不能作为生产观测快照边界。
function automatic uvm_object rdma_cmq_clone_object_value(
  uvm_object source,
  string label
);
  uvm_object result;

  if (source == null)
    return null;
  result = source.clone();
  if (result == null)
    `uvm_fatal("RDMA_COPY_TYPE", {label, " object clone returned null"})
  return result;
endfunction

// 功能：逐字段复制 rdma_status，避免状态值与源节点共享句柄。
// 输入/输出及副作用：source 为只读输入；非空时 factory-create 新 status 并
// 复制 category/code、hardware/source identity、severity/retryable 和 message。
// 失败/边界：null source 返回 null；该 legacy helper 依赖 factory 创建成功，
// 不提供 nonfatal factory-fault 降级语义。
function automatic rdma_status rdma_cmq_clone_status_value(
  rdma_status source
);
  rdma_status result;

  if (source == null)
    return null;
  result = rdma_status::type_id::create("status");
  result.category = source.category;
  result.code = source.code;
  result.hardware_code = source.hardware_code;
  result.hardware_code_valid = source.hardware_code_valid;
  result.source_engine = source.source_engine;
  result.function_uid = source.function_uid;
  result.generation = source.generation;
  result.resource_id = source.resource_id;
  result.command_id = source.command_id;
  result.wr_id = source.wr_id;
  result.severity = source.severity;
  result.retryable = source.retryable;
  result.message = source.message;
  return result;
endfunction

// 设计说明：opcode key 把 profile、硬件 opcode 与 variant 组成稳定注册键，
// 避免 codec 选择依赖 polymorphic body 的 factory 类型名或对象身份。
class rdma_cmq_opcode_key extends uvm_object;
  `uvm_object_utils(rdma_cmq_opcode_key)

  string profile_name;
  bit [31:0] opcode;
  string variant;

  // 功能：构造一个尚未标识 profile/opcode variant 的 CMQ opcode key。
  // 输入/输出及副作用：name 设置 UVM 实例名；将 profile_name/variant 置空、
  // opcode 置零，不持有外部对象。
  // 失败/边界：默认对象故意无法通过 validate()，调用方必须填充两个文本字段。
  function new(string name = "rdma_cmq_opcode_key");
    super.new(name);
    profile_name = "";
    opcode = '0;
    variant = "";
  endfunction

  // 功能：将 rhs 中 rdma_cmq_opcode_key 的值字段复制到当前对象，建立与源对象隔离的快照。
  // 输入/输出及副作用：rhs 为只读源；覆盖当前 profile_name、opcode 和 variant，
  // 三者均为值拷贝，不产生嵌套句柄。
  // 失败/边界：do_copy 在源对象为空、clone/cast 失败或类型不匹配时触发 UVM fatal（CMQ opcode key copy mismatch），不保留部分有效快照。
  virtual function void do_copy(uvm_object rhs);
    rdma_cmq_opcode_key rhs_key;

    super.do_copy(rhs);
    if (!$cast(rhs_key, rhs))
      `uvm_fatal("RDMA_COPY_TYPE", "CMQ opcode key copy mismatch")
    profile_name = rhs_key.profile_name;
    opcode = rhs_key.opcode;
    variant = rhs_key.variant;
  endfunction

  // 功能：验证 opcode key 可安全组成以“|”分隔的 profile/opcode/variant 索引。
  // 输入/输出及副作用：只读 profile_name 和 variant，返回独立 rdma_status；
  // 不规范化文本，不修改 opcode。
  // 失败/边界：任一文本为空或含“|”时返回 INVALID_ARGUMENT；opcode==0 本身合法。
  function rdma_status validate();
    if (profile_name.len() == 0)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "CMQ profile name is empty");
    if (variant.len() == 0)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "CMQ opcode variant is empty");
    if (rdma_cmq_string_has_separator(profile_name))
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "CMQ profile name contains '|'");
    if (rdma_cmq_string_has_separator(variant))
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "CMQ opcode variant contains '|'");
    return rdma_status::success();
  endfunction
endclass

// 功能：为 ticket/command 的传统 do_copy 克隆可选 opcode key。
// 输入/输出及副作用：source 为只读源，label 用于诊断；null 返回 null，
// 非空返回 factory clone 的新 rdma_cmq_opcode_key。
// 失败/边界：clone 返回 null 或错误 runtime type 时发布 RDMA_COPY_TYPE fatal；
// 函数不调用 validate()，因此可保留无效 fixture 的原始值。
function automatic rdma_cmq_opcode_key rdma_cmq_clone_opcode_key_value(
  rdma_cmq_opcode_key source,
  string label
);
  uvm_object cloned_object;
  rdma_cmq_opcode_key result;

  if (source == null)
    return null;
  cloned_object = source.clone();
  if (cloned_object == null || !$cast(result, cloned_object))
    `uvm_fatal("RDMA_COPY_TYPE", {label, " opcode key clone mismatch"})
  return result;
endfunction

// 设计说明：恢复 owner 把业务 workflow、资源 incarnation 和首次 admission
// attempt 冻结为一个值节点。legacy sentinel 只兼容旧调用方，永不授予自动恢复权限。
class rdma_cmq_recovery_owner extends uvm_object;
  `uvm_object_utils(rdma_cmq_recovery_owner)

  rdma_cmq_recovery_workflow_e workflow;
  rdma_handle resource_h;
  longint unsigned transaction_id;
  logic [2:0] allowed_actions;
  rdma_function_identity function_identity;
  longint unsigned admission_attempt_id;
  bit frozen;

  // 功能：构造 fail-closed 的 recovery owner，默认处于 INVALID、未冻结且无权限状态。
  // 输入/输出及副作用：name 传给 uvm_object；只初始化本对象拥有的值字段。
  // 失败/边界：默认对象不能通过 admission/frozen 校验，也不持有外部资源引用。
  function new(string name = "rdma_cmq_recovery_owner");
    super.new(name);
    workflow = RDMA_CMQ_WORKFLOW_INVALID;
    resource_h = null;
    transaction_id = 0;
    allowed_actions = '0;
    function_identity = null;
    admission_attempt_id = 0;
    frozen = 1'b0;
  endfunction

  // 功能：创建精确的 LEGACY_UNMIGRATED sentinel，供尚未迁移 owner 的命令 admission。
  // 输入/输出及副作用：无输入；返回直接构造的新对象，不经过 UVM factory。
  // 失败/边界：sentinel 不含资源、identity、transaction/attempt 或 action 权限。
  static function rdma_cmq_recovery_owner legacy_unmigrated();
    rdma_cmq_recovery_owner owner;

    owner = new("legacy_unmigrated_recovery_owner");
    owner.workflow = RDMA_CMQ_WORKFLOW_LEGACY_UNMIGRATED;
    return owner;
  endfunction

  // 功能：判断当前对象是否逐字段等于唯一合法的 legacy sentinel。
  // 输入/输出及副作用：只读全部 owner 字段并返回 bit，不修改对象或账本。
  // 失败/边界：mask/workflow 含 X/Z、任一引用或 ID 非空、frozen 置位均返回 0。
  function bit is_legacy_unmigrated();
    return workflow === RDMA_CMQ_WORKFLOW_LEGACY_UNMIGRATED &&
           resource_h == null && transaction_id == 0 &&
           allowed_actions === 3'b000 && function_identity == null &&
           admission_attempt_id == 0 && frozen == 1'b0;
  endfunction

  // 功能：校验具体 owner 的 workflow/resource/action 公共形状，供 admission 和冻结复验复用。
  // 输入/输出及副作用：只读 workflow、resource_h、transaction_id 和 allowed_actions；
  //   返回 detached rdma_status，不改变 owner。
  // 失败/边界：未知/spare workflow、空/无效资源、零事务、非法或空 action mask
  //   以及 MR/QUEUE/QP 与资源 kind 不匹配时返回 INVALID_ARGUMENT。
  protected function rdma_status validate_concrete_shape();
    if ($isunknown(workflow))
      return rdma_status::make(
        RDMA_SC_INVALID_ARGUMENT,
        "CMQ recovery workflow contains X/Z"
      );
    if (!(workflow inside {RDMA_CMQ_WORKFLOW_MR,
                           RDMA_CMQ_WORKFLOW_QUEUE,
                           RDMA_CMQ_WORKFLOW_QP}))
      return rdma_status::make(
        RDMA_SC_INVALID_ARGUMENT,
        "CMQ recovery workflow is invalid or unsupported"
      );
    if (resource_h == null)
      return rdma_status::make(
        RDMA_SC_INVALID_ARGUMENT,
        "CMQ recovery owner resource handle is null"
      );
    if (resource_h.function_uid == 0 || resource_h.generation == 0 ||
        resource_h.object_id == 0)
      return rdma_status::make(
        RDMA_SC_INVALID_ARGUMENT,
        "CMQ recovery owner resource identity is incomplete"
      );
    if (transaction_id == 0)
      return rdma_status::make(
        RDMA_SC_INVALID_ARGUMENT,
        "CMQ recovery owner transaction ID is zero"
      );
    if ($isunknown(allowed_actions) || allowed_actions[0] !== 1'b0 ||
        (allowed_actions & 3'b110) == 3'b000)
      return rdma_status::make(
        RDMA_SC_INVALID_ARGUMENT,
        "CMQ recovery owner action mask is invalid"
      );

    case (workflow)
      RDMA_CMQ_WORKFLOW_MR: begin
        if (resource_h.kind != RDMA_RESOURCE_MR)
          return rdma_status::make(
            RDMA_SC_INVALID_ARGUMENT,
            "MR recovery owner does not reference an MR"
          );
      end

      RDMA_CMQ_WORKFLOW_QUEUE: begin
        if (!(resource_h.kind inside {RDMA_RESOURCE_CQ,
                                      RDMA_RESOURCE_SRQ,
                                      RDMA_RESOURCE_CEQ,
                                      RDMA_RESOURCE_AEQ}))
          return rdma_status::make(
            RDMA_SC_INVALID_ARGUMENT,
            "queue recovery owner references a non-queue resource"
          );
      end

      RDMA_CMQ_WORKFLOW_QP: begin
        if (resource_h.kind != RDMA_RESOURCE_QP)
          return rdma_status::make(
            RDMA_SC_INVALID_ARGUMENT,
            "QP recovery owner does not reference a QP"
          );
      end

      default: begin
        return rdma_status::make(
          RDMA_SC_INVALID_ARGUMENT,
          "CMQ recovery workflow is not concrete"
        );
      end
    endcase

    return rdma_status::success();
  endfunction

  // 功能：校验 owner 是否可用于首次 admission，区分精确 legacy sentinel 与具体 owner。
  // 输入/输出及副作用：只读当前 owner；返回状态，不冻结或写入 provenance。
  // 失败/边界：具体 owner 已带 identity/attempt、已 frozen 或公共形状非法时拒绝；
  //   被篡改的 legacy 形状不会降级为具体 workflow。
  function rdma_status validate_for_admission();
    rdma_status status;

    if (is_legacy_unmigrated())
      return rdma_status::success();
    if (workflow === RDMA_CMQ_WORKFLOW_LEGACY_UNMIGRATED)
      return rdma_status::make(
        RDMA_SC_INVALID_ARGUMENT,
        "CMQ legacy recovery owner sentinel was modified"
      );

    status = validate_concrete_shape();
    if (status == null || !status.ok())
      return status;
    if (function_identity != null || admission_attempt_id != 0 || frozen)
      return rdma_status::make(
        RDMA_SC_INVALID_ARGUMENT,
        "CMQ admission owner already contains frozen provenance"
      );
    return rdma_status::success();
  endfunction

  // 功能：把有效具体 owner 绑定到 Function incarnation 和首次 admission attempt。
  // 输入/输出及副作用：identity 与 frozen_admission_attempt_id 为输入；成功时保存
  //   detached identity、记录不可变 attempt 并置 frozen。
  // 失败/边界：legacy/已冻结、零 attempt、无效 identity 或资源 UID/generation
  //   不匹配时原子失败，现有 owner 字段保持不变。
  function rdma_status freeze_for_journal(
    input rdma_function_identity identity,
    input longint unsigned frozen_admission_attempt_id
  );
    rdma_function_identity identity_snapshot;
    rdma_status status;

    if (is_legacy_unmigrated())
      return rdma_status::make(
        RDMA_SC_INVALID_ARGUMENT,
        "legacy recovery owner cannot be frozen"
      );
    if (frozen)
      return rdma_status::make(
        RDMA_SC_INVALID_STATE,
        "CMQ recovery owner is already frozen"
      );
    status = validate_for_admission();
    if (status == null || !status.ok())
      return status;
    if (frozen_admission_attempt_id == 0)
      return rdma_status::make(
        RDMA_SC_INVALID_ARGUMENT,
        "CMQ recovery admission attempt ID is zero"
      );
    if (identity == null)
      return rdma_status::make(
        RDMA_SC_INVALID_ARGUMENT,
        "CMQ recovery Function identity is null"
      );
    status = identity.validate();
    if (status == null || !status.ok())
      return (status == null) ? rdma_status::make(
        RDMA_SC_INVALID_STATE,
        "CMQ recovery Function identity validation returned null"
      ) : status;
    if (resource_h.function_uid != identity.function_uid)
      return rdma_status::make(
        RDMA_SC_INVALID_ARGUMENT,
        "CMQ recovery resource Function UID does not match identity"
      );
    if (resource_h.generation != identity.generation)
      return rdma_status::make(
        RDMA_SC_STALE_GENERATION,
        "CMQ recovery resource generation does not match identity"
      );

    identity_snapshot = new("recovery_function_identity");
    identity_snapshot.key = identity.key;
    identity_snapshot.global_function_id = identity.global_function_id;
    identity_snapshot.function_uid = identity.function_uid;
    identity_snapshot.generation = identity.generation;
    identity_snapshot.reset_epoch = identity.reset_epoch;
    function_identity = identity_snapshot;
    admission_attempt_id = frozen_admission_attempt_id;
    frozen = 1'b1;
    return rdma_status::success();
  endfunction

  // 功能：复验 journal 中具体 owner 的完整冻结值与期望 Function/首次 attempt。
  // 输入/输出及副作用：expected_identity、expected_admission_attempt_id 为输入；
  //   只读当前 frozen 值并返回状态。
  // 失败/边界：legacy、未冻结、空/非法 identity、资源或期望 incarnation/attempt
  //   不匹配时拒绝；generation 漂移返回 STALE_GENERATION。
  function rdma_status validate_frozen(
    input rdma_function_identity expected_identity,
    input longint unsigned expected_admission_attempt_id
  );
    rdma_status status;

    if (is_legacy_unmigrated() || !frozen)
      return rdma_status::make(
        RDMA_SC_INVALID_ARGUMENT,
        "CMQ recovery owner is not a concrete frozen value"
      );
    status = validate_concrete_shape();
    if (status == null || !status.ok())
      return status;
    if (function_identity == null)
      return rdma_status::make(
        RDMA_SC_INVALID_ARGUMENT,
        "frozen CMQ recovery owner has no Function identity"
      );
    status = function_identity.validate();
    if (status == null || !status.ok())
      return (status == null) ? rdma_status::make(
        RDMA_SC_INVALID_STATE,
        "frozen CMQ recovery identity validation returned null"
      ) : status;
    if (resource_h.function_uid != function_identity.function_uid)
      return rdma_status::make(
        RDMA_SC_INVALID_ARGUMENT,
        "frozen recovery resource Function UID drifted"
      );
    if (resource_h.generation != function_identity.generation)
      return rdma_status::make(
        RDMA_SC_STALE_GENERATION,
        "frozen recovery resource generation drifted"
      );
    if (expected_identity == null || expected_admission_attempt_id == 0)
      return rdma_status::make(
        RDMA_SC_INVALID_ARGUMENT,
        "expected recovery identity or admission attempt is invalid"
      );
    status = expected_identity.validate();
    if (status == null || !status.ok())
      return (status == null) ? rdma_status::make(
        RDMA_SC_INVALID_STATE,
        "expected recovery identity validation returned null"
      ) : status;
    if (!function_identity.same_incarnation(expected_identity))
      return rdma_status::make(
        RDMA_SC_INVALID_ARGUMENT,
        "frozen recovery Function incarnation does not match"
      );
    if (admission_attempt_id != expected_admission_attempt_id)
      return rdma_status::make(
        RDMA_SC_INVALID_ARGUMENT,
        "frozen recovery admission attempt does not match"
      );
    return rdma_status::success();
  endfunction

  // 功能：检查当前 owner 是否显式允许给定自动恢复 action。
  // 输入/输出及副作用：action 为输入；只读 allowed_actions 并返回 bit，不修改 owner。
  // 失败/边界：action/mask 含 X/Z、INVALID、spare 或对应位未置位时返回 0，
  //   且在完成这些检查前绝不使用 action 作为索引。
  function bit permits(input rdma_cmq_submission_recovery_action_e action);
    if ($isunknown(action) || $isunknown(allowed_actions))
      return 1'b0;
    case (action)
      RDMA_CMQ_RECOVERY_RETRY_PUBLISH,
      RDMA_CMQ_RECOVERY_CONFIRM_RESET_ISOLATION:
        return allowed_actions[action] === 1'b1;

      default:
        return 1'b0;
    endcase
  endfunction

  // 功能：把 rhs recovery owner 深复制为当前对象拥有的资源句柄和 Function identity。
  // 输入/输出及副作用：rhs 为输入；覆盖当前值字段，源对象保持不变。
  // 失败/边界：rhs 类型不匹配触发既有 UVM copy fatal；空嵌套值保持为空，
  //   本方法不作为生产 nonfatal snapshot 边界。
  virtual function void do_copy(uvm_object rhs);
    rdma_cmq_recovery_owner source;

    super.do_copy(rhs);
    if (!$cast(source, rhs))
      `uvm_fatal("RDMA_COPY_TYPE", "CMQ recovery owner copy mismatch")
    workflow = source.workflow;
    if (source.resource_h == null) begin
      resource_h = null;
    end
    else begin
      resource_h = new("recovery_resource_h");
      resource_h.kind = source.resource_h.kind;
      resource_h.function_uid = source.resource_h.function_uid;
      resource_h.object_id = source.resource_h.object_id;
      resource_h.generation = source.resource_h.generation;
    end
    transaction_id = source.transaction_id;
    allowed_actions = source.allowed_actions;
    if (source.function_identity == null) begin
      function_identity = null;
    end
    else begin
      function_identity = new("recovery_function_identity");
      function_identity.key = source.function_identity.key;
      function_identity.global_function_id =
        source.function_identity.global_function_id;
      function_identity.function_uid = source.function_identity.function_uid;
      function_identity.generation = source.function_identity.generation;
      function_identity.reset_epoch = source.function_identity.reset_epoch;
    end
    admission_attempt_id = source.admission_attempt_id;
    frozen = source.frozen;
  endfunction
endclass

// 设计说明：command descriptor 汇合 Function、opcode、body、timeout 与 recovery
// owner 的准入边界；journal 复验复用同一命令值但采用冻结 owner 规则。
class rdma_cmq_command_desc extends uvm_object;
  `uvm_object_utils(rdma_cmq_command_desc)

  rdma_function_handle function_h;
  rdma_cmq_opcode_key opcode_key;
  rdma_hw_model body;
  rdma_hw_image qpc_signature_source;
  bit vfid_override;
  bit [10:0] use_vfid;
  time timeout;
  rdma_cmq_recovery_owner recovery_owner;

  // 功能：构造未填充的 CMQ command，并安装精确 LEGACY_UNMIGRATED recovery sentinel。
  // 输入/输出及副作用：name 设置 UVM 实例名；将 Function/key/body/signature 置空，
  // VFID/timeout 置零，并拥有新建的 sentinel owner。
  // 失败/边界：默认 command 因缺少 Function、opcode、body 和 timeout 不可提交；
  // sentinel 仅允许旧准入流程，不授予自动恢复权限。
  function new(string name = "rdma_cmq_command_desc");
    super.new(name);
    function_h = null;
    opcode_key = null;
    body = null;
    qpc_signature_source = null;
    vfid_override = 1'b0;
    use_vfid = '0;
    timeout = 0;
    recovery_owner = rdma_cmq_recovery_owner::legacy_unmigrated();
  endfunction

  // 功能：为 UVM 兼容路径复制 command shell，并深拷贝所有嵌套值节点。
  // 输入/输出及副作用：rhs 为只读 command；覆盖当前 Function/key/body/image、
  // VFID/timeout 和 owner，非空 owner 由直接 new 的对象承载。
  // 失败/边界：rhs 类型错误或任一 legacy clone/cast 失败时发布 UVM fatal；
  // polymorphic body 无 profile/status 语义，因此生产 journal 不得以本方法作 nonfatal 边界。
  virtual function void do_copy(uvm_object rhs);
    rdma_cmq_command_desc rhs_command;

    super.do_copy(rhs);
    if (!$cast(rhs_command, rhs))
      `uvm_fatal("RDMA_COPY_TYPE", "CMQ command descriptor copy mismatch")
    function_h = rdma_clone_function_handle_value(rhs_command.function_h,
                                                   "CMQ command");
    opcode_key = rdma_cmq_clone_opcode_key_value(rhs_command.opcode_key,
                                                  "CMQ command");
    body = rdma_cmq_clone_hw_model_value(rhs_command.body, "CMQ command");
    qpc_signature_source = rdma_cmq_clone_image_value(
      rhs_command.qpc_signature_source, "CMQ command QPC signature source"
    );
    vfid_override = rhs_command.vfid_override;
    use_vfid = rhs_command.use_vfid;
    timeout = rhs_command.timeout;
    if (rhs_command.recovery_owner == null) begin
      recovery_owner = null;
    end
    else begin
      recovery_owner = new("command_recovery_owner");
      recovery_owner.copy(rhs_command.recovery_owner);
    end
  endfunction

  // 功能：在首次 admission 前校验 command 的 Function、opcode、body、timeout 和 owner。
  // 输入/输出及副作用：只读当前 command 及嵌套 validate() 结果，返回首个
  // 失败 status 或 OK；不冻结 recovery_owner，不修改 body/image。
  // 失败/边界：缺少/invalid Function、key、body、timeout 或 owner 时拒绝；body/owner
  // 返回 null status 时转为 INVALID_STATE，QPC signature generation 不同时返回 STALE_GENERATION。
  function rdma_status validate();
    rdma_status status;

    status = rdma_cmq_function_status(function_h, "CMQ command");
    if (!status.ok())
      return status;
    if (opcode_key == null)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "CMQ command opcode key is null");
    status = opcode_key.validate();
    if (!status.ok())
      return status;
    if (body == null)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "CMQ command body is null");
    status = rdma_status::nonnull(body.validate(), "CMQ command body returned null status");
    if (!status.ok())
      return status;
    if (timeout == 0)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "CMQ command timeout is zero");
    if (recovery_owner == null)
      return rdma_status::make(
        RDMA_SC_INVALID_ARGUMENT,
        "CMQ command recovery owner is null"
      );
    status = recovery_owner.validate_for_admission();
    if (status == null || !status.ok())
      return (status == null) ? rdma_status::make(
        RDMA_SC_INVALID_STATE,
        "CMQ command recovery owner validation returned null"
      ) : status;
    if (qpc_signature_source != null &&
        qpc_signature_source.function_generation != function_h.generation)
      return rdma_status::make(
        RDMA_SC_STALE_GENERATION,
        "CMQ QPC signature source generation does not match Function"
      );
    return rdma_status::success();
  endfunction

  // 功能：校验已冻结命令是否可写入 journal，保留 legacy sentinel 的精确兼容分支。
  // 输入/输出及副作用：expected_identity 与 expected_admission_attempt_id 为输入；
  //   只读 command 字段和 owner，返回 detached status，不改变命令。
  // 失败/边界：基础 command 字段非法、owner 缺失、legacy 形状被篡改或具体 owner
  //   的 frozen identity/attempt 不匹配时拒绝；不会重新应用未冻结 admission 规则。
  function rdma_status validate_for_journal(
    input rdma_function_identity expected_identity,
    input longint unsigned expected_admission_attempt_id
  );
    rdma_status status;

    status = rdma_cmq_function_status(function_h, "CMQ command");
    if (status == null || !status.ok())
      return (status == null) ? rdma_status::make(
        RDMA_SC_INVALID_STATE,
        "CMQ command Function validation returned null"
      ) : status;
    if (opcode_key == null)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "CMQ command opcode key is null");
    status = opcode_key.validate();
    if (status == null || !status.ok())
      return (status == null) ? rdma_status::make(
        RDMA_SC_INVALID_STATE,
        "CMQ command opcode key validation returned null"
      ) : status;
    if (body == null)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "CMQ command body is null");
    status = body.validate();
    if (status == null || !status.ok())
      return (status == null) ? rdma_status::make(
        RDMA_SC_INVALID_STATE,
        "CMQ command body validation returned null"
      ) : status;
    if (timeout == 0)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "CMQ command timeout is zero");
    if (qpc_signature_source != null &&
        qpc_signature_source.function_generation != function_h.generation)
      return rdma_status::make(
        RDMA_SC_STALE_GENERATION,
        "CMQ QPC signature source generation does not match Function"
      );
    if (recovery_owner == null)
      return rdma_status::make(
        RDMA_SC_INVALID_ARGUMENT,
        "CMQ command recovery owner is null"
      );
    if (recovery_owner.is_legacy_unmigrated()) begin
      return rdma_status::success();
    end
    if (expected_identity == null || expected_admission_attempt_id == 0)
      return rdma_status::make(
        RDMA_SC_INVALID_ARGUMENT,
        "CMQ journal expected identity or attempt is invalid"
      );
    return recovery_owner.validate_frozen(
      expected_identity, expected_admission_attempt_id
    );
  endfunction
endclass

// 功能：构造 profile="rdma" 的 CMQ opcode key。
// 输入/输出及副作用：opcode/variant 写入新对象；name 仅作 UVM 对象名。
// 失败/边界：不校验 opcode 是否受 profile 支持，由 codec/engine 在提交时拒绝。
function automatic rdma_cmq_opcode_key rdma_make_cmq_opcode_key(
  bit [31:0] opcode,
  string variant,
  string name = "cmq_opcode_key"
);
  rdma_cmq_opcode_key key;

  key = rdma_cmq_opcode_key::type_id::create(name);
  key.profile_name = "rdma";
  key.opcode = opcode;
  key.variant = variant;
  return key;
endfunction

// 功能：构造一条控制路径 CMQ 命令：detached Function 句柄、rdma opcode key、body 与超时。
// 输入/输出及副作用：owner 被深拷贝，body 按引用挂接（调用方负责是否先 clone）；返回新命令。
// 失败/边界：不调用 validate；owner 为 null 时 function_h 为 null，由提交路径拒绝。
function automatic rdma_cmq_command_desc rdma_make_cmq_command(
  rdma_function_handle owner,
  bit [31:0] opcode,
  string variant,
  rdma_hw_model body,
  time timeout,
  string name = "cmq_command"
);
  rdma_cmq_command_desc command;

  command = rdma_cmq_command_desc::type_id::create(name);
  command.function_h = rdma_clone_function_handle_value(owner, name);
  command.opcode_key = rdma_make_cmq_opcode_key(opcode, variant,
                                                {name, "_opcode"});
  command.body = body;
  command.timeout = timeout;
  return command;
endfunction

// 设计说明：slot context 把 allocator 给出的 SQ 物理位置与 command 分离，
// 让 profile 编码前能独立验证 Function/CMQ 归属和 sequence/index/wrap 几何。
class rdma_cmq_slot_context extends uvm_object;
  `uvm_object_utils(rdma_cmq_slot_context)

  rdma_function_handle function_h;
  rdma_handle cmq_h;
  rdma_backing_addr_t backing_addr;
  longint unsigned relative_offset;
  longint unsigned slot_sequence;
  int unsigned sq_index;
  bit sq_wrap;

  // 功能：构造未定位的 CMQ SQ slot 值，作为 allocator 填充的容器。
  // 输入/输出及副作用：name 设置 UVM 实例名；清空 Function/CMQ 句柄、backing、
  // offset、sequence、index 和 wrap，不拥有 Host-memory backing。
  // 失败/边界：默认值因句柄缺失无法通过 validate()；零 sequence/index 本身是合法位置。
  function new(string name = "rdma_cmq_slot_context");
    super.new(name);
    function_h = null;
    cmq_h = null;
    backing_addr = '0;
    relative_offset = '0;
    slot_sequence = '0;
    sq_index = '0;
    sq_wrap = 1'b0;
  endfunction

  // 功能：深拷贝 slot 的 Function/CMQ identity 和物理位置值。
  // 输入/输出及副作用：rhs 为只读 slot；克隆两个句柄并覆盖 backing_addr、
  // relative_offset、slot_sequence、sq_index 和 sq_wrap，不修改源对象。
  // 失败/边界：do_copy 在源对象为空、clone/cast 失败或类型不匹配时触发
  // UVM fatal（CMQ slot context copy mismatch），不保留部分有效快照。
  virtual function void do_copy(uvm_object rhs);
    rdma_cmq_slot_context rhs_slot;

    super.do_copy(rhs);
    if (!$cast(rhs_slot, rhs))
      `uvm_fatal("RDMA_COPY_TYPE", "CMQ slot context copy mismatch")
    function_h = rdma_clone_function_handle_value(rhs_slot.function_h,
                                                   "CMQ slot");
    cmq_h = rdma_clone_handle_value(rhs_slot.cmq_h, "CMQ slot");
    backing_addr = rhs_slot.backing_addr;
    relative_offset = rhs_slot.relative_offset;
    slot_sequence = rhs_slot.slot_sequence;
    sq_index = rhs_slot.sq_index;
    sq_wrap = rhs_slot.sq_wrap;
  endfunction

  // 功能：校验 slot 的 Function/CMQ 归属、32x64 几何和 sequence/index/wrap 对应关系。
  // 输入/输出及副作用：只读当前 slot，返回首个失败 status 或 OK；
  // 不访问 backing 内存，不推进生产者游标。
  // 失败/边界：句柄非法、index>=32、offset 非 64B 对齐/不等于 index*64、
  // backing 非 64B 对齐或 sequence 不匹配时返回 INVALID_ARGUMENT；地址加法溢出返回 DMA_TRANSLATION。
  function rdma_status validate();
    rdma_status status;

    status = rdma_cmq_function_status(function_h, "CMQ slot");
    if (!status.ok())
      return status;
    status = rdma_cmq_handle_status(cmq_h, function_h, "CMQ slot");
    if (!status.ok())
      return status;
    if (sq_index >= 32)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "CMQ SQ slot index is outside depth 32");
    if ((relative_offset & 64'h3f) != 0 ||
        relative_offset != (longint'(sq_index) * 64))
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "CMQ SQ slot offset is invalid");
    if ((backing_addr.value & 64'h3f) != 0)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "CMQ SQ backing is not 64-byte aligned");
    if (sq_index != (slot_sequence % 32) ||
        sq_wrap != ((slot_sequence / 32) % 2))
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "CMQ SQ slot sequence position is invalid");
    if (backing_addr.value >
        (64'hffff_ffff_ffff_ffff - relative_offset))
      return rdma_status::make(RDMA_SC_DMA_TRANSLATION,
                               "CMQ SQ slot backing address overflows");
    return rdma_status::success();
  endfunction
endclass

// 设计说明：expected response 只描述 profile 应匹配的 opcode/variant，
// 不提前绑定具体 payload 类型，使 CQE 解码仍由选中的 hardware profile 负责。
class rdma_cmq_expected_response extends uvm_object;
  `uvm_object_utils(rdma_cmq_expected_response)

  bit [31:0] hardware_opcode;
  string variant;

  // 功能：构造尚未指定 variant 的预期 CMQ 响应键。
  // 输入/输出及副作用：name 设置 UVM 实例名；hardware_opcode 置零且 variant 置空，
  // 本对象不持有 payload 或外部资源。
  // 失败/边界：空 variant 使默认对象无法通过 validate()；零 hardware opcode 可由 profile 解释。
  function new(string name = "rdma_cmq_expected_response");
    super.new(name);
    hardware_opcode = '0;
    variant = "";
  endfunction

  // 功能：将 rhs 中 rdma_cmq_expected_response 的值字段复制到当前对象，
  // 建立与源对象隔离的快照。
  // 输入/输出及副作用：rhs 为只读源；按值覆盖 hardware_opcode 和 variant，
  // 不分配嵌套对象也不修改 rhs。
  // 失败/边界：do_copy 在源对象为空、clone/cast 失败或类型不匹配时触发
  // UVM fatal（CMQ expected response copy mismatch），不保留部分有效快照。
  virtual function void do_copy(uvm_object rhs);
    rdma_cmq_expected_response rhs_expected;

    super.do_copy(rhs);
    if (!$cast(rhs_expected, rhs))
      `uvm_fatal("RDMA_COPY_TYPE", "CMQ expected response copy mismatch")
    hardware_opcode = rhs_expected.hardware_opcode;
    variant = rhs_expected.variant;
  endfunction

  // 功能：验证 expected-response variant 可安全参与 profile 的分隔键比较。
  // 输入/输出及副作用：只读 variant 并返回新 rdma_status；不修改 hardware_opcode。
  // 失败/边界：variant 为空或含“|”时返回 INVALID_ARGUMENT；其他字节由 profile 进一步解释。
  function rdma_status validate();
    if (variant.len() == 0)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "CMQ expected response variant is empty");
    if (rdma_cmq_string_has_separator(variant))
      return rdma_status::make(
        RDMA_SC_INVALID_ARGUMENT,
        "CMQ expected response variant contains '|'"
      );
    return rdma_status::success();
  endfunction
endclass

// 设计说明：decoded CQE 是 codec 与 engine lifecycle 之间的中间值，
// 分开保存硬件字段、operation status 和 polymorphic payload，尚不承担 ticket 关联。
class rdma_cmq_decoded_cqe extends uvm_object;
  `uvm_object_utils(rdma_cmq_decoded_cqe)

  bit [31:0] hardware_opcode;
  int unsigned wqe_index;
  bit wqe_wrap;
  bit [31:0] hardware_ecode;
  rdma_status command_status;
  uvm_object response_payload;

  // 功能：构造空的 CQE 解码结果容器，等待 completion codec 填入索引和状态。
  // 输入/输出及副作用：name 设置 UVM 实例名；标量清零，command_status 和可选
  // response_payload 均置 null，未取得 payload 所有权。
  // 失败/边界：command_status 未填充前 validate() 必然拒绝；wqe_index==0 为合法索引。
  function new(string name = "rdma_cmq_decoded_cqe");
    super.new(name);
    hardware_opcode = '0;
    wqe_index = '0;
    wqe_wrap = 1'b0;
    hardware_ecode = '0;
    command_status = null;
    response_payload = null;
  endfunction

  // 功能：将 rhs 中 rdma_cmq_decoded_cqe 的值字段复制到当前对象，建立与源对象隔离的快照。
  // 输入/输出及副作用：rhs 为只读 decoded CQE；覆盖 opcode/index/wrap/ecode，
  // 并分别复制 command_status 和克隆 response_payload。
  // 失败/边界：do_copy 在源对象为空、clone/cast 失败或类型不匹配时触发 UVM fatal（CMQ decoded CQE copy mismatch），不保留部分有效快照。
  virtual function void do_copy(uvm_object rhs);
    rdma_cmq_decoded_cqe rhs_decoded;

    super.do_copy(rhs);
    if (!$cast(rhs_decoded, rhs))
      `uvm_fatal("RDMA_COPY_TYPE", "CMQ decoded CQE copy mismatch")
    hardware_opcode = rhs_decoded.hardware_opcode;
    wqe_index = rhs_decoded.wqe_index;
    wqe_wrap = rhs_decoded.wqe_wrap;
    hardware_ecode = rhs_decoded.hardware_ecode;
    command_status = rdma_cmq_clone_status_value(rhs_decoded.command_status);
    response_payload = rdma_cmq_clone_object_value(
      rhs_decoded.response_payload, "CMQ decoded response payload"
    );
  endfunction

  // 功能：检查 CQE 解码结果至少有 command status，且 WQE 索引可放入五位硬件字段。
  // 输入/输出及副作用：只读 command_status 和 wqe_index，返回 OK/INVALID_ARGUMENT；
  // 不解释 operation status 是否成功，也不触及 response_payload。
  // 失败/边界：command_status==null 或 wqe_index>=32 时拒绝；非 OK command_status 仍是合法硬件结果。
  function rdma_status validate();
    if (command_status == null)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "CMQ decoded CQE status is null");
    if (wqe_index >= 32)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "CMQ decoded CQE WQE index exceeds 5 bits");
    return rdma_status::success();
  endfunction
endclass

// 设计说明：ticket 冻结单次提交的 command ID、Function/CMQ、slot 和 deadline，
// 使 completion、timeout 与 late diagnostic 可用同一 immutable identity 关联。
class rdma_cmq_ticket extends uvm_object;
  `uvm_object_utils(rdma_cmq_ticket)

  longint unsigned command_id;
  rdma_function_handle function_h;
  rdma_handle cmq_h;
  longint unsigned slot_sequence;
  int unsigned sq_index;
  bit sq_wrap;
  rdma_cmq_opcode_key opcode_key;
  time absolute_deadline;

  // 功能：构造尚未发布的 CMQ ticket 容器，不预设 command、slot 或 deadline 权威。
  // 输入/输出及副作用：name 设置 UVM 实例名；ID/sequence/index/wrap/deadline 清零，
  // Function、CMQ 和 opcode key 句柄置 null。
  // 失败/边界：默认 ticket 不表示有效提交，validate() 在 ID、deadline 或句柄填充前拒绝。
  function new(string name = "rdma_cmq_ticket");
    super.new(name);
    command_id = '0;
    function_h = null;
    cmq_h = null;
    slot_sequence = '0;
    sq_index = '0;
    sq_wrap = 1'b0;
    opcode_key = null;
    absolute_deadline = 0;
  endfunction

  // 功能：将 rhs 中 rdma_cmq_ticket 的值字段复制到当前对象，建立与源对象隔离的快照。
  // 输入/输出及副作用：rhs 为只读 ticket；深拷贝 Function/CMQ/opcode key，
  // 并按值覆盖 command_id、slot 位置和 absolute_deadline。
  // 失败/边界：do_copy 在源对象为空、clone/cast 失败或类型不匹配时触发 UVM fatal（CMQ ticket copy mismatch），不保留部分有效快照。
  virtual function void do_copy(uvm_object rhs);
    rdma_cmq_ticket rhs_ticket;

    super.do_copy(rhs);
    if (!$cast(rhs_ticket, rhs))
      `uvm_fatal("RDMA_COPY_TYPE", "CMQ ticket copy mismatch")
    command_id = rhs_ticket.command_id;
    function_h = rdma_clone_function_handle_value(rhs_ticket.function_h,
                                                   "CMQ ticket");
    cmq_h = rdma_clone_handle_value(rhs_ticket.cmq_h, "CMQ ticket");
    slot_sequence = rhs_ticket.slot_sequence;
    sq_index = rhs_ticket.sq_index;
    sq_wrap = rhs_ticket.sq_wrap;
    opcode_key = rdma_cmq_clone_opcode_key_value(rhs_ticket.opcode_key,
                                                  "CMQ ticket");
    absolute_deadline = rhs_ticket.absolute_deadline;
  endfunction

  // 功能：校验 ticket 的 command identity、Function/CMQ 归属、opcode 与 32-entry SQ 位置。
  // 输入/输出及副作用：只读 ticket 和嵌套 opcode key，返回首个失败 status 或 OK；
  // 不消费 ticket，不比较当前仿真时间。
  // 失败/边界：command_id/deadline 为零、句柄/key 非法、sq_index>=32，或
  // index/wrap 与 slot_sequence 不一致时拒绝。
  function rdma_status validate();
    rdma_status status;

    if (command_id == 0)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "CMQ ticket command ID is zero");
    if (absolute_deadline == 0)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "CMQ ticket absolute deadline is zero");
    status = rdma_cmq_function_status(function_h, "CMQ ticket");
    if (!status.ok())
      return status;
    status = rdma_cmq_handle_status(cmq_h, function_h, "CMQ ticket");
    if (!status.ok())
      return status;
    if (opcode_key == null)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "CMQ ticket opcode key is null");
    status = opcode_key.validate();
    if (!status.ok())
      return status;
    if (sq_index >= 32)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "CMQ ticket SQ index is outside depth 32");
    if (sq_index != (slot_sequence % 32) ||
        sq_wrap != ((slot_sequence / 32) % 2))
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "CMQ ticket SQ sequence position is invalid");
    return rdma_status::success();
  endfunction
endclass

// 功能：为 completion/diagnostic 的传统 do_copy 克隆可选 CMQ ticket。
// 输入/输出及副作用：source 为只读源，label 标识调用者；null 返回 null，
// 非空返回 factory clone 的新 ticket 图。
// 失败/边界：clone 返回 null/错误 runtime type 时发布 RDMA_COPY_TYPE fatal；
// 需要保留重复节点别名的 nonfatal 路径应使用 snapshot context。
function automatic rdma_cmq_ticket rdma_cmq_clone_ticket_value(
  rdma_cmq_ticket source,
  string label
);
  uvm_object cloned_object;
  rdma_cmq_ticket result;

  if (source == null)
    return null;
  cloned_object = source.clone();
  if (cloned_object == null || !$cast(result, cloned_object))
    `uvm_fatal("RDMA_COPY_TYPE", {label, " ticket clone mismatch"})
  return result;
endfunction

// 功能：校验 raw CQE 的 64B image 形状、metadata 和可选 ticket generation 绑定。
// 输入/输出及副作用：raw_cqe/ticket 为只读输入，label 加入诊断；
// 返回新 rdma_status，不解码 bytes 且不修改 image。
// 失败/边界：null、长度/对齐/端序/image kind/target metadata 非法时返回
// INVALID_ARGUMENT；与非空 ticket 的 Function generation 不同时返回 STALE_GENERATION。
function automatic rdma_status rdma_cmq_raw_cqe_status(
  rdma_hw_image raw_cqe,
  rdma_cmq_ticket ticket,
  string label
);
  if (raw_cqe == null)
    return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                             {label, " raw CQE is null"});
  if (raw_cqe.length != 64 || raw_cqe.bytes.size() != 64)
    return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                             {label, " raw CQE is not 64 bytes"});
  if (raw_cqe.alignment != 64)
    return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                             {label, " raw CQE alignment is not 64 bytes"});
  if (!(raw_cqe.endian inside {RDMA_ENDIAN_LITTLE, RDMA_ENDIAN_BIG}))
    return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                             {label, " raw CQE endian is invalid"});
  if (raw_cqe.image_kind != RDMA_IMAGE_CMQ_CQE ||
      raw_cqe.hardware_version == 0 ||
      raw_cqe.function_generation == 0 ||
      raw_cqe.write_target_kind != RDMA_HW_TARGET_NONE ||
      raw_cqe.backing_target.value != 0 ||
      raw_cqe.hmc_target.value != 0 || raw_cqe.bar_target.value != 0)
    return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                             {label, " raw CQE metadata is invalid"});
  if (ticket != null && ticket.function_h != null &&
      raw_cqe.function_generation != ticket.function_h.generation)
    return rdma_status::make(RDMA_SC_STALE_GENERATION,
                             {label, " raw CQE generation is stale"});
  return rdma_status::success();
endfunction

// 设计说明：completion envelope 聚合 ticket、operation status、原始 CQE 与 payload；
// timeout/reset 允许无 CQE，其余路径必须保留可复验的硬件 image。
class rdma_cmq_completion extends uvm_object;
  `uvm_object_utils(rdma_cmq_completion)

  rdma_cmq_ticket ticket;
  rdma_status status;
  rdma_hw_image raw_cqe;
  uvm_object decoded_response;

  // 功能：构造空 completion envelope，等待 engine 填入 ticket、operation status 和观测证据。
  // 输入/输出及副作用：name 设置 UVM 实例名；ticket/status/raw_cqe/payload 均置 null，
  // 构造时不拥有任何嵌套值。
  // 失败/边界：默认 envelope 不是成功结果；在 ticket/status 填充前 validate() 必然拒绝。
  function new(string name = "rdma_cmq_completion");
    super.new(name);
    ticket = null;
    status = null;
    raw_cqe = null;
    decoded_response = null;
  endfunction

  // 功能：将 rhs 中 rdma_cmq_completion 的值字段复制到当前对象，建立与源对象隔离的快照。
  // 输入/输出及副作用：rhs 为只读 completion；深拷贝 ticket/status/image 并通过
  // uvm_object::clone() 复制 polymorphic decoded_response，覆盖当前 envelope。
  // 失败/边界：do_copy 在源对象为空、clone/cast 失败或类型不匹配时触发 UVM fatal（CMQ completion copy mismatch），不保留部分有效快照。
  virtual function void do_copy(uvm_object rhs);
    rdma_cmq_completion rhs_completion;

    super.do_copy(rhs);
    if (!$cast(rhs_completion, rhs))
      `uvm_fatal("RDMA_COPY_TYPE", "CMQ completion copy mismatch")
    ticket = rdma_cmq_clone_ticket_value(rhs_completion.ticket,
                                         "CMQ completion");
    status = rdma_cmq_clone_status_value(rhs_completion.status);
    raw_cqe = rdma_cmq_clone_image_value(rhs_completion.raw_cqe,
                                         "CMQ completion raw CQE");
    decoded_response = rdma_cmq_clone_object_value(
      rhs_completion.decoded_response, "CMQ completion decoded response"
    );
  endfunction

  // 功能：校验 completion 具有有效 ticket/status，并区分硬件 CQE 与 timeout/reset 无 CQE 形状。
  // 输入/输出及副作用：只读 envelope，透传 ticket 或 raw-CQE 校验 status；
  // 不根据 operation status 改写 payload，不消费 completion。
  // 失败/边界：ticket/status 为 null 时拒绝；raw_cqe==null 仅对 TIMEOUT 或
  // RESET_CANCELLED 合法，非空 raw CQE 必须满足 64B metadata 与 generation 约束。
  function rdma_status validate();
    rdma_status validation_status;

    if (ticket == null)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "CMQ completion ticket is null");
    validation_status = ticket.validate();
    if (!validation_status.ok())
      return validation_status;
    if (status == null)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "CMQ completion status is null");
    if (raw_cqe == null) begin
      if (!(status.code inside {RDMA_SC_TIMEOUT,
                                RDMA_SC_RESET_CANCELLED}))
        return rdma_status::make(
          RDMA_SC_INVALID_ARGUMENT,
          "CMQ hardware completion has no raw CQE"
        );
      return rdma_status::success();
    end
    return rdma_cmq_raw_cqe_status(raw_cqe, ticket, "CMQ completion");
  endfunction
endclass

// 设计说明：diagnostic 与正常 completion 分离保存 late/orphan/reset 证据，
// 避免诊断投递改变主 completion 生命周期或消费其 retained journal evidence。
class rdma_cmq_diagnostic extends uvm_object;
  `uvm_object_utils(rdma_cmq_diagnostic)

  rdma_cmq_diagnostic_kind_e kind;
  rdma_cmq_ticket ticket;
  rdma_status status;
  rdma_hw_image raw_cqe;

  // 功能：构造默认为 late-completion 类别的空 CMQ 诊断 envelope。
  // 输入/输出及副作用：name 设置 UVM 实例名；ticket/status/raw_cqe 置 null，
  // 本对象在填充后拥有这些诊断快照。
  // 失败/边界：默认 late-completion 因缺少 status/ticket/CQE 无效，不得当作已观测事件。
  function new(string name = "rdma_cmq_diagnostic");
    super.new(name);
    kind = RDMA_CMQ_DIAG_LATE_COMPLETION;
    ticket = null;
    status = null;
    raw_cqe = null;
  endfunction

  // 功能：将 rhs 中 rdma_cmq_diagnostic 的值字段复制到当前对象，建立与源对象隔离的快照。
  // 输入/输出及副作用：rhs 为只读 diagnostic；覆盖 kind，并深拷贝 ticket、status 和 raw CQE。
  // 失败/边界：do_copy 在源对象为空、clone/cast 失败或类型不匹配时触发 UVM fatal（CMQ diagnostic copy mismatch），不保留部分有效快照。
  virtual function void do_copy(uvm_object rhs);
    rdma_cmq_diagnostic rhs_diagnostic;

    super.do_copy(rhs);
    if (!$cast(rhs_diagnostic, rhs))
      `uvm_fatal("RDMA_COPY_TYPE", "CMQ diagnostic copy mismatch")
    kind = rhs_diagnostic.kind;
    ticket = rdma_cmq_clone_ticket_value(rhs_diagnostic.ticket,
                                         "CMQ diagnostic");
    status = rdma_cmq_clone_status_value(rhs_diagnostic.status);
    raw_cqe = rdma_cmq_clone_image_value(rhs_diagnostic.raw_cqe,
                                         "CMQ diagnostic raw CQE");
  endfunction

  // 功能：校验诊断 status、late-completion ticket 要求和 raw CQE 的硬件 image 契约。
  // 输入/输出及副作用：只读 diagnostic，可校验可选 ticket，最后返回 raw-CQE
  // 校验结果；不改写诊断种类或 operation status。
  // 失败/边界：status 为 null，late-completion 缺 ticket，可选 ticket 无效，或
  // raw CQE 为 null/形状非法时拒绝；其他诊断类别允许 ticket==null。
  function rdma_status validate();
    rdma_status validation_status;

    if (status == null)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "CMQ diagnostic status is null");
    if (kind == RDMA_CMQ_DIAG_LATE_COMPLETION && ticket == null)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "late CMQ completion has no ticket");
    if (ticket != null) begin
      validation_status = ticket.validate();
      if (!validation_status.ok())
        return validation_status;
    end
    return rdma_cmq_raw_cqe_status(raw_cqe, ticket, "CMQ diagnostic");
  endfunction
endclass

// 设计说明：runtime descriptor 冻结 CMQ ring 的 IOVA、固定几何和初始相位，
// 供 engine 配置前复验；它只描述 backing，不取得 Host-memory 生命周期。
class rdma_cmq_runtime_desc extends uvm_object;
  `uvm_object_utils(rdma_cmq_runtime_desc)

  rdma_function_handle function_h;
  rdma_handle cmq_h;
  rdma_iova_t sq_iova;
  rdma_iova_t cq_iova;
  int unsigned sq_depth;
  int unsigned cq_depth;
  int unsigned entry_bytes;
  bit initial_sq_valid;
  bit initial_cq_owner;
  bit initial_doorbell_polarity;

  // 功能：构造未配置的 CMQ runtime geometry 容器，不伪造 SQ/CQ backing 权威。
  // 输入/输出及副作用：name 设置 UVM 实例名；句柄、IOVA、depth、entry size 和
  // 三个初始 polarity/valid 位全部清零，不拥有对应 DMA memory。
  // 失败/边界：默认形状无法通过 validate()；初始 owner/polarity 的零值本身是合法起点。
  function new(string name = "rdma_cmq_runtime_desc");
    super.new(name);
    function_h = null;
    cmq_h = null;
    sq_iova = '0;
    cq_iova = '0;
    sq_depth = '0;
    cq_depth = '0;
    entry_bytes = '0;
    initial_sq_valid = 1'b0;
    initial_cq_owner = 1'b0;
    initial_doorbell_polarity = 1'b0;
  endfunction

  // 功能：将 rhs 中 rdma_cmq_runtime_desc 的值字段复制到当前对象，
  // 建立与源对象隔离的快照。
  // 输入/输出及副作用：rhs 为只读 runtime；克隆 Function/CMQ 句柄，并覆盖
  // SQ/CQ IOVA、geometry 和初始 ring 位，不复制实际 backing 内存。
  // 失败/边界：do_copy 在源对象为空、clone/cast 失败或类型不匹配时触发
  // UVM fatal（CMQ runtime descriptor copy mismatch），不保留部分有效快照。
  virtual function void do_copy(uvm_object rhs);
    rdma_cmq_runtime_desc rhs_runtime;

    super.do_copy(rhs);
    if (!$cast(rhs_runtime, rhs))
      `uvm_fatal("RDMA_COPY_TYPE", "CMQ runtime descriptor copy mismatch")
    function_h = rdma_clone_function_handle_value(rhs_runtime.function_h,
                                                   "CMQ runtime");
    cmq_h = rdma_clone_handle_value(rhs_runtime.cmq_h, "CMQ runtime");
    sq_iova = rhs_runtime.sq_iova;
    cq_iova = rhs_runtime.cq_iova;
    sq_depth = rhs_runtime.sq_depth;
    cq_depth = rhs_runtime.cq_depth;
    entry_bytes = rhs_runtime.entry_bytes;
    initial_sq_valid = rhs_runtime.initial_sq_valid;
    initial_cq_owner = rhs_runtime.initial_cq_owner;
    initial_doorbell_polarity = rhs_runtime.initial_doorbell_polarity;
  endfunction

  // 功能：校验 CMQ runtime 的 Function/CMQ 归属、固定 32x64 ring 几何和连续 IOVA 布局。
  // 输入/输出及副作用：只读 runtime 并返回首个失败 status 或 OK；
  // 不映射 DMA、不读写 SQ/CQ，不改写初始 owner/polarity。
  // 失败/边界：句柄非法或 geometry/对齐/CQ=SQ+2048 约束不满足时拒绝；
  // SQ 加 2048 或 CQ 覆盖 2048B 范围溢出时返回 DMA_TRANSLATION。
  function rdma_status validate();
    rdma_status status;

    status = rdma_cmq_function_status(function_h, "CMQ runtime");
    if (!status.ok())
      return status;
    status = rdma_cmq_handle_status(cmq_h, function_h, "CMQ runtime");
    if (!status.ok())
      return status;
    if (sq_depth != 32 || cq_depth != 32 || entry_bytes != 64)
      return rdma_status::make(
        RDMA_SC_INVALID_ARGUMENT,
        "CMQ runtime geometry must be 32 entries by 64 bytes"
      );
    if (sq_iova.value > (64'hffff_ffff_ffff_ffff - 64'd2048))
      return rdma_status::make(RDMA_SC_DMA_TRANSLATION,
                               "CMQ SQ-to-CQ IOVA addition overflows");
    if (cq_iova.value > (64'hffff_ffff_ffff_ffff - 64'd2047))
      return rdma_status::make(RDMA_SC_DMA_TRANSLATION,
                               "CMQ CQ IOVA range overflows");
    if ((sq_iova.value & 64'hfff) != 0 ||
        (cq_iova.value & 64'h3f) != 0)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "CMQ runtime IOVA alignment is invalid");
    if (cq_iova.value != (sq_iova.value + 64'd2048))
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "CMQ CQ IOVA is not SQ IOVA plus 2048");
    return rdma_status::success();
  endfunction
endclass
