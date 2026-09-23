// 目录：测试层 mocks/rdma_mock_control_plane.sv。
// 职责：验证 rdma_mock_control_plane 对应模块的接口、错误路径和边界行为。
// 依赖：依赖被测 package、UVM 测试基类和必要的 mock/fixture。
// 所有权与生命周期：测试对象只拥有本地 fixture；外部后端句柄由测试环境提供并在测试结束释放。

// 中文说明：rdma_mock_control_plane.sv 属于测试替身，为单元测试提供可控的适配器和控制面行为。
// 阅读提示：先看公开类型和接口，再看实现细节；失败路径应保持状态与资源所有权可追踪。

class rdma_mock_stag_key_policy extends rdma_stag_key_policy;
  `uvm_object_utils(rdma_mock_stag_key_policy)

  bit [7:0] fixed_key;
  int unsigned call_count;
  protected rdma_status next_failure;

  // 功能：构造 rdma_mock_stag_key_policy，调用 super.new 建立 UVM 对象，并把构造体直接写入的默认值设为：fixed_key='0；call_count=0；next_failure=null。
  // 输入/输出及副作用：name（输入）；new 只写入构造体列出的默认字段并返回 void，外部依赖与资源所有权仍由上层管理。
  // 失败/边界：rdma_mock_stag_key_policy 构造只建立本地初始状态，不接管外部 Host-memory、PCIe 或 manager；未完成后续 configure/build/activate 时，业务入口必须返回 INVALID_STATE。
  function new(string name = "rdma_mock_stag_key_policy");
    super.new(name);
    fixed_key = '0;
    call_count = 0;
    next_failure = null;
  endfunction

  // 功能：在 rdma_mock_stag_key_policy 中，fail_next 把错误消息、硬件码或注入故障封装为统一 rdma_status，保留原事务的诊断证据。
  // 输入/输出及副作用：failure（输入）；fail_next 读取 failure 并使用字段 next_failure；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：fail_next 返回 RDMA_SC_INVALID_ARGUMENT；典型拒绝条件为“STAG key failure status is null”；失败路径不提交部分状态或转移未声明资源。
  function rdma_status fail_next(rdma_status failure);
    if (failure == null)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "STAG key failure status is null");
    next_failure = rdma_cmq_clone_status_value(failure);
    return rdma_status::success();
  endfunction

  // 功能：在 rdma_mock_stag_key_policy 中，derive 根据 STAG index、incarnation 和策略参数派生硬件 key，避免释放后旧 key 再次有效。
  // 输入/输出及副作用：mr（输入）、stag_key（输出）；derive 读取 mr、stag_key 并使用字段 stag_key、failure、next_failure，并写入 stag_key；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：derive 下游操作失败时原样传播其 status/result，不伪造成功；该路径不隐式重试，也不转移未声明资源。
  virtual function rdma_status derive(
    rdma_mr mr,
    output bit [7:0] stag_key
  );
    rdma_status failure;

    call_count++;
    stag_key = fixed_key;
    if (next_failure != null) begin
      failure = rdma_cmq_clone_status_value(next_failure);
      next_failure = null;
      return failure;
    end
    return rdma_status::success();
  endfunction
endclass

class rdma_fault_inject_resource_manager extends rdma_resource_manager;
  `uvm_object_utils(rdma_fault_inject_resource_manager)

  int unsigned release_reserved_calls;
  protected rdma_status transition_failures[string];
  protected rdma_status role_failures[string];
  protected int unsigned transition_ordinals[string];

  // 功能：构造 rdma_fault_inject_resource_manager，调用 super.new 建立 UVM 对象，并把构造体直接写入的默认值设为：release_reserved_calls=0。
  // 输入/输出及副作用：name（输入）；new 只写入构造体列出的默认字段并返回 void，外部依赖与资源所有权仍由上层管理。
  // 失败/边界：rdma_fault_inject_resource_manager 构造只建立本地初始状态，不接管外部 Host-memory、PCIe 或 manager；未完成后续 configure/build/activate 时，业务入口必须返回 INVALID_STATE。
  function new(string name = "rdma_fault_inject_resource_manager");
    super.new(name);
    release_reserved_calls = 0;
    transition_failures.delete();
    role_failures.delete(); transition_ordinals.delete();
  endfunction

  // 功能：在 rdma_fault_inject_resource_manager 中，fail_next_transition 把错误消息、硬件码或注入故障封装为统一 rdma_status，保留原事务的诊断证据。
  // 输入/输出及副作用：transition_name（输入）、failure（输入）；fail_next_transition 可能更新本对象明确拥有的状态；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：fail_next_transition 返回 RDMA_SC_INVALID_ARGUMENT；典型拒绝条件为“unknown resource transition”“transition failure status is null”；失败路径不提交部分状态或转移未声明资源。
  function rdma_status fail_next_transition(
    string transition_name,
    rdma_status failure
  );
    if (!(transition_name inside {"stage_allocated", "commit_programmed", "activate",
                                  "release_reserved", "mark_error",
                                  "complete_reserved_error",
                                  "record_queue_context_cleanup_complete",
                                  "record_queue_cleanup_complete"}))
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "unknown resource transition");
    if (failure == null)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "transition failure status is null");
    transition_failures[transition_name] =
      rdma_cmq_clone_status_value(failure);
    return rdma_status::success();
  endfunction

  // 功能：在 rdma_fault_inject_resource_manager 中，fail_role_call 把错误消息、硬件码或注入故障封装为统一 rdma_status，保留原事务的诊断证据。
  // 输入/输出及副作用：method_name（输入）、role（输入）、ordinal（输入）、failure（输入）；fail_role_call 读取 method_name、role、ordinal、failure 并使用输入参数和固定枚举/常量；函数返回 void，不取得调用方资源所有权。
  // 失败/边界：fail_role_call 无返回值，仅执行 函数体中的顺序操作；调用方须保证前置依赖已经绑定，函数不自动重试或接管外部资源。
  function void fail_role_call(string method_name,
                               rdma_queue_backing_role_e role,
                               int unsigned ordinal,
                               rdma_status failure);
    if (failure != null && ordinal != 0)
      role_failures[$sformatf("%s:%0d:%0d", method_name, role, ordinal)] =
        rdma_cmq_clone_status_value(failure);
  endfunction

  // 功能：在 rdma_fault_inject_resource_manager 中，reset reset 清理当前运行状态并建立新的复位/代际边界，使旧句柄或旧事务不能继续生效。
  // 输入/输出及副作用：无显式参数；输入 action/epoch/handle 决定迁移目标；成功时更新状态或恢复证据，外部资源仍由其拥有者管理。
  // 失败/边界：复位参数为零、代际回退或存在未处理 pending 事务时拒绝更新 authority。
  function void reset();
    transition_failures.delete(); role_failures.delete();
    transition_ordinals.delete(); release_reserved_calls = 0;
  endfunction

  // 功能：在 rdma_fault_inject_resource_manager 中，stage_allocated 预检输入并预留事务所需的槽位、映射或中间状态，失败时保留可恢复证据。
  // 输入/输出及副作用：candidate（输入）；stage_allocated 读取 candidate 并使用字段 failure；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：stage_allocated 下游操作失败时原样传播其 status/result，不伪造成功；该路径不隐式重试，也不转移未声明资源。
  virtual function rdma_status stage_allocated(rdma_resource candidate);
    rdma_status failure;

    failure = take_transition_failure("stage_allocated",
      queue_role_for_kind(candidate == null ? RDMA_RESOURCE_CQ :
                          candidate.resource_kind()));
    if (failure != null)
      return failure;
    return super.stage_allocated(candidate);
  endfunction

  // 功能：执行 take_transition_failure 指定的测试或恢复状态变更，更新受控账本并保留可回滚的故障证据。
  // 输入/输出及副作用：transition_name（输入）、role（输入）；take_transition_failure 可能更新本对象明确拥有的状态；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：take_transition_failure 仅允许测试/恢复范围内的状态变更；代际或资源不匹配时拒绝并保留原账本。
  protected function rdma_status take_transition_failure(
    string transition_name,
    rdma_queue_backing_role_e role
  );
    rdma_status failure;
    int unsigned ordinal;
    string key;

    transition_ordinals[transition_name]++;
    ordinal = transition_ordinals[transition_name];
    key = $sformatf("%s:%0d:%0d", transition_name, role, ordinal);
    if (role_failures.exists(key)) begin
      failure = rdma_cmq_clone_status_value(role_failures[key]);
      role_failures.delete(key);
      return failure;
    end

    if (!transition_failures.exists(transition_name))
      return null;
    failure = rdma_cmq_clone_status_value(
      transition_failures[transition_name]
    );
    transition_failures.delete(transition_name);
    return failure;
  endfunction

  // 功能：queue_role_for_kind 使用 kind 计算并返回 rdma_queue_backing_role_e 结果；不修改对象字段或外部资源。
  // 输入/输出及副作用：kind（输入）；queue_role_for_kind 读取 kind 并使用输入参数和固定枚举/常量；函数返回 rdma_queue_backing_role_e，不取得调用方资源所有权。
  // 失败/边界：queue_role_for_kind 按 case(kind) 的固定映射计算 rdma_queue_backing_role_e（RDMA_RESOURCE_SRQ→RDMA_QUEUE_ROLE_SRQ_RING；RDMA_RESOURCE_CEQ→RDMA_QUEUE_ROLE_CEQ_RING；RDMA_RESOURCE_AEQ→RDMA_QUEUE_ROLE_AEQ_RING；default→RDMA_QUEUE_ROLE_CQ_RING）；未列出的输入走 default，不修改运行时账本。
  protected function rdma_queue_backing_role_e queue_role_for_kind(
    rdma_resource_kind_e kind
  );
    case (kind)
      RDMA_RESOURCE_SRQ: return RDMA_QUEUE_ROLE_SRQ_RING;
      RDMA_RESOURCE_CEQ: return RDMA_QUEUE_ROLE_CEQ_RING;
      RDMA_RESOURCE_AEQ: return RDMA_QUEUE_ROLE_AEQ_RING;
      default: return RDMA_QUEUE_ROLE_CQ_RING;
    endcase
  endfunction

  // 功能：在 rdma_fault_inject_resource_manager 中，commit_programmed 执行受控事务并按后端提交证据推进状态机，同时保留失败阶段和 generation 证据。
  // 输入/输出及副作用：candidate（输入）；输入 request/image/cursor 决定写入内容；成功时更新 PI/CI、slot ledger 或 pending journal，并通过 output 返回结果。
  // 失败/边界：commit_programmed 遇到锁、超时、generation 变化或提交证据不完整时保持原状态，不推进游标。
  virtual function rdma_status commit_programmed(rdma_resource candidate);
    rdma_status failure;

    failure = take_transition_failure("commit_programmed",
      queue_role_for_kind(candidate == null ? RDMA_RESOURCE_CQ :
                          candidate.resource_kind()));
    if (failure != null)
      return failure;
    return super.commit_programmed(candidate);
  endfunction

  // 功能：在 rdma_fault_inject_resource_manager 中，activate 校验依赖和 binding 后建立运行边界，只保存非拥有引用并拒绝重复配置。
  // 输入/输出及副作用：handle（输入）；activate 先依据 failure != null 校验 handle；成功时更新本对象配置/状态并保存非拥有引用，返回 rdma_status。
  // 失败/边界：实现中的空依赖、重复登记、状态或 generation/authority 校验失败时返回错误；失败时保留旧配置。
  virtual function rdma_status activate(rdma_handle handle);
    rdma_status failure;

    failure = take_transition_failure("activate", queue_role_for_kind(
      handle == null ? RDMA_RESOURCE_CQ : handle.kind));
    if (failure != null)
      return failure;
    return super.activate(handle);
  endfunction

  // 功能：在 rdma_fault_inject_resource_manager 中，release_reserved 按 owner、generation 和幂等规则释放/隔离记录，并同步删除其账本引用。
  // 输入/输出及副作用：handle（输入）；输入 handle/mapping/token 指定释放目标；成功时更新账本和生命周期，外部资源只按 adapter 契约释放。
  // 失败/边界：release_reserved 发现 owner/generation 不匹配、记录未知或重复释放时返回错误或幂等结果，不重新激活旧句柄。
  virtual function rdma_status release_reserved(rdma_handle handle);
    rdma_status failure;

    release_reserved_calls++;
    failure = take_transition_failure("release_reserved", queue_role_for_kind(
      handle == null ? RDMA_RESOURCE_CQ : handle.kind));
    if (failure != null)
      return failure;
    return super.release_reserved(handle);
  endfunction

  // 功能：在 rdma_fault_inject_resource_manager 中，mark_error 执行 mark_error 的mark_error 指定的测试或恢复状态变更，更新受控账本并保留可回滚的故障证据。
  // 输入/输出及副作用：handle（输入）、recovery（输入）；输入 request/image/cursor 决定写入内容；成功时更新 PI/CI、slot ledger 或 pending journal，并通过
  //   output 返回结果。
  // 失败/边界：mark_error 仅允许测试/恢复范围内的状态变更；代际或资源不匹配时拒绝并保留原账本。
  virtual function rdma_status mark_error(
    rdma_handle handle,
    rdma_recovery_record recovery
  );
    rdma_status failure;

    failure = take_transition_failure("mark_error",
      (recovery != null && recovery.queue_recovery_valid) ?
        recovery.ambiguous_role : queue_role_for_kind(
          handle == null ? RDMA_RESOURCE_CQ : handle.kind));
    if (failure != null)
      return failure;
    return super.mark_error(handle, recovery);
  endfunction

  // 功能：在 rdma_fault_inject_resource_manager 中，complete_reserved_error 提交当前事务阶段并发布 detached 结果，只有成功路径才推进游标或状态。
  // 输入/输出及副作用：handle（输入）；complete_reserved_error 读取 handle 并使用字段 failure；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：complete_reserved_error 下游操作失败时原样传播其 status/result，不伪造成功；该路径不隐式重试，也不转移未声明资源。
  virtual function rdma_status complete_reserved_error(
    rdma_handle handle
  );
    rdma_status failure;

    failure = take_transition_failure("complete_reserved_error",
      queue_role_for_kind(handle == null ? RDMA_RESOURCE_CQ : handle.kind));
    if (failure != null)
      return failure;
    return super.complete_reserved_error(handle);
  endfunction

  // 功能：在 rdma_fault_inject_resource_manager 中，record_queue_context_cleanup_complete 记录 record_queue_context_cleanup_complete 的调用名称和顺序，供测试断言转发路径；不改变被测事务业务结果。
  // 输入/输出及副作用：handle（输入）；输入 request/image/cursor 决定写入内容；成功时更新 PI/CI、slot ledger 或 pending journal，并通过 output 返回结果。
  // 失败/边界：记录操作仅影响测试 trace；不得因注入记录故障改变生产状态或吞掉真实错误。
  virtual function rdma_status record_queue_context_cleanup_complete(
    rdma_handle handle
  );
    rdma_status failure;

    failure = take_transition_failure(
      "record_queue_context_cleanup_complete", queue_role_for_kind(
        handle == null ? RDMA_RESOURCE_CQ : handle.kind));
    if (failure != null)
      return failure;
    return super.record_queue_context_cleanup_complete(handle);
  endfunction

  // 功能：在 rdma_fault_inject_resource_manager 中，record_queue_cleanup_complete 记录 record_queue_cleanup_complete 的调用名称和顺序，供测试断言转发路径；不改变被测事务业务结果。
  // 输入/输出及副作用：handle（输入）、role（输入）；输入 request/image/cursor 决定写入内容；成功时更新 PI/CI、slot ledger 或 pending journal，并通过 output
  //   返回结果。
  // 失败/边界：记录操作仅影响测试 trace；不得因注入记录故障改变生产状态或吞掉真实错误。
  virtual function rdma_status record_queue_cleanup_complete(
    rdma_handle handle,
    rdma_queue_backing_role_e role
  );
    rdma_status failure;

    failure = take_transition_failure("record_queue_cleanup_complete", role);
    if (failure != null)
      return failure;
    return super.record_queue_cleanup_complete(handle, role);
  endfunction
