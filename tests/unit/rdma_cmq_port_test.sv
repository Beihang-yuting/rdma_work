// 目录：测试层 unit/rdma_cmq_port_test.sv。
// 职责：验证 rdma_cmq_port_test 对应模块的接口、错误路径和边界行为。
// 依赖：依赖被测 package、UVM 测试基类和必要的 mock/fixture。
// 所有权与生命周期：测试对象只拥有本地 fixture；外部后端句柄由测试环境提供并在测试结束释放。

// 中文说明：rdma_cmq_port_test.sv 属于单元测试，覆盖对应模型、编码器或执行器契约。
// 阅读提示：先看公开类型和接口，再看实现细节；失败路径应保持状态与资源所有权可追踪。

// 设计说明：该 probe 只暴露 production adapter 的 observed envelope 判定，
//   不绑定 engine 或外部资源；它用于把身份图的 fail-closed 决策表写成独立测试。
class rdma_cmq_observed_semantics_probe extends rdma_cmq_engine_port_adapter;
  `uvm_object_utils(rdma_cmq_observed_semantics_probe)

  // 功能：构造 observed semantics probe，继承 adapter 的空绑定表和兼容位默认值。
  // 输入/输出及副作用：name 传给父类；只建立本地 UVM 对象，不登记 engine。
  // 失败/边界：probe 未绑定 Function 时不能执行真实命令，仅可调用纯 envelope 判定。
  function new(string name = "rdma_cmq_observed_semantics_probe");
    super.new(name);
  endfunction

  // 功能：调用 adapter 内部 observed_result_semantics_valid，检查 phase/effect 与
  //   ticket、identity、owner、DMA 和 batch/attempt 图的完整性。
  // 输入/输出及副作用：value 为只读结果图；返回 production 判定，不修改 value 或
  //   adapter 兼容状态，也不触发 engine/外部 I/O。
  // 失败/边界：任何未知枚举、半成品身份或 completion alias 不一致均按生产规则拒绝；
  //   该 wrapper 不增加额外放宽条件。
  function bit semantics_valid(rdma_cmq_execution_result value);
    return observed_result_semantics_valid(value);
  endfunction
endclass

// 设计说明：该 adapter 模拟 delegated engine 返回一个看似 PRE rejection、但
//   observation_status 已失败的 malformed envelope，用于保护 no-submit 判定不被伪造。
class rdma_cmq_malformed_delegated_adapter
  extends rdma_cmq_engine_port_adapter;
  `uvm_object_utils(rdma_cmq_malformed_delegated_adapter)

  // 功能：构造 malformed delegated adapter，保留父类的空 engine registry。
  // 输入/输出及副作用：name 传给父类；不创建 engine、DMA 或 scheduler 资源。
  // 失败/边界：该对象只用于 no-submit 判定测试，不能代表真实 observed route。
  function new(string name = "rdma_cmq_malformed_delegated_adapter");
    super.new(name);
  endfunction

  // 功能：返回一个身份全空、PRE effect 正确但 observation_status 非 OK 的 delegated
  //   result，模拟下游恶意/损坏实现试图伪造“确定未提交”证明。
  // 输入/输出及副作用：command 为只读输入，result 为 caller-owned 新结果；不修改
  //   command、adapter registry 或任何外部资源。
  // 失败/边界：无论 command 内容如何都返回 malformed observation；调用方必须把
  //   该 envelope 当作不可靠证据，不能判定为确定未提交。
  virtual task execute_observed(
    input rdma_cmq_command_desc command,
    output rdma_cmq_execution_result result
  );
    result = new("malformed_delegated_result");
    result.status = rdma_cmq_direct_status(
      RDMA_SC_INVALID_STATE, "delegated local rejection"
    );
    result.observation_status = rdma_cmq_direct_status(
      RDMA_SC_INVALID_STATE, "delegated observation is malformed"
    );
    result.submission_effect = RDMA_SUBMIT_EFFECT_PRE_SUBMIT_REJECTED;
    result.attempt_effect = RDMA_SUBMIT_EFFECT_PRE_SUBMIT_REJECTED;
    result.completion_phase = RDMA_CMQ_COMPLETION_NONE;
    result.batch_key = "";
    result.batch_id = 0;
    result.attempt_id = 0;
    result.recovery_required = 1'b0;
    result.ticket = null;
    result.completion = null;
    result.command_identity = null;
    result.recovery_owner = null;
    result.dma_context = null;
  endtask
