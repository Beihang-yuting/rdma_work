class rdma_cmq_engine_port_adapter extends rdma_cmq_port;
  `uvm_object_utils(rdma_cmq_engine_port_adapter)

  protected rdma_cmq_engine engines[string];
  // Set only when this adapter returns from a validation guard that runs
  // before handing a command to the CMQ engine.  Engine submit/wait failures
  // intentionally remain unclassified because they may have crossed the
  // hardware boundary.
  protected bit last_execute_no_submit_proven;

  function new(string name = "rdma_cmq_engine_port_adapter");
    super.new(name);
    last_execute_no_submit_proven = 1'b0;
  endfunction

  virtual function bit last_execute_definitive_no_submit();
    return last_execute_no_submit_proven;
  endfunction

  protected function string function_key(rdma_function_handle owner);
    return $sformatf("%016h:%08h:%08h", owner.function_uid,
                     owner.object_id, owner.generation);
  endfunction

  protected function rdma_status invalid_argument(string message);
    return rdma_status::make(RDMA_SC_INVALID_ARGUMENT, message);
  endfunction

  protected function rdma_status invalid_state(string message);
    return rdma_status::make(RDMA_SC_INVALID_STATE, message);
  endfunction

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