endclass

class rdma_mock_cmq_call extends uvm_object;
  `uvm_object_utils(rdma_mock_cmq_call)

  longint unsigned \sequence ;
  bit [7:0] opcode;
  rdma_cmq_command_desc command;
  rdma_cmq_ticket ticket;

  // 功能：构造 rdma_mock_cmq_call，调用 super.new 建立 UVM 对象，并把构造体直接写入的默认值设为：sequence=0；opcode='0；command=null；ticket=null。
  // 输入/输出及副作用：name（输入）；new 只写入构造体列出的默认字段并返回 void，外部依赖与资源所有权仍由上层管理。
  // 失败/边界：rdma_mock_cmq_call 构造只建立本地初始状态，不接管外部 Host-memory、PCIe 或 manager；未完成后续 configure/build/activate 时，业务入口必须返回 INVALID_STATE。
  function new(string name = "rdma_mock_cmq_call");
    super.new(name);
    \sequence  = 0;
    opcode = '0;
    command = null;
    ticket = null;
  endfunction

  // 功能：将 rhs 中 rdma_mock_cmq_call 的值字段复制到当前对象，建立与源对象隔离的快照。
  // 输入/输出及副作用：rhs（输入）；rhs 是源对象；当前对象字段会被覆盖，嵌套句柄按实现执行 clone 或保持非拥有引用，源对象不被修改。
  // 失败/边界：do_copy 在源对象为空、clone/cast 失败或类型不匹配时触发 UVM fatal（mock CMQ call copy mismatch），不保留部分有效快照。
  virtual function void do_copy(uvm_object rhs);
    rdma_mock_cmq_call rhs_call;
    uvm_object cloned_object;

    super.do_copy(rhs);
    if (!$cast(rhs_call, rhs))
      `uvm_fatal("RDMA_COPY_TYPE", "mock CMQ call copy mismatch")
    \sequence  = rhs_call.\sequence ;
    opcode = rhs_call.opcode;
    command = null;
    if (rhs_call.command != null) begin
      cloned_object = rhs_call.command.clone();
      if (cloned_object == null || !$cast(command, cloned_object))
        `uvm_fatal("RDMA_COPY_TYPE", "mock CMQ call command clone mismatch")
    end
    ticket = rdma_cmq_clone_ticket_value(rhs_call.ticket, "mock CMQ call");
  endfunction
endclass

typedef enum bit {
  RDMA_MOCK_CMQ_COMPLETION,
  RDMA_MOCK_CMQ_TIMEOUT
} rdma_mock_cmq_outcome_kind_e;

class rdma_mock_cmq_snapshot_engine extends rdma_cmq_engine;
  `uvm_object_utils(rdma_mock_cmq_snapshot_engine)

  // 功能：构造 rdma_mock_cmq_snapshot_engine，调用 super.new 建立 UVM 对象，并把构造体直接写入的默认值设为：profile=rdma_hw_cmq_hw_profile::type_id::create(。
  // 输入/输出及副作用：name（输入）；new 只写入构造体列出的默认字段并返回 void，外部依赖与资源所有权仍由上层管理。
  // 失败/边界：rdma_mock_cmq_snapshot_engine 构造只建立本地初始状态，不接管外部 Host-memory、PCIe 或 manager；未完成后续 configure/build/activate 时，业务入口必须返回 INVALID_STATE。
  function new(string name = "rdma_mock_cmq_snapshot_engine");
    super.new(name);
    profile = rdma_hw_cmq_hw_profile::type_id::create(
      {name, "_profile"}
    );
  endfunction

  // 功能：在 rdma_mock_cmq_snapshot_engine 中，snapshot_command_for_mock 按完整 key/handle 查找唯一权威记录并返回 detached 快照，避免把内部可变引用泄露给调用方。
  // 输入/输出及副作用：source（输入）、snapshot（输出）、staging_invariant_failed（输出）；输入 handle/key/cursor 用于选择读取范围；返回值或 output 为
  //   detached 快照，读取不取得外部资源所有权。
  // 失败/边界：snapshot_command_for_mock 在 key/handle 缺失、记录不唯一或 generation/reset epoch 过期时返回明确错误，不回退到默认 authority。
  function rdma_status snapshot_command_for_mock(
    rdma_cmq_command_desc source,
    output rdma_cmq_command_desc snapshot,
    output bit staging_invariant_failed
  );
    return snapshot_command_value(source, snapshot,
                                  staging_invariant_failed);
  endfunction
