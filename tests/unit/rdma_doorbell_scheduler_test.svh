class rdma_doorbell_blocking_pcie extends rdma_mock_pcie;
  `uvm_object_utils(rdma_doorbell_blocking_pcie)

  longint unsigned blocked_function_uid;
  string blocked_method;
  bit block_enabled;
  bit barrier_entered;
  bit release_barrier;
  int unsigned blocked_call_count;

  function new(string name = "rdma_doorbell_blocking_pcie");
    super.new(name);
    blocked_function_uid = 0;
    blocked_method = "dma_visibility_barrier";
    block_enabled = 1'b0;
    barrier_entered = 1'b0;
    release_barrier = 1'b0;
    blocked_call_count = 0;
  endfunction

  protected task block_selected_call(
    string method_name,
    rdma_function_handle function_h
  );
    if (block_enabled && method_name == blocked_method &&
        function_h != null &&
        function_h.function_uid == blocked_function_uid) begin
      barrier_entered = 1'b1;
      blocked_call_count++;
      wait (release_barrier);
    end
  endtask

  virtual task dma_visibility_barrier(
    rdma_function_handle function_h,
    output rdma_status status
  );
    void'(record_call("dma_visibility_barrier", '0, '0, '0, '0,
                      function_h));
    status = take_failure("dma_visibility_barrier");
    if (status != null)
      return;
    block_selected_call("dma_visibility_barrier", function_h);
    status = rdma_status::success();
  endtask

  virtual task mmio_ordering_barrier(
    rdma_function_handle function_h,
    output rdma_status status
  );
    void'(record_call("mmio_ordering_barrier", '0, '0, '0, '0,
                      function_h));
    status = take_failure("mmio_ordering_barrier");
    if (status != null)
      return;
    block_selected_call("mmio_ordering_barrier", function_h);
    status = rdma_status::success();
  endtask

  virtual task mmio_write(
    rdma_function_handle function_h,
    rdma_bar_addr_t address,
    byte data[],
    output rdma_status status
  );
    void'(record_call("mmio_write", '0, '0, '0, '0, function_h,
                      address, data));
    status = take_failure("mmio_write");
    if (status != null)
      return;
    block_selected_call("mmio_write", function_h);
    status = rdma_status::success();
  endtask
endclass

class rdma_doorbell_scheduler_test extends uvm_test;
  `uvm_component_utils(rdma_doorbell_scheduler_test)

  function new(string name = "rdma_doorbell_scheduler_test",
               uvm_component parent = null);
    super.new(name, parent);
  endfunction

  function automatic void expect_status(
    string label,
    rdma_status status,
    rdma_status_code_e expected
  );
    if (status == null) begin
      `uvm_error(label, "scheduler returned null status")
      return;
    end
    if (status.code != expected)
      `uvm_error(label,
                 $sformatf("expected %s, got %s (%s)", expected.name(),
                           status.code.name(), status.convert2string()))
  endfunction

  function automatic rdma_function_binding make_binding(
    string name,
    longint unsigned function_uid,
    int unsigned function_id,
    int unsigned generation,
    longint unsigned bar_base
  );
    rdma_function_binding binding;
    rdma_interrupt_vector_binding vector;
    binding = rdma_function_binding::type_id::create(name);
    binding.function_uid = function_uid;
    binding.global_function_id = function_id;
    binding.generation = generation;
    binding.pcie.bdf = '{segment:16'h0, bus:function_id[7:0],
                         device:5'h1, function_num:3'h0};
    binding.pcie.bar[0].base.value = bar_base;
    binding.pcie.bar[0].size = 64'h4000;
    binding.pcie.bar[0].enabled = 1'b1;
    binding.notify_bar_id = 3'd0;
    binding.notify_base.value = bar_base + 64'h2000;
    binding.notify_size = 64'h2000;
    binding.state = RDMA_BIND_ACTIVE;
    binding.owner_h = binding.make_handle();
    binding.queue_dma.requester_bdf = binding.pcie.bdf;
    binding.queue_dma.pasid_valid = 1'b0;
    binding.queue_dma.pasid = '0;
    binding.queue_dma.dma_domain_valid = 1'b1;
    binding.queue_dma.dma_domain_id = 32'h1122_3344;
    binding.queue_caps.min_cq_depth = 16;
    binding.queue_caps.max_cq_depth = 32768;
    binding.queue_caps.min_srq_depth = 16;
    binding.queue_caps.max_srq_depth = 32768;
    binding.queue_caps.max_ceq_depth = 4096;
    binding.queue_caps.max_aeq_depth = 4096;
    binding.queue_caps.max_wq_sge = 8;
    binding.queue_caps.max_queue_ring_bytes = 32'h0020_0000;
    binding.queue_caps.max_sgb_bytes = 32'h0040_0000;
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

  function automatic rdma_handle make_target(
    string name,
    rdma_function_handle function_h,
    rdma_resource_kind_e kind,
    int unsigned object_id
  );
    rdma_handle target;
    target = rdma_handle::type_id::create(name);
    target.kind = kind;
    target.function_uid = function_h.function_uid;
    target.object_id = object_id;
    target.generation = function_h.generation;
    return target;
  endfunction

  function automatic rdma_hw_image make_image(
    string name,
    rdma_function_handle function_h,
    longint unsigned relative_offset,
    byte unsigned payload[],
    rdma_hw_target_kind_e target_kind
  );
    rdma_hw_image image;
    image = rdma_hw_image::type_id::create(name);
    foreach (payload[i]) image.bytes.push_back(payload[i]);
    image.length = payload.size();
    image.alignment = 8;
    image.endian = RDMA_ENDIAN_BIG;
    image.image_kind = RDMA_IMAGE_DOORBELL;
    image.hardware_version = 1;
    image.function_generation = function_h.generation;
    image.write_target_kind = target_kind;
    if (target_kind == RDMA_HW_TARGET_BAR)
      image.bar_target.value = relative_offset;
    return image;
  endfunction

  function automatic rdma_doorbell_desc make_desc(
    string name,
    rdma_function_binding binding
  );
    rdma_doorbell_desc desc;
    rdma_function_handle function_h;
    byte unsigned payload[] = '{8'h00, 8'h00, 8'hc5, 8'h67,
                                8'h00, 8'ha1, 8'h55, 8'h55};
    desc = rdma_doorbell_desc::type_id::create(name);
    function_h = binding.make_handle();
    desc.kind = RDMA_DOORBELL_RQ;
    desc.function_h = function_h;
    desc.target_h = make_target({name, "_qp"}, function_h,
                                RDMA_RESOURCE_QP, 21'h15555);
    desc.notify_bar_id = binding.notify_bar_id;
    desc.relative_offset = 64'h10;
    desc.width = 8;
    desc.endian = RDMA_ENDIAN_BIG;
    desc.payload_image = make_image({name, "_payload"}, function_h,
                                    desc.relative_offset, payload,
                                    RDMA_HW_TARGET_BAR);
    desc.barrier_policy = RDMA_DB_BARRIER_DMA_MMIO;
    desc.write_combining_policy = RDMA_DB_WRITE_NON_COMBINING;
    desc.allow_merge = 1'b0;
    desc.merge_requested = 1'b0;
    desc.timeout = 100ns;
    desc.readback_policy = RDMA_DB_READBACK_NONE;
    return desc;
  endfunction

  function automatic rdma_doorbell_dependency make_dependency(
    string name,
    longint unsigned dependency_id,
    rdma_doorbell_dependency_stage_e stage,
    rdma_dma_mapping mapping,
    longint unsigned relative_offset,
    rdma_function_handle function_h,
    byte unsigned value
  );
    rdma_doorbell_dependency dependency;
    byte unsigned payload[];
    payload = new[8];
    foreach (payload[i]) payload[i] = value + i;
    dependency = rdma_doorbell_dependency::type_id::create(name);
    dependency.dependency_id = dependency_id;
    dependency.stage = stage;
    dependency.mapping = mapping;
    dependency.relative_offset = relative_offset;
    dependency.image = make_image({name, "_image"}, function_h, 0,
                                  payload, RDMA_HW_TARGET_BACKING);
    dependency.ready = 1'b1;
    return dependency;
  endfunction

  function automatic void add_two_dependencies(
    rdma_doorbell_desc desc,
    rdma_dma_mapping mapping,
    rdma_function_handle function_h
  );
    rdma_doorbell_dependency queue_dependency;
    rdma_doorbell_dependency payload_dependency;
    queue_dependency = make_dependency(
      "queue_dependency", 64'd2, RDMA_DB_DEP_QUEUE_CONTEXT,
      mapping, 16, function_h, 8'hb0
    );
    payload_dependency = make_dependency(
      "payload_dependency", 64'd1, RDMA_DB_DEP_PAYLOAD,
      mapping, 8, function_h, 8'ha0
    );
    // Deliberately interleaved: the scheduler must stage-sort while retaining
    // caller order within each stage.
    desc.dependencies.push_back(queue_dependency);
    desc.dependencies.push_back(payload_dependency);
  endfunction

  function automatic void clear_observation(
    rdma_mock_host_mem mem,
    rdma_mock_pcie pcie,
    rdma_mock_call_trace trace
  );
    mem.calls.delete();
    pcie.calls.delete();
    trace.clear();
  endfunction

  function automatic void expect_no_side_effects(
    string label,
    rdma_mock_host_mem mem,
    rdma_mock_pcie pcie,
    rdma_mock_call_trace trace
  );
    if (mem.calls.size() != 0 || pcie.calls.size() != 0 ||
        trace.calls.size() != 0)
      `uvm_error(label, "preflight failure caused adapter side effects")
  endfunction

  task automatic expect_rejected(
    string label,
    rdma_doorbell_scheduler scheduler,
    rdma_function_binding binding,
    rdma_doorbell_desc desc,
    rdma_status_code_e expected,
    rdma_mock_host_mem mem,
    rdma_mock_pcie pcie,
    rdma_mock_call_trace trace
  );
    rdma_doorbell_result result;
    rdma_status status;
    clear_observation(mem, pcie, trace);
    result = null;
    scheduler.submit(binding, desc, result, status);
    expect_status(label, status, expected);
    if (result != null)
      `uvm_error(label, "rejected submission published a result")
    expect_no_side_effects(label, mem, pcie, trace);
  endtask

  function automatic void expect_trace(
    string label,
    rdma_mock_call_trace trace,
    string expected[]
  );
    if (trace.calls.size() != expected.size()) begin
      `uvm_error(label,
                 $sformatf("trace has %0d calls, expected %0d",
                           trace.calls.size(), expected.size()))
      return;
    end
    foreach (expected[i]) begin
      if (trace.calls[i] != expected[i])
        `uvm_error(label,
                   $sformatf("call %0d is %s, expected %s", i,
                             trace.calls[i], expected[i]))
    end
  endfunction

  task automatic expect_recovery_submit(
    string label,
    rdma_doorbell_scheduler scheduler,
    rdma_function_binding binding
  );
    rdma_doorbell_desc recovery_desc;
    rdma_doorbell_result recovery_result;
    rdma_status recovery_status;

    recovery_desc = make_desc({label, "_desc"}, binding);
    scheduler.submit(binding, recovery_desc, recovery_result, recovery_status);
    expect_status(label, recovery_status, RDMA_SC_OK);
    if (recovery_result == null)
      `uvm_error(label, "same-Function recovery did not publish a result")
  endtask

  task automatic check_value_clone_contracts(
    rdma_function_binding binding,
    rdma_dma_mapping allocated_mapping
  );
    uvm_object cloned_object;
    rdma_dma_mapping source_mapping;
    rdma_mock_dma_mapping source_mock_mapping;
    rdma_mock_dma_mapping cloned_mock_mapping;
    rdma_doorbell_dependency source_dependency;
    rdma_doorbell_dependency cloned_dependency;
    rdma_doorbell_desc source_desc;
    rdma_doorbell_desc cloned_desc;
    rdma_doorbell_result source_result;
    rdma_doorbell_result cloned_result;
    rdma_function_handle function_h;
    longint unsigned expected_mapping_iova;
    byte unsigned expected_dependency_byte;
    byte unsigned expected_payload_byte;

    function_h = binding.make_handle();
    cloned_object = allocated_mapping.clone();
    if (cloned_object == null || !$cast(source_mapping, cloned_object)) begin
      `uvm_error("DB_COPY_SETUP", "could not clone source DMA mapping")
      return;
    end
    source_dependency = make_dependency(
      "copy_dependency", 64'h1234, RDMA_DB_DEP_QUEUE_CONTEXT,
      source_mapping, 8, function_h, 8'h40
    );
    expected_mapping_iova = source_dependency.mapping.iova.value;
    expected_dependency_byte = source_dependency.image.bytes[0];

    cloned_object = source_dependency.clone();
    if (cloned_object == null || !$cast(cloned_dependency, cloned_object)) begin
      `uvm_error("DEPENDENCY_COPY", "dependency clone type was not preserved")
    end
    else begin
      if (cloned_dependency.dependency_id != source_dependency.dependency_id ||
          cloned_dependency.stage != source_dependency.stage ||
          cloned_dependency.relative_offset !=
            source_dependency.relative_offset ||
          cloned_dependency.ready != source_dependency.ready)
        `uvm_error("DEPENDENCY_COPY", "dependency scalar fields were not copied")
      if (cloned_dependency.mapping == null ||
          cloned_dependency.mapping == source_dependency.mapping ||
          cloned_dependency.image == null ||
          cloned_dependency.image == source_dependency.image)
        `uvm_error("DEPENDENCY_COPY", "dependency value handles alias source")
      if (cloned_dependency.mapping == null) begin
        `uvm_error("DEPENDENCY_COPY", "mapping clone was null")
      end
      else if (!$cast(source_mock_mapping, source_dependency.mapping)) begin
        `uvm_error("DEPENDENCY_COPY",
                   "source mapping lost its concrete mock type")
      end
      else if (!$cast(cloned_mock_mapping, cloned_dependency.mapping)) begin
        `uvm_error("DEPENDENCY_COPY",
                   "mapping clone lost its concrete mock type")
      end
      else if (!cloned_mock_mapping.same_allocation(source_mock_mapping)) begin
        `uvm_error("DEPENDENCY_COPY",
                   "mapping clone lost opaque allocation identity")
      end
      if (cloned_dependency.mapping != null &&
          cloned_dependency.mapping.state !=
            source_dependency.mapping.state)
        `uvm_error("DEPENDENCY_COPY", "mapping clone lost mapping state")

      source_dependency.mapping.iova.value++;
      source_dependency.image.bytes[0] ^= 8'hff;
      if (cloned_dependency.mapping == null ||
          cloned_dependency.image == null) begin
        `uvm_error("DEPENDENCY_COPY",
                   "dependency clone omitted nested values")
      end
      else if (cloned_dependency.mapping.iova.value != expected_mapping_iova ||
               cloned_dependency.image.bytes[0] !=
                 expected_dependency_byte) begin
        `uvm_error("DEPENDENCY_COPY",
                   "dependency clone changed after source mutation")
      end
    end

    source_desc = make_desc("copy_desc", binding);
    source_desc.dependencies.push_back(source_dependency);
    expected_payload_byte = source_desc.payload_image.bytes[0];
    cloned_object = source_desc.clone();
    if (cloned_object == null || !$cast(cloned_desc, cloned_object)) begin
      `uvm_error("DESC_COPY", "descriptor clone type was not preserved")
    end
    else begin
      if (cloned_desc.kind != source_desc.kind ||
          cloned_desc.notify_bar_id != source_desc.notify_bar_id ||
          cloned_desc.relative_offset != source_desc.relative_offset ||
          cloned_desc.width != source_desc.width ||
          cloned_desc.endian != source_desc.endian ||
          cloned_desc.barrier_policy != source_desc.barrier_policy ||
          cloned_desc.write_combining_policy !=
            source_desc.write_combining_policy ||
          cloned_desc.allow_merge != source_desc.allow_merge ||
          cloned_desc.merge_requested != source_desc.merge_requested ||
          cloned_desc.timeout != source_desc.timeout ||
          cloned_desc.readback_policy != source_desc.readback_policy)
        `uvm_error("DESC_COPY", "descriptor scalar fields were not copied")
      if (cloned_desc.function_h == null ||
          cloned_desc.target_h == null ||
          cloned_desc.payload_image == null ||
          cloned_desc.dependencies.size() != 1) begin
        `uvm_error("DESC_COPY", "descriptor clone omitted value fields")
      end
      else if (cloned_desc.function_h == source_desc.function_h ||
               cloned_desc.target_h == source_desc.target_h ||
               cloned_desc.payload_image == source_desc.payload_image ||
               cloned_desc.dependencies[0] == source_desc.dependencies[0] ||
               cloned_desc.dependencies[0].mapping ==
                 source_desc.dependencies[0].mapping ||
               cloned_desc.dependencies[0].image ==
                 source_desc.dependencies[0].image) begin
        `uvm_error("DESC_COPY", "descriptor value graph aliases source")
      end
      if (cloned_desc.dependencies.size() == 1 &&
          cloned_desc.dependencies[0].mapping != null &&
          cloned_desc.dependencies[0].mapping.state !=
            source_desc.dependencies[0].mapping.state)
        `uvm_error("DESC_COPY", "nested mapping clone lost mapping state")

      source_desc.function_h.generation++;
      source_desc.target_h.object_id++;
      source_desc.payload_image.bytes[0] ^= 8'hff;
      source_desc.dependencies[0].relative_offset++;
      if (cloned_desc.function_h == null ||
          cloned_desc.target_h == null ||
          cloned_desc.payload_image == null ||
          cloned_desc.dependencies.size() != 1) begin
        `uvm_error("DESC_COPY", "descriptor clone omitted mutation targets")
      end
      else if (cloned_desc.function_h.generation != binding.generation ||
               cloned_desc.target_h.object_id != 21'h15555 ||
               cloned_desc.payload_image.bytes[0] != expected_payload_byte ||
               cloned_desc.dependencies[0].relative_offset != 8) begin
        `uvm_error("DESC_COPY", "descriptor clone changed after source mutation")
      end
    end

    source_result = rdma_doorbell_result::type_id::create("copy_result");
    source_result.kind = RDMA_DOORBELL_RQ;
    source_result.function_h = function_h;
    source_result.target_h = make_target("copy_result_target", function_h,
                                         RDMA_RESOURCE_QP, 21'h15555);
    source_result.absolute_address.value = 64'h1234_5000;
    source_result.width = 8;
    source_result.dependency_count = 3;
    cloned_object = source_result.clone();
    if (cloned_object == null || !$cast(cloned_result, cloned_object)) begin
      `uvm_error("RESULT_COPY", "result clone type was not preserved")
    end
    else begin
      if (cloned_result.kind != source_result.kind ||
          cloned_result.absolute_address != source_result.absolute_address ||
          cloned_result.width != source_result.width ||
          cloned_result.dependency_count != source_result.dependency_count ||
          cloned_result.function_h == null ||
          cloned_result.target_h == null) begin
        `uvm_error("RESULT_COPY", "result fields were not copied")
      end
      else if (cloned_result.function_h == source_result.function_h ||
               cloned_result.target_h == source_result.target_h) begin
        `uvm_error("RESULT_COPY", "result fields were not deep copied")
      end
      source_result.function_h.generation++;
      source_result.target_h.object_id++;
      if (cloned_result.function_h == null ||
          cloned_result.target_h == null) begin
        `uvm_error("RESULT_COPY", "result clone omitted mutation targets")
      end
      else if (cloned_result.function_h.generation != binding.generation ||
               cloned_result.target_h.object_id != 21'h15555) begin
        `uvm_error("RESULT_COPY", "result clone changed after source mutation")
      end
    end
  endtask

  task run_phase(uvm_phase phase);
    rdma_mock_call_trace trace;
    rdma_mock_host_mem mem;
    rdma_host_mem_api mem_api;
    rdma_mock_pcie pcie;
    rdma_pcie_api pcie_api;
    rdma_doorbell_scheduler scheduler;
    rdma_function_binding binding_a;
    rdma_function_binding binding_b;
    rdma_function_binding snapshot_binding;
    rdma_function_binding rebound_binding_old;
    rdma_function_binding rebound_binding_new;
    rdma_function_handle function_a;
    rdma_function_handle function_b;
    rdma_dma_request_context request_context;
    rdma_dma_mapping mapping;
    rdma_doorbell_desc desc;
    rdma_doorbell_dependency dependency;
    rdma_doorbell_result result;
    rdma_status status;
    rdma_status injected;
    byte expected_mmio[] = '{8'h00, 8'h00, 8'hc5, 8'h67,
                             8'h00, 8'ha1, 8'h55, 8'h55};
    string full_order[] = '{"host_write", "host_write",
                            "pcie_dma_visibility_barrier",
                            "pcie_mmio_ordering_barrier",
                            "pcie_mmio_write"};
    string host_first_failure[] = '{"host_write"};
    string host_second_failure[] = '{"host_write", "host_write"};
    string dma_failure[] = '{"host_write", "host_write",
                             "pcie_dma_visibility_barrier"};
    string mmio_barrier_failure[] = '{
      "host_write", "host_write", "pcie_dma_visibility_barrier",
      "pcie_mmio_ordering_barrier"
    };
    rdma_doorbell_blocking_pcie blocking_pcie;
    rdma_pcie_api blocking_pcie_api;
    rdma_doorbell_scheduler concurrent_scheduler;
    rdma_doorbell_desc first_desc;
    rdma_doorbell_desc second_desc;
    rdma_doorbell_desc other_desc;
    rdma_doorbell_desc snapshot_desc;
    rdma_doorbell_result first_result;
    rdma_doorbell_result second_result;
    rdma_doorbell_result other_result;
    rdma_doorbell_result snapshot_result;
    rdma_status first_status;
    rdma_status second_status;
    rdma_status other_status;
    rdma_status snapshot_status;
    bit first_done;
    bit second_started;
    bit second_done;
    bit other_done;
    bit snapshot_done;
    bit watchdog_fired;
    time submit_started_at;
    time submit_finished_at;
    string blocking_methods[3] = '{
      "dma_visibility_barrier", "mmio_ordering_barrier", "mmio_write"
    };
    longint unsigned snapshot_address;
    int unsigned expected_generation;
    int unsigned expected_target_id;

    phase.raise_objection(this);

    trace = rdma_mock_call_trace::type_id::create("trace");
    mem = rdma_mock_host_mem::type_id::create("mem");
    pcie = rdma_mock_pcie::type_id::create("pcie");
    mem.set_call_trace(trace);
    pcie.set_call_trace(trace);
    mem_api = mem;
    pcie_api = pcie;
    scheduler = rdma_doorbell_scheduler::type_id::create("scheduler");
    expect_status("CONFIGURE_NULL_HOST", scheduler.configure(null, pcie_api),
                  RDMA_SC_INVALID_ARGUMENT);
    expect_status("CONFIGURE_NULL_PCIE", scheduler.configure(mem_api, null),
                  RDMA_SC_INVALID_ARGUMENT);
    expect_status("CONFIGURE", scheduler.configure(mem_api, pcie_api),
                  RDMA_SC_OK);

    binding_a = make_binding("binding_a", 64'haaaa, 1, 9,
                             64'h0000_0000_8000_0000);
    binding_b = make_binding("binding_b", 64'hbbbb, 2, 4,
                             64'h0000_0000_9000_0000);
    function_a = binding_a.make_handle();
    function_b = binding_b.make_handle();
    request_context = rdma_dma_request_context::type_id::create(
      "dependency_dma_context"
    );
    request_context.function_h =
      rdma_mock_clone_function_handle(function_a);
    request_context.requester_bdf = binding_a.pcie.bdf;
    request_context.pasid_valid = 1'b0;
    request_context.pasid = '0;
    request_context.dma_domain_valid = binding_a.queue_dma.dma_domain_valid;
    request_context.dma_domain_id = binding_a.queue_dma.dma_domain_id;
    request_context.owner_h = null;
    status = mem.allocate(request_context, 64, 8,
                          RDMA_DMA_DEVICE_READ, mapping);
    expect_status("ALLOCATE_DEPENDENCY", status, RDMA_SC_OK);
    if (mapping == null) begin
      `uvm_fatal("TEST_SETUP", "dependency mapping allocation failed")
    end
    // Scheduler request/result objects are values: cloning must recursively
    // detach every mutable handle/image/dependency while preserving the
    // concrete mapping subclass's opaque allocation identity.
    check_value_clone_contracts(binding_a, mapping);
    if (mapping.state != RDMA_MAPPING_ACTIVE)
      `uvm_error("DB_COPY_SETUP", "clone contract mutated source mapping state")

    // Successful execution proves stage ordering, barriers, final address,
    // exact payload bytes, and success-only result publication.
    desc = make_desc("success_desc", binding_a);
    add_two_dependencies(desc, mapping, function_a);
    clear_observation(mem, pcie, trace);
    result = null;
    scheduler.submit(binding_a, desc, result, status);
    expect_status("ORDERED_SUBMIT", status, RDMA_SC_OK);
    expect_trace("ORDERED_SUBMIT", trace, full_order);
    if (mem.calls.size() != 2 || mem.calls[0].offset != 8 ||
        mem.calls[1].offset != 16)
      `uvm_error("ORDERED_SUBMIT", "dependency stage order is incorrect")
    if (pcie.calls.size() != 3 ||
        pcie.calls[2].method_name != "mmio_write" ||
        pcie.calls[2].address.value != binding_a.notify_base.value + 16 ||
        pcie.calls[2].data != expected_mmio)
      `uvm_error("ORDERED_SUBMIT", "MMIO address or payload is incorrect")
    if (result == null || result.absolute_address.value !=
        binding_a.notify_base.value + 16 || result.width != 8 ||
        result.dependency_count != 2)
      `uvm_error("ORDERED_SUBMIT", "success result is incomplete")

    // Complete preflight must reject each malformed coordinate before the
    // first host-memory or PCIe side effect.
    binding_a.state = RDMA_BIND_BOUND;
    desc = make_desc("inactive_binding", binding_a);
    expect_rejected("INACTIVE_BINDING", scheduler, binding_a, desc,
                    RDMA_SC_INVALID_STATE, mem, pcie, trace);
    binding_a.state = RDMA_BIND_ACTIVE;

    binding_a.owner_h.generation = binding_a.generation - 1;
    desc = make_desc("stale_binding", binding_a);
    expect_rejected("STALE_BINDING", scheduler, binding_a, desc,
                    RDMA_SC_STALE_GENERATION, mem, pcie, trace);
    binding_a.owner_h.generation = binding_a.generation;

    desc = make_desc("function_mismatch", binding_a);
    desc.function_h.function_uid = 64'hcccc;
    expect_rejected("FUNCTION_MISMATCH", scheduler, binding_a, desc,
                    RDMA_SC_INVALID_ARGUMENT, mem, pcie, trace);

    desc = make_desc("target_uid", binding_a);
    desc.target_h.function_uid = 64'hcccc;
    expect_rejected("TARGET_UID", scheduler, binding_a, desc,
                    RDMA_SC_INVALID_ARGUMENT, mem, pcie, trace);

    desc = make_desc("target_generation", binding_a);
    desc.target_h.generation--;
    expect_rejected("TARGET_GENERATION", scheduler, binding_a, desc,
                    RDMA_SC_STALE_GENERATION, mem, pcie, trace);

    desc = make_desc("target_kind", binding_a);
    desc.target_h.kind = RDMA_RESOURCE_CQ;
    expect_rejected("TARGET_KIND", scheduler, binding_a, desc,
                    RDMA_SC_INVALID_ARGUMENT, mem, pcie, trace);

    desc = make_desc("wrong_bar", binding_a);
    desc.notify_bar_id = 1;
    expect_rejected("WRONG_BAR", scheduler, binding_a, desc,
                    RDMA_SC_INVALID_ARGUMENT, mem, pcie, trace);

    desc = make_desc("out_of_window", binding_a);
    desc.relative_offset = binding_a.notify_size - 4;
    desc.payload_image.bar_target.value = desc.relative_offset;
    expect_rejected("OUT_OF_WINDOW", scheduler, binding_a, desc,
                    RDMA_SC_INVALID_ARGUMENT, mem, pcie, trace);

    desc = make_desc("address_overflow", binding_a);
    binding_a.notify_base.value = 64'hffff_ffff_ffff_e000;
    binding_a.pcie.bar[0].base.value = 64'hffff_ffff_ffff_e000;
    binding_a.pcie.bar[0].size = 64'h2000;
    expect_rejected("ADDRESS_OVERFLOW", scheduler, binding_a, desc,
                    RDMA_SC_INVALID_ARGUMENT, mem, pcie, trace);
    binding_a.notify_base.value = 64'h0000_0000_8000_2000;
    binding_a.pcie.bar[0].base.value = 64'h0000_0000_8000_0000;
    binding_a.pcie.bar[0].size = 64'h4000;

    desc = make_desc("width_mismatch", binding_a);
    desc.width = 4;
    expect_rejected("WIDTH_MISMATCH", scheduler, binding_a, desc,
                    RDMA_SC_INVALID_ARGUMENT, mem, pcie, trace);

    desc = make_desc("endian_mismatch", binding_a);
    desc.endian = RDMA_ENDIAN_LITTLE;
    expect_rejected("ENDIAN_MISMATCH", scheduler, binding_a, desc,
                    RDMA_SC_INVALID_ARGUMENT, mem, pcie, trace);

    desc = make_desc("offset_mismatch", binding_a);
    desc.payload_image.bar_target.value = 64'h18;
    expect_rejected("OFFSET_MISMATCH", scheduler, binding_a, desc,
                    RDMA_SC_INVALID_ARGUMENT, mem, pcie, trace);

    desc = make_desc("unready_dependency", binding_a);
    dependency = make_dependency("unready", 1, RDMA_DB_DEP_PAYLOAD,
                                 mapping, 0, function_a, 8'h11);
    dependency.ready = 1'b0;
    desc.dependencies.push_back(dependency);
    expect_rejected("UNREADY_DEPENDENCY", scheduler, binding_a, desc,
                    RDMA_SC_INVALID_STATE, mem, pcie, trace);

    desc = make_desc("duplicate_dependency", binding_a);
    dependency = make_dependency("duplicate_0", 7, RDMA_DB_DEP_PAYLOAD,
                                 mapping, 0, function_a, 8'h22);
    desc.dependencies.push_back(dependency);
    dependency = make_dependency("duplicate_1", 7,
                                 RDMA_DB_DEP_QUEUE_CONTEXT,
                                 mapping, 8, function_a, 8'h33);
    desc.dependencies.push_back(dependency);
    expect_rejected("DUPLICATE_DEPENDENCY", scheduler, binding_a, desc,
                    RDMA_SC_INVALID_ARGUMENT, mem, pcie, trace);

    desc = make_desc("cross_function_mapping", binding_a);
    dependency = make_dependency("cross_function", 1,
                                 RDMA_DB_DEP_PAYLOAD, mapping, 0,
                                 function_a, 8'h44);
    mapping.function_h = function_b;
    desc.dependencies.push_back(dependency);
    expect_rejected("CROSS_FUNCTION_MAPPING", scheduler, binding_a, desc,
                    RDMA_SC_DMA_TRANSLATION, mem, pcie, trace);
    mapping.function_h = function_a;

    desc = make_desc("inactive_mapping", binding_a);
    dependency = make_dependency("inactive_mapping_dep", 1,
                                 RDMA_DB_DEP_PAYLOAD, mapping, 0,
                                 function_a, 8'h55);
    mapping.state = RDMA_MAPPING_FROZEN;
    desc.dependencies.push_back(dependency);
    expect_rejected("INACTIVE_MAPPING", scheduler, binding_a, desc,
                    RDMA_SC_INVALID_STATE, mem, pcie, trace);
    mapping.state = RDMA_MAPPING_ACTIVE;

    desc = make_desc("mapping_range", binding_a);
    dependency = make_dependency("mapping_range_dep", 1,
                                 RDMA_DB_DEP_PAYLOAD, mapping, 60,
                                 function_a, 8'h66);
    desc.dependencies.push_back(dependency);
    expect_rejected("MAPPING_RANGE", scheduler, binding_a, desc,
                    RDMA_SC_DMA_TRANSLATION, mem, pcie, trace);

    desc = make_desc("mapping_permission", binding_a);
    dependency = make_dependency("mapping_permission_dep", 1,
                                 RDMA_DB_DEP_PAYLOAD, mapping, 0,
                                 function_a, 8'h77);
    mapping.permissions.device_read = 1'b0;
    mapping.direction = RDMA_DMA_DEVICE_WRITE;
    desc.dependencies.push_back(dependency);
    expect_rejected("MAPPING_PERMISSION", scheduler, binding_a, desc,
                    RDMA_SC_DMA_PERMISSION, mem, pcie, trace);
    mapping.permissions.device_read = 1'b1;
    mapping.permissions.device_write = 1'b0;
    mapping.direction = RDMA_DMA_DEVICE_READ;

    desc = make_desc("illegal_merge", binding_a);
    desc.merge_requested = 1'b1;
    expect_rejected("ILLEGAL_MERGE", scheduler, binding_a, desc,
                    RDMA_SC_INVALID_ARGUMENT, mem, pcie, trace);

    desc = make_desc("readback", binding_a);
    desc.readback_policy = RDMA_DB_READBACK_REQUIRED;
    expect_rejected("UNSUPPORTED_READBACK", scheduler, binding_a, desc,
                    RDMA_SC_UNSUPPORTED_OPCODE, mem, pcie, trace);

    // Each adapter failure stops the pipeline immediately and never publishes
    // a result. The second host-write case proves no later write/barrier leaks.
    injected = rdma_status::make(RDMA_SC_TIMEOUT, "injected doorbell failure");

    desc = make_desc("fail_host_first", binding_a);
    add_two_dependencies(desc, mapping, function_a);
    clear_observation(mem, pcie, trace);
    expect_status("ARM_HOST_FIRST", mem.fail_write_at(1, injected),
                  RDMA_SC_OK);
    scheduler.submit(binding_a, desc, result, status);
    expect_status("FAIL_HOST_FIRST", status, RDMA_SC_TIMEOUT);
    expect_trace("FAIL_HOST_FIRST", trace, host_first_failure);
    if (result != null) `uvm_error("FAIL_HOST_FIRST", "failure published result")
    expect_recovery_submit("RECOVER_HOST_FIRST", scheduler, binding_a);

    desc = make_desc("fail_host_second", binding_a);
    add_two_dependencies(desc, mapping, function_a);
    clear_observation(mem, pcie, trace);
    expect_status("ARM_HOST_SECOND", mem.fail_write_at(2, injected),
                  RDMA_SC_OK);
    scheduler.submit(binding_a, desc, result, status);
    expect_status("FAIL_HOST_SECOND", status, RDMA_SC_TIMEOUT);
    expect_trace("FAIL_HOST_SECOND", trace, host_second_failure);
    if (result != null) `uvm_error("FAIL_HOST_SECOND", "failure published result")
    expect_recovery_submit("RECOVER_HOST_SECOND", scheduler, binding_a);

    desc = make_desc("fail_dma_barrier", binding_a);
    add_two_dependencies(desc, mapping, function_a);
    clear_observation(mem, pcie, trace);
    expect_status("ARM_DMA_BARRIER",
                  pcie.fail_next("dma_visibility_barrier", injected),
                  RDMA_SC_OK);
    scheduler.submit(binding_a, desc, result, status);
    expect_status("FAIL_DMA_BARRIER", status, RDMA_SC_TIMEOUT);
    expect_trace("FAIL_DMA_BARRIER", trace, dma_failure);
    if (result != null) `uvm_error("FAIL_DMA_BARRIER", "failure published result")
    expect_recovery_submit("RECOVER_DMA_FAILURE", scheduler, binding_a);

    desc = make_desc("fail_mmio_barrier", binding_a);
    add_two_dependencies(desc, mapping, function_a);
    clear_observation(mem, pcie, trace);
    expect_status("ARM_MMIO_BARRIER",
                  pcie.fail_next("mmio_ordering_barrier", injected),
                  RDMA_SC_OK);
    scheduler.submit(binding_a, desc, result, status);
    expect_status("FAIL_MMIO_BARRIER", status, RDMA_SC_TIMEOUT);
    expect_trace("FAIL_MMIO_BARRIER", trace, mmio_barrier_failure);
    if (result != null) `uvm_error("FAIL_MMIO_BARRIER", "failure published result")
    expect_recovery_submit("RECOVER_MMIO_BARRIER_FAILURE", scheduler,
                           binding_a);

    desc = make_desc("fail_mmio_write", binding_a);
    add_two_dependencies(desc, mapping, function_a);
    clear_observation(mem, pcie, trace);
    expect_status("ARM_MMIO_WRITE", pcie.fail_next("mmio_write", injected),
                  RDMA_SC_OK);
    scheduler.submit(binding_a, desc, result, status);
    expect_status("FAIL_MMIO_WRITE", status, RDMA_SC_TIMEOUT);
    expect_trace("FAIL_MMIO_WRITE", trace, full_order);
    if (result != null) `uvm_error("FAIL_MMIO_WRITE", "failure published result")
    expect_recovery_submit("RECOVER_MMIO_WRITE_FAILURE", scheduler, binding_a);

    // All execution inputs become immutable values after the Function lock is
    // acquired. Mutating the caller graph while a barrier is blocked cannot
    // alter later adapter calls or the published result.
    blocking_pcie = rdma_doorbell_blocking_pcie::type_id::create(
        "blocking_pcie");
    blocking_pcie_api = blocking_pcie;
    concurrent_scheduler = rdma_doorbell_scheduler::type_id::create(
        "concurrent_scheduler");
    expect_status("CONFIGURE_CONCURRENT",
                  concurrent_scheduler.configure(mem_api, blocking_pcie_api),
                  RDMA_SC_OK);

    snapshot_binding = make_binding("snapshot_binding", 64'haaaa, 1, 9,
                                    64'h0000_0000_8000_0000);
    snapshot_desc = make_desc("snapshot_desc", snapshot_binding);
    add_two_dependencies(snapshot_desc, mapping,
                         snapshot_desc.function_h);
    snapshot_address = snapshot_binding.notify_base.value +
                       snapshot_desc.relative_offset;
    expected_generation = snapshot_desc.function_h.generation;
    expected_target_id = snapshot_desc.target_h.object_id;
    blocking_pcie.blocked_function_uid = function_a.function_uid;
    blocking_pcie.blocked_method = "dma_visibility_barrier";
    blocking_pcie.block_enabled = 1'b1;
    blocking_pcie.barrier_entered = 1'b0;
    blocking_pcie.release_barrier = 1'b0;
    blocking_pcie.blocked_call_count = 0;
    blocking_pcie.calls.delete();
    clear_observation(mem, blocking_pcie, trace);
    snapshot_done = 1'b0;
    watchdog_fired = 1'b0;
    fork : snapshot_watchdog
      begin : snapshot_scenario
        fork : snapshot_submit_worker
          begin
            concurrent_scheduler.submit(snapshot_binding, snapshot_desc,
                                        snapshot_result, snapshot_status);
            snapshot_done = 1'b1;
          end
        join_none
        wait (blocking_pcie.barrier_entered);
        snapshot_binding.state = RDMA_BIND_BOUND;
        snapshot_binding.generation++;
        snapshot_binding.notify_base.value += 64'h2000;
        snapshot_desc.function_h.generation += 32;
        snapshot_desc.target_h.object_id++;
        snapshot_desc.relative_offset = 64'h18;
        snapshot_desc.payload_image.bytes[0] = 8'hff;
        snapshot_desc.dependencies[0].relative_offset = 40;
        snapshot_desc.dependencies[0].image.bytes[0] = 8'hee;
        snapshot_desc.dependencies[0].mapping.state = RDMA_MAPPING_FROZEN;
        snapshot_desc.dependencies.delete();
        blocking_pcie.release_barrier = 1'b1;
        wait (snapshot_done);
      end
      begin : snapshot_deadline
        #200ns;
        watchdog_fired = 1'b1;
        blocking_pcie.release_barrier = 1'b1;
        #20ns;
      end
    join_any
    disable snapshot_watchdog;
    if (watchdog_fired)
      `uvm_error("IMMUTABLE_SNAPSHOT", "snapshot submission hung")
    expect_status("IMMUTABLE_SNAPSHOT", snapshot_status, RDMA_SC_OK);
    if (snapshot_result == null ||
        snapshot_result.function_h == null ||
        snapshot_result.function_h.generation != expected_generation ||
        snapshot_result.target_h == null ||
        snapshot_result.target_h.object_id != expected_target_id ||
        snapshot_result.absolute_address.value != snapshot_address ||
        snapshot_result.dependency_count != 2)
      `uvm_error("IMMUTABLE_SNAPSHOT", "result observed caller mutation")
    if (blocking_pcie.calls.size() != 3 ||
        blocking_pcie.calls[1].function_h == null ||
        blocking_pcie.calls[1].function_h.generation != expected_generation ||
        blocking_pcie.calls[2].function_h == null ||
        blocking_pcie.calls[2].function_h.generation != expected_generation ||
        blocking_pcie.calls[2].address.value != snapshot_address ||
        blocking_pcie.calls[2].data != expected_mmio)
      `uvm_error("IMMUTABLE_SNAPSHOT", "adapter observed caller mutation")

    // The timeout is one total simulation-time deadline. Each potentially
    // blocking PCIe task must consume only the remaining request budget, be
    // killed locally on expiry, and leave the Function lock reusable.
    foreach (blocking_methods[method_index]) begin
      first_desc = make_desc({"timeout_", blocking_methods[method_index]},
                             binding_a);
      first_desc.timeout = 5ns;
      blocking_pcie.blocked_function_uid = function_a.function_uid;
      blocking_pcie.blocked_method = blocking_methods[method_index];
      blocking_pcie.block_enabled = 1'b1;
      blocking_pcie.barrier_entered = 1'b0;
      blocking_pcie.release_barrier = 1'b0;
      blocking_pcie.blocked_call_count = 0;
      blocking_pcie.calls.delete();
      first_done = 1'b0;
      watchdog_fired = 1'b0;
      submit_started_at = $time;
      fork : pcie_timeout_watchdog
        begin : timed_submit
          concurrent_scheduler.submit(binding_a, first_desc, first_result,
                                      first_status);
          submit_finished_at = $time;
          first_done = 1'b1;
        end
        begin : timed_submit_deadline
          #(first_desc.timeout + 5ns);
          if (!first_done) begin
            watchdog_fired = 1'b1;
            blocking_pcie.release_barrier = 1'b1;
          end
          #20ns;
        end
      join_any
      disable pcie_timeout_watchdog;
      if (watchdog_fired || !first_done)
        `uvm_error("PCIE_TIMEOUT", {blocking_methods[method_index],
                    " did not honor the descriptor deadline"})
      expect_status({"TIMEOUT_", blocking_methods[method_index]},
                    first_status, RDMA_SC_TIMEOUT);
      if (first_result != null)
        `uvm_error("PCIE_TIMEOUT", "timed-out submission published a result")
      if (!blocking_pcie.barrier_entered ||
          blocking_pcie.blocked_call_count != 1)
        `uvm_error("PCIE_TIMEOUT", "selected adapter task did not block")
      if (submit_finished_at - submit_started_at != first_desc.timeout)
        `uvm_error("PCIE_TIMEOUT", "submit did not use one total deadline")
      blocking_pcie.block_enabled = 1'b0;
      blocking_pcie.release_barrier = 1'b1;
      expect_recovery_submit({"RECOVER_", blocking_methods[method_index]},
                             concurrent_scheduler, binding_a);
    end

    // Waiting for an already-held Function lock consumes the same deadline.
    // A timed-out waiter must not put a token it never acquired: a third
    // waiter remains blocked until the original owner releases the lock.
    first_desc = make_desc("lock_owner", binding_a);
    first_desc.timeout = 100ns;
    second_desc = make_desc("lock_timeout", binding_a);
    second_desc.timeout = 5ns;
    other_desc = make_desc("post_timeout_waiter", binding_a);
    other_desc.timeout = 50ns;
    blocking_pcie.blocked_function_uid = function_a.function_uid;
    blocking_pcie.blocked_method = "dma_visibility_barrier";
    blocking_pcie.block_enabled = 1'b1;
    blocking_pcie.barrier_entered = 1'b0;
    blocking_pcie.release_barrier = 1'b0;
    blocking_pcie.blocked_call_count = 0;
    blocking_pcie.calls.delete();
    first_done = 1'b0;
    second_started = 1'b0;
    second_done = 1'b0;
    other_done = 1'b0;
    watchdog_fired = 1'b0;
    fork : lock_timeout_watchdog
      begin : lock_timeout_scenario
        fork : lock_timeout_workers
          begin
            concurrent_scheduler.submit(binding_a, first_desc, first_result,
                                        first_status);
            first_done = 1'b1;
          end
          begin
            wait (blocking_pcie.barrier_entered);
            second_started = 1'b1;
            submit_started_at = $time;
            concurrent_scheduler.submit(binding_a, second_desc, second_result,
                                        second_status);
            submit_finished_at = $time;
            second_done = 1'b1;
          end
        join_none
        wait (blocking_pcie.barrier_entered && second_done);
        fork : post_timeout_waiter_worker
          begin
            concurrent_scheduler.submit(binding_a, other_desc, other_result,
                                        other_status);
            other_done = 1'b1;
          end
        join_none
        #1ns;
        if (first_done || other_done || blocking_pcie.calls.size() != 1)
          `uvm_error("LOCK_TIMEOUT_TOKEN",
                     "timed-out lock waiter leaked a semaphore token")
        blocking_pcie.release_barrier = 1'b1;
        wait (first_done && other_done);
      end
      begin : lock_timeout_deadline
        #40ns;
        watchdog_fired = 1'b1;
        blocking_pcie.release_barrier = 1'b1;
        #20ns;
      end
    join_any
    disable lock_timeout_watchdog;
    if (watchdog_fired)
      `uvm_error("LOCK_TIMEOUT", "lock wait did not honor its deadline")
    expect_status("LOCK_OWNER", first_status, RDMA_SC_OK);
    expect_status("LOCK_TIMEOUT", second_status, RDMA_SC_TIMEOUT);
    expect_status("POST_TIMEOUT_WAITER", other_status, RDMA_SC_OK);
    if (second_result != null)
      `uvm_error("LOCK_TIMEOUT", "timed-out lock waiter published a result")
    if (submit_finished_at - submit_started_at != second_desc.timeout)
      `uvm_error("LOCK_TIMEOUT", "lock wait used the wrong deadline")
    if (first_result == null || other_result == null)
      `uvm_error("LOCK_TIMEOUT", "lock timeout recovery lost a result")
    blocking_pcie.block_enabled = 1'b0;
    expect_recovery_submit("RECOVER_LOCK_TIMEOUT", concurrent_scheduler,
                           binding_a);

    // Lock identity deliberately excludes generation. Two distinct binding
    // objects for old/new incarnations of one immutable Function serialize.
    rebound_binding_old = make_binding("rebound_old", 64'hcccc, 3, 1,
                                       64'h0000_0000_a000_0000);
    rebound_binding_new = make_binding("rebound_new", 64'hcccc, 3, 2,
                                       64'h0000_0000_a000_0000);
    first_desc = make_desc("old_incarnation", rebound_binding_old);
    second_desc = make_desc("new_incarnation", rebound_binding_new);
    first_desc.timeout = 100ns;
    second_desc.timeout = 100ns;
    blocking_pcie.blocked_function_uid = rebound_binding_old.function_uid;
    blocking_pcie.blocked_method = "dma_visibility_barrier";
    blocking_pcie.block_enabled = 1'b1;
    blocking_pcie.barrier_entered = 1'b0;
    blocking_pcie.release_barrier = 1'b0;
    blocking_pcie.blocked_call_count = 0;
    blocking_pcie.calls.delete();
    first_done = 1'b0;
    second_started = 1'b0;
    second_done = 1'b0;
    watchdog_fired = 1'b0;
    fork : incarnation_lock_watchdog
      begin : incarnation_lock_scenario
        fork : incarnation_workers
          begin
            concurrent_scheduler.submit(rebound_binding_old, first_desc,
                                        first_result, first_status);
            first_done = 1'b1;
          end
          begin
            wait (blocking_pcie.barrier_entered);
            second_started = 1'b1;
            concurrent_scheduler.submit(rebound_binding_new, second_desc,
                                        second_result, second_status);
            second_done = 1'b1;
          end
        join_none
        wait (blocking_pcie.barrier_entered && second_started);
        #1ns;
        if (first_done || second_done || blocking_pcie.calls.size() != 1)
          `uvm_error("INCARNATION_LOCK",
                     "new Function incarnation overlapped the old one")
        blocking_pcie.release_barrier = 1'b1;
        wait (first_done && second_done);
      end
      begin : incarnation_lock_deadline
        #50ns;
        watchdog_fired = 1'b1;
        blocking_pcie.release_barrier = 1'b1;
        #20ns;
      end
    join_any
    disable incarnation_lock_watchdog;
    if (watchdog_fired)
      `uvm_error("INCARNATION_LOCK", "incarnation serialization hung")
    expect_status("OLD_INCARNATION", first_status, RDMA_SC_OK);
    expect_status("NEW_INCARNATION", second_status, RDMA_SC_OK);
    if (first_result == null || second_result == null)
      `uvm_error("INCARNATION_LOCK", "serialized incarnation lost result")

    // A different Function remains independent of the blocked Function.
    first_desc = make_desc("different_function_a", binding_a);
    other_desc = make_desc("different_function_b", binding_b);
    blocking_pcie.blocked_function_uid = function_a.function_uid;
    blocking_pcie.blocked_method = "dma_visibility_barrier";
    blocking_pcie.block_enabled = 1'b1;
    blocking_pcie.barrier_entered = 1'b0;
    blocking_pcie.release_barrier = 1'b0;
    blocking_pcie.blocked_call_count = 0;
    blocking_pcie.calls.delete();
    first_done = 1'b0;
    other_done = 1'b0;
    watchdog_fired = 1'b0;
    fork : independent_function_watchdog
      begin : independent_function_scenario
        fork : independent_function_workers
          begin
            concurrent_scheduler.submit(binding_a, first_desc, first_result,
                                        first_status);
            first_done = 1'b1;
          end
          begin
            wait (blocking_pcie.barrier_entered);
            concurrent_scheduler.submit(binding_b, other_desc, other_result,
                                        other_status);
            other_done = 1'b1;
          end
        join_none
        wait (blocking_pcie.barrier_entered && other_done);
        blocking_pcie.release_barrier = 1'b1;
        wait (first_done);
      end
      begin : independent_function_deadline
        #50ns;
        watchdog_fired = 1'b1;
        blocking_pcie.release_barrier = 1'b1;
        #20ns;
      end
    join_any
    disable independent_function_watchdog;
    if (watchdog_fired)
      `uvm_error("DIFFERENT_FUNCTION_LOCK",
                 "independent Function progress hung")
    if (!first_done || first_result == null || other_result == null)
      `uvm_error("DIFFERENT_FUNCTION_LOCK",
                 "independent Function submissions lost a result")
    expect_status("DIFFERENT_FUNCTION_B", other_status, RDMA_SC_OK);
    expect_status("DIFFERENT_FUNCTION_A", first_status, RDMA_SC_OK);

    phase.drop_objection(this);
  endtask
endclass
