typedef enum bit [2:0] {
  CMQ_SLOT_FREE,
  CMQ_SLOT_PUBLISHED,
  CMQ_SLOT_COMPLETED,
  CMQ_SLOT_TIMED_OUT_QUARANTINED,
  CMQ_SLOT_LATE_COMPLETED,
  CMQ_SLOT_RESET_CANCELLED
} rdma_cmq_slot_state_e;

class rdma_cmq_slot_record extends uvm_object;
  `uvm_object_utils(rdma_cmq_slot_record)

  longint unsigned slot_sequence;
  int unsigned sq_index;
  bit sq_wrap;
  rdma_cmq_slot_state_e state;
  rdma_cmq_ticket ticket;
  rdma_cmq_expected_response expected;
  bit [4:0] command_token;

  function new(string name = "rdma_cmq_slot_record");
    super.new(name);
    slot_sequence = 0;
    sq_index = 0;
    sq_wrap = 1'b0;
    state = CMQ_SLOT_FREE;
    ticket = null;
    expected = null;
    command_token = '0;
  endfunction

  virtual function void do_copy(uvm_object rhs);
    rdma_cmq_slot_record rhs_record;

    super.do_copy(rhs);
    if (!$cast(rhs_record, rhs))
      `uvm_fatal("RDMA_COPY_TYPE", "CMQ slot record copy mismatch")
    slot_sequence = rhs_record.slot_sequence;
    sq_index = rhs_record.sq_index;
    sq_wrap = rhs_record.sq_wrap;
    state = rhs_record.state;
    ticket = rdma_cmq_clone_ticket_value(rhs_record.ticket,
                                          "CMQ slot record");
    if (rhs_record.expected == null)
      expected = null;
    else begin
      uvm_object cloned_object;
      cloned_object = rhs_record.expected.clone();
      if (cloned_object == null || !$cast(expected, cloned_object))
        `uvm_fatal("RDMA_COPY_TYPE",
                   "CMQ slot expected response clone mismatch")
    end
    command_token = rhs_record.command_token;
  endfunction
endclass

class rdma_cmq_engine extends uvm_object;
  `uvm_object_utils(rdma_cmq_engine)

  localparam int unsigned CMQ_DEPTH = 32;
  localparam int unsigned CMQE_BYTES = 64;
  localparam int unsigned SQ_BYTES = 2048;
  localparam int unsigned CQ_OFFSET = SQ_BYTES;
  localparam int unsigned BACKING_BYTES = 2 * SQ_BYTES;

  protected semaphore engine_lock;
  protected rdma_cmq_engine_state_e engine_state;
  protected rdma_function_binding prepared_binding;
  protected rdma_dma_request_context dma_context;
  protected rdma_cmq cmq_snapshot;
  protected rdma_dma_mapping backing_mapping;
  protected rdma_host_mem_api host_mem;
  protected rdma_doorbell_scheduler scheduler;
  protected rdma_cmq_hw_profile profile;
  protected longint unsigned publish_seq;
  protected longint unsigned retire_seq;
  protected longint unsigned cq_consume_seq;
  protected rdma_cmq_slot_record slots[CMQ_DEPTH];
  protected bit token_in_use[CMQ_DEPTH];
  protected bit [58:0] token_incarnation[CMQ_DEPTH];

  function new(string name = "rdma_cmq_engine");
    super.new(name);
    engine_lock = new(1);
    engine_state = RDMA_CMQ_ENGINE_UNCONFIGURED;
    prepared_binding = null;
    dma_context = null;
    cmq_snapshot = null;
    backing_mapping = null;
    host_mem = null;
    scheduler = null;
    profile = null;
    publish_seq = 0;
    retire_seq = 0;
    cq_consume_seq = 0;
    foreach (slots[i]) begin
      slots[i] = null;
      token_in_use[i] = 1'b0;
      token_incarnation[i] = '0;
    end
  endfunction

  protected function rdma_status invalid_argument(string message);
    return rdma_status::make(RDMA_SC_INVALID_ARGUMENT, message);
  endfunction

  protected function rdma_status invalid_state(string message);
    return rdma_status::make(RDMA_SC_INVALID_STATE, message);
  endfunction

  protected function bit same_handle(rdma_handle lhs, rdma_handle rhs);
    if (lhs == null || rhs == null)
      return 1'b0;
    return lhs.same_instance(rhs);
  endfunction

  protected function bit same_bdf(rdma_bdf_t lhs, rdma_bdf_t rhs);
    return lhs == rhs;
  endfunction

  protected function rdma_status clone_binding_snapshot(
    rdma_function_binding source,
    output rdma_function_binding snapshot
  );
    uvm_object cloned_object;

    snapshot = null;
    if (source == null)
      return invalid_argument("CMQ Function binding is null");
    cloned_object = source.clone();
    if (cloned_object == null || !$cast(snapshot, cloned_object)) begin
      snapshot = null;
      return invalid_state("CMQ Function binding snapshot clone failed");
    end
    return rdma_status::success();
  endfunction

  protected function rdma_status validate_binding_owner(
    rdma_function_binding binding,
    string lifecycle_name
  );
    rdma_function_handle expected_owner;

    if (binding == null)
      return invalid_argument("CMQ Function binding is null");
    expected_owner = binding.make_handle();
    if (binding.owner_h == null ||
        !same_handle(binding.owner_h, expected_owner))
      return invalid_state({lifecycle_name,
                            " Function binding owner identity is invalid"});
    return rdma_status::success();
  endfunction

  protected function rdma_status prepared_binding_status(
    rdma_function_binding binding
  );
    rdma_status status;

    if (binding == null)
      return invalid_argument("CMQ Function binding is null");
    if (binding.state != RDMA_BIND_PREPARED)
      return invalid_state("CMQ prepare requires a PREPARED binding");
    status = binding.validate();
    if (status == null)
      return invalid_state("CMQ PREPARED binding returned null status");
    if (!status.ok())
      return status;
    return validate_binding_owner(binding, "PREPARED");
  endfunction

  protected function rdma_status active_binding_status(
    rdma_function_binding binding
  );
    rdma_status status;

    if (binding == null)
      return invalid_argument("CMQ active Function binding is null");
    if (binding.state != RDMA_BIND_ACTIVE)
      return invalid_state("CMQ activate requires an ACTIVE binding");
    status = binding.validate();
    if (status == null)
      return invalid_state("CMQ ACTIVE binding returned null status");
    if (!status.ok())
      return status;
    return validate_binding_owner(binding, "ACTIVE");
  endfunction

  protected function rdma_status clone_cmq_snapshot(
    rdma_cmq source,
    output rdma_cmq snapshot
  );
    uvm_object cloned_object;

    snapshot = null;
    if (source == null)
      return invalid_argument("CMQ resource is null");
    cloned_object = source.clone();
    if (cloned_object == null || !$cast(snapshot, cloned_object)) begin
      snapshot = null;
      return invalid_state("CMQ resource snapshot clone failed");
    end
    return rdma_status::success();
  endfunction

  protected function rdma_status cmq_resource_status(
    rdma_cmq cmq,
    rdma_function_binding binding
  );
    rdma_status status;
    rdma_function_handle expected_owner;

    if (cmq == null)
      return invalid_argument("CMQ resource is null");
    status = cmq.validate();
    if (status == null)
      return invalid_state("CMQ resource returned null status");
    if (!status.ok())
      return status;
    if (cmq.state != RDMA_RESOURCE_ALLOCATED)
      return invalid_state("CMQ resource is not ALLOCATED");
    if (cmq.depth != CMQ_DEPTH)
      return invalid_argument("CMQ queue depth must be 32");
    expected_owner = binding.make_handle();
    if (cmq.owner == null || !same_handle(cmq.owner, expected_owner))
      return invalid_argument("CMQ owner does not match Function binding");
    if (cmq.handle == null || cmq.handle.kind != RDMA_RESOURCE_CMQ)
      return invalid_argument("CMQ resource handle is invalid");
    if (cmq.handle.function_uid != expected_owner.function_uid)
      return invalid_argument("CMQ handle Function UID does not match owner");
    if (cmq.handle.generation != expected_owner.generation)
      return rdma_status::make(
        RDMA_SC_STALE_GENERATION,
        "CMQ handle Function generation does not match owner"
      );
    return rdma_status::success();
  endfunction

  protected function rdma_status make_request_context(
    rdma_function_binding binding,
    rdma_cmq cmq,
    bit pasid_valid,
    bit [19:0] pasid,
    output rdma_dma_request_context request_context
  );
    rdma_status status;
    request_context = rdma_dma_request_context::type_id::create(
      "cmq_dma_request_context"
    );
    if (request_context == null)
      return invalid_state("CMQ DMA request context construction failed");
    request_context.function_h = binding.make_handle();
    if (request_context.function_h == null)
      return invalid_state("CMQ DMA Function handle construction failed");
    request_context.requester_bdf = binding.pcie.bdf;
    request_context.pasid_valid = pasid_valid;
    request_context.pasid = pasid_valid ? pasid : '0;
    request_context.owner_h = rdma_clone_handle_value(
      cmq.handle, "CMQ DMA owner"
    );
    status = request_context.validate();
    if (status == null)
      return invalid_state("CMQ DMA request context returned null status");
    return status;
  endfunction

  protected function rdma_status mapping_authority_status(
    rdma_dma_mapping mapping,
    rdma_dma_request_context request_context
  );
    rdma_dma_permission_t expected_permissions;

    expected_permissions = '{
      device_read: 1'b1,
      device_write: 1'b1,
      atomic: 1'b0
    };
    if (mapping == null)
      return invalid_state("CMQ host memory returned a null mapping");
    if (request_context == null)
      return invalid_state("CMQ DMA authority context is missing");
    if (mapping.function_h == null)
      return invalid_state("CMQ mapping Function authority is missing");
    if (request_context.function_h == null)
      return invalid_state("CMQ request Function authority is missing");
    if (mapping.function_h.kind != RDMA_RESOURCE_FUNCTION)
      return rdma_status::make(
        RDMA_SC_DMA_TRANSLATION,
        "CMQ mapping Function handle kind is invalid"
      );
    if (mapping.function_h.function_uid !=
          request_context.function_h.function_uid ||
        mapping.function_h.object_id != request_context.function_h.object_id)
      return rdma_status::make(
        RDMA_SC_DMA_TRANSLATION,
        "CMQ mapping Function authority does not match request"
      );
    if (mapping.function_h.generation !=
        request_context.function_h.generation)
      return rdma_status::make(
        RDMA_SC_STALE_GENERATION,
        "CMQ mapping Function generation does not match request"
      );
    if (!same_bdf(mapping.requester_bdf,
                  request_context.requester_bdf))
      return rdma_status::make(
        RDMA_SC_DMA_TRANSLATION,
        "CMQ mapping requester BDF does not match request"
      );
    if (mapping.pasid_valid != request_context.pasid_valid)
      return rdma_status::make(
        RDMA_SC_DMA_PERMISSION,
        "CMQ mapping PASID-valid authority does not match request"
      );
    if (mapping.pasid != request_context.pasid)
      return rdma_status::make(
        RDMA_SC_DMA_PERMISSION,
        "CMQ mapping PASID authority does not match request"
      );
    if (mapping.owner_h == null || request_context.owner_h == null ||
        !same_handle(mapping.owner_h, request_context.owner_h))
      return rdma_status::make(
        RDMA_SC_DMA_TRANSLATION,
        "CMQ mapping owner authority does not match request"
      );
    if (mapping.state != RDMA_MAPPING_ACTIVE)
      return invalid_state("CMQ backing mapping is not ACTIVE");
    if (mapping.size != BACKING_BYTES)
      return invalid_state("CMQ backing mapping size is not 4096 bytes");
    if (mapping.direction != RDMA_DMA_BIDIRECTIONAL)
      return invalid_state("CMQ backing mapping is not bidirectional");
    if (mapping.permissions != expected_permissions)
      return rdma_status::make(
        RDMA_SC_DMA_PERMISSION,
        "CMQ backing mapping permissions are not exactly bidirectional"
      );
    if ((mapping.iova.value & (BACKING_BYTES - 1'b1)) != 0 ||
        (mapping.backing_addr.value & (BACKING_BYTES - 1'b1)) != 0)
      return rdma_status::make(
        RDMA_SC_DMA_TRANSLATION,
        "CMQ backing mapping is not 4096-byte aligned"
      );
    if (mapping.iova.value >
          (64'hffff_ffff_ffff_ffff - (BACKING_BYTES - 1'b1)) ||
        mapping.backing_addr.value >
          (64'hffff_ffff_ffff_ffff - (BACKING_BYTES - 1'b1)))
      return rdma_status::make(
        RDMA_SC_DMA_TRANSLATION,
        "CMQ backing mapping range overflows"
      );
    return rdma_status::success();
  endfunction

  protected function rdma_status clone_function_handle_fields(
    rdma_function_handle source,
    string name,
    output rdma_function_handle result
  );
    result = null;
    if (source == null)
      return invalid_state("CMQ runtime Function source is null");
    result = rdma_function_handle::type_id::create(name);
    if (result == null)
      return invalid_state("CMQ runtime Function construction failed");
    result.kind = source.kind;
    result.function_uid = source.function_uid;
    result.object_id = source.object_id;
    result.generation = source.generation;
    return rdma_status::success();
  endfunction

  protected function rdma_status clone_handle_fields(
    rdma_handle source,
    string name,
    output rdma_handle result
  );
    result = null;
    if (source == null)
      return invalid_state("CMQ runtime handle source is null");
    result = rdma_handle::type_id::create(name);
    if (result == null)
      return invalid_state("CMQ runtime handle construction failed");
    result.kind = source.kind;
    result.function_uid = source.function_uid;
    result.object_id = source.object_id;
    result.generation = source.generation;
    return rdma_status::success();
  endfunction

  protected function rdma_status snapshot_failure(
    rdma_status_code_e failure_code,
    string message
  );
    return rdma_status::make(failure_code, message);
  endfunction

  protected function bit same_byte_queue(
    byte unsigned lhs[$],
    byte unsigned rhs[$]
  );
    if (lhs.size() != rhs.size())
      return 1'b0;
    foreach (lhs[i])
      if (lhs[i] != rhs[i])
        return 1'b0;
    return 1'b1;
  endfunction

  protected function bit same_string_queue(
    string lhs[$],
    string rhs[$]
  );
    if (lhs.size() != rhs.size())
      return 1'b0;
    foreach (lhs[i])
      if (lhs[i] != rhs[i])
        return 1'b0;
    return 1'b1;
  endfunction

  protected function bit same_image_value(
    rdma_hw_image lhs,
    rdma_hw_image rhs
  );
    if (lhs == null || rhs == null)
      return 1'b0;
    return same_byte_queue(lhs.bytes, rhs.bytes) &&
           lhs.length == rhs.length &&
           lhs.alignment == rhs.alignment &&
           lhs.endian == rhs.endian &&
           lhs.image_kind == rhs.image_kind &&
           lhs.hardware_version == rhs.hardware_version &&
           lhs.function_generation == rhs.function_generation &&
           lhs.write_target_kind == rhs.write_target_kind &&
           lhs.backing_target.value == rhs.backing_target.value &&
           lhs.hmc_target.value == rhs.hmc_target.value &&
           lhs.bar_target.value == rhs.bar_target.value &&
           same_string_queue(lhs.field_summary, rhs.field_summary);
  endfunction

  protected function bit same_expected_value(
    rdma_cmq_expected_response lhs,
    rdma_cmq_expected_response rhs
  );
    if (lhs == null || rhs == null)
      return 1'b0;
    return lhs.hardware_opcode == rhs.hardware_opcode &&
           lhs.variant == rhs.variant;
  endfunction

  protected function bit same_opcode_value(
    rdma_cmq_opcode_key lhs,
    rdma_cmq_opcode_key rhs
  );
    if (lhs == null || rhs == null)
      return 1'b0;
    return lhs.profile_name == rhs.profile_name &&
           lhs.opcode == rhs.opcode && lhs.variant == rhs.variant;
  endfunction

  protected function bit same_mapping_value(
    rdma_dma_mapping lhs,
    rdma_dma_mapping rhs
  );
    if (lhs == null || rhs == null ||
        lhs.function_h == null || rhs.function_h == null ||
        lhs.owner_h == null || rhs.owner_h == null)
      return 1'b0;
    return lhs.function_h.same_instance(rhs.function_h) &&
           lhs.requester_bdf == rhs.requester_bdf &&
           lhs.pasid_valid == rhs.pasid_valid &&
           lhs.pasid == rhs.pasid &&
           lhs.backing_addr.value == rhs.backing_addr.value &&
           lhs.iova.value == rhs.iova.value &&
           lhs.size == rhs.size &&
           lhs.direction == rhs.direction &&
           lhs.permissions == rhs.permissions &&
           lhs.state == rhs.state &&
           lhs.owner_h.same_instance(rhs.owner_h);
  endfunction

  protected function bit same_ticket_value(
    rdma_cmq_ticket lhs,
    rdma_cmq_ticket rhs
  );
    if (lhs == null || rhs == null ||
        lhs.function_h == null || rhs.function_h == null ||
        lhs.cmq_h == null || rhs.cmq_h == null)
      return 1'b0;
    return lhs.command_id == rhs.command_id &&
           lhs.function_h.same_instance(rhs.function_h) &&
           lhs.cmq_h.same_instance(rhs.cmq_h) &&
           lhs.slot_sequence == rhs.slot_sequence &&
           lhs.sq_index == rhs.sq_index &&
           lhs.sq_wrap == rhs.sq_wrap &&
           same_opcode_value(lhs.opcode_key, rhs.opcode_key) &&
           lhs.absolute_deadline == rhs.absolute_deadline;
  endfunction

  protected function bit same_dependency_value(
    rdma_doorbell_dependency lhs,
    rdma_doorbell_dependency rhs
  );
    if (lhs == null || rhs == null)
      return 1'b0;
    return lhs.dependency_id == rhs.dependency_id &&
           lhs.stage == rhs.stage &&
           same_mapping_value(lhs.mapping, rhs.mapping) &&
           lhs.relative_offset == rhs.relative_offset &&
           same_image_value(lhs.image, rhs.image) &&
           lhs.ready == rhs.ready;
  endfunction

  protected function rdma_status checked_function_snapshot(
    rdma_function_handle source,
    string label,
    rdma_status_code_e failure_code,
    output rdma_function_handle snapshot
  );
    uvm_object cloned_object;
    rdma_resource_kind_e saved_kind;
    longint unsigned saved_function_uid;
    int unsigned saved_object_id;
    int unsigned saved_generation;

    snapshot = null;
    if (source == null)
      return snapshot_failure(failure_code, {label, " Function is null"});
    saved_kind = source.kind;
    saved_function_uid = source.function_uid;
    saved_object_id = source.object_id;
    saved_generation = source.generation;
    cloned_object = source.clone();
    if (cloned_object == null || !$cast(snapshot, cloned_object) ||
        snapshot == source) begin
      snapshot = null;
      return snapshot_failure(
        failure_code, {label, " Function snapshot clone contract failed"}
      );
    end
    if (source.kind != saved_kind ||
        source.function_uid != saved_function_uid ||
        source.object_id != saved_object_id ||
        source.generation != saved_generation ||
        snapshot.kind != saved_kind ||
        snapshot.function_uid != saved_function_uid ||
        snapshot.object_id != saved_object_id ||
        snapshot.generation != saved_generation) begin
      snapshot = null;
      return snapshot_failure(
        failure_code, {label, " Function snapshot changed its source value"}
      );
    end
    return rdma_status::success();
  endfunction

  protected function rdma_status checked_handle_snapshot(
    rdma_handle source,
    string label,
    rdma_status_code_e failure_code,
    output rdma_handle snapshot
  );
    uvm_object cloned_object;
    rdma_resource_kind_e saved_kind;
    longint unsigned saved_function_uid;
    int unsigned saved_object_id;
    int unsigned saved_generation;

    snapshot = null;
    if (source == null)
      return snapshot_failure(failure_code, {label, " handle is null"});
    saved_kind = source.kind;
    saved_function_uid = source.function_uid;
    saved_object_id = source.object_id;
    saved_generation = source.generation;
    cloned_object = source.clone();
    if (cloned_object == null || !$cast(snapshot, cloned_object) ||
        snapshot == source) begin
      snapshot = null;
      return snapshot_failure(
        failure_code, {label, " handle snapshot clone contract failed"}
      );
    end
    if (source.kind != saved_kind ||
        source.function_uid != saved_function_uid ||
        source.object_id != saved_object_id ||
        source.generation != saved_generation ||
        snapshot.kind != saved_kind ||
        snapshot.function_uid != saved_function_uid ||
        snapshot.object_id != saved_object_id ||
        snapshot.generation != saved_generation) begin
      snapshot = null;
      return snapshot_failure(
        failure_code, {label, " handle snapshot changed its source value"}
      );
    end
    return rdma_status::success();
  endfunction

  protected function rdma_status checked_opcode_snapshot(
    rdma_cmq_opcode_key source,
    string label,
    rdma_status_code_e failure_code,
    output rdma_cmq_opcode_key snapshot
  );
    uvm_object cloned_object;
    rdma_status status;
    string saved_profile_name;
    bit [31:0] saved_opcode;
    string saved_variant;

    snapshot = null;
    if (source == null)
      return snapshot_failure(failure_code, {label, " opcode key is null"});
    status = source.validate();
    if (status == null)
      return snapshot_failure(
        failure_code, {label, " opcode validation returned null"}
      );
    if (!status.ok())
      return status;
    saved_profile_name = source.profile_name;
    saved_opcode = source.opcode;
    saved_variant = source.variant;
    cloned_object = source.clone();
    if (cloned_object == null || !$cast(snapshot, cloned_object) ||
        snapshot == source) begin
      snapshot = null;
      return snapshot_failure(
        failure_code, {label, " opcode snapshot clone contract failed"}
      );
    end
    if (source.profile_name != saved_profile_name ||
        source.opcode != saved_opcode || source.variant != saved_variant ||
        snapshot.profile_name != saved_profile_name ||
        snapshot.opcode != saved_opcode ||
        snapshot.variant != saved_variant) begin
      snapshot = null;
      return snapshot_failure(
        failure_code, {label, " opcode snapshot changed its source value"}
      );
    end
    status = snapshot.validate();
    if (status == null) begin
      snapshot = null;
      return snapshot_failure(
        failure_code, {label, " opcode snapshot validation returned null"}
      );
    end
    if (!status.ok())
      snapshot = null;
    return status;
  endfunction

  protected function rdma_status checked_body_snapshot(
    rdma_hw_model source,
    string label,
    rdma_status_code_e failure_code,
    output rdma_hw_model snapshot
  );
    uvm_object cloned_object;
    rdma_status status;
    string source_type_name;

    snapshot = null;
    if (source == null)
      return snapshot_failure(failure_code, {label, " body is null"});
    status = source.validate();
    if (status == null)
      return snapshot_failure(
        failure_code, {label, " body validation returned null"}
      );
    if (!status.ok())
      return status;
    source_type_name = source.get_type_name();
    cloned_object = source.clone();
    if (cloned_object == null || !$cast(snapshot, cloned_object) ||
        snapshot == source || snapshot.get_type_name() != source_type_name) begin
      snapshot = null;
      return snapshot_failure(
        failure_code, {label, " body snapshot clone contract failed"}
      );
    end
    status = snapshot.validate();
    if (status == null) begin
      snapshot = null;
      return snapshot_failure(
        failure_code, {label, " body snapshot validation returned null"}
      );
    end
    if (!status.ok())
      snapshot = null;
    return status;
  endfunction

  protected function rdma_status checked_image_snapshot(
    rdma_hw_image source,
    string label,
    rdma_status_code_e failure_code,
    output rdma_hw_image snapshot
  );
    uvm_object cloned_object;
    rdma_hw_image saved_value;

    snapshot = null;
    if (source == null)
      return snapshot_failure(failure_code, {label, " image is null"});
    saved_value = rdma_hw_image::type_id::create({label, "_saved"});
    if (saved_value == null)
      return snapshot_failure(
        failure_code, {label, " image value capture failed"}
      );
    saved_value.bytes = source.bytes;
    saved_value.length = source.length;
    saved_value.alignment = source.alignment;
    saved_value.endian = source.endian;
    saved_value.image_kind = source.image_kind;
    saved_value.hardware_version = source.hardware_version;
    saved_value.function_generation = source.function_generation;
    saved_value.write_target_kind = source.write_target_kind;
    saved_value.backing_target = source.backing_target;
    saved_value.hmc_target = source.hmc_target;
    saved_value.bar_target = source.bar_target;
    saved_value.field_summary = source.field_summary;
    cloned_object = source.clone();
    if (cloned_object == null || !$cast(snapshot, cloned_object) ||
        snapshot == source) begin
      snapshot = null;
      return snapshot_failure(
        failure_code, {label, " image snapshot clone contract failed"}
      );
    end
    if (!same_image_value(source, saved_value) ||
        !same_image_value(snapshot, saved_value)) begin
      snapshot = null;
      return snapshot_failure(
        failure_code, {label, " image snapshot changed its source value"}
      );
    end
    return rdma_status::success();
  endfunction

  protected function rdma_status checked_expected_snapshot(
    rdma_cmq_expected_response source,
    string label,
    rdma_status_code_e failure_code,
    output rdma_cmq_expected_response snapshot
  );
    uvm_object cloned_object;
    rdma_status status;
    bit [31:0] saved_hardware_opcode;
    string saved_variant;

    snapshot = null;
    if (source == null)
      return snapshot_failure(
        failure_code, {label, " expected response is null"}
      );
    status = source.validate();
    if (status == null)
      return snapshot_failure(
        failure_code, {label, " expected validation returned null"}
      );
    if (!status.ok())
      return status;
    saved_hardware_opcode = source.hardware_opcode;
    saved_variant = source.variant;
    cloned_object = source.clone();
    if (cloned_object == null || !$cast(snapshot, cloned_object) ||
        snapshot == source) begin
      snapshot = null;
      return snapshot_failure(
        failure_code, {label, " expected snapshot clone contract failed"}
      );
    end
    if (source.hardware_opcode != saved_hardware_opcode ||
        source.variant != saved_variant ||
        snapshot.hardware_opcode != saved_hardware_opcode ||
        snapshot.variant != saved_variant) begin
      snapshot = null;
      return snapshot_failure(
        failure_code, {label, " expected snapshot changed its source value"}
      );
    end
    status = snapshot.validate();
    if (status == null) begin
      snapshot = null;
      return snapshot_failure(
        failure_code, {label, " expected snapshot validation returned null"}
      );
    end
    if (!status.ok())
      snapshot = null;
    return status;
  endfunction

  protected function rdma_status snapshot_command_value(
    rdma_cmq_command_desc source,
    output rdma_cmq_command_desc snapshot
  );
    rdma_status status;

    snapshot = null;
    if (source == null)
      return invalid_argument("CMQ command is null");
    snapshot = rdma_cmq_command_desc::type_id::create(
      "cmq_command_snapshot"
    );
    if (snapshot == null)
      return invalid_state("CMQ command snapshot construction failed");
    status = checked_function_snapshot(
      source.function_h, "CMQ command", RDMA_SC_INVALID_ARGUMENT,
      snapshot.function_h
    );
    if (!status.ok()) begin
      snapshot = null;
      return status;
    end
    status = checked_opcode_snapshot(
      source.opcode_key, "CMQ command", RDMA_SC_INVALID_ARGUMENT,
      snapshot.opcode_key
    );
    if (!status.ok()) begin
      snapshot = null;
      return status;
    end
    status = checked_body_snapshot(
      source.body, "CMQ command", RDMA_SC_INVALID_ARGUMENT, snapshot.body
    );
    if (!status.ok()) begin
      snapshot = null;
      return status;
    end
    if (source.qpc_signature_source != null) begin
      status = checked_image_snapshot(
        source.qpc_signature_source, "CMQ command signature",
        RDMA_SC_INVALID_ARGUMENT, snapshot.qpc_signature_source
      );
      if (!status.ok()) begin
        snapshot = null;
        return status;
      end
    end
    snapshot.vfid_override = source.vfid_override;
    snapshot.use_vfid = source.use_vfid;
    snapshot.timeout = source.timeout;
    status = snapshot.validate();
    if (status == null) begin
      snapshot = null;
      return invalid_state("CMQ command validation returned null status");
    end
    if (!status.ok())
      snapshot = null;
    return status;
  endfunction

  protected function rdma_status make_mapping_snapshot(
    rdma_dma_mapping source,
    string name,
    output rdma_dma_mapping snapshot
  );
    rdma_status status;
    uvm_object cloned_object;
    rdma_dma_mapping saved_value;

    snapshot = null;
    if (source == null)
      return invalid_state("CMQ dependency mapping source is null");
    saved_value = rdma_dma_mapping::type_id::create({name, "_saved"});
    if (saved_value == null)
      return invalid_state("CMQ dependency mapping value capture failed");
    status = checked_function_snapshot(
      source.function_h, "CMQ dependency mapping", RDMA_SC_INVALID_STATE,
      saved_value.function_h
    );
    if (!status.ok()) begin
      return status;
    end
    status = checked_handle_snapshot(
      source.owner_h, "CMQ dependency mapping owner", RDMA_SC_INVALID_STATE,
      saved_value.owner_h
    );
    if (!status.ok()) begin
      return status;
    end
    saved_value.requester_bdf = source.requester_bdf;
    saved_value.pasid_valid = source.pasid_valid;
    saved_value.pasid = source.pasid;
    saved_value.backing_addr = source.backing_addr;
    saved_value.iova = source.iova;
    saved_value.size = source.size;
    saved_value.direction = source.direction;
    saved_value.permissions = source.permissions;
    saved_value.state = source.state;
    cloned_object = source.clone();
    if (cloned_object == null || !$cast(snapshot, cloned_object) ||
        snapshot == source) begin
      snapshot = null;
      return invalid_state("CMQ dependency mapping clone contract failed");
    end
    if (!same_mapping_value(source, saved_value) ||
        !same_mapping_value(snapshot, saved_value) ||
        snapshot.function_h == source.function_h ||
        snapshot.owner_h == source.owner_h) begin
      snapshot = null;
      return invalid_state("CMQ dependency mapping snapshot changed value");
    end
    return rdma_status::success();
  endfunction

  protected function rdma_status make_ticket_value(
    string name,
    longint unsigned command_id,
    rdma_function_handle function_h,
    rdma_handle cmq_h,
    longint unsigned slot_sequence,
    int unsigned sq_index,
    bit sq_wrap,
    rdma_cmq_opcode_key opcode_key,
    time absolute_deadline,
    output rdma_cmq_ticket ticket
  );
    rdma_status status;
    uvm_object cloned_object;
    rdma_cmq_ticket detached_ticket;

    ticket = rdma_cmq_ticket::type_id::create(name);
    if (ticket == null)
      return invalid_state("CMQ ticket construction failed");
    ticket.command_id = command_id;
    status = checked_function_snapshot(
      function_h, "CMQ ticket", RDMA_SC_INVALID_STATE, ticket.function_h
    );
    if (!status.ok()) begin
      ticket = null;
      return status;
    end
    status = checked_handle_snapshot(
      cmq_h, "CMQ ticket", RDMA_SC_INVALID_STATE, ticket.cmq_h
    );
    if (!status.ok()) begin
      ticket = null;
      return status;
    end
    ticket.slot_sequence = slot_sequence;
    ticket.sq_index = sq_index;
    ticket.sq_wrap = sq_wrap;
    status = checked_opcode_snapshot(
      opcode_key, "CMQ ticket", RDMA_SC_INVALID_STATE, ticket.opcode_key
    );
    if (!status.ok()) begin
      ticket = null;
      return status;
    end
    ticket.absolute_deadline = absolute_deadline;
    status = ticket.validate();
    if (status == null || !status.ok()) begin
      ticket = null;
      return invalid_state("CMQ ticket validation failed");
    end
    cloned_object = ticket.clone();
    if (cloned_object == null ||
        !$cast(detached_ticket, cloned_object) ||
        detached_ticket == ticket ||
        !same_ticket_value(detached_ticket, ticket) ||
        detached_ticket.function_h == ticket.function_h ||
        detached_ticket.cmq_h == ticket.cmq_h ||
        detached_ticket.opcode_key == ticket.opcode_key) begin
      ticket = null;
      return invalid_state("CMQ ticket snapshot clone contract failed");
    end
    ticket = detached_ticket;
    return rdma_status::success();
  endfunction

  protected function rdma_status checked_slot_context_snapshot(
    rdma_cmq_slot_context source,
    output rdma_cmq_slot_context snapshot
  );
    uvm_object cloned_object;

    snapshot = null;
    if (source == null)
      return invalid_state("CMQ slot context source is null");
    cloned_object = source.clone();
    if (cloned_object == null || !$cast(snapshot, cloned_object) ||
        snapshot == source) begin
      snapshot = null;
      return invalid_state("CMQ slot context snapshot clone contract failed");
    end
    if (snapshot.function_h == null || source.function_h == null ||
        !snapshot.function_h.same_instance(source.function_h) ||
        snapshot.cmq_h == null || source.cmq_h == null ||
        !snapshot.cmq_h.same_instance(source.cmq_h) ||
        snapshot.backing_addr.value != source.backing_addr.value ||
        snapshot.relative_offset != source.relative_offset ||
        snapshot.slot_sequence != source.slot_sequence ||
        snapshot.sq_index != source.sq_index ||
        snapshot.sq_wrap != source.sq_wrap ||
        snapshot.function_h == source.function_h ||
        snapshot.cmq_h == source.cmq_h) begin
      snapshot = null;
      return invalid_state("CMQ slot context snapshot changed value");
    end
    return rdma_status::success();
  endfunction

  protected function rdma_status checked_record_snapshot(
    rdma_cmq_slot_record source,
    output rdma_cmq_slot_record snapshot
  );
    uvm_object cloned_object;

    snapshot = null;
    if (source == null)
      return invalid_state("CMQ slot record source is null");
    cloned_object = source.clone();
    if (cloned_object == null || !$cast(snapshot, cloned_object) ||
        snapshot == source) begin
      snapshot = null;
      return invalid_state("CMQ slot record snapshot clone contract failed");
    end
    if (snapshot.slot_sequence != source.slot_sequence ||
        snapshot.sq_index != source.sq_index ||
        snapshot.sq_wrap != source.sq_wrap ||
        snapshot.state != source.state ||
        snapshot.command_token != source.command_token ||
        !same_ticket_value(snapshot.ticket, source.ticket) ||
        !same_expected_value(snapshot.expected, source.expected) ||
        snapshot.ticket == source.ticket ||
        snapshot.expected == source.expected) begin
      snapshot = null;
      return invalid_state("CMQ slot record snapshot changed value");
    end
    return rdma_status::success();
  endfunction

  protected function rdma_status checked_dependency_snapshot(
    rdma_doorbell_dependency source,
    output rdma_doorbell_dependency snapshot
  );
    uvm_object cloned_object;

    snapshot = null;
    if (source == null)
      return invalid_state("CMQ dependency source is null");
    cloned_object = source.clone();
    if (cloned_object == null || !$cast(snapshot, cloned_object) ||
        snapshot == source) begin
      snapshot = null;
      return invalid_state("CMQ dependency snapshot clone contract failed");
    end
    if (!same_dependency_value(snapshot, source) ||
        snapshot.mapping == source.mapping || snapshot.image == source.image) begin
      snapshot = null;
      return invalid_state("CMQ dependency snapshot changed value");
    end
    return rdma_status::success();
  endfunction

  protected function rdma_status checked_doorbell_desc_snapshot(
    rdma_doorbell_desc source,
    output rdma_doorbell_desc snapshot
  );
    uvm_object cloned_object;

    snapshot = null;
    if (source == null)
      return invalid_state("CMQ doorbell descriptor source is null");
    cloned_object = source.clone();
    if (cloned_object == null || !$cast(snapshot, cloned_object) ||
        snapshot == source) begin
      snapshot = null;
      return invalid_state(
        "CMQ doorbell descriptor snapshot clone contract failed"
      );
    end
    if (snapshot.kind != source.kind ||
        snapshot.function_h == null || source.function_h == null ||
        !snapshot.function_h.same_instance(source.function_h) ||
        snapshot.target_h == null || source.target_h == null ||
        !snapshot.target_h.same_instance(source.target_h) ||
        snapshot.notify_bar_id != source.notify_bar_id ||
        snapshot.relative_offset != source.relative_offset ||
        snapshot.width != source.width || snapshot.endian != source.endian ||
        !same_image_value(snapshot.payload_image, source.payload_image) ||
        snapshot.barrier_policy != source.barrier_policy ||
        snapshot.write_combining_policy != source.write_combining_policy ||
        snapshot.allow_merge != source.allow_merge ||
        snapshot.merge_requested != source.merge_requested ||
        snapshot.timeout != source.timeout ||
        snapshot.readback_policy != source.readback_policy ||
        snapshot.dependencies.size() != source.dependencies.size() ||
        snapshot.function_h == source.function_h ||
        snapshot.target_h == source.target_h ||
        snapshot.payload_image == source.payload_image) begin
      snapshot = null;
      return invalid_state("CMQ doorbell descriptor snapshot changed value");
    end
    foreach (source.dependencies[i]) begin
      if (!same_dependency_value(snapshot.dependencies[i],
                                 source.dependencies[i]) ||
          snapshot.dependencies[i] == source.dependencies[i]) begin
        snapshot = null;
        return invalid_state(
          "CMQ doorbell descriptor dependency snapshot changed value"
        );
      end
    end
    return rdma_status::success();
  endfunction

  protected function rdma_status sqe_metadata_status(
    rdma_hw_image image,
    longint unsigned expected_backing_target
  );
    if (image == null)
      return invalid_state("CMQ profile returned a null SQE");
    if (image.length != CMQE_BYTES || image.bytes.size() != CMQE_BYTES)
      return invalid_argument("CMQ SQE is not exactly 64 bytes");
    if (image.alignment != CMQE_BYTES)
      return invalid_argument("CMQ SQE alignment is not 64 bytes");
    if (!(image.endian inside {RDMA_ENDIAN_LITTLE, RDMA_ENDIAN_BIG}) ||
        image.hardware_version == 0)
      return invalid_argument("CMQ SQE metadata is incomplete");
    if (image.image_kind != RDMA_IMAGE_CMQ_SQE)
      return invalid_argument("CMQ profile image is not an SQE");
    if (image.function_generation != prepared_binding.generation)
      return rdma_status::make(
        RDMA_SC_STALE_GENERATION, "CMQ SQE Function generation is stale"
      );
    if (image.write_target_kind != RDMA_HW_TARGET_BACKING)
      return invalid_argument("CMQ SQE write target is not backing memory");
    if (image.hmc_target.value != 0 || image.bar_target.value != 0)
      return invalid_argument("CMQ SQE has an inactive write target");
    if (image.backing_target.value != expected_backing_target)
      return invalid_argument(
        "CMQ SQE backing target does not match compacted slot"
      );
    return rdma_status::success();
  endfunction

  protected function rdma_status doorbell_metadata_status(
    rdma_hw_image image
  );
    if (image == null)
      return invalid_state("CMQ profile returned a null doorbell image");
    if (image.length == 0 || image.bytes.size() != image.length)
      return invalid_argument("CMQ doorbell image length is invalid");
    if (image.alignment == 0 ||
        (image.alignment & (image.alignment - 1'b1)) != 0)
      return invalid_argument("CMQ doorbell image alignment is invalid");
    if (!(image.endian inside {RDMA_ENDIAN_LITTLE, RDMA_ENDIAN_BIG}) ||
        image.hardware_version == 0)
      return invalid_argument("CMQ doorbell metadata is incomplete");
    if (image.image_kind != RDMA_IMAGE_DOORBELL)
      return invalid_argument("CMQ profile image is not a doorbell");
    if (image.function_generation != prepared_binding.generation)
      return rdma_status::make(
        RDMA_SC_STALE_GENERATION,
        "CMQ doorbell Function generation is stale"
      );
    if (image.write_target_kind != RDMA_HW_TARGET_BAR)
      return invalid_argument("CMQ doorbell target is not a BAR");
    if (image.backing_target.value != 0 || image.hmc_target.value != 0)
      return invalid_argument("CMQ doorbell has an inactive write target");
    if ((image.bar_target.value & (image.alignment - 1'b1)) != 0)
      return invalid_argument("CMQ doorbell BAR target is misaligned");
    if (image.bar_target.value > prepared_binding.notify_size ||
        image.length >
          (prepared_binding.notify_size - image.bar_target.value))
      return invalid_argument(
        "CMQ doorbell target is outside the notify aperture"
      );
    return rdma_status::success();
  endfunction

  protected virtual function rdma_status build_runtime_desc(
    rdma_dma_request_context request_context,
    rdma_cmq cmq,
    rdma_dma_mapping mapping,
    output rdma_cmq_runtime_desc runtime
  );
    rdma_status status;
    rdma_function_handle runtime_function;
    rdma_handle runtime_cmq;

    runtime = null;
    if (mapping.iova.value >
        (64'hffff_ffff_ffff_ffff - CQ_OFFSET))
      return rdma_status::make(
        RDMA_SC_DMA_TRANSLATION,
        "CMQ SQ-to-CQ IOVA addition overflows"
      );
    runtime = rdma_cmq_runtime_desc::type_id::create(
      "cmq_runtime_candidate"
    );
    if (runtime == null)
      return invalid_state("CMQ runtime descriptor construction failed");
    status = clone_function_handle_fields(request_context.function_h,
                                          "cmq_runtime_function",
                                          runtime_function);
    if (!status.ok()) begin
      runtime = null;
      return status;
    end
    status = clone_handle_fields(cmq.handle, "cmq_runtime_cmq",
                                 runtime_cmq);
    if (!status.ok()) begin
      runtime = null;
      return status;
    end
    runtime.function_h = runtime_function;
    runtime.cmq_h = runtime_cmq;
    runtime.sq_iova = mapping.iova;
    runtime.cq_iova.value = mapping.iova.value + CQ_OFFSET;
    runtime.sq_depth = CMQ_DEPTH;
    runtime.cq_depth = CMQ_DEPTH;
    runtime.entry_bytes = CMQE_BYTES;
    runtime.initial_sq_valid = 1'b1;
    runtime.initial_cq_owner = 1'b1;
    runtime.initial_doorbell_polarity = 1'b0;
    status = runtime.validate();
    if (status == null) begin
      runtime = null;
      return invalid_state("CMQ runtime descriptor returned null status");
    end
    if (!status.ok())
      runtime = null;
    return status;
  endfunction

  protected virtual function rdma_status publish_runtime_snapshot(
    rdma_cmq_runtime_desc source,
    output rdma_cmq_runtime_desc snapshot
  );
    rdma_status status;
    rdma_function_handle runtime_function;
    rdma_handle runtime_cmq;

    snapshot = null;
    if (source == null)
      return invalid_state("CMQ runtime snapshot source is null");
    snapshot = rdma_cmq_runtime_desc::type_id::create(
      "cmq_runtime_snapshot"
    );
    if (snapshot == null)
      return invalid_state("CMQ runtime snapshot construction failed");
    status = clone_function_handle_fields(source.function_h,
                                          "cmq_published_function",
                                          runtime_function);
    if (!status.ok()) begin
      snapshot = null;
      return status;
    end
    status = clone_handle_fields(source.cmq_h, "cmq_published_cmq",
                                 runtime_cmq);
    if (!status.ok()) begin
      snapshot = null;
      return status;
    end
    snapshot.function_h = runtime_function;
    snapshot.cmq_h = runtime_cmq;
    snapshot.sq_iova = source.sq_iova;
    snapshot.cq_iova = source.cq_iova;
    snapshot.sq_depth = source.sq_depth;
    snapshot.cq_depth = source.cq_depth;
    snapshot.entry_bytes = source.entry_bytes;
    snapshot.initial_sq_valid = source.initial_sq_valid;
    snapshot.initial_cq_owner = source.initial_cq_owner;
    snapshot.initial_doorbell_polarity =
      source.initial_doorbell_polarity;
    status = snapshot.validate();
    if (status == null) begin
      snapshot = null;
      return invalid_state("CMQ runtime snapshot returned null status");
    end
    if (!status.ok())
      snapshot = null;
    return status;
  endfunction

  protected function void clear_configuration();
    prepared_binding = null;
    dma_context = null;
    cmq_snapshot = null;
    backing_mapping = null;
    host_mem = null;
    scheduler = null;
    profile = null;
    publish_seq = 0;
    retire_seq = 0;
    cq_consume_seq = 0;
    foreach (slots[i]) begin
      slots[i] = null;
      token_in_use[i] = 1'b0;
    end
  endfunction

  protected function void retain_release_authority(
    rdma_dma_mapping retained_mapping,
    rdma_host_mem_api retained_host_mem
  );
    clear_configuration();
    if (retained_mapping != null) begin
      backing_mapping = retained_mapping;
      host_mem = retained_host_mem;
    end
    engine_state = RDMA_CMQ_ENGINE_POISONED;
  endfunction

  protected function rdma_status rollback_candidate(
    rdma_host_mem_api candidate_host_mem,
    rdma_dma_mapping candidate_mapping,
    rdma_status original_failure
  );
    rdma_status release_status;
    rdma_status cleanup_failure;
    string original_message;

    if (original_failure == null)
      original_failure = invalid_state("CMQ prepare failed with null status");
    if (candidate_mapping == null)
      return original_failure;
    release_status = candidate_host_mem.\release (candidate_mapping);
    if (release_status != null && release_status.ok()) begin
      clear_configuration();
      engine_state = RDMA_CMQ_ENGINE_UNCONFIGURED;
      return original_failure;
    end
    original_message = original_failure.message;
    retain_release_authority(candidate_mapping, candidate_host_mem);
    if (release_status == null)
      cleanup_failure = invalid_state(
        {"CMQ prepare rollback release returned null; original failure: ",
         original_message}
      );
    else
      cleanup_failure = rdma_status::make(
        release_status.code,
        {"CMQ prepare rollback release failed: ", release_status.message,
         "; original failure: ", original_message}
      );
    return cleanup_failure;
  endfunction

  task prepare(
    rdma_function_binding binding,
    rdma_cmq cmq,
    bit pasid_valid,
    bit [19:0] pasid,
    rdma_host_mem_api host_mem,
    rdma_doorbell_scheduler scheduler,
    rdma_cmq_hw_profile profile,
    output rdma_cmq_runtime_desc runtime_desc,
    output rdma_status status
  );
    rdma_function_binding binding_candidate;
    rdma_cmq cmq_candidate;
    rdma_dma_request_context context_candidate;
    rdma_dma_mapping mapping_candidate;
    rdma_cmq_runtime_desc runtime_candidate;
    rdma_cmq_runtime_desc published_runtime;
    byte zeros[];

    runtime_desc = null;
    status = invalid_state("CMQ prepare did not complete");
    engine_lock.get(1);
    if (engine_state != RDMA_CMQ_ENGINE_UNCONFIGURED) begin
      status = invalid_state("CMQ engine is already configured");
      engine_lock.put(1);
      return;
    end

    status = clone_binding_snapshot(binding, binding_candidate);
    if (!status.ok()) begin
      engine_lock.put(1);
      return;
    end
    status = prepared_binding_status(binding_candidate);
    if (!status.ok()) begin
      engine_lock.put(1);
      return;
    end
    status = clone_cmq_snapshot(cmq, cmq_candidate);
    if (!status.ok()) begin
      engine_lock.put(1);
      return;
    end
    status = cmq_resource_status(cmq_candidate, binding_candidate);
    if (!status.ok()) begin
      engine_lock.put(1);
      return;
    end
    if (host_mem == null) begin
      status = invalid_argument("CMQ host memory adapter is null");
      engine_lock.put(1);
      return;
    end
    if (scheduler == null) begin
      status = invalid_argument("CMQ doorbell scheduler is null");
      engine_lock.put(1);
      return;
    end
    if (profile == null) begin
      status = invalid_argument("CMQ hardware profile is null");
      engine_lock.put(1);
      return;
    end
    status = profile.validate_profile();
    if (status == null)
      status = invalid_state("CMQ hardware profile returned null status");
    if (!status.ok()) begin
      engine_lock.put(1);
      return;
    end
    status = make_request_context(binding_candidate, cmq_candidate,
                                  pasid_valid, pasid, context_candidate);
    if (!status.ok()) begin
      engine_lock.put(1);
      return;
    end

    mapping_candidate = null;
    status = host_mem.allocate(context_candidate, BACKING_BYTES,
                               BACKING_BYTES, RDMA_DMA_BIDIRECTIONAL,
                               mapping_candidate);
    if (status == null)
      status = invalid_state("CMQ host allocation returned null status");
    if (!status.ok()) begin
      if (mapping_candidate != null)
        status = rollback_candidate(host_mem, mapping_candidate, status);
      engine_lock.put(1);
      return;
    end
    status = mapping_authority_status(mapping_candidate,
                                      context_candidate);
    if (!status.ok()) begin
      status = rollback_candidate(host_mem, mapping_candidate, status);
      engine_lock.put(1);
      return;
    end

    zeros = new[BACKING_BYTES];
    foreach (zeros[i])
      zeros[i] = 0;
    status = host_mem.write(mapping_candidate, 0, zeros);
    if (status == null)
      status = invalid_state("CMQ backing zero-write returned null status");
    if (!status.ok()) begin
      status = rollback_candidate(host_mem, mapping_candidate, status);
      engine_lock.put(1);
      return;
    end
    status = build_runtime_desc(context_candidate, cmq_candidate,
                                mapping_candidate, runtime_candidate);
    if (status == null)
      status = invalid_state("CMQ runtime construction returned null status");
    if (!status.ok()) begin
      status = rollback_candidate(host_mem, mapping_candidate, status);
      engine_lock.put(1);
      return;
    end
    status = publish_runtime_snapshot(runtime_candidate,
                                      published_runtime);
    if (status == null)
      status = invalid_state("CMQ runtime publication returned null status");
    if (!status.ok() || published_runtime == null) begin
      if (status.ok())
        status = invalid_state("CMQ runtime publication returned null");
      status = rollback_candidate(host_mem, mapping_candidate, status);
      engine_lock.put(1);
      return;
    end

    cmq_candidate.queue_iova = runtime_candidate.sq_iova;
    cmq_candidate.completion_iova = runtime_candidate.cq_iova;
    prepared_binding = binding_candidate;
    dma_context = context_candidate;
    cmq_snapshot = cmq_candidate;
    backing_mapping = mapping_candidate;
    this.host_mem = host_mem;
    this.scheduler = scheduler;
    this.profile = profile;
    publish_seq = 0;
    retire_seq = 0;
    cq_consume_seq = 0;
    foreach (slots[i]) begin
      slots[i] = null;
      token_in_use[i] = 1'b0;
    end
    engine_state = RDMA_CMQ_ENGINE_PREPARED;
    runtime_desc = published_runtime;
    status = rdma_status::success();
    engine_lock.put(1);
  endtask

  task activate(
    rdma_function_binding active_binding,
    output rdma_status status
  );
    rdma_function_binding binding_candidate;

    status = invalid_state("CMQ activate did not complete");
    engine_lock.get(1);
    if (engine_state != RDMA_CMQ_ENGINE_PREPARED) begin
      status = invalid_state("CMQ engine is not PREPARED");
      engine_lock.put(1);
      return;
    end
    status = clone_binding_snapshot(active_binding, binding_candidate);
    if (!status.ok()) begin
      engine_lock.put(1);
      return;
    end
    status = active_binding_status(binding_candidate);
    if (!status.ok()) begin
      engine_lock.put(1);
      return;
    end
    if (prepared_binding == null) begin
      status = invalid_state("CMQ prepared binding authority is missing");
      engine_lock.put(1);
      return;
    end
    if (binding_candidate.function_uid != prepared_binding.function_uid ||
        binding_candidate.global_function_id !=
          prepared_binding.global_function_id) begin
      status = invalid_argument(
        "CMQ ACTIVE binding Function identity does not match PREPARED"
      );
      engine_lock.put(1);
      return;
    end
    if (binding_candidate.generation != prepared_binding.generation) begin
      status = rdma_status::make(
        RDMA_SC_STALE_GENERATION,
        "CMQ ACTIVE binding generation does not match PREPARED"
      );
      engine_lock.put(1);
      return;
    end
    if (!same_bdf(binding_candidate.pcie.bdf,
                  prepared_binding.pcie.bdf)) begin
      status = rdma_status::make(
        RDMA_SC_DMA_TRANSLATION,
        "CMQ ACTIVE binding BDF does not match PREPARED"
      );
      engine_lock.put(1);
      return;
    end
    status = mapping_authority_status(backing_mapping, dma_context);
    if (!status.ok()) begin
      engine_lock.put(1);
      return;
    end
    prepared_binding = binding_candidate;
    engine_state = RDMA_CMQ_ENGINE_ACTIVE;
    status = rdma_status::success();
    engine_lock.put(1);
  endtask

  task submit(
    rdma_cmq_command_desc request,
    output rdma_cmq_ticket ticket,
    output rdma_status status
  );
    rdma_cmq_command_desc requests[];
    rdma_cmq_ticket tickets[];
    rdma_status item_statuses[];
    rdma_status batch_status;

    ticket = null;
    status = invalid_state("CMQ submit did not complete");
    requests = new[1];
    requests[0] = request;
    submit_batch(requests, tickets, item_statuses, batch_status);
    if (item_statuses.size() != 1 || tickets.size() != 1) begin
      status = invalid_state("CMQ one-item batch returned misaligned outputs");
      return;
    end
    if (item_statuses[0] == null) begin
      status = invalid_state("CMQ one-item batch returned null item status");
      return;
    end
    if (!item_statuses[0].ok()) begin
      status = rdma_cmq_clone_status_value(item_statuses[0]);
      return;
    end
    if (batch_status == null) begin
      status = invalid_state("CMQ one-item batch returned null batch status");
      return;
    end
    if (!batch_status.ok()) begin
      status = rdma_cmq_clone_status_value(batch_status);
      return;
    end
    if (tickets[0] == null) begin
      status = invalid_state("CMQ one-item batch published no ticket");
      return;
    end
    ticket = tickets[0];
    status = rdma_status::success();
  endtask

  task submit_batch(
    input rdma_cmq_command_desc requests[],
    output rdma_cmq_ticket tickets[],
    output rdma_status item_statuses[],
    output rdma_status batch_status
  );
    rdma_cmq_ticket caller_tickets[CMQ_DEPTH];
    rdma_cmq_slot_record tentative_records[CMQ_DEPTH];
    rdma_status tentative_success_statuses[CMQ_DEPTH];
    rdma_doorbell_dependency dependencies[$];
    int unsigned original_indices[CMQ_DEPTH];
    bit [4:0] tentative_tokens[CMQ_DEPTH];
    time tentative_deadlines[CMQ_DEPTH];
    bit tentative_token_reserved[CMQ_DEPTH];
    bit preserve_item_status[];
    int unsigned success_count;
    rdma_function_handle active_function;
    rdma_hw_image doorbell_image;
    rdma_hw_image doorbell_snapshot;
    rdma_doorbell_desc doorbell_candidate;
    rdma_doorbell_desc doorbell_snapshot_desc;
    rdma_doorbell_result doorbell_result;
    rdma_status status;
    rdma_status transaction_status;
    rdma_status successful_batch_status;
    longint unsigned final_sequence;
    int unsigned final_pi;
    bit final_polarity;
    time minimum_remaining;
    time remaining;
    bit transaction_failed;

    tickets = new[requests.size()];
    item_statuses = new[requests.size()];
    preserve_item_status = new[requests.size()];
    foreach (tickets[i]) begin
      tickets[i] = null;
      item_statuses[i] = invalid_state("CMQ batch item was not published");
      preserve_item_status[i] = 1'b0;
    end
    batch_status = invalid_state("CMQ batch submit did not complete");
    success_count = 0;
    transaction_failed = 1'b0;
    transaction_status = null;
    successful_batch_status = null;
    dependencies.delete();
    foreach (tentative_token_reserved[i]) begin
      tentative_token_reserved[i] = 1'b0;
      caller_tickets[i] = null;
      tentative_records[i] = null;
      tentative_success_statuses[i] = null;
      original_indices[i] = 0;
      tentative_tokens[i] = '0;
      tentative_deadlines[i] = 0;
    end

    engine_lock.get(1);
    if (engine_state != RDMA_CMQ_ENGINE_ACTIVE) begin
      batch_status = invalid_state("CMQ submit requires an ACTIVE engine");
      foreach (item_statuses[i])
        item_statuses[i] = rdma_cmq_clone_status_value(batch_status);
      engine_lock.put(1);
      return;
    end
    if (prepared_binding == null || cmq_snapshot == null ||
        backing_mapping == null || scheduler == null || profile == null) begin
      batch_status = invalid_state("CMQ ACTIVE publication authority is missing");
      foreach (item_statuses[i])
        item_statuses[i] = rdma_cmq_clone_status_value(batch_status);
      engine_lock.put(1);
      return;
    end
    active_function = prepared_binding.make_handle();
    if (active_function == null) begin
      batch_status = invalid_state("CMQ ACTIVE Function handle is missing");
      foreach (item_statuses[i])
        item_statuses[i] = rdma_cmq_clone_status_value(batch_status);
      engine_lock.put(1);
      return;
    end
    if (requests.size() == 0) begin
      batch_status = rdma_status::success();
      engine_lock.put(1);
      return;
    end

    foreach (requests[i]) begin : stage_each_request
      rdma_cmq_command_desc command_snapshot;
      rdma_cmq_slot_context slot_context;
      rdma_cmq_slot_context slot_context_snapshot;
      rdma_hw_image profile_sqe;
      rdma_hw_image sqe_snapshot;
      rdma_cmq_expected_response profile_expected;
      rdma_cmq_expected_response expected_snapshot;
      rdma_cmq_ticket authority_ticket;
      rdma_cmq_ticket caller_ticket;
      rdma_cmq_slot_record record_candidate;
      rdma_cmq_slot_record record_snapshot;
      rdma_doorbell_dependency dependency_candidate;
      rdma_doorbell_dependency dependency_snapshot;
      rdma_dma_mapping dependency_mapping;
      time absolute_deadline;
      longint unsigned slot_sequence;
      longint unsigned relative_offset;
      longint unsigned expected_backing_target;
      longint unsigned command_id;
      int unsigned sq_index;
      int unsigned selected_token;
      bit sq_wrap;
      bit token_found;

      command_snapshot = null;
      slot_context_snapshot = null;
      profile_sqe = null;
      sqe_snapshot = null;
      profile_expected = null;
      expected_snapshot = null;
      authority_ticket = null;
      caller_ticket = null;
      record_candidate = null;
      record_snapshot = null;
      dependency_candidate = null;
      dependency_snapshot = null;
      dependency_mapping = null;
      token_found = 1'b0;
      selected_token = 0;

      status = snapshot_command_value(requests[i], command_snapshot);
      if (!status.ok()) begin
        item_statuses[i] = rdma_cmq_clone_status_value(status);
        preserve_item_status[i] = 1'b1;
        continue;
      end
      if (command_snapshot.function_h.kind != active_function.kind ||
          command_snapshot.function_h.function_uid !=
            active_function.function_uid ||
          command_snapshot.function_h.object_id != active_function.object_id) begin
        item_statuses[i] = invalid_argument(
          "CMQ command Function identity does not match ACTIVE binding"
        );
        preserve_item_status[i] = 1'b1;
        continue;
      end
      if (command_snapshot.function_h.generation !=
          active_function.generation) begin
        item_statuses[i] = rdma_status::make(
          RDMA_SC_STALE_GENERATION,
          "CMQ command Function generation does not match ACTIVE binding"
        );
        preserve_item_status[i] = 1'b1;
        continue;
      end
      if (command_snapshot.opcode_key.profile_name !=
          profile.profile_name()) begin
        item_statuses[i] = rdma_status::make(
          RDMA_SC_UNSUPPORTED_OPCODE,
          "CMQ command opcode profile does not match ACTIVE profile"
        );
        preserve_item_status[i] = 1'b1;
        continue;
      end
      if ($isunknown(command_snapshot.timeout)) begin
        item_statuses[i] = invalid_argument(
          "CMQ command timeout contains an unknown bit"
        );
        preserve_item_status[i] = 1'b1;
        continue;
      end
      absolute_deadline = $time + command_snapshot.timeout;
      if ($isunknown(absolute_deadline) || absolute_deadline == 0 ||
          absolute_deadline < $time) begin
        item_statuses[i] = invalid_argument(
          "CMQ command absolute deadline overflows simulation time"
        );
        preserve_item_status[i] = 1'b1;
        continue;
      end
      if ((publish_seq - retire_seq) + success_count >= CMQ_DEPTH) begin
        item_statuses[i] = rdma_status::make(
          RDMA_SC_QUEUE_FULL, "CMQ submission ring is full"
        );
        preserve_item_status[i] = 1'b1;
        continue;
      end

      for (int unsigned token_index = 0;
           token_index < CMQ_DEPTH; token_index++) begin
        if (!token_found && !token_in_use[token_index] &&
            !tentative_token_reserved[token_index] &&
            token_incarnation[token_index] != {59{1'b1}}) begin
          token_found = 1'b1;
          selected_token = token_index;
        end
      end
      if (!token_found) begin
        item_statuses[i] = rdma_status::make(
          RDMA_SC_RESOURCE_EXHAUSTED, "CMQ command tokens are exhausted"
        );
        preserve_item_status[i] = 1'b1;
        continue;
      end
      token_incarnation[selected_token]++;
      tentative_token_reserved[selected_token] = 1'b1;
      command_id = {token_incarnation[selected_token],
                    selected_token[4:0]};
      if (command_id == 0) begin
        tentative_token_reserved[selected_token] = 1'b0;
        item_statuses[i] = rdma_status::make(
          RDMA_SC_RESOURCE_EXHAUSTED, "CMQ command ID is exhausted"
        );
        preserve_item_status[i] = 1'b1;
        continue;
      end

      if (publish_seq >
          (64'hffff_ffff_ffff_ffff - success_count)) begin
        tentative_token_reserved[selected_token] = 1'b0;
        item_statuses[i] = rdma_status::make(
          RDMA_SC_RESOURCE_EXHAUSTED, "CMQ slot sequence overflows"
        );
        preserve_item_status[i] = 1'b1;
        continue;
      end
      slot_sequence = publish_seq + success_count;
      if (slot_sequence == 64'hffff_ffff_ffff_ffff) begin
        tentative_token_reserved[selected_token] = 1'b0;
        item_statuses[i] = rdma_status::make(
          RDMA_SC_RESOURCE_EXHAUSTED,
          "CMQ dependency identifier would overflow"
        );
        preserve_item_status[i] = 1'b1;
        continue;
      end
      sq_index = slot_sequence % CMQ_DEPTH;
      sq_wrap = (slot_sequence / CMQ_DEPTH) & 1'b1;
      relative_offset = longint'(sq_index) * CMQE_BYTES;
      if (backing_mapping.backing_addr.value >
          (64'hffff_ffff_ffff_ffff - relative_offset)) begin
        tentative_token_reserved[selected_token] = 1'b0;
        item_statuses[i] = rdma_status::make(
          RDMA_SC_DMA_TRANSLATION, "CMQ SQE backing address overflows"
        );
        preserve_item_status[i] = 1'b1;
        continue;
      end
      expected_backing_target = backing_mapping.backing_addr.value +
                                relative_offset;

      slot_context = rdma_cmq_slot_context::type_id::create(
        $sformatf("cmq_slot_context_%0d", slot_sequence)
      );
      if (slot_context == null) begin
        transaction_status = invalid_state(
          "CMQ slot context construction failed"
        );
        transaction_failed = 1'b1;
        break;
      end
      status = checked_function_snapshot(
        active_function, "CMQ submission slot", RDMA_SC_INVALID_STATE,
        slot_context.function_h
      );
      if (!status.ok()) begin
        transaction_status = status;
        transaction_failed = 1'b1;
        break;
      end
      status = checked_handle_snapshot(
        cmq_snapshot.handle, "CMQ submission slot", RDMA_SC_INVALID_STATE,
        slot_context.cmq_h
      );
      if (!status.ok()) begin
        transaction_status = status;
        transaction_failed = 1'b1;
        break;
      end
      slot_context.backing_addr = backing_mapping.backing_addr;
      slot_context.relative_offset = relative_offset;
      slot_context.slot_sequence = slot_sequence;
      slot_context.sq_index = sq_index;
      slot_context.sq_wrap = sq_wrap;
      status = slot_context.validate();
      if (status == null || !status.ok()) begin
        transaction_status = invalid_state(
          "CMQ slot context validation failed"
        );
        transaction_failed = 1'b1;
        break;
      end
      status = checked_slot_context_snapshot(slot_context,
                                             slot_context_snapshot);
      if (!status.ok()) begin
        transaction_status = status;
        transaction_failed = 1'b1;
        break;
      end

      status = profile.compose_sqe(command_snapshot, slot_context_snapshot,
                                   profile_sqe, profile_expected);
      if (status == null)
        status = invalid_state("CMQ SQE composition returned null status");
      if (!status.ok()) begin
        tentative_token_reserved[selected_token] = 1'b0;
        item_statuses[i] = rdma_cmq_clone_status_value(status);
        preserve_item_status[i] = 1'b1;
        continue;
      end
      status = sqe_metadata_status(profile_sqe, expected_backing_target);
      if (!status.ok()) begin
        transaction_status = status;
        transaction_failed = 1'b1;
        break;
      end
      status = checked_image_snapshot(
        profile_sqe, "CMQ SQE", RDMA_SC_INVALID_STATE, sqe_snapshot
      );
      if (!status.ok()) begin
        transaction_status = status;
        transaction_failed = 1'b1;
        break;
      end
      status = sqe_metadata_status(sqe_snapshot, expected_backing_target);
      if (!status.ok()) begin
        transaction_status = status;
        transaction_failed = 1'b1;
        break;
      end
      status = checked_expected_snapshot(
        profile_expected, "CMQ profile", RDMA_SC_INVALID_STATE,
        expected_snapshot
      );
      if (!status.ok()) begin
        transaction_status = status;
        transaction_failed = 1'b1;
        break;
      end

      status = make_ticket_value(
        $sformatf("cmq_authority_ticket_%0d", command_id), command_id,
        active_function, cmq_snapshot.handle, slot_sequence, sq_index,
        sq_wrap, command_snapshot.opcode_key, absolute_deadline,
        authority_ticket
      );
      if (!status.ok()) begin
        transaction_status = status;
        transaction_failed = 1'b1;
        break;
      end
      status = make_ticket_value(
        $sformatf("cmq_caller_ticket_%0d", command_id), command_id,
        active_function, cmq_snapshot.handle, slot_sequence, sq_index,
        sq_wrap, command_snapshot.opcode_key, absolute_deadline,
        caller_ticket
      );
      if (!status.ok()) begin
        transaction_status = status;
        transaction_failed = 1'b1;
        break;
      end

      record_candidate = rdma_cmq_slot_record::type_id::create(
        $sformatf("cmq_slot_record_%0d", slot_sequence)
      );
      if (record_candidate == null) begin
        transaction_status = invalid_state(
          "CMQ slot record construction failed"
        );
        transaction_failed = 1'b1;
        break;
      end
      record_candidate.slot_sequence = slot_sequence;
      record_candidate.sq_index = sq_index;
      record_candidate.sq_wrap = sq_wrap;
      record_candidate.state = CMQ_SLOT_PUBLISHED;
      record_candidate.ticket = authority_ticket;
      record_candidate.expected = expected_snapshot;
      record_candidate.command_token = selected_token[4:0];
      status = checked_record_snapshot(record_candidate, record_snapshot);
      if (!status.ok()) begin
        transaction_status = status;
        transaction_failed = 1'b1;
        break;
      end

      dependency_candidate = rdma_doorbell_dependency::type_id::create(
        $sformatf("cmq_dependency_%0d", slot_sequence + 1'b1)
      );
      status = make_mapping_snapshot(
        backing_mapping, $sformatf("cmq_dependency_mapping_%0d",
                                   slot_sequence), dependency_mapping
      );
      if (dependency_candidate == null || !status.ok() ||
          dependency_mapping == null) begin
        transaction_status = invalid_state(
          "CMQ scheduler dependency construction failed"
        );
        transaction_failed = 1'b1;
        break;
      end
      dependency_candidate.dependency_id = slot_sequence + 1'b1;
      dependency_candidate.stage = RDMA_DB_DEP_QUEUE_CONTEXT;
      dependency_candidate.mapping = dependency_mapping;
      dependency_candidate.relative_offset = relative_offset;
      dependency_candidate.image = sqe_snapshot;
      dependency_candidate.ready = 1'b1;
      status = checked_dependency_snapshot(dependency_candidate,
                                           dependency_snapshot);
      if (!status.ok()) begin
        transaction_status = status;
        transaction_failed = 1'b1;
        break;
      end

      original_indices[success_count] = i;
      tentative_tokens[success_count] = selected_token[4:0];
      tentative_deadlines[success_count] = absolute_deadline;
      caller_tickets[success_count] = caller_ticket;
      tentative_records[success_count] = record_snapshot;
      tentative_success_statuses[success_count] = rdma_status::success();
      dependencies.push_back(dependency_snapshot);
      success_count++;
    end

    if (!transaction_failed && success_count == 0) begin
      batch_status = rdma_status::success();
      engine_lock.put(1);
      return;
    end

    if (!transaction_failed) begin
      if (publish_seq >
          (64'hffff_ffff_ffff_ffff - success_count)) begin
        transaction_status = rdma_status::make(
          RDMA_SC_RESOURCE_EXHAUSTED,
          "CMQ final producer sequence overflows"
        );
        transaction_failed = 1'b1;
      end
      else begin
        final_sequence = publish_seq + success_count;
        final_pi = final_sequence % CMQ_DEPTH;
        final_polarity = (final_sequence / CMQ_DEPTH) & 1'b1;
        doorbell_image = null;
        status = profile.encode_doorbell(cmq_snapshot.handle, final_pi,
                                         final_polarity, doorbell_image);
        if (status == null)
          status = invalid_state("CMQ doorbell encoding returned null status");
        if (!status.ok()) begin
          transaction_status = status;
          transaction_failed = 1'b1;
        end
      end
    end

    if (!transaction_failed) begin
      status = doorbell_metadata_status(doorbell_image);
      if (!status.ok()) begin
        transaction_status = status;
        transaction_failed = 1'b1;
      end
    end
    if (!transaction_failed) begin
      status = checked_image_snapshot(
        doorbell_image, "CMQ doorbell", RDMA_SC_INVALID_STATE,
        doorbell_snapshot
      );
      if (!status.ok()) begin
        transaction_status = status;
        transaction_failed = 1'b1;
      end
    end
    if (!transaction_failed) begin
      status = doorbell_metadata_status(doorbell_snapshot);
      if (!status.ok()) begin
        transaction_status = status;
        transaction_failed = 1'b1;
      end
    end

    if (!transaction_failed) begin
      minimum_remaining = 0;
      for (int unsigned success_index = 0;
           success_index < success_count; success_index++) begin
        if ($time >= tentative_deadlines[success_index]) begin
          transaction_status = rdma_status::make(
            RDMA_SC_TIMEOUT, "CMQ batch deadline expired before publication"
          );
          transaction_failed = 1'b1;
          break;
        end
        remaining = tentative_deadlines[success_index] - $time;
        if (minimum_remaining == 0 || remaining < minimum_remaining)
          minimum_remaining = remaining;
      end
    end

    doorbell_candidate = null;
    doorbell_snapshot_desc = null;
    if (!transaction_failed) begin
      doorbell_candidate = rdma_doorbell_desc::type_id::create(
        "cmq_batch_doorbell_candidate"
      );
      if (doorbell_candidate == null) begin
        transaction_status = invalid_state(
          "CMQ doorbell descriptor construction failed"
        );
        transaction_failed = 1'b1;
      end
    end
    if (!transaction_failed) begin
      doorbell_candidate.kind = RDMA_DOORBELL_CMQ_SQ;
      status = checked_function_snapshot(
        active_function, "CMQ doorbell descriptor", RDMA_SC_INVALID_STATE,
        doorbell_candidate.function_h
      );
      if (!status.ok()) begin
        transaction_status = status;
        transaction_failed = 1'b1;
      end
    end
    if (!transaction_failed) begin
      status = checked_handle_snapshot(
        cmq_snapshot.handle, "CMQ doorbell descriptor",
        RDMA_SC_INVALID_STATE, doorbell_candidate.target_h
      );
      if (!status.ok()) begin
        transaction_status = status;
        transaction_failed = 1'b1;
      end
    end
    if (!transaction_failed) begin
      doorbell_candidate.notify_bar_id = prepared_binding.notify_bar_id;
      doorbell_candidate.relative_offset = doorbell_snapshot.bar_target.value;
      doorbell_candidate.width = doorbell_snapshot.length;
      doorbell_candidate.endian = doorbell_snapshot.endian;
      doorbell_candidate.payload_image = doorbell_snapshot;
      doorbell_candidate.barrier_policy = RDMA_DB_BARRIER_DMA_MMIO;
      doorbell_candidate.write_combining_policy =
        RDMA_DB_WRITE_NON_COMBINING;
      doorbell_candidate.allow_merge = 1'b0;
      doorbell_candidate.merge_requested = 1'b0;
      doorbell_candidate.dependencies = dependencies;
      doorbell_candidate.timeout = minimum_remaining;
      doorbell_candidate.readback_policy = RDMA_DB_READBACK_NONE;
      status = checked_doorbell_desc_snapshot(doorbell_candidate,
                                              doorbell_snapshot_desc);
      if (!status.ok()) begin
        transaction_status = status;
        transaction_failed = 1'b1;
      end
    end

    if (!transaction_failed) begin
      successful_batch_status = rdma_status::success();
      doorbell_result = null;
      scheduler.submit(prepared_binding, doorbell_snapshot_desc,
                       doorbell_result,
                       status);
      if (status == null)
        status = invalid_state("CMQ doorbell scheduler returned null status");
      else if (status.ok() && doorbell_result == null)
        status = invalid_state("CMQ doorbell scheduler returned no result");
      if (!status.ok()) begin
        transaction_status = status;
        transaction_failed = 1'b1;
      end
    end

    if (transaction_failed) begin
      if (transaction_status == null)
        transaction_status = invalid_state(
          "CMQ batch transaction failed without a status"
        );
      foreach (tentative_token_reserved[token_index])
        tentative_token_reserved[token_index] = 1'b0;
      foreach (tickets[item_index]) begin
        tickets[item_index] = null;
        if (!preserve_item_status[item_index])
          item_statuses[item_index] =
            rdma_cmq_clone_status_value(transaction_status);
      end
      batch_status = rdma_cmq_clone_status_value(transaction_status);
      engine_lock.put(1);
      return;
    end

    for (int unsigned success_index = 0;
         success_index < success_count; success_index++) begin
      int unsigned original_index;
      int unsigned token_index;
      int unsigned slot_index;

      original_index = original_indices[success_index];
      token_index = tentative_tokens[success_index];
      slot_index = tentative_records[success_index].sq_index;
      token_in_use[token_index] = 1'b1;
      slots[slot_index] = tentative_records[success_index];
      tickets[original_index] = caller_tickets[success_index];
      item_statuses[original_index] =
        tentative_success_statuses[success_index];
      tentative_token_reserved[token_index] = 1'b0;
    end
    publish_seq += success_count;
    batch_status = successful_batch_status;
    engine_lock.put(1);
  endtask

  function rdma_cmq_engine_state_e state();
    return engine_state;
  endfunction

  function rdma_dma_mapping mapping_snapshot();
    uvm_object cloned_object;
    rdma_dma_mapping snapshot;

    if (backing_mapping == null)
      return null;
    cloned_object = backing_mapping.clone();
    if (cloned_object == null || !$cast(snapshot, cloned_object))
      `uvm_fatal("RDMA_COPY_TYPE", "CMQ mapping snapshot clone mismatch")
    return snapshot;
  endfunction

  function longint unsigned published_count();
    return publish_seq;
  endfunction

  function longint unsigned retired_count();
    return retire_seq;
  endfunction

  function longint unsigned cq_consumed_count();
    return cq_consume_seq;
  endfunction

  task shutdown(output rdma_status status);
    rdma_status release_status;

    status = invalid_state("CMQ shutdown did not complete");
    engine_lock.get(1);
    if (engine_state == RDMA_CMQ_ENGINE_UNCONFIGURED) begin
      clear_configuration();
      status = rdma_status::success();
      engine_lock.put(1);
      return;
    end
    if (!(engine_state inside {RDMA_CMQ_ENGINE_PREPARED,
                               RDMA_CMQ_ENGINE_ACTIVE,
                               RDMA_CMQ_ENGINE_POISONED})) begin
      status = invalid_state("CMQ engine state cannot be shut down");
      engine_lock.put(1);
      return;
    end
    if (backing_mapping == null || host_mem == null) begin
      retain_release_authority(backing_mapping, host_mem);
      status = invalid_state("CMQ shutdown release authority is missing");
      engine_lock.put(1);
      return;
    end
    release_status = host_mem.\release (backing_mapping);
    if (release_status == null) begin
      retain_release_authority(backing_mapping, host_mem);
      status = invalid_state("CMQ shutdown release returned null status");
      engine_lock.put(1);
      return;
    end
    if (!release_status.ok()) begin
      retain_release_authority(backing_mapping, host_mem);
      status = release_status;
      engine_lock.put(1);
      return;
    end
    clear_configuration();
    engine_state = RDMA_CMQ_ENGINE_UNCONFIGURED;
    status = rdma_status::success();
    engine_lock.put(1);
  endtask
endclass
