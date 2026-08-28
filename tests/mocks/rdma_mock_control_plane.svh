class rdma_mock_stag_key_policy extends rdma_stag_key_policy;
  `uvm_object_utils(rdma_mock_stag_key_policy)

  bit [7:0] fixed_key;
  int unsigned call_count;
  protected rdma_status next_failure;

  function new(string name = "rdma_mock_stag_key_policy");
    super.new(name);
    fixed_key = '0;
    call_count = 0;
    next_failure = null;
  endfunction

  function rdma_status fail_next(rdma_status failure);
    if (failure == null)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "STAG key failure status is null");
    next_failure = rdma_cmq_clone_status_value(failure);
    return rdma_status::success();
  endfunction

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

  function new(string name = "rdma_fault_inject_resource_manager");
    super.new(name);
    release_reserved_calls = 0;
    transition_failures.delete();
    role_failures.delete(); transition_ordinals.delete();
  endfunction

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

  function void fail_role_call(string method_name,
                               rdma_queue_backing_role_e role,
                               int unsigned ordinal,
                               rdma_status failure);
    if (failure != null && ordinal != 0)
      role_failures[$sformatf("%s:%0d:%0d", method_name, role, ordinal)] =
        rdma_cmq_clone_status_value(failure);
  endfunction

  function void reset();
    transition_failures.delete(); role_failures.delete();
    transition_ordinals.delete(); release_reserved_calls = 0;
  endfunction

  virtual function rdma_status stage_allocated(rdma_resource candidate);
    rdma_status failure;

    failure = take_transition_failure("stage_allocated");
    if (failure != null)
      return failure;
    return super.stage_allocated(candidate);
  endfunction

  protected function rdma_status take_transition_failure(
    string transition_name
  );
    rdma_status failure;
    int unsigned ordinal;

    transition_ordinals[transition_name]++;
    ordinal = transition_ordinals[transition_name];
    for (int unsigned role = 0; role < 32; role++) begin
      string key;
      key = $sformatf("%s:%0d:%0d", transition_name, role, ordinal);
      if (role_failures.exists(key)) begin
        failure = rdma_cmq_clone_status_value(role_failures[key]);
        role_failures.delete(key);
        return failure;
      end
    end

    if (!transition_failures.exists(transition_name))
      return null;
    failure = rdma_cmq_clone_status_value(
      transition_failures[transition_name]
    );
    transition_failures.delete(transition_name);
    return failure;
  endfunction

  virtual function rdma_status commit_programmed(rdma_resource candidate);
    rdma_status failure;

    failure = take_transition_failure("commit_programmed");
    if (failure != null)
      return failure;
    return super.commit_programmed(candidate);
  endfunction

  virtual function rdma_status activate(rdma_handle handle);
    rdma_status failure;

    failure = take_transition_failure("activate");
    if (failure != null)
      return failure;
    return super.activate(handle);
  endfunction

  virtual function rdma_status release_reserved(rdma_handle handle);
    rdma_status failure;

    release_reserved_calls++;
    failure = take_transition_failure("release_reserved");
    if (failure != null)
      return failure;
    return super.release_reserved(handle);
  endfunction

  virtual function rdma_status mark_error(
    rdma_handle handle,
    rdma_recovery_record recovery
  );
    rdma_status failure;

    failure = take_transition_failure("mark_error");
    if (failure != null)
      return failure;
    return super.mark_error(handle, recovery);
  endfunction

  virtual function rdma_status complete_reserved_error(
    rdma_handle handle
  );
    rdma_status failure;

    failure = take_transition_failure("complete_reserved_error");
    if (failure != null)
      return failure;
    return super.complete_reserved_error(handle);
  endfunction

  virtual function rdma_status record_queue_context_cleanup_complete(
    rdma_handle handle
  );
    rdma_status failure;

    failure = take_transition_failure(
      "record_queue_context_cleanup_complete");
    if (failure != null)
      return failure;
    return super.record_queue_context_cleanup_complete(handle);
  endfunction

  virtual function rdma_status record_queue_cleanup_complete(
    rdma_handle handle,
    rdma_queue_backing_role_e role
  );
    rdma_status failure;

    failure = take_transition_failure("record_queue_cleanup_complete");
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

  function new(string name = "rdma_mock_cmq_call");
    super.new(name);
    \sequence  = 0;
    opcode = '0;
    command = null;
    ticket = null;
  endfunction

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

  function new(string name = "rdma_mock_cmq_snapshot_engine");
    super.new(name);
    profile = rdma_xtr_v1_cmq_hw_profile::type_id::create(
      {name, "_profile"}
    );
  endfunction

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
    snapshot_engine = rdma_mock_cmq_snapshot_engine::type_id::create(
      {name, "_snapshot_engine"}
    );
  endfunction

  virtual function bit last_execute_definitive_no_submit();
    return last_execute_no_submit_proven;
  endfunction

  function void set_call_trace(rdma_mock_call_trace trace);
    call_trace = trace;
  endfunction

  function void gate_opcode(bit [7:0] opcode);
    gate_opcode_count(opcode, 1);
  endfunction

  // Lifecycle-test naming for the CMQ pause barrier.  The gate only waits on
  // the selected opcode and does not hold any adapter mutex, so other
  // Functions may continue to enter execute().
  task pause_cmq_opcode(bit [7:0] opcode);
    gate_opcode(opcode);
  endtask

  task wait_until_paused(bit [7:0] opcode);
    bit observed;
    while (!gate_enabled || gated_opcode != opcode || gate_entered_count == 0)
      #1;
    observed = 1'b1;
  endtask

  function void release_cmq_opcode(bit [7:0] opcode);
    if (gate_enabled && gated_opcode == opcode)
      release_one();
  endfunction

  function void fail_role_call(string method_name,
                               rdma_queue_backing_role_e role,
                               int unsigned ordinal,
                               rdma_status status);
    if (status != null && ordinal != 0) begin
      role_failures[$sformatf("%s:%0d:%0d", method_name, role, ordinal)] =
        rdma_cmq_clone_status_value(status);
      // CMQ lifecycle points are represented by opcode outcomes.  This keeps
      // the machine-readable method+role+ordinal API useful even though the
      // port itself only observes execute(opcode).
      if (method_name == "create_submit" || method_name == "create_terminal" ||
          method_name == "delete")
        fail_opcode((method_name == "delete") ? XTR_V1_OP_CQC_DELETE :
                    XTR_V1_OP_CQC_CREATE, status);
      else if (method_name.substr(0, 5) == "flush" ||
               method_name.substr(0, 9) == "pre_flush" ||
               method_name.substr(0, 10) == "post_flush")
        fail_opcode(XTR_V1_OP_OCC_FLUSH, status);
    end
  endfunction

  function void reset();
    calls.delete(); outcomes.delete(); late_completions.delete();
    reconcile_scripts.delete(); next_sequence = 1;
    role_failures.delete();
    gate_enabled = 1'b0; gate_entered_count = 0; gate_target_count = 1;
    last_execute_no_submit_proven = 1'b0;
    entered.reset(); release_gate.reset();
  endfunction

  // Hold all matching CMQ executions until release_one(), allowing tests to
  // establish a deterministic multi-Function barrier.
  function void gate_opcode_count(bit [7:0] opcode, int unsigned count);
    gated_opcode = opcode;
    gate_enabled = 1'b1;
    gate_target_count = (count == 0) ? 1 : count;
    gate_entered_count = 0;
    release_gate.reset();
    entered.reset();
  endfunction

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

  task release_one();
    gate_enabled = 1'b0;
    release_gate.trigger();
  endtask

  protected function rdma_status invalid_argument(string message);
    return rdma_status::make(RDMA_SC_INVALID_ARGUMENT, message);
  endfunction

  protected function rdma_status invalid_state(string message);
    return rdma_status::make(RDMA_SC_INVALID_STATE, message);
  endfunction

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

  protected function bit ticket_was_recorded(rdma_cmq_ticket ticket);
    foreach (calls[i]) begin
      if (calls[i] != null && same_ticket(calls[i].ticket, ticket))
        return 1'b1;
    end
    return 1'b0;
  endfunction

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

  function void fail_opcode(bit [7:0] opcode, rdma_status status);
    rdma_mock_cmq_outcome outcome;

    outcome = new("mock_cmq_failure_outcome");
    outcome.kind = RDMA_MOCK_CMQ_COMPLETION;
    outcome.status = rdma_cmq_clone_status_value(status);
    outcomes[opcode].push_back(outcome);
  endfunction

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

  function void get_opcodes(output bit [7:0] values[$]);
    values.delete();
    foreach (calls[i]) begin
      if (calls[i] != null)
        values.push_back(calls[i].opcode);
    end
  endfunction

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
    bit [7:0] opcode;

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

    outcome = null;
    if (outcomes.exists(opcode) && outcomes[opcode].size() != 0)
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