endclass

class rdma_mock_cmq_outcome extends uvm_object;
  `uvm_object_utils(rdma_mock_cmq_outcome)

  rdma_mock_cmq_outcome_kind_e kind;
  rdma_status status;
  // Optional decoded payload used by scripted QUERY completions.
  uvm_object decoded_response;

  // 功能：构造 rdma_mock_cmq_outcome，调用 super.new 建立 UVM 对象，并把构造体直接写入的默认值设为：kind=RDMA_MOCK_CMQ_COMPLETION；status=null；decoded_response=null。
  // 输入/输出及副作用：name（输入）；new 只写入构造体列出的默认字段并返回 void，外部依赖与资源所有权仍由上层管理。
  // 失败/边界：rdma_mock_cmq_outcome 构造只建立本地初始状态，不接管外部 Host-memory、PCIe 或 manager；未完成后续 configure/build/activate 时，业务入口必须返回 INVALID_STATE。
  function new(string name = "rdma_mock_cmq_outcome");
    super.new(name);
    kind = RDMA_MOCK_CMQ_COMPLETION;
    status = null;
    decoded_response = null;
  endfunction
endclass

class rdma_mock_cmq_reconcile_script extends uvm_object;
  `uvm_object_utils(rdma_mock_cmq_reconcile_script)

  bit terminal_known;
  rdma_cmq_completion completion;
  rdma_status status;

  // 功能：构造 rdma_mock_cmq_reconcile_script，调用 super.new 建立 UVM 对象，并把构造体直接写入的默认值设为：terminal_known=1'b0；completion=null；status=null。
  // 输入/输出及副作用：name（输入）；new 只写入构造体列出的默认字段并返回 void，外部依赖与资源所有权仍由上层管理。
  // 失败/边界：rdma_mock_cmq_reconcile_script 构造只建立本地初始状态，不接管外部 Host-memory、PCIe 或 manager；未完成后续 configure/build/activate 时，业务入口必须返回 INVALID_STATE。
  function new(string name = "rdma_mock_cmq_reconcile_script");
    super.new(name);
    terminal_known = 1'b0;
    completion = null;
    status = null;
  endfunction
endclass

