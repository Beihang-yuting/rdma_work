class rdma_qp_allocate_error_host_mem extends rdma_mock_host_mem;
  `uvm_object_utils(rdma_qp_allocate_error_host_mem)
  bit injected;

  function new(string name = "rdma_qp_allocate_error_host_mem");
    super.new(name);
    injected = 1'b0;
  endfunction

  virtual function rdma_status allocate(
    rdma_dma_request_context request_context,
    int unsigned size,
    int unsigned alignment,
    rdma_dma_direction_e direction,
    output rdma_dma_mapping mapping
  );
    rdma_status status;
    status = super.allocate(request_context, size, alignment, direction, mapping);
    if (status != null && status.ok() && !injected) begin
      injected = 1'b1;
      return rdma_status::make(
        RDMA_SC_RESOURCE_EXHAUSTED,
        "injected allocation error with a non-null mapping"
      );
    end
    return status;
  endfunction
endclass

// The CMQ adapter may return the ticket only through the completion payload.
// This fixture preserves that completion ticket while clearing the task's
// direct ticket output to exercise the executor's fallback authority path.
class rdma_qp_completion_ticket_only_cmq extends rdma_mock_cmq_port;
  `uvm_object_utils(rdma_qp_completion_ticket_only_cmq)

  function new(string name = "rdma_qp_completion_ticket_only_cmq");
    super.new(name);
  endfunction

  virtual task execute(
    rdma_cmq_command_desc command,
    output rdma_cmq_ticket ticket,
    output rdma_cmq_completion completion,
    output rdma_status status
  );
    super.execute(command, ticket, completion, status);
    if (command != null && command.opcode_key != null &&
        command.opcode_key.opcode[7:0] == XTR_V1_OP_QPC_MODIFY &&
        completion != null && completion.ticket != null)
      ticket = null;
  endtask
endclass

// Query buffers use DEVICE_WRITE, while QPC staging uses DEVICE_READ.  Fail
// the first query allocation before creating a mapping so the modify path must
// publish ERROR recovery authority even without a query buffer.
class rdma_qp_query_allocate_fail_host_mem extends rdma_mock_host_mem;
  `uvm_object_utils(rdma_qp_query_allocate_fail_host_mem)
  bit injected;

  function new(string name = "rdma_qp_query_allocate_fail_host_mem");
    super.new(name);
    injected = 1'b0;
  endfunction

  virtual function rdma_status allocate(
    rdma_dma_request_context request_context,
    int unsigned size,
    int unsigned alignment,
    rdma_dma_direction_e direction,
    output rdma_dma_mapping mapping
  );
    if (direction == RDMA_DMA_DEVICE_WRITE && !injected) begin
      injected = 1'b1;
      mapping = null;
      return rdma_status::make(
        RDMA_SC_RESOURCE_EXHAUSTED,
        "injected QP query allocation failure"
      );
    end
    return super.allocate(request_context, size, alignment, direction, mapping);
  endfunction
endclass

// Return a non-null but undersized query mapping and leave its first release
// incomplete.  The modify path must retain this adapter-owned capability in
// durable recovery instead of publishing the timeout as a definitive result.
class rdma_qp_query_malformed_pending_host_mem extends rdma_mock_host_mem;
  `uvm_object_utils(rdma_qp_query_malformed_pending_host_mem)
  bit injected;
  bit pending_release;
  int unsigned release_calls;
  byte scripted_query_bytes[];

  function new(string name = "rdma_qp_query_malformed_pending_host_mem");
    super.new(name);
    injected = 1'b0;
    pending_release = 1'b0;
    release_calls = 0;
    scripted_query_bytes = new[0];
  endfunction

  virtual function rdma_status allocate(
    rdma_dma_request_context request_context,
    int unsigned size,
    int unsigned alignment,
    rdma_dma_direction_e direction,
    output rdma_dma_mapping mapping
  );
    rdma_status status;
    longint unsigned original_iova;
    status = super.allocate(request_context, size, alignment, direction,
                            mapping);
    if (direction == RDMA_DMA_DEVICE_WRITE && !injected &&
        status != null && status.ok() && mapping != null) begin
      injected = 1'b1;
      pending_release = 1'b1;
      original_iova = mapping.iova.value;
      mapping.size = size - 1;
      foreach (regions[i]) begin
        if (regions[i] != null && regions[i].mapping != null &&
            regions[i].mapping.iova.value == original_iova)
          regions[i].mapping.size = size - 1;
      end
      return rdma_status::make(
        RDMA_SC_RESOURCE_EXHAUSTED,
        "injected malformed query allocation"
      );
    end
    if (direction == RDMA_DMA_DEVICE_WRITE && injected && mapping != null &&
        scripted_query_bytes.size() == 512)
      void'(super.write(mapping, 0, scripted_query_bytes));
    return status;
  endfunction

  function void script_query_image(byte bytes[]);
    scripted_query_bytes = new[bytes.size()];
    foreach (bytes[i]) scripted_query_bytes[i] = bytes[i];
  endfunction

  virtual function rdma_status \release (rdma_dma_mapping mapping);
    rdma_status status;
    if (mapping != null && mapping.direction == RDMA_DMA_DEVICE_WRITE)
      release_calls++;
    if (pending_release) begin
      pending_release = 1'b0;
      void'(record_call("release", null, mapping));
      return rdma_status::make(RDMA_SC_TIMEOUT,
                               "injected malformed query release pending");
    end
    status = super.\release (mapping);
    return status;
  endfunction
endclass

class rdma_qp_pending_allocate_host_mem extends rdma_mock_host_mem;
  `uvm_object_utils(rdma_qp_pending_allocate_host_mem)
  bit injected;
  bit pending_release;
  int unsigned release_calls;

  function new(string name = "rdma_qp_pending_allocate_host_mem");
    super.new(name);
    injected = 1'b0;
    pending_release = 1'b0;
    release_calls = 0;
  endfunction

  virtual function rdma_status allocate(
    rdma_dma_request_context request_context,
    int unsigned size,
    int unsigned alignment,
    rdma_dma_direction_e direction,
    output rdma_dma_mapping mapping
  );
    rdma_status status;
    status = super.allocate(request_context, size, alignment, direction, mapping);
    if (status != null && status.ok() && !injected) begin
      injected = 1'b1;
      pending_release = 1'b1;
      return rdma_status::make(RDMA_SC_RESOURCE_EXHAUSTED,
                               "injected allocation failure with pending release");
    end
    return status;
  endfunction

  virtual function rdma_status \release (rdma_dma_mapping mapping);
    rdma_status status;
    release_calls++;
    if (pending_release) begin
      pending_release = 1'b0;
      void'(record_call("release", null, mapping));
      return rdma_status::make(RDMA_SC_TIMEOUT,
                               "injected pending allocation release");
    end
    status = super.\release (mapping);
    return status;
  endfunction
endclass

class rdma_qp_authority_probe_mapping extends rdma_mock_dma_mapping;
  `uvm_object_utils(rdma_qp_authority_probe_mapping)
  bit fail_before_copy;
  bit fail_after_copy;
  bit return_null_snapshot;
  int unsigned check_count;

  function new(string name = "rdma_qp_authority_probe_mapping");
    super.new(name);
    fail_before_copy = 1'b0;
    fail_after_copy = 1'b0;
    return_null_snapshot = 1'b0;
    check_count = 0;
  endfunction

  virtual function rdma_status snapshot_release_authority(
    output rdma_dma_mapping snapshot
  );
    if (return_null_snapshot) begin
      snapshot = null;
      return rdma_status::success();
    end
    return super.snapshot_release_authority(snapshot);
  endfunction

  virtual function rdma_status release_authority_status(
    rdma_dma_mapping snapshot
  );
    check_count++;
    if (snapshot != null &&
        (fail_before_copy && snapshot.iova.value == 0 ||
         fail_after_copy && snapshot.iova.value != 0))
      return rdma_status::make(
        RDMA_SC_INVALID_STATE,
        "injected opaque release-authority mismatch"
      );
    return super.release_authority_status(snapshot);
  endfunction
endclass

// Round-5 fault adapter: report a non-null allocation whose public geometry
// is malformed, then leave the release pending on its first release attempt.
// The backing adapter still owns an opaque completion seal, so a later retry
// can complete exactly once if recovery retained the original capability.
class rdma_qp_malformed_allocate_host_mem extends rdma_mock_host_mem;
  `uvm_object_utils(rdma_qp_malformed_allocate_host_mem)
  string geometry_mode;
  bit injected;
  bit pending_release;
  int unsigned release_calls;

  function new(string name = "rdma_qp_malformed_allocate_host_mem");
    super.new(name);
    geometry_mode = "undersized";
    injected = 1'b0;
    pending_release = 1'b0;
    release_calls = 0;
  endfunction

  virtual function rdma_status allocate(
    rdma_dma_request_context request_context,
    int unsigned size,
    int unsigned alignment,
    rdma_dma_direction_e direction,
    output rdma_dma_mapping mapping
  );
    rdma_status status;
    longint unsigned original_iova;

    status = super.allocate(request_context, size, alignment, direction,
                            mapping);
    if (status != null && status.ok() && !injected) begin
      injected = 1'b1;
      pending_release = 1'b1;
      original_iova = mapping == null ? 0 : mapping.iova.value;
      // Keep the mock region's public fields in sync with the returned value
      // so a later opaque release can still locate the same allocation.
      foreach (regions[i]) begin
        if (regions[i] != null && regions[i].mapping != null &&
            regions[i].mapping.iova.value == original_iova) begin
          if (geometry_mode == "unaligned") begin
            mapping.iova.value += 1;
            mapping.backing_addr.value += 1;
            regions[i].mapping.iova.value += 1;
            regions[i].mapping.backing_addr.value += 1;
          end else begin
            mapping.size = size - 1;
            regions[i].mapping.size = size - 1;
          end
        end
      end
      return rdma_status::make(
        RDMA_SC_RESOURCE_EXHAUSTED,
        "injected malformed non-null allocation"
      );
    end
    return status;
  endfunction

  virtual function rdma_status \release (rdma_dma_mapping mapping);
    rdma_status status;

    release_calls++;
    if (pending_release) begin
      pending_release = 1'b0;
      void'(record_call("release", null, mapping));
      return rdma_status::make(
        RDMA_SC_TIMEOUT, "injected malformed release pending"
      );
    end
    status = super.\release (mapping);
    return status;
  endfunction
endclass

class rdma_qp_urc_malformed_allocate_host_mem extends rdma_mock_host_mem;
  `uvm_object_utils(rdma_qp_urc_malformed_allocate_host_mem)
  int unsigned allocate_count;
  int unsigned release_calls;
  bit pending_release;
  function new(string name = "rdma_qp_urc_malformed_allocate_host_mem");
    super.new(name); allocate_count = 0; release_calls = 0; pending_release = 0;
  endfunction
  virtual function rdma_status allocate(
    rdma_dma_request_context request_context, int unsigned size,
    int unsigned alignment, rdma_dma_direction_e direction,
    output rdma_dma_mapping mapping
  );
    rdma_status status;
    status = super.allocate(request_context, size, alignment, direction, mapping);
    allocate_count++;
    if (status != null && status.ok() && allocate_count == 5 && mapping != null) begin
      pending_release = 1'b1;
      mapping.size = size - 1;
      return rdma_status::make(RDMA_SC_RESOURCE_EXHAUSTED,
                               "injected URC malformed allocation");
    end
    return status;
  endfunction
  virtual function rdma_status \release (rdma_dma_mapping mapping);
    rdma_status status;
    release_calls++;
    if (pending_release) begin pending_release = 0; return rdma_status::make(RDMA_SC_TIMEOUT, "pending URC release"); end
    status = super.\release (mapping); return status;
  endfunction
endclass

// Round-5 fault adapter: the allocation is valid, but the adapter's
// authority hook rejects the initial validation.  Release is also incomplete
// once, exercising durable recovery projection independently of geometry.
class rdma_qp_authority_pending_host_mem extends rdma_mock_host_mem;
  `uvm_object_utils(rdma_qp_authority_pending_host_mem)
  bit injected;
  bit null_snapshot;
  bit pending_release;
  int unsigned release_calls;

  function new(string name = "rdma_qp_authority_pending_host_mem");
    super.new(name);
    injected = 1'b0;
    null_snapshot = 1'b0;
    pending_release = 1'b0;
    release_calls = 0;
  endfunction

  virtual function rdma_status allocate(
    rdma_dma_request_context request_context,
    int unsigned size,
    int unsigned alignment,
    rdma_dma_direction_e direction,
    output rdma_dma_mapping mapping
  );
    rdma_status status;
    rdma_qp_authority_probe_mapping probe;

    status = super.allocate(request_context, size, alignment, direction,
                            mapping);
    if (status != null && status.ok() && !injected) begin
      injected = 1'b1;
      pending_release = 1'b1;
      probe = rdma_qp_authority_probe_mapping::type_id::create(
        "qp_authority_pending_probe"
      );
      probe.copy(mapping);
      probe.fail_before_copy = 1'b1;
      probe.return_null_snapshot = null_snapshot;
      mapping = probe;
      return rdma_status::success();
    end
    return status;
  endfunction

  virtual function rdma_status \release (rdma_dma_mapping mapping);
    rdma_status status;

    release_calls++;
    if (pending_release) begin
      pending_release = 1'b0;
      void'(record_call("release", null, mapping));
      return rdma_status::make(
        RDMA_SC_TIMEOUT, "injected authority release pending"
      );
    end
    status = super.\release (mapping);
    return status;
  endfunction
endclass

class rdma_qp_authority_failure_host_mem extends rdma_mock_host_mem;
  `uvm_object_utils(rdma_qp_authority_failure_host_mem)
  int unsigned fail_check_ordinal;
  bit decorated;

  function new(string name = "rdma_qp_authority_failure_host_mem");
    super.new(name);
    fail_check_ordinal = 1;
    decorated = 1'b0;
  endfunction

  virtual function rdma_status allocate(
    rdma_dma_request_context request_context,
    int unsigned size,
    int unsigned alignment,
    rdma_dma_direction_e direction,
    output rdma_dma_mapping mapping
  );
    rdma_status status;
    rdma_qp_authority_probe_mapping probe;

    status = super.allocate(request_context, size, alignment, direction, mapping);
    if (status != null && status.ok() && !decorated) begin
      probe = rdma_qp_authority_probe_mapping::type_id::create(
        "qp_authority_probe"
      );
      probe.copy(mapping);
      probe.fail_before_copy = fail_check_ordinal == 1;
      probe.fail_after_copy = fail_check_ordinal == 2;
      mapping = probe;
      decorated = 1'b1;
    end
    return status;
  endfunction
endclass

class rdma_qp_rebind_host_mem extends rdma_mock_host_mem;
  `uvm_object_utils(rdma_qp_rebind_host_mem)
  rdma_function_binding binding_target;
  bit rebound;

  function new(string name = "rdma_qp_rebind_host_mem");
    super.new(name);
    binding_target = null;
    rebound = 1'b0;
  endfunction

  virtual function rdma_status write(
    rdma_dma_mapping mapping,
    longint unsigned offset,
    byte data[]
  );
    rdma_status status;
    status = super.write(mapping, offset, data);
    if (status != null && status.ok() && data.size() == 512 &&
        binding_target != null && !rebound) begin
      binding_target.generation++;
      binding_target.owner_h = binding_target.make_handle();
      rebound = 1'b1;
    end
    return status;
  endfunction
endclass

class rdma_qp_fault_host_mem extends rdma_mock_host_mem;
  `uvm_object_utils(rdma_qp_fault_host_mem)
  int unsigned fail_allocate_ordinal;
  int unsigned fail_write_ordinal;
  int unsigned allocate_count;
  int unsigned write_count;

  function new(string name = "rdma_qp_fault_host_mem");
    super.new(name);
    fail_allocate_ordinal = 0;
    fail_write_ordinal = 0;
    allocate_count = 0;
    write_count = 0;
  endfunction

  virtual function rdma_status allocate(
    rdma_dma_request_context request_context,
    int unsigned size,
    int unsigned alignment,
    rdma_dma_direction_e direction,
    output rdma_dma_mapping mapping
  );
    allocate_count++;
    if (allocate_count == fail_allocate_ordinal) begin
      mapping = null;
      return rdma_status::make(RDMA_SC_RESOURCE_EXHAUSTED,
                               "injected QP allocation failure");
    end
    return super.allocate(request_context, size, alignment, direction, mapping);
  endfunction

  virtual function rdma_status write(
    rdma_dma_mapping mapping,
    longint unsigned offset,
    byte data[]
  );
    write_count++;
    if (write_count == fail_write_ordinal)
      return rdma_status::make(RDMA_SC_DMA_TRANSLATION,
                               "injected QP host write failure");
    return super.write(mapping, offset, data);
  endfunction
endclass

class rdma_qp_fault_manager extends rdma_resource_manager;
  `uvm_object_utils(rdma_qp_fault_manager)
  rdma_status attach_failure;
  rdma_status activate_failure;
  rdma_status sequence_failure;
  rdma_function_binding binding_target;
  bit rebind_after_attach;
  bit rebind_on_sequence_failure;
  bit attach_rebound;

  function new(string name = "rdma_qp_fault_manager");
    super.new(name);
    attach_failure = null;
    activate_failure = null;
    sequence_failure = null;
    binding_target = null;
    rebind_after_attach = 1'b0;
    rebind_on_sequence_failure = 1'b0;
    attach_rebound = 1'b0;
  endfunction

  virtual function rdma_status qp_sequence(
    rdma_function_handle owner,
    int unsigned local_qpn,
    output bit [7:0] sequence_value
  );
    rdma_status failure;
    sequence_value = '0;
    if (sequence_failure != null) begin
      failure = rdma_cmq_clone_status_value(sequence_failure);
      sequence_failure = null;
      if (rebind_on_sequence_failure && binding_target != null) begin
        binding_target.generation++;
        binding_target.owner_h = binding_target.make_handle();
      end
      return failure;
    end
    return super.qp_sequence(owner, local_qpn, sequence_value);
  endfunction

  virtual function rdma_status attach_qp_programming(rdma_qp candidate);
    rdma_status failure;
    rdma_status status;
    if (attach_failure != null) begin
      failure = rdma_cmq_clone_status_value(attach_failure);
      attach_failure = null;
      return failure;
    end
    status = super.attach_qp_programming(candidate);
    if (status != null && status.ok() && rebind_after_attach &&
        binding_target != null) begin
      rebind_after_attach = 1'b0;
      binding_target.generation++;
      binding_target.owner_h = binding_target.make_handle();
      attach_rebound = 1'b1;
    end
    return status;
  endfunction

  virtual function rdma_status activate(rdma_handle handle);
    rdma_status failure;
    if (activate_failure != null && handle != null &&
        handle.kind == RDMA_RESOURCE_QP) begin
      failure = rdma_cmq_clone_status_value(activate_failure);
      activate_failure = null;
      return failure;
    end
    return super.activate(handle);
  endfunction

  function bit raw_qp_state(
    rdma_handle handle,
    output rdma_resource_state_e state
  );
    string key;
    state = RDMA_RESOURCE_NEW;
    if (handle == null)
      return 1'b0;
    key = resource_key(handle);
    if (!registry.exists(key) || registry[key] == null)
      return 1'b0;
    state = registry[key].state;
    return 1'b1;
  endfunction

  function bit raw_qp_local_id(
    rdma_handle handle,
    output int unsigned local_id
  );
    string key;
    rdma_qp qp_value;

    local_id = '0;
    if (handle == null)
      return 1'b0;
    key = resource_key(handle);
    if (!registry.exists(key) || registry[key] == null ||
        !$cast(qp_value, registry[key]))
      return 1'b0;
    local_id = qp_value.local_qp_id;
    return 1'b1;
  endfunction

  function bit raw_recovery_exists(rdma_handle handle);
    string key;
    if (handle == null)
      return 1'b0;
    key = resource_key(handle);
    return recovery_records.exists(key);
  endfunction

  function bit raw_recovery(
    rdma_handle handle,
    output rdma_recovery_record recovery
  );
    string key;
    recovery = null;
    if (handle == null)
      return 1'b0;
    key = resource_key(handle);
    if (!recovery_records.exists(key) || recovery_records[key] == null)
      return 1'b0;
    recovery = recovery_records[key];
    return 1'b1;
  endfunction
endclass

class rdma_qp_boundary_host_mem extends rdma_mock_host_mem;
  `uvm_object_utils(rdma_qp_boundary_host_mem)
  rdma_function_binding binding_target;
  string mode;
  int unsigned allocate_count;
  int unsigned write_count;
  int unsigned release_count;
  bit rebound;
  bit unauthorized_effect;
  bit injected;

  function new(string name = "rdma_qp_boundary_host_mem");
    super.new(name);
    binding_target = null;
    mode = "";
    allocate_count = 0;
    write_count = 0;
    release_count = 0;
    rebound = 1'b0;
    unauthorized_effect = 1'b0;
    injected = 1'b0;
  endfunction

  function void rebind();
    if (binding_target != null && !rebound) begin
      binding_target.generation++;
      binding_target.owner_h = binding_target.make_handle();
      rebound = 1'b1;
    end
  endfunction

  virtual function rdma_status allocate(
    rdma_dma_request_context request_context,
    int unsigned size,
    int unsigned alignment,
    rdma_dma_direction_e direction,
    output rdma_dma_mapping mapping
  );
    rdma_status status;
    if (rebound)
      unauthorized_effect = 1'b1;
    allocate_count++;
    status = super.allocate(request_context, size, alignment, direction,
                            mapping);
    if (status != null && status.ok() && !injected &&
        ((mode == "rebind_allocate" && allocate_count == 1) ||
         (mode == "rebind_staging_allocate" && size == 512))) begin
      injected = 1'b1;
      rebind();
    end
    if (status != null && status.ok() && !injected &&
        mode == "timeout_staging_allocate_after" && size == 512) begin
      injected = 1'b1;
      return rdma_status::make(RDMA_SC_TIMEOUT,
                               "injected staging allocation timeout");
    end
    return status;
  endfunction

  virtual function rdma_status write(
    rdma_dma_mapping mapping,
    longint unsigned offset,
    byte data[]
  );
    rdma_status status;
    if (rebound)
      unauthorized_effect = 1'b1;
    write_count++;
    status = super.write(mapping, offset, data);
    if (status != null && status.ok() && !injected &&
        ((mode == "rebind_pd_write" && write_count == 2) ||
         (mode == "rebind_staging_write" && data.size() == 512))) begin
      injected = 1'b1;
      rebind();
    end
    if (status != null && status.ok() && !injected &&
        mode == "timeout_staging_write_after" && data.size() == 512) begin
      injected = 1'b1;
      return rdma_status::make(RDMA_SC_TIMEOUT,
                               "injected staging write timeout");
    end
    if (status != null && status.ok() && !injected &&
        mode == "complete_staging_before_cleanup" && mapping != null &&
        mapping.size == 512 && data.size() == 512) begin
      injected = 1'b1;
      status = super.\release (mapping);
    end
    return status;
  endfunction

  virtual function rdma_status \release (rdma_dma_mapping mapping);
    rdma_status status;
    release_count++;
    if (!injected && mode == "timeout_staging_release_before" &&
        mapping != null && mapping.size == 512) begin
      injected = 1'b1;
      void'(record_call("release", null, mapping));
      return rdma_status::make(RDMA_SC_TIMEOUT,
                               "injected pending staging release");
    end
    if (!injected && mode == "timeout_plan_release_before" &&
        mapping != null && mapping.size != 512) begin
      injected = 1'b1;
      void'(record_call("release", null, mapping));
      return rdma_status::make(RDMA_SC_TIMEOUT,
                               "injected pending plan release");
    end
    if (!injected && mode == "timeout_plan_release_rebind_before" &&
        mapping != null && mapping.size != 512) begin
      injected = 1'b1;
      rebind();
      void'(record_call("release", null, mapping));
      return rdma_status::make(RDMA_SC_TIMEOUT,
                               "injected pending exact-old plan release");
    end
    status = super.\release (mapping);
    if (status != null && status.ok() && !injected && mapping != null &&
        mapping.size == 512 && mode == "rebind_staging_release") begin
      injected = 1'b1;
      rebind();
    end
    if (status != null && status.ok() && !injected && mapping != null &&
        mapping.size == 512 && mode == "timeout_staging_release_after") begin
      injected = 1'b1;
      return rdma_status::make(RDMA_SC_TIMEOUT,
                               "injected completed staging release timeout");
    end
    return status;
  endfunction
endclass

