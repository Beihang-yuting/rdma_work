class rdma_resource_manager_probe extends rdma_resource_manager;
  function new(string name = "rdma_resource_manager_probe");
    super.new(name);
  endfunction

  function void force_next_object_serial(
    rdma_resource_kind_e kind,
    int unsigned next_serial
  );
    next_object_serial[kind] = next_serial;
  endfunction

  function int unsigned observed_next_local_id(
    rdma_resource_kind_e kind
  );
    return next_local_id[kind];
  endfunction

  function int unsigned observed_next_object_serial(
    rdma_resource_kind_e kind
  );
    return next_object_serial[kind];
  endfunction

  function int unsigned observed_recovery_count();
    return recovery_records.num();
  endfunction
endclass

// Boundary injection is intentionally isolated from the behavior tests.  It
// models corrupted allocator state without exposing registry mutation hooks.
class rdma_width_probe_manager extends rdma_resource_manager;
  function new(string name = "rdma_width_probe_manager");
    super.new(name);
  endfunction

  function void set_next_local_id(rdma_resource_kind_e kind,
                                  int unsigned value);
    next_local_id[kind] = value;
  endfunction

  function void inject_free_local_id(rdma_resource_kind_e kind,
                                     int unsigned value);
    free_local_ids[kind].push_back(value);
  endfunction

  function int unsigned observed_next_object_serial(
    rdma_resource_kind_e kind
  );
    return next_object_serial[kind];
  endfunction

  function int unsigned observed_free_local_id_count(
    rdma_resource_kind_e kind
  );
    if (!free_local_ids.exists(kind))
      return 0;
    return free_local_ids[kind].size();
  endfunction
endclass

typedef enum bit [5:0] {
  RDMA_RM_CLONE_GOOD,
  RDMA_RM_CLONE_SELF,
  RDMA_RM_CLONE_WRONG,
  RDMA_RM_CLONE_DRIFT,
  RDMA_RM_CLONE_BACKING_DRIFT,
  RDMA_RM_CLONE_HMC_DRIFT,
  RDMA_RM_CLONE_PROGRAMMABLE_DRIFT,
  RDMA_RM_CLONE_SHALLOW_RESOURCE_HANDLE,
  RDMA_RM_CLONE_SHALLOW_RESOURCE_OWNER,
  RDMA_RM_CLONE_SHALLOW_RESOURCE_DEPENDENCY,
  RDMA_RM_CLONE_SHALLOW_RESOURCE_BACKING_REF,
  RDMA_RM_CLONE_SHALLOW_RESOURCE_MAPPING,
  RDMA_RM_CLONE_SHALLOW_RESOURCE_MAPPING_FUNCTION,
  RDMA_RM_CLONE_SHALLOW_RESOURCE_MAPPING_OWNER,
  RDMA_RM_CLONE_SHALLOW_RESOURCE_HMC_REF,
  RDMA_RM_CLONE_SHALLOW_RESOURCE_HMC_OWNER,
  RDMA_RM_CLONE_SHALLOW_RESOURCE_KIND_HANDLE,
  RDMA_RM_CLONE_SHALLOW_RECOVERY_RESOURCE_HANDLE,
  RDMA_RM_CLONE_SHALLOW_RECOVERY_BACKING_REF,
  RDMA_RM_CLONE_SHALLOW_RECOVERY_MAPPING,
  RDMA_RM_CLONE_SHALLOW_RECOVERY_MAPPING_FUNCTION,
  RDMA_RM_CLONE_SHALLOW_RECOVERY_MAPPING_OWNER,
  RDMA_RM_CLONE_SHALLOW_RECOVERY_HMC_REF,
  RDMA_RM_CLONE_SHALLOW_RECOVERY_HMC_OWNER,
  RDMA_RM_CLONE_SHALLOW_RECOVERY_TICKET,
  RDMA_RM_CLONE_SHALLOW_RECOVERY_TICKET_FUNCTION,
  RDMA_RM_CLONE_SHALLOW_RECOVERY_TICKET_CMQ,
  RDMA_RM_CLONE_SHALLOW_RECOVERY_TICKET_OPCODE,
  RDMA_RM_CLONE_SHALLOW_RECOVERY_PRIMARY_STATUS,
  RDMA_RM_CLONE_SHALLOW_RECOVERY_ROLLBACK_STATUS,
  RDMA_RM_CLONE_CROSS_RESOURCE_ALIAS,
  RDMA_RM_CLONE_RECOVERY_TICKET_DRIFT,
  RDMA_RM_CLONE_RECOVERY_STEPS_DRIFT,
  RDMA_RM_CLONE_RECOVERY_PRIMARY_HIDDEN_HW_DRIFT,
  RDMA_RM_CLONE_RECOVERY_ROLLBACK_STATUS_DRIFT,
  RDMA_RM_CLONE_MUTATE_SOURCE_SCALAR,
  RDMA_RM_CLONE_LAUNDER_SOURCE_CHILD
} rdma_rm_clone_fault_e;

typedef enum bit [1:0] {
  RDMA_RM_KIND_CLONE_GOOD,
  RDMA_RM_KIND_CLONE_VALUE_DRIFT,
  RDMA_RM_KIND_CLONE_SHALLOW_HANDLES
} rdma_rm_kind_clone_fault_e;

typedef enum bit [1:0] {
  RDMA_RM_FUNCTION_CLONE_GOOD,
  RDMA_RM_FUNCTION_CLONE_SHALLOW_BINDING,
  RDMA_RM_FUNCTION_CLONE_SHALLOW_PCIE,
  RDMA_RM_FUNCTION_CLONE_SHALLOW_BAR
} rdma_rm_function_clone_fault_e;

class rdma_rm_fault_mr extends rdma_mr;
  `uvm_object_utils(rdma_rm_fault_mr)

  rdma_rm_clone_fault_e clone_fault;

  function new(string name = "rdma_rm_fault_mr");
    super.new(name);
    clone_fault = RDMA_RM_CLONE_GOOD;
  endfunction

  virtual function uvm_object clone();
    uvm_object cloned_object;
    rdma_rm_fault_mr cloned_mr;
    rdma_pd wrong_pd;
    rdma_handle saved_pd_h;

    case (clone_fault)
      RDMA_RM_CLONE_SELF: return this;
      RDMA_RM_CLONE_WRONG: begin
        wrong_pd = rdma_pd::type_id::create("wrong_mr_clone");
        wrong_pd.handle = rdma_clone_handle_value(handle, "wrong MR clone");
        wrong_pd.owner = rdma_clone_function_handle_value(
          owner, "wrong MR clone"
        );
        wrong_pd.state = state;
        return wrong_pd;
      end
      RDMA_RM_CLONE_DRIFT: begin
        cloned_object = super.clone();
        if (!$cast(cloned_mr, cloned_object))
          `uvm_fatal("RM_TEST_CLONE", "fault MR clone cast failed")
        cloned_mr.local_mr_id++;
        return cloned_mr;
      end
      RDMA_RM_CLONE_BACKING_DRIFT: begin
        cloned_object = super.clone();
        if (!$cast(cloned_mr, cloned_object) ||
            cloned_mr.backing_refs.size() == 0 ||
            cloned_mr.backing_refs[0] == null ||
            cloned_mr.backing_refs[0].mapping == null)
          `uvm_fatal("RM_TEST_CLONE",
                     "fault MR backing clone setup failed")
        cloned_mr.backing_refs[0].mapping.iova.value++;
        return cloned_mr;
      end
      RDMA_RM_CLONE_HMC_DRIFT: begin
        cloned_object = super.clone();
        if (!$cast(cloned_mr, cloned_object) ||
            cloned_mr.hmc_refs.size() == 0 ||
            cloned_mr.hmc_refs[0] == null)
          `uvm_fatal("RM_TEST_CLONE", "fault MR HMC clone setup failed")
        cloned_mr.hmc_refs[0].address.value++;
        return cloned_mr;
      end
      RDMA_RM_CLONE_PROGRAMMABLE_DRIFT: begin
        cloned_object = super.clone();
        if (!$cast(cloned_mr, cloned_object))
          `uvm_fatal("RM_TEST_CLONE", "fault MR clone cast failed")
        cloned_mr.iova.value += 64'h1000;
        cloned_mr.length += 64'h1000;
        cloned_mr.lkey[7:0]++;
        cloned_mr.rkey = cloned_mr.lkey;
        cloned_mr.access.local_write = !cloned_mr.access.local_write;
        cloned_mr.mr_serial++;
        cloned_mr.hmc_fvm_addr.value++;
        return cloned_mr;
      end
      RDMA_RM_CLONE_SHALLOW_RESOURCE_HANDLE: begin
        cloned_object = super.clone();
        if (!$cast(cloned_mr, cloned_object))
          `uvm_fatal("RM_TEST_CLONE", "fault MR clone cast failed")
        cloned_mr.handle = handle;
        return cloned_mr;
      end
      RDMA_RM_CLONE_SHALLOW_RESOURCE_OWNER: begin
        cloned_object = super.clone();
        if (!$cast(cloned_mr, cloned_object))
          `uvm_fatal("RM_TEST_CLONE", "fault MR clone cast failed")
        cloned_mr.owner = owner;
        return cloned_mr;
      end
      RDMA_RM_CLONE_SHALLOW_RESOURCE_DEPENDENCY: begin
        cloned_object = super.clone();
        if (!$cast(cloned_mr, cloned_object) || dependencies.size() == 0)
          `uvm_fatal("RM_TEST_CLONE",
                     "fault MR dependency clone setup failed")
        cloned_mr.dependencies[0] = dependencies[0];
        return cloned_mr;
      end
      RDMA_RM_CLONE_SHALLOW_RESOURCE_BACKING_REF: begin
        cloned_object = super.clone();
        if (!$cast(cloned_mr, cloned_object) || backing_refs.size() == 0)
          `uvm_fatal("RM_TEST_CLONE",
                     "fault MR backing reference clone setup failed")
        cloned_mr.backing_refs[0] = backing_refs[0];
        return cloned_mr;
      end
      RDMA_RM_CLONE_SHALLOW_RESOURCE_MAPPING: begin
        cloned_object = super.clone();
        if (!$cast(cloned_mr, cloned_object) || backing_refs.size() == 0 ||
            backing_refs[0] == null)
          `uvm_fatal("RM_TEST_CLONE",
                     "fault MR mapping clone setup failed")
        cloned_mr.backing_refs[0].mapping = backing_refs[0].mapping;
        return cloned_mr;
      end
      RDMA_RM_CLONE_SHALLOW_RESOURCE_MAPPING_FUNCTION: begin
        cloned_object = super.clone();
        if (!$cast(cloned_mr, cloned_object) || backing_refs.size() == 0 ||
            backing_refs[0] == null || backing_refs[0].mapping == null)
          `uvm_fatal("RM_TEST_CLONE",
                     "fault MR mapping Function clone setup failed")
        cloned_mr.backing_refs[0].mapping.function_h =
          backing_refs[0].mapping.function_h;
        return cloned_mr;
      end
      RDMA_RM_CLONE_SHALLOW_RESOURCE_MAPPING_OWNER: begin
        cloned_object = super.clone();
        if (!$cast(cloned_mr, cloned_object) || backing_refs.size() == 0 ||
            backing_refs[0] == null || backing_refs[0].mapping == null)
          `uvm_fatal("RM_TEST_CLONE",
                     "fault MR mapping owner clone setup failed")
        cloned_mr.backing_refs[0].mapping.owner_h =
          backing_refs[0].mapping.owner_h;
        return cloned_mr;
      end
      RDMA_RM_CLONE_SHALLOW_RESOURCE_HMC_REF: begin
        cloned_object = super.clone();
        if (!$cast(cloned_mr, cloned_object) || hmc_refs.size() == 0)
          `uvm_fatal("RM_TEST_CLONE",
                     "fault MR HMC reference clone setup failed")
        cloned_mr.hmc_refs[0] = hmc_refs[0];
        return cloned_mr;
      end
      RDMA_RM_CLONE_SHALLOW_RESOURCE_HMC_OWNER: begin
        cloned_object = super.clone();
        if (!$cast(cloned_mr, cloned_object) || hmc_refs.size() == 0 ||
            hmc_refs[0] == null)
          `uvm_fatal("RM_TEST_CLONE",
                     "fault MR HMC owner clone setup failed")
        cloned_mr.hmc_refs[0].owner = hmc_refs[0].owner;
        return cloned_mr;
      end
      RDMA_RM_CLONE_SHALLOW_RESOURCE_KIND_HANDLE: begin
        cloned_object = super.clone();
        if (!$cast(cloned_mr, cloned_object))
          `uvm_fatal("RM_TEST_CLONE", "fault MR clone cast failed")
        cloned_mr.pd_h = pd_h;
        return cloned_mr;
      end
      RDMA_RM_CLONE_CROSS_RESOURCE_ALIAS: begin
        cloned_object = super.clone();
        if (!$cast(cloned_mr, cloned_object) || backing_refs.size() == 0 ||
            backing_refs[0] == null || backing_refs[0].mapping == null ||
            hmc_refs.size() == 0 || hmc_refs[0] == null)
          `uvm_fatal("RM_TEST_CLONE",
                     "fault MR cross-alias setup failed")
        cloned_mr.backing_refs[0].mapping.function_h = hmc_refs[0].owner;
        cloned_mr.backing_refs[0].mapping.owner_h = handle;
        return cloned_mr;
      end
      RDMA_RM_CLONE_MUTATE_SOURCE_SCALAR: begin
        cloned_object = super.clone();
        if (!$cast(cloned_mr, cloned_object))
          `uvm_fatal("RM_TEST_CLONE", "fault MR clone cast failed")
        length++;
        return cloned_mr;
      end
      RDMA_RM_CLONE_LAUNDER_SOURCE_CHILD: begin
        saved_pd_h = pd_h;
        cloned_object = super.clone();
        if (!$cast(cloned_mr, cloned_object))
          `uvm_fatal("RM_TEST_CLONE", "fault MR clone cast failed")
        pd_h = cloned_mr.pd_h;
        cloned_mr.pd_h = saved_pd_h;
        return cloned_mr;
      end
      default: return super.clone();
    endcase
  endfunction
endclass

class rdma_rm_fault_function extends rdma_function;
  `uvm_object_utils(rdma_rm_fault_function)

  rdma_rm_function_clone_fault_e clone_fault;

  function new(string name = "rdma_rm_fault_function");
    super.new(name);
    clone_fault = RDMA_RM_FUNCTION_CLONE_GOOD;
  endfunction

  virtual function uvm_object clone();
    uvm_object cloned_object;
    rdma_rm_fault_function cloned_function;

    cloned_object = super.clone();
    if (!$cast(cloned_function, cloned_object))
      `uvm_fatal("RM_TEST_CLONE", "fault Function clone cast failed")
    case (clone_fault)
      RDMA_RM_FUNCTION_CLONE_SHALLOW_BINDING:
        cloned_function.binding = binding;
      RDMA_RM_FUNCTION_CLONE_SHALLOW_PCIE:
        cloned_function.binding.pcie = binding.pcie;
      RDMA_RM_FUNCTION_CLONE_SHALLOW_BAR:
        cloned_function.binding.pcie.bar[0] = binding.pcie.bar[0];
    endcase
    return cloned_function;
  endfunction
endclass

class rdma_rm_fault_pd extends rdma_pd;
  `uvm_object_utils(rdma_rm_fault_pd)
  rdma_rm_kind_clone_fault_e clone_fault;
  function new(string name = "rdma_rm_fault_pd");
    super.new(name);
    clone_fault = RDMA_RM_KIND_CLONE_GOOD;
  endfunction
  virtual function uvm_object clone();
    uvm_object cloned_object;
    rdma_rm_fault_pd cloned_pd;
    cloned_object = super.clone();
    if (!$cast(cloned_pd, cloned_object))
      `uvm_fatal("RM_TEST_CLONE", "fault PD clone cast failed")
    if (clone_fault == RDMA_RM_KIND_CLONE_VALUE_DRIFT)
      cloned_pd.global_pd_id++;
    return cloned_pd;
  endfunction
endclass

class rdma_rm_fault_cq extends rdma_cq;
  `uvm_object_utils(rdma_rm_fault_cq)
  rdma_rm_kind_clone_fault_e clone_fault;
  function new(string name = "rdma_rm_fault_cq");
    super.new(name);
    clone_fault = RDMA_RM_KIND_CLONE_GOOD;
  endfunction
  virtual function uvm_object clone();
    uvm_object cloned_object;
    rdma_rm_fault_cq cloned_cq;
    cloned_object = super.clone();
    if (!$cast(cloned_cq, cloned_object))
      `uvm_fatal("RM_TEST_CLONE", "fault CQ clone cast failed")
    case (clone_fault)
      RDMA_RM_KIND_CLONE_VALUE_DRIFT: begin
        cloned_cq.queue_iova.value++;
      end
      RDMA_RM_KIND_CLONE_SHALLOW_HANDLES: cloned_cq.ceq_h = ceq_h;
    endcase
    return cloned_cq;
  endfunction
endclass

class rdma_rm_fault_qp extends rdma_qp;
  `uvm_object_utils(rdma_rm_fault_qp)
  rdma_rm_kind_clone_fault_e clone_fault;
  function new(string name = "rdma_rm_fault_qp");
    super.new(name);
    clone_fault = RDMA_RM_KIND_CLONE_GOOD;
  endfunction
  virtual function uvm_object clone();
    uvm_object cloned_object;
    rdma_rm_fault_qp cloned_qp;
    cloned_object = super.clone();
    if (!$cast(cloned_qp, cloned_object))
      `uvm_fatal("RM_TEST_CLONE", "fault QP clone cast failed")
    case (clone_fault)
      RDMA_RM_KIND_CLONE_VALUE_DRIFT: begin
        cloned_qp.rq_iova.value++;
      end
      RDMA_RM_KIND_CLONE_SHALLOW_HANDLES: begin
        cloned_qp.pd_h = pd_h;
        cloned_qp.send_cq_h = send_cq_h;
        cloned_qp.recv_cq_h = recv_cq_h;
        cloned_qp.srq_h = srq_h;
      end
    endcase
    return cloned_qp;
  endfunction
endclass

class rdma_rm_fault_srq extends rdma_srq;
  `uvm_object_utils(rdma_rm_fault_srq)
  rdma_rm_kind_clone_fault_e clone_fault;
  function new(string name = "rdma_rm_fault_srq");
    super.new(name);
    clone_fault = RDMA_RM_KIND_CLONE_GOOD;
  endfunction
  virtual function uvm_object clone();
    uvm_object cloned_object;
    rdma_rm_fault_srq cloned_srq;
    cloned_object = super.clone();
    if (!$cast(cloned_srq, cloned_object))
      `uvm_fatal("RM_TEST_CLONE", "fault SRQ clone cast failed")
    case (clone_fault)
      RDMA_RM_KIND_CLONE_VALUE_DRIFT: begin
        cloned_srq.max_sge++;
      end
      RDMA_RM_KIND_CLONE_SHALLOW_HANDLES: cloned_srq.pd_h = pd_h;
    endcase
    return cloned_srq;
  endfunction
endclass

class rdma_rm_fault_cmq extends rdma_cmq;
  `uvm_object_utils(rdma_rm_fault_cmq)
  rdma_rm_kind_clone_fault_e clone_fault;
  function new(string name = "rdma_rm_fault_cmq");
    super.new(name);
    clone_fault = RDMA_RM_KIND_CLONE_GOOD;
  endfunction
  virtual function uvm_object clone();
    uvm_object cloned_object;
    rdma_rm_fault_cmq cloned_cmq;
    cloned_object = super.clone();
    if (!$cast(cloned_cmq, cloned_object))
      `uvm_fatal("RM_TEST_CLONE", "fault CMQ clone cast failed")
    if (clone_fault == RDMA_RM_KIND_CLONE_VALUE_DRIFT) begin
      cloned_cmq.completion_iova.value++;
    end
    return cloned_cmq;
  endfunction
endclass

class rdma_rm_fault_ceq extends rdma_ceq;
  `uvm_object_utils(rdma_rm_fault_ceq)
  rdma_rm_kind_clone_fault_e clone_fault;
  function new(string name = "rdma_rm_fault_ceq");
    super.new(name);
    clone_fault = RDMA_RM_KIND_CLONE_GOOD;
  endfunction
  virtual function uvm_object clone();
    uvm_object cloned_object;
    rdma_rm_fault_ceq cloned_ceq;
    cloned_object = super.clone();
    if (!$cast(cloned_ceq, cloned_object))
      `uvm_fatal("RM_TEST_CLONE", "fault CEQ clone cast failed")
    if (clone_fault == RDMA_RM_KIND_CLONE_VALUE_DRIFT) begin
      cloned_ceq.queue_iova.value++;
    end
    return cloned_ceq;
  endfunction
endclass

class rdma_rm_fault_aeq extends rdma_aeq;
  `uvm_object_utils(rdma_rm_fault_aeq)
  rdma_rm_kind_clone_fault_e clone_fault;
  function new(string name = "rdma_rm_fault_aeq");
    super.new(name);
    clone_fault = RDMA_RM_KIND_CLONE_GOOD;
  endfunction
  virtual function uvm_object clone();
    uvm_object cloned_object;
    rdma_rm_fault_aeq cloned_aeq;
    cloned_object = super.clone();
    if (!$cast(cloned_aeq, cloned_object))
      `uvm_fatal("RM_TEST_CLONE", "fault AEQ clone cast failed")
    if (clone_fault == RDMA_RM_KIND_CLONE_VALUE_DRIFT) begin
      cloned_aeq.queue_iova.value++;
    end
    return cloned_aeq;
  endfunction
endclass

