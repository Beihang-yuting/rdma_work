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

  // 功能：构造当前对象并初始化其字段、集合和 UVM 名称；不接管传入句柄的生命周期。
  // 输入/输出及副作用：name 仅用于 UVM 对象命名；内部字段被初始化为安全默认值，传入句柄不转移所有权。
  //   返回新对象实例；构造失败由 UVM 工厂或调用方处理。
  // 失败/边界：不创建外部资源；name 为空时仍允许构造，但所有字段必须保持可配置的初始值。
  function new(string name = "rdma_mock_stag_key_policy");
    super.new(name);
    fixed_key = '0;
    call_count = 0;
    next_failure = null;
  endfunction

  // 功能：把输入错误或注入故障转换成统一的 rdma_status，供上层沿原事务路径处理。
  // 输入/输出及副作用：输入为错误消息、错误码或故障证据；返回统一 rdma_status，不推进事务游标。
  //   空消息仍需保留错误类别；未知错误码不得被静默转换为成功。
  // 失败/边界：错误路径不能返回成功状态；消息和错误码缺失时仍须保留可诊断类别。
  function rdma_status fail_next(rdma_status failure);
    if (failure == null)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "STAG key failure status is null");
    next_failure = rdma_cmq_clone_status_value(failure);
    return rdma_status::success();
  endfunction

  // 功能：处理 derive：依据其参数完成所属层的具体协议动作，并保持返回状态、游标和资源所有权一致。
  // 输入/输出及副作用：参数 mr, stag_key 用于执行 derive；返回值或 output/inout 交付处理结果，必要时更新本对象状态。
  //   调用方不获得内部集合或外部依赖的所有权。
  // 失败/边界：derive 只接受其签名声明的输入；缺少必要字段时返回错误，成功路径不得隐式修改无关资源。
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

  // 功能：构造当前对象并初始化其字段、集合和 UVM 名称；不接管传入句柄的生命周期。
  // 输入/输出及副作用：name 仅用于 UVM 对象命名；内部字段被初始化为安全默认值，传入句柄不转移所有权。
  //   返回新对象实例；构造失败由 UVM 工厂或调用方处理。
  // 失败/边界：不创建外部资源；name 为空时仍允许构造，但所有字段必须保持可配置的初始值。
  function new(string name = "rdma_fault_inject_resource_manager");
    super.new(name);
    release_reserved_calls = 0;
    transition_failures.delete();
    role_failures.delete(); transition_ordinals.delete();
  endfunction

  // 功能：把输入错误或注入故障转换成统一的 rdma_status，供上层沿原事务路径处理。
  // 输入/输出及副作用：输入为错误消息、错误码或故障证据；返回统一 rdma_status，不推进事务游标。
  //   空消息仍需保留错误类别；未知错误码不得被静默转换为成功。
  // 失败/边界：错误路径不能返回成功状态；消息和错误码缺失时仍须保留可诊断类别。
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

  // 功能：把输入错误或注入故障转换成统一的 rdma_status，供上层沿原事务路径处理。
  // 输入/输出及副作用：输入为错误消息、错误码或故障证据；返回统一 rdma_status，不推进事务游标。
  //   空消息仍需保留错误类别；未知错误码不得被静默转换为成功。
  // 失败/边界：错误路径不能返回成功状态；消息和错误码缺失时仍须保留可诊断类别。
  function void fail_role_call(string method_name,
                               rdma_queue_backing_role_e role,
                               int unsigned ordinal,
                               rdma_status failure);
    if (failure != null && ordinal != 0)
      role_failures[$sformatf("%s:%0d:%0d", method_name, role, ordinal)] =
        rdma_cmq_clone_status_value(failure);
  endfunction

  // 功能：清理当前运行状态并建立新的复位/代际边界，使旧句柄或旧事务不能继续生效。
  // 输入/输出及副作用：参数 delete 用于执行 reset；返回值或 output/inout 交付处理结果，必要时更新本对象状态。
  //   调用方不获得内部集合或外部依赖的所有权。
  // 失败/边界：复位参数为零、代际回退或存在未处理 pending 事务时拒绝更新 authority。
  function void reset();
    transition_failures.delete(); role_failures.delete();
    transition_ordinals.delete(); release_reserved_calls = 0;
  endfunction

  // 功能：处理 stage_allocated：依据其参数完成所属层的具体协议动作，并保持返回状态、游标和资源所有权一致。
  // 输入/输出及副作用：参数 failure 用于执行 stage_allocated；返回值或 output/inout 交付处理结果，必要时更新本对象状态。
  //   调用方不获得内部集合或外部依赖的所有权。
  // 失败/边界：stage_allocated 只接受其签名声明的输入；缺少必要字段时返回错误，成功路径不得隐式修改无关资源。
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
  // 输入/输出及副作用：参数 transition_name, role 用于执行 take_transition_failure；返回值或 output/inout 交付处理结果，必要时更新本对象状态。
  //   调用方不获得内部集合或外部依赖的所有权。
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

  // 功能：处理 queue_role_for_kind：依据其参数完成所属层的具体协议动作，并保持返回状态、游标和资源所有权一致。
  // 输入/输出及副作用：参数 kind 用于执行 queue_role_for_kind；返回值或 output/inout 交付处理结果，必要时更新本对象状态。
  //   调用方不获得内部集合或外部依赖的所有权。
  // 失败/边界：queue_role_for_kind 只接受其签名声明的输入；缺少必要字段时返回错误，成功路径不得隐式修改无关资源。
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

  // 功能：执行一次受控事务并推进所属状态机；返回结果时保留失败阶段、代际和后端提交证据。
  // 输入/输出及副作用：参数 failure 用于执行 commit_programmed；返回值或 output/inout 交付处理结果，必要时更新本对象状态。
  //   调用方不获得内部集合或外部依赖的所有权。
  // 失败/边界：事务超时、代际变化或提交证据不完整时不得推进下一阶段。
  virtual function rdma_status commit_programmed(rdma_resource candidate);
    rdma_status failure;

    failure = take_transition_failure("commit_programmed",
      queue_role_for_kind(candidate == null ? RDMA_RESOURCE_CQ :
                          candidate.resource_kind()));
    if (failure != null)
      return failure;
    return super.commit_programmed(candidate);
  endfunction

  // 功能：校验依赖并建立该对象的运行边界，成功后保存必要的非拥有引用；拒绝不完整或重复配置。
  // 输入/输出及副作用：接收 manager、binding、router 或 profile 等依赖；成功后保存非拥有引用并更新配置状态。
  //   任一依赖为空、重复配置或代际不匹配时保持原状态并返回错误。
  // 失败/边界：配置失败不得写入半成品引用；已激活对象不得被无条件降级或重复占用资源。
  virtual function rdma_status activate(rdma_handle handle);
    rdma_status failure;

    failure = take_transition_failure("activate", queue_role_for_kind(
      handle == null ? RDMA_RESOURCE_CQ : handle.kind));
    if (failure != null)
      return failure;
    return super.activate(handle);
  endfunction

  // 功能：按资源所有权和幂等规则释放或清理记录；重复释放不会再次扣减 credit，也不触碰已隔离资源。
  // 输入/输出及副作用：输入为待解除或释放的 handle/key；成功后隔离或删除本对象记录，外部拥有者仍负责真正销毁。
  //   空值、未知记录或重复调用按接口约定返回错误或幂等成功。
  // 失败/边界：不得释放非本对象所有资源；重复解除按幂等约定处理，旧 handle 不得重新激活。
  virtual function rdma_status release_reserved(rdma_handle handle);
    rdma_status failure;

    release_reserved_calls++;
    failure = take_transition_failure("release_reserved", queue_role_for_kind(
      handle == null ? RDMA_RESOURCE_CQ : handle.kind));
    if (failure != null)
      return failure;
    return super.release_reserved(handle);
  endfunction

  // 功能：执行 mark_error 指定的测试或恢复状态变更，更新受控账本并保留可回滚的故障证据。
  // 输入/输出及副作用：参数 handle, recovery 用于执行 mark_error；返回值或 output/inout 交付处理结果，必要时更新本对象状态。
  //   调用方不获得内部集合或外部依赖的所有权。
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

  // 功能：处理 complete_reserved_error：依据其参数完成所属层的具体协议动作，并保持返回状态、游标和资源所有权一致。
  // 输入/输出及副作用：参数 handle 用于执行 complete_reserved_error；返回值或 output/inout 交付处理结果，必要时更新本对象状态。
  //   调用方不获得内部集合或外部依赖的所有权。
  // 失败/边界：complete_reserved_error 只接受其签名声明的输入；缺少必要字段时返回错误，成功路径不得隐式修改无关资源。
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

  // 功能：记录本次调用的名称和顺序，供测试断言转发路径；不改变被测事务的业务结果。
  // 输入/输出及副作用：输入为调用名称、事件或 trace 数据；成功后追加测试可见记录，不改变业务资源。
  //   空名称或记录容量边界按测试替身约定处理，不影响被测对象。
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

  // 功能：记录本次调用的名称和顺序，供测试断言转发路径；不改变被测事务的业务结果。
  // 输入/输出及副作用：输入为调用名称、事件或 trace 数据；成功后追加测试可见记录，不改变业务资源。
  //   空名称或记录容量边界按测试替身约定处理，不影响被测对象。
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

  // 功能：构造当前对象并初始化其字段、集合和 UVM 名称；不接管传入句柄的生命周期。
  // 输入/输出及副作用：name 仅用于 UVM 对象命名；内部字段被初始化为安全默认值，传入句柄不转移所有权。
  //   返回新对象实例；构造失败由 UVM 工厂或调用方处理。
  // 失败/边界：不创建外部资源；name 为空时仍允许构造，但所有字段必须保持可配置的初始值。
  function new(string name = "rdma_mock_cmq_call");
    super.new(name);
    \sequence  = 0;
    opcode = '0;
    command = null;
    ticket = null;
  endfunction

  // 功能：从源对象复制可变字段并生成独立值快照；源对象保持不变，类型不匹配时报告复制错误。
  // 输入/输出及副作用：source/rhs 是源对象；返回或写入独立副本，不修改源对象。
  //   source/rhs 为空或类型不匹配时返回空值或触发既定复制错误。
  // 失败/边界：空源对象不应解引用；类型不匹配必须拒绝复制或按既定 UVM 规则报告 fatal。
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

  // 功能：构造当前对象并初始化其字段、集合和 UVM 名称；不接管传入句柄的生命周期。
  // 输入/输出及副作用：name 仅用于 UVM 对象命名；内部字段被初始化为安全默认值，传入句柄不转移所有权。
  //   返回新对象实例；构造失败由 UVM 工厂或调用方处理。
  // 失败/边界：不创建外部资源；name 为空时仍允许构造，但所有字段必须保持可配置的初始值。
  function new(string name = "rdma_mock_cmq_snapshot_engine");
    super.new(name);
    profile = rdma_xtr_v1_cmq_hw_profile::type_id::create(
      {name, "_profile"}
    );
  endfunction

  // 功能：按输入的完整标识查询当前权威记录并返回独立快照；缺失、歧义或代际过期时返回明确错误。
  // 输入/输出及副作用：输入为完整 key/handle，output 或返回值为记录快照；查询不改变登记表和外部资源。
  //   缺失、歧义、空句柄或旧 generation/reset epoch 返回明确错误。
  // 失败/边界：查询不到唯一记录、输入为空或 authority 已失效时返回错误，不回退到默认 Function/root。
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

  // 功能：构造当前对象并初始化其字段、集合和 UVM 名称；不接管传入句柄的生命周期。
  // 输入/输出及副作用：name 仅用于 UVM 对象命名；内部字段被初始化为安全默认值，传入句柄不转移所有权。
  //   返回新对象实例；构造失败由 UVM 工厂或调用方处理。
  // 失败/边界：不创建外部资源；name 为空时仍允许构造，但所有字段必须保持可配置的初始值。
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

  // 功能：构造当前对象并初始化其字段、集合和 UVM 名称；不接管传入句柄的生命周期。
  // 输入/输出及副作用：name 仅用于 UVM 对象命名；内部字段被初始化为安全默认值，传入句柄不转移所有权。
  //   返回新对象实例；构造失败由 UVM 工厂或调用方处理。
  // 失败/边界：不创建外部资源；name 为空时仍允许构造，但所有字段必须保持可配置的初始值。
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
  // Evidence is scoped to the most recent execute() call.  It is asserted
  // only on mock adapter paths that return before recording a CMQ call.
  protected bit last_execute_no_submit_proven;
  protected rdma_status role_failures[string];
  protected int unsigned method_ordinals[string];

  // 功能：构造当前对象并初始化其字段、集合和 UVM 名称；不接管传入句柄的生命周期。
  // 输入/输出及副作用：name 仅用于 UVM 对象命名；内部字段被初始化为安全默认值，传入句柄不转移所有权。
  //   返回新对象实例；构造失败由 UVM 工厂或调用方处理。
  // 失败/边界：不创建外部资源；name 为空时仍允许构造，但所有字段必须保持可配置的初始值。
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

  // 功能：处理 last_execute_definitive_no_submit：依据其参数完成所属层的具体协议动作，并保持返回状态、游标和资源所有权一致。
  // 输入/输出及副作用：参数 last_execute_no_submit_proven 用于执行 last_execute_definitive_no_submit；返回值或 output/inout 交付处理结果，必要时更新本对象状态。
  //   调用方不获得内部集合或外部依赖的所有权。
  // 失败/边界：last_execute_definitive_no_submit 只接受其签名声明的输入；缺少必要字段时返回错误，成功路径不得隐式修改无关资源。
  virtual function bit last_execute_definitive_no_submit();
    return last_execute_no_submit_proven;
  endfunction

  // 功能：记录本次调用的名称和顺序，供测试断言转发路径；不改变被测事务的业务结果。
  // 输入/输出及副作用：输入为调用名称、事件或 trace 数据；成功后追加测试可见记录，不改变业务资源。
  //   空名称或记录容量边界按测试替身约定处理，不影响被测对象。
  // 失败/边界：记录操作仅影响测试 trace；不得因注入记录故障改变生产状态或吞掉真实错误。
  function void set_call_trace(rdma_mock_call_trace trace);
    call_trace = trace;
  endfunction

  // 功能：处理 gate_opcode：依据其参数完成所属层的具体协议动作，并保持返回状态、游标和资源所有权一致。
  // 输入/输出及副作用：参数 opcode 用于执行 gate_opcode；返回值或 output/inout 交付处理结果，必要时更新本对象状态。
  //   调用方不获得内部集合或外部依赖的所有权。
  // 失败/边界：gate_opcode 只接受其签名声明的输入；缺少必要字段时返回错误，成功路径不得隐式修改无关资源。
  function void gate_opcode(bit [7:0] opcode);
    gate_opcode_count(opcode, 1);
  endfunction

  // Lifecycle-test naming for the CMQ pause barrier.  The gate only waits on
  // the selected opcode and does not hold any adapter mutex, so other
  // Functions may continue to enter execute().
  // 功能：处理 pause_cmq_opcode：依据其参数完成所属层的具体协议动作，并保持返回状态、游标和资源所有权一致。
  // 输入/输出及副作用：参数 opcode 用于执行 pause_cmq_opcode；返回值或 output/inout 交付处理结果，必要时更新本对象状态。
  //   调用方不获得内部集合或外部依赖的所有权。
  // 失败/边界：pause_cmq_opcode 只接受其签名声明的输入；缺少必要字段时返回错误，成功路径不得隐式修改无关资源。
  task pause_cmq_opcode(bit [7:0] opcode);
    gate_opcode(opcode);
  endtask

  // 功能：控制 wait_until_paused 对应的等待、异常或同步边界，按超时/捕获结果返回状态，不吞掉原始错误。
  // 输入/输出及副作用：参数 observed 用于执行 wait_until_paused；返回值或 output/inout 交付处理结果，必要时更新本对象状态。
  //   调用方不获得内部集合或外部依赖的所有权。
  // 失败/边界：wait_until_paused 超时或异常必须返回原始错误证据；不得无限等待或跳过同步边界。
  task wait_until_paused(bit [7:0] opcode);
    bit observed;
    while (!gate_enabled || gated_opcode != opcode || gate_entered_count == 0)
      #1;
    observed = 1'b1;
  endtask

  // 功能：按资源所有权和幂等规则释放或清理记录；重复释放不会再次扣减 credit，也不触碰已隔离资源。
  // 输入/输出及副作用：输入为待解除或释放的 handle/key；成功后隔离或删除本对象记录，外部拥有者仍负责真正销毁。
  //   空值、未知记录或重复调用按接口约定返回错误或幂等成功。
  // 失败/边界：不得释放非本对象所有资源；重复解除按幂等约定处理，旧 handle 不得重新激活。
  function void release_cmq_opcode(bit [7:0] opcode);
    if (gate_enabled && gated_opcode == opcode)
      release_one();
  endfunction

  // 功能：把输入错误或注入故障转换成统一的 rdma_status，供上层沿原事务路径处理。
  // 输入/输出及副作用：输入为错误消息、错误码或故障证据；返回统一 rdma_status，不推进事务游标。
  //   空消息仍需保留错误类别；未知错误码不得被静默转换为成功。
  // 失败/边界：错误路径不能返回成功状态；消息和错误码缺失时仍须保留可诊断类别。
  function void fail_role_call(string method_name,
                               rdma_queue_backing_role_e role,
                               int unsigned ordinal,
                               rdma_status status);
    if (status != null && ordinal != 0) begin
      role_failures[$sformatf("%s:%0d:%0d", method_name, role, ordinal)] =
        rdma_cmq_clone_status_value(status);
    end
  endfunction

  // 功能：清理当前运行状态并建立新的复位/代际边界，使旧句柄或旧事务不能继续生效。
  // 输入/输出及副作用：参数 delete 用于执行 reset；返回值或 output/inout 交付处理结果，必要时更新本对象状态。
  //   调用方不获得内部集合或外部依赖的所有权。
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
  // 功能：处理 gate_opcode_count：依据其参数完成所属层的具体协议动作，并保持返回状态、游标和资源所有权一致。
  // 输入/输出及副作用：参数 opcode, gated_opcode 用于执行 gate_opcode_count；返回值或 output/inout 交付处理结果，必要时更新本对象状态。
  //   调用方不获得内部集合或外部依赖的所有权。
  // 失败/边界：gate_opcode_count 只接受其签名声明的输入；缺少必要字段时返回错误，成功路径不得隐式修改无关资源。
  function void gate_opcode_count(bit [7:0] opcode, int unsigned count);
    gated_opcode = opcode;
    gate_enabled = 1'b1;
    gate_target_count = (count == 0) ? 1 : count;
    gate_entered_count = 0;
    release_gate.reset();
    entered.reset();
  endfunction

  // 功能：控制 wait_until_entered 对应的等待、异常或同步边界，按超时/捕获结果返回状态，不吞掉原始错误。
  // 输入/输出及副作用：参数 expected_count, timeout, observed 用于执行 wait_until_entered；返回值或 output/inout 交付处理结果，必要时更新本对象状态。
  //   调用方不获得内部集合或外部依赖的所有权。
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

  // 功能：按资源所有权和幂等规则释放或清理记录；重复释放不会再次扣减 credit，也不触碰已隔离资源。
  // 输入/输出及副作用：输入为待解除或释放的 handle/key；成功后隔离或删除本对象记录，外部拥有者仍负责真正销毁。
  //   空值、未知记录或重复调用按接口约定返回错误或幂等成功。
  // 失败/边界：不得释放非本对象所有资源；重复解除按幂等约定处理，旧 handle 不得重新激活。
  task release_one();
    gate_enabled = 1'b0;
    release_gate.trigger();
  endtask

  // 功能：把输入错误或注入故障转换成统一的 rdma_status，供上层沿原事务路径处理。
  // 输入/输出及副作用：输入为错误消息、错误码或故障证据；返回统一 rdma_status，不推进事务游标。
  //   空消息仍需保留错误类别；未知错误码不得被静默转换为成功。
  // 失败/边界：错误路径不能返回成功状态；消息和错误码缺失时仍须保留可诊断类别。
  protected function rdma_status invalid_argument(string message);
    return rdma_status::make(RDMA_SC_INVALID_ARGUMENT, message);
  endfunction

  // 功能：把输入错误或注入故障转换成统一的 rdma_status，供上层沿原事务路径处理。
  // 输入/输出及副作用：输入为错误消息、错误码或故障证据；返回统一 rdma_status，不推进事务游标。
  //   空消息仍需保留错误类别；未知错误码不得被静默转换为成功。
  // 失败/边界：错误路径不能返回成功状态；消息和错误码缺失时仍须保留可诊断类别。
  protected function rdma_status invalid_state(string message);
    return rdma_status::make(RDMA_SC_INVALID_STATE, message);
  endfunction

  // 功能：执行一次受控事务并推进所属状态机；返回结果时保留失败阶段、代际和后端提交证据。
  // 输入/输出及副作用：参数 opcode, flush_ordinal 用于执行 execute_role；返回值或 output/inout 交付处理结果，必要时更新本对象状态。
  //   调用方不获得内部集合或外部依赖的所有权。
  // 失败/边界：事务超时、代际变化或提交证据不完整时不得推进下一阶段。
  protected function rdma_queue_backing_role_e execute_role(
    bit [7:0] opcode,
    int unsigned flush_ordinal
  );
    string key;

    case (opcode)
      XTR_V1_OP_CQC_CREATE, XTR_V1_OP_CQC_DELETE,
      XTR_V1_OP_CQC_QUERY: return RDMA_QUEUE_ROLE_CQ_RING;
      XTR_V1_OP_SRFQC_CREATE, XTR_V1_OP_SRFQC_DELETE,
      XTR_V1_OP_SRFQC_QUERY: return RDMA_QUEUE_ROLE_SRQ_RING;
      XTR_V1_OP_CEQC_CREATE, XTR_V1_OP_CEQC_DELETE,
      XTR_V1_OP_CEQC_QUERY: return RDMA_QUEUE_ROLE_CEQ_RING;
      XTR_V1_OP_AEQC_CREATE, XTR_V1_OP_AEQC_DELETE,
      XTR_V1_OP_AEQC_QUERY: return RDMA_QUEUE_ROLE_AEQ_RING;
      XTR_V1_OP_OCC_FLUSH: begin
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

  // 功能：执行 take_role_failure 指定的测试或恢复状态变更，更新受控账本并保留可回滚的故障证据。
  // 输入/输出及副作用：参数 method_name, role, ordinal 用于执行 take_role_failure；返回值或 output/inout 交付处理结果，必要时更新本对象状态。
  //   调用方不获得内部集合或外部依赖的所有权。
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

  // 功能：比较两个输入对象的协议字段或身份快照并返回确定的相等性结果，不修改任一输入。
  // 输入/输出及副作用：输入为待比较的两个值对象；返回 bit/状态结果，不修改任一输入或外部账本。
  //   任一对象为空、类型不符或字段未初始化时按接口约定返回不相等或错误。
  // 失败/边界：比较输入为空或类型不符时不得抛出未处理异常；结果必须保持确定且无副作用。
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

  // 功能：处理 ticket_key：依据其参数完成所属层的具体协议动作，并保持返回状态、游标和资源所有权一致。
  // 输入/输出及副作用：参数 sq_wrap 用于执行 ticket_key；返回值或 output/inout 交付处理结果，必要时更新本对象状态。
  //   调用方不获得内部集合或外部依赖的所有权。
  // 失败/边界：ticket_key 只接受其签名声明的输入；缺少必要字段时返回错误，成功路径不得隐式修改无关资源。
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

  // 功能：处理 ticket_was_recorded：依据其参数完成所属层的具体协议动作，并保持返回状态、游标和资源所有权一致。
  // 输入/输出及副作用：参数 begi 用于执行 ticket_was_recorded；返回值或 output/inout 交付处理结果，必要时更新本对象状态。
  //   调用方不获得内部集合或外部依赖的所有权。
  // 失败/边界：ticket_was_recorded 只接受其签名声明的输入；缺少必要字段时返回错误，成功路径不得隐式修改无关资源。
  protected function bit ticket_was_recorded(rdma_cmq_ticket ticket);
    foreach (calls[i]) begin
      if (calls[i] != null && same_ticket(calls[i].ticket, ticket))
        return 1'b1;
    end
    return 1'b0;
  endfunction

  // 功能：按输入的完整标识查询当前权威记录并返回独立快照；缺失、歧义或代际过期时返回明确错误。
  // 输入/输出及副作用：输入为完整 key/handle，output 或返回值为记录快照；查询不改变登记表和外部资源。
  //   缺失、歧义、空句柄或旧 generation/reset epoch 返回明确错误。
  // 失败/边界：查询不到唯一记录、输入为空或 authority 已失效时返回错误，不回退到默认 Function/root。
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

  // 功能：依据输入请求创建对应的值对象或资源计划，并校验依赖、所有权和生命周期后返回结果。
  // 输入/输出及副作用：输入请求、容量和依赖用于构造/预留资源；返回独立对象或状态，不暴露内部可变集合。
  //   参数越界、容量不足或构造中途失败时回滚已登记的局部状态。
  // 失败/边界：依赖为空、参数越界、容量不足或构造步骤失败时清理局部结果并返回明确错误。
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

  // 功能：依据输入请求创建对应的值对象或资源计划，并校验依赖、所有权和生命周期后返回结果。
  // 输入/输出及副作用：输入请求、容量和依赖用于构造/预留资源；返回独立对象或状态，不暴露内部可变集合。
  //   参数越界、容量不足或构造中途失败时回滚已登记的局部状态。
  // 失败/边界：依赖为空、参数越界、容量不足或构造步骤失败时清理局部结果并返回明确错误。
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

  // 功能：把输入错误或注入故障转换成统一的 rdma_status，供上层沿原事务路径处理。
  // 输入/输出及副作用：输入为错误消息、错误码或故障证据；返回统一 rdma_status，不推进事务游标。
  //   空消息仍需保留错误类别；未知错误码不得被静默转换为成功。
  // 失败/边界：错误路径不能返回成功状态；消息和错误码缺失时仍须保留可诊断类别。
  function void fail_opcode(bit [7:0] opcode, rdma_status status);
    rdma_mock_cmq_outcome outcome;

    outcome = new("mock_cmq_failure_outcome");
    outcome.kind = RDMA_MOCK_CMQ_COMPLETION;
    outcome.status = rdma_cmq_clone_status_value(status);
    outcomes[opcode].push_back(outcome);
  endfunction

  // 功能：处理 timeout_opcode：依据其参数完成所属层的具体协议动作，并保持返回状态、游标和资源所有权一致。
  // 输入/输出及副作用：参数 outcome 用于执行 timeout_opcode；返回值或 output/inout 交付处理结果，必要时更新本对象状态。
  //   调用方不获得内部集合或外部依赖的所有权。
  // 失败/边界：timeout_opcode 只接受其签名声明的输入；缺少必要字段时返回错误，成功路径不得隐式修改无关资源。
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
  // 输入/输出及副作用：参数 ticket, terminal_known, completion, status 用于执行 script_reconcile；返回值或 output/inout 交付处理结果，必要时更新本对象状态。
  //   调用方不获得内部集合或外部依赖的所有权。
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
  // rdma_xtr_v1_cmq_completion payload or any other uvm_object; the policy
  // classifier decides whether the object is authentic evidence.
  // 功能：执行 script_query_context 指定的测试或恢复状态变更，更新受控账本并保留可回滚的故障证据。
  // 输入/输出及副作用：参数 opcode, response_context, status 用于执行 script_query_context；返回值或 output/inout 交付处理结果，必要时更新本对象状态。
  //   调用方不获得内部集合或外部依赖的所有权。
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

  // 功能：处理 push_late_completion：依据其参数完成所属层的具体协议动作，并保持返回状态、游标和资源所有权一致。
  // 输入/输出及副作用：参数 ticket, status 用于执行 push_late_completion；返回值或 output/inout 交付处理结果，必要时更新本对象状态。
  //   调用方不获得内部集合或外部依赖的所有权。
  // 失败/边界：push_late_completion 只接受其签名声明的输入；缺少必要字段时返回错误，成功路径不得隐式修改无关资源。
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

  // 功能：按输入的完整标识查询当前权威记录并返回独立快照；缺失、歧义或代际过期时返回明确错误。
  // 输入/输出及副作用：输入为完整 key/handle，output 或返回值为记录快照；查询不改变登记表和外部资源。
  //   缺失、歧义、空句柄或旧 generation/reset epoch 返回明确错误。
  // 失败/边界：查询不到唯一记录、输入为空或 authority 已失效时返回错误，不回退到默认 Function/root。
  function void get_opcodes(output bit [7:0] values[$]);
    values.delete();
    foreach (calls[i]) begin
      if (calls[i] != null)
        values.push_back(calls[i].opcode);
    end
  endfunction

  // 功能：执行一次受控事务并推进所属状态机；返回结果时保留失败阶段、代际和后端提交证据。
  // 输入/输出及副作用：参数 command, ticket, completion, status 用于执行 execute；返回值或 output/inout 交付处理结果，必要时更新本对象状态。
  //   调用方不获得内部集合或外部依赖的所有权。
  // 失败/边界：事务超时、代际变化或提交证据不完整时不得推进下一阶段。
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
    if (opcode inside {XTR_V1_OP_CQC_CREATE, XTR_V1_OP_SRFQC_CREATE,
                       XTR_V1_OP_CEQC_CREATE, XTR_V1_OP_AEQC_CREATE}) begin
      method_name = "create_terminal";
      method_ordinals[method_name]++;
      method_ordinal = method_ordinals[method_name];
      role = execute_role(opcode, 0);
      scripted_failure = take_role_failure(method_name, role, method_ordinal);
      if (scripted_failure == null)
        scripted_failure = take_role_failure("create_submit", role,
                                             method_ordinal);
    end
    else if (opcode inside {XTR_V1_OP_CQC_DELETE, XTR_V1_OP_SRFQC_DELETE,
                            XTR_V1_OP_CEQC_DELETE, XTR_V1_OP_AEQC_DELETE}) begin
      method_name = "delete";
      method_ordinals[method_name]++;
      method_ordinal = method_ordinals[method_name];
      role = execute_role(opcode, 0);
      scripted_failure = take_role_failure(method_name, role, method_ordinal);
    end
    else if (opcode inside {XTR_V1_OP_CQC_QUERY, XTR_V1_OP_SRFQC_QUERY,
                            XTR_V1_OP_CEQC_QUERY, XTR_V1_OP_AEQC_QUERY}) begin
      method_name = "query";
      method_ordinals[method_name]++;
      method_ordinal = method_ordinals[method_name];
      role = execute_role(opcode, 0);
      scripted_failure = take_role_failure(method_name, role, method_ordinal);
    end
    else if (opcode == XTR_V1_OP_OCC_FLUSH) begin
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

  // 功能：执行一次受控事务并推进所属状态机；返回结果时保留失败阶段、代际和后端提交证据。
  // 输入/输出及副作用：参数 ticket, terminal_known, completion, status 用于执行 reconcile；返回值或 output/inout 交付处理结果，必要时更新本对象状态。
  //   调用方不获得内部集合或外部依赖的所有权。
  // 失败/边界：事务超时、代际变化或提交证据不完整时不得推进下一阶段。
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