class rdma_qp_command_fault_executor extends rdma_qp_lifecycle_executor;
  `uvm_object_utils(rdma_qp_command_fault_executor)
  bit fail_create_command;

  function new(string name = "rdma_qp_command_fault_executor");
    super.new(name);
    fail_create_command = 1'b0;
  endfunction

  protected virtual function rdma_status build_qpc_command(
    rdma_function_handle owner,
    rdma_qpc_model model,
    rdma_dma_mapping staging,
    rdma_hw_image image,
    bit [7:0] opcode,
    output rdma_cmq_command_desc command
  );
    if (fail_create_command && opcode == XTR_V1_OP_QPC_CREATE) begin
      command = null;
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "injected QPC_CREATE command-build failure");
    end
    return super.build_qpc_command(owner, model, staging, image, opcode,
                                    command);
  endfunction
endclass

class rdma_qp_boundary_context_backing extends rdma_mock_context_backing;
  `uvm_object_utils(rdma_qp_boundary_context_backing)
  rdma_function_binding binding_target;
  string mode;
  int unsigned acquire_count;
  int unsigned write_count;
  int unsigned boundary_release_count;
  bit rebound;
  bit unauthorized_effect;
  bit injected;

  function new(string name = "rdma_qp_boundary_context_backing");
    super.new(name);
    binding_target = null;
    mode = "";
    acquire_count = 0;
    write_count = 0;
    boundary_release_count = 0;
    rebound = 1'b0;
    unauthorized_effect = 1'b0;
    injected = 1'b0;
  endfunction

  function void rebind();
    if (binding_target != null && !rebound) begin
      binding_target.generation++;
      binding_target.owner_h = binding_target.make_handle();
      rebound = 1'b1;
    end
  endfunction

  virtual function rdma_status acquire(
    rdma_function_binding binding,
    rdma_resource_kind_e resource_kind,
    int unsigned local_id,
    output rdma_context_backing_ref context_ref
  );
    rdma_status status;
    if (rebound)
      unauthorized_effect = 1'b1;
    acquire_count++;
    status = super.acquire(binding, resource_kind, local_id, context_ref);
    if (status != null && status.ok() && !injected &&
        mode == "rebind_context_acquire") begin
      injected = 1'b1;
      rebind();
    end
    if (status != null && status.ok() && !injected &&
        mode == "timeout_context_acquire_after") begin
      injected = 1'b1;
      return rdma_status::make(RDMA_SC_TIMEOUT,
                               "injected context acquire timeout");
    end
    return status;
  endfunction

  virtual function rdma_status write(
    rdma_context_backing_ref context_ref,
    longint unsigned offset,
    byte unsigned data[]
  );
    rdma_status status;
    if (rebound)
      unauthorized_effect = 1'b1;
    write_count++;
    status = super.write(context_ref, offset, data);
    if (status != null && status.ok() && !injected &&
        mode == "rebind_context_write") begin
      injected = 1'b1;
      rebind();
    end
    if (status != null && status.ok() && !injected &&
        mode == "timeout_context_write_after") begin
      injected = 1'b1;
      return rdma_status::make(RDMA_SC_TIMEOUT,
                               "injected context write timeout");
    end
    return status;
  endfunction

  virtual function rdma_status \release (
    rdma_context_backing_ref context_ref
  );
    rdma_status status;
    boundary_release_count++;
    if (!injected && mode == "timeout_context_release_before") begin
      injected = 1'b1;
      call_trace.push_back("release");
      return rdma_status::make(RDMA_SC_TIMEOUT,
                               "injected pending context release");
    end
    status = super.\release (context_ref);
    if (status != null && status.ok() && !injected &&
        mode == "rebind_context_release") begin
      injected = 1'b1;
      rebind();
    end
    if (status != null && status.ok() && !injected &&
        mode == "timeout_context_release_after") begin
      injected = 1'b1;
      return rdma_status::make(RDMA_SC_TIMEOUT,
                               "injected completed context release timeout");
    end
    return status;
  endfunction
endclass

class rdma_qp_activation_rebind_manager extends rdma_qp_fault_manager;
  `uvm_object_utils(rdma_qp_activation_rebind_manager)
  rdma_function_binding binding_target;
  bit rebind_after_activate;

  function new(string name = "rdma_qp_activation_rebind_manager");
    super.new(name);
    binding_target = null;
    rebind_after_activate = 1'b0;
  endfunction

  virtual function rdma_status activate(rdma_handle handle);
    rdma_status status;
    status = super.activate(handle);
    if (status != null && status.ok() && rebind_after_activate &&
        binding_target != null) begin
      rebind_after_activate = 1'b0;
      binding_target.generation++;
      binding_target.owner_h = binding_target.make_handle();
    end
    return status;
  endfunction
endclass

class rdma_qp_codec_fault_executor extends rdma_qp_lifecycle_executor;
  `uvm_object_utils(rdma_qp_codec_fault_executor)
  function new(string name = "rdma_qp_codec_fault_executor");
    super.new(name);
  endfunction
  function void remove_qpc_codecs();
    qpc_codecs.clear();
  endfunction
endclass

class rdma_qp_output_fault_cmq extends rdma_mock_cmq_port;
  `uvm_object_utils(rdma_qp_output_fault_cmq)
  bit drop_ticket;
  bit drop_completion;
  bit definitive_no_submit;

  function new(string name = "rdma_qp_output_fault_cmq");
    super.new(name);
    drop_ticket = 0;
    drop_completion = 0;
    definitive_no_submit = 0;
  endfunction

  virtual task execute(
    rdma_cmq_command_desc command,
    output rdma_cmq_ticket ticket,
    output rdma_cmq_completion completion,
    output rdma_status status
  );
    if (definitive_no_submit && command != null &&
        command.opcode_key != null &&
        command.opcode_key.opcode == XTR_V1_OP_QPC_CREATE) begin
      ticket = null;
      completion = null;
      last_execute_no_submit_proven = 1'b1;
      status = rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                                 "injected definitive QPC no-submit");
      return;
    end
    super.execute(command, ticket, completion, status);
    if (command != null && command.opcode_key != null &&
        command.opcode_key.opcode == XTR_V1_OP_QPC_CREATE) begin
      if (drop_ticket) ticket = null;
      if (drop_completion) completion = null;
    end
  endtask
endclass

// Destroy-path adapter that withholds all CMQ correlation metadata for the
// ERROR transition while preserving a timeout status.  This models a command
// that may have crossed the hardware boundary but for which no ticket can be
// recovered; the executor must retain durable ERROR authority and fail closed
// on a retry rather than guessing or calling reconcile(null).
class rdma_qp_ticketless_destroy_cmq extends rdma_mock_cmq_port;
  `uvm_object_utils(rdma_qp_ticketless_destroy_cmq)

  function new(string name = "rdma_qp_ticketless_destroy_cmq");
    super.new(name);
  endfunction

  virtual task execute(
    rdma_cmq_command_desc command,
    output rdma_cmq_ticket ticket,
    output rdma_cmq_completion completion,
    output rdma_status status
  );
    super.execute(command, ticket, completion, status);
    if (command != null && command.opcode_key != null &&
        command.opcode_key.opcode == XTR_V1_OP_QPC_MODIFY &&
        status != null && status.code == RDMA_SC_TIMEOUT) begin
      ticket = null;
      completion = null;
      // This is deliberately not a no-submit proof: timeout remains
      // ambiguous even though the adapter cannot return a ticket.
      last_execute_no_submit_proven = 1'b0;
    end
  endtask
endclass

