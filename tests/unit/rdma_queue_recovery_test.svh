// Focused recovery coverage for the queue lifecycle executor.  The broader
// lifecycle test owns the fixture builders; this test deliberately exercises
// the public recovery facade so that queue ERROR records cannot accidentally
// fall through the MR-only recovery path.
class rdma_queue_recovery_test extends rdma_queue_lifecycle_test;
  `uvm_component_utils(rdma_queue_recovery_test)

  function new(string name = "rdma_queue_recovery_test",
               uvm_component parent = null);
    super.new(name, parent);
  endfunction

  task automatic check_late_delete_success_recovery();
    rdma_control_plane control;
    rdma_resource_manager manager;
    rdma_mock_cmq_port cmq;
    rdma_mock_stag_key_policy key_policy;
    rdma_mock_host_mem host_mem;
    rdma_mock_context_backing context_backing;
    rdma_function_binding binding;
    rdma_create_ceq_req create_request;
    rdma_destroy_resource_req destroy_request;
    rdma_ceq ceq;
    rdma_control_result result;
    rdma_control_result recovery_result;
    rdma_recovery_record recovery;
    rdma_status status;

    control = rdma_control_plane::type_id::create("QUEUE_RECOVERY_control");
    manager = rdma_resource_manager::type_id::create("QUEUE_RECOVERY_manager");
    cmq = rdma_mock_cmq_port::type_id::create("QUEUE_RECOVERY_cmq");
    key_policy = rdma_mock_stag_key_policy::type_id::create(
      "QUEUE_RECOVERY_key_policy");
    host_mem = rdma_mock_host_mem::type_id::create("QUEUE_RECOVERY_mem");
    context_backing = rdma_mock_context_backing::type_id::create(
      "QUEUE_RECOVERY_context");
    binding = make_binding("QUEUE_RECOVERY_binding");
    status = control.configure(manager, cmq, key_policy, host_mem, null,
                               context_backing, 100ns);
    expect_status("QUEUE_RECOVERY_CONFIGURE", status, RDMA_SC_OK);

    create_request = rdma_create_ceq_req::type_id::create(
      "QUEUE_RECOVERY_create");
    create_request.owner = binding.make_handle();
    create_request.depth = 64;
    create_request.vector_id = 3;
    control.create_ceq(binding, create_request, ceq, result);
    if (ceq == null || result == null || !result.ok()) begin
      `uvm_error("QUEUE_RECOVERY_CREATE", "failed to create CEQ fixture")
      return;
    end

    cmq.timeout_opcode(XTR_V1_OP_CEQC_DELETE);
    destroy_request = make_destroy_request("QUEUE_RECOVERY_destroy", binding,
                                           ceq.handle);
    control.destroy_ceq(binding, destroy_request, result);
    if (result == null || result.status == null ||
        result.status.code != RDMA_SC_RECOVERY_REQUIRED ||
        !result.recovery_required) begin
      `uvm_error("QUEUE_RECOVERY_TIMEOUT",
                 "CEQ delete timeout did not retain recovery")
      return;
    end
    status = manager.lookup_recovery(ceq.handle, recovery);
    expect_status("QUEUE_RECOVERY_LOOKUP", status, RDMA_SC_OK);
    if (recovery == null || recovery.ambiguous_ticket == null) begin
      `uvm_error("QUEUE_RECOVERY_TICKET", "delete ticket was not retained")
      return;
    end

    // The late terminal result is the only evidence that permits recovery to
    // cross the delete boundary.
    cmq.push_late_completion(recovery.ambiguous_ticket,
                             rdma_status::success("late CEQ delete"));
    control.recover_resource(binding, ceq.handle, recovery_result);
    if (recovery_result == null || !recovery_result.ok() ||
        recovery_result.final_resource_state != RDMA_RESOURCE_RELEASED ||
        recovery_result.recovery_required) begin
      `uvm_error("QUEUE_RECOVERY_LATE_SUCCESS",
                 "queue recovery did not complete after late delete success")
    end
  endtask

  task run_phase(uvm_phase phase);
    phase.raise_objection(this);
    check_late_delete_success_recovery();
    phase.drop_objection(this);
  endtask
endclass