endclass

class rdma_cmq_port_test extends rdma_cmq_engine_test;
  `uvm_component_utils(rdma_cmq_port_test)

  // 功能：构造 rdma_cmq_port_test，调用 super.new 建立 UVM 层级对象；外部依赖字段保持未绑定，后续由 configure/build/activate 明确注入。
  // 输入/输出及副作用：name、parent（输入）；new 只写入构造体列出的默认字段并返回 void，外部依赖与资源所有权仍由上层管理。
  // 失败/边界：rdma_cmq_port_test 构造只建立本地初始状态，不接管外部 Host-memory、PCIe 或 manager；未完成后续 configure/build/activate 时，业务入口必须返回 INVALID_STATE。
  function new(string name = "rdma_cmq_port_test",
               uvm_component parent = null);
    super.new(name, parent);
  endfunction

  // 功能：验证 production adapter 的 observed 入口对 pre-engine Function 拒绝
  //   直接发布 PRE_SUBMIT_REJECTED 证据，而不是退回 legacy UNOBSERVED fallback。
  // 输入/输出及副作用：无显式输入；构造空 command 并调用 adapter.execute_observed，
  //   仅产生 caller-owned result，不接管外部资源。
  // 失败/边界：当前 adapter 若仍继承 base 反向 fallback，结果会被标成
  //   UNOBSERVED/recovery_required；该差异必须以 UVM_ERROR 暴露为 RED。
  task automatic check_production_observed_pre_rejection();
    rdma_cmq_engine_port_adapter adapter;
    rdma_cmq_malformed_delegated_adapter malformed_adapter;
    rdma_cmq_observed_semantics_probe semantics_probe;
    rdma_cmq_execution_result malformed_result;
    rdma_cmq_execution_result result;
    rdma_status status;

    adapter = rdma_cmq_engine_port_adapter::type_id::create(
      "production_observed_pre_rejection_adapter"
    );
    adapter.execute_observed(null, result);
    if (result == null || result.status == null ||
        result.observation_status == null ||
        result.submission_effect != RDMA_SUBMIT_EFFECT_PRE_SUBMIT_REJECTED ||
        result.attempt_effect != RDMA_SUBMIT_EFFECT_PRE_SUBMIT_REJECTED ||
        result.completion_phase != RDMA_CMQ_COMPLETION_NONE ||
        result.recovery_required != 1'b0 ||
        !rdma_cmq_result_no_submit_proven(result))
      `uvm_error("PRODUCTION_OBSERVED_PRE_REJECT",
                 "production observed pre-engine rejection contract is missing")

    // 非 PRE 的 NONE 不能用全空 evidence 伪装成可恢复或已拒绝结果。
    semantics_probe = rdma_cmq_observed_semantics_probe::type_id::create(
      "observed_semantics_probe"
    );
    malformed_result = new("none_without_identity");
    malformed_result.status = rdma_cmq_direct_status(RDMA_SC_OK);
    malformed_result.observation_status = rdma_cmq_direct_status(RDMA_SC_OK);
    malformed_result.submission_effect =
      RDMA_SUBMIT_EFFECT_HOST_MEMORY_MAYBE_VISIBLE;
    malformed_result.attempt_effect =
      RDMA_SUBMIT_EFFECT_HOST_MEMORY_MAYBE_VISIBLE;
    malformed_result.completion_phase = RDMA_CMQ_COMPLETION_NONE;
    malformed_result.recovery_required = 1'b1;
    if (semantics_probe.semantics_valid(malformed_result))
      `uvm_error("OBSERVED_NONE_IDENTITY_GATE",
                 "NONE result with no identity graph was accepted")

    // UNOBSERVED 允许 post-delegation 的全空 envelope，但不允许只带 batch/id
    //   的半成品；否则调用方可能把不属于任何 journal 的证据送进恢复。
    malformed_result = new("unobserved_partial_batch");
    malformed_result.status = rdma_cmq_direct_status(RDMA_SC_INVALID_STATE);
    malformed_result.observation_status = rdma_cmq_direct_status(
      RDMA_SC_INVALID_STATE
    );
    malformed_result.submission_effect = RDMA_SUBMIT_EFFECT_UNOBSERVED;
    malformed_result.attempt_effect = RDMA_SUBMIT_EFFECT_UNOBSERVED;
    malformed_result.completion_phase = RDMA_CMQ_COMPLETION_UNOBSERVED;
    malformed_result.batch_key = "partial-batch";
    malformed_result.batch_id = 1;
    malformed_result.recovery_required = 1'b1;
    if (semantics_probe.semantics_valid(malformed_result))
      `uvm_error("OBSERVED_UNOBSERVED_PARTIAL_GATE",
                 "UNOBSERVED partial batch identity was accepted")

    // delegated result 即使伪造 PRE effect/zero IDs，只要 observation_status
    //   非 OK，也不能被判定为“确定未提交”。
    malformed_adapter =
      rdma_cmq_malformed_delegated_adapter::type_id::create(
        "malformed_delegated_adapter"
      );
    malformed_adapter.execute_observed(null, malformed_result);
    if (rdma_cmq_result_no_submit_proven(malformed_result))
      `uvm_error("LEGACY_NO_SUBMIT_MALFORMED",
                 "malformed delegated result set no-submit proof")
  endtask

  // 功能：在 rdma_cmq_port_test 中，next_generation_binding 配置测试 fixture 的定向故障或替代依赖，使下一次调用覆盖指定边界路径。
  // 输入/输出及副作用：name（输入）、binding_state（输入）、generation_delta（输入）；next_generation_binding 读取 name、binding_state、generation_delta 并使用字段 binding、binding.owner_h；函数返回 rdma_function_binding，不取得调用方资源所有权。
  // 失败/边界：next_generation_binding 的结果直接由 return binding 计算；输入不满足表达式条件时沿函数体的保守分支返回，不修改已发布账本。
  function automatic rdma_function_binding next_generation_binding(
    string name,
    rdma_binding_state_e binding_state,
    int unsigned generation_delta
  );
    rdma_function_binding binding;

    binding = make_binding(name, binding_state);
    binding.generation += generation_delta;
    binding.owner_h = binding.make_handle();
    return binding;
  endfunction

  // 功能：验证 mock CMQ 的失败、超时、晚完成和成功 FIFO 顺序，并确认 ticket
  //   从调用快照派生、absolute_deadline 使用调用时刻加 command.timeout。
  // 输入/输出及副作用：无显式输入；构造三条 command 和注入结果，调用 execute/
  //   reconcile，消费一次 late completion，并以 UVM assertion 发布可观察结果。
  // 失败/边界：缺失 detached ticket/completion、错误序列、重复消费、caller 突变
  //   泄漏，或非零仿真时刻下 deadline 仍按裸 timeout 比较时报告 UVM_ERROR。
  task automatic check_mock_fifo_status_and_reconcile();
    rdma_function_binding binding;
    rdma_mock_cmq_port mock_cmq;
    rdma_cmq_port port;
    rdma_cmq_command_desc command;
    rdma_cmq_command_desc timeout_command;
    rdma_cmq_command_desc success_command;
    rdma_cmq_ticket ticket;
    rdma_cmq_ticket timeout_ticket;
    rdma_cmq_completion completion;
    rdma_status injected_status;
    rdma_status late_status;
    rdma_status status;
    rdma_cmq_sqe_model recorded_body;
    bit terminal_known;
    bit [7:0] opcodes[$];
    int unsigned saved_generation;
    bit [31:0] saved_opcode;
    int unsigned saved_flags;
    time execute_started_at;

    binding = make_binding("mock_port_binding", RDMA_BIND_ACTIVE);
    mock_cmq = rdma_mock_cmq_port::type_id::create("mock_cmq");
    port = mock_cmq;
    command = make_command("mock_fail_command", binding,
                           RDMA_OP_KEY_ALLOC, 8'h31, 1us);
    timeout_command = make_command("mock_timeout_command", binding,
                                   RDMA_OP_KEY_ALLOC, 8'h32, 1us);
    success_command = make_command("mock_success_command", binding,
                                   RDMA_OP_KEY_ALLOC, 8'h33, 1us);
    injected_status = rdma_status::make(
      RDMA_SC_DMA_PERMISSION, "injected key failure"
    );
    mock_cmq.fail_opcode(RDMA_OP_KEY_ALLOC, injected_status);
    mock_cmq.timeout_opcode(RDMA_OP_KEY_ALLOC);
    injected_status.message = "caller mutation";

    saved_generation = command.function_h.generation;
    saved_opcode = command.opcode_key.opcode;
    if (!$cast(recorded_body, command.body))
      `uvm_fatal("MOCK_PORT_FIXTURE", "command body has an unexpected type")
    saved_flags = recorded_body.flags;
    // 中文：ticket 保存绝对截止时刻；先记录本次无阻塞 mock 调用的起点，既保留
    // 前序 fallback 的非零时间覆盖，也避免把 timeout 时长误当成绝对时间。
    execute_started_at = $time;
    mock_cmq.execute(command, ticket, completion, status);
    expect_status("MOCK_PORT_FAIL_STATUS", status, RDMA_SC_DMA_PERMISSION);
    if (ticket == null || completion == null ||
        completion.status == null || completion.raw_cqe == null ||
        mock_cmq.calls.size() != 1 || mock_cmq.calls[0] == null ||
        mock_cmq.calls[0].ticket == null)
      `uvm_error("MOCK_PORT_FAIL_RESULT",
                 "failure outcome did not retain complete call/result state")
    else begin
      expect_status("MOCK_PORT_FAIL_COMPLETION", completion.status,
                    RDMA_SC_DMA_PERMISSION);
      if (status == completion.status || status.message !=
          "injected key failure")
        `uvm_error("MOCK_PORT_FAIL_DETACH",
                   "failure status was not returned as a detached value")
      if (ticket.function_h == null || ticket.opcode_key == null ||
          ticket.command_id != 1 ||
          ticket.function_h.generation != saved_generation ||
          ticket.opcode_key.opcode != saved_opcode ||
          ticket.absolute_deadline != execute_started_at + command.timeout ||
          mock_cmq.calls[0].\sequence  != 1 ||
          mock_cmq.calls[0].ticket.command_id != ticket.command_id)
        `uvm_error("MOCK_PORT_TICKET_ORIGIN",
                   "ticket identity did not originate from the call snapshot")
    end

    command.function_h.generation++;
    command.opcode_key.opcode = 8'hfe;
    recorded_body.flags = 32'hfeed_beef;
    if (mock_cmq.calls[0] == null || mock_cmq.calls[0].command == null ||
        mock_cmq.calls[0].ticket == null ||
        mock_cmq.calls[0].command == command ||
        mock_cmq.calls[0].ticket == ticket ||
        mock_cmq.calls[0].command.function_h == command.function_h ||
        mock_cmq.calls[0].command.opcode_key == command.opcode_key ||
        mock_cmq.calls[0].command.function_h.generation != saved_generation ||
        mock_cmq.calls[0].command.opcode_key.opcode != saved_opcode ||
        !$cast(recorded_body, mock_cmq.calls[0].command.body) ||
        recorded_body.flags != saved_flags)
      `uvm_error("MOCK_PORT_CALL_DETACH",
                 "recorded call changed with caller-owned command/ticket")

    mock_cmq.execute(timeout_command, timeout_ticket, completion, status);
    expect_status("MOCK_PORT_TIMEOUT_STATUS", status, RDMA_SC_TIMEOUT);
    if (timeout_ticket == null || completion == null ||
        completion.ticket == null || completion.status == null ||
        completion.raw_cqe != null || mock_cmq.calls.size() != 2 ||
        mock_cmq.calls[1] == null || mock_cmq.calls[1].ticket == null ||
        timeout_ticket.command_id != 2 ||
        mock_cmq.calls[1].\sequence  != 2)
      `uvm_error("MOCK_PORT_TIMEOUT_RESULT",
                 "timeout did not retain a ticket and timeout completion")
    else
      expect_status("MOCK_PORT_TIMEOUT_COMPLETION", completion.status,
                    RDMA_SC_TIMEOUT);

    late_status = rdma_status::success("late hardware completion");
    mock_cmq.push_late_completion(timeout_ticket, late_status);
    late_status.code = RDMA_SC_INVALID_STATE;
    port.reconcile(timeout_ticket, terminal_known, completion, status);
    expect_status("MOCK_PORT_RECONCILE_STATUS", status, RDMA_SC_OK);
    if (!terminal_known || completion == null || completion.status == null ||
        completion.raw_cqe == null ||
        completion.ticket == timeout_ticket)
      `uvm_error("MOCK_PORT_RECONCILE_RESULT",
                 "late completion was not returned detached and complete")
    else
      expect_status("MOCK_PORT_RECONCILE_COMPLETION", completion.status,
                    RDMA_SC_OK);
    port.reconcile(timeout_ticket, terminal_known, completion, status);
    expect_status("MOCK_PORT_RECONCILE_ONCE", status, RDMA_SC_OK);
    if (terminal_known || completion != null)
      `uvm_error("MOCK_PORT_RECONCILE_ONCE",
                 "late completion was consumed more than once")

    mock_cmq.execute(success_command, ticket, completion, status);
    expect_status("MOCK_PORT_DEFAULT_STATUS", status, RDMA_SC_OK);
    if (ticket == null || completion == null ||
        completion.status == null || completion.raw_cqe == null ||
        mock_cmq.calls.size() != 3)
      `uvm_error("MOCK_PORT_DEFAULT_RESULT",
                 "default success did not produce a complete result")
    mock_cmq.get_opcodes(opcodes);
    if (opcodes.size() != 3 ||
        opcodes[0] != RDMA_OP_KEY_ALLOC ||
        opcodes[1] != RDMA_OP_KEY_ALLOC ||
        opcodes[2] != RDMA_OP_KEY_ALLOC)
      `uvm_error("MOCK_PORT_OPCODE_ORDER",
                 "mock call opcode order does not match execute order")
  endtask

  // 功能：在测试辅助 rdma_cmq_port_test.check_mock_gate_prerelease 中构造或驱动“mock gate prerelease”场景，并断言 DUT 的状态、错误码和资源账本符合契约。
  // 输入/输出及副作用：无显式参数；fixture/输入由测试调用方提供；执行时会产生 UVM assertion/report，不向 DUT 转移未声明的资源所有权。
  // 失败/边界：fixture 未初始化、故障注入未生效或观测值与预期不一致时报告 UVM_ERROR/断言失败；测试不会吞掉失败。
  task automatic check_mock_gate_prerelease();
    rdma_function_binding binding;
    rdma_mock_cmq_port mock_cmq;
    rdma_cmq_command_desc command;
    rdma_cmq_ticket ticket;
    rdma_cmq_completion completion;
    rdma_status status;
    bit execute_completed;

    binding = make_binding("mock_gate_prerelease_binding", RDMA_BIND_ACTIVE);
    mock_cmq = rdma_mock_cmq_port::type_id::create(
      "mock_gate_prerelease_cmq"
    );
    command = make_command(
      "mock_gate_prerelease_command", binding, RDMA_OP_KEY_ALLOC,
      8'h34, 1us
    );
    mock_cmq.gate_opcode(RDMA_OP_KEY_ALLOC);
    mock_cmq.release_one();
    execute_completed = 1'b0;
    fork : wait_for_mock_gate_prerelease
      begin
        mock_cmq.execute(command, ticket, completion, status);
        execute_completed = 1'b1;
      end
      begin
        #100ns;
      end
    join_any
    disable wait_for_mock_gate_prerelease;

    if (!execute_completed)
      `uvm_error("MOCK_GATE_PRERELEASE_TIMEOUT",
                 "pre-released mock gate did not complete execute")
    else begin
      expect_status("MOCK_GATE_PRERELEASE_STATUS", status, RDMA_SC_OK);
      if (ticket == null || completion == null ||
          completion.status == null || mock_cmq.calls.size() != 1)
        `uvm_error("MOCK_GATE_PRERELEASE_RESULT",
                   "pre-released mock gate returned an incomplete result")
    end
  endtask

  // 功能：把 fixture 改写为另一个 Function（uid/global id/BDF 均不同），用于多 engine 路由。
  // 输入/输出及副作用：修改 fx 的 binding 与 CMQ。
  // 失败/边界：identity 重建失败时报告 UVM_ERROR。
  function automatic void retarget_fixture(string label, rdma_cmq_engine_fixture fx);
    rdma_function_binding bindings[2];

    bindings = '{fx.prepared, fx.active};
    foreach (bindings[i]) begin
      bindings[i].function_uid++;
      bindings[i].global_function_id++;
      bindings[i].pcie.bdf.function_num = 3'h2;
      bindings[i].queue_dma.requester_bdf = bindings[i].pcie.bdf;
      expect_status({label, "_IDENTITY"},
                    bindings[i].configure_identity_from_legacy_mirrors(16'h0, 32'h1,
                                                                       RDMA_FUNCTION_PF),
                    RDMA_SC_OK);
      bindings[i].owner_h = bindings[i].make_handle();
    end
    fx.cmq = make_cmq({label, "_cmq"}, fx.prepared);
  endfunction

  // 功能：两个 Function 各绑定一个真实 engine，adapter 按 command Function 路由；A 正常完成，
  //   B 的设备丢弃完成而看门狗超时；reconcile 恒无终态；未绑定 generation 不触达任何 engine。
  // 输入/输出及副作用：两套 fixture 各自 prepare/activate/shutdown。
  // 失败/边界：路由串线、证据缺失或绑定校验失效时报告 UVM_ERROR。
  task automatic check_adapter_routes_real_engines_by_function();
    rdma_cmq_engine_port_adapter adapter;
    rdma_cmq_engine_fixture fx_a;
    rdma_cmq_engine_fixture fx_b;
    rdma_cmq_execution_result result_a;
    rdma_cmq_ticket ticket_b;
    rdma_cmq_ticket unbound_ticket;
    rdma_cmq_completion completion_b;
    rdma_cmq_completion unbound_completion;
    rdma_cmq_completion reconciled;
    rdma_function_binding unbound_binding;
    rdma_function_handle wrong_owner;
    rdma_status status_b;
    rdma_status status;
    bit no_submit_b;
    bit terminal_known;

    adapter = rdma_cmq_engine_port_adapter::type_id::create("adapter");
    build_fixture("adapter_a", fx_a);
    build_fixture("adapter_b", fx_b);
    retarget_fixture("ADAPTER_B", fx_b);
    start_fixture("ADAPTER_A", fx_a);
    start_fixture("ADAPTER_B", fx_b);

    expect_status("ADAPTER_BIND_A", adapter.bind_engine(fx_a.active.make_handle(), fx_a.engine),
                  RDMA_SC_OK);
    expect_status("ADAPTER_BIND_B", adapter.bind_engine(fx_b.active.make_handle(), fx_b.engine),
                  RDMA_SC_OK);
    expect_status("ADAPTER_BIND_DUPLICATE",
                  adapter.bind_engine(fx_a.active.make_handle(), fx_b.engine),
                  RDMA_SC_INVALID_STATE);
    expect_status("ADAPTER_BIND_NULL_OWNER", adapter.bind_engine(null, fx_a.engine),
                  RDMA_SC_INVALID_ARGUMENT);
    wrong_owner = fx_a.active.make_handle();
    wrong_owner.kind = RDMA_RESOURCE_CMQ;
    expect_status("ADAPTER_BIND_WRONG_OWNER", adapter.bind_engine(wrong_owner, fx_a.engine),
                  RDMA_SC_INVALID_ARGUMENT);
    expect_status("ADAPTER_BIND_NULL_ENGINE",
                  adapter.bind_engine(fx_a.active.make_handle(), null),
                  RDMA_SC_INVALID_ARGUMENT);

    // A 走 observed API，B 经 rdma_cmq_dispatch 拆包；两条路径并发且不串证据。
    fx_b.device.drop_next = 1'b1;
    fork
      adapter.execute_observed(make_hw_command("adapter_command_a", fx_a.active,
                                               RDMA_OP_TQ_FLUSH), result_a);
      rdma_cmq_dispatch(adapter, make_hw_command("adapter_command_b", fx_b.active,
                                                 RDMA_OP_OCC_FLUSH, 300ns),
                        ticket_b, completion_b, status_b, no_submit_b,
                        "adapter unavailable", "adapter command is null");
    join
    expect_terminal("ADAPTER_EXECUTE_A", result_a);
    if (result_a != null)
      expect_status("ADAPTER_EXECUTE_A", result_a.status, RDMA_SC_OK);
    expect_status("ADAPTER_EXECUTE_B", status_b, RDMA_SC_TIMEOUT);
    if (result_a == null || result_a.ticket == null || ticket_b == null ||
        completion_b == null || completion_b.raw_cqe != null || no_submit_b ||
        result_a.ticket.function_h.function_uid != fx_a.active.function_uid ||
        ticket_b.function_h.function_uid != fx_b.active.function_uid ||
        fx_a.device.observed_opcodes.size() != 1 || fx_b.device.observed_opcodes.size() != 1 ||
        fx_a.device.observed_opcodes[0] != RDMA_OP_TQ_FLUSH ||
        fx_b.device.observed_opcodes[0] != RDMA_OP_OCC_FLUSH ||
        fx_a.engine.state() != RDMA_CMQ_ENGINE_ACTIVE ||
        fx_b.engine.state() != RDMA_CMQ_ENGINE_POISONED)
      `uvm_error("ADAPTER_REAL_ROUTE", "commands did not reach their Function-specific engines")

    adapter.reconcile(ticket_b, terminal_known, reconciled, status);
    expect_status("ADAPTER_RECONCILE_ROUTE", status, RDMA_SC_INVALID_STATE);
    if (terminal_known || reconciled != null)
      `uvm_error("ADAPTER_RECONCILE_ROUTE", "reconcile reported a terminal completion")

    unbound_binding = next_generation_binding("adapter_unbound", RDMA_BIND_ACTIVE, 2);
    rdma_cmq_dispatch(adapter, make_hw_command("adapter_unbound_command", unbound_binding,
                                               RDMA_OP_TQ_FLUSH),
                      unbound_ticket, unbound_completion, status, no_submit_b,
                      "adapter unavailable", "adapter command is null");
    expect_status("ADAPTER_UNBOUND_GENERATION", status, RDMA_SC_INVALID_STATE);
    if (unbound_ticket != null || unbound_completion != null ||
        fx_a.engine.published_count() != 1 || fx_b.engine.published_count() != 1)
      `uvm_error("ADAPTER_UNBOUND_GENERATION", "unbound generation reached a different engine")

    stop_fixture("ADAPTER_A", fx_a);
    stop_fixture("ADAPTER_B", fx_b);
  endtask

  // 功能：逐项验证 command identity 的无 factory 形状判断与既有 Function/opcode
  //   validator 接受集合一致，覆盖空节点、非法 kind/generation、分隔符和零 opcode。
  // 输入/输出及副作用：无显式输入；为每个 case 新建 command/identity，并调用
  //   capture_from、rdma_cmq_function_status 和 opcode_key.validate 生成 UVM 断言。
  // 失败/边界：任一接受结果偏离手工真值或两套 validator 语义不一致时报告
  //   UVM_ERROR；fixture 不安装 factory override，也不推进仿真时间。
  task automatic check_command_identity_capture_equivalence();
    rdma_function_binding binding;
    rdma_cmq_command_desc command;
    rdma_cmq_command_desc tested_command;
    rdma_cmq_command_identity identity;
    rdma_status function_status;
    rdma_status opcode_status;
    string failure_reason;
    bit capture_accepts;
    bit validators_accept;
    bit expected_accept;

    binding = make_binding("identity_equivalence_binding", RDMA_BIND_ACTIVE);
    for (int unsigned case_index = 0; case_index < 11; case_index++) begin
      command = make_command(
        $sformatf("identity_equivalence_%0d", case_index), binding,
        RDMA_OP_CQC_QUERY, byte'(8'h80 + case_index), 1us
      );
      tested_command = command;
      expected_accept = (case_index == 0 || case_index == 10);
      case (case_index)
        1: tested_command = null;
        2: command.function_h = null;
        3: command.opcode_key = null;
        4: command.function_h.kind = RDMA_RESOURCE_CMQ;
        5: command.function_h.generation = 0;
        6: command.opcode_key.profile_name = "";
        7: command.opcode_key.variant = "";
        8: command.opcode_key.profile_name = "bad|profile";
        9: command.opcode_key.variant = "bad|variant";
        10: command.opcode_key.opcode = 0;
        default: begin
        end
      endcase

      identity = new($sformatf("identity_equivalence_result_%0d", case_index));
      capture_accepts = identity.capture_from(tested_command, failure_reason);
      validators_accept = 1'b0;
      function_status = null;
      opcode_status = null;
      if (tested_command != null) begin
        function_status = rdma_cmq_function_status(
          tested_command.function_h, "CMQ command identity equivalence"
        );
        if (function_status != null && function_status.ok() &&
            tested_command.opcode_key != null) begin
          opcode_status = tested_command.opcode_key.validate();
          if (opcode_status != null && opcode_status.ok())
            validators_accept = 1'b1;
        end
      end

      if (capture_accepts != expected_accept ||
          validators_accept != expected_accept ||
          capture_accepts != validators_accept ||
          (capture_accepts && failure_reason != "") ||
          (!capture_accepts && failure_reason == ""))
        `uvm_error(
          "COMMAND_IDENTITY_CAPTURE_EQUIVALENCE",
          $sformatf(
            "case=%0d expected=%0b capture=%0b validators=%0b reason='%s'",
            case_index, expected_accept, capture_accepts, validators_accept,
            failure_reason
          )
        )
    end
  endtask

  // 功能：按顺序执行 identity 等价性、legacy fallback、mock 与 real-engine port
  //   场景，使 factory override 前置条件和后续非零时间 deadline 覆盖保持确定。
  // 输入/输出及副作用：phase 为 UVM 输入；持有一次 objection，调用本类五个检查
  //   task 并由它们发布 UVM assertion，最后释放 objection。
  // 失败/边界：子检查通过 UVM_ERROR/FATAL 报告契约偏差；本 task 不吞掉失败，
  //   正常路径始终在全部同步检查返回后 drop_objection。
  virtual task run_phase(uvm_phase phase);
    phase.raise_objection(this);
    check_production_observed_pre_rejection();
    check_command_identity_capture_equivalence();
    check_mock_fifo_status_and_reconcile();
    check_mock_gate_prerelease();
    check_adapter_routes_real_engines_by_function();
    phase.drop_objection(this);
  endtask
endclass
