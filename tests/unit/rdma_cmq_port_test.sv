// 目录：测试层 unit/rdma_cmq_port_test.sv。
// 职责：验证 rdma_cmq_port_test 对应模块的接口、错误路径和边界行为。
// 依赖：依赖被测 package、UVM 测试基类和必要的 mock/fixture。
// 所有权与生命周期：测试对象只拥有本地 fixture；外部后端句柄由测试环境提供并在测试结束释放。

// 中文说明：rdma_cmq_port_test.sv 属于单元测试，覆盖对应模型、编码器或执行器契约。
// 阅读提示：先看公开类型和接口，再看实现细节；失败路径应保持状态与资源所有权可追踪。

class rdma_cmq_late_pair_probe extends rdma_cmq_engine_probe;
  `uvm_object_utils(rdma_cmq_late_pair_probe)

  // 功能：构造 rdma_cmq_late_pair_probe，调用 super.new 建立 UVM 层级对象；外部依赖字段保持未绑定，后续由 configure/build/activate 明确注入。
  // 输入/输出及副作用：name（输入）；new 只写入构造体列出的默认字段并返回 void，外部依赖与资源所有权仍由上层管理。
  // 失败/边界：rdma_cmq_late_pair_probe 构造只建立本地初始状态，不接管外部 Host-memory、PCIe 或 manager；未完成后续 configure/build/activate 时，业务入口必须返回 INVALID_STATE。
  function new(string name = "rdma_cmq_late_pair_probe");
    super.new(name);
  endfunction

  // 功能：late_final_count 只读当前账本/队列状态并计算 int unsigned 计数或可用容量，不推进任何事务游标。
  // 输入/输出及副作用：无显式参数；late_final_count 读取固定返回值或局部计算结果，不使用对象成员字段；函数返回 int unsigned，不取得调用方资源所有权。
  // 失败/边界：late_final_count 的结果直接由 return late_final_fifo.size() 计算；输入不满足表达式条件时沿函数体的保守分支返回，不修改已发布账本。
  function int unsigned late_final_count();
    return late_final_fifo.size();
  endfunction
endclass

// 设计说明：该 payload 是 legacy port 允许直接按字段复制的最小已知测试类型，
// 用来区分 base fallback 的保守拒绝与子类明确授予的复制能力。
class rdma_legacy_direct_payload extends uvm_object;
  `uvm_object_utils(rdma_legacy_direct_payload)

  int unsigned value;

  // 功能：构造 legacy decoded-response fixture，并把可观察数值初始化为零。
  // 输入/输出及副作用：name 传给 uvm_object；仅写入本对象拥有的 value 字段。
  // 失败/边界：默认值不是有效完成语义；构造不申请 factory、DMA 或外部资源。
  function new(string name = "rdma_legacy_direct_payload");
    super.new(name);
    value = 0;
  endfunction
endclass

// 设计说明：该端口只实现遗留 execute()，用输出和输入的主动突变证明 base
// wrapper 必须先捕获 command/owner，且必须把遗留返回图复制为独立值。
class rdma_legacy_only_cmq_port extends rdma_mock_cmq_port;
  `uvm_object_utils(rdma_legacy_only_cmq_port)

  int unsigned execute_calls;
  rdma_cmq_ticket source_ticket;
  rdma_cmq_completion source_completion;
  rdma_status source_status;
  rdma_status returned_status;

  // 功能：构造 legacy-only CMQ port，并清空预置返回图与调用计数。
  // 输入/输出及副作用：name 传给父类；初始化本测试 adapter 自己拥有的引用槽位。
  // 失败/边界：未先 configure_response 时 execute 返回全空遗留输出；不接管 command。
  function new(string name = "rdma_legacy_only_cmq_port");
    super.new(name);
    execute_calls = 0;
    source_ticket = null;
    source_completion = null;
    source_status = null;
    returned_status = null;
  endfunction

  // 功能：在 factory 故障窗口前建立固定的 legacy ticket/status/completion 返回图。
  // 输入/输出及副作用：command、code、with_completion、null_status 和 payload 为输入；
  //   写入本 port 的 source 输出，正常 completion 的 outer 与 nested handle 保持别名。
  // 失败/边界：ticket/completion 构建失败时相关输出保持 null；null_status 只使
  //   execute 的 status 输出为空，不改变 completion 内部的已构造 status。
  function void configure_response(
    rdma_cmq_command_desc command,
    rdma_status_code_e code,
    bit with_completion,
    bit null_status,
    uvm_object payload = null
  );
    rdma_status build_status;

    source_ticket = null;
    source_completion = null;
    source_status = null;
    returned_status = null;
    build_status = rdma_cmq_direct_status(code, "legacy test response");
    if (make_ticket(command, 64'h5501, source_ticket) == null ||
        source_ticket == null)
      return;
    if (with_completion) begin
      source_completion = make_completion(
        source_ticket, build_status,
        !(code inside {RDMA_SC_TIMEOUT, RDMA_SC_RESET_CANCELLED})
      );
      if (source_completion == null)
        return;
      source_completion.decoded_response = payload;
      source_ticket = source_completion.ticket;
      source_status = source_completion.status;
    end
    else begin
      source_status = build_status;
    end
    returned_status = null_status ? null : source_status;
  endfunction

  // 功能：在 execute_observed 返回后同步改写遗留输出图，验证结果不泄露源引用。
  // 输入/输出及副作用：无显式输入；修改本 port 保留的 ticket/status/completion/payload，
  //   供调用方在同一时间槽立即断言已发布快照保持原值。
  // 失败/边界：任一可选节点为空时跳过该节点；该测试故障注入不释放外部资源。
  function void mutate_outputs_now();
    rdma_legacy_direct_payload payload;

    if (source_ticket != null)
      source_ticket.command_id = 64'hdead;
    if (source_status != null) begin
      source_status.code = RDMA_SC_INVALID_STATE;
      source_status.message = "legacy output mutated after return";
    end
    if (source_completion != null) begin
      source_completion.raw_cqe = null;
      if (source_completion.decoded_response != null &&
          $cast(payload, source_completion.decoded_response))
        payload.value++;
    end
  endfunction

  // 功能：返回预置 legacy 输出，并主动改写 caller command/owner 以覆盖 dispatch 前快照。
  // 输入/输出及副作用：command 为输入，ticket/completion/status 为输出；递增 execute_calls，
  //   同步污染 command 图；返回后的 output 突变由测试显式调用
  //   mutate_outputs_now，避免与观察断言共享不确定调度时间槽。
  // 失败/边界：未配置 source 时输出可为空；该 adapter 不提供 lifecycle 提交证据。
  virtual task execute(
    rdma_cmq_command_desc command,
    output rdma_cmq_ticket ticket,
    output rdma_cmq_completion completion,
    output rdma_status status
  );
    execute_calls++;
    ticket = source_ticket;
    completion = source_completion;
    status = returned_status;
    if (command != null) begin
      if (command.function_h != null)
        command.function_h.function_uid++;
      if (command.opcode_key != null)
        command.opcode_key.profile_name = "legacy_mutated_profile";
      if (command.recovery_owner != null)
        command.recovery_owner.workflow = RDMA_CMQ_WORKFLOW_INVALID;
    end
  endtask
endclass

// 设计说明：该子类只为已知 test payload 开放直接字段复制，证明 base hook
// 默认拒绝任意非空 decoded response，而兼容 adapter 可以显式收窄其能力。
class rdma_legacy_payload_cmq_port extends rdma_legacy_only_cmq_port;
  `uvm_object_utils(rdma_legacy_payload_cmq_port)

  // 功能：构造带明确 payload 复制能力的 legacy test port。
  // 输入/输出及副作用：name 传给父类；不创建外部资源，也不改变预置输出。
  // 失败/边界：仅本子类的 hook 扩展复制能力，不改变 base execute 的生命周期语义。
  function new(string name = "rdma_legacy_payload_cmq_port");
    super.new(name);
  endfunction

  // 功能：将唯一支持的 legacy test payload 直接复制为 detached decoded response。
  // 输入/输出及副作用：source 为输入，snapshot/failure_reason 为输出；成功时 new 一个
  //   payload 并复制 value，不调用 clone、factory 或 profile/engine 服务。
  // 失败/边界：null source 是成功的 null 输出；未知 runtime type 清空输出并给出稳定原因。
  protected virtual function bit try_snapshot_legacy_decoded_response(
    input uvm_object source,
    output uvm_object snapshot,
    output string failure_reason
  );
    rdma_legacy_direct_payload source_payload;
    rdma_legacy_direct_payload snapshot_payload;

    snapshot = null;
    failure_reason = "";
    if (source == null)
      return 1'b1;
    if (!$cast(source_payload, source)) begin
      failure_reason = "legacy test payload runtime type is unsupported";
      return 1'b0;
    end
    snapshot_payload = new("legacy_direct_payload_snapshot");
    snapshot_payload.value = source_payload.value;
    snapshot = snapshot_payload;
    return 1'b1;
  endfunction
