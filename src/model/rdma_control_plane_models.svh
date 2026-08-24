typedef enum bit [3:0] {
  RDMA_CTRL_STEP_RESOURCE_RESERVED,
  RDMA_CTRL_STEP_BACKING_ATTACHED,
  RDMA_CTRL_STEP_HMC_ATTACHED,
  RDMA_CTRL_STEP_HW_KEY_ALLOCATED,
  RDMA_CTRL_STEP_REGISTRY_PROGRAMMED,
  RDMA_CTRL_STEP_REGISTRY_ACTIVE,
  RDMA_CTRL_STEP_HW_OCC_FLUSHED,
  RDMA_CTRL_STEP_HW_MR_DEREGISTERED,
  RDMA_CTRL_STEP_HW_DRAINED,
  RDMA_CTRL_STEP_BACKING_RELEASED,
  RDMA_CTRL_STEP_RESOURCE_RELEASED
} rdma_control_step_e;

function automatic bit rdma_control_step_valid(rdma_control_step_e step);
  return step inside {
    RDMA_CTRL_STEP_RESOURCE_RESERVED,
    RDMA_CTRL_STEP_BACKING_ATTACHED,
    RDMA_CTRL_STEP_HMC_ATTACHED,
    RDMA_CTRL_STEP_HW_KEY_ALLOCATED,
    RDMA_CTRL_STEP_REGISTRY_PROGRAMMED,
    RDMA_CTRL_STEP_REGISTRY_ACTIVE,
    RDMA_CTRL_STEP_HW_OCC_FLUSHED,
    RDMA_CTRL_STEP_HW_MR_DEREGISTERED,
    RDMA_CTRL_STEP_HW_DRAINED,
    RDMA_CTRL_STEP_BACKING_RELEASED,
    RDMA_CTRL_STEP_RESOURCE_RELEASED
  };
endfunction

function automatic bit rdma_control_step_is_hardware(
  rdma_control_step_e step
);
  return step inside {
    RDMA_CTRL_STEP_HW_KEY_ALLOCATED,
    RDMA_CTRL_STEP_HW_OCC_FLUSHED,
    RDMA_CTRL_STEP_HW_MR_DEREGISTERED,
    RDMA_CTRL_STEP_HW_DRAINED
  };
endfunction

