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

  // 功能：检查 observed execution result 的 effect/phase/completion 形状，阻止
  //   adapter 把不可能 envelope 当作可靠 lifecycle 证据继续发布。
  // 输入/输出及副作用：value 为只读 engine 输出；返回布尔形状判定，不修改 value。
  // 失败/边界：未知枚举、pending/terminal 与 completion nullness 矛盾均拒绝；
  //   operation status 与 effects 不被该检查改写。
  protected function bit observed_result_shape_valid(
    input rdma_cmq_execution_result value
  );
    if (value == null || value.status == null ||
        value.observation_status == null ||
        !rdma_cmq_status_shape_valid(value.status) ||
        !rdma_cmq_status_shape_valid(value.observation_status) ||
        !rdma_cmq_submission_effect_valid(value.submission_effect) ||
        !rdma_cmq_submission_effect_valid(value.attempt_effect) ||
        !rdma_cmq_completion_phase_valid(value.completion_phase))
      return 1'b0;
    if (value.completion_phase == RDMA_CMQ_COMPLETION_PENDING &&
        value.completion != null)
      return 1'b0;
    if (value.completion_phase == RDMA_CMQ_COMPLETION_NONE &&
        value.completion != null)
      return 1'b0;
    if (value.completion_phase == RDMA_CMQ_COMPLETION_UNOBSERVED &&
        (value.submission_effect != RDMA_SUBMIT_EFFECT_UNOBSERVED ||
         value.attempt_effect != RDMA_SUBMIT_EFFECT_UNOBSERVED ||
         value.recovery_required != 1'b1))
      return 1'b0;
    if (value.submission_effect == RDMA_SUBMIT_EFFECT_PRE_SUBMIT_REJECTED &&
        (value.attempt_effect != RDMA_SUBMIT_EFFECT_PRE_SUBMIT_REJECTED ||
         value.completion_phase != RDMA_CMQ_COMPLETION_NONE ||
         value.recovery_required != 1'b0))
      return 1'b0;
    if (value.completion_phase == RDMA_CMQ_COMPLETION_PENDING &&
        value.submission_effect inside {
          RDMA_SUBMIT_EFFECT_UNOBSERVED,
          RDMA_SUBMIT_EFFECT_PRE_SUBMIT_REJECTED
        })
      return 1'b0;
    if (value.completion_phase inside {
          RDMA_CMQ_COMPLETION_TERMINAL,
          RDMA_CMQ_COMPLETION_TIMEOUT,
          RDMA_CMQ_COMPLETION_DIAGNOSTIC_ONLY,
          RDMA_CMQ_COMPLETION_RESET_CANCELLED
        } && value.completion == null)
      return 1'b0;
    if (value.completion != null &&
        (value.completion.status == null ||
         !rdma_cmq_status_shape_valid(value.completion.status) ||
         value.completion.ticket == null ||
         (value.ticket != null &&
          (value.completion.ticket.command_id != value.ticket.command_id ||
           value.completion.ticket.slot_sequence != value.ticket.slot_sequence ||
           value.completion.ticket.sq_index != value.ticket.sq_index ||
           value.completion.ticket.sq_wrap != value.ticket.sq_wrap ||
           value.completion.ticket.function_h == null ||
           value.ticket.function_h == null ||
           !value.completion.ticket.function_h.same_instance(value.ticket.function_h) ||
           value.completion.ticket.cmq_h == null ||
           value.ticket.cmq_h == null ||
           !value.completion.ticket.cmq_h.same_instance(value.ticket.cmq_h)))))
      return 1'b0;
    return 1'b1;
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
    if (observed_result.status != null &&
        observed_result.status.code == RDMA_SC_INVALID_STATE &&
        observed_result.submission_effect ==
          RDMA_SUBMIT_EFFECT_PRE_SUBMIT_REJECTED &&
        observed_result.batch_id == 0 && observed_result.attempt_id == 0 &&
        observed_result.batch_key.len() == 0 &&
        observed_result.recovery_required == 1'b0)
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
    if (!observed_result_shape_valid(result))
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
