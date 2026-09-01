// Focused Task 5 recovery regression shell.  The lifecycle test owns the
// fixture builders; this test is registered early so the mandated RED command
// compiles while modify recovery behavior is being developed.
class rdma_qp_recovery_test extends rdma_qp_lifecycle_test;
  `uvm_component_utils(rdma_qp_recovery_test)

  function new(string name = "rdma_qp_recovery_test",
               uvm_component parent = null);
    super.new(name, parent);
  endfunction

  task run_phase(uvm_phase phase);
    phase.raise_objection(this);
    check_ambiguous_modify_recovery();
    check_ambiguous_destroy_recovery();
    phase.drop_objection(this);
  endtask

  task automatic check_ambiguous_modify_recovery();
    rdma_mock_host_mem mem;
    rdma_function_binding binding;
    rdma_resource_manager manager;
    rdma_mock_context_backing contexts;
    rdma_mock_cmq_port cmq;
    rdma_qp_lifecycle_executor executor;
    rdma_pd pd;
    rdma_cq cq;
    rdma_create_qp_req create_req;
    rdma_modify_qp_req modify_req;
    rdma_qp qp;
    rdma_control_result result;
    rdma_control_result recovery_result;
    rdma_status status;
    rdma_resource resource;
    rdma_recovery_record recovery;
    rdma_qp_state_e qp_state;

    mem = rdma_mock_host_mem::type_id::create("recovery_mem");
    setup_qp_environment("recovery", mem, binding, manager,
                         contexts, cmq, executor, pd, cq);
    create_req = make_request("recovery_create", binding, pd, cq,
                              RDMA_TRANSPORT_RC);
    executor.create_locked(binding, binding.make_handle(), create_req, 800,
                           qp, result);
    modify_req = rdma_modify_qp_req::type_id::create("recovery_modify_init");
    modify_req.owner = binding.make_handle();
    modify_req.qp_h = rdma_clone_handle_value(qp.handle, "recovery QP");
    modify_req.new_state = RDMA_QPS_INIT;
    executor.modify_locked(binding, binding.make_handle(), modify_req, 801,
                           qp, result);
    modify_req.new_state = RDMA_QPS_RTR;
    modify_req.destination_qpn_valid = 1'b1;
    modify_req.destination_qpn = 24'h23456;
    cmq.timeout_opcode(XTR_V1_OP_QPC_MODIFY);
    executor.modify_locked(binding, binding.make_handle(), modify_req, 802,
                           qp, result);
    recovery = null;
    if (result != null && result.resource_h != null)
      void'(manager.lookup_recovery(result.resource_h, recovery));
    if (qp != null || result == null || result.status == null ||
        result.status.code != RDMA_SC_RECOVERY_REQUIRED || recovery == null ||
        recovery.qp_recovery == null ||
        recovery.qp_recovery.ambiguous_operation != RDMA_QP_AMBIG_MODIFY ||
        recovery.qp_recovery.query_mapping == null)
      `uvm_error("QP_RECOVERY_AMBIGUOUS", "ambiguous modify did not retain recovery authority")

    if (cmq.calls.size() != 2 || cmq.calls[1] == null ||
        cmq.calls[1].ticket == null) begin
      `uvm_error("QP_RECOVERY_TICKET", "ambiguous modify did not retain a ticket")
    end
    else begin
      cmq.push_late_completion(cmq.calls[1].ticket, rdma_status::success());
      recovery_result = null;
      executor.recover_locked(binding, binding.make_handle(), result.resource_h,
                              803, recovery_result);
      status = manager.lookup(result.resource_h, resource);
      qp_state = RDMA_QPS_RESET;
      if (resource != null)
        qp_state = $cast(qp, resource) ? qp.qp_state : RDMA_QPS_RESET;
      if (recovery_result == null || recovery_result.status == null ||
          !recovery_result.status.ok() || status == null || !status.ok() ||
          resource == null || resource.state != RDMA_RESOURCE_ACTIVE ||
          qp_state != RDMA_QPS_RTR)
        `uvm_error("QP_RECOVERY_RECONCILE", "ambiguous modify was not reconciled")
    end
  endtask

  task automatic check_ambiguous_destroy_recovery();
    rdma_mock_host_mem mem;
    rdma_function_binding binding;
    rdma_resource_manager manager;
    rdma_mock_context_backing contexts;
    rdma_mock_cmq_port cmq;
    rdma_qp_lifecycle_executor executor;
    rdma_pd pd;
    rdma_cq cq;
    rdma_create_qp_req create_req;
    rdma_destroy_resource_req destroy_req;
    rdma_qp qp;
    rdma_control_result result;
    rdma_control_result recovery_result;
    rdma_recovery_record recovery;
    rdma_resource resource;
    rdma_status lookup_status;

    mem = rdma_mock_host_mem::type_id::create("destroy_recovery_mem");
    setup_qp_environment("destroy_recovery", mem, binding, manager,
                         contexts, cmq, executor, pd, cq);
    create_req = make_request("destroy_recovery_create", binding, pd, cq,
                              RDMA_TRANSPORT_RC);
    executor.create_locked(binding, binding.make_handle(), create_req, 850,
                           qp, result);
    destroy_req = rdma_destroy_resource_req::type_id::create(
      "destroy_recovery_destroy");
    destroy_req.owner = binding.make_handle();
    destroy_req.target_h = rdma_clone_handle_value(
      qp.handle, "destroy recovery target");
    cmq.timeout_opcode(XTR_V1_OP_QPC_MODIFY);
    executor.destroy_locked(binding, binding.make_handle(), destroy_req, 851,
                            result);
    recovery = null;
    if (result != null && result.resource_h != null)
      void'(manager.lookup_recovery(result.resource_h, recovery));
    if (result == null || result.status == null ||
        result.status.code != RDMA_SC_RECOVERY_REQUIRED || recovery == null ||
        recovery.qp_recovery == null ||
        recovery.qp_recovery.ambiguous_operation != RDMA_QP_AMBIG_MODIFY ||
        recovery.qp_recovery.ambiguous_ticket == null)
      `uvm_error("QP_DESTROY_RECOVERY_SETUP",
                 "destroy timeout did not retain ERROR transition authority")
    else begin
      cmq.push_late_completion(recovery.qp_recovery.ambiguous_ticket,
                               rdma_status::success());
      recovery_result = null;
      executor.recover_locked(binding, binding.make_handle(), result.resource_h,
                              852, recovery_result);
      lookup_status = manager.lookup(result.resource_h, resource);
      if (recovery_result == null || recovery_result.status == null ||
          !recovery_result.status.ok() || lookup_status == null ||
          lookup_status.code != RDMA_SC_INVALID_STATE || resource != null)
        `uvm_error("QP_DESTROY_RECOVERY",
                   "destroy timeout recovery did not finalize the QP")
    end
  endtask
endclass