class rdma_mr_backing_desc extends uvm_object;
  `uvm_object_utils(rdma_mr_backing_desc)

  rdma_function_handle function_h;
  rdma_bdf_t requester_bdf;
  bit pasid_valid;
  bit [19:0] pasid;
  rdma_backing_ref backing_refs[$];
  rdma_hmc_ref hmc_refs[$];
  rdma_mr_page_layout page_layout;

  function new(string name = "rdma_mr_backing_desc");
    super.new(name);
    function_h = null;
    requester_bdf = '0;
    pasid_valid = 1'b0;
    pasid = '0;
    page_layout = rdma_mr_page_layout::type_id::create("page_layout");
  endfunction

  virtual function rdma_status validate();
    rdma_status status;

    if (function_h == null ||
        function_h.kind != RDMA_RESOURCE_FUNCTION ||
        page_layout == null || backing_refs.size() == 0)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "MR backing authority is incomplete");
    foreach (backing_refs[i]) begin
      if (backing_refs[i] == null)
        return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                                 "MR backing reference is null");
      status = backing_refs[i].validate();
      if (status == null)
        return rdma_status::make(RDMA_SC_INVALID_STATE,
                                 "MR backing validation returned null");
      if (!status.ok())
        return status;
    end
    foreach (hmc_refs[i]) begin
      if (hmc_refs[i] == null)
        return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                                 "MR HMC reference is null");
      status = hmc_refs[i].validate();
      if (status == null)
        return rdma_status::make(RDMA_SC_INVALID_STATE,
                                 "MR HMC validation returned null");
      if (!status.ok())
        return status;
    end
    status = page_layout.validate();
    if (status == null)
      return rdma_status::make(RDMA_SC_INVALID_STATE,
                               "MR page layout validation returned null");
    if (!status.ok())
      return status;
    case (page_layout.pbl_mode)
      RDMA_MR_PBL0:
        if (backing_refs.size() != 1 || hmc_refs.size() != 0 ||
            page_layout.pba0 != backing_refs[0].mapping.backing_addr)
          return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                                   "PBL0 backing does not match its PBA");
      RDMA_MR_PBL1:
        if (backing_refs.size() != 2 || hmc_refs.size() != 0 ||
            page_layout.pba0 != backing_refs[0].mapping.backing_addr ||
            page_layout.pba1 != backing_refs[1].mapping.backing_addr)
          return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                                   "PBL1 backing does not match its PBAs");
      RDMA_MR_PBL2:
        if (hmc_refs.size() != 1 || hmc_refs[0].first_pbl_index !=
            page_layout.first_pbl_index)
          return rdma_status::make(
            RDMA_SC_INVALID_ARGUMENT,
            "PBL2 backing does not match its HMC lease"
          );
    endcase
    return rdma_status::success();
  endfunction

  virtual function void do_copy(uvm_object rhs);
    rdma_mr_backing_desc rhs_desc;
    uvm_object cloned_object;
    rdma_backing_ref cloned_backing_ref;
    rdma_hmc_ref cloned_hmc_ref;

    super.do_copy(rhs);
    if (!$cast(rhs_desc, rhs))
      `uvm_fatal("RDMA_COPY_TYPE", "MR backing descriptor copy mismatch")
    function_h = rdma_clone_function_handle_value(rhs_desc.function_h,
                                                   "MR backing descriptor");
    requester_bdf = rhs_desc.requester_bdf;
    pasid_valid = rhs_desc.pasid_valid;
    pasid = rhs_desc.pasid;
    backing_refs.delete();
    foreach (rhs_desc.backing_refs[i]) begin
      if (rhs_desc.backing_refs[i] == null) begin
        backing_refs.push_back(null);
      end
      else begin
        cloned_object = rhs_desc.backing_refs[i].clone();
        if (cloned_object == null ||
            !$cast(cloned_backing_ref, cloned_object))
          `uvm_fatal("RDMA_COPY_TYPE",
                     "MR backing reference clone mismatch")
        backing_refs.push_back(cloned_backing_ref);
      end
    end
    hmc_refs.delete();
    foreach (rhs_desc.hmc_refs[i]) begin
      if (rhs_desc.hmc_refs[i] == null) begin
        hmc_refs.push_back(null);
      end
      else begin
        cloned_object = rhs_desc.hmc_refs[i].clone();
        if (cloned_object == null || !$cast(cloned_hmc_ref, cloned_object))
          `uvm_fatal("RDMA_COPY_TYPE", "MR HMC reference clone mismatch")
        hmc_refs.push_back(cloned_hmc_ref);
      end
    end
    if (rhs_desc.page_layout == null) begin
      page_layout = null;
    end
    else begin
      cloned_object = rhs_desc.page_layout.clone();
      if (cloned_object == null || !$cast(page_layout, cloned_object))
        `uvm_fatal("RDMA_COPY_TYPE", "MR page layout clone mismatch")
    end
  endfunction
endclass

class rdma_control_result extends uvm_object;
  `uvm_object_utils(rdma_control_result)

  longint unsigned transaction_id;
  rdma_status status;
  rdma_status primary_status;
  rdma_status rollback_statuses[$];
  rdma_handle resource_h;
  rdma_control_step_e completed_steps[$];
  rdma_resource_state_e final_resource_state;
  bit final_resource_state_known;
  bit recovery_required;

  function new(string name = "rdma_control_result");
    super.new(name);
    transaction_id = 0;
    status = null;
    primary_status = null;
    resource_h = null;
    final_resource_state = RDMA_RESOURCE_NEW;
    final_resource_state_known = 1'b0;
    recovery_required = 1'b0;
  endfunction

  function bit ok();
    return status != null && status.ok();
  endfunction

  virtual function rdma_status validate();
    if (status == null || primary_status == null)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "control result status is incomplete");
    foreach (rollback_statuses[i]) begin
      if (rollback_statuses[i] == null)
        return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                                 "control result rollback status is null");
    end
    foreach (completed_steps[i]) begin
      if (!rdma_control_step_valid(completed_steps[i]))
        return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                                 "control result step is invalid");
    end
    if (!(final_resource_state inside {
          RDMA_RESOURCE_NEW, RDMA_RESOURCE_ALLOCATED,
          RDMA_RESOURCE_PROGRAMMED, RDMA_RESOURCE_ACTIVE,
          RDMA_RESOURCE_QUIESCING, RDMA_RESOURCE_RELEASED,
          RDMA_RESOURCE_ERROR}))
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "control result final state is invalid");
    if (!final_resource_state_known &&
        final_resource_state != RDMA_RESOURCE_NEW)
      return rdma_status::make(
        RDMA_SC_INVALID_STATE,
        "unknown control result final state is not canonical"
      );
    if (recovery_required &&
        (!final_resource_state_known ||
         status.code != RDMA_SC_RECOVERY_REQUIRED ||
         final_resource_state != RDMA_RESOURCE_ERROR))
      return rdma_status::make(
        RDMA_SC_INVALID_STATE,
        "recovery-required result is not an ERROR recovery result"
      );
    return rdma_status::success();
  endfunction

  virtual function void do_copy(uvm_object rhs);
    rdma_control_result rhs_result;

    super.do_copy(rhs);
    if (!$cast(rhs_result, rhs))
      `uvm_fatal("RDMA_COPY_TYPE", "control result copy mismatch")
    transaction_id = rhs_result.transaction_id;
    status = rdma_cmq_clone_status_value(rhs_result.status);
    primary_status = rdma_cmq_clone_status_value(rhs_result.primary_status);
    rollback_statuses.delete();
    foreach (rhs_result.rollback_statuses[i])
      rollback_statuses.push_back(
        rdma_cmq_clone_status_value(rhs_result.rollback_statuses[i])
      );
    resource_h = rdma_clone_handle_value(rhs_result.resource_h,
                                         "control result");
    completed_steps = rhs_result.completed_steps;
    final_resource_state = rhs_result.final_resource_state;
    final_resource_state_known = rhs_result.final_resource_state_known;
    recovery_required = rhs_result.recovery_required;
  endfunction
endclass

class rdma_recovery_record extends uvm_object;
  `uvm_object_utils(rdma_recovery_record)

  rdma_handle resource_h;
  rdma_hw_presence_e hardware_presence;
  rdma_control_step_e completed_steps[$];
  rdma_control_step_e pending_steps[$];
  rdma_backing_ref backing_refs[$];
  rdma_hmc_ref hmc_refs[$];
  rdma_cmq_ticket ambiguous_ticket;
  rdma_status primary_status;
  rdma_status rollback_statuses[$];

  function new(string name = "rdma_recovery_record");
    super.new(name);
    resource_h = null;
    hardware_presence = RDMA_HW_PRESENCE_UNKNOWN;
    ambiguous_ticket = null;
    primary_status = null;
  endfunction

  virtual function rdma_status validate();
    rdma_status status;
    bit has_pending_hardware_step;

    if (resource_h == null)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "recovery resource handle is null");
    if (!(hardware_presence inside {RDMA_HW_PRESENCE_UNKNOWN,
                                    RDMA_HW_PRESENCE_PRESENT,
                                    RDMA_HW_PRESENCE_ABSENT}))
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "recovery hardware presence is invalid");
    has_pending_hardware_step = 1'b0;
    foreach (completed_steps[i]) begin
      if (!rdma_control_step_valid(completed_steps[i]))
        return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                                 "recovery completed step is invalid");
    end
    foreach (pending_steps[i]) begin
      if (!rdma_control_step_valid(pending_steps[i]))
        return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                                 "recovery pending step is invalid");
      if (rdma_control_step_is_hardware(pending_steps[i]))
        has_pending_hardware_step = 1'b1;
    end
    foreach (backing_refs[i]) begin
      if (backing_refs[i] == null)
        return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                                 "recovery backing reference is null");
      status = backing_refs[i].validate();
      if (status == null)
        return rdma_status::make(RDMA_SC_INVALID_STATE,
                                 "recovery backing validation returned null");
      if (!status.ok())
        return status;
    end
    foreach (hmc_refs[i]) begin
      if (hmc_refs[i] == null)
        return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                                 "recovery HMC reference is null");
      status = hmc_refs[i].validate();
      if (status == null)
        return rdma_status::make(RDMA_SC_INVALID_STATE,
                                 "recovery HMC validation returned null");
      if (!status.ok())
        return status;
    end
    if (ambiguous_ticket != null) begin
      status = ambiguous_ticket.validate();
      if (status == null)
        return rdma_status::make(RDMA_SC_INVALID_STATE,
                                 "recovery ticket validation returned null");
      if (!status.ok())
        return status;
    end
    if (primary_status == null)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "recovery primary status is null");
    foreach (rollback_statuses[i]) begin
      if (rollback_statuses[i] == null)
        return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                                 "recovery rollback status is null");
    end
    if (hardware_presence == RDMA_HW_PRESENCE_UNKNOWN &&
        ambiguous_ticket == null && !has_pending_hardware_step)
      return rdma_status::make(
        RDMA_SC_INVALID_STATE,
        "unknown hardware presence lacks an ambiguous ticket or hardware step"
      );
    return rdma_status::success();
  endfunction

  virtual function void do_copy(uvm_object rhs);
    rdma_recovery_record rhs_record;
    uvm_object cloned_object;
    rdma_backing_ref cloned_backing_ref;
    rdma_hmc_ref cloned_hmc_ref;

    super.do_copy(rhs);
    if (!$cast(rhs_record, rhs))
      `uvm_fatal("RDMA_COPY_TYPE", "recovery record copy mismatch")
    resource_h = rdma_clone_handle_value(rhs_record.resource_h,
                                         "recovery record");
    hardware_presence = rhs_record.hardware_presence;
    completed_steps = rhs_record.completed_steps;
    pending_steps = rhs_record.pending_steps;
    backing_refs.delete();
    foreach (rhs_record.backing_refs[i]) begin
      if (rhs_record.backing_refs[i] == null) begin
        backing_refs.push_back(null);
      end
      else begin
        cloned_object = rhs_record.backing_refs[i].clone();
        if (cloned_object == null ||
            !$cast(cloned_backing_ref, cloned_object))
          `uvm_fatal("RDMA_COPY_TYPE",
                     "recovery backing reference clone mismatch")
        backing_refs.push_back(cloned_backing_ref);
      end
    end
    hmc_refs.delete();
    foreach (rhs_record.hmc_refs[i]) begin
      if (rhs_record.hmc_refs[i] == null) begin
        hmc_refs.push_back(null);
      end
      else begin
        cloned_object = rhs_record.hmc_refs[i].clone();
        if (cloned_object == null || !$cast(cloned_hmc_ref, cloned_object))
          `uvm_fatal("RDMA_COPY_TYPE",
                     "recovery HMC reference clone mismatch")
        hmc_refs.push_back(cloned_hmc_ref);
      end
    end
    ambiguous_ticket = rdma_cmq_clone_ticket_value(
      rhs_record.ambiguous_ticket, "recovery record"
    );
    primary_status = rdma_cmq_clone_status_value(rhs_record.primary_status);
    rollback_statuses.delete();
    foreach (rhs_record.rollback_statuses[i])
      rollback_statuses.push_back(
        rdma_cmq_clone_status_value(rhs_record.rollback_statuses[i])
      );
  endfunction
endclass
