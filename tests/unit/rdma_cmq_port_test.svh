class rdma_cmq_port_test extends rdma_cmq_engine_test;
  `uvm_component_utils(rdma_cmq_port_test)

  function new(string name = "rdma_cmq_port_test",
               uvm_component parent = null);
    super.new(name, parent);
  endfunction

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
    mock_cmq.fail_opcode(XTR_V1_OP_KEY_ALLOC, retained_outcome);

    mutating_command = make_command(
      "mock_mutating_command", binding, XTR_V1_OP_KEY_ALLOC, 8'h21, 1us
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
      "mock_alias_command", binding, XTR_V1_OP_KEY_ALLOC, 8'h22, 1us
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
      "mock_hostile_recovery", binding, XTR_V1_OP_KEY_ALLOC, 8'h23, 1us
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

    binding = make_binding("mock_port_binding", RDMA_BIND_ACTIVE);
    mock_cmq = rdma_mock_cmq_port::type_id::create("mock_cmq");
    port = mock_cmq;
    command = make_command("mock_fail_command", binding,
                           XTR_V1_OP_KEY_ALLOC, 8'h31, 1us);
    timeout_command = make_command("mock_timeout_command", binding,
                                   XTR_V1_OP_KEY_ALLOC, 8'h32, 1us);
    success_command = make_command("mock_success_command", binding,
                                   XTR_V1_OP_KEY_ALLOC, 8'h33, 1us);
    injected_status = rdma_status::make(
      RDMA_SC_DMA_PERMISSION, "injected key failure"
    );
    mock_cmq.fail_opcode(XTR_V1_OP_KEY_ALLOC, injected_status);
    mock_cmq.timeout_opcode(XTR_V1_OP_KEY_ALLOC);
    injected_status.message = "caller mutation";

    saved_generation = command.function_h.generation;
    saved_opcode = command.opcode_key.opcode;
    if (!$cast(recorded_body, command.body))
      `uvm_fatal("MOCK_PORT_FIXTURE", "command body has an unexpected type")
    saved_flags = recorded_body.flags;
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
          ticket.absolute_deadline != command.timeout ||
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
        opcodes[0] != XTR_V1_OP_KEY_ALLOC ||
        opcodes[1] != XTR_V1_OP_KEY_ALLOC ||
        opcodes[2] != XTR_V1_OP_KEY_ALLOC)
      `uvm_error("MOCK_PORT_OPCODE_ORDER",
                 "mock call opcode order does not match execute order")
  endtask

  task automatic check_adapter_routes_real_engines_by_generation();
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
    rdma_cmq_completion unbound_completion;
    rdma_cmq_completion reconciled_completion;
    rdma_dma_mapping mapping_a;
    rdma_hw_image raw_a;
    rdma_status status;
    rdma_status status_a;
    rdma_status status_b;
    rdma_function_handle wrong_owner;
    bit terminal_known;

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
    prepared_b = next_generation_binding("adapter_prepared_b",
                                         RDMA_BIND_PREPARED, 1);
    active_b = next_generation_binding("adapter_active_b",
                                       RDMA_BIND_ACTIVE, 1);
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
    mapping_a = engine_a.mapping_snapshot();
    cqe_hint_a = rdma_cmq_ticket::type_id::create("adapter_cqe_hint_a");
    cqe_hint_a.function_h = command_a.function_h;
    cqe_hint_a.opcode_key = command_a.opcode_key;
    cqe_hint_a.sq_index = 0;
    cqe_hint_a.sq_wrap = 1'b0;
    fork
      begin
        adapter.execute(command_a, ticket_a, completion_a, status_a);
      end
      begin
        adapter.execute(command_b, ticket_b, completion_b, status_b);
      end
    join_none
    while (engine_a.outstanding_count() != 1 ||
           engine_b.outstanding_count() != 1)
      #1ns;
    if (engine_a.outstanding_count() != 1 ||
        engine_b.outstanding_count() != 1 ||
        engine_a.published_count() != 1 ||
        engine_b.published_count() != 1)
      `uvm_error("ADAPTER_REAL_ROUTE",
                 "commands did not reach their generation-specific engines")
    write_profile_cqe("ADAPTER_CQE_A", mem_a, mapping_a, profile_a,
                      0, 1'b1, cqe_hint_a, 0, raw_a);
    wait fork;
    expect_status("ADAPTER_EXECUTE_A", status_a, RDMA_SC_OK);
    expect_status("ADAPTER_EXECUTE_B", status_b, RDMA_SC_TIMEOUT);
    if (completion_a == null || completion_b == null ||
        completion_a.status == null || completion_b.status == null ||
        status_a == completion_a.status || status_b == completion_b.status ||
        ticket_a == null || ticket_b == null ||
        completion_a.ticket == null || completion_b.ticket == null ||
        completion_a.raw_cqe == null || completion_b.raw_cqe != null ||
        completion_a.ticket.function_h.generation != active_a.generation ||
        completion_b.ticket.function_h.generation != active_b.generation ||
        engine_a.outstanding_count() != 0 ||
        engine_b.outstanding_count() != 0 ||
        engine_a.quarantine_count() != 0 ||
        engine_b.quarantine_count() != 1)
      `uvm_error("ADAPTER_REAL_COMPLETE",
                 "adapter did not retain detached timeout ticket/status")

    adapter.reconcile(ticket_b, terminal_known, reconciled_completion, status);
    expect_status("ADAPTER_RECONCILE_ROUTE", status, RDMA_SC_OK);
    if (terminal_known || reconciled_completion != null ||
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
    rdma_cmq_ticket tickets[];
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
        engine.terminal_fifo_count() != 2 ||
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
        completion.raw_cqe == null || completion.ticket == null ||
        completion.ticket.command_id != tickets[1].command_id ||
        completion.status.code != RDMA_SC_TIMEOUT ||
        !engine.probe_same_image(completion.raw_cqe, second_raw) ||
        engine.terminal_fifo_count() != 2 ||
        engine.diagnostic_fifo_count() != 2 ||
        engine.quarantine_count() != 0 ||
        engine.cq_consumed_count() != 3 || engine.retired_count() != 3)
      `uvm_error("RECONCILE_LATE_ISOLATION",
                 "middle reconcile changed outer diagnostic FIFO entries")

    engine.poll(completions, diagnostics, status);
    expect_status("RECONCILE_OUTER_POLL", status, RDMA_SC_OK);
    if (completions.size() != 2 || diagnostics.size() != 2 ||
        completions[0] == null || completions[0].ticket == null ||
        completions[0].status == null ||
        completions[1] == null || completions[1].ticket == null ||
        completions[1].status == null ||
        completions[0].ticket.command_id != tickets[0].command_id ||
        completions[1].ticket.command_id != tickets[2].command_id ||
        completions[0].status.code != RDMA_SC_TIMEOUT ||
        completions[1].status.code != RDMA_SC_TIMEOUT ||
        completions[0].raw_cqe != null || completions[1].raw_cqe != null ||
        diagnostics[0] == null || diagnostics[0].ticket == null ||
        diagnostics[0].status == null || diagnostics[0].raw_cqe == null ||
        diagnostics[1] == null || diagnostics[1].ticket == null ||
        diagnostics[1].status == null || diagnostics[1].raw_cqe == null ||
        diagnostics[0].ticket.command_id != tickets[0].command_id ||
        diagnostics[1].ticket.command_id != tickets[2].command_id ||
        diagnostics[0].kind != RDMA_CMQ_DIAG_LATE_COMPLETION ||
        diagnostics[1].kind != RDMA_CMQ_DIAG_LATE_COMPLETION ||
        !engine.probe_same_image(diagnostics[0].raw_cqe, first_raw) ||
        !engine.probe_same_image(diagnostics[1].raw_cqe, third_raw) ||
        engine.terminal_fifo_count() != 0 ||
        engine.diagnostic_fifo_count() != 0 ||
        engine.quarantine_count() != 0 ||
        engine.outstanding_count() != 0 ||
        engine.cq_consumed_count() != 3 || engine.retired_count() != 3)
      `uvm_error("RECONCILE_OUTER_ORDER",
                 "A/C terminal or diagnostic FIFO order was not retained")

    engine.shutdown(status);
    expect_status("RECONCILE_SHUTDOWN", status, RDMA_SC_OK);
  endtask

  virtual task run_phase(uvm_phase phase);
    phase.raise_objection(this);
    check_mock_rejects_hostile_command_snapshots();
    check_mock_fifo_status_and_reconcile();
    check_adapter_routes_real_engines_by_generation();
    check_real_engine_ticket_specific_reconcile();
    phase.drop_objection(this);
  endtask
endclass