class rdma_rm_fault_recovery extends rdma_recovery_record;
  `uvm_object_utils(rdma_rm_fault_recovery)

  rdma_rm_clone_fault_e clone_fault;

  function new(string name = "rdma_rm_fault_recovery");
    super.new(name);
    clone_fault = RDMA_RM_CLONE_GOOD;
  endfunction

  virtual function uvm_object clone();
    uvm_object cloned_object;
    rdma_rm_fault_recovery cloned_recovery;
    rdma_cmq_ticket saved_ticket;

    case (clone_fault)
      RDMA_RM_CLONE_SELF: return this;
      RDMA_RM_CLONE_DRIFT: begin
        cloned_object = super.clone();
        if (!$cast(cloned_recovery, cloned_object))
          `uvm_fatal("RM_TEST_CLONE", "fault recovery clone cast failed")
        cloned_recovery.resource_h.object_id++;
        return cloned_recovery;
      end
      RDMA_RM_CLONE_BACKING_DRIFT: begin
        cloned_object = super.clone();
        if (!$cast(cloned_recovery, cloned_object) ||
            cloned_recovery.backing_refs.size() == 0 ||
            cloned_recovery.backing_refs[0] == null ||
            cloned_recovery.backing_refs[0].mapping == null)
          `uvm_fatal("RM_TEST_CLONE",
                     "fault recovery backing clone setup failed")
        cloned_recovery.backing_refs[0].mapping.iova.value++;
        return cloned_recovery;
      end
      RDMA_RM_CLONE_HMC_DRIFT: begin
        cloned_object = super.clone();
        if (!$cast(cloned_recovery, cloned_object) ||
            cloned_recovery.hmc_refs.size() == 0 ||
            cloned_recovery.hmc_refs[0] == null)
          `uvm_fatal("RM_TEST_CLONE",
                     "fault recovery HMC clone setup failed")
        cloned_recovery.hmc_refs[0].address.value++;
        return cloned_recovery;
      end
      RDMA_RM_CLONE_SHALLOW_RECOVERY_RESOURCE_HANDLE: begin
        cloned_object = super.clone();
        if (!$cast(cloned_recovery, cloned_object))
          `uvm_fatal("RM_TEST_CLONE", "fault recovery clone cast failed")
        cloned_recovery.resource_h = resource_h;
        return cloned_recovery;
      end
      RDMA_RM_CLONE_SHALLOW_RECOVERY_BACKING_REF: begin
        cloned_object = super.clone();
        if (!$cast(cloned_recovery, cloned_object) ||
            backing_refs.size() == 0)
          `uvm_fatal("RM_TEST_CLONE",
                     "fault recovery backing reference setup failed")
        cloned_recovery.backing_refs[0] = backing_refs[0];
        return cloned_recovery;
      end
      RDMA_RM_CLONE_SHALLOW_RECOVERY_MAPPING: begin
        cloned_object = super.clone();
        if (!$cast(cloned_recovery, cloned_object) ||
            backing_refs.size() == 0 || backing_refs[0] == null)
          `uvm_fatal("RM_TEST_CLONE",
                     "fault recovery mapping setup failed")
        cloned_recovery.backing_refs[0].mapping = backing_refs[0].mapping;
        return cloned_recovery;
      end
      RDMA_RM_CLONE_SHALLOW_RECOVERY_MAPPING_FUNCTION: begin
        cloned_object = super.clone();
        if (!$cast(cloned_recovery, cloned_object) ||
            backing_refs.size() == 0 || backing_refs[0] == null ||
            backing_refs[0].mapping == null)
          `uvm_fatal("RM_TEST_CLONE",
                     "fault recovery mapping Function setup failed")
        cloned_recovery.backing_refs[0].mapping.function_h =
          backing_refs[0].mapping.function_h;
        return cloned_recovery;
      end
      RDMA_RM_CLONE_SHALLOW_RECOVERY_MAPPING_OWNER: begin
        cloned_object = super.clone();
        if (!$cast(cloned_recovery, cloned_object) ||
            backing_refs.size() == 0 || backing_refs[0] == null ||
            backing_refs[0].mapping == null)
          `uvm_fatal("RM_TEST_CLONE",
                     "fault recovery mapping owner setup failed")
        cloned_recovery.backing_refs[0].mapping.owner_h =
          backing_refs[0].mapping.owner_h;
        return cloned_recovery;
      end
      RDMA_RM_CLONE_SHALLOW_RECOVERY_HMC_REF: begin
        cloned_object = super.clone();
        if (!$cast(cloned_recovery, cloned_object) || hmc_refs.size() == 0)
          `uvm_fatal("RM_TEST_CLONE",
                     "fault recovery HMC reference setup failed")
        cloned_recovery.hmc_refs[0] = hmc_refs[0];
        return cloned_recovery;
      end
      RDMA_RM_CLONE_SHALLOW_RECOVERY_HMC_OWNER: begin
        cloned_object = super.clone();
        if (!$cast(cloned_recovery, cloned_object) || hmc_refs.size() == 0 ||
            hmc_refs[0] == null)
          `uvm_fatal("RM_TEST_CLONE",
                     "fault recovery HMC owner setup failed")
        cloned_recovery.hmc_refs[0].owner = hmc_refs[0].owner;
        return cloned_recovery;
      end
      RDMA_RM_CLONE_SHALLOW_RECOVERY_TICKET: begin
        cloned_object = super.clone();
        if (!$cast(cloned_recovery, cloned_object))
          `uvm_fatal("RM_TEST_CLONE", "fault recovery clone cast failed")
        cloned_recovery.ambiguous_ticket = ambiguous_ticket;
        return cloned_recovery;
      end
      RDMA_RM_CLONE_SHALLOW_RECOVERY_TICKET_FUNCTION: begin
        cloned_object = super.clone();
        if (!$cast(cloned_recovery, cloned_object) ||
            ambiguous_ticket == null)
          `uvm_fatal("RM_TEST_CLONE",
                     "fault recovery ticket Function setup failed")
        cloned_recovery.ambiguous_ticket.function_h =
          ambiguous_ticket.function_h;
        return cloned_recovery;
      end
      RDMA_RM_CLONE_SHALLOW_RECOVERY_TICKET_CMQ: begin
        cloned_object = super.clone();
        if (!$cast(cloned_recovery, cloned_object) ||
            ambiguous_ticket == null)
          `uvm_fatal("RM_TEST_CLONE",
                     "fault recovery ticket CMQ setup failed")
        cloned_recovery.ambiguous_ticket.cmq_h = ambiguous_ticket.cmq_h;
        return cloned_recovery;
      end
      RDMA_RM_CLONE_SHALLOW_RECOVERY_TICKET_OPCODE: begin
        cloned_object = super.clone();
        if (!$cast(cloned_recovery, cloned_object) ||
            ambiguous_ticket == null)
          `uvm_fatal("RM_TEST_CLONE",
                     "fault recovery ticket opcode setup failed")
        cloned_recovery.ambiguous_ticket.opcode_key =
          ambiguous_ticket.opcode_key;
        return cloned_recovery;
      end
      RDMA_RM_CLONE_SHALLOW_RECOVERY_PRIMARY_STATUS: begin
        cloned_object = super.clone();
        if (!$cast(cloned_recovery, cloned_object))
          `uvm_fatal("RM_TEST_CLONE", "fault recovery clone cast failed")
        cloned_recovery.primary_status = primary_status;
        return cloned_recovery;
      end
      RDMA_RM_CLONE_SHALLOW_RECOVERY_ROLLBACK_STATUS: begin
        cloned_object = super.clone();
        if (!$cast(cloned_recovery, cloned_object) ||
            rollback_statuses.size() == 0)
          `uvm_fatal("RM_TEST_CLONE",
                     "fault recovery rollback status setup failed")
        cloned_recovery.rollback_statuses[0] = rollback_statuses[0];
        return cloned_recovery;
      end
      RDMA_RM_CLONE_RECOVERY_TICKET_DRIFT: begin
        cloned_object = super.clone();
        if (!$cast(cloned_recovery, cloned_object) ||
            cloned_recovery.ambiguous_ticket == null)
          `uvm_fatal("RM_TEST_CLONE",
                     "fault recovery ticket drift setup failed")
        cloned_recovery.ambiguous_ticket.command_id++;
        return cloned_recovery;
      end
      RDMA_RM_CLONE_RECOVERY_STEPS_DRIFT: begin
        cloned_object = super.clone();
        if (!$cast(cloned_recovery, cloned_object) ||
            cloned_recovery.completed_steps.size() == 0)
          `uvm_fatal("RM_TEST_CLONE",
                     "fault recovery step drift setup failed")
        cloned_recovery.completed_steps[0] =
          RDMA_CTRL_STEP_BACKING_ATTACHED;
        return cloned_recovery;
      end
      RDMA_RM_CLONE_RECOVERY_PRIMARY_HIDDEN_HW_DRIFT: begin
        cloned_object = super.clone();
        if (!$cast(cloned_recovery, cloned_object) ||
            cloned_recovery.primary_status == null)
          `uvm_fatal("RM_TEST_CLONE",
                     "fault recovery primary status setup failed")
        cloned_recovery.primary_status.hardware_code++;
        return cloned_recovery;
      end
      RDMA_RM_CLONE_RECOVERY_ROLLBACK_STATUS_DRIFT: begin
        cloned_object = super.clone();
        if (!$cast(cloned_recovery, cloned_object) ||
            cloned_recovery.rollback_statuses.size() == 0 ||
            cloned_recovery.rollback_statuses[0] == null)
          `uvm_fatal("RM_TEST_CLONE",
                     "fault recovery rollback status drift setup failed")
        cloned_recovery.rollback_statuses[0].retryable =
          !cloned_recovery.rollback_statuses[0].retryable;
        return cloned_recovery;
      end
      RDMA_RM_CLONE_MUTATE_SOURCE_SCALAR: begin
        cloned_object = super.clone();
        if (!$cast(cloned_recovery, cloned_object))
          `uvm_fatal("RM_TEST_CLONE", "fault recovery clone cast failed")
        hardware_presence = RDMA_HW_PRESENCE_PRESENT;
        return cloned_recovery;
      end
      RDMA_RM_CLONE_LAUNDER_SOURCE_CHILD: begin
        saved_ticket = ambiguous_ticket;
        cloned_object = super.clone();
        if (!$cast(cloned_recovery, cloned_object))
          `uvm_fatal("RM_TEST_CLONE", "fault recovery clone cast failed")
        ambiguous_ticket = cloned_recovery.ambiguous_ticket;
        cloned_recovery.ambiguous_ticket = saved_ticket;
        return cloned_recovery;
      end
      default: return super.clone();
    endcase
  endfunction
endclass

class rdma_rm_schema_mr extends rdma_mr;
  `uvm_object_utils(rdma_rm_schema_mr)

  int unsigned clone_calls;
  int unsigned extra_scalar;
  rdma_handle extra_child;

  function new(string name = "rdma_rm_schema_mr");
    super.new(name);
    clone_calls = 0;
    extra_scalar = 32'h51a7_e001;
    extra_child = null;
  endfunction

  virtual function uvm_object clone();
    clone_calls++;
    return super.clone();
  endfunction
endclass

class rdma_rm_schema_recovery extends rdma_recovery_record;
  `uvm_object_utils(rdma_rm_schema_recovery)

  int unsigned clone_calls;
  int unsigned extra_scalar;
  rdma_handle extra_child;

  function new(string name = "rdma_rm_schema_recovery");
    super.new(name);
    clone_calls = 0;
    extra_scalar = 32'h51a7_e002;
    extra_child = null;
  endfunction

  virtual function uvm_object clone();
    clone_calls++;
    return super.clone();
  endfunction
endclass

class rdma_rm_schema_handle extends rdma_handle;
  `uvm_object_utils(rdma_rm_schema_handle)

  int unsigned clone_calls;

  function new(string name = "rdma_rm_schema_handle");
    super.new(name);
    clone_calls = 0;
  endfunction

  virtual function uvm_object clone();
    clone_calls++;
    return super.clone();
  endfunction
endclass

class rdma_rm_schema_function_handle extends rdma_function_handle;
  `uvm_object_utils(rdma_rm_schema_function_handle)

  int unsigned clone_calls;

  function new(string name = "rdma_rm_schema_function_handle");
    super.new(name);
    clone_calls = 0;
  endfunction

  virtual function uvm_object clone();
    clone_calls++;
    return super.clone();
  endfunction
endclass

class rdma_rm_schema_backing_ref extends rdma_backing_ref;
  `uvm_object_utils(rdma_rm_schema_backing_ref)

  int unsigned clone_calls;

  function new(string name = "rdma_rm_schema_backing_ref");
    super.new(name);
    clone_calls = 0;
  endfunction

  virtual function uvm_object clone();
    clone_calls++;
    return super.clone();
  endfunction
endclass

class rdma_rm_schema_mapping extends rdma_dma_mapping;
  `uvm_object_utils(rdma_rm_schema_mapping)

  int unsigned clone_calls;

  function new(string name = "rdma_rm_schema_mapping");
    super.new(name);
    clone_calls = 0;
  endfunction

  virtual function uvm_object clone();
    clone_calls++;
    return super.clone();
  endfunction
endclass

class rdma_rm_schema_hmc_ref extends rdma_hmc_ref;
  `uvm_object_utils(rdma_rm_schema_hmc_ref)

  int unsigned clone_calls;

  function new(string name = "rdma_rm_schema_hmc_ref");
    super.new(name);
    clone_calls = 0;
  endfunction

  virtual function uvm_object clone();
    clone_calls++;
    return super.clone();
  endfunction
endclass

class rdma_rm_schema_binding extends rdma_function_binding;
  `uvm_object_utils(rdma_rm_schema_binding)

  int unsigned clone_calls;

  function new(string name = "rdma_rm_schema_binding");
    super.new(name);
    clone_calls = 0;
  endfunction

  virtual function uvm_object clone();
    clone_calls++;
    return super.clone();
  endfunction
endclass

class rdma_rm_schema_pcie extends rdma_pcie_identity;
  `uvm_object_utils(rdma_rm_schema_pcie)

  int unsigned clone_calls;

  function new(string name = "rdma_rm_schema_pcie");
    super.new(name);
    clone_calls = 0;
  endfunction

  virtual function uvm_object clone();
    clone_calls++;
    return super.clone();
  endfunction
endclass

class rdma_rm_schema_bar extends rdma_bar_info;
  `uvm_object_utils(rdma_rm_schema_bar)

  int unsigned clone_calls;

  function new(string name = "rdma_rm_schema_bar");
    super.new(name);
    clone_calls = 0;
  endfunction

  virtual function uvm_object clone();
    clone_calls++;
    return super.clone();
  endfunction
endclass

class rdma_rm_schema_ticket extends rdma_cmq_ticket;
  `uvm_object_utils(rdma_rm_schema_ticket)

  int unsigned clone_calls;

  function new(string name = "rdma_rm_schema_ticket");
    super.new(name);
    clone_calls = 0;
  endfunction

  virtual function uvm_object clone();
    clone_calls++;
    return super.clone();
  endfunction
endclass

class rdma_rm_schema_opcode extends rdma_cmq_opcode_key;
  `uvm_object_utils(rdma_rm_schema_opcode)

  int unsigned clone_calls;

  function new(string name = "rdma_rm_schema_opcode");
    super.new(name);
    clone_calls = 0;
  endfunction

  virtual function uvm_object clone();
    clone_calls++;
    return super.clone();
  endfunction
endclass

class rdma_rm_schema_status extends rdma_status;
  `uvm_object_utils(rdma_rm_schema_status)

  int unsigned clone_calls;

  function new(string name = "rdma_rm_schema_status");
    super.new(name);
    clone_calls = 0;
  endfunction

  virtual function uvm_object clone();
    clone_calls++;
    return super.clone();
  endfunction
endclass

class rdma_rm_stateful_mr extends rdma_mr;
  `uvm_object_utils(rdma_rm_stateful_mr)

  int unsigned clone_calls;

  function new(string name = "rdma_rm_stateful_mr");
    super.new(name);
    clone_calls = 0;
  endfunction

  virtual function uvm_object clone();
    uvm_object cloned_object;
    rdma_rm_stateful_mr cloned_mr;

    clone_calls++;
    cloned_object = super.clone();
    if (clone_calls > 1) begin
      if (!$cast(cloned_mr, cloned_object))
        `uvm_fatal("RM_TEST_SCHEMA", "stateful MR clone cast failed")
      cloned_mr.length++;
    end
    return cloned_object;
  endfunction
endclass

// These carriers model the two ways wrapper identity can be spoofed.  The
// unregistered subclasses inherit the built-in wrapper, while the registered
// subclasses deliberately report the built-in wrapper.  Neither extension is
// authoritative at the resource-manager boundary.
class rdma_rm_unregistered_mr extends rdma_mr;
  int unsigned clone_calls;
  int unsigned extra_scalar;
  rdma_handle extra_child;

  function new(string name = "rdma_rm_unregistered_mr");
    super.new(name);
    clone_calls = 0;
    extra_scalar = 32'hc011_a001;
    extra_child = null;
  endfunction

  virtual function uvm_object clone();
    uvm_object result;

    clone_calls++;
    result = super.clone();
    length++;
    return result;
  endfunction
endclass

class rdma_rm_lying_mr extends rdma_mr;
  typedef uvm_object_registry#(rdma_rm_lying_mr,
                               "rdma_rm_lying_mr") type_id;

  static function type_id get_type();
    return type_id::get();
  endfunction

  int unsigned clone_calls;
  int unsigned extra_scalar;
  rdma_handle extra_child;

  function new(string name = "rdma_rm_lying_mr");
    super.new(name);
    clone_calls = 0;
    extra_scalar = 32'hc011_a002;
    extra_child = null;
  endfunction

  virtual function uvm_object_wrapper get_object_type();
    return rdma_mr::get_type();
  endfunction

  virtual function uvm_object clone();
    uvm_object result;

    clone_calls++;
    result = super.clone();
    length++;
    return result;
  endfunction
endclass

class rdma_rm_unregistered_mapping extends rdma_dma_mapping;
  int unsigned clone_calls;
  int unsigned extra_scalar;
  rdma_handle extra_child;

  function new(string name = "rdma_rm_unregistered_mapping");
    super.new(name);
    clone_calls = 0;
    extra_scalar = 32'hc011_b001;
    extra_child = null;
  endfunction

  virtual function uvm_object clone();
    uvm_object result;

    clone_calls++;
    result = super.clone();
    size++;
    return result;
  endfunction
endclass

class rdma_rm_lying_mapping extends rdma_dma_mapping;
  typedef uvm_object_registry#(rdma_rm_lying_mapping,
                               "rdma_rm_lying_mapping") type_id;

  static function type_id get_type();
    return type_id::get();
  endfunction

  int unsigned clone_calls;
  int unsigned extra_scalar;
  rdma_handle extra_child;

  function new(string name = "rdma_rm_lying_mapping");
    super.new(name);
    clone_calls = 0;
    extra_scalar = 32'hc011_b002;
    extra_child = null;
  endfunction

  virtual function uvm_object_wrapper get_object_type();
    return rdma_dma_mapping::get_type();
  endfunction

  virtual function uvm_object clone();
    uvm_object result;

    clone_calls++;
    result = super.clone();
    size++;
    return result;
  endfunction
endclass

class rdma_rm_unregistered_recovery extends rdma_recovery_record;
  int unsigned clone_calls;
  int unsigned extra_scalar;
  rdma_handle extra_child;

  function new(string name = "rdma_rm_unregistered_recovery");
    super.new(name);
    clone_calls = 0;
    extra_scalar = 32'hc011_c001;
    extra_child = null;
  endfunction

  virtual function uvm_object clone();
    uvm_object result;

    clone_calls++;
    result = super.clone();
    hardware_presence = RDMA_HW_PRESENCE_PRESENT;
    return result;
  endfunction
endclass

class rdma_rm_lying_recovery extends rdma_recovery_record;
  typedef uvm_object_registry#(rdma_rm_lying_recovery,
                               "rdma_rm_lying_recovery") type_id;

  static function type_id get_type();
    return type_id::get();
  endfunction

  int unsigned clone_calls;
  int unsigned extra_scalar;
  rdma_handle extra_child;

  function new(string name = "rdma_rm_lying_recovery");
    super.new(name);
    clone_calls = 0;
    extra_scalar = 32'hc011_c002;
    extra_child = null;
  endfunction

  virtual function uvm_object_wrapper get_object_type();
    return rdma_recovery_record::get_type();
  endfunction

  virtual function uvm_object clone();
    uvm_object result;

    clone_calls++;
    result = super.clone();
    hardware_presence = RDMA_HW_PRESENCE_PRESENT;
    return result;
  endfunction
endclass

