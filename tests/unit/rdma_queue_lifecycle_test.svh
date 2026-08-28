class rdma_queue_planner_nth_fail_mem extends rdma_mock_host_mem;
  `uvm_object_utils(rdma_queue_planner_nth_fail_mem)

  int unsigned allocate_attempt;
  int unsigned fail_on_allocate;

  function new(string name = "rdma_queue_planner_nth_fail_mem");
    super.new(name);
    allocate_attempt = 0;
    fail_on_allocate = 0;
  endfunction

  virtual function rdma_status allocate(
    rdma_dma_request_context request_context,
    int unsigned size,
    int unsigned alignment,
    rdma_dma_direction_e direction,
    output rdma_dma_mapping mapping
  );
    allocate_attempt++;
    if (allocate_attempt == fail_on_allocate)
      void'(fail_next("allocate", rdma_status::make(
        RDMA_SC_RESOURCE_EXHAUSTED, "injected planner allocation failure"
      )));
    return super.allocate(request_context, size, alignment, direction,
                          mapping);
  endfunction
endclass

class rdma_queue_planner_snapshot_fail_mapping extends rdma_mock_dma_mapping;
  `uvm_object_utils(rdma_queue_planner_snapshot_fail_mapping)

  function new(string name = "rdma_queue_planner_snapshot_fail_mapping");
    super.new(name);
  endfunction

  virtual function rdma_status snapshot_release_authority(
    output rdma_dma_mapping snapshot
  );
    snapshot = null;
    return rdma_status::make(RDMA_SC_INVALID_STATE,
                             "injected authority snapshot failure");
  endfunction
endclass

class rdma_queue_planner_snapshot_fail_mem extends rdma_mock_host_mem;
  `uvm_object_utils(rdma_queue_planner_snapshot_fail_mem)

  function new(string name = "rdma_queue_planner_snapshot_fail_mem");
    super.new(name);
  endfunction

  virtual function rdma_status allocate(
    rdma_dma_request_context request_context,
    int unsigned size,
    int unsigned alignment,
    rdma_dma_direction_e direction,
    output rdma_dma_mapping mapping
  );
    rdma_dma_mapping allocated_mapping;
    rdma_queue_planner_snapshot_fail_mapping failure_mapping;
    rdma_status status;

    mapping = null;
    status = super.allocate(request_context, size, alignment, direction,
                            allocated_mapping);
    if (status == null || !status.ok())
      return status;
    failure_mapping =
      rdma_queue_planner_snapshot_fail_mapping::type_id::create(
        "snapshot_failure_mapping"
      );
    failure_mapping.copy(allocated_mapping);
    mapping = failure_mapping;
    return rdma_status::success();
  endfunction
endclass

class rdma_queue_planner_observing_mem extends rdma_mock_host_mem;
  `uvm_object_utils(rdma_queue_planner_observing_mem)

  rdma_dma_mapping last_allocated_mapping;
  rdma_dma_mapping allocated_mappings[$];

  function new(string name = "rdma_queue_planner_observing_mem");
    super.new(name);
    last_allocated_mapping = null;
  endfunction

  virtual function rdma_status allocate(
    rdma_dma_request_context request_context,
    int unsigned size,
    int unsigned alignment,
    rdma_dma_direction_e direction,
    output rdma_dma_mapping mapping
  );
    rdma_status status;

    status = super.allocate(request_context, size, alignment, direction,
                            mapping);
    if (status != null && status.ok()) begin
      last_allocated_mapping = mapping;
      allocated_mappings.push_back(mapping);
    end
    return status;
  endfunction
endclass

class rdma_queue_planner_second_release_fail_mem extends rdma_mock_host_mem;
  `uvm_object_utils(rdma_queue_planner_second_release_fail_mem)

  int unsigned release_attempt;

  function new(string name = "rdma_queue_planner_second_release_fail_mem");
    super.new(name);
    release_attempt = 0;
  endfunction

  virtual function rdma_status \release (rdma_dma_mapping mapping);
    release_attempt++;
    if (release_attempt == 2)
      void'(fail_next("release", rdma_status::make(
        RDMA_SC_DMA_TRANSLATION, "injected second-segment release failure"
      )));
    return super.\release (mapping);
  endfunction
endclass

class rdma_queue_planner_write_observer_mem extends rdma_mock_host_mem;
  `uvm_object_utils(rdma_queue_planner_write_observer_mem)

  function new(string name = "rdma_queue_planner_write_observer_mem");
    super.new(name);
  endfunction

  virtual function rdma_status write(
    rdma_dma_mapping mapping,
    longint unsigned offset,
    byte data[]
  );
    void'(record_call("write", null, mapping, data.size(), 0,
                      RDMA_DMA_DEVICE_READ, offset, data));
    if (mapping == null || mapping.state != RDMA_MAPPING_ACTIVE)
      return rdma_status::make(RDMA_SC_INVALID_STATE,
                               "observed mapping is not active");
    return rdma_status::success();
  endfunction
endclass

class rdma_queue_executor_trace_mem extends rdma_queue_planner_nth_fail_mem;
  `uvm_object_utils(rdma_queue_executor_trace_mem)

  rdma_resource_kind_e queue_kind;
  int unsigned write_ordinal;
  rdma_mock_call_trace shared_trace;

  function new(string name = "rdma_queue_executor_trace_mem");
    super.new(name);
    queue_kind = RDMA_RESOURCE_CQ;
    write_ordinal = 0;
    shared_trace = null;
  endfunction

  function void set_shared_trace(rdma_mock_call_trace trace);
    shared_trace = trace;
  endfunction

  virtual function rdma_status write(
    rdma_dma_mapping mapping, longint unsigned offset, byte data[]
  );
    string prefix;
    string role;

    write_ordinal++;
    case (queue_kind)
      RDMA_RESOURCE_CQ:  prefix = "CQ";
      RDMA_RESOURCE_SRQ: prefix = "SRQ";
      RDMA_RESOURCE_CEQ: prefix = "CEQ";
      default:           prefix = "AEQ";
    endcase
    if (queue_kind == RDMA_RESOURCE_SRQ) begin
      case (write_ordinal)
        1: role = "SRQ_RING";
        2: role = "SRFQ_RING";
        3: role = "SRQ_SGB";
        4: role = "SRQ_PD";
        default: role = "SRFQ_PD";
      endcase
    end
    else
      role = (write_ordinal == 1) ? {prefix, "_RING"} : {prefix, "_PD"};
    if (shared_trace != null)
      shared_trace.record({"host_write:", role});
    if (find_region(mapping) < 0) begin
      void'(record_call("write", null, mapping, data.size(), 0,
                        RDMA_DMA_DEVICE_READ, offset, data));
      return rdma_status::success();
    end
    return super.write(mapping, offset, data);
  endfunction
endclass

class rdma_queue_executor_trace_context extends rdma_mock_context_backing;
  `uvm_object_utils(rdma_queue_executor_trace_context)

  rdma_mock_call_trace shared_trace;

  function new(string name = "rdma_queue_executor_trace_context");
    super.new(name);
    shared_trace = null;
  endfunction

  function void set_call_trace(rdma_mock_call_trace trace);
    shared_trace = trace;
  endfunction

  virtual function rdma_status write(
    rdma_context_backing_ref context_ref,
    longint unsigned offset,
    byte unsigned data[]
  );
    if (shared_trace != null)
      shared_trace.record(offset == 0 ?
        (context_ref != null && context_ref.resource_kind == RDMA_RESOURCE_SRQ ?
          "context_write:SRFQC_CONTEXT_SLOT" :
          "context_write:CQC_CONTEXT_SLOT") :
        (context_ref != null && context_ref.resource_kind == RDMA_RESOURCE_SRQ ?
          "context_write:SRFQC_CONTEXT_SHADOW" :
          "context_write:CQC_CONTEXT_SHADOW"));
    return super.write(context_ref, offset, data);
  endfunction
endclass

// Destroy-specific adapters keep a semantic trace in addition to the raw
// mock call logs.  The lifecycle executor intentionally talks to abstract
// adapters, so observing the adapter boundary is the most stable way for the
// behavioral tests to prove the hardware/local ordering contract.
class rdma_queue_destroy_trace_mem extends rdma_queue_executor_trace_mem;
  `uvm_object_utils(rdma_queue_destroy_trace_mem)

  bit include_sgb;
  int unsigned release_ordinal;

  function new(string name = "rdma_queue_destroy_trace_mem");
    super.new(name);
    include_sgb = 1'b0;
    release_ordinal = 0;
  endfunction

  function void reset_destroy_trace();
    release_ordinal = 0;
  endfunction

  protected function string release_role(int unsigned ordinal);
    case (queue_kind)
      RDMA_RESOURCE_CQ: begin
        return ordinal == 1 ? "CQ_PD" : "CQ_RING";
      end
      RDMA_RESOURCE_SRQ: begin
        if (include_sgb) begin
          case (ordinal)
            1: return "SRFQ_PD";
            2: return "SRQ_PD";
            3: return "SRQ_SGB";
            4: return "SRFQ_RING";
            default: return "SRQ_RING";
          endcase
        end
        case (ordinal)
          1: return "SRFQ_PD";
          2: return "SRQ_PD";
          3: return "SRFQ_RING";
          default: return "SRQ_RING";
        endcase
      end
      RDMA_RESOURCE_CEQ: begin
        return ordinal == 1 ? "CEQ_PD" : "CEQ_RING";
      end
      default: begin
        return ordinal == 1 ? "AEQ_PD" : "AEQ_RING";
      end
    endcase
  endfunction

  virtual function rdma_status \release (rdma_dma_mapping mapping);
    rdma_status status;
    string role;
    bit is_pd;

    status = super.\release (mapping);
    if (status != null && status.ok() && shared_trace != null) begin
      release_ordinal++;
      role = release_role(release_ordinal);
      is_pd = (queue_kind == RDMA_RESOURCE_CQ && release_ordinal == 1) ||
              (queue_kind == RDMA_RESOURCE_SRQ && release_ordinal <= 2) ||
              (queue_kind inside {RDMA_RESOURCE_CEQ, RDMA_RESOURCE_AEQ} &&
               release_ordinal == 1);
      if (is_pd)
        shared_trace.record({"host_release:", role});
      else
        shared_trace.record({"detach_or_release:", role});
    end
    return status;
  endfunction
endclass

class rdma_queue_destroy_trace_context extends rdma_queue_executor_trace_context;
  `uvm_object_utils(rdma_queue_destroy_trace_context)

  function new(string name = "rdma_queue_destroy_trace_context");
    super.new(name);
  endfunction

  virtual function rdma_status \release (
    rdma_context_backing_ref context_ref
  );
    rdma_status status;

    status = super.\release (context_ref);
    if (status != null && status.ok() && shared_trace != null)
      shared_trace.record("context_release");
    return status;
  endfunction
endclass

class rdma_queue_destroy_trace_cmq extends rdma_mock_cmq_port;
  `uvm_object_utils(rdma_queue_destroy_trace_cmq)

  rdma_mock_call_trace semantic_trace;
  rdma_resource_kind_e destroy_kind;
  int unsigned destroy_call_ordinal;
  bit trace_destroy;
  bit reject_next_flush;
  int unsigned reject_flush_ordinal;
  int unsigned flush_attempt_ordinal;
  rdma_status reject_flush_status;
  bit lose_next_completion;
  // Model an adapter that has already crossed the CMQ boundary but returns a
  // non-OK status without either ticket or completion.  No explicit
  // pre-submit proof accompanies this outcome, so destroy must fail closed.
  bit nonok_null_without_proof;
  rdma_status nonok_null_status;

  function new(string name = "rdma_queue_destroy_trace_cmq");
    super.new(name);
    semantic_trace = null;
    destroy_kind = RDMA_RESOURCE_CQ;
    destroy_call_ordinal = 0;
    trace_destroy = 1'b0;
    reject_next_flush = 1'b0;
    reject_flush_ordinal = 1;
    flush_attempt_ordinal = 0;
    reject_flush_status = null;
    lose_next_completion = 1'b0;
    nonok_null_without_proof = 1'b0;
    nonok_null_status = null;
  endfunction

  function void begin_destroy_trace(
    rdma_mock_call_trace trace,
    rdma_resource_kind_e kind
  );
    semantic_trace = trace;
    destroy_kind = kind;
    destroy_call_ordinal = 0;
    flush_attempt_ordinal = 0;
    trace_destroy = 1'b1;
  endfunction

  protected function string flush_role(int unsigned ordinal);
    if (destroy_kind == RDMA_RESOURCE_SRQ)
      return ordinal == 1 ? "SRFQ_PD" : "SRQ_PD";
    return "CQ_PD";
  endfunction

  virtual task execute(
    rdma_cmq_command_desc command,
    output rdma_cmq_ticket ticket,
    output rdma_cmq_completion completion,
    output rdma_status status
  );
    rdma_mock_call_trace saved_trace;
    int unsigned prior_calls;
    bit is_flush;

    // This override can return before super.execute(); reset the proof bit at
    // the adapter boundary so evidence from an earlier step cannot leak.
    last_execute_no_submit_proven = 1'b0;
    prior_calls = calls.size();
    is_flush = command != null && command.opcode_key != null &&
               command.opcode_key.opcode[7:0] == XTR_V1_OP_OCC_FLUSH;
    if (is_flush)
      flush_attempt_ordinal++;
    if (reject_next_flush && is_flush &&
        flush_attempt_ordinal == reject_flush_ordinal) begin
      reject_next_flush = 1'b0;
      // This injection is intentionally a definitive pre-submit validation
      // rejection; unlike the null-outcome regression below, it carries an
      // explicit adapter proof and may restore ACTIVE.
      last_execute_no_submit_proven = 1'b1;
      ticket = null;
      completion = null;
      status = reject_flush_status == null ?
        rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                          "injected pre-submit flush validation failure") :
        rdma_cmq_clone_status_value(reject_flush_status);
      return;
    end
    saved_trace = call_trace;
    if (trace_destroy)
      call_trace = null;
    super.execute(command, ticket, completion, status);
    call_trace = saved_trace;
    if (nonok_null_without_proof && trace_destroy &&
        calls.size() > prior_calls && destroy_call_ordinal == 0) begin
      nonok_null_without_proof = 1'b0;
      ticket = null;
      completion = null;
      status = nonok_null_status == null ?
        rdma_status::make(RDMA_SC_INVALID_STATE,
                          "injected non-OK null CMQ outcome") :
        rdma_cmq_clone_status_value(nonok_null_status);
    end
    if (lose_next_completion && trace_destroy && calls.size() > prior_calls &&
        destroy_call_ordinal == 0) begin
      // Only consume this injection for the first destructive command.  The
      // completion is deliberately removed after the CMQ has allocated its
      // ticket, modelling a lost/null completion at the executor boundary.
      lose_next_completion = 1'b0;
      completion = null;
    end
    if (trace_destroy && semantic_trace != null && calls.size() > prior_calls) begin
      destroy_call_ordinal++;
      if (is_flush)
        semantic_trace.record({"cmq:0a:", flush_role(destroy_call_ordinal)});
      else
        semantic_trace.record($sformatf("cmq:%02x",
                                        calls[calls.size()-1].opcode));
    end
  endtask
endclass

class rdma_queue_executor_generation_fail extends
  rdma_queue_lifecycle_executor;
  `uvm_object_utils(rdma_queue_executor_generation_fail)

  int unsigned generation_checks;

  function new(string name = "rdma_queue_executor_generation_fail");
    super.new(name);
    generation_checks = 0;
  endfunction

  protected virtual function rdma_status generation_status(
    rdma_function_binding binding,
    rdma_function_handle expected_owner
  );
    generation_checks++;
    if (generation_checks == 2)
      return rdma_status::make(RDMA_SC_STALE_GENERATION,
                               "injected post-create generation change");
    return super.generation_status(binding, expected_owner);
  endfunction
endclass

