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

  // 功能：构造当前对象并初始化其字段、集合和 UVM 名称；不接管传入句柄的生命周期。
  // 输入/输出及副作用：name 仅用于 UVM 对象命名；内部字段被初始化为安全默认值，传入句柄不转移所有权。
  //   返回新对象实例；构造失败由 UVM 工厂或调用方处理。
  // 失败/边界：不创建外部资源；name 为空时仍允许构造，但所有字段必须保持可配置的初始值。
  function new(string name = "rdma_cmq_engine_port_adapter");
    super.new(name);
    last_execute_no_submit_proven = 1'b0;
  endfunction

  // 功能：处理 last_execute_definitive_no_submit：依据其参数完成所属层的具体协议动作，并保持返回状态、游标和资源所有权一致。
  // 输入/输出及副作用：参数 last_execute_no_submit_proven 用于执行 last_execute_definitive_no_submit；返回值或 output/inout 交付处理结果，必要时更新本对象状态。
  //   调用方不获得内部集合或外部依赖的所有权。
  // 失败/边界：last_execute_definitive_no_submit 只接受其签名声明的输入；缺少必要字段时返回错误，成功路径不得隐式修改无关资源。
  virtual function bit last_execute_definitive_no_submit();
    return last_execute_no_submit_proven;
  endfunction

  // 功能：处理 function_key：依据其参数完成所属层的具体协议动作，并保持返回状态、游标和资源所有权一致。
  // 输入/输出及副作用：参数 generation 用于执行 function_key；返回值或 output/inout 交付处理结果，必要时更新本对象状态。
  //   调用方不获得内部集合或外部依赖的所有权。
  // 失败/边界：function_key 只接受其签名声明的输入；缺少必要字段时返回错误，成功路径不得隐式修改无关资源。
  protected function string function_key(rdma_function_handle owner);
    return $sformatf("%016h:%08h:%08h", owner.function_uid,
                     owner.object_id, owner.generation);
  endfunction

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

  // 功能：把指定资源或后端能力绑定到当前对象的唯一索引，并校验 Function、generation 和队列类型一致。
  // 输入/输出及副作用：输入为待绑定资源/后端引用；成功后新增一条受 identity 保护的关联记录。
  //   重复绑定、资源类型错误或依赖缺失时不留下部分关联。
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
    rdma_cmq_engine engine;
    rdma_status engine_status;
    string key;

    last_execute_no_submit_proven = 1'b0;
    ticket = null;
    completion = null;
    status = invalid_state("CMQ port execute did not complete");
    if (command == null || command.function_h == null ||
        command.function_h.kind != RDMA_RESOURCE_FUNCTION) begin
      last_execute_no_submit_proven = 1'b1;
      status = invalid_state("CMQ port command Function is unavailable");
      return;
    end
    key = function_key(command.function_h);
    if (!engines.exists(key) || engines[key] == null) begin
      last_execute_no_submit_proven = 1'b1;
      status = invalid_state("CMQ port Function has no bound engine");
      return;
    end
    engine = engines[key];
    engine.submit(command, ticket, engine_status);
    if (engine_status == null) begin
      status = invalid_state("CMQ engine submit returned null status");
      return;
    end
    if (!engine_status.ok()) begin
      status = rdma_cmq_clone_status_value(engine_status);
      return;
    end
    if (ticket == null) begin
      status = invalid_state("CMQ engine submit returned no ticket");
      return;
    end
    engine.wait_for(ticket, completion, engine_status);
    if (engine_status == null) begin
      status = invalid_state("CMQ engine wait returned null status");
      return;
    end
    if (!engine_status.ok()) begin
      status = rdma_cmq_clone_status_value(engine_status);
      return;
    end
    if (completion == null || completion.status == null) begin
      completion = null;
      status = invalid_state("CMQ engine wait returned incomplete completion");
      return;
    end
    status = rdma_cmq_clone_status_value(completion.status);
    if (status == null)
      status = invalid_state("CMQ completion status copy failed");
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
