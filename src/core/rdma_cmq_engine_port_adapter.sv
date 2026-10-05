// 目录：核心执行层 core/rdma_cmq_engine_port_adapter.sv。
// 职责：把 rdma_cmq_port 适配到按 Function 绑定的 rdma_cmq_engine，并校验 engine 返回的 observed result。
// 依赖：rdma_cmq_engine、rdma_cmq_port 及 CMQ 共享值比较/shape 契约。
// 所有权与生命周期：engines 只保存非拥有引用；result/ticket/completion 由调用方持有。

class rdma_cmq_engine_port_adapter extends rdma_cmq_port;
  `uvm_object_utils(rdma_cmq_engine_port_adapter)

  protected rdma_cmq_engine engines[string];
  // Set only when this adapter returns from a validation guard that runs
  // before handing a command to the CMQ engine.  Engine submit/wait failures
  // intentionally remain unclassified because they may have crossed the
  // hardware boundary.
  protected bit last_execute_no_submit_proven;

  // 功能：构造 adapter，清除 no-submit 证明标志。
  // 输入/输出及副作用：name 为对象名。
  // 失败/边界：无。
  function new(string name = "rdma_cmq_engine_port_adapter");
    super.new(name);
    last_execute_no_submit_proven = 1'b0;
  endfunction

  // 功能：返回最近一次 execute 是否确定未提交。
  // 输入/输出及副作用：只读 last_execute_no_submit_proven。
  // 失败/边界：无。
  virtual function bit last_execute_definitive_no_submit();
    return last_execute_no_submit_proven;
  endfunction

  // 功能：由 Function handle 生成绑定表 key（UID:object_id:generation）。
  // 输入/输出及副作用：owner 只读；返回字符串。
  // 失败/边界：调用方须保证 owner 非空。
  protected function string function_key(rdma_function_handle owner);
    return $sformatf("%016h:%08h:%08h", owner.function_uid,
                     owner.object_id, owner.generation);
  endfunction

  // 功能：构造 INVALID_ARGUMENT 状态。
  // 输入/输出及副作用：message 为诊断文本；返回新 status。
  // 失败/边界：无。
  protected function rdma_status invalid_argument(string message);
    return rdma_status::make(RDMA_SC_INVALID_ARGUMENT, message);
  endfunction

  // 功能：构造 INVALID_STATE 状态。
  // 输入/输出及副作用：message 为诊断文本；返回新 status。
  // 失败/边界：无。
  protected function rdma_status invalid_state(string message);
    return rdma_status::make(RDMA_SC_INVALID_STATE, message);
  endfunction

  // 功能：转发到 CMQ 共享契约，比较两个 handle 的值。
  // 输入/输出及副作用：lhs/rhs 只读；返回比较结果。
  // 失败/边界：null 或字段含 X/Z 时返回 0。
  protected function bit same_handle_value(
    input rdma_handle lhs,
    input rdma_handle rhs
  );
    return rdma_cmq_same_handle_value(lhs, rhs);
  endfunction

  // 功能：比较两个 ticket 的公开值（command、handle、slot、opcode key、deadline）。
  // 输入/输出及副作用：lhs/rhs 只读；不要求对象别名。
  // 失败/边界：任一 ticket shape 非法、嵌套值不等或含未知值返回 0。
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

  // 功能：转发到 CMQ 共享契约，比较两个 status 的全部诊断字段。
  // 输入/输出及副作用：lhs/rhs 只读；返回比较结果。
  // 失败/边界：null、不支持的 subtype 或非法 shape 返回 0。
  protected function bit same_status_value(
    input rdma_status lhs,
    input rdma_status rhs
  );
    return rdma_cmq_same_status_value(lhs, rhs);
  endfunction

  // 功能：检查 command identity 的标量字段能否构成可追踪的 Function/opcode 身份。
  // 输入/输出及副作用：identity 只读；返回 bit。
  // 失败/边界：null、非 Function kind、零 UID/generation、未知 opcode、profile/variant 为空或含分隔符返回 0。
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

  // 功能：确认 command identity 与 ticket 的 Function/opcode 字段一致。
  // 输入/输出及副作用：identity/ticket 只读；返回 bit。
  // 失败/边界：任一为空、identity shape 非法或字段不一致返回 0。
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

  // 功能：判断 observed result 是否完全没有提交身份图。
  // 输入/输出及副作用：value 只读；返回 bit。
  // 失败/边界：value 为 null 返回 0；ticket/identity/owner/DMA/completion 任一存在或 batch/attempt 非零即非空。
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

  // 功能：校验 observed result 的身份图完整且 ticket、identity、owner、DMA context 互相一致。
  // 输入/输出及副作用：value 只读；调用 dma_context.validate()，不复制或提交 authority。
  // 失败/边界：半成品图、零 batch/attempt、ticket/identity 漂移、非 legacy owner 的 generation/reset epoch 不一致或 DMA
  //   校验失败返回 0。
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

  // 功能：确认结果是 adapter 在 engine 之前确定拒绝的 PRE_SUBMIT_REJECTED envelope。
  // 输入/输出及副作用：value 只读；返回 bit。
  // 失败/边界：status/observation 缺失或失败、effect 非 PRE、身份图非空、有 completion 或 recovery 标志均返回 0。
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

  // 功能：对 observed result 做 effect/phase/recovery 语义交叉校验，并检查 completion 的别名拓扑。
  // 输入/输出及副作用：value 只读；返回 bit。
  // 失败/边界：枚举未知、phase 与 effect 组合非法、completion 缺失/多余或未别名 result 的 ticket/status、身份图漂移均返回 0。
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

  // 功能：把 engine 绑定到 Function handle。
  // 输入/输出及副作用：成功时写入 engines，不接管 engine 所有权。
  // 失败/边界：owner/engine 为空、owner 非 Function 或含 X/Z 返回 INVALID_ARGUMENT；重复绑定返回 INVALID_STATE。
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

  // 功能：legacy execute 入口，包装 execute_observed 并回填 ticket/completion/status。
  // 输入/输出及副作用：先清空输出和 no-submit 标志；仅当结果通过 legacy_no_submit_result_valid 才置标志。
  // 失败/边界：observed result 为 null 时 status 为 INVALID_STATE。
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

  // 功能：按 command 的 Function 找到 engine 并执行 observed 路径，返回 detached result。
  // 输入/输出及副作用：result 为调用方持有输出；成功绑定时恰好调用一次 engine.execute_observed。
  // 失败/边界：Function 缺失或未绑定返回 PRE_SUBMIT_REJECTED；engine 返回 null 或缺 status 时补 INVALID_STATE；envelope
  //   非法时标记 observation_status。
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

  // 功能：把 ticket 对账转发给对应 engine 的 reconcile_ticket。
  // 输入/输出及副作用：terminal_known/completion/status 为输出；status 为 engine status 的克隆。
  // 失败/边界：ticket 或 Function 缺失、未绑定、engine status 为 null、克隆失败、terminal 却无 completion 均返回
  //   INVALID_STATE 并清除输出。
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