class rdma_queue_lifecycle_test extends uvm_test;
  `uvm_component_utils(rdma_queue_lifecycle_test)

  function new(string name = "rdma_queue_lifecycle_test",
               uvm_component parent = null);
    super.new(name, parent);
  endfunction

  function automatic void expect_status(
    string label,
    rdma_status status,
    rdma_status_code_e expected
  );
    if (status == null)
      `uvm_error(label, "policy returned a null status")
    else if (status.code != expected)
      `uvm_error(label,
                 $sformatf("expected %s, got %s (%s)", expected.name(),
                           status.code.name(), status.convert2string()))
  endfunction

  function automatic rdma_handle make_handle(
    string name,
    rdma_function_handle owner,
    rdma_resource_kind_e kind,
    int unsigned object_id
  );
    rdma_handle handle;
    handle = rdma_handle::type_id::create(name);
    handle.kind = kind;
    handle.function_uid = owner.function_uid;
    handle.generation = owner.generation;
    handle.object_id = object_id;
    return handle;
  endfunction

  function automatic rdma_function_binding make_binding(
    string name,
    longint unsigned function_uid = 64'h1122_3344_5566_7788,
    int unsigned function_id = 32'h9000_0101,
    int unsigned generation = 7
  );
    rdma_function_binding binding;
    rdma_interrupt_vector_binding vector;

    binding = rdma_function_binding::type_id::create(name);
    binding.function_uid = function_uid;
    binding.global_function_id = function_id;
    binding.generation = generation;
    binding.rdma_vf_id = 8'h22;
    binding.pcie.bdf = '{segment:16'h0, bus:8'h20, device:5'h3,
                         function_num:3'h1};
    binding.pcie.bar[0].base.value = 64'h8000_0000;
    binding.pcie.bar[0].size = 64'h4000;
    binding.pcie.bar[0].enabled = 1'b1;
    binding.notify_bar_id = 0;
    binding.notify_base.value = 64'h8000_2000;
    binding.notify_size = 64'h2000;
    binding.state = RDMA_BIND_ACTIVE;
    binding.owner_h = binding.make_handle();
    binding.queue_dma.requester_bdf = binding.pcie.bdf;
    binding.queue_dma.dma_domain_valid = 1'b1;
    binding.queue_dma.dma_domain_id = 32'h1234_5678;
    binding.queue_caps.min_cq_depth = 16;
    binding.queue_caps.max_cq_depth = 32768;
    binding.queue_caps.min_srq_depth = 16;
    binding.queue_caps.max_srq_depth = 32768;
    binding.queue_caps.max_ceq_depth = 131072;
    binding.queue_caps.max_aeq_depth = 131072;
    binding.queue_caps.max_wq_sge = 8;
    binding.queue_caps.max_queue_ring_bytes = 64'h0020_0000;
    binding.queue_caps.max_sgb_bytes = 64'h0040_0000;
    vector = '{default:'0};
    vector.function_local_vector = 3;
    vector.hardware_eq_vector = 17;
    vector.msix_table_index = 5;
    vector.enabled = 1'b1;
    binding.interrupt_vectors.push_back(vector);
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

  function automatic rdma_dma_mapping make_mapping(
    string name,
    rdma_function_binding binding,
    longint unsigned iova,
    longint unsigned backing,
    longint unsigned size
  );
    rdma_dma_mapping mapping;
    mapping = rdma_dma_mapping::type_id::create(name);
    mapping.function_h = binding.make_handle();
    mapping.requester_bdf = binding.queue_dma.requester_bdf;
    mapping.pasid_valid = binding.queue_dma.pasid_valid;
    mapping.pasid = binding.queue_dma.pasid;
    mapping.dma_domain_valid = binding.queue_dma.dma_domain_valid;
    mapping.dma_domain_id = binding.queue_dma.dma_domain_id;
    mapping.iova.value = iova;
    mapping.backing_addr.value = backing;
    mapping.size = size;
    mapping.direction = RDMA_DMA_BIDIRECTIONAL;
    mapping.permissions =
      '{device_read:1'b1, device_write:1'b1, atomic:1'b0};
    mapping.state = RDMA_MAPPING_ACTIVE;
    return mapping;
  endfunction

  function automatic rdma_queue_backing_slice make_slice(
    string name,
    rdma_queue_backing_role_e role,
    rdma_dma_mapping mapping,
    longint unsigned offset,
    longint unsigned length
  );
    rdma_queue_backing_slice slice;
    slice = rdma_queue_backing_slice::type_id::create(name);
    slice.role = role;
    slice.mapping = mapping;
    slice.mapping_offset = offset;
    slice.length = length;
    slice.logical_queue_offset = 0;
    return slice;
  endfunction

  function automatic rdma_queue_ring_layout make_ring(
    string name,
    rdma_queue_backing_role_e role,
    int unsigned depth,
    int unsigned entry_size,
    bit polarity
  );
    rdma_queue_ring_layout ring;
    longint unsigned logical_bytes;
    longint unsigned storage_bytes;

    logical_bytes = longint'(depth) * entry_size;
    storage_bytes = ((logical_bytes + 4095) / 4096) * 4096;
    ring = rdma_queue_ring_layout::type_id::create(name);
    ring.role = role;
    ring.entry_size_bytes = entry_size;
    ring.depth = depth;
    ring.logical_bytes = logical_bytes;
    ring.storage_bytes = storage_bytes;
    ring.page_count = storage_bytes / 4096;
    ring.initial_polarity = polarity;
    return ring;
  endfunction

  function automatic rdma_queue_backing_ref make_ref(
    string name,
    rdma_queue_backing_role_e role,
    rdma_dma_mapping mapping,
    longint unsigned offset,
    longint unsigned length
  );
    rdma_queue_backing_ref ref_value;
    ref_value = rdma_queue_backing_ref::type_id::create(name);
    ref_value.role = role;
    ref_value.mapping = mapping;
    ref_value.ownership = RDMA_OWNERSHIP_CONTROL_PLANE;
    ref_value.mapping_offset = offset;
    ref_value.length = length;
    return ref_value;
  endfunction

  function automatic int unsigned count_planner_host_calls(
    rdma_mock_host_mem mem,
    string method_name
  );
    int unsigned count;

    count = 0;
    foreach (mem.calls[i]) begin
      if (mem.calls[i].method_name == method_name)
        count++;
    end
    return count;
  endfunction

  function automatic rdma_queue_preflight make_planner_preflight(
    string name,
    rdma_resource_kind_e kind,
    rdma_queue_backing_mode_e mode,
    bit include_sgb = 1'b0,
    int unsigned depth = 64
  );
    rdma_queue_preflight preflight;

    preflight = rdma_queue_preflight::type_id::create(name);
    preflight.resource_kind = kind;
    preflight.depth = depth;
    preflight.cqe_size_bytes = 64;
    preflight.max_sge = include_sgb ? 4 : 2;
    preflight.limit_threshold = 16;
    preflight.backing_spec = rdma_queue_backing_spec::type_id::create(
      {name, "_spec"}
    );
    preflight.backing_spec.mode = mode;
    case (kind)
      RDMA_RESOURCE_CQ: begin
        preflight.required_rings.push_back(make_ring(
          {name, "_cq"}, RDMA_QUEUE_ROLE_CQ_RING, depth, 64, 1'b1
        ));
      end
      RDMA_RESOURCE_SRQ: begin
        preflight.required_rings.push_back(make_ring(
          {name, "_srq"}, RDMA_QUEUE_ROLE_SRQ_RING, depth, 64, 1'b0
        ));
        preflight.required_rings.push_back(make_ring(
          {name, "_srfq"}, RDMA_QUEUE_ROLE_SRFQ_RING, depth, 64, 1'b0
        ));
        if (include_sgb)
          preflight.required_rings.push_back(make_ring(
            {name, "_sgb"}, RDMA_QUEUE_ROLE_SRQ_SGB, depth, 512, 1'b0
          ));
      end
      RDMA_RESOURCE_CEQ: begin
        preflight.required_rings.push_back(make_ring(
          {name, "_ceq"}, RDMA_QUEUE_ROLE_CEQ_RING, depth, 16, 1'b1
        ));
      end
      RDMA_RESOURCE_AEQ: begin
        preflight.required_rings.push_back(make_ring(
          {name, "_aeq"}, RDMA_QUEUE_ROLE_AEQ_RING, depth, 16, 1'b1
        ));
      end
      default: begin
      end
    endcase
    return preflight;
  endfunction

  function automatic void add_borrowed_slice(
    rdma_queue_preflight preflight,
    string name,
    rdma_queue_backing_role_e role,
    rdma_dma_mapping mapping,
    longint unsigned mapping_offset,
    longint unsigned length,
    longint unsigned logical_offset = 0
  );
    rdma_queue_backing_slice slice;

    slice = make_slice(name, role, mapping, mapping_offset, length);
    slice.logical_queue_offset = logical_offset;
    preflight.backing_spec.slices.push_back(slice);
  endfunction

  function automatic void expect_planner_no_host_calls(
    string label,
    rdma_mock_host_mem mem
  );
    if (mem.calls.size() != 0)
      `uvm_error(label, "borrowed validation performed a host-memory call")
  endfunction

  function automatic rdma_context_backing_ref make_context_ref(
    string name,
    rdma_function_binding binding,
    rdma_resource_kind_e kind,
    int unsigned local_id,
    longint unsigned shadow_base,
    longint unsigned view_offset,
    longint unsigned view_length
  );
    rdma_context_backing_ref context_ref;
    context_ref = rdma_context_backing_ref::type_id::create(name);
    context_ref.owner = binding.make_handle();
    context_ref.resource_kind = kind;
    context_ref.local_id = local_id;
    context_ref.shadow_pointer_base.value = shadow_base;
    context_ref.slot_length = 64;
    context_ref.shadow_view_offset = view_offset;
    context_ref.shadow_view_length = view_length;
    return context_ref;
  endfunction

  function automatic rdma_queue_backing_plan make_cq_plan(
    rdma_function_binding binding
  );
    rdma_queue_backing_plan plan;
    rdma_dma_mapping ring_mapping;
    rdma_dma_mapping pd_mapping;
    plan = rdma_queue_backing_plan::type_id::create("cq_plan");
    plan.resource_kind = RDMA_RESOURCE_CQ;
    ring_mapping = make_mapping("cq_ring_mapping", binding,
                                64'h0000_0002_0000_0000,
                                64'h0000_0000_3000_0000, 64'h200000);
    pd_mapping = make_mapping("cq_pd_mapping", binding,
                              64'h0000_0003_1234_5000,
                              64'h0000_0000_4000_0000, 4096);
    plan.rings.push_back(make_ring("cq_ring", RDMA_QUEUE_ROLE_CQ_RING,
                                   64, 64, 1'b1));
    plan.refs.push_back(make_ref("cq_ring_ref", RDMA_QUEUE_ROLE_CQ_RING,
                                 ring_mapping, 0, 4096));
    plan.refs.push_back(make_ref("cq_pd_ref", RDMA_QUEUE_ROLE_CQ_PD,
                                 pd_mapping, 0, 4096));
    plan.context_ref = make_context_ref("cqc_context", binding,
      RDMA_RESOURCE_CQ, 21'h12345, 64'h0000_0004_5678_9000, 48, 8);
    return plan;
  endfunction

  function automatic rdma_queue_backing_plan make_srq_plan(
    rdma_function_binding binding
  );
    rdma_queue_backing_plan plan;
    rdma_dma_mapping ring_mapping;
    rdma_dma_mapping srfq_mapping;
    rdma_dma_mapping srq_pd_mapping;
    rdma_dma_mapping srfq_pd_mapping;
    plan = rdma_queue_backing_plan::type_id::create("srq_plan");
    plan.resource_kind = RDMA_RESOURCE_SRQ;
    ring_mapping = make_mapping("srq_ring_mapping", binding,
                                64'h0000_0005_0000_0000,
                                64'h0000_0000_5000_0000, 4096);
    srfq_mapping = make_mapping("srfq_ring_mapping", binding,
                                64'h0000_0005_0001_0000,
                                64'h0000_0000_5001_0000, 4096);
    srq_pd_mapping = make_mapping("srq_pd_mapping", binding,
                                  64'h0000_0006_1111_1000,
                                  64'h0000_0000_6000_0000, 4096);
    srfq_pd_mapping = make_mapping("srfq_pd_mapping", binding,
                                   64'h0000_0007_2222_2000,
                                   64'h0000_0000_7000_0000, 4096);
    plan.rings.push_back(make_ring("srq_ring", RDMA_QUEUE_ROLE_SRQ_RING,
                                   64, 64, 1'b0));
    plan.rings.push_back(make_ring("srfq_ring", RDMA_QUEUE_ROLE_SRFQ_RING,
                                   64, 64, 1'b0));
    plan.refs.push_back(make_ref("srq_ring_ref", RDMA_QUEUE_ROLE_SRQ_RING,
                                 ring_mapping, 0, 4096));
    plan.refs.push_back(make_ref("srfq_ring_ref", RDMA_QUEUE_ROLE_SRFQ_RING,
                                 srfq_mapping, 0, 4096));
    plan.refs.push_back(make_ref("srq_pd_ref", RDMA_QUEUE_ROLE_SRQ_PD,
                                 srq_pd_mapping, 0, 4096));
    plan.refs.push_back(make_ref("srfq_pd_ref", RDMA_QUEUE_ROLE_SRFQ_PD,
                                 srfq_pd_mapping, 0, 4096));
    plan.context_ref = make_context_ref("srqc_context", binding,
      RDMA_RESOURCE_SRQ, 16'h2345, 64'h0000_0008_3333_3000, 28, 4);
    plan.context_ref.slot_length = 32;
    return plan;
  endfunction

  function automatic rdma_queue_backing_plan make_eq_plan(
    string name,
    rdma_function_binding binding,
    rdma_resource_kind_e kind
  );
    rdma_queue_backing_plan plan;
    rdma_queue_backing_role_e ring_role;
    rdma_queue_backing_role_e pd_role;
    rdma_dma_mapping ring_mapping;
    rdma_dma_mapping pd_mapping;

    plan = rdma_queue_backing_plan::type_id::create(name);
    plan.resource_kind = kind;
    ring_role = (kind == RDMA_RESOURCE_CEQ) ? RDMA_QUEUE_ROLE_CEQ_RING
                                            : RDMA_QUEUE_ROLE_AEQ_RING;
    pd_role = (kind == RDMA_RESOURCE_CEQ) ? RDMA_QUEUE_ROLE_CEQ_PD
                                          : RDMA_QUEUE_ROLE_AEQ_PD;
    ring_mapping = make_mapping({name, "_ring_mapping"}, binding,
                                64'h0000_0009_0000_0000,
                                64'h0000_0000_9000_0000, 4096);
    pd_mapping = make_mapping({name, "_pd_mapping"}, binding,
                              64'h0000_000a_4444_4000,
                              64'h0000_0000_a000_0000, 4096);
    plan.rings.push_back(make_ring({name, "_ring"}, ring_role, 64, 16,
                                   1'b1));
    plan.refs.push_back(make_ref({name, "_ring_ref"}, ring_role,
                                 ring_mapping, 0, 4096));
    plan.refs.push_back(make_ref({name, "_pd_ref"}, pd_role,
                                 pd_mapping, 0, 4096));
    return plan;
  endfunction

  function automatic void expect_canonical_image(
    string label,
    rdma_hw_model model,
    rdma_image_kind_e kind,
    string object_type,
    bit [7:0] opcode,
    byte unsigned actual[]
  );
    rdma_codec_registry registry;
    rdma_codec_key key;
    rdma_codec_base codec;
    rdma_hw_image expected;
    rdma_status status;

    registry = rdma_codec_registry::type_id::create({label, "_registry"});
    status = rdma_xtr_v1_register_context_body_codecs(registry);
    expect_status({label, "_REGISTER"}, status, RDMA_SC_OK);
    key.hw_version = "xtr_v1";
    key.image_kind = kind;
    key.object_type = object_type;
    key.variant = "create";
    key.opcode = opcode;
    status = registry.lookup(key, codec);
    expect_status({label, "_LOOKUP"}, status, RDMA_SC_OK);
    if (status == null || !status.ok() || codec == null)
      return;
    status = codec.encode(model, expected);
    expect_status({label, "_ENCODE"}, status, RDMA_SC_OK);
    if (status == null || !status.ok() || expected == null)
      return;
    if (actual.size() != expected.bytes.size()) begin
      `uvm_error(label, "context slot image length is not canonical")
      return;
    end
    foreach (actual[i]) begin
      if (actual[i] != expected.bytes[i]) begin
        `uvm_error(label, $sformatf("context byte %0d differs", i))
        return;
      end
    end
  endfunction

  function automatic void check_preflight();
    rdma_cq_lifecycle_policy cq_policy;
    rdma_srq_lifecycle_policy srq_policy;
    rdma_ceq_lifecycle_policy ceq_policy;
    rdma_aeq_lifecycle_policy aeq_policy;
    rdma_resource_manager manager;
    rdma_function_binding binding;
    rdma_function_binding other_binding;
    rdma_ceq ceq_dependency;
    rdma_ceq other_ceq;
    rdma_pd pd_dependency;
    rdma_create_cq_req cq_req;
    rdma_create_srq_req srq_req;
    rdma_create_ceq_req ceq_req;
    rdma_create_aeq_req aeq_req;
    rdma_queue_preflight preflight;
    rdma_queue_backing_slice slice;
    rdma_dma_mapping borrowed_mapping;

    cq_policy = rdma_cq_lifecycle_policy::type_id::create("cq_policy");
    srq_policy = rdma_srq_lifecycle_policy::type_id::create("srq_policy");
    ceq_policy = rdma_ceq_lifecycle_policy::type_id::create("ceq_policy");
    aeq_policy = rdma_aeq_lifecycle_policy::type_id::create("aeq_policy");
    manager = rdma_resource_manager::type_id::create("policy_manager");
    binding = make_binding("policy_binding");
    expect_status("SETUP_CEQ", manager.create_ceq(binding, ceq_dependency),
                  RDMA_SC_OK);
    expect_status("SETUP_PD", manager.create_pd(binding, pd_dependency),
                  RDMA_SC_OK);

    cq_req = rdma_create_cq_req::type_id::create("cq_req");
    cq_req.owner = binding.make_handle();
    cq_req.depth = 64;
    cq_req.ceq_h = ceq_dependency.handle;
    for (int unsigned cqe_size = 32; cqe_size <= 128; cqe_size *= 2) begin
      cq_req.cqe_size_bytes = cqe_size;
      preflight = null;
      expect_status($sformatf("CQ_PREFLIGHT_%0d", cqe_size),
        cq_policy.preflight(binding, cq_req, manager, preflight), RDMA_SC_OK);
      if (preflight == null || preflight.required_rings.size() != 1 ||
          preflight.required_rings[0].entry_size_bytes != cqe_size ||
          preflight.required_rings[0].initial_polarity != 1'b1 ||
          preflight.required_rings[0].storage_bytes !=
            ((longint'(64) * cqe_size + 4095) / 4096) * 4096)
        `uvm_error("CQ_PREFLIGHT", "CQ boundary layout is incorrect")
    end

    cq_req.cqe_size_bytes = 64;
    cq_req.depth = 32768;
    expect_status("CQ_2M_BOUNDARY",
      cq_policy.preflight(binding, cq_req, manager, preflight), RDMA_SC_OK);
    if (preflight == null ||
        preflight.required_rings[0].storage_bytes != 64'h0020_0000)
      `uvm_error("CQ_2M_BOUNDARY", "CQ 2 MiB boundary is incorrect")

    cq_req.depth = 65536;
    binding.queue_caps.max_cq_depth = 65536;
    binding.queue_caps.max_queue_ring_bytes = 64'h0040_0000;
    preflight = rdma_queue_preflight::type_id::create("stale_cq_preflight");
    expect_status("CQ_OVER_2M",
      cq_policy.preflight(binding, cq_req, manager, preflight),
      RDMA_SC_INVALID_ARGUMENT);
    if (preflight != null)
      `uvm_error("CQ_OVER_2M", "failed preflight published stale output")

    other_binding = make_binding("other_binding", 64'h8877_6655_4433_2211,
                                 32'h9000_0202, 9);
    expect_status("SETUP_OTHER_CEQ",
                  manager.create_ceq(other_binding, other_ceq), RDMA_SC_OK);
    cq_req.depth = 64;
    cq_req.ceq_h = other_ceq.handle;
    expect_status("CQ_CROSS_FUNCTION",
      cq_policy.preflight(binding, cq_req, manager, preflight),
      RDMA_SC_INVALID_ARGUMENT);

    srq_req = rdma_create_srq_req::type_id::create("srq_req");
    srq_req.owner = binding.make_handle();
    srq_req.depth = 64;
    srq_req.max_sge = 4;
    srq_req.limit_threshold = 16;
    srq_req.pd_h = pd_dependency.handle;
    preflight = null;
    expect_status("SRQ_PREFLIGHT",
      srq_policy.preflight(binding, srq_req, manager, preflight), RDMA_SC_OK);
    if (preflight == null || preflight.required_rings.size() != 3 ||
        preflight.required_rings[0].role != RDMA_QUEUE_ROLE_SRQ_RING ||
        preflight.required_rings[0].entry_size_bytes != 64 ||
        preflight.required_rings[1].role != RDMA_QUEUE_ROLE_SRFQ_RING ||
        preflight.required_rings[1].entry_size_bytes != 64 ||
        preflight.required_rings[2].role != RDMA_QUEUE_ROLE_SRQ_SGB ||
        preflight.required_rings[2].entry_size_bytes != 512)
      `uvm_error("SRQ_PREFLIGHT", "SRQ/SRFQ/SGB layout is incorrect")
    srq_req.depth = 8192;
    expect_status("SRQ_SGB_ABOVE_PD_CEILING",
      srq_policy.preflight(binding, srq_req, manager, preflight), RDMA_SC_OK);
    if (preflight == null || preflight.required_rings.size() != 3 ||
        preflight.required_rings[2].storage_bytes != 64'h0040_0000 ||
        preflight.required_rings[2].page_count != 1024)
      `uvm_error("SRQ_SGB_ABOVE_PD_CEILING",
                 "large SGB layout inherited the PD-backed ring ceiling")
    srq_req.depth = 64;
    srq_req.max_sge = 2;
    expect_status("SRQ_NO_SGB",
      srq_policy.preflight(binding, srq_req, manager, preflight), RDMA_SC_OK);
    if (preflight == null || preflight.required_rings.size() != 2)
      `uvm_error("SRQ_NO_SGB", "max_sge=2 unexpectedly requires SGB")
    srq_req.max_sge = binding.queue_caps.max_wq_sge + 1;
    expect_status("SRQ_MAX_SGE",
      srq_policy.preflight(binding, srq_req, manager, preflight),
      RDMA_SC_INVALID_ARGUMENT);
    srq_req.max_sge = 2;
    srq_req.limit_threshold = 18;
    expect_status("SRQ_LIMIT_GRANULARITY",
      srq_policy.preflight(binding, srq_req, manager, preflight),
      RDMA_SC_INVALID_ARGUMENT);

    borrowed_mapping = make_mapping("borrowed_mapping", binding,
                                    64'h0000_000b_0000_0000,
                                    64'h0000_0000_b000_0000, 64'h200000);
    srq_req.limit_threshold = 16;
    srq_req.max_sge = 4;
    srq_req.payload_backing.mode = RDMA_QUEUE_BACKING_BORROWED;
    srq_req.payload_backing.slices.delete();
    slice = make_slice("borrowed_srq", RDMA_QUEUE_ROLE_SRQ_RING,
                       borrowed_mapping, 0, 4096);
    srq_req.payload_backing.slices.push_back(slice);
    slice = make_slice("borrowed_srfq", RDMA_QUEUE_ROLE_SRFQ_RING,
                       borrowed_mapping, 4096, 4096);
    srq_req.payload_backing.slices.push_back(slice);
    expect_status("SRQ_BORROWED_MISSING_SGB",
      srq_policy.preflight(binding, srq_req, manager, preflight),
      RDMA_SC_INVALID_ARGUMENT);

    ceq_req = rdma_create_ceq_req::type_id::create("ceq_req");
    ceq_req.owner = binding.make_handle();
    ceq_req.depth = 64;
    ceq_req.vector_id = 3;
    expect_status("CEQ_VECTOR",
      ceq_policy.preflight(binding, ceq_req, manager, preflight), RDMA_SC_OK);
    if (preflight == null || preflight.hardware_vector != 17 ||
        preflight.msix_table_index != 5 ||
        preflight.required_rings[0].entry_size_bytes != 16 ||
        preflight.required_rings[0].initial_polarity != 1'b1)
      `uvm_error("CEQ_VECTOR", "local vector was not resolved")
    binding.interrupt_vectors[0].enabled = 1'b0;
    expect_status("CEQ_DISABLED_VECTOR",
      ceq_policy.preflight(binding, ceq_req, manager, preflight),
      RDMA_SC_INVALID_STATE);
    binding.interrupt_vectors[0].enabled = 1'b1;
    binding.interrupt_vectors[0].hardware_eq_vector = 17'h1_0000;
    expect_status("CEQ_VECTOR_WIDTH",
      ceq_policy.preflight(binding, ceq_req, manager, preflight),
      RDMA_SC_INVALID_ARGUMENT);
    binding.interrupt_vectors[0].hardware_eq_vector = 17;
    ceq_req.depth = 131072;
    expect_status("CEQ_2M_BOUNDARY",
      ceq_policy.preflight(binding, ceq_req, manager, preflight), RDMA_SC_OK);

    aeq_req = rdma_create_aeq_req::type_id::create("aeq_req");
    aeq_req.owner = binding.make_handle();
    aeq_req.depth = 131072;
    aeq_req.vector_id = 3;
    expect_status("AEQ_2M_BOUNDARY",
      aeq_policy.preflight(binding, aeq_req, manager, preflight), RDMA_SC_OK);
    aeq_req.depth = 262144;
    binding.queue_caps.max_aeq_depth = 262144;
    binding.queue_caps.max_queue_ring_bytes = 64'h0040_0000;
    expect_status("AEQ_OVER_2M",
      aeq_policy.preflight(binding, aeq_req, manager, preflight),
      RDMA_SC_INVALID_ARGUMENT);

    // Keeps a wrong typed request from accidentally passing a public policy.
    expect_status("CQ_REJECTS_AEQ_REQUEST",
      cq_policy.preflight(binding, aeq_req, manager, preflight),
      RDMA_SC_INVALID_ARGUMENT);
  endfunction

  function automatic void check_backing_planner_positive();
    rdma_function_binding binding;
    rdma_function_handle owner;
    rdma_handle resource_h;
    rdma_queue_backing_planner planner;
    rdma_mock_host_mem mem;
    rdma_queue_planner_observing_mem observing_mem;
    rdma_queue_preflight preflight;
    rdma_queue_backing_plan plan;
    rdma_dma_mapping mapping;
    rdma_dma_mapping second_mapping;
    rdma_queue_planner_write_observer_mem fragmented_mem;
    rdma_xtr_v1_queue_pd_codec pd_codec;
    rdma_status status;
    byte data[];
    bit complete;

    binding = make_binding("planner_binding");
    owner = binding.make_handle();
    pd_codec = rdma_xtr_v1_queue_pd_codec::type_id::create(
      "planner_pd_codec"
    );

    // Owned CQ: payload then PD, both authority snapshots, IOVA pages, and
    // complete zero/PD initialization.
    observing_mem = rdma_queue_planner_observing_mem::type_id::create(
      "owned_cq_mem"
    );
    mem = observing_mem;
    planner = rdma_queue_backing_planner::type_id::create("owned_cq_planner");
    expect_status("OWNED_CQ_CONFIGURE", planner.configure(mem), RDMA_SC_OK);
    preflight = make_planner_preflight(
      "owned_cq_preflight", RDMA_RESOURCE_CQ, RDMA_QUEUE_BACKING_OWNED
    );
    resource_h = make_handle("owned_cq_resource", owner,
                             RDMA_RESOURCE_CQ, 32'h1001);
    expect_status("OWNED_CQ_SPEC", planner.validate_spec(binding, preflight),
                  RDMA_SC_OK);
    plan = null;
    expect_status("OWNED_CQ_PLAN", planner.materialize(
      binding, preflight, resource_h, plan), RDMA_SC_OK);
    if (plan == null || plan.context_ref != null || plan.rings.size() != 1 ||
        plan.refs.size() != 2 ||
        plan.refs[0].role != RDMA_QUEUE_ROLE_CQ_RING ||
        plan.refs[1].role != RDMA_QUEUE_ROLE_CQ_PD ||
        plan.refs[0].ownership != RDMA_OWNERSHIP_CONTROL_PLANE ||
        plan.refs[1].ownership != RDMA_OWNERSHIP_CONTROL_PLANE ||
        plan.rings[0].pages.size() != 1 ||
        plan.rings[0].pages[0].page_iova.value !=
          plan.refs[0].mapping.iova.value ||
        plan.flush_targets.size() != 1 ||
        plan.flush_targets[0].role != RDMA_QUEUE_ROLE_CQ_PD ||
        plan.flush_targets[0].phase != RDMA_QUEUE_FLUSH_POST_DELETE)
      `uvm_error("OWNED_CQ_PLAN", "owned CQ plan geometry is incorrect")
    if (count_planner_host_calls(mem, "allocate") != 2 ||
        mem.calls[0].size != 4096 || mem.calls[0].alignment != 4096 ||
        mem.calls[0].direction != RDMA_DMA_DEVICE_WRITE ||
        mem.calls[1].size != 4096 || mem.calls[1].alignment != 4096 ||
        mem.calls[1].direction != RDMA_DMA_DEVICE_READ ||
        mem.calls[0].request_context == null ||
        mem.calls[0].request_context.owner_h == null ||
        !mem.calls[0].request_context.owner_h.same_instance(resource_h) ||
        mem.calls[0].request_context.requester_bdf !=
          binding.queue_dma.requester_bdf ||
        mem.calls[0].request_context.dma_domain_id !=
          binding.queue_dma.dma_domain_id)
      `uvm_error("OWNED_CQ_ALLOC", "owned CQ allocation contract is wrong")
    status = mem.regions[0].mapping.release_authority_status(
      plan.refs[0].mapping
    );
    expect_status("OWNED_CQ_PAYLOAD_AUTHORITY", status, RDMA_SC_OK);
    status = mem.regions[1].mapping.release_authority_status(
      plan.refs[1].mapping
    );
    expect_status("OWNED_CQ_PD_AUTHORITY", status, RDMA_SC_OK);
    if (observing_mem.allocated_mappings.size() != 2 ||
        plan.refs[0].mapping == observing_mem.allocated_mappings[0] ||
        plan.refs[1].mapping == observing_mem.allocated_mappings[1] ||
        plan.refs[0].mapping.iova.value !=
          observing_mem.allocated_mappings[0].iova.value ||
        plan.refs[1].mapping.iova.value !=
          observing_mem.allocated_mappings[1].iova.value)
      `uvm_error("OWNED_CQ_DISTINCT_AUTHORITY_SNAPSHOT",
                 "planner published the acquired mapping as cleanup authority")
    expect_status("OWNED_CQ_INITIALIZE", planner.initialize_payload_and_pd(
      binding, plan, pd_codec), RDMA_SC_OK);
    if (count_planner_host_calls(mem, "write") != 2)
      `uvm_error("OWNED_CQ_INITIALIZE", "CQ initialization write count is wrong")
    expect_status("OWNED_CQ_READ_PAYLOAD",
      mem.read(plan.refs[0].mapping, 0, 4096, data), RDMA_SC_OK);
    foreach (data[i]) begin
      if (data[i] != 0) begin
        `uvm_error("OWNED_CQ_ZERO", "CQ payload was not zero initialized")
        break;
      end
    end
    expect_status("OWNED_CQ_READ_PD",
      mem.read(plan.refs[1].mapping, 0, 4096, data), RDMA_SC_OK);
    if (data.size() != 4096 || data[0] != 8'h00 || data[1] != 8'h00 ||
        data[2] != 8'h00 || data[3] != 8'h01 || data[4] != 8'h00 ||
        data[5] != 8'h00 || data[6] != 8'h02 || data[7] != 8'h21)
      `uvm_error("OWNED_CQ_PD", "CQ page directory first entry is wrong")
    for (int unsigned i = 8; i < data.size(); i++) begin
      if (data[i] != 0) begin
        `uvm_error("OWNED_CQ_PD", "unused CQ PD bytes are not zero")
        break;
      end
    end
    complete = 1'b0;
    expect_status("OWNED_CQ_PAYLOAD_CLEANUP",
      planner.cleanup_local_role(plan.refs[0], complete), RDMA_SC_OK);
    if (!complete || count_planner_host_calls(mem, "release") != 1)
      `uvm_error("OWNED_CQ_PAYLOAD_CLEANUP", "owned cleanup did not complete")
    complete = 1'b0;
    expect_status("OWNED_CQ_PAYLOAD_CLEANUP_AGAIN",
      planner.cleanup_local_role(plan.refs[0], complete), RDMA_SC_OK);
    if (!complete || count_planner_host_calls(mem, "release") != 1)
      `uvm_error("OWNED_CQ_PAYLOAD_CLEANUP_AGAIN",
                 "owned cleanup was not exactly once")
    complete = 1'b0;
    expect_status("OWNED_CQ_PD_CLEANUP",
      planner.cleanup_local_role(plan.refs[1], complete), RDMA_SC_OK);

    // Borrowed CQ proves that the device page list uses IOVA, not backing.
    mem = rdma_mock_host_mem::type_id::create("borrowed_cq_mem");
    planner = rdma_queue_backing_planner::type_id::create(
      "borrowed_cq_planner"
    );
    expect_status("BORROWED_CQ_CONFIGURE", planner.configure(mem), RDMA_SC_OK);
    preflight = make_planner_preflight(
      "borrowed_cq_preflight", RDMA_RESOURCE_CQ,
      RDMA_QUEUE_BACKING_BORROWED
    );
    mapping = make_mapping("borrowed_cq_mapping", binding,
      64'h0000_0021_0000_0000, 64'h0000_0099_0000_0000, 4096);
    add_borrowed_slice(preflight, "borrowed_cq_slice",
      RDMA_QUEUE_ROLE_CQ_RING, mapping, 0, 4096);
    resource_h = make_handle("borrowed_cq_resource", owner,
                             RDMA_RESOURCE_CQ, 32'h1002);
    expect_status("BORROWED_CQ_SPEC", planner.validate_spec(
      binding, preflight), RDMA_SC_OK);
    expect_planner_no_host_calls("BORROWED_CQ_SPEC", mem);
    plan = null;
    expect_status("BORROWED_PLAN", planner.materialize(
      binding, preflight, resource_h, plan), RDMA_SC_OK);
    if (plan == null || plan.refs.size() != 2 ||
        plan.refs[0].ownership != RDMA_OWNERSHIP_BORROWED ||
        plan.rings[0].pages[0].page_iova.value !=
          64'h0000_0021_0000_0000)
      `uvm_error("BORROWED_PLAN", "page list did not use mapping IOVA")
    if (plan != null && plan.refs[0].mapping.backing_addr.value ==
                        plan.rings[0].pages[0].page_iova.value)
      `uvm_error("BORROWED_PLAN", "fixture failed to separate address spaces")
    if (count_planner_host_calls(mem, "allocate") != 1 ||
        mem.calls[0].direction != RDMA_DMA_DEVICE_READ)
      `uvm_error("BORROWED_PLAN", "borrowed CQ allocated more than its PD")
    complete = 1'b0;
    expect_status("BORROWED_CQ_CLEANUP",
      planner.cleanup_local_role(plan.refs[0], complete), RDMA_SC_OK);
    if (!complete || count_planner_host_calls(mem, "release") != 0)
      `uvm_error("BORROWED_CQ_CLEANUP", "borrowed cleanup called release")
    complete = 1'b0;
    expect_status("BORROWED_CQ_PD_CLEANUP",
      planner.cleanup_local_role(plan.refs[1], complete), RDMA_SC_OK);

    // A fragmented role remains one top-level ref while retaining every
    // authoritative slice.  First cover adjacent slices of one mapping.
    mem = rdma_mock_host_mem::type_id::create("fragmented_same_mapping_mem");
    planner = rdma_queue_backing_planner::type_id::create(
      "fragmented_same_mapping_planner"
    );
    expect_status("FRAGMENTED_SAME_CONFIGURE", planner.configure(mem),
                  RDMA_SC_OK);
    preflight = make_planner_preflight(
      "fragmented_same_preflight", RDMA_RESOURCE_CQ,
      RDMA_QUEUE_BACKING_BORROWED, 1'b0, 128
    );
    mapping = make_mapping("fragmented_same_mapping", binding,
      64'h0000_0022_0000_0000, 64'h0000_009a_0000_0000, 8192);
    add_borrowed_slice(preflight, "fragmented_same_first",
      RDMA_QUEUE_ROLE_CQ_RING, mapping, 0, 4096, 0);
    add_borrowed_slice(preflight, "fragmented_same_second",
      RDMA_QUEUE_ROLE_CQ_RING, mapping, 4096, 4096, 4096);
    resource_h = make_handle("fragmented_same_resource", owner,
                             RDMA_RESOURCE_CQ, 32'h1003);
    plan = null;
    expect_status("FRAGMENTED_SAME_PLAN", planner.materialize(
      binding, preflight, resource_h, plan), RDMA_SC_OK);
    if (plan == null || plan.refs.size() != 2 ||
        plan.refs[0].additional_segments.size() != 1 ||
        plan.refs[0].additional_segments[0].mapping_offset != 4096 ||
        plan.refs[0].additional_segments[0].logical_queue_offset != 4096 ||
        plan.rings[0].pages.size() != 2 ||
        plan.rings[0].pages[1].page_iova.value !=
          64'h0000_0022_0000_1000)
      `uvm_error("FRAGMENTED_SAME_PLAN",
                 "same-mapping fragments lost grouped authority")
    complete = 1'b0;
    expect_status("FRAGMENTED_SAME_PD_CLEANUP",
      planner.cleanup_local_role(plan.refs[1], complete), RDMA_SC_OK);

    // Then cover two mappings and prove initialization writes both physical
    // segments rather than only the primary slice.
    fragmented_mem = rdma_queue_planner_write_observer_mem::type_id::create(
      "fragmented_multi_mapping_mem"
    );
    planner = rdma_queue_backing_planner::type_id::create(
      "fragmented_multi_mapping_planner"
    );
    expect_status("FRAGMENTED_MULTI_CONFIGURE",
      planner.configure(fragmented_mem), RDMA_SC_OK);
    preflight = make_planner_preflight(
      "fragmented_multi_preflight", RDMA_RESOURCE_CQ,
      RDMA_QUEUE_BACKING_BORROWED, 1'b0, 128
    );
    mapping = make_mapping("fragmented_multi_first_mapping", binding,
      64'h0000_0023_0000_0000, 64'h0000_009b_0000_0000, 4096);
    second_mapping = make_mapping("fragmented_multi_second_mapping", binding,
      64'h0000_0024_0000_0000, 64'h0000_009c_0000_0000, 8192);
    add_borrowed_slice(preflight, "fragmented_multi_first",
      RDMA_QUEUE_ROLE_CQ_RING, mapping, 0, 4096, 0);
    add_borrowed_slice(preflight, "fragmented_multi_second",
      RDMA_QUEUE_ROLE_CQ_RING, second_mapping, 4096, 4096, 4096);
    resource_h = make_handle("fragmented_multi_resource", owner,
                             RDMA_RESOURCE_CQ, 32'h1004);
    plan = null;
    expect_status("FRAGMENTED_MULTI_PLAN", planner.materialize(
      binding, preflight, resource_h, plan), RDMA_SC_OK);
    if (plan == null || plan.refs[0].additional_segments.size() != 1 ||
        plan.rings[0].pages.size() != 2 ||
        plan.rings[0].pages[0].page_iova.value !=
          64'h0000_0023_0000_0000 ||
        plan.rings[0].pages[1].page_iova.value !=
          64'h0000_0024_0000_1000)
      `uvm_error("FRAGMENTED_MULTI_PLAN",
                 "multi-mapping fragments lost grouped authority")
    expect_status("FRAGMENTED_MULTI_INITIALIZE",
      planner.initialize_payload_and_pd(binding, plan, pd_codec), RDMA_SC_OK);
    if (count_planner_host_calls(fragmented_mem, "write") != 3 ||
        fragmented_mem.calls[1].mapping.iova.value !=
          64'h0000_0023_0000_0000 ||
        fragmented_mem.calls[1].offset != 0 ||
        fragmented_mem.calls[1].data.size() != 4096 ||
        fragmented_mem.calls[2].mapping.iova.value !=
          64'h0000_0024_0000_0000 ||
        fragmented_mem.calls[2].offset != 4096 ||
        fragmented_mem.calls[2].data.size() != 4096)
      `uvm_error("FRAGMENTED_MULTI_INITIALIZE",
                 "initialization did not write every borrowed segment")
    else begin
      foreach (fragmented_mem.calls[1].data[i]) begin
        if (fragmented_mem.calls[1].data[i] != 0)
          `uvm_error("FRAGMENTED_MULTI_ZERO", "primary segment was not zeroed")
      end
      foreach (fragmented_mem.calls[2].data[i]) begin
        if (fragmented_mem.calls[2].data[i] != 0)
          `uvm_error("FRAGMENTED_MULTI_ZERO", "additional segment was not zeroed")
      end
    end
    complete = 1'b0;
    expect_status("FRAGMENTED_MULTI_PD_CLEANUP",
      planner.cleanup_local_role(plan.refs[1], complete), RDMA_SC_OK);

    // Owned and borrowed compound SRQ plans use request payload order and
    // fixed SRQ_PD/SRFQ_PD order, with no planner-owned context authority.
    mem = rdma_mock_host_mem::type_id::create("owned_srq_mem");
    planner = rdma_queue_backing_planner::type_id::create(
      "owned_srq_planner"
    );
    expect_status("OWNED_SRQ_CONFIGURE", planner.configure(mem), RDMA_SC_OK);
    preflight = make_planner_preflight(
      "owned_srq_preflight", RDMA_RESOURCE_SRQ,
      RDMA_QUEUE_BACKING_OWNED, 1'b1
    );
    resource_h = make_handle("owned_srq_resource", owner,
                             RDMA_RESOURCE_SRQ, 32'h2001);
    plan = null;
    expect_status("OWNED_SRQ_PLAN", planner.materialize(
      binding, preflight, resource_h, plan), RDMA_SC_OK);
    if (plan == null || plan.context_ref != null || plan.rings.size() != 3 ||
        plan.refs.size() != 5 ||
        plan.refs[0].role != RDMA_QUEUE_ROLE_SRQ_RING ||
        plan.refs[1].role != RDMA_QUEUE_ROLE_SRFQ_RING ||
        plan.refs[2].role != RDMA_QUEUE_ROLE_SRQ_SGB ||
        plan.refs[3].role != RDMA_QUEUE_ROLE_SRQ_PD ||
        plan.refs[4].role != RDMA_QUEUE_ROLE_SRFQ_PD ||
        plan.flush_targets.size() != 2 ||
        plan.flush_targets[0].role != RDMA_QUEUE_ROLE_SRFQ_PD ||
        plan.flush_targets[1].role != RDMA_QUEUE_ROLE_SRQ_PD)
      `uvm_error("OWNED_SRQ_PLAN", "owned SRQ role ordering is wrong")
    if (count_planner_host_calls(mem, "allocate") != 5 ||
        mem.calls[0].direction != RDMA_DMA_DEVICE_READ ||
        mem.calls[1].direction != RDMA_DMA_DEVICE_READ ||
        mem.calls[2].direction != RDMA_DMA_DEVICE_READ ||
        mem.calls[3].direction != RDMA_DMA_DEVICE_READ ||
        mem.calls[4].direction != RDMA_DMA_DEVICE_READ ||
        mem.calls[2].size != 32768)
      `uvm_error("OWNED_SRQ_PLAN", "owned SRQ allocations are incorrect")
    foreach (plan.refs[i]) begin
      complete = 1'b0;
      expect_status($sformatf("OWNED_SRQ_CLEANUP_%0d", i),
        planner.cleanup_local_role(plan.refs[i], complete), RDMA_SC_OK);
    end
    if (count_planner_host_calls(mem, "release") != 5)
      `uvm_error("OWNED_SRQ_CLEANUP", "owned SRQ release count is wrong")

    mem = rdma_mock_host_mem::type_id::create("borrowed_srq_mem");
    planner = rdma_queue_backing_planner::type_id::create(
      "borrowed_srq_planner"
    );
    expect_status("BORROWED_SRQ_CONFIGURE", planner.configure(mem), RDMA_SC_OK);
    preflight = make_planner_preflight(
      "borrowed_srq_preflight", RDMA_RESOURCE_SRQ,
      RDMA_QUEUE_BACKING_BORROWED, 1'b1
    );
    mapping = make_mapping("borrowed_srq_ring_mapping", binding,
      64'h0000_0030_0000_0000, 64'h0000_00a0_0000_0000, 4096);
    add_borrowed_slice(preflight, "borrowed_srq_ring",
      RDMA_QUEUE_ROLE_SRQ_RING, mapping, 0, 4096);
    mapping = make_mapping("borrowed_srfq_ring_mapping", binding,
      64'h0000_0031_0000_0000, 64'h0000_00a1_0000_0000, 4096);
    add_borrowed_slice(preflight, "borrowed_srfq_ring",
      RDMA_QUEUE_ROLE_SRFQ_RING, mapping, 0, 4096);
    mapping = make_mapping("borrowed_sgb_mapping", binding,
      64'h0000_0032_0000_0000, 64'h0000_00a2_0000_0000, 32768);
    add_borrowed_slice(preflight, "borrowed_sgb_first",
      RDMA_QUEUE_ROLE_SRQ_SGB, mapping, 0, 16384, 0);
    add_borrowed_slice(preflight, "borrowed_sgb_second",
      RDMA_QUEUE_ROLE_SRQ_SGB, mapping, 16384, 16384, 16384);
    resource_h = make_handle("borrowed_srq_resource", owner,
                             RDMA_RESOURCE_SRQ, 32'h2002);
    plan = null;
    expect_status("BORROWED_SRQ_PLAN", planner.materialize(
      binding, preflight, resource_h, plan), RDMA_SC_OK);
    if (plan == null || plan.refs.size() != 5 ||
        plan.refs[0].ownership != RDMA_OWNERSHIP_BORROWED ||
        plan.refs[1].ownership != RDMA_OWNERSHIP_BORROWED ||
        plan.refs[2].ownership != RDMA_OWNERSHIP_BORROWED ||
        plan.refs[2].additional_segments.size() != 1 ||
        plan.refs[2].additional_segments[0].mapping_offset != 16384 ||
        plan.refs[2].additional_segments[0].logical_queue_offset != 16384 ||
        count_planner_host_calls(mem, "allocate") != 2)
      `uvm_error("BORROWED_SRQ_PLAN", "borrowed SRQ role ownership is wrong")
    foreach (plan.refs[i]) begin
      complete = 1'b0;
      expect_status($sformatf("BORROWED_SRQ_CLEANUP_%0d", i),
        planner.cleanup_local_role(plan.refs[i], complete), RDMA_SC_OK);
    end
    if (count_planner_host_calls(mem, "release") != 2)
      `uvm_error("BORROWED_SRQ_CLEANUP", "borrowed SRQ released payload")

    mem = rdma_mock_host_mem::type_id::create("large_sgb_mem");
    planner = rdma_queue_backing_planner::type_id::create(
      "large_sgb_planner"
    );
    expect_status("LARGE_SGB_CONFIGURE", planner.configure(mem), RDMA_SC_OK);
    preflight = make_planner_preflight(
      "large_sgb_preflight", RDMA_RESOURCE_SRQ,
      RDMA_QUEUE_BACKING_OWNED, 1'b1, 8192
    );
    expect_status("LARGE_SGB_SPEC", planner.validate_spec(binding, preflight),
                  RDMA_SC_OK);
    expect_planner_no_host_calls("LARGE_SGB_SPEC", mem);

    // CEQ is owned and AEQ borrowed; neither planner plan has context/flush.
    mem = rdma_mock_host_mem::type_id::create("owned_ceq_mem");
    planner = rdma_queue_backing_planner::type_id::create("owned_ceq_planner");
    expect_status("OWNED_CEQ_CONFIGURE", planner.configure(mem), RDMA_SC_OK);
    preflight = make_planner_preflight(
      "owned_ceq_preflight", RDMA_RESOURCE_CEQ, RDMA_QUEUE_BACKING_OWNED
    );
    resource_h = make_handle("owned_ceq_resource", owner,
                             RDMA_RESOURCE_CEQ, 32'h3001);
    plan = null;
    expect_status("OWNED_CEQ_PLAN", planner.materialize(
      binding, preflight, resource_h, plan), RDMA_SC_OK);
    if (plan == null || plan.context_ref != null ||
        plan.flush_targets.size() != 0 || plan.refs.size() != 2 ||
        plan.refs[0].role != RDMA_QUEUE_ROLE_CEQ_RING ||
        plan.refs[1].role != RDMA_QUEUE_ROLE_CEQ_PD)
      `uvm_error("OWNED_CEQ_PLAN", "CEQ plan roles are incorrect")
    expect_status("OWNED_CEQ_VALIDATE", plan.validate(), RDMA_SC_OK);
    foreach (plan.refs[i]) begin
      complete = 1'b0;
      expect_status($sformatf("OWNED_CEQ_CLEANUP_%0d", i),
        planner.cleanup_local_role(plan.refs[i], complete), RDMA_SC_OK);
    end

    mem = rdma_mock_host_mem::type_id::create("borrowed_aeq_mem");
    planner = rdma_queue_backing_planner::type_id::create(
      "borrowed_aeq_planner"
    );
    expect_status("BORROWED_AEQ_CONFIGURE", planner.configure(mem), RDMA_SC_OK);
    preflight = make_planner_preflight(
      "borrowed_aeq_preflight", RDMA_RESOURCE_AEQ,
      RDMA_QUEUE_BACKING_BORROWED
    );
    mapping = make_mapping("borrowed_aeq_mapping", binding,
      64'h0000_0040_0000_0000, 64'h0000_00b0_0000_0000, 4096);
    add_borrowed_slice(preflight, "borrowed_aeq_slice",
      RDMA_QUEUE_ROLE_AEQ_RING, mapping, 0, 4096);
    resource_h = make_handle("borrowed_aeq_resource", owner,
                             RDMA_RESOURCE_AEQ, 32'h4001);
    plan = null;
    expect_status("BORROWED_AEQ_PLAN", planner.materialize(
      binding, preflight, resource_h, plan), RDMA_SC_OK);
    if (plan == null || plan.refs[0].role != RDMA_QUEUE_ROLE_AEQ_RING ||
        plan.refs[1].role != RDMA_QUEUE_ROLE_AEQ_PD ||
        plan.context_ref != null || plan.flush_targets.size() != 0)
      `uvm_error("BORROWED_AEQ_PLAN", "AEQ plan roles are incorrect")
    expect_status("BORROWED_AEQ_VALIDATE", plan.validate(), RDMA_SC_OK);
    foreach (plan.refs[i]) begin
      complete = 1'b0;
      expect_status($sformatf("BORROWED_AEQ_CLEANUP_%0d", i),
        planner.cleanup_local_role(plan.refs[i], complete), RDMA_SC_OK);
    end
  endfunction

  function automatic void check_backing_planner_negative();
    rdma_function_binding binding;
    rdma_function_handle owner;
    rdma_queue_backing_planner planner;
    rdma_mock_host_mem mem;
    rdma_queue_preflight preflight;
    rdma_queue_backing_plan plan;
    rdma_dma_mapping first_mapping;
    rdma_dma_mapping second_mapping;
    rdma_queue_backing_slice slice;
    rdma_handle resource_h;

    binding = make_binding("planner_negative_binding");
    owner = binding.make_handle();
    mem = rdma_mock_host_mem::type_id::create("planner_negative_mem");
    planner = rdma_queue_backing_planner::type_id::create(
      "planner_negative"
    );
    expect_status("PLANNER_NEGATIVE_CONFIGURE", planner.configure(mem),
                  RDMA_SC_OK);

    preflight = make_planner_preflight(
      "missing_role", RDMA_RESOURCE_CQ, RDMA_QUEUE_BACKING_BORROWED
    );
    expect_status("PLANNER_MISSING_ROLE", planner.validate_spec(
      binding, preflight), RDMA_SC_INVALID_ARGUMENT);

    preflight = make_planner_preflight(
      "extra_role", RDMA_RESOURCE_CQ, RDMA_QUEUE_BACKING_BORROWED
    );
    first_mapping = make_mapping("extra_role_cq", binding,
      64'h0000_0050_0000_0000, 64'h0000_00c0_0000_0000, 4096);
    second_mapping = make_mapping("extra_role_srq", binding,
      64'h0000_0051_0000_0000, 64'h0000_00c1_0000_0000, 4096);
    add_borrowed_slice(preflight, "extra_role_cq_slice",
      RDMA_QUEUE_ROLE_CQ_RING, first_mapping, 0, 4096);
    add_borrowed_slice(preflight, "extra_role_srq_slice",
      RDMA_QUEUE_ROLE_SRQ_RING, second_mapping, 0, 4096);
    expect_status("PLANNER_EXTRA_ROLE", planner.validate_spec(
      binding, preflight), RDMA_SC_INVALID_ARGUMENT);

    preflight = make_planner_preflight(
      "logical_hole", RDMA_RESOURCE_CQ, RDMA_QUEUE_BACKING_BORROWED,
      1'b0, 128
    );
    first_mapping = make_mapping("logical_hole_mapping", binding,
      64'h0000_0052_0000_0000, 64'h0000_00c2_0000_0000, 12288);
    add_borrowed_slice(preflight, "logical_hole_first",
      RDMA_QUEUE_ROLE_CQ_RING, first_mapping, 0, 4096, 0);
    add_borrowed_slice(preflight, "logical_hole_second",
      RDMA_QUEUE_ROLE_CQ_RING, first_mapping, 8192, 4096, 8192);
    expect_status("PLANNER_LOGICAL_HOLE", planner.validate_spec(
      binding, preflight), RDMA_SC_INVALID_ARGUMENT);

    preflight = make_planner_preflight(
      "logical_overlap", RDMA_RESOURCE_CQ, RDMA_QUEUE_BACKING_BORROWED,
      1'b0, 128
    );
    first_mapping = make_mapping("logical_overlap_mapping", binding,
      64'h0000_0053_0000_0000, 64'h0000_00c3_0000_0000, 8192);
    add_borrowed_slice(preflight, "logical_overlap_first",
      RDMA_QUEUE_ROLE_CQ_RING, first_mapping, 0, 4096, 0);
    add_borrowed_slice(preflight, "logical_overlap_second",
      RDMA_QUEUE_ROLE_CQ_RING, first_mapping, 4096, 4096, 0);
    expect_status("PLANNER_LOGICAL_OVERLAP", planner.validate_spec(
      binding, preflight), RDMA_SC_INVALID_ARGUMENT);

    preflight = make_planner_preflight(
      "same_role_iova_overlap", RDMA_RESOURCE_CQ,
      RDMA_QUEUE_BACKING_BORROWED, 1'b0, 128
    );
    first_mapping = make_mapping("same_role_iova_first", binding,
      64'h0000_0053_1000_0000, 64'h0000_00c3_1000_0000, 4096);
    second_mapping = make_mapping("same_role_iova_second", binding,
      64'h0000_0053_1000_0000, 64'h0000_00c3_2000_0000, 4096);
    add_borrowed_slice(preflight, "same_role_iova_first_slice",
      RDMA_QUEUE_ROLE_CQ_RING, first_mapping, 0, 4096, 0);
    add_borrowed_slice(preflight, "same_role_iova_second_slice",
      RDMA_QUEUE_ROLE_CQ_RING, second_mapping, 0, 4096, 4096);
    expect_status("PLANNER_SAME_ROLE_IOVA_OVERLAP", planner.validate_spec(
      binding, preflight), RDMA_SC_INVALID_ARGUMENT);

    // Inclusive host ranges at the top of the address space are compared for
    // same-role fragments as well as for different roles.
    preflight = make_planner_preflight(
      "same_role_top_backing_overlap", RDMA_RESOURCE_CQ,
      RDMA_QUEUE_BACKING_BORROWED, 1'b0, 128
    );
    first_mapping = make_mapping("same_role_top_backing_first", binding,
      64'h0000_0053_2000_0000, 64'hffff_ffff_ffff_f000, 4096);
    second_mapping = make_mapping("same_role_top_backing_second", binding,
      64'h0000_0053_3000_0000, 64'hffff_ffff_ffff_f000, 4096);
    add_borrowed_slice(preflight, "same_role_top_backing_first_slice",
      RDMA_QUEUE_ROLE_CQ_RING, first_mapping, 0, 4096, 0);
    add_borrowed_slice(preflight, "same_role_top_backing_second_slice",
      RDMA_QUEUE_ROLE_CQ_RING, second_mapping, 0, 4096, 4096);
    expect_status("PLANNER_SAME_ROLE_TOP_BACKING_OVERLAP",
      planner.validate_spec(binding, preflight), RDMA_SC_INVALID_ARGUMENT);

    preflight = make_planner_preflight(
      "iova_overlap", RDMA_RESOURCE_SRQ, RDMA_QUEUE_BACKING_BORROWED
    );
    first_mapping = make_mapping("iova_overlap_first", binding,
      64'h0000_0054_0000_0000, 64'h0000_00c4_0000_0000, 4096);
    second_mapping = make_mapping("iova_overlap_second", binding,
      64'h0000_0054_0000_0000, 64'h0000_00c5_0000_0000, 4096);
    add_borrowed_slice(preflight, "iova_overlap_srq",
      RDMA_QUEUE_ROLE_SRQ_RING, first_mapping, 0, 4096);
    add_borrowed_slice(preflight, "iova_overlap_srfq",
      RDMA_QUEUE_ROLE_SRFQ_RING, second_mapping, 0, 4096);
    expect_status("PLANNER_DEVICE_IOVA_OVERLAP", planner.validate_spec(
      binding, preflight), RDMA_SC_INVALID_ARGUMENT);

    preflight = make_planner_preflight(
      "backing_overlap", RDMA_RESOURCE_SRQ, RDMA_QUEUE_BACKING_BORROWED
    );
    first_mapping = make_mapping("backing_overlap_first", binding,
      64'h0000_0055_0000_0000, 64'h0000_00c6_0000_0000, 4096);
    second_mapping = make_mapping("backing_overlap_second", binding,
      64'h0000_0056_0000_0000, 64'h0000_00c6_0000_0000, 4096);
    add_borrowed_slice(preflight, "backing_overlap_srq",
      RDMA_QUEUE_ROLE_SRQ_RING, first_mapping, 0, 4096);
    add_borrowed_slice(preflight, "backing_overlap_srfq",
      RDMA_QUEUE_ROLE_SRFQ_RING, second_mapping, 0, 4096);
    expect_status("PLANNER_HOST_BACKING_OVERLAP", planner.validate_spec(
      binding, preflight), RDMA_SC_INVALID_ARGUMENT);

    // Inclusive ranges ending at the top of the 64-bit address space still
    // overlap; an exclusive-end calculation would wrap both ends to zero.
    preflight = make_planner_preflight(
      "top_iova_overlap", RDMA_RESOURCE_SRQ, RDMA_QUEUE_BACKING_BORROWED
    );
    first_mapping = make_mapping("top_iova_overlap_first", binding,
      64'hffff_ffff_ffff_f000, 64'h0000_00c7_0000_0000, 4096);
    second_mapping = make_mapping("top_iova_overlap_second", binding,
      64'hffff_ffff_ffff_f000, 64'h0000_00c8_0000_0000, 4096);
    add_borrowed_slice(preflight, "top_iova_overlap_srq",
      RDMA_QUEUE_ROLE_SRQ_RING, first_mapping, 0, 4096);
    add_borrowed_slice(preflight, "top_iova_overlap_srfq",
      RDMA_QUEUE_ROLE_SRFQ_RING, second_mapping, 0, 4096);
    expect_status("PLANNER_TOP_IOVA_OVERLAP", planner.validate_spec(
      binding, preflight), RDMA_SC_INVALID_ARGUMENT);

    preflight = make_planner_preflight(
      "short_role", RDMA_RESOURCE_CQ, RDMA_QUEUE_BACKING_BORROWED,
      1'b0, 128
    );
    first_mapping = make_mapping("short_role_mapping", binding,
      64'h0000_0057_0000_0000, 64'h0000_00c7_0000_0000, 4096);
    add_borrowed_slice(preflight, "short_role_slice",
      RDMA_QUEUE_ROLE_CQ_RING, first_mapping, 0, 4096);
    expect_status("PLANNER_LENGTH_INSUFFICIENT", planner.validate_spec(
      binding, preflight), RDMA_SC_INVALID_ARGUMENT);

    preflight = make_planner_preflight(
      "unaligned_role", RDMA_RESOURCE_CQ, RDMA_QUEUE_BACKING_BORROWED
    );
    first_mapping = make_mapping("unaligned_role_mapping", binding,
      64'h0000_0058_0000_0000, 64'h0000_00c8_0000_0000, 8192);
    add_borrowed_slice(preflight, "unaligned_role_slice",
      RDMA_QUEUE_ROLE_CQ_RING, first_mapping, 1, 4096);
    expect_status("PLANNER_UNALIGNED_OFFSET", planner.validate_spec(
      binding, preflight), RDMA_SC_INVALID_ARGUMENT);

    preflight = make_planner_preflight(
      "bdf_mismatch", RDMA_RESOURCE_CQ, RDMA_QUEUE_BACKING_BORROWED
    );
    first_mapping = make_mapping("bdf_mismatch_mapping", binding,
      64'h0000_0059_0000_0000, 64'h0000_00c9_0000_0000, 4096);
    first_mapping.requester_bdf.bus++;
    add_borrowed_slice(preflight, "bdf_mismatch_slice",
      RDMA_QUEUE_ROLE_CQ_RING, first_mapping, 0, 4096);
    expect_status("PLANNER_BDF_MISMATCH", planner.validate_spec(
      binding, preflight), RDMA_SC_DMA_TRANSLATION);

    preflight = make_planner_preflight(
      "pasid_mismatch", RDMA_RESOURCE_CQ, RDMA_QUEUE_BACKING_BORROWED
    );
    first_mapping = make_mapping("pasid_mismatch_mapping", binding,
      64'h0000_005a_0000_0000, 64'h0000_00ca_0000_0000, 4096);
    first_mapping.pasid_valid = 1'b1;
    first_mapping.pasid = 20'h12345;
    add_borrowed_slice(preflight, "pasid_mismatch_slice",
      RDMA_QUEUE_ROLE_CQ_RING, first_mapping, 0, 4096);
    expect_status("PLANNER_PASID_MISMATCH", planner.validate_spec(
      binding, preflight), RDMA_SC_DMA_TRANSLATION);

    preflight = make_planner_preflight(
      "domain_mismatch", RDMA_RESOURCE_CQ, RDMA_QUEUE_BACKING_BORROWED
    );
    first_mapping = make_mapping("domain_mismatch_mapping", binding,
      64'h0000_005b_0000_0000, 64'h0000_00cb_0000_0000, 4096);
    first_mapping.dma_domain_id++;
    add_borrowed_slice(preflight, "domain_mismatch_slice",
      RDMA_QUEUE_ROLE_CQ_RING, first_mapping, 0, 4096);
    expect_status("PLANNER_DOMAIN_MISMATCH", planner.validate_spec(
      binding, preflight), RDMA_SC_DMA_TRANSLATION);

    preflight = make_planner_preflight(
      "generation_mismatch", RDMA_RESOURCE_CQ, RDMA_QUEUE_BACKING_BORROWED
    );
    first_mapping = make_mapping("generation_mismatch_mapping", binding,
      64'h0000_005c_0000_0000, 64'h0000_00cc_0000_0000, 4096);
    first_mapping.function_h.generation++;
    add_borrowed_slice(preflight, "generation_mismatch_slice",
      RDMA_QUEUE_ROLE_CQ_RING, first_mapping, 0, 4096);
    expect_status("PLANNER_GENERATION_MISMATCH", planner.validate_spec(
      binding, preflight), RDMA_SC_STALE_GENERATION);

    preflight = make_planner_preflight(
      "direction_mismatch", RDMA_RESOURCE_CQ, RDMA_QUEUE_BACKING_BORROWED
    );
    first_mapping = make_mapping("direction_mismatch_mapping", binding,
      64'h0000_005d_0000_0000, 64'h0000_00cd_0000_0000, 4096);
    first_mapping.direction = RDMA_DMA_DEVICE_READ;
    add_borrowed_slice(preflight, "direction_mismatch_slice",
      RDMA_QUEUE_ROLE_CQ_RING, first_mapping, 0, 4096);
    expect_status("PLANNER_DIRECTION_MISMATCH", planner.validate_spec(
      binding, preflight), RDMA_SC_DMA_PERMISSION);

    // A split inside a 512-byte SGB slot must fail before allocation.  The
    // first fragment deliberately violates the slot granularity.
    preflight = make_planner_preflight(
      "sgb_cross_slice", RDMA_RESOURCE_SRQ, RDMA_QUEUE_BACKING_BORROWED,
      1'b1
    );
    first_mapping = make_mapping("sgb_cross_srq", binding,
      64'h0000_005e_0000_0000, 64'h0000_00ce_0000_0000, 4096);
    add_borrowed_slice(preflight, "sgb_cross_srq_slice",
      RDMA_QUEUE_ROLE_SRQ_RING, first_mapping, 0, 4096);
    second_mapping = make_mapping("sgb_cross_srfq", binding,
      64'h0000_005f_0000_0000, 64'h0000_00cf_0000_0000, 4096);
    add_borrowed_slice(preflight, "sgb_cross_srfq_slice",
      RDMA_QUEUE_ROLE_SRFQ_RING, second_mapping, 0, 4096);
    first_mapping = make_mapping("sgb_cross_payload", binding,
      64'h0000_0060_0000_0000, 64'h0000_00d0_0000_0000, 32768);
    add_borrowed_slice(preflight, "sgb_cross_first",
      RDMA_QUEUE_ROLE_SRQ_SGB, first_mapping, 0, 256, 0);
    add_borrowed_slice(preflight, "sgb_cross_second",
      RDMA_QUEUE_ROLE_SRQ_SGB, first_mapping, 256, 32512, 256);
    expect_status("PLANNER_SGB_SLOT_CROSSES_SLICE", planner.validate_spec(
      binding, preflight), RDMA_SC_INVALID_ARGUMENT);

    // 64 Mi entries * 64 bytes is 4 GiB: a naive 32-bit multiplication wraps
    // to zero, while checked widening must reject the host API width.
    preflight = make_planner_preflight(
      "multiply_overflow", RDMA_RESOURCE_CQ, RDMA_QUEUE_BACKING_OWNED,
      1'b0, 32'h0400_0000
    );
    preflight.required_rings[0].logical_bytes = 0;
    preflight.required_rings[0].storage_bytes = 4096;
    preflight.required_rings[0].page_count = 1;
    expect_status("PLANNER_CHECKED_MULTIPLICATION", planner.validate_spec(
      binding, preflight), RDMA_SC_INVALID_ARGUMENT);

    expect_planner_no_host_calls("PLANNER_NEGATIVE_MATRIX", mem);

    // Any materialization failure clears a stale caller output.
    preflight = make_planner_preflight(
      "atomic_failure", RDMA_RESOURCE_CQ, RDMA_QUEUE_BACKING_BORROWED
    );
    first_mapping = make_mapping("atomic_failure_mapping", binding,
      64'h0000_0061_0000_0000, 64'h0000_00d1_0000_0000, 4096);
    add_borrowed_slice(preflight, "atomic_failure_slice",
      RDMA_QUEUE_ROLE_CQ_RING, first_mapping, 0, 4096);
    resource_h = make_handle("wrong_kind_resource", owner,
                             RDMA_RESOURCE_SRQ, 32'h5001);
    plan = rdma_queue_backing_plan::type_id::create("stale_planner_output");
    expect_status("PLANNER_OUTPUT_ATOMIC", planner.materialize(
      binding, preflight, resource_h, plan), RDMA_SC_INVALID_ARGUMENT);
    if (plan != null)
      `uvm_error("PLANNER_OUTPUT_ATOMIC", "failed materialize leaked a plan")
    expect_planner_no_host_calls("PLANNER_OUTPUT_ATOMIC", mem);
  endfunction

  function automatic void check_backing_planner_rollback_and_cleanup();
    rdma_function_binding binding;
    rdma_function_handle owner;
    rdma_handle resource_h;
    rdma_queue_backing_planner planner;
    rdma_queue_planner_nth_fail_mem fail_mem;
    rdma_queue_planner_snapshot_fail_mem snapshot_mem;
    rdma_mock_host_mem cleanup_mem;
    rdma_queue_planner_second_release_fail_mem grouped_cleanup_mem;
    rdma_queue_preflight preflight;
    rdma_queue_backing_plan plan;
    rdma_queue_backing_segment cleanup_segment;
    rdma_dma_mapping borrowed_mapping;
    int unsigned release_ordinal;
    longint unsigned expected_release_iova[4];
    bit complete;

    binding = make_binding("planner_rollback_binding");
    owner = binding.make_handle();

    // A late SRQ PD allocation failure releases every prior owned role in
    // strict reverse acquisition order and publishes no partial plan.
    fail_mem = rdma_queue_planner_nth_fail_mem::type_id::create(
      "late_srq_allocation_failure_mem"
    );
    fail_mem.fail_on_allocate = 5;
    planner = rdma_queue_backing_planner::type_id::create(
      "late_srq_allocation_failure_planner"
    );
    expect_status("ROLLBACK_CONFIGURE", planner.configure(fail_mem),
                  RDMA_SC_OK);
    preflight = make_planner_preflight(
      "rollback_srq_preflight", RDMA_RESOURCE_SRQ,
      RDMA_QUEUE_BACKING_OWNED, 1'b1
    );
    resource_h = make_handle("rollback_srq_resource", owner,
                             RDMA_RESOURCE_SRQ, 32'h6001);
    plan = rdma_queue_backing_plan::type_id::create("stale_rollback_plan");
    expect_status("ROLLBACK_LATE_PD_ALLOC", planner.materialize(
      binding, preflight, resource_h, plan), RDMA_SC_RESOURCE_EXHAUSTED);
    if (plan != null || count_planner_host_calls(fail_mem, "allocate") != 5 ||
        count_planner_host_calls(fail_mem, "release") != 4 ||
        fail_mem.live_allocations() != 0)
      `uvm_error("ROLLBACK_LATE_PD_ALLOC",
                 "late allocation failure leaked an owned role")
    expected_release_iova[0] = 64'h0000_0001_0000_a000;
    expected_release_iova[1] = 64'h0000_0001_0000_2000;
    expected_release_iova[2] = 64'h0000_0001_0000_1000;
    expected_release_iova[3] = 64'h0000_0001_0000_0000;
    release_ordinal = 0;
    foreach (fail_mem.calls[i]) begin
      if (fail_mem.calls[i].method_name != "release")
        continue;
      if (release_ordinal >= 4 || fail_mem.calls[i].mapping == null ||
          fail_mem.calls[i].mapping.iova.value !=
            expected_release_iova[release_ordinal])
        `uvm_error("ROLLBACK_REVERSE_ORDER",
                   "owned roles were not released in reverse order")
      release_ordinal++;
    end

    // A failed reverse-order release must not prevent rollback from
    // attempting every earlier acquisition.
    fail_mem = rdma_queue_planner_nth_fail_mem::type_id::create(
      "rollback_release_failure_mem"
    );
    fail_mem.fail_on_allocate = 5;
    expect_status("ARM_ROLLBACK_RELEASE_FAILURE", fail_mem.fail_next(
      "release", rdma_status::make(
        RDMA_SC_DMA_TRANSLATION, "injected rollback release failure"
      )), RDMA_SC_OK);
    planner = rdma_queue_backing_planner::type_id::create(
      "rollback_release_failure_planner"
    );
    expect_status("ROLLBACK_RELEASE_FAILURE_CONFIGURE",
      planner.configure(fail_mem), RDMA_SC_OK);
    preflight = make_planner_preflight(
      "rollback_release_failure_preflight", RDMA_RESOURCE_SRQ,
      RDMA_QUEUE_BACKING_OWNED, 1'b1
    );
    resource_h = make_handle("rollback_release_failure_resource", owner,
                             RDMA_RESOURCE_SRQ, 32'h6005);
    plan = null;
    expect_status("ROLLBACK_RELEASE_FAILURE", planner.materialize(
      binding, preflight, resource_h, plan), RDMA_SC_DMA_TRANSLATION);
    if (plan != null || count_planner_host_calls(fail_mem, "allocate") != 5 ||
        count_planner_host_calls(fail_mem, "release") != 4 ||
        fail_mem.live_allocations() != 1)
      `uvm_error("ROLLBACK_RELEASE_FAILURE",
                 "rollback stopped after its first release failure")

    // A borrowed payload is detached, not released, when its owned PD
    // acquisition fails.
    fail_mem = rdma_queue_planner_nth_fail_mem::type_id::create(
      "borrowed_pd_failure_mem"
    );
    fail_mem.fail_on_allocate = 1;
    planner = rdma_queue_backing_planner::type_id::create(
      "borrowed_pd_failure_planner"
    );
    expect_status("BORROWED_PD_FAILURE_CONFIGURE", planner.configure(fail_mem),
                  RDMA_SC_OK);
    preflight = make_planner_preflight(
      "borrowed_pd_failure_preflight", RDMA_RESOURCE_CQ,
      RDMA_QUEUE_BACKING_BORROWED
    );
    borrowed_mapping = make_mapping("borrowed_pd_failure_mapping", binding,
      64'h0000_0070_0000_0000, 64'h0000_00e0_0000_0000, 4096);
    add_borrowed_slice(preflight, "borrowed_pd_failure_slice",
      RDMA_QUEUE_ROLE_CQ_RING, borrowed_mapping, 0, 4096);
    resource_h = make_handle("borrowed_pd_failure_resource", owner,
                             RDMA_RESOURCE_CQ, 32'h6002);
    plan = null;
    expect_status("BORROWED_PD_FAILURE", planner.materialize(
      binding, preflight, resource_h, plan), RDMA_SC_RESOURCE_EXHAUSTED);
    if (plan != null || count_planner_host_calls(fail_mem, "allocate") != 1 ||
        count_planner_host_calls(fail_mem, "release") != 0)
      `uvm_error("BORROWED_PD_FAILURE",
                 "borrowed rollback released caller backing")

    // The allocated mapping itself remains rollback authority until its
    // snapshot succeeds; a snapshot failure therefore releases exactly once.
    snapshot_mem = rdma_queue_planner_snapshot_fail_mem::type_id::create(
      "snapshot_failure_mem"
    );
    planner = rdma_queue_backing_planner::type_id::create(
      "snapshot_failure_planner"
    );
    expect_status("SNAPSHOT_FAILURE_CONFIGURE", planner.configure(snapshot_mem),
                  RDMA_SC_OK);
    preflight = make_planner_preflight(
      "snapshot_failure_preflight", RDMA_RESOURCE_CEQ,
      RDMA_QUEUE_BACKING_OWNED
    );
    resource_h = make_handle("snapshot_failure_resource", owner,
                             RDMA_RESOURCE_CEQ, 32'h6003);
    plan = null;
    expect_status("SNAPSHOT_FAILURE", planner.materialize(
      binding, preflight, resource_h, plan), RDMA_SC_INVALID_STATE);
    if (plan != null ||
        count_planner_host_calls(snapshot_mem, "allocate") != 1 ||
        count_planner_host_calls(snapshot_mem, "release") != 1 ||
        snapshot_mem.live_allocations() != 0)
      `uvm_error("SNAPSHOT_FAILURE",
                 "snapshot failure lost allocation rollback authority")

    // Release failures are retryable.  Once the mapping completion authority
    // reports complete, later cleanup calls do not invoke release again.
    cleanup_mem = rdma_mock_host_mem::type_id::create("cleanup_failure_mem");
    planner = rdma_queue_backing_planner::type_id::create(
      "cleanup_failure_planner"
    );
    expect_status("CLEANUP_FAILURE_CONFIGURE", planner.configure(cleanup_mem),
                  RDMA_SC_OK);
    preflight = make_planner_preflight(
      "cleanup_failure_preflight", RDMA_RESOURCE_CEQ,
      RDMA_QUEUE_BACKING_OWNED
    );
    resource_h = make_handle("cleanup_failure_resource", owner,
                             RDMA_RESOURCE_CEQ, 32'h6004);
    plan = null;
    expect_status("CLEANUP_FAILURE_PLAN", planner.materialize(
      binding, preflight, resource_h, plan), RDMA_SC_OK);
    expect_status("ARM_CLEANUP_FAILURE", cleanup_mem.fail_next(
      "release", rdma_status::make(
        RDMA_SC_DMA_TRANSLATION, "injected planner release failure"
      )), RDMA_SC_OK);
    complete = 1'b1;
    expect_status("CLEANUP_FAILURE_FIRST",
      planner.cleanup_local_role(plan.refs[0], complete),
      RDMA_SC_DMA_TRANSLATION);
    if (complete || count_planner_host_calls(cleanup_mem, "release") != 1)
      `uvm_error("CLEANUP_FAILURE_FIRST",
                 "failed cleanup incorrectly reported completion")
    complete = 1'b0;
    expect_status("CLEANUP_FAILURE_RETRY",
      planner.cleanup_local_role(plan.refs[0], complete), RDMA_SC_OK);
    if (!complete || count_planner_host_calls(cleanup_mem, "release") != 2)
      `uvm_error("CLEANUP_FAILURE_RETRY", "cleanup retry did not complete")
    complete = 1'b0;
    expect_status("CLEANUP_FAILURE_IDEMPOTENT",
      planner.cleanup_local_role(plan.refs[0], complete), RDMA_SC_OK);
    if (!complete || count_planner_host_calls(cleanup_mem, "release") != 2)
      `uvm_error("CLEANUP_FAILURE_IDEMPOTENT",
                 "completed cleanup repeated release")
    complete = 1'b0;
    expect_status("CLEANUP_FAILURE_PD",
      planner.cleanup_local_role(plan.refs[1], complete), RDMA_SC_OK);

    // A grouped owned role can partially complete.  Retry must query each
    // segment and skip the primary allocation that the first attempt already
    // released before retrying the failed later segment.
    grouped_cleanup_mem =
      rdma_queue_planner_second_release_fail_mem::type_id::create(
        "grouped_cleanup_mem"
      );
    planner = rdma_queue_backing_planner::type_id::create(
      "grouped_cleanup_planner"
    );
    expect_status("GROUPED_CLEANUP_CONFIGURE",
      planner.configure(grouped_cleanup_mem), RDMA_SC_OK);
    preflight = make_planner_preflight(
      "grouped_cleanup_preflight", RDMA_RESOURCE_CEQ,
      RDMA_QUEUE_BACKING_OWNED
    );
    resource_h = make_handle("grouped_cleanup_resource", owner,
                             RDMA_RESOURCE_CEQ, 32'h6006);
    plan = null;
    expect_status("GROUPED_CLEANUP_PLAN", planner.materialize(
      binding, preflight, resource_h, plan), RDMA_SC_OK);
    cleanup_segment = rdma_queue_backing_segment::type_id::create(
      "grouped_cleanup_segment"
    );
    cleanup_segment.role = RDMA_QUEUE_ROLE_CEQ_RING;
    cleanup_segment.mapping = plan.refs[1].mapping;
    cleanup_segment.ownership = RDMA_OWNERSHIP_CONTROL_PLANE;
    cleanup_segment.mapping_offset = 0;
    cleanup_segment.length = 4096;
    cleanup_segment.logical_queue_offset = plan.refs[0].length;
    plan.refs[0].additional_segments.push_back(cleanup_segment);
    complete = 1'b1;
    expect_status("GROUPED_CLEANUP_PARTIAL",
      planner.cleanup_local_role(plan.refs[0], complete),
      RDMA_SC_DMA_TRANSLATION);
    if (complete ||
        count_planner_host_calls(grouped_cleanup_mem, "release") != 2)
      `uvm_error("GROUPED_CLEANUP_PARTIAL",
                 "partial grouped cleanup did not preserve retry state")
    complete = 1'b0;
    expect_status("GROUPED_CLEANUP_RETRY",
      planner.cleanup_local_role(plan.refs[0], complete), RDMA_SC_OK);
    if (!complete ||
        count_planner_host_calls(grouped_cleanup_mem, "release") != 3)
      `uvm_error("GROUPED_CLEANUP_RETRY",
                 "retry re-released a completed segment")
    complete = 1'b0;
    expect_status("GROUPED_CLEANUP_IDEMPOTENT",
      planner.cleanup_local_role(plan.refs[0], complete), RDMA_SC_OK);
    if (!complete ||
        count_planner_host_calls(grouped_cleanup_mem, "release") != 3)
      `uvm_error("GROUPED_CLEANUP_IDEMPOTENT",
                 "completed grouped cleanup repeated release")
    complete = 1'b0;
    expect_status("GROUPED_CLEANUP_PD_ALREADY_COMPLETE",
      planner.cleanup_local_role(plan.refs[1], complete), RDMA_SC_OK);
  endfunction

  function automatic void check_contexts_and_commands();
    rdma_function_binding binding;
    rdma_function_binding foreign_binding;
    rdma_function_handle owner;
    rdma_function_handle foreign_owner;
    rdma_cq_lifecycle_policy cq_policy;
    rdma_srq_lifecycle_policy srq_policy;
    rdma_ceq_lifecycle_policy ceq_policy;
    rdma_aeq_lifecycle_policy aeq_policy;
    rdma_cq cq;
    rdma_srq srq;
    rdma_ceq ceq;
    rdma_aeq aeq;
    rdma_queue_backing_plan cq_plan;
    rdma_queue_backing_plan srq_plan;
    rdma_queue_backing_plan ceq_plan;
    rdma_queue_backing_plan aeq_plan;
    rdma_hw_model model;
    rdma_cqc_model cqc;
    rdma_cqc_model optional_cqc;
    rdma_srqc_model srqc;
    rdma_ceqc_model ceqc;
    rdma_aeqc_model aeqc;
    byte unsigned slot_image[];
    byte unsigned shadow_image[];
    rdma_cmq_command_desc command;
    rdma_xtr_v1_object_id_command_body object_body;
    rdma_xtr_v1_occ_flush_body occ_body;
    rdma_queue_flush_target target;
    rdma_queue_resource wrong_resource;

    binding = make_binding("context_binding");
    owner = binding.make_handle();
    foreign_binding = make_binding("foreign_context_binding",
      64'h8877_6655_4433_2211, 32'h9000_0202, 9);
    foreign_owner = foreign_binding.make_handle();
    cq_policy = rdma_cq_lifecycle_policy::type_id::create("context_cq_policy");
    srq_policy = rdma_srq_lifecycle_policy::type_id::create("context_srq_policy");
    ceq_policy = rdma_ceq_lifecycle_policy::type_id::create("context_ceq_policy");
    aeq_policy = rdma_aeq_lifecycle_policy::type_id::create("context_aeq_policy");

    cq_plan = make_cq_plan(binding);
    cq = rdma_cq::type_id::create("cq_builder_view");
    cq.handle = make_handle("cq_incarnation", owner, RDMA_RESOURCE_CQ,
                            32'h3000_9876);
    cq.owner = owner;
    cq.local_cq_id = 21'h12345;
    cq.depth = 64;
    cq.cqe_size_bytes = 64;
    // This is an explicit projected dependency, observably unlike an RM ID.
    cq.ceq_h = make_handle("projected_ceq", owner, RDMA_RESOURCE_CEQ,
                           12'h345);
    model = null;
    slot_image = new[0];
    shadow_image = new[0];
    expect_status("CQC_CONTEXT",
      cq_policy.build_create_context(cq, cq_plan, model, slot_image,
                                     shadow_image), RDMA_SC_OK);
    if (!$cast(cqc, model)) begin
      `uvm_error("CQC_CONTEXT", "policy did not publish a CQC model")
    end else begin
      if (cqc.cq_h.object_id != cq.local_cq_id ||
          cqc.cq_h.object_id == cq.handle.object_id ||
          cqc.ceq_h.object_id != 12'h345 || cqc.threshold != 2 ||
          !cqc.load_ci_done || cqc.last_arm_sequence != 1 ||
          cqc.arm_sequence != 0 || cqc.arm_state != 0 ||
          cqc.producer.index != 0 || cqc.producer.wrap != 0 ||
          cqc.consumer.index != 0 || cqc.consumer.wrap != 0 ||
          cqc.page_layout.current_base.value != 64'h0000_0003_1234_5000 ||
          cqc.page_layout.current_base.value ==
            cq_plan.refs[1].mapping.backing_addr.value ||
          cqc.shadow_backing.value != 64'h0000_0004_5678_9000)
        `uvm_error("CQC_CONTEXT", "canonical CQC fields are incorrect")
      expect_canonical_image("CQC_IMAGE", cqc, RDMA_IMAGE_CQC, "cqc",
                             8'h0c, slot_image);
    end
    if (shadow_image.size() != 8)
      `uvm_error("CQC_SHADOW", "CQC shadow length is not eight bytes")
    else foreach (shadow_image[i]) begin
      if (shadow_image[i] != 0)
        `uvm_error("CQC_SHADOW", "CQC shadow is not zero initialized")
    end

    cq.ceq_h = null;
    expect_status("CQC_OPTIONAL_CEQ",
      cq_policy.build_create_context(cq, cq_plan, model, slot_image,
                                     shadow_image), RDMA_SC_OK);
    if (!$cast(optional_cqc, model) || optional_cqc.ceq_h != null)
      `uvm_error("CQC_OPTIONAL_CEQ",
                 "CQ without a CEQ did not produce a canonical CQC")
    cq.ceq_h = make_handle("restored_projected_ceq", owner,
                           RDMA_RESOURCE_CEQ, 12'h345);

    cq_plan.refs[1].mapping.function_h = foreign_owner;
    model = cqc;
    slot_image = '{8'haa};
    shadow_image = '{8'hbb};
    expect_status("CQC_REJECTS_FOREIGN_PD_MAPPING",
      cq_policy.build_create_context(cq, cq_plan, model, slot_image,
                                     shadow_image), RDMA_SC_INVALID_ARGUMENT);
    if (model != null || slot_image.size() != 0 || shadow_image.size() != 0)
      `uvm_error("CQC_REJECTS_FOREIGN_PD_MAPPING",
                 "failed foreign-plan context build leaked caller outputs")
    cq_plan.refs[1].mapping.function_h = owner;

    cq_plan.context_ref.owner = foreign_owner;
    expect_status("CQC_REJECTS_FOREIGN_CONTEXT_REF",
      cq_policy.build_create_context(cq, cq_plan, model, slot_image,
                                     shadow_image), RDMA_SC_INVALID_ARGUMENT);
    cq_plan.context_ref.owner = owner;

    command = null;
    expect_status("CQC_CREATE_COMMAND",
      cq_policy.build_create_command(owner, cq, cqc, 100ns, command),
      RDMA_SC_OK);
    if (command == null || command.opcode_key.opcode != 8'h0c ||
        command.opcode_key.profile_name != "xtr_v1" ||
        command.opcode_key.variant != "create")
      `uvm_error("CQC_CREATE_COMMAND", "CQC create descriptor is incorrect")
    command = rdma_cmq_command_desc::type_id::create("stale_foreign_command");
    expect_status("CQC_REJECTS_FOREIGN_COMMAND_OWNER",
      cq_policy.build_create_command(foreign_owner, cq, cqc, 100ns, command),
      RDMA_SC_INVALID_ARGUMENT);
    if (command != null)
      `uvm_error("CQC_REJECTS_FOREIGN_COMMAND_OWNER",
                 "failed foreign-owner command leaked caller output")
    expect_status("CQC_DELETE_COMMAND",
      cq_policy.build_object_command(8'h0e, owner, cq, 100ns, command),
      RDMA_SC_OK);
    if (command == null || command.opcode_key.opcode != 8'h0e ||
        !$cast(object_body, command.body) ||
        object_body.object_h.object_id != cq.local_cq_id)
      `uvm_error("CQC_DELETE_COMMAND", "CQC delete descriptor is incorrect")
    expect_status("CQC_QUERY_COMMAND",
      cq_policy.build_object_command(8'h0f, owner, cq, 100ns, command),
      RDMA_SC_OK);
    cq.owner = foreign_owner;
    command = rdma_cmq_command_desc::type_id::create(
      "stale_cq_foreign_resource_delete");
    expect_status("CQC_DELETE_REJECTS_FOREIGN_RESOURCE_OWNER",
      cq_policy.build_object_command(8'h0e, owner, cq, 100ns, command),
      RDMA_SC_INVALID_ARGUMENT);
    if (command != null)
      `uvm_error("CQC_DELETE_REJECTS_FOREIGN_RESOURCE_OWNER",
                 "failed foreign-resource delete leaked caller output")
    cq.owner = owner;

    target = rdma_queue_flush_target::type_id::create("cq_flush_target");
    target.role = RDMA_QUEUE_ROLE_CQ_PD;
    target.phase = RDMA_QUEUE_FLUSH_POST_DELETE;
    target.pd_ref = cq_plan.refs[1];
    target.pd_ref.mapping_offset = 4096;
    target.pd_ref.mapping.size = 8192;
    command = null;
    expect_status("CQ_FLUSH_COMMAND",
      cq_policy.build_flush_command(owner, target, 100ns, command), RDMA_SC_OK);
    if (command == null || command.opcode_key.opcode != 8'h0a ||
        !$cast(occ_body, command.body) || !occ_body.pd || occ_body.qpn != 0 ||
        occ_body.pd_backing.value != 64'h0000_0003_1234_6000 ||
        occ_body.pd_backing.value == target.pd_ref.mapping.backing_addr.value +
                                     target.pd_ref.mapping_offset ||
        occ_body.vf_flush || occ_body.mr_serial_flush || occ_body.qpc ||
        occ_body.cqc || occ_body.mrt || occ_body.pble || occ_body.sqrqe ||
        occ_body.sgb_irqe || occ_body.eirqe || occ_body.orqe || occ_body.uaqe)
      `uvm_error("CQ_FLUSH_COMMAND", "CQ OCC descriptor is incorrect")

    target.pd_ref.mapping.function_h = foreign_owner;
    command = rdma_cmq_command_desc::type_id::create("stale_foreign_flush");
    expect_status("CQ_FLUSH_REJECTS_FOREIGN_MAPPING",
      cq_policy.build_flush_command(owner, target, 100ns, command),
      RDMA_SC_INVALID_ARGUMENT);
    if (command != null)
      `uvm_error("CQ_FLUSH_REJECTS_FOREIGN_MAPPING",
                 "failed foreign-mapping flush leaked caller output")
    target.pd_ref.mapping.function_h = owner;

    srq_plan = make_srq_plan(binding);
    srq = rdma_srq::type_id::create("srq_builder_view");
    srq.handle = make_handle("srq_incarnation", owner, RDMA_RESOURCE_SRQ,
                             32'h5000_8765);
    srq.owner = owner;
    srq.local_srq_id = 16'h2345;
    srq.depth = 64;
    srq.max_sge = 4;
    srq.limit_threshold = 16;
    srq.pd_h = make_handle("projected_pd", owner, RDMA_RESOURCE_PD,
                           16'h4567);
    expect_status("SRQC_CONTEXT",
      srq_policy.build_create_context(srq, srq_plan, model, slot_image,
                                      shadow_image), RDMA_SC_OK);
    if (!$cast(srqc, model)) begin
      `uvm_error("SRQC_CONTEXT", "policy did not publish an SRQC model")
    end else begin
      if (srqc.srq_h.object_id != srq.local_srq_id ||
          srqc.srq_h.object_id == srq.handle.object_id ||
          srqc.pd_h.object_id != 16'h4567 || srqc.load_pi_threshold != 8 ||
          srqc.limit_threshold != 4 || srqc.producer.index != 0 ||
          srqc.producer.wrap != 0 || srqc.arm_sequence != 0 ||
          srqc.srfq_backing.value != 64'h0000_0007_2222_2000 ||
          srqc.srfq_backing.value ==
            srq_plan.refs[3].mapping.backing_addr.value ||
          srqc.shadow_backing.value != 64'h0000_0008_3333_3000)
        `uvm_error("SRQC_CONTEXT", "canonical SRQC fields are incorrect")
      expect_canonical_image("SRQC_IMAGE", srqc, RDMA_IMAGE_SRQC, "srqc",
                             8'h35, slot_image);
    end
    if (shadow_image.size() != 4 || shadow_image[0] != 8'h00 ||
        shadow_image[1] != 8'h00 || shadow_image[2] != 8'h00 ||
        shadow_image[3] != 8'h10)
      `uvm_error("SRQC_SHADOW", "SRFQC shadow is not 00 00 00 10")
    expect_status("SRFQC_CREATE_COMMAND",
      srq_policy.build_create_command(owner, srq, srqc, 100ns, command),
      RDMA_SC_OK);
    if (command == null || command.opcode_key.opcode != 8'h35)
      `uvm_error("SRFQC_CREATE_COMMAND", "SRFQC create opcode is incorrect")
    expect_status("SRFQC_DELETE_COMMAND",
      srq_policy.build_object_command(8'h37, owner, srq, 100ns, command),
      RDMA_SC_OK);
    expect_status("SRFQC_QUERY_COMMAND",
      srq_policy.build_object_command(8'h38, owner, srq, 100ns, command),
      RDMA_SC_OK);
    srq.owner = foreign_owner;
    command = rdma_cmq_command_desc::type_id::create(
      "stale_srq_foreign_resource_query");
    expect_status("SRFQC_QUERY_REJECTS_FOREIGN_RESOURCE_OWNER",
      srq_policy.build_object_command(8'h38, owner, srq, 100ns, command),
      RDMA_SC_INVALID_ARGUMENT);
    if (command != null)
      `uvm_error("SRFQC_QUERY_REJECTS_FOREIGN_RESOURCE_OWNER",
                 "failed foreign-resource query leaked caller output")
    srq.owner = owner;

    ceq_plan = make_eq_plan("ceq_plan", binding, RDMA_RESOURCE_CEQ);
    ceq = rdma_ceq::type_id::create("ceq_builder_view");
    ceq.handle = make_handle("ceq_incarnation", owner, RDMA_RESOURCE_CEQ,
                             32'h7000_7654);
    ceq.owner = owner;
    ceq.local_ceq_id = 12'h678;
    ceq.depth = 64;
    ceq.hardware_vector = 17;
    expect_status("CEQC_CONTEXT",
      ceq_policy.build_create_context(ceq, ceq_plan, model, slot_image,
                                      shadow_image), RDMA_SC_OK);
    if (!$cast(ceqc, model)) begin
      `uvm_error("CEQC_CONTEXT", "policy did not publish a CEQC model")
    end else begin
      if (ceqc.ceq_h.object_id != ceq.local_ceq_id ||
          ceqc.ceq_h.object_id == ceq.handle.object_id ||
          ceqc.vector_id != 17 || ceqc.producer.index != 0 ||
          ceqc.producer.wrap != 0 || ceqc.consumer.index != 0 ||
          ceqc.consumer.wrap != 0 ||
          ceqc.page_layout.current_base.value != 64'h0000_000a_4444_4000)
        `uvm_error("CEQC_CONTEXT", "canonical CEQC fields are incorrect")
      expect_canonical_image("CEQC_IMAGE", ceqc, RDMA_IMAGE_CEQC, "ceqc",
                             8'h10, slot_image);
    end
    if (shadow_image.size() != 0)
      `uvm_error("CEQC_CONTEXT", "CEQC unexpectedly published shadow bytes")
    expect_status("CEQC_CREATE_COMMAND",
      ceq_policy.build_create_command(owner, ceq, ceqc, 100ns, command),
      RDMA_SC_OK);
    if (command == null || command.opcode_key.opcode != 8'h10)
      `uvm_error("CEQC_CREATE_COMMAND", "CEQC create opcode is incorrect")
    expect_status("CEQC_DELETE_COMMAND",
      ceq_policy.build_object_command(8'h12, owner, ceq, 100ns, command),
      RDMA_SC_OK);
    expect_status("CEQC_QUERY_COMMAND",
      ceq_policy.build_object_command(8'h13, owner, ceq, 100ns, command),
      RDMA_SC_OK);
    ceq.owner = foreign_owner;
    command = rdma_cmq_command_desc::type_id::create(
      "stale_ceq_foreign_resource_delete");
    expect_status("CEQC_DELETE_REJECTS_FOREIGN_RESOURCE_OWNER",
      ceq_policy.build_object_command(8'h12, owner, ceq, 100ns, command),
      RDMA_SC_INVALID_ARGUMENT);
    if (command != null)
      `uvm_error("CEQC_DELETE_REJECTS_FOREIGN_RESOURCE_OWNER",
                 "failed foreign-resource delete leaked caller output")
    ceq.owner = owner;

    aeq_plan = make_eq_plan("aeq_plan", binding, RDMA_RESOURCE_AEQ);
    aeq = rdma_aeq::type_id::create("aeq_builder_view");
    aeq.handle = make_handle("aeq_incarnation", owner, RDMA_RESOURCE_AEQ,
                             32'h8000_6543);
    aeq.owner = owner;
    aeq.local_aeq_id = 12'h789;
    aeq.depth = 64;
    aeq.hardware_vector = 17;
    expect_status("AEQC_CONTEXT",
      aeq_policy.build_create_context(aeq, aeq_plan, model, slot_image,
                                      shadow_image), RDMA_SC_OK);
    if (!$cast(aeqc, model)) begin
      `uvm_error("AEQC_CONTEXT", "policy did not publish an AEQC model")
    end else begin
      if (aeqc.aeq_h.object_id != aeq.local_aeq_id ||
          aeqc.aeq_h.object_id == aeq.handle.object_id ||
          aeqc.vector_id != 17 || aeqc.producer.index != 0 ||
          aeqc.producer.wrap != 0 || aeqc.consumer.index != 0 ||
          aeqc.consumer.wrap != 0)
        `uvm_error("AEQC_CONTEXT", "canonical AEQC fields are incorrect")
      expect_canonical_image("AEQC_IMAGE", aeqc, RDMA_IMAGE_AEQC, "aeqc",
                             8'h14, slot_image);
    end
    expect_status("AEQC_CREATE_COMMAND",
      aeq_policy.build_create_command(owner, aeq, aeqc, 100ns, command),
      RDMA_SC_OK);
    if (command == null || command.opcode_key.opcode != 8'h14)
      `uvm_error("AEQC_CREATE_COMMAND", "AEQC create opcode is incorrect")
    expect_status("AEQC_DELETE_COMMAND",
      aeq_policy.build_object_command(8'h16, owner, aeq, 100ns, command),
      RDMA_SC_OK);
    expect_status("AEQC_QUERY_COMMAND",
      aeq_policy.build_object_command(8'h17, owner, aeq, 100ns, command),
      RDMA_SC_OK);
    aeq.owner = foreign_owner;
    command = rdma_cmq_command_desc::type_id::create(
      "stale_aeq_foreign_resource_query");
    expect_status("AEQC_QUERY_REJECTS_FOREIGN_RESOURCE_OWNER",
      aeq_policy.build_object_command(8'h17, owner, aeq, 100ns, command),
      RDMA_SC_INVALID_ARGUMENT);
    if (command != null)
      `uvm_error("AEQC_QUERY_REJECTS_FOREIGN_RESOURCE_OWNER",
                 "failed foreign-resource query leaked caller output")
    aeq.owner = owner;

    wrong_resource = rdma_queue_resource::type_id::create("wrong_resource");
    slot_image = '{8'haa};
    shadow_image = '{8'hbb};
    model = cqc;
    expect_status("CQC_REJECTS_UNTYPED_RESOURCE",
      cq_policy.build_create_context(wrong_resource, cq_plan, model,
                                     slot_image, shadow_image),
      RDMA_SC_INVALID_ARGUMENT);
    if (model != null || slot_image.size() != 0 || shadow_image.size() != 0)
      `uvm_error("CQC_REJECTS_UNTYPED_RESOURCE",
                 "failed context build leaked caller outputs")

    command = rdma_cmq_command_desc::type_id::create("stale_command");
    expect_status("CQC_REJECTS_WRONG_OPCODE",
      cq_policy.build_object_command(8'h37, owner, cq, 100ns, command),
      RDMA_SC_UNSUPPORTED_OPCODE);
    if (command != null)
      `uvm_error("CQC_REJECTS_WRONG_OPCODE",
                 "failed object command leaked caller output")

    target.pd_ref.mapping.iova.value = 64'hffff_ffff_ffff_f000;
    target.pd_ref.mapping_offset = 4096;
    command = rdma_cmq_command_desc::type_id::create("stale_flush_command");
    expect_status("CQ_FLUSH_IOVA_OVERFLOW",
      cq_policy.build_flush_command(owner, target, 100ns, command),
      RDMA_SC_DMA_TRANSLATION);
    if (command != null)
      `uvm_error("CQ_FLUSH_IOVA_OVERFLOW",
                 "failed flush command leaked caller output")
  endfunction

  function automatic rdma_semantic_request make_executor_request(
    string name,
    rdma_resource_kind_e kind,
    rdma_function_binding binding,
    rdma_ceq dependency,
    bit borrowed
  );
    rdma_create_cq_req cq_req;
    rdma_create_ceq_req ceq_req;
    rdma_create_aeq_req aeq_req;
    rdma_dma_mapping mapping;
    rdma_queue_backing_slice slice;
    rdma_queue_backing_role_e role;

    case (kind)
      RDMA_RESOURCE_CQ: begin
        cq_req = rdma_create_cq_req::type_id::create(name);
        cq_req.owner = binding.make_handle();
        cq_req.depth = 64;
        cq_req.cqe_size_bytes = 64;
        cq_req.ceq_h = dependency == null ? null : dependency.handle;
        if (borrowed) begin
          cq_req.ring_backing.mode = RDMA_QUEUE_BACKING_BORROWED;
          role = RDMA_QUEUE_ROLE_CQ_RING;
          mapping = make_mapping({name, "_mapping"}, binding,
            64'h0000_0030_0000_0000, 64'hdead_0000_0000_0000, 4096);
          slice = make_slice({name, "_slice"}, role, mapping, 0, 4096);
          cq_req.ring_backing.slices.push_back(slice);
        end
        return cq_req;
      end
      RDMA_RESOURCE_CEQ: begin
        ceq_req = rdma_create_ceq_req::type_id::create(name);
        ceq_req.owner = binding.make_handle();
        ceq_req.depth = 64;
        ceq_req.vector_id = 3;
        if (borrowed) begin
          ceq_req.ring_backing.mode = RDMA_QUEUE_BACKING_BORROWED;
          role = RDMA_QUEUE_ROLE_CEQ_RING;
          mapping = make_mapping({name, "_mapping"}, binding,
            64'h0000_0031_0000_0000, 64'hdead_1000_0000_0000, 4096);
          slice = make_slice({name, "_slice"}, role, mapping, 0, 4096);
          ceq_req.ring_backing.slices.push_back(slice);
        end
        return ceq_req;
      end
      default: begin
        aeq_req = rdma_create_aeq_req::type_id::create(name);
        aeq_req.owner = binding.make_handle();
        aeq_req.depth = 64;
        aeq_req.vector_id = 3;
        if (borrowed) begin
          aeq_req.ring_backing.mode = RDMA_QUEUE_BACKING_BORROWED;
          role = RDMA_QUEUE_ROLE_AEQ_RING;
          mapping = make_mapping({name, "_mapping"}, binding,
            64'h0000_0032_0000_0000, 64'hdead_2000_0000_0000, 4096);
          slice = make_slice({name, "_slice"}, role, mapping, 0, 4096);
          aeq_req.ring_backing.slices.push_back(slice);
        end
        return aeq_req;
      end
    endcase
  endfunction

  function automatic rdma_create_srq_req make_executor_srq_request(
    string name,
    rdma_function_binding binding,
    rdma_pd dependency,
    int unsigned max_sge = 4
  );
    rdma_create_srq_req request;

    request = rdma_create_srq_req::type_id::create(name);
    request.owner = binding.make_handle();
    request.depth = 64;
    request.max_sge = max_sge;
    request.limit_threshold = 16;
    request.pd_h = dependency == null ? null : dependency.handle;
    request.payload_backing.mode = RDMA_QUEUE_BACKING_OWNED;
    return request;
  endfunction

  // Build one real ACTIVE queue through the lifecycle executor and return all
  // adapters needed by a subsequent destroy/failure assertion.  Keeping each
  // case isolated ensures that release authority from one scenario cannot
  // accidentally satisfy another scenario.
  task automatic create_destroy_fixture(
    string label,
    rdma_resource_kind_e kind,
    output rdma_function_binding binding,
    output rdma_fault_inject_resource_manager manager,
    output rdma_queue_destroy_trace_mem mem,
    output rdma_queue_destroy_trace_context context_backing,
    output rdma_queue_destroy_trace_cmq cmq,
    output rdma_mock_call_trace trace,
    output rdma_queue_lifecycle_executor executor,
    output rdma_queue_resource queue,
    output rdma_control_result create_result,
    output rdma_ceq ceq_dependency,
    output rdma_pd pd_dependency,
    input bit borrowed = 1'b0
  );
    rdma_semantic_request request;

    binding = make_binding({label, "_binding"});
    manager = rdma_fault_inject_resource_manager::type_id::create(
      {label, "_manager"}
    );
    ceq_dependency = null;
    pd_dependency = null;
    if (kind == RDMA_RESOURCE_CQ)
      expect_status({label, "_CEQ"},
                    manager.create_ceq(binding, ceq_dependency), RDMA_SC_OK);
    else if (kind == RDMA_RESOURCE_SRQ)
      expect_status({label, "_PD"},
                    manager.create_pd(binding, pd_dependency), RDMA_SC_OK);

    mem = rdma_queue_destroy_trace_mem::type_id::create(
      {label, "_mem"}
    );
    mem.queue_kind = kind;
    mem.include_sgb = kind == RDMA_RESOURCE_SRQ;
    context_backing = rdma_queue_destroy_trace_context::type_id::create(
      {label, "_context"}
    );
    cmq = rdma_queue_destroy_trace_cmq::type_id::create(
      {label, "_cmq"}
    );
    trace = rdma_mock_call_trace::type_id::create({label, "_trace"});
    mem.set_shared_trace(trace);
    context_backing.set_call_trace(trace);
    cmq.set_call_trace(trace);
    executor = rdma_queue_lifecycle_executor::type_id::create(
      {label, "_executor"}
    );
    expect_status({label, "_CONFIGURE"}, executor.configure(
      manager, cmq, mem, context_backing, 100ns
    ), RDMA_SC_OK);

    if (kind == RDMA_RESOURCE_SRQ)
      request = make_executor_srq_request({label, "_request"}, binding,
                                           pd_dependency, 4);
    else
      request = make_executor_request({label, "_request"}, kind, binding,
                                       ceq_dependency, borrowed);
    queue = null;
    create_result = null;
    executor.create_locked(binding, binding.make_handle(), request,
                           64'd1000, queue, create_result);
    if (create_result == null || !create_result.ok() || queue == null ||
        queue.state != RDMA_RESOURCE_ACTIVE)
      `uvm_error(label, $sformatf(
        "fixture did not publish ACTIVE queue: %s",
        create_result == null || create_result.status == null ? "null" :
          create_result.status.convert2string()))

    trace.clear();
    context_backing.call_trace.delete();
    cmq.begin_destroy_trace(trace, kind);
    mem.reset_destroy_trace();
  endtask

  function automatic rdma_destroy_resource_req make_destroy_request(
    string name,
    rdma_function_binding binding,
    rdma_handle target
  );
    rdma_destroy_resource_req request;

    request = rdma_destroy_resource_req::type_id::create(name);
    request.owner = binding.make_handle();
    request.target_h = target;
    return request;
  endfunction

  function automatic void expect_destroy_trace(
    string label,
    rdma_mock_call_trace trace,
    string expected[$]
  );
    if (trace == null || trace.calls.size() != expected.size()) begin
      if (trace == null)
        `uvm_error(label, $sformatf(
          "destroy trace is null, expected %0d calls", expected.size()))
      else
        `uvm_error(label, $sformatf(
          "destroy trace has %0d calls, expected %0d: %p",
          trace.calls.size(), expected.size(), trace.calls))
      return;
    end
    foreach (expected[i]) begin
      if (trace.calls[i] != expected[i])
        `uvm_error(label, $sformatf(
          "destroy trace[%0d] is %s, expected %s", i,
          trace.calls[i], expected[i]))
    end
  endfunction

  function automatic int unsigned count_executor_host_calls(
    rdma_mock_host_mem mem, string method_name
  );
    int unsigned count;
    count = 0;
    foreach (mem.calls[i])
      if (mem.calls[i].method_name == method_name)
        count++;
    return count;
  endfunction

  function automatic int unsigned count_executor_host_releases_for_backing(
    rdma_mock_host_mem mem, longint unsigned backing_address
  );
    int unsigned count;

    count = 0;
    foreach (mem.calls[i])
      if (mem.calls[i] != null && mem.calls[i].method_name == "release" &&
          mem.calls[i].mapping != null &&
          mem.calls[i].mapping.backing_addr.value == backing_address)
        count++;
    return count;
  endfunction

  function automatic int unsigned count_executor_recovery_step(
    rdma_control_step_e steps[$], rdma_control_step_e expected
  );
    int unsigned count;

    count = 0;
    foreach (steps[i])
      if (steps[i] == expected)
        count++;
    return count;
  endfunction

  function automatic int unsigned count_executor_rollback_code(
    rdma_status statuses[$], rdma_status_code_e expected
  );
    int unsigned count;

    count = 0;
    foreach (statuses[i])
      if (statuses[i] != null && statuses[i].code == expected)
        count++;
    return count;
  endfunction

  task automatic retry_executor_local_cleanup(
    string label,
    rdma_resource_manager manager,
    rdma_queue_executor_trace_mem mem,
    rdma_queue_executor_trace_context context_backing,
    rdma_handle resource_h
  );
    rdma_recovery_record recovery;
    rdma_resource snapshot;
    rdma_status status;
    bit release_complete;
    bit backing_step_completed;

    status = manager.lookup_recovery(resource_h, recovery);
    expect_status({label, "_RETRY_LOOKUP"}, status, RDMA_SC_OK);
    if (recovery == null || recovery.queue_plan == null) begin
      `uvm_error(label, "retry recovery plan is unavailable")
      return;
    end
    if (recovery.queue_plan.context_ref != null &&
        !recovery.queue_plan.context_ref.release_complete) begin
      release_complete = 1'b0;
      status = context_backing.query_release_completion(
        recovery.queue_plan.context_ref, release_complete
      );
      expect_status({label, "_CONTEXT_QUERY"}, status, RDMA_SC_OK);
      if (!release_complete) begin
        status = context_backing.\release (
          recovery.queue_plan.context_ref
        );
        expect_status({label, "_CONTEXT_RELEASE"}, status, RDMA_SC_OK);
      end
      status = manager.record_queue_context_cleanup_complete(resource_h);
      expect_status({label, "_CONTEXT_PROGRESS"}, status, RDMA_SC_OK);
    end
    for (int i = int'(recovery.queue_plan.refs.size()) - 1; i >= 0; i--) begin
      if (recovery.queue_plan.refs[i] == null ||
          recovery.queue_plan.refs[i].ownership !=
            RDMA_OWNERSHIP_CONTROL_PLANE ||
          recovery.queue_plan.refs[i].cleanup_complete)
        continue;
      release_complete = 1'b0;
      status = recovery.queue_plan.refs[i].mapping.release_completion_status(
        release_complete
      );
      expect_status($sformatf("%s_REF_%0d_QUERY", label, i), status,
                    RDMA_SC_OK);
      if (!release_complete) begin
        status = mem.\release (recovery.queue_plan.refs[i].mapping);
        expect_status($sformatf("%s_REF_%0d_RELEASE", label, i), status,
                      RDMA_SC_OK);
      end
      status = manager.record_queue_cleanup_complete(
        resource_h, recovery.queue_plan.refs[i].role
      );
      expect_status($sformatf("%s_REF_%0d_PROGRESS", label, i), status,
                    RDMA_SC_OK);
    end
    recovery = null;
    status = manager.lookup_recovery(resource_h, recovery);
    expect_status({label, "_RETRY_REFRESH"}, status, RDMA_SC_OK);
    if (recovery == null) begin
      `uvm_error(label, "retry recovery refresh is unavailable")
      return;
    end
    for (int i = int'(recovery.pending_steps.size()) - 1; i >= 0; i--)
      if (recovery.pending_steps[i] == RDMA_CTRL_STEP_BACKING_RELEASED)
        recovery.pending_steps.delete(i);
    backing_step_completed = 1'b0;
    foreach (recovery.completed_steps[i])
      if (recovery.completed_steps[i] == RDMA_CTRL_STEP_BACKING_RELEASED)
        backing_step_completed = 1'b1;
    if (!backing_step_completed)
      recovery.completed_steps.push_back(RDMA_CTRL_STEP_BACKING_RELEASED);
    status = manager.mark_error(resource_h, recovery);
    expect_status({label, "_RETRY_PERSIST"}, status, RDMA_SC_OK);
    status = manager.finalize_release(resource_h);
    expect_status({label, "_RETRY_FINALIZE"}, status, RDMA_SC_OK);
    status = manager.lookup(resource_h, snapshot);
    expect_status({label, "_RETRY_RELEASED"}, status,
                  RDMA_SC_INVALID_STATE);
  endtask

  task automatic check_executor_positive_case(
    rdma_resource_kind_e kind, bit borrowed
  );
    string label;
    string prefix;
    rdma_function_binding binding;
    rdma_fault_inject_resource_manager manager;
    rdma_ceq dependency;
    rdma_queue_executor_trace_mem mem;
    rdma_queue_executor_trace_context context_backing;
    rdma_mock_cmq_port cmq;
    rdma_mock_call_trace trace;
    rdma_queue_lifecycle_executor executor;
    rdma_semantic_request request;
    rdma_queue_resource queue;
    rdma_control_result result;
    rdma_resource looked_up;
    rdma_status status;
    int unsigned expected_live;

    label = $sformatf("EXEC_%s_%s", kind.name(),
                      borrowed ? "BORROWED" : "OWNED");
    case (kind)
      RDMA_RESOURCE_CQ:  prefix = "CQ";
      RDMA_RESOURCE_CEQ: prefix = "CEQ";
      default:           prefix = "AEQ";
    endcase
    binding = make_binding({label, "_binding"});
    manager = rdma_fault_inject_resource_manager::type_id::create(
      {label, "_manager"});
    dependency = null;
    if (kind == RDMA_RESOURCE_CQ)
      expect_status({label, "_DEPENDENCY"},
                    manager.create_ceq(binding, dependency), RDMA_SC_OK);
    mem = rdma_queue_executor_trace_mem::type_id::create({label, "_mem"});
    mem.queue_kind = kind;
    context_backing = rdma_queue_executor_trace_context::type_id::create(
      {label, "_context"});
    cmq = rdma_mock_cmq_port::type_id::create({label, "_cmq"});
    trace = rdma_mock_call_trace::type_id::create({label, "_trace"});
    mem.set_shared_trace(trace);
    context_backing.set_call_trace(trace);
    cmq.set_call_trace(trace);
    executor = rdma_queue_lifecycle_executor::type_id::create(
      {label, "_executor"});
    expect_status({label, "_CONFIGURE"}, executor.configure(
      manager, cmq, mem, context_backing, 100ns), RDMA_SC_OK);
    request = make_executor_request({label, "_request"}, kind, binding,
                                    dependency, borrowed);
    queue = null;
    result = null;
    executor.create_locked(binding, binding.make_handle(), request, 64'd101,
                           queue, result);
    if (result == null || !result.ok() || result.transaction_id != 64'd101 ||
        result.status == null || result.primary_status == null ||
        result.status.code != RDMA_SC_OK ||
        result.primary_status.code != RDMA_SC_OK || queue == null ||
        queue.state != RDMA_RESOURCE_ACTIVE ||
        !result.final_resource_state_known ||
        result.final_resource_state != RDMA_RESOURCE_ACTIVE)
      `uvm_error(label, $sformatf(
        "create did not publish ACTIVE: status=%s primary=%s trace=%p",
        result == null || result.status == null ? "null" :
          result.status.convert2string(),
        result == null || result.primary_status == null ? "null" :
          result.primary_status.convert2string(), trace.calls))
    status = manager.lookup(queue == null ? null : queue.handle, looked_up);
    expect_status({label, "_LOOKUP"}, status, RDMA_SC_OK);
    if (looked_up == null || looked_up.state != RDMA_RESOURCE_ACTIVE)
      `uvm_error(label, "registry did not retain the ACTIVE queue")
    if (manager.release_reserved_calls != 0 ||
        count_executor_host_calls(mem, "release") != 0 ||
        context_backing.release_call_count != 0)
      `uvm_error(label, "successful create released acquired authority")
    expected_live = borrowed ? 1 : 2;
    if (mem.live_allocations() != expected_live)
      `uvm_error(label, "successful create retained the wrong owned count")
    if (trace.calls.size() != (kind == RDMA_RESOURCE_CQ ? 5 : 3) ||
        trace.calls[0] != {"host_write:", prefix, "_RING"} ||
        trace.calls[1] != {"host_write:", prefix, "_PD"})
      `uvm_error(label, $sformatf(
        "payload/PD trace prefix is not canonical: %p", trace.calls))
    if (kind == RDMA_RESOURCE_CQ) begin
      if (trace.calls.size() == 5 &&
          (trace.calls[2] != "context_write:CQC_CONTEXT_SLOT" ||
           trace.calls[3] != "context_write:CQC_CONTEXT_SHADOW" ||
           trace.calls[4] != "cmq:0c"))
        `uvm_error(label, "CQ context/create trace is out of order")
      if (dependency != null) begin
        status = manager.release_reserved(dependency.handle);
        expect_status({label, "_DEPENDENCY_RETAINED"}, status,
                      RDMA_SC_RESOURCE_BUSY);
      end
    end
    else if (trace.calls.size() == 3 &&
             trace.calls[2] != (kind == RDMA_RESOURCE_CEQ ?
                                "cmq:10" : "cmq:14"))
      `uvm_error(label, "EQ create trace is out of order")
    if (kind != RDMA_RESOURCE_CQ && context_backing.call_trace.size() != 0)
      `uvm_error(label, "EQ create touched context backing")
  endtask

  task automatic check_executor_failure_case(int unsigned mode);
    string label;
    rdma_function_binding binding;
    rdma_fault_inject_resource_manager manager;
    rdma_ceq dependency;
    rdma_queue_executor_trace_mem mem;
    rdma_queue_executor_trace_context context_backing;
    rdma_mock_cmq_port cmq;
    rdma_queue_lifecycle_executor executor;
    rdma_semantic_request request;
    rdma_queue_resource queue;
    rdma_control_result result;
    rdma_resource looked_up;
    rdma_recovery_record recovery;
    rdma_status injected;
    rdma_status status;
    bit gate_observed;
    int unsigned expected_releases;
    int unsigned expected_context_releases;
    int unsigned expected_reservation_releases;

    label = $sformatf("EXEC_FAIL_%0d", mode);
    binding = make_binding({label, "_binding"});
    manager = rdma_fault_inject_resource_manager::type_id::create(
      {label, "_manager"});
    expect_status({label, "_DEPENDENCY"},
                  manager.create_ceq(binding, dependency), RDMA_SC_OK);
    mem = rdma_queue_executor_trace_mem::type_id::create({label, "_mem"});
    context_backing = rdma_queue_executor_trace_context::type_id::create(
      {label, "_context"});
    cmq = rdma_mock_cmq_port::type_id::create({label, "_cmq"});
    if (mode == 9)
      executor = rdma_queue_executor_generation_fail::type_id::create(
        {label, "_executor"});
    else
      executor = rdma_queue_lifecycle_executor::type_id::create(
        {label, "_executor"});
    expect_status({label, "_CONFIGURE"}, executor.configure(
      manager, cmq, mem, context_backing, 100ns), RDMA_SC_OK);
    request = make_executor_request({label, "_request"}, RDMA_RESOURCE_CQ,
                                    binding, dependency, 1'b0);
    injected = rdma_status::make(RDMA_SC_UNKNOWN_HW_ERROR,
                                 {label, " injected failure"});
    case (mode)
      0: mem.fail_on_allocate = 1;
      1: mem.fail_on_allocate = 2;
      2: void'(mem.fail_write_at(1, injected));
      3: void'(mem.fail_write_at(2, injected));
      4: void'(context_backing.fail_next("acquire", injected));
      5: void'(context_backing.fail_next("write", injected));
      6: void'(manager.fail_next_transition("stage_allocated", injected));
      7: cmq.fail_opcode(8'h0c, injected);
      8: cmq.timeout_opcode(8'h0c);
      9: begin end
      10: void'(manager.fail_next_transition("commit_programmed", injected));
      11: void'(manager.fail_next_transition("activate", injected));
      default: `uvm_fatal(label, "unknown failure mode")
    endcase
    queue = null;
    result = null;
    executor.create_locked(binding, binding.make_handle(), request,
                           64'd200 + mode, queue, result);
    if (result == null || result.transaction_id != 64'd200 + mode ||
        result.status == null || result.primary_status == null || result.ok())
      `uvm_error(label, "failure result is incomplete or spuriously successful")
    if (mode == 8) begin
      if (result.status.code != RDMA_SC_RECOVERY_REQUIRED ||
          result.primary_status.code != RDMA_SC_TIMEOUT ||
          !result.recovery_required || queue == null ||
          queue.state != RDMA_RESOURCE_ERROR)
        `uvm_error(label, "timeout did not return canonical ERROR recovery")
      status = manager.lookup_recovery(result.resource_h, recovery);
      expect_status({label, "_RECOVERY"}, status, RDMA_SC_OK);
      if (recovery == null || !recovery.queue_recovery_valid ||
          recovery.queue_intent != RDMA_QUEUE_RECOVER_CREATE_ROLLBACK ||
          recovery.ambiguous_queue_operation != RDMA_QUEUE_AMBIG_CREATE ||
          recovery.ambiguous_ticket == null || recovery.queue_plan == null ||
          recovery.hardware_presence != RDMA_HW_PRESENCE_UNKNOWN ||
          recovery.queue_create_opcode == null ||
          recovery.queue_create_opcode.opcode != 8'h0c ||
          recovery.queue_delete_opcode == null ||
          recovery.queue_delete_opcode.opcode != 8'h0e ||
          recovery.queue_query_opcode == null ||
          recovery.queue_query_opcode.opcode != 8'h0f)
        `uvm_error(label, "timeout recovery lost queue plan/ticket/opcodes")
      if (count_executor_host_calls(mem, "release") != 0 ||
          context_backing.release_call_count != 0 ||
          manager.release_reserved_calls != 0)
        `uvm_error(label, "ambiguous create destroyed retained authority")
      status = manager.release_reserved(dependency.handle);
      expect_status({label, "_DEPENDENCY_RETAINED"}, status,
                    RDMA_SC_RESOURCE_BUSY);
      return;
    end
    if (queue != null || result.recovery_required ||
        result.status.code != result.primary_status.code ||
        !result.final_resource_state_known ||
        result.final_resource_state != RDMA_RESOURCE_RELEASED)
      `uvm_error(label, "definitive failure did not finish fail-atomically")
    status = manager.lookup(result.resource_h, looked_up);
    expect_status({label, "_RELEASED_LOOKUP"}, status,
                  RDMA_SC_INVALID_STATE);
    expected_releases = (mode == 0) ? 0 : (mode == 1 ? 1 : 2);
    expected_context_releases = mode inside {2, 3, 5, 6, 7, 9, 10, 11} ?
                                1 : 0;
    expected_reservation_releases = mode == 11 ? 0 : 1;
    if (count_executor_host_calls(mem, "release") != expected_releases ||
        context_backing.release_call_count != expected_context_releases ||
        manager.release_reserved_calls != expected_reservation_releases)
      `uvm_error(label, "rollback release cardinality is incorrect")
    status = manager.release_reserved(dependency.handle);
    expect_status({label, "_DEPENDENCY_RELEASED"}, status, RDMA_SC_OK);
    if (mode inside {9, 10, 11}) begin
      if (cmq.calls.size() != 3 || cmq.calls[0].opcode != 8'h0c ||
          cmq.calls[1].opcode != 8'h0e || cmq.calls[2].opcode != 8'h0a)
        `uvm_error(label, "post-create rollback omitted delete/CQ_PD flush")
    end
  endtask

  task automatic check_executor_cq_reset_cancelled();
    for (int unsigned mode = 0; mode < 3; mode++) begin
      string label;
      rdma_function_binding binding;
      rdma_fault_inject_resource_manager manager;
      rdma_ceq dependency;
      rdma_queue_executor_trace_mem mem;
      rdma_queue_executor_trace_context context_backing;
      rdma_mock_cmq_port cmq;
      rdma_queue_lifecycle_executor executor;
      rdma_semantic_request request;
      rdma_queue_resource queue;
      rdma_control_result result;
      rdma_recovery_record recovery;
      rdma_status primary;
      rdma_status reset_status;
      rdma_status status;
      rdma_queue_ambiguous_operation_e expected_operation;
      rdma_hw_presence_e expected_presence;
      bit [7:0] expected_ticket_opcode;

      label = $sformatf("EXEC_CQ_RESET_%0d", mode);
      binding = make_binding({label, "_binding"});
      manager = rdma_fault_inject_resource_manager::type_id::create(
        {label, "_manager"}
      );
      expect_status({label, "_DEPENDENCY"},
                    manager.create_ceq(binding, dependency), RDMA_SC_OK);
      mem = rdma_queue_executor_trace_mem::type_id::create({label, "_mem"});
      context_backing = rdma_queue_executor_trace_context::type_id::create(
        {label, "_context"}
      );
      cmq = rdma_mock_cmq_port::type_id::create({label, "_cmq"});
      executor = rdma_queue_lifecycle_executor::type_id::create(
        {label, "_executor"}
      );
      expect_status({label, "_CONFIGURE"}, executor.configure(
        manager, cmq, mem, context_backing, 100ns), RDMA_SC_OK);
      request = make_executor_request({label, "_request"}, RDMA_RESOURCE_CQ,
                                      binding, dependency, 1'b0);
      primary = rdma_status::make(RDMA_SC_UNKNOWN_HW_ERROR,
                                  {label, " primary"});
      reset_status = rdma_status::make(RDMA_SC_RESET_CANCELLED,
                                       {label, " reset cancelled"});
      case (mode)
        0: begin
          cmq.fail_opcode(8'h0c, reset_status);
          expected_operation = RDMA_QUEUE_AMBIG_CREATE;
          expected_presence = RDMA_HW_PRESENCE_UNKNOWN;
          expected_ticket_opcode = 8'h0c;
        end
        1: begin
          void'(manager.fail_next_transition("commit_programmed", primary));
          cmq.fail_opcode(8'h0e, reset_status);
          expected_operation = RDMA_QUEUE_AMBIG_DELETE;
          expected_presence = RDMA_HW_PRESENCE_UNKNOWN;
          expected_ticket_opcode = 8'h0e;
        end
        default: begin
          void'(manager.fail_next_transition("commit_programmed", primary));
          cmq.fail_opcode(8'h0a, reset_status);
          expected_operation = RDMA_QUEUE_AMBIG_OCC_FLUSH;
          expected_presence = RDMA_HW_PRESENCE_ABSENT;
          expected_ticket_opcode = 8'h0a;
        end
      endcase
      executor.create_locked(binding, binding.make_handle(), request,
                             64'd400 + mode, queue, result);
      if (result == null || result.status == null ||
          result.primary_status == null ||
          result.status.code != RDMA_SC_RECOVERY_REQUIRED ||
          result.primary_status.code != (mode == 0 ?
            RDMA_SC_RESET_CANCELLED : RDMA_SC_UNKNOWN_HW_ERROR) ||
          !result.recovery_required || queue == null ||
          queue.state != RDMA_RESOURCE_ERROR)
        `uvm_error(label, "reset cancellation did not retain CQ ERROR")
      status = manager.lookup_recovery(result.resource_h, recovery);
      expect_status({label, "_RECOVERY"}, status, RDMA_SC_OK);
      if (recovery == null || recovery.queue_plan == null ||
          recovery.ambiguous_queue_operation != expected_operation ||
          recovery.hardware_presence != expected_presence ||
          recovery.ambiguous_ticket == null ||
          recovery.ambiguous_ticket.opcode_key == null ||
          recovery.ambiguous_ticket.opcode_key.opcode !=
            expected_ticket_opcode ||
          count_executor_recovery_step(
            recovery.pending_steps, RDMA_CTRL_STEP_BACKING_RELEASED
          ) != 1)
        `uvm_error(label,
                   "reset recovery lost CQ operation/ticket/plan authority")
      if (mode != 0 && count_executor_rollback_code(
            result.rollback_statuses, RDMA_SC_RESET_CANCELLED
          ) != 1)
        `uvm_error(label, "rollback reset status was not aggregated")
      if (count_executor_host_calls(mem, "release") != 0 ||
          context_backing.release_call_count != 0 ||
          manager.release_reserved_calls != 0)
        `uvm_error(label, "ambiguous CQ outcome released local authority")
      status = manager.release_reserved(dependency.handle);
      expect_status({label, "_DEPENDENCY_RETAINED"}, status,
                    RDMA_SC_RESOURCE_BUSY);
    end
  endtask

  task automatic check_executor_local_cleanup_recovery();
    string label;
    rdma_function_binding binding;
    rdma_fault_inject_resource_manager manager;
    rdma_ceq dependency;
    rdma_queue_executor_trace_mem mem;
    rdma_queue_executor_trace_context context_backing;
    rdma_mock_cmq_port cmq;
    rdma_queue_lifecycle_executor executor;
    rdma_semantic_request request;
    rdma_queue_resource queue;
    rdma_control_result result;
    rdma_recovery_record recovery;
    rdma_status primary;
    rdma_status cleanup_failure;
    rdma_status status;

    label = "EXEC_CQ_CONTEXT_CLEANUP_RECOVERY";
    binding = make_binding({label, "_binding"});
    manager = rdma_fault_inject_resource_manager::type_id::create(
      {label, "_manager"}
    );
    expect_status({label, "_DEPENDENCY"},
                  manager.create_ceq(binding, dependency), RDMA_SC_OK);
    mem = rdma_queue_executor_trace_mem::type_id::create({label, "_mem"});
    context_backing = rdma_queue_executor_trace_context::type_id::create(
      {label, "_context"}
    );
    cmq = rdma_mock_cmq_port::type_id::create({label, "_cmq"});
    executor = rdma_queue_lifecycle_executor::type_id::create(
      {label, "_executor"}
    );
    expect_status({label, "_CONFIGURE"}, executor.configure(
      manager, cmq, mem, context_backing, 100ns), RDMA_SC_OK);
    request = make_executor_request({label, "_request"}, RDMA_RESOURCE_CQ,
                                    binding, dependency, 1'b0);
    primary = rdma_status::make(RDMA_SC_UNKNOWN_HW_ERROR,
                                {label, " primary"});
    cleanup_failure = rdma_status::make(RDMA_SC_DMA_TRANSLATION,
                                        {label, " context release"});
    void'(context_backing.fail_next("write", primary));
    void'(context_backing.fail_next("release", cleanup_failure));
    executor.create_locked(binding, binding.make_handle(), request, 64'd410,
                           queue, result);
    if (result == null || result.status == null ||
        result.primary_status == null ||
        result.status.code != RDMA_SC_RECOVERY_REQUIRED ||
        result.primary_status.code != RDMA_SC_UNKNOWN_HW_ERROR ||
        !result.recovery_required || queue == null ||
        queue.state != RDMA_RESOURCE_ERROR ||
        manager.release_reserved_calls != 0 || mem.live_allocations() != 0 ||
        count_executor_rollback_code(
          result.rollback_statuses, RDMA_SC_DMA_TRANSLATION
        ) != 1)
      `uvm_error(label,
                 "context cleanup failure discarded durable CQ authority")
    status = manager.lookup_recovery(result.resource_h, recovery);
    expect_status({label, "_RECOVERY"}, status, RDMA_SC_OK);
    if (recovery == null || recovery.queue_plan == null ||
        recovery.queue_plan.context_ref == null ||
        recovery.queue_plan.context_ref.release_complete ||
        recovery.hardware_presence != RDMA_HW_PRESENCE_ABSENT ||
        recovery.ambiguous_queue_operation != RDMA_QUEUE_AMBIG_NONE ||
        recovery.ambiguous_ticket != null ||
        recovery.queue_create_opcode == null ||
        recovery.queue_create_opcode.opcode != 8'h0c ||
        count_executor_recovery_step(
          recovery.pending_steps, RDMA_CTRL_STEP_BACKING_RELEASED
        ) != 1)
      `uvm_error(label, "context cleanup recovery schema is incomplete")
    retry_executor_local_cleanup(label, manager, mem, context_backing,
                                 result.resource_h);
    if (count_executor_host_calls(mem, "release") != 2 ||
        context_backing.release_call_count != 1 ||
        mem.live_allocations() != 0)
      `uvm_error(label, "cleanup retry duplicated or omitted exact authority")
    status = manager.release_reserved(dependency.handle);
    expect_status({label, "_DEPENDENCY_RELEASED"}, status, RDMA_SC_OK);
  endtask

  task automatic check_executor_prestage_cleanup_recovery();
    for (int unsigned mode = 0; mode < 3; mode++) begin
      string label;
      rdma_resource_kind_e kind;
      rdma_function_binding binding;
      rdma_fault_inject_resource_manager manager;
      rdma_ceq dependency;
      rdma_queue_executor_trace_mem mem;
      rdma_queue_executor_trace_context context_backing;
      rdma_mock_cmq_port cmq;
      rdma_queue_lifecycle_executor executor;
      rdma_semantic_request request;
      rdma_queue_resource queue;
      rdma_control_result result;
      rdma_recovery_record recovery;
      rdma_status primary;
      rdma_status cleanup_failure;
      rdma_status status;

      case (mode)
        0: kind = RDMA_RESOURCE_CQ;
        1: kind = RDMA_RESOURCE_CEQ;
        default: kind = RDMA_RESOURCE_AEQ;
      endcase
      label = $sformatf("EXEC_PRESTAGE_%s_CLEANUP", kind.name());
      binding = make_binding({label, "_binding"});
      manager = rdma_fault_inject_resource_manager::type_id::create(
        {label, "_manager"}
      );
      dependency = null;
      if (kind == RDMA_RESOURCE_CQ)
        expect_status({label, "_DEPENDENCY"},
                      manager.create_ceq(binding, dependency), RDMA_SC_OK);
      mem = rdma_queue_executor_trace_mem::type_id::create({label, "_mem"});
      mem.queue_kind = kind;
      context_backing = rdma_queue_executor_trace_context::type_id::create(
        {label, "_context"}
      );
      cmq = rdma_mock_cmq_port::type_id::create({label, "_cmq"});
      executor = rdma_queue_lifecycle_executor::type_id::create(
        {label, "_executor"}
      );
      expect_status({label, "_CONFIGURE"}, executor.configure(
        manager, cmq, mem, context_backing, 100ns), RDMA_SC_OK);
      request = make_executor_request({label, "_request"}, kind, binding,
                                      dependency, 1'b0);
      primary = rdma_status::make(RDMA_SC_UNKNOWN_HW_ERROR,
                                  {label, " stage"});
      cleanup_failure = rdma_status::make(RDMA_SC_DMA_TRANSLATION,
                                          {label, " local release"});
      void'(manager.fail_next_transition("stage_allocated", primary));
      if (kind == RDMA_RESOURCE_CQ)
        void'(context_backing.fail_next("release", cleanup_failure));
      else
        void'(mem.fail_next("release", cleanup_failure));
      executor.create_locked(binding, binding.make_handle(), request,
                             64'd420 + mode, queue, result);
      status = manager.lookup_recovery(result.resource_h, recovery);
      expect_status({label, "_RECOVERY"}, status, RDMA_SC_OK);
      if (result == null || result.status == null ||
          result.primary_status == null ||
          result.status.code != RDMA_SC_RECOVERY_REQUIRED ||
          result.primary_status.code != RDMA_SC_UNKNOWN_HW_ERROR ||
          !result.recovery_required || queue == null ||
          queue.state != RDMA_RESOURCE_ERROR || recovery == null ||
          recovery.queue_plan == null ||
          recovery.queue_plan.resource_kind != kind ||
          recovery.hardware_presence != RDMA_HW_PRESENCE_ABSENT ||
          recovery.queue_intent != RDMA_QUEUE_RECOVER_CREATE_ROLLBACK ||
          recovery.ambiguous_queue_operation != RDMA_QUEUE_AMBIG_NONE ||
          recovery.ambiguous_ticket != null ||
          count_executor_rollback_code(
            result.rollback_statuses, RDMA_SC_DMA_TRANSLATION
          ) != 1 ||
          count_executor_recovery_step(
            recovery.pending_steps, RDMA_CTRL_STEP_BACKING_RELEASED
          ) != 1 || manager.release_reserved_calls != 0)
        `uvm_error(label,
                   "pre-stage cleanup failure lost transaction authority")
      retry_executor_local_cleanup(label, manager, mem, context_backing,
                                   result.resource_h);
      if (kind == RDMA_RESOURCE_CQ) begin
        if (count_executor_host_calls(mem, "release") != 2 ||
            context_backing.release_call_count != 1)
          `uvm_error(label, "CQ pre-stage retry duplicated local authority")
        status = manager.release_reserved(dependency.handle);
        expect_status({label, "_DEPENDENCY_RELEASED"}, status, RDMA_SC_OK);
      end
      else if (count_executor_host_calls(mem, "release") != 3)
        `uvm_error(label, "EQ pre-stage retry used the wrong host authority")
    end
  endtask

  task automatic check_executor_reservation_release_recovery();
    rdma_resource_kind_e kinds[$];

    kinds.push_back(RDMA_RESOURCE_CQ);
    kinds.push_back(RDMA_RESOURCE_CEQ);
    kinds.push_back(RDMA_RESOURCE_AEQ);
    foreach (kinds[kind_index]) begin
      for (int unsigned borrow_mode = 0; borrow_mode < 2; borrow_mode++) begin
      string label;
      rdma_resource_kind_e kind;
      bit borrowed;
      rdma_function_binding binding;
      rdma_fault_inject_resource_manager manager;
      rdma_ceq dependency;
      rdma_queue_executor_trace_mem mem;
      rdma_queue_executor_trace_context context_backing;
      rdma_mock_cmq_port cmq;
      rdma_queue_lifecycle_executor executor;
      rdma_semantic_request request;
      rdma_create_cq_req borrowed_cq_request;
      rdma_create_ceq_req borrowed_ceq_request;
      rdma_create_aeq_req borrowed_aeq_request;
      rdma_dma_mapping borrowed_primary_mapping;
      rdma_dma_mapping borrowed_segment_mapping;
      rdma_queue_backing_slice borrowed_slice;
      rdma_queue_resource queue;
      rdma_control_result result;
      rdma_recovery_record recovery;
      rdma_resource snapshot;
      rdma_status primary;
      rdma_status release_failure;
      rdma_status status;
      int unsigned host_release_count;
      int unsigned context_release_count;
      int unsigned expected_host_releases;
      longint unsigned borrowed_primary_backing;
      longint unsigned borrowed_segment_backing;
      bit release_complete;

      kind = kinds[kind_index];
      borrowed = borrow_mode != 0;
      label = $sformatf("EXEC_%s_%s_RESERVATION_RELEASE_RECOVERY",
                        kind.name(), borrowed ? "BORROWED" : "OWNED");
      binding = make_binding({label, "_binding"});
      manager = rdma_fault_inject_resource_manager::type_id::create(
        {label, "_manager"}
      );
      dependency = null;
      if (kind == RDMA_RESOURCE_CQ)
        expect_status({label, "_DEPENDENCY"},
                      manager.create_ceq(binding, dependency), RDMA_SC_OK);
      mem = rdma_queue_executor_trace_mem::type_id::create({label, "_mem"});
      mem.queue_kind = kind;
      context_backing = rdma_queue_executor_trace_context::type_id::create(
        {label, "_context"}
      );
      cmq = rdma_mock_cmq_port::type_id::create({label, "_cmq"});
      executor = rdma_queue_lifecycle_executor::type_id::create(
        {label, "_executor"}
      );
      expect_status({label, "_CONFIGURE"}, executor.configure(
        manager, cmq, mem, context_backing, 100ns), RDMA_SC_OK);
      request = make_executor_request({label, "_request"}, kind, binding,
                                      dependency, borrowed);
      if (borrowed) begin
        case (kind)
          RDMA_RESOURCE_CQ: begin
            if (!$cast(borrowed_cq_request, request))
              `uvm_fatal(label, "borrowed CQ request cast failed")
            borrowed_cq_request.depth = 128;
            borrowed_cq_request.ring_backing.slices.delete();
            borrowed_primary_backing = 64'hdead_0000_0000_0000;
            borrowed_segment_backing = 64'hdead_0000_0000_1000;
            borrowed_primary_mapping = make_mapping(
              {label, "_borrowed_primary"}, binding,
              64'h0000_0030_0000_0000, borrowed_primary_backing, 4096
            );
            borrowed_segment_mapping = make_mapping(
              {label, "_borrowed_segment"}, binding,
              64'h0000_0030_0000_1000, borrowed_segment_backing, 4096
            );
            borrowed_slice = make_slice(
              {label, "_borrowed_primary_slice"}, RDMA_QUEUE_ROLE_CQ_RING,
              borrowed_primary_mapping, 0, 4096
            );
            borrowed_cq_request.ring_backing.slices.push_back(borrowed_slice);
            borrowed_slice = make_slice(
              {label, "_borrowed_segment_slice"}, RDMA_QUEUE_ROLE_CQ_RING,
              borrowed_segment_mapping, 0, 4096
            );
            borrowed_slice.logical_queue_offset = 4096;
            borrowed_cq_request.ring_backing.slices.push_back(borrowed_slice);
          end
          RDMA_RESOURCE_CEQ: begin
            if (!$cast(borrowed_ceq_request, request))
              `uvm_fatal(label, "borrowed CEQ request cast failed")
            borrowed_ceq_request.depth = 512;
            borrowed_ceq_request.ring_backing.slices.delete();
            borrowed_primary_backing = 64'hdead_1000_0000_0000;
            borrowed_segment_backing = 64'hdead_1000_0000_1000;
            borrowed_primary_mapping = make_mapping(
              {label, "_borrowed_primary"}, binding,
              64'h0000_0031_0000_0000, borrowed_primary_backing, 4096
            );
            borrowed_segment_mapping = make_mapping(
              {label, "_borrowed_segment"}, binding,
              64'h0000_0031_0000_1000, borrowed_segment_backing, 4096
            );
            borrowed_slice = make_slice(
              {label, "_borrowed_primary_slice"}, RDMA_QUEUE_ROLE_CEQ_RING,
              borrowed_primary_mapping, 0, 4096
            );
            borrowed_ceq_request.ring_backing.slices.push_back(borrowed_slice);
            borrowed_slice = make_slice(
              {label, "_borrowed_segment_slice"}, RDMA_QUEUE_ROLE_CEQ_RING,
              borrowed_segment_mapping, 0, 4096
            );
            borrowed_slice.logical_queue_offset = 4096;
            borrowed_ceq_request.ring_backing.slices.push_back(borrowed_slice);
          end
          default: begin
            if (!$cast(borrowed_aeq_request, request))
              `uvm_fatal(label, "borrowed AEQ request cast failed")
            borrowed_aeq_request.depth = 512;
            borrowed_aeq_request.ring_backing.slices.delete();
            borrowed_primary_backing = 64'hdead_2000_0000_0000;
            borrowed_segment_backing = 64'hdead_2000_0000_1000;
            borrowed_primary_mapping = make_mapping(
              {label, "_borrowed_primary"}, binding,
              64'h0000_0032_0000_0000, borrowed_primary_backing, 4096
            );
            borrowed_segment_mapping = make_mapping(
              {label, "_borrowed_segment"}, binding,
              64'h0000_0032_0000_1000, borrowed_segment_backing, 4096
            );
            borrowed_slice = make_slice(
              {label, "_borrowed_primary_slice"}, RDMA_QUEUE_ROLE_AEQ_RING,
              borrowed_primary_mapping, 0, 4096
            );
            borrowed_aeq_request.ring_backing.slices.push_back(borrowed_slice);
            borrowed_slice = make_slice(
              {label, "_borrowed_segment_slice"}, RDMA_QUEUE_ROLE_AEQ_RING,
              borrowed_segment_mapping, 0, 4096
            );
            borrowed_slice.logical_queue_offset = 4096;
            borrowed_aeq_request.ring_backing.slices.push_back(borrowed_slice);
          end
        endcase
      end
      primary = rdma_status::make(RDMA_SC_UNKNOWN_HW_ERROR,
                                  {label, " payload write"});
      release_failure = rdma_status::make(RDMA_SC_RESOURCE_BUSY,
                                          {label, " reservation release"});
      void'(mem.fail_next("write", primary));
      void'(manager.fail_next_transition("release_reserved", release_failure));

      executor.create_locked(binding, binding.make_handle(), request,
                             64'd430 + kind_index * 2 + borrow_mode,
                             queue, result);
      status = manager.lookup_recovery(result.resource_h, recovery);
      expect_status({label, "_RECOVERY"}, status, RDMA_SC_OK);
      expected_host_releases = borrowed ? 1 : 2;
      if (result == null || result.status == null ||
          result.primary_status == null ||
          result.status.code != RDMA_SC_RECOVERY_REQUIRED ||
          result.primary_status.code != RDMA_SC_UNKNOWN_HW_ERROR ||
          !result.recovery_required || !result.final_resource_state_known ||
          result.final_resource_state != RDMA_RESOURCE_ERROR ||
          queue == null || queue.state != RDMA_RESOURCE_ERROR ||
          queue.queue_plan == null || recovery == null ||
          recovery.queue_plan == null ||
          recovery.queue_plan == queue.queue_plan ||
          recovery.hardware_presence != RDMA_HW_PRESENCE_ABSENT ||
          recovery.queue_intent != RDMA_QUEUE_RECOVER_CREATE_ROLLBACK ||
          recovery.ambiguous_queue_operation != RDMA_QUEUE_AMBIG_NONE ||
          recovery.ambiguous_ticket != null ||
          count_executor_recovery_step(
            recovery.pending_steps, RDMA_CTRL_STEP_RESOURCE_RELEASED
          ) != 1 ||
          count_executor_recovery_step(
            recovery.pending_steps, RDMA_CTRL_STEP_BACKING_RELEASED
          ) != 0 ||
          count_executor_recovery_step(
            recovery.completed_steps, RDMA_CTRL_STEP_BACKING_RELEASED
          ) != 1 ||
          count_executor_rollback_code(
            result.rollback_statuses, RDMA_SC_RESOURCE_BUSY
          ) != 1 || manager.release_reserved_calls != 1 ||
          count_executor_host_calls(mem, "release") !=
            expected_host_releases ||
          (borrowed &&
           (count_executor_host_releases_for_backing(
              mem, borrowed_primary_backing
            ) != 0 ||
            count_executor_host_releases_for_backing(
              mem, borrowed_segment_backing
            ) != 0)) ||
          cmq.calls.size() != 0 || mem.live_allocations() != 0)
        `uvm_error(label,
                   "reservation release failure lost durable queue authority")
      if (recovery != null && recovery.queue_plan != null) begin
        foreach (recovery.queue_plan.refs[i]) begin
          release_complete = 1'b0;
          if (recovery.queue_plan.refs[i] == null ||
              recovery.queue_plan.refs[i].mapping == null ||
              recovery.queue_plan.refs[i].mapping.function_h == null ||
              !recovery.queue_plan.refs[i].mapping.function_h.same_instance(
                binding.make_handle()
              ))
            `uvm_error(
              label, "reservation recovery backing proof is not authoritative"
            )
          else if (recovery.queue_plan.refs[i].ownership ==
                     RDMA_OWNERSHIP_BORROWED) begin
            if (recovery.queue_plan.refs[i].cleanup_complete ||
                recovery.queue_plan.refs[i].mapping.state !=
                  RDMA_MAPPING_ACTIVE ||
                recovery.queue_plan.refs[i].additional_segments.size() != 1)
              `uvm_error(
                label, "borrowed reservation recovery forged completion"
              )
            foreach (recovery.queue_plan.refs[i].additional_segments[j]) begin
              if (recovery.queue_plan.refs[i].additional_segments[j] == null ||
                  recovery.queue_plan.refs[i].additional_segments[j].ownership !=
                    RDMA_OWNERSHIP_BORROWED ||
                  recovery.queue_plan.refs[i].additional_segments[j].mapping ==
                    null ||
                  recovery.queue_plan.refs[i].additional_segments[j].mapping.
                    state != RDMA_MAPPING_ACTIVE)
                `uvm_error(
                  label, "borrowed reservation segment authority was released"
                )
            end
          end
          else if (recovery.queue_plan.refs[i].ownership !=
                     RDMA_OWNERSHIP_CONTROL_PLANE ||
                   !recovery.queue_plan.refs[i].cleanup_complete ||
                   recovery.queue_plan.refs[i].mapping.owner_h == null ||
                   !recovery.queue_plan.refs[i].mapping.owner_h.same_instance(
                     result.resource_h
                   ) ||
                   recovery.queue_plan.refs[i].mapping.
                     release_completion_status(release_complete) == null ||
                   !release_complete)
            `uvm_error(
              label, "owned reservation recovery lacks completion proof"
            )
        end
        if ((kind == RDMA_RESOURCE_CQ &&
             (recovery.queue_plan.context_ref == null ||
              !recovery.queue_plan.context_ref.release_complete)) ||
            (kind != RDMA_RESOURCE_CQ &&
             recovery.queue_plan.context_ref != null))
          `uvm_error(label,
                     "reservation recovery context cleanup proof is invalid")
      end

      status = manager.mark_error(result.resource_h, recovery);
      expect_status({label, "_REJECT_ERROR_REPLAY"}, status,
                    RDMA_SC_INVALID_STATE);
      host_release_count = count_executor_host_calls(mem, "release");
      context_release_count = context_backing.release_call_count;
      status = manager.release_reserved(result.resource_h);
      expect_status({label, "_RETRY_RELEASE"}, status, RDMA_SC_OK);
      status = manager.lookup(result.resource_h, snapshot);
      expect_status({label, "_RETRY_RELEASED"}, status,
                    RDMA_SC_INVALID_STATE);
      status = manager.release_reserved(result.resource_h);
      expect_status({label, "_RETRY_EXACTLY_ONCE"}, status,
                    RDMA_SC_INVALID_STATE);
      if (manager.release_reserved_calls != 3 ||
          count_executor_host_calls(mem, "release") != host_release_count ||
          context_backing.release_call_count != context_release_count ||
          mem.live_allocations() != 0)
        `uvm_error(label,
                   "reservation retry repeated local or registry release")
      if (dependency != null) begin
        status = manager.release_reserved(dependency.handle);
        expect_status({label, "_DEPENDENCY_RELEASED"}, status, RDMA_SC_OK);
      end
      end
    end
  endtask

  task automatic check_executor_eq_rollback_recovery();
    rdma_resource_kind_e kinds[$];

    kinds.push_back(RDMA_RESOURCE_CEQ);
    kinds.push_back(RDMA_RESOURCE_AEQ);
    foreach (kinds[kind_index]) begin
      for (int unsigned scenario = 0; scenario < 6; scenario++) begin
        string label;
        rdma_resource_kind_e kind;
        bit borrowed;
        bit [7:0] create_opcode;
        bit [7:0] delete_opcode;
        bit [7:0] query_opcode;
        rdma_function_binding binding;
        rdma_fault_inject_resource_manager manager;
        rdma_queue_executor_trace_mem mem;
        rdma_queue_executor_trace_context context_backing;
        rdma_mock_cmq_port cmq;
        rdma_queue_lifecycle_executor executor;
        rdma_semantic_request request;
        rdma_queue_resource queue;
        rdma_control_result result;
        rdma_recovery_record recovery;
        rdma_status primary;
        rdma_status reset_status;
        rdma_status cleanup_failure;
        rdma_status status;
        int unsigned expected_release_calls;

        kind = kinds[kind_index];
        borrowed = scenario inside {1, 3, 5};
        create_opcode = kind == RDMA_RESOURCE_CEQ ? 8'h10 : 8'h14;
        delete_opcode = kind == RDMA_RESOURCE_CEQ ? 8'h12 : 8'h16;
        query_opcode = kind == RDMA_RESOURCE_CEQ ? 8'h13 : 8'h17;
        label = $sformatf("EXEC_%s_ROLLBACK_%0d", kind.name(), scenario);
        binding = make_binding({label, "_binding"});
        manager = rdma_fault_inject_resource_manager::type_id::create(
          {label, "_manager"}
        );
        mem = rdma_queue_executor_trace_mem::type_id::create({label, "_mem"});
        mem.queue_kind = kind;
        context_backing = rdma_queue_executor_trace_context::type_id::create(
          {label, "_context"}
        );
        cmq = rdma_mock_cmq_port::type_id::create({label, "_cmq"});
        executor = rdma_queue_lifecycle_executor::type_id::create(
          {label, "_executor"}
        );
        expect_status({label, "_CONFIGURE"}, executor.configure(
          manager, cmq, mem, context_backing, 100ns), RDMA_SC_OK);
        request = make_executor_request({label, "_request"}, kind, binding,
                                        null, borrowed);
        primary = rdma_status::make(RDMA_SC_UNKNOWN_HW_ERROR,
                                    {label, " primary"});
        reset_status = rdma_status::make(RDMA_SC_RESET_CANCELLED,
                                         {label, " reset cancelled"});
        cleanup_failure = rdma_status::make(RDMA_SC_DMA_TRANSLATION,
                                            {label, " host release"});
        if (scenario != 2)
          void'(manager.fail_next_transition("commit_programmed", primary));
        case (scenario)
          2: cmq.fail_opcode(create_opcode, reset_status);
          3: cmq.fail_opcode(delete_opcode, reset_status);
          4, 5: void'(mem.fail_next("release", cleanup_failure));
          default: begin end
        endcase
        executor.create_locked(binding, binding.make_handle(), request,
                               64'd500 + kind_index * 10 + scenario,
                               queue, result);
        foreach (cmq.calls[i])
          if (cmq.calls[i].opcode == 8'h0a)
            `uvm_error(label, "EQ rollback issued a CQ OCC flush")
        if (scenario inside {0, 1}) begin
          expected_release_calls = borrowed ? 1 : 2;
          if (queue != null || result == null || result.status == null ||
              result.primary_status == null || result.recovery_required ||
              result.status.code != RDMA_SC_UNKNOWN_HW_ERROR ||
              result.primary_status.code != RDMA_SC_UNKNOWN_HW_ERROR ||
              !result.final_resource_state_known ||
              result.final_resource_state != RDMA_RESOURCE_RELEASED ||
              cmq.calls.size() != 2 ||
              cmq.calls[0].opcode != create_opcode ||
              cmq.calls[1].opcode != delete_opcode ||
              count_executor_host_calls(mem, "release") !=
                expected_release_calls ||
              manager.release_reserved_calls != 1 ||
              mem.live_allocations() != 0)
            `uvm_error(label, "definitive EQ rollback was not fail-atomic")
          continue;
        end
        if (scenario inside {2, 3}) begin
          status = manager.lookup_recovery(result.resource_h, recovery);
          expect_status({label, "_RECOVERY"}, status, RDMA_SC_OK);
          if (result == null || result.status == null ||
              result.primary_status == null ||
              result.status.code != RDMA_SC_RECOVERY_REQUIRED ||
              result.primary_status.code != (scenario == 2 ?
                RDMA_SC_RESET_CANCELLED : RDMA_SC_UNKNOWN_HW_ERROR) ||
              !result.recovery_required || queue == null ||
              queue.state != RDMA_RESOURCE_ERROR || recovery == null ||
              recovery.queue_plan == null ||
              recovery.queue_plan.refs[0].ownership != (borrowed ?
                RDMA_OWNERSHIP_BORROWED : RDMA_OWNERSHIP_CONTROL_PLANE) ||
              recovery.hardware_presence != RDMA_HW_PRESENCE_UNKNOWN ||
              recovery.ambiguous_queue_operation != (scenario == 2 ?
                RDMA_QUEUE_AMBIG_CREATE : RDMA_QUEUE_AMBIG_DELETE) ||
              recovery.ambiguous_ticket == null ||
              recovery.ambiguous_ticket.opcode_key == null ||
              recovery.ambiguous_ticket.opcode_key.opcode != (scenario == 2 ?
                create_opcode : delete_opcode) ||
              recovery.queue_create_opcode.opcode != create_opcode ||
              recovery.queue_delete_opcode.opcode != delete_opcode ||
              recovery.queue_query_opcode.opcode != query_opcode ||
              count_executor_host_calls(mem, "release") != 0 ||
              manager.release_reserved_calls != 0)
            `uvm_error(label, "reset-cancelled EQ authority was not retained")
          continue;
        end
        status = manager.lookup_recovery(result.resource_h, recovery);
        expect_status({label, "_RECOVERY"}, status, RDMA_SC_OK);
        expected_release_calls = borrowed ? 1 : 2;
        if (result == null || result.status == null ||
            result.primary_status == null ||
            result.status.code != RDMA_SC_RECOVERY_REQUIRED ||
            result.primary_status.code != RDMA_SC_UNKNOWN_HW_ERROR ||
            !result.recovery_required || queue == null ||
            queue.state != RDMA_RESOURCE_ERROR || recovery == null ||
            recovery.queue_plan == null ||
            recovery.hardware_presence != RDMA_HW_PRESENCE_ABSENT ||
            recovery.ambiguous_queue_operation != RDMA_QUEUE_AMBIG_NONE ||
            recovery.ambiguous_ticket != null ||
            count_executor_rollback_code(
              result.rollback_statuses, RDMA_SC_DMA_TRANSLATION
            ) != 1 ||
            count_executor_recovery_step(
              recovery.pending_steps, RDMA_CTRL_STEP_BACKING_RELEASED
            ) != 1 ||
            count_executor_host_calls(mem, "release") !=
              expected_release_calls ||
            manager.release_reserved_calls != 0 ||
            mem.live_allocations() != 1)
          `uvm_error(label, "EQ cleanup failure lost durable authority")
        retry_executor_local_cleanup(label, manager, mem, context_backing,
                                     result.resource_h);
        if (count_executor_host_calls(mem, "release") !=
              expected_release_calls + 1 || mem.live_allocations() != 0)
          `uvm_error(label, "EQ cleanup retry used the wrong authority")
      end
    end
  endtask

  task automatic check_executor_srq_compound_create();
    rdma_function_binding binding;
    rdma_fault_inject_resource_manager manager;
    rdma_pd pd_dependency;
    rdma_queue_executor_trace_mem mem;
    rdma_queue_executor_trace_context context_backing;
    rdma_mock_cmq_port cmq;
    rdma_mock_call_trace trace;
    rdma_queue_lifecycle_executor executor;
    rdma_create_srq_req request;
    rdma_queue_resource queue;
    rdma_control_result result;
    rdma_srq srq;
    rdma_status status;
    byte unsigned shadow_byte;

    binding = make_binding("EXEC_SRQ_COMPOUND_binding");
    manager = rdma_fault_inject_resource_manager::type_id::create(
      "EXEC_SRQ_COMPOUND_manager"
    );
    pd_dependency = null;
    expect_status("EXEC_SRQ_COMPOUND_PD",
                  manager.create_pd(binding, pd_dependency), RDMA_SC_OK);
    mem = rdma_queue_executor_trace_mem::type_id::create(
      "EXEC_SRQ_COMPOUND_mem"
    );
    mem.queue_kind = RDMA_RESOURCE_SRQ;
    context_backing = rdma_queue_executor_trace_context::type_id::create(
      "EXEC_SRQ_COMPOUND_context"
    );
    cmq = rdma_mock_cmq_port::type_id::create("EXEC_SRQ_COMPOUND_cmq");
    trace = rdma_mock_call_trace::type_id::create("EXEC_SRQ_COMPOUND_trace");
    mem.set_shared_trace(trace);
    context_backing.set_call_trace(trace);
    cmq.set_call_trace(trace);
    executor = rdma_queue_lifecycle_executor::type_id::create(
      "EXEC_SRQ_COMPOUND_executor"
    );
    expect_status("EXEC_SRQ_COMPOUND_CONFIGURE", executor.configure(
      manager, cmq, mem, context_backing, 100ns), RDMA_SC_OK);
    request = rdma_create_srq_req::type_id::create(
      "EXEC_SRQ_COMPOUND_request"
    );
    request.owner = binding.make_handle();
    request.depth = 64;
    request.max_sge = 4;
    request.limit_threshold = 16;
    request.pd_h = pd_dependency.handle;
    request.payload_backing.mode = RDMA_QUEUE_BACKING_OWNED;
    executor.create_locked(binding, binding.make_handle(), request, 64'd300,
                           queue, result);
    if (result == null || !result.ok() || !$cast(srq, queue) ||
        srq.state != RDMA_RESOURCE_ACTIVE)
      `uvm_error("EXEC_SRQ_COMPOUND", $sformatf(
        "SRQ did not become ACTIVE: %s",
        result == null || result.status == null ? "null" :
          result.status.convert2string()))
    if (srq != null && (srq.queue_plan == null ||
        srq.queue_plan.refs.size() != 5 ||
        srq.queue_plan.refs[0].role != RDMA_QUEUE_ROLE_SRQ_RING ||
        srq.queue_plan.refs[1].role != RDMA_QUEUE_ROLE_SRFQ_RING ||
        srq.queue_plan.refs[2].role != RDMA_QUEUE_ROLE_SRQ_SGB ||
        srq.queue_plan.refs[3].role != RDMA_QUEUE_ROLE_SRQ_PD ||
        srq.queue_plan.refs[4].role != RDMA_QUEUE_ROLE_SRFQ_PD ||
        srq.queue_plan.context_ref == null))
      `uvm_error("EXEC_SRQ_COMPOUND", "SRQ backing roles are incomplete")
    if (srq != null && (srq.pd_h == null ||
                        !srq.pd_h.same_instance(pd_dependency.handle)))
      `uvm_error("EXEC_SRQ_COMPOUND",
                 "SRQ registry dependency was replaced with a local ID")
    if (trace.calls.size() != 8 ||
        trace.calls[0] != "host_write:SRQ_RING" ||
        trace.calls[1] != "host_write:SRFQ_RING" ||
        trace.calls[2] != "host_write:SRQ_SGB" ||
        trace.calls[3] != "host_write:SRQ_PD" ||
        trace.calls[4] != "host_write:SRFQ_PD" ||
        trace.calls[5] != "context_write:SRFQC_CONTEXT_SLOT" ||
        trace.calls[6] != "context_write:SRFQC_CONTEXT_SHADOW" ||
        trace.calls[7] != "cmq:35")
      `uvm_error("EXEC_SRQ_COMPOUND", $sformatf(
        "SRQ create trace is not canonical: %p", trace.calls))
    if (srq != null && srq.queue_plan != null) begin
      for (int unsigned offset = 28; offset < 32; offset++) begin
        shadow_byte = '0;
        status = context_backing.read_slot_byte(srq.queue_plan.context_ref,
                                                offset, shadow_byte);
        expect_status($sformatf("EXEC_SRQ_SHADOW_%0d", offset), status,
                      RDMA_SC_OK);
        if (shadow_byte != (offset == 31 ? 8'h10 : 8'h00))
          `uvm_error("EXEC_SRQ_SHADOW", "SRFQC shadow is not 00 00 00 10")
      end
    end

    request.max_sge = 2;
    queue = null;
    result = null;
    executor.create_locked(binding, binding.make_handle(), request, 64'd301,
                           queue, result);
    if (result == null || !result.ok() || !$cast(srq, queue) ||
        srq.queue_plan == null || srq.queue_plan.refs.size() != 4 ||
        srq.queue_plan.refs[0].role != RDMA_QUEUE_ROLE_SRQ_RING ||
        srq.queue_plan.refs[1].role != RDMA_QUEUE_ROLE_SRFQ_RING ||
        srq.queue_plan.refs[2].role != RDMA_QUEUE_ROLE_SRQ_PD ||
        srq.queue_plan.refs[3].role != RDMA_QUEUE_ROLE_SRFQ_PD)
      `uvm_error("EXEC_SRQ_NO_SGB", "max_sge=2 unexpectedly allocated SGB")
  endtask

  task automatic check_executor_srq_rollback_order();
    rdma_function_binding binding;
    rdma_fault_inject_resource_manager manager;
    rdma_pd pd_dependency;
    rdma_queue_executor_trace_mem mem;
    rdma_queue_executor_trace_context context_backing;
    rdma_mock_cmq_port cmq;
    rdma_queue_lifecycle_executor executor;
    rdma_create_srq_req request;
    rdma_queue_resource queue;
    rdma_control_result result;

    binding = make_binding("EXEC_SRQ_ROLLBACK_binding");
    manager = rdma_fault_inject_resource_manager::type_id::create(
      "EXEC_SRQ_ROLLBACK_manager"
    );
    pd_dependency = null;
    expect_status("EXEC_SRQ_ROLLBACK_PD",
                  manager.create_pd(binding, pd_dependency), RDMA_SC_OK);
    mem = rdma_queue_executor_trace_mem::type_id::create(
      "EXEC_SRQ_ROLLBACK_mem"
    );
    mem.queue_kind = RDMA_RESOURCE_SRQ;
    context_backing = rdma_queue_executor_trace_context::type_id::create(
      "EXEC_SRQ_ROLLBACK_context"
    );
    cmq = rdma_mock_cmq_port::type_id::create("EXEC_SRQ_ROLLBACK_cmq");
    executor = rdma_queue_lifecycle_executor::type_id::create(
      "EXEC_SRQ_ROLLBACK_executor"
    );
    expect_status("EXEC_SRQ_ROLLBACK_CONFIGURE", executor.configure(
      manager, cmq, mem, context_backing, 100ns), RDMA_SC_OK);
    request = rdma_create_srq_req::type_id::create("EXEC_SRQ_ROLLBACK_request");
    request.owner = binding.make_handle();
    request.depth = 64;
    request.max_sge = 4;
    request.limit_threshold = 16;
    request.pd_h = pd_dependency.handle;
    request.payload_backing.mode = RDMA_QUEUE_BACKING_OWNED;
    void'(manager.fail_next_transition("commit_programmed",
      rdma_status::make(RDMA_SC_UNKNOWN_HW_ERROR, "injected SRQ commit")));
    executor.create_locked(binding, binding.make_handle(), request, 64'd302,
                           queue, result);
    if (queue != null || result == null || result.status == null ||
        result.primary_status == null ||
        result.status.code != RDMA_SC_UNKNOWN_HW_ERROR ||
        result.primary_status.code != RDMA_SC_UNKNOWN_HW_ERROR ||
        cmq.calls.size() != 4 || cmq.calls[0].opcode != 8'h35 ||
        cmq.calls[1].opcode != 8'h0a || cmq.calls[2].opcode != 8'h0a ||
        cmq.calls[3].opcode != 8'h37)
      `uvm_error("EXEC_SRQ_ROLLBACK",
                 "SRQ rollback was not SRFQ_PD, SRQ_PD, then SRQC delete")
  endtask

  task automatic check_create_executor();
    check_executor_positive_case(RDMA_RESOURCE_CQ, 1'b0);
    check_executor_positive_case(RDMA_RESOURCE_CQ, 1'b1);
    check_executor_positive_case(RDMA_RESOURCE_CEQ, 1'b0);
    check_executor_positive_case(RDMA_RESOURCE_CEQ, 1'b1);
    check_executor_positive_case(RDMA_RESOURCE_AEQ, 1'b0);
    check_executor_positive_case(RDMA_RESOURCE_AEQ, 1'b1);
    for (int unsigned mode = 0; mode < 12; mode++)
      check_executor_failure_case(mode);
    check_executor_cq_reset_cancelled();
    check_executor_local_cleanup_recovery();
    check_executor_prestage_cleanup_recovery();
    check_executor_reservation_release_recovery();
    check_executor_eq_rollback_recovery();
    check_executor_srq_compound_create();
    check_executor_srq_rollback_order();
  endtask

  task automatic check_executor_context_optional_for_eq();
    rdma_function_binding binding;
    rdma_fault_inject_resource_manager manager;
    rdma_queue_executor_trace_mem mem;
    rdma_mock_cmq_port cmq;
    rdma_queue_lifecycle_executor executor;
    rdma_semantic_request request;
    rdma_queue_resource queue;
    rdma_control_result result;

    binding = make_binding("optional_context_binding");
    manager = rdma_fault_inject_resource_manager::type_id::create(
      "optional_context_manager"
    );
    mem = rdma_queue_executor_trace_mem::type_id::create(
      "optional_context_mem"
    );
    mem.queue_kind = RDMA_RESOURCE_CEQ;
    cmq = rdma_mock_cmq_port::type_id::create("optional_context_cmq");
    executor = rdma_queue_lifecycle_executor::type_id::create(
      "optional_context_executor"
    );
    expect_status("OPTIONAL_CONTEXT_CONFIGURE",
                  executor.configure(manager, cmq, mem, null, 100ns),
                  RDMA_SC_OK);
    request = make_executor_request("optional_context_ceq_request",
                                    RDMA_RESOURCE_CEQ, binding, null, 1'b0);
    executor.create_locked(binding, binding.make_handle(), request, 64'd701,
                           queue, result);
    if (result == null || !result.ok() || queue == null ||
        queue.resource_kind() != RDMA_RESOURCE_CEQ ||
        queue.state != RDMA_RESOURCE_ACTIVE)
      `uvm_error("OPTIONAL_CONTEXT_CEQ", "EQ create did not allow null context")
  endtask

  task automatic check_destroy_success_traces();
    rdma_resource_kind_e kinds[$];

    kinds.push_back(RDMA_RESOURCE_CQ);
    kinds.push_back(RDMA_RESOURCE_SRQ);
    kinds.push_back(RDMA_RESOURCE_CEQ);
    kinds.push_back(RDMA_RESOURCE_AEQ);
    foreach (kinds[kind_index]) begin
      string label;
      string expected[$];
      rdma_resource_kind_e kind;
      rdma_function_binding binding;
      rdma_fault_inject_resource_manager manager;
      rdma_queue_destroy_trace_mem mem;
      rdma_queue_destroy_trace_context context_backing;
      rdma_queue_destroy_trace_cmq cmq;
      rdma_mock_call_trace trace;
      rdma_queue_lifecycle_executor executor;
      rdma_queue_resource queue;
      rdma_control_result create_result;
      rdma_control_result result;
      rdma_ceq ceq_dependency;
      rdma_pd pd_dependency;
      rdma_destroy_resource_req request;
      rdma_resource looked_up;
      rdma_status status;
      int unsigned cmq_before;
      int unsigned expected_cmq_calls;

      kind = kinds[kind_index];
      label = $sformatf("DESTROY_%s_SUCCESS", kind.name());
      create_destroy_fixture(label, kind, binding, manager, mem,
                             context_backing, cmq, trace, executor, queue,
                             create_result, ceq_dependency, pd_dependency);
      if (queue == null || create_result == null || !create_result.ok())
        continue;
      request = make_destroy_request({label, "_request"}, binding,
                                     queue.handle);
      cmq_before = cmq.calls.size();
      result = null;
      executor.destroy_locked(binding, binding.make_handle(), request,
                              64'd1100 + kind_index, result);
      case (kind)
        RDMA_RESOURCE_CQ: begin
          expected = '{"cmq:0e", "cmq:0a:CQ_PD", "context_release",
                       "host_release:CQ_PD", "detach_or_release:CQ_RING"};
          expected_cmq_calls = 2;
        end
        RDMA_RESOURCE_SRQ: begin
          expected = '{"cmq:0a:SRFQ_PD", "cmq:0a:SRQ_PD", "cmq:37",
                       "context_release", "host_release:SRFQ_PD",
                       "host_release:SRQ_PD", "detach_or_release:SRQ_SGB",
                       "detach_or_release:SRFQ_RING",
                       "detach_or_release:SRQ_RING"};
          expected_cmq_calls = 3;
        end
        RDMA_RESOURCE_CEQ: begin
          expected = '{"cmq:12", "host_release:CEQ_PD",
                       "detach_or_release:CEQ_RING"};
          expected_cmq_calls = 1;
        end
        default: begin
          expected = '{"cmq:16", "host_release:AEQ_PD",
                       "detach_or_release:AEQ_RING"};
          expected_cmq_calls = 1;
        end
      endcase
      expect_destroy_trace(label, trace, expected);
      if (result == null || result.status == null || !result.ok() ||
          result.final_resource_state != RDMA_RESOURCE_RELEASED ||
          !result.final_resource_state_known || result.recovery_required ||
          cmq.calls.size() != cmq_before + expected_cmq_calls)
        `uvm_error(label, $sformatf(
          "destroy did not complete atomically: result=%s cmq=%0d/%0d",
          result == null || result.status == null ? "null" :
            result.status.convert2string(), cmq.calls.size(),
          cmq_before + expected_cmq_calls))
      status = manager.lookup(request.target_h, looked_up);
      expect_status({label, "_LOOKUP_RELEASED"}, status,
                    RDMA_SC_INVALID_STATE);
      if (kind == RDMA_RESOURCE_CQ && ceq_dependency != null)
        expect_status({label, "_CEQ_RELEASE"},
                      manager.release_reserved(ceq_dependency.handle),
                      RDMA_SC_OK);
      if (kind == RDMA_RESOURCE_SRQ && pd_dependency != null)
        expect_status({label, "_PD_RELEASE"},
                      manager.release_reserved(pd_dependency.handle),
                      RDMA_SC_OK);
    end
  endtask

  task automatic check_destroy_borrowed_eq_detach();
    string label;
    string expected[$];
    rdma_function_binding binding;
    rdma_fault_inject_resource_manager manager;
    rdma_queue_destroy_trace_mem mem;
    rdma_queue_destroy_trace_context context_backing;
    rdma_queue_destroy_trace_cmq cmq;
    rdma_mock_call_trace trace;
    rdma_queue_lifecycle_executor executor;
    rdma_queue_resource queue;
    rdma_control_result create_result;
    rdma_control_result result;
    rdma_ceq ceq_dependency;
    rdma_pd pd_dependency;
    rdma_destroy_resource_req request;
    rdma_resource looked_up;
    rdma_status status;
    bit borrowed_ring_seen;

    label = "DESTROY_BORROWED_CEQ";
    create_destroy_fixture(label, RDMA_RESOURCE_CEQ, binding, manager, mem,
                           context_backing, cmq, trace, executor, queue,
                           create_result, ceq_dependency, pd_dependency,
                           1'b1);
    borrowed_ring_seen = 1'b0;
    if (queue != null && queue.queue_plan != null)
      foreach (queue.queue_plan.refs[i])
        if (queue.queue_plan.refs[i] != null &&
            queue.queue_plan.refs[i].role == RDMA_QUEUE_ROLE_CEQ_RING &&
            queue.queue_plan.refs[i].ownership == RDMA_OWNERSHIP_BORROWED)
          borrowed_ring_seen = 1'b1;
    if (!borrowed_ring_seen)
      `uvm_error(label, "fixture did not retain a borrowed CEQ ring")
    request = make_destroy_request({label, "_request"}, binding,
                                   queue.handle);
    result = null;
    executor.destroy_locked(binding, binding.make_handle(), request,
                            64'd1170, result);
    expected = '{"cmq:12", "host_release:CEQ_PD"};
    expect_destroy_trace(label, trace, expected);
    if (result == null || !result.ok() ||
        result.final_resource_state != RDMA_RESOURCE_RELEASED ||
        !result.final_resource_state_known || result.recovery_required)
      `uvm_error(label, "borrowed CEQ destroy did not complete")
    if (count_executor_host_calls(mem, "release") != 1)
      `uvm_error(label, "borrowed CEQ ring unexpectedly reached host release")
    status = manager.lookup(request.target_h, looked_up);
    expect_status({label, "_RELEASED_LOOKUP"}, status, RDMA_SC_INVALID_STATE);
  endtask

  task automatic check_destroy_busy_guards();
    string label;
    rdma_function_binding binding;
    rdma_fault_inject_resource_manager manager;
    rdma_queue_destroy_trace_mem mem;
    rdma_queue_destroy_trace_context context_backing;
    rdma_queue_destroy_trace_cmq cmq;
    rdma_mock_call_trace trace;
    rdma_queue_lifecycle_executor executor;
    rdma_queue_resource queue;
    rdma_control_result create_result;
    rdma_control_result result;
    rdma_ceq ceq_dependency;
    rdma_pd pd_dependency;
    rdma_pd qp_pd;
    rdma_cq qp_cq;
    rdma_qp qp;
    rdma_destroy_resource_req request;
    rdma_resource looked_up;
    rdma_status status;
    int unsigned cmq_before;

    // A QP retaining a CQ is a real dependency edge in the manager graph.
    label = "DESTROY_BUSY_CQ_DEPENDENT_QP";
    create_destroy_fixture(label, RDMA_RESOURCE_CQ, binding, manager, mem,
                           context_backing, cmq, trace, executor, queue,
                           create_result, ceq_dependency, pd_dependency);
    status = manager.create_pd(binding, qp_pd);
    expect_status({label, "_QP_PD"}, status, RDMA_SC_OK);
    qp = null;
    status = manager.create_qp(binding, qp_pd.handle, queue.handle,
                               queue.handle, null, qp);
    expect_status({label, "_QP"}, status, RDMA_SC_OK);
    request = make_destroy_request({label, "_request"}, binding, queue.handle);
    cmq_before = cmq.calls.size();
    result = null;
    executor.destroy_locked(binding, binding.make_handle(), request, 64'd1200,
                            result);
    if (result == null || result.status == null ||
        result.status.code != RDMA_SC_RESOURCE_BUSY ||
        result.final_resource_state_known || cmq.calls.size() != cmq_before)
      `uvm_error(label, "CQ dependent destroy submitted or changed state")
    status = manager.lookup(queue.handle, looked_up);
    expect_status({label, "_ACTIVE"}, status, RDMA_SC_OK);
    if (looked_up == null || looked_up.state != RDMA_RESOURCE_ACTIVE)
      `uvm_error(label, "CQ dependent busy guard did not preserve ACTIVE")
    expect_status({label, "_QP_RELEASE"}, manager.release_reserved(qp.handle),
                  RDMA_SC_OK);
    trace.clear();
    cmq.begin_destroy_trace(trace, RDMA_RESOURCE_CQ);
    mem.reset_destroy_trace();
    executor.destroy_locked(binding, binding.make_handle(), request, 64'd1201,
                            result);
    if (result == null || !result.ok())
      `uvm_error(label, "CQ destroy did not succeed after dependent release")
    expect_status({label, "_QP_PD_RELEASE"},
                  manager.release_reserved(qp_pd.handle), RDMA_SC_OK);
    expect_status({label, "_CEQ_RELEASE"},
                  manager.release_reserved(ceq_dependency.handle), RDMA_SC_OK);

    // An SRQ dependency is independently guarded; use a bare ALLOCATED CQ
    // for the QP's mandatory send/receive CQ references.
    label = "DESTROY_BUSY_SRQ_DEPENDENT_QP";
    create_destroy_fixture(label, RDMA_RESOURCE_SRQ, binding, manager, mem,
                           context_backing, cmq, trace, executor, queue,
                           create_result, ceq_dependency, pd_dependency);
    status = manager.create_cq(binding, null, qp_cq);
    expect_status({label, "_QP_CQ"}, status, RDMA_SC_OK);
    qp = null;
    status = manager.create_qp(binding, pd_dependency.handle, qp_cq.handle,
                               qp_cq.handle, queue.handle, qp);
    expect_status({label, "_QP"}, status, RDMA_SC_OK);
    request = make_destroy_request({label, "_request"}, binding, queue.handle);
    cmq_before = cmq.calls.size();
    executor.destroy_locked(binding, binding.make_handle(), request, 64'd1210,
                            result);
    if (result == null || result.status == null ||
        result.status.code != RDMA_SC_RESOURCE_BUSY ||
        result.final_resource_state_known || cmq.calls.size() != cmq_before)
      `uvm_error(label, "SRQ dependent destroy submitted or changed state")
    expect_status({label, "_QP_RELEASE"}, manager.release_reserved(qp.handle),
                  RDMA_SC_OK);
    expect_status({label, "_QP_CQ_RELEASE"},
                  manager.release_reserved(qp_cq.handle), RDMA_SC_OK);
    trace.clear();
    cmq.begin_destroy_trace(trace, RDMA_RESOURCE_SRQ);
    mem.reset_destroy_trace();
    executor.destroy_locked(binding, binding.make_handle(), request, 64'd1211,
                            result);
    if (result == null || !result.ok())
      `uvm_error(label, "SRQ destroy did not succeed after dependent release")
    expect_status({label, "_PD_RELEASE"},
                  manager.release_reserved(pd_dependency.handle), RDMA_SC_OK);

    // Outstanding operation tracking is a separate busy source and must be
    // rejected before any CMQ submission as well.
    label = "DESTROY_BUSY_OUTSTANDING";
    create_destroy_fixture(label, RDMA_RESOURCE_CEQ, binding, manager, mem,
                           context_backing, cmq, trace, executor, queue,
                           create_result, ceq_dependency, pd_dependency);
    expect_status({label, "_TRACK"}, manager.track_outstanding(
      queue.handle, 64'hd357_0001), RDMA_SC_OK);
    request = make_destroy_request({label, "_request"}, binding, queue.handle);
    cmq_before = cmq.calls.size();
    executor.destroy_locked(binding, binding.make_handle(), request, 64'd1220,
                            result);
    if (result == null || result.status == null ||
        result.status.code != RDMA_SC_RESOURCE_BUSY ||
        result.final_resource_state_known || cmq.calls.size() != cmq_before)
      `uvm_error(label, "outstanding operation bypassed destroy busy guard")
    expect_status({label, "_RETIRE"}, manager.retire_outstanding(
      queue.handle, 64'hd357_0001), RDMA_SC_OK);
    trace.clear();
    cmq.begin_destroy_trace(trace, RDMA_RESOURCE_CEQ);
    mem.reset_destroy_trace();
    executor.destroy_locked(binding, binding.make_handle(), request, 64'd1221,
                            result);
    if (result == null || !result.ok())
      `uvm_error(label, "outstanding busy resource did not destroy after retire")
  endtask

  task automatic check_destroy_srq_restore_retry();
    string label;
    string expected[$];
    rdma_function_binding binding;
    rdma_fault_inject_resource_manager manager;
    rdma_queue_destroy_trace_mem mem;
    rdma_queue_destroy_trace_context context_backing;
    rdma_queue_destroy_trace_cmq cmq;
    rdma_mock_call_trace trace;
    rdma_queue_lifecycle_executor executor;
    rdma_queue_resource queue;
    rdma_control_result create_result;
    rdma_control_result result;
    rdma_ceq ceq_dependency;
    rdma_pd pd_dependency;
    rdma_destroy_resource_req request;
    rdma_resource snapshot;
    rdma_srq srq_snapshot;
    rdma_status status;
    int unsigned cmq_before;

    label = "DESTROY_SRQ_RESTORE_RETRY";
    create_destroy_fixture(label, RDMA_RESOURCE_SRQ, binding, manager, mem,
                           context_backing, cmq, trace, executor, queue,
                           create_result, ceq_dependency, pd_dependency);
    request = make_destroy_request({label, "_request"}, binding, queue.handle);
    cmq.reject_next_flush = 1'b1;
    cmq.reject_flush_ordinal = 2;
    cmq.reject_flush_status = rdma_status::make(
      RDMA_SC_INVALID_ARGUMENT, "injected second-flush pre-submit failure");
    cmq_before = cmq.calls.size();
    result = null;
    executor.destroy_locked(binding, binding.make_handle(), request, 64'd1300,
                            result);
    expected = '{"cmq:0a:SRFQ_PD"};
    expect_destroy_trace({label, "_FIRST_TRACE"}, trace, expected);
    if (result == null || result.status == null ||
        result.status.code != RDMA_SC_INVALID_ARGUMENT ||
        result.final_resource_state != RDMA_RESOURCE_ACTIVE ||
        !result.final_resource_state_known || result.recovery_required ||
        cmq.calls.size() != cmq_before + 1 ||
        mem.release_ordinal != 0 || context_backing.release_call_count != 0)
      `uvm_error(label,
                 "pre-submit SRQ flush failure did not restore ACTIVE safely")
    status = manager.lookup(queue.handle, snapshot);
    expect_status({label, "_ACTIVE_LOOKUP"}, status, RDMA_SC_OK);
    if (!$cast(srq_snapshot, snapshot) || srq_snapshot == null ||
        srq_snapshot.state != RDMA_RESOURCE_ACTIVE ||
        srq_snapshot.queue_plan == null ||
        srq_snapshot.queue_plan.flush_targets.size() != 2)
      `uvm_error(label, "restored SRQ snapshot is not typed or complete")
    else begin
      foreach (srq_snapshot.queue_plan.flush_targets[i])
        if (srq_snapshot.queue_plan.flush_targets[i] == null ||
            srq_snapshot.queue_plan.flush_targets[i].flush_complete)
          `uvm_error(label, "restored SRQ retained stale flush progress")
    end
    foreach (cmq.calls[i]) begin
      if (i > cmq_before && cmq.calls[i].opcode == XTR_V1_OP_SRFQC_DELETE)
        `uvm_error(label, "failed second flush issued SRQ delete")
    end

    trace.clear();
    cmq.begin_destroy_trace(trace, RDMA_RESOURCE_SRQ);
    mem.reset_destroy_trace();
    executor.destroy_locked(binding, binding.make_handle(), request, 64'd1301,
                            result);
    expected = '{"cmq:0a:SRFQ_PD", "cmq:0a:SRQ_PD", "cmq:37",
                 "context_release", "host_release:SRFQ_PD",
                 "host_release:SRQ_PD", "detach_or_release:SRQ_SGB",
                 "detach_or_release:SRFQ_RING", "detach_or_release:SRQ_RING"};
    expect_destroy_trace({label, "_RETRY_TRACE"}, trace, expected);
    if (result == null || !result.ok() || cmq.calls.size() != cmq_before + 4)
      `uvm_error(label, "SRQ retry did not resend both flushes and delete")
    expect_status({label, "_PD_RELEASE"},
                  manager.release_reserved(pd_dependency.handle), RDMA_SC_OK);
  endtask

  task automatic check_destroy_failure_matrix();
    for (int unsigned scenario = 0; scenario < 4; scenario++) begin
      string label;
      string expected[$];
      rdma_function_binding binding;
      rdma_fault_inject_resource_manager manager;
      rdma_queue_destroy_trace_mem mem;
      rdma_queue_destroy_trace_context context_backing;
      rdma_queue_destroy_trace_cmq cmq;
      rdma_mock_call_trace trace;
      rdma_queue_lifecycle_executor executor;
      rdma_queue_resource queue;
      rdma_control_result create_result;
      rdma_control_result result;
      rdma_ceq ceq_dependency;
      rdma_pd pd_dependency;
      rdma_destroy_resource_req request;
      rdma_resource error_resource;
      rdma_recovery_record recovery;
      rdma_status injected;
      rdma_status status;
      int unsigned cmq_before;

      label = $sformatf("DESTROY_CQ_FAILURE_%0d", scenario);
      create_destroy_fixture(label, RDMA_RESOURCE_CQ, binding, manager, mem,
                             context_backing, cmq, trace, executor, queue,
                             create_result, ceq_dependency, pd_dependency);
      request = make_destroy_request({label, "_request"}, binding,
                                     queue.handle);
      case (scenario)
        0: begin
          injected = rdma_status::make(RDMA_SC_UNKNOWN_HW_ERROR,
                                       "ticketed nonzero hardware ecode");
          injected.hardware_code_valid = 1'b1;
          injected.hardware_code = 16'h5a5a;
          cmq.fail_opcode(XTR_V1_OP_CQC_DELETE, injected);
        end
        1: cmq.timeout_opcode(XTR_V1_OP_CQC_DELETE);
        2: cmq.fail_opcode(XTR_V1_OP_CQC_DELETE,
                           rdma_status::make(RDMA_SC_RESET_CANCELLED,
                                              "destroy reset cancelled"));
        default: cmq.lose_next_completion = 1'b1;
      endcase
      cmq_before = cmq.calls.size();
      result = null;
      executor.destroy_locked(binding, binding.make_handle(), request,
                              64'd1400 + scenario, result);
      expected = '{"cmq:0e"};
      expect_destroy_trace(label, trace, expected);
      if (result == null || result.status == null ||
          result.status.code != RDMA_SC_RECOVERY_REQUIRED ||
          !result.recovery_required || result.final_resource_state !=
            RDMA_RESOURCE_ERROR || !result.final_resource_state_known ||
          cmq.calls.size() != cmq_before + 1 ||
          mem.release_ordinal != 0 || context_backing.release_call_count != 0)
        `uvm_error(label, "destructive failure did not stop in ERROR recovery")
      status = manager.lookup(request.target_h, error_resource);
      expect_status({label, "_ERROR_LOOKUP"}, status, RDMA_SC_OK);
      if (error_resource == null || error_resource.state != RDMA_RESOURCE_ERROR)
        `uvm_error(label, "failure did not publish an ERROR queue")
      status = manager.lookup_recovery(request.target_h, recovery);
      expect_status({label, "_RECOVERY"}, status, RDMA_SC_OK);
      if (recovery == null || recovery.queue_plan == null ||
          recovery.ambiguous_queue_operation != (scenario == 0 ?
            RDMA_QUEUE_AMBIG_NONE : RDMA_QUEUE_AMBIG_DELETE) ||
          count_executor_recovery_step(recovery.pending_steps,
                                        RDMA_CTRL_STEP_HW_CONTEXT_DELETED) != 1 ||
          count_executor_recovery_step(recovery.pending_steps,
                                        RDMA_CTRL_STEP_BACKING_RELEASED) != 1)
        `uvm_error(label, "recovery lost ticket/operation/cleanup authority")
      else if (scenario == 0 && recovery.ambiguous_ticket != null)
        `uvm_error(label, "definitive delete failure retained an ambiguous ticket")
      else if (scenario != 0 && recovery.ambiguous_ticket == null)
        `uvm_error(label, "ambiguous delete failure lost its ticket")
      if (scenario == 0 &&
          (recovery.primary_status == null ||
           !recovery.primary_status.hardware_code_valid ||
           recovery.primary_status.hardware_code != 16'h5a5a))
        `uvm_error(label, "ticketed hardware ecode was not preserved")
      if (scenario == 1 &&
          (result.primary_status == null ||
           result.primary_status.code != RDMA_SC_TIMEOUT))
        `uvm_error(label, "timeout status was not retained as primary")
      if (scenario == 2 &&
          (result.primary_status == null ||
           result.primary_status.code != RDMA_SC_RESET_CANCELLED))
        `uvm_error(label, "reset-cancel status was not retained as primary")
    end
  endtask

  task automatic check_destroy_srq_flush_failure();
    string label;
    string expected[$];
    rdma_function_binding binding;
    rdma_fault_inject_resource_manager manager;
    rdma_queue_destroy_trace_mem mem;
    rdma_queue_destroy_trace_context context_backing;
    rdma_queue_destroy_trace_cmq cmq;
    rdma_mock_call_trace trace;
    rdma_queue_lifecycle_executor executor;
    rdma_queue_resource queue;
    rdma_control_result create_result;
    rdma_control_result result;
    rdma_ceq ceq_dependency;
    rdma_pd pd_dependency;
    rdma_destroy_resource_req request;
    rdma_recovery_record recovery;
    rdma_resource error_resource;
    rdma_status status;

    label = "DESTROY_SRQ_FLUSH_RESET";
    create_destroy_fixture(label, RDMA_RESOURCE_SRQ, binding, manager, mem,
                           context_backing, cmq, trace, executor, queue,
                           create_result, ceq_dependency, pd_dependency);
    cmq.fail_opcode(XTR_V1_OP_OCC_FLUSH,
                    rdma_status::make(RDMA_SC_RESET_CANCELLED,
                                      "SRQ flush reset cancelled"));
    request = make_destroy_request({label, "_request"}, binding, queue.handle);
    result = null;
    executor.destroy_locked(binding, binding.make_handle(), request, 64'd1450,
                            result);
    expected = '{"cmq:0a:SRFQ_PD"};
    expect_destroy_trace(label, trace, expected);
    if (result == null || result.status == null ||
        result.status.code != RDMA_SC_RECOVERY_REQUIRED ||
        result.primary_status == null ||
        result.primary_status.code != RDMA_SC_RESET_CANCELLED ||
        mem.release_ordinal != 0 || context_backing.release_call_count != 0)
      `uvm_error(label, "SRQ flush reset did not stop recipe in ERROR")
    status = manager.lookup_recovery(queue.handle, recovery);
    expect_status({label, "_RECOVERY"}, status, RDMA_SC_OK);
    if (recovery == null || recovery.ambiguous_queue_operation !=
          RDMA_QUEUE_AMBIG_OCC_FLUSH || recovery.ambiguous_ticket == null)
      `uvm_error(label, "SRQ flush reset lost OCC_FLUSH ticket authority")
    status = manager.lookup(queue.handle, error_resource);
    expect_status({label, "_ERROR"}, status, RDMA_SC_OK);
    if (error_resource == null || error_resource.state != RDMA_RESOURCE_ERROR)
      `uvm_error(label, "SRQ flush reset did not publish ERROR")
  endtask

  // A non-OK CMQ status with no ticket/completion does not, by itself, prove
  // that a destructive command was rejected before submission.  The executor
  // must retain ERROR recovery until an adapter supplies explicit proof.
  task automatic check_destroy_nonok_null_outcome_fail_closed();
    string label;
    string expected[$];
    rdma_function_binding binding;
    rdma_fault_inject_resource_manager manager;
    rdma_queue_destroy_trace_mem mem;
    rdma_queue_destroy_trace_context context_backing;
    rdma_queue_destroy_trace_cmq cmq;
    rdma_mock_call_trace trace;
    rdma_queue_lifecycle_executor executor;
    rdma_queue_resource queue;
    rdma_control_result create_result;
    rdma_control_result result;
    rdma_ceq ceq_dependency;
    rdma_pd pd_dependency;
    rdma_destroy_resource_req request;
    rdma_recovery_record recovery;
    rdma_resource error_resource;
    rdma_status status;

    label = "DESTROY_NONOK_NULL_NO_PROOF";
    create_destroy_fixture(label, RDMA_RESOURCE_CQ, binding, manager, mem,
                           context_backing, cmq, trace, executor, queue,
                           create_result, ceq_dependency, pd_dependency);
    cmq.nonok_null_without_proof = 1'b1;
    cmq.nonok_null_status = rdma_status::make(
      RDMA_SC_INVALID_STATE, "injected post-boundary null outcome");
    request = make_destroy_request({label, "_request"}, binding,
                                   queue.handle);
    result = null;
    executor.destroy_locked(binding, binding.make_handle(), request,
                            64'd1460, result);
    expected = '{"cmq:0e"};
    expect_destroy_trace(label, trace, expected);
    if (result == null || result.status == null ||
        result.status.code != RDMA_SC_RECOVERY_REQUIRED ||
        !result.recovery_required || !result.final_resource_state_known ||
        result.final_resource_state != RDMA_RESOURCE_ERROR ||
        mem.release_ordinal != 0 || context_backing.release_call_count != 0)
      `uvm_error(label,
                 "non-OK null outcome was incorrectly restored to ACTIVE")
    status = manager.lookup(queue.handle, error_resource);
    expect_status({label, "_ERROR_LOOKUP"}, status, RDMA_SC_OK);
    if (error_resource == null || error_resource.state != RDMA_RESOURCE_ERROR)
      `uvm_error(label, "non-OK null outcome did not publish ERROR")
    status = manager.lookup_recovery(queue.handle, recovery);
    expect_status({label, "_RECOVERY"}, status, RDMA_SC_OK);
    if (recovery == null || recovery.queue_plan == null ||
        recovery.hardware_presence != RDMA_HW_PRESENCE_UNKNOWN ||
        recovery.ambiguous_queue_operation != RDMA_QUEUE_AMBIG_DELETE ||
        recovery.ambiguous_ticket != null ||
        count_executor_recovery_step(recovery.pending_steps,
                                      RDMA_CTRL_STEP_HW_CONTEXT_DELETED) != 1 ||
        count_executor_recovery_step(recovery.pending_steps,
                                      RDMA_CTRL_STEP_BACKING_RELEASED) != 1)
      `uvm_error(label, "null outcome recovery lost delete authority")
  endtask

  task automatic check_destroy_cq_post_delete_flush_failure();
    string label;
    string expected[$];
    rdma_function_binding binding;
    rdma_fault_inject_resource_manager manager;
    rdma_queue_destroy_trace_mem mem;
    rdma_queue_destroy_trace_context context_backing;
    rdma_queue_destroy_trace_cmq cmq;
    rdma_mock_call_trace trace;
    rdma_queue_lifecycle_executor executor;
    rdma_queue_resource queue;
    rdma_control_result create_result;
    rdma_control_result result;
    rdma_ceq ceq_dependency;
    rdma_pd pd_dependency;
    rdma_destroy_resource_req request;
    rdma_recovery_record recovery;
    rdma_resource error_resource;
    rdma_status status;

    label = "DESTROY_CQ_POST_DELETE_FLUSH_FAILURE";
    create_destroy_fixture(label, RDMA_RESOURCE_CQ, binding, manager, mem,
                           context_backing, cmq, trace, executor, queue,
                           create_result, ceq_dependency, pd_dependency);
    cmq.reject_next_flush = 1'b1;
    cmq.reject_flush_ordinal = 1;
    cmq.reject_flush_status = rdma_status::make(
      RDMA_SC_INVALID_ARGUMENT, "injected CQ post-delete flush rejection");
    request = make_destroy_request({label, "_request"}, binding,
                                   queue.handle);
    result = null;
    executor.destroy_locked(binding, binding.make_handle(), request,
                            64'd1470, result);
    expected = '{"cmq:0e"};
    expect_destroy_trace(label, trace, expected);
    if (result == null || result.status == null ||
        result.status.code != RDMA_SC_RECOVERY_REQUIRED ||
        !result.recovery_required || !result.final_resource_state_known ||
        result.final_resource_state != RDMA_RESOURCE_ERROR ||
        mem.release_ordinal != 0 || context_backing.release_call_count != 0)
      `uvm_error(label, "CQ post-delete flush failure was not retained")
    status = manager.lookup(queue.handle, error_resource);
    expect_status({label, "_ERROR_LOOKUP"}, status, RDMA_SC_OK);
    if (error_resource == null || error_resource.state != RDMA_RESOURCE_ERROR)
      `uvm_error(label, "CQ post-delete flush failure restored ACTIVE")
    status = manager.lookup_recovery(queue.handle, recovery);
    expect_status({label, "_RECOVERY"}, status, RDMA_SC_OK);
    if (recovery == null || recovery.queue_plan == null ||
        recovery.hardware_presence != RDMA_HW_PRESENCE_ABSENT ||
        recovery.ambiguous_queue_operation != RDMA_QUEUE_AMBIG_NONE ||
        recovery.ambiguous_ticket != null ||
        count_executor_recovery_step(recovery.completed_steps,
                                      RDMA_CTRL_STEP_HW_CONTEXT_DELETED) != 1 ||
        count_executor_recovery_step(recovery.pending_steps,
                                      RDMA_CTRL_STEP_BACKING_RELEASED) != 1 ||
        count_executor_recovery_step(recovery.pending_steps,
                                      RDMA_CTRL_STEP_HW_CONTEXT_DELETED) != 0)
      `uvm_error(label,
                 "CQ post-delete failure lost ABSENT hardware recovery state")
  endtask

  task automatic check_public_destroy_success();
    rdma_control_plane control;
    rdma_resource_manager manager;
    rdma_mock_cmq_port cmq;
    rdma_mock_stag_key_policy key_policy;
    rdma_mock_host_mem host_mem;
    rdma_function_binding binding;
    rdma_create_ceq_req request;
    rdma_destroy_resource_req destroy_request;
    rdma_ceq ceq;
    rdma_control_result result;
    rdma_resource looked_up;
    rdma_status status;
    int unsigned cmq_before;
    int unsigned release_before;

    control = rdma_control_plane::type_id::create("PUBLIC_DESTROY_control");
    manager = rdma_resource_manager::type_id::create("PUBLIC_DESTROY_manager");
    cmq = rdma_mock_cmq_port::type_id::create("PUBLIC_DESTROY_cmq");
    key_policy = rdma_mock_stag_key_policy::type_id::create(
      "PUBLIC_DESTROY_key_policy");
    host_mem = rdma_mock_host_mem::type_id::create("PUBLIC_DESTROY_mem");
    binding = make_binding("PUBLIC_DESTROY_binding");
    status = control.configure(manager, cmq, key_policy, host_mem, null, null,
                               100ns);
    expect_status("PUBLIC_DESTROY_CONFIGURE", status, RDMA_SC_OK);
    request = rdma_create_ceq_req::type_id::create("PUBLIC_DESTROY_request");
    request.owner = binding.make_handle();
    request.depth = 64;
    request.vector_id = 3;
    control.create_ceq(binding, request, ceq, result);
    if (ceq == null || result == null || !result.ok()) begin
      `uvm_error("PUBLIC_DESTROY_CREATE", "public CEQ fixture failed")
      return;
    end
    cmq_before = cmq.calls.size();
    release_before = count_executor_host_calls(host_mem, "release");
    destroy_request = make_destroy_request("PUBLIC_DESTROY_destroy_request",
                                           binding, ceq.handle);
    control.destroy_ceq(binding, destroy_request, result);
    if (result == null || result.status == null || !result.ok() ||
        result.final_resource_state != RDMA_RESOURCE_RELEASED ||
        cmq.calls.size() != cmq_before + 1 ||
        cmq.calls[cmq.calls.size()-1].opcode != XTR_V1_OP_CEQC_DELETE ||
        count_executor_host_calls(host_mem, "release") != release_before + 2)
      `uvm_error("PUBLIC_DESTROY_SUCCESS",
                 "public CEQ destroy did not complete in order")
    status = manager.lookup(ceq.handle, looked_up);
    expect_status("PUBLIC_DESTROY_RELEASED_LOOKUP", status,
                  RDMA_SC_INVALID_STATE);
  endtask

  task automatic check_destroy_recipe_contract();
    rdma_queue_lifecycle_policy policy;
    rdma_queue_backing_role_e fr[$], lr[$];
    rdma_queue_flush_phase_e fp[$];
    bit d, c;
    policy = rdma_cq_lifecycle_policy::type_id::create("recipe_cq");
    policy.hardware_cleanup_roles(fr, fp, d);
    if (fr.size()!=1 || fr[0]!=RDMA_QUEUE_ROLE_CQ_PD || fp[0]!=RDMA_QUEUE_FLUSH_POST_DELETE || !d)
      `uvm_error("DESTROY_RECIPE_CQ", "CQ recipe mismatch")
    policy.local_cleanup_roles(lr, c);
    if (!c || lr.size()!=2 || lr[0]!=RDMA_QUEUE_ROLE_CQ_PD || lr[1]!=RDMA_QUEUE_ROLE_CQ_RING)
      `uvm_error("DESTROY_RECIPE_CQ_LOCAL", "CQ local recipe mismatch")
    policy = rdma_srq_lifecycle_policy::type_id::create("recipe_srq");
    policy.hardware_cleanup_roles(fr, fp, d);
    if (d || fr.size()!=2 || fr[0]!=RDMA_QUEUE_ROLE_SRFQ_PD || fr[1]!=RDMA_QUEUE_ROLE_SRQ_PD)
      `uvm_error("DESTROY_RECIPE_SRQ", "SRQ recipe mismatch")
    policy = rdma_ceq_lifecycle_policy::type_id::create("recipe_ceq");
    policy.hardware_cleanup_roles(fr, fp, d);
    if (!d || fr.size()!=0)
      `uvm_error("DESTROY_RECIPE_CEQ", "CEQ recipe mismatch")
    policy = rdma_aeq_lifecycle_policy::type_id::create("recipe_aeq");
    policy.hardware_cleanup_roles(fr, fp, d);
    if (!d || fr.size()!=0)
      `uvm_error("DESTROY_RECIPE_AEQ", "AEQ recipe mismatch")
  endtask

  task automatic check_destroy_invalid_matrix();
    rdma_queue_lifecycle_executor ex;
    rdma_function_binding b;
    rdma_destroy_resource_req req;
    rdma_control_result res;
    ex = rdma_queue_lifecycle_executor::type_id::create("destroy_matrix_ex");
    b = make_binding("destroy_matrix_binding");
    req = rdma_destroy_resource_req::type_id::create("destroy_matrix_req");
    req.target_h = null;
    ex.destroy_locked(b, b.make_handle(), req, 32'd900, res);
    if (res == null || res.status == null || res.status.code != RDMA_SC_INVALID_ARGUMENT)
      `uvm_error("DESTROY_INVALID", "invalid destroy did not fail closed")
  endtask


  task run_phase(uvm_phase phase);
    phase.raise_objection(this);
    check_preflight();
    check_backing_planner_positive();
    check_backing_planner_negative();
    check_backing_planner_rollback_and_cleanup();
    check_contexts_and_commands();
    check_executor_context_optional_for_eq();
    check_destroy_success_traces();
    check_destroy_borrowed_eq_detach();
    check_destroy_busy_guards();
    check_destroy_srq_restore_retry();
    check_destroy_nonok_null_outcome_fail_closed();
    check_destroy_cq_post_delete_flush_failure();
    check_destroy_failure_matrix();
    check_destroy_srq_flush_failure();
    check_public_destroy_success();
    check_destroy_recipe_contract();
    check_destroy_invalid_matrix();
    check_create_executor();
    phase.drop_objection(this);
  endtask
endclass
