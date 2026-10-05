// 目录：核心执行层 core/rdma_cmq_engine_port_adapter.sv。
// 职责：实现 rdma_cmq_engine_port_adapter 在本层的职责和对外接口。
// 依赖：依赖本层公共 types/model/adapter 契约及其上游快照。
// 所有权与生命周期：对象只拥有显式创建的值快照；外部资源保存非拥有引用，生命周期由调用方管理。

// 中文说明：rdma_cmq_engine_port_adapter.sv 属于核心执行层，负责队列、控制面、资源和恢复流程。
// 阅读提示：先看公开类型和接口，再看实现细节；失败路径应保持状态与资源所有权可追踪。

class rdma_cmq_engine_port_adapter extends rdma_cmq_port;
  `uvm_object_utils(rdma_cmq_engine_port_adapter)

  protected rdma_cmq_engine engines[string];
  // Set only when this adapter returns from a validation guard that runs
  // before handing a command to the CMQ engine.  Engine submit/wait failures
  // intentionally remain unclassified because they may have crossed the
  // hardware boundary.
  protected bit last_execute_no_submit_proven;

  // 功能：构造 rdma_cmq_engine_port_adapter，调用 super.new 建立 UVM 对象，并把构造体直接写入的默认值设为：last_execute_no_submit_proven=1'b0。
  // 输入/输出及副作用：name（输入）；new 只写入构造体列出的默认字段并返回 void，外部依赖与资源所有权仍由上层管理。
  // 失败/边界：rdma_cmq_engine_port_adapter 构造只建立本地初始状态，不接管外部 Host-memory、PCIe 或 manager；未完成后续 configure/build/activate 时，业务入口必须返回 INVALID_STATE。
  function new(string name = "rdma_cmq_engine_port_adapter");
    super.new(name);
    last_execute_no_submit_proven = 1'b0;
  endfunction

  // 功能：在 rdma_cmq_engine_port_adapter 中，last_execute_definitive_no_submit 只读查询当前运行时/测试账本，返回槽位、对象或恢复记录的快照而不推进事务。
  // 输入/输出及副作用：无显式参数；last_execute_definitive_no_submit 读取固定返回值或局部计算结果，不使用对象成员字段；函数返回 bit，不取得调用方资源所有权。
  // 失败/边界：last_execute_definitive_no_submit 的结果直接由 return last_execute_no_submit_proven 计算；输入不满足表达式条件时沿函数体的保守分支返回，不修改已发布账本。
  virtual function bit last_execute_definitive_no_submit();
    return last_execute_no_submit_proven;
  endfunction

  // 功能：在 rdma_cmq_engine_port_adapter 中，function_key 把 Function/对象身份、代际和游标字段拼成稳定的查找键，供登记表去重和恢复路由使用。
  // 输入/输出及副作用：owner（输入）；function_key 读取 owner 并使用输入参数和固定枚举/常量；函数返回 string，不取得调用方资源所有权。
// 失败/边界：function_key 只按函数体列出的身份、generation、kind、object_id 或 cursor 字段拼接键；调用方须先完成空句柄校验，函数本身不分配资源、不自动回退到 root0。
  protected function string function_key(rdma_function_handle owner);
    return $sformatf("%016h:%08h:%08h", owner.function_uid,
                     owner.object_id, owner.generation);
  endfunction

  // 功能：在 rdma_cmq_engine_port_adapter 中，invalid_argument 把错误消息、硬件码或注入故障封装为统一 rdma_status，保留原事务的诊断证据。
  // 输入/输出及副作用：message（输入）；invalid_argument 读取 message 并使用字段 rdma_status；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：invalid_argument 返回 RDMA_SC_INVALID_ARGUMENT；失败路径不提交部分状态或转移未声明资源。
  protected function rdma_status invalid_argument(string message);
    return rdma_status::make(RDMA_SC_INVALID_ARGUMENT, message);
  endfunction

  // 功能：在 rdma_cmq_engine_port_adapter 中，invalid_state 把错误消息、硬件码或注入故障封装为统一 rdma_status，保留原事务的诊断证据。
  // 输入/输出及副作用：message（输入）；invalid_state 读取 message 并使用字段 rdma_status；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：invalid_state 返回 RDMA_SC_INVALID_STATE；失败路径不提交部分状态或转移未声明资源。
  protected function rdma_status invalid_state(string message);
    return rdma_status::make(RDMA_SC_INVALID_STATE, message);
  endfunction

  // 功能：保留 adapter 的 protected detached-handle 比较 seam，转发到 CMQ 共享值契约。
  // 输入/输出及副作用：lhs/rhs 为只读 handle；返回 kind、Function UID、object ID 与 generation 比较结果，不修改 adapter。
  // 失败/边界：null 或任一字段含 X/Z 时共享契约返回 0；转发不推断 observed graph 的 alias topology。
  protected function bit same_handle_value(
    input rdma_handle lhs,
    input rdma_handle rhs
  );
    return rdma_cmq_same_handle_value(lhs, rhs);
  endfunction

  // 功能：比较两个 detached ticket 的完整公开值，确认 completion 与 operation
  //   result 指向同一 immutable command authority。
  // 输入/输出及副作用：lhs/rhs 为只读 ticket；比较 command、Function/CMQ handle、
  //   slot、opcode key 和 deadline，不执行 I/O 或修改对象。
  // 失败/边界：任一 ticket shape 非法、嵌套值不一致或字段未知时返回 0；本函数
  //   不要求对象别名，别名关系由 observed_result_semantics_valid 单独验证。
  protected function bit same_ticket_value(
    input rdma_cmq_ticket lhs,
    input rdma_cmq_ticket rhs
  );
    if (lhs == null || rhs == null ||
        !rdma_cmq_ticket_shape_valid(lhs) ||
        !rdma_cmq_ticket_shape_valid(rhs))
      return 1'b0;
    return lhs.command_id == rhs.command_id &&
           same_handle_value(lhs.function_h, rhs.function_h) &&
           same_handle_value(lhs.cmq_h, rhs.cmq_h) &&
           lhs.slot_sequence == rhs.slot_sequence &&
           lhs.sq_index == rhs.sq_index &&
           lhs.sq_wrap == rhs.sq_wrap &&
           lhs.opcode_key.profile_name == rhs.opcode_key.profile_name &&
           lhs.opcode_key.opcode == rhs.opcode_key.opcode &&
           lhs.opcode_key.variant == rhs.opcode_key.variant &&
           lhs.absolute_deadline == rhs.absolute_deadline;
  endfunction

  // 功能：保留 adapter 的 protected status 比较 seam，委托 CMQ 共享契约检查完整诊断值。
  // 输入/输出及副作用：lhs/rhs 为只读 status；返回 shape 与全部现有字段的比较结果，不修改 adapter 或 status。
  // 失败/边界：null、不支持 subtype 或非法 required-status shape 返回 0；对象 alias 仍由 observed-result 边界检查。
  protected function bit same_status_value(
    input rdma_status lhs,
    input rdma_status rhs
  );
    return rdma_cmq_same_status_value(lhs, rhs);
  endfunction

  // 功能：检查 observed envelope 中 command identity 的标量字段是否构成可追踪的
  //   Function/opcode 身份，供 completion 与 ticket 交叉校验使用。
  // 输入/输出及副作用：identity 为只读 command identity；返回 bit，不分配对象或修改
  //   adapter 状态。
  // 失败/边界：null、非 Function kind、零 UID/代际、未知 opcode 或空/含分隔符的
  //   profile/variant 均返回 0；global_function_id 可为零，由上游 route 契约解释。
  protected function bit command_identity_shape_valid(
    input rdma_cmq_command_identity identity
  );
    return identity != null &&
           identity.function_kind == RDMA_RESOURCE_FUNCTION &&
           !$isunknown(identity.function_uid) && identity.function_uid != 0 &&
           !$isunknown(identity.generation) && identity.generation != 0 &&
           !$isunknown(identity.opcode) &&
           identity.profile_name.len() != 0 &&
           identity.variant.len() != 0 &&
           !rdma_cmq_string_has_separator(identity.profile_name) &&
           !rdma_cmq_string_has_separator(identity.variant);
  endfunction

  // 功能：比较 command identity 与 result ticket 的 Function/opcode 字段，确认
  //   observed envelope 未将另一个 command 的诊断身份拼接进当前 ticket。
  // 输入/输出及副作用：identity/ticket 为只读输入；返回值相等 bit，不创建快照。
  // 失败/边界：任一对象为空、identity shape 非法或 profile/variant/UID/代际漂移
  //   时返回 0；该函数不推断 batch 或恢复状态。
  protected function bit command_identity_matches_ticket(
    input rdma_cmq_command_identity identity,
    input rdma_cmq_ticket ticket
  );
    if (identity == null || ticket == null ||
        !command_identity_shape_valid(identity) ||
        !rdma_cmq_ticket_shape_valid(ticket))
      return 1'b0;
    return identity.function_kind == ticket.function_h.kind &&
           identity.function_uid == ticket.function_h.function_uid &&
           identity.global_function_id == ticket.function_h.object_id &&
           identity.generation == ticket.function_h.generation &&
           identity.profile_name == ticket.opcode_key.profile_name &&
           identity.opcode == ticket.opcode_key.opcode &&
           identity.variant == ticket.opcode_key.variant;
  endfunction

  // 功能：判断 observed result 是否完全没有提交身份图，供本地 PRE 拒绝和
  //   delegated UNOBSERVED 两种零 identity 形状共用。
  // 输入/输出及副作用：value 为只读 execution result；返回 bit，不修改对象或
  //   adapter 状态，也不访问 engine/外部资源。
  // 失败/边界：value 为 null 时返回 0；只要 ticket、identity、owner、DMA 或
  //   completion 任一存在，或 batch/attempt 有任一非零值，就不再视为空图。
  protected function bit observed_identity_graph_empty(
    input rdma_cmq_execution_result value
  );
    if (value == null)
      return 1'b0;
    return value.ticket == null && value.completion == null &&
           value.command_identity == null && value.recovery_owner == null &&
           value.dma_context == null && value.batch_key.len() == 0 &&
           value.batch_id == 0 && value.attempt_id == 0;
  endfunction

  // 功能：验证 admitted observed result 的完整身份图，确保 ticket、Function/
  //   opcode identity、recovery owner、DMA context 和 batch attempt 可互相追溯。
  // 输入/输出及副作用：value 为只读结果图；返回 bit，不冻结、复制或
  //   提交 authority；DMA validate 只读取 context 的公开约束。
  // 失败/边界：任何半成品图、零 batch/attempt、ticket/identity 漂移、legacy owner
  //   以外的 owner reset/generation 不一致，或 DMA context 校验失败均返回 0。
  protected function bit observed_identity_graph_complete(
    input rdma_cmq_execution_result value
  );
    rdma_status dma_status;

    if (value == null || value.ticket == null ||
        value.command_identity == null || value.recovery_owner == null ||
        value.dma_context == null || value.batch_key.len() == 0 ||
        value.batch_id == 0 || value.attempt_id == 0 ||
        !rdma_cmq_ticket_shape_valid(value.ticket) ||
        !command_identity_matches_ticket(value.command_identity,
                                         value.ticket) ||
        !rdma_cmq_frozen_owner_shape_valid(value.recovery_owner) ||
        value.dma_context.function_h == null ||
        value.dma_context.get_object_type() !=
          rdma_dma_request_context::get_type())
      return 1'b0;

    dma_status = value.dma_context.validate();
    if (dma_status == null || !dma_status.ok() ||
        !same_handle_value(value.dma_context.function_h,
                           value.ticket.function_h))
      return 1'b0;

    if (value.recovery_owner.is_legacy_unmigrated())
      return 1'b1;

    return value.recovery_owner.function_identity != null &&
           value.recovery_owner.resource_h != null &&
           value.recovery_owner.function_identity.function_uid ==
             value.ticket.function_h.function_uid &&
           value.recovery_owner.function_identity.generation ==
             value.ticket.function_h.generation &&
           value.recovery_owner.resource_h.function_uid ==
             value.ticket.function_h.function_uid &&
           value.recovery_owner.resource_h.generation ==
             value.ticket.function_h.generation &&
           value.dma_context.reset_epoch ==
             value.recovery_owner.function_identity.reset_epoch;
  endfunction

  // 功能：确认 legacy execute 返回的结果确实是 adapter 在 engine 前确定拒绝的
  //   PRE_SUBMIT_REJECTED envelope，作为 deprecated no-submit compatibility proof。
  // 输入/输出及副作用：value 为只读 observed result；返回 bit，不读写共享
  //   seam。
  // 失败/边界：status/observation 缺失、观察失败、非 PRE effect、任何身份
  //   半成品、
  //   completion 或 recovery 标志存在时均返回 0，避免把 delegated malformed result
  //   误报为“确定未提交”。
  protected function bit legacy_no_submit_result_valid(
    input rdma_cmq_execution_result value
  );
    if (value == null || value.status == null || value.observation_status == null ||
        !rdma_cmq_status_shape_valid(value.status) ||
        !rdma_cmq_status_shape_valid(value.observation_status) ||
        value.status.code == RDMA_SC_OK ||
        value.observation_status.code != RDMA_SC_OK ||
        value.submission_effect != RDMA_SUBMIT_EFFECT_PRE_SUBMIT_REJECTED ||
        value.attempt_effect != RDMA_SUBMIT_EFFECT_PRE_SUBMIT_REJECTED ||
        value.completion_phase != RDMA_CMQ_COMPLETION_NONE ||
        value.recovery_required != 1'b0 ||
        !observed_identity_graph_empty(value))
      return 1'b0;
    return 1'b1;
  endfunction

  // 功能：对 observed result 执行完整 effect/phase/recovery 语义交叉校验，并确认
  //   completion、ticket、status 和 identity 的 alias topology。
  // 输入/输出及副作用：value 为只读 engine 输出；返回布尔形状判定，不修改 value。
  // 失败/边界：未知枚举、PRE 与非 NONE phase 混用、UNOBSERVED 携带 completion、
  //   terminal phase 缺 completion、ticket/owner/DMA/identity 漂移或 completion 未
  //   alias result ticket/status 均拒绝；operation status/effects 不被改写。
  protected function bit observed_result_semantics_valid(
    input rdma_cmq_execution_result value
  );
    bit completion_phase_has_shell;
    bit concrete_effect;
    bit identity_graph_empty;
    bit identity_graph_complete;

    if (value == null || value.status == null ||
        value.observation_status == null ||
        !rdma_cmq_status_shape_valid(value.status) ||
        !rdma_cmq_status_shape_valid(value.observation_status) ||
        !rdma_cmq_submission_effect_valid(value.submission_effect) ||
        !rdma_cmq_submission_effect_valid(value.attempt_effect) ||
        !rdma_cmq_completion_phase_valid(value.completion_phase))
      return 1'b0;

    identity_graph_empty = observed_identity_graph_empty(value);
    identity_graph_complete = observed_identity_graph_complete(value);
    if (!identity_graph_empty && !identity_graph_complete)
      return 1'b0;

    if (value.completion != null &&
        (!identity_graph_complete || value.completion.ticket == null ||
         value.completion.status == null ||
         !rdma_cmq_ticket_shape_valid(value.completion.ticket) ||
         !rdma_cmq_status_shape_valid(value.completion.status) ||
         !same_ticket_value(value.completion.ticket, value.ticket) ||
         !same_status_value(value.completion.status, value.status) ||
         value.completion.ticket != value.ticket ||
         value.completion.status != value.status))
      return 1'b0;

    completion_phase_has_shell = value.completion_phase inside {
      RDMA_CMQ_COMPLETION_TERMINAL,
      RDMA_CMQ_COMPLETION_TIMEOUT,
      RDMA_CMQ_COMPLETION_DIAGNOSTIC_ONLY,
      RDMA_CMQ_COMPLETION_RESET_CANCELLED
    };
    if (value.completion_phase inside {
          RDMA_CMQ_COMPLETION_NONE,
          RDMA_CMQ_COMPLETION_PENDING,
          RDMA_CMQ_COMPLETION_UNOBSERVED
        } && value.completion != null)
      return 1'b0;
    if (completion_phase_has_shell && value.completion == null)
      return 1'b0;

    concrete_effect = rdma_cmq_concrete_submission_effect(
      value.submission_effect
    );
    if (value.submission_effect == RDMA_SUBMIT_EFFECT_PRE_SUBMIT_REJECTED ||
        value.attempt_effect == RDMA_SUBMIT_EFFECT_PRE_SUBMIT_REJECTED)
      return legacy_no_submit_result_valid(value);

    case (value.completion_phase)
      RDMA_CMQ_COMPLETION_UNOBSERVED:
        return value.completion == null && value.recovery_required == 1'b1 &&
               value.submission_effect == RDMA_SUBMIT_EFFECT_UNOBSERVED &&
               value.attempt_effect == RDMA_SUBMIT_EFFECT_UNOBSERVED &&
               (identity_graph_empty || identity_graph_complete);
      RDMA_CMQ_COMPLETION_NONE:
        return identity_graph_complete && value.completion == null &&
               value.submission_effect != RDMA_SUBMIT_EFFECT_MMIO_MAYBE_VISIBLE &&
               value.submission_effect != RDMA_SUBMIT_EFFECT_MMIO_VISIBLE &&
               value.attempt_effect != RDMA_SUBMIT_EFFECT_MMIO_MAYBE_VISIBLE &&
               value.attempt_effect != RDMA_SUBMIT_EFFECT_MMIO_VISIBLE &&
               value.recovery_required == 1'b1;
      RDMA_CMQ_COMPLETION_PENDING:
        return identity_graph_complete && value.completion == null &&
               value.submission_effect inside {
                 RDMA_SUBMIT_EFFECT_MMIO_MAYBE_VISIBLE,
                 RDMA_SUBMIT_EFFECT_MMIO_VISIBLE
               } && value.attempt_effect inside {
                 RDMA_SUBMIT_EFFECT_MMIO_MAYBE_VISIBLE,
                 RDMA_SUBMIT_EFFECT_MMIO_VISIBLE
               } && value.recovery_required == 1'b1;
      RDMA_CMQ_COMPLETION_TERMINAL,
      RDMA_CMQ_COMPLETION_DIAGNOSTIC_ONLY:
        return identity_graph_complete && concrete_effect &&
               rdma_cmq_concrete_submission_effect(value.attempt_effect) &&
               value.completion != null &&
               value.recovery_required == 1'b0;
      RDMA_CMQ_COMPLETION_TIMEOUT:
        return identity_graph_complete && concrete_effect &&
               rdma_cmq_concrete_submission_effect(value.attempt_effect) &&
               value.completion != null &&
               value.recovery_required == 1'b1;
      RDMA_CMQ_COMPLETION_RESET_CANCELLED:
        return identity_graph_complete && concrete_effect &&
               rdma_cmq_concrete_submission_effect(value.attempt_effect) &&
               value.completion != null;
      default:
        return 1'b0;
    endcase
  endfunction

  // 功能：在 rdma_cmq_engine_port_adapter 中，bind_engine 把 bind_engine 指定的资源或后端能力绑定到当前对象索引，并校验 Function、generation 和队列类型一致。
  // 输入/输出及副作用：owner（输入）、engine（输入）；bind_engine 先依据 owner == null || owner.kind != RDMA_RESOURCE_FUNCTION || engine == null；$isunknown(owner.function_uid；engines.exists(key 校验 owner、engine；成功时更新本对象配置/状态并保存非拥有引用，返回 rdma_status。
  // 失败/边界：资源不存在、类型不符、重复登记或跨 Function 串线时拒绝绑定并保持索引不变。
  function rdma_status bind_engine(
    rdma_function_handle owner,
    rdma_cmq_engine engine
  );
    string key;

    if (owner == null || owner.kind != RDMA_RESOURCE_FUNCTION ||
        engine == null)
      return invalid_argument("CMQ engine binding arguments are invalid");
    if ($isunknown(owner.function_uid) || $isunknown(owner.object_id) ||
        $isunknown(owner.generation))
      return invalid_argument("CMQ engine binding identity is unknown");
    key = function_key(owner);
    if (engines.exists(key))
      return invalid_state("CMQ engine binding already exists");
    engines[key] = engine;
    return rdma_status::success();
  endfunction

  // 功能：在 rdma_cmq_engine_port_adapter 中，execute 执行受控事务并按后端提交证据推进状态机，同时保留失败阶段和 generation 证据。
  // 输入/输出及副作用：command（输入）、ticket（输出）、completion（输出）、status（输出）；execute 驱动下游事务，并写入 ticket、completion、status；函数返回 无直接返回值，不取得调用方资源所有权。
  // 失败/边界：execute 遇到锁、超时、generation 变化或提交证据不完整时保持原状态，不推进游标。
  virtual task execute(
    rdma_cmq_command_desc command,
    output rdma_cmq_ticket ticket,
    output rdma_cmq_completion completion,
    output rdma_status status
  );
    rdma_cmq_execution_result observed_result;

    last_execute_no_submit_proven = 1'b0;
    ticket = null;
    completion = null;
    status = invalid_state("CMQ port execute did not complete");
    execute_observed(command, observed_result);
    if (observed_result == null) begin
      status = invalid_state("CMQ observed execute returned null result");
      return;
    end
    if (observed_result.status != null)
      status = observed_result.status;
    if (observed_result.ticket != null)
      ticket = observed_result.ticket;
    if (observed_result.completion != null)
      completion = observed_result.completion;
    if (legacy_no_submit_result_valid(observed_result))
      last_execute_no_submit_proven = 1'b1;
  endtask

  // 功能：production adapter 直接执行 observed route，并将 pre-engine 校验
  //   或 engine 返回的 detached result 传递给调用方。
  // 输入/输出及副作用：command 为非拥有输入，result 为 caller-owned 输出；
  //   成功绑定时恰好调用一次 engine.execute_observed，不调用 super fallback。
  // 失败/边界：Function 缺失/未绑定返回 PRE_SUBMIT_REJECTED；engine null 或
  //   缺失 status 时保留可用字段并补 INVALID_STATE，observed 不读写共享 bit。
  virtual task execute_observed(
    input rdma_cmq_command_desc command,
    output rdma_cmq_execution_result result
  );
    rdma_cmq_engine engine;
    string key;

    result = new("cmq_production_observed_result");
    result.status = invalid_state("CMQ port command Function is unavailable");
    result.observation_status = rdma_status::success();
    result.submission_effect = RDMA_SUBMIT_EFFECT_PRE_SUBMIT_REJECTED;
    result.attempt_effect = RDMA_SUBMIT_EFFECT_PRE_SUBMIT_REJECTED;
    result.completion_phase = RDMA_CMQ_COMPLETION_NONE;
    result.recovery_required = 1'b0;
    if (command == null || command.function_h == null ||
        command.function_h.kind != RDMA_RESOURCE_FUNCTION)
      return;
    key = function_key(command.function_h);
    if (!engines.exists(key) || engines[key] == null) begin
      result.status = invalid_state("CMQ port Function has no bound engine");
      return;
    end
    engine = engines[key];
    engine.execute_observed(command, result);
    if (result == null) begin
      result = new("cmq_production_observed_null_result");
      result.status = invalid_state("CMQ engine observed execute returned null result");
      result.observation_status = invalid_state("CMQ engine observed execute returned null result");
      result.submission_effect = RDMA_SUBMIT_EFFECT_UNOBSERVED;
      result.attempt_effect = RDMA_SUBMIT_EFFECT_UNOBSERVED;
      result.completion_phase = RDMA_CMQ_COMPLETION_UNOBSERVED;
      result.recovery_required = 1'b1;
      return;
    end
    if (result.status == null)
      result.status = invalid_state("CMQ engine observed result status is null");
    if (result.observation_status == null)
      result.observation_status = invalid_state(
        "CMQ engine observed result observation status is null"
      );
    if (!observed_result_semantics_valid(result))
      result.observation_status = invalid_state(
        "CMQ engine observed result envelope is malformed"
      );
  endtask

  // 功能：在 rdma_cmq_engine_port_adapter 中，reconcile 执行受控事务并按后端提交证据推进状态机，同时保留失败阶段和 generation 证据。
  // 输入/输出及副作用：ticket（输入）、terminal_known（输出）、completion（输出）、status（输出）；输入 action/epoch/handle
  //   决定迁移目标；成功时更新状态或恢复证据，外部资源仍由其拥有者管理。
  // 失败/边界：reconcile 遇到锁、超时、generation 变化或提交证据不完整时保持原状态，不推进游标。
  virtual task reconcile(
    rdma_cmq_ticket ticket,
    output bit terminal_known,
    output rdma_cmq_completion completion,
    output rdma_status status
  );
    rdma_status engine_status;
    string key;

    terminal_known = 1'b0;
    completion = null;
    status = invalid_state("CMQ port reconcile did not complete");
    if (ticket == null || ticket.function_h == null ||
        ticket.function_h.kind != RDMA_RESOURCE_FUNCTION) begin
      status = invalid_state("CMQ reconcile ticket Function is unavailable");
      return;
    end
    key = function_key(ticket.function_h);
    if (!engines.exists(key) || engines[key] == null) begin
      status = invalid_state("CMQ reconcile Function has no bound engine");
      return;
    end
    engines[key].reconcile_ticket(ticket, terminal_known, completion,
                                  engine_status);
    if (engine_status == null) begin
      terminal_known = 1'b0;
      completion = null;
      status = invalid_state("CMQ engine reconcile returned null status");
      return;
    end
    status = rdma_cmq_clone_status_value(engine_status);
    if (status == null) begin
      terminal_known = 1'b0;
      completion = null;
      status = invalid_state("CMQ reconcile status copy failed");
      return;
    end
    if (terminal_known &&
        (completion == null || completion.status == null)) begin
      terminal_known = 1'b0;
      completion = null;
      status = invalid_state("CMQ engine reconcile returned no completion");
    end
  endtask
endclass