// Inject a generation rebind immediately after the destroy ERROR MODIFY
// command returns.  The destroy executor must fence this side-effect
// boundary, stop before issuing OCC/DELETE, and retain ERROR recovery
// authority for the old generation.
class rdma_qp_destroy_rebind_cmq extends rdma_mock_cmq_port;
  `uvm_object_utils(rdma_qp_destroy_rebind_cmq)
  rdma_function_binding binding_target;
  bit rebound;
  bit armed;

  function new(string name = "rdma_qp_destroy_rebind_cmq");
    super.new(name);
    binding_target = null;
    rebound = 1'b0;
    armed = 1'b0;
  endfunction

  virtual task execute(
    rdma_cmq_command_desc command,
    output rdma_cmq_ticket ticket,
    output rdma_cmq_completion completion,
    output rdma_status status
  );
    super.execute(command, ticket, completion, status);
    if (armed && !rebound && binding_target != null && command != null &&
        command.opcode_key != null &&
        command.opcode_key.opcode == XTR_V1_OP_QPC_MODIFY) begin
      binding_target.generation++;
      binding_target.owner_h = binding_target.make_handle();
      rebound = 1'b1;
    end
  endtask
endclass

class rdma_qp_lifecycle_test extends uvm_test;
  `uvm_component_utils(rdma_qp_lifecycle_test)

  function new(string name = "rdma_qp_lifecycle_test",
               uvm_component parent = null);
    super.new(name, parent);
  endfunction

  function automatic void expect_ok(string label, rdma_status status);
    if (status == null || !status.ok())
      `uvm_error(label, status == null ? "null status" : status.convert2string())
  endfunction

  function automatic void expect_code(
    string label, rdma_status status, rdma_status_code_e expected
  );
    if (status == null || status.code != expected)
      `uvm_error(label, $sformatf("expected %s, got %s", expected.name(),
        status == null ? "null" : status.convert2string()))
  endfunction

  function automatic rdma_function_binding make_binding(string name);
    rdma_function_binding binding;
    rdma_interrupt_vector_binding vector;

    binding = rdma_function_binding::type_id::create(name);
    binding.function_uid = 64'h1122_3344_5566_7788;
    binding.generation = 7;
    binding.global_function_id = 32'h1234_0001;
    binding.host_id = 5;
    binding.rdma_vf_id = 8'h55;
    binding.pfvf_id = 32'h1234_0099;
    binding.pcie.bdf = '{segment:16'h1, bus:8'h20, device:5'h2,
                         function_num:3'h1};
    binding.pcie.parent_pf_bdf = binding.pcie.bdf;
    binding.pcie.mse = 1'b1;
    binding.pcie.bme = 1'b1;
    binding.pcie.bar[0].base.value = 64'h8000_0000;
    binding.pcie.bar[0].size = 64'h4000;
    binding.pcie.bar[0].enabled = 1'b1;
    binding.notify_bar_id = 0;
    binding.notify_base.value = 64'h8000_2000;
    binding.notify_size = 64'h2000;
    binding.queue_dma.requester_bdf = binding.pcie.bdf;
    binding.queue_dma.pasid_valid = 1'b1;
    binding.queue_dma.pasid = 20'h12345;
    binding.queue_dma.dma_domain_valid = 1'b1;
    binding.queue_dma.dma_domain_id = 9;
    binding.queue_caps.min_cq_depth = 16;
    binding.queue_caps.max_cq_depth = 32768;
    binding.queue_caps.min_srq_depth = 16;
    binding.queue_caps.max_srq_depth = 32768;
    binding.queue_caps.max_ceq_depth = 4096;
    binding.queue_caps.max_aeq_depth = 4096;
    binding.queue_caps.max_wq_sge = 8;
    binding.queue_caps.max_queue_ring_bytes = 2 * 1024 * 1024;
    binding.queue_caps.max_sgb_bytes = 2 * 1024 * 1024;
    vector = '{default:'0};
    vector.function_local_vector = 1;
    vector.hardware_eq_vector = 1;
    vector.msix_table_index = 1;
    vector.enabled = 1'b1;
    binding.interrupt_vectors.push_back(vector);
    binding.state = RDMA_BIND_ACTIVE;
    binding.owner_h = binding.make_handle();
    binding.notify_valid = 1'b1;
    binding.notify_ready = 1'b1;
    binding.dmi_valid = 1'b1;
    binding.dmi_ready = 1'b1;
    binding.vft_valid = 1'b1;
    binding.vft_ready = 1'b1;
    return binding;
  endfunction

  function automatic rdma_qp_context_attributes make_rc_attrs(string name);
    rdma_qp_context_attributes attrs;
    rdma_qpc_rc_ext ext;

    attrs = rdma_qp_context_attributes::type_id::create(name);
    attrs.path_mtu_bytes = 4096;
    attrs.pkey = 16'hbeef;
    attrs.address_vector = rdma_address_vector::type_id::create({name, "_av"});
    attrs.address_vector.destination_mac = 48'h1122_3344_5566;
    attrs.address_vector.traffic_class = 8'h02;
    attrs.behavior = rdma_qpc_behavior::type_id::create({name, "_behavior"});
    attrs.behavior.transport_version = 1;
    ext = rdma_qpc_rc_ext::type_id::create({name, "_rc"});
    ext.remote_qpn = 24'h456789;
    ext.send_psn = 24'h123456;
    ext.recv_psn = 24'h654321;
    ext.retry_count = 2;
    ext.rnr_retry_count = 2;
    attrs.transport_ext = ext;
    return attrs;
  endfunction

  function automatic rdma_qp_context_attributes make_urc_attrs(string name);
    rdma_qp_context_attributes attrs;
    rdma_qpc_urc_ext ext;

    attrs = make_rc_attrs(name);
    ext = rdma_qpc_urc_ext::type_id::create({name, "_urc"});
    ext.remote_qpn = 24'h765432;
    ext.rbsn = 24'h010203;
    ext.dbsn = 24'h040506;
    ext.rpsn = 24'h070809;
    ext.dpsn = 24'h0a0b0c;
    ext.queues.rsq_depth = 64;
    ext.queues.rdsq_depth = 64;
    ext.queues.rdsq_fetch_count = 8;
    ext.queues.dsq_fetch_count = 8;
    ext.queues.rq_sequence_threshold_entries = 64;
    ext.queues.sq_completion_threshold_entries = 128;
    attrs.transport_ext = ext;
    return attrs;
  endfunction

  function automatic rdma_qp_context_attributes make_ud_attrs(string name);
    rdma_qp_context_attributes attrs;
    rdma_qpc_ud_ext ext;
    attrs = make_rc_attrs(name);
    attrs.address_vector.traffic_class = 8'hac;
    ext = rdma_qpc_ud_ext::type_id::create({name, "_ud"});
    ext.qkey = 32'h1111_2222;
    attrs.transport_ext = ext;
    return attrs;
  endfunction

  function automatic rdma_create_qp_req make_request(
    string name, rdma_function_binding binding, rdma_pd pd, rdma_cq cq,
    rdma_transport_e transport
  );
    rdma_create_qp_req request;

    request = rdma_create_qp_req::type_id::create(name);
    request.owner = binding.make_handle();
    request.transport = transport;
    request.sq_depth = 128;
    request.rq_depth = 64;
    request.max_send_sge = transport == RDMA_TRANSPORT_UD ? 4 : 2;
    request.max_recv_sge = transport == RDMA_TRANSPORT_UD ? 4 : 2;
    request.max_inline_data = transport == RDMA_TRANSPORT_UD ? 512 : 32;
    if (transport == RDMA_TRANSPORT_UD)
      request.sq_sgb_backing.mode = RDMA_QUEUE_BACKING_OWNED;
    request.pd_h = rdma_clone_handle_value(pd.handle, "test QP PD");
    request.send_cq_h = rdma_clone_handle_value(cq.handle, "test QP send CQ");
    request.recv_cq_h = rdma_clone_handle_value(cq.handle, "test QP receive CQ");
    request.context_attrs = transport == RDMA_TRANSPORT_URC ?
      make_urc_attrs({name, "_attrs"}) : transport == RDMA_TRANSPORT_UD ?
      make_ud_attrs({name, "_attrs"}) : make_rc_attrs({name, "_attrs"});
    return request;
  endfunction

  task automatic setup_qp_environment(
    string label,
    rdma_mock_host_mem mem,
    output rdma_function_binding binding,
    output rdma_resource_manager manager,
    output rdma_mock_context_backing contexts,
    output rdma_mock_cmq_port cmq,
    output rdma_qp_lifecycle_executor executor,
    output rdma_pd pd,
    output rdma_cq cq
  );
    rdma_function function_resource;

    binding = make_binding({label, "_binding"});
    manager = rdma_resource_manager::type_id::create({label, "_manager"});
    contexts = rdma_mock_context_backing::type_id::create({label, "_contexts"});
    cmq = rdma_mock_cmq_port::type_id::create({label, "_cmq"});
    executor = rdma_qp_lifecycle_executor::type_id::create({label, "_executor"});
    expect_ok({label, "_FUNCTION"}, manager.create_function(binding,
                                                              function_resource));
    expect_ok({label, "_PD"}, manager.create_pd(binding, pd));
    expect_ok({label, "_CQ"}, manager.create_cq(binding, null, cq));
    expect_ok({label, "_CONFIGURE"}, executor.configure(manager, cmq, mem,
                                                          contexts, 2us));
  endtask

  task automatic setup_custom_qp_environment(
    string label,
    rdma_mock_host_mem mem,
    rdma_resource_manager manager,
    rdma_mock_context_backing contexts,
    rdma_mock_cmq_port cmq,
    rdma_qp_lifecycle_executor executor,
    output rdma_function_binding binding,
    output rdma_pd pd,
    output rdma_cq cq
  );
    rdma_function function_resource;

    binding = make_binding({label, "_binding"});
    expect_ok({label, "_FUNCTION"}, manager.create_function(binding,
                                                              function_resource));
    expect_ok({label, "_PD"}, manager.create_pd(binding, pd));
    expect_ok({label, "_CQ"}, manager.create_cq(binding, null, cq));
    expect_ok({label, "_CONFIGURE"}, executor.configure(manager, cmq, mem,
                                                          contexts, 2us));
  endtask

  function automatic void expect_create_steps(
    string label, rdma_control_result result
  );
    rdma_control_step_e expected[$];
    expected.push_back(RDMA_CTRL_STEP_RESOURCE_RESERVED);
    expected.push_back(RDMA_CTRL_STEP_BACKING_ATTACHED);
    expected.push_back(RDMA_CTRL_STEP_HMC_ATTACHED);
    expected.push_back(RDMA_CTRL_STEP_HW_CONTEXT_CREATED);
    expected.push_back(RDMA_CTRL_STEP_REGISTRY_PROGRAMMED);
    expected.push_back(RDMA_CTRL_STEP_REGISTRY_ACTIVE);
    if (result == null || result.completed_steps != expected)
      `uvm_error(label, $sformatf("unexpected create steps: %p",
        result == null ? expected : result.completed_steps))
  endfunction

  function automatic rdma_dma_request_context make_borrowed_context(
    string name,
    rdma_function_binding binding,
    rdma_handle owner_h,
    rdma_queue_backing_role_e role
  );
    rdma_dma_request_context request_context;

    request_context = rdma_dma_request_context::type_id::create(name);
    request_context.function_h = binding.make_handle();
    request_context.requester_bdf = binding.queue_dma.requester_bdf;
    request_context.pasid_valid = binding.queue_dma.pasid_valid;
    request_context.pasid = binding.queue_dma.pasid;
    request_context.dma_domain_valid = binding.queue_dma.dma_domain_valid;
    request_context.dma_domain_id = binding.queue_dma.dma_domain_id;
    request_context.owner_h = rdma_clone_handle_value(owner_h,
                                                       "borrowed caller owner");
    request_context.queue_role_valid = 1'b1;
    request_context.queue_role = int'(role);
    return request_context;
  endfunction

  task automatic allocate_borrowed_mapping(
    string label,
    rdma_mock_host_mem mem,
    rdma_function_binding binding,
    rdma_handle owner_h,
    rdma_queue_backing_role_e role,
    output rdma_dma_mapping mapping
  );
    rdma_dma_request_context request_context;
    request_context = make_borrowed_context({label, "_context"}, binding,
                                             owner_h, role);
    expect_ok(label, mem.allocate(request_context, 8192, 4096,
                                  RDMA_DMA_BIDIRECTIONAL, mapping));
  endtask

  function automatic rdma_queue_backing_slice make_borrowed_slice(
    string name,
    rdma_queue_backing_role_e role,
    rdma_dma_mapping mapping,
    longint unsigned mapping_offset,
    longint unsigned logical_queue_offset
  );
    rdma_queue_backing_slice slice;
    slice = rdma_queue_backing_slice::type_id::create(name);
    slice.role = role;
    slice.mapping = mapping;
    slice.mapping_offset = mapping_offset;
    slice.length = 4096;
    slice.logical_queue_offset = logical_queue_offset;
    return slice;
  endfunction

  task automatic create_qp_fixture(
    string label,
    rdma_transport_e transport,
    output rdma_mock_host_mem mem,
    output rdma_qp qp
  );
    rdma_function_binding binding;
    rdma_resource_manager manager;
    rdma_mock_context_backing contexts;
    rdma_mock_cmq_port cmq;
    rdma_qp_lifecycle_executor executor;
    rdma_function function_resource;
    rdma_pd pd;
    rdma_cq cq;
    rdma_create_qp_req request;
    rdma_control_result result;

    qp = null;
    binding = make_binding({label, "_binding"});
    manager = rdma_resource_manager::type_id::create({label, "_manager"});
    mem = rdma_mock_host_mem::type_id::create({label, "_mem"});
    contexts = rdma_mock_context_backing::type_id::create({label, "_contexts"});
    cmq = rdma_mock_cmq_port::type_id::create({label, "_cmq"});
    executor = rdma_qp_lifecycle_executor::type_id::create({label, "_executor"});
    expect_ok({label, "_FUNCTION"}, manager.create_function(binding, function_resource));
    expect_ok({label, "_PD"}, manager.create_pd(binding, pd));
    expect_ok({label, "_CQ"}, manager.create_cq(binding, null, cq));
    expect_ok({label, "_CONFIGURE"}, executor.configure(manager, cmq, mem,
                                                           contexts, 2us));
    request = make_request({label, "_request"}, binding, pd, cq, transport);
    executor.create_locked(binding, binding.make_handle(), request, 41, qp, result);
    if (result == null || result.status == null || !result.status.ok() || qp == null)
      `uvm_error(label, result == null || result.status == null ?
                 "QP create returned no successful result" : result.status.convert2string())
    else begin
      rdma_xtr_v1_qpc_command_body body;
      longint unsigned expected_staging_iova;
      expected_staging_iova = transport == RDMA_TRANSPORT_URC ?
        64'h0000_0001_0000_9000 : transport == RDMA_TRANSPORT_UD ?
        64'h0000_0001_0001_5000 : 64'h0000_0001_0000_5000;
      expect_create_steps({label, "_STEPS"}, result);
      if (qp.state != RDMA_RESOURCE_ACTIVE || qp.qp_state != RDMA_QPS_RESET ||
          !result.final_resource_state_known ||
          result.final_resource_state != RDMA_RESOURCE_ACTIVE ||
          cmq.calls.size() != 1 || cmq.calls[0].opcode != XTR_V1_OP_QPC_CREATE ||
          cmq.calls[0].command == null ||
          !$cast(body, cmq.calls[0].command.body) || body == null ||
          body.qp_h == null || body.qp_h.object_id != 0 ||
          body.send_cq_h == null || body.send_cq_h.object_id != 0 ||
          body.recv_cq_h == null || body.recv_cq_h.object_id != 0 ||
          body.qpc_buffer.value != expected_staging_iova)
        `uvm_error({label, "_CREATE_COMMAND"},
          "QPC_CREATE did not use literal local IDs and staging IOVA")
      if (mem.live_allocations() !=
          (transport == RDMA_TRANSPORT_URC ? 7 :
           transport == RDMA_TRANSPORT_UD ? 5 : 4))
        `uvm_error({label, "_STAGING_LIVE"},
          "successful create did not return staging to the live baseline")
    end
  endtask

  task automatic check_rc_plan_and_staging_authority();
    rdma_mock_host_mem mem;
    rdma_qp qp;
    rdma_dma_mapping staging_mapping;

    create_qp_fixture("RC_PLAN", RDMA_TRANSPORT_RC, mem, qp);
    if (qp == null || qp.qp_plan == null || qp.programmed_qpc == null)
      `uvm_error("RC_PLAN", "create did not retain plan and semantic QPC")
    else begin
      if (qp.qp_plan.sq_ring.logical_bytes != 8192 ||
          qp.qp_plan.sq_ring.storage_bytes != 8192 ||
          qp.qp_plan.rq_ring.logical_bytes != 4096 ||
          qp.qp_plan.rq_ring.storage_bytes != 4096)
        `uvm_error("RC_PLAN", "64-byte WQE geometry was not materialized")
      if (qp.sq_iova.value == qp.qp_plan.sq_pd_ref.mapping.iova.value ||
          qp.rq_iova.value == qp.qp_plan.rq_pd_ref.mapping.iova.value ||
          qp.programmed_qpc.sq_backing.value !=
            qp.qp_plan.sq_pd_ref.mapping.iova.value ||
          qp.programmed_qpc.rq_backing.value !=
            qp.qp_plan.rq_pd_ref.mapping.iova.value)
        `uvm_error("RC_PLAN", "payload IOVA and page-directory authority crossed")
      if ((qp.qp_plan.context_ref.shadow_pointer_base.value & 64'h1ff) != 0)
        `uvm_error("RC_PLAN", "QPC context is not 512-byte aligned")
    end
    staging_mapping = null;
    foreach (mem.regions[i])
      if (mem.regions[i].mapping != null && mem.regions[i].mapping.size == 512)
        staging_mapping = mem.regions[i].mapping;
    if (staging_mapping == null || qp == null || qp.qp_plan == null ||
        staging_mapping.iova.value == qp.qp_plan.context_ref.shadow_pointer_base.value)
      `uvm_error("RC_PLAN", "staging mapping was not distinct from QPC context")
    foreach (mem.calls[i])
      if (mem.calls[i].method_name == "allocate" && mem.calls[i].size == 512 &&
          (mem.calls[i].request_context == null ||
           mem.calls[i].request_context.owner_h == null || qp == null ||
           !mem.calls[i].request_context.owner_h.same_instance(qp.handle)))
        `uvm_error("RC_PLAN", "staging DMA owner was not the global QP handle")
  endtask

  task automatic check_ud_semantic_round_trip();
    rdma_mock_host_mem mem;
    rdma_qp qp;
    rdma_qpc_ud_ext ud_ext;
    create_qp_fixture("UD_QPC", RDMA_TRANSPORT_UD, mem, qp);
    ud_ext = null;
    if (qp == null || qp.programmed_qpc == null ||
        qp.programmed_qpc.transport != RDMA_TRANSPORT_UD ||
        !$cast(ud_ext, qp.programmed_qpc.transport_ext) ||
        ud_ext.qkey != 32'h1111_2222)
      `uvm_error("UD_QPC", "UD QPC was not materialized through its codec")
    if (qp == null || qp.qp_plan == null || qp.qp_plan.sq_sgb_ref == null)
      `uvm_error("SQ_SGB", "UD QP did not retain SQ SGB authority")
    else begin
      if (qp.qp_plan.sq_sgb_ref.length != qp.sq_depth * 512)
        `uvm_error("SQ_SGB_SIZE", "SQ SGB logical length is not depth*512")
      if ((qp.qp_plan.sq_sgb_ref.mapping.iova.value & 64'h1ff) != 0)
        `uvm_error("SQ_SGB_ALIGN", "SQ SGB IOVA is not 512-byte aligned")
    end
  endtask

  task automatic check_urc_internal_geometry();
    rdma_mock_host_mem mem;
    rdma_qp qp;
    bit seen_rsq, seen_rdsq, seen_dsq;

    create_qp_fixture("URC_PLAN", RDMA_TRANSPORT_URC, mem, qp);
    seen_rsq = 0; seen_rdsq = 0; seen_dsq = 0;
    if (qp != null && qp.qp_plan != null) begin
      foreach (qp.qp_plan.urc_refs[i]) begin
        if (qp.qp_plan.urc_refs[i].role == RDMA_QUEUE_ROLE_QP_URC_RSQ &&
            qp.qp_plan.urc_refs[i].length == 4096) seen_rsq = 1;
        if (qp.qp_plan.urc_refs[i].role == RDMA_QUEUE_ROLE_QP_URC_RDSQ &&
            qp.qp_plan.urc_refs[i].length == 4096) seen_rdsq = 1;
        if (qp.qp_plan.urc_refs[i].role == RDMA_QUEUE_ROLE_QP_URC_DSQ &&
            qp.qp_plan.urc_refs[i].length == 8192) seen_dsq = 1;
      end
    end
    if (!(seen_rsq && seen_rdsq && seen_dsq))
      `uvm_error("URC_PLAN", "URC RSQ/RDSQ/DSQ owned geometry is wrong")
  endtask

  task automatic check_allocate_error_cleanup();
    rdma_qp_allocate_error_host_mem mem;
    rdma_function_binding binding;
    rdma_resource_manager manager;
    rdma_mock_context_backing contexts;
    rdma_mock_cmq_port cmq;
    rdma_qp_lifecycle_executor executor;
    rdma_pd pd;
    rdma_cq cq;
    rdma_create_qp_req request;
    rdma_qp qp;
    rdma_control_result result;
    int unsigned release_count;

    mem = rdma_qp_allocate_error_host_mem::type_id::create("ALLOC_ERROR_mem");
    setup_qp_environment("ALLOC_ERROR", mem, binding, manager, contexts, cmq,
                         executor, pd, cq);
    request = make_request("ALLOC_ERROR_request", binding, pd, cq,
                           RDMA_TRANSPORT_RC);
    executor.create_locked(binding, binding.make_handle(), request, 201, qp,
                           result);
    expect_code("ALLOC_ERROR_STATUS",
      result == null ? null : result.status, RDMA_SC_RESOURCE_EXHAUSTED);
    release_count = 0;
    foreach (mem.calls[i])
      if (mem.calls[i].method_name == "release") release_count++;
    if (qp != null || mem.live_allocations() != 0 || release_count != 1)
      `uvm_error("ALLOC_ERROR_CLEANUP",
        "non-null failed allocation was not released exactly once")
  endtask

  task automatic check_authority_failure_cleanup(int unsigned ordinal);
    rdma_qp_authority_failure_host_mem mem;
    rdma_function_binding binding;
    rdma_resource_manager manager;
    rdma_mock_context_backing contexts;
    rdma_mock_cmq_port cmq;
    rdma_qp_lifecycle_executor executor;
    rdma_pd pd;
    rdma_cq cq;
    rdma_create_qp_req request;
    rdma_qp qp;
    rdma_control_result result;
    int unsigned release_count;
    string label;

    label = $sformatf("AUTHORITY_%0d", ordinal);
    mem = rdma_qp_authority_failure_host_mem::type_id::create({label, "_mem"});
    mem.fail_check_ordinal = ordinal;
    setup_qp_environment(label, mem, binding, manager, contexts, cmq, executor,
                         pd, cq);
    request = make_request({label, "_request"}, binding, pd, cq,
                           RDMA_TRANSPORT_RC);
    executor.create_locked(binding, binding.make_handle(), request, 202 + ordinal,
                           qp, result);
    expect_code({label, "_STATUS"}, result == null ? null : result.status,
                RDMA_SC_INVALID_STATE);
    release_count = 0;
    foreach (mem.calls[i])
      if (mem.calls[i].method_name == "release") release_count++;
    if (qp != null || mem.live_allocations() != 0 || release_count != 1)
      `uvm_error({label, "_CLEANUP"},
        "opaque authority failure did not release its allocation")
  endtask

  task automatic check_stale_rebind_blocks_attach();
    rdma_qp_rebind_host_mem mem;
    rdma_function_binding binding;
    rdma_resource_manager manager;
    rdma_mock_context_backing contexts;
    rdma_mock_cmq_port cmq;
    rdma_qp_lifecycle_executor executor;
    rdma_pd pd;
    rdma_cq cq;
    rdma_create_qp_req request;
    rdma_qp qp;
    rdma_control_result result;
    rdma_handle reserved_qp_h;
    rdma_resource reserved_resource;
    bit saw_staging_release;

    mem = rdma_qp_rebind_host_mem::type_id::create("STALE_REBIND_mem");
    setup_qp_environment("STALE_REBIND", mem, binding, manager, contexts, cmq,
                         executor, pd, cq);
    mem.binding_target = binding;
    request = make_request("STALE_REBIND_request", binding, pd, cq,
                           RDMA_TRANSPORT_RC);
    executor.create_locked(binding, binding.make_handle(), request, 205, qp,
                           result);
    expect_code("STALE_REBIND_STATUS",
      result == null ? null : result.status, RDMA_SC_STALE_GENERATION);
    reserved_qp_h = null;
    saw_staging_release = 1'b0;
    foreach (mem.calls[i]) begin
      if (reserved_qp_h == null && mem.calls[i].method_name == "allocate" &&
          mem.calls[i].request_context != null)
        reserved_qp_h = mem.calls[i].request_context.owner_h;
      if (mem.calls[i].method_name == "release" &&
          mem.calls[i].mapping != null && mem.calls[i].mapping.size == 512)
        saw_staging_release = 1'b1;
    end
    // Restore the registry's original Function generation only for the
    // read-only publication check.  The create result above already captured
    // the injected stale-generation outcome.
    if (mem.rebound) begin
      binding.generation--;
      binding.owner_h = binding.make_handle();
    end
    expect_code("STALE_REBIND_LOOKUP",
                manager.lookup(reserved_qp_h, reserved_resource),
                RDMA_SC_STALE_GENERATION);
    if (!mem.rebound || qp != null || !saw_staging_release ||
        reserved_resource != null || mem.live_allocations() != 0)
      `uvm_error("STALE_REBIND_ATTACH",
        "stale binding reached QP attachment or leaked rollback authority")
  endtask

  task automatic check_urc_nonzero_rejected();
    rdma_mock_host_mem mem;
    rdma_function_binding binding;
    rdma_resource_manager manager;
    rdma_mock_context_backing contexts;
    rdma_mock_cmq_port cmq;
    rdma_qp_lifecycle_executor executor;
    rdma_pd pd;
    rdma_cq cq;
    rdma_create_qp_req request;
    rdma_qpc_urc_ext urc_ext;
    rdma_qp qp;
    rdma_control_result result;

    mem = rdma_mock_host_mem::type_id::create("URC_NONZERO_mem");
    setup_qp_environment("URC_NONZERO", mem, binding, manager, contexts, cmq,
                         executor, pd, cq);
    request = make_request("URC_NONZERO_request", binding, pd, cq,
                           RDMA_TRANSPORT_URC);
    if (!$cast(urc_ext, request.context_attrs.transport_ext))
      `uvm_fatal("URC_NONZERO", "URC fixture extension cast failed")
    urc_ext.queues.rsq_backing.value = 64'h1000;
    executor.create_locked(binding, binding.make_handle(), request, 206, qp,
                           result);
    expect_code("URC_NONZERO_STATUS",
      result == null ? null : result.status, RDMA_SC_INVALID_ARGUMENT);
    if (qp != null || mem.calls.size() != 0)
      `uvm_error("URC_NONZERO_SIDE_EFFECT",
        "caller URC backing reached allocation side effects")
  endtask

  task automatic expect_zero_page(
    string label, rdma_mock_host_mem mem, rdma_dma_mapping mapping,
    longint unsigned offset
  );
    byte data[];
    expect_ok(label, mem.read(mapping, offset, 4096, data));
    foreach (data[i])
      if (data[i] != 8'h00) begin
        `uvm_error(label, $sformatf("byte %0d was not zero", i))
        break;
      end
  endtask

  task automatic expect_pd_prefix(
    string label, rdma_mock_host_mem mem, rdma_dma_mapping mapping,
    byte expected[16]
  );
    byte data[];
    expect_ok(label, mem.read(mapping, 0, 16, data));
    if (data.size() != 16)
      `uvm_error(label, "PD prefix did not contain 16 bytes")
    else foreach (expected[i])
      if (data[i] != expected[i])
        `uvm_error(label, $sformatf(
          "PD byte %0d expected 0x%02x got 0x%02x", i, expected[i], data[i]))
  endtask

  task automatic check_borrowed_multislice_authority();
    rdma_mock_host_mem mem;
    rdma_function_binding binding;
    rdma_resource_manager manager;
    rdma_mock_context_backing contexts;
    rdma_mock_cmq_port cmq;
    rdma_qp_lifecycle_executor executor;
    rdma_pd pd;
    rdma_cq cq;
    rdma_create_qp_req request;
    rdma_dma_mapping sq0, sq1, rq0, rq1;
    rdma_qp qp, lookup_qp;
    rdma_resource looked_up;
    rdma_control_result result;
    byte fill[];
    byte sq_pd_expected[16];
    byte rq_pd_expected[16];
    bit borrowed_release;
    longint unsigned stored_segment_iova;
    rdma_status status;

    mem = rdma_mock_host_mem::type_id::create("BORROWED_MULTI_mem");
    mem.next_address = 64'h0000_0100_0000_0000;
    setup_qp_environment("BORROWED_MULTI", mem, binding, manager, contexts, cmq,
                         executor, pd, cq);
    allocate_borrowed_mapping("BORROWED_SQ0", mem, binding, pd.handle,
      RDMA_QUEUE_ROLE_QP_SQ_RING, sq0);
    allocate_borrowed_mapping("BORROWED_SQ1", mem, binding, pd.handle,
      RDMA_QUEUE_ROLE_QP_SQ_RING, sq1);
    allocate_borrowed_mapping("BORROWED_RQ0", mem, binding, pd.handle,
      RDMA_QUEUE_ROLE_QP_RQ_RING, rq0);
    allocate_borrowed_mapping("BORROWED_RQ1", mem, binding, pd.handle,
      RDMA_QUEUE_ROLE_QP_RQ_RING, rq1);
    fill = new[4096];
    foreach (fill[i]) fill[i] = 8'ha5;
    expect_ok("BORROWED_FILL_SQ0", mem.write(sq0, 4096, fill));
    expect_ok("BORROWED_FILL_SQ1", mem.write(sq1, 0, fill));
    expect_ok("BORROWED_FILL_RQ0", mem.write(rq0, 4096, fill));
    expect_ok("BORROWED_FILL_RQ1", mem.write(rq1, 0, fill));
    mem.calls.delete();
    mem.method_ordinals.delete();

    request = make_request("BORROWED_MULTI_request", binding, pd, cq,
                           RDMA_TRANSPORT_RC);
    request.rq_depth = 128;
    request.sq_backing.mode = RDMA_QUEUE_BACKING_BORROWED;
    request.sq_backing.slices.push_back(make_borrowed_slice(
      "BORROWED_SQ0_slice", RDMA_QUEUE_ROLE_QP_SQ_RING, sq0, 4096, 0));
    request.sq_backing.slices.push_back(make_borrowed_slice(
      "BORROWED_SQ1_slice", RDMA_QUEUE_ROLE_QP_SQ_RING, sq1, 0, 4096));
    request.rq_backing.mode = RDMA_QUEUE_BACKING_BORROWED;
    request.rq_backing.slices.push_back(make_borrowed_slice(
      "BORROWED_RQ0_slice", RDMA_QUEUE_ROLE_QP_RQ_RING, rq0, 4096, 0));
    request.rq_backing.slices.push_back(make_borrowed_slice(
      "BORROWED_RQ1_slice", RDMA_QUEUE_ROLE_QP_RQ_RING, rq1, 0, 4096));
    executor.create_locked(binding, binding.make_handle(), request, 207, qp,
                           result);
    if (result == null || !result.ok() || qp == null ||
        qp.state != RDMA_RESOURCE_ACTIVE || qp.qp_state != RDMA_QPS_RESET ||
        qp.qp_plan == null) begin
      `uvm_error("BORROWED_MULTI_CREATE",
        result == null || result.status == null ? "null result" :
          result.status.convert2string())
      return;
    end
    if (qp.qp_plan.sq_ref.ownership != RDMA_OWNERSHIP_BORROWED ||
        qp.qp_plan.rq_ref.ownership != RDMA_OWNERSHIP_BORROWED ||
        qp.qp_plan.sq_ref.additional_segments.size() != 1 ||
        qp.qp_plan.rq_ref.additional_segments.size() != 1 ||
        qp.qp_plan.sq_ref.mapping == sq0 ||
        qp.qp_plan.sq_ref.additional_segments[0].mapping == sq1 ||
        qp.qp_plan.rq_ref.mapping == rq0 ||
        qp.qp_plan.rq_ref.additional_segments[0].mapping == rq1)
      `uvm_error("BORROWED_MULTI_DETACH",
        "persistent borrowed slices were missing or aliased caller mappings")
    if (qp.qp_plan.sq_ref.mapping.owner_h == null ||
        !qp.qp_plan.sq_ref.mapping.owner_h.same_instance(qp.handle) ||
        qp.qp_plan.sq_ref.additional_segments[0].mapping.owner_h == null ||
        !qp.qp_plan.sq_ref.additional_segments[0].mapping.owner_h.same_instance(
          qp.handle) ||
        qp.qp_plan.rq_ref.mapping.owner_h == null ||
        !qp.qp_plan.rq_ref.mapping.owner_h.same_instance(qp.handle) ||
        qp.qp_plan.rq_ref.additional_segments[0].mapping.owner_h == null ||
        !qp.qp_plan.rq_ref.additional_segments[0].mapping.owner_h.same_instance(
          qp.handle))
      `uvm_error("BORROWED_MULTI_OWNER",
        "detached borrowed mappings did not bind to the global QP")
    if (sq0.owner_h == null || !sq0.owner_h.same_instance(pd.handle) ||
        sq1.owner_h == null || !sq1.owner_h.same_instance(pd.handle) ||
        rq0.owner_h == null || !rq0.owner_h.same_instance(pd.handle) ||
        rq1.owner_h == null || !rq1.owner_h.same_instance(pd.handle))
      `uvm_error("BORROWED_CALLER_OWNER",
        "QP owner rebinding mutated caller mapping authority")

    borrowed_release = 1'b0;
    foreach (mem.calls[i])
      if (mem.calls[i].method_name == "release" &&
          mem.calls[i].mapping != null &&
          mem.calls[i].mapping.iova.value inside {
            sq0.iova.value, sq1.iova.value, rq0.iova.value, rq1.iova.value})
        borrowed_release = 1'b1;
    if (borrowed_release || sq0.state != RDMA_MAPPING_ACTIVE ||
        sq1.state != RDMA_MAPPING_ACTIVE || rq0.state != RDMA_MAPPING_ACTIVE ||
        rq1.state != RDMA_MAPPING_ACTIVE)
      `uvm_error("BORROWED_NON_RELEASE", "borrowed mapping was released")

    expect_zero_page("BORROWED_ZERO_SQ0", mem, sq0, 4096);
    expect_zero_page("BORROWED_ZERO_SQ1", mem, sq1, 0);
    expect_zero_page("BORROWED_ZERO_RQ0", mem, rq0, 4096);
    expect_zero_page("BORROWED_ZERO_RQ1", mem, rq1, 0);
    sq_pd_expected = '{8'h00, 8'h00, 8'h01, 8'h00, 8'h00, 8'h00, 8'h15, 8'h51,
                       8'h00, 8'h00, 8'h01, 8'h00, 8'h00, 8'h00, 8'h25, 8'h51};
    rq_pd_expected = '{8'h00, 8'h00, 8'h01, 8'h00, 8'h00, 8'h00, 8'h55, 8'h51,
                       8'h00, 8'h00, 8'h01, 8'h00, 8'h00, 8'h00, 8'h65, 8'h51};
    expect_pd_prefix("BORROWED_SQ_PD_LITERAL", mem,
                     qp.qp_plan.sq_pd_ref.mapping, sq_pd_expected);
    expect_pd_prefix("BORROWED_RQ_PD_LITERAL", mem,
                     qp.qp_plan.rq_pd_ref.mapping, rq_pd_expected);

    status = rdma_qp_recovery_ref_status(qp.qp_plan.sq_ref, 1'b0,
                                         "borrowed SQ");
    expect_code("BORROWED_RECOVERY_ACTIVE", status, RDMA_SC_OK);
    qp.qp_plan.sq_ref.additional_segments[0].mapping.state = RDMA_MAPPING_INVALID;
    status = rdma_qp_recovery_ref_status(qp.qp_plan.sq_ref, 1'b0,
                                         "borrowed SQ");
    expect_code("BORROWED_RECOVERY_SEGMENT_INVALID", status,
                RDMA_SC_INVALID_STATE);
    qp.qp_plan.sq_ref.additional_segments[0].mapping.state = RDMA_MAPPING_RELEASED;
    status = rdma_qp_recovery_ref_status(qp.qp_plan.sq_ref, 1'b1,
                                         "borrowed SQ");
    expect_code("BORROWED_RECOVERY_SEGMENT_COMPLETE", status, RDMA_SC_OK);
    if (qp.qp_plan.sq_ref.additional_segments[0].mapping.state !=
        RDMA_MAPPING_ACTIVE)
      `uvm_error("BORROWED_RECOVERY_SEGMENT_COMPLETE",
        "completed segment was not normalized for plan validation")

    stored_segment_iova = qp.qp_plan.sq_ref.additional_segments[0].mapping.iova.value;
    qp.qp_plan.sq_ref.additional_segments[0].mapping.iova.value += 64'h1000;
    expect_ok("BORROWED_MANAGER_LOOKUP", manager.lookup(qp.handle, looked_up));
    if (!$cast(lookup_qp, looked_up) || lookup_qp.qp_plan == null ||
        lookup_qp.qp_plan.sq_ref.additional_segments.size() != 1 ||
        lookup_qp.qp_plan.sq_ref.additional_segments[0].mapping.iova.value !=
          stored_segment_iova)
      `uvm_error("BORROWED_MANAGER_PROJECTION",
        "caller segment mutation reached manager authority")
  endtask

  task automatic check_rc_srq_geometry();
    rdma_function_binding binding;
    rdma_resource_manager manager;
    rdma_mock_host_mem mem;
    rdma_mock_context_backing contexts;
    rdma_mock_cmq_port cmq;
    rdma_queue_lifecycle_executor queue_executor;
    rdma_qp_lifecycle_executor qp_executor;
    rdma_function function_resource;
    rdma_pd pd;
    rdma_cq cq;
    rdma_create_srq_req srq_request;
    rdma_queue_resource queue_resource;
    rdma_srq srq;
    rdma_create_qp_req qp_request;
    rdma_qp qp;
    rdma_control_result result;
    rdma_queue_backing_ref srq_frfq_pd;
    rdma_create_qp_req depth_request;
    rdma_qp depth_qp;
    rdma_control_result depth_result;
    rdma_qp mismatched_qp, cloned_mismatch;
    uvm_object cloned_object;
    rdma_status status;

    binding = make_binding("RC_SRQ");
    manager = rdma_resource_manager::type_id::create("RC_SRQ_manager");
    mem = rdma_mock_host_mem::type_id::create("RC_SRQ_mem");
    contexts = rdma_mock_context_backing::type_id::create("RC_SRQ_contexts");
    cmq = rdma_mock_cmq_port::type_id::create("RC_SRQ_cmq");
    expect_ok("RC_SRQ_FUNCTION", manager.create_function(binding,
                                                           function_resource));
    expect_ok("RC_SRQ_PD", manager.create_pd(binding, pd));
    expect_ok("RC_SRQ_CQ", manager.create_cq(binding, null, cq));
    queue_executor = rdma_queue_lifecycle_executor::type_id::create(
      "RC_SRQ_queue_executor");
    expect_ok("RC_SRQ_QUEUE_CONFIGURE", queue_executor.configure(
      manager, cmq, mem, contexts, 2us));
    srq_request = rdma_create_srq_req::type_id::create("RC_SRQ_request");
    srq_request.owner = binding.make_handle();
    srq_request.depth = 64;
    srq_request.max_sge = 2;
    srq_request.limit_threshold = 16;
    srq_request.pd_h = rdma_clone_handle_value(pd.handle, "RC SRQ PD");
    queue_executor.create_locked(binding, binding.make_handle(), srq_request,
                                  101, queue_resource, result);
    if (result == null || !result.ok() || !$cast(srq, queue_resource) ||
        srq.queue_plan == null)
      `uvm_error("RC_SRQ", $sformatf("SRQ fixture did not become programmed: %s",
        result == null || result.status == null ? "null" :
          result.status.convert2string()))
    qp_executor = rdma_qp_lifecycle_executor::type_id::create(
      "RC_SRQ_qp_executor");
    expect_ok("RC_SRQ_QP_CONFIGURE", qp_executor.configure(
      manager, cmq, mem, contexts, 2us));
    qp_request = make_request("RC_SRQ_qp_request", binding, pd, cq,
                              RDMA_TRANSPORT_RC);
    qp_request.srq_h = rdma_clone_handle_value(srq.handle, "RC SRQ source");
    qp = null;
    result = null;
    qp_executor.create_locked(binding, binding.make_handle(), qp_request, 102,
                               qp, result);
    if (result == null || !result.ok() || qp == null ||
        qp.state != RDMA_RESOURCE_ACTIVE || qp.qp_state != RDMA_QPS_RESET ||
        qp.qp_plan == null ||
        qp.programmed_qpc == null)
      `uvm_error("RC_SRQ", $sformatf("RC+SRQ QP create did not succeed: %s",
        result == null || result.status == null ? "null" :
          result.status.convert2string()))
    else begin
      if (qp.qp_plan.rq_source_h == null ||
          !qp.qp_plan.rq_source_h.same_instance(srq.handle) ||
          qp.qp_plan.rq_ring != null || qp.qp_plan.rq_ref != null ||
          qp.qp_plan.rq_pd_ref != null || qp.programmed_qpc.srq_h == null ||
          qp.rq_depth != 64 || qp.programmed_qpc.rq_depth != 64)
        `uvm_error("RC_SRQ", "RC+SRQ plan retained private RQ authority")
      srq_frfq_pd = null;
      foreach (srq.queue_plan.refs[i])
        if (srq.queue_plan.refs[i] != null &&
            srq.queue_plan.refs[i].role == RDMA_QUEUE_ROLE_SRFQ_PD)
          srq_frfq_pd = srq.queue_plan.refs[i];
      if (srq_frfq_pd == null ||
          qp.programmed_qpc.rq_backing.value !=
            srq_frfq_pd.mapping.iova.value + srq_frfq_pd.mapping_offset)
        `uvm_error("RC_SRQ", "QPC RQ backing did not use SRFQ page directory")

      cloned_object = qp.clone();
      if (!$cast(mismatched_qp, cloned_object) || mismatched_qp.qp_plan == null)
        `uvm_fatal("RC_SRQ_MISMATCH", "failed to clone SRQ QP fixture")
      mismatched_qp.qp_plan.rq_source_h.object_id++;
      expect_code("RC_SRQ_MISMATCH_SOURCE", mismatched_qp.validate(),
                  RDMA_SC_INVALID_STATE);
      cloned_object = mismatched_qp.clone();
      if (!$cast(cloned_mismatch, cloned_object) ||
          cloned_mismatch.qp_plan == null ||
          cloned_mismatch.qp_plan.rq_source_h == null ||
          !cloned_mismatch.qp_plan.rq_source_h.same_instance(
            mismatched_qp.qp_plan.rq_source_h) ||
          cloned_mismatch.qp_plan.rq_source_h.same_instance(
            cloned_mismatch.srq_h))
        `uvm_error("RC_SRQ_MISMATCH_CLONE",
          "QP clone sanitized mismatched resource/plan SRQ identity")
      status = cloned_mismatch.validate();
      expect_code("RC_SRQ_MISMATCH_CLONE_STATUS", status,
                  RDMA_SC_INVALID_STATE);
    end

    depth_request = make_request("RC_SRQ_depth_request", binding, pd, cq,
                                 RDMA_TRANSPORT_RC);
    depth_request.srq_h = rdma_clone_handle_value(srq.handle,
                                                  "RC SRQ depth source");
    depth_request.rq_depth = 128;
    depth_qp = null;
    depth_result = null;
    qp_executor.create_locked(binding, binding.make_handle(), depth_request, 103,
                              depth_qp, depth_result);
    expect_code("RC_SRQ_DEPTH_MISMATCH",
      depth_result == null ? null : depth_result.status,
      RDMA_SC_INVALID_ARGUMENT);
    if (depth_qp != null)
      `uvm_error("RC_SRQ_DEPTH_MISMATCH", "mismatched SRQ depth returned a QP")
  endtask

  task automatic expect_definitive_create_rollback(
    string label,
    rdma_resource_manager manager,
    rdma_mock_host_mem mem,
    rdma_qp qp,
    rdma_control_result result,
    rdma_status_code_e expected_code
  );
    rdma_resource resource;
    expect_code({label, "_STATUS"}, result == null ? null : result.status,
                expected_code);
    expect_code({label, "_PRIMARY"},
                result == null ? null : result.primary_status, expected_code);
    if (qp != null || result == null || result.resource_h == null ||
        !result.final_resource_state_known ||
        result.final_resource_state != RDMA_RESOURCE_RELEASED ||
        mem.live_allocations() != 0)
      `uvm_error({label, "_CLEANUP"},
        "definitive create failure did not release all owned authority")
    if (result != null && result.resource_h != null) begin
      expect_code({label, "_ABSENT"}, manager.lookup(result.resource_h, resource),
                  RDMA_SC_INVALID_STATE);
    end
  endtask

  task automatic check_allocation_and_host_write_failures();
    for (int unsigned failure_ordinal = 1; failure_ordinal <= 5;
         failure_ordinal++) begin
      string label;
      rdma_qp_fault_host_mem mem;
      rdma_resource_manager manager;
      rdma_mock_context_backing contexts;
      rdma_mock_cmq_port cmq;
      rdma_qp_lifecycle_executor executor;
      rdma_function_binding binding;
      rdma_pd pd;
      rdma_cq cq;
      rdma_create_qp_req request;
      rdma_qp qp;
      rdma_control_result result;

      label = $sformatf("CREATE_ALLOC_%0d", failure_ordinal);
      mem = rdma_qp_fault_host_mem::type_id::create({label, "_mem"});
      mem.fail_allocate_ordinal = failure_ordinal;
      manager = rdma_resource_manager::type_id::create({label, "_manager"});
      contexts = rdma_mock_context_backing::type_id::create({label, "_contexts"});
      cmq = rdma_mock_cmq_port::type_id::create({label, "_cmq"});
      executor = rdma_qp_lifecycle_executor::type_id::create({label, "_executor"});
      setup_custom_qp_environment(label, mem, manager, contexts, cmq, executor,
                                  binding, pd, cq);
      request = make_request({label, "_request"}, binding, pd, cq,
                             RDMA_TRANSPORT_RC);
      executor.create_locked(binding, binding.make_handle(), request,
                             300 + failure_ordinal, qp, result);
      expect_definitive_create_rollback(label, manager, mem, qp, result,
                                        RDMA_SC_RESOURCE_EXHAUSTED);
      if (cmq.calls.size() != 0)
        `uvm_error({label, "_NO_CMQ"}, "allocation failure reached QPC_CREATE")
    end

    for (int unsigned failure_ordinal = 1; failure_ordinal <= 5;
         failure_ordinal++) begin
      string label;
      rdma_qp_fault_host_mem mem;
      rdma_resource_manager manager;
      rdma_mock_context_backing contexts;
      rdma_mock_cmq_port cmq;
      rdma_qp_lifecycle_executor executor;
      rdma_function_binding binding;
      rdma_pd pd;
      rdma_cq cq;
      rdma_create_qp_req request;
      rdma_qp qp;
      rdma_control_result result;

      label = $sformatf("CREATE_WRITE_%0d", failure_ordinal);
      mem = rdma_qp_fault_host_mem::type_id::create({label, "_mem"});
      mem.fail_write_ordinal = failure_ordinal;
      manager = rdma_resource_manager::type_id::create({label, "_manager"});
      contexts = rdma_mock_context_backing::type_id::create({label, "_contexts"});
      cmq = rdma_mock_cmq_port::type_id::create({label, "_cmq"});
      executor = rdma_qp_lifecycle_executor::type_id::create({label, "_executor"});
      setup_custom_qp_environment(label, mem, manager, contexts, cmq, executor,
                                  binding, pd, cq);
      request = make_request({label, "_request"}, binding, pd, cq,
                             RDMA_TRANSPORT_RC);
      executor.create_locked(binding, binding.make_handle(), request,
                             320 + failure_ordinal, qp, result);
      expect_definitive_create_rollback(label, manager, mem, qp, result,
                                        RDMA_SC_DMA_TRANSLATION);
      if (cmq.calls.size() != 0)
        `uvm_error({label, "_NO_CMQ"}, "host write failure reached QPC_CREATE")
    end
  endtask

  task automatic check_context_codec_and_attach_failures();
    for (int unsigned failure_kind = 0; failure_kind < 4; failure_kind++) begin
      string label;
      rdma_mock_host_mem mem;
      rdma_qp_fault_manager manager;
      rdma_mock_context_backing contexts;
      rdma_mock_cmq_port cmq;
      rdma_qp_lifecycle_executor executor;
      rdma_qp_codec_fault_executor codec_executor;
      rdma_function_binding binding;
      rdma_pd pd;
      rdma_cq cq;
      rdma_create_qp_req request;
      rdma_qp qp;
      rdma_control_result result;
      rdma_status injected;
      rdma_status_code_e expected;

      label = $sformatf("CREATE_LOCAL_%0d", failure_kind);
      mem = rdma_mock_host_mem::type_id::create({label, "_mem"});
      manager = rdma_qp_fault_manager::type_id::create({label, "_manager"});
      contexts = rdma_mock_context_backing::type_id::create({label, "_contexts"});
      cmq = rdma_mock_cmq_port::type_id::create({label, "_cmq"});
      if (failure_kind == 2) begin
        codec_executor = rdma_qp_codec_fault_executor::type_id::create(
          {label, "_executor"});
        executor = codec_executor;
      end else
        executor = rdma_qp_lifecycle_executor::type_id::create(
          {label, "_executor"});
      setup_custom_qp_environment(label, mem, manager, contexts, cmq, executor,
                                  binding, pd, cq);
      injected = rdma_status::make(RDMA_SC_DMA_TRANSLATION,
                                   "injected local QP failure");
      expected = RDMA_SC_DMA_TRANSLATION;
      case (failure_kind)
        0: expect_ok({label, "_INJECT"}, contexts.fail_next("acquire", injected));
        1: expect_ok({label, "_INJECT"}, contexts.fail_next("write", injected));
        2: begin
          codec_executor.remove_qpc_codecs();
          expected = RDMA_SC_UNSUPPORTED_OPCODE;
        end
        3: manager.attach_failure = injected;
      endcase
      request = make_request({label, "_request"}, binding, pd, cq,
                             RDMA_TRANSPORT_RC);
      executor.create_locked(binding, binding.make_handle(), request,
                             340 + failure_kind, qp, result);
      expect_definitive_create_rollback(label, manager, mem, qp, result,
                                        expected);
      if (cmq.calls.size() != 0 || contexts.release_call_count > 1)
        `uvm_error({label, "_ORDER"},
          "local failure submitted CMQ or released context more than once")
    end
  endtask

  task automatic check_definitive_cmq_and_activation_failures();
    rdma_xtr_v1_occ_flush_body malformed_zero_qpn;
    malformed_zero_qpn = rdma_xtr_v1_occ_flush_body::type_id::create(
      "CREATE_MALFORMED_ZERO_QPN");
    malformed_zero_qpn.eirqe = 1'b1;
    malformed_zero_qpn.orqe = 1'b1;
    expect_code("CREATE_MALFORMED_ZERO_QPN",
                malformed_zero_qpn.validate(), RDMA_SC_INVALID_ARGUMENT);
    for (int unsigned failure_kind = 0; failure_kind < 3; failure_kind++) begin
      string label;
      rdma_mock_host_mem mem;
      rdma_qp_fault_manager manager;
      rdma_mock_context_backing contexts;
      rdma_mock_cmq_port cmq;
      rdma_qp_output_fault_cmq output_cmq;
      rdma_qp_lifecycle_executor executor;
      rdma_function_binding binding;
      rdma_pd pd;
      rdma_cq cq;
      rdma_create_qp_req request;
      rdma_qp qp;
      rdma_control_result result;
      bit [7:0] opcodes[$];

      label = $sformatf("CREATE_DEFINITIVE_%0d", failure_kind);
      mem = rdma_mock_host_mem::type_id::create({label, "_mem"});
      manager = rdma_qp_fault_manager::type_id::create({label, "_manager"});
      contexts = rdma_mock_context_backing::type_id::create({label, "_contexts"});
      if (failure_kind == 1) begin
        output_cmq = rdma_qp_output_fault_cmq::type_id::create({label, "_cmq"});
        output_cmq.definitive_no_submit = 1'b1;
        cmq = output_cmq;
      end else
        cmq = rdma_mock_cmq_port::type_id::create({label, "_cmq"});
      executor = rdma_qp_lifecycle_executor::type_id::create({label, "_executor"});
      setup_custom_qp_environment(label, mem, manager, contexts, cmq, executor,
                                  binding, pd, cq);
      if (failure_kind == 0)
        cmq.fail_opcode(XTR_V1_OP_QPC_CREATE,
          rdma_status::make(RDMA_SC_DMA_TRANSLATION,
                            "injected terminal QPC_CREATE failure"));
      if (failure_kind == 2)
        manager.activate_failure = rdma_status::make(
          RDMA_SC_INVALID_STATE, "injected QP activation failure");
      request = make_request({label, "_request"}, binding, pd, cq,
                             RDMA_TRANSPORT_RC);
      executor.create_locked(binding, binding.make_handle(), request,
                             360 + failure_kind, qp, result);
      expect_definitive_create_rollback(label, manager, mem, qp, result,
        failure_kind == 0 ? RDMA_SC_DMA_TRANSLATION :
        failure_kind == 1 ? RDMA_SC_INVALID_ARGUMENT : RDMA_SC_INVALID_STATE);
      cmq.get_opcodes(opcodes);
      if (failure_kind == 2) begin
        bit [7:0] expected[$];
        rdma_xtr_v1_occ_flush_body qpn_flush;
        expected.push_back(XTR_V1_OP_QPC_CREATE);
        expected.push_back(XTR_V1_OP_OCC_FLUSH);
        expected.push_back(XTR_V1_OP_OCC_FLUSH);
        expected.push_back(XTR_V1_OP_OCC_FLUSH);
        expected.push_back(XTR_V1_OP_QPC_DELETE);
        if (opcodes != expected)
          `uvm_error({label, "_DESTROY_RECIPE"},
                     $sformatf("unexpected activation rollback: %p", opcodes))
        if (cmq.calls.size() < 2 || cmq.calls[1] == null ||
            cmq.calls[1].command == null ||
            !$cast(qpn_flush, cmq.calls[1].command.body) ||
            qpn_flush == null || qpn_flush.qpn != 0 ||
            !qpn_flush.eirqe || !qpn_flush.orqe || !qpn_flush.uaqe ||
            qpn_flush.vf_flush || qpn_flush.mr_serial_flush ||
            qpn_flush.qpc || qpn_flush.cqc || qpn_flush.mrt ||
            qpn_flush.pble || qpn_flush.sqrqe || qpn_flush.sgb_irqe ||
            qpn_flush.pd || qpn_flush.mr_serial != 0 ||
            qpn_flush.pd_backing.value != 0)
          `uvm_error({label, "_QPN_ZERO_PATTERN"},
            "activation rollback did not issue the exact QPN-zero cache flush")
      end else if (opcodes.size() != (failure_kind == 0 ? 1 : 0))
        `uvm_error({label, "_CMQ_COUNT"},
                   "terminal/no-submit CMQ evidence was not preserved")
    end
  endtask

  task automatic check_stale_forged_recovery_rejected();
    rdma_mock_host_mem mem;
    rdma_qp_fault_manager manager;
    rdma_mock_context_backing contexts;
    rdma_mock_cmq_port cmq;
    rdma_qp_lifecycle_executor executor;
    rdma_function_binding binding;
    rdma_pd pd;
    rdma_cq cq;
    rdma_create_qp_req request;
    rdma_qp qp;
    rdma_control_result result;
    rdma_qp_recovery_state recovery;
    rdma_resource resource;
    rdma_resource_state_e raw_state;
    rdma_status status;

    mem = rdma_mock_host_mem::type_id::create("STALE_FORGED_mem");
    manager = rdma_qp_fault_manager::type_id::create("STALE_FORGED_manager");
    contexts = rdma_mock_context_backing::type_id::create(
      "STALE_FORGED_contexts");
    cmq = rdma_mock_cmq_port::type_id::create("STALE_FORGED_cmq");
    executor = rdma_qp_lifecycle_executor::type_id::create(
      "STALE_FORGED_executor");
    setup_custom_qp_environment("STALE_FORGED", mem, manager, contexts, cmq,
                                executor, binding, pd, cq);
    request = make_request("STALE_FORGED_request", binding, pd, cq,
                           RDMA_TRANSPORT_RC);
    executor.create_locked(binding, binding.make_handle(), request, 399,
                           qp, result);
    if (result == null || !result.ok() || qp == null || cmq.calls.size() != 1)
      return;

    recovery = rdma_qp_recovery_state::type_id::create(
      "STALE_FORGED_recovery");
    recovery.intent = RDMA_QP_RECOVER_CREATE_ROLLBACK;
    recovery.ambiguous_operation = RDMA_QP_AMBIG_CREATE;
    recovery.candidate_qpc = qp.programmed_qpc;
    recovery.qp_plan = qp.qp_plan;
    recovery.context_ref = qp.qp_plan.context_ref;
    recovery.create_opcode = rdma_cmq_opcode_key::type_id::create(
      "STALE_FORGED_create");
    recovery.modify_opcode = rdma_cmq_opcode_key::type_id::create(
      "STALE_FORGED_modify");
    recovery.delete_opcode = rdma_cmq_opcode_key::type_id::create(
      "STALE_FORGED_delete");
    recovery.query_opcode = rdma_cmq_opcode_key::type_id::create(
      "STALE_FORGED_query");
    recovery.occ_opcode = rdma_cmq_opcode_key::type_id::create(
      "STALE_FORGED_occ");
    recovery.create_opcode.profile_name = "xtr_v1";
    recovery.create_opcode.opcode = XTR_V1_OP_QPC_CREATE;
    recovery.create_opcode.variant = "create";
    recovery.modify_opcode.profile_name = "xtr_v1";
    recovery.modify_opcode.opcode = XTR_V1_OP_QPC_MODIFY;
    recovery.modify_opcode.variant = "modify";
    recovery.delete_opcode.profile_name = "xtr_v1";
    recovery.delete_opcode.opcode = XTR_V1_OP_QPC_DELETE;
    recovery.delete_opcode.variant = "delete";
    recovery.query_opcode.profile_name = "xtr_v1";
    recovery.query_opcode.opcode = XTR_V1_OP_QPC_QUERY;
    recovery.query_opcode.variant = "query";
    recovery.occ_opcode.profile_name = "xtr_v1";
    recovery.occ_opcode.opcode = XTR_V1_OP_OCC_FLUSH;
    recovery.occ_opcode.variant = "occ_flush";
    recovery.ambiguous_ticket = rdma_cmq_clone_ticket_value(
      cmq.calls[0].ticket, "STALE_FORGED");
    recovery.ambiguous_ticket.opcode_key.opcode = XTR_V1_OP_QPC_DELETE;
    recovery.ambiguous_ticket.opcode_key.variant = "delete";

    binding.generation++;
    binding.owner_h = binding.make_handle();
    expect_code("STALE_FORGED_PUBLIC_LOOKUP",
                manager.lookup(qp.handle, resource),
                RDMA_SC_STALE_GENERATION);
    status = manager.mark_qp_error(qp.handle, recovery);
    if (status == null || status.ok())
      `uvm_error("STALE_FORGED_STATUS",
                 "forged stale recovery unexpectedly entered ERROR")
    expect_code("STALE_FORGED_PUBLIC_LOOKUP_AFTER",
                manager.lookup(qp.handle, resource),
                RDMA_SC_STALE_GENERATION);
    if (!manager.raw_qp_state(qp.handle, raw_state) ||
        raw_state != RDMA_RESOURCE_ACTIVE ||
        manager.raw_recovery_exists(qp.handle))
      `uvm_error("STALE_FORGED_AUTHORITY",
                 "forged stale recovery mutated authoritative QP state")

    recovery.ambiguous_operation = RDMA_QP_AMBIG_NONE;
    recovery.ambiguous_ticket = null;
    recovery.candidate_qpc.pkey ^= 16'h0001;
    status = manager.mark_qp_error(qp.handle, recovery);
    if (status == null || status.ok())
      `uvm_error("STALE_ORDINARY_STATUS",
        "ordinary stale recovery with a different QPC entered ERROR")
    if (!manager.raw_qp_state(qp.handle, raw_state) ||
        raw_state != RDMA_RESOURCE_ACTIVE ||
        manager.raw_recovery_exists(qp.handle))
      `uvm_error("STALE_ORDINARY_ATOMIC",
        "rejected ordinary stale recovery mutated authoritative QP state")
  endtask

  task automatic check_ambiguous_create_outcomes();
    for (int unsigned failure_kind = 0; failure_kind < 4; failure_kind++) begin
      string label;
      rdma_mock_host_mem mem;
      rdma_resource_manager manager;
      rdma_mock_context_backing contexts;
      rdma_qp_output_fault_cmq cmq;
      rdma_qp_lifecycle_executor executor;
      rdma_function_binding binding;
      rdma_pd pd;
      rdma_cq cq;
      rdma_create_qp_req request;
      rdma_qp qp;
      rdma_control_result result;
      rdma_resource resource;
      rdma_recovery_record recovery;
      rdma_status_code_e primary_code;

      label = $sformatf("CREATE_AMBIG_%0d", failure_kind);
      mem = rdma_mock_host_mem::type_id::create({label, "_mem"});
      manager = rdma_resource_manager::type_id::create({label, "_manager"});
      contexts = rdma_mock_context_backing::type_id::create({label, "_contexts"});
      cmq = rdma_qp_output_fault_cmq::type_id::create({label, "_cmq"});
      executor = rdma_qp_lifecycle_executor::type_id::create({label, "_executor"});
      setup_custom_qp_environment(label, mem, manager, contexts, cmq, executor,
                                  binding, pd, cq);
      case (failure_kind)
        0: begin cmq.timeout_opcode(XTR_V1_OP_QPC_CREATE); primary_code = RDMA_SC_TIMEOUT; end
        1: begin
          cmq.fail_opcode(XTR_V1_OP_QPC_CREATE,
            rdma_status::make(RDMA_SC_RESET_CANCELLED, "injected reset cancel"));
          primary_code = RDMA_SC_RESET_CANCELLED;
        end
        2: begin cmq.drop_ticket = 1'b1; primary_code = RDMA_SC_INVALID_STATE; end
        3: begin cmq.drop_completion = 1'b1; primary_code = RDMA_SC_INVALID_STATE; end
      endcase
      request = make_request({label, "_request"}, binding, pd, cq,
                             RDMA_TRANSPORT_RC);
      executor.create_locked(binding, binding.make_handle(), request,
                             380 + failure_kind, qp, result);
      expect_code({label, "_STATUS"}, result == null ? null : result.status,
                  RDMA_SC_RECOVERY_REQUIRED);
      expect_code({label, "_PRIMARY"},
                  result == null ? null : result.primary_status, primary_code);
      if (qp != null || result == null || result.resource_h == null ||
          !result.recovery_required || !result.final_resource_state_known ||
          result.final_resource_state != RDMA_RESOURCE_ERROR ||
          mem.live_allocations() != 5)
        `uvm_error({label, "_RESULT"},
          "ambiguous create did not retain ERROR authority and staging")
      if (result != null && result.resource_h != null) begin
        expect_ok({label, "_LOOKUP"}, manager.lookup(result.resource_h, resource));
        expect_ok({label, "_RECOVERY"},
                  manager.lookup_recovery(result.resource_h, recovery));
        if (resource == null || resource.state != RDMA_RESOURCE_ERROR ||
            recovery == null || !recovery.qp_recovery_valid ||
            recovery.qp_recovery == null ||
            recovery.hardware_presence != RDMA_HW_PRESENCE_UNKNOWN ||
            recovery.qp_recovery.ambiguous_operation != RDMA_QP_AMBIG_CREATE ||
            recovery.qp_recovery.ambiguous_ticket == null ||
            recovery.qp_recovery.staging_mapping == null)
          `uvm_error({label, "_AUTHORITY"},
            "ERROR publication lost create ticket/staging authority")
      end
    end
  endtask

  task automatic check_create_generation_fences();
    rdma_mock_host_mem mem;
    rdma_resource_manager manager;
    rdma_mock_context_backing contexts;
    rdma_qp_output_fault_cmq cmq;
    rdma_qp_lifecycle_executor executor;
    rdma_function_binding binding;
    rdma_function_handle expected_owner;
    rdma_pd pd;
    rdma_cq cq;
    rdma_create_qp_req request;
    rdma_qp qp;
    rdma_control_result result;
    bit gate_observed;

    mem = rdma_mock_host_mem::type_id::create("CREATE_FENCE_mem");
    manager = rdma_resource_manager::type_id::create("CREATE_FENCE_manager");
    contexts = rdma_mock_context_backing::type_id::create("CREATE_FENCE_contexts");
    cmq = rdma_qp_output_fault_cmq::type_id::create("CREATE_FENCE_cmq");
    executor = rdma_qp_lifecycle_executor::type_id::create("CREATE_FENCE_executor");
    setup_custom_qp_environment("CREATE_FENCE", mem, manager, contexts, cmq,
                                executor, binding, pd, cq);
    request = make_request("CREATE_FENCE_request", binding, pd, cq,
                           RDMA_TRANSPORT_RC);
    expected_owner = binding.make_handle();
    binding.generation++;
    binding.owner_h = binding.make_handle();
    executor.create_locked(binding, expected_owner, request, 400, qp, result);
    expect_code("CREATE_FENCE_PRE_STATUS", result.status,
                RDMA_SC_STALE_GENERATION);
    if (qp != null || result.resource_h != null || cmq.calls.size() != 0 ||
        mem.live_allocations() != 0)
      `uvm_error("CREATE_FENCE_PRE_SIDE_EFFECT",
                 "pre-create stale generation had side effects")

    binding.generation--;
    binding.owner_h = binding.make_handle();
    request.owner = binding.make_handle();
    cmq.pause_cmq_opcode(XTR_V1_OP_QPC_CREATE);
    fork
      begin
        executor.create_locked(binding, binding.make_handle(), request, 401,
                               qp, result);
      end
      begin
        cmq.wait_until_entered(1, 20ns, gate_observed);
        binding.generation++;
        binding.owner_h = binding.make_handle();
        cmq.release_cmq_opcode(XTR_V1_OP_QPC_CREATE);
      end
    join
    if (!gate_observed)
      `uvm_error("CREATE_FENCE_GATE_ENTER",
                 "QPC_CREATE never reached the held CMQ gate")
    expect_code("CREATE_FENCE_GATE_STATUS", result.status,
                RDMA_SC_RECOVERY_REQUIRED);
    expect_code("CREATE_FENCE_GATE_PRIMARY", result.primary_status,
                RDMA_SC_STALE_GENERATION);
    if (qp != null || result.resource_h == null || !result.recovery_required ||
        cmq.calls.size() != 1)
      `uvm_error("CREATE_FENCE_GATE_AUTHORITY",
                 "held-gate rebind did not retain old create authority")
  endtask

  task automatic check_immediate_adapter_generation_boundaries();
    string host_modes[$];
    string context_modes[$];

    host_modes.push_back("rebind_allocate");
    host_modes.push_back("rebind_pd_write");
    host_modes.push_back("rebind_staging_allocate");
    host_modes.push_back("rebind_staging_write");
    foreach (host_modes[i]) begin
      string label;
      rdma_qp_boundary_host_mem mem;
      rdma_qp_fault_manager manager;
      rdma_qp_boundary_context_backing contexts;
      rdma_mock_cmq_port cmq;
      rdma_qp_lifecycle_executor executor;
      rdma_function_binding binding;
      rdma_pd pd;
      rdma_cq cq;
      rdma_create_qp_req request;
      rdma_qp qp;
      rdma_control_result result;

      label = {"CREATE_BOUNDARY_", host_modes[i]};
      mem = rdma_qp_boundary_host_mem::type_id::create({label, "_mem"});
      manager = rdma_qp_fault_manager::type_id::create({label, "_manager"});
      contexts = rdma_qp_boundary_context_backing::type_id::create(
        {label, "_contexts"}
      );
      cmq = rdma_mock_cmq_port::type_id::create({label, "_cmq"});
      executor = rdma_qp_lifecycle_executor::type_id::create(
        {label, "_executor"}
      );
      setup_custom_qp_environment(label, mem, manager, contexts, cmq, executor,
                                  binding, pd, cq);
      mem.binding_target = binding;
      mem.mode = host_modes[i];
      request = make_request({label, "_request"}, binding, pd, cq,
                             RDMA_TRANSPORT_RC);
      executor.create_locked(binding, binding.make_handle(), request,
                             410 + i, qp, result);
      expect_code({label, "_PRIMARY"},
                  result == null ? null : result.primary_status,
                  RDMA_SC_STALE_GENERATION);
      if (!mem.rebound || mem.unauthorized_effect || qp != null ||
          cmq.calls.size() != 0)
        `uvm_error(label,
          "generation change permitted a later unauthorized adapter/CMQ effect")
      case (host_modes[i])
        "rebind_allocate":
          if (mem.allocate_count != 1 || contexts.acquire_count != 0)
            `uvm_error(label, "allocation boundary did not stop immediately")
        "rebind_pd_write":
          if (mem.write_count != 2 || contexts.acquire_count != 0)
            `uvm_error(label, "PD-write boundary did not stop immediately")
        "rebind_staging_allocate":
          if (mem.write_count != 4 || contexts.write_count != 0)
            `uvm_error(label, "staging-allocation boundary allowed a write")
        "rebind_staging_write":
          if (mem.write_count != 5 || contexts.write_count != 0)
            `uvm_error(label, "staging-write boundary allowed a context write")
        default:;
      endcase
    end

    context_modes.push_back("rebind_context_acquire");
    context_modes.push_back("rebind_context_write");
    foreach (context_modes[i]) begin
      string label;
      rdma_qp_boundary_host_mem mem;
      rdma_qp_fault_manager manager;
      rdma_qp_boundary_context_backing contexts;
      rdma_mock_cmq_port cmq;
      rdma_qp_lifecycle_executor executor;
      rdma_function_binding binding;
      rdma_pd pd;
      rdma_cq cq;
      rdma_create_qp_req request;
      rdma_qp qp;
      rdma_control_result result;

      label = {"CREATE_BOUNDARY_", context_modes[i]};
      mem = rdma_qp_boundary_host_mem::type_id::create({label, "_mem"});
      manager = rdma_qp_fault_manager::type_id::create({label, "_manager"});
      contexts = rdma_qp_boundary_context_backing::type_id::create(
        {label, "_contexts"}
      );
      cmq = rdma_mock_cmq_port::type_id::create({label, "_cmq"});
      executor = rdma_qp_lifecycle_executor::type_id::create(
        {label, "_executor"}
      );
      setup_custom_qp_environment(label, mem, manager, contexts, cmq, executor,
                                  binding, pd, cq);
      contexts.binding_target = binding;
      contexts.mode = context_modes[i];
      request = make_request({label, "_request"}, binding, pd, cq,
                             RDMA_TRANSPORT_RC);
      executor.create_locked(binding, binding.make_handle(), request,
                             420 + i, qp, result);
      expect_code({label, "_PRIMARY"},
                  result == null ? null : result.primary_status,
                  RDMA_SC_STALE_GENERATION);
      if (!contexts.rebound || contexts.unauthorized_effect || qp != null ||
          cmq.calls.size() != 0)
        `uvm_error(label,
          "generation change permitted a later context/CMQ effect")
      if (context_modes[i] == "rebind_context_acquire" &&
          (contexts.acquire_count != 1 || contexts.write_count != 0))
        `uvm_error(label, "context-acquire boundary allowed a context write")
      if (context_modes[i] == "rebind_context_write" &&
          contexts.write_count != 1)
        `uvm_error(label, "context-write boundary was not fenced")
    end
  endtask

  task automatic check_local_timeout_authority_retained();
    string modes[$];

    modes.push_back("timeout_context_acquire_after");
    modes.push_back("timeout_context_write_after");
    modes.push_back("timeout_staging_allocate_after");
    modes.push_back("timeout_staging_write_after");
    foreach (modes[i]) begin
      string label;
      rdma_qp_boundary_host_mem mem;
      rdma_qp_fault_manager manager;
      rdma_qp_boundary_context_backing contexts;
      rdma_mock_cmq_port cmq;
      rdma_qp_lifecycle_executor executor;
      rdma_function_binding binding;
      rdma_pd pd;
      rdma_cq cq;
      rdma_create_qp_req request;
      rdma_qp qp;
      rdma_control_result result;
      rdma_recovery_record recovery;
      rdma_resource_state_e raw_state;
      bit expect_staging;

      label = {"CREATE_LOCAL_TIMEOUT_", modes[i]};
      mem = rdma_qp_boundary_host_mem::type_id::create({label, "_mem"});
      manager = rdma_qp_fault_manager::type_id::create({label, "_manager"});
      contexts = rdma_qp_boundary_context_backing::type_id::create(
        {label, "_contexts"}
      );
      cmq = rdma_mock_cmq_port::type_id::create({label, "_cmq"});
      executor = rdma_qp_lifecycle_executor::type_id::create(
        {label, "_executor"}
      );
      setup_custom_qp_environment(label, mem, manager, contexts, cmq, executor,
                                  binding, pd, cq);
      if (modes[i] inside {"timeout_context_acquire_after",
                           "timeout_context_write_after"})
        contexts.mode = modes[i];
      else
        mem.mode = modes[i];
      request = make_request({label, "_request"}, binding, pd, cq,
                             RDMA_TRANSPORT_RC);
      executor.create_locked(binding, binding.make_handle(), request,
                             430 + i, qp, result);
      expect_staging = modes[i] != "timeout_context_acquire_after";
      expect_code({label, "_STATUS"}, result == null ? null : result.status,
                  RDMA_SC_RECOVERY_REQUIRED);
      expect_code({label, "_PRIMARY"},
                  result == null ? null : result.primary_status,
                  RDMA_SC_TIMEOUT);
      if (result == null || result.resource_h == null || qp != null ||
          !result.recovery_required || cmq.calls.size() != 0 ||
          !manager.raw_qp_state(result.resource_h, raw_state) ||
          raw_state != RDMA_RESOURCE_ERROR ||
          !manager.raw_recovery(result.resource_h, recovery) ||
          recovery == null || recovery.hardware_presence != RDMA_HW_PRESENCE_ABSENT ||
          recovery.qp_recovery == null ||
          recovery.qp_recovery.ambiguous_operation != RDMA_QP_AMBIG_NONE ||
          recovery.qp_recovery.ambiguous_ticket != null ||
          recovery.qp_recovery.candidate_qpc != null ||
          recovery.qp_recovery.context_ref == null ||
          recovery.qp_recovery.context_ref.release_complete ||
          ((recovery.qp_recovery.staging_mapping != null) != expect_staging) ||
          mem.live_allocations() != (expect_staging ? 5 : 4))
        `uvm_error(label,
          "timeout-after-effect lost durable pre-CMQ recovery authority")
    end
  endtask

  task automatic check_staging_release_completion_and_rebind();
    string timeout_modes[$];

    timeout_modes.push_back("complete_staging_before_cleanup");
    timeout_modes.push_back("timeout_staging_release_before");
    timeout_modes.push_back("timeout_staging_release_after");
    foreach (timeout_modes[i]) begin
      string label;
      rdma_qp_boundary_host_mem mem;
      rdma_qp_fault_manager manager;
      rdma_qp_boundary_context_backing contexts;
      rdma_mock_cmq_port cmq;
      rdma_qp_lifecycle_executor executor;
      rdma_function_binding binding;
      rdma_pd pd;
      rdma_cq cq;
      rdma_create_qp_req request;
      rdma_qp qp;
      rdma_control_result result;
      rdma_recovery_record recovery;
      bit release_complete;
      int unsigned staging_release_calls;
      rdma_status query_status;

      label = {"CREATE_STAGING_RELEASE_", timeout_modes[i]};
      mem = rdma_qp_boundary_host_mem::type_id::create({label, "_mem"});
      manager = rdma_qp_fault_manager::type_id::create({label, "_manager"});
      contexts = rdma_qp_boundary_context_backing::type_id::create(
        {label, "_contexts"}
      );
      cmq = rdma_mock_cmq_port::type_id::create({label, "_cmq"});
      executor = rdma_qp_lifecycle_executor::type_id::create(
        {label, "_executor"}
      );
      setup_custom_qp_environment(label, mem, manager, contexts, cmq, executor,
                                  binding, pd, cq);
      mem.mode = timeout_modes[i];
      request = make_request({label, "_request"}, binding, pd, cq,
                             RDMA_TRANSPORT_RC);
      executor.create_locked(binding, binding.make_handle(), request,
                             440 + i, qp, result);
      staging_release_calls = 0;
      foreach (mem.calls[j])
        if (mem.calls[j] != null &&
            mem.calls[j].method_name == "release" &&
            mem.calls[j].mapping != null &&
            mem.calls[j].mapping.size == 512)
          staging_release_calls++;
      if (timeout_modes[i] inside {
            "complete_staging_before_cleanup",
            "timeout_staging_release_after"
          }) begin
        if (result == null || !result.ok() || qp == null ||
            result.recovery_required || mem.live_allocations() != 4 ||
            manager.raw_recovery_exists(result.resource_h) ||
            staging_release_calls != 1)
          `uvm_error(label,
            "opaque completed staging release retried or blocked activation")
      end else begin
        expect_code({label, "_STATUS"}, result == null ? null : result.status,
                    RDMA_SC_RECOVERY_REQUIRED);
        release_complete = 1'b1;
        query_status = null;
        if (result != null && result.resource_h != null &&
            manager.raw_recovery(result.resource_h, recovery) &&
            recovery != null && recovery.qp_recovery != null &&
            recovery.qp_recovery.staging_mapping != null)
          query_status = recovery.qp_recovery.staging_mapping.
            release_completion_status(release_complete);
        if (qp != null || recovery == null || recovery.qp_recovery == null ||
            recovery.qp_recovery.staging_mapping == null ||
            query_status == null || !query_status.ok() || release_complete ||
            mem.live_allocations() != 5 || staging_release_calls != 1)
          `uvm_error(label,
            "pending staging release was retried or lost opaque authority")
      end
    end

    begin
      string label;
      rdma_qp_boundary_host_mem mem;
      rdma_qp_fault_manager manager;
      rdma_qp_boundary_context_backing contexts;
      rdma_mock_cmq_port cmq;
      rdma_qp_lifecycle_executor executor;
      rdma_function_binding binding;
      rdma_pd pd;
      rdma_cq cq;
      rdma_create_qp_req request;
      rdma_qp qp;
      rdma_control_result result;
      rdma_recovery_record recovery;
      rdma_resource_state_e raw_state;

      label = "CREATE_STAGING_RELEASE_REBIND";
      mem = rdma_qp_boundary_host_mem::type_id::create({label, "_mem"});
      manager = rdma_qp_fault_manager::type_id::create({label, "_manager"});
      contexts = rdma_qp_boundary_context_backing::type_id::create(
        {label, "_contexts"}
      );
      cmq = rdma_mock_cmq_port::type_id::create({label, "_cmq"});
      executor = rdma_qp_lifecycle_executor::type_id::create(
        {label, "_executor"}
      );
      setup_custom_qp_environment(label, mem, manager, contexts, cmq, executor,
                                  binding, pd, cq);
      mem.binding_target = binding;
      mem.mode = "rebind_staging_release";
      request = make_request({label, "_request"}, binding, pd, cq,
                             RDMA_TRANSPORT_RC);
      executor.create_locked(binding, binding.make_handle(), request, 449,
                             qp, result);
      expect_code({label, "_STATUS"}, result == null ? null : result.status,
                  RDMA_SC_RECOVERY_REQUIRED);
      expect_code({label, "_PRIMARY"},
                  result == null ? null : result.primary_status,
                  RDMA_SC_STALE_GENERATION);
      if (!mem.rebound || qp != null || result == null ||
          result.resource_h == null ||
          !manager.raw_qp_state(result.resource_h, raw_state) ||
          raw_state != RDMA_RESOURCE_ERROR ||
          !manager.raw_recovery(result.resource_h, recovery) ||
          recovery == null || recovery.hardware_presence != RDMA_HW_PRESENCE_PRESENT ||
          recovery.qp_recovery == null ||
          recovery.qp_recovery.ambiguous_operation != RDMA_QP_AMBIG_NONE ||
          recovery.qp_recovery.ambiguous_ticket != null ||
          recovery.qp_recovery.candidate_qpc == null ||
          recovery.qp_recovery.staging_mapping != null)
        `uvm_error(label,
          "successful old-generation staging release lost known-present recovery")
    end
  endtask

  task automatic check_context_release_completion();
    string modes[$];

    modes.push_back("timeout_context_release_before");
    modes.push_back("timeout_context_release_after");
    foreach (modes[i]) begin
      string label;
      rdma_qp_boundary_host_mem mem;
      rdma_qp_fault_manager manager;
      rdma_qp_boundary_context_backing contexts;
      rdma_mock_cmq_port cmq;
      rdma_qp_lifecycle_executor executor;
      rdma_function_binding binding;
      rdma_pd pd;
      rdma_cq cq;
      rdma_create_qp_req request;
      rdma_qp qp;
      rdma_control_result result;
      rdma_recovery_record recovery;
      bit complete;
      rdma_status query_status;

      label = {"CREATE_CONTEXT_RELEASE_", modes[i]};
      mem = rdma_qp_boundary_host_mem::type_id::create({label, "_mem"});
      manager = rdma_qp_fault_manager::type_id::create({label, "_manager"});
      manager.activate_failure = rdma_status::make(
        RDMA_SC_INVALID_STATE, "injected activation failure"
      );
      contexts = rdma_qp_boundary_context_backing::type_id::create(
        {label, "_contexts"}
      );
      contexts.mode = modes[i];
      cmq = rdma_mock_cmq_port::type_id::create({label, "_cmq"});
      executor = rdma_qp_lifecycle_executor::type_id::create(
        {label, "_executor"}
      );
      setup_custom_qp_environment(label, mem, manager, contexts, cmq, executor,
                                  binding, pd, cq);
      request = make_request({label, "_request"}, binding, pd, cq,
                             RDMA_TRANSPORT_RC);
      executor.create_locked(binding, binding.make_handle(), request,
                             450 + i, qp, result);
      expect_code({label, "_PRIMARY"},
                  result == null ? null : result.primary_status,
                  RDMA_SC_INVALID_STATE);
      if (modes[i] == "timeout_context_release_after") begin
        if (qp != null || result == null || result.recovery_required ||
            !result.final_resource_state_known ||
            result.final_resource_state != RDMA_RESOURCE_RELEASED ||
            mem.live_allocations() != 0 ||
            manager.raw_recovery_exists(result.resource_h))
          `uvm_error(label,
            "opaque completed context release did not finish rollback")
      end else begin
        complete = 1'b1;
        query_status = null;
        if (result != null && result.resource_h != null &&
            manager.raw_recovery(result.resource_h, recovery) &&
            recovery != null && recovery.qp_recovery != null &&
            recovery.qp_recovery.context_ref != null)
          query_status = contexts.query_release_completion(
            recovery.qp_recovery.context_ref, complete
          );
        if (result == null || result.status == null ||
            result.status.code != RDMA_SC_RECOVERY_REQUIRED ||
            !result.recovery_required || recovery == null ||
            recovery.qp_recovery == null || query_status == null ||
            !query_status.ok() || complete || mem.live_allocations() != 4)
          `uvm_error(label,
            "pending context release did not retain rollback authority")
      end
    end
  endtask

  task automatic check_activation_rebind_recovery();
    string label;
    rdma_qp_boundary_host_mem mem;
    rdma_qp_activation_rebind_manager manager;
    rdma_qp_boundary_context_backing contexts;
    rdma_mock_cmq_port cmq;
    rdma_qp_lifecycle_executor executor;
    rdma_function_binding binding;
    rdma_pd pd;
    rdma_cq cq;
    rdma_create_qp_req request;
    rdma_qp qp;
    rdma_control_result result;
    rdma_recovery_record recovery;
    rdma_resource_state_e raw_state;

    label = "CREATE_ACTIVATE_REBIND";
    mem = rdma_qp_boundary_host_mem::type_id::create({label, "_mem"});
    manager = rdma_qp_activation_rebind_manager::type_id::create(
      {label, "_manager"}
    );
    contexts = rdma_qp_boundary_context_backing::type_id::create(
      {label, "_contexts"}
    );
    cmq = rdma_mock_cmq_port::type_id::create({label, "_cmq"});
    executor = rdma_qp_lifecycle_executor::type_id::create({label, "_executor"});
    setup_custom_qp_environment(label, mem, manager, contexts, cmq, executor,
                                binding, pd, cq);
    manager.binding_target = binding;
    manager.rebind_after_activate = 1'b1;
    request = make_request({label, "_request"}, binding, pd, cq,
                           RDMA_TRANSPORT_RC);
    executor.create_locked(binding, binding.make_handle(), request, 460,
                           qp, result);
    expect_code({label, "_STATUS"}, result == null ? null : result.status,
                RDMA_SC_RECOVERY_REQUIRED);
    expect_code({label, "_PRIMARY"},
                result == null ? null : result.primary_status,
                RDMA_SC_STALE_GENERATION);
    if (qp != null || result == null || result.resource_h == null ||
        !manager.raw_qp_state(result.resource_h, raw_state) ||
        raw_state != RDMA_RESOURCE_ERROR ||
        !manager.raw_recovery(result.resource_h, recovery) ||
        recovery == null || recovery.hardware_presence != RDMA_HW_PRESENCE_PRESENT ||
        recovery.qp_recovery == null ||
        recovery.qp_recovery.ambiguous_operation != RDMA_QP_AMBIG_NONE ||
        recovery.qp_recovery.candidate_qpc == null ||
        recovery.qp_recovery.ambiguous_ticket != null)
      `uvm_error(label,
        "post-activation rebind did not retain exact old-generation authority")
  endtask

  task automatic check_activation_rollback_ambiguity();
    rdma_queue_backing_role_e roles[$];

    roles.push_back(RDMA_QUEUE_ROLE_QP_SQ_RING);
    roles.push_back(RDMA_QUEUE_ROLE_QP_SQ_PD);
    roles.push_back(RDMA_QUEUE_ROLE_QP_RQ_PD);
    foreach (roles[i]) begin
      string label;
      rdma_qp_boundary_host_mem mem;
      rdma_qp_fault_manager manager;
      rdma_qp_boundary_context_backing contexts;
      rdma_mock_cmq_port cmq;
      rdma_qp_lifecycle_executor executor;
      rdma_function_binding binding;
      rdma_pd pd;
      rdma_cq cq;
      rdma_create_qp_req request;
      rdma_qp qp;
      rdma_control_result result;
      rdma_recovery_record recovery;

      label = $sformatf("CREATE_OCC_AMBIG_%0d", i);
      mem = rdma_qp_boundary_host_mem::type_id::create({label, "_mem"});
      manager = rdma_qp_fault_manager::type_id::create({label, "_manager"});
      manager.activate_failure = rdma_status::make(
        RDMA_SC_INVALID_STATE, "injected activation failure"
      );
      contexts = rdma_qp_boundary_context_backing::type_id::create(
        {label, "_contexts"}
      );
      cmq = rdma_mock_cmq_port::type_id::create({label, "_cmq"});
      executor = rdma_qp_lifecycle_executor::type_id::create(
        {label, "_executor"}
      );
      setup_custom_qp_environment(label, mem, manager, contexts, cmq, executor,
                                  binding, pd, cq);
      for (int unsigned prior = 0; prior < i; prior++)
        cmq.fail_opcode(XTR_V1_OP_OCC_FLUSH, rdma_status::success());
      cmq.timeout_opcode(XTR_V1_OP_OCC_FLUSH);
      request = make_request({label, "_request"}, binding, pd, cq,
                             RDMA_TRANSPORT_RC);
      executor.create_locked(binding, binding.make_handle(), request,
                             470 + i, qp, result);
      if (result != null && result.resource_h != null)
        void'(manager.raw_recovery(result.resource_h, recovery));
      if (qp != null || result == null || result.status == null ||
          result.status.code != RDMA_SC_RECOVERY_REQUIRED ||
          !result.recovery_required || recovery == null ||
          recovery.qp_recovery == null ||
          recovery.qp_recovery.ambiguous_operation != RDMA_QP_AMBIG_OCC_FLUSH ||
          recovery.qp_recovery.ambiguous_role != roles[i] ||
          recovery.qp_recovery.ambiguous_ticket == null ||
          recovery.qp_recovery.ambiguous_ticket.command_id !=
            cmq.calls[i + 1].ticket.command_id ||
          recovery.qp_recovery.ambiguous_ticket.opcode_key == null ||
          recovery.qp_recovery.ambiguous_ticket.opcode_key.opcode !=
            XTR_V1_OP_OCC_FLUSH ||
          recovery.qp_recovery.role_complete[roles[i]] ||
          recovery.qp_recovery.role_complete[RDMA_QUEUE_ROLE_QP_SQ_RING] !=
            (i > 0) ||
          recovery.qp_recovery.role_complete[RDMA_QUEUE_ROLE_QP_SQ_PD] !=
            (i > 1) || cmq.calls.size() != i + 2)
        `uvm_error(label,
          "activation rollback lost exact OCC ambiguity role/ticket/progress")
    end

    for (int unsigned failure_kind = 0; failure_kind < 2; failure_kind++) begin
      string label;
      rdma_qp_boundary_host_mem mem;
      rdma_qp_fault_manager manager;
      rdma_qp_boundary_context_backing contexts;
      rdma_mock_cmq_port cmq;
      rdma_qp_lifecycle_executor executor;
      rdma_function_binding binding;
      rdma_pd pd;
      rdma_cq cq;
      rdma_create_qp_req request;
      rdma_qp qp;
      rdma_control_result result;
      rdma_recovery_record recovery;

      label = $sformatf("CREATE_DELETE_AMBIG_%0d", failure_kind);
      mem = rdma_qp_boundary_host_mem::type_id::create({label, "_mem"});
      manager = rdma_qp_fault_manager::type_id::create({label, "_manager"});
      manager.activate_failure = rdma_status::make(
        RDMA_SC_INVALID_STATE, "injected activation failure"
      );
      contexts = rdma_qp_boundary_context_backing::type_id::create(
        {label, "_contexts"}
      );
      cmq = rdma_mock_cmq_port::type_id::create({label, "_cmq"});
      executor = rdma_qp_lifecycle_executor::type_id::create(
        {label, "_executor"}
      );
      setup_custom_qp_environment(label, mem, manager, contexts, cmq, executor,
                                  binding, pd, cq);
      if (failure_kind == 0)
        cmq.timeout_opcode(XTR_V1_OP_QPC_DELETE);
      else
        cmq.fail_opcode(XTR_V1_OP_QPC_DELETE,
          rdma_status::make(RDMA_SC_RESET_CANCELLED,
                            "injected delete reset cancellation"));
      request = make_request({label, "_request"}, binding, pd, cq,
                             RDMA_TRANSPORT_RC);
      executor.create_locked(binding, binding.make_handle(), request,
                             480 + failure_kind, qp, result);
      if (result != null && result.resource_h != null)
        void'(manager.raw_recovery(result.resource_h, recovery));
      if (qp != null || result == null || result.status == null ||
          result.status.code != RDMA_SC_RECOVERY_REQUIRED ||
          !result.recovery_required || recovery == null ||
          recovery.qp_recovery == null ||
          recovery.qp_recovery.ambiguous_operation != RDMA_QP_AMBIG_DELETE ||
          recovery.qp_recovery.ambiguous_ticket == null ||
          recovery.qp_recovery.ambiguous_ticket.command_id !=
            cmq.calls[4].ticket.command_id ||
          recovery.qp_recovery.ambiguous_ticket.opcode_key == null ||
          recovery.qp_recovery.ambiguous_ticket.opcode_key.opcode !=
            XTR_V1_OP_QPC_DELETE ||
          !recovery.qp_recovery.role_complete[RDMA_QUEUE_ROLE_QP_SQ_RING] ||
          !recovery.qp_recovery.role_complete[RDMA_QUEUE_ROLE_QP_SQ_PD] ||
          !recovery.qp_recovery.role_complete[RDMA_QUEUE_ROLE_QP_RQ_PD] ||
          cmq.calls.size() != 5)
        `uvm_error(label,
          "activation rollback lost QPC_DELETE ambiguity ticket")
    end
  endtask

  task automatic check_pre_create_execute_generation_fence();
    string label;
    rdma_qp_boundary_host_mem mem;
    rdma_qp_fault_manager manager;
    rdma_qp_boundary_context_backing contexts;
    rdma_mock_cmq_port cmq;
    rdma_qp_lifecycle_executor executor;
    rdma_function_binding binding;
    rdma_function_handle old_owner;
    rdma_pd pd;
    rdma_cq cq;
    rdma_create_qp_req request;
    rdma_qp qp;
    rdma_control_result result;
    rdma_recovery_record recovery;
    rdma_resource_state_e raw_state;

    label = "CREATE_PRE_EXECUTE_REBIND";
    mem = rdma_qp_boundary_host_mem::type_id::create({label, "_mem"});
    manager = rdma_qp_fault_manager::type_id::create({label, "_manager"});
    contexts = rdma_qp_boundary_context_backing::type_id::create(
      {label, "_contexts"}
    );
    cmq = rdma_mock_cmq_port::type_id::create({label, "_cmq"});
    executor = rdma_qp_lifecycle_executor::type_id::create(
      {label, "_executor"}
    );
    setup_custom_qp_environment(label, mem, manager, contexts, cmq, executor,
                                binding, pd, cq);
    old_owner = binding.make_handle();
    manager.binding_target = binding;
    manager.rebind_after_attach = 1'b1;
    request = make_request({label, "_request"}, binding, pd, cq,
                           RDMA_TRANSPORT_RC);
    executor.create_locked(binding, old_owner, request, 490, qp, result);
    expect_code({label, "_STATUS"}, result == null ? null : result.status,
                RDMA_SC_RECOVERY_REQUIRED);
    expect_code({label, "_PRIMARY"},
                result == null ? null : result.primary_status,
                RDMA_SC_STALE_GENERATION);
    if (!manager.attach_rebound || qp != null || result == null ||
        result.resource_h == null || !result.recovery_required ||
        cmq.calls.size() != 0 || mem.unauthorized_effect ||
        contexts.unauthorized_effect ||
        !manager.raw_qp_state(result.resource_h, raw_state) ||
        raw_state != RDMA_RESOURCE_ERROR ||
        !manager.raw_recovery(result.resource_h, recovery) ||
        recovery == null || recovery.hardware_presence !=
          RDMA_HW_PRESENCE_ABSENT || recovery.qp_recovery == null ||
        recovery.qp_recovery.ambiguous_operation != RDMA_QP_AMBIG_NONE ||
        recovery.qp_recovery.ambiguous_ticket != null ||
        recovery.qp_recovery.candidate_qpc != null ||
        recovery.qp_recovery.staging_mapping == null ||
        recovery.qp_recovery.context_ref == null ||
        recovery.qp_recovery.context_ref.owner == null ||
        !recovery.qp_recovery.context_ref.owner.same_instance(old_owner) ||
        binding.make_handle().same_instance(old_owner))
      `uvm_error(label,
        "pre-QPC_CREATE fence submitted or lost exact-old recovery authority")
  endtask

  task automatic check_context_acquire_rebind_authority();
    string label;
    rdma_qp_boundary_host_mem mem;
    rdma_qp_fault_manager manager;
    rdma_qp_boundary_context_backing contexts;
    rdma_mock_cmq_port cmq;
    rdma_qp_lifecycle_executor executor;
    rdma_function_binding binding;
    rdma_function_handle old_owner;
    rdma_pd pd;
    rdma_cq cq;
    rdma_create_qp_req request;
    rdma_qp qp;
    rdma_control_result result;
    rdma_recovery_record recovery;
    rdma_resource_state_e raw_state;

    label = "CREATE_CONTEXT_ACQUIRE_REBIND_AUTHORITY";
    mem = rdma_qp_boundary_host_mem::type_id::create({label, "_mem"});
    manager = rdma_qp_fault_manager::type_id::create({label, "_manager"});
    contexts = rdma_qp_boundary_context_backing::type_id::create(
      {label, "_contexts"}
    );
    cmq = rdma_mock_cmq_port::type_id::create({label, "_cmq"});
    executor = rdma_qp_lifecycle_executor::type_id::create(
      {label, "_executor"}
    );
    setup_custom_qp_environment(label, mem, manager, contexts, cmq, executor,
                                binding, pd, cq);
    old_owner = binding.make_handle();
    contexts.binding_target = binding;
    contexts.mode = "rebind_context_acquire";
    request = make_request({label, "_request"}, binding, pd, cq,
                           RDMA_TRANSPORT_RC);
    executor.create_locked(binding, old_owner, request, 491, qp, result);
    expect_code({label, "_STATUS"}, result == null ? null : result.status,
                RDMA_SC_RECOVERY_REQUIRED);
    expect_code({label, "_PRIMARY"},
                result == null ? null : result.primary_status,
                RDMA_SC_STALE_GENERATION);
    if (!contexts.rebound || contexts.unauthorized_effect || qp != null ||
        result == null || result.resource_h == null ||
        !result.recovery_required || cmq.calls.size() != 0 ||
        contexts.slots.size() != 1 || contexts.slots[0] == null ||
        contexts.slots[0].released || mem.live_allocations() != 4 ||
        !manager.raw_qp_state(result.resource_h, raw_state) ||
        raw_state != RDMA_RESOURCE_ERROR ||
        !manager.raw_recovery(result.resource_h, recovery) ||
        recovery == null || recovery.hardware_presence !=
          RDMA_HW_PRESENCE_ABSENT || recovery.qp_recovery == null ||
        recovery.qp_recovery.ambiguous_operation != RDMA_QP_AMBIG_NONE ||
        recovery.qp_recovery.ambiguous_ticket != null ||
        recovery.qp_recovery.candidate_qpc != null ||
        recovery.qp_recovery.staging_mapping != null ||
        recovery.qp_recovery.context_ref == null ||
        recovery.qp_recovery.context_ref.owner == null ||
        !recovery.qp_recovery.context_ref.owner.same_instance(old_owner) ||
        recovery.qp_recovery.qp_plan == null ||
        recovery.qp_recovery.qp_plan.sq_ref == null ||
        recovery.qp_recovery.qp_plan.sq_ref.mapping == null ||
        recovery.qp_recovery.qp_plan.sq_ref.mapping.function_h == null ||
        !recovery.qp_recovery.qp_plan.sq_ref.mapping.function_h.
          same_instance(old_owner) || binding.make_handle().same_instance(old_owner))
      `uvm_error(label,
        "post-acquire rebind left bare stale or lost exact-old authority")
  endtask

  task automatic check_definitive_failure_staging_release_ambiguity();
    for (int unsigned failure_kind = 0; failure_kind < 3; failure_kind++) begin
      string label;
      rdma_qp_boundary_host_mem mem;
      rdma_qp_fault_manager manager;
      rdma_qp_boundary_context_backing contexts;
      rdma_mock_cmq_port cmq;
      rdma_qp_output_fault_cmq output_cmq;
      rdma_qp_lifecycle_executor executor;
      rdma_qp_command_fault_executor command_executor;
      rdma_function_binding binding;
      rdma_pd pd;
      rdma_cq cq;
      rdma_create_qp_req request;
      rdma_qp qp;
      rdma_control_result result;
      rdma_recovery_record recovery;
      rdma_resource_state_e raw_state;
      bit release_complete;
      rdma_status query_status;

      label = $sformatf("CREATE_DEFINITIVE_STAGING_AMBIG_%0d", failure_kind);
      mem = rdma_qp_boundary_host_mem::type_id::create({label, "_mem"});
      mem.mode = "timeout_staging_release_before";
      manager = rdma_qp_fault_manager::type_id::create({label, "_manager"});
      contexts = rdma_qp_boundary_context_backing::type_id::create(
        {label, "_contexts"}
      );
      if (failure_kind == 1) begin
        output_cmq = rdma_qp_output_fault_cmq::type_id::create(
          {label, "_cmq"}
        );
        output_cmq.definitive_no_submit = 1'b1;
        cmq = output_cmq;
      end else
        cmq = rdma_mock_cmq_port::type_id::create({label, "_cmq"});
      if (failure_kind == 2) begin
        command_executor = rdma_qp_command_fault_executor::type_id::create(
          {label, "_executor"}
        );
        command_executor.fail_create_command = 1'b1;
        executor = command_executor;
      end else
        executor = rdma_qp_lifecycle_executor::type_id::create(
          {label, "_executor"}
        );
      setup_custom_qp_environment(label, mem, manager, contexts, cmq, executor,
                                  binding, pd, cq);
      if (failure_kind == 0)
        cmq.fail_opcode(XTR_V1_OP_QPC_CREATE,
          rdma_status::make(RDMA_SC_DMA_TRANSLATION,
                            "injected terminal QPC_CREATE failure"));
      request = make_request({label, "_request"}, binding, pd, cq,
                             RDMA_TRANSPORT_RC);
      executor.create_locked(binding, binding.make_handle(), request,
                             492 + failure_kind, qp, result);
      expect_code({label, "_STATUS"}, result == null ? null : result.status,
                  RDMA_SC_RECOVERY_REQUIRED);
      expect_code({label, "_PRIMARY"},
                  result == null ? null : result.primary_status,
                  failure_kind == 0 ? RDMA_SC_DMA_TRANSLATION :
                                      RDMA_SC_INVALID_ARGUMENT);
      recovery = null;
      if (result != null && result.resource_h != null)
        void'(manager.raw_recovery(result.resource_h, recovery));
      release_complete = 1'b1;
      query_status = null;
      if (recovery != null && recovery.qp_recovery != null &&
          recovery.qp_recovery.staging_mapping != null)
        query_status = recovery.qp_recovery.staging_mapping.
          release_completion_status(release_complete);
      if (qp != null || result == null || result.resource_h == null ||
          !result.recovery_required ||
          !manager.raw_qp_state(result.resource_h, raw_state) ||
          raw_state != RDMA_RESOURCE_ERROR || recovery == null ||
          recovery.hardware_presence != RDMA_HW_PRESENCE_ABSENT ||
          recovery.qp_recovery == null ||
          recovery.qp_recovery.ambiguous_operation != RDMA_QP_AMBIG_NONE ||
          recovery.qp_recovery.ambiguous_ticket != null ||
          recovery.qp_recovery.candidate_qpc != null ||
          recovery.qp_recovery.staging_mapping == null ||
          query_status == null || !query_status.ok() || release_complete ||
          contexts.release_call_count != 0 || mem.live_allocations() != 5 ||
          cmq.calls.size() != (failure_kind == 0 ? 1 : 0))
        `uvm_error(label,
          "definitive failure lost pending staging/plan/context authority")
    end
  endtask

  task automatic check_direct_unattached_release_authority();
    for (int unsigned failure_kind = 0; failure_kind < 2; failure_kind++) begin
      string label;
      rdma_qp_boundary_host_mem mem;
      rdma_qp_fault_manager manager;
      rdma_qp_boundary_context_backing contexts;
      rdma_mock_cmq_port cmq;
      rdma_qp_lifecycle_executor executor;
      rdma_qp_codec_fault_executor codec_executor;
      rdma_function_binding binding;
      rdma_function_handle old_owner;
      rdma_pd pd;
      rdma_cq cq;
      rdma_create_qp_req request;
      rdma_qp qp;
      rdma_control_result result;
      rdma_recovery_record recovery;
      rdma_resource_state_e raw_state;
      rdma_dma_mapping pending_mapping;
      rdma_status query_status;
      bit release_complete;
      int unsigned release_calls;

      label = $sformatf("CREATE_DIRECT_UNATTACHED_%0d", failure_kind);
      mem = rdma_qp_boundary_host_mem::type_id::create({label, "_mem"});
      manager = rdma_qp_fault_manager::type_id::create({label, "_manager"});
      contexts = rdma_qp_boundary_context_backing::type_id::create(
        {label, "_contexts"}
      );
      cmq = rdma_mock_cmq_port::type_id::create({label, "_cmq"});
      if (failure_kind == 1) begin
        codec_executor = rdma_qp_codec_fault_executor::type_id::create(
          {label, "_executor"}
        );
        executor = codec_executor;
      end else
        executor = rdma_qp_lifecycle_executor::type_id::create(
          {label, "_executor"}
        );
      setup_custom_qp_environment(label, mem, manager, contexts, cmq, executor,
                                  binding, pd, cq);
      old_owner = binding.make_handle();
      mem.binding_target = binding;
      mem.mode = "timeout_plan_release_rebind_before";
      if (failure_kind == 0) begin
        manager.binding_target = binding;
        manager.rebind_on_sequence_failure = 1'b1;
        manager.sequence_failure = rdma_status::make(
          RDMA_SC_DMA_TRANSLATION, "injected QPC authority capture failure"
        );
      end else
        codec_executor.remove_qpc_codecs();
      request = make_request({label, "_request"}, binding, pd, cq,
                             RDMA_TRANSPORT_RC);
      executor.create_locked(binding, old_owner, request, 497 + failure_kind,
                             qp, result);
      expect_code({label, "_STATUS"}, result == null ? null : result.status,
                  RDMA_SC_RECOVERY_REQUIRED);
      expect_code({label, "_PRIMARY"},
                  result == null ? null : result.primary_status,
                  failure_kind == 0 ? RDMA_SC_DMA_TRANSLATION :
                                      RDMA_SC_UNSUPPORTED_OPCODE);
      recovery = null;
      if (result != null && result.resource_h != null)
        void'(manager.raw_recovery(result.resource_h, recovery));
      pending_mapping = recovery == null || recovery.qp_recovery == null ||
                        recovery.qp_recovery.qp_plan == null ||
                        recovery.qp_recovery.qp_plan.rq_pd_ref == null ? null :
                        recovery.qp_recovery.qp_plan.rq_pd_ref.mapping;
      release_complete = 1'b1;
      query_status = pending_mapping == null ? null :
        pending_mapping.release_completion_status(release_complete);
      release_calls = 0;
      foreach (mem.calls[i])
        if (mem.calls[i] != null && mem.calls[i].method_name == "release")
          release_calls++;
      if (qp != null || result == null || result.resource_h == null ||
          !result.recovery_required || !result.final_resource_state_known ||
          result.final_resource_state != RDMA_RESOURCE_ERROR ||
          cmq.calls.size() != 0 || mem.unauthorized_effect ||
          !manager.raw_qp_state(result.resource_h, raw_state) ||
          raw_state != RDMA_RESOURCE_ERROR || recovery == null ||
          recovery.hardware_presence != RDMA_HW_PRESENCE_ABSENT ||
          recovery.qp_recovery == null ||
          recovery.qp_recovery.ambiguous_operation != RDMA_QP_AMBIG_NONE ||
          recovery.qp_recovery.ambiguous_ticket != null ||
          recovery.qp_recovery.candidate_qpc != null ||
          recovery.qp_recovery.staging_mapping != null ||
          recovery.qp_recovery.qp_plan == null || pending_mapping == null ||
          query_status == null || !query_status.ok() || release_complete ||
          release_calls != 1 || mem.live_allocations() != 4 ||
          recovery.qp_recovery.qp_plan.sq_ref == null ||
          recovery.qp_recovery.qp_plan.sq_pd_ref == null ||
          recovery.qp_recovery.qp_plan.rq_ref == null ||
          recovery.qp_recovery.qp_plan.sq_ref.mapping == null ||
          recovery.qp_recovery.qp_plan.sq_pd_ref.mapping == null ||
          recovery.qp_recovery.qp_plan.rq_ref.mapping == null ||
          recovery.qp_recovery.qp_plan.sq_ref.mapping.function_h == null ||
          recovery.qp_recovery.qp_plan.sq_pd_ref.mapping.function_h == null ||
          recovery.qp_recovery.qp_plan.rq_ref.mapping.function_h == null ||
          pending_mapping.function_h == null ||
          recovery.qp_recovery.qp_plan.sq_ref.mapping.state !=
            RDMA_MAPPING_ACTIVE ||
          recovery.qp_recovery.qp_plan.sq_pd_ref.mapping.state !=
            RDMA_MAPPING_ACTIVE ||
          recovery.qp_recovery.qp_plan.rq_ref.mapping.state !=
            RDMA_MAPPING_ACTIVE ||
          pending_mapping.state != RDMA_MAPPING_ACTIVE ||
          !recovery.qp_recovery.qp_plan.sq_ref.mapping.function_h.
            same_instance(old_owner) ||
          !recovery.qp_recovery.qp_plan.sq_pd_ref.mapping.function_h.
            same_instance(old_owner) ||
          !recovery.qp_recovery.qp_plan.rq_ref.mapping.function_h.
            same_instance(old_owner) ||
          !pending_mapping.function_h.same_instance(old_owner) ||
          binding.make_handle().same_instance(old_owner) ||
          (failure_kind == 0 &&
            (recovery.qp_recovery.context_ref != null ||
             recovery.qp_recovery.qp_plan.context_ref != null ||
             contexts.slots.size() != 0 || contexts.release_call_count != 0)) ||
          (failure_kind == 1 &&
            (recovery.qp_recovery.context_ref == null ||
             recovery.qp_recovery.qp_plan.context_ref == null ||
             !recovery.qp_recovery.context_ref.release_complete ||
             !recovery.qp_recovery.qp_plan.context_ref.release_complete ||
             contexts.release_call_count != 1)))
        `uvm_error(label,
          "direct unattached rollback orphaned or changed exact-old authority")
    end
  endtask

  task automatic check_unattached_release_ambiguity();
    for (int unsigned failure_kind = 0; failure_kind < 2; failure_kind++) begin
      string label;
      rdma_qp_boundary_host_mem mem;
      rdma_qp_fault_manager manager;
      rdma_qp_boundary_context_backing contexts;
      rdma_mock_cmq_port cmq;
      rdma_qp_lifecycle_executor executor;
      rdma_function_binding binding;
      rdma_pd pd;
      rdma_cq cq;
      rdma_create_qp_req request;
      rdma_qp qp;
      rdma_control_result result;
      rdma_recovery_record recovery;
      rdma_resource_state_e raw_state;
      rdma_dma_mapping retained_mapping;
      bit release_complete;
      int unsigned retained_release_calls;
      rdma_status query_status;

      label = $sformatf("CREATE_UNATTACHED_RELEASE_AMBIG_%0d", failure_kind);
      mem = rdma_qp_boundary_host_mem::type_id::create({label, "_mem"});
      manager = rdma_qp_fault_manager::type_id::create({label, "_manager"});
      manager.attach_failure = rdma_status::make(
        RDMA_SC_DMA_TRANSLATION, "injected programming attach failure"
      );
      contexts = rdma_qp_boundary_context_backing::type_id::create(
        {label, "_contexts"}
      );
      if (failure_kind == 0)
        contexts.mode = "timeout_context_release_before";
      else
        mem.mode = "timeout_plan_release_before";
      cmq = rdma_mock_cmq_port::type_id::create({label, "_cmq"});
      executor = rdma_qp_lifecycle_executor::type_id::create(
        {label, "_executor"}
      );
      setup_custom_qp_environment(label, mem, manager, contexts, cmq, executor,
                                  binding, pd, cq);
      request = make_request({label, "_request"}, binding, pd, cq,
                             RDMA_TRANSPORT_RC);
      executor.create_locked(binding, binding.make_handle(), request,
                             495 + failure_kind, qp, result);
      expect_code({label, "_STATUS"}, result == null ? null : result.status,
                  RDMA_SC_RECOVERY_REQUIRED);
      expect_code({label, "_PRIMARY"},
                  result == null ? null : result.primary_status,
                  RDMA_SC_DMA_TRANSLATION);
      recovery = null;
      if (result != null && result.resource_h != null)
        void'(manager.raw_recovery(result.resource_h, recovery));
      release_complete = 1'b1;
      query_status = null;
      retained_mapping = null;
      if (recovery != null && recovery.qp_recovery != null) begin
        if (failure_kind == 0)
          query_status = contexts.query_release_completion(
            recovery.qp_recovery.context_ref, release_complete
          );
        else if (recovery.qp_recovery.qp_plan != null) begin
          retained_mapping = recovery.qp_recovery.qp_plan.rq_pd_ref.mapping;
          query_status = retained_mapping.
            release_completion_status(release_complete);
        end
      end
      retained_release_calls = 0;
      if (retained_mapping != null) begin
        foreach (mem.calls[i])
          if (mem.calls[i] != null && mem.calls[i].method_name == "release" &&
              mem.calls[i].mapping != null &&
              mem.calls[i].mapping.iova.value == retained_mapping.iova.value)
            retained_release_calls++;
      end
      if (qp != null || result == null || result.resource_h == null ||
          !result.recovery_required || cmq.calls.size() != 0 ||
          !manager.raw_qp_state(result.resource_h, raw_state) ||
          raw_state != RDMA_RESOURCE_ERROR || recovery == null ||
          recovery.hardware_presence != RDMA_HW_PRESENCE_ABSENT ||
          recovery.qp_recovery == null ||
          recovery.qp_recovery.ambiguous_operation != RDMA_QP_AMBIG_NONE ||
          recovery.qp_recovery.ambiguous_ticket != null ||
          recovery.qp_recovery.candidate_qpc != null ||
          recovery.qp_recovery.staging_mapping != null ||
          recovery.qp_recovery.qp_plan == null ||
          recovery.qp_recovery.context_ref == null ||
          query_status == null || !query_status.ok() || release_complete ||
          mem.live_allocations() != 4 ||
          (failure_kind == 0 && contexts.boundary_release_count != 1) ||
          (failure_kind == 1 && retained_release_calls != 1))
        `uvm_error(label,
          "unattached opaque release lost identity/authority or retried")
    end
  endtask

  task automatic check_contextless_preprogram_progress();
    rdma_qp_boundary_host_mem mem;
    rdma_qp_fault_manager manager;
    rdma_mock_context_backing contexts;
    rdma_mock_cmq_port cmq;
    rdma_qp_lifecycle_executor executor;
    rdma_function_binding binding;
    rdma_pd pd;
    rdma_cq cq;
    rdma_create_qp_req request;
    rdma_qp qp;
    rdma_control_result result;
    rdma_recovery_record recovery;
    rdma_handle qp_h;
    rdma_status status;
    rdma_resource_state_e state;
    rdma_qp_backing_ref refs[$];

    mem = rdma_qp_boundary_host_mem::type_id::create("CTXLESS_PROGRESS_mem");
    manager = rdma_qp_fault_manager::type_id::create("CTXLESS_PROGRESS_manager");
    manager.sequence_failure = rdma_status::make(
      RDMA_SC_DMA_TRANSLATION, "injected pre-program authority failure"
    );
    mem.mode = "timeout_plan_release_before";
    contexts = rdma_mock_context_backing::type_id::create(
      "CTXLESS_PROGRESS_contexts"
    );
    cmq = rdma_mock_cmq_port::type_id::create("CTXLESS_PROGRESS_cmq");
    executor = rdma_qp_lifecycle_executor::type_id::create(
      "CTXLESS_PROGRESS_executor"
    );
    setup_custom_qp_environment("CTXLESS_PROGRESS", mem, manager, contexts,
                                cmq, executor, binding, pd, cq);
    request = make_request("CTXLESS_PROGRESS_request", binding, pd, cq,
                           RDMA_TRANSPORT_RC);
    executor.create_locked(binding, binding.make_handle(), request, 701,
                           qp, result);
    qp_h = result == null ? null : result.resource_h;
    recovery = null;
    if (qp_h != null)
      void'(manager.raw_recovery(qp_h, recovery));
    if (qp != null || result == null || result.status == null ||
        result.status.code != RDMA_SC_RECOVERY_REQUIRED || recovery == null ||
        recovery.qp_recovery == null ||
        recovery.qp_recovery.context_ref != null ||
        recovery.qp_recovery.qp_plan == null)
      `uvm_error("CTXLESS_PROGRESS_PUBLICATION",
                 "contextless pre-program recovery was not published")
    status = qp_h == null ? null : manager.clear_recovery(qp_h);
    if (status == null || status.code != RDMA_SC_RECOVERY_REQUIRED)
      `uvm_error("CTXLESS_PROGRESS_CLEAR_GUARD",
                 "clear_recovery discarded incomplete QP plan authority")
    status = qp_h == null ? null :
      manager.record_qp_context_cleanup_complete(qp_h);
    if (status == null || !status.ok())
      `uvm_error("CTXLESS_PROGRESS_CONTEXT_SKIP",
                 "no-context QP incorrectly required context progress")
    if (recovery != null && recovery.qp_recovery != null &&
        recovery.qp_recovery.qp_plan != null) begin
      refs.push_back(recovery.qp_recovery.qp_plan.sq_ref);
      refs.push_back(recovery.qp_recovery.qp_plan.sq_pd_ref);
      refs.push_back(recovery.qp_recovery.qp_plan.rq_ref);
      refs.push_back(recovery.qp_recovery.qp_plan.rq_pd_ref);
      foreach (refs[i])
        if (refs[i] != null)
          void'(mem.\release (refs[i].mapping));
      status = manager.record_qp_flush_complete(qp_h,
                                                RDMA_QUEUE_ROLE_QP_SQ_RING);
      status = manager.record_qp_flush_complete(qp_h,
                                                RDMA_QUEUE_ROLE_QP_SQ_PD);
      status = manager.record_qp_flush_complete(qp_h,
                                                RDMA_QUEUE_ROLE_QP_RQ_PD);
      status = manager.record_qp_cleanup_complete(qp_h,
                                                  RDMA_QUEUE_ROLE_QP_RQ_PD);
      if (status == null || !status.ok())
        `uvm_error("CTXLESS_PROGRESS_RQPD", "contextless RQ PD progress rejected")
      status = manager.record_qp_cleanup_complete(qp_h,
                                                  RDMA_QUEUE_ROLE_QP_SQ_PD);
      if (status == null || !status.ok())
        `uvm_error("CTXLESS_PROGRESS_SQPD", "contextless SQ PD progress rejected")
      status = manager.record_qp_cleanup_complete(qp_h,
                                                  RDMA_QUEUE_ROLE_QP_RQ_RING);
      if (status == null || !status.ok())
        `uvm_error("CTXLESS_PROGRESS_RQ", "contextless RQ progress rejected")
      status = manager.record_qp_cleanup_complete(qp_h,
                                                  RDMA_QUEUE_ROLE_QP_SQ_RING);
      if (status == null || !status.ok())
        `uvm_error("CTXLESS_PROGRESS_SQ", "contextless SQ progress rejected")
    end
    status = qp_h == null ? null : manager.finalize_qp_release(qp_h);
    if (status == null || !status.ok() ||
        (qp_h != null && manager.raw_qp_state(qp_h, state)))
      `uvm_error("CTXLESS_PROGRESS_FINALIZE",
                 "contextless QP plan did not finalize after opaque cleanup")
  endtask

  task automatic check_allocate_pending_release_retained();
    rdma_qp_pending_allocate_host_mem mem;
    rdma_function_binding binding;
    rdma_resource_manager manager;
    rdma_mock_context_backing contexts;
    rdma_mock_cmq_port cmq;
    rdma_qp_lifecycle_executor executor;
    rdma_pd pd;
    rdma_cq cq;
    rdma_create_qp_req request;
    rdma_qp qp;
    rdma_control_result result;
    rdma_recovery_record recovery;

    mem = rdma_qp_pending_allocate_host_mem::type_id::create(
      "ALLOC_PENDING_mem");
    setup_qp_environment("ALLOC_PENDING", mem, binding, manager, contexts,
                         cmq, executor, pd, cq);
    request = make_request("ALLOC_PENDING_request", binding, pd, cq,
                           RDMA_TRANSPORT_RC);
    executor.create_locked(binding, binding.make_handle(), request, 702, qp,
                           result);
    recovery = null;
    if (result != null && result.resource_h != null)
      void'(manager.lookup_recovery(result.resource_h, recovery));
    if (qp != null || result == null || result.status == null ||
        result.status.code != RDMA_SC_RECOVERY_REQUIRED || recovery == null ||
        recovery.qp_recovery == null || recovery.qp_recovery.qp_plan == null ||
        recovery.qp_recovery.qp_plan.sq_ref == null ||
        recovery.qp_recovery.qp_plan.sq_ref.mapping == null ||
        recovery.qp_recovery.qp_plan.sq_ref.mapping.state != RDMA_MAPPING_ACTIVE ||
        mem.release_calls != 1)
      `uvm_error("ALLOC_PENDING_RETAINED",
                 "non-null failed allocation release authority was dropped")
  endtask

  // Round-5 regressions: a failed non-null allocation must retain a durable
  // opaque capability even when its public geometry is malformed, and an
  // authority-hook rejection must not make the allocation disappear.  The
  // first release is deliberately incomplete; the second call seals it and
  // recovery progress must then be idempotent.
  task automatic check_malformed_allocation_recovery();
    string modes[$];

    modes.push_back("undersized");
    modes.push_back("unaligned");
    modes.push_back("authority");
    modes.push_back("authority_null");
    foreach (modes[i]) begin
      string label;
      rdma_mock_host_mem mem;
      rdma_qp_malformed_allocate_host_mem malformed_mem;
      rdma_qp_authority_pending_host_mem authority_mem;
      rdma_qp_fault_manager manager;
      rdma_mock_context_backing contexts;
      rdma_mock_cmq_port cmq;
      rdma_qp_lifecycle_executor executor;
      rdma_function_binding binding;
      rdma_function_handle old_owner;
      rdma_pd pd;
      rdma_cq cq;
      rdma_create_qp_req request;
      rdma_qp qp;
      rdma_qp replacement_qp;
      rdma_control_result result;
      rdma_recovery_record recovery;
      rdma_dma_mapping retained_mapping;
      rdma_status status;
      rdma_resource_state_e raw_state;
      int unsigned old_local_qpn;
      int unsigned release_calls_before;

      label = {"CREATE_MALFORMED_", modes[i]};
      if (modes[i] inside {"authority", "authority_null"}) begin
        authority_mem = rdma_qp_authority_pending_host_mem::type_id::create(
          {label, "_mem"});
        authority_mem.null_snapshot = modes[i] == "authority_null";
        mem = authority_mem;
      end else begin
        malformed_mem = rdma_qp_malformed_allocate_host_mem::type_id::create(
          {label, "_mem"});
        malformed_mem.geometry_mode = modes[i];
        mem = malformed_mem;
      end
      manager = rdma_qp_fault_manager::type_id::create({label, "_manager"});
      contexts = rdma_mock_context_backing::type_id::create({label, "_contexts"});
      cmq = rdma_mock_cmq_port::type_id::create({label, "_cmq"});
      executor = rdma_qp_lifecycle_executor::type_id::create({label, "_executor"});
      setup_custom_qp_environment(label, mem, manager, contexts, cmq,
                                  executor, binding, pd, cq);
      old_owner = binding.make_handle();
      request = make_request({label, "_request"}, binding, pd, cq,
                             RDMA_TRANSPORT_RC);
      executor.create_locked(binding, old_owner, request, 710 + i, qp, result);

      recovery = null;
      if (result != null && result.resource_h != null)
        void'(manager.raw_recovery(result.resource_h, recovery));
      retained_mapping = recovery == null || recovery.qp_recovery == null ||
                         recovery.qp_recovery.qp_plan == null ||
                         recovery.qp_recovery.qp_plan.sq_ref == null ? null :
                         recovery.qp_recovery.qp_plan.sq_ref.mapping;
      old_local_qpn = '0;
      if (result != null && result.resource_h != null)
        void'(manager.raw_qp_local_id(result.resource_h, old_local_qpn));

      // Before the adapter seals completion, finalization must remain blocked
      // and the original QP reservation must continue to own its local QPN.
      status = result == null || result.resource_h == null ? null :
               manager.finalize_qp_release(result.resource_h);
      if (qp != null || result == null || result.status == null ||
          result.status.code != RDMA_SC_RECOVERY_REQUIRED ||
          !result.recovery_required || result.resource_h == null ||
          cmq.calls.size() != 0 || recovery == null ||
          recovery.hardware_presence != RDMA_HW_PRESENCE_ABSENT ||
          recovery.qp_recovery == null || retained_mapping == null ||
          status == null || status.code != RDMA_SC_RECOVERY_REQUIRED ||
          !manager.raw_qp_state(result.resource_h, raw_state) ||
          raw_state != RDMA_RESOURCE_ERROR ||
          retained_mapping.function_h == null ||
          !retained_mapping.function_h.same_instance(old_owner) ||
          retained_mapping.owner_h == null ||
          !retained_mapping.owner_h.same_instance(result.resource_h) ||
          (modes[i] == "undersized" && retained_mapping.size >= 8192) ||
          (modes[i] == "unaligned" &&
           ((retained_mapping.iova.value & 64'hfff) == 0 ||
            (retained_mapping.backing_addr.value & 64'hfff) == 0)) ||
          (!(modes[i] inside {"authority", "authority_null"}) &&
           ((malformed_mem == null) || malformed_mem.release_calls != 1)) ||
          ((modes[i] inside {"authority", "authority_null"}) &&
           ((authority_mem == null) || authority_mem.release_calls != 1)))
        `uvm_error(label,
          "malformed allocation did not retain exact-old recovery authority")

      // Clearing an incomplete ERROR record must not discard the only
      // retained mapping authority or create a finalization bypass.
      status = result == null || result.resource_h == null ? null :
               manager.clear_recovery(result.resource_h);
      if (status == null || status.code != RDMA_SC_RECOVERY_REQUIRED)
        `uvm_error({label, "_CLEAR_GUARD"},
          "incomplete malformed recovery was cleared prematurely")

      // A new reservation must not recycle the ERROR QPN while cleanup is
      // pending.  Release the temporary reservation immediately afterwards.
      replacement_qp = null;
      status = manager.create_qp(binding, pd.handle, cq.handle, cq.handle,
                                 null, replacement_qp);
      if (status == null || !status.ok() || replacement_qp == null ||
          replacement_qp.local_qp_id == old_local_qpn)
        `uvm_error(label, "pending malformed recovery reused the old QPN")
      if (replacement_qp != null)
        void'(manager.finalize_qp_release(replacement_qp.handle));

      // Complete the one pending physical release through the exact retained
      // mapping, then advance the canonical cleanup state once.  The second
      // cleanup attempt must be rejected and finalization must not duplicate
      // the already-sealed physical release.  Keep the ERROR recovery record
      // until QP finalization; clear_recovery() intentionally acknowledges a
      // record without bypassing the QP-specific finalization gate.
      release_calls_before = (modes[i] inside {"authority", "authority_null"}) ?
        authority_mem.release_calls : malformed_mem.release_calls;
      if (retained_mapping != null)
        status = mem.\release (retained_mapping);
      else
        status = null;
      if (status == null || !status.ok())
        `uvm_error({label, "_COMPLETE"},
          "retained malformed mapping could not complete release")
      status = manager.record_qp_flush_complete(
        result.resource_h, RDMA_QUEUE_ROLE_QP_SQ_RING);
      if (status == null || !status.ok())
        `uvm_error({label, "_SQ_FLUSH"},
          "malformed recovery SQ flush progress was rejected")
      status = manager.record_qp_flush_complete(
        result.resource_h, RDMA_QUEUE_ROLE_QP_SQ_PD);
      if (status == null || !status.ok())
        `uvm_error({label, "_SQPD_FLUSH"},
          "malformed recovery SQ-PD flush progress was rejected")
      status = manager.record_qp_flush_complete(
        result.resource_h, RDMA_QUEUE_ROLE_QP_RQ_PD);
      if (status == null || !status.ok())
        `uvm_error({label, "_RQPD_FLUSH"},
          "malformed recovery RQ-PD flush progress was rejected")
      status = manager.record_qp_cleanup_complete(
        result.resource_h, RDMA_QUEUE_ROLE_QP_SQ_RING);
      if (status == null || !status.ok())
        `uvm_error({label, "_SQ_CLEANUP"},
          "malformed recovery backing cleanup was rejected")
      status = manager.record_qp_cleanup_complete(
        result.resource_h, RDMA_QUEUE_ROLE_QP_SQ_RING);
      if (status == null || status.code != RDMA_SC_INVALID_ARGUMENT)
        `uvm_error({label, "_SQ_ONCE"},
          "malformed recovery cleanup was not exactly-once")
      status = manager.finalize_qp_release(result.resource_h);
      if (status == null || !status.ok() ||
          !((modes[i] inside {"authority", "authority_null"} &&
             authority_mem.release_calls ==
             release_calls_before + 1) ||
            (!(modes[i] inside {"authority", "authority_null"}) &&
             malformed_mem.release_calls ==
             release_calls_before + 1)))
        `uvm_error({label, "_FINALIZE"},
          "malformed recovery finalization duplicated or lost release")
    end
  endtask

  task run_phase(uvm_phase phase);
    phase.raise_objection(this);
    check_rc_plan_and_staging_authority();
    check_ud_semantic_round_trip();
    check_rc_srq_geometry();
    check_urc_internal_geometry();
    check_urc_nonzero_rejected();
    check_allocate_error_cleanup();
    check_authority_failure_cleanup(1);
    check_authority_failure_cleanup(2);
    check_stale_rebind_blocks_attach();
    check_borrowed_multislice_authority();
    check_allocation_and_host_write_failures();
    check_context_codec_and_attach_failures();
    check_definitive_cmq_and_activation_failures();
    check_ambiguous_create_outcomes();
    check_stale_forged_recovery_rejected();
    check_create_generation_fences();
    check_immediate_adapter_generation_boundaries();
    check_local_timeout_authority_retained();
    check_staging_release_completion_and_rebind();
    check_context_release_completion();
    check_activation_rebind_recovery();
    check_activation_rollback_ambiguity();
    check_pre_create_execute_generation_fence();
    check_context_acquire_rebind_authority();
    check_definitive_failure_staging_release_ambiguity();
    check_direct_unattached_release_authority();
    check_unattached_release_ambiguity();
    check_contextless_preprogram_progress();
    check_allocate_pending_release_retained();
    check_malformed_allocation_recovery();
    check_urc_recovery_retention();
    check_modify_state_machine();
    check_modify_transport_and_guards();
    check_modify_completion_ticket_fallback();
    check_modify_query_allocation_failure();
    check_modify_query_malformed_pending();
    check_destroy_lifecycle();
    check_destroy_ticketless_ambiguity();
    check_destroy_stale_generation_boundary();
    phase.drop_objection(this);
  endtask

  task automatic check_destroy_stale_generation_boundary();
    rdma_mock_host_mem mem;
    rdma_function_binding binding;
    rdma_qp_fault_manager manager;
    rdma_mock_context_backing contexts;
    rdma_qp_destroy_rebind_cmq cmq;
    rdma_qp_lifecycle_executor executor;
    rdma_pd pd;
    rdma_cq cq;
    rdma_create_qp_req create_req;
    rdma_destroy_resource_req destroy_req;
    rdma_qp qp;
    rdma_control_result result;
    rdma_recovery_record recovery;
    int unsigned calls_before;

    mem = rdma_mock_host_mem::type_id::create("destroy_stale_mem");
    manager = rdma_qp_fault_manager::type_id::create("destroy_stale_manager");
    contexts = rdma_mock_context_backing::type_id::create("destroy_stale_contexts");
    cmq = rdma_qp_destroy_rebind_cmq::type_id::create("destroy_stale_cmq");
    executor = rdma_qp_lifecycle_executor::type_id::create("destroy_stale_executor");
    setup_custom_qp_environment("destroy_stale", mem, manager, contexts,
                                cmq, executor, binding, pd, cq);
    cmq.binding_target = binding;
    create_req = make_request("destroy_stale_create", binding, pd, cq,
                              RDMA_TRANSPORT_RC);
    executor.create_locked(binding, binding.make_handle(), create_req, 867,
                           qp, result);
    cmq.armed = 1'b1;
    destroy_req = rdma_destroy_resource_req::type_id::create("destroy_stale_req");
    destroy_req.owner = binding.make_handle();
    destroy_req.target_h = rdma_clone_handle_value(qp.handle,
                                                    "destroy stale target");
    calls_before = cmq.calls.size();
    executor.destroy_locked(binding, binding.make_handle(), destroy_req, 868,
                            result);
    recovery = null;
    if (result != null && result.resource_h != null)
      void'(manager.raw_recovery(result.resource_h, recovery));
    if (result == null || result.status == null ||
        result.status.code != RDMA_SC_RECOVERY_REQUIRED ||
        !result.recovery_required || recovery == null ||
        recovery.qp_recovery == null ||
        recovery.qp_recovery.ambiguous_operation != RDMA_QP_AMBIG_MODIFY ||
        cmq.calls.size() != calls_before + 1)
      `uvm_error("QP_DESTROY_STALE_BOUNDARY",
                 "stale generation after destroy side effect was not fenced")
  endtask

  task automatic check_destroy_lifecycle();
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
    rdma_status status;
    rdma_status released_status;
    bit [7:0] expected[$];
    bit [7:0] actual[$];
    rdma_resource resource;
    int unsigned calls_before;

    // A normal RC destroy emits ERROR transition, QPN/SQ-PD/RQ-PD flushes,
    // then QPC_DELETE and releases all QP-owned authority.
    mem = rdma_mock_host_mem::type_id::create("destroy_rc_mem");
    setup_qp_environment("destroy_rc", mem, binding, manager, contexts,
                         cmq, executor, pd, cq);
    create_req = make_request("destroy_rc_create", binding, pd, cq,
                              RDMA_TRANSPORT_RC);
    executor.create_locked(binding, binding.make_handle(), create_req, 860,
                           qp, result);
    destroy_req = rdma_destroy_resource_req::type_id::create("destroy_rc_req");
    destroy_req.owner = binding.make_handle();
    destroy_req.target_h = rdma_clone_handle_value(qp.handle,
                                                    "destroy rc target");
    executor.destroy_locked(binding, binding.make_handle(), destroy_req, 861,
                            result);
    expected = {XTR_V1_OP_QPC_CREATE, XTR_V1_OP_QPC_MODIFY,
                XTR_V1_OP_OCC_FLUSH, XTR_V1_OP_OCC_FLUSH,
                XTR_V1_OP_OCC_FLUSH, XTR_V1_OP_QPC_DELETE};
    actual.delete();
    cmq.get_opcodes(actual);
    released_status = manager.lookup(destroy_req.target_h, resource);
    if (result == null || result.status == null || !result.status.ok() ||
        result.final_resource_state != RDMA_RESOURCE_RELEASED ||
        !result.final_resource_state_known || result.recovery_required ||
        actual != expected || mem.live_allocations() != 0 ||
        contexts.slots.size() != 1 || !contexts.slots[0].released ||
        released_status == null ||
        released_status.code != RDMA_SC_INVALID_STATE || resource != null)
      `uvm_error("QP_DESTROY_RC", "normal RC QP destroy did not complete in order")

    // Outstanding work is rejected before begin_quiesce and any CMQ side effect.
    mem = rdma_mock_host_mem::type_id::create("destroy_busy_mem");
    setup_qp_environment("destroy_busy", mem, binding, manager, contexts,
                         cmq, executor, pd, cq);
    create_req = make_request("destroy_busy_create", binding, pd, cq,
                              RDMA_TRANSPORT_RC);
    executor.create_locked(binding, binding.make_handle(), create_req, 862,
                           qp, result);
    status = manager.track_outstanding(qp.handle, 64'hd35);
    calls_before = cmq.calls.size();
    destroy_req = rdma_destroy_resource_req::type_id::create("destroy_busy_req");
    destroy_req.owner = binding.make_handle();
    destroy_req.target_h = rdma_clone_handle_value(qp.handle,
                                                    "destroy busy target");
    executor.destroy_locked(binding, binding.make_handle(), destroy_req, 863,
                            result);
    status = manager.lookup(qp.handle, resource);
    if (result == null || result.status == null ||
        result.status.code != RDMA_SC_RESOURCE_BUSY || status == null ||
        !status.ok() || resource == null || resource.state != RDMA_RESOURCE_ACTIVE ||
        cmq.calls.size() != calls_before)
      `uvm_error("QP_DESTROY_BUSY", "busy QP destroy issued side effects")
  endtask

  task automatic check_destroy_ticketless_ambiguity();
    rdma_mock_host_mem mem;
    rdma_function_binding binding;
    rdma_resource_manager manager;
    rdma_mock_context_backing contexts;
    rdma_qp_ticketless_destroy_cmq cmq;
    rdma_qp_lifecycle_executor executor;
    rdma_pd pd;
    rdma_cq cq;
    rdma_create_qp_req create_req;
    rdma_destroy_resource_req destroy_req;
    rdma_qp qp;
    rdma_control_result result;
    rdma_control_result retry_result;
    rdma_recovery_record recovery;
    int unsigned calls_before;

    mem = rdma_mock_host_mem::type_id::create("destroy_ticketless_mem");
    manager = rdma_resource_manager::type_id::create("destroy_ticketless_manager");
    contexts = rdma_mock_context_backing::type_id::create("destroy_ticketless_contexts");
    cmq = rdma_qp_ticketless_destroy_cmq::type_id::create(
      "destroy_ticketless_cmq");
    executor = rdma_qp_lifecycle_executor::type_id::create(
      "destroy_ticketless_executor");
    setup_custom_qp_environment("destroy_ticketless", mem, manager,
                                contexts, cmq, executor, binding, pd, cq);
    create_req = make_request("destroy_ticketless_create", binding, pd, cq,
                              RDMA_TRANSPORT_RC);
    executor.create_locked(binding, binding.make_handle(), create_req, 864,
                           qp, result);
    destroy_req = rdma_destroy_resource_req::type_id::create(
      "destroy_ticketless_req");
    destroy_req.owner = binding.make_handle();
    destroy_req.target_h = rdma_clone_handle_value(
      qp.handle, "destroy ticketless target");
    cmq.timeout_opcode(XTR_V1_OP_QPC_MODIFY);
    executor.destroy_locked(binding, binding.make_handle(), destroy_req, 865,
                            result);
    recovery = null;
    if (result != null && result.resource_h != null)
      void'(manager.lookup_recovery(result.resource_h, recovery));
    if (result == null || result.status == null ||
        result.status.code != RDMA_SC_RECOVERY_REQUIRED ||
        !result.recovery_required || recovery == null ||
        recovery.qp_recovery == null ||
        recovery.qp_recovery.ambiguous_operation != RDMA_QP_AMBIG_MODIFY ||
        recovery.qp_recovery.ambiguous_ticket != null ||
        !recovery.qp_recovery.has_pending_hardware_step)
      `uvm_error("QP_DESTROY_TICKETLESS",
                 "ticketless destroy ambiguity was not durably retained")
    calls_before = cmq.calls.size();
    retry_result = null;
    executor.recover_locked(binding, binding.make_handle(), result.resource_h,
                            866, retry_result);
    if (retry_result == null || retry_result.status == null ||
        retry_result.status.code != RDMA_SC_RECOVERY_REQUIRED ||
        !retry_result.recovery_required || cmq.calls.size() != calls_before)
      `uvm_error("QP_DESTROY_TICKETLESS_RETRY",
                 "ticketless destroy recovery did not fail closed")
  endtask

  task automatic check_modify_state_machine();
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
    rdma_xtr_v1_qpc_command_body modify_body;
    rdma_qpc_rc_ext rc_ext;
    mem = rdma_mock_host_mem::type_id::create("modify_red_mem");
    setup_qp_environment("modify_red", mem, binding, manager, contexts, cmq,
                         executor, pd, cq);
    create_req = make_request("modify_red_create", binding, pd, cq,
                              RDMA_TRANSPORT_RC);
    executor.create_locked(binding, binding.make_handle(), create_req, 700,
                           qp, result);
    modify_req = rdma_modify_qp_req::type_id::create("modify_red_req");
    modify_req.owner = binding.make_handle();
    modify_req.qp_h = rdma_clone_handle_value(qp.handle, "modify red QP");
    modify_req.new_state = RDMA_QPS_INIT;
    executor.modify_locked(binding, binding.make_handle(), modify_req, 701,
                           qp, result);
    if (result == null || result.status == null || !result.status.ok() ||
        qp == null || qp.qp_state != RDMA_QPS_INIT ||
        qp.programmed_qpc == null || qp.programmed_qpc.state != RDMA_QPS_RESET ||
        cmq.calls.size() != 1)
      `uvm_error("MODIFY_RESET_INIT", "RESET to INIT semantic modify is invalid")
    modify_req.new_state = RDMA_QPS_RTR;
    modify_req.destination_qpn_valid = 1'b1;
    modify_req.destination_qpn = 24'h12345;
    executor.modify_locked(binding, binding.make_handle(), modify_req, 702,
                           qp, result);
    if (result == null || result.status == null || !result.status.ok() ||
        qp == null || qp.qp_state != RDMA_QPS_RTR || cmq.calls.size() != 2 ||
        cmq.calls[1] == null || cmq.calls[1].command == null ||
        cmq.calls[1].command.opcode_key == null ||
        cmq.calls[1].command.opcode_key.variant != "modify" ||
        !$cast(modify_body, cmq.calls[1].command.body) ||
        modify_body == null || !modify_body.full_modify ||
        modify_body.next_state != RDMA_QPS_RTR ||
        modify_body.wbe_template_count != 0)
      `uvm_error("MODIFY_INIT_RTR", "INIT to RTR full modify is invalid")
    if (qp != null && qp.programmed_qpc != null &&
        $cast(rc_ext, qp.programmed_qpc.transport_ext) &&
        (rc_ext.remote_qpn != modify_req.destination_qpn ||
         rc_ext.send_psn != 24'h123456 || rc_ext.recv_psn != 24'h654321))
      `uvm_error("MODIFY_RC_DEST", "RC destination valid-bit patch changed the wrong fields")
    modify_req.send_psn_valid = 1'b1;
    modify_req.send_psn = 24'h0abcde;
    modify_req.recv_psn_valid = 1'b1;
    modify_req.recv_psn = 24'h0fedcb;
    modify_req.new_state = RDMA_QPS_RTS;
    executor.modify_locked(binding, binding.make_handle(), modify_req, 703,
                           qp, result);
    if (result == null || result.status == null || !result.status.ok() ||
        qp == null || qp.qp_state != RDMA_QPS_RTS || cmq.calls.size() != 3)
      `uvm_error("MODIFY_RTR_RTS", "RTR to RTS full modify is invalid")
    if (qp != null && qp.programmed_qpc != null &&
        $cast(rc_ext, qp.programmed_qpc.transport_ext) &&
        (rc_ext.send_psn != modify_req.send_psn ||
         rc_ext.recv_psn != modify_req.recv_psn))
      `uvm_error("MODIFY_RC_PSN", "RC PSN valid-bit patches were not applied")

    // State-only transitions must submit no staging image and no WBE pairs.
    modify_req.new_state = RDMA_QPS_ERROR;
    executor.modify_locked(binding, binding.make_handle(), modify_req, 704,
                           qp, result);
    if (result == null || result.status == null || !result.status.ok() ||
        qp == null || qp.qp_state != RDMA_QPS_ERROR || cmq.calls.size() != 4 ||
        cmq.calls[3] == null || cmq.calls[3].command == null ||
        !$cast(modify_body, cmq.calls[3].command.body) ||
        modify_body == null || modify_body.full_modify ||
        modify_body.partial_modify || modify_body.qpc_buffer.value != 0 ||
        modify_body.wbe_template_count != 0)
      `uvm_error("MODIFY_ERROR_STATE_ONLY", "ERROR state-only modify is invalid")

    modify_req.new_state = RDMA_QPS_RESET;
    executor.modify_locked(binding, binding.make_handle(), modify_req, 705,
                           qp, result);
    if (result == null || result.status == null || !result.status.ok() ||
        qp == null || qp.qp_state != RDMA_QPS_RESET || cmq.calls.size() != 5 ||
        cmq.calls[4] == null || cmq.calls[4].command == null ||
        !$cast(modify_body, cmq.calls[4].command.body) ||
        modify_body == null || modify_body.full_modify ||
        modify_body.qpc_buffer.value != 0)
      `uvm_error("MODIFY_RESET_STATE_ONLY", "ERROR to RESET state-only modify is invalid")

    // Same-state and unsupported SQD/SQE requests are rejected before CMQ.
    // The QP is RESET after the preceding state-only transition, so use RESET
    // for the same-state probe and retain the post-transition call count.
    modify_req.new_state = RDMA_QPS_RESET;
    executor.modify_locked(binding, binding.make_handle(), modify_req, 706,
                           qp, result);
    if (result == null || result.status == null ||
        result.status.code != RDMA_SC_INVALID_STATE || cmq.calls.size() != 5)
      `uvm_error("MODIFY_SAME_STATE", "same-state modify was not rejected")
    modify_req.new_state = RDMA_QPS_SQD;
    executor.modify_locked(binding, binding.make_handle(), modify_req, 707,
                           qp, result);
    if (result == null || result.status == null ||
        result.status.code != RDMA_SC_UNSUPPORTED_OPCODE || cmq.calls.size() != 5)
      `uvm_error("MODIFY_SQD", "SQD modify was not rejected as unsupported")
  endtask

  task automatic check_urc_recovery_retention();
    rdma_qp_urc_malformed_allocate_host_mem mem;
    rdma_function_binding binding; rdma_resource_manager manager;
    rdma_mock_context_backing contexts; rdma_mock_cmq_port cmq;
    rdma_qp_lifecycle_executor executor; rdma_pd pd; rdma_cq cq;
    rdma_create_qp_req request; rdma_qp qp; rdma_control_result result;
    rdma_recovery_record recovery; rdma_status status;
    rdma_dma_mapping retained_mapping; rdma_qp replacement_qp;
    mem = rdma_qp_urc_malformed_allocate_host_mem::type_id::create("urc_recovery_mem");
    manager = rdma_resource_manager::type_id::create("urc_recovery_manager");
    contexts = rdma_mock_context_backing::type_id::create("urc_recovery_contexts");
    cmq = rdma_mock_cmq_port::type_id::create("urc_recovery_cmq");
    executor = rdma_qp_lifecycle_executor::type_id::create("urc_recovery_executor");
    setup_custom_qp_environment("urc_recovery", mem, manager, contexts, cmq,
                                executor, binding, pd, cq);
    request = make_request("urc_recovery_request", binding, pd, cq, RDMA_TRANSPORT_URC);
    executor.create_locked(binding, binding.make_handle(), request, 790, qp, result);
    recovery = null;
    if (result != null && result.resource_h != null) void'(manager.lookup_recovery(result.resource_h, recovery));
    retained_mapping = (recovery == null || recovery.qp_recovery == null ||
      recovery.qp_recovery.qp_plan == null || recovery.qp_recovery.qp_plan.urc_refs.size() == 0) ? null :
      recovery.qp_recovery.qp_plan.urc_refs[0].mapping;
    if (result != null && result.resource_h != null) begin
      status = manager.finalize_qp_release(result.resource_h);
      if (status == null || status.code != RDMA_SC_RECOVERY_REQUIRED)
        `uvm_error("URC_RECOVERY_FINALIZE", "pending URC recovery finalized early")
    end
    replacement_qp = null;
    status = manager.create_qp(binding, pd.handle, cq.handle, cq.handle, null, replacement_qp);
    if (status == null || !status.ok() || replacement_qp == null || replacement_qp.local_qp_id == 0)
      `uvm_error("URC_RECOVERY_QPN", "pending URC recovery reused QPN")
    if (replacement_qp != null) void'(manager.finalize_qp_release(replacement_qp.handle));
    if (mem.release_calls != 1)
      `uvm_error("URC_RECOVERY_RELEASE_ONCE", "retained URC mapping release was duplicated")
    status = result == null ? null : result.status;
    if (status == null || status.code != RDMA_SC_RECOVERY_REQUIRED || qp != null ||
        recovery == null || recovery.qp_recovery == null ||
        recovery.qp_recovery.qp_plan == null || recovery.qp_recovery.qp_plan.urc_refs.size() == 0 ||
        retained_mapping == null || retained_mapping.function_h == null ||
        !retained_mapping.function_h.same_instance(binding.make_handle()) ||
        retained_mapping.owner_h == null || !retained_mapping.owner_h.same_instance(result.resource_h))
      `uvm_error("URC_RECOVERY_RED", "URC failed allocation was not retained in recovery plan")
  endtask

  task automatic check_modify_completion_ticket_fallback();
    rdma_mock_host_mem mem;
    rdma_function_binding binding;
    rdma_resource_manager manager;
    rdma_mock_context_backing contexts;
    rdma_qp_completion_ticket_only_cmq cmq;
    rdma_qp_lifecycle_executor executor;
    rdma_pd pd;
    rdma_cq cq;
    rdma_create_qp_req create_req;
    rdma_modify_qp_req modify_req;
    rdma_qp qp;
    rdma_control_result result;
    rdma_control_result recovery_result;
    rdma_recovery_record recovery;
    rdma_resource resource;

    mem = rdma_mock_host_mem::type_id::create("ticket_fallback_mem");
    binding = make_binding("ticket_fallback_binding");
    manager = rdma_resource_manager::type_id::create("ticket_fallback_manager");
    contexts = rdma_mock_context_backing::type_id::create("ticket_fallback_contexts");
    cmq = rdma_qp_completion_ticket_only_cmq::type_id::create("ticket_fallback_cmq");
    executor = rdma_qp_lifecycle_executor::type_id::create("ticket_fallback_executor");
    expect_ok("ticket_fallback_FUNCTION", manager.create_function(binding, resource));
    expect_ok("ticket_fallback_PD", manager.create_pd(binding, pd));
    expect_ok("ticket_fallback_CQ", manager.create_cq(binding, null, cq));
    expect_ok("ticket_fallback_CONFIGURE", executor.configure(manager, cmq, mem,
                                                               contexts, 2us));
    create_req = make_request("ticket_fallback_create", binding, pd, cq,
                              RDMA_TRANSPORT_RC);
    executor.create_locked(binding, binding.make_handle(), create_req, 810,
                           qp, result);
    modify_req = rdma_modify_qp_req::type_id::create("ticket_fallback_init");
    modify_req.owner = binding.make_handle();
    modify_req.qp_h = rdma_clone_handle_value(qp.handle, "ticket fallback QP");
    modify_req.new_state = RDMA_QPS_INIT;
    executor.modify_locked(binding, binding.make_handle(), modify_req, 811,
                           qp, result);
    modify_req.new_state = RDMA_QPS_RTR;
    cmq.timeout_opcode(XTR_V1_OP_QPC_MODIFY);
    executor.modify_locked(binding, binding.make_handle(), modify_req, 812,
                           qp, result);
    recovery = null;
    if (result != null && result.resource_h != null)
      void'(manager.lookup_recovery(result.resource_h, recovery));
    if (result == null || result.status == null ||
        result.status.code != RDMA_SC_RECOVERY_REQUIRED || qp != null ||
        recovery == null || recovery.qp_recovery == null ||
        recovery.qp_recovery.ambiguous_ticket == null ||
        cmq.calls.size() != 2 || cmq.calls[1] == null ||
        cmq.calls[1].ticket == null)
      `uvm_error("MODIFY_TICKET_FALLBACK", "completion ticket was not retained")
    else begin
      cmq.push_late_completion(cmq.calls[1].ticket, rdma_status::success());
      recovery_result = null;
      executor.recover_locked(binding, binding.make_handle(), result.resource_h,
                              813, recovery_result);
      if (recovery_result == null || recovery_result.status == null ||
          !recovery_result.status.ok() ||
          manager.lookup(result.resource_h, resource) == null ||
          resource == null || resource.state != RDMA_RESOURCE_ACTIVE)
        `uvm_error("MODIFY_TICKET_RECOVERY", "completion ticket fallback did not recover")
    end
  endtask

  task automatic check_modify_query_allocation_failure();
    rdma_qp_query_allocate_fail_host_mem mem;
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
    rdma_recovery_record recovery;
    rdma_resource resource;
    rdma_status status;

    mem = rdma_qp_query_allocate_fail_host_mem::type_id::create("query_fail_mem");
    setup_qp_environment("query_fail", mem, binding, manager, contexts, cmq,
                         executor, pd, cq);
    create_req = make_request("query_fail_create", binding, pd, cq,
                              RDMA_TRANSPORT_RC);
    executor.create_locked(binding, binding.make_handle(), create_req, 820,
                           qp, result);
    modify_req = rdma_modify_qp_req::type_id::create("query_fail_init");
    modify_req.owner = binding.make_handle();
    modify_req.qp_h = rdma_clone_handle_value(qp.handle, "query fail QP");
    modify_req.new_state = RDMA_QPS_INIT;
    executor.modify_locked(binding, binding.make_handle(), modify_req, 821,
                           qp, result);
    modify_req.new_state = RDMA_QPS_RTR;
    cmq.timeout_opcode(XTR_V1_OP_QPC_MODIFY);
    executor.modify_locked(binding, binding.make_handle(), modify_req, 822,
                           qp, result);
    recovery = null;
    if (result != null && result.resource_h != null)
      void'(manager.lookup_recovery(result.resource_h, recovery));
    status = result == null ? null : result.status;
    if (status == null || status.code != RDMA_SC_RECOVERY_REQUIRED ||
        result.primary_status == null || result.primary_status.code != RDMA_SC_TIMEOUT ||
        qp != null || manager.lookup(result.resource_h, resource) == null ||
        resource == null || resource.state != RDMA_RESOURCE_ERROR ||
        recovery == null || recovery.qp_recovery == null ||
        recovery.qp_recovery.ambiguous_operation != RDMA_QP_AMBIG_MODIFY ||
        recovery.qp_recovery.ambiguous_ticket == null ||
        recovery.qp_recovery.query_mapping != null)
      `uvm_error("MODIFY_QUERY_ALLOC", "query allocation failure lost ERROR recovery authority")
  endtask

  task automatic check_modify_query_malformed_pending();
    rdma_qp_query_malformed_pending_host_mem mem;
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
    rdma_recovery_record recovery;
    rdma_resource resource;
    rdma_status status;
    int unsigned releases_before;
    rdma_codec_registry query_registry;
    rdma_codec_key query_key;
    rdma_codec_base query_codec;
    rdma_hw_image query_image;
    byte query_bytes[];

    mem = rdma_qp_query_malformed_pending_host_mem::type_id::create(
      "query_malformed_mem"
    );
    setup_qp_environment("query_malformed", mem, binding, manager,
                         contexts, cmq, executor, pd, cq);
    create_req = make_request("query_malformed_create", binding, pd, cq,
                              RDMA_TRANSPORT_RC);
    executor.create_locked(binding, binding.make_handle(), create_req, 823,
                           qp, result);
    modify_req = rdma_modify_qp_req::type_id::create("query_malformed_init");
    modify_req.owner = binding.make_handle();
    modify_req.qp_h = rdma_clone_handle_value(qp.handle,
                                               "query malformed QP");
    modify_req.new_state = RDMA_QPS_INIT;
    executor.modify_locked(binding, binding.make_handle(), modify_req, 824,
                           qp, result);
    releases_before = mem.release_calls;
    modify_req.new_state = RDMA_QPS_RTR;
    cmq.timeout_opcode(XTR_V1_OP_QPC_MODIFY);
    executor.modify_locked(binding, binding.make_handle(), modify_req, 825,
                           qp, result);
    recovery = null;
    if (result != null && result.resource_h != null)
      void'(manager.lookup_recovery(result.resource_h, recovery));
    status = result == null ? null : result.status;
    if (status == null || status.code != RDMA_SC_RECOVERY_REQUIRED ||
        qp != null || recovery == null || recovery.qp_recovery == null ||
        recovery.qp_recovery.query_mapping == null ||
        !recovery.qp_recovery.query_mapping_recovery_only ||
        mem.release_calls != releases_before + 1)
      `uvm_error("MODIFY_QUERY_MALFORMED",
                 "malformed pending query authority was not retained")
    if (recovery != null && recovery.qp_recovery != null &&
        recovery.qp_recovery.candidate_qpc != null &&
        result != null && result.resource_h != null) begin
      query_registry = rdma_codec_registry::type_id::create(
        "query_malformed_registry");
      status = rdma_xtr_v1_register_qpc_codecs(query_registry);
      query_key.hw_version = "xtr_v1";
      query_key.image_kind = RDMA_IMAGE_QPC;
      query_key.object_type = "qpc";
      query_key.variant = "rc";
      query_key.opcode = XTR_V1_OP_QPC_CREATE;
      if (status.ok()) status = query_registry.lookup(query_key, query_codec);
      if (status.ok()) status = query_codec.encode(
        recovery.qp_recovery.candidate_qpc, query_image);
      if (status.ok() && query_image != null) begin
        query_bytes = new[query_image.bytes.size()];
        foreach (query_image.bytes[i]) query_bytes[i] = query_image.bytes[i];
        mem.script_query_image(query_bytes);
      end
      cmq.script_query_context(XTR_V1_OP_QPC_QUERY,
                               recovery.qp_recovery.candidate_qpc,
                               rdma_status::success());
      recovery_result = null;
      executor.recover_locked(binding, binding.make_handle(), result.resource_h,
                              826, recovery_result);
      status = recovery_result == null ? null : recovery_result.status;
      void'(manager.lookup(result.resource_h, resource));
      if (status == null || !status.ok() ||
          manager.lookup(result.resource_h, resource) == null ||
          resource == null || resource.state != RDMA_RESOURCE_ACTIVE ||
          mem.release_calls != releases_before + 3)
        `uvm_error("MODIFY_QUERY_MALFORMED_RECOVERY",
                   "recovery-only query release was not reconciled exactly once")
    end
  endtask

  task automatic check_modify_transport_and_guards();
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
    rdma_xtr_v1_qpc_command_body modify_body;
    rdma_qpc_urc_ext urc_ext;
    rdma_status status;
    longint unsigned qp_sequence_value;
    int unsigned calls_before;
    int unsigned live_before;
    rdma_resource live_resource;
    rdma_qp live_qp;

    // UD rejects transport fields before any QPC_MODIFY CMQ side effect.
    mem = rdma_mock_host_mem::type_id::create("ud_modify_mem");
    setup_qp_environment("ud_modify", mem, binding, manager, contexts, cmq,
                         executor, pd, cq);
    create_req = make_request("ud_modify_create", binding, pd, cq,
                              RDMA_TRANSPORT_UD);
    executor.create_locked(binding, binding.make_handle(), create_req, 830,
                           qp, result);
    modify_req = rdma_modify_qp_req::type_id::create("ud_modify_init");
    modify_req.owner = binding.make_handle();
    modify_req.qp_h = rdma_clone_handle_value(qp.handle, "UD modify QP");
    modify_req.new_state = RDMA_QPS_INIT;
    executor.modify_locked(binding, binding.make_handle(), modify_req, 831,
                           qp, result);
    modify_req.new_state = RDMA_QPS_RTR;
    modify_req.destination_qpn_valid = 1'b1;
    modify_req.destination_qpn = 24'h10101;
    calls_before = cmq.calls.size();
    executor.modify_locked(binding, binding.make_handle(), modify_req, 832,
                           qp, result);
    live_resource = null;
    live_qp = null;
    status = manager.lookup(modify_req.qp_h, live_resource);
    if (status != null && status.ok() && live_resource != null)
      void'($cast(live_qp, live_resource));
    if (result == null || result.status == null ||
        result.status.code != RDMA_SC_INVALID_ARGUMENT ||
        live_qp == null || live_qp.qp_state != RDMA_QPS_INIT ||
        cmq.calls.size() != calls_before)
      `uvm_error("MODIFY_UD_VALID", "UD valid-bit transport fields were not rejected")

    // URC full modify uses the one-entry WBE template and preserves sequence.
    mem = rdma_mock_host_mem::type_id::create("urc_modify_mem");
    setup_qp_environment("urc_modify", mem, binding, manager, contexts, cmq,
                         executor, pd, cq);
    create_req = make_request("urc_modify_create", binding, pd, cq,
                              RDMA_TRANSPORT_URC);
    executor.create_locked(binding, binding.make_handle(), create_req, 833,
                           qp, result);
    qp_sequence_value = qp == null || qp.programmed_qpc == null ? 0 :
               qp.programmed_qpc.qp_sequence;
    modify_req = rdma_modify_qp_req::type_id::create("urc_modify_init");
    modify_req.owner = binding.make_handle();
    modify_req.qp_h = rdma_clone_handle_value(qp.handle, "URC modify QP");
    modify_req.new_state = RDMA_QPS_INIT;
    executor.modify_locked(binding, binding.make_handle(), modify_req, 834,
                           qp, result);
    modify_req.new_state = RDMA_QPS_RTR;
    modify_req.destination_qpn_valid = 1'b1;
    modify_req.destination_qpn = 24'h20202;
    modify_req.send_psn_valid = 1'b1;
    modify_req.send_psn = 24'h30303;
    modify_req.recv_psn_valid = 1'b1;
    modify_req.recv_psn = 24'h40404;
    executor.modify_locked(binding, binding.make_handle(), modify_req, 835,
                           qp, result);
    if (result == null || result.status == null || !result.status.ok() ||
        qp == null || qp.qp_state != RDMA_QPS_RTR ||
        qp.programmed_qpc == null || qp.programmed_qpc.qp_sequence != qp_sequence_value ||
        cmq.calls.size() != 2 || cmq.calls[1] == null ||
        cmq.calls[1].command == null ||
        !$cast(modify_body, cmq.calls[1].command.body) ||
        modify_body == null || !modify_body.full_modify ||
        modify_body.wbe_template_count != 1 ||
        !$cast(urc_ext, qp.programmed_qpc.transport_ext) ||
        urc_ext == null || urc_ext.remote_qpn != modify_req.destination_qpn ||
        urc_ext.dpsn != modify_req.send_psn ||
        urc_ext.rpsn != modify_req.recv_psn)
      `uvm_error("MODIFY_URC_WBE", "URC sequence or WBE projection is invalid")

    // Outstanding work is rejected before staging allocation or CMQ submit.
    status = manager.track_outstanding(qp.handle, 64'h55aa);
    if (status == null || !status.ok())
      `uvm_error("MODIFY_BUSY_SETUP", "could not install outstanding QP work")
    modify_req.new_state = RDMA_QPS_RTS;
    calls_before = cmq.calls.size();
    executor.modify_locked(binding, binding.make_handle(), modify_req, 836,
                           qp, result);
    live_resource = null;
    live_qp = null;
    status = manager.lookup(modify_req.qp_h, live_resource);
    if (status != null && status.ok() && live_resource != null)
      void'($cast(live_qp, live_resource));
    if (result == null || result.status == null ||
        result.status.code != RDMA_SC_RESOURCE_BUSY ||
        live_qp == null || live_qp.qp_state != RDMA_QPS_RTR ||
        cmq.calls.size() != calls_before)
      `uvm_error("MODIFY_BUSY", "outstanding QP work was not rejected early")

    // Definitive CMQ failure leaves the prior semantic/programmed image and
    // releases the temporary staging allocation.
    mem = rdma_mock_host_mem::type_id::create("definitive_modify_mem");
    setup_qp_environment("definitive_modify", mem, binding, manager, contexts,
                         cmq, executor, pd, cq);
    create_req = make_request("definitive_modify_create", binding, pd, cq,
                              RDMA_TRANSPORT_RC);
    executor.create_locked(binding, binding.make_handle(), create_req, 837,
                           qp, result);
    modify_req = rdma_modify_qp_req::type_id::create("definitive_modify_init");
    modify_req.owner = binding.make_handle();
    modify_req.qp_h = rdma_clone_handle_value(qp.handle, "definitive modify QP");
    modify_req.new_state = RDMA_QPS_INIT;
    executor.modify_locked(binding, binding.make_handle(), modify_req, 838,
                           qp, result);
    live_before = mem.live_allocations();
    modify_req.new_state = RDMA_QPS_RTR;
    cmq.fail_opcode(XTR_V1_OP_QPC_MODIFY,
                    rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                                      "definitive modify failure"));
    executor.modify_locked(binding, binding.make_handle(), modify_req, 839,
                           qp, result);
    live_resource = null;
    live_qp = null;
    status = manager.lookup(modify_req.qp_h, live_resource);
    if (status != null && status.ok() && live_resource != null)
      void'($cast(live_qp, live_resource));
    if (result == null || result.status == null ||
        result.status.code != RDMA_SC_INVALID_ARGUMENT ||
        live_qp == null || live_qp.qp_state != RDMA_QPS_INIT ||
        live_qp.programmed_qpc == null ||
        live_qp.programmed_qpc.state != RDMA_QPS_RESET ||
        mem.live_allocations() != live_before)
      `uvm_error("MODIFY_DEFINITIVE", "definitive modify failure changed state or leaked staging")

    // A generation rebind is rejected by the live binding fence before CMQ.
    mem = rdma_mock_host_mem::type_id::create("stale_modify_mem");
    setup_qp_environment("stale_modify", mem, binding, manager, contexts, cmq,
                         executor, pd, cq);
    create_req = make_request("stale_modify_create", binding, pd, cq,
                              RDMA_TRANSPORT_RC);
    executor.create_locked(binding, binding.make_handle(), create_req, 840,
                           qp, result);
    modify_req = rdma_modify_qp_req::type_id::create("stale_modify_req");
    modify_req.owner = binding.make_handle();
    modify_req.qp_h = rdma_clone_handle_value(qp.handle, "stale modify QP");
    modify_req.new_state = RDMA_QPS_INIT;
    binding.generation++;
    calls_before = cmq.calls.size();
    executor.modify_locked(binding, modify_req.owner, modify_req, 841,
                           qp, result);
    if (result == null || result.status == null ||
        result.status.code != RDMA_SC_STALE_GENERATION ||
        qp != null || cmq.calls.size() != calls_before)
      `uvm_error("MODIFY_STALE", "stale generation reached QP modify side effects")
  endtask
endclass
