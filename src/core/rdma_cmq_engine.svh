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
  protected rdma_cmq_slot_record command_registry[string];
  protected rdma_cmq_slot_record entry_registry[string];
  protected rdma_cmq_completion terminal_fifo[$];
  protected rdma_cmq_diagnostic diagnostic_fifo[$];
  protected rdma_cmq_diagnostic last_poison;
  // The fixed CMQ profile API has no separate raw-CQE metadata hook.  A
  // profile therefore owns one endian/hardware-version format across its
  // SQE and CQE images.  Only a scheduler-successful batch may establish
  // this authority; staging and transport failures must leave it unchanged.
  protected bit profile_image_format_valid;
  protected rdma_byte_endian_e profile_image_endian;
  protected int unsigned profile_hardware_version;

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
    profile_image_format_valid = 1'b0;
    profile_image_endian = RDMA_ENDIAN_LITTLE;
    profile_hardware_version = 0;
    last_poison = null;
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

  protected function rdma_status poison_status(string message);
    engine_state = RDMA_CMQ_ENGINE_POISONED;
    return invalid_state(message);
  endfunction

  protected function rdma_status ring_used(output longint unsigned used);
    used = 0;
    if (publish_seq < retire_seq)
      return poison_status("CMQ publish counter precedes retire counter");
    used = publish_seq - retire_seq;
    if (used > CMQ_DEPTH)
      return poison_status("CMQ ring occupancy exceeds depth");
    return rdma_status::success();
  endfunction

  protected function rdma_status decoded_status_contract(
    rdma_cmq_decoded_cqe decoded
  );
    rdma_status command_status;

    if (decoded == null || decoded.command_status == null)
      return invalid_state("CMQ decoded completion status is missing");
    command_status = decoded.command_status;
    if (command_status.category !=
        rdma_status::category_for(command_status.code))
      return invalid_state(
        "CMQ decoded completion status category is inconsistent"
      );
    if (decoded.hardware_ecode == 0) begin
      if (!command_status.ok() || command_status.hardware_code_valid ||
          command_status.hardware_code != 0 ||
          command_status.severity != RDMA_SEVERITY_INFO)
        return invalid_state(
          "CMQ successful hardware ecode status is inconsistent"
        );
    end
    else begin
      if (command_status.ok() || !command_status.hardware_code_valid ||
          command_status.hardware_code != decoded.hardware_ecode ||
          !(command_status.severity inside {
            RDMA_SEVERITY_WARNING,
            RDMA_SEVERITY_ERROR,
            RDMA_SEVERITY_FATAL
          }))
        return invalid_state(
          "CMQ failed hardware ecode status is inconsistent"
        );
    end
    return rdma_status::success();
  endfunction

  protected function rdma_status poll_ledger_status(
    output longint unsigned used
  );
    rdma_status status;
    int unsigned slot_count;
    int unsigned token_count;

    used = 0;
    status = ring_used(used);
    if (!status.ok())
      return status;
    if (cq_consume_seq < retire_seq || cq_consume_seq > publish_seq)
      return poison_status("CMQ completion counters are inconsistent");
    slot_count = 0;
    token_count = 0;
    foreach (slots[i]) begin
      if (slots[i] != null)
        slot_count++;
      if (token_in_use[i])
        token_count++;
    end
    if (slot_count != used || entry_registry.num() != used ||
        token_count != command_registry.num() ||
        command_registry.num() > used)
      return poison_status("CMQ polling ledger is inconsistent");
    return rdma_status::success();
  endfunction

  protected function string command_key(rdma_cmq_ticket ticket);
    return $sformatf(
      "%016h:%08h:%08h:%016h",
      ticket.function_h.function_uid,
      ticket.function_h.object_id,
      ticket.function_h.generation,
      ticket.command_id
    );
  endfunction

  protected function string entry_key(int unsigned index, bit wrap);
    return $sformatf(
      "%016h:%08h:%0d:%0b",
      prepared_binding.function_uid,
      prepared_binding.generation,
      index,
      wrap
    );
  endfunction

  protected function rdma_status make_raw_cqe_image(
    byte data[],
    output rdma_hw_image raw_cqe
  );
    raw_cqe = null;
    if (data.size() != CMQE_BYTES)
      return invalid_state("CMQ host read did not return one full CQE");
    if (prepared_binding == null)
      return invalid_state("CMQ CQE Function authority is missing");
    if (!profile_image_format_valid ||
        !(profile_image_endian inside {
          RDMA_ENDIAN_LITTLE, RDMA_ENDIAN_BIG
        }) || profile_hardware_version == 0)
      return invalid_state(
        "CMQ profile-wide CQE format authority is missing"
      );
    raw_cqe = rdma_hw_image::type_id::create("cmq_raw_cqe");
    if (raw_cqe == null)
      return invalid_state("CMQ raw CQE construction failed");
    foreach (data[i])
      raw_cqe.bytes.push_back(data[i]);
    raw_cqe.length = CMQE_BYTES;
    raw_cqe.alignment = CMQE_BYTES;
    raw_cqe.endian = profile_image_endian;
    raw_cqe.image_kind = RDMA_IMAGE_CMQ_CQE;
    raw_cqe.hardware_version = profile_hardware_version;
    raw_cqe.function_generation = prepared_binding.generation;
    raw_cqe.write_target_kind = RDMA_HW_TARGET_NONE;
    raw_cqe.backing_target = '0;
    raw_cqe.hmc_target = '0;
    raw_cqe.bar_target = '0;
    return rdma_status::success();
  endfunction

  protected function rdma_status make_polled_completion(
    rdma_cmq_slot_record record,
    rdma_hw_image raw_cqe,
    rdma_cmq_decoded_cqe decoded,
    output rdma_cmq_completion completion
  );
    rdma_status validation_status;
    rdma_status snapshot_status;
    rdma_cmq_ticket ticket_snapshot;
    uvm_object payload_snapshot;

    completion = null;
    if (record == null || record.ticket == null ||
        record.ticket.function_h == null || record.ticket.cmq_h == null)
      return invalid_state("CMQ completion ticket authority is missing");
    if (raw_cqe == null || decoded == null ||
        decoded.command_status == null)
      return invalid_state("CMQ completion decode authority is missing");
    completion = rdma_cmq_completion::type_id::create(
      "cmq_polled_completion"
    );
    if (completion == null)
      return invalid_state("CMQ completion construction failed");
    snapshot_status = checked_completion_ticket_snapshot(
      record.ticket, ticket_snapshot
    );
    if (snapshot_status == null || !snapshot_status.ok()) begin
      completion = null;
      return (snapshot_status == null) ?
        invalid_state("CMQ completion ticket snapshot returned null") :
        snapshot_status;
    end
    completion.ticket = ticket_snapshot;
    completion.status = rdma_cmq_clone_status_value(
      decoded.command_status
    );
    completion.raw_cqe = raw_cqe;
    snapshot_status = checked_completion_payload_snapshot(
      decoded.response_payload, payload_snapshot
    );
    if (snapshot_status == null || !snapshot_status.ok()) begin
      completion = null;
      return (snapshot_status == null) ?
        invalid_state("CMQ completion payload snapshot returned null") :
        snapshot_status;
    end
    completion.decoded_response = payload_snapshot;
    if (completion.ticket == null || completion.status == null ||
        completion.raw_cqe == null) begin
      completion = null;
      return invalid_state("CMQ completion snapshot construction failed");
    end
    completion.status.source_engine = RDMA_ENGINE_CMQ;
    completion.status.function_uid =
      completion.ticket.function_h.function_uid;
    completion.status.generation =
      completion.ticket.function_h.generation;
    completion.status.resource_id = completion.ticket.cmq_h.object_id;
    completion.status.command_id = completion.ticket.command_id;
    validation_status = completion.validate();
    if (validation_status == null || !validation_status.ok()) begin
      completion = null;
      return invalid_state("CMQ completion snapshot validation failed");
    end
    return rdma_status::success();
  endfunction

  protected function rdma_status make_timeout_status(
    rdma_cmq_ticket ticket,
    string message,
    output rdma_status timeout_status
  );
    timeout_status = null;
    if (ticket == null || ticket.function_h == null || ticket.cmq_h == null)
      return invalid_state("CMQ timeout status ticket authority is missing");
    timeout_status = rdma_status::make(RDMA_SC_TIMEOUT, message);
    if (timeout_status == null)
      return invalid_state("CMQ timeout status construction failed");
    timeout_status.source_engine = RDMA_ENGINE_CMQ;
    timeout_status.function_uid = ticket.function_h.function_uid;
    timeout_status.generation = ticket.function_h.generation;
    timeout_status.resource_id = ticket.cmq_h.object_id;
    timeout_status.command_id = ticket.command_id;
    return rdma_status::success();
  endfunction

  protected function rdma_status make_timeout_completion(
    rdma_cmq_slot_record record,
    output rdma_cmq_completion completion
  );
    rdma_status status;
    rdma_cmq_ticket ticket_snapshot;

    completion = null;
    if (record == null || record.ticket == null)
      return invalid_state("CMQ timeout completion authority is missing");
    completion = rdma_cmq_completion::type_id::create(
      "cmq_timeout_completion"
    );
    if (completion == null)
      return invalid_state("CMQ timeout completion construction failed");
    status = checked_completion_ticket_snapshot(record.ticket,
                                                ticket_snapshot);
    if (status == null || !status.ok()) begin
      completion = null;
      return (status == null) ?
        invalid_state("CMQ timeout ticket snapshot returned null status") :
        status;
    end
    completion.ticket = ticket_snapshot;
    status = make_timeout_status(
      completion.ticket, "CMQ command deadline expired", completion.status
    );
    if (status == null || !status.ok()) begin
      completion = null;
      return (status == null) ?
        invalid_state("CMQ timeout status helper returned null") : status;
    end
    completion.raw_cqe = null;
    completion.decoded_response = null;
    status = completion.validate();
    if (status == null || !status.ok()) begin
      completion = null;
      return invalid_state("CMQ timeout completion validation failed");
    end
    return rdma_status::success();
  endfunction

  protected function rdma_status make_cancel_completion(
    rdma_cmq_slot_record record,
    output rdma_cmq_completion completion
  );
    rdma_status status;
    rdma_cmq_ticket ticket_snapshot;

    completion = null;
    if (record == null || record.ticket == null ||
        record.ticket.function_h == null || record.ticket.cmq_h == null)
      return invalid_state("CMQ cancel completion authority is missing");
    completion = rdma_cmq_completion::type_id::create(
      "cmq_cancel_completion"
    );
    if (completion == null)
      return invalid_state("CMQ cancel completion construction failed");
    status = checked_completion_ticket_snapshot(record.ticket,
                                                ticket_snapshot);
    if (status == null || !status.ok()) begin
      completion = null;
      return (status == null) ?
        invalid_state("CMQ cancel ticket snapshot returned null") : status;
    end
    completion.ticket = ticket_snapshot;
    completion.status = rdma_status::make(
      RDMA_SC_RESET_CANCELLED,
      "CMQ command cancelled by generation reset"
    );
    if (completion.status == null) begin
      completion = null;
      return invalid_state("CMQ cancel status construction failed");
    end
    completion.status.source_engine = RDMA_ENGINE_RESET;
    completion.status.function_uid = ticket_snapshot.function_h.function_uid;
    completion.status.generation = ticket_snapshot.function_h.generation;
    completion.status.resource_id = ticket_snapshot.cmq_h.object_id;
    completion.status.command_id = ticket_snapshot.command_id;
    completion.raw_cqe = null;
    completion.decoded_response = null;
    status = completion.validate();
    if (status == null || !status.ok()) begin
      completion = null;
      return invalid_state("CMQ cancel completion validation failed");
    end
    return rdma_status::success();
  endfunction

  protected function int terminal_index(rdma_cmq_ticket ticket);
    if (ticket == null)
      return -1;
    foreach (terminal_fifo[i]) begin
      if (terminal_fifo[i] != null && terminal_fifo[i].ticket != null &&
          same_ticket_value(terminal_fifo[i].ticket, ticket))
        return i;
    end
    return -1;
  endfunction

  protected function bit ticket_is_outstanding(rdma_cmq_ticket ticket);
    string software_key;

    if (ticket == null)
      return 1'b0;
    software_key = command_key(ticket);
    return command_registry.exists(software_key) &&
           command_registry[software_key] != null &&
           command_registry[software_key].ticket != null &&
           same_ticket_value(command_registry[software_key].ticket, ticket);
  endfunction

  protected function rdma_status make_late_diagnostic(
    rdma_cmq_slot_record record,
    rdma_hw_image raw_cqe,
    output rdma_cmq_diagnostic diagnostic
  );
    rdma_status status;
    rdma_cmq_ticket ticket_snapshot;

    diagnostic = null;
    if (record == null || record.ticket == null || raw_cqe == null)
      return invalid_state("CMQ late diagnostic authority is missing");
    diagnostic = rdma_cmq_diagnostic::type_id::create(
      "cmq_late_completion_diagnostic"
    );
    if (diagnostic == null)
      return invalid_state("CMQ late diagnostic construction failed");
    status = checked_completion_ticket_snapshot(record.ticket,
                                                ticket_snapshot);
    if (status == null || !status.ok()) begin
      diagnostic = null;
      return (status == null) ?
        invalid_state("CMQ late diagnostic ticket snapshot returned null") :
        status;
    end
    diagnostic.kind = RDMA_CMQ_DIAG_LATE_COMPLETION;
    diagnostic.ticket = ticket_snapshot;
    status = make_timeout_status(
      diagnostic.ticket, "CMQ completion arrived after timeout",
      diagnostic.status
    );
    if (status == null || !status.ok()) begin
      diagnostic = null;
      return (status == null) ?
        invalid_state("CMQ late diagnostic status helper returned null") :
        status;
    end
    diagnostic.raw_cqe = raw_cqe;
    status = diagnostic.validate();
    if (status == null || !status.ok()) begin
      diagnostic = null;
      return invalid_state("CMQ late diagnostic validation failed");
    end
    return rdma_status::success();
  endfunction

  protected function rdma_status make_diagnostic(
    rdma_cmq_diagnostic_kind_e kind,
    rdma_cmq_ticket trusted_ticket,
    rdma_status failure,
    rdma_hw_image raw_cqe,
    output rdma_cmq_diagnostic diagnostic
  );
    rdma_status status;
    rdma_cmq_ticket ticket_snapshot;
    rdma_function_handle function_snapshot;
    rdma_handle cmq_snapshot_value;
    rdma_cmq_opcode_key opcode_snapshot;
    rdma_status failure_snapshot;
    rdma_hw_image raw_snapshot;

    diagnostic = null;
    if (failure == null || raw_cqe == null)
      return invalid_state("CMQ poison diagnostic authority is missing");
    ticket_snapshot = null;
    if (trusted_ticket != null) begin
      if (trusted_ticket.function_h == null ||
          trusted_ticket.cmq_h == null ||
          trusted_ticket.opcode_key == null)
        return invalid_state("CMQ trusted poison ticket is incomplete");
      function_snapshot = new("cmq_poison_ticket_function");
      function_snapshot.kind = trusted_ticket.function_h.kind;
      function_snapshot.function_uid =
        trusted_ticket.function_h.function_uid;
      function_snapshot.object_id = trusted_ticket.function_h.object_id;
      function_snapshot.generation = trusted_ticket.function_h.generation;
      cmq_snapshot_value = new("cmq_poison_ticket_cmq");
      cmq_snapshot_value.kind = trusted_ticket.cmq_h.kind;
      cmq_snapshot_value.function_uid = trusted_ticket.cmq_h.function_uid;
      cmq_snapshot_value.object_id = trusted_ticket.cmq_h.object_id;
      cmq_snapshot_value.generation = trusted_ticket.cmq_h.generation;
      opcode_snapshot = new("cmq_poison_ticket_opcode");
      opcode_snapshot.profile_name = trusted_ticket.opcode_key.profile_name;
      opcode_snapshot.opcode = trusted_ticket.opcode_key.opcode;
      opcode_snapshot.variant = trusted_ticket.opcode_key.variant;
      ticket_snapshot = new("cmq_poison_ticket");
      ticket_snapshot.command_id = trusted_ticket.command_id;
      ticket_snapshot.function_h = function_snapshot;
      ticket_snapshot.cmq_h = cmq_snapshot_value;
      ticket_snapshot.slot_sequence = trusted_ticket.slot_sequence;
      ticket_snapshot.sq_index = trusted_ticket.sq_index;
      ticket_snapshot.sq_wrap = trusted_ticket.sq_wrap;
      ticket_snapshot.opcode_key = opcode_snapshot;
      ticket_snapshot.absolute_deadline =
        trusted_ticket.absolute_deadline;
      status = ticket_snapshot.validate();
      if (status == null || !status.ok()) begin
        ticket_snapshot = null;
        return (status == null) ?
          invalid_state("CMQ poison ticket validation returned null") :
          status;
      end
    end
    failure_snapshot = new("cmq_poison_status");
    failure_snapshot.category = failure.category;
    failure_snapshot.code = failure.code;
    failure_snapshot.hardware_code = failure.hardware_code;
    failure_snapshot.hardware_code_valid = failure.hardware_code_valid;
    failure_snapshot.source_engine = failure.source_engine;
    failure_snapshot.function_uid = failure.function_uid;
    failure_snapshot.generation = failure.generation;
    failure_snapshot.resource_id = failure.resource_id;
    failure_snapshot.command_id = failure.command_id;
    failure_snapshot.wr_id = failure.wr_id;
    failure_snapshot.severity = failure.severity;
    failure_snapshot.retryable = failure.retryable;
    failure_snapshot.message = failure.message;
    raw_snapshot = new("cmq_poison_raw_cqe");
    raw_snapshot.bytes = raw_cqe.bytes;
    raw_snapshot.length = raw_cqe.length;
    raw_snapshot.alignment = raw_cqe.alignment;
    raw_snapshot.endian = raw_cqe.endian;
    raw_snapshot.image_kind = raw_cqe.image_kind;
    raw_snapshot.hardware_version = raw_cqe.hardware_version;
    raw_snapshot.function_generation = raw_cqe.function_generation;
    raw_snapshot.write_target_kind = raw_cqe.write_target_kind;
    raw_snapshot.backing_target = raw_cqe.backing_target;
    raw_snapshot.hmc_target = raw_cqe.hmc_target;
    raw_snapshot.bar_target = raw_cqe.bar_target;
    raw_snapshot.field_summary = raw_cqe.field_summary;
    diagnostic = new("cmq_poison_diagnostic");
    diagnostic.kind = kind;
    diagnostic.ticket = ticket_snapshot;
    diagnostic.status = failure_snapshot;
    diagnostic.raw_cqe = raw_snapshot;
    status = diagnostic.validate();
    if (status == null || !status.ok()) begin
      diagnostic = null;
      return invalid_state("CMQ poison diagnostic validation failed");
    end
    return rdma_status::success();
  endfunction

  protected function rdma_status clone_diagnostic(
    rdma_cmq_diagnostic source,
    output rdma_cmq_diagnostic snapshot
  );
    snapshot = null;
    if (source == null)
      return invalid_state("CMQ poison diagnostic source is null");
    return make_diagnostic(
      source.kind, source.ticket, source.status, source.raw_cqe, snapshot
    );
  endfunction

  protected function rdma_status poison(
    rdma_cmq_diagnostic_kind_e kind,
    string message,
    rdma_hw_image raw_cqe,
    rdma_cmq_ticket trusted_ticket = null
  );
    rdma_status status;
    rdma_status failure;
    rdma_cmq_diagnostic diagnostic;
    rdma_cmq_diagnostic poison_snapshot;

    failure = rdma_status::make(RDMA_SC_CODEC_ERROR, message);
    failure.source_engine = RDMA_ENGINE_CMQ;
    if (prepared_binding != null) begin
      failure.function_uid = prepared_binding.function_uid;
      failure.generation = prepared_binding.generation;
    end
    if (cmq_snapshot != null && cmq_snapshot.handle != null)
      failure.resource_id = cmq_snapshot.handle.object_id;
    if (trusted_ticket != null)
      failure.command_id = trusted_ticket.command_id;

    // Stage both owned objects before publishing any poison state.  The FIFO
    // item is caller-owned after poll(), while last_poison remains engine
    // authority, so they must never share a root or nested object.
    status = make_diagnostic(
      kind, trusted_ticket, failure, raw_cqe, diagnostic
    );
    if (status == null || !status.ok() || diagnostic == null) begin
      // If a trusted ticket was itself inconsistent, preserve raw evidence
      // without claiming that association.  The fallback remains a complete,
      // detached diagnostic rather than publishing a partial poison state.
      failure.command_id = 0;
      status = make_diagnostic(
        RDMA_CMQ_DIAG_POISON, null, failure, raw_cqe, diagnostic
      );
      if (status == null || !status.ok() || diagnostic == null) begin
        engine_state = RDMA_CMQ_ENGINE_POISONED;
        return (status == null) ?
          invalid_state("CMQ poison diagnostic staging returned null") :
          status;
      end
    end
    status = clone_diagnostic(diagnostic, poison_snapshot);
    if (status == null || !status.ok() || poison_snapshot == null) begin
      engine_state = RDMA_CMQ_ENGINE_POISONED;
      return (status == null) ?
        invalid_state("CMQ last-poison staging returned null") : status;
    end
    last_poison = poison_snapshot;
    diagnostic_fifo.push_back(diagnostic);
    engine_state = RDMA_CMQ_ENGINE_POISONED;
    return failure;
  endfunction

  protected function rdma_status expire_locked();
    rdma_status status;
    longint unsigned ledger_used;
    rdma_cmq_slot_record staged_records[CMQ_DEPTH];
    rdma_cmq_completion staged_completions[CMQ_DEPTH];
    string staged_command_keys[CMQ_DEPTH];
    int unsigned staged_tokens[CMQ_DEPTH];
    int unsigned staged_count;

    status = poll_ledger_status(ledger_used);
    if (status == null || !status.ok())
      return (status == null) ?
        invalid_state("CMQ expiry ledger audit returned null status") : status;
    staged_count = 0;
    foreach (slots[i]) begin
      rdma_cmq_slot_record record;
      string software_key;
      string hardware_key;
      int unsigned token_index;

      record = slots[i];
      if (record == null || record.state != CMQ_SLOT_PUBLISHED)
        continue;
      if (record.ticket == null || record.ticket.function_h == null ||
          record.ticket.cmq_h == null || record.ticket.opcode_key == null ||
          record.expected == null ||
          $isunknown(record.ticket.absolute_deadline))
        return invalid_state("CMQ expiry slot authority is incomplete");
      if (record.ticket.absolute_deadline > $time)
        continue;
      hardware_key = entry_key(record.sq_index, record.sq_wrap);
      software_key = command_key(record.ticket);
      token_index = record.command_token;
      if (record.sq_index != i || record.ticket.sq_index != i ||
          record.ticket.slot_sequence != record.slot_sequence ||
          record.ticket.sq_wrap != record.sq_wrap ||
          record.ticket.command_id[4:0] != record.command_token ||
          !entry_registry.exists(hardware_key) ||
          entry_registry[hardware_key] != record ||
          !command_registry.exists(software_key) ||
          command_registry[software_key] != record ||
          token_index >= CMQ_DEPTH || !token_in_use[token_index])
        return invalid_state("CMQ expiry slot ledger is inconsistent");
      status = make_timeout_completion(
        record, staged_completions[staged_count]
      );
      if (status == null || !status.ok() ||
          staged_completions[staged_count] == null)
        return (status == null) ?
          invalid_state("CMQ timeout completion helper returned null status") :
          status;
      staged_records[staged_count] = record;
      staged_command_keys[staged_count] = software_key;
      staged_tokens[staged_count] = token_index;
      staged_count++;
    end

    for (int unsigned i = 0; i < staged_count; i++) begin
      terminal_fifo.push_back(staged_completions[i]);
      command_registry.delete(staged_command_keys[i]);
      token_in_use[staged_tokens[i]] = 1'b0;
      staged_records[i].state = CMQ_SLOT_TIMED_OUT_QUARANTINED;
    end
    return rdma_status::success();
  endfunction

  protected function rdma_status cancel_generation_locked(
    int unsigned generation,
    bit recover_poisoned_ledger
  );
    rdma_status status;
    rdma_cmq_completion staged_completions[CMQ_DEPTH];
    bit staged_command_keys[string];
    int unsigned staged_count;

    if (prepared_binding == null)
      return invalid_state("CMQ generation authority is missing");
    if (generation != prepared_binding.generation)
      return rdma_status::make(
        RDMA_SC_STALE_GENERATION,
        "CMQ cancel generation does not match current generation"
      );

    staged_count = 0;
    if (recover_poisoned_ledger) begin
      foreach (slots[i]) begin
        rdma_cmq_slot_record record;
        string software_key;

        record = slots[i];
        if (record == null || record.state != CMQ_SLOT_PUBLISHED ||
            record.ticket == null || record.ticket.function_h == null ||
            record.ticket.cmq_h == null ||
            !prepared_binding.accepts(record.ticket.function_h) ||
            cmq_snapshot == null || cmq_snapshot.handle == null ||
            !same_handle(record.ticket.cmq_h, cmq_snapshot.handle) ||
            record.ticket.function_h.generation != generation ||
            record.sq_index != i || record.ticket.sq_index != i ||
            record.ticket.slot_sequence != record.slot_sequence ||
            record.ticket.sq_wrap != record.sq_wrap ||
            record.ticket.command_id[4:0] != record.command_token)
          continue;
        software_key = command_key(record.ticket);
        if (staged_command_keys.exists(software_key))
          continue;
        status = make_cancel_completion(
          record, staged_completions[staged_count]
        );
        if (status != null && status.ok() &&
            staged_completions[staged_count] != null) begin
          staged_command_keys[software_key] = 1'b1;
          staged_count++;
        end
      end
    end
    else begin
      foreach (slots[i]) begin
        rdma_cmq_slot_record record;

        record = slots[i];
        if (record == null)
          continue;
        if (record.state != CMQ_SLOT_PUBLISHED)
          continue;
        if (record.ticket == null || record.ticket.function_h == null ||
            record.ticket.cmq_h == null ||
            record.ticket.function_h.generation != generation)
          return invalid_state("CMQ cancel slot authority is inconsistent");
        if (record.command_token >= CMQ_DEPTH ||
            !token_in_use[record.command_token])
          return invalid_state("CMQ cancel token authority is inconsistent");
        status = make_cancel_completion(
          record, staged_completions[staged_count]
        );
        if (status == null || !status.ok() ||
            staged_completions[staged_count] == null)
          return (status == null) ?
            invalid_state("CMQ cancel completion helper returned null") :
            status;
        staged_count++;
      end
    end

    for (int unsigned i = 0; i < staged_count; i++)
      terminal_fifo.push_back(staged_completions[i]);
    foreach (slots[i]) begin
      rdma_cmq_slot_record record;
      int unsigned token_index;

      record = slots[i];
      if (record == null)
        continue;
      if (!recover_poisoned_ledger &&
          record.state == CMQ_SLOT_PUBLISHED) begin
        token_index = record.command_token;
        token_in_use[token_index] = 1'b0;
        record.state = CMQ_SLOT_RESET_CANCELLED;
      end
      // Strict cancellation must not write the token bitmap for quarantine:
      // that token may name a newer command.  Poison recovery clears the
      // whole current-generation bitmap after removing every slot.
      slots[i] = null;
    end
    if (recover_poisoned_ledger) begin
      foreach (token_in_use[i])
        token_in_use[i] = 1'b0;
    end
    command_registry.delete();
    entry_registry.delete();
    publish_seq = 0;
    retire_seq = 0;
    cq_consume_seq = 0;
    profile_image_format_valid = 1'b0;
    profile_image_endian = RDMA_ENDIAN_LITTLE;
    profile_hardware_version = 0;
    engine_state = RDMA_CMQ_ENGINE_QUIESCED;
    return rdma_status::success();
  endfunction

  protected function rdma_status prospective_retirement_status(
    rdma_cmq_slot_record prospective_record,
    output longint unsigned prospective_retire_seq
  );
    prospective_retire_seq = retire_seq;
    if (prospective_record == null)
      return invalid_state("CMQ prospective retirement record is null");
    if (prospective_record.slot_sequence < retire_seq ||
        prospective_record.slot_sequence >= publish_seq ||
        prospective_record.sq_index !=
          (prospective_record.slot_sequence % CMQ_DEPTH) ||
        prospective_record.sq_wrap !=
          ((prospective_record.slot_sequence / CMQ_DEPTH) & 1'b1))
      return invalid_state(
        "CMQ prospective retirement record incarnation is inconsistent"
      );
    while (prospective_retire_seq < publish_seq) begin
      int unsigned index;
      rdma_cmq_slot_record record;

      index = prospective_retire_seq % CMQ_DEPTH;
      record = slots[index];
      if (record == null ||
          record.slot_sequence != prospective_retire_seq ||
          record.sq_index != index ||
          record.sq_wrap !=
            ((prospective_retire_seq / CMQ_DEPTH) & 1'b1))
        return invalid_state("CMQ retirement slot ledger is inconsistent");
      if (record != prospective_record &&
          !(record.state inside {
            CMQ_SLOT_COMPLETED,
            CMQ_SLOT_LATE_COMPLETED,
            CMQ_SLOT_RESET_CANCELLED
          }))
        break;
      prospective_retire_seq++;
    end
    return rdma_status::success();
  endfunction

  protected function void commit_retired_prefix(
    longint unsigned prospective_retire_seq
  );
    while (retire_seq < prospective_retire_seq) begin
      int unsigned index;

      index = retire_seq % CMQ_DEPTH;
      entry_registry.delete(entry_key(index, slots[index].sq_wrap));
      slots[index] = null;
      retire_seq++;
    end
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

  protected function automatic string handle_value_key(rdma_handle handle);
    if (handle == null)
      return "<null-handle>";
    return $sformatf("%0d:%016h:%08h:%08h", handle.kind,
                     handle.function_uid, handle.object_id,
                     handle.generation);
  endfunction

  protected function automatic bit has_exact_object_type(
    uvm_object value,
    uvm_object_wrapper expected_type
  );
    uvm_object_wrapper actual_type;

    if (value == null || expected_type == null)
      return 1'b0;
    actual_type = value.get_object_type();
    return actual_type != null && actual_type == expected_type;
  endfunction

  protected function automatic bit has_optional_exact_object_type(
    uvm_object value,
    uvm_object_wrapper expected_type
  );
    return value == null || has_exact_object_type(value, expected_type);
  endfunction

  protected function automatic bit core_body_shell_is_exact(
    rdma_hw_model body
  );
    rdma_cmq_sqe_model sqe;
    rdma_qpc_model qpc;
    rdma_qpc_urc_ext urc_ext;
    rdma_cqc_model cqc;
    rdma_mrt_model mrt;
    rdma_srqc_model srqc;
    rdma_ceqc_model ceqc;
    rdma_aeqc_model aeqc;

    if (body == null)
      return 1'b0;
    if (has_exact_object_type(body, rdma_cmq_sqe_model::get_type())) begin
      if (!$cast(sqe, body)) return 1'b0;
      return has_exact_object_type(
               sqe.function_h, rdma_function_handle::get_type()
             ) &&
             has_optional_exact_object_type(
               sqe.target_h, rdma_handle::get_type()
             );
    end
    if (has_exact_object_type(body, rdma_qpc_model::get_type())) begin
      if (!$cast(qpc, body)) return 1'b0;
      if (!has_exact_object_type(qpc.qp_h, rdma_handle::get_type()) ||
          !has_exact_object_type(qpc.pd_h, rdma_handle::get_type()) ||
          !has_exact_object_type(qpc.send_cq_h, rdma_handle::get_type()) ||
          !has_exact_object_type(qpc.recv_cq_h, rdma_handle::get_type()) ||
          !has_optional_exact_object_type(
            qpc.srq_h, rdma_handle::get_type()
          ) ||
          !has_exact_object_type(
            qpc.address_vector, rdma_address_vector::get_type()
          ) ||
          !has_exact_object_type(
            qpc.behavior, rdma_qpc_behavior::get_type()
          ))
        return 1'b0;
      if (has_exact_object_type(qpc.transport_ext,
                                rdma_qpc_rc_ext::get_type()) ||
          has_exact_object_type(qpc.transport_ext,
                                rdma_qpc_ud_ext::get_type()))
        return 1'b1;
      if (!has_exact_object_type(qpc.transport_ext,
                                 rdma_qpc_urc_ext::get_type()) ||
          !$cast(urc_ext, qpc.transport_ext))
        return 1'b0;
      return has_exact_object_type(
        urc_ext.queues, rdma_urc_queue_config::get_type()
      );
    end
    if (has_exact_object_type(body, rdma_cqc_model::get_type())) begin
      if (!$cast(cqc, body)) return 1'b0;
      return has_exact_object_type(cqc.cq_h, rdma_handle::get_type()) &&
             has_optional_exact_object_type(
               cqc.ceq_h, rdma_handle::get_type()
             ) &&
             has_exact_object_type(
               cqc.page_layout, rdma_page_table_layout::get_type()
             ) &&
             has_exact_object_type(
               cqc.producer, rdma_ring_position::get_type()
             ) &&
             has_exact_object_type(
               cqc.consumer, rdma_ring_position::get_type()
             );
    end
    if (has_exact_object_type(body, rdma_mrt_model::get_type())) begin
      if (!$cast(mrt, body)) return 1'b0;
      return has_exact_object_type(mrt.mr_h, rdma_handle::get_type()) &&
             has_exact_object_type(mrt.pd_h, rdma_handle::get_type()) &&
             has_exact_object_type(
               mrt.page_layout, rdma_mr_page_layout::get_type()
             );
    end
    if (has_exact_object_type(body, rdma_srqc_model::get_type())) begin
      if (!$cast(srqc, body)) return 1'b0;
      return has_exact_object_type(srqc.srq_h, rdma_handle::get_type()) &&
             has_exact_object_type(srqc.pd_h, rdma_handle::get_type()) &&
             has_exact_object_type(
               srqc.producer, rdma_ring_position::get_type()
             );
    end
    if (has_exact_object_type(body, rdma_ceqc_model::get_type())) begin
      if (!$cast(ceqc, body)) return 1'b0;
      return has_exact_object_type(ceqc.ceq_h, rdma_handle::get_type()) &&
             has_exact_object_type(
               ceqc.page_layout, rdma_page_table_layout::get_type()
             ) &&
             has_exact_object_type(
               ceqc.producer, rdma_ring_position::get_type()
             ) &&
             has_exact_object_type(
               ceqc.consumer, rdma_ring_position::get_type()
             );
    end
    if (has_exact_object_type(body, rdma_aeqc_model::get_type())) begin
      if (!$cast(aeqc, body)) return 1'b0;
      return has_exact_object_type(aeqc.aeq_h, rdma_handle::get_type()) &&
             has_exact_object_type(
               aeqc.page_layout, rdma_page_table_layout::get_type()
             ) &&
             has_exact_object_type(
               aeqc.producer, rdma_ring_position::get_type()
             ) &&
             has_exact_object_type(
               aeqc.consumer, rdma_ring_position::get_type()
             );
    end
    return 1'b0;
  endfunction

  protected function automatic string nested_value_key(uvm_object value);
    rdma_handle handle;
    rdma_ring_position ring;
    rdma_page_table_layout page_layout;
    rdma_address_vector address_vector;
    rdma_urc_queue_config queues;
    rdma_mr_page_layout mr_page_layout;
    rdma_qpc_behavior behavior;
    rdma_qpc_rc_ext rc_ext;
    rdma_qpc_ud_ext ud_ext;
    rdma_qpc_urc_ext urc_ext;
    string result;

    if (value == null)
      return "<null-object>";
    if (has_exact_object_type(value, rdma_handle::get_type()) &&
        $cast(handle, value))
      return {"handle:", handle_value_key(handle)};
    if (has_exact_object_type(value, rdma_ring_position::get_type()) &&
        $cast(ring, value))
      return $sformatf("ring:%0d:%0b", ring.index, ring.wrap);
    if (has_exact_object_type(value, rdma_page_table_layout::get_type()) &&
        $cast(page_layout, value))
      return $sformatf("page:%0d:%016h:%016h:%0b:%016h:%0b",
                       page_layout.mode, page_layout.sd_base.value,
                       page_layout.current_base.value,
                       page_layout.current_valid,
                       page_layout.next_base.value,
                       page_layout.next_valid);
    if (has_exact_object_type(value, rdma_address_vector::get_type()) &&
        $cast(address_vector, value)) begin
      result = $sformatf(
        "av:%0d:%0d:%0d:%0d:%012h:%0b:%0b:%0b:%0b:%0b:%0b:%03h:%02h:%05h:%02h:%04h",
        address_vector.source_address_index, address_vector.source_vport,
        address_vector.destination_vport,
        address_vector.destination_port,
        address_vector.destination_mac, address_vector.ipv6,
        address_vector.vlan_enable, address_vector.cfi,
        address_vector.lag_enable, address_vector.tunnel_enable,
        address_vector.forwarding_enable, address_vector.vlan_id,
        address_vector.traffic_class, address_vector.flow_label,
        address_vector.hop_limit, address_vector.udp_source_port
      );
      foreach (address_vector.destination_ip[i])
        result = {result,
                  $sformatf(":%02h", address_vector.destination_ip[i])};
      return result;
    end
    if (has_exact_object_type(value, rdma_urc_queue_config::get_type()) &&
        $cast(queues, value))
      return $sformatf(
        "urcq:%016h:%016h:%016h:%0d:%0d:%0d:%0d:%0d:%0d",
        queues.rsq_backing.value, queues.rdsq_backing.value,
        queues.dsq_backing.value, queues.rsq_depth, queues.rdsq_depth,
        queues.rdsq_fetch_count, queues.dsq_fetch_count,
        queues.rq_sequence_threshold_entries,
        queues.sq_completion_threshold_entries
      );
    if (has_exact_object_type(value, rdma_mr_page_layout::get_type()) &&
        $cast(mr_page_layout, value))
      return $sformatf(
        "mrpage:%0d:%0d:%016h:%016h:%0d:%0d:%0b:%0b:%0b:%0d:%0d",
        mr_page_layout.pbl_mode, mr_page_layout.host_page_size,
        mr_page_layout.pba0.value, mr_page_layout.pba1.value,
        mr_page_layout.first_pbl_index, mr_page_layout.address_mode,
        mr_page_layout.odp, mr_page_layout.invalidate_enable,
        mr_page_layout.payload_vf_enable,
        mr_page_layout.payload_vf_id, mr_page_layout.mr_serial
      );
    if (has_exact_object_type(value, rdma_qpc_behavior::get_type()) &&
        $cast(behavior, value))
      return $sformatf("behavior:%0d:%0b:%0b:%0b:%0b:%0b:%0d",
                       behavior.transport_version,
                       behavior.migration_enable,
                       behavior.tx_endian_swap, behavior.rx_endian_swap,
                       behavior.read_after_write_fence,
                       behavior.atomic_after_atomic_fence,
                       behavior.\priority );
    if (has_exact_object_type(value, rdma_qpc_rc_ext::get_type()) &&
        $cast(rc_ext, value))
      return $sformatf("rc:%06h:%06h:%06h:%0d:%0d",
                       rc_ext.remote_qpn, rc_ext.send_psn,
                       rc_ext.recv_psn, rc_ext.retry_count,
                       rc_ext.rnr_retry_count);
    if (has_exact_object_type(value, rdma_qpc_ud_ext::get_type()) &&
        $cast(ud_ext, value))
      return $sformatf("ud:%08h", ud_ext.qkey);
    if (has_exact_object_type(value, rdma_qpc_urc_ext::get_type()) &&
        $cast(urc_ext, value))
      return $sformatf("urc:%06h:%06h:%06h:%06h:%06h:%s",
                       urc_ext.remote_qpn, urc_ext.rbsn, urc_ext.dbsn,
                       urc_ext.rpsn, urc_ext.dpsn,
                       nested_value_key(urc_ext.queues));
    return "";
  endfunction

  protected function automatic string body_value_key(rdma_hw_model body);
    rdma_cmq_sqe_model sqe;
    rdma_qpc_model qpc;
    rdma_cqc_model cqc;
    rdma_mrt_model mrt;
    rdma_srqc_model srqc;
    rdma_ceqc_model ceqc;
    rdma_aeqc_model aeqc;

    if (body == null)
      return "<null-body>";
    if (has_exact_object_type(body, rdma_cmq_sqe_model::get_type()) &&
        $cast(sqe, body))
      return $sformatf("sqe:%0d:%016h:%08h:%s:%s:%s", sqe.opcode,
                       sqe.command_id, sqe.flags,
                       handle_value_key(sqe.function_h),
                       handle_value_key(sqe.target_h),
                       (sqe.context_model == null) ? "<null-context>" :
                         body_value_key(sqe.context_model));
    if (has_exact_object_type(body, rdma_qpc_model::get_type()) &&
        $cast(qpc, body))
      return $sformatf(
        "qpc:%s:%s:%s:%s:%s:%0d:%0d:%0d:%0d:%0d:%04h:%02h:%0h:%0d:%0d:%0d:%016h:%016h:%016h:%0d:%0d:%s:%0b:%0b:%0b:%s:%s",
        handle_value_key(qpc.qp_h), handle_value_key(qpc.pd_h),
        handle_value_key(qpc.send_cq_h),
        handle_value_key(qpc.recv_cq_h), handle_value_key(qpc.srq_h),
        qpc.transport, qpc.state, qpc.host_id, qpc.vf_id,
        qpc.stat_index, qpc.pkey, qpc.qp_sequence, qpc.access,
        qpc.path_mtu_bytes, qpc.sq_depth, qpc.rq_depth,
        qpc.sq_backing.value, qpc.rq_backing.value,
        qpc.context_backing.value, qpc.sq_mode, qpc.rq_mode,
        nested_value_key(qpc.address_vector), qpc.signature_enable,
        qpc.tx_flow_control, qpc.rx_flow_control,
        nested_value_key(qpc.behavior),
        nested_value_key(qpc.transport_ext)
      );
    if (has_exact_object_type(body, rdma_cqc_model::get_type()) &&
        $cast(cqc, body))
      return $sformatf(
        "cqc:%s:%s:%0d:%0d:%0d:%0d:%s:%s:%s:%0b:%0b:%0h:%0h:%0h:%016h",
        handle_value_key(cqc.cq_h), handle_value_key(cqc.ceq_h),
        cqc.state, cqc.depth, cqc.cqe_size_bytes, cqc.threshold,
        nested_value_key(cqc.page_layout),
        nested_value_key(cqc.producer), nested_value_key(cqc.consumer),
        cqc.urc_enable, cqc.load_ci_done, cqc.last_arm_sequence,
        cqc.arm_sequence, cqc.arm_state, cqc.shadow_backing.value
      );
    if (has_exact_object_type(body, rdma_mrt_model::get_type()) &&
        $cast(mrt, body))
      return $sformatf(
        "mrt:%s:%s:%0d:%016h:%016h:%08h:%08h:%0h:%0h:%s",
        handle_value_key(mrt.mr_h), handle_value_key(mrt.pd_h),
        mrt.state, mrt.iova.value, mrt.length, mrt.lkey, mrt.rkey,
        mrt.access, mrt.object_type, nested_value_key(mrt.page_layout)
      );
    if (has_exact_object_type(body, rdma_srqc_model::get_type()) &&
        $cast(srqc, body))
      return $sformatf(
        "srqc:%s:%s:%0d:%0d:%0d:%0d:%0d:%016h:%016h:%s:%0h",
        handle_value_key(srqc.srq_h), handle_value_key(srqc.pd_h),
        srqc.state, srqc.depth, srqc.load_pi_threshold,
        srqc.limit_threshold, srqc.object_mode,
        srqc.srfq_backing.value, srqc.shadow_backing.value,
        nested_value_key(srqc.producer), srqc.arm_sequence
      );
    if (has_exact_object_type(body, rdma_ceqc_model::get_type()) &&
        $cast(ceqc, body))
      return $sformatf("ceqc:%s:%0d:%0d:%0d:%s:%s:%s",
                       handle_value_key(ceqc.ceq_h), ceqc.state,
                       ceqc.depth, ceqc.vector_id,
                       nested_value_key(ceqc.page_layout),
                       nested_value_key(ceqc.producer),
                       nested_value_key(ceqc.consumer));
    if (has_exact_object_type(body, rdma_aeqc_model::get_type()) &&
        $cast(aeqc, body))
      return $sformatf("aeqc:%s:%0d:%0d:%0d:%s:%s:%s",
                       handle_value_key(aeqc.aeq_h), aeqc.state,
                       aeqc.depth, aeqc.vector_id,
                       nested_value_key(aeqc.page_layout),
                       nested_value_key(aeqc.producer),
                       nested_value_key(aeqc.consumer));
    return "";
  endfunction

  protected function automatic bit same_body_value(
    rdma_hw_model lhs,
    rdma_hw_model rhs
  );
    uvm_object_wrapper lhs_type;
    uvm_object_wrapper rhs_type;
    rdma_cmq_sqe_model lhs_sqe;
    rdma_cmq_sqe_model rhs_sqe;
    string lhs_value;
    string rhs_value;

    if (lhs == null || rhs == null)
      return 1'b0;
    lhs_type = lhs.get_object_type();
    rhs_type = rhs.get_object_type();
    if (lhs_type == null || rhs_type == null || lhs_type != rhs_type)
      return 1'b0;
    if (!core_body_shell_is_exact(lhs) ||
        !core_body_shell_is_exact(rhs)) begin
      if (profile == null)
        return 1'b0;
      return profile.same_command_body_value(lhs, rhs);
    end
    if (lhs_type == rdma_cmq_sqe_model::get_type()) begin
      if (!$cast(lhs_sqe, lhs) || !$cast(rhs_sqe, rhs))
        return 1'b0;
      if (lhs_sqe.opcode != rhs_sqe.opcode ||
          lhs_sqe.command_id != rhs_sqe.command_id ||
          lhs_sqe.flags != rhs_sqe.flags ||
          handle_value_key(lhs_sqe.function_h) !=
            handle_value_key(rhs_sqe.function_h) ||
          handle_value_key(lhs_sqe.target_h) !=
            handle_value_key(rhs_sqe.target_h) ||
          ((lhs_sqe.context_model == null) !=
           (rhs_sqe.context_model == null)))
        return 1'b0;
      return lhs_sqe.context_model == null ||
             same_body_value(lhs_sqe.context_model,
                             rhs_sqe.context_model);
    end
    lhs_value = body_value_key(lhs);
    rhs_value = body_value_key(rhs);
    if (lhs_value != "" || rhs_value != "")
      return lhs_value != "" && lhs_value == rhs_value;
    return 1'b0;
  endfunction

  protected function automatic void append_body_graph_nodes(
    rdma_hw_model body,
    ref uvm_object nodes[$]
  );
    rdma_cmq_sqe_model sqe;
    rdma_qpc_model qpc;
    rdma_qpc_urc_ext urc_ext;
    rdma_cqc_model cqc;
    rdma_mrt_model mrt;
    rdma_srqc_model srqc;
    rdma_ceqc_model ceqc;
    rdma_aeqc_model aeqc;

    if (body == null)
      return;
    nodes.push_back(body);
    if (has_exact_object_type(body, rdma_cmq_sqe_model::get_type()) &&
        $cast(sqe, body)) begin
      if (sqe.function_h != null) nodes.push_back(sqe.function_h);
      if (sqe.target_h != null) nodes.push_back(sqe.target_h);
    end
    else if (has_exact_object_type(body, rdma_qpc_model::get_type()) &&
             $cast(qpc, body)) begin
      if (qpc.qp_h != null) nodes.push_back(qpc.qp_h);
      if (qpc.pd_h != null) nodes.push_back(qpc.pd_h);
      if (qpc.send_cq_h != null) nodes.push_back(qpc.send_cq_h);
      if (qpc.recv_cq_h != null) nodes.push_back(qpc.recv_cq_h);
      if (qpc.srq_h != null) nodes.push_back(qpc.srq_h);
      if (qpc.address_vector != null) nodes.push_back(qpc.address_vector);
      if (qpc.behavior != null) nodes.push_back(qpc.behavior);
      if (qpc.transport_ext != null) nodes.push_back(qpc.transport_ext);
      if ($cast(urc_ext, qpc.transport_ext) && urc_ext.queues != null)
        nodes.push_back(urc_ext.queues);
    end
    else if (has_exact_object_type(body, rdma_cqc_model::get_type()) &&
             $cast(cqc, body)) begin
      if (cqc.cq_h != null) nodes.push_back(cqc.cq_h);
      if (cqc.ceq_h != null) nodes.push_back(cqc.ceq_h);
      if (cqc.page_layout != null) nodes.push_back(cqc.page_layout);
      if (cqc.producer != null) nodes.push_back(cqc.producer);
      if (cqc.consumer != null) nodes.push_back(cqc.consumer);
    end
    else if (has_exact_object_type(body, rdma_mrt_model::get_type()) &&
             $cast(mrt, body)) begin
      if (mrt.mr_h != null) nodes.push_back(mrt.mr_h);
      if (mrt.pd_h != null) nodes.push_back(mrt.pd_h);
      if (mrt.page_layout != null) nodes.push_back(mrt.page_layout);
    end
    else if (has_exact_object_type(body, rdma_srqc_model::get_type()) &&
             $cast(srqc, body)) begin
      if (srqc.srq_h != null) nodes.push_back(srqc.srq_h);
      if (srqc.pd_h != null) nodes.push_back(srqc.pd_h);
      if (srqc.producer != null) nodes.push_back(srqc.producer);
    end
    else if (has_exact_object_type(body, rdma_ceqc_model::get_type()) &&
             $cast(ceqc, body)) begin
      if (ceqc.ceq_h != null) nodes.push_back(ceqc.ceq_h);
      if (ceqc.page_layout != null) nodes.push_back(ceqc.page_layout);
      if (ceqc.producer != null) nodes.push_back(ceqc.producer);
      if (ceqc.consumer != null) nodes.push_back(ceqc.consumer);
    end
    else if (has_exact_object_type(body, rdma_aeqc_model::get_type()) &&
             $cast(aeqc, body)) begin
      if (aeqc.aeq_h != null) nodes.push_back(aeqc.aeq_h);
      if (aeqc.page_layout != null) nodes.push_back(aeqc.page_layout);
      if (aeqc.producer != null) nodes.push_back(aeqc.producer);
      if (aeqc.consumer != null) nodes.push_back(aeqc.consumer);
    end
  endfunction

  protected function automatic bit body_graph_detached(
    rdma_hw_model source,
    rdma_hw_model snapshot
  );
    uvm_object_wrapper source_type;
    uvm_object_wrapper snapshot_type;
    rdma_cmq_sqe_model source_sqe;
    rdma_cmq_sqe_model snapshot_sqe;
    uvm_object source_nodes[$];
    uvm_object snapshot_nodes[$];

    if (source == null || snapshot == null)
      return 1'b0;
    source_type = source.get_object_type();
    snapshot_type = snapshot.get_object_type();
    if (source_type == null || snapshot_type == null ||
        source_type != snapshot_type)
      return 1'b0;
    if (!core_body_shell_is_exact(source) ||
        !core_body_shell_is_exact(snapshot)) begin
      if (profile == null)
        return 1'b0;
      return profile.command_body_graph_detached(source, snapshot);
    end
    if (source_type == rdma_cmq_sqe_model::get_type()) begin
      if (!$cast(source_sqe, source) || !$cast(snapshot_sqe, snapshot))
        return 1'b0;
      append_body_graph_nodes(source, source_nodes);
      append_body_graph_nodes(snapshot, snapshot_nodes);
      foreach (source_nodes[i])
        foreach (snapshot_nodes[j])
          if (source_nodes[i] == snapshot_nodes[j])
            return 1'b0;
      if ((source_sqe.context_model == null) !=
          (snapshot_sqe.context_model == null))
        return 1'b0;
      return source_sqe.context_model == null ||
             body_graph_detached(source_sqe.context_model,
                                 snapshot_sqe.context_model);
    end
    append_body_graph_nodes(source, source_nodes);
    append_body_graph_nodes(snapshot, snapshot_nodes);
    foreach (source_nodes[i])
      foreach (snapshot_nodes[j])
        if (source_nodes[i] == snapshot_nodes[j])
          return 1'b0;
    return 1'b1;
  endfunction

  protected function rdma_status checked_function_snapshot(
    rdma_function_handle source,
    string label,
    rdma_status_code_e failure_code,
    output rdma_function_handle snapshot
  );
    uvm_object cloned_object;
    string source_type_name;
    rdma_resource_kind_e saved_kind;
    longint unsigned saved_function_uid;
    int unsigned saved_object_id;
    int unsigned saved_generation;

    snapshot = null;
    if (source == null)
      return snapshot_failure(failure_code, {label, " Function is null"});
    saved_kind = source.kind;
    source_type_name = source.get_type_name();
    saved_function_uid = source.function_uid;
    saved_object_id = source.object_id;
    saved_generation = source.generation;
    cloned_object = source.clone();
    source.kind = saved_kind;
    source.function_uid = saved_function_uid;
    source.object_id = saved_object_id;
    source.generation = saved_generation;
    if (cloned_object == null || !$cast(snapshot, cloned_object) ||
        snapshot == source || snapshot.get_type_name() != source_type_name) begin
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
    string source_type_name;
    rdma_resource_kind_e saved_kind;
    longint unsigned saved_function_uid;
    int unsigned saved_object_id;
    int unsigned saved_generation;

    snapshot = null;
    if (source == null)
      return snapshot_failure(failure_code, {label, " handle is null"});
    saved_kind = source.kind;
    source_type_name = source.get_type_name();
    saved_function_uid = source.function_uid;
    saved_object_id = source.object_id;
    saved_generation = source.generation;
    cloned_object = source.clone();
    source.kind = saved_kind;
    source.function_uid = saved_function_uid;
    source.object_id = saved_object_id;
    source.generation = saved_generation;
    if (cloned_object == null || !$cast(snapshot, cloned_object) ||
        snapshot == source || snapshot.get_type_name() != source_type_name) begin
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

  protected function rdma_status nested_object_status(
    uvm_object source,
    string label,
    rdma_status_code_e failure_code
  );
    rdma_handle handle;
    rdma_ring_position ring;
    rdma_page_table_layout page_layout;
    rdma_address_vector address_vector;
    rdma_urc_queue_config queues;
    rdma_mr_page_layout mr_page_layout;
    rdma_qpc_behavior behavior;
    rdma_qpc_transport_ext transport_ext;
    rdma_status status;

    if (source == null)
      return snapshot_failure(failure_code, {label, " is null"});
    if ($cast(handle, source))
      return rdma_status::success();
    if ($cast(ring, source))
      status = ring.validate();
    else if ($cast(page_layout, source))
      status = page_layout.validate();
    else if ($cast(address_vector, source))
      status = address_vector.validate();
    else if ($cast(queues, source))
      status = queues.validate();
    else if ($cast(mr_page_layout, source))
      status = mr_page_layout.validate();
    else if ($cast(behavior, source))
      status = behavior.validate();
    else if ($cast(transport_ext, source))
      status = transport_ext.validate();
    else
      return snapshot_failure(
        failure_code, {label, " has an unsupported nested type"}
      );
    if (status == null)
      return snapshot_failure(
        failure_code, {label, " validation returned null"}
      );
    return status;
  endfunction

  protected function rdma_status checked_nested_snapshot(
    uvm_object source,
    string label,
    rdma_status_code_e failure_code,
    output uvm_object snapshot
  );
    uvm_object cloned_object;
    uvm_object saved_source;
    uvm_object_wrapper source_wrapper;
    rdma_status status;
    string source_type_name;
    string saved_value;

    snapshot = null;
    status = nested_object_status(source, label, failure_code);
    if (!status.ok())
      return status;
    source_type_name = source.get_type_name();
    saved_value = nested_value_key(source);
    if (saved_value == "")
      return snapshot_failure(
        failure_code, {label, " has no checked value representation"}
      );
    source_wrapper = source.get_object_type();
    saved_source = (source_wrapper == null) ? null :
      source_wrapper.create_object({label, "_saved"});
    if (saved_source == null)
      return snapshot_failure(
        failure_code, {label, " source value capture failed"}
      );
    saved_source.copy(source);
    cloned_object = source.clone();
    source.copy(saved_source);
    if (cloned_object == null || cloned_object == source ||
        cloned_object.get_type_name() != source_type_name) begin
      return snapshot_failure(
        failure_code, {label, " snapshot clone contract failed"}
      );
    end
    if (nested_value_key(source) != saved_value ||
        nested_value_key(cloned_object) != saved_value) begin
      return snapshot_failure(
        failure_code, {label, " snapshot changed its source value"}
      );
    end
    status = nested_object_status(cloned_object, label, failure_code);
    if (!status.ok())
      return status;
    snapshot = cloned_object;
    return rdma_status::success();
  endfunction

  protected function rdma_status checked_transport_snapshot(
    rdma_qpc_transport_ext source,
    string label,
    rdma_status_code_e failure_code,
    output rdma_qpc_transport_ext snapshot
  );
    uvm_object cloned_object;
    uvm_object queues_object;
    uvm_object saved_object;
    uvm_object_wrapper source_wrapper;
    rdma_status status;
    rdma_qpc_rc_ext source_rc;
    rdma_qpc_ud_ext source_ud;
    rdma_qpc_urc_ext source_urc;
    rdma_qpc_urc_ext snapshot_urc;
    rdma_urc_queue_config queues_snapshot;
    string source_type_name;
    string saved_value;
    string saved_shell_value;
    rdma_urc_queue_config saved_queues;

    snapshot = null;
    if (source == null)
      return snapshot_failure(failure_code,
                              {label, " transport extension is null"});
    if ($cast(source_rc, source) || $cast(source_ud, source)) begin
      status = checked_nested_snapshot(
        source, {label, " transport extension"}, failure_code,
        cloned_object
      );
      if (!status.ok())
        return status;
      if (!$cast(snapshot, cloned_object))
        return snapshot_failure(
          failure_code, {label, " transport snapshot type is invalid"}
        );
      return rdma_status::success();
    end
    if (!$cast(source_urc, source))
      return snapshot_failure(
        failure_code, {label, " transport extension type is unsupported"}
      );
    status = nested_object_status(source_urc, label, failure_code);
    if (!status.ok())
      return status;
    status = checked_nested_snapshot(
      source_urc.queues, {label, " URC queues"}, failure_code,
      queues_object
    );
    if (!status.ok())
      return status;
    if (!$cast(queues_snapshot, queues_object))
      return snapshot_failure(failure_code,
                              {label, " URC queue snapshot is invalid"});
    source_type_name = source.get_type_name();
    saved_value = nested_value_key(source);
    saved_queues = source_urc.queues;
    source_urc.queues = null;
    source_wrapper = source.get_object_type();
    saved_object = (source_wrapper == null) ? null :
      source_wrapper.create_object({label, "_saved_transport"});
    if (saved_object == null) begin
      source_urc.queues = saved_queues;
      return snapshot_failure(
        failure_code, {label, " transport value capture failed"}
      );
    end
    saved_object.copy(source);
    saved_shell_value = nested_value_key(saved_object);
    cloned_object = source.clone();
    source.copy(saved_object);
    source_urc.queues = saved_queues;
    if (cloned_object == null || !$cast(snapshot, cloned_object) ||
        snapshot == source || snapshot.get_type_name() != source_type_name ||
        !$cast(snapshot_urc, snapshot)) begin
      snapshot = null;
      return snapshot_failure(
        failure_code, {label, " transport snapshot clone contract failed"}
      );
    end
    if (nested_value_key(source) != saved_value ||
        nested_value_key(snapshot) != saved_shell_value ||
        snapshot_urc.queues != null) begin
      snapshot = null;
      return snapshot_failure(
        failure_code, {label, " transport snapshot changed its source value"}
      );
    end
    snapshot_urc.queues = queues_snapshot;
    if (snapshot_urc.queues == source_urc.queues) begin
      snapshot = null;
      return snapshot_failure(
        failure_code, {label, " transport snapshot aliases its source"}
      );
    end
    status = snapshot.validate();
    if (status == null) begin
      snapshot = null;
      return snapshot_failure(
        failure_code, {label, " transport validation returned null"}
      );
    end
    if (!status.ok())
      snapshot = null;
    return status;
  endfunction

  protected function automatic bit clear_body_references(
    rdma_hw_model body,
    ref uvm_object references[$]
  );
    rdma_cmq_sqe_model sqe;
    rdma_qpc_model qpc;
    rdma_cqc_model cqc;
    rdma_mrt_model mrt;
    rdma_srqc_model srqc;
    rdma_ceqc_model ceqc;
    rdma_aeqc_model aeqc;

    references.delete();
    if ($cast(sqe, body)) begin
      references.push_back(sqe.function_h);
      references.push_back(sqe.target_h);
      references.push_back(sqe.context_model);
      sqe.function_h = null;
      sqe.target_h = null;
      sqe.context_model = null;
      return 1'b1;
    end
    if ($cast(qpc, body)) begin
      references.push_back(qpc.qp_h);
      references.push_back(qpc.pd_h);
      references.push_back(qpc.send_cq_h);
      references.push_back(qpc.recv_cq_h);
      references.push_back(qpc.srq_h);
      references.push_back(qpc.address_vector);
      references.push_back(qpc.behavior);
      references.push_back(qpc.transport_ext);
      qpc.qp_h = null;
      qpc.pd_h = null;
      qpc.send_cq_h = null;
      qpc.recv_cq_h = null;
      qpc.srq_h = null;
      qpc.address_vector = null;
      qpc.behavior = null;
      qpc.transport_ext = null;
      return 1'b1;
    end
    if ($cast(cqc, body)) begin
      references.push_back(cqc.cq_h);
      references.push_back(cqc.ceq_h);
      references.push_back(cqc.page_layout);
      references.push_back(cqc.producer);
      references.push_back(cqc.consumer);
      cqc.cq_h = null;
      cqc.ceq_h = null;
      cqc.page_layout = null;
      cqc.producer = null;
      cqc.consumer = null;
      return 1'b1;
    end
    if ($cast(mrt, body)) begin
      references.push_back(mrt.mr_h);
      references.push_back(mrt.pd_h);
      references.push_back(mrt.page_layout);
      mrt.mr_h = null;
      mrt.pd_h = null;
      mrt.page_layout = null;
      return 1'b1;
    end
    if ($cast(srqc, body)) begin
      references.push_back(srqc.srq_h);
      references.push_back(srqc.pd_h);
      references.push_back(srqc.producer);
      srqc.srq_h = null;
      srqc.pd_h = null;
      srqc.producer = null;
      return 1'b1;
    end
    if ($cast(ceqc, body)) begin
      references.push_back(ceqc.ceq_h);
      references.push_back(ceqc.page_layout);
      references.push_back(ceqc.producer);
      references.push_back(ceqc.consumer);
      ceqc.ceq_h = null;
      ceqc.page_layout = null;
      ceqc.producer = null;
      ceqc.consumer = null;
      return 1'b1;
    end
    if ($cast(aeqc, body)) begin
      references.push_back(aeqc.aeq_h);
      references.push_back(aeqc.page_layout);
      references.push_back(aeqc.producer);
      references.push_back(aeqc.consumer);
      aeqc.aeq_h = null;
      aeqc.page_layout = null;
      aeqc.producer = null;
      aeqc.consumer = null;
      return 1'b1;
    end
    return 1'b0;
  endfunction

  protected function automatic bit restore_body_references(
    rdma_hw_model body,
    ref uvm_object references[$]
  );
    rdma_cmq_sqe_model sqe;
    rdma_qpc_model qpc;
    rdma_cqc_model cqc;
    rdma_mrt_model mrt;
    rdma_srqc_model srqc;
    rdma_ceqc_model ceqc;
    rdma_aeqc_model aeqc;

    if ($cast(sqe, body) && references.size() == 3) begin
      if (!$cast(sqe.function_h, references[0]) && references[0] != null)
        return 1'b0;
      if (!$cast(sqe.target_h, references[1]) && references[1] != null)
        return 1'b0;
      if (!$cast(sqe.context_model, references[2]) &&
          references[2] != null)
        return 1'b0;
      return 1'b1;
    end
    if ($cast(qpc, body) && references.size() == 8) begin
      if (!$cast(qpc.qp_h, references[0]) && references[0] != null)
        return 1'b0;
      if (!$cast(qpc.pd_h, references[1]) && references[1] != null)
        return 1'b0;
      if (!$cast(qpc.send_cq_h, references[2]) && references[2] != null)
        return 1'b0;
      if (!$cast(qpc.recv_cq_h, references[3]) && references[3] != null)
        return 1'b0;
      if (!$cast(qpc.srq_h, references[4]) && references[4] != null)
        return 1'b0;
      if (!$cast(qpc.address_vector, references[5]) &&
          references[5] != null)
        return 1'b0;
      if (!$cast(qpc.behavior, references[6]) && references[6] != null)
        return 1'b0;
      if (!$cast(qpc.transport_ext, references[7]) &&
          references[7] != null)
        return 1'b0;
      return 1'b1;
    end
    if ($cast(cqc, body) && references.size() == 5) begin
      if (!$cast(cqc.cq_h, references[0]) && references[0] != null)
        return 1'b0;
      if (!$cast(cqc.ceq_h, references[1]) && references[1] != null)
        return 1'b0;
      if (!$cast(cqc.page_layout, references[2]) && references[2] != null)
        return 1'b0;
      if (!$cast(cqc.producer, references[3]) && references[3] != null)
        return 1'b0;
      if (!$cast(cqc.consumer, references[4]) && references[4] != null)
        return 1'b0;
      return 1'b1;
    end
    if ($cast(mrt, body) && references.size() == 3) begin
      if (!$cast(mrt.mr_h, references[0]) && references[0] != null)
        return 1'b0;
      if (!$cast(mrt.pd_h, references[1]) && references[1] != null)
        return 1'b0;
      if (!$cast(mrt.page_layout, references[2]) && references[2] != null)
        return 1'b0;
      return 1'b1;
    end
    if ($cast(srqc, body) && references.size() == 3) begin
      if (!$cast(srqc.srq_h, references[0]) && references[0] != null)
        return 1'b0;
      if (!$cast(srqc.pd_h, references[1]) && references[1] != null)
        return 1'b0;
      if (!$cast(srqc.producer, references[2]) && references[2] != null)
        return 1'b0;
      return 1'b1;
    end
    if ($cast(ceqc, body) && references.size() == 4) begin
      if (!$cast(ceqc.ceq_h, references[0]) && references[0] != null)
        return 1'b0;
      if (!$cast(ceqc.page_layout, references[1]) && references[1] != null)
        return 1'b0;
      if (!$cast(ceqc.producer, references[2]) && references[2] != null)
        return 1'b0;
      if (!$cast(ceqc.consumer, references[3]) && references[3] != null)
        return 1'b0;
      return 1'b1;
    end
    if ($cast(aeqc, body) && references.size() == 4) begin
      if (!$cast(aeqc.aeq_h, references[0]) && references[0] != null)
        return 1'b0;
      if (!$cast(aeqc.page_layout, references[1]) && references[1] != null)
        return 1'b0;
      if (!$cast(aeqc.producer, references[2]) && references[2] != null)
        return 1'b0;
      if (!$cast(aeqc.consumer, references[3]) && references[3] != null)
        return 1'b0;
      return 1'b1;
    end
    return 1'b0;
  endfunction

  protected function automatic bit body_references_are_null(
    rdma_hw_model body
  );
    rdma_cmq_sqe_model sqe;
    rdma_qpc_model qpc;
    rdma_cqc_model cqc;
    rdma_mrt_model mrt;
    rdma_srqc_model srqc;
    rdma_ceqc_model ceqc;
    rdma_aeqc_model aeqc;

    if ($cast(sqe, body))
      return sqe.function_h == null && sqe.target_h == null &&
             sqe.context_model == null;
    if ($cast(qpc, body))
      return qpc.qp_h == null && qpc.pd_h == null &&
             qpc.send_cq_h == null && qpc.recv_cq_h == null &&
             qpc.srq_h == null && qpc.address_vector == null &&
             qpc.behavior == null && qpc.transport_ext == null;
    if ($cast(cqc, body))
      return cqc.cq_h == null && cqc.ceq_h == null &&
             cqc.page_layout == null && cqc.producer == null &&
             cqc.consumer == null;
    if ($cast(mrt, body))
      return mrt.mr_h == null && mrt.pd_h == null &&
             mrt.page_layout == null;
    if ($cast(srqc, body))
      return srqc.srq_h == null && srqc.pd_h == null &&
             srqc.producer == null;
    if ($cast(ceqc, body))
      return ceqc.ceq_h == null && ceqc.page_layout == null &&
             ceqc.producer == null && ceqc.consumer == null;
    if ($cast(aeqc, body))
      return aeqc.aeq_h == null && aeqc.page_layout == null &&
             aeqc.producer == null && aeqc.consumer == null;
    return 1'b0;
  endfunction

  protected function rdma_status checked_outer_body_clone(
    rdma_hw_model source,
    string saved_value,
    string label,
    rdma_status_code_e failure_code,
    output rdma_hw_model snapshot
  );
    uvm_object cloned_object;
    uvm_object saved_object;
    uvm_object_wrapper source_wrapper;
    rdma_status status;
    rdma_hw_model saved_body;
    string source_type_name;
    string saved_shell_value;
    uvm_object saved_references[$];

    snapshot = null;
    source_type_name = source.get_type_name();
    if (!clear_body_references(source, saved_references))
      return snapshot_failure(
        failure_code, {label, " body reference capture failed"}
      );
    source_wrapper = source.get_object_type();
    saved_object = (source_wrapper == null) ? null :
      source_wrapper.create_object({label, "_saved_shell"});
    if (saved_object == null || !$cast(saved_body, saved_object)) begin
      void'(restore_body_references(source, saved_references));
      return snapshot_failure(
        failure_code, {label, " body value capture failed"}
      );
    end
    saved_body.copy(source);
    saved_shell_value = body_value_key(saved_body);
    cloned_object = source.clone();
    source.copy(saved_body);
    if (!restore_body_references(source, saved_references)) begin
      snapshot = null;
      return snapshot_failure(
        failure_code, {label, " body source restoration failed"}
      );
    end
    if (cloned_object == null || !$cast(snapshot, cloned_object) ||
        snapshot == source || snapshot.get_type_name() != source_type_name) begin
      snapshot = null;
      return snapshot_failure(
        failure_code, {label, " body snapshot clone contract failed"}
      );
    end
    if (body_value_key(source) != saved_value ||
        body_value_key(snapshot) != saved_shell_value ||
        !body_references_are_null(snapshot)) begin
      snapshot = null;
      return snapshot_failure(
        failure_code, {label, " body snapshot changed its source value"}
      );
    end
    return rdma_status::success();
  endfunction

  protected function rdma_status checked_qpc_snapshot(
    rdma_qpc_model source,
    string label,
    rdma_status_code_e failure_code,
    output rdma_hw_model snapshot
  );
    uvm_object nested_snapshot;
    rdma_status status;
    rdma_hw_model cloned_body;
    rdma_qpc_model cloned_qpc;
    rdma_handle qp_snapshot;
    rdma_handle pd_snapshot;
    rdma_handle send_cq_snapshot;
    rdma_handle recv_cq_snapshot;
    rdma_handle srq_snapshot;
    rdma_address_vector address_snapshot;
    rdma_qpc_behavior behavior_snapshot;
    rdma_qpc_transport_ext transport_snapshot;
    string saved_value;

    snapshot = null;
    saved_value = body_value_key(source);
    status = checked_handle_snapshot(source.qp_h, {label, " QPC QP"},
                                     failure_code, qp_snapshot);
    if (!status.ok()) return status;
    status = checked_handle_snapshot(source.pd_h, {label, " QPC PD"},
                                     failure_code, pd_snapshot);
    if (!status.ok()) return status;
    status = checked_handle_snapshot(
      source.send_cq_h, {label, " QPC send CQ"}, failure_code,
      send_cq_snapshot
    );
    if (!status.ok()) return status;
    status = checked_handle_snapshot(
      source.recv_cq_h, {label, " QPC receive CQ"}, failure_code,
      recv_cq_snapshot
    );
    if (!status.ok()) return status;
    srq_snapshot = null;
    if (source.srq_h != null) begin
      status = checked_handle_snapshot(source.srq_h, {label, " QPC SRQ"},
                                       failure_code, srq_snapshot);
      if (!status.ok()) return status;
    end
    status = checked_nested_snapshot(
      source.address_vector, {label, " QPC address vector"}, failure_code,
      nested_snapshot
    );
    if (!status.ok() || !$cast(address_snapshot, nested_snapshot))
      return status.ok() ? snapshot_failure(
        failure_code, {label, " QPC address snapshot is invalid"}
      ) : status;
    status = checked_nested_snapshot(
      source.behavior, {label, " QPC behavior"}, failure_code,
      nested_snapshot
    );
    if (!status.ok() || !$cast(behavior_snapshot, nested_snapshot))
      return status.ok() ? snapshot_failure(
        failure_code, {label, " QPC behavior snapshot is invalid"}
      ) : status;
    status = checked_transport_snapshot(
      source.transport_ext, label, failure_code, transport_snapshot
    );
    if (!status.ok()) return status;
    status = checked_outer_body_clone(
      source, saved_value, label, failure_code, cloned_body
    );
    if (!status.ok()) return status;
    if (!$cast(cloned_qpc, cloned_body))
      return snapshot_failure(failure_code,
                              {label, " QPC body snapshot is invalid"});
    cloned_qpc.qp_h = qp_snapshot;
    cloned_qpc.pd_h = pd_snapshot;
    cloned_qpc.send_cq_h = send_cq_snapshot;
    cloned_qpc.recv_cq_h = recv_cq_snapshot;
    cloned_qpc.srq_h = srq_snapshot;
    cloned_qpc.address_vector = address_snapshot;
    cloned_qpc.behavior = behavior_snapshot;
    cloned_qpc.transport_ext = transport_snapshot;
    snapshot = cloned_qpc;
    if (!body_graph_detached(source, snapshot)) begin
      snapshot = null;
      return snapshot_failure(failure_code,
                              {label, " QPC snapshot aliases its source"});
    end
    status = snapshot.validate();
    if (status == null) begin
      snapshot = null;
      return snapshot_failure(failure_code,
                              {label, " QPC validation returned null"});
    end
    if (!status.ok()) snapshot = null;
    return status;
  endfunction

  protected function rdma_status checked_context_snapshot(
    rdma_hw_model source,
    string label,
    rdma_status_code_e failure_code,
    output rdma_hw_model snapshot
  );
    rdma_status status;
    rdma_hw_model cloned_body;
    rdma_handle handle0_snapshot;
    rdma_handle handle1_snapshot;
    uvm_object nested0_snapshot;
    uvm_object nested1_snapshot;
    uvm_object nested2_snapshot;
    rdma_page_table_layout page_snapshot;
    rdma_mr_page_layout mr_page_snapshot;
    rdma_ring_position ring0_snapshot;
    rdma_ring_position ring1_snapshot;
    rdma_cqc_model source_cqc;
    rdma_cqc_model cloned_cqc;
    rdma_mrt_model source_mrt;
    rdma_mrt_model cloned_mrt;
    rdma_srqc_model source_srqc;
    rdma_srqc_model cloned_srqc;
    rdma_ceqc_model source_ceqc;
    rdma_ceqc_model cloned_ceqc;
    rdma_aeqc_model source_aeqc;
    rdma_aeqc_model cloned_aeqc;
    string saved_value;

    snapshot = null;
    handle0_snapshot = null;
    handle1_snapshot = null;
    nested0_snapshot = null;
    nested1_snapshot = null;
    nested2_snapshot = null;
    saved_value = body_value_key(source);
    if ($cast(source_cqc, source)) begin
      status = checked_handle_snapshot(source_cqc.cq_h,
                                       {label, " CQC CQ"}, failure_code,
                                       handle0_snapshot);
      if (!status.ok()) return status;
      if (source_cqc.ceq_h != null) begin
        status = checked_handle_snapshot(source_cqc.ceq_h,
                                         {label, " CQC CEQ"}, failure_code,
                                         handle1_snapshot);
        if (!status.ok()) return status;
      end
      status = checked_nested_snapshot(source_cqc.page_layout,
                                       {label, " CQC page layout"},
                                       failure_code, nested0_snapshot);
      if (!status.ok()) return status;
      status = checked_nested_snapshot(source_cqc.producer,
                                       {label, " CQC producer"},
                                       failure_code, nested1_snapshot);
      if (!status.ok()) return status;
      status = checked_nested_snapshot(source_cqc.consumer,
                                       {label, " CQC consumer"},
                                       failure_code, nested2_snapshot);
      if (!status.ok()) return status;
    end
    else if ($cast(source_mrt, source)) begin
      status = checked_handle_snapshot(source_mrt.mr_h,
                                       {label, " MRT MR"}, failure_code,
                                       handle0_snapshot);
      if (!status.ok()) return status;
      status = checked_handle_snapshot(source_mrt.pd_h,
                                       {label, " MRT PD"}, failure_code,
                                       handle1_snapshot);
      if (!status.ok()) return status;
      status = checked_nested_snapshot(source_mrt.page_layout,
                                       {label, " MRT page layout"},
                                       failure_code, nested0_snapshot);
      if (!status.ok()) return status;
    end
    else if ($cast(source_srqc, source)) begin
      status = checked_handle_snapshot(source_srqc.srq_h,
                                       {label, " SRQC SRQ"}, failure_code,
                                       handle0_snapshot);
      if (!status.ok()) return status;
      status = checked_handle_snapshot(source_srqc.pd_h,
                                       {label, " SRQC PD"}, failure_code,
                                       handle1_snapshot);
      if (!status.ok()) return status;
      status = checked_nested_snapshot(source_srqc.producer,
                                       {label, " SRQC producer"},
                                       failure_code, nested0_snapshot);
      if (!status.ok()) return status;
    end
    else if ($cast(source_ceqc, source)) begin
      status = checked_handle_snapshot(source_ceqc.ceq_h,
                                       {label, " CEQC CEQ"}, failure_code,
                                       handle0_snapshot);
      if (!status.ok()) return status;
      status = checked_nested_snapshot(source_ceqc.page_layout,
                                       {label, " CEQC page layout"},
                                       failure_code, nested0_snapshot);
      if (!status.ok()) return status;
      status = checked_nested_snapshot(source_ceqc.producer,
                                       {label, " CEQC producer"},
                                       failure_code, nested1_snapshot);
      if (!status.ok()) return status;
      status = checked_nested_snapshot(source_ceqc.consumer,
                                       {label, " CEQC consumer"},
                                       failure_code, nested2_snapshot);
      if (!status.ok()) return status;
    end
    else if ($cast(source_aeqc, source)) begin
      status = checked_handle_snapshot(source_aeqc.aeq_h,
                                       {label, " AEQC AEQ"}, failure_code,
                                       handle0_snapshot);
      if (!status.ok()) return status;
      status = checked_nested_snapshot(source_aeqc.page_layout,
                                       {label, " AEQC page layout"},
                                       failure_code, nested0_snapshot);
      if (!status.ok()) return status;
      status = checked_nested_snapshot(source_aeqc.producer,
                                       {label, " AEQC producer"},
                                       failure_code, nested1_snapshot);
      if (!status.ok()) return status;
      status = checked_nested_snapshot(source_aeqc.consumer,
                                       {label, " AEQC consumer"},
                                       failure_code, nested2_snapshot);
      if (!status.ok()) return status;
    end
    else begin
      return snapshot_failure(failure_code,
                              {label, " context type is unsupported"});
    end
    status = checked_outer_body_clone(source, saved_value, label,
                                      failure_code, cloned_body);
    if (!status.ok()) return status;
    if (source_cqc != null) begin
      if (!$cast(cloned_cqc, cloned_body) ||
          !$cast(page_snapshot, nested0_snapshot) ||
          !$cast(ring0_snapshot, nested1_snapshot) ||
          !$cast(ring1_snapshot, nested2_snapshot))
        return snapshot_failure(failure_code,
                                {label, " CQC snapshot type is invalid"});
      cloned_cqc.cq_h = handle0_snapshot;
      cloned_cqc.ceq_h = handle1_snapshot;
      cloned_cqc.page_layout = page_snapshot;
      cloned_cqc.producer = ring0_snapshot;
      cloned_cqc.consumer = ring1_snapshot;
    end
    else if (source_mrt != null) begin
      if (!$cast(cloned_mrt, cloned_body) ||
          !$cast(mr_page_snapshot, nested0_snapshot))
        return snapshot_failure(failure_code,
                                {label, " MRT snapshot type is invalid"});
      cloned_mrt.mr_h = handle0_snapshot;
      cloned_mrt.pd_h = handle1_snapshot;
      cloned_mrt.page_layout = mr_page_snapshot;
    end
    else if (source_srqc != null) begin
      if (!$cast(cloned_srqc, cloned_body) ||
          !$cast(ring0_snapshot, nested0_snapshot))
        return snapshot_failure(failure_code,
                                {label, " SRQC snapshot type is invalid"});
      cloned_srqc.srq_h = handle0_snapshot;
      cloned_srqc.pd_h = handle1_snapshot;
      cloned_srqc.producer = ring0_snapshot;
    end
    else if (source_ceqc != null) begin
      if (!$cast(cloned_ceqc, cloned_body) ||
          !$cast(page_snapshot, nested0_snapshot) ||
          !$cast(ring0_snapshot, nested1_snapshot) ||
          !$cast(ring1_snapshot, nested2_snapshot))
        return snapshot_failure(failure_code,
                                {label, " CEQC snapshot type is invalid"});
      cloned_ceqc.ceq_h = handle0_snapshot;
      cloned_ceqc.page_layout = page_snapshot;
      cloned_ceqc.producer = ring0_snapshot;
      cloned_ceqc.consumer = ring1_snapshot;
    end
    else begin
      if (!$cast(cloned_aeqc, cloned_body) ||
          !$cast(page_snapshot, nested0_snapshot) ||
          !$cast(ring0_snapshot, nested1_snapshot) ||
          !$cast(ring1_snapshot, nested2_snapshot))
        return snapshot_failure(failure_code,
                                {label, " AEQC snapshot type is invalid"});
      cloned_aeqc.aeq_h = handle0_snapshot;
      cloned_aeqc.page_layout = page_snapshot;
      cloned_aeqc.producer = ring0_snapshot;
      cloned_aeqc.consumer = ring1_snapshot;
    end
    snapshot = cloned_body;
    if (!body_graph_detached(source, snapshot)) begin
      snapshot = null;
      return snapshot_failure(failure_code,
                              {label, " context snapshot aliases its source"});
    end
    status = snapshot.validate();
    if (status == null) begin
      snapshot = null;
      return snapshot_failure(failure_code,
                              {label, " context validation returned null"});
    end
    if (!status.ok()) snapshot = null;
    return status;
  endfunction

  protected function rdma_status checked_opcode_snapshot(
    rdma_cmq_opcode_key source,
    string label,
    rdma_status_code_e failure_code,
    output rdma_cmq_opcode_key snapshot
  );
    rdma_status status;
    uvm_object cloned_object;
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
    source.profile_name = saved_profile_name;
    source.opcode = saved_opcode;
    source.variant = saved_variant;
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

  protected function rdma_status checked_profile_body_snapshot(
    rdma_hw_model source,
    string label,
    output rdma_hw_model snapshot,
    output bit staging_invariant_failed
  );
    uvm_object_wrapper source_type;
    uvm_object_wrapper snapshot_type;
    rdma_status status;

    snapshot = null;
    if (profile == null)
      return invalid_argument({label, " body profile is unavailable"});
    source_type = source.get_object_type();
    if (source_type == null)
      return invalid_argument({label, " body dynamic type is unregistered"});
    status = profile.snapshot_command_body(source, snapshot);
    if (status == null) begin
      snapshot = null;
      staging_invariant_failed = 1'b1;
      return snapshot_failure(
        RDMA_SC_INVALID_STATE,
        {label, " body profile snapshot returned null status"}
      );
    end
    if (!status.ok()) begin
      snapshot = null;
      return status;
    end
    snapshot_type = (snapshot == null) ? null : snapshot.get_object_type();
    if (snapshot == null || snapshot == source || snapshot_type == null ||
        snapshot_type != source_type ||
        !profile.same_command_body_value(source, snapshot) ||
        !profile.command_body_graph_detached(source, snapshot)) begin
      snapshot = null;
      staging_invariant_failed = 1'b1;
      return snapshot_failure(
        RDMA_SC_INVALID_STATE,
        {label, " body profile snapshot contract failed"}
      );
    end
    status = snapshot.validate();
    if (status == null || !status.ok()) begin
      snapshot = null;
      staging_invariant_failed = 1'b1;
      return snapshot_failure(
        RDMA_SC_INVALID_STATE,
        {label, " body profile snapshot validation failed"}
      );
    end
    return rdma_status::success();
  endfunction

  protected function rdma_status checked_body_snapshot(
    rdma_hw_model source,
    string label,
    rdma_status_code_e failure_code,
    output rdma_hw_model snapshot,
    output bit staging_invariant_failed
  );
    rdma_status status;
    rdma_hw_model cloned_body;
    rdma_cmq_sqe_model source_sqe;
    rdma_cmq_sqe_model cloned_sqe;
    rdma_qpc_model source_qpc;
    rdma_cqc_model source_cqc;
    rdma_mrt_model source_mrt;
    rdma_srqc_model source_srqc;
    rdma_ceqc_model source_ceqc;
    rdma_aeqc_model source_aeqc;
    rdma_function_handle function_snapshot;
    rdma_handle target_snapshot;
    rdma_hw_model context_snapshot;
    rdma_cmq_opcode_e saved_opcode;
    longint unsigned saved_command_id;
    int unsigned saved_flags;
    string saved_body_value;

    snapshot = null;
    staging_invariant_failed = 1'b0;
    if (source == null)
      return snapshot_failure(failure_code, {label, " body is null"});
    status = source.validate();
    if (status == null)
      return snapshot_failure(
        failure_code, {label, " body validation returned null"}
      );
    if (!status.ok())
      return status;
    if (!core_body_shell_is_exact(source))
      return checked_profile_body_snapshot(
        source, label, snapshot, staging_invariant_failed
      );
    if (!has_exact_object_type(source,
                               rdma_cmq_sqe_model::get_type())) begin
      if (has_exact_object_type(source, rdma_qpc_model::get_type()) &&
          $cast(source_qpc, source))
        return checked_qpc_snapshot(
          source_qpc, label, failure_code, snapshot
        );
      if ((has_exact_object_type(source, rdma_cqc_model::get_type()) &&
           $cast(source_cqc, source)) ||
          (has_exact_object_type(source, rdma_mrt_model::get_type()) &&
           $cast(source_mrt, source)) ||
          (has_exact_object_type(source, rdma_srqc_model::get_type()) &&
           $cast(source_srqc, source)) ||
          (has_exact_object_type(source, rdma_ceqc_model::get_type()) &&
           $cast(source_ceqc, source)) ||
          (has_exact_object_type(source, rdma_aeqc_model::get_type()) &&
           $cast(source_aeqc, source)))
        return checked_context_snapshot(
          source, label, failure_code, snapshot
        );
      return invalid_argument({label, " body exact type is unsupported"});
    end
    if (!$cast(source_sqe, source))
      return invalid_argument({label, " SQE body dynamic type is invalid"});
    begin
      saved_body_value = body_value_key(source);
      saved_opcode = source_sqe.opcode;
      saved_command_id = source_sqe.command_id;
      saved_flags = source_sqe.flags;
      status = checked_function_snapshot(
        source_sqe.function_h, {label, " body"}, failure_code,
        function_snapshot
      );
      if (!status.ok())
        return status;
      target_snapshot = null;
      if (source_sqe.target_h != null) begin
        status = checked_handle_snapshot(
          source_sqe.target_h, {label, " body target"}, failure_code,
          target_snapshot
        );
        if (!status.ok())
          return status;
      end
      context_snapshot = null;
      if (source_sqe.context_model != null) begin
        status = checked_body_snapshot(
          source_sqe.context_model, {label, " body context"}, failure_code,
          context_snapshot, staging_invariant_failed
        );
        if (!status.ok())
          return status;
      end
    end
    status = checked_outer_body_clone(
      source, saved_body_value, label, failure_code, cloned_body
    );
    if (!status.ok())
      return status;
    if (!$cast(cloned_sqe, cloned_body))
      return snapshot_failure(
        failure_code, {label, " body snapshot type is invalid"}
      );
    if (source_sqe.opcode != saved_opcode ||
        source_sqe.command_id != saved_command_id ||
        source_sqe.flags != saved_flags) begin
      return snapshot_failure(
        failure_code, {label, " body snapshot changed its source value"}
      );
    end
    cloned_sqe.function_h = function_snapshot;
    cloned_sqe.target_h = target_snapshot;
    cloned_sqe.context_model = context_snapshot;
    snapshot = cloned_sqe;
    if (!body_graph_detached(source, snapshot)) begin
      snapshot = null;
      return snapshot_failure(
        failure_code, {label, " body snapshot aliases its source"}
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
    source.bytes = saved_value.bytes;
    source.length = saved_value.length;
    source.alignment = saved_value.alignment;
    source.endian = saved_value.endian;
    source.image_kind = saved_value.image_kind;
    source.hardware_version = saved_value.hardware_version;
    source.function_generation = saved_value.function_generation;
    source.write_target_kind = saved_value.write_target_kind;
    source.backing_target = saved_value.backing_target;
    source.hmc_target = saved_value.hmc_target;
    source.bar_target = saved_value.bar_target;
    source.field_summary = saved_value.field_summary;
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

  protected function rdma_status checked_completion_payload_snapshot(
    uvm_object source,
    output uvm_object snapshot
  );
    uvm_object_wrapper source_type;
    uvm_object_wrapper snapshot_type;
    rdma_status status;

    snapshot = null;
    if (profile == null)
      return invalid_state("CMQ completion payload profile is unavailable");
    if (source == null)
      return invalid_state("CMQ completion payload is null");
    source_type = source.get_object_type();
    if (source_type == null)
      return invalid_state(
        "CMQ completion payload dynamic type is unregistered"
      );
    status = profile.snapshot_completion_payload(source, snapshot);
    if (status == null) begin
      snapshot = null;
      return invalid_state(
        "CMQ completion payload snapshot returned null status"
      );
    end
    if (!status.ok()) begin
      snapshot = null;
      return status;
    end
    snapshot_type = (snapshot == null) ? null : snapshot.get_object_type();
    if (snapshot == null || snapshot == source || snapshot_type == null ||
        snapshot_type != source_type ||
        !profile.same_completion_payload_value(source, snapshot) ||
        !profile.completion_payload_graph_detached(source, snapshot)) begin
      snapshot = null;
      return invalid_state("CMQ completion payload snapshot contract failed");
    end
    if (!profile.same_completion_payload_value(source, snapshot) ||
        !profile.completion_payload_graph_detached(source, snapshot)) begin
      snapshot = null;
      return invalid_state(
        "CMQ completion payload final snapshot contract failed"
      );
    end
    return rdma_status::success();
  endfunction

  protected function rdma_status checked_completion_ticket_snapshot(
    rdma_cmq_ticket source,
    output rdma_cmq_ticket snapshot
  );
    rdma_status status;
    longint unsigned saved_command_id;
    longint unsigned saved_slot_sequence;
    int unsigned saved_sq_index;
    bit saved_sq_wrap;
    time saved_absolute_deadline;

    snapshot = null;
    if (source == null || source.function_h == null ||
        source.cmq_h == null || source.opcode_key == null)
      return invalid_state("CMQ completion ticket authority is incomplete");
    saved_command_id = source.command_id;
    saved_slot_sequence = source.slot_sequence;
    saved_sq_index = source.sq_index;
    saved_sq_wrap = source.sq_wrap;
    saved_absolute_deadline = source.absolute_deadline;
    snapshot = rdma_cmq_ticket::type_id::create(
      "cmq_polled_completion_ticket"
    );
    if (snapshot == null)
      return invalid_state("CMQ completion ticket construction failed");
    snapshot.command_id = saved_command_id;
    status = checked_function_snapshot(
      source.function_h, "CMQ completion ticket", RDMA_SC_INVALID_STATE,
      snapshot.function_h
    );
    if (!status.ok()) begin
      snapshot = null;
      return status;
    end
    status = checked_handle_snapshot(
      source.cmq_h, "CMQ completion ticket", RDMA_SC_INVALID_STATE,
      snapshot.cmq_h
    );
    if (!status.ok()) begin
      snapshot = null;
      return status;
    end
    snapshot.slot_sequence = saved_slot_sequence;
    snapshot.sq_index = saved_sq_index;
    snapshot.sq_wrap = saved_sq_wrap;
    status = checked_opcode_snapshot(
      source.opcode_key, "CMQ completion ticket", RDMA_SC_INVALID_STATE,
      snapshot.opcode_key
    );
    if (!status.ok()) begin
      snapshot = null;
      return status;
    end
    snapshot.absolute_deadline = saved_absolute_deadline;
    if (source.command_id != saved_command_id ||
        source.slot_sequence != saved_slot_sequence ||
        source.sq_index != saved_sq_index || source.sq_wrap != saved_sq_wrap ||
        source.absolute_deadline != saved_absolute_deadline) begin
      snapshot = null;
      return invalid_state(
        "CMQ completion ticket snapshot changed its source value"
      );
    end
    status = snapshot.validate();
    if (status == null || !status.ok()) begin
      snapshot = null;
      return invalid_state("CMQ completion ticket snapshot validation failed");
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
    output rdma_cmq_command_desc snapshot,
    output bit staging_invariant_failed
  );
    rdma_status status;
    uvm_object cloned_object;
    rdma_cmq_command_desc cloned_command;
    rdma_function_handle function_snapshot;
    rdma_cmq_opcode_key opcode_snapshot;
    rdma_hw_model body_snapshot;
    rdma_hw_image signature_snapshot;
    rdma_function_handle saved_function_source;
    rdma_cmq_opcode_key saved_opcode_source;
    rdma_hw_model saved_body_source;
    rdma_hw_image saved_signature_source;
    string source_type_name;
    bit saved_vfid_override;
    bit [10:0] saved_use_vfid;
    time saved_timeout;
    bit root_source_changed_during_clone;

    snapshot = null;
    staging_invariant_failed = 1'b0;
    if (source == null)
      return invalid_argument("CMQ command is null");
    saved_function_source = source.function_h;
    saved_opcode_source = source.opcode_key;
    saved_body_source = source.body;
    saved_signature_source = source.qpc_signature_source;
    source_type_name = source.get_type_name();
    saved_vfid_override = source.vfid_override;
    saved_use_vfid = source.use_vfid;
    saved_timeout = source.timeout;
    status = checked_function_snapshot(
      source.function_h, "CMQ command", RDMA_SC_INVALID_ARGUMENT,
      function_snapshot
    );
    if (!status.ok())
      return status;
    status = checked_opcode_snapshot(
      source.opcode_key, "CMQ command", RDMA_SC_INVALID_ARGUMENT,
      opcode_snapshot
    );
    if (!status.ok())
      return status;
    status = checked_body_snapshot(
      source.body, "CMQ command", RDMA_SC_INVALID_ARGUMENT, body_snapshot,
      staging_invariant_failed
    );
    if (!status.ok())
      return status;
    signature_snapshot = null;
    if (source.qpc_signature_source != null) begin
      status = checked_image_snapshot(
        source.qpc_signature_source, "CMQ command signature",
        RDMA_SC_INVALID_ARGUMENT, signature_snapshot
      );
      if (!status.ok())
        return status;
    end

    source.function_h = null;
    source.opcode_key = null;
    source.body = null;
    source.qpc_signature_source = null;
    cloned_object = source.clone();
    root_source_changed_during_clone =
      source.function_h != null || source.opcode_key != null ||
      source.body != null || source.qpc_signature_source != null ||
      source.vfid_override != saved_vfid_override ||
      source.use_vfid != saved_use_vfid || source.timeout != saved_timeout;
    source.function_h = saved_function_source;
    source.opcode_key = saved_opcode_source;
    source.body = saved_body_source;
    source.qpc_signature_source = saved_signature_source;
    source.vfid_override = saved_vfid_override;
    source.use_vfid = saved_use_vfid;
    source.timeout = saved_timeout;
    if (cloned_object == null || !$cast(cloned_command, cloned_object) ||
        cloned_command == source ||
        cloned_command.get_type_name() != source_type_name) begin
      return invalid_argument("CMQ command snapshot clone contract failed");
    end
    if (root_source_changed_during_clone ||
        cloned_command.function_h != null ||
        cloned_command.opcode_key != null ||
        cloned_command.body != null ||
        cloned_command.qpc_signature_source != null ||
        cloned_command.vfid_override != saved_vfid_override ||
        cloned_command.use_vfid != saved_use_vfid ||
        cloned_command.timeout != saved_timeout ||
        !same_handle(source.function_h, function_snapshot) ||
        !same_opcode_value(source.opcode_key, opcode_snapshot) ||
        ((source.qpc_signature_source == null) !=
         (signature_snapshot == null)) ||
        (signature_snapshot != null &&
         (!same_image_value(source.qpc_signature_source,
                            signature_snapshot)))) begin
      return invalid_argument("CMQ command snapshot changed its source value");
    end

    if (!same_body_value(source.body, body_snapshot) ||
        !body_graph_detached(source.body, body_snapshot)) begin
      staging_invariant_failed = 1'b1;
      return invalid_state(
        "CMQ command body snapshot violated its final staging contract"
      );
    end

    snapshot = cloned_command;
    snapshot.function_h = function_snapshot;
    snapshot.opcode_key = opcode_snapshot;
    snapshot.body = body_snapshot;
    snapshot.qpc_signature_source = signature_snapshot;
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
    profile_image_format_valid = 1'b0;
    profile_image_endian = RDMA_ENDIAN_LITTLE;
    profile_hardware_version = 0;
    command_registry.delete();
    entry_registry.delete();
    terminal_fifo.delete();
    diagnostic_fifo.delete();
    last_poison = null;
    foreach (slots[i]) begin
      slots[i] = null;
      token_in_use[i] = 1'b0;
    end
  endfunction

  protected function void retain_release_authority(
    rdma_dma_mapping retained_mapping,
    rdma_host_mem_api retained_host_mem
  );
    rdma_cmq_diagnostic retained_last_poison;

    retained_last_poison = last_poison;
    clear_configuration();
    last_poison = retained_last_poison;
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
    profile_image_format_valid = 1'b0;
    profile_image_endian = RDMA_ENDIAN_LITTLE;
    profile_hardware_version = 0;
    command_registry.delete();
    entry_registry.delete();
    terminal_fifo.delete();
    diagnostic_fifo.delete();
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
    rdma_handle doorbell_encode_target;
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
    longint unsigned used;
    bit transaction_failed;
    bit staged_profile_format_valid;
    rdma_byte_endian_e staged_profile_endian;
    int unsigned staged_profile_hardware_version;

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
    staged_profile_format_valid = 1'b0;
    staged_profile_endian = RDMA_ENDIAN_LITTLE;
    staged_profile_hardware_version = 0;
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
    status = ring_used(used);
    if (!status.ok()) begin
      batch_status = rdma_cmq_clone_status_value(status);
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
    staged_profile_format_valid = profile_image_format_valid;
    staged_profile_endian = profile_image_endian;
    staged_profile_hardware_version = profile_hardware_version;

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
      bit snapshot_invariant_failed;

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
      snapshot_invariant_failed = 1'b0;

      status = snapshot_command_value(requests[i], command_snapshot,
                                      snapshot_invariant_failed);
      if (!status.ok()) begin
        if (snapshot_invariant_failed) begin
          transaction_status = status;
          transaction_failed = 1'b1;
          break;
        end
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
      if ((used + success_count) == CMQ_DEPTH) begin
        item_statuses[i] = rdma_status::make(
          RDMA_SC_QUEUE_FULL, "CMQ submission ring is full"
        );
        preserve_item_status[i] = 1'b1;
        continue;
      end

      // Include the current candidate in the producer precheck.  A sequence
      // at UINT64_MAX cannot be published because its dependency ID is the
      // checked sequence + 1, so fail before constructing either value.
      if (publish_seq >=
          (64'hffff_ffff_ffff_ffff - success_count)) begin
        transaction_status = poison_status(
          "CMQ producer sequence addition overflows"
        );
        transaction_failed = 1'b1;
        break;
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

      slot_sequence = publish_seq + success_count;
      if (slot_sequence == 64'hffff_ffff_ffff_ffff) begin
        transaction_status = poison_status(
          "CMQ dependency identifier addition overflows"
        );
        transaction_failed = 1'b1;
        break;
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
      if (status == null) begin
        transaction_status = invalid_state(
          "CMQ SQE composition returned null status"
        );
        transaction_failed = 1'b1;
        break;
      end
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
      if (!staged_profile_format_valid) begin
        staged_profile_format_valid = 1'b1;
        staged_profile_endian = sqe_snapshot.endian;
        staged_profile_hardware_version = sqe_snapshot.hardware_version;
      end
      else if (sqe_snapshot.endian != staged_profile_endian ||
               sqe_snapshot.hardware_version !=
                 staged_profile_hardware_version) begin
        transaction_status = invalid_state(
          "CMQ profile changed its profile-wide SQE/CQE image format"
        );
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
        transaction_status = poison_status(
          "CMQ final producer sequence overflows"
        );
        transaction_failed = 1'b1;
      end
      else begin
        final_sequence = publish_seq + success_count;
        final_pi = final_sequence % CMQ_DEPTH;
        final_polarity = (final_sequence / CMQ_DEPTH) & 1'b1;
        status = checked_handle_snapshot(
          cmq_snapshot.handle, "CMQ doorbell encoder",
          RDMA_SC_INVALID_STATE, doorbell_encode_target
        );
        if (!status.ok()) begin
          transaction_status = status;
          transaction_failed = 1'b1;
        end
        else begin
          doorbell_image = null;
          status = profile.encode_doorbell(
            doorbell_encode_target, final_pi, final_polarity, doorbell_image
          );
          if (!same_handle(doorbell_encode_target, cmq_snapshot.handle)) begin
            transaction_status = invalid_state(
              "CMQ doorbell encoder changed its detached handle input"
            );
            transaction_failed = 1'b1;
          end
          else begin
            if (status == null)
              status = invalid_state(
                "CMQ doorbell encoding returned null status"
              );
            if (!status.ok()) begin
              transaction_status = status;
              transaction_failed = 1'b1;
            end
          end
        end
      end
    end

    if (!transaction_failed) begin
      status = doorbell_metadata_status(doorbell_image);
      if (!status.ok()) begin
        transaction_status = invalid_state(
          {"CMQ doorbell profile output is invalid: ", status.message}
        );
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
        transaction_status = invalid_state(
          {"CMQ doorbell snapshot metadata is invalid: ", status.message}
        );
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
      string published_command_key;
      string published_entry_key;

      original_index = original_indices[success_index];
      token_index = tentative_tokens[success_index];
      slot_index = tentative_records[success_index].sq_index;
      token_in_use[token_index] = 1'b1;
      slots[slot_index] = tentative_records[success_index];
      published_command_key = command_key(slots[slot_index].ticket);
      published_entry_key = entry_key(
        slot_index, slots[slot_index].sq_wrap
      );
      command_registry[published_command_key] = slots[slot_index];
      entry_registry[published_entry_key] = slots[slot_index];
      tickets[original_index] = caller_tickets[success_index];
      item_statuses[original_index] =
        tentative_success_statuses[success_index];
      tentative_token_reserved[token_index] = 1'b0;
    end
    publish_seq = final_sequence;
    profile_image_format_valid = staged_profile_format_valid;
    profile_image_endian = staged_profile_endian;
    profile_hardware_version = staged_profile_hardware_version;
    batch_status = successful_batch_status;
    engine_lock.put(1);
  endtask

  task expire(
    output rdma_cmq_completion completions[$],
    output rdma_status status
  );
    completions.delete();
    status = invalid_state("CMQ expire did not complete");
    engine_lock.get(1);
    if (engine_state != RDMA_CMQ_ENGINE_ACTIVE) begin
      status = invalid_state("CMQ expire requires an ACTIVE engine");
      engine_lock.put(1);
      return;
    end
    status = expire_locked();
    while (terminal_fifo.size() != 0)
      completions.push_back(terminal_fifo.pop_front());
    engine_lock.put(1);
  endtask

  protected task poll_locked(output rdma_status status);
    byte data[];
    rdma_status read_status;
    rdma_status inspect_status;
    rdma_status validation_status;
    rdma_status completion_status;
    rdma_status diagnostic_status;
    rdma_status retirement_status;
    rdma_hw_image raw_cqe;
    rdma_hw_image raw_snapshot;
    rdma_cmq_decoded_cqe decoded;
    rdma_cmq_slot_record record;
    rdma_cmq_completion completion;
    rdma_cmq_diagnostic diagnostic;
    longint unsigned read_offset;
    int unsigned cq_index;
    int unsigned token_index;
    bit expected_owner;
    bit ready;
    string hardware_key;
    string software_key;
    longint unsigned ledger_used;
    longint unsigned prospective_retire_seq;

    status = invalid_state("CMQ poll did not complete");
    if (engine_state != RDMA_CMQ_ENGINE_ACTIVE) begin
      status = invalid_state("CMQ poll requires an ACTIVE engine");
      return;
    end
    if (prepared_binding == null || backing_mapping == null ||
        host_mem == null || profile == null) begin
      status = invalid_state("CMQ ACTIVE polling authority is missing");
      return;
    end
    status = mapping_authority_status(backing_mapping, dma_context);
    if (!status.ok())
      return;
    status = poll_ledger_status(ledger_used);
    if (!status.ok())
      return;
    if (ledger_used == 0) begin
      status = rdma_status::success();
      return;
    end

    status = rdma_status::success();
    while (status.ok()) begin
      cq_index = cq_consume_seq % CMQ_DEPTH;
      read_offset = CQ_OFFSET + (longint'(cq_index) * CMQE_BYTES);
      data = new[0];
      read_status = host_mem.read(
        backing_mapping, read_offset, CMQE_BYTES, data
      );
      if (read_status == null) begin
        status = invalid_state("CMQ CQ backing read returned null status");
        break;
      end
      if (!read_status.ok()) begin
        status = rdma_cmq_clone_status_value(read_status);
        break;
      end
      status = make_raw_cqe_image(data, raw_cqe);
      if (!status.ok())
        break;
      status = checked_image_snapshot(
        raw_cqe, "CMQ CQE inspection", RDMA_SC_INVALID_STATE,
        raw_snapshot
      );
      if (!status.ok())
        break;
      expected_owner = !((cq_consume_seq / CMQ_DEPTH) & 1'b1);
      ready = 1'b0;
      decoded = null;
      inspect_status = profile.inspect_cqe(
        raw_cqe, expected_owner, ready, decoded
      );
      if (!same_image_value(raw_cqe, raw_snapshot)) begin
        status = invalid_state("CMQ profile changed its raw CQE input");
        break;
      end
      if (inspect_status == null) begin
        status = poison(
          RDMA_CMQ_DIAG_MALFORMED_CQE,
          "CMQ profile inspection returned null status", raw_snapshot
        );
        break;
      end
      if (!inspect_status.ok()) begin
        if (inspect_status.code inside {
              RDMA_SC_CODEC_ERROR, RDMA_SC_UNSUPPORTED_OPCODE
            })
          status = poison(
            RDMA_CMQ_DIAG_MALFORMED_CQE,
            inspect_status.message, raw_snapshot
          );
        else
          status = rdma_cmq_clone_status_value(inspect_status);
        break;
      end
      if (!ready) begin
        status = rdma_status::success();
        break;
      end
      if (decoded == null || decoded.wqe_index >= CMQ_DEPTH) begin
        status = poison(
          RDMA_CMQ_DIAG_MALFORMED_CQE,
          "CMQ profile returned an invalid decoded CQE", raw_snapshot
        );
        break;
      end

      hardware_key = entry_key(decoded.wqe_index, decoded.wqe_wrap);
      if (!entry_registry.exists(hardware_key)) begin
        status = poison(
          RDMA_CMQ_DIAG_UNKNOWN_CQE,
          "CMQ decoded CQE has no registered entry", raw_snapshot
        );
        break;
      end
      record = entry_registry[hardware_key];
      if (record == null || slots[decoded.wqe_index] == null ||
          slots[decoded.wqe_index] != record ||
          record.sq_index != decoded.wqe_index ||
          record.sq_wrap != decoded.wqe_wrap ||
          record.ticket == null || record.expected == null ||
          record.ticket.sq_index != record.sq_index ||
          record.ticket.sq_wrap != record.sq_wrap ||
          record.ticket.slot_sequence != record.slot_sequence ||
          record.ticket.command_id[4:0] != record.command_token ||
          !(record.state inside {
            CMQ_SLOT_PUBLISHED,
            CMQ_SLOT_TIMED_OUT_QUARANTINED
          })) begin
        status = poison(
          RDMA_CMQ_DIAG_POISON,
          "CMQ decoded CQE entry ledger is inconsistent", raw_snapshot
        );
        break;
      end
      if (decoded.command_status == null) begin
        status = poison(
          RDMA_CMQ_DIAG_MALFORMED_CQE,
          "CMQ profile returned a null decoded command status",
          raw_snapshot, record.ticket
        );
        break;
      end
      validation_status = decoded.validate();
      if (validation_status == null || !validation_status.ok()) begin
        status = poison(
          RDMA_CMQ_DIAG_MALFORMED_CQE,
          "CMQ decoded CQE validation failed", raw_snapshot,
          record.ticket
        );
        break;
      end
      status = decoded_status_contract(decoded);
      if (!status.ok()) begin
        status = poison(
          RDMA_CMQ_DIAG_MALFORMED_CQE, status.message, raw_snapshot,
          record.ticket
        );
        break;
      end
      if (record.expected.hardware_opcode != decoded.hardware_opcode) begin
        status = poison(
          RDMA_CMQ_DIAG_MALFORMED_CQE,
          "CMQ decoded CQE opcode does not match command", raw_snapshot,
          record.ticket
        );
        break;
      end
      software_key = command_key(record.ticket);
      if (cq_consume_seq == 64'hffff_ffff_ffff_ffff) begin
        status = poison(
          RDMA_CMQ_DIAG_POISON,
          "CMQ completion consumer counter overflows", raw_snapshot,
          record.ticket
        );
        break;
      end

      if (record.state == CMQ_SLOT_PUBLISHED) begin
        if (!command_registry.exists(software_key) ||
            command_registry[software_key] != record) begin
          status = poison(
            RDMA_CMQ_DIAG_POISON,
            "CMQ decoded CQE command registry is inconsistent",
            raw_snapshot, record.ticket
          );
          break;
        end
        token_index = record.command_token;
        if (token_index >= CMQ_DEPTH || !token_in_use[token_index]) begin
          status = poison(
            RDMA_CMQ_DIAG_POISON,
            "CMQ decoded CQE command token is inconsistent", raw_snapshot,
            record.ticket
          );
          break;
        end
      end
      else begin
        if (command_registry.exists(software_key)) begin
          status = poison(
            RDMA_CMQ_DIAG_POISON,
            "CMQ quarantined command remains in the command registry",
            raw_snapshot, record.ticket
          );
          break;
        end
      end
      retirement_status = prospective_retirement_status(
        record, prospective_retire_seq
      );
      if (retirement_status == null || !retirement_status.ok()) begin
        status = poison(
          RDMA_CMQ_DIAG_POISON,
          (retirement_status == null) ?
            "CMQ prospective retirement returned null status" :
            retirement_status.message,
          raw_snapshot
        );
        break;
      end

      if (record.state == CMQ_SLOT_PUBLISHED) begin
        completion_status = make_polled_completion(
          record, raw_snapshot, decoded, completion
        );
        if (completion_status == null || !completion_status.ok() ||
            completion == null) begin
          status = (completion_status == null) ?
            invalid_state("CMQ completion construction returned null status") :
            completion_status;
          break;
        end
        terminal_fifo.push_back(completion);
        command_registry.delete(software_key);
        token_in_use[token_index] = 1'b0;
        record.state = CMQ_SLOT_COMPLETED;
      end
      else begin
        diagnostic_status = make_late_diagnostic(
          record, raw_snapshot, diagnostic
        );
        if (diagnostic_status == null || !diagnostic_status.ok() ||
            diagnostic == null) begin
          status = (diagnostic_status == null) ?
            invalid_state("CMQ late diagnostic returned null status") :
            diagnostic_status;
          break;
        end
        diagnostic_fifo.push_back(diagnostic);
        record.state = CMQ_SLOT_LATE_COMPLETED;
      end
      cq_consume_seq++;
      commit_retired_prefix(prospective_retire_seq);
      if (publish_seq == retire_seq)
        break;
    end

  endtask

  task poll(
    output rdma_cmq_completion completions[$],
    output rdma_cmq_diagnostic diagnostics[$],
    output rdma_status status
  );
    rdma_status expiry_status;

    completions.delete();
    diagnostics.delete();
    status = invalid_state("CMQ poll did not complete");
    engine_lock.get(1);
    if (engine_state != RDMA_CMQ_ENGINE_ACTIVE) begin
      status = invalid_state("CMQ poll requires an ACTIVE engine");
      engine_lock.put(1);
      return;
    end
    expiry_status = expire_locked();
    if (expiry_status == null)
      status = invalid_state("CMQ expiry helper returned null status");
    else if (!expiry_status.ok())
      status = expiry_status;
    else begin
      poll_locked(status);
    end
    while (terminal_fifo.size() != 0)
      completions.push_back(terminal_fifo.pop_front());
    while (diagnostic_fifo.size() != 0)
      diagnostics.push_back(diagnostic_fifo.pop_front());
    engine_lock.put(1);
  endtask

  task wait_for(
    rdma_cmq_ticket ticket,
    output rdma_cmq_completion completion,
    output rdma_status status
  );
    rdma_status validation_status;
    rdma_status expiry_status;
    int fifo_index;
    time remaining;
    time wait_time;

    completion = null;
    status = invalid_state("CMQ wait did not complete");
    engine_lock.get(1);
    if (engine_state != RDMA_CMQ_ENGINE_ACTIVE) begin
      status = invalid_state("CMQ wait requires an ACTIVE engine");
      engine_lock.put(1);
      return;
    end
    if (ticket == null) begin
      status = invalid_argument("CMQ wait ticket is null");
      engine_lock.put(1);
      return;
    end
    validation_status = ticket.validate();
    if (validation_status == null || !validation_status.ok()) begin
      status = invalid_argument("CMQ wait ticket is invalid");
      engine_lock.put(1);
      return;
    end
    fifo_index = terminal_index(ticket);
    if (fifo_index < 0 && !ticket_is_outstanding(ticket)) begin
      status = invalid_argument("CMQ wait ticket is unknown or delivered");
      engine_lock.put(1);
      return;
    end

    forever begin
      fifo_index = terminal_index(ticket);
      if (fifo_index >= 0) begin
        completion = terminal_fifo[fifo_index];
        terminal_fifo.delete(fifo_index);
        status = rdma_status::success();
        engine_lock.put(1);
        return;
      end
      expiry_status = expire_locked();
      if (expiry_status == null)
        status = invalid_state("CMQ expiry helper returned null status");
      else if (!expiry_status.ok())
        status = expiry_status;
      else begin
        poll_locked(status);
      end
      fifo_index = terminal_index(ticket);
      if (fifo_index >= 0) begin
        completion = terminal_fifo[fifo_index];
        terminal_fifo.delete(fifo_index);
        status = rdma_status::success();
        engine_lock.put(1);
        return;
      end
      if (status == null || !status.ok()) begin
        if (status == null)
          status = invalid_state("CMQ wait helper returned null status");
        engine_lock.put(1);
        return;
      end
      if (!ticket_is_outstanding(ticket)) begin
        status = invalid_argument("CMQ wait ticket is unknown or delivered");
        engine_lock.put(1);
        return;
      end
      if ($time >= ticket.absolute_deadline) begin
        status = invalid_state("CMQ wait deadline produced no completion");
        engine_lock.put(1);
        return;
      end
      remaining = ticket.absolute_deadline - $time;
      wait_time = (remaining < 1ns) ? remaining : 1ns;
      engine_lock.put(1);
      #(wait_time);
      engine_lock.get(1);
      if (engine_state != RDMA_CMQ_ENGINE_ACTIVE) begin
        status = invalid_state("CMQ engine changed state during wait");
        engine_lock.put(1);
        return;
      end
    end
  endtask

  task cancel_generation(
    int unsigned generation,
    output rdma_cmq_completion completions[$],
    output rdma_status status
  );
    completions.delete();
    status = invalid_state("CMQ generation cancel did not complete");
    engine_lock.get(1);
    if (!(engine_state inside {
          RDMA_CMQ_ENGINE_PREPARED,
          RDMA_CMQ_ENGINE_ACTIVE,
          RDMA_CMQ_ENGINE_QUIESCED,
          RDMA_CMQ_ENGINE_POISONED
        })) begin
      status = invalid_state("CMQ engine state cannot be cancelled");
      engine_lock.put(1);
      return;
    end
    status = cancel_generation_locked(generation, 1'b0);
    if (status != null && status.ok()) begin
      while (terminal_fifo.size() != 0)
        completions.push_back(terminal_fifo.pop_front());
    end
    if (status == null)
      status = invalid_state("CMQ generation cancel returned null status");
    engine_lock.put(1);
  endtask

  task reset(
    output rdma_cmq_completion completions[$],
    output rdma_status status
  );
    rdma_status release_status;
    bit was_poisoned;

    completions.delete();
    status = invalid_state("CMQ reset did not complete");
    engine_lock.get(1);
    was_poisoned = (engine_state == RDMA_CMQ_ENGINE_POISONED);
    if (engine_state == RDMA_CMQ_ENGINE_UNCONFIGURED) begin
      clear_configuration();
      status = rdma_status::success();
      engine_lock.put(1);
      return;
    end
    if (!(engine_state inside {
          RDMA_CMQ_ENGINE_PREPARED,
          RDMA_CMQ_ENGINE_ACTIVE,
          RDMA_CMQ_ENGINE_QUIESCED,
          RDMA_CMQ_ENGINE_POISONED
        })) begin
      status = invalid_state("CMQ engine state cannot be reset");
      engine_lock.put(1);
      return;
    end
    if (prepared_binding != null) begin
      status = cancel_generation_locked(
        prepared_binding.generation, was_poisoned
      );
      if (status == null || !status.ok()) begin
        if (status == null)
          status = invalid_state("CMQ reset cancellation returned null");
        engine_lock.put(1);
        return;
      end
    end
    if (backing_mapping == null || host_mem == null) begin
      engine_state = RDMA_CMQ_ENGINE_POISONED;
      status = invalid_state("CMQ reset release authority is missing");
      engine_lock.put(1);
      return;
    end
    release_status = host_mem.\release (backing_mapping);
    if (release_status == null) begin
      engine_state = RDMA_CMQ_ENGINE_POISONED;
      status = invalid_state("CMQ reset release returned null status");
      engine_lock.put(1);
      return;
    end
    if (!release_status.ok()) begin
      engine_state = RDMA_CMQ_ENGINE_POISONED;
      status = release_status;
      engine_lock.put(1);
      return;
    end
    while (terminal_fifo.size() != 0)
      completions.push_back(terminal_fifo.pop_front());
    clear_configuration();
    engine_state = RDMA_CMQ_ENGINE_UNCONFIGURED;
    status = rdma_status::success();
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

  function int unsigned outstanding_count();
    return command_registry.num();
  endfunction

  function int unsigned quarantine_count();
    int unsigned count;

    count = 0;
    foreach (slots[i]) begin
      if (slots[i] != null &&
          slots[i].state == CMQ_SLOT_TIMED_OUT_QUARANTINED)
        count++;
    end
    return count;
  endfunction

  function rdma_cmq_diagnostic last_poison_snapshot();
    rdma_status status;
    rdma_cmq_diagnostic snapshot;

    if (last_poison == null)
      return null;
    status = clone_diagnostic(last_poison, snapshot);
    if (status == null || !status.ok() || snapshot == null)
      return null;
    return snapshot;
  endfunction

  task shutdown(output rdma_status status);
    rdma_status cancel_status;
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
                               RDMA_CMQ_ENGINE_QUIESCED,
                               RDMA_CMQ_ENGINE_POISONED})) begin
      status = invalid_state("CMQ engine state cannot be shut down");
      engine_lock.put(1);
      return;
    end
    if (engine_state != RDMA_CMQ_ENGINE_POISONED &&
        prepared_binding != null) begin
      cancel_status = cancel_generation_locked(
        prepared_binding.generation, 1'b0
      );
      if (cancel_status == null || !cancel_status.ok()) begin
        status = (cancel_status == null) ?
          invalid_state("CMQ shutdown cancellation returned null") :
          cancel_status;
        engine_lock.put(1);
        return;
      end
    end
    // shutdown has no completion output; cancellation and any older
    // undelivered results are deliberately discarded after ledger cleanup.
    terminal_fifo.delete();
    diagnostic_fifo.delete();
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
