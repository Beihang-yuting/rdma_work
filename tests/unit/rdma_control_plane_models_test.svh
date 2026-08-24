class rdma_control_plane_models_test extends uvm_test;
  `uvm_component_utils(rdma_control_plane_models_test)

  localparam longint unsigned TEST_FUNCTION_UID =
    64'h0123_4567_89ab_cdef;
  localparam int unsigned TEST_GENERATION = 32'd7;

  function new(string name = "rdma_control_plane_models_test",
               uvm_component parent = null);
    super.new(name, parent);
  endfunction

  function automatic void expect_status(
    string check_name,
    rdma_status status,
    rdma_status_code_e expected_code
  );
    if (status == null) begin
      `uvm_error(check_name, "model returned a null status")
      return;
    end
    if (status.code != expected_code)
      `uvm_error(check_name,
                 $sformatf("expected %s, got %s (%s)",
                           expected_code.name(), status.code.name(),
                           status.convert2string()))
  endfunction

  function automatic rdma_function_handle make_function(string name);
    rdma_function_handle function_h;

    function_h = rdma_function_handle::type_id::create(name);
    function_h.function_uid = TEST_FUNCTION_UID;
    function_h.object_id = 32'h1234;
    function_h.generation = TEST_GENERATION;
    return function_h;
  endfunction

  function automatic rdma_handle make_resource(
    string name,
    rdma_resource_kind_e kind = RDMA_RESOURCE_MR
  );
    rdma_handle resource_h;

    resource_h = rdma_handle::type_id::create(name);
    resource_h.kind = kind;
    resource_h.function_uid = TEST_FUNCTION_UID;
    resource_h.object_id = 32'h55;
    resource_h.generation = TEST_GENERATION;
    return resource_h;
  endfunction

  function automatic rdma_dma_mapping make_mapping(
    string name,
    rdma_function_handle function_h,
    bit [63:0] backing_addr
  );
    rdma_dma_mapping mapping;

    mapping = rdma_dma_mapping::type_id::create(name);
    mapping.function_h = function_h;
    mapping.requester_bdf = '{segment:16'h1001, bus:8'h20,
                              device:5'h03, function_num:3'h5};
    mapping.pasid_valid = 1'b1;
    mapping.pasid = 20'habcde;
    mapping.backing_addr.value = backing_addr;
    mapping.iova.value = 64'h0000_0001_0000_0000 + backing_addr;
    mapping.size = 64'h1000;
    mapping.direction = RDMA_DMA_BIDIRECTIONAL;
    mapping.permissions = '{device_read:1'b1, device_write:1'b1,
                            atomic:1'b0};
    mapping.state = RDMA_MAPPING_ACTIVE;
    mapping.owner_h = make_resource({name, "_owner"});
    return mapping;
  endfunction

  function automatic rdma_backing_ref make_backing_ref(
    string name,
    rdma_dma_mapping mapping,
    rdma_resource_ownership_e ownership = RDMA_OWNERSHIP_BORROWED
  );
    rdma_backing_ref backing_ref;

    backing_ref = rdma_backing_ref::type_id::create(name);
    backing_ref.mapping = mapping;
    backing_ref.ownership = ownership;
    backing_ref.release_complete = 1'b0;
    return backing_ref;
  endfunction

  function automatic rdma_hmc_ref make_hmc_ref(
    string name,
    rdma_function_handle owner,
    int unsigned first_pbl_index
  );
    rdma_hmc_ref hmc_ref;

    hmc_ref = rdma_hmc_ref::type_id::create(name);
    hmc_ref.owner = owner;
    hmc_ref.object_kind = RDMA_RESOURCE_MR;
    hmc_ref.address.value = 64'h0000_0000_8000_0000;
    hmc_ref.size = 64'h1000;
    hmc_ref.first_pbl_index = first_pbl_index;
    hmc_ref.ownership = RDMA_OWNERSHIP_BORROWED;
    hmc_ref.release_complete = 1'b0;
    return hmc_ref;
  endfunction

  function automatic rdma_cmq_ticket make_ticket(
    string name,
    rdma_function_handle function_h
  );
    rdma_cmq_ticket ticket;

    ticket = rdma_cmq_ticket::type_id::create(name);
    ticket.command_id = 64'h1234_0005;
    ticket.function_h = function_h;
    ticket.cmq_h = make_resource({name, "_cmq"}, RDMA_RESOURCE_CMQ);
    ticket.slot_sequence = 64'd37;
    ticket.sq_index = 5;
    ticket.sq_wrap = 1'b1;
    ticket.opcode_key = rdma_cmq_opcode_key::type_id::create(
      {name, "_opcode_key"}
    );
    ticket.opcode_key.profile_name = "generic_profile";
    ticket.opcode_key.opcode = 32'hff00_abcd;
    ticket.opcode_key.variant = "deregister";
    ticket.absolute_deadline = 64'd1000;
    return ticket;
  endfunction

  task run_phase(uvm_phase phase);
    rdma_function_handle function_h;
    rdma_dma_mapping mapping;
    rdma_dma_mapping mapping2;
    rdma_backing_ref backing_ref;
    rdma_backing_ref backing_ref2;
    rdma_backing_ref backing_ref_clone;
    rdma_hmc_ref hmc_ref;
    rdma_hmc_ref hmc_ref_clone;
    rdma_mr_backing_desc descriptor;
    rdma_mr_backing_desc descriptor_clone;
    rdma_control_result result;
    rdma_control_result result_clone;
    rdma_recovery_record recovery;
    rdma_recovery_record recovery_clone;
    rdma_cmq_ticket ticket;
    rdma_status saved_status;
    rdma_status saved_primary_status;
    rdma_mr_page_layout saved_page_layout;
    rdma_function_handle saved_function_h;
    rdma_backing_ref saved_backing_ref;
    rdma_hmc_ref saved_hmc_ref;
    rdma_handle saved_resource_h;
    uvm_object cloned_object;

    phase.raise_objection(this);

    function_h = make_function("function_h");
    mapping = make_mapping("mapping", function_h,
                           64'h0000_0000_4000_0000);
    mapping2 = make_mapping("mapping2", function_h,
                            64'h0000_0000_5000_0000);
    backing_ref = make_backing_ref("backing_ref", mapping);
    backing_ref2 = make_backing_ref("backing_ref2", mapping2);
    hmc_ref = make_hmc_ref("hmc_ref", function_h, 32'h80);

    expect_status("BACKING_REF", backing_ref.validate(), RDMA_SC_OK);
    cloned_object = backing_ref.clone();
    if (!$cast(backing_ref_clone, cloned_object))
      `uvm_error("BACKING_REF_COPY", "backing reference clone type mismatch")
    else if (backing_ref_clone.mapping == null ||
             backing_ref_clone.mapping == backing_ref.mapping ||
             backing_ref_clone.mapping.function_h == mapping.function_h ||
             backing_ref_clone.mapping.owner_h == mapping.owner_h ||
             backing_ref_clone.mapping.backing_addr !=
               mapping.backing_addr ||
             backing_ref_clone.mapping.state != mapping.state ||
             backing_ref_clone.ownership != backing_ref.ownership ||
             backing_ref_clone.release_complete !=
               backing_ref.release_complete)
      `uvm_error("BACKING_REF_COPY",
                 "backing reference clone aliases or loses source state")

    backing_ref.mapping = null;
    expect_status("BACKING_REF_NULL", backing_ref.validate(),
                  RDMA_SC_INVALID_ARGUMENT);
    backing_ref.mapping = mapping;
    mapping.state = RDMA_MAPPING_FROZEN;
    expect_status("BACKING_REF_INACTIVE", backing_ref.validate(),
                  RDMA_SC_INVALID_STATE);
    backing_ref.release_complete = 1'b1;
    expect_status("BACKING_REF_BORROWED_RELEASED", backing_ref.validate(),
                  RDMA_SC_INVALID_STATE);
    backing_ref.ownership = RDMA_OWNERSHIP_CONTROL_PLANE;
    expect_status("BACKING_REF_OWNED_RELEASED", backing_ref.validate(),
                  RDMA_SC_OK);
    mapping.state = RDMA_MAPPING_ACTIVE;
    backing_ref.release_complete = 1'b0;
    backing_ref.ownership = RDMA_OWNERSHIP_BORROWED;

    expect_status("HMC_REF", hmc_ref.validate(), RDMA_SC_OK);
    cloned_object = hmc_ref.clone();
    if (!$cast(hmc_ref_clone, cloned_object))
      `uvm_error("HMC_REF_COPY", "HMC reference clone type mismatch")
    else if (hmc_ref_clone.owner == null ||
             hmc_ref_clone.owner == hmc_ref.owner ||
             hmc_ref_clone.owner.function_uid !=
               hmc_ref.owner.function_uid ||
             hmc_ref_clone.object_kind != hmc_ref.object_kind ||
             hmc_ref_clone.address != hmc_ref.address ||
             hmc_ref_clone.size != hmc_ref.size ||
             hmc_ref_clone.first_pbl_index != hmc_ref.first_pbl_index ||
             hmc_ref_clone.ownership != hmc_ref.ownership ||
             hmc_ref_clone.release_complete != hmc_ref.release_complete)
      `uvm_error("HMC_REF_COPY",
                 "HMC reference clone aliases or loses source state")

    saved_function_h = hmc_ref.owner;
    hmc_ref.owner = null;
    expect_status("HMC_REF_NULL_OWNER", hmc_ref.validate(),
                  RDMA_SC_INVALID_ARGUMENT);
    hmc_ref.owner = saved_function_h;
    hmc_ref.object_kind = RDMA_RESOURCE_PD;
    expect_status("HMC_REF_KIND", hmc_ref.validate(),
                  RDMA_SC_INVALID_ARGUMENT);
    hmc_ref.object_kind = RDMA_RESOURCE_MR;
    hmc_ref.size = 0;
    expect_status("HMC_REF_SIZE", hmc_ref.validate(),
                  RDMA_SC_INVALID_ARGUMENT);
    hmc_ref.size = 64'h1000;
    hmc_ref.first_pbl_index = 0;
    expect_status("HMC_REF_INDEX", hmc_ref.validate(),
                  RDMA_SC_INVALID_ARGUMENT);
    hmc_ref.first_pbl_index = 32'h80;
    hmc_ref.release_complete = 1'b1;
    expect_status("HMC_REF_BORROWED_RELEASED", hmc_ref.validate(),
                  RDMA_SC_INVALID_STATE);
    hmc_ref.ownership = RDMA_OWNERSHIP_CONTROL_PLANE;
    expect_status("HMC_REF_OWNED_RELEASED", hmc_ref.validate(), RDMA_SC_OK);
    hmc_ref.release_complete = 1'b0;
    hmc_ref.ownership = RDMA_OWNERSHIP_BORROWED;

    descriptor = rdma_mr_backing_desc::type_id::create("descriptor");
    descriptor.function_h = function_h;
    descriptor.requester_bdf = mapping.requester_bdf;
    descriptor.pasid_valid = mapping.pasid_valid;
    descriptor.pasid = mapping.pasid;
    descriptor.page_layout.pbl_mode = RDMA_MR_PBL0;
    descriptor.page_layout.pba0 = mapping.backing_addr;
    descriptor.backing_refs.push_back(backing_ref);
    expect_status("MR_BACKING", descriptor.validate(), RDMA_SC_OK);

    cloned_object = descriptor.clone();
    if (!$cast(descriptor_clone, cloned_object))
      `uvm_error("MR_BACKING_COPY", "descriptor clone type mismatch")
    else if (descriptor_clone.function_h == null ||
             descriptor_clone.function_h == descriptor.function_h ||
             descriptor_clone.page_layout == null ||
             descriptor_clone.page_layout == descriptor.page_layout ||
             descriptor_clone.backing_refs.size() != 1 ||
             descriptor_clone.backing_refs[0] ==
               descriptor.backing_refs[0] ||
             descriptor_clone.backing_refs[0].mapping == mapping ||
             descriptor_clone.page_layout.pbl_mode !=
               descriptor.page_layout.pbl_mode ||
             descriptor_clone.page_layout.pba0 !=
               descriptor.page_layout.pba0 ||
             descriptor_clone.requester_bdf != descriptor.requester_bdf ||
             descriptor_clone.pasid_valid != descriptor.pasid_valid ||
             descriptor_clone.pasid != descriptor.pasid)
      `uvm_error("MR_BACKING_COPY",
                 "descriptor clone aliases or loses source graph")

    saved_function_h = descriptor.function_h;
    descriptor.function_h = null;
    expect_status("MR_BACKING_NULL_FUNCTION", descriptor.validate(),
                  RDMA_SC_INVALID_ARGUMENT);
    descriptor.function_h = saved_function_h;
    saved_page_layout = descriptor.page_layout;
    descriptor.page_layout = null;
    expect_status("MR_BACKING_NULL_LAYOUT", descriptor.validate(),
                  RDMA_SC_INVALID_ARGUMENT);
    descriptor.page_layout = saved_page_layout;
    saved_backing_ref = descriptor.backing_refs.pop_front();
    expect_status("MR_BACKING_EMPTY", descriptor.validate(),
                  RDMA_SC_INVALID_ARGUMENT);
    descriptor.backing_refs.push_back(saved_backing_ref);
    descriptor.backing_refs[0] = null;
    expect_status("MR_BACKING_NULL_REF", descriptor.validate(),
                  RDMA_SC_INVALID_ARGUMENT);
    descriptor.backing_refs[0] = saved_backing_ref;
    descriptor.page_layout.pba0.value++;
    expect_status("MR_BACKING_PBL0_PBA", descriptor.validate(),
                  RDMA_SC_INVALID_ARGUMENT);
    descriptor.page_layout.pba0 = mapping.backing_addr;

    descriptor.page_layout.pbl_mode = RDMA_MR_PBL1;
    descriptor.page_layout.pba1 = mapping2.backing_addr;
    descriptor.backing_refs.push_back(backing_ref2);
    expect_status("MR_BACKING_PBL1", descriptor.validate(), RDMA_SC_OK);
    descriptor.page_layout.pba1.value++;
    expect_status("MR_BACKING_PBL1_PBA", descriptor.validate(),
                  RDMA_SC_INVALID_ARGUMENT);
    descriptor.page_layout.pba1 = mapping2.backing_addr;

    descriptor.page_layout.pbl_mode = RDMA_MR_PBL2;
    descriptor.page_layout.pba0 = '0;
    descriptor.page_layout.pba1 = '0;
    descriptor.page_layout.first_pbl_index = hmc_ref.first_pbl_index;
    descriptor.hmc_refs.push_back(hmc_ref);
    expect_status("MR_BACKING_PBL2", descriptor.validate(), RDMA_SC_OK);
    cloned_object = descriptor.clone();
    if (!$cast(descriptor_clone, cloned_object))
      `uvm_error("MR_BACKING_PBL2_COPY", "PBL2 clone type mismatch")
    else if (descriptor_clone.backing_refs.size() != 2 ||
             descriptor_clone.hmc_refs.size() != 1 ||
             descriptor_clone.backing_refs[1] == backing_ref2 ||
             descriptor_clone.hmc_refs[0] == hmc_ref ||
             descriptor_clone.hmc_refs[0].owner == hmc_ref.owner)
      `uvm_error("MR_BACKING_PBL2_COPY",
                 "PBL2 clone aliases an object queue member")
    descriptor.page_layout.first_pbl_index++;
    expect_status("MR_BACKING_PBL2_INDEX", descriptor.validate(),
                  RDMA_SC_INVALID_ARGUMENT);
    descriptor.page_layout.first_pbl_index = hmc_ref.first_pbl_index;
    saved_hmc_ref = descriptor.hmc_refs[0];
    descriptor.hmc_refs[0] = null;
    expect_status("MR_BACKING_NULL_HMC", descriptor.validate(),
                  RDMA_SC_INVALID_ARGUMENT);
    descriptor.hmc_refs[0] = saved_hmc_ref;

    result = rdma_control_result::type_id::create("result");
    result.transaction_id = 64'h100;
    result.status = rdma_status::success("registered");
    result.primary_status = rdma_status::success("registered");
    result.rollback_statuses.push_back(
      rdma_status::make(RDMA_SC_TIMEOUT, "recorded rollback probe")
    );
    result.resource_h = make_resource("result_resource");
    result.completed_steps.push_back(RDMA_CTRL_STEP_RESOURCE_RESERVED);
    result.completed_steps.push_back(RDMA_CTRL_STEP_REGISTRY_ACTIVE);
    result.final_resource_state = RDMA_RESOURCE_ACTIVE;
    result.recovery_required = 1'b0;
    expect_status("RESULT", result.validate(), RDMA_SC_OK);
    if (!result.ok())
      `uvm_error("RESULT_OK", "successful control result is not ok")

    cloned_object = result.clone();
    if (!$cast(result_clone, cloned_object))
      `uvm_error("RESULT_COPY", "result clone type mismatch")
    else if (result_clone.status == null ||
             result_clone.status == result.status ||
             result_clone.primary_status == null ||
             result_clone.primary_status == result.primary_status ||
             result_clone.rollback_statuses.size() != 1 ||
             result_clone.rollback_statuses[0] ==
               result.rollback_statuses[0] ||
             result_clone.resource_h == null ||
             result_clone.resource_h == result.resource_h ||
             !result_clone.resource_h.same_instance(result.resource_h) ||
             result_clone.status.code != result.status.code ||
             result_clone.status.message != result.status.message ||
             result_clone.primary_status.code !=
               result.primary_status.code ||
             result_clone.rollback_statuses[0].code !=
               result.rollback_statuses[0].code ||
             result_clone.completed_steps != result.completed_steps ||
             result_clone.transaction_id != result.transaction_id ||
             result_clone.final_resource_state !=
               result.final_resource_state ||
             result_clone.recovery_required != result.recovery_required)
      `uvm_error("RESULT_COPY", "result clone is not a detached snapshot")

    result.recovery_required = 1'b1;
    result.status = rdma_status::make(RDMA_SC_RECOVERY_REQUIRED,
                                      "rollback incomplete");
    result.primary_status = rdma_status::make(RDMA_SC_TIMEOUT,
                                              "operation timeout");
    result.final_resource_state = RDMA_RESOURCE_ERROR;
    expect_status("RESULT_RECOVERY", result.validate(), RDMA_SC_OK);
    if (result.ok())
      `uvm_error("RESULT_RECOVERY_OK", "recovery-required result is ok")
    saved_status = result.status;
    result.status = rdma_status::make(RDMA_SC_TIMEOUT, "wrong aggregate");
    expect_status("RESULT_RECOVERY_CODE", result.validate(),
                  RDMA_SC_INVALID_STATE);
    result.status = saved_status;
    result.final_resource_state = RDMA_RESOURCE_ACTIVE;
    expect_status("RESULT_RECOVERY_STATE", result.validate(),
                  RDMA_SC_INVALID_STATE);
    result.final_resource_state = RDMA_RESOURCE_ERROR;
    result.rollback_statuses.push_back(null);
    expect_status("RESULT_NULL_ROLLBACK", result.validate(),
                  RDMA_SC_INVALID_ARGUMENT);
    void'(result.rollback_statuses.pop_back());
    saved_primary_status = result.primary_status;
    result.primary_status = null;
    expect_status("RESULT_NULL_PRIMARY", result.validate(),
                  RDMA_SC_INVALID_ARGUMENT);
    result.primary_status = saved_primary_status;
    result.status = null;
    expect_status("RESULT_NULL_STATUS", result.validate(),
                  RDMA_SC_INVALID_ARGUMENT);
    result.status = saved_status;

    recovery = rdma_recovery_record::type_id::create("recovery");
    recovery.resource_h = make_resource("recovery_resource");
    recovery.hardware_presence = RDMA_HW_PRESENCE_UNKNOWN;
    recovery.completed_steps.push_back(RDMA_CTRL_STEP_HW_KEY_ALLOCATED);
    recovery.pending_steps.push_back(
      RDMA_CTRL_STEP_HW_MR_DEREGISTERED
    );
    recovery.backing_refs.push_back(backing_ref);
    recovery.hmc_refs.push_back(hmc_ref);
    ticket = make_ticket("ambiguous_ticket", function_h);
    recovery.ambiguous_ticket = ticket;
    recovery.primary_status = rdma_status::make(RDMA_SC_TIMEOUT,
                                                "ambiguous completion");
    recovery.rollback_statuses.push_back(
      rdma_status::make(RDMA_SC_UNKNOWN_HW_ERROR,
                        "deregister not confirmed")
    );
    expect_status("RECOVERY", recovery.validate(), RDMA_SC_OK);

    cloned_object = recovery.clone();
    if (!$cast(recovery_clone, cloned_object))
      `uvm_error("RECOVERY_COPY", "recovery clone type mismatch")
    else if (recovery_clone.resource_h == null ||
             recovery_clone.resource_h == recovery.resource_h ||
             !recovery_clone.resource_h.same_instance(
               recovery.resource_h
             ) ||
             recovery_clone.completed_steps != recovery.completed_steps ||
             recovery_clone.pending_steps != recovery.pending_steps ||
             recovery_clone.backing_refs.size() != 1 ||
             recovery_clone.backing_refs[0] == backing_ref ||
             recovery_clone.backing_refs[0].mapping == mapping ||
             recovery_clone.hmc_refs.size() != 1 ||
             recovery_clone.hmc_refs[0] == hmc_ref ||
             recovery_clone.hmc_refs[0].owner == hmc_ref.owner ||
             recovery_clone.ambiguous_ticket == null ||
             recovery_clone.ambiguous_ticket == ticket ||
             recovery_clone.ambiguous_ticket.command_id !=
               ticket.command_id ||
             recovery_clone.ambiguous_ticket.function_h ==
               ticket.function_h ||
             recovery_clone.ambiguous_ticket.cmq_h == ticket.cmq_h ||
             recovery_clone.ambiguous_ticket.opcode_key ==
               ticket.opcode_key ||
             recovery_clone.primary_status == null ||
             recovery_clone.primary_status == recovery.primary_status ||
             recovery_clone.primary_status.code !=
               recovery.primary_status.code ||
             recovery_clone.rollback_statuses.size() != 1 ||
             recovery_clone.rollback_statuses[0] ==
               recovery.rollback_statuses[0] ||
             recovery_clone.rollback_statuses[0].code !=
               recovery.rollback_statuses[0].code ||
             recovery_clone.hardware_presence !=
               recovery.hardware_presence)
      `uvm_error("RECOVERY_COPY",
                 "recovery clone aliases or loses source graph")

    recovery.ambiguous_ticket = null;
    recovery.pending_steps.delete();
    expect_status("RECOVERY_UNKNOWN_UNEXPLAINED", recovery.validate(),
                  RDMA_SC_INVALID_STATE);
    recovery.pending_steps.push_back(RDMA_CTRL_STEP_RESOURCE_RELEASED);
    expect_status("RECOVERY_UNKNOWN_LOCAL_STEP", recovery.validate(),
                  RDMA_SC_INVALID_STATE);
    recovery.pending_steps.delete();
    recovery.pending_steps.push_back(RDMA_CTRL_STEP_HW_MR_DEREGISTERED);
    expect_status("RECOVERY_UNKNOWN_HW_STEP", recovery.validate(),
                  RDMA_SC_OK);
    recovery.pending_steps.delete();
    recovery.hardware_presence = RDMA_HW_PRESENCE_ABSENT;
    expect_status("RECOVERY_ABSENT", recovery.validate(), RDMA_SC_OK);

    saved_backing_ref = recovery.backing_refs[0];
    recovery.backing_refs[0] = null;
    expect_status("RECOVERY_NULL_BACKING", recovery.validate(),
                  RDMA_SC_INVALID_ARGUMENT);
    recovery.backing_refs[0] = saved_backing_ref;
    saved_hmc_ref = recovery.hmc_refs[0];
    recovery.hmc_refs[0] = null;
    expect_status("RECOVERY_NULL_HMC", recovery.validate(),
                  RDMA_SC_INVALID_ARGUMENT);
    recovery.hmc_refs[0] = saved_hmc_ref;
    recovery.rollback_statuses.push_back(null);
    expect_status("RECOVERY_NULL_ROLLBACK", recovery.validate(),
                  RDMA_SC_INVALID_ARGUMENT);
    void'(recovery.rollback_statuses.pop_back());
    saved_resource_h = recovery.resource_h;
    recovery.resource_h = null;
    expect_status("RECOVERY_NULL_RESOURCE", recovery.validate(),
                  RDMA_SC_INVALID_ARGUMENT);
    recovery.resource_h = saved_resource_h;
    saved_primary_status = recovery.primary_status;
    recovery.primary_status = null;
    expect_status("RECOVERY_NULL_PRIMARY", recovery.validate(),
                  RDMA_SC_INVALID_ARGUMENT);
    recovery.primary_status = saved_primary_status;
    recovery.hardware_presence = rdma_hw_presence_e'(2'b11);
    expect_status("RECOVERY_PRESENCE", recovery.validate(),
                  RDMA_SC_INVALID_ARGUMENT);

    phase.drop_objection(this);
  endtask
endclass
