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
      token_incarnation[i] = '0;
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
      token_incarnation[i] = '0;
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
    ticket = rdma_cmq_clone_ticket_value(tickets[0], "CMQ submit output");
    status = rdma_status::success();
  endtask

  task submit_batch(
    input rdma_cmq_command_desc requests[],
    output rdma_cmq_ticket tickets[],
    output rdma_status item_statuses[],
    output rdma_status batch_status
  );
    rdma_cmq_ticket tentative_tickets[CMQ_DEPTH];
    rdma_cmq_slot_record tentative_records[CMQ_DEPTH];
    rdma_doorbell_dependency dependencies[$];
    int unsigned original_indices[CMQ_DEPTH];
    bit [4:0] tentative_tokens[CMQ_DEPTH];
    time tentative_deadlines[CMQ_DEPTH];
    bit tentative_token_reserved[CMQ_DEPTH];
    int unsigned success_count;
    rdma_function_handle active_function;
    rdma_hw_image doorbell_image;
    rdma_hw_image doorbell_snapshot;
    rdma_doorbell_desc doorbell_desc;
    rdma_doorbell_result doorbell_result;
    rdma_status status;
    longint unsigned final_sequence;
    int unsigned final_pi;
    bit final_polarity;
    time minimum_remaining;
    time remaining;

    tickets = new[requests.size()];
    item_statuses = new[requests.size()];
    foreach (tickets[i]) begin
      tickets[i] = null;
      item_statuses[i] = invalid_state("CMQ batch item was not published");
    end
    batch_status = invalid_state("CMQ batch submit did not complete");
    success_count = 0;
    dependencies.delete();
    foreach (tentative_token_reserved[i]) begin
      tentative_token_reserved[i] = 1'b0;
      tentative_tickets[i] = null;
      tentative_records[i] = null;
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
      uvm_object cloned_object;
      rdma_cmq_command_desc command_snapshot;
      rdma_cmq_slot_context slot_context;
      rdma_hw_image profile_sqe;
      rdma_hw_image sqe_snapshot;
      rdma_cmq_expected_response profile_expected;
      rdma_cmq_expected_response expected_snapshot;
      rdma_cmq_ticket tentative_ticket;
      rdma_cmq_slot_record tentative_record;
      rdma_doorbell_dependency dependency;
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
      profile_sqe = null;
      sqe_snapshot = null;
      profile_expected = null;
      expected_snapshot = null;
      tentative_ticket = null;
      tentative_record = null;
      dependency = null;
      dependency_mapping = null;
      token_found = 1'b0;
      selected_token = 0;

      if (requests[i] == null) begin
        item_statuses[i] = invalid_argument("CMQ command is null");
        continue;
      end
      cloned_object = requests[i].clone();
      if (cloned_object == null ||
          !$cast(command_snapshot, cloned_object)) begin
        item_statuses[i] = invalid_state("CMQ command snapshot clone failed");
        continue;
      end
      status = command_snapshot.validate();
      if (status == null)
        status = invalid_state("CMQ command validation returned null status");
      if (!status.ok()) begin
        item_statuses[i] = rdma_cmq_clone_status_value(status);
        continue;
      end
      if (command_snapshot.function_h.kind != active_function.kind ||
          command_snapshot.function_h.function_uid !=
            active_function.function_uid ||
          command_snapshot.function_h.object_id != active_function.object_id) begin
        item_statuses[i] = invalid_argument(
          "CMQ command Function identity does not match ACTIVE binding"
        );
        continue;
      end
      if (command_snapshot.function_h.generation !=
          active_function.generation) begin
        item_statuses[i] = rdma_status::make(
          RDMA_SC_STALE_GENERATION,
          "CMQ command Function generation does not match ACTIVE binding"
        );
        continue;
      end
      if (command_snapshot.opcode_key.profile_name !=
          profile.profile_name()) begin
        item_statuses[i] = rdma_status::make(
          RDMA_SC_UNSUPPORTED_OPCODE,
          "CMQ command opcode profile does not match ACTIVE profile"
        );
        continue;
      end
      absolute_deadline = $time + command_snapshot.timeout;
      if (absolute_deadline == 0 || absolute_deadline < $time) begin
        item_statuses[i] = invalid_argument(
          "CMQ command absolute deadline overflows simulation time"
        );
        continue;
      end
      if ((publish_seq - retire_seq) + success_count >= CMQ_DEPTH) begin
        item_statuses[i] = rdma_status::make(
          RDMA_SC_QUEUE_FULL, "CMQ submission ring is full"
        );
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
        continue;
      end

      if (publish_seq >
          (64'hffff_ffff_ffff_ffff - success_count)) begin
        tentative_token_reserved[selected_token] = 1'b0;
        item_statuses[i] = rdma_status::make(
          RDMA_SC_RESOURCE_EXHAUSTED, "CMQ slot sequence overflows"
        );
        continue;
      end
      slot_sequence = publish_seq + success_count;
      if (slot_sequence == 64'hffff_ffff_ffff_ffff) begin
        tentative_token_reserved[selected_token] = 1'b0;
        item_statuses[i] = rdma_status::make(
          RDMA_SC_RESOURCE_EXHAUSTED,
          "CMQ dependency identifier would overflow"
        );
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
        continue;
      end
      expected_backing_target = backing_mapping.backing_addr.value +
                                relative_offset;

      slot_context = rdma_cmq_slot_context::type_id::create(
        $sformatf("cmq_slot_context_%0d", slot_sequence)
      );
      if (slot_context == null) begin
        tentative_token_reserved[selected_token] = 1'b0;
        item_statuses[i] = invalid_state(
          "CMQ slot context construction failed"
        );
        continue;
      end
      slot_context.function_h = rdma_clone_function_handle_value(
        active_function, "CMQ submission slot"
      );
      slot_context.cmq_h = rdma_clone_handle_value(
        cmq_snapshot.handle, "CMQ submission slot"
      );
      slot_context.backing_addr = backing_mapping.backing_addr;
      slot_context.relative_offset = relative_offset;
      slot_context.slot_sequence = slot_sequence;
      slot_context.sq_index = sq_index;
      slot_context.sq_wrap = sq_wrap;
      status = slot_context.validate();
      if (status == null)
        status = invalid_state("CMQ slot context validation returned null");
      if (!status.ok()) begin
        tentative_token_reserved[selected_token] = 1'b0;
        item_statuses[i] = rdma_cmq_clone_status_value(status);
        continue;
      end

      status = profile.compose_sqe(command_snapshot, slot_context,
                                   profile_sqe, profile_expected);
      if (status == null)
        status = invalid_state("CMQ SQE composition returned null status");
      if (!status.ok()) begin
        tentative_token_reserved[selected_token] = 1'b0;
        item_statuses[i] = rdma_cmq_clone_status_value(status);
        continue;
      end
      if (profile_sqe == null) begin
        tentative_token_reserved[selected_token] = 1'b0;
        item_statuses[i] = invalid_state("CMQ profile returned a null SQE");
        continue;
      end
      if (profile_sqe.length != CMQE_BYTES ||
          profile_sqe.bytes.size() != CMQE_BYTES) begin
        tentative_token_reserved[selected_token] = 1'b0;
        item_statuses[i] = invalid_argument("CMQ SQE is not exactly 64 bytes");
        continue;
      end
      if (profile_sqe.alignment != CMQE_BYTES) begin
        tentative_token_reserved[selected_token] = 1'b0;
        item_statuses[i] = invalid_argument("CMQ SQE alignment is not 64 bytes");
        continue;
      end
      if (!(profile_sqe.endian inside {RDMA_ENDIAN_LITTLE,
                                       RDMA_ENDIAN_BIG}) ||
          profile_sqe.hardware_version == 0) begin
        tentative_token_reserved[selected_token] = 1'b0;
        item_statuses[i] = invalid_argument("CMQ SQE metadata is incomplete");
        continue;
      end
      if (profile_sqe.image_kind != RDMA_IMAGE_CMQ_SQE) begin
        tentative_token_reserved[selected_token] = 1'b0;
        item_statuses[i] = invalid_argument("CMQ profile image is not an SQE");
        continue;
      end
      if (profile_sqe.function_generation != prepared_binding.generation) begin
        tentative_token_reserved[selected_token] = 1'b0;
        item_statuses[i] = rdma_status::make(
          RDMA_SC_STALE_GENERATION, "CMQ SQE Function generation is stale"
        );
        continue;
      end
      if (profile_sqe.write_target_kind != RDMA_HW_TARGET_BACKING) begin
        tentative_token_reserved[selected_token] = 1'b0;
        item_statuses[i] = invalid_argument(
          "CMQ SQE write target is not backing memory"
        );
        continue;
      end
      if (profile_sqe.backing_target.value != expected_backing_target) begin
        tentative_token_reserved[selected_token] = 1'b0;
        item_statuses[i] = invalid_argument(
          "CMQ SQE backing target does not match compacted slot"
        );
        continue;
      end
      cloned_object = profile_sqe.clone();
      if (cloned_object == null || !$cast(sqe_snapshot, cloned_object)) begin
        tentative_token_reserved[selected_token] = 1'b0;
        item_statuses[i] = invalid_state("CMQ SQE snapshot clone failed");
        continue;
      end
      if (profile_expected == null) begin
        tentative_token_reserved[selected_token] = 1'b0;
        item_statuses[i] = invalid_state(
          "CMQ profile returned a null expected response"
        );
        continue;
      end
      status = profile_expected.validate();
      if (status == null)
        status = invalid_state(
          "CMQ expected response validation returned null status"
        );
      if (!status.ok()) begin
        tentative_token_reserved[selected_token] = 1'b0;
        item_statuses[i] = rdma_cmq_clone_status_value(status);
        continue;
      end
      cloned_object = profile_expected.clone();
      if (cloned_object == null ||
          !$cast(expected_snapshot, cloned_object)) begin
        tentative_token_reserved[selected_token] = 1'b0;
        item_statuses[i] = invalid_state(
          "CMQ expected response snapshot clone failed"
        );
        continue;
      end

      tentative_ticket = rdma_cmq_ticket::type_id::create(
        $sformatf("cmq_ticket_%0d", command_id)
      );
      if (tentative_ticket == null) begin
        tentative_token_reserved[selected_token] = 1'b0;
        item_statuses[i] = invalid_state("CMQ ticket construction failed");
        continue;
      end
      tentative_ticket.command_id = command_id;
      tentative_ticket.function_h = rdma_clone_function_handle_value(
        active_function, "CMQ ticket"
      );
      tentative_ticket.cmq_h = rdma_clone_handle_value(
        cmq_snapshot.handle, "CMQ ticket"
      );
      tentative_ticket.slot_sequence = slot_sequence;
      tentative_ticket.sq_index = sq_index;
      tentative_ticket.sq_wrap = sq_wrap;
      tentative_ticket.opcode_key = rdma_cmq_clone_opcode_key_value(
        command_snapshot.opcode_key, "CMQ ticket"
      );
      tentative_ticket.absolute_deadline = absolute_deadline;
      status = tentative_ticket.validate();
      if (status == null)
        status = invalid_state("CMQ ticket validation returned null status");
      if (!status.ok()) begin
        tentative_token_reserved[selected_token] = 1'b0;
        item_statuses[i] = rdma_cmq_clone_status_value(status);
        continue;
      end

      tentative_record = rdma_cmq_slot_record::type_id::create(
        $sformatf("cmq_slot_record_%0d", slot_sequence)
      );
      if (tentative_record == null) begin
        tentative_token_reserved[selected_token] = 1'b0;
        item_statuses[i] = invalid_state(
          "CMQ slot record construction failed"
        );
        continue;
      end
      tentative_record.slot_sequence = slot_sequence;
      tentative_record.sq_index = sq_index;
      tentative_record.sq_wrap = sq_wrap;
      tentative_record.state = CMQ_SLOT_PUBLISHED;
      tentative_record.ticket = rdma_cmq_clone_ticket_value(
        tentative_ticket, "CMQ slot record"
      );
      cloned_object = expected_snapshot.clone();
      if (cloned_object == null ||
          !$cast(tentative_record.expected, cloned_object)) begin
        tentative_token_reserved[selected_token] = 1'b0;
        item_statuses[i] = invalid_state(
          "CMQ slot expected response clone failed"
        );
        continue;
      end
      tentative_record.command_token = selected_token[4:0];

      dependency = rdma_doorbell_dependency::type_id::create(
        $sformatf("cmq_dependency_%0d", slot_sequence + 1'b1)
      );
      dependency_mapping = mapping_snapshot();
      if (dependency == null || dependency_mapping == null) begin
        tentative_token_reserved[selected_token] = 1'b0;
        item_statuses[i] = invalid_state(
          "CMQ scheduler dependency construction failed"
        );
        continue;
      end
      dependency.dependency_id = slot_sequence + 1'b1;
      dependency.stage = RDMA_DB_DEP_QUEUE_CONTEXT;
      dependency.mapping = dependency_mapping;
      dependency.relative_offset = relative_offset;
      dependency.image = sqe_snapshot;
      dependency.ready = 1'b1;

      original_indices[success_count] = i;
      tentative_tokens[success_count] = selected_token[4:0];
      tentative_deadlines[success_count] = absolute_deadline;
      tentative_tickets[success_count] = tentative_ticket;
      tentative_records[success_count] = tentative_record;
      dependencies.push_back(dependency);
      success_count++;
    end

    if (success_count == 0) begin
      batch_status = rdma_status::success();
      engine_lock.put(1);
      return;
    end

    if (publish_seq >
        (64'hffff_ffff_ffff_ffff - success_count)) begin
      status = rdma_status::make(
        RDMA_SC_RESOURCE_EXHAUSTED, "CMQ final producer sequence overflows"
      );
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
    end

    if (status.ok()) begin
      if (doorbell_image == null)
        status = invalid_state("CMQ profile returned a null doorbell image");
      else if (doorbell_image.length == 0 ||
               doorbell_image.bytes.size() != doorbell_image.length)
        status = invalid_argument("CMQ doorbell image length is invalid");
      else if (doorbell_image.alignment == 0 ||
               (doorbell_image.alignment &
                (doorbell_image.alignment - 1'b1)) != 0)
        status = invalid_argument("CMQ doorbell image alignment is invalid");
      else if (!(doorbell_image.endian inside {RDMA_ENDIAN_LITTLE,
                                               RDMA_ENDIAN_BIG}) ||
               doorbell_image.hardware_version == 0)
        status = invalid_argument("CMQ doorbell metadata is incomplete");
      else if (doorbell_image.image_kind != RDMA_IMAGE_DOORBELL)
        status = invalid_argument("CMQ profile image is not a doorbell");
      else if (doorbell_image.function_generation !=
               prepared_binding.generation)
        status = rdma_status::make(
          RDMA_SC_STALE_GENERATION,
          "CMQ doorbell Function generation is stale"
        );
      else if (doorbell_image.write_target_kind != RDMA_HW_TARGET_BAR)
        status = invalid_argument("CMQ doorbell target is not a BAR");
      else if ((doorbell_image.bar_target.value &
                (doorbell_image.alignment - 1'b1)) != 0)
        status = invalid_argument("CMQ doorbell BAR target is misaligned");
      else if (doorbell_image.bar_target.value >
               prepared_binding.notify_size ||
               doorbell_image.length >
               (prepared_binding.notify_size -
                doorbell_image.bar_target.value))
        status = invalid_argument(
          "CMQ doorbell target is outside the notify aperture"
        );
    end

    doorbell_snapshot = null;
    if (status.ok()) begin
      uvm_object cloned_object;
      cloned_object = doorbell_image.clone();
      if (cloned_object == null ||
          !$cast(doorbell_snapshot, cloned_object))
        status = invalid_state("CMQ doorbell image snapshot clone failed");
    end

    doorbell_desc = null;
    if (status.ok()) begin
      doorbell_desc = rdma_doorbell_desc::type_id::create(
        "cmq_batch_doorbell"
      );
      if (doorbell_desc == null)
        status = invalid_state("CMQ doorbell descriptor construction failed");
    end
    if (status.ok()) begin
      minimum_remaining = 0;
      for (int unsigned success_index = 0;
           success_index < success_count; success_index++) begin
        if ($time >= tentative_deadlines[success_index]) begin
          status = rdma_status::make(
            RDMA_SC_TIMEOUT, "CMQ batch deadline expired before publication"
          );
          break;
        end
        remaining = tentative_deadlines[success_index] - $time;
        if (minimum_remaining == 0 || remaining < minimum_remaining)
          minimum_remaining = remaining;
      end
    end
    if (status.ok()) begin
      doorbell_desc.kind = RDMA_DOORBELL_CMQ_SQ;
      doorbell_desc.function_h = rdma_clone_function_handle_value(
        active_function, "CMQ doorbell descriptor"
      );
      doorbell_desc.target_h = rdma_clone_handle_value(
        cmq_snapshot.handle, "CMQ doorbell descriptor"
      );
      doorbell_desc.notify_bar_id = prepared_binding.notify_bar_id;
      doorbell_desc.relative_offset = doorbell_snapshot.bar_target.value;
      doorbell_desc.width = doorbell_snapshot.length;
      doorbell_desc.endian = doorbell_snapshot.endian;
      doorbell_desc.payload_image = doorbell_snapshot;
      doorbell_desc.barrier_policy = RDMA_DB_BARRIER_DMA_MMIO;
      doorbell_desc.write_combining_policy =
        RDMA_DB_WRITE_NON_COMBINING;
      doorbell_desc.allow_merge = 1'b0;
      doorbell_desc.merge_requested = 1'b0;
      doorbell_desc.dependencies = dependencies;
      doorbell_desc.timeout = minimum_remaining;
      doorbell_desc.readback_policy = RDMA_DB_READBACK_NONE;
      doorbell_result = null;
      scheduler.submit(prepared_binding, doorbell_desc, doorbell_result,
                       status);
      if (status == null)
        status = invalid_state("CMQ doorbell scheduler returned null status");
      else if (status.ok() && doorbell_result == null)
        status = invalid_state("CMQ doorbell scheduler returned no result");
    end

    if (!status.ok()) begin
      for (int unsigned success_index = 0;
           success_index < success_count; success_index++) begin
        tentative_token_reserved[tentative_tokens[success_index]] = 1'b0;
        item_statuses[original_indices[success_index]] =
          rdma_cmq_clone_status_value(status);
      end
      batch_status = rdma_cmq_clone_status_value(status);
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
      tickets[original_index] = rdma_cmq_clone_ticket_value(
        tentative_tickets[success_index], "CMQ batch output"
      );
      item_statuses[original_index] = rdma_status::success();
      tentative_token_reserved[token_index] = 1'b0;
    end
    publish_seq += success_count;
    batch_status = rdma_status::success();
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