class rdma_mock_cmq_port extends rdma_cmq_port;
  `uvm_object_utils(rdma_mock_cmq_port)

  rdma_mock_cmq_call calls[$];
  uvm_event entered;
  uvm_event release_gate;
  rdma_mock_call_trace call_trace;

  protected longint unsigned next_sequence;
  protected rdma_mock_cmq_outcome outcomes[bit [7:0]][$];
  protected rdma_cmq_completion late_completions[string][$];
  protected rdma_mock_cmq_reconcile_script reconcile_scripts[string][$];
  protected rdma_mock_cmq_snapshot_engine snapshot_engine;
  protected bit gate_enabled;
  protected bit [7:0] gated_opcode;
  protected int unsigned gate_target_count;
  protected int unsigned gate_entered_count;
  // 中文设计：该 shared seam 仅描述最近一次 legacy execute() 在 mock 内部是否
  // 可证明地未写入 call ledger；Phase 1A observed fallback 不读取它，避免把
  // mock 专属证据误提升为通用 lifecycle observation，1B consumer 迁移前保留。
  // Evidence is scoped to the most recent execute() call.  It is asserted
  // only on mock adapter paths that return before recording a CMQ call.
  protected bit last_execute_no_submit_proven;
  protected rdma_status role_failures[string];
  protected int unsigned method_ordinals[string];

  // 功能：构造 rdma_mock_cmq_port，调用 super.new 建立 UVM 对象，并把构造体直接写入的默认值设为：next_sequence=1；entered=new({name, "_entered"})；release_gate=new({name, "_release_gate"})；call_trace=null；gate_enabled=1'b0；gated_opcode='0；gate_target_count=1；gate_entered_count=0；其余字段按实现默认值初始化。
  // 输入/输出及副作用：name（输入）；new 只写入构造体列出的默认字段并返回 void，外部依赖与资源所有权仍由上层管理。
  // 失败/边界：rdma_mock_cmq_port 构造只建立本地初始状态；本地 semaphore/ledger 等按构造体显式分配，不接管外部 Host-memory、PCIe 或 manager；未完成后续 configure/build/activate 时，业务入口必须返回 INVALID_STATE。
  function new(string name = "rdma_mock_cmq_port");
    super.new(name);
    calls.delete();
    outcomes.delete();
    late_completions.delete();
    reconcile_scripts.delete();
    next_sequence = 1;
    entered = new({name, "_entered"});
    release_gate = new({name, "_release_gate"});
    call_trace = null;
    gate_enabled = 1'b0;
    gated_opcode = '0;
    gate_target_count = 1;
    gate_entered_count = 0;
    last_execute_no_submit_proven = 1'b0;
    role_failures.delete();
    method_ordinals.delete();
    snapshot_engine = rdma_mock_cmq_snapshot_engine::type_id::create(
      {name, "_snapshot_engine"}
    );
  endfunction

  // 功能：在 rdma_mock_cmq_port 中，last_execute_definitive_no_submit 只读查询当前运行时/测试账本，返回槽位、对象或恢复记录的快照而不推进事务。
  // 输入/输出及副作用：无显式参数；last_execute_definitive_no_submit 读取固定返回值或局部计算结果，不使用对象成员字段；函数返回 bit，不取得调用方资源所有权。
  // 失败/边界：last_execute_definitive_no_submit 的结果直接由 return last_execute_no_submit_proven 计算；输入不满足表达式条件时沿函数体的保守分支返回，不修改已发布账本。
  virtual function bit last_execute_definitive_no_submit();
    return last_execute_no_submit_proven;
  endfunction

  // 功能：在 rdma_mock_cmq_port 中，set_call_trace 记录 set_call_trace 的调用名称和顺序，供测试断言转发路径；不改变被测事务业务结果。
  // 输入/输出及副作用：trace（输入）；set_call_trace 先依据 依赖存在性、authority 和 generation 条件 校验 trace；成功时更新本对象配置/状态并保存非拥有引用，返回 void。
  // 失败/边界：记录操作仅影响测试 trace；不得因注入记录故障改变生产状态或吞掉真实错误。
  function void set_call_trace(rdma_mock_call_trace trace);
    call_trace = trace;
  endfunction

  // 功能：在 rdma_mock_cmq_port 中，gate_opcode 配置测试 fixture 的定向故障或替代依赖，使下一次调用覆盖指定边界路径。
  // 输入/输出及副作用：opcode（输入）；gate_opcode 读取 opcode 并使用输入参数和固定枚举/常量；函数返回 void，不取得调用方资源所有权。
  // 失败/边界：gate_opcode 无返回值，仅执行 函数体中的顺序操作；调用方须保证前置依赖已经绑定，函数不自动重试或接管外部资源。
  function void gate_opcode(bit [7:0] opcode);
    gate_opcode_count(opcode, 1);
  endfunction

  // Lifecycle-test naming for the CMQ pause barrier.  The gate only waits on
  // the selected opcode and does not hold any adapter mutex, so other
  // Functions may continue to enter execute().
  // 功能：在 rdma_mock_cmq_port 中，pause_cmq_opcode 配置测试 fixture 的定向故障或替代依赖，使下一次调用覆盖指定边界路径。
  // 输入/输出及副作用：opcode（输入）；pause_cmq_opcode 驱动下游事务；函数返回 无直接返回值，不取得调用方资源所有权。
  // 失败/边界：pause_cmq_opcode 异常完成由下游接口或 UVM 报告机制发布；该路径不隐式重试，也不转移未声明资源。
  task pause_cmq_opcode(bit [7:0] opcode);
    gate_opcode(opcode);
  endtask

  // 功能：控制 wait_until_paused 对应的等待、异常或同步边界，按超时/捕获结果返回状态，不吞掉原始错误。
  // 输入/输出及副作用：opcode（输入）；wait_until_paused 驱动下游事务；函数返回 无直接返回值，不取得调用方资源所有权。
  // 失败/边界：wait_until_paused 超时或异常必须返回原始错误证据；不得无限等待或跳过同步边界。
  task wait_until_paused(bit [7:0] opcode);
    bit observed;
    while (!gate_enabled || gated_opcode != opcode || gate_entered_count == 0)
      #1;
    observed = 1'b1;
  endtask

  // 功能：在 rdma_mock_cmq_port 中，release_cmq_opcode 按 owner、generation 和幂等规则释放/隔离记录，并同步删除其账本引用。
  // 输入/输出及副作用：opcode（输入）；输入 handle/mapping/token 指定释放目标；成功时更新账本和生命周期，外部资源只按 adapter 契约释放。
  // 失败/边界：release_cmq_opcode 发现 owner/generation 不匹配、记录未知或重复释放时返回错误或幂等结果，不重新激活旧句柄。
  function void release_cmq_opcode(bit [7:0] opcode);
    if (gate_enabled && gated_opcode == opcode)
      release_one();
  endfunction

  // 功能：在 rdma_mock_cmq_port 中，fail_role_call 把错误消息、硬件码或注入故障封装为统一 rdma_status，保留原事务的诊断证据。
  // 输入/输出及副作用：method_name（输入）、role（输入）、ordinal（输入）、status（输入）；fail_role_call 读取 method_name、role、ordinal、status 并使用输入参数和固定枚举/常量；函数返回 void，不取得调用方资源所有权。
  // 失败/边界：fail_role_call 无返回值，仅执行 函数体中的顺序操作；调用方须保证前置依赖已经绑定，函数不自动重试或接管外部资源。
  function void fail_role_call(string method_name,
                               rdma_queue_backing_role_e role,
                               int unsigned ordinal,
                               rdma_status status);
    if (status != null && ordinal != 0) begin
      role_failures[$sformatf("%s:%0d:%0d", method_name, role, ordinal)] =
        rdma_cmq_clone_status_value(status);
    end
  endfunction

  // 功能：在 rdma_mock_cmq_port 中，reset reset 清理当前运行状态并建立新的复位/代际边界，使旧句柄或旧事务不能继续生效。
  // 输入/输出及副作用：无显式参数；输入 action/epoch/handle 决定迁移目标；成功时更新状态或恢复证据，外部资源仍由其拥有者管理。
  // 失败/边界：复位参数为零、代际回退或存在未处理 pending 事务时拒绝更新 authority。
  function void reset();
    calls.delete(); outcomes.delete(); late_completions.delete();
    reconcile_scripts.delete(); next_sequence = 1;
    role_failures.delete();
    method_ordinals.delete();
    gate_enabled = 1'b0; gate_entered_count = 0; gate_target_count = 1;
    last_execute_no_submit_proven = 1'b0;
    entered.reset(); release_gate.reset();
  endfunction

  // Hold all matching CMQ executions until release_one(), allowing tests to
  // establish a deterministic multi-Function barrier.
  // 功能：在 rdma_mock_cmq_port 中，gate_opcode_count 配置测试 fixture 的定向故障或替代依赖，使下一次调用覆盖指定边界路径。
  // 输入/输出及副作用：opcode（输入）、count（输入）；gate_opcode_count 读取 opcode、count 并使用字段 gated_opcode、gate_enabled、gate_target_count、gate_entered_count；函数返回 void，不取得调用方资源所有权。
  // 失败/边界：gate_opcode_count 无返回值，仅执行 gated_opcode=opcode、gate_enabled=1'b1、gate_target_count=(count == 0) ? 1 : count、gate_entered_count=0；调用方须保证前置依赖已经绑定，函数不自动重试或接管外部资源。
  function void gate_opcode_count(bit [7:0] opcode, int unsigned count);
    gated_opcode = opcode;
    gate_enabled = 1'b1;
    gate_target_count = (count == 0) ? 1 : count;
    gate_entered_count = 0;
    release_gate.reset();
    entered.reset();
  endfunction

  // 功能：控制 wait_until_entered 对应的等待、异常或同步边界，按超时/捕获结果返回状态，不吞掉原始错误。
  // 输入/输出及副作用：expected_count（输入）、timeout（输入）、observed（输出）；wait_until_entered 驱动下游事务，并写入 observed；函数返回 无直接返回值，不取得调用方资源所有权。
  // 失败/边界：wait_until_entered 超时或异常必须返回原始错误证据；不得无限等待或跳过同步边界。
  task wait_until_entered(
    int unsigned expected_count,
    time timeout,
    output bit observed
  );
    observed = 1'b0;
    fork : wait_for_mock_cmq_gate
      begin
        while (gate_entered_count < expected_count)
          entered.wait_trigger();
        observed = 1'b1;
      end
      begin
        #(timeout);
      end
    join_any
    disable wait_for_mock_cmq_gate;
  endtask

  // 功能：在 rdma_mock_cmq_port 中，release_one 关闭当前 opcode gate 并触发等待者继续执行，完成测试同步屏障的释放。
  // 输入/输出及副作用：无显式参数；成功时更新 gate_enabled 并触发 release_gate 事件，不修改 CMQ call ledger 或外部资源。
  // 失败/边界：release_one 仅在 release_gate 已构造时有效；重复调用保持 gate 关闭并重复触发事件，调用者不得把它当作 CMQ 提交结果。
  function void release_one();
    gate_enabled = 1'b0;
    release_gate.trigger();
  endfunction

  // 功能：在 rdma_mock_cmq_port 中，invalid_argument 把错误消息、硬件码或注入故障封装为统一 rdma_status，保留原事务的诊断证据。
  // 输入/输出及副作用：message（输入）；invalid_argument 读取 message 并使用字段 rdma_status；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：invalid_argument 返回 RDMA_SC_INVALID_ARGUMENT；失败路径不提交部分状态或转移未声明资源。
  protected function rdma_status invalid_argument(string message);
    return rdma_status::make(RDMA_SC_INVALID_ARGUMENT, message);
  endfunction

  // 功能：在 rdma_mock_cmq_port 中，invalid_state 把错误消息、硬件码或注入故障封装为统一 rdma_status，保留原事务的诊断证据。
  // 输入/输出及副作用：message（输入）；invalid_state 读取 message 并使用字段 rdma_status；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：invalid_state 返回 RDMA_SC_INVALID_STATE；失败路径不提交部分状态或转移未声明资源。
  protected function rdma_status invalid_state(string message);
    return rdma_status::make(RDMA_SC_INVALID_STATE, message);
  endfunction

  // 功能：在 rdma_mock_cmq_port 中，execute_role 执行受控事务并按后端提交证据推进状态机，同时保留失败阶段和 generation 证据。
  // 输入/输出及副作用：opcode（输入）、flush_ordinal（输入）；execute_role 可能更新本对象明确拥有的状态；函数返回 rdma_queue_backing_role_e，不取得调用方资源所有权。
  // 失败/边界：execute_role 遇到锁、超时、generation 变化或提交证据不完整时保持原状态，不推进游标。
  protected function rdma_queue_backing_role_e execute_role(
    bit [7:0] opcode,
    int unsigned flush_ordinal
  );
    string key;

    case (opcode)
      RDMA_OP_CQC_CREATE, RDMA_OP_CQC_DELETE,
      RDMA_OP_CQC_QUERY: return RDMA_QUEUE_ROLE_CQ_RING;
      RDMA_OP_SRFQC_CREATE, RDMA_OP_SRFQC_DELETE,
      RDMA_OP_SRFQC_QUERY: return RDMA_QUEUE_ROLE_SRQ_RING;
      RDMA_OP_CEQC_CREATE, RDMA_OP_CEQC_DELETE,
      RDMA_OP_CEQC_QUERY: return RDMA_QUEUE_ROLE_CEQ_RING;
      RDMA_OP_AEQC_CREATE, RDMA_OP_AEQC_DELETE,
      RDMA_OP_AEQC_QUERY: return RDMA_QUEUE_ROLE_AEQ_RING;
      RDMA_OP_OCC_FLUSH: begin
        // SRQ has two ordered PD flushes.  CQ has one post-delete PD flush;
        // prefer an explicitly scripted CQ role when present, otherwise use
        // the canonical SRQ ordinal mapping.
        key = $sformatf("pre_flush_%0d:%0d:%0d", flush_ordinal - 1,
                        RDMA_QUEUE_ROLE_CQ_PD, flush_ordinal);
        if (role_failures.exists(key)) return RDMA_QUEUE_ROLE_CQ_PD;
        key = $sformatf("post_flush_%0d:%0d:%0d", flush_ordinal - 1,
                        RDMA_QUEUE_ROLE_CQ_PD, flush_ordinal);
        if (role_failures.exists(key)) return RDMA_QUEUE_ROLE_CQ_PD;
        return flush_ordinal == 1 ? RDMA_QUEUE_ROLE_SRFQ_PD :
                                     RDMA_QUEUE_ROLE_SRQ_PD;
      end
      default: return RDMA_QUEUE_ROLE_CQ_RING;
    endcase
  endfunction

  // 功能：在 rdma_mock_cmq_port 中，take_role_failure 执行 take_role_failure 的take_role_failure 指定的测试或恢复状态变更，更新受控账本并保留可回滚的故障证据。
  // 输入/输出及副作用：method_name（输入）、role（输入）、ordinal（输入）；take_role_failure 读取 method_name、role、ordinal 并使用字段 key、failure；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：take_role_failure 仅允许测试/恢复范围内的状态变更；代际或资源不匹配时拒绝并保留原账本。
  protected function rdma_status take_role_failure(
    string method_name,
    rdma_queue_backing_role_e role,
    int unsigned ordinal
  );
    string key;
    rdma_status failure;

    key = $sformatf("%s:%0d:%0d", method_name, role, ordinal);
    if (!role_failures.exists(key)) return null;
    failure = rdma_cmq_clone_status_value(role_failures[key]);
    role_failures.delete(key);
    return failure;
  endfunction

  // 功能：在 rdma_mock_cmq_port 中由 same_ticket 逐字段比较输入值，返回结构、身份或序列化内容是否一致。
  // 输入/输出及副作用：lhs（输入）、rhs（输入）；比较对象/数组只读；返回 bit 或状态结果，不更新 runtime、账本或外部 adapter。
  // 失败/边界：same_ticket 的任一比较对象为空或类型不符时返回确定的 false/不等结果，不抛出未处理异常。
  protected function bit same_ticket(
    rdma_cmq_ticket lhs,
    rdma_cmq_ticket rhs
  );
    if (lhs == null || rhs == null || lhs.function_h == null ||
        rhs.function_h == null || lhs.cmq_h == null || rhs.cmq_h == null ||
        lhs.opcode_key == null || rhs.opcode_key == null)
      return 1'b0;
    return lhs.command_id == rhs.command_id &&
           lhs.function_h.same_instance(rhs.function_h) &&
           lhs.cmq_h.same_instance(rhs.cmq_h) &&
           lhs.slot_sequence == rhs.slot_sequence &&
           lhs.sq_index == rhs.sq_index && lhs.sq_wrap == rhs.sq_wrap &&
           lhs.opcode_key.profile_name == rhs.opcode_key.profile_name &&
           lhs.opcode_key.opcode == rhs.opcode_key.opcode &&
           lhs.opcode_key.variant == rhs.opcode_key.variant &&
           lhs.absolute_deadline == rhs.absolute_deadline;
  endfunction

  // 功能：在 rdma_mock_cmq_port 中，ticket_key 把 Function/对象身份、代际和游标字段拼成稳定的查找键，供登记表去重和恢复路由使用。
  // 输入/输出及副作用：ticket（输入）；ticket_key 读取 ticket 并使用字段 function_uid、object_id、generation；函数返回 string，不取得调用方资源所有权。
// 失败/边界：ticket_key 只按函数体列出的身份、generation、kind、object_id 或 cursor 字段拼接键；调用方须先完成空句柄校验，函数本身不分配资源、不自动回退到 root0。
  protected function string ticket_key(rdma_cmq_ticket ticket);
    return $sformatf(
      "%016h:%08h:%08h:%016h:%016h:%08h:%0b",
      ticket.function_h.function_uid,
      ticket.function_h.object_id,
      ticket.function_h.generation,
      ticket.command_id,
      ticket.slot_sequence,
      ticket.sq_index,
      ticket.sq_wrap
    );
  endfunction

  // 功能：在 rdma_mock_cmq_port 中，ticket_was_recorded 检查当前事务或测试证据是否满足指定布尔条件，供恢复分类和断言选择后续路径。
  // 输入/输出及副作用：ticket（输入）；ticket_was_recorded 读取 ticket 并使用字段 calls；函数返回 bit，不取得调用方资源所有权。
  // 失败/边界：ticket_was_recorded 比较或前置条件不满足时返回 0/false；该路径不隐式重试，也不转移未声明资源。
  protected function bit ticket_was_recorded(rdma_cmq_ticket ticket);
    foreach (calls[i]) begin
      if (calls[i] != null && same_ticket(calls[i].ticket, ticket))
        return 1'b1;
    end
    return 1'b0;
  endfunction

  // 功能：在 rdma_mock_cmq_port 中，snapshot_command 按完整 key/handle 查找唯一权威记录并返回 detached 快照，避免把内部可变引用泄露给调用方。
  // 输入/输出及副作用：source（输入）、snapshot（输出）；snapshot_command 读取 source、snapshot 并使用字段 snapshot、staging_invariant_failed、snapshot_status、status_copy，并写入 snapshot；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：snapshot_command 在 key/handle 缺失、记录不唯一或 generation/reset epoch 过期时返回明确错误，不回退到默认 authority。
  protected function rdma_status snapshot_command(
    rdma_cmq_command_desc source,
    output rdma_cmq_command_desc snapshot
  );
    rdma_status snapshot_status;
    rdma_status status_copy;
    bit staging_invariant_failed;

    snapshot = null;
    staging_invariant_failed = 1'b0;
    if (snapshot_engine == null)
      return invalid_state("mock CMQ snapshot engine is unavailable");
    snapshot_status = snapshot_engine.snapshot_command_for_mock(
      source, snapshot, staging_invariant_failed
    );
    if (snapshot_status == null) begin
      snapshot = null;
      return invalid_state("mock CMQ command snapshot returned null status");
    end
    if (staging_invariant_failed) begin
      snapshot = null;
      return invalid_state("mock CMQ command snapshot invariant failed");
    end
    if (!snapshot_status.ok()) begin
      snapshot = null;
      status_copy = rdma_cmq_clone_status_value(snapshot_status);
      return (status_copy == null) ?
        invalid_state("mock CMQ command snapshot status copy failed") :
        status_copy;
    end
    if (snapshot == null)
      return invalid_state("mock CMQ command snapshot is null");
    return rdma_status::success();
  endfunction

  // 功能：make_ticket 创建独立的 rdma_status；根据 command、call_sequence、ticket 设置字段 ticket、ticket.command_id、ticket.function_h、function_h.kind、function_h.function_uid、function_h.object_id、function_h.generation、ticket.cmq_h、cmq_h.kind、cmq_h.function_uid，返回对象仅由调用方持有，不转移外部资源所有权。
  // 输入/输出及副作用：command（输入）、call_sequence（输入）、ticket（输出）；make_ticket 读取 command、call_sequence、ticket 并使用字段 ticket、ticket.command_id、ticket.function_h、function_h.kind、function_h.function_uid、function_h.object_id、function_h.generation、ticket.cmq_h，并写入 ticket；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：make_ticket 返回 RDMA_SC_INVALID_STATE；典型拒绝条件为“mock CMQ ticket source is incomplete”；失败路径不提交部分状态或转移未声明资源。
  protected function rdma_status make_ticket(
    rdma_cmq_command_desc command,
    longint unsigned call_sequence,
    output rdma_cmq_ticket ticket
  );
    rdma_status validation_status;

    ticket = null;
    if (command == null || command.function_h == null ||
        command.opcode_key == null || command.timeout == 0)
      return invalid_state("mock CMQ ticket source is incomplete");
    ticket = new($sformatf("mock_cmq_ticket_%0d", call_sequence));
    ticket.command_id = call_sequence;
    ticket.function_h = new(
      $sformatf("mock_cmq_function_%0d", call_sequence)
    );
    ticket.function_h.kind = command.function_h.kind;
    ticket.function_h.function_uid = command.function_h.function_uid;
    ticket.function_h.object_id = command.function_h.object_id;
    ticket.function_h.generation = command.function_h.generation;
    ticket.cmq_h = new($sformatf("mock_cmq_handle_%0d", call_sequence));
    ticket.cmq_h.kind = RDMA_RESOURCE_CMQ;
    ticket.cmq_h.function_uid = ticket.function_h.function_uid;
    ticket.cmq_h.object_id = 32'hffff_0001;
    ticket.cmq_h.generation = ticket.function_h.generation;
    ticket.slot_sequence = call_sequence - 1'b1;
    ticket.sq_index = ticket.slot_sequence % 32;
    ticket.sq_wrap = (ticket.slot_sequence / 32) % 2;
    ticket.opcode_key = new(
      $sformatf("mock_cmq_opcode_%0d", call_sequence)
    );
    ticket.opcode_key.profile_name = command.opcode_key.profile_name;
    ticket.opcode_key.opcode = command.opcode_key.opcode;
    ticket.opcode_key.variant = command.opcode_key.variant;
    ticket.absolute_deadline = $time + command.timeout;
    validation_status = ticket.validate();
    if (validation_status == null || !validation_status.ok()) begin
      ticket = null;
      return (validation_status == null) ?
        invalid_state("mock CMQ ticket validation returned null") :
        rdma_cmq_clone_status_value(validation_status);
    end
    return rdma_status::success();
  endfunction

  // 功能：make_completion 创建独立的 rdma_cmq_completion；根据 ticket、result_status、with_raw_cqe 设置字段 completion、completion.ticket、completion.status、status.source_engine、status.function_uid、status.generation、status.resource_id、status.command_id、completion.raw_cqe、i，返回对象仅由调用方持有，不转移外部资源所有权。
  // 输入/输出及副作用：ticket（输入）、result_status（输入）、with_raw_cqe（输入）；make_completion 读取 ticket、result_status、with_raw_cqe 并使用字段 completion、completion.ticket、completion.status、status.source_engine、status.function_uid、status.generation、status.resource_id、status.command_id；函数返回 rdma_cmq_completion，不取得调用方资源所有权。
  // 失败/边界：make_completion 输入对象为空或查找未命中时返回 null；该路径不隐式重试，也不转移未声明资源。
  protected function rdma_cmq_completion make_completion(
    rdma_cmq_ticket ticket,
    rdma_status result_status,
    bit with_raw_cqe
  );
    rdma_cmq_completion completion;
    rdma_status validation_status;

    if (ticket == null || result_status == null)
      return null;
    completion = new("mock_cmq_completion");
    completion.ticket = rdma_cmq_clone_ticket_value(
      ticket, "mock CMQ completion"
    );
    completion.status = rdma_cmq_clone_status_value(result_status);
    if (completion.ticket == null || completion.status == null)
      return null;
    completion.status.source_engine = RDMA_ENGINE_CMQ;
    completion.status.function_uid = completion.ticket.function_h.function_uid;
    completion.status.generation = completion.ticket.function_h.generation;
    completion.status.resource_id = completion.ticket.cmq_h.object_id;
    completion.status.command_id = completion.ticket.command_id;
    if (with_raw_cqe) begin
      completion.raw_cqe = new("mock_cmq_raw_cqe");
      for (int unsigned i = 0; i < 64; i++)
        completion.raw_cqe.bytes.push_back(byte'(i));
      completion.raw_cqe.length = 64;
      completion.raw_cqe.alignment = 64;
      completion.raw_cqe.endian = RDMA_ENDIAN_LITTLE;
      completion.raw_cqe.image_kind = RDMA_IMAGE_CMQ_CQE;
      completion.raw_cqe.hardware_version = 1;
      completion.raw_cqe.function_generation =
        completion.ticket.function_h.generation;
      completion.raw_cqe.write_target_kind = RDMA_HW_TARGET_NONE;
    end
    else begin
      completion.raw_cqe = null;
    end
    completion.decoded_response = null;
    validation_status = completion.validate();
    if (validation_status == null || !validation_status.ok())
      return null;
    return completion;
  endfunction

  // 功能：在 rdma_mock_cmq_port 中，fail_opcode 把错误消息、硬件码或注入故障封装为统一 rdma_status，保留原事务的诊断证据。
  // 输入/输出及副作用：opcode（输入）、status（输入）；fail_opcode 读取 opcode、status 并使用字段 outcome、outcome.kind、outcome.status；函数返回 void，不取得调用方资源所有权。
  // 失败/边界：fail_opcode 无返回值，仅执行 outcome=new("mock_cmq_failure_outcome")、outcome.kind=RDMA_MOCK_CMQ_COMPLETION、outcome.status=rdma_cmq_clone_status_value(status)；调用方须保证前置依赖已经绑定，函数不自动重试或接管外部资源。
  function void fail_opcode(bit [7:0] opcode, rdma_status status);
    rdma_mock_cmq_outcome outcome;

    outcome = new("mock_cmq_failure_outcome");
    outcome.kind = RDMA_MOCK_CMQ_COMPLETION;
    outcome.status = rdma_cmq_clone_status_value(status);
    outcomes[opcode].push_back(outcome);
  endfunction

  // 功能：在 rdma_mock_cmq_port 中，timeout_opcode 配置测试 fixture 的定向故障或替代依赖，使下一次调用覆盖指定边界路径。
  // 输入/输出及副作用：opcode（输入）；timeout_opcode 读取 opcode 并使用字段 outcome、outcome.kind、outcome.status；函数返回 void，不取得调用方资源所有权。
  // 失败/边界：timeout_opcode 无返回值，仅执行 outcome=new("mock_cmq_timeout_outcome")、outcome.kind=RDMA_MOCK_CMQ_TIMEOUT、outcome.status=null；调用方须保证前置依赖已经绑定，函数不自动重试或接管外部资源。
  function void timeout_opcode(bit [7:0] opcode);
    rdma_mock_cmq_outcome outcome;

    outcome = new("mock_cmq_timeout_outcome");
    outcome.kind = RDMA_MOCK_CMQ_TIMEOUT;
    outcome.status = null;
    outcomes[opcode].push_back(outcome);
  endfunction

  // Queue recovery tests can prescribe reconciliation independently of the
  // late-completion FIFO.  The script is keyed by the complete ticket
  // identity, so unrelated commands cannot consume its terminal evidence.
  // 功能：执行 script_reconcile 指定的测试或恢复状态变更，更新受控账本并保留可回滚的故障证据。
  // 输入/输出及副作用：ticket（输入）、terminal_known（输入）、completion（输入）、status（输入）；script_reconcile 读取 ticket、terminal_known、completion、status 并使用字段 key、script、script.terminal_known、script.status、cloned_object、completion_copy.ticket、script.completion；函数返回 void，不取得调用方资源所有权。
  // 失败/边界：script_reconcile 仅允许测试/恢复范围内的状态变更；代际或资源不匹配时拒绝并保留原账本。
  function void script_reconcile(
    rdma_cmq_ticket ticket,
    bit terminal_known,
    rdma_cmq_completion completion,
    rdma_status status
  );
    rdma_mock_cmq_reconcile_script script;
    uvm_object cloned_object;
    rdma_cmq_completion completion_copy;
    string key;

    if (ticket == null || ticket.function_h == null || ticket.cmq_h == null ||
        ticket.opcode_key == null)
      return;
    key = ticket_key(ticket);
    script = rdma_mock_cmq_reconcile_script::type_id::create(
      "mock_reconcile_script"
    );
    script.terminal_known = terminal_known;
    script.status = status == null ? rdma_status::success() :
                    rdma_cmq_clone_status_value(status);
    if (completion != null) begin
      cloned_object = completion.clone();
      if (cloned_object != null && $cast(completion_copy, cloned_object)) begin
        if (completion_copy.ticket == null)
          completion_copy.ticket = rdma_cmq_clone_ticket_value(
            ticket, "scripted reconcile ticket"
          );
        script.completion = completion_copy;
      end
    end
    reconcile_scripts[key].push_back(script);
  endfunction

  // Script a terminal QUERY result.  Response payload may be a
  // rdma_hw_cmq_completion payload or any other uvm_object; the policy
  // classifier decides whether the object is authentic evidence.
  // 功能：执行 script_query_context 指定的测试或恢复状态变更，更新受控账本并保留可回滚的故障证据。
  // 输入/输出及副作用：opcode（输入）、response_context（输入）、status（输入）；script_query_context 读取 opcode、response_context、status 并使用字段 outcome、outcome.kind、outcome.status、outcome.decoded_response；函数返回 void，不取得调用方资源所有权。
  // 失败/边界：script_query_context 仅允许测试/恢复范围内的状态变更；代际或资源不匹配时拒绝并保留原账本。
  function void script_query_context(
    bit [7:0] opcode,
    uvm_object response_context,
    rdma_status status
  );
    rdma_mock_cmq_outcome outcome;

    if (status == null)
      return;
    outcome = rdma_mock_cmq_outcome::type_id::create(
      "mock_query_outcome"
    );
    outcome.kind = RDMA_MOCK_CMQ_COMPLETION;
    outcome.status = rdma_cmq_clone_status_value(status);
    outcome.decoded_response = rdma_cmq_clone_object_value(
      response_context, "scripted query response"
    );
    outcomes[opcode].push_back(outcome);
  endfunction

  // 功能：在 rdma_mock_cmq_port 中，push_late_completion 将输入对象登记或挂接到当前集合/依赖图，并同步维护对应账本和生命周期引用。
  // 输入/输出及副作用：ticket（输入）、status（输入）；push_late_completion 可能更新本对象明确拥有的状态；函数返回 void，不取得调用方资源所有权。
  // 失败/边界：push_late_completion 无返回值，仅执行 validation_status=ticket.validate()、completion=make_completion(ticket, status, 1'b1)、key=ticket_key(ticket)；调用方须保证前置依赖已经绑定，函数不自动重试或接管外部资源。
  function void push_late_completion(
    rdma_cmq_ticket ticket,
    rdma_status status
  );
    rdma_cmq_completion completion;
    rdma_status validation_status;
    string key;

    if (ticket == null || status == null || !ticket_was_recorded(ticket))
      return;
    validation_status = ticket.validate();
    if (validation_status == null || !validation_status.ok())
      return;
    completion = make_completion(ticket, status, 1'b1);
    if (completion == null)
      return;
    key = ticket_key(ticket);
    late_completions[key].push_back(completion);
  endfunction

  // 功能：在 rdma_mock_cmq_port 中，get_opcodes 按完整 key/handle 查找唯一权威记录并返回 detached 快照，避免把内部可变引用泄露给调用方。
  // 输入/输出及副作用：values（输出）；get_opcodes 读取 values 并使用字段 calls、i，并写入 values；函数返回 void，不取得调用方资源所有权。
  // 失败/边界：get_opcodes 在 key/handle 缺失、记录不唯一或 generation/reset epoch 过期时返回明确错误，不回退到默认 authority。
  function void get_opcodes(output bit [7:0] values[$]);
    values.delete();
    foreach (calls[i]) begin
      if (calls[i] != null)
        values.push_back(calls[i].opcode);
    end
  endfunction

  // 功能：在 rdma_mock_cmq_port 中，execute 执行受控事务并按后端提交证据推进状态机，同时保留失败阶段和 generation 证据。
  // 输入/输出及副作用：command（输入）、ticket（输出）、completion（输出）、status（输出）；execute 驱动下游事务，并写入 ticket、completion、status；函数返回 无直接返回值，不取得调用方资源所有权。
  // 失败/边界：execute 遇到锁、超时、generation 变化或提交证据不完整时保持原状态，不推进游标。
  virtual task execute(
    rdma_cmq_command_desc command,
    output rdma_cmq_ticket ticket,
    output rdma_cmq_completion completion,
    output rdma_status status
  );
    rdma_status helper_status;
    rdma_status result_status;
    rdma_cmq_command_desc command_snapshot;
    rdma_mock_cmq_call call_record;
    rdma_mock_cmq_outcome outcome;
    rdma_status scripted_failure;
    bit [7:0] opcode;
    rdma_queue_backing_role_e role;
    int unsigned method_ordinal;
    int unsigned flush_ordinal;
    string method_name;

    last_execute_no_submit_proven = 1'b0;
    method_ordinals["legacy_execute"]++;
    ticket = null;
    completion = null;
    status = invalid_state("mock CMQ execute did not complete");
    if (gate_enabled && command != null && command.opcode_key != null &&
        command.opcode_key.opcode[7:0] == gated_opcode) begin
      gate_entered_count++;
      entered.trigger();
      release_gate.wait_on();
    end
    helper_status = snapshot_command(command, command_snapshot);
    if (helper_status == null || !helper_status.ok()) begin
      // No call record exists, so the mock can prove this was rejected before
      // submission.
      last_execute_no_submit_proven = 1'b1;
      status = (helper_status == null) ?
        invalid_state("mock CMQ command snapshot returned null status") :
        helper_status;
      return;
    end
    opcode = command_snapshot.opcode_key.opcode[7:0];
    if (call_trace != null)
      call_trace.record($sformatf("cmq:%02x", opcode));
    helper_status = make_ticket(command_snapshot, next_sequence, ticket);
    if (helper_status == null || !helper_status.ok() || ticket == null) begin
      // Ticket construction precedes call publication in this adapter.
      last_execute_no_submit_proven = 1'b1;
      status = (helper_status == null) ?
        invalid_state("mock CMQ ticket helper returned null status") :
        helper_status;
      ticket = null;
      return;
    end
    call_record = new($sformatf("mock_cmq_call_%0d", next_sequence));
    call_record.\sequence  = next_sequence;
    call_record.opcode = opcode;
    call_record.command = command_snapshot;
    call_record.ticket = rdma_cmq_clone_ticket_value(ticket,
                                                     "mock CMQ call");
    if (call_record.ticket == null) begin
      last_execute_no_submit_proven = 1'b1;
      ticket = null;
      status = invalid_state("mock CMQ call ticket snapshot failed");
      return;
    end
    calls.push_back(call_record);
    next_sequence++;

    scripted_failure = null;
    method_name = "";
    method_ordinal = 0;
    flush_ordinal = 0;
    if (opcode inside {RDMA_OP_CQC_CREATE, RDMA_OP_SRFQC_CREATE,
                       RDMA_OP_CEQC_CREATE, RDMA_OP_AEQC_CREATE}) begin
      method_name = "create_terminal";
      method_ordinals[method_name]++;
      method_ordinal = method_ordinals[method_name];
      role = execute_role(opcode, 0);
      scripted_failure = take_role_failure(method_name, role, method_ordinal);
      if (scripted_failure == null)
        scripted_failure = take_role_failure("create_submit", role,
                                             method_ordinal);
    end
    else if (opcode inside {RDMA_OP_CQC_DELETE, RDMA_OP_SRFQC_DELETE,
                            RDMA_OP_CEQC_DELETE, RDMA_OP_AEQC_DELETE}) begin
      method_name = "delete";
      method_ordinals[method_name]++;
      method_ordinal = method_ordinals[method_name];
      role = execute_role(opcode, 0);
      scripted_failure = take_role_failure(method_name, role, method_ordinal);
    end
    else if (opcode inside {RDMA_OP_CQC_QUERY, RDMA_OP_SRFQC_QUERY,
                            RDMA_OP_CEQC_QUERY, RDMA_OP_AEQC_QUERY}) begin
      method_name = "query";
      method_ordinals[method_name]++;
      method_ordinal = method_ordinals[method_name];
      role = execute_role(opcode, 0);
      scripted_failure = take_role_failure(method_name, role, method_ordinal);
    end
    else if (opcode == RDMA_OP_OCC_FLUSH) begin
      method_name = "flush";
      method_ordinals[method_name]++;
      flush_ordinal = method_ordinals[method_name];
      role = execute_role(opcode, flush_ordinal);
      scripted_failure = take_role_failure(
        {"pre_flush_", $sformatf("%0d", flush_ordinal - 1)}, role,
        flush_ordinal);
      if (scripted_failure == null)
        scripted_failure = take_role_failure(
          {"post_flush_", $sformatf("%0d", flush_ordinal - 1)}, role,
          flush_ordinal);
      if (scripted_failure == null)
        scripted_failure = take_role_failure("flush", role, flush_ordinal);
    end

    outcome = null;
    if (scripted_failure != null) begin
      outcome = new("mock_role_failure_outcome");
      outcome.kind = RDMA_MOCK_CMQ_COMPLETION;
      outcome.status = scripted_failure;
    end
    else if (outcomes.exists(opcode) && outcomes[opcode].size() != 0)
      outcome = outcomes[opcode].pop_front();
    if (outcome != null && outcome.kind == RDMA_MOCK_CMQ_TIMEOUT) begin
      result_status = rdma_status::make(RDMA_SC_TIMEOUT,
                                        "mock CMQ command timed out");
      completion = make_completion(ticket, result_status, 1'b0);
    end
    else begin
      result_status = (outcome == null) ? rdma_status::success() :
                      rdma_cmq_clone_status_value(outcome.status);
      completion = make_completion(ticket, result_status, 1'b1);
      if (completion != null && outcome != null &&
          outcome.decoded_response != null)
        completion.decoded_response = rdma_cmq_clone_object_value(
          outcome.decoded_response, "mock scripted query response"
        );
    end
    if (result_status == null || completion == null ||
        completion.status == null) begin
      completion = null;
      status = invalid_state("mock CMQ outcome is incomplete");
      return;
    end
    status = rdma_cmq_clone_status_value(completion.status);
    if (status == null) begin
      completion = null;
      status = invalid_state("mock CMQ final status copy failed");
    end
  endtask

  // 功能：在 legacy-only mock 中记录 observed fallback 的一次调用并委托基类
  //   wrapper，验证 base 方向为 observed→legacy 且不会递归回 observed。
  // 输入/输出及副作用：command 为非拥有输入，result 为 detached 输出；更新
  //   method_ordinals 计数并调用一次 super.execute_observed。
  // 失败/边界：基类快照失败仍按其 observation_status 返回；本 mock 不伪造
  //   ticket/effect，也不写 production adapter 的 shared seam。
  virtual task execute_observed(
    input rdma_cmq_command_desc command,
    output rdma_cmq_execution_result result
  );
    method_ordinals["observed_execute"]++;
    super.execute_observed(command, result);
  endtask

  // 功能：在 rdma_mock_cmq_port 中，reconcile 执行受控事务并按后端提交证据推进状态机，同时保留失败阶段和 generation 证据。
  // 输入/输出及副作用：ticket（输入）、terminal_known（输出）、completion（输出）、status（输出）；输入 action/epoch/handle
  //   决定迁移目标；成功时更新状态或恢复证据，外部资源仍由其拥有者管理。
  // 失败/边界：reconcile 遇到锁、超时、generation 变化或提交证据不完整时保持原状态，不推进游标。
  virtual task reconcile(
    rdma_cmq_ticket ticket,
    output bit terminal_known,
    output rdma_cmq_completion completion,
    output rdma_status status
  );
    rdma_status validation_status;
    rdma_mock_cmq_reconcile_script script;
    uvm_object cloned_object;
    rdma_cmq_completion completion_copy;
    string key;

    terminal_known = 1'b0;
    completion = null;
    status = invalid_state("mock CMQ reconcile did not complete");
    if (ticket == null || !ticket_was_recorded(ticket)) begin
      status = invalid_argument("mock CMQ reconcile ticket is unknown");
      return;
    end
    validation_status = ticket.validate();
    if (validation_status == null || !validation_status.ok()) begin
      status = invalid_argument("mock CMQ reconcile ticket is invalid");
      return;
    end
    key = ticket_key(ticket);
    if (reconcile_scripts.exists(key) &&
        reconcile_scripts[key].size() != 0) begin
      script = reconcile_scripts[key].pop_front();
      if (script == null) begin
        status = invalid_state("mock reconcile script is null");
        return;
      end
      terminal_known = script.terminal_known;
      status = script.status == null ? rdma_status::success() :
               rdma_cmq_clone_status_value(script.status);
      if (script.completion != null) begin
        cloned_object = script.completion.clone();
        if (cloned_object == null || !$cast(completion_copy, cloned_object)) begin
          completion = null;
          status = invalid_state("mock reconcile script completion clone failed");
          return;
        end
        if (completion_copy.ticket == null)
          completion_copy.ticket = rdma_cmq_clone_ticket_value(
            ticket, "mock scripted reconcile ticket"
          );
        completion = completion_copy;
      end
      return;
    end
    if (!late_completions.exists(key) || late_completions[key].size() == 0) begin
      status = rdma_status::success();
      return;
    end
    completion = late_completions[key].pop_front();
    if (completion == null || completion.status == null) begin
      completion = null;
      status = invalid_state("mock CMQ late completion is incomplete");
      return;
    end
    status = rdma_cmq_clone_status_value(completion.status);
    if (status == null) begin
      completion = null;
      status = invalid_state("mock CMQ reconcile status copy failed");
      return;
    end
    terminal_known = 1'b1;
  endtask
endclass