endclass

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
//   observation_status 已失败的 malformed envelope，用于保护 legacy 兼容位不被伪造。
class rdma_cmq_malformed_delegated_adapter
  extends rdma_cmq_engine_port_adapter;
  `uvm_object_utils(rdma_cmq_malformed_delegated_adapter)

  // 功能：构造 malformed delegated adapter，保留父类的空 engine registry。
  // 输入/输出及副作用：name 传给父类；不创建 engine、DMA 或 scheduler 资源。
  // 失败/边界：该对象只用于 legacy execute seam 测试，不能代表真实 observed route。
  function new(string name = "rdma_cmq_malformed_delegated_adapter");
    super.new(name);
  endfunction

  // 功能：返回一个身份全空、PRE effect 正确但 observation_status 非 OK 的 delegated
  //   result，模拟下游恶意/损坏实现试图伪造“确定未提交”证明。
  // 输入/输出及副作用：command 为只读输入，result 为 caller-owned 新结果；不修改
  //   command、adapter registry 或任何外部资源。
  // 失败/边界：无论 command 内容如何都返回 malformed observation；调用方必须把
  //   该 envelope 当作不可靠证据，不能置 last_execute_no_submit_proven。
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
    rdma_cmq_ticket ticket;
    rdma_cmq_completion completion;
    rdma_status status;
    bit seeded;

    adapter = rdma_cmq_engine_port_adapter::type_id::create(
      "production_observed_pre_rejection_adapter"
    );
    seeded = adapter.last_execute_definitive_no_submit();
    adapter.execute_observed(null, result);
    if (result == null || result.status == null ||
        result.observation_status == null ||
        result.submission_effect != RDMA_SUBMIT_EFFECT_PRE_SUBMIT_REJECTED ||
        result.attempt_effect != RDMA_SUBMIT_EFFECT_PRE_SUBMIT_REJECTED ||
        result.completion_phase != RDMA_CMQ_COMPLETION_NONE ||
        result.recovery_required != 1'b0 ||
        adapter.last_execute_definitive_no_submit() != seeded)
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
    //   非 OK，也不能污染 deprecated last_execute_no_submit_proven seam。
    malformed_adapter =
      rdma_cmq_malformed_delegated_adapter::type_id::create(
        "malformed_delegated_adapter"
      );
    malformed_adapter.execute(null, ticket, completion, status);
    if (malformed_adapter.last_execute_definitive_no_submit())
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

  // 功能：在测试辅助 rdma_cmq_port_test.check_mock_rejects_hostile_command_snapshots 中构造或驱动“mock rejects hostile command
  //   snapshots”场景，并断言 DUT 的状态、错误码和资源账本符合契约。
  // 输入/输出及副作用：无显式参数；fixture/输入由测试调用方提供；执行时会产生 UVM assertion/report，不向 DUT 转移未声明的资源所有权。
  // 失败/边界：fixture 未初始化、故障注入未生效或观测值与预期不一致时报告 UVM_ERROR/断言失败；测试不会吞掉失败。
  task automatic check_mock_rejects_hostile_command_snapshots();
    rdma_function_binding binding;
    rdma_mock_cmq_port mock_cmq;
    rdma_cmq_port port;
    rdma_cmq_command_desc mutating_command;
    rdma_cmq_command_desc alias_command;
    rdma_cmq_command_desc recovery_command;
    rdma_cmq_sqe_model mutating_body;
    rdma_cmq_sqe_model alias_body;
    rdma_cmq_clone_fault_function_handle mutating_function;
    rdma_cmq_clone_fault_function_handle alias_function;
    rdma_cmq_clone_fault_function_handle sibling_function;
    rdma_function_handle saved_command_function;
    rdma_cmq_opcode_key saved_command_opcode;
    rdma_hw_model saved_command_body;
    rdma_hw_image saved_command_signature;
    rdma_function_handle saved_body_function;
    rdma_handle saved_body_target;
    rdma_cmq_ticket ticket;
    rdma_cmq_completion completion;
    rdma_status retained_outcome;
    rdma_status status;
    int unsigned saved_object_id;
    int unsigned saved_sibling_object_id;

    binding = make_binding("mock_hostile_binding", RDMA_BIND_ACTIVE);
    mock_cmq = rdma_mock_cmq_port::type_id::create("mock_hostile_cmq");
    port = mock_cmq;
    retained_outcome = rdma_status::make(
      RDMA_SC_DMA_PERMISSION, "retained hostile snapshot outcome"
    );
    mock_cmq.fail_opcode(RDMA_OP_KEY_ALLOC, retained_outcome);

    mutating_command = make_command(
      "mock_mutating_command", binding, RDMA_OP_KEY_ALLOC, 8'h21, 1us
    );
    if (!$cast(mutating_body, mutating_command.body))
      `uvm_fatal("MOCK_HOSTILE_SETUP", "mutating body type is invalid")
    mutating_function =
      rdma_cmq_clone_fault_function_handle::type_id::create(
        "mock_mutating_function"
      );
    mutating_function.copy(mutating_command.function_h);
    mutating_function.clone_fault = RDMA_CMQ_TEST_CLONE_MUTATE;
    mutating_command.function_h = mutating_function;
    saved_command_function = mutating_command.function_h;
    saved_command_opcode = mutating_command.opcode_key;
    saved_command_body = mutating_command.body;
    saved_command_signature = mutating_command.qpc_signature_source;
    saved_body_function = mutating_body.function_h;
    saved_body_target = mutating_body.target_h;
    saved_object_id = mutating_function.object_id;

    port.execute(mutating_command, ticket, completion, status);
    expect_status("MOCK_MUTATING_SNAPSHOT", status,
                  RDMA_SC_INVALID_ARGUMENT);
    if (ticket != null || completion != null || mock_cmq.calls.size() != 0)
      `uvm_error("MOCK_MUTATING_EFFECTS",
                 "mutating clone produced a ticket, completion, or call")
    if (mutating_command.function_h != saved_command_function ||
        mutating_command.opcode_key != saved_command_opcode ||
        mutating_command.body != saved_command_body ||
        mutating_command.qpc_signature_source != saved_command_signature ||
        mutating_body.function_h != saved_body_function ||
        mutating_body.target_h != saved_body_target ||
        mutating_function.object_id != saved_object_id)
      `uvm_error("MOCK_MUTATING_RESTORE",
                 "mutating clone changed the caller-owned command graph")

    alias_command = make_command(
      "mock_alias_command", binding, RDMA_OP_KEY_ALLOC, 8'h22, 1us
    );
    if (!$cast(alias_body, alias_command.body))
      `uvm_fatal("MOCK_HOSTILE_SETUP", "alias body type is invalid")
    sibling_function =
      rdma_cmq_clone_fault_function_handle::type_id::create(
        "mock_alias_sibling_function"
      );
    sibling_function.copy(alias_body.function_h);
    sibling_function.clone_fault = RDMA_CMQ_TEST_CLONE_GOOD;
    alias_body.function_h = sibling_function;
    alias_function = rdma_cmq_clone_fault_function_handle::type_id::create(
      "mock_alias_function"
    );
    alias_function.copy(alias_command.function_h);
    alias_function.clone_fault = RDMA_CMQ_TEST_CLONE_ALIAS;
    alias_function.alias_target = sibling_function;
    alias_function.alias_once = 1'b1;
    alias_command.function_h = alias_function;
    saved_command_function = alias_command.function_h;
    saved_command_opcode = alias_command.opcode_key;
    saved_command_body = alias_command.body;
    saved_command_signature = alias_command.qpc_signature_source;
    saved_body_function = alias_body.function_h;
    saved_body_target = alias_body.target_h;
    saved_object_id = alias_function.object_id;
    saved_sibling_object_id = sibling_function.object_id;

    rdma_cmq_clone_fault_function_handle::clear_fault_clone_calls();
    port.execute(alias_command, ticket, completion, status);
    expect_status("MOCK_ALIAS_SNAPSHOT", status, RDMA_SC_INVALID_ARGUMENT);
    if (rdma_cmq_clone_fault_function_handle::fault_clone_call_count() != 1 ||
        alias_function.alias_once != 1'b0)
      `uvm_error("MOCK_ALIAS_HOOK",
                 "one-shot alias hook did not execute exactly once")
    if (ticket != null || completion != null || mock_cmq.calls.size() != 0)
      `uvm_error("MOCK_ALIAS_EFFECTS",
                 "alias-laundered clone produced a ticket or call")
    if (alias_command.function_h != saved_command_function ||
        alias_command.opcode_key != saved_command_opcode ||
        alias_command.body != saved_command_body ||
        alias_command.qpc_signature_source != saved_command_signature ||
        alias_body.function_h != saved_body_function ||
        alias_body.target_h != saved_body_target ||
        alias_function.alias_target != saved_body_function ||
        alias_function.object_id != saved_object_id ||
        sibling_function.object_id != saved_sibling_object_id)
      `uvm_error("MOCK_ALIAS_RESTORE",
                 "alias-laundered clone changed its caller-owned source")

    recovery_command = make_command(
      "mock_hostile_recovery", binding, RDMA_OP_KEY_ALLOC, 8'h23, 1us
    );
    port.execute(recovery_command, ticket, completion, status);
    expect_status("MOCK_HOSTILE_RECOVERY", status, RDMA_SC_DMA_PERMISSION);
    if (ticket == null || completion == null ||
        completion.status == null || mock_cmq.calls.size() != 1 ||
        mock_cmq.calls[0] == null ||
        mock_cmq.calls[0].\sequence  != 1 || ticket.command_id != 1 ||
        completion.status.code != RDMA_SC_DMA_PERMISSION ||
        rdma_cmq_clone_fault_function_handle::fault_clone_call_count() != 1)
      `uvm_error("MOCK_HOSTILE_RECOVERY",
                 "rejected snapshots advanced sequence or consumed outcome")
  endtask

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
    port.execute(command, ticket, completion, status);
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

    port.execute(timeout_command, timeout_ticket, completion, status);
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

    port.execute(success_command, ticket, completion, status);
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
    rdma_cmq_port port;
    rdma_cmq_command_desc command;
    rdma_cmq_ticket ticket;
    rdma_cmq_completion completion;
    rdma_status status;
    bit execute_completed;

    binding = make_binding("mock_gate_prerelease_binding", RDMA_BIND_ACTIVE);
    mock_cmq = rdma_mock_cmq_port::type_id::create(
      "mock_gate_prerelease_cmq"
    );
    port = mock_cmq;
    command = make_command(
      "mock_gate_prerelease_command", binding, RDMA_OP_KEY_ALLOC,
      8'h34, 1us
    );
    mock_cmq.gate_opcode(RDMA_OP_KEY_ALLOC);
    mock_cmq.release_one();
    execute_completed = 1'b0;
    fork : wait_for_mock_gate_prerelease
      begin
        port.execute(command, ticket, completion, status);
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

  // 功能：在测试辅助 rdma_cmq_port_test.check_adapter_routes_real_engines_by_function 中构造或驱动“adapter routes real engines by
  //   function”场景，并断言 DUT 的状态、错误码和资源账本符合契约。
  // 输入/输出及副作用：无显式参数；fixture/输入由测试调用方提供；执行时会产生 UVM assertion/report，不向 DUT 转移未声明的资源所有权。
  // 失败/边界：fixture 未初始化、故障注入未生效或观测值与预期不一致时报告 UVM_ERROR/断言失败；测试不会吞掉失败。
  task automatic check_adapter_routes_real_engines_by_function();
    rdma_cmq_engine_port_adapter adapter;
    rdma_cmq_engine_probe engine_a;
    rdma_cmq_engine_probe engine_b;
    rdma_mock_host_mem mem_a;
    rdma_mock_host_mem mem_b;
    rdma_cmq_test_pcie pcie_a;
    rdma_cmq_test_pcie pcie_b;
    rdma_doorbell_scheduler scheduler_a;
    rdma_doorbell_scheduler scheduler_b;
    rdma_cmq_test_profile profile_a;
    rdma_cmq_test_profile profile_b;
    rdma_function_binding prepared_a;
    rdma_function_binding prepared_b;
    rdma_function_binding active_a;
    rdma_function_binding active_b;
    rdma_function_binding unbound_binding;
    rdma_cmq cmq_a;
    rdma_cmq cmq_b;
    rdma_cmq_runtime_desc runtime_a;
    rdma_cmq_runtime_desc runtime_b;
    rdma_cmq_command_desc command_a;
    rdma_cmq_command_desc command_b;
    rdma_cmq_command_desc unbound_command;
    rdma_cmq_ticket ticket_a;
    rdma_cmq_ticket ticket_b;
    rdma_cmq_ticket unbound_ticket;
    rdma_cmq_ticket cqe_hint_a;
    rdma_cmq_ticket unbound_reconcile_ticket;
    rdma_cmq_completion completion_a;
    rdma_cmq_completion completion_b;
    rdma_cmq_execution_result observed_result_a;
    rdma_cmq_completion unbound_completion;
    rdma_cmq_completion reconciled_completion;
    rdma_dma_mapping mapping_a;
    rdma_hw_image raw_a;
    rdma_status status;
    rdma_status status_a;
    rdma_status status_b;
    rdma_function_handle wrong_owner;
    bit terminal_known;
    bit routes_published;
    bit last_no_submit_before_observed;

    adapter = rdma_cmq_engine_port_adapter::type_id::create("adapter");
    engine_a = rdma_cmq_engine_probe::type_id::create("adapter_engine_a");
    engine_b = rdma_cmq_engine_probe::type_id::create("adapter_engine_b");
    mem_a = rdma_mock_host_mem::type_id::create("adapter_mem_a");
    mem_b = rdma_mock_host_mem::type_id::create("adapter_mem_b");
    pcie_a = rdma_cmq_test_pcie::type_id::create("adapter_pcie_a");
    pcie_b = rdma_cmq_test_pcie::type_id::create("adapter_pcie_b");
    scheduler_a = rdma_doorbell_scheduler::type_id::create(
      "adapter_scheduler_a"
    );
    scheduler_b = rdma_doorbell_scheduler::type_id::create(
      "adapter_scheduler_b"
    );
    profile_a = rdma_cmq_test_profile::type_id::create("adapter_profile_a");
    profile_b = rdma_cmq_test_profile::type_id::create("adapter_profile_b");
    prepared_a = make_binding("adapter_prepared_a", RDMA_BIND_PREPARED);
    active_a = make_binding("adapter_active_a", RDMA_BIND_ACTIVE);
    prepared_b = make_binding("adapter_prepared_b", RDMA_BIND_PREPARED);
    prepared_b.function_uid = prepared_a.function_uid + 1'b1;
    prepared_b.global_function_id = prepared_a.global_function_id + 1'b1;
    prepared_b.pcie.bdf.function_num = 3'h2;
    prepared_b.queue_dma.requester_bdf = prepared_b.pcie.bdf;
    // 中文：B 夹具改写兼容镜像后，必须重建同一条 Function identity authority；
    // 否则 prepare 会按设计拒绝镜像与权威快照不一致的 binding。
    status = prepared_b.configure_identity_from_legacy_mirrors(
      16'h0, 32'h1, RDMA_FUNCTION_PF
    );
    expect_status("ADAPTER_B_PREPARED_IDENTITY", status, RDMA_SC_OK);
    prepared_b.owner_h = prepared_b.make_handle();
    active_b = make_binding("adapter_active_b", RDMA_BIND_ACTIVE);
    active_b.function_uid = active_a.function_uid + 1'b1;
    active_b.global_function_id = active_a.global_function_id + 1'b1;
    active_b.pcie.bdf.function_num = 3'h2;
    active_b.queue_dma.requester_bdf = active_b.pcie.bdf;
    // 中文：active B 与 prepared B 共用新的 Function 路由身份，但各自保持
    // 独立 generation/state fixture，供 activate 和 engine adapter 分别校验。
    status = active_b.configure_identity_from_legacy_mirrors(
      16'h0, 32'h1, RDMA_FUNCTION_PF
    );
    expect_status("ADAPTER_B_ACTIVE_IDENTITY", status, RDMA_SC_OK);
    active_b.owner_h = active_b.make_handle();
    if (prepared_a.function_uid == prepared_b.function_uid ||
        prepared_a.global_function_id == prepared_b.global_function_id)
      `uvm_fatal("ADAPTER_DISTINCT_FUNCTIONS",
                 "adapter route fixture reused one Function")
    cmq_a = make_cmq("adapter_cmq_a", prepared_a);
    cmq_b = make_cmq("adapter_cmq_b", prepared_b);
    prepare_active("ADAPTER_A", engine_a, mem_a, pcie_a, scheduler_a,
                   profile_a, prepared_a, active_a, cmq_a, runtime_a);
    prepare_active("ADAPTER_B", engine_b, mem_b, pcie_b, scheduler_b,
                   profile_b, prepared_b, active_b, cmq_b, runtime_b);

    status = adapter.bind_engine(active_a.make_handle(), engine_a);
    expect_status("ADAPTER_BIND_A", status, RDMA_SC_OK);
    status = adapter.bind_engine(active_b.make_handle(), engine_b);
    expect_status("ADAPTER_BIND_B", status, RDMA_SC_OK);
    status = adapter.bind_engine(active_a.make_handle(), engine_b);
    expect_status("ADAPTER_BIND_DUPLICATE", status, RDMA_SC_INVALID_STATE);
    status = adapter.bind_engine(null, engine_a);
    expect_status("ADAPTER_BIND_NULL_OWNER", status,
                  RDMA_SC_INVALID_ARGUMENT);
    wrong_owner = active_a.make_handle();
    wrong_owner.kind = RDMA_RESOURCE_CMQ;
    status = adapter.bind_engine(wrong_owner, engine_a);
    expect_status("ADAPTER_BIND_WRONG_OWNER", status,
                  RDMA_SC_INVALID_ARGUMENT);
    status = adapter.bind_engine(active_a.make_handle(), null);
    expect_status("ADAPTER_BIND_NULL_ENGINE", status,
                  RDMA_SC_INVALID_ARGUMENT);

    command_a = make_command("adapter_command_a", active_a,
                             rdma_cmq_test_profile::TEST_OPCODE_A,
                             8'h51, 1us);
    command_b = make_command("adapter_command_b", active_b,
                             rdma_cmq_test_profile::TEST_OPCODE_B,
                             8'h52, 1us);
    last_no_submit_before_observed =
      adapter.last_execute_definitive_no_submit();
    mapping_a = engine_a.mapping_snapshot();
    cqe_hint_a = rdma_cmq_ticket::type_id::create("adapter_cqe_hint_a");
    cqe_hint_a.function_h = command_a.function_h;
    cqe_hint_a.opcode_key = command_a.opcode_key;
    cqe_hint_a.sq_index = 0;
    cqe_hint_a.sq_wrap = 1'b0;
    fork
      begin
        // A 路径直接调用 production observed API；只有 B 保留 legacy wrapper，
        // 这样同一 fixture 同时证明 direct route 与兼容 route 不会串证据。
        adapter.execute_observed(command_a, observed_result_a);
      end
      begin
        adapter.execute(command_b, ticket_b, completion_b, status_b);
      end
    join_none
    routes_published = 1'b0;
    fork : wait_for_adapter_route_publication
      begin
        while (engine_a.outstanding_count() != 1 ||
               engine_b.outstanding_count() != 1 ||
               engine_a.published_count() != 1 ||
               engine_b.published_count() != 1)
          #1ns;
        routes_published = 1'b1;
      end
      begin
        #100ns;
      end
    join_any
    disable wait_for_adapter_route_publication;
    if (!routes_published) begin
      `uvm_error(
        "ADAPTER_REAL_ROUTE_TIMEOUT",
        $sformatf(
          {"Function routes did not publish before the observation ",
           "deadline: A published=%0d outstanding=%0d, ",
           "B published=%0d outstanding=%0d"},
          engine_a.published_count(), engine_a.outstanding_count(),
          engine_b.published_count(), engine_b.outstanding_count()
        )
      )
      wait fork;
      engine_a.shutdown(status);
      expect_status("ADAPTER_TIMEOUT_SHUTDOWN_A", status, RDMA_SC_OK);
      engine_b.shutdown(status);
      expect_status("ADAPTER_TIMEOUT_SHUTDOWN_B", status, RDMA_SC_OK);
      return;
    end
    if (engine_a.outstanding_count() != 1 ||
        engine_b.outstanding_count() != 1 ||
        engine_a.published_count() != 1 ||
        engine_b.published_count() != 1)
      `uvm_error("ADAPTER_REAL_ROUTE",
                 "commands did not reach their Function-specific engines")
    write_profile_cqe("ADAPTER_CQE_A", mem_a, mapping_a, profile_a,
                      0, 1'b1, cqe_hint_a, 0, raw_a);
    wait fork;
    if (observed_result_a != null) begin
      ticket_a = observed_result_a.ticket;
      completion_a = observed_result_a.completion;
      status_a = observed_result_a.status;
    end
    expect_status("ADAPTER_EXECUTE_A", status_a, RDMA_SC_OK);
    expect_status("ADAPTER_EXECUTE_B", status_b, RDMA_SC_TIMEOUT);
    if (completion_a == null || completion_b == null ||
        completion_a.status == null || completion_b.status == null ||
        status_a != completion_a.status || status_b != completion_b.status ||
        ticket_a == null || ticket_b == null ||
        completion_a.ticket == null || completion_b.ticket == null ||
        completion_a.raw_cqe == null || completion_b.raw_cqe != null ||
        completion_a.ticket.function_h.generation != active_a.generation ||
        completion_b.ticket.function_h.generation != active_b.generation ||
        completion_a.ticket.function_h.function_uid !=
          active_a.function_uid ||
        completion_b.ticket.function_h.function_uid !=
          active_b.function_uid ||
        completion_a.ticket.function_h.object_id !=
          active_a.global_function_id ||
        completion_b.ticket.function_h.object_id !=
          active_b.global_function_id ||
        engine_a.outstanding_count() != 0 ||
        engine_b.outstanding_count() != 0 ||
        engine_a.quarantine_count() != 0 ||
        engine_b.quarantine_count() != 1)
      `uvm_error("ADAPTER_REAL_COMPLETE",
                 "adapter did not retain detached timeout ticket/status")
    if (observed_result_a == null ||
        observed_result_a.submission_effect == RDMA_SUBMIT_EFFECT_UNOBSERVED ||
        observed_result_a.attempt_effect == RDMA_SUBMIT_EFFECT_UNOBSERVED ||
        observed_result_a.completion_phase != RDMA_CMQ_COMPLETION_TERMINAL ||
        observed_result_a.recovery_required != 1'b0 ||
        observed_result_a.ticket == null ||
        observed_result_a.completion == null ||
        observed_result_a.ticket != observed_result_a.completion.ticket ||
        observed_result_a.status != observed_result_a.completion.status ||
        adapter.last_execute_definitive_no_submit() !=
          last_no_submit_before_observed)
      `uvm_error("ADAPTER_DIRECT_OBSERVED_ROUTE",
                 "direct observed route did not preserve terminal evidence")

    adapter.reconcile(ticket_b, terminal_known, reconciled_completion, status);
    expect_status("ADAPTER_RECONCILE_ROUTE", status, RDMA_SC_TIMEOUT);
    if (!terminal_known || reconciled_completion == null ||
        reconciled_completion.status == null ||
        reconciled_completion.status.code != RDMA_SC_TIMEOUT ||
        engine_a.quarantine_count() != 0 ||
        engine_b.quarantine_count() != 1)
      `uvm_error("ADAPTER_RECONCILE_ROUTE",
                 "reconcile did not route to the ticket generation")
    unbound_reconcile_ticket = rdma_cmq_clone_ticket_value(
      ticket_b, "adapter unbound reconcile"
    );
    unbound_reconcile_ticket.function_h.generation++;
    unbound_reconcile_ticket.cmq_h.generation++;
    adapter.reconcile(unbound_reconcile_ticket, terminal_known,
                      reconciled_completion, status);
    expect_status("ADAPTER_RECONCILE_UNBOUND", status,
                  RDMA_SC_INVALID_STATE);
    if (terminal_known || reconciled_completion != null ||
        engine_b.quarantine_count() != 1)
      `uvm_error("ADAPTER_RECONCILE_UNBOUND",
                 "unbound reconcile consumed a bound generation")

    unbound_binding = next_generation_binding("adapter_unbound",
                                              RDMA_BIND_ACTIVE, 2);
    unbound_command = make_command("adapter_unbound_command",
                                   unbound_binding,
                                   rdma_cmq_test_profile::TEST_OPCODE_A,
                                   8'h53, 1us);
    adapter.execute(unbound_command, unbound_ticket, unbound_completion,
                    status);
    expect_status("ADAPTER_UNBOUND_GENERATION", status,
                  RDMA_SC_INVALID_STATE);
    if (unbound_ticket != null || unbound_completion != null ||
        engine_a.published_count() != 1 || engine_b.published_count() != 1)
      `uvm_error("ADAPTER_UNBOUND_GENERATION",
                 "unbound generation reached a different engine")

    engine_a.shutdown(status);
    expect_status("ADAPTER_SHUTDOWN_A", status, RDMA_SC_OK);
    engine_b.shutdown(status);
    expect_status("ADAPTER_SHUTDOWN_B", status, RDMA_SC_OK);
  endtask

  // 功能：在测试辅助 rdma_cmq_port_test.check_real_engine_ticket_specific_reconcile 中构造或驱动“real engine ticket specific
  //   reconcile”场景，并断言 DUT 的状态、错误码和资源账本符合契约。
  // 输入/输出及副作用：无显式参数；fixture/输入由测试调用方提供；执行时会产生 UVM assertion/report，不向 DUT 转移未声明的资源所有权。
  // 失败/边界：fixture 未初始化、故障注入未生效或观测值与预期不一致时报告 UVM_ERROR/断言失败；测试不会吞掉失败。
  task automatic check_real_engine_ticket_specific_reconcile();
    rdma_cmq_engine_probe engine;
    rdma_mock_host_mem mem;
    rdma_cmq_test_pcie pcie;
    rdma_doorbell_scheduler scheduler;
    rdma_cmq_test_profile profile;
    rdma_function_binding prepared_binding;
    rdma_function_binding active_binding;
    rdma_cmq cmq;
    rdma_cmq_runtime_desc runtime_desc;
    rdma_cmq_command_desc requests[];
    rdma_cmq_command_desc failure_request;
    rdma_cmq_ticket tickets[];
    rdma_cmq_ticket failure_ticket;
    rdma_cmq_ticket forged_ticket;
    rdma_cmq_ticket stale_ticket;
    rdma_status item_statuses[];
    rdma_status batch_status;
    rdma_status status;
    rdma_cmq_completion completion;
    rdma_cmq_completion completions[$];
    rdma_cmq_diagnostic diagnostics[$];
    rdma_dma_mapping mapping;
    rdma_hw_image first_raw;
    rdma_hw_image second_raw;
    rdma_hw_image third_raw;
    rdma_hw_image failure_raw;
    bit terminal_known;

    engine = rdma_cmq_engine_probe::type_id::create("reconcile_engine");
    mem = rdma_mock_host_mem::type_id::create("reconcile_mem");
    pcie = rdma_cmq_test_pcie::type_id::create("reconcile_pcie");
    scheduler = rdma_doorbell_scheduler::type_id::create(
      "reconcile_scheduler"
    );
    profile = rdma_cmq_test_profile::type_id::create("reconcile_profile");
    prepared_binding = make_binding("reconcile_prepared",
                                    RDMA_BIND_PREPARED);
    active_binding = make_binding("reconcile_active", RDMA_BIND_ACTIVE);
    cmq = make_cmq("reconcile_cmq", prepared_binding);
    prepare_active("RECONCILE", engine, mem, pcie, scheduler, profile,
                   prepared_binding, active_binding, cmq, runtime_desc);
    requests = new[3];
    requests[0] = make_command("reconcile_first", active_binding,
                               rdma_cmq_test_profile::TEST_OPCODE_A,
                               8'h61, 5ns);
    requests[1] = make_command("reconcile_second", active_binding,
                               rdma_cmq_test_profile::TEST_OPCODE_B,
                               8'h62, 5ns);
    requests[2] = make_command("reconcile_third", active_binding,
                               rdma_cmq_test_profile::TEST_OPCODE_A,
                               8'h63, 5ns);
    engine.submit_batch(requests, tickets, item_statuses, batch_status);
    expect_status("RECONCILE_SUBMIT", batch_status, RDMA_SC_OK);
    if (tickets.size() != 3 || tickets[0] == null || tickets[1] == null ||
        tickets[2] == null) begin
      `uvm_error("RECONCILE_SUBMIT", "three timeout tickets were not produced")
      engine.shutdown(status);
      return;
    end
    mapping = engine.mapping_snapshot();
    #10ns;

    forged_ticket = rdma_cmq_clone_ticket_value(tickets[1],
                                                "reconcile forged");
    forged_ticket.command_id += 32;
    engine.reconcile_ticket(forged_ticket, terminal_known, completion, status);
    expect_status("RECONCILE_FORGED", status, RDMA_SC_INVALID_ARGUMENT);
    if (terminal_known || completion != null ||
        engine.terminal_fifo_count() != 0 ||
        engine.diagnostic_fifo_count() != 0 ||
        engine.quarantine_count() != 0 || engine.outstanding_count() != 3 ||
        engine.cq_consumed_count() != 0 || engine.retired_count() != 0)
      `uvm_error("RECONCILE_FORGED_ISOLATION",
                 "forged ticket changed unrelated engine authority")

    stale_ticket = rdma_cmq_clone_ticket_value(tickets[1],
                                               "reconcile stale");
    stale_ticket.function_h.generation++;
    stale_ticket.cmq_h.generation++;
    engine.reconcile_ticket(stale_ticket, terminal_known, completion, status);
    expect_status("RECONCILE_STALE", status, RDMA_SC_INVALID_ARGUMENT);
    if (terminal_known || completion != null ||
        engine.terminal_fifo_count() != 0 ||
        engine.diagnostic_fifo_count() != 0 ||
        engine.quarantine_count() != 0 || engine.outstanding_count() != 3 ||
        engine.cq_consumed_count() != 0 || engine.retired_count() != 0)
      `uvm_error("RECONCILE_STALE_ISOLATION",
                 "stale ticket changed unrelated engine authority")

    engine.reconcile_ticket(tickets[1], terminal_known, completion, status);
    expect_status("RECONCILE_MIDDLE_TIMEOUT", status, RDMA_SC_TIMEOUT);
    if (!terminal_known || completion == null || completion.status == null ||
        completion.ticket == null ||
        completion.ticket.command_id != tickets[1].command_id ||
        completion.status.code != RDMA_SC_TIMEOUT ||
        completion.raw_cqe != null ||
        engine.terminal_fifo_count() != 3 ||
        engine.diagnostic_fifo_count() != 0 ||
        engine.quarantine_count() != 3 || engine.outstanding_count() != 0 ||
        engine.cq_consumed_count() != 0 || engine.retired_count() != 0)
      `uvm_error("RECONCILE_TIMEOUT_ISOLATION",
                 "middle reconcile changed outer terminal FIFO entries")

    write_profile_cqe("RECONCILE_LATE_FIRST", mem, mapping, profile,
                      0, 1'b1, tickets[0], 0, first_raw);
    write_profile_cqe("RECONCILE_LATE_SECOND", mem, mapping, profile,
                      1, 1'b1, tickets[1], 0, second_raw);
    write_profile_cqe("RECONCILE_LATE_THIRD", mem, mapping, profile,
                      2, 1'b1, tickets[2], 0, third_raw);
    engine.reconcile_ticket(tickets[1], terminal_known, completion, status);
    expect_status("RECONCILE_MIDDLE_LATE", status, RDMA_SC_TIMEOUT);
    if (!terminal_known || completion == null || completion.status == null ||
        completion.ticket == null ||
        completion.ticket.command_id != tickets[1].command_id ||
        completion.status.code != RDMA_SC_TIMEOUT ||
        completion.decoded_response != null ||
        completion.raw_cqe != null ||
        engine.terminal_fifo_count() != 3 ||
        engine.diagnostic_fifo_count() != 0 ||
        engine.quarantine_count() != 3 ||
        engine.cq_consumed_count() != 0 || engine.retired_count() != 0)
      `uvm_error("RECONCILE_LATE_ISOLATION",
                 $sformatf("middle late mismatch tf=%0d df=%0d q=%0d cq=%0d ret=%0d",
                           engine.terminal_fifo_count(), engine.diagnostic_fifo_count(),
                           engine.quarantine_count(), engine.cq_consumed_count(),
                           engine.retired_count()))
    if (completion != null && completion.status != null &&
        completion.status.code == RDMA_SC_TIMEOUT)
      expect_status("RECONCILE_MIDDLE_LATE_FINAL", completion.status,
                    RDMA_SC_TIMEOUT);

    engine.poll(completions, diagnostics, status);
    expect_status("RECONCILE_OUTER_POLL", status, RDMA_SC_OK);
    if (completions.size() != 3 || diagnostics.size() != 3 ||
        completions[0] == null || completions[0].ticket == null ||
        completions[0].status == null ||
        completions[1] == null || completions[1].ticket == null ||
        completions[1].status == null ||
        completions[2] == null || completions[2].ticket == null ||
        completions[2].status == null ||
        completions[0].ticket.command_id != tickets[0].command_id ||
        completions[1].ticket.command_id != tickets[1].command_id ||
        completions[2].ticket.command_id != tickets[2].command_id ||
        completions[0].status.code != RDMA_SC_TIMEOUT ||
        completions[1].status.code != RDMA_SC_TIMEOUT ||
        completions[2].status.code != RDMA_SC_TIMEOUT ||
        completions[0].raw_cqe != null || completions[1].raw_cqe != null ||
        completions[2].raw_cqe != null ||
        diagnostics[0] == null || diagnostics[0].ticket == null ||
        diagnostics[0].status == null || diagnostics[0].raw_cqe == null ||
        diagnostics[1] == null || diagnostics[1].ticket == null ||
        diagnostics[1].status == null || diagnostics[1].raw_cqe == null ||
        diagnostics[2] == null || diagnostics[2].ticket == null ||
        diagnostics[2].status == null || diagnostics[2].raw_cqe == null ||
        diagnostics[0].ticket.command_id != tickets[0].command_id ||
        diagnostics[1].ticket.command_id != tickets[1].command_id ||
        diagnostics[2].ticket.command_id != tickets[2].command_id ||
        diagnostics[0].kind != RDMA_CMQ_DIAG_LATE_COMPLETION ||
        diagnostics[1].kind != RDMA_CMQ_DIAG_LATE_COMPLETION ||
        diagnostics[2].kind != RDMA_CMQ_DIAG_LATE_COMPLETION ||
        !engine.probe_same_image(diagnostics[0].raw_cqe, first_raw) ||
        !engine.probe_same_image(diagnostics[1].raw_cqe, second_raw) ||
        !engine.probe_same_image(diagnostics[2].raw_cqe, third_raw) ||
        engine.terminal_fifo_count() != 0 ||
        engine.diagnostic_fifo_count() != 0 ||
        engine.quarantine_count() != 0 ||
        engine.outstanding_count() != 0 ||
        engine.cq_consumed_count() != 3 || engine.retired_count() != 3)
      `uvm_error("RECONCILE_OUTER_ORDER",
                 "A/C terminal or diagnostic FIFO order was not retained")
    if (diagnostics.size() == 3) begin
      expect_late_diagnostic("RECONCILE_OUTER_FIRST_DIAGNOSTIC", engine,
                             diagnostics[0], tickets[0], first_raw);
      expect_late_diagnostic("RECONCILE_OUTER_SECOND_DIAGNOSTIC", engine,
                             diagnostics[1], tickets[1], second_raw);
      expect_late_diagnostic("RECONCILE_OUTER_THIRD_DIAGNOSTIC", engine,
                             diagnostics[2], tickets[2], third_raw);
    end

    failure_request = make_command(
      "reconcile_late_failure", active_binding,
      rdma_cmq_test_profile::TEST_OPCODE_B, 8'h64, 5ns
    );
    engine.submit(failure_request, failure_ticket, status);
    expect_status("RECONCILE_FAILURE_SUBMIT", status, RDMA_SC_OK);
    if (failure_ticket == null) begin
      `uvm_error("RECONCILE_FAILURE_SUBMIT",
                 "late-failure ticket was not produced")
      engine.shutdown(status);
      return;
    end
    #10ns;
    engine.reconcile_ticket(failure_ticket, terminal_known, completion,
                            status);
    expect_status("RECONCILE_FAILURE_TIMEOUT", status, RDMA_SC_TIMEOUT);
    if (!terminal_known || completion == null || completion.status == null ||
        completion.status.code != RDMA_SC_TIMEOUT ||
        completion.raw_cqe != null)
      `uvm_error("RECONCILE_FAILURE_TIMEOUT",
                 "late-failure setup did not consume its timeout")
    write_profile_cqe(
      "RECONCILE_LATE_FAILURE", mem, mapping, profile, 3, 1'b1,
      failure_ticket, RDMA_ECODE_EC_RCE_CQ_FULL, failure_raw
    );
    engine.reconcile_ticket(failure_ticket, terminal_known, completion,
                            status);
    expect_status("RECONCILE_LATE_FAILURE", status, RDMA_SC_TIMEOUT);
    if (!terminal_known || completion == null || completion.status == null ||
        completion.status.code != RDMA_SC_TIMEOUT ||
        completion.decoded_response != null || completion.raw_cqe != null)
      `uvm_error("RECONCILE_LATE_FAILURE",
                 "late hardware failure was not returned as final status")
    engine.poll(completions, diagnostics, status);
    expect_status("RECONCILE_LATE_FAILURE_POLL", status, RDMA_SC_OK);
    if (completions.size() != 1 || diagnostics.size() != 1 ||
        completions[0] == null || completions[0].status == null ||
        completions[0].status.code != RDMA_SC_TIMEOUT ||
        diagnostics[0] == null || diagnostics[0].status == null ||
        diagnostics[0].status.code != RDMA_SC_TIMEOUT)
      `uvm_error("RECONCILE_LATE_FAILURE_POLL",
                 $sformatf("late failure poll mismatch c=%0d d=%0d c0=%0d d0=%0d",
                           completions.size(), diagnostics.size(),
                           (completions.size() > 0 && completions[0] != null &&
                            completions[0].status != null) ? completions[0].status.code : -1,
                           (diagnostics.size() > 0 && diagnostics[0] != null &&
                            diagnostics[0].status != null) ? diagnostics[0].status.code : -1))

    engine.shutdown(status);
    expect_status("RECONCILE_SHUTDOWN", status, RDMA_SC_OK);
  endtask

  // 功能：在测试辅助 rdma_cmq_port_test.check_real_engine_late_pair_cleanup 中构造或驱动“real engine late pair cleanup”场景，并断言 DUT
  //   的状态、错误码和资源账本符合契约。
  // 输入/输出及副作用：无显式参数；fixture/输入由测试调用方提供；执行时会产生 UVM assertion/report，不向 DUT 转移未声明的资源所有权。
  // 失败/边界：fixture 未初始化、故障注入未生效或观测值与预期不一致时报告 UVM_ERROR/断言失败；测试不会吞掉失败。
  task automatic check_real_engine_late_pair_cleanup();
    rdma_cmq_late_pair_probe engine;
    rdma_mock_host_mem mem;
    rdma_cmq_test_pcie pcie;
    rdma_doorbell_scheduler scheduler;
    rdma_cmq_test_profile profile;
    rdma_function_binding prepared_binding;
    rdma_function_binding active_binding;
    rdma_cmq cmq;
    rdma_cmq_runtime_desc runtime_desc;
    rdma_cmq_command_desc requests[];
    rdma_cmq_ticket tickets[];
    rdma_status item_statuses[];
    rdma_status batch_status;
    rdma_status status;
    rdma_cmq_completion completion;
    rdma_cmq_completion completions[$];
    rdma_cmq_diagnostic diagnostics[$];
    rdma_dma_mapping mapping;
    rdma_hw_image raw_cqes[2];
    bit terminal_known;
    string label;

    for (int unsigned mode = 0; mode < 4; mode++) begin
      case (mode)
        0: label = "LATE_PAIR_ACTIVE_POLL";
        1: label = "LATE_PAIR_QUIESCED_POLL";
        2: label = "LATE_PAIR_RESET";
        default: label = "LATE_PAIR_SHUTDOWN";
      endcase
      engine = rdma_cmq_late_pair_probe::type_id::create(
        $sformatf("late_pair_cleanup_engine_%0d", mode)
      );
      mem = rdma_mock_host_mem::type_id::create(
        $sformatf("late_pair_cleanup_mem_%0d", mode)
      );
      pcie = rdma_cmq_test_pcie::type_id::create(
        $sformatf("late_pair_cleanup_pcie_%0d", mode)
      );
      scheduler = rdma_doorbell_scheduler::type_id::create(
        $sformatf("late_pair_cleanup_scheduler_%0d", mode)
      );
      profile = rdma_cmq_test_profile::type_id::create(
        $sformatf("late_pair_cleanup_profile_%0d", mode)
      );
      prepared_binding = make_binding(
        $sformatf("late_pair_cleanup_prepared_%0d", mode),
        RDMA_BIND_PREPARED
      );
      active_binding = make_binding(
        $sformatf("late_pair_cleanup_active_%0d", mode), RDMA_BIND_ACTIVE
      );
      cmq = make_cmq($sformatf("late_pair_cleanup_cmq_%0d", mode),
                     prepared_binding);
      prepare_active(label, engine, mem, pcie, scheduler, profile,
                     prepared_binding, active_binding, cmq, runtime_desc);
      requests = new[2];
      foreach (requests[i]) begin
        requests[i] = make_command(
          $sformatf("late_pair_cleanup_request_%0d_%0d", mode, i),
          active_binding,
          (i == 0) ? rdma_cmq_test_profile::TEST_OPCODE_A :
                     rdma_cmq_test_profile::TEST_OPCODE_B,
          8'h70 + i, 5ns
        );
      end
      engine.submit_batch(requests, tickets, item_statuses, batch_status);
      expect_status({label, "_SUBMIT"}, batch_status, RDMA_SC_OK);
      if (tickets.size() != 2 || tickets[0] == null || tickets[1] == null) begin
        `uvm_error(label, "cleanup fixture did not produce two tickets")
        engine.shutdown(status);
        continue;
      end
      mapping = engine.mapping_snapshot();
      #10ns;
      foreach (tickets[i]) begin
        engine.reconcile_ticket(tickets[i], terminal_known, completion,
                                status);
        expect_status($sformatf("%s_TIMEOUT_%0d", label, i), status,
                      RDMA_SC_TIMEOUT);
        if (!terminal_known || completion == null ||
            completion.status == null ||
            completion.status.code != RDMA_SC_TIMEOUT ||
            completion.raw_cqe != null)
          `uvm_error(label, "cleanup fixture did not consume its timeout")
      end
      foreach (tickets[i]) begin
        write_profile_cqe(
          $sformatf("%s_CQE_%0d", label, i), mem, mapping, profile, i,
          1'b1, tickets[i], 0, raw_cqes[i]
        );
      end
      engine.reconcile_ticket(tickets[0], terminal_known, completion, status);
      expect_status({label, "_RECONCILE"}, status, RDMA_SC_TIMEOUT);
      if (!terminal_known || completion == null ||
          completion.status == null || completion.status.code != RDMA_SC_TIMEOUT ||
          engine.diagnostic_fifo_count() != 0 ||
          engine.late_final_count() != 0)
        `uvm_error(label,
                   "cleanup fixture did not retain one strict pair")

      case (mode)
        0: begin
          engine.poll(completions, diagnostics, status);
          expect_status({label, "_STATUS"}, status, RDMA_SC_OK);
          if (completions.size() != 2 || diagnostics.size() != 2 ||
              engine.diagnostic_fifo_count() != 0 ||
              engine.late_final_count() != 0)
            `uvm_error(label,
                       $sformatf("ACTIVE poll mismatch c=%0d d=%0d df=%0d lf=%0d",
                                 completions.size(), diagnostics.size(),
                                 engine.diagnostic_fifo_count(), engine.late_final_count()))
          else begin
            expect_late_diagnostic({label, "_DIAGNOSTIC_0"}, engine,
                                   diagnostics[0], tickets[0], raw_cqes[0]);
            expect_late_diagnostic({label, "_DIAGNOSTIC_1"}, engine,
                                   diagnostics[1], tickets[1], raw_cqes[1]);
          end
          engine.shutdown(status);
          expect_status({label, "_SHUTDOWN"}, status, RDMA_SC_OK);
        end
        1: begin
          engine.cancel_generation(prepared_binding.generation,
                                   completions, status);
          expect_status({label, "_CANCEL"}, status, RDMA_SC_OK);
          if (engine.late_final_count() != 0 ||
              engine.diagnostic_fifo_count() != 0)
            `uvm_error(label,
                       $sformatf("quiesce pair mismatch df=%0d lf=%0d",
                                 engine.diagnostic_fifo_count(), engine.late_final_count()))
          engine.poll(completions, diagnostics, status);
          expect_status({label, "_STATUS"}, status, RDMA_SC_INVALID_STATE);
          if (completions.size() != 0 || diagnostics.size() != 0 ||
              engine.diagnostic_fifo_count() != 0 ||
              engine.late_final_count() != 0)
            `uvm_error(
              label,
              $sformatf("non-ACTIVE poll mismatch c=%0d d=%0d df=%0d lf=%0d",
                        completions.size(), diagnostics.size(),
                        engine.diagnostic_fifo_count(), engine.late_final_count())
            )
          else begin
            // Non-ACTIVE poll intentionally returns no diagnostics; no indexing.
          end
          engine.shutdown(status);
          expect_status({label, "_SHUTDOWN"}, status, RDMA_SC_OK);
        end
        2: begin
          engine.reset(completions, status);
          expect_status({label, "_STATUS"}, status, RDMA_SC_OK);
          if (engine.state() != RDMA_CMQ_ENGINE_UNCONFIGURED ||
              engine.late_final_count() != 0)
            `uvm_error(label, "reset retained a paired final result")
        end
        default: begin
          engine.shutdown(status);
          expect_status({label, "_STATUS"}, status, RDMA_SC_OK);
          if (engine.state() != RDMA_CMQ_ENGINE_UNCONFIGURED ||
              engine.late_final_count() != 0)
            `uvm_error(label, "shutdown retained a paired final result")
        end
      endcase
    end
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

  // 功能：验证 base port 对仅有 execute() 的 legacy adapter 只发布 detached、
  //   UNOBSERVED 结果，并在 payload、状态和 raw-factory 异常下保留独立字段。
  // 输入/输出及副作用：无显式输入；构造 legacy adapter、command、completion 和
  //   raw-factory fault wrapper，调用真实 execute_observed 并发布 UVM assertion。
  // 失败/边界：null/timeout/reset status、缺失或未支持 payload、输入/输出突变和
  //   null/wrong-type factory 均必须保守降级；任何不符都报告 UVM_ERROR。
  task automatic check_legacy_observed_fallback();
    rdma_function_binding binding;
    rdma_cmq_command_desc command;
    rdma_cmq_port port;
    rdma_legacy_only_cmq_port legacy_port;
    rdma_legacy_payload_cmq_port payload_port;
    rdma_legacy_direct_payload source_payload;
    rdma_legacy_direct_payload result_payload;
    rdma_cmq_execution_result result;
    uvm_factory factory;
    rdma_cmq_value_factory_fault_wrapper result_fault;
    rdma_cmq_value_factory_fault_wrapper status_fault;
    rdma_cmq_value_factory_fault_wrapper ticket_fault;
    rdma_cmq_value_factory_fault_wrapper image_fault;
    rdma_cmq_value_factory_fault_wrapper completion_fault;
    rdma_cmq_command_desc factory_commands[2];
    rdma_legacy_only_cmq_port factory_ports[2];
    longint unsigned expected_uid;
    string expected_profile;

    binding = make_binding("legacy_observed_binding", RDMA_BIND_ACTIVE);

    command = make_command(
      "legacy_observed_normal", binding, RDMA_OP_CQC_QUERY, 8'h91, 1us
    );
    expected_uid = command.function_h.function_uid;
    expected_profile = command.opcode_key.profile_name;
    legacy_port = new("legacy_observed_normal_port");
    legacy_port.configure_response(command, RDMA_SC_OK, 1'b1, 1'b0);
    port = legacy_port;
    port.execute_observed(command, result);
    if (legacy_port.execute_calls != 1 || result == null ||
        result.status == null || result.observation_status == null ||
        result.submission_effect != RDMA_SUBMIT_EFFECT_UNOBSERVED)
      `uvm_error("PORT_OBSERVED_FALLBACK", "legacy fallback is incomplete")
    if (result.completion == null || result.ticket == null ||
        result.command_identity == null || result.recovery_owner == null ||
        result.status.code != RDMA_SC_OK ||
        result.observation_status.code != RDMA_SC_OK ||
        result.completion_phase != RDMA_CMQ_COMPLETION_UNOBSERVED ||
        result.attempt_effect != RDMA_SUBMIT_EFFECT_UNOBSERVED ||
        !result.recovery_required || result.dma_context != null ||
        result.batch_key != "" || result.batch_id != 0 || result.attempt_id != 0)
      `uvm_error("PORT_OBSERVED_NORMAL", "legacy result classification is wrong")
    if (result.command_identity.function_uid != expected_uid ||
        result.command_identity.profile_name != expected_profile ||
        !result.recovery_owner.is_legacy_unmigrated() ||
        result.ticket == legacy_port.source_ticket ||
        result.status == legacy_port.source_status ||
        result.ticket != result.completion.ticket ||
        result.status != result.completion.status)
      `uvm_error("PORT_OBSERVED_DETACH", "pre-dispatch or alias snapshot is wrong")
    legacy_port.mutate_outputs_now();
    if (result.ticket.command_id != 64'h5501 ||
        result.status.code != RDMA_SC_OK || result.completion.raw_cqe == null)
      `uvm_error("PORT_OBSERVED_POST_RETURN", "legacy output mutation leaked")

    command = make_command(
      "legacy_observed_null_completion", binding, RDMA_OP_CQC_QUERY, 8'h92,
      1us
    );
    legacy_port = new("legacy_observed_null_completion_port");
    legacy_port.configure_response(command, RDMA_SC_OK, 1'b0, 1'b0);
    port = legacy_port;
    port.execute_observed(command, result);
    if (result == null || result.ticket == null || result.completion != null ||
        result.status == null || result.status.code != RDMA_SC_OK ||
        result.observation_status == null ||
        result.observation_status.code != RDMA_SC_OK ||
        result.completion_phase != RDMA_CMQ_COMPLETION_UNOBSERVED)
      `uvm_error("PORT_OBSERVED_NULL_COMPLETION",
                 "null legacy completion was not retained as unobserved")
    #1ns;

    command = make_command(
      "legacy_observed_null_status", binding, RDMA_OP_CQC_QUERY, 8'h93, 1us
    );
    legacy_port = new("legacy_observed_null_status_port");
    legacy_port.configure_response(command, RDMA_SC_OK, 1'b0, 1'b1);
    port = legacy_port;
    port.execute_observed(command, result);
    if (result == null || result.status == null ||
        result.observation_status == null ||
        result.status.code != RDMA_SC_INVALID_STATE ||
        result.observation_status.code != RDMA_SC_INVALID_STATE ||
        result.completion_phase != RDMA_CMQ_COMPLETION_UNOBSERVED)
      `uvm_error("PORT_OBSERVED_NULL_STATUS",
                 "null legacy status did not become INVALID_STATE")
    #1ns;

    command = make_command(
      "legacy_observed_timeout", binding, RDMA_OP_CQC_QUERY, 8'h94, 1us
    );
    legacy_port = new("legacy_observed_timeout_port");
    legacy_port.configure_response(command, RDMA_SC_TIMEOUT, 1'b1, 1'b0);
    port = legacy_port;
    port.execute_observed(command, result);
    if (result == null || result.completion == null || result.status == null ||
        result.status.code != RDMA_SC_TIMEOUT ||
        result.completion_phase != RDMA_CMQ_COMPLETION_UNOBSERVED)
      `uvm_error("PORT_OBSERVED_TIMEOUT",
                 "legacy timeout inferred an observed lifecycle phase")
    #1ns;

    command = make_command(
      "legacy_observed_reset", binding, RDMA_OP_CQC_QUERY, 8'h95, 1us
    );
    legacy_port = new("legacy_observed_reset_port");
    legacy_port.configure_response(
      command, RDMA_SC_RESET_CANCELLED, 1'b1, 1'b0
    );
    port = legacy_port;
    port.execute_observed(command, result);
    if (result == null || result.completion == null || result.status == null ||
        result.status.code != RDMA_SC_RESET_CANCELLED ||
        result.completion_phase != RDMA_CMQ_COMPLETION_UNOBSERVED)
      `uvm_error("PORT_OBSERVED_RESET",
                 "legacy reset inferred an observed lifecycle phase")
    #1ns;

    command = make_command(
      "legacy_observed_unsupported_payload", binding, RDMA_OP_CQC_QUERY,
      8'h96, 1us
    );
    source_payload = new("legacy_unsupported_payload");
    source_payload.value = 32'h96;
    legacy_port = new("legacy_observed_unsupported_payload_port");
    legacy_port.configure_response(
      command, RDMA_SC_OK, 1'b1, 1'b0, source_payload
    );
    port = legacy_port;
    port.execute_observed(command, result);
    if (result == null || result.ticket == null || result.status == null ||
        result.status.code != RDMA_SC_OK || result.completion != null ||
        result.observation_status == null ||
        result.observation_status.code != RDMA_SC_INVALID_STATE ||
        result.submission_effect != RDMA_SUBMIT_EFFECT_UNOBSERVED)
      `uvm_error("PORT_OBSERVED_UNSUPPORTED_PAYLOAD",
                 "unsupported payload erased outer legacy snapshots")
    #1ns;

    command = make_command(
      "legacy_observed_supported_payload", binding, RDMA_OP_CQC_QUERY,
      8'h97, 1us
    );
    source_payload = new("legacy_supported_payload");
    source_payload.value = 32'h97;
    payload_port = new("legacy_observed_supported_payload_port");
    payload_port.configure_response(
      command, RDMA_SC_OK, 1'b1, 1'b0, source_payload
    );
    port = payload_port;
    port.execute_observed(command, result);
    payload_port.mutate_outputs_now();
    if (result == null || result.completion == null ||
        !$cast(result_payload, result.completion.decoded_response) ||
        result.ticket != result.completion.ticket ||
        result.status != result.completion.status)
      `uvm_error("PORT_OBSERVED_SUPPORTED_PAYLOAD",
                 "explicit payload hook did not retain detached aliases")
    else if (result_payload == source_payload)
      `uvm_error("PORT_OBSERVED_SUPPORTED_PAYLOAD",
                 "explicit payload hook retained a source reference")
    else if (result_payload.value != 32'h97)
      `uvm_error("PORT_OBSERVED_PAYLOAD_MUTATION",
                 "legacy payload mutation leaked into result")

    for (int unsigned source_index = 0; source_index < 2; source_index++) begin
      factory_commands[source_index] = make_command(
        $sformatf("legacy_observed_factory_%0d", source_index), binding,
        RDMA_OP_CQC_QUERY, 8'ha0 + source_index, 1us
      );
      factory_ports[source_index] = new(
        $sformatf("legacy_observed_factory_port_%0d", source_index)
      );
      factory_ports[source_index].configure_response(
        factory_commands[source_index], RDMA_SC_OK, 1'b1, 1'b0
      );
    end

    factory = uvm_factory::get();
    result_fault = new(
      "legacy_execution_result_fault", rdma_cmq_execution_result::get_type()
    );
    status_fault = new("legacy_status_fault", rdma_status::get_type());
    ticket_fault = new("legacy_ticket_fault", rdma_cmq_ticket::get_type());
    image_fault = new("legacy_image_fault", rdma_hw_image::get_type());
    completion_fault = new(
      "legacy_completion_fault", rdma_cmq_completion::get_type()
    );
    factory.set_type_override_by_type(
      rdma_cmq_execution_result::get_type(), result_fault, 1'b1
    );
    factory.set_type_override_by_type(
      rdma_status::get_type(), status_fault, 1'b1
    );
    factory.set_type_override_by_type(
      rdma_cmq_ticket::get_type(), ticket_fault, 1'b1
    );
    factory.set_type_override_by_type(
      rdma_hw_image::get_type(), image_fault, 1'b1
    );
    factory.set_type_override_by_type(
      rdma_cmq_completion::get_type(), completion_fault, 1'b1
    );
    for (int unsigned wrong_type = 0; wrong_type < 2; wrong_type++) begin
      command = factory_commands[wrong_type];
      legacy_port = factory_ports[wrong_type];
      result_fault.arm(wrong_type);
      status_fault.arm(wrong_type);
      ticket_fault.arm(wrong_type);
      image_fault.arm(wrong_type);
      completion_fault.arm(wrong_type);
      port = legacy_port;
      port.execute_observed(command, result);
      if (result == null || result.status == null ||
          result.observation_status == null || result.ticket == null ||
          result.completion == null || result_fault.call_count() != 0 ||
          status_fault.call_count() != 0 || ticket_fault.call_count() != 0 ||
          image_fault.call_count() != 0 || completion_fault.call_count() != 0)
        `uvm_error("PORT_OBSERVED_FACTORY",
                   "legacy fallback entered a raw factory fault wrapper")
      result_fault.disarm();
      status_fault.disarm();
      ticket_fault.disarm();
      image_fault.disarm();
      completion_fault.disarm();
      #1ns;
    end
  endtask

  // 功能：按顺序执行 identity 等价性、legacy fallback、mock 与 real-engine port
  //   场景，使 factory override 前置条件和后续非零时间 deadline 覆盖保持确定。
  // 输入/输出及副作用：phase 为 UVM 输入；持有一次 objection，调用本类八个检查
  //   task 并由它们发布 UVM assertion，最后释放 objection。
  // 失败/边界：子检查通过 UVM_ERROR/FATAL 报告契约偏差；本 task 不吞掉失败，
  //   正常路径始终在全部同步检查返回后 drop_objection。
  virtual task run_phase(uvm_phase phase);
    phase.raise_objection(this);
    check_production_observed_pre_rejection();
    check_command_identity_capture_equivalence();
    check_legacy_observed_fallback();
    check_mock_rejects_hostile_command_snapshots();
    check_mock_fifo_status_and_reconcile();
    check_mock_gate_prerelease();
    check_adapter_routes_real_engines_by_function();
    check_real_engine_ticket_specific_reconcile();
    check_real_engine_late_pair_cleanup();
    phase.drop_objection(this);
  endtask
endclass