class rdma_clone_probe_manager extends rdma_resource_manager;
  function new(string name = "rdma_clone_probe_manager");
    super.new(name);
  endfunction

  function void replace_authoritative(rdma_resource replacement);
    registry[resource_key(replacement.handle)] = replacement;
  endfunction

  function rdma_resource observed_resource_probe(rdma_handle handle);
    string key;

    key = resource_key(handle);
    if (!registry.exists(key))
      return null;
    return registry[key];
  endfunction

  function int unsigned observed_generation_high_water(
    rdma_function_handle owner
  );
    string key;

    key = function_key(owner);
    if (!generation_high_water.exists(key))
      return 0;
    return generation_high_water[key];
  endfunction

  function void reset_publication_probe(rdma_resource replacement,
                                        bit staged);
    string key;

    key = resource_key(replacement.handle);
    registry[key] = replacement;
    if (staged)
      staged_allocations[key] = 1'b1;
    else
      staged_allocations.delete(key);
  endfunction

  function rdma_status probe_public_resource_projection(
    rdma_resource source,
    output rdma_resource result
  );
    return project_public_resource_value(source, "projection gate probe",
                                         result);
  endfunction

  function void reset_error_probe(rdma_resource replacement);
    string key;
    rdma_resource replacement_copy;
    rdma_status status;

    key = resource_key(replacement.handle);
    status = project_resource_value(replacement, "error probe reset",
                                    replacement_copy);
    if (!status.ok())
      `uvm_fatal("RM_TEST_SCHEMA", status.convert2string())
    registry[key] = replacement_copy;
    recovery_records.delete(key);
  endfunction

  function void inject_recovery_probe(
    rdma_handle handle,
    rdma_recovery_record recovery
  );
    recovery_records[resource_key(handle)] = recovery;
  endfunction

  function rdma_recovery_record observed_recovery_probe(rdma_handle handle);
    string key;

    key = resource_key(handle);
    if (!recovery_records.exists(key))
      return null;
    return recovery_records[key];
  endfunction
endclass

class rdma_resource_manager_test extends uvm_test;
  `uvm_component_utils(rdma_resource_manager_test)

  function new(string name = "rdma_resource_manager_test",
               uvm_component parent = null);
    super.new(name, parent);
  endfunction

  function automatic void expect_status(
    string check_name,
    rdma_status status,
    rdma_status_code_e expected_code
  );
    if (status == null) begin
      `uvm_error(check_name, "resource API returned a null status")
      return;
    end
    if (status.code != expected_code)
      `uvm_error(check_name,
                 $sformatf("expected %s, got %s (%s)",
                           expected_code.name(), status.code.name(),
                           status.convert2string()))
  endfunction

  function automatic rdma_handle clone_handle(
    string check_name,
    rdma_handle source
  );
    uvm_object cloned_object;
    rdma_handle cloned_handle;

    if (source == null)
      `uvm_fatal(check_name, "cannot clone a null handle")
    cloned_object = source.clone();
    if (cloned_object == null || !$cast(cloned_handle, cloned_object))
      `uvm_fatal(check_name, "handle clone cast failed")
    return cloned_handle;
  endfunction

  function automatic rdma_function_handle clone_function_handle(
    string check_name,
    rdma_function_handle source
  );
    uvm_object cloned_object;
    rdma_function_handle cloned_handle;

    if (source == null)
      `uvm_fatal(check_name, "cannot clone a null function handle")
    cloned_object = source.clone();
    if (cloned_object == null || !$cast(cloned_handle, cloned_object))
      `uvm_fatal(check_name, "function handle clone cast failed")
    return cloned_handle;
  endfunction

  function automatic rdma_function_binding make_active_binding(
    string name,
    longint unsigned function_uid = 64'h0123_4567_89ab_cdef,
    int unsigned global_function_id = 32'h9000_0101,
    int unsigned generation = 32'd7
  );
    rdma_function_binding binding;

    binding = rdma_function_binding::type_id::create(name);
    binding.function_uid = function_uid;
    binding.generation = generation;
    binding.global_function_id = global_function_id;
    binding.rdma_vf_id = 32'h9000_0202;
    binding.pfvf_id = 32'h9000_0303;
    binding.pcie.vf_index = 32'h8000_8080;
    binding.pcie.bdf = '{segment:16'h1001, bus:8'h20, device:5'h03,
                         function_num:3'h5};
    binding.pcie.parent_pf_bdf = '{segment:16'h2002, bus:8'h30,
                                   device:5'h04, function_num:3'h2};
    binding.pcie.bar[0].base.value = 64'h0000_0000_8000_0000;
    binding.pcie.bar[0].size = 64'h4000;
    binding.pcie.bar[0].enabled = 1'b1;
    binding.notify_bar_id = 3'd0;
    binding.notify_base.value = 64'h0000_0000_8000_2000;
    binding.notify_size = 64'h2000;
    binding.state = RDMA_BIND_ACTIVE;
    binding.owner_h = binding.make_handle();
    binding.dma_domain_valid = 1'b1;
    binding.pcie.mse = 1'b1;
    binding.pcie.bme = 1'b1;
    binding.notify_valid = 1'b1;
    binding.notify_ready = 1'b1;
    binding.dmi_valid = 1'b1;
    binding.dmi_ready = 1'b1;
    binding.vft_valid = 1'b1;
    binding.vft_ready = 1'b1;
    return binding;
  endfunction

  function automatic void prepare_mr(rdma_mr mr,
                                     longint unsigned iova_value);
    mr.iova.value = iova_value;
    mr.length = 64'h2000;
    mr.lkey = {mr.local_mr_id[23:0], 8'h5a};
    mr.rkey = mr.lkey;
    mr.access = '{local_write:1'b1, remote_read:1'b1,
                  remote_write:1'b0, memory_window_bind:1'b0,
                  remote_atomic:1'b0};
  endfunction

  task run_phase(uvm_phase phase);
    rdma_resource_manager rm;
    rdma_resource_manager dep_rm;
    rdma_resource_manager teardown_rm;
    rdma_resource_manager identity_rm;
    rdma_resource_manager all_kind_rm;
    rdma_resource_manager generation_rm;
    rdma_resource_manager snapshot_rm;
    rdma_resource_manager rollback_rm;
    rdma_resource_manager function_cycle_rm;
    rdma_resource_manager function_wrap_rm;
    rdma_resource_manager function_release_rm;
    rdma_resource_manager_probe permanent_exhaustion_rm;
    rdma_resource_manager_probe exhaustion_rm;
    rdma_width_probe_manager width_pd_rm;
    rdma_width_probe_manager width_mr_rm;
    rdma_width_probe_manager width_cq_rm;
    rdma_width_probe_manager width_function_rm;
    rdma_width_probe_manager width_free_pd_rm;
    rdma_width_probe_manager width_free_mr_rm;
    rdma_resource_manager lifecycle_rm;
    rdma_width_probe_manager publication_rm;
    rdma_resource_manager pd_commit_rm;
    rdma_width_probe_manager dependency_gate_rm;
    rdma_clone_probe_manager clone_gate_rm;
    rdma_clone_probe_manager schema_rm;
    rdma_clone_probe_manager schema_lookup_rm;
    rdma_clone_probe_manager projection_rm;
    rdma_resource_manager allocated_error_rm;
    rdma_resource_manager recovery_rm;
    rdma_resource_manager_probe privileged_recovery_rm;
    rdma_resource_manager stale_recovery_rm;
    rdma_hmc_allocator hmc;
    rdma_hmc_allocator hmc_exhaustion;
    rdma_hmc_allocator hmc_overflow;
    rdma_function_binding active_binding;
    rdma_function_binding binding_a;
    rdma_function_binding binding_b;
    rdma_function_binding exhaustion_binding;
    rdma_function_binding snapshot_binding;
    rdma_function_binding rollback_binding;
    rdma_function_binding function_cycle_binding;
    rdma_function_binding function_wrap_binding;
    rdma_function_binding function_release_binding;
    rdma_function_binding permanent_exhaustion_binding;
    rdma_function_binding width_binding;
    rdma_function_binding width_binding_copy;
    rdma_function_binding width_function_binding_a;
    rdma_function_binding width_function_binding_b;
    rdma_function_binding width_function_binding_b_copy;
    rdma_function_binding lifecycle_binding;
    rdma_function_binding publication_binding;
    rdma_function_binding pd_commit_binding;
    rdma_function_binding dependency_gate_binding;
    rdma_function_binding clone_gate_binding;
    rdma_function_binding schema_binding;
    rdma_function_binding schema_lookup_binding;
    rdma_function_binding schema_nested_binding;
    rdma_function_binding projection_binding;
    rdma_rm_schema_binding schema_binding_probe;
    rdma_rm_schema_pcie schema_pcie_probe;
    rdma_rm_schema_bar schema_bar_probe;
    rdma_function_binding allocated_error_binding;
    rdma_function_binding recovery_binding;
    rdma_function_binding privileged_recovery_binding;
    rdma_function_binding stale_recovery_binding;
    rdma_function_handle owner_h;
    rdma_function_handle owner_b_h;
    rdma_pd pd;
    rdma_pd pd_first;
    rdma_pd pd_reused;
    rdma_pd pd_b;
    rdma_pd dep_pd;
    rdma_pd teardown_pd;
    rdma_pd exhausted_pd;
    rdma_pd width_pd;
    rdma_pd width_pd_failed;
    rdma_pd width_mr_pd;
    rdma_pd width_free_mr_pd;
    rdma_pd lifecycle_pd;
    rdma_pd publication_pd;
    rdma_pd pd_commit_pd;
    rdma_pd dependency_quiescing_pd;
    rdma_pd dependency_error_pd;
    rdma_pd clone_gate_pd;
    rdma_pd clone_kind_pd_seed;
    rdma_rm_fault_pd clone_kind_pd_authoritative;
    rdma_rm_fault_pd clone_kind_pd_candidate;
    rdma_rm_fault_pd clone_kind_pd_lookup;
    rdma_pd clone_recovery_pd;
    rdma_pd schema_pd;
    rdma_pd schema_recovery_pd;
    rdma_pd projection_pd;
    rdma_pd projection_recovery_pd_a;
    rdma_pd projection_recovery_pd_b;
    rdma_pd allocated_error_pd;
    rdma_pd wrong_stage_pd;
    rdma_pd recovery_pd;
    rdma_pd privileged_recovery_pd;
    rdma_pd privileged_recovery_pd_reused;
    rdma_pd stale_recovery_pd;
    rdma_function all_kind_function;
    rdma_pd all_kind_pd;
    rdma_pd generation_pd;
    rdma_pd rejected_generation_pd;
    rdma_pd next_generation_pd;
    rdma_pd snapshot_pd;
    rdma_pd rollback_pd;
    rdma_mr all_kind_mr;
    rdma_cq all_kind_cq;
    rdma_qp all_kind_qp;
    rdma_srq all_kind_srq;
    rdma_cmq all_kind_cmq;
    rdma_ceq all_kind_ceq;
    rdma_aeq all_kind_aeq;
    rdma_function snapshot_function;
    rdma_function snapshot_function_lookup;
    rdma_function function_a;
    rdma_function function_b;
    rdma_function rejected_function;
    rdma_function function_max;
    rdma_function function_wrapped;
    rdma_function function_release_function;
    rdma_function function_release_lookup;
    rdma_function width_function_a;
    rdma_function width_function_b_failed;
    rdma_function width_function_b_reused;
    rdma_function clone_gate_function;
    rdma_rm_fault_function clone_fault_function;
    rdma_pd function_release_pd;
    rdma_function permanent_exhaustion_function;
    rdma_pd permanent_exhaustion_pd;
    rdma_cmq permanent_exhaustion_cmq;
    rdma_aeq permanent_exhaustion_aeq;
    rdma_mr dep_mr;
    rdma_mr teardown_mr;
    rdma_mr width_mr;
    rdma_mr width_mr_failed;
    rdma_mr width_free_mr;
    rdma_mr lifecycle_mr;
    rdma_mr publication_local_mr;
    rdma_mr publication_global_mr;
    rdma_mr publication_topology_mr;
    rdma_mr publication_commit_mr;
    rdma_mr publication_lookup_mr;
    rdma_mr dependency_blocked_mr;
    rdma_mr clone_seed_mr;
    rdma_rm_fault_mr clone_authoritative_mr;
    rdma_rm_fault_mr clone_candidate_mr;
    rdma_rm_fault_mr clone_wrong_mr;
    rdma_rm_fault_mr clone_drift_mr;
    rdma_rm_schema_mr schema_mr;
    rdma_mr schema_nested_mr;
    rdma_mr schema_seed_mr;
    rdma_rm_stateful_mr schema_registry_mr;
    rdma_mr projection_seed_mr;
    rdma_mr projection_nested_mr;
    rdma_mr projection_lookup_mr;
    rdma_rm_unregistered_mr projection_unregistered_mr;
    rdma_rm_unregistered_mr projection_unregistered_mr_leak;
    rdma_rm_unregistered_mr projection_mismatched_mr;
    rdma_rm_lying_mr projection_lying_mr;
    rdma_rm_lying_mr projection_lying_mr_leak;
    rdma_mr allocated_error_mr;
    rdma_cq cq_pool;
    rdma_cq width_cq;
    rdma_cq width_cq_failed;
    rdma_cq width_cq_reused;
    rdma_cq publication_cq;
    rdma_cq publication_lookup_cq;
    rdma_cq dep_cq;
    rdma_cq teardown_cq;
    rdma_cq clone_kind_cq_seed;
    rdma_rm_fault_cq clone_kind_cq_authoritative;
    rdma_rm_fault_cq clone_kind_cq_candidate;
    rdma_rm_fault_cq clone_kind_cq_lookup;
    rdma_qp dep_qp;
    rdma_qp teardown_qp;
    rdma_qp snapshot_qp;
    rdma_qp snapshot_qp_lookup;
    rdma_qp clone_kind_qp_seed;
    rdma_rm_fault_qp clone_kind_qp_authoritative;
    rdma_rm_fault_qp clone_kind_qp_candidate;
    rdma_rm_fault_qp clone_kind_qp_lookup;
    rdma_srq dep_srq;
    rdma_srq clone_kind_srq_seed;
    rdma_rm_fault_srq clone_kind_srq_authoritative;
    rdma_rm_fault_srq clone_kind_srq_candidate;
    rdma_rm_fault_srq clone_kind_srq_lookup;
    rdma_ceq dep_ceq;
    rdma_ceq teardown_ceq;
    rdma_ceq clone_kind_ceq_seed;
    rdma_rm_fault_ceq clone_kind_ceq_authoritative;
    rdma_rm_fault_ceq clone_kind_ceq_candidate;
    rdma_rm_fault_ceq clone_kind_ceq_lookup;
    rdma_aeq frozen_aeq;
    rdma_aeq width_probe_aeq;
    rdma_aeq rollback_aeq;
    rdma_aeq schema_rejected_aeq;
    rdma_aeq clone_kind_aeq_seed;
    rdma_rm_fault_aeq clone_kind_aeq_authoritative;
    rdma_rm_fault_aeq clone_kind_aeq_candidate;
    rdma_rm_fault_aeq clone_kind_aeq_lookup;
    rdma_cmq clone_kind_cmq_seed;
    rdma_rm_fault_cmq clone_kind_cmq_authoritative;
    rdma_rm_fault_cmq clone_kind_cmq_candidate;
    rdma_rm_fault_cmq clone_kind_cmq_lookup;
    rdma_handle old_h;
    rdma_handle same_generation_old_h;
    rdma_handle frozen_qp_h;
    rdma_handle forged_h;
    rdma_handle generation_old_h;
    rdma_handle snapshot_pd_h;
    rdma_handle snapshot_qp_h;
    rdma_handle rollback_h;
    rdma_handle function_release_h;
    rdma_handle width_pd_h;
    rdma_handle width_cq_h;
    rdma_function_handle width_function_owner_a;
    rdma_handle lifecycle_mr_h;
    rdma_handle stale_recovery_h;
    rdma_function_handle stale_recovery_owner;
    rdma_function_handle privileged_recovery_owner;
    rdma_resource resource;
    rdma_resource second_resource;
    rdma_resource clone_probe_result;
    rdma_resource schema_authoritative;
    rdma_recovery_record recovery_record;
    rdma_recovery_record recovery_lookup;
    rdma_recovery_record recovery_lookup_again;
    rdma_recovery_record malformed_recovery;
    rdma_recovery_record ready_recovery;
    rdma_rm_fault_recovery clone_fault_recovery;
    rdma_rm_schema_recovery schema_recovery;
    rdma_recovery_record schema_nested_recovery;
    rdma_rm_schema_recovery schema_registry_recovery;
    rdma_recovery_record schema_recovery_before;
    rdma_rm_unregistered_recovery projection_unregistered_recovery;
    rdma_rm_unregistered_recovery projection_unregistered_recovery_leak;
    rdma_rm_lying_recovery projection_lying_recovery;
    rdma_rm_lying_recovery projection_lying_recovery_leak;
    rdma_backing_ref clone_backing_ref;
    rdma_backing_ref schema_exact_backing_ref;
    rdma_backing_ref projection_unregistered_backing_ref;
    rdma_backing_ref projection_lying_backing_ref;
    rdma_dma_mapping clone_mapping;
    rdma_dma_mapping schema_mapping;
    rdma_rm_schema_mapping schema_mapping_probe;
    rdma_rm_unregistered_mapping projection_unregistered_mapping;
    rdma_rm_unregistered_mapping projection_unregistered_mapping_leak;
    rdma_rm_lying_mapping projection_lying_mapping;
    rdma_rm_lying_mapping projection_lying_mapping_leak;
    rdma_hmc_ref clone_hmc_ref;
    rdma_rm_schema_hmc_ref schema_hmc_probe;
    rdma_mr clone_lookup_mr;
    rdma_rm_clone_fault_e resource_clone_faults[$];
    string resource_clone_fault_names[$];
    rdma_rm_clone_fault_e recovery_clone_faults[$];
    string recovery_clone_fault_names[$];
    rdma_cmq_ticket clone_ticket;
    rdma_cmq_ticket schema_exact_ticket;
    rdma_cmq_opcode_key schema_opcode;
    rdma_rm_schema_opcode schema_opcode_probe;
    rdma_rm_schema_handle schema_handle;
    rdma_rm_schema_backing_ref schema_backing_ref;
    rdma_rm_schema_ticket schema_ticket;
    rdma_rm_schema_status schema_status;
    rdma_rm_schema_function_handle schema_function_handle;
    rdma_handle mutating_clone_pd_ref;
    rdma_cmq_ticket mutating_clone_ticket_ref;
    longint unsigned mutating_clone_length;
    rdma_hw_presence_e mutating_clone_presence;
    longint unsigned projection_size_before;
    rdma_hw_presence_e projection_presence_before;
    rdma_status s;
    int unsigned leak_count;
    int unsigned pd_local_before_exhaustion;
    int unsigned pd_serial_before_exhaustion;
    int unsigned cmq_local_before_exhaustion;
    int unsigned cmq_serial_before_exhaustion;
    int unsigned serial_before_width_failure;
    int unsigned free_count_before_width_failure;
    int unsigned publication_serial_before;
    int unsigned publication_free_before;
    int unsigned publication_local_before;
    int unsigned publication_global_before;
    int unsigned schema_generation_before;
    rdma_resource all_kind_resources[$];
    rdma_hmc_fvm_addr_t hmc_base;
    rdma_hmc_fvm_addr_t hmc_addr;
    rdma_hmc_fvm_addr_t hmc_addr_two;
    rdma_hmc_fvm_addr_t hmc_other_addr;
    rdma_iova_t equal_iova;
    rdma_dma_mapping untouched_mapping;
    longint unsigned lease_size;
    string hmc_type_name;
    string iova_type_name;
    rdma_bdf_t snapshot_bdf;
    rdma_pcie_identity schema_saved_pcie;

    phase.raise_objection(this);

    // PD and MR local IDs are hardware-width projections.  The inclusive
    // boundary succeeds, while the next fresh ID fails atomically without
    // consuming another incarnation serial or registering another resource.
    width_pd_rm = new("width_pd_rm");
    width_binding = make_active_binding(
      "width_pd_binding", 64'h1d00_0000_0000_0001,
      32'h1d00_0101, 32'd1
    );
    width_pd_rm.set_next_local_id(RDMA_RESOURCE_PD, 16'hffff);
    expect_status("WIDTH_PD_LAST",
                  width_pd_rm.create_pd(width_binding, width_pd),
                  RDMA_SC_OK);
    if (width_pd == null || width_pd.local_pd_id != 16'hffff)
      `uvm_error("WIDTH_PD_LAST",
                 "allocator did not return the last 16-bit PD ID")
    width_pd_h = clone_handle("WIDTH_PD_LAST_H", width_pd.handle);
    serial_before_width_failure =
      width_pd_rm.observed_next_object_serial(RDMA_RESOURCE_PD);
    expect_status("WIDTH_PD_EXHAUSTED",
                  width_pd_rm.create_pd(width_binding, width_pd_failed),
                  RDMA_SC_RESOURCE_EXHAUSTED);
    if (width_pd_failed != null ||
        width_pd_rm.observed_next_object_serial(RDMA_RESOURCE_PD) !=
          serial_before_width_failure)
      `uvm_error("WIDTH_PD_EXHAUSTED",
                 "failed PD allocation consumed output or serial state")
    expect_status("WIDTH_PD_FAILURE_LEAK_COUNT",
                  width_pd_rm.check_leaks(leak_count),
                  RDMA_SC_INVALID_STATE);
    if (leak_count != 1)
      `uvm_error("WIDTH_PD_FAILURE_LEAK_COUNT",
                 $sformatf("expected one live PD, got %0d", leak_count))
    expect_status("WIDTH_PD_RELEASE",
                  width_pd_rm.\release (width_pd.handle), RDMA_SC_OK);
    expect_status("WIDTH_PD_REUSE_LIMIT",
                  width_pd_rm.create_pd(width_binding, width_pd_failed),
                  RDMA_SC_OK);
    if (width_pd_failed == null ||
        width_pd_failed.local_pd_id != 16'hffff ||
        width_pd_failed.handle.same_instance(width_pd_h))
      `uvm_error("WIDTH_PD_REUSE_LIMIT",
                 "valid boundary ID reuse lost incarnation uniqueness")
    expect_status("WIDTH_PD_REUSE_RELEASE",
                  width_pd_rm.\release (width_pd_failed.handle), RDMA_SC_OK);

    width_mr_rm = new("width_mr_rm");
    width_binding = make_active_binding(
      "width_mr_binding", 64'h1d00_0000_0000_0002,
      32'h1d00_0202, 32'd2
    );
    expect_status("WIDTH_MR_PD",
                  width_mr_rm.create_pd(width_binding, width_mr_pd),
                  RDMA_SC_OK);
    width_mr_rm.set_next_local_id(RDMA_RESOURCE_MR, 24'hff_ffff);
    expect_status("WIDTH_MR_LAST",
                  width_mr_rm.create_mr(width_binding, width_mr_pd.handle,
                                         width_mr),
                  RDMA_SC_OK);
    if (width_mr == null || width_mr.local_mr_id != 24'hff_ffff)
      `uvm_error("WIDTH_MR_LAST",
                 "allocator did not return the last 24-bit MR ID")
    serial_before_width_failure =
      width_mr_rm.observed_next_object_serial(RDMA_RESOURCE_MR);
    expect_status("WIDTH_MR_EXHAUSTED",
                  width_mr_rm.create_mr(width_binding, width_mr_pd.handle,
                                         width_mr_failed),
                  RDMA_SC_RESOURCE_EXHAUSTED);
    if (width_mr_failed != null ||
        width_mr_rm.observed_next_object_serial(RDMA_RESOURCE_MR) !=
          serial_before_width_failure)
      `uvm_error("WIDTH_MR_EXHAUSTED",
                 "failed MR allocation consumed output or serial state")
    expect_status("WIDTH_MR_FAILURE_LEAK_COUNT",
                  width_mr_rm.check_leaks(leak_count),
                  RDMA_SC_INVALID_STATE);
    if (leak_count != 2)
      `uvm_error("WIDTH_MR_FAILURE_LEAK_COUNT",
                 $sformatf("expected PD plus MR, got %0d", leak_count))
    expect_status("WIDTH_MR_RELEASE",
                  width_mr_rm.\release (width_mr.handle), RDMA_SC_OK);
    expect_status("WIDTH_MR_PD_RELEASE",
                  width_mr_rm.\release (width_mr_pd.handle), RDMA_SC_OK);

    // The default 32-bit pool also owns its inclusive maximum.  Fresh-pool
    // exhaustion must not wrap the counter, mutate the registry, or consume
    // an incarnation; a released maximum remains reusable from the free list.
    width_cq_rm = new("width_cq_rm");
    width_binding = make_active_binding(
      "width_cq_binding", 64'h1d00_0000_0000_0005,
      32'h1d00_0505, 32'd5
    );
    width_cq_rm.set_next_local_id(RDMA_RESOURCE_CQ, 32'hffff_ffff);
    expect_status("WIDTH_CQ_LAST",
                  width_cq_rm.create_cq(width_binding, null, width_cq),
                  RDMA_SC_OK);
    if (width_cq == null) begin
      `uvm_error("WIDTH_CQ_LAST",
                 "allocator rejected the last 32-bit CQ ID")
    end
    else begin
      if (width_cq.local_cq_id != 32'hffff_ffff)
        `uvm_error("WIDTH_CQ_LAST",
                   "allocator did not return the last 32-bit CQ ID")
      width_cq_h = clone_handle("WIDTH_CQ_LAST_H", width_cq.handle);
      serial_before_width_failure =
        width_cq_rm.observed_next_object_serial(RDMA_RESOURCE_CQ);
      free_count_before_width_failure =
        width_cq_rm.observed_free_local_id_count(RDMA_RESOURCE_CQ);
      expect_status("WIDTH_CQ_EXHAUSTED",
                    width_cq_rm.create_cq(width_binding, null,
                                           width_cq_failed),
                    RDMA_SC_RESOURCE_EXHAUSTED);
      if (width_cq_failed != null ||
          width_cq_rm.observed_next_object_serial(RDMA_RESOURCE_CQ) !=
            serial_before_width_failure ||
          width_cq_rm.observed_free_local_id_count(RDMA_RESOURCE_CQ) !=
            free_count_before_width_failure)
        `uvm_error("WIDTH_CQ_EXHAUSTED",
                   "failed CQ allocation mutated allocator state")
      expect_status("WIDTH_CQ_FAILURE_LIVE",
                    width_cq_rm.lookup(width_cq_h, resource), RDMA_SC_OK);
      if (resource == null || resource.state != RDMA_RESOURCE_ALLOCATED)
        `uvm_error("WIDTH_CQ_FAILURE_LIVE",
                   "failed CQ allocation changed the live registry entry")
      expect_status("WIDTH_CQ_FAILURE_LEAK_COUNT",
                    width_cq_rm.check_leaks(leak_count),
                    RDMA_SC_INVALID_STATE);
      if (leak_count != 1)
        `uvm_error("WIDTH_CQ_FAILURE_LEAK_COUNT",
                   $sformatf("expected one live CQ, got %0d", leak_count))
      expect_status("WIDTH_CQ_RELEASE",
                    width_cq_rm.\release (width_cq_h), RDMA_SC_OK);
      expect_status("WIDTH_CQ_REUSE_LIMIT",
                    width_cq_rm.create_cq(width_binding, null,
                                           width_cq_reused),
                    RDMA_SC_OK);
      if (width_cq_reused == null ||
          width_cq_reused.local_cq_id != 32'hffff_ffff ||
          width_cq_reused.handle.same_instance(width_cq_h))
        `uvm_error("WIDTH_CQ_REUSE_LIMIT",
                   "recycled maximum CQ ID lost incarnation uniqueness")
      expect_status("WIDTH_CQ_REUSE_RELEASE",
                    width_cq_rm.\release (width_cq_reused.handle),
                    RDMA_SC_OK);
      expect_status("WIDTH_CQ_NO_LEAKS",
                    width_cq_rm.check_leaks(leak_count), RDMA_SC_OK);
    end

    // Function IDs share the same inclusive 32-bit boundary.  A failed
    // allocation must not register its caller-owned binding, so a distinct
    // binding object with the same identity can consume a recycled maximum.
    width_function_rm = new("width_function_rm");
    width_function_binding_a = make_active_binding(
      "width_function_binding_a", 64'h1d00_0000_0000_0006,
      32'h1d00_0606, 32'd6
    );
    width_function_binding_b = make_active_binding(
      "width_function_binding_b", 64'h1d00_0000_0000_0007,
      32'h1d00_0707, 32'd7
    );
    width_function_binding_b_copy = make_active_binding(
      "width_function_binding_b_copy", 64'h1d00_0000_0000_0007,
      32'h1d00_0707, 32'd7
    );
    width_function_rm.set_next_local_id(RDMA_RESOURCE_FUNCTION,
                                         32'hffff_ffff);
    expect_status(
      "WIDTH_FUNCTION_LAST",
      width_function_rm.create_function(width_function_binding_a,
                                         width_function_a),
      RDMA_SC_OK
    );
    if (width_function_a == null) begin
      `uvm_error("WIDTH_FUNCTION_LAST",
                 "allocator rejected the last 32-bit Function ID")
    end
    else begin
      if (width_function_a.local_function_id != 32'hffff_ffff)
        `uvm_error("WIDTH_FUNCTION_LAST",
                   "allocator did not return the last 32-bit Function ID")
      width_function_owner_a = clone_function_handle(
        "WIDTH_FUNCTION_OWNER_A", width_function_a.owner
      );
      free_count_before_width_failure =
        width_function_rm.observed_free_local_id_count(
          RDMA_RESOURCE_FUNCTION
        );
      expect_status(
        "WIDTH_FUNCTION_EXHAUSTED",
        width_function_rm.create_function(width_function_binding_b,
                                           width_function_b_failed),
        RDMA_SC_RESOURCE_EXHAUSTED
      );
      if (width_function_b_failed != null ||
          width_function_rm.observed_free_local_id_count(
            RDMA_RESOURCE_FUNCTION
          ) != free_count_before_width_failure)
        `uvm_error("WIDTH_FUNCTION_EXHAUSTED",
                   "failed Function allocation mutated allocator state")
      expect_status("WIDTH_FUNCTION_FAILURE_LIVE",
                    width_function_rm.lookup(width_function_a.handle,
                                             resource),
                    RDMA_SC_OK);
      expect_status("WIDTH_FUNCTION_FAILURE_LEAK_COUNT",
                    width_function_rm.check_leaks(leak_count),
                    RDMA_SC_INVALID_STATE);
      if (leak_count != 1)
        `uvm_error("WIDTH_FUNCTION_FAILURE_LEAK_COUNT",
                   $sformatf("expected one live Function, got %0d",
                             leak_count))
      expect_status(
        "WIDTH_FUNCTION_RELEASE_A",
        width_function_rm.release_function(width_function_owner_a),
        RDMA_SC_OK
      );
      expect_status(
        "WIDTH_FUNCTION_REUSE_LIMIT",
        width_function_rm.create_function(width_function_binding_b_copy,
                                           width_function_b_reused),
        RDMA_SC_OK
      );
      if (width_function_b_reused == null ||
          width_function_b_reused.local_function_id != 32'hffff_ffff ||
          width_function_b_reused.handle.same_instance(
            width_function_a.handle
          ))
        `uvm_error("WIDTH_FUNCTION_REUSE_LIMIT",
                   "recycled maximum Function ID or binding was invalid")
      expect_status(
        "WIDTH_FUNCTION_RELEASE_B",
        width_function_rm.release_function(width_function_b_reused.owner),
        RDMA_SC_OK
      );
      expect_status("WIDTH_FUNCTION_NO_LEAKS",
                    width_function_rm.check_leaks(leak_count), RDMA_SC_OK);
    end

    // An invalid free-list head is neither returned nor silently discarded.
    // The first failed allocation also must not install a binding source.
    width_free_pd_rm = new("width_free_pd_rm");
    width_binding = make_active_binding(
      "width_free_pd_binding", 64'h1d00_0000_0000_0003,
      32'h1d00_0303, 32'd3
    );
    width_binding_copy = make_active_binding(
      "width_free_pd_binding_copy", 64'h1d00_0000_0000_0003,
      32'h1d00_0303, 32'd3
    );
    width_free_pd_rm.inject_free_local_id(RDMA_RESOURCE_PD, 32'h0001_0000);
    free_count_before_width_failure =
      width_free_pd_rm.observed_free_local_id_count(RDMA_RESOURCE_PD);
    serial_before_width_failure =
      width_free_pd_rm.observed_next_object_serial(RDMA_RESOURCE_PD);
    expect_status("WIDTH_PD_BAD_FREE",
                  width_free_pd_rm.create_pd(width_binding, width_pd_failed),
                  RDMA_SC_RESOURCE_EXHAUSTED);
    if (width_pd_failed != null ||
        width_free_pd_rm.observed_free_local_id_count(RDMA_RESOURCE_PD) !=
          free_count_before_width_failure ||
        width_free_pd_rm.observed_next_object_serial(RDMA_RESOURCE_PD) !=
          serial_before_width_failure)
      `uvm_error("WIDTH_PD_BAD_FREE",
                 "invalid free-list PD ID mutated allocator state")
    expect_status("WIDTH_PD_BAD_FREE_NO_LEAKS",
                  width_free_pd_rm.check_leaks(leak_count), RDMA_SC_OK);
    expect_status("WIDTH_PD_BAD_FREE_NO_BINDING",
                  width_free_pd_rm.create_aeq(width_binding_copy,
                                               width_probe_aeq),
                  RDMA_SC_OK);
    expect_status("WIDTH_PD_BAD_FREE_AEQ_RELEASE",
                  width_free_pd_rm.\release (width_probe_aeq.handle),
                  RDMA_SC_OK);

    width_free_mr_rm = new("width_free_mr_rm");
    width_binding = make_active_binding(
      "width_free_mr_binding", 64'h1d00_0000_0000_0004,
      32'h1d00_0404, 32'd4
    );
    expect_status("WIDTH_BAD_FREE_MR_PD",
                  width_free_mr_rm.create_pd(width_binding,
                                              width_free_mr_pd),
                  RDMA_SC_OK);
    width_free_mr_rm.inject_free_local_id(RDMA_RESOURCE_MR,
                                           32'h0100_0000);
    free_count_before_width_failure =
      width_free_mr_rm.observed_free_local_id_count(RDMA_RESOURCE_MR);
    serial_before_width_failure =
      width_free_mr_rm.observed_next_object_serial(RDMA_RESOURCE_MR);
    expect_status("WIDTH_MR_BAD_FREE",
                  width_free_mr_rm.create_mr(width_binding,
                                              width_free_mr_pd.handle,
                                              width_free_mr),
                  RDMA_SC_RESOURCE_EXHAUSTED);
    if (width_free_mr != null ||
        width_free_mr_rm.observed_free_local_id_count(RDMA_RESOURCE_MR) !=
          free_count_before_width_failure ||
        width_free_mr_rm.observed_next_object_serial(RDMA_RESOURCE_MR) !=
          serial_before_width_failure)
      `uvm_error("WIDTH_MR_BAD_FREE",
                 "invalid free-list MR ID mutated allocator state")
    expect_status("WIDTH_BAD_FREE_MR_PD_RELEASE",
                  width_free_mr_rm.\release (width_free_mr_pd.handle),
                  RDMA_SC_OK);

    // ERROR snapshots require the key authority handed off by staging.  A raw
    // zero-ID ALLOCATED MR happens to validate after forcing ERROR, but must be
    // rejected atomically until that incarnation is populated and staged.
    allocated_error_rm = rdma_resource_manager::type_id::create(
      "allocated_error_rm"
    );
    allocated_error_binding = make_active_binding(
      "allocated_error_binding", 64'he220_0000_0000_0004,
      32'he220_0404, 32'd14
    );
    expect_status("ALLOC_ERROR_CREATE_PD",
                  allocated_error_rm.create_pd(allocated_error_binding,
                                                allocated_error_pd),
                  RDMA_SC_OK);
    expect_status("ALLOC_ERROR_CREATE_MR",
                  allocated_error_rm.create_mr(allocated_error_binding,
                                                allocated_error_pd.handle,
                                                allocated_error_mr),
                  RDMA_SC_OK);
    if (allocated_error_mr.local_mr_id != 0)
      `uvm_error("ALLOC_ERROR_CREATE_MR",
                 "test requires the first, zero-ID unprogrammed MR")
    expect_status("ALLOC_ERROR_FREEZE_RAW",
                  allocated_error_rm.freeze(allocated_error_mr.handle),
                  RDMA_SC_INVALID_STATE);
    expect_status("ALLOC_ERROR_FREEZE_RAW_LOOKUP",
                  allocated_error_rm.lookup(allocated_error_mr.handle,
                                            resource),
                  RDMA_SC_OK);
    if (resource == null || resource.state != RDMA_RESOURCE_ALLOCATED)
      `uvm_error("ALLOC_ERROR_FREEZE_RAW_LOOKUP",
                 "raw freeze attempt changed authoritative MR state")
    expect_status("ALLOC_ERROR_STAGE_RAW",
                  allocated_error_rm.stage_allocated(allocated_error_mr),
                  RDMA_SC_INVALID_ARGUMENT);
    expect_status("ALLOC_ERROR_STAGE_RAW_LOOKUP",
                  allocated_error_rm.lookup(allocated_error_mr.handle,
                                            resource),
                  RDMA_SC_OK);
    if (resource == null || resource.state != RDMA_RESOURCE_ALLOCATED)
      `uvm_error("ALLOC_ERROR_STAGE_RAW_LOOKUP",
                 "raw stage attempt changed authoritative MR state")
    expect_status("ALLOC_ERROR_STAGE_RAW_NO_RECOVERY",
                  allocated_error_rm.lookup_recovery(
                    allocated_error_mr.handle, recovery_lookup
                  ),
                  RDMA_SC_INVALID_STATE);
    expect_status("ALLOC_ERROR_PD_RESERVED_BUSY",
                  allocated_error_rm.release_reserved(
                    allocated_error_pd.handle
                  ), RDMA_SC_RESOURCE_BUSY);
    expect_status("ALLOC_ERROR_PD_RESERVED_PRESERVED",
                  allocated_error_rm.lookup(allocated_error_pd.handle,
                                            resource),
                  RDMA_SC_OK);
    if (resource == null || resource.state != RDMA_RESOURCE_ALLOCATED)
      `uvm_error("ALLOC_ERROR_PD_RESERVED_PRESERVED",
                 "busy reservation rollback changed PD state")
    recovery_record = rdma_recovery_record::type_id::create(
      "allocated_error_recovery"
    );
    recovery_record.resource_h = clone_handle(
      "ALLOC_ERROR_H", allocated_error_mr.handle
    );
    recovery_record.hardware_presence = RDMA_HW_PRESENCE_ABSENT;
    recovery_record.primary_status = rdma_status::make(
      RDMA_SC_RESET_CANCELLED, "programming aborted before key commit"
    );
    expect_status("ALLOC_ERROR_MARK_RAW",
                  allocated_error_rm.mark_error(allocated_error_mr.handle,
                                                recovery_record),
                  RDMA_SC_INVALID_STATE);
    expect_status("ALLOC_ERROR_RAW_LOOKUP",
                  allocated_error_rm.lookup(allocated_error_mr.handle,
                                            resource),
                  RDMA_SC_OK);
    if (resource == null || resource.state != RDMA_RESOURCE_ALLOCATED)
      `uvm_error("ALLOC_ERROR_RAW_LOOKUP",
                 "rejected raw MR recovery changed registry state")
    expect_status("ALLOC_ERROR_RAW_NO_RECOVERY",
                  allocated_error_rm.lookup_recovery(
                    allocated_error_mr.handle, recovery_lookup
                  ), RDMA_SC_INVALID_STATE);
    allocated_error_mr.iova.value = 64'h2000_0000;
    allocated_error_mr.length = 64'h4000;
    allocated_error_mr.lkey = {
      allocated_error_mr.local_mr_id[23:0], 8'ha5
    };
    allocated_error_mr.rkey = allocated_error_mr.lkey;
    allocated_error_mr.access = '{local_write:1'b1, remote_read:1'b1,
                                  remote_write:1'b0,
                                  memory_window_bind:1'b0,
                                  remote_atomic:1'b0};
    expect_status("ALLOC_ERROR_STAGE",
                  allocated_error_rm.stage_allocated(allocated_error_mr),
                  RDMA_SC_OK);
    expect_status("ALLOC_ERROR_MARK_STAGED",
                  allocated_error_rm.mark_error(allocated_error_mr.handle,
                                                recovery_record),
                  RDMA_SC_OK);
    expect_status("ALLOC_ERROR_STAGED_LOOKUP",
                  allocated_error_rm.lookup(allocated_error_mr.handle,
                                            resource),
                  RDMA_SC_OK);
    if (resource == null || resource.state != RDMA_RESOURCE_ERROR)
      `uvm_error("ALLOC_ERROR_STAGED_LOOKUP",
                 "staged exact incarnation did not enter ERROR")
    expect_status("ALLOC_ERROR_FUNCTION_RELEASE",
                  allocated_error_rm.release_function(
                    allocated_error_binding.make_handle()
                  ), RDMA_SC_OK);
    expect_status("ALLOC_ERROR_NO_LEAKS",
                  allocated_error_rm.check_leaks(leak_count), RDMA_SC_OK);

    // Publication may update programmable context, but allocator identity and
    // dependency topology remain manager-owned across staging and commit.
    publication_rm = new("publication_rm");
    publication_binding = make_active_binding(
      "publication_binding", 64'h1c1f_1000_0000_0001,
      32'h1c1f_1101, 32'd18
    );
    expect_status("PUBLICATION_CREATE_PD",
                  publication_rm.create_pd(publication_binding,
                                            publication_pd),
                  RDMA_SC_OK);
    expect_status("PUBLICATION_CREATE_LOCAL_MR",
                  publication_rm.create_mr(publication_binding,
                                            publication_pd.handle,
                                            publication_local_mr),
                  RDMA_SC_OK);
    prepare_mr(publication_local_mr, 64'h3100_0000);
    publication_local_before = publication_local_mr.local_mr_id;
    publication_serial_before =
      publication_rm.observed_next_object_serial(RDMA_RESOURCE_MR);
    publication_free_before =
      publication_rm.observed_free_local_id_count(RDMA_RESOURCE_MR);
    publication_local_mr.local_mr_id++;
    publication_local_mr.lkey = {
      publication_local_mr.local_mr_id[23:0], 8'h5a
    };
    publication_local_mr.rkey = publication_local_mr.lkey;
    expect_status("PUBLICATION_REJECT_LOCAL_ID",
                  publication_rm.stage_allocated(publication_local_mr),
                  RDMA_SC_INVALID_ARGUMENT);
    expect_status("PUBLICATION_LOCAL_ID_REGISTRY",
                  publication_rm.lookup(publication_local_mr.handle,
                                         resource),
                  RDMA_SC_OK);
    if (resource == null || !$cast(publication_lookup_mr, resource) ||
        publication_lookup_mr.local_mr_id != publication_local_before)
      `uvm_error("PUBLICATION_LOCAL_ID_REGISTRY",
                 "rejected local-ID mutation changed authoritative MR")

    expect_status("PUBLICATION_CREATE_GLOBAL_MR",
                  publication_rm.create_mr(publication_binding,
                                            publication_pd.handle,
                                            publication_global_mr),
                  RDMA_SC_OK);
    prepare_mr(publication_global_mr, 64'h3200_0000);
    publication_global_before = publication_global_mr.global_mr_id;
    publication_global_mr.global_mr_id++;
    expect_status("PUBLICATION_REJECT_GLOBAL_ID",
                  publication_rm.stage_allocated(publication_global_mr),
                  RDMA_SC_INVALID_ARGUMENT);
    expect_status("PUBLICATION_GLOBAL_ID_REGISTRY",
                  publication_rm.lookup(publication_global_mr.handle,
                                         resource),
                  RDMA_SC_OK);
    if (resource == null || !$cast(publication_lookup_mr, resource) ||
        publication_lookup_mr.global_mr_id != publication_global_before)
      `uvm_error("PUBLICATION_GLOBAL_ID_REGISTRY",
                 "rejected global-ID mutation changed authoritative MR")

    expect_status("PUBLICATION_CREATE_TOPOLOGY_MR",
                  publication_rm.create_mr(publication_binding,
                                            publication_pd.handle,
                                            publication_topology_mr),
                  RDMA_SC_OK);
    prepare_mr(publication_topology_mr, 64'h3300_0000);
    publication_topology_mr.pd_h = null;
    publication_topology_mr.dependencies.delete();
    expect_status("PUBLICATION_REJECT_TOPOLOGY",
                  publication_rm.stage_allocated(publication_topology_mr),
                  RDMA_SC_INVALID_ARGUMENT);
    expect_status("PUBLICATION_PD_STILL_BUSY",
                  publication_rm.release_reserved(publication_pd.handle),
                  RDMA_SC_RESOURCE_BUSY);

    expect_status("PUBLICATION_CREATE_CQ",
                  publication_rm.create_cq(publication_binding, null,
                                            publication_cq),
                  RDMA_SC_OK);
    publication_cq.depth = 8;
    publication_local_before = publication_cq.local_cq_id;
    publication_global_before = publication_cq.global_cq_id;
    publication_cq.local_cq_id++;
    publication_cq.global_cq_id++;
    expect_status("PUBLICATION_REJECT_CQ_IDS",
                  publication_rm.stage_allocated(publication_cq),
                  RDMA_SC_INVALID_ARGUMENT);
    expect_status("PUBLICATION_CQ_REGISTRY",
                  publication_rm.lookup(publication_cq.handle, resource),
                  RDMA_SC_OK);
    if (resource == null || !$cast(publication_lookup_cq, resource) ||
        publication_lookup_cq.local_cq_id != publication_local_before ||
        publication_lookup_cq.global_cq_id != publication_global_before)
      `uvm_error("PUBLICATION_CQ_REGISTRY",
                 "rejected CQ identity mutation changed registry")

    expect_status("PUBLICATION_CREATE_COMMIT_MR",
                  publication_rm.create_mr(publication_binding,
                                            publication_pd.handle,
                                            publication_commit_mr),
                  RDMA_SC_OK);
    prepare_mr(publication_commit_mr, 64'h3400_0000);
    expect_status("PUBLICATION_STAGE_COMMIT_MR",
                  publication_rm.stage_allocated(publication_commit_mr),
                  RDMA_SC_OK);
    publication_local_before = publication_commit_mr.local_mr_id;
    publication_commit_mr.local_mr_id++;
    publication_commit_mr.lkey = {
      publication_commit_mr.local_mr_id[23:0], 8'h5a
    };
    publication_commit_mr.rkey = publication_commit_mr.lkey;
    expect_status("PUBLICATION_REJECT_COMMIT_ID",
                  publication_rm.commit_programmed(publication_commit_mr),
                  RDMA_SC_INVALID_ARGUMENT);
    expect_status("PUBLICATION_COMMIT_REGISTRY",
                  publication_rm.lookup(publication_commit_mr.handle,
                                         resource),
                  RDMA_SC_OK);
    if (resource == null || !$cast(publication_lookup_mr, resource) ||
        publication_lookup_mr.state != RDMA_RESOURCE_ALLOCATED ||
        publication_lookup_mr.local_mr_id != publication_local_before)
      `uvm_error("PUBLICATION_COMMIT_REGISTRY",
                 "rejected commit changed staged authoritative MR")
    if (publication_rm.observed_next_object_serial(RDMA_RESOURCE_MR) !=
          publication_serial_before + 3 ||
        publication_rm.observed_free_local_id_count(RDMA_RESOURCE_MR) !=
          publication_free_before)
      `uvm_error("PUBLICATION_ALLOCATOR_ATOMIC",
                 "publication attacks changed allocator bookkeeping")
    expect_status("PUBLICATION_RELEASE_FUNCTION",
                  publication_rm.release_function(
                    publication_binding.make_handle()
                  ),
                  RDMA_SC_OK);
    expect_status("PUBLICATION_NO_LEAKS",
                  publication_rm.check_leaks(leak_count), RDMA_SC_OK);

    // PD bypasses hardware programming and transitions directly from
    // ALLOCATED to ACTIVE, even if a caller previously staged its snapshot.
    pd_commit_rm = rdma_resource_manager::type_id::create("pd_commit_rm");
    pd_commit_binding = make_active_binding(
      "pd_commit_binding", 64'h1c1f_2000_0000_0001,
      32'h1c1f_2201, 32'd19
    );
    expect_status("PD_COMMIT_CREATE",
                  pd_commit_rm.create_pd(pd_commit_binding, pd_commit_pd),
                  RDMA_SC_OK);
    expect_status("PD_COMMIT_FREEZE_REJECT",
                  pd_commit_rm.freeze(pd_commit_pd.handle),
                  RDMA_SC_INVALID_STATE);
    expect_status("PD_COMMIT_ORDINARY_REJECT",
                  pd_commit_rm.commit_programmed(pd_commit_pd),
                  RDMA_SC_INVALID_STATE);
    expect_status("PD_COMMIT_STAGE",
                  pd_commit_rm.stage_allocated(pd_commit_pd), RDMA_SC_OK);
    expect_status("PD_COMMIT_STAGED_FREEZE_REJECT",
                  pd_commit_rm.freeze(pd_commit_pd.handle),
                  RDMA_SC_INVALID_STATE);
    expect_status("PD_COMMIT_STAGED_REJECT",
                  pd_commit_rm.commit_programmed(pd_commit_pd),
                  RDMA_SC_INVALID_STATE);
    expect_status("PD_COMMIT_STATE_PRESERVED",
                  pd_commit_rm.lookup(pd_commit_pd.handle, resource),
                  RDMA_SC_OK);
    if (resource == null || resource.state != RDMA_RESOURCE_ALLOCATED)
      `uvm_error("PD_COMMIT_STATE_PRESERVED",
                 "PD commit attempt changed ALLOCATED state")
    expect_status("PD_COMMIT_ACTIVATE",
                  pd_commit_rm.activate(pd_commit_pd.handle), RDMA_SC_OK);
    expect_status("PD_COMMIT_RELEASE_FUNCTION",
                  pd_commit_rm.release_function(
                    pd_commit_binding.make_handle()
                  ),
                  RDMA_SC_OK);
    expect_status("PD_COMMIT_NO_LEAKS",
                  pd_commit_rm.check_leaks(leak_count), RDMA_SC_OK);

    // Dependencies that are closing or failed cannot admit new children.
    dependency_gate_rm = new("dependency_gate_rm");
    dependency_gate_binding = make_active_binding(
      "dependency_gate_binding", 64'h1c1f_3000_0000_0001,
      32'h1c1f_3301, 32'd20
    );
    expect_status("DEPENDENCY_QUIESCING_CREATE_PD",
                  dependency_gate_rm.create_pd(dependency_gate_binding,
                                                dependency_quiescing_pd),
                  RDMA_SC_OK);
    expect_status("DEPENDENCY_QUIESCING_ACTIVATE_PD",
                  dependency_gate_rm.activate(dependency_quiescing_pd.handle),
                  RDMA_SC_OK);
    expect_status("DEPENDENCY_QUIESCING_BEGIN",
                  dependency_gate_rm.begin_quiesce(
                    dependency_quiescing_pd.handle
                  ),
                  RDMA_SC_OK);
    expect_status("DEPENDENCY_ERROR_CREATE_PD",
                  dependency_gate_rm.create_pd(dependency_gate_binding,
                                                dependency_error_pd),
                  RDMA_SC_OK);
    recovery_record = rdma_recovery_record::type_id::create(
      "dependency_error_recovery"
    );
    recovery_record.resource_h = clone_handle(
      "DEPENDENCY_ERROR_H", dependency_error_pd.handle
    );
    recovery_record.hardware_presence = RDMA_HW_PRESENCE_ABSENT;
    recovery_record.primary_status = rdma_status::make(
      RDMA_SC_RESET_CANCELLED, "dependency failed before child creation"
    );
    expect_status("DEPENDENCY_ERROR_MARK",
                  dependency_gate_rm.mark_error(dependency_error_pd.handle,
                                                recovery_record),
                  RDMA_SC_OK);
    publication_serial_before =
      dependency_gate_rm.observed_next_object_serial(RDMA_RESOURCE_MR);
    publication_free_before =
      dependency_gate_rm.observed_free_local_id_count(RDMA_RESOURCE_MR);
    expect_status("DEPENDENCY_QUIESCING_REJECT_CHILD",
                  dependency_gate_rm.create_mr(
                    dependency_gate_binding, dependency_quiescing_pd.handle,
                    dependency_blocked_mr
                  ),
                  RDMA_SC_INVALID_STATE);
    if (dependency_blocked_mr != null ||
        dependency_gate_rm.observed_next_object_serial(RDMA_RESOURCE_MR) !=
          publication_serial_before ||
        dependency_gate_rm.observed_free_local_id_count(RDMA_RESOURCE_MR) !=
          publication_free_before)
      `uvm_error("DEPENDENCY_QUIESCING_ATOMIC",
                 "QUIESCING dependency consumed MR allocator state")
    expect_status("DEPENDENCY_ERROR_REJECT_CHILD",
                  dependency_gate_rm.create_mr(
                    dependency_gate_binding, dependency_error_pd.handle,
                    dependency_blocked_mr
                  ),
                  RDMA_SC_INVALID_STATE);
    if (dependency_blocked_mr != null ||
        dependency_gate_rm.observed_next_object_serial(RDMA_RESOURCE_MR) !=
          publication_serial_before ||
        dependency_gate_rm.observed_free_local_id_count(RDMA_RESOURCE_MR) !=
          publication_free_before)
      `uvm_error("DEPENDENCY_ERROR_ATOMIC",
                 "ERROR dependency consumed MR allocator state")
    expect_status("DEPENDENCY_GATE_LEAK_COUNT",
                  dependency_gate_rm.check_leaks(leak_count),
                  RDMA_SC_INVALID_STATE);
    if (leak_count != 2)
      `uvm_error("DEPENDENCY_GATE_LEAK_COUNT",
                 $sformatf("rejected child creation left %0d resources",
                           leak_count))
    expect_status("DEPENDENCY_GATE_RELEASE_FUNCTION",
                  dependency_gate_rm.release_function(
                    dependency_gate_binding.make_handle()
                  ),
                  RDMA_SC_OK);
    expect_status("DEPENDENCY_GATE_NO_LEAKS",
                  dependency_gate_rm.check_leaks(leak_count), RDMA_SC_OK);

    // Public values are carriers, not trusted UVM implementations.  Compatible
    // subclasses are projected field-by-field into built-in manager storage;
    // inherited or forged wrapper identity must never trigger a virtual hook.
    void'(rdma_rm_lying_mr::get_type());
    void'(rdma_rm_lying_mapping::get_type());
    void'(rdma_rm_lying_recovery::get_type());
    projection_rm = new("projection_rm");
    projection_binding = make_active_binding(
      "projection_binding", 64'h1c1f_5000_0000_0001,
      32'h1c1f_5501, 32'd23
    );
    expect_status("PROJECTION_CREATE_PD",
                  projection_rm.create_pd(projection_binding, projection_pd),
                  RDMA_SC_OK);
    expect_status("PROJECTION_CREATE_MR",
                  projection_rm.create_mr(projection_binding,
                                          projection_pd.handle,
                                          projection_seed_mr),
                  RDMA_SC_OK);
    prepare_mr(projection_seed_mr, 64'h6100_0000);

    projection_unregistered_mr = new("projection_unregistered_mr");
    projection_unregistered_mr.copy(projection_seed_mr);
    projection_unregistered_mr.extra_scalar = 32'hc011_aa01;
    projection_unregistered_mr.extra_child = clone_handle(
      "PROJECTION_UNREGISTERED_MR_EXTRA", projection_seed_mr.pd_h
    );
    projection_unregistered_mr.clone_calls = 0;
    mutating_clone_length = projection_unregistered_mr.length;
    expect_status("PROJECTION_UNREGISTERED_MR_STAGE",
                  projection_rm.stage_allocated(projection_unregistered_mr),
                  RDMA_SC_OK);
    if (projection_unregistered_mr.clone_calls != 0 ||
        projection_unregistered_mr.length != mutating_clone_length ||
        projection_unregistered_mr.extra_scalar != 32'hc011_aa01 ||
        projection_unregistered_mr.extra_child == null)
      `uvm_error("PROJECTION_UNREGISTERED_MR_SOURCE",
                 "unregistered MR virtual hook ran or source fields changed")
    expect_status("PROJECTION_UNREGISTERED_MR_LOOKUP",
                  projection_rm.lookup(projection_seed_mr.handle, resource),
                  RDMA_SC_OK);
    projection_unregistered_mr_leak = null;
    projection_lookup_mr = null;
    if (resource == null ||
        !$cast(projection_lookup_mr, resource) ||
        $cast(projection_unregistered_mr_leak, resource) ||
        resource.handle == projection_unregistered_mr.handle ||
        resource.owner == projection_unregistered_mr.owner ||
        projection_lookup_mr.pd_h ==
          projection_unregistered_mr.extra_child)
      `uvm_error("PROJECTION_UNREGISTERED_MR_STORAGE",
                 "unregistered MR, root handle, or extension child escaped projection")
    expect_status("PROJECTION_UNREGISTERED_MR_COMMIT",
                  projection_rm.commit_programmed(projection_unregistered_mr),
                  RDMA_SC_OK);
    expect_status("PROJECTION_UNREGISTERED_MR_ACTIVATE",
                  projection_rm.activate(projection_seed_mr.handle),
                  RDMA_SC_OK);
    if (projection_unregistered_mr.clone_calls != 0 ||
        projection_unregistered_mr.length != mutating_clone_length)
      `uvm_error("PROJECTION_UNREGISTERED_MR_LIFECYCLE",
                 "MR lifecycle dispatched through the public carrier")

    // A registered subtype can lie about get_object_type().  Inject it into the
    // registry to cover later lookup/quiesce/restore paths as well as ingress.
    projection_lying_mr = new("projection_lying_mr");
    projection_lying_mr.copy(projection_unregistered_mr);
    projection_lying_mr.state = RDMA_RESOURCE_ACTIVE;
    projection_lying_mr.extra_scalar = 32'hc011_aa02;
    projection_lying_mr.extra_child = clone_handle(
      "PROJECTION_LYING_MR_EXTRA", projection_seed_mr.pd_h
    );
    projection_lying_mr.clone_calls = 0;
    mutating_clone_length = projection_lying_mr.length;
    projection_rm.replace_authoritative(projection_lying_mr);
    expect_status("PROJECTION_LYING_MR_LOOKUP",
                  projection_rm.lookup(projection_lying_mr.handle, resource),
                  RDMA_SC_OK);
    projection_lying_mr_leak = null;
    projection_lookup_mr = null;
    if (projection_lying_mr.clone_calls != 0 ||
        projection_lying_mr.length != mutating_clone_length ||
        projection_lying_mr.extra_scalar != 32'hc011_aa02 ||
        !$cast(projection_lookup_mr, resource) ||
        $cast(projection_lying_mr_leak, resource) ||
        projection_lookup_mr.pd_h == projection_lying_mr.extra_child)
      `uvm_error("PROJECTION_LYING_MR_LOOKUP_STORAGE",
                 "lying MR hook ran, source changed, subtype escaped, or extension child leaked")
    expect_status("PROJECTION_LYING_MR_QUIESCE",
                  projection_rm.begin_quiesce(projection_lying_mr.handle),
                  RDMA_SC_OK);
    projection_lying_mr_leak = null;
    if (projection_lying_mr.clone_calls != 0 ||
        projection_lying_mr.state != RDMA_RESOURCE_ACTIVE ||
        $cast(projection_lying_mr_leak,
              projection_rm.observed_resource_probe(
                projection_lying_mr.handle
              )) ||
        projection_rm.observed_resource_probe(
          projection_lying_mr.handle
        ).state != RDMA_RESOURCE_QUIESCING)
      `uvm_error("PROJECTION_LYING_MR_QUIESCE_STORAGE",
                 "quiesce retained or mutated a lying registry carrier")
    expect_status("PROJECTION_LYING_MR_RESTORE",
                  projection_rm.restore_active(projection_lying_mr.handle),
                  RDMA_SC_OK);
    if (projection_lying_mr.clone_calls != 0 ||
        projection_lying_mr.state != RDMA_RESOURCE_ACTIVE)
      `uvm_error("PROJECTION_LYING_MR_RESTORE_SOURCE",
                 "restore dispatched through the lying registry carrier")

    // handle.kind selects the built-in projection class.  A carrier whose
    // declared resource class disagrees must fail with a null output and must
    // not disturb the already-normalized registry entry.
    projection_mismatched_mr = new("projection_mismatched_mr");
    projection_mismatched_mr.copy(projection_seed_mr);
    projection_mismatched_mr.handle.kind = RDMA_RESOURCE_PD;
    resource = projection_seed_mr;
    expect_status(
      "PROJECTION_KIND_CLASS_MISMATCH",
      projection_rm.probe_public_resource_projection(
        projection_mismatched_mr, resource
      ), RDMA_SC_INVALID_ARGUMENT
    );
    if (resource != null || projection_mismatched_mr.clone_calls != 0)
      `uvm_error("PROJECTION_KIND_CLASS_MISMATCH_OUTPUT",
                 "kind/class mismatch retained output or invoked a hook")
    expect_status("PROJECTION_KIND_CLASS_MISMATCH_ROLLBACK",
                  projection_rm.lookup(projection_seed_mr.handle, resource),
                  RDMA_SC_OK);
    if (resource == null || resource.state != RDMA_RESOURCE_ACTIVE)
      `uvm_error("PROJECTION_KIND_CLASS_MISMATCH_ROLLBACK",
                 "failed projection changed the authoritative registry")

    // Nested inherited-wrapper and lying-wrapper mappings are independently
    // projected; extension children cannot enter the registry graph.
    expect_status("PROJECTION_CREATE_NESTED_MR",
                  projection_rm.create_mr(projection_binding,
                                          projection_pd.handle,
                                          projection_nested_mr),
                  RDMA_SC_OK);
    prepare_mr(projection_nested_mr, 64'h6200_0000);
    projection_unregistered_mapping =
      new("projection_unregistered_mapping");
    projection_unregistered_mapping.function_h = clone_function_handle(
      "PROJECTION_UNREGISTERED_MAPPING_FUNCTION",
      projection_binding.make_handle()
    );
    projection_unregistered_mapping.requester_bdf =
      projection_binding.pcie.bdf;
    projection_unregistered_mapping.backing_addr.value = 64'h6300_0000;
    projection_unregistered_mapping.iova.value = 64'h6400_0000;
    projection_unregistered_mapping.size = 64'h1000;
    projection_unregistered_mapping.direction = RDMA_DMA_BIDIRECTIONAL;
    projection_unregistered_mapping.permissions =
      '{device_read:1'b1, device_write:1'b1, atomic:1'b0};
    projection_unregistered_mapping.state = RDMA_MAPPING_ACTIVE;
    projection_unregistered_mapping.owner_h = clone_handle(
      "PROJECTION_UNREGISTERED_MAPPING_OWNER", projection_nested_mr.handle
    );
    projection_unregistered_mapping.extra_child = clone_handle(
      "PROJECTION_UNREGISTERED_MAPPING_EXTRA", projection_nested_mr.pd_h
    );
    projection_unregistered_mapping.clone_calls = 0;
    projection_unregistered_backing_ref =
      new("projection_unregistered_backing_ref");
    projection_unregistered_backing_ref.mapping =
      projection_unregistered_mapping;
    projection_unregistered_backing_ref.ownership =
      RDMA_OWNERSHIP_CONTROL_PLANE;
    projection_nested_mr.backing_refs.push_back(
      projection_unregistered_backing_ref
    );

    projection_lying_mapping = new("projection_lying_mapping");
    projection_lying_mapping.function_h = clone_function_handle(
      "PROJECTION_LYING_MAPPING_FUNCTION", projection_binding.make_handle()
    );
    projection_lying_mapping.requester_bdf = projection_binding.pcie.bdf;
    projection_lying_mapping.backing_addr.value = 64'h6500_0000;
    projection_lying_mapping.iova.value = 64'h6600_0000;
    projection_lying_mapping.size = 64'h1000;
    projection_lying_mapping.direction = RDMA_DMA_BIDIRECTIONAL;
    projection_lying_mapping.permissions =
      '{device_read:1'b1, device_write:1'b1, atomic:1'b0};
    projection_lying_mapping.state = RDMA_MAPPING_ACTIVE;
    projection_lying_mapping.owner_h = clone_handle(
      "PROJECTION_LYING_MAPPING_OWNER", projection_nested_mr.handle
    );
    projection_lying_mapping.extra_child = clone_handle(
      "PROJECTION_LYING_MAPPING_EXTRA", projection_nested_mr.pd_h
    );
    projection_lying_mapping.clone_calls = 0;
    projection_lying_backing_ref = new("projection_lying_backing_ref");
    projection_lying_backing_ref.mapping = projection_lying_mapping;
    projection_lying_backing_ref.ownership = RDMA_OWNERSHIP_CONTROL_PLANE;
    projection_nested_mr.backing_refs.push_back(
      projection_lying_backing_ref
    );
    projection_size_before = projection_unregistered_mapping.size;
    expect_status("PROJECTION_NESTED_MAPPING_STAGE",
                  projection_rm.stage_allocated(projection_nested_mr),
                  RDMA_SC_OK);
    if (projection_unregistered_mapping.clone_calls != 0 ||
        projection_lying_mapping.clone_calls != 0 ||
        projection_unregistered_mapping.size != projection_size_before ||
        projection_lying_mapping.size != projection_size_before)
      `uvm_error("PROJECTION_NESTED_MAPPING_SOURCE",
                 "nested mapping hook ran or source mapping changed")
    expect_status("PROJECTION_NESTED_MAPPING_LOOKUP",
                  projection_rm.lookup(projection_nested_mr.handle, resource),
                  RDMA_SC_OK);
    projection_unregistered_mapping_leak = null;
    projection_lying_mapping_leak = null;
    if (resource == null || resource.backing_refs.size() != 2 ||
        resource.backing_refs[0] == null ||
        resource.backing_refs[1] == null ||
        $cast(projection_unregistered_mapping_leak,
              resource.backing_refs[0].mapping) ||
        $cast(projection_lying_mapping_leak,
              resource.backing_refs[1].mapping) ||
        resource.backing_refs[0].mapping ==
          projection_unregistered_mapping ||
        resource.backing_refs[1].mapping == projection_lying_mapping ||
        resource.backing_refs[0].mapping.function_h ==
          projection_unregistered_mapping.extra_child ||
        resource.backing_refs[0].mapping.owner_h ==
          projection_unregistered_mapping.extra_child ||
        resource.backing_refs[1].mapping.function_h ==
          projection_lying_mapping.extra_child ||
        resource.backing_refs[1].mapping.owner_h ==
          projection_lying_mapping.extra_child)
      `uvm_error("PROJECTION_NESTED_MAPPING_STORAGE",
                 "mapping subtype, extension graph, or alias escaped projection")

    // Recovery roots use the same carrier rule at ingress and on later table
    // reads.  Both wrapper-spoof mechanisms must remain hook-free.
    expect_status("PROJECTION_CREATE_RECOVERY_PD_A",
                  projection_rm.create_pd(projection_binding,
                                          projection_recovery_pd_a),
                  RDMA_SC_OK);
    projection_unregistered_recovery =
      new("projection_unregistered_recovery");
    projection_unregistered_recovery.resource_h = clone_handle(
      "PROJECTION_UNREGISTERED_RECOVERY_H",
      projection_recovery_pd_a.handle
    );
    projection_unregistered_recovery.hardware_presence =
      RDMA_HW_PRESENCE_ABSENT;
    projection_unregistered_recovery.primary_status = rdma_status::make(
      RDMA_SC_RESET_CANCELLED, "unregistered recovery carrier"
    );
    projection_unregistered_recovery.extra_child = clone_handle(
      "PROJECTION_UNREGISTERED_RECOVERY_EXTRA",
      projection_recovery_pd_a.handle
    );
    projection_unregistered_recovery.clone_calls = 0;
    projection_presence_before =
      projection_unregistered_recovery.hardware_presence;
    expect_status("PROJECTION_UNREGISTERED_RECOVERY_MARK",
                  projection_rm.mark_error(
                    projection_recovery_pd_a.handle,
                    projection_unregistered_recovery
                  ), RDMA_SC_OK);
    if (projection_unregistered_recovery.clone_calls != 0 ||
        projection_unregistered_recovery.hardware_presence !=
          projection_presence_before ||
        projection_unregistered_recovery.extra_scalar != 32'hc011_c001 ||
        projection_unregistered_recovery.extra_child == null)
      `uvm_error("PROJECTION_UNREGISTERED_RECOVERY_SOURCE",
                 "unregistered recovery hook ran or source changed")
    expect_status("PROJECTION_UNREGISTERED_RECOVERY_LOOKUP",
                  projection_rm.lookup_recovery(
                    projection_recovery_pd_a.handle, recovery_lookup
                  ), RDMA_SC_OK);
    projection_unregistered_recovery_leak = null;
    if (recovery_lookup == null ||
        $cast(projection_unregistered_recovery_leak, recovery_lookup) ||
        recovery_lookup.resource_h ==
          projection_unregistered_recovery.resource_h ||
        recovery_lookup.resource_h ==
          projection_unregistered_recovery.extra_child)
      `uvm_error("PROJECTION_UNREGISTERED_RECOVERY_STORAGE",
                 "unregistered recovery or handle alias escaped projection")
    expect_status("PROJECTION_UNREGISTERED_RECOVERY_CLEAR",
                  projection_rm.clear_recovery(
                    projection_recovery_pd_a.handle
                  ), RDMA_SC_OK);

    expect_status("PROJECTION_CREATE_RECOVERY_PD_B",
                  projection_rm.create_pd(projection_binding,
                                          projection_recovery_pd_b),
                  RDMA_SC_OK);
    projection_lying_recovery = new("projection_lying_recovery");
    projection_lying_recovery.resource_h = clone_handle(
      "PROJECTION_LYING_RECOVERY_H", projection_recovery_pd_b.handle
    );
    projection_lying_recovery.hardware_presence = RDMA_HW_PRESENCE_ABSENT;
    projection_lying_recovery.primary_status = rdma_status::make(
      RDMA_SC_RESET_CANCELLED, "lying recovery carrier"
    );
    projection_lying_recovery.extra_child = clone_handle(
      "PROJECTION_LYING_RECOVERY_EXTRA", projection_recovery_pd_b.handle
    );
    projection_lying_recovery.clone_calls = 0;
    projection_presence_before = projection_lying_recovery.hardware_presence;
    expect_status("PROJECTION_LYING_RECOVERY_MARK",
                  projection_rm.mark_error(
                    projection_recovery_pd_b.handle,
                    projection_lying_recovery
                  ), RDMA_SC_OK);
    if (projection_lying_recovery.clone_calls != 0 ||
        projection_lying_recovery.hardware_presence !=
          projection_presence_before ||
        projection_lying_recovery.extra_scalar != 32'hc011_c002)
      `uvm_error("PROJECTION_LYING_RECOVERY_SOURCE",
                 "lying recovery hook ran or source changed")
    expect_status("PROJECTION_LYING_RECOVERY_LOOKUP",
                  projection_rm.lookup_recovery(
                    projection_recovery_pd_b.handle, recovery_lookup
                  ), RDMA_SC_OK);
    projection_lying_recovery_leak = null;
    if (recovery_lookup == null ||
        $cast(projection_lying_recovery_leak, recovery_lookup) ||
        recovery_lookup.resource_h == projection_lying_recovery.extra_child)
      `uvm_error("PROJECTION_LYING_RECOVERY_STORAGE",
                 "lying recovery subtype or extension child escaped ingress projection")

    // Simulate later table corruption with a fresh lying carrier.  Lookup must
    // return a built-in projection and clear must remove it without dispatch.
    projection_lying_recovery = new("projection_late_lying_recovery");
    projection_lying_recovery.copy(recovery_lookup);
    projection_lying_recovery.extra_child = clone_handle(
      "PROJECTION_LATE_RECOVERY_EXTRA", projection_recovery_pd_b.handle
    );
    projection_lying_recovery.clone_calls = 0;
    projection_presence_before = projection_lying_recovery.hardware_presence;
    projection_rm.inject_recovery_probe(projection_recovery_pd_b.handle,
                                        projection_lying_recovery);
    expect_status("PROJECTION_LATE_RECOVERY_LOOKUP",
                  projection_rm.lookup_recovery(
                    projection_recovery_pd_b.handle, recovery_lookup_again
                  ), RDMA_SC_OK);
    projection_lying_recovery_leak = null;
    if (projection_lying_recovery.clone_calls != 0 ||
        projection_lying_recovery.hardware_presence !=
          projection_presence_before ||
        recovery_lookup_again == null ||
        $cast(projection_lying_recovery_leak, recovery_lookup_again) ||
        recovery_lookup_again.resource_h ==
          projection_lying_recovery.extra_child)
      `uvm_error("PROJECTION_LATE_RECOVERY_STORAGE",
                 "later recovery lookup dispatched or retained subtype")
    expect_status("PROJECTION_LATE_RECOVERY_CLEAR",
                  projection_rm.clear_recovery(
                    projection_recovery_pd_b.handle
                  ), RDMA_SC_OK);
    if (projection_lying_recovery.clone_calls != 0 ||
        projection_rm.observed_recovery_probe(
          projection_recovery_pd_b.handle
        ) != null)
      `uvm_error("PROJECTION_LATE_RECOVERY_CLEAR",
                 "later recovery clear dispatched or retained carrier")

    expect_status("PROJECTION_RELEASE_FUNCTION",
                  projection_rm.release_function(
                    projection_binding.make_handle()
                  ), RDMA_SC_OK);
    expect_status("PROJECTION_NO_LEAKS",
                  projection_rm.check_leaks(leak_count), RDMA_SC_OK);
    // Controlled lifecycle publication keeps the registry authoritative and
    // detached from every candidate and lookup snapshot.
    lifecycle_rm = rdma_resource_manager::type_id::create("lifecycle_rm");
    lifecycle_binding = make_active_binding(
      "lifecycle_binding", 64'h1c1f_0000_0000_0001,
      32'h1c1f_0101, 32'd17
    );
    expect_status("LIFECYCLE_CREATE_PD",
                  lifecycle_rm.create_pd(lifecycle_binding, lifecycle_pd),
                  RDMA_SC_OK);
    expect_status("LIFECYCLE_ACTIVATE_NULL",
                  lifecycle_rm.activate(null), RDMA_SC_INVALID_ARGUMENT);
    expect_status("LIFECYCLE_PD_ACTIVATE",
                  lifecycle_rm.activate(lifecycle_pd.handle), RDMA_SC_OK);
    expect_status("LIFECYCLE_PD_ACTIVATE_AGAIN",
                  lifecycle_rm.activate(lifecycle_pd.handle),
                  RDMA_SC_INVALID_STATE);
    expect_status("LIFECYCLE_QUIESCE_NULL",
                  lifecycle_rm.begin_quiesce(null),
                  RDMA_SC_INVALID_ARGUMENT);
    expect_status("LIFECYCLE_RESTORE_NULL",
                  lifecycle_rm.restore_active(null),
                  RDMA_SC_INVALID_ARGUMENT);
    expect_status("LIFECYCLE_FINALIZE_NULL",
                  lifecycle_rm.finalize_release(null),
                  RDMA_SC_INVALID_ARGUMENT);
    expect_status("LIFECYCLE_RELEASE_RESERVED_NULL",
                  lifecycle_rm.release_reserved(null),
                  RDMA_SC_INVALID_ARGUMENT);
    expect_status("LIFECYCLE_CREATE_MR",
                  lifecycle_rm.create_mr(lifecycle_binding,
                                          lifecycle_pd.handle,
                                          lifecycle_mr),
                  RDMA_SC_OK);
    expect_status("LIFECYCLE_PD_BUSY",
                  lifecycle_rm.begin_quiesce(lifecycle_pd.handle),
                  RDMA_SC_RESOURCE_BUSY);
    expect_status("LIFECYCLE_PD_BUSY_STATE",
                  lifecycle_rm.lookup(lifecycle_pd.handle, resource),
                  RDMA_SC_OK);
    if (resource == null || resource.state != RDMA_RESOURCE_ACTIVE)
      `uvm_error("LIFECYCLE_PD_BUSY_STATE",
                 "busy quiesce changed the PD state")

    lifecycle_mr.iova.value = 64'h1000_0000;
    lifecycle_mr.length = 64'h2000;
    lifecycle_mr.lkey = {lifecycle_mr.local_mr_id[23:0], 8'h5a};
    lifecycle_mr.rkey = lifecycle_mr.lkey;
    lifecycle_mr.access = '{local_write:1'b1, remote_read:1'b1,
                            remote_write:1'b0, memory_window_bind:1'b0,
                            remote_atomic:1'b0};
    lifecycle_mr_h = clone_handle("LIFECYCLE_MR_H", lifecycle_mr.handle);
    expect_status("LIFECYCLE_COMMIT_NULL",
                  lifecycle_rm.commit_programmed(null),
                  RDMA_SC_INVALID_ARGUMENT);
    expect_status("LIFECYCLE_COMMIT_BEFORE_STAGE",
                  lifecycle_rm.commit_programmed(lifecycle_mr),
                  RDMA_SC_INVALID_STATE);
    expect_status("LIFECYCLE_ACTIVATE_ALLOCATED_MR",
                  lifecycle_rm.activate(lifecycle_mr.handle),
                  RDMA_SC_INVALID_STATE);
    expect_status("LIFECYCLE_STAGE_NULL",
                  lifecycle_rm.stage_allocated(null),
                  RDMA_SC_INVALID_ARGUMENT);
    wrong_stage_pd = rdma_pd::type_id::create("wrong_stage_pd");
    wrong_stage_pd.handle = clone_handle("WRONG_STAGE_H",
                                         lifecycle_mr.handle);
    wrong_stage_pd.owner = clone_function_handle("WRONG_STAGE_OWNER",
                                                  lifecycle_mr.owner);
    wrong_stage_pd.state = RDMA_RESOURCE_ALLOCATED;
    expect_status("LIFECYCLE_STAGE_WRONG_TYPE",
                  lifecycle_rm.stage_allocated(wrong_stage_pd),
                  RDMA_SC_INVALID_ARGUMENT);
    lifecycle_mr.handle.object_id++;
    expect_status("LIFECYCLE_STAGE_WRONG_INCARCATION",
                  lifecycle_rm.stage_allocated(lifecycle_mr),
                  RDMA_SC_INVALID_ARGUMENT);
    lifecycle_mr.handle = lifecycle_mr_h;
    lifecycle_mr.state = RDMA_RESOURCE_PROGRAMMED;
    expect_status("LIFECYCLE_STAGE_WRONG_STATE",
                  lifecycle_rm.stage_allocated(lifecycle_mr),
                  RDMA_SC_INVALID_STATE);
    lifecycle_mr.state = RDMA_RESOURCE_ALLOCATED;
    lifecycle_mr.outstanding_ids.push_back(64'hfeed);
    expect_status("LIFECYCLE_STAGE_INJECT_OUTSTANDING",
                  lifecycle_rm.stage_allocated(lifecycle_mr),
                  RDMA_SC_INVALID_ARGUMENT);
    lifecycle_mr.outstanding_ids.delete();
    expect_status("LIFECYCLE_STAGE",
                  lifecycle_rm.stage_allocated(lifecycle_mr), RDMA_SC_OK);
    lifecycle_mr.length = 64'h4000;
    expect_status("LIFECYCLE_STAGE_LOOKUP",
                  lifecycle_rm.lookup(lifecycle_mr.handle, resource),
                  RDMA_SC_OK);
    if (resource == null || resource.state != RDMA_RESOURCE_ALLOCATED ||
        !$cast(width_mr_failed, resource) ||
        width_mr_failed.length != 64'h2000)
      `uvm_error("LIFECYCLE_STAGE_LOOKUP",
                 "stage did not publish a detached ALLOCATED snapshot")
    expect_status("LIFECYCLE_COMMIT_WRONG_TYPE",
                  lifecycle_rm.commit_programmed(wrong_stage_pd),
                  RDMA_SC_INVALID_ARGUMENT);
    lifecycle_mr.state = RDMA_RESOURCE_PROGRAMMED;
    expect_status("LIFECYCLE_COMMIT_WRONG_STATE",
                  lifecycle_rm.commit_programmed(lifecycle_mr),
                  RDMA_SC_INVALID_STATE);
    lifecycle_mr.state = RDMA_RESOURCE_ALLOCATED;
    lifecycle_mr.length = 0;
    expect_status("LIFECYCLE_COMMIT_INVALID",
                  lifecycle_rm.commit_programmed(lifecycle_mr),
                  RDMA_SC_INVALID_ARGUMENT);
    expect_status("LIFECYCLE_COMMIT_INVALID_STATE_PRESERVED",
                  lifecycle_rm.lookup(lifecycle_mr.handle, resource),
                  RDMA_SC_OK);
    if (resource == null || resource.state != RDMA_RESOURCE_ALLOCATED)
      `uvm_error("LIFECYCLE_COMMIT_INVALID_STATE_PRESERVED",
                 "invalid commit mutated the staged registry state")
    lifecycle_mr.length = 64'h2000;
    expect_status("LIFECYCLE_PROGRAM",
                  lifecycle_rm.commit_programmed(lifecycle_mr), RDMA_SC_OK);
    lifecycle_mr.length = 64'h8000;
    expect_status("LIFECYCLE_PROGRAM_LOOKUP",
                  lifecycle_rm.lookup(lifecycle_mr.handle, resource),
                  RDMA_SC_OK);
    if (resource == null || resource.state != RDMA_RESOURCE_PROGRAMMED ||
        !$cast(width_mr_failed, resource) ||
        width_mr_failed.length != 64'h2000)
      `uvm_error("LIFECYCLE_PROGRAM_LOOKUP",
                 "commit did not publish a detached PROGRAMMED snapshot")
    expect_status("LIFECYCLE_MR_ACTIVATE",
                  lifecycle_rm.activate(lifecycle_mr.handle), RDMA_SC_OK);
    expect_status("LIFECYCLE_RELEASE_ACTIVE",
                  lifecycle_rm.release_reserved(lifecycle_mr.handle),
                  RDMA_SC_INVALID_STATE);
    expect_status("LIFECYCLE_COMPAT_RELEASE_ACTIVE",
                  lifecycle_rm.\release (lifecycle_mr.handle),
                  RDMA_SC_INVALID_STATE);
    expect_status("LIFECYCLE_COMPAT_FREEZE_ACTIVE",
                  lifecycle_rm.freeze(lifecycle_mr.handle),
                  RDMA_SC_INVALID_STATE);

    expect_status("OUTSTANDING_ZERO",
                  lifecycle_rm.track_outstanding(lifecycle_mr.handle, 0),
                  RDMA_SC_INVALID_ARGUMENT);
    expect_status("OUTSTANDING_TRACK_NULL",
                  lifecycle_rm.track_outstanding(null, 64'h1234),
                  RDMA_SC_INVALID_ARGUMENT);
    expect_status("OUTSTANDING_RETIRE_NULL",
                  lifecycle_rm.retire_outstanding(null, 64'h1234),
                  RDMA_SC_INVALID_ARGUMENT);
    expect_status("OUTSTANDING_TRACK",
                  lifecycle_rm.track_outstanding(lifecycle_mr.handle,
                                                  64'h1234),
                  RDMA_SC_OK);
    expect_status("OUTSTANDING_DUPLICATE",
                  lifecycle_rm.track_outstanding(lifecycle_mr.handle,
                                                  64'h1234),
                  RDMA_SC_INVALID_ARGUMENT);
    expect_status("OUTSTANDING_LOOKUP",
                  lifecycle_rm.lookup(lifecycle_mr.handle, resource),
                  RDMA_SC_OK);
    if (resource == null || resource.outstanding_ids.size() != 1 ||
        resource.outstanding_ids[0] != 64'h1234)
      `uvm_error("OUTSTANDING_LOOKUP",
                 "registry did not authoritatively track one unique ID")
    expect_status("OUTSTANDING_QUIESCE_BUSY",
                  lifecycle_rm.begin_quiesce(lifecycle_mr.handle),
                  RDMA_SC_RESOURCE_BUSY);
    expect_status("OUTSTANDING_RETIRE_UNKNOWN",
                  lifecycle_rm.retire_outstanding(lifecycle_mr.handle,
                                                   64'h9999),
                  RDMA_SC_INVALID_ARGUMENT);
    expect_status("OUTSTANDING_RETIRE",
                  lifecycle_rm.retire_outstanding(lifecycle_mr.handle,
                                                   64'h1234),
                  RDMA_SC_OK);
    expect_status("OUTSTANDING_QUIESCE",
                  lifecycle_rm.begin_quiesce(lifecycle_mr.handle),
                  RDMA_SC_OK);
    expect_status("OUTSTANDING_TRACK_QUIESCING",
                  lifecycle_rm.track_outstanding(lifecycle_mr.handle,
                                                  64'h5678),
                  RDMA_SC_INVALID_STATE);
    expect_status("LIFECYCLE_RESTORE",
                  lifecycle_rm.restore_active(lifecycle_mr.handle),
                  RDMA_SC_OK);
    expect_status("LIFECYCLE_RESTORE_ACTIVE",
                  lifecycle_rm.restore_active(lifecycle_mr.handle),
                  RDMA_SC_INVALID_STATE);
    expect_status("LIFECYCLE_MR_QUIESCE",
                  lifecycle_rm.begin_quiesce(lifecycle_mr.handle),
                  RDMA_SC_OK);
    expect_status("LIFECYCLE_MR_FINALIZE",
                  lifecycle_rm.finalize_release(lifecycle_mr.handle),
                  RDMA_SC_OK);
    expect_status("LIFECYCLE_PD_QUIESCE",
                  lifecycle_rm.begin_quiesce(lifecycle_pd.handle),
                  RDMA_SC_OK);
    expect_status("LIFECYCLE_PD_FINALIZE",
                  lifecycle_rm.finalize_release(lifecycle_pd.handle),
                  RDMA_SC_OK);
    expect_status("LIFECYCLE_CREATE_ROLLBACK",
                  lifecycle_rm.create_aeq(lifecycle_binding, rollback_aeq),
                  RDMA_SC_OK);
    expect_status("LIFECYCLE_RELEASE_RESERVED",
                  lifecycle_rm.release_reserved(rollback_aeq.handle),
                  RDMA_SC_OK);
    expect_status("LIFECYCLE_RELEASE_RESERVED_AGAIN",
                  lifecycle_rm.release_reserved(rollback_aeq.handle),
                  RDMA_SC_INVALID_STATE);

    // ERROR owns a detached recovery record.  Neither normal release nor
    // clearing a completed record may bypass the recovery release gate.
    recovery_rm = rdma_resource_manager::type_id::create("recovery_rm");
    recovery_binding = make_active_binding(
      "recovery_binding", 64'he220_0000_0000_0001,
      32'he220_0101, 32'd22
    );
    expect_status("RECOVERY_CREATE_PD",
                  recovery_rm.create_pd(recovery_binding, recovery_pd),
                  RDMA_SC_OK);
    expect_status("RECOVERY_ACTIVATE_PD",
                  recovery_rm.activate(recovery_pd.handle), RDMA_SC_OK);
    recovery_record = rdma_recovery_record::type_id::create(
      "recovery_record"
    );
    recovery_record.resource_h = clone_handle("RECOVERY_RECORD_H",
                                               recovery_pd.handle);
    recovery_record.hardware_presence = RDMA_HW_PRESENCE_PRESENT;
    recovery_record.pending_steps.push_back(RDMA_CTRL_STEP_HW_DRAINED);
    recovery_record.primary_status = rdma_status::make(
      RDMA_SC_TIMEOUT, "hardware state is ambiguous"
    );
    malformed_recovery = rdma_recovery_record::type_id::create(
      "malformed_recovery"
    );
    malformed_recovery.copy(recovery_record);
    expect_status("RECOVERY_MARK_NULL_HANDLE",
                  recovery_rm.mark_error(null, recovery_record),
                  RDMA_SC_INVALID_ARGUMENT);
    expect_status("RECOVERY_MARK_NULL_RECORD",
                  recovery_rm.mark_error(recovery_pd.handle, null),
                  RDMA_SC_INVALID_ARGUMENT);
    expect_status("RECOVERY_LOOKUP_NULL",
                  recovery_rm.lookup_recovery(null, recovery_lookup),
                  RDMA_SC_INVALID_ARGUMENT);
    expect_status("RECOVERY_LOOKUP_MISSING",
                  recovery_rm.lookup_recovery(recovery_pd.handle,
                                              recovery_lookup),
                  RDMA_SC_INVALID_STATE);
    malformed_recovery.primary_status = null;
    expect_status("RECOVERY_MARK_MALFORMED",
                  recovery_rm.mark_error(recovery_pd.handle,
                                         malformed_recovery),
                  RDMA_SC_INVALID_ARGUMENT);
    malformed_recovery.copy(recovery_record);
    malformed_recovery.resource_h.object_id++;
    expect_status("RECOVERY_MARK_MISMATCH",
                  recovery_rm.mark_error(recovery_pd.handle,
                                         malformed_recovery),
                  RDMA_SC_INVALID_ARGUMENT);
    expect_status("RECOVERY_MALFORMED_STATE_PRESERVED",
                  recovery_rm.lookup(recovery_pd.handle, resource),
                  RDMA_SC_OK);
    if (resource == null || resource.state != RDMA_RESOURCE_ACTIVE)
      `uvm_error("RECOVERY_MALFORMED_STATE_PRESERVED",
                 "malformed recovery changed resource state")
    expect_status("RECOVERY_MARK_ERROR",
                  recovery_rm.mark_error(recovery_pd.handle,
                                         recovery_record),
                  RDMA_SC_OK);
    recovery_record.hardware_presence = RDMA_HW_PRESENCE_ABSENT;
    recovery_record.pending_steps.delete();
    expect_status("RECOVERY_LOOKUP",
                  recovery_rm.lookup_recovery(recovery_pd.handle,
                                              recovery_lookup),
                  RDMA_SC_OK);
    if (recovery_lookup == null ||
        recovery_lookup.hardware_presence != RDMA_HW_PRESENCE_PRESENT ||
        recovery_lookup.pending_steps.size() != 1)
      `uvm_error("RECOVERY_LOOKUP",
                 "mark_error did not retain a detached recovery record")
    recovery_lookup.hardware_presence = RDMA_HW_PRESENCE_ABSENT;
    recovery_lookup.pending_steps.delete();
    expect_status("RECOVERY_LOOKUP_AGAIN",
                  recovery_rm.lookup_recovery(recovery_pd.handle,
                                              recovery_lookup_again),
                  RDMA_SC_OK);
    if (recovery_lookup_again == null ||
        recovery_lookup_again.hardware_presence != RDMA_HW_PRESENCE_PRESENT ||
        recovery_lookup_again.pending_steps.size() != 1)
      `uvm_error("RECOVERY_LOOKUP_AGAIN",
                 "caller mutation reached recovery side-table state")
    expect_status("RECOVERY_ERROR_LOOKUP",
                  recovery_rm.lookup(recovery_pd.handle, resource),
                  RDMA_SC_OK);
    if (resource == null || resource.state != RDMA_RESOURCE_ERROR)
      `uvm_error("RECOVERY_ERROR_LOOKUP",
                 "mark_error did not publish ERROR state")
    expect_status("RECOVERY_ERROR_ACTIVATE",
                  recovery_rm.activate(recovery_pd.handle),
                  RDMA_SC_INVALID_STATE);
    expect_status("RECOVERY_ERROR_RELEASE_RESERVED",
                  recovery_rm.release_reserved(recovery_pd.handle),
                  RDMA_SC_INVALID_STATE);
    expect_status("RECOVERY_ERROR_COMPAT_RELEASE",
                  recovery_rm.\release (recovery_pd.handle),
                  RDMA_SC_RECOVERY_REQUIRED);
    expect_status("RECOVERY_ERROR_FINALIZE_PRESENT",
                  recovery_rm.finalize_release(recovery_pd.handle),
                  RDMA_SC_RECOVERY_REQUIRED);
    expect_status("RECOVERY_CLEAR_INCOMPLETE",
                  recovery_rm.clear_recovery(recovery_pd.handle),
                  RDMA_SC_RECOVERY_REQUIRED);
    expect_status("RECOVERY_INCOMPLETE_RETAINED",
                  recovery_rm.lookup_recovery(recovery_pd.handle,
                                              recovery_lookup),
                  RDMA_SC_OK);

    ready_recovery = rdma_recovery_record::type_id::create(
      "ready_recovery"
    );
    ready_recovery.resource_h = clone_handle("READY_RECOVERY_H",
                                              recovery_pd.handle);
    ready_recovery.hardware_presence = RDMA_HW_PRESENCE_ABSENT;
    ready_recovery.primary_status = rdma_status::make(
      RDMA_SC_TIMEOUT, "hardware absence confirmed"
    );
    ready_recovery.pending_steps.push_back(RDMA_CTRL_STEP_HW_DRAINED);
    expect_status("RECOVERY_REMARK_PENDING_ONLY",
                  recovery_rm.mark_error(recovery_pd.handle,
                                         ready_recovery),
                  RDMA_SC_OK);
    expect_status("RECOVERY_FINALIZE_PENDING_ONLY",
                  recovery_rm.finalize_release(recovery_pd.handle),
                  RDMA_SC_RECOVERY_REQUIRED);
    ready_recovery.pending_steps.delete();
    ready_recovery.hardware_presence = RDMA_HW_PRESENCE_PRESENT;
    expect_status("RECOVERY_REMARK_PRESENT_ONLY",
                  recovery_rm.mark_error(recovery_pd.handle,
                                         ready_recovery),
                  RDMA_SC_OK);
    expect_status("RECOVERY_FINALIZE_PRESENT_ONLY",
                  recovery_rm.finalize_release(recovery_pd.handle),
                  RDMA_SC_RECOVERY_REQUIRED);
    ready_recovery.hardware_presence = RDMA_HW_PRESENCE_ABSENT;
    expect_status("RECOVERY_REMARK_READY",
                  recovery_rm.mark_error(recovery_pd.handle,
                                         ready_recovery),
                  RDMA_SC_OK);
    expect_status("RECOVERY_CLEAR_READY",
                  recovery_rm.clear_recovery(recovery_pd.handle),
                  RDMA_SC_OK);
    expect_status("RECOVERY_CLEARED_LOOKUP",
                  recovery_rm.lookup_recovery(recovery_pd.handle,
                                              recovery_lookup),
                  RDMA_SC_INVALID_STATE);
    expect_status("RECOVERY_CLEAR_NO_BYPASS",
                  recovery_rm.finalize_release(recovery_pd.handle),
                  RDMA_SC_RECOVERY_REQUIRED);
    expect_status("RECOVERY_REATTACH_READY",
                  recovery_rm.mark_error(recovery_pd.handle,
                                         ready_recovery),
                  RDMA_SC_OK);
    expect_status("RECOVERY_FINALIZE",
                  recovery_rm.finalize_release(recovery_pd.handle),
                  RDMA_SC_OK);
    expect_status("RECOVERY_RELEASED_LOOKUP",
                  recovery_rm.lookup(recovery_pd.handle, resource),
                  RDMA_SC_INVALID_STATE);

    // Function retirement is the privileged reset boundary: its complete
    // dependency-order preflight supplies hardware invalidation authority and
    // may force an incomplete ERROR topology down without weakening any
    // ordinary per-resource gate.
    privileged_recovery_rm = new("privileged_recovery_rm");
    privileged_recovery_binding = make_active_binding(
      "privileged_recovery_binding", 64'he220_0000_0000_0003,
      32'he220_0303, 32'd41
    );
    privileged_recovery_owner = privileged_recovery_binding.make_handle();
    expect_status("PRIV_RECOVERY_CREATE",
                  privileged_recovery_rm.create_pd(
                    privileged_recovery_binding, privileged_recovery_pd
                  ), RDMA_SC_OK);
    expect_status("PRIV_RECOVERY_ACTIVATE",
                  privileged_recovery_rm.activate(
                    privileged_recovery_pd.handle
                  ), RDMA_SC_OK);
    recovery_record = rdma_recovery_record::type_id::create(
      "privileged_unknown_recovery"
    );
    recovery_record.resource_h = clone_handle(
      "PRIV_RECOVERY_H", privileged_recovery_pd.handle
    );
    recovery_record.hardware_presence = RDMA_HW_PRESENCE_UNKNOWN;
    recovery_record.pending_steps.push_back(RDMA_CTRL_STEP_HW_DRAINED);
    recovery_record.primary_status = rdma_status::make(
      RDMA_SC_TIMEOUT, "reset owns ambiguous hardware invalidation"
    );
    expect_status("PRIV_RECOVERY_MARK",
                  privileged_recovery_rm.mark_error(
                    privileged_recovery_pd.handle, recovery_record
                  ), RDMA_SC_OK);
    expect_status("PRIV_RECOVERY_ORDINARY_FINALIZE",
                  privileged_recovery_rm.finalize_release(
                    privileged_recovery_pd.handle
                  ), RDMA_SC_RECOVERY_REQUIRED);
    expect_status("PRIV_RECOVERY_FUNCTION_RELEASE",
                  privileged_recovery_rm.release_function(
                    privileged_recovery_owner
                  ), RDMA_SC_OK);
    expect_status("PRIV_RECOVERY_NO_LEAKS",
                  privileged_recovery_rm.check_leaks(
                    leak_count, privileged_recovery_owner
                  ), RDMA_SC_OK);
    if (privileged_recovery_rm.observed_recovery_count() != 0)
      `uvm_error("PRIV_RECOVERY_NO_LEAKS",
                 "privileged ERROR teardown leaked recovery metadata")
    expect_status("PRIV_RECOVERY_RECORD_RETIRED",
                  privileged_recovery_rm.lookup_recovery(
                    privileged_recovery_pd.handle, recovery_lookup
                  ), RDMA_SC_STALE_GENERATION);
    privileged_recovery_binding.generation++;
    privileged_recovery_binding.owner_h =
      privileged_recovery_binding.make_handle();
    expect_status("PRIV_RECOVERY_ID_REUSE",
                  privileged_recovery_rm.create_pd(
                    privileged_recovery_binding,
                    privileged_recovery_pd_reused
                  ), RDMA_SC_OK);
    if (privileged_recovery_pd_reused == null ||
        privileged_recovery_pd_reused.local_pd_id !=
          privileged_recovery_pd.local_pd_id ||
        privileged_recovery_pd_reused.handle.same_instance(
          privileged_recovery_pd.handle
        ))
      `uvm_error("PRIV_RECOVERY_ID_REUSE",
                 "privileged ERROR teardown leaked ID/incarnation state")
    expect_status("PRIV_RECOVERY_RELEASE_NEXT",
                  privileged_recovery_rm.release_function(
                    privileged_recovery_binding.make_handle()
                  ), RDMA_SC_OK);

    // Only mark_error receives the exact-key stale-generation exception.
    // Other public operations retain ordinary live-binding authority checks.
    stale_recovery_rm = rdma_resource_manager::type_id::create(
      "stale_recovery_rm"
    );
    stale_recovery_binding = make_active_binding(
      "stale_recovery_binding", 64'he220_0000_0000_0002,
      32'he220_0202, 32'd31
    );
    stale_recovery_owner = stale_recovery_binding.make_handle();
    expect_status("STALE_RECOVERY_CREATE",
                  stale_recovery_rm.create_pd(stale_recovery_binding,
                                               stale_recovery_pd),
                  RDMA_SC_OK);
    stale_recovery_h = clone_handle("STALE_RECOVERY_H",
                                    stale_recovery_pd.handle);
    ready_recovery = rdma_recovery_record::type_id::create(
      "stale_ready_recovery"
    );
    ready_recovery.resource_h = clone_handle("STALE_READY_H",
                                              stale_recovery_h);
    ready_recovery.hardware_presence = RDMA_HW_PRESENCE_ABSENT;
    ready_recovery.primary_status = rdma_status::make(
      RDMA_SC_RESET_CANCELLED, "Function generation advanced"
    );
    stale_recovery_binding.generation++;
    stale_recovery_binding.owner_h = stale_recovery_binding.make_handle();
    expect_status("STALE_RECOVERY_MARK_EXCEPTION",
                  stale_recovery_rm.mark_error(stale_recovery_h,
                                                ready_recovery),
                  RDMA_SC_OK);
    expect_status("STALE_RECOVERY_ORDINARY_LOOKUP",
                  stale_recovery_rm.lookup(stale_recovery_h, resource),
                  RDMA_SC_STALE_GENERATION);
    expect_status("STALE_RECOVERY_ACTIVATE",
                  stale_recovery_rm.activate(stale_recovery_h),
                  RDMA_SC_STALE_GENERATION);
    expect_status("STALE_RECOVERY_RECORD_LOOKUP",
                  stale_recovery_rm.lookup_recovery(stale_recovery_h,
                                                    recovery_lookup),
                  RDMA_SC_STALE_GENERATION);
    expect_status("STALE_RECOVERY_CLEAR",
                  stale_recovery_rm.clear_recovery(stale_recovery_h),
                  RDMA_SC_STALE_GENERATION);
    expect_status("STALE_RECOVERY_FINALIZE",
                  stale_recovery_rm.finalize_release(stale_recovery_h),
                  RDMA_SC_STALE_GENERATION);
    expect_status("STALE_RECOVERY_PRIVILEGED_TEARDOWN",
                  stale_recovery_rm.release_function(stale_recovery_owner),
                  RDMA_SC_OK);
    expect_status("STALE_RECOVERY_NO_LEAKS",
                  stale_recovery_rm.check_leaks(leak_count,
                                                stale_recovery_owner),
                  RDMA_SC_OK);

    // Required minimal stale-generation scenario.
    rm = rdma_resource_manager::type_id::create("rm_stale");
    active_binding = make_active_binding("active_binding");
    s = rm.create_pd(active_binding, pd);
    old_h = clone_handle("RM", pd.handle);
    expect_status("RM_CREATE_PD", s, RDMA_SC_OK);
    s = rm.\release (pd.handle);
    expect_status("RM_RELEASE_PD", s, RDMA_SC_OK);
    active_binding.generation++;
    s = rm.lookup(old_h, resource);
    expect_status("RM_STALE_GENERATION", s, RDMA_SC_STALE_GENERATION);

    // Local IDs are recycled independently by kind, while the opaque global
    // incarnation in object_id is never recycled within a generation.
    rm = rdma_resource_manager::type_id::create("rm_id_pool");
    binding_a = make_active_binding("binding_a");
    expect_status("ID_CREATE_PD_FIRST",
                  rm.create_pd(binding_a, pd_first), RDMA_SC_OK);
    same_generation_old_h = clone_handle("ID_OLD_HANDLE", pd_first.handle);
    expect_status("ID_RELEASE_PD_FIRST", rm.\release (pd_first.handle),
                  RDMA_SC_OK);
    expect_status("ID_RELEASED_LOOKUP",
                  rm.lookup(same_generation_old_h, resource),
                  RDMA_SC_INVALID_STATE);
    expect_status("ID_CREATE_PD_REUSED",
                  rm.create_pd(binding_a, pd_reused), RDMA_SC_OK);
    if (pd_reused.local_pd_id != pd_first.local_pd_id)
      `uvm_error("ID_REUSE", "released PD local ID was not reused")
    if (pd_reused.handle.object_id == same_generation_old_h.object_id ||
        pd_reused.global_pd_id != pd_reused.handle.object_id ||
        pd_reused.handle.same_instance(same_generation_old_h))
      `uvm_error("ID_INCAR",
                 "reused local ID did not receive a new incarnation")
    expect_status("ID_OLD_LOOKUP_AFTER_REUSE",
                  rm.lookup(same_generation_old_h, resource),
                  RDMA_SC_INVALID_STATE);
    expect_status("ID_OLD_RELEASE_AFTER_REUSE",
                  rm.\release (same_generation_old_h),
                  RDMA_SC_INVALID_STATE);
    expect_status("ID_CREATE_CQ_POOL",
                  rm.create_cq(binding_a, null, cq_pool), RDMA_SC_OK);
    if (cq_pool.local_cq_id != pd_first.local_pd_id)
      `uvm_error("ID_KIND_POOL", "PD and CQ did not use independent pools")

    // Registry lookups are value based and return deep copies.
    expect_status("LOOKUP_CLONE",
                  rm.lookup(clone_handle("LOOKUP_CLONE_H",
                                         pd_reused.handle), resource),
                  RDMA_SC_OK);
    if (resource == null || resource == pd_reused ||
        resource.handle == pd_reused.handle)
      `uvm_error("LOOKUP_COPY", "lookup did not return a deep value copy")
    else begin
      resource.handle.object_id++;
      expect_status("LOOKUP_COPY_ISOLATION",
                    rm.lookup(pd_reused.handle, second_resource), RDMA_SC_OK);
      if (second_resource == null ||
          second_resource.handle.object_id != pd_reused.handle.object_id)
        `uvm_error("LOOKUP_COPY_ISOLATION",
                   "caller mutation reached the authoritative registry")
    end

    forged_h = clone_handle("FORGED_KIND", pd_reused.handle);
    forged_h.kind = RDMA_RESOURCE_CQ;
    expect_status("FORGED_KIND_LOOKUP", rm.lookup(forged_h, resource),
                  RDMA_SC_INVALID_ARGUMENT);
    forged_h = clone_handle("FORGED_OWNER", pd_reused.handle);
    forged_h.function_uid ^= 64'h1;
    expect_status("FORGED_OWNER_LOOKUP", rm.lookup(forged_h, resource),
                  RDMA_SC_INVALID_ARGUMENT);
    forged_h = clone_handle("FORGED_GENERATION", pd_reused.handle);
    forged_h.generation++;
    expect_status("FORGED_GENERATION_LOOKUP", rm.lookup(forged_h, resource),
                  RDMA_SC_STALE_GENERATION);
    forged_h = clone_handle("FORGED_OBJECT_ID", pd_reused.handle);
    forged_h.object_id++;
    expect_status("FORGED_OBJECT_ID_LOOKUP", rm.lookup(forged_h, resource),
                  RDMA_SC_INVALID_ARGUMENT);
    expect_status("ID_RELEASE_CQ", rm.\release (cq_pool.handle), RDMA_SC_OK);
    expect_status("ID_RELEASE_PD_REUSED", rm.\release (pd_reused.handle),
                  RDMA_SC_OK);
    expect_status("ID_REPEAT_RELEASE", rm.\release (pd_reused.handle),
                  RDMA_SC_INVALID_STATE);

    // Caller-owned bindings and published resources are never authoritative.
    // Only monotonic generation changes from the original binding reference
    // may affect lifecycle checks; identity and configuration are snapshots.
    snapshot_rm = rdma_resource_manager::type_id::create("snapshot_rm");
    snapshot_binding = make_active_binding(
      "snapshot_binding", 64'h5a5a_0000_0000_0001,
      32'h5a5a_0101, 32'd11
    );
    snapshot_binding.rdma_vf_id = 32'h5a5a_0202;
    snapshot_binding.vsi_id = 32'h5a5a_0303;
    snapshot_binding.pfvf_id = 32'h5a5a_0404;
    snapshot_bdf = snapshot_binding.pcie.bdf;
    expect_status("SNAPSHOT_CREATE_FUNCTION",
                  snapshot_rm.create_function(snapshot_binding,
                                              snapshot_function),
                  RDMA_SC_OK);
    if (snapshot_function == null ||
        snapshot_function.rdma_vf_id != 32'h5a5a_0202 ||
        snapshot_function.vsi_id != 32'h5a5a_0303 ||
        snapshot_function.pfvf_id != 32'h5a5a_0404)
      `uvm_error("SNAPSHOT_FUNCTION_LOGICAL_IDS",
                 "created Function omitted trusted logical identity fields")
    if (snapshot_function == null || snapshot_function.binding == null ||
        snapshot_function.binding.rdma_vf_id != 32'h5a5a_0202 ||
        snapshot_function.binding.vsi_id != 32'h5a5a_0303 ||
        snapshot_function.binding.pfvf_id != 32'h5a5a_0404)
      `uvm_error("SNAPSHOT_FUNCTION_NESTED_IDS",
                 "created Function binding omitted logical identity fields")
    owner_h = clone_function_handle("SNAPSHOT_OWNER",
                                    snapshot_function.owner);
    expect_status("SNAPSHOT_CREATE_PD",
                  snapshot_rm.create_pd(snapshot_binding, snapshot_pd),
                  RDMA_SC_OK);
    snapshot_pd_h = clone_handle("SNAPSHOT_PD_H", snapshot_pd.handle);
    expect_status("SNAPSHOT_CREATE_CQ",
                  snapshot_rm.create_cq(snapshot_binding, null, cq_pool),
                  RDMA_SC_OK);
    expect_status("SNAPSHOT_CREATE_QP",
                  snapshot_rm.create_qp(snapshot_binding,
                                        snapshot_pd.handle,
                                        cq_pool.handle, cq_pool.handle,
                                        null, snapshot_qp),
                  RDMA_SC_OK);
    snapshot_qp_h = clone_handle("SNAPSHOT_QP_H", snapshot_qp.handle);

    snapshot_function.handle.object_id++;
    snapshot_function.owner.object_id++;
    snapshot_function.binding.global_function_id++;
    snapshot_function.binding.pcie.bdf.bus++;
    snapshot_function.rdma_vf_id++;
    snapshot_function.vsi_id++;
    snapshot_function.pfvf_id++;
    snapshot_function.binding.rdma_vf_id++;
    snapshot_function.binding.vsi_id++;
    snapshot_function.binding.pfvf_id++;
    snapshot_qp.handle.object_id++;
    snapshot_qp.owner.object_id++;
    snapshot_qp.pd_h.object_id++;
    snapshot_qp.dependencies[0].object_id++;
    snapshot_pd.handle.object_id++;
    snapshot_binding.function_uid ^= 64'hffff;
    snapshot_binding.global_function_id++;
    snapshot_binding.host_id = 32'hffff_0001;
    snapshot_binding.pcie.bdf.bus++;
    snapshot_binding.rdma_vf_id++;
    snapshot_binding.vsi_id++;
    snapshot_binding.pfvf_id++;

    expect_status("SNAPSHOT_FUNCTION_LOOKUP",
                  snapshot_rm.lookup(owner_h, resource), RDMA_SC_OK);
    if (resource == null || !$cast(snapshot_function_lookup, resource)) begin
      `uvm_error("SNAPSHOT_FUNCTION_LOOKUP",
                 "Function lookup returned the wrong resource type")
    end
    else begin
      if (snapshot_function_lookup.rdma_vf_id != 32'h5a5a_0202 ||
          snapshot_function_lookup.vsi_id != 32'h5a5a_0303 ||
          snapshot_function_lookup.pfvf_id != 32'h5a5a_0404)
        `uvm_error("SNAPSHOT_FUNCTION_LOGICAL_IDS_LOOKUP",
                   "caller mutation changed Function logical identity")
      if (snapshot_function_lookup.binding == null ||
          snapshot_function_lookup.binding.function_uid !=
            64'h5a5a_0000_0000_0001 ||
          snapshot_function_lookup.binding.global_function_id !=
            32'h5a5a_0101 ||
          snapshot_function_lookup.binding.rdma_vf_id != 32'h5a5a_0202 ||
          snapshot_function_lookup.binding.vsi_id != 32'h5a5a_0303 ||
          snapshot_function_lookup.binding.pfvf_id != 32'h5a5a_0404 ||
          snapshot_function_lookup.binding.host_id != 0 ||
          snapshot_function_lookup.binding.pcie == null ||
          snapshot_function_lookup.binding.pcie.bdf != snapshot_bdf)
        `uvm_error("SNAPSHOT_FUNCTION_VALUE",
                   "caller mutation changed authoritative Function binding")
    end
    expect_status("SNAPSHOT_QP_LOOKUP",
                  snapshot_rm.lookup(snapshot_qp_h, resource), RDMA_SC_OK);
    if (resource == null || !$cast(snapshot_qp_lookup, resource)) begin
      `uvm_error("SNAPSHOT_QP_LOOKUP",
                 "QP lookup returned the wrong resource type")
    end
    else if (snapshot_qp_lookup.owner == null ||
             !snapshot_qp_lookup.owner.same_instance(owner_h) ||
             snapshot_qp_lookup.pd_h == null ||
             !snapshot_qp_lookup.pd_h.same_instance(snapshot_pd_h) ||
             snapshot_qp_lookup.dependencies.size() == 0 ||
             !snapshot_qp_lookup.dependencies[0].same_instance(snapshot_pd_h))
      `uvm_error("SNAPSHOT_QP_VALUE",
                 "caller mutation changed authoritative QP ownership")
    expect_status("SNAPSHOT_TEARDOWN",
                  snapshot_rm.release_function(owner_h), RDMA_SC_OK);
    expect_status("SNAPSHOT_RETIRED_LOOKUP",
                  snapshot_rm.lookup(snapshot_qp_h, resource),
                  RDMA_SC_STALE_GENERATION);

    // Generation observation is monotonic.  Seeing B makes A stale forever,
    // even if the caller later writes A back into the source binding.
    rollback_rm = rdma_resource_manager::type_id::create("rollback_rm");
    rollback_binding = make_active_binding(
      "rollback_binding", 64'hb011_bacc_0000_0001,
      32'hb011_0101, 32'd41
    );
    owner_h = rollback_binding.make_handle();
    expect_status("ROLLBACK_CREATE_A",
                  rollback_rm.create_pd(rollback_binding, rollback_pd),
                  RDMA_SC_OK);
    rollback_h = clone_handle("ROLLBACK_H", rollback_pd.handle);
    rollback_binding.generation = 32'd42;
    rollback_binding.owner_h = rollback_binding.make_handle();
    expect_status("ROLLBACK_A_STALE_AT_B",
                  rollback_rm.lookup(rollback_h, resource),
                  RDMA_SC_STALE_GENERATION);
    rollback_binding.generation = 32'd41;
    rollback_binding.owner_h = rollback_binding.make_handle();
    expect_status("ROLLBACK_A_STAYS_STALE",
                  rollback_rm.lookup(rollback_h, resource),
                  RDMA_SC_STALE_GENERATION);
    expect_status("ROLLBACK_PRIVILEGED_TEARDOWN",
                  rollback_rm.release_function(owner_h), RDMA_SC_OK);
    expect_status("ROLLBACK_REPEATED_TEARDOWN",
                  rollback_rm.release_function(owner_h),
                  RDMA_SC_STALE_GENERATION);

    // A new Function generation cannot be admitted while an older generation
    // still owns live resources.  Once the old generation is drained, the
    // local ID may be reused but the old cloned handle remains stale.
    generation_rm = rdma_resource_manager::type_id::create("generation_rm");
    binding_a = make_active_binding("generation_binding",
                                    64'h600d_0000_0000_0001,
                                    32'h600d_0001, 32'd31);
    owner_h = binding_a.make_handle();
    expect_status("GENERATION_CREATE_OLD",
                  generation_rm.create_pd(binding_a, generation_pd),
                  RDMA_SC_OK);
    generation_old_h = clone_handle("GENERATION_OLD_H",
                                    generation_pd.handle);
    binding_a.generation++;
    binding_a.owner_h = binding_a.make_handle();
    expect_status("GENERATION_REJECT_OVERLAP",
                  generation_rm.create_pd(binding_a,
                                          rejected_generation_pd),
                  RDMA_SC_INVALID_STATE);
    if (rejected_generation_pd != null)
      `uvm_error("GENERATION_REJECT_OVERLAP",
                 "overlapping Function generation returned a resource")
    expect_status("GENERATION_RELEASE_OLD",
                  generation_rm.release_function(owner_h), RDMA_SC_OK);
    expect_status("GENERATION_OLD_LOOKUP_RETIRED",
                  generation_rm.lookup(generation_old_h, resource),
                  RDMA_SC_STALE_GENERATION);
    expect_status("GENERATION_OLD_RELEASE_RETIRED",
                  generation_rm.\release (generation_old_h),
                  RDMA_SC_STALE_GENERATION);
    expect_status("GENERATION_OLD_TEARDOWN_RETIRED",
                  generation_rm.release_function(owner_h),
                  RDMA_SC_STALE_GENERATION);
    expect_status("GENERATION_CREATE_NEXT",
                  generation_rm.create_pd(binding_a, next_generation_pd),
                  RDMA_SC_OK);
    if (next_generation_pd == null) begin
      `uvm_error("GENERATION_REUSE",
                 "next Function generation returned no resource")
    end
    else if (next_generation_pd.local_pd_id != generation_pd.local_pd_id ||
             next_generation_pd.handle.object_id ==
               generation_old_h.object_id)
      `uvm_error("GENERATION_REUSE",
                 "generation transition violated ID/incarnation rules")
    expect_status("GENERATION_OLD_STAYS_STALE",
                  generation_rm.lookup(generation_old_h, resource),
                  RDMA_SC_STALE_GENERATION);
    expect_status("GENERATION_RELEASE_NEXT",
                  generation_rm.release_function(binding_a.make_handle()),
                  RDMA_SC_OK);
    if (next_generation_pd != null)
      expect_status("GENERATION_NEXT_RETIRED",
                    generation_rm.lookup(next_generation_pd.handle, resource),
                    RDMA_SC_STALE_GENERATION);

    // A display-key collision on uid/generation must not alias distinct
    // complete Function instances.
    identity_rm = rdma_resource_manager::type_id::create("identity_rm");
    binding_a = make_active_binding("identity_binding_a",
                                    64'hface_cafe_0123_4567,
                                    32'h1111_0001, 32'd19);
    binding_b = make_active_binding("identity_binding_b",
                                    64'hface_cafe_0123_4567,
                                    32'h2222_0002, 32'd19);
    expect_status("IDENTITY_CREATE_A",
                  identity_rm.create_pd(binding_a, pd), RDMA_SC_OK);
    expect_status("IDENTITY_CREATE_B",
                  identity_rm.create_pd(binding_b, pd_b), RDMA_SC_OK);
    owner_b_h = clone_function_handle("IDENTITY_OWNER_B", pd_b.owner);
    binding_b.generation++;
    expect_status("IDENTITY_A_REMAINS_LIVE",
                  identity_rm.lookup(pd.handle, resource), RDMA_SC_OK);
    expect_status("IDENTITY_B_IS_STALE",
                  identity_rm.lookup(pd_b.handle, resource),
                  RDMA_SC_STALE_GENERATION);
    expect_status("IDENTITY_RELEASE_A",
                  identity_rm.release_function(binding_a.make_handle()),
                  RDMA_SC_OK);
    expect_status("IDENTITY_RELEASE_B",
                  identity_rm.release_function(owner_b_h),
                  RDMA_SC_OK);
    expect_status("IDENTITY_B_RETIRED",
                  identity_rm.lookup(pd_b.handle, resource),
                  RDMA_SC_STALE_GENERATION);

    // Dependency checks reject unsafe release; explicit leaf-first release is
    // accepted once all dependents are gone.
    dep_rm = rdma_resource_manager::type_id::create("dep_rm");
    binding_a = make_active_binding("dep_binding");
    expect_status("DEP_CREATE_PD",
                  dep_rm.create_pd(binding_a, dep_pd), RDMA_SC_OK);
    expect_status("DEP_CREATE_CEQ",
                  dep_rm.create_ceq(binding_a, dep_ceq), RDMA_SC_OK);
    expect_status("DEP_CREATE_CQ",
                  dep_rm.create_cq(binding_a, dep_ceq.handle, dep_cq),
                  RDMA_SC_OK);
    expect_status("DEP_CREATE_SRQ",
                  dep_rm.create_srq(binding_a, dep_pd.handle, dep_srq),
                  RDMA_SC_OK);
    expect_status("DEP_CREATE_MR",
                  dep_rm.create_mr(binding_a, dep_pd.handle, dep_mr),
                  RDMA_SC_OK);
    expect_status("DEP_CREATE_QP",
                  dep_rm.create_qp(binding_a, dep_pd.handle,
                                   dep_cq.handle, dep_cq.handle,
                                   dep_srq.handle, dep_qp), RDMA_SC_OK);
    expect_status("DEP_RELEASE_PD_BUSY", dep_rm.\release (dep_pd.handle),
                  RDMA_SC_INVALID_STATE);
    expect_status("DEP_RELEASE_CQ_BUSY", dep_rm.\release (dep_cq.handle),
                  RDMA_SC_INVALID_STATE);
    expect_status("DEP_RELEASE_SRQ_BUSY", dep_rm.\release (dep_srq.handle),
                  RDMA_SC_INVALID_STATE);
    expect_status("DEP_RELEASE_CEQ_BUSY", dep_rm.\release (dep_ceq.handle),
                  RDMA_SC_INVALID_STATE);
    expect_status("DEP_RELEASE_QP", dep_rm.\release (dep_qp.handle),
                  RDMA_SC_OK);
    expect_status("DEP_RELEASE_MR", dep_rm.\release (dep_mr.handle),
                  RDMA_SC_OK);
    expect_status("DEP_RELEASE_SRQ", dep_rm.\release (dep_srq.handle),
                  RDMA_SC_OK);
    expect_status("DEP_RELEASE_CQ", dep_rm.\release (dep_cq.handle),
                  RDMA_SC_OK);
    expect_status("DEP_RELEASE_CEQ", dep_rm.\release (dep_ceq.handle),
                  RDMA_SC_OK);
    expect_status("DEP_RELEASE_PD", dep_rm.\release (dep_pd.handle),
                  RDMA_SC_OK);
    expect_status("DEP_NO_LEAKS", dep_rm.check_leaks(leak_count), RDMA_SC_OK);
    if (leak_count != 0)
      `uvm_error("DEP_NO_LEAKS", "released dependency graph leaked")

    // freeze locks individual release. release_function computes a complete
    // dependent-first order and is allowed to tear down frozen resources.
    teardown_rm = rdma_resource_manager::type_id::create("teardown_rm");
    binding_a = make_active_binding("teardown_binding");
    owner_h = binding_a.make_handle();
    expect_status("TEARDOWN_CREATE_PD",
                  teardown_rm.create_pd(binding_a, teardown_pd), RDMA_SC_OK);
    expect_status("TEARDOWN_CREATE_CEQ",
                  teardown_rm.create_ceq(binding_a, teardown_ceq), RDMA_SC_OK);
    expect_status("TEARDOWN_CREATE_CQ",
                  teardown_rm.create_cq(binding_a, teardown_ceq.handle,
                                        teardown_cq), RDMA_SC_OK);
    expect_status("TEARDOWN_CREATE_MR",
                  teardown_rm.create_mr(binding_a, teardown_pd.handle,
                                        teardown_mr), RDMA_SC_OK);
    expect_status("TEARDOWN_CREATE_QP",
                  teardown_rm.create_qp(binding_a, teardown_pd.handle,
                                        teardown_cq.handle,
                                        teardown_cq.handle, null,
                                        teardown_qp), RDMA_SC_OK);
    frozen_qp_h = clone_handle("TEARDOWN_QP_H", teardown_qp.handle);
    expect_status("TEARDOWN_FREEZE_PD",
                  teardown_rm.freeze(teardown_pd.handle),
                  RDMA_SC_INVALID_STATE);
    expect_status("TEARDOWN_FREEZE_CEQ",
                  teardown_rm.freeze(teardown_ceq.handle),
                  RDMA_SC_INVALID_STATE);
    expect_status("TEARDOWN_FREEZE_CQ",
                  teardown_rm.freeze(teardown_cq.handle),
                  RDMA_SC_INVALID_STATE);
    prepare_mr(teardown_mr, 64'h6100_0000);
    expect_status("TEARDOWN_STAGE_MR",
                  teardown_rm.stage_allocated(teardown_mr), RDMA_SC_OK);
    expect_status("TEARDOWN_FREEZE_MR",
                  teardown_rm.freeze(teardown_mr.handle), RDMA_SC_OK);
    expect_status("TEARDOWN_FREEZE_QP",
                  teardown_rm.freeze(teardown_qp.handle),
                  RDMA_SC_INVALID_STATE);
    expect_status("TEARDOWN_FROZEN_LOOKUP",
                  teardown_rm.lookup(teardown_mr.handle, resource), RDMA_SC_OK);
    if (resource == null || resource.state != RDMA_RESOURCE_PROGRAMMED)
      `uvm_error("TEARDOWN_FROZEN_LOOKUP",
                 "freeze did not publish PROGRAMMED state")
    expect_status("TEARDOWN_FROZEN_RELEASE",
                  teardown_rm.\release (teardown_mr.handle),
                  RDMA_SC_INVALID_STATE);
    expect_status("TEARDOWN_HAS_LEAKS",
                  teardown_rm.check_leaks(leak_count, owner_h),
                  RDMA_SC_INVALID_STATE);
    if (leak_count != 5)
      `uvm_error("TEARDOWN_HAS_LEAKS",
                 $sformatf("expected 5 leaks, got %0d", leak_count))
    expect_status("TEARDOWN_RELEASE_FUNCTION",
                  teardown_rm.release_function(owner_h), RDMA_SC_OK);
    expect_status("TEARDOWN_USE_AFTER_FREE",
                  teardown_rm.lookup(frozen_qp_h, resource),
                  RDMA_SC_STALE_GENERATION);
    expect_status("TEARDOWN_RELEASE_AFTER_FREE",
                  teardown_rm.\release (frozen_qp_h),
                  RDMA_SC_STALE_GENERATION);
    expect_status("TEARDOWN_NO_LEAKS",
                  teardown_rm.check_leaks(leak_count, owner_h), RDMA_SC_OK);
    if (leak_count != 0)
      `uvm_error("TEARDOWN_NO_LEAKS", "release_function leaked resources")
    expect_status("TEARDOWN_REPEATED_FUNCTION",
                  teardown_rm.release_function(owner_h),
                  RDMA_SC_STALE_GENERATION);

    // A Function is the retirement boundary.  Ordinary release must preserve
    // it so only privileged Function teardown can atomically retire topology.
    function_release_rm = rdma_resource_manager::type_id::create(
      "function_release_rm"
    );
    function_release_binding = make_active_binding(
      "function_release_binding", 64'hf00d_0000_0000_0001,
      32'hf00d_0101, 32'd77
    );
    function_release_binding.vsi_id = 32'hf00d_0202;
    expect_status(
      "FUNCTION_ORDINARY_RELEASE_CREATE",
      function_release_rm.create_function(function_release_binding,
                                           function_release_function),
      RDMA_SC_OK
    );
    owner_h = clone_function_handle("FUNCTION_ORDINARY_RELEASE_OWNER",
                                    function_release_function.owner);
    function_release_h = clone_handle("FUNCTION_ORDINARY_RELEASE_HANDLE",
                                      function_release_function.handle);
    expect_status(
      "FUNCTION_ORDINARY_RELEASE_REJECT",
      function_release_rm.\release (function_release_h),
      RDMA_SC_INVALID_STATE
    );
    expect_status(
      "FUNCTION_ORDINARY_RELEASE_STILL_LIVE",
      function_release_rm.lookup(function_release_h, resource), RDMA_SC_OK
    );
    if (resource == null || !$cast(function_release_lookup, resource)) begin
      `uvm_error("FUNCTION_ORDINARY_RELEASE_STILL_LIVE",
                 "ordinary release removed or changed Function type")
    end
    else if (!function_release_lookup.handle.same_instance(
               function_release_h
             ) ||
             !function_release_lookup.owner.same_instance(owner_h) ||
             function_release_lookup.local_function_id !=
               function_release_function.local_function_id ||
             function_release_lookup.rdma_vf_id !=
               function_release_binding.rdma_vf_id ||
             function_release_lookup.vsi_id !=
               function_release_binding.vsi_id ||
             function_release_lookup.pfvf_id !=
               function_release_binding.pfvf_id)
      `uvm_error("FUNCTION_ORDINARY_RELEASE_UNCHANGED",
                 "rejected ordinary release changed the live Function")
    expect_status(
      "FUNCTION_ORDINARY_RELEASE_CREATE_PD",
      function_release_rm.create_pd(function_release_binding,
                                    function_release_pd),
      RDMA_SC_OK
    );
    expect_status(
      "FUNCTION_ORDINARY_RELEASE_TEARDOWN",
      function_release_rm.release_function(owner_h), RDMA_SC_OK
    );
    expect_status(
      "FUNCTION_ORDINARY_RELEASE_RETIRED",
      function_release_rm.lookup(function_release_h, resource),
      RDMA_SC_STALE_GENERATION
    );
    expect_status(
      "FUNCTION_ORDINARY_RELEASE_RETIRED_RELEASE",
      function_release_rm.\release (function_release_h),
      RDMA_SC_STALE_GENERATION
    );
    expect_status(
      "FUNCTION_ORDINARY_RELEASE_PD_RETIRED",
      function_release_rm.lookup(function_release_pd.handle, resource),
      RDMA_SC_STALE_GENERATION
    );
    expect_status(
      "FUNCTION_ORDINARY_RELEASE_NO_LEAKS",
      function_release_rm.check_leaks(leak_count, owner_h), RDMA_SC_OK
    );
    if (leak_count != 0)
      `uvm_error("FUNCTION_ORDINARY_RELEASE_NO_LEAKS",
                 "privileged Function teardown leaked topology")

    // Function generations are exact non-reusable incarnations.  A -> B -> A
    // rollback is rejected, and max -> zero is exhaustion rather than wrap.
    function_cycle_rm = rdma_resource_manager::type_id::create(
      "function_cycle_rm"
    );
    function_cycle_binding = make_active_binding(
      "function_cycle_binding", 64'hf00c_0000_0000_0001,
      32'hf00c_0101, 32'd5
    );
    expect_status("FUNCTION_CYCLE_CREATE_A",
                  function_cycle_rm.create_function(function_cycle_binding,
                                                    function_a),
                  RDMA_SC_OK);
    owner_h = clone_function_handle("FUNCTION_CYCLE_OWNER_A",
                                    function_a.owner);
    expect_status("FUNCTION_CYCLE_RELEASE_A",
                  function_cycle_rm.release_function(owner_h), RDMA_SC_OK);
    function_cycle_binding.generation = 32'd6;
    function_cycle_binding.owner_h = function_cycle_binding.make_handle();
    expect_status("FUNCTION_CYCLE_CREATE_B",
                  function_cycle_rm.create_function(function_cycle_binding,
                                                    function_b),
                  RDMA_SC_OK);
    if (function_b.local_function_id != function_a.local_function_id ||
        function_b.handle.same_instance(function_a.handle))
      `uvm_error("FUNCTION_CYCLE_B",
                 "Function local ID/incarnation transition is invalid")
    owner_b_h = clone_function_handle("FUNCTION_CYCLE_OWNER_B",
                                      function_b.owner);
    expect_status("FUNCTION_CYCLE_RELEASE_B",
                  function_cycle_rm.release_function(owner_b_h), RDMA_SC_OK);
    function_cycle_binding.generation = 32'd5;
    function_cycle_binding.owner_h = function_cycle_binding.make_handle();
    expect_status("FUNCTION_CYCLE_REJECT_A",
                  function_cycle_rm.create_function(function_cycle_binding,
                                                    rejected_function),
                  RDMA_SC_STALE_GENERATION);
    if (rejected_function != null)
      `uvm_error("FUNCTION_CYCLE_REJECT_A",
                 "retired Function generation was recreated")

    function_wrap_rm = rdma_resource_manager::type_id::create(
      "function_wrap_rm"
    );
    function_wrap_binding = make_active_binding(
      "function_wrap_binding", 64'hf00c_0000_0000_0002,
      32'hf00c_0202, 32'hffff_ffff
    );
    expect_status("FUNCTION_WRAP_CREATE_MAX",
                  function_wrap_rm.create_function(function_wrap_binding,
                                                   function_max),
                  RDMA_SC_OK);
    owner_h = clone_function_handle("FUNCTION_WRAP_OWNER_MAX",
                                    function_max.owner);
    expect_status("FUNCTION_WRAP_RELEASE_MAX",
                  function_wrap_rm.release_function(owner_h), RDMA_SC_OK);
    function_wrap_binding.generation = 32'd0;
    function_wrap_binding.owner_h = function_wrap_binding.make_handle();
    expect_status("FUNCTION_WRAP_REJECT_ZERO",
                  function_wrap_rm.create_function(function_wrap_binding,
                                                   function_wrapped),
                  RDMA_SC_RESOURCE_EXHAUSTED);
    if (function_wrapped != null)
      `uvm_error("FUNCTION_WRAP_REJECT_ZERO",
                 "wrapped Function generation returned a resource")
    expect_status("FUNCTION_WRAP_OLD_STALE",
                  function_wrap_rm.lookup(owner_h, resource),
                  RDMA_SC_STALE_GENERATION);

    // Once max -> zero is observed, exhaustion is permanent even if the same
    // live source is written back to max.  Rejected retries are atomic and the
    // privileged teardown path remains available for the old max topology.
    permanent_exhaustion_rm = new("permanent_exhaustion_rm");
    permanent_exhaustion_binding = make_active_binding(
      "permanent_exhaustion_binding", 64'hf00c_0000_0000_0003,
      32'hf00c_0303, 32'hffff_ffff
    );
    expect_status(
      "PERMANENT_EXHAUSTION_CREATE_MAX",
      permanent_exhaustion_rm.create_function(
        permanent_exhaustion_binding, permanent_exhaustion_function
      ),
      RDMA_SC_OK
    );
    owner_h = clone_function_handle(
      "PERMANENT_EXHAUSTION_OWNER_MAX", permanent_exhaustion_function.owner
    );
    old_h = clone_handle("PERMANENT_EXHAUSTION_OLD_HANDLE",
                         permanent_exhaustion_function.handle);
    expect_status(
      "PERMANENT_EXHAUSTION_INITIAL_LIVE",
      permanent_exhaustion_rm.check_leaks(leak_count, owner_h),
      RDMA_SC_INVALID_STATE
    );
    if (leak_count != 1)
      `uvm_error("PERMANENT_EXHAUSTION_INITIAL_LIVE",
                 $sformatf("expected 1 live resource, got %0d", leak_count))

    pd_local_before_exhaustion =
      permanent_exhaustion_rm.observed_next_local_id(RDMA_RESOURCE_PD);
    pd_serial_before_exhaustion =
      permanent_exhaustion_rm.observed_next_object_serial(RDMA_RESOURCE_PD);
    cmq_local_before_exhaustion =
      permanent_exhaustion_rm.observed_next_local_id(RDMA_RESOURCE_CMQ);
    cmq_serial_before_exhaustion =
      permanent_exhaustion_rm.observed_next_object_serial(RDMA_RESOURCE_CMQ);

    permanent_exhaustion_binding.generation = 32'd0;
    permanent_exhaustion_binding.owner_h =
      permanent_exhaustion_binding.make_handle();
    expect_status(
      "PERMANENT_EXHAUSTION_REJECT_ZERO",
      permanent_exhaustion_rm.create_pd(permanent_exhaustion_binding,
                                        permanent_exhaustion_pd),
      RDMA_SC_RESOURCE_EXHAUSTED
    );
    if (permanent_exhaustion_pd != null)
      `uvm_error("PERMANENT_EXHAUSTION_REJECT_ZERO",
                 "zero generation returned a PD")

    permanent_exhaustion_binding.generation = 32'hffff_ffff;
    permanent_exhaustion_binding.owner_h =
      permanent_exhaustion_binding.make_handle();
    expect_status(
      "PERMANENT_EXHAUSTION_REJECT_MAX_PD",
      permanent_exhaustion_rm.create_pd(permanent_exhaustion_binding,
                                        permanent_exhaustion_pd),
      RDMA_SC_RESOURCE_EXHAUSTED
    );
    if (permanent_exhaustion_pd != null)
      `uvm_error("PERMANENT_EXHAUSTION_REJECT_MAX_PD",
                 "max-generation retry returned a PD")
    expect_status(
      "PERMANENT_EXHAUSTION_REJECT_MAX_CMQ",
      permanent_exhaustion_rm.create_cmq(permanent_exhaustion_binding,
                                         permanent_exhaustion_cmq),
      RDMA_SC_RESOURCE_EXHAUSTED
    );
    if (permanent_exhaustion_cmq != null)
      `uvm_error("PERMANENT_EXHAUSTION_REJECT_MAX_CMQ",
                 "max-generation retry returned a CMQ")
    expect_status(
      "PERMANENT_EXHAUSTION_NO_GHOSTS",
      permanent_exhaustion_rm.check_leaks(leak_count, owner_h),
      RDMA_SC_INVALID_STATE
    );
    if (leak_count != 1)
      `uvm_error("PERMANENT_EXHAUSTION_NO_GHOSTS",
                 $sformatf("failed creates changed leak count to %0d",
                           leak_count))
    if (permanent_exhaustion_rm.observed_next_local_id(RDMA_RESOURCE_PD) !=
          pd_local_before_exhaustion ||
        permanent_exhaustion_rm.observed_next_object_serial(
          RDMA_RESOURCE_PD
        ) != pd_serial_before_exhaustion)
      `uvm_error("PERMANENT_EXHAUSTION_PD_ATOMIC",
                 "failed PD creates consumed an ID or incarnation serial")
    if (permanent_exhaustion_rm.observed_next_local_id(RDMA_RESOURCE_CMQ) !=
          cmq_local_before_exhaustion ||
        permanent_exhaustion_rm.observed_next_object_serial(
          RDMA_RESOURCE_CMQ
        ) != cmq_serial_before_exhaustion)
      `uvm_error("PERMANENT_EXHAUSTION_CMQ_ATOMIC",
                 "failed CMQ create consumed an ID or incarnation serial")
    expect_status(
      "PERMANENT_EXHAUSTION_OLD_LOOKUP",
      permanent_exhaustion_rm.lookup(old_h, resource),
      RDMA_SC_STALE_GENERATION
    );
    expect_status(
      "PERMANENT_EXHAUSTION_OLD_RELEASE",
      permanent_exhaustion_rm.\release (old_h),
      RDMA_SC_STALE_GENERATION
    );
    expect_status(
      "PERMANENT_EXHAUSTION_PRIVILEGED_TEARDOWN",
      permanent_exhaustion_rm.release_function(owner_h), RDMA_SC_OK
    );
    expect_status(
      "PERMANENT_EXHAUSTION_NO_LEAKS",
      permanent_exhaustion_rm.check_leaks(leak_count, owner_h), RDMA_SC_OK
    );
    if (leak_count != 0)
      `uvm_error("PERMANENT_EXHAUSTION_NO_LEAKS",
                 "privileged teardown leaked the max-generation topology")
    expect_status(
      "PERMANENT_EXHAUSTION_AFTER_TEARDOWN",
      permanent_exhaustion_rm.create_aeq(permanent_exhaustion_binding,
                                         permanent_exhaustion_aeq),
      RDMA_SC_RESOURCE_EXHAUSTED
    );
    if (permanent_exhaustion_aeq != null)
      `uvm_error("PERMANENT_EXHAUSTION_AFTER_TEARDOWN",
                 "post-teardown retry returned an AEQ")
    expect_status(
      "PERMANENT_EXHAUSTION_RETIRED_LOOKUP",
      permanent_exhaustion_rm.lookup(old_h, resource),
      RDMA_SC_STALE_GENERATION
    );
    expect_status(
      "PERMANENT_EXHAUSTION_RETIRED_RELEASE",
      permanent_exhaustion_rm.\release (old_h),
      RDMA_SC_STALE_GENERATION
    );

    // Incarnation exhaustion is a clean failure; it never wraps to revive an
    // earlier handle, and another kind's serial pool remains independent.
    exhaustion_rm = new("exhaustion_rm");
    exhaustion_binding = make_active_binding("exhaustion_binding");
    exhaustion_rm.force_next_object_serial(RDMA_RESOURCE_PD,
                                            32'h1000_0000);
    expect_status("SERIAL_EXHAUSTED",
                  exhaustion_rm.create_pd(exhaustion_binding, exhausted_pd),
                  RDMA_SC_RESOURCE_EXHAUSTED);
    if (exhausted_pd != null)
      `uvm_error("SERIAL_EXHAUSTED", "serial exhaustion returned a PD")
    expect_status("SERIAL_OTHER_KIND",
                  exhaustion_rm.create_aeq(exhaustion_binding, frozen_aeq),
                  RDMA_SC_OK);
    expect_status("SERIAL_OTHER_KIND_RELEASE",
                  exhaustion_rm.\release (frozen_aeq.handle), RDMA_SC_OK);
    expect_status("SERIAL_NO_LEAKS",
                  exhaustion_rm.check_leaks(leak_count), RDMA_SC_OK);

    // Every resource kind owns a separate local ID pool.  The first object in
    // each pool therefore receives local ID zero, independent of creation
    // order in the other pools.
    all_kind_rm = rdma_resource_manager::type_id::create("all_kind_rm");
    binding_a = make_active_binding("all_kind_binding",
                                    64'ha110_ca7e_0000_0001,
                                    32'h0102_0304, 32'd23);
    expect_status("ALL_KIND_FUNCTION",
                  all_kind_rm.create_function(binding_a, all_kind_function),
                  RDMA_SC_OK);
    expect_status("ALL_KIND_PD",
                  all_kind_rm.create_pd(binding_a, all_kind_pd), RDMA_SC_OK);
    expect_status("ALL_KIND_CEQ",
                  all_kind_rm.create_ceq(binding_a, all_kind_ceq), RDMA_SC_OK);
    expect_status("ALL_KIND_CQ",
                  all_kind_rm.create_cq(binding_a, all_kind_ceq.handle,
                                        all_kind_cq), RDMA_SC_OK);
    expect_status("ALL_KIND_SRQ",
                  all_kind_rm.create_srq(binding_a, all_kind_pd.handle,
                                         all_kind_srq), RDMA_SC_OK);
    expect_status("ALL_KIND_MR",
                  all_kind_rm.create_mr(binding_a, all_kind_pd.handle,
                                        all_kind_mr), RDMA_SC_OK);
    expect_status("ALL_KIND_QP",
                  all_kind_rm.create_qp(binding_a, all_kind_pd.handle,
                                        all_kind_cq.handle,
                                        all_kind_cq.handle,
                                        all_kind_srq.handle,
                                        all_kind_qp), RDMA_SC_OK);
    expect_status("ALL_KIND_CMQ",
                  all_kind_rm.create_cmq(binding_a, all_kind_cmq),
                  RDMA_SC_OK);
    expect_status("ALL_KIND_AEQ",
                  all_kind_rm.create_aeq(binding_a, all_kind_aeq),
                  RDMA_SC_OK);
    prepare_mr(all_kind_mr, 64'h7100_0000);
    all_kind_ceq.depth = 8;
    all_kind_cq.depth = 8;
    all_kind_srq.depth = 8;
    all_kind_srq.max_sge = 4;
    all_kind_qp.sq_depth = 8;
    all_kind_qp.rq_depth = 8;
    all_kind_cmq.depth = 8;
    all_kind_aeq.depth = 8;
    all_kind_resources.delete();
    all_kind_resources.push_back(all_kind_function);
    all_kind_resources.push_back(all_kind_pd);
    all_kind_resources.push_back(all_kind_mr);
    all_kind_resources.push_back(all_kind_cq);
    all_kind_resources.push_back(all_kind_qp);
    all_kind_resources.push_back(all_kind_srq);
    all_kind_resources.push_back(all_kind_cmq);
    all_kind_resources.push_back(all_kind_ceq);
    all_kind_resources.push_back(all_kind_aeq);
    foreach (all_kind_resources[i]) begin
      expect_status(
        $sformatf("ALL_KIND_%s_STAGE",
                  all_kind_resources[i].resource_kind().name()),
        all_kind_rm.stage_allocated(all_kind_resources[i]), RDMA_SC_OK
      );
      if (all_kind_resources[i].resource_kind() != RDMA_RESOURCE_PD)
        expect_status(
          $sformatf("ALL_KIND_%s_COMMIT",
                    all_kind_resources[i].resource_kind().name()),
          all_kind_rm.commit_programmed(all_kind_resources[i]), RDMA_SC_OK
        );
      expect_status(
        $sformatf("ALL_KIND_%s_ACTIVATE",
                  all_kind_resources[i].resource_kind().name()),
        all_kind_rm.activate(all_kind_resources[i].handle), RDMA_SC_OK
      );
      expect_status(
        $sformatf("ALL_KIND_%s_LOOKUP",
                  all_kind_resources[i].resource_kind().name()),
        all_kind_rm.lookup(all_kind_resources[i].handle, resource),
        RDMA_SC_OK
      );
      if (resource == null || resource.state != RDMA_RESOURCE_ACTIVE)
        `uvm_error("ALL_KIND_LOOKUP",
                   "exact lifecycle lookup did not return ACTIVE authority")
      recovery_record = new(
        $sformatf("all_kind_%s_recovery",
                  all_kind_resources[i].resource_kind().name())
      );
      recovery_record.resource_h = clone_handle(
        "ALL_KIND_RECOVERY_H", all_kind_resources[i].handle
      );
      recovery_record.hardware_presence = RDMA_HW_PRESENCE_ABSENT;
      recovery_record.primary_status = rdma_status::make(
        RDMA_SC_RESET_CANCELLED, "all-kind exact recovery probe"
      );
      expect_status(
        $sformatf("ALL_KIND_%s_MARK_ERROR",
                  all_kind_resources[i].resource_kind().name()),
        all_kind_rm.mark_error(all_kind_resources[i].handle,
                               recovery_record),
        RDMA_SC_OK
      );
      expect_status(
        $sformatf("ALL_KIND_%s_RECOVERY_LOOKUP",
                  all_kind_resources[i].resource_kind().name()),
        all_kind_rm.lookup_recovery(all_kind_resources[i].handle,
                                    recovery_lookup),
        RDMA_SC_OK
      );
      expect_status(
        $sformatf("ALL_KIND_%s_RECOVERY_CLEAR",
                  all_kind_resources[i].resource_kind().name()),
        all_kind_rm.clear_recovery(all_kind_resources[i].handle),
        RDMA_SC_OK
      );
    end
    if (all_kind_function.local_function_id != 0 ||
        all_kind_pd.local_pd_id != 0 || all_kind_mr.local_mr_id != 0 ||
        all_kind_cq.local_cq_id != 0 || all_kind_qp.local_qp_id != 0 ||
        all_kind_srq.local_srq_id != 0 ||
        all_kind_cmq.local_cmq_id != 0 ||
        all_kind_ceq.local_ceq_id != 0 ||
        all_kind_aeq.local_aeq_id != 0)
      `uvm_error("ALL_KIND_POOLS",
                 "resource kinds did not use independent local ID pools")
    expect_status("ALL_KIND_RELEASE_FUNCTION",
                  all_kind_rm.release_function(binding_a.make_handle()),
                  RDMA_SC_OK);
    expect_status("ALL_KIND_NO_LEAKS",
                  all_kind_rm.check_leaks(leak_count), RDMA_SC_OK);

    // HMC/FVM is an independent aperture and lease registry.  Deliberately
    // make its first address numerically equal to an IOVA and prove that the
    // wrapper/API domain remains distinct and no DMA mapping is modified.
    hmc = rdma_hmc_allocator::type_id::create("hmc");
    hmc_base.value = 64'h0000_0001_0000_0000;
    equal_iova.value = hmc_base.value;
    untouched_mapping = rdma_dma_mapping::type_id::create(
      "untouched_mapping"
    );
    untouched_mapping.iova = equal_iova;
    untouched_mapping.backing_addr.value = 64'hdead_beef_0000_0000;
    expect_status("HMC_CONFIGURE", hmc.configure(hmc_base, 64'h1000),
                  RDMA_SC_OK);
    owner_h = exhaustion_binding.make_handle();
    expect_status("HMC_ALLOCATE_EQUAL_IOVA",
                  hmc.allocate(owner_h, RDMA_RESOURCE_QP, 64, 64, hmc_addr),
                  RDMA_SC_OK);
    hmc_type_name = $typename(hmc_addr);
    iova_type_name = $typename(equal_iova);
    if (hmc_addr.value != equal_iova.value ||
        hmc_type_name == iova_type_name)
      `uvm_error("HMC_WRAPPER",
                 "equal numeric values collapsed HMC and IOVA domains")
    if (untouched_mapping.iova != equal_iova ||
        untouched_mapping.backing_addr.value !=
          64'hdead_beef_0000_0000)
      `uvm_error("HMC_DMA_SEPARATION",
                 "HMC allocation modified a DMA mapping")
    expect_status("HMC_LOOKUP",
                  hmc.lookup(owner_h, RDMA_RESOURCE_QP, hmc_addr,
                             lease_size), RDMA_SC_OK);
    if (lease_size != 64)
      `uvm_error("HMC_LOOKUP", "HMC lease size was not retained")

    owner_b_h = clone_function_handle("HMC_OTHER_OWNER", owner_h);
    owner_b_h.object_id++;
    expect_status("HMC_RELEASE_WRONG_OWNER",
                  hmc.\release (owner_b_h, RDMA_RESOURCE_QP, hmc_addr),
                  RDMA_SC_INVALID_ARGUMENT);
    expect_status("HMC_ACTIVE_AFTER_WRONG_OWNER",
                  hmc.lookup(owner_h, RDMA_RESOURCE_QP, hmc_addr,
                             lease_size), RDMA_SC_OK);
    expect_status("HMC_WRONG_OWNER",
                  hmc.lookup(owner_b_h, RDMA_RESOURCE_QP, hmc_addr,
                             lease_size), RDMA_SC_INVALID_ARGUMENT);
    owner_b_h = clone_function_handle("HMC_STALE_OWNER", owner_h);
    owner_b_h.generation++;
    expect_status("HMC_RELEASE_STALE_OWNER",
                  hmc.\release (owner_b_h, RDMA_RESOURCE_QP, hmc_addr),
                  RDMA_SC_STALE_GENERATION);
    expect_status("HMC_ACTIVE_AFTER_STALE_OWNER",
                  hmc.lookup(owner_h, RDMA_RESOURCE_QP, hmc_addr,
                             lease_size), RDMA_SC_OK);
    expect_status("HMC_STALE_OWNER",
                  hmc.lookup(owner_b_h, RDMA_RESOURCE_QP, hmc_addr,
                             lease_size), RDMA_SC_STALE_GENERATION);
    expect_status("HMC_RELEASE_WRONG_KIND",
                  hmc.\release (owner_h, RDMA_RESOURCE_CQ, hmc_addr),
                  RDMA_SC_INVALID_ARGUMENT);
    expect_status("HMC_ACTIVE_AFTER_WRONG_KIND",
                  hmc.lookup(owner_h, RDMA_RESOURCE_QP, hmc_addr,
                             lease_size), RDMA_SC_OK);
    expect_status("HMC_WRONG_KIND",
                  hmc.lookup(owner_h, RDMA_RESOURCE_CQ, hmc_addr,
                             lease_size), RDMA_SC_INVALID_ARGUMENT);
    expect_status("HMC_RELEASE",
                  hmc.\release (owner_h, RDMA_RESOURCE_QP, hmc_addr),
                  RDMA_SC_OK);
    expect_status("HMC_USE_AFTER_FREE",
                  hmc.lookup(owner_h, RDMA_RESOURCE_QP, hmc_addr,
                             lease_size), RDMA_SC_INVALID_STATE);
    expect_status("HMC_REPEAT_RELEASE",
                  hmc.\release (owner_h, RDMA_RESOURCE_QP, hmc_addr),
                  RDMA_SC_INVALID_STATE);

    // Alignment, per-Function lease teardown, and owner isolation.
    expect_status("HMC_ALLOCATE_ALIGNED",
                  hmc.allocate(owner_h, RDMA_RESOURCE_CQ, 32, 256,
                               hmc_addr), RDMA_SC_OK);
    if ((hmc_addr.value & 64'hff) != 0)
      `uvm_error("HMC_ALIGNMENT", "HMC allocation is not 256-byte aligned")
    expect_status("HMC_ALLOCATE_SECOND",
                  hmc.allocate(owner_h, RDMA_RESOURCE_PD, 16, 16,
                               hmc_addr_two), RDMA_SC_OK);
    owner_b_h = clone_function_handle("HMC_OTHER_FUNCTION", owner_h);
    owner_b_h.object_id += 32'h100;
    expect_status("HMC_ALLOCATE_OTHER_OWNER",
                  hmc.allocate(owner_b_h, RDMA_RESOURCE_MR, 16, 16,
                               hmc_other_addr), RDMA_SC_OK);
    expect_status("HMC_HAS_LEASES",
                  hmc.check_leaks(leak_count, owner_h),
                  RDMA_SC_INVALID_STATE);
    if (leak_count != 2)
      `uvm_error("HMC_HAS_LEASES",
                 $sformatf("expected 2 HMC leases, got %0d", leak_count))
    expect_status("HMC_RELEASE_FUNCTION",
                  hmc.release_function(owner_h), RDMA_SC_OK);
    expect_status("HMC_FUNCTION_RELEASED",
                  hmc.lookup(owner_h, RDMA_RESOURCE_CQ, hmc_addr,
                             lease_size), RDMA_SC_INVALID_STATE);
    expect_status("HMC_OTHER_OWNER_REMAINS",
                  hmc.lookup(owner_b_h, RDMA_RESOURCE_MR, hmc_other_addr,
                             lease_size), RDMA_SC_OK);
    expect_status("HMC_RELEASE_OTHER_OWNER",
                  hmc.release_function(owner_b_h), RDMA_SC_OK);
    expect_status("HMC_NO_LEAKS", hmc.check_leaks(leak_count), RDMA_SC_OK);

    // Function generations occupy isolated lease namespaces.  Teardown of one
    // generation must neither fail because of nor release another generation.
    owner_h = exhaustion_binding.make_handle();
    owner_b_h = clone_function_handle("HMC_NEXT_GENERATION", owner_h);
    owner_b_h.generation++;
    expect_status("HMC_GENERATION_OLD_ALLOC",
                  hmc.allocate(owner_h, RDMA_RESOURCE_CEQ, 16, 16,
                               hmc_addr), RDMA_SC_OK);
    expect_status("HMC_GENERATION_NEXT_ALLOC",
                  hmc.allocate(owner_b_h, RDMA_RESOURCE_CEQ, 16, 16,
                               hmc_addr_two), RDMA_SC_OK);
    expect_status("HMC_GENERATION_NEXT_RELEASE",
                  hmc.release_function(owner_b_h), RDMA_SC_OK);
    expect_status("HMC_GENERATION_OLD_REMAINS",
                  hmc.lookup(owner_h, RDMA_RESOURCE_CEQ, hmc_addr,
                             lease_size), RDMA_SC_OK);
    expect_status("HMC_GENERATION_NEXT_GONE",
                  hmc.lookup(owner_b_h, RDMA_RESOURCE_CEQ, hmc_addr_two,
                             lease_size), RDMA_SC_INVALID_STATE);
    expect_status("HMC_GENERATION_OLD_RELEASE",
                  hmc.release_function(owner_h), RDMA_SC_OK);
    expect_status("HMC_GENERATION_NO_LEAKS",
                  hmc.check_leaks(leak_count), RDMA_SC_OK);

    // Invalid sizes/alignments and aperture exhaustion do not advance or
    // manufacture leases.
    hmc_exhaustion = rdma_hmc_allocator::type_id::create("hmc_exhaustion");
    hmc_base.value = 64'h0000_0000_0000_1003;
    expect_status("HMC_SMALL_CONFIGURE",
                  hmc_exhaustion.configure(hmc_base, 64'hfd), RDMA_SC_OK);
    expect_status("HMC_ZERO_SIZE",
                  hmc_exhaustion.allocate(owner_h, RDMA_RESOURCE_QP,
                                          0, 16, hmc_addr),
                  RDMA_SC_INVALID_ARGUMENT);
    expect_status("HMC_ZERO_ALIGNMENT",
                  hmc_exhaustion.allocate(owner_h, RDMA_RESOURCE_QP,
                                          16, 0, hmc_addr),
                  RDMA_SC_INVALID_ARGUMENT);
    expect_status("HMC_BAD_ALIGNMENT",
                  hmc_exhaustion.allocate(owner_h, RDMA_RESOURCE_QP,
                                          16, 24, hmc_addr),
                  RDMA_SC_INVALID_ARGUMENT);
    expect_status("HMC_SMALL_ALLOCATE",
                  hmc_exhaustion.allocate(owner_h, RDMA_RESOURCE_QP,
                                          128, 64, hmc_addr), RDMA_SC_OK);
    if (hmc_addr.value != 64'h1040)
      `uvm_error("HMC_SMALL_ALLOCATE", "alignment skipped wrong prefix")
    expect_status("HMC_APERTURE_EXHAUSTED",
                  hmc_exhaustion.allocate(owner_h, RDMA_RESOURCE_QP,
                                          65, 64, hmc_addr_two),
                  RDMA_SC_RESOURCE_EXHAUSTED);
    if (hmc_addr_two.value != 0)
      `uvm_error("HMC_APERTURE_EXHAUSTED",
                 "failed allocation returned an address")
    expect_status("HMC_SMALL_RELEASE_FUNCTION",
                  hmc_exhaustion.release_function(owner_h), RDMA_SC_OK);

    // Both aperture-end overflow and alignment addition overflow are checked
    // before allocator state is mutated.
    hmc_overflow = rdma_hmc_allocator::type_id::create("hmc_overflow");
    hmc_base.value = 64'hffff_ffff_ffff_fff0;
    expect_status("HMC_APERTURE_OVERFLOW",
                  hmc_overflow.configure(hmc_base, 64'h20),
                  RDMA_SC_INVALID_ARGUMENT);
    expect_status("HMC_OVERFLOW_CONFIGURE",
                  hmc_overflow.configure(hmc_base, 64'h10), RDMA_SC_OK);
    expect_status("HMC_ALIGNMENT_OVERFLOW",
                  hmc_overflow.allocate(owner_h, RDMA_RESOURCE_QP,
                                        1, 32, hmc_addr),
                  RDMA_SC_RESOURCE_EXHAUSTED);
    expect_status("HMC_OVERFLOW_NO_LEAKS",
                  hmc_overflow.check_leaks(leak_count), RDMA_SC_OK);

    phase.drop_objection(this);
  endtask
endclass
