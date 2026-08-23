class rdma_cmq_test_profile extends rdma_cmq_hw_profile;
  `uvm_object_utils(rdma_cmq_test_profile)

  localparam bit [31:0] TEST_OPCODE = 32'hcafe_0001;

  bit fail_validation;
  int unsigned validation_calls;

  function new(string name = "rdma_cmq_test_profile");
    super.new(name);
    fail_validation = 1'b0;
    validation_calls = 0;
  endfunction

  virtual function string profile_name();
    return "cmq_engine_test";
  endfunction

  virtual function rdma_status validate_profile();
    validation_calls++;
    if (fail_validation)
      return rdma_status::make(RDMA_SC_INVALID_STATE,
                               "test CMQ profile validation failed");
    return rdma_status::success();
  endfunction

  virtual function rdma_status compose_sqe(
    rdma_cmq_command_desc command,
    rdma_cmq_slot_context slot,
    output rdma_hw_image sqe,
    output rdma_cmq_expected_response expected
  );
    sqe = null;
    expected = null;
    if (command == null || command.opcode_key == null ||
        command.opcode_key.profile_name != profile_name() ||
        command.opcode_key.opcode != TEST_OPCODE)
      return rdma_status::make(RDMA_SC_UNSUPPORTED_OPCODE,
                               "test profile accepts only its test opcode");
    if (slot == null)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "test profile slot is null");
    sqe = rdma_hw_image::type_id::create("test_sqe");
    for (int unsigned i = 0; i < 64; i++)
      sqe.bytes.push_back(8'h00);
    sqe.length = 64;
    sqe.alignment = 64;
    sqe.endian = RDMA_ENDIAN_LITTLE;
    sqe.image_kind = RDMA_IMAGE_CMQ_SQE;
    sqe.hardware_version = 1;
    sqe.function_generation = command.function_h.generation;
    expected = rdma_cmq_expected_response::type_id::create(
      "test_expected"
    );
    expected.hardware_opcode = TEST_OPCODE;
    expected.variant = "test";
    return rdma_status::success();
  endfunction

  virtual function rdma_status inspect_cqe(
    rdma_hw_image raw_cqe,
    bit expected_owner,
    output bit ready,
    output rdma_cmq_decoded_cqe decoded
  );
    ready = 1'b0;
    decoded = null;
    return rdma_status::make(RDMA_SC_UNSUPPORTED_OPCODE,
                             "test profile has no completion opcode");
  endfunction

  virtual function rdma_status encode_doorbell(
    rdma_handle cmq_h,
    int unsigned final_pi,
    bit polarity,
    output rdma_hw_image image
  );
    image = null;
    return rdma_status::make(RDMA_SC_UNSUPPORTED_OPCODE,
                             "test profile has no doorbell opcode");
  endfunction
endclass

class rdma_cmq_runtime_clone_failure_engine extends rdma_cmq_engine;
  `uvm_object_utils(rdma_cmq_runtime_clone_failure_engine)

  function new(string name = "rdma_cmq_runtime_clone_failure_engine");
    super.new(name);
  endfunction

  virtual function rdma_status publish_runtime_snapshot(
    rdma_cmq_runtime_desc source,
    output rdma_cmq_runtime_desc snapshot
  );
    snapshot = null;
    return rdma_status::make(RDMA_SC_INVALID_STATE,
                             "injected runtime descriptor clone failure");
  endfunction
endclass

class rdma_cmq_engine_probe extends rdma_cmq_engine;
  `uvm_object_utils(rdma_cmq_engine_probe)

  function new(string name = "rdma_cmq_engine_probe");
    super.new(name);
  endfunction

  function void restore_mapping(rdma_dma_mapping source);
    if (backing_mapping != null && source != null)
      backing_mapping.copy(source);
  endfunction

  function void tamper_mapping(int unsigned kind);
    if (backing_mapping == null)
      return;
    case (kind)
      0: backing_mapping.function_h.function_uid++;
      1: backing_mapping.function_h.object_id++;
      2: backing_mapping.function_h.generation++;
      3: backing_mapping.requester_bdf.bus++;
      4: backing_mapping.pasid_valid = !backing_mapping.pasid_valid;
      5: backing_mapping.pasid++;
      6: backing_mapping.owner_h.object_id++;
      7: backing_mapping.state = RDMA_MAPPING_FROZEN;
      8: backing_mapping.size--;
      9: backing_mapping.direction = RDMA_DMA_DEVICE_READ;
      default: backing_mapping.owner_h = null;
    endcase
  endfunction
endclass

class rdma_cmq_short_mapping_mem extends rdma_mock_host_mem;
  `uvm_object_utils(rdma_cmq_short_mapping_mem)

  function new(string name = "rdma_cmq_short_mapping_mem");
    super.new(name);
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
    if (status.ok() && mapping != null) begin
      mapping.size = size - 1'b1;
      regions[regions.size() - 1].mapping.size = size - 1'b1;
    end
    return status;
  endfunction
endclass

class rdma_cmq_engine_test extends uvm_test;
  `uvm_component_utils(rdma_cmq_engine_test)

  localparam longint unsigned TEST_FUNCTION_UID =
    64'h1234_5678_90ab_cdef;
  localparam int unsigned TEST_FUNCTION_ID = 32'h1020_3040;
  localparam int unsigned TEST_GENERATION = 32'd9;
  localparam int unsigned TEST_CMQ_ID = 32'h5566_7788;

  function new(string name = "rdma_cmq_engine_test",
               uvm_component parent = null);
    super.new(name, parent);
  endfunction

  function automatic void expect_status(
    string label,
    rdma_status status,
    rdma_status_code_e expected
  );
    if (status == null) begin
      `uvm_error(label, "engine returned a null status")
      return;
    end
    if (status.code != expected)
      `uvm_error(label,
                 $sformatf("expected %s, got %s (%s)", expected.name(),
                           status.code.name(), status.convert2string()))
  endfunction

  function automatic rdma_function_binding make_binding(
    string name,
    rdma_binding_state_e binding_state
  );
    rdma_function_binding binding;

    binding = rdma_function_binding::type_id::create(name);
    binding.function_uid = TEST_FUNCTION_UID;
    binding.global_function_id = TEST_FUNCTION_ID;
    binding.generation = TEST_GENERATION;
    binding.pcie.bdf = '{segment:16'h0001, bus:8'h42,
                         device:5'h03, function_num:3'h1};
    binding.pcie.bar[0].base.value = 64'h0000_0000_8000_0000;
    binding.pcie.bar[0].size = 64'h0001_0000;
    binding.pcie.bar[0].enabled = 1'b1;
    binding.notify_bar_id = 0;
    binding.notify_base.value = 64'h0000_0000_8000_2000;
    binding.notify_size = 64'h2000;
    binding.state = binding_state;
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

  function automatic rdma_cmq make_cmq(
    string name,
    rdma_function_binding binding,
    int unsigned depth = 32
  );
    rdma_cmq cmq;

    cmq = rdma_cmq::type_id::create(name);
    cmq.handle = rdma_handle::type_id::create({name, "_handle"});
    cmq.handle.kind = RDMA_RESOURCE_CMQ;
    cmq.handle.function_uid = binding.function_uid;
    cmq.handle.object_id = TEST_CMQ_ID;
    cmq.handle.generation = binding.generation;
    cmq.owner = binding.make_handle();
    cmq.state = RDMA_RESOURCE_ALLOCATED;
    cmq.depth = depth;
    return cmq;
  endfunction

  function automatic int unsigned count_host_calls(
    rdma_mock_host_mem mem,
    string method_name
  );
    int unsigned result;

    result = 0;
    foreach (mem.calls[i]) begin
      if (mem.calls[i].method_name == method_name)
        result++;
    end
    return result;
  endfunction

  function automatic void expect_unconfigured(
    string label,
    rdma_cmq_engine engine
  );
    if (engine.state() != RDMA_CMQ_ENGINE_UNCONFIGURED)
      `uvm_error(label, "engine did not remain UNCONFIGURED")
    if (engine.mapping_snapshot() != null)
      `uvm_error(label, "unconfigured engine retained a mapping")
  endfunction

  task automatic prepare_defaults(
    string label,
    rdma_cmq_engine engine,
    rdma_mock_host_mem mem,
    rdma_function_binding binding,
    rdma_cmq cmq,
    rdma_doorbell_scheduler scheduler,
    rdma_cmq_test_profile profile,
    output rdma_cmq_runtime_desc runtime_desc
  );
    rdma_status status;

    engine.prepare(binding, cmq, 1'b1, 20'h34567, mem, scheduler,
                   profile, runtime_desc, status);
    expect_status(label, status, RDMA_SC_OK);
  endtask

  task automatic check_success_and_detachment();
    rdma_cmq_engine engine;
    rdma_mock_host_mem mem;
    rdma_doorbell_scheduler scheduler;
    rdma_cmq_test_profile profile;
    rdma_function_binding prepared_binding;
    rdma_function_binding active_binding;
    rdma_cmq cmq;
    rdma_cmq_runtime_desc runtime_desc;
    rdma_dma_mapping first_snapshot;
    rdma_dma_mapping second_snapshot;
    rdma_status status;

    engine = rdma_cmq_engine::type_id::create("success_engine");
    mem = rdma_mock_host_mem::type_id::create("success_mem");
    scheduler = rdma_doorbell_scheduler::type_id::create(
      "success_scheduler"
    );
    profile = rdma_cmq_test_profile::type_id::create("success_profile");
    prepared_binding = make_binding("prepared_binding", RDMA_BIND_PREPARED);
    active_binding = make_binding("active_binding", RDMA_BIND_ACTIVE);
    cmq = make_cmq("success_cmq", prepared_binding);

    if (engine.state() != RDMA_CMQ_ENGINE_UNCONFIGURED ||
        engine.published_count() != 0 || engine.retired_count() != 0 ||
        engine.cq_consumed_count() != 0 ||
        engine.mapping_snapshot() != null)
      `uvm_error("CMQ_INITIAL_STATE", "new engine state is not empty")

    engine.prepare(prepared_binding, cmq, 1'b1, 20'h34567,
                   mem, scheduler, profile, runtime_desc, status);
    expect_status("PREPARE", status, RDMA_SC_OK);
    if (engine.state() != RDMA_CMQ_ENGINE_PREPARED)
      `uvm_error("PREPARE_STATE", "prepare did not enter PREPARED")
    if (runtime_desc == null)
      `uvm_error("PREPARE_RUNTIME", "prepare returned no runtime descriptor")
    else begin
      expect_status("PREPARE_RUNTIME_VALIDATE", runtime_desc.validate(),
                    RDMA_SC_OK);
      if (runtime_desc.sq_iova.value !=
            mem.regions[0].mapping.iova.value ||
          runtime_desc.cq_iova.value !=
            mem.regions[0].mapping.iova.value + 64'd2048)
        `uvm_error("CMQ_LAYOUT", "runtime IOVA layout is incorrect")
      if (runtime_desc.sq_depth != 32 || runtime_desc.cq_depth != 32 ||
          runtime_desc.entry_bytes != 64 ||
          !runtime_desc.initial_sq_valid ||
          !runtime_desc.initial_cq_owner ||
          runtime_desc.initial_doorbell_polarity)
        `uvm_error("CMQ_RUNTIME_INIT",
                   "runtime descriptor initialization is incorrect")
      if (runtime_desc.function_h == prepared_binding.owner_h ||
          runtime_desc.cmq_h == cmq.handle)
        `uvm_error("CMQ_RUNTIME_DETACH",
                   "runtime descriptor aliases caller authority")
    end

    if (mem.calls.size() != 2 ||
        count_host_calls(mem, "allocate") != 1 ||
        count_host_calls(mem, "write") != 1 ||
        mem.calls[0].size != 4096 || mem.calls[0].alignment != 4096 ||
        mem.calls[0].direction != RDMA_DMA_BIDIRECTIONAL ||
        mem.calls[0].request_context == null ||
        mem.calls[0].request_context.function_h == null ||
        !mem.calls[0].request_context.function_h.same_instance(
          prepared_binding.make_handle()
        ) || mem.calls[0].request_context.requester_bdf == '0 ||
        mem.calls[0].request_context.requester_bdf !=
          prepared_binding.pcie.bdf ||
        !mem.calls[0].request_context.pasid_valid ||
        mem.calls[0].request_context.pasid != 20'h34567 ||
        mem.calls[0].request_context.owner_h == null ||
        !mem.calls[0].request_context.owner_h.same_instance(cmq.handle))
      `uvm_error("CMQ_ALLOCATE",
                 "prepare allocation request/context is incorrect")
    if (mem.calls.size() >= 2 &&
        (mem.calls[1].method_name != "write" ||
         mem.calls[1].offset != 0 || mem.calls[1].data.size() != 4096))
      `uvm_error("CMQ_ZERO_WRITE", "prepare did not issue one 4096B write")
    if (mem.regions.size() != 1 || mem.regions[0].data.size() != 4096)
      `uvm_error("CMQ_ZERO_REGION", "prepare allocated wrong backing size")
    else begin
      foreach (mem.regions[0].data[i]) begin
        if (mem.regions[0].data[i] != 0)
          `uvm_error("CMQ_ZERO_REGION",
                     $sformatf("backing byte %0d was not zero", i))
      end
    end

    first_snapshot = engine.mapping_snapshot();
    second_snapshot = engine.mapping_snapshot();
    if (first_snapshot == null || second_snapshot == null ||
        first_snapshot == second_snapshot ||
        first_snapshot == mem.regions[0].mapping)
      `uvm_error("CMQ_MAPPING_SNAPSHOT",
                 "mapping query did not return detached snapshots")
    else begin
      first_snapshot.pasid = '0;
      if (second_snapshot.pasid != 20'h34567 ||
          engine.mapping_snapshot().pasid != 20'h34567)
        `uvm_error("CMQ_MAPPING_SNAPSHOT",
                   "mapping snapshot mutation reached engine authority")
    end
    if (engine.published_count() != 0 || engine.retired_count() != 0 ||
        engine.cq_consumed_count() != 0)
      `uvm_error("CMQ_PREPARE_COUNTS", "prepare changed ring counters")

    prepared_binding.function_uid = '0;
    prepared_binding.pcie.bdf = '0;
    cmq.handle.object_id = '0;
    cmq.depth = 64;
    if (runtime_desc != null) begin
      runtime_desc.sq_iova.value = '0;
      runtime_desc.function_h.generation = '0;
      runtime_desc.cmq_h.object_id = '0;
    end
    engine.activate(active_binding, status);
    expect_status("ACTIVATE_DETACHED_INPUTS", status, RDMA_SC_OK);
    if (engine.state() != RDMA_CMQ_ENGINE_ACTIVE)
      `uvm_error("ACTIVATE_STATE", "activate did not enter ACTIVE")
    engine.activate(active_binding, status);
    expect_status("ACTIVATE_ALREADY_ACTIVE", status,
                  RDMA_SC_INVALID_STATE);

    engine.shutdown(status);
    expect_status("SUCCESS_SHUTDOWN", status, RDMA_SC_OK);
    expect_unconfigured("SUCCESS_SHUTDOWN_STATE", engine);
    if (count_host_calls(mem, "release") != 1)
      `uvm_error("SUCCESS_SHUTDOWN_RELEASE",
                 "shutdown did not release backing exactly once")
    engine.shutdown(status);
    expect_status("SUCCESS_SHUTDOWN_IDEMPOTENT", status, RDMA_SC_OK);
    if (count_host_calls(mem, "release") != 1)
      `uvm_error("SUCCESS_SHUTDOWN_IDEMPOTENT",
                 "idempotent shutdown released backing again")
  endtask

  task automatic check_preallocation_rejections();
    rdma_cmq_engine engine;
    rdma_mock_host_mem mem;
    rdma_doorbell_scheduler scheduler;
    rdma_cmq_test_profile profile;
    rdma_function_binding binding;
    rdma_cmq cmq;
    rdma_cmq_runtime_desc runtime_desc;
    rdma_status status;

    scheduler = rdma_doorbell_scheduler::type_id::create("reject_scheduler");

    mem = rdma_mock_host_mem::type_id::create("null_binding_mem");
    profile = rdma_cmq_test_profile::type_id::create("null_binding_profile");
    binding = make_binding("null_binding_reference", RDMA_BIND_PREPARED);
    cmq = make_cmq("null_binding_cmq", binding);
    engine = rdma_cmq_engine::type_id::create("null_binding_engine");
    engine.prepare(null, cmq, 1'b0, '0, mem, scheduler, profile,
                   runtime_desc, status);
    expect_status("NULL_BINDING", status, RDMA_SC_INVALID_ARGUMENT);
    expect_unconfigured("NULL_BINDING_STATE", engine);

    mem = rdma_mock_host_mem::type_id::create("null_cmq_mem");
    binding = make_binding("null_cmq_binding", RDMA_BIND_PREPARED);
    engine = rdma_cmq_engine::type_id::create("null_cmq_engine");
    engine.prepare(binding, null, 1'b0, '0, mem, scheduler, profile,
                   runtime_desc, status);
    expect_status("NULL_CMQ", status, RDMA_SC_INVALID_ARGUMENT);
    expect_unconfigured("NULL_CMQ_STATE", engine);

    binding = make_binding("null_adapter_binding", RDMA_BIND_PREPARED);
    cmq = make_cmq("null_adapter_cmq", binding);
    engine = rdma_cmq_engine::type_id::create("null_adapter_engine");
    engine.prepare(binding, cmq, 1'b0, '0, null, scheduler, profile,
                   runtime_desc, status);
    expect_status("NULL_HOST_MEM", status, RDMA_SC_INVALID_ARGUMENT);
    expect_unconfigured("NULL_HOST_MEM_STATE", engine);

    mem = rdma_mock_host_mem::type_id::create("null_scheduler_mem");
    engine = rdma_cmq_engine::type_id::create("null_scheduler_engine");
    engine.prepare(binding, cmq, 1'b0, '0, mem, null, profile,
                   runtime_desc, status);
    expect_status("NULL_SCHEDULER", status, RDMA_SC_INVALID_ARGUMENT);
    expect_unconfigured("NULL_SCHEDULER_STATE", engine);

    mem = rdma_mock_host_mem::type_id::create("null_profile_mem");
    engine = rdma_cmq_engine::type_id::create("null_profile_engine");
    engine.prepare(binding, cmq, 1'b0, '0, mem, scheduler, null,
                   runtime_desc, status);
    expect_status("NULL_PROFILE", status, RDMA_SC_INVALID_ARGUMENT);
    expect_unconfigured("NULL_PROFILE_STATE", engine);

    mem = rdma_mock_host_mem::type_id::create("wrong_lifecycle_mem");
    binding = make_binding("wrong_lifecycle_binding", RDMA_BIND_ACTIVE);
    cmq = make_cmq("wrong_lifecycle_cmq", binding);
    engine = rdma_cmq_engine::type_id::create("wrong_lifecycle_engine");
    engine.prepare(binding, cmq, 1'b0, '0, mem, scheduler, profile,
                   runtime_desc, status);
    expect_status("BINDING_NOT_PREPARED", status, RDMA_SC_INVALID_STATE);
    expect_unconfigured("BINDING_NOT_PREPARED_STATE", engine);

    mem = rdma_mock_host_mem::type_id::create("invalid_binding_mem");
    binding = make_binding("invalid_binding", RDMA_BIND_PREPARED);
    binding.pcie = null;
    cmq = make_cmq("invalid_binding_cmq", binding);
    engine = rdma_cmq_engine::type_id::create("invalid_binding_engine");
    engine.prepare(binding, cmq, 1'b0, '0, mem, scheduler, profile,
                   runtime_desc, status);
    expect_status("INVALID_BINDING", status, RDMA_SC_INVALID_STATE);
    expect_unconfigured("INVALID_BINDING_STATE", engine);

    mem = rdma_mock_host_mem::type_id::create("binding_owner_mem");
    binding = make_binding("binding_owner_binding", RDMA_BIND_PREPARED);
    binding.owner_h.object_id++;
    cmq = make_cmq("binding_owner_cmq", binding);
    engine = rdma_cmq_engine::type_id::create("binding_owner_engine");
    engine.prepare(binding, cmq, 1'b0, '0, mem, scheduler, profile,
                   runtime_desc, status);
    expect_status("BINDING_OWNER", status, RDMA_SC_INVALID_STATE);
    expect_unconfigured("BINDING_OWNER_STATE", engine);

    mem = rdma_mock_host_mem::type_id::create("cmq_depth_mem");
    binding = make_binding("cmq_depth_binding", RDMA_BIND_PREPARED);
    cmq = make_cmq("cmq_depth_cmq", binding, 64);
    engine = rdma_cmq_engine::type_id::create("cmq_depth_engine");
    engine.prepare(binding, cmq, 1'b0, '0, mem, scheduler, profile,
                   runtime_desc, status);
    expect_status("CMQ_DEPTH", status, RDMA_SC_INVALID_ARGUMENT);
    expect_unconfigured("CMQ_DEPTH_STATE", engine);

    mem = rdma_mock_host_mem::type_id::create("cmq_handle_mem");
    cmq = make_cmq("cmq_handle_cmq", binding);
    cmq.handle = null;
    engine = rdma_cmq_engine::type_id::create("cmq_handle_engine");
    engine.prepare(binding, cmq, 1'b0, '0, mem, scheduler, profile,
                   runtime_desc, status);
    expect_status("CMQ_HANDLE", status, RDMA_SC_INVALID_ARGUMENT);
    expect_unconfigured("CMQ_HANDLE_STATE", engine);

    mem = rdma_mock_host_mem::type_id::create("cmq_owner_mem");
    cmq = make_cmq("cmq_owner_cmq", binding);
    cmq.owner = null;
    engine = rdma_cmq_engine::type_id::create("cmq_owner_engine");
    engine.prepare(binding, cmq, 1'b0, '0, mem, scheduler, profile,
                   runtime_desc, status);
    expect_status("CMQ_OWNER", status, RDMA_SC_INVALID_ARGUMENT);
    expect_unconfigured("CMQ_OWNER_STATE", engine);

    mem = rdma_mock_host_mem::type_id::create("cmq_state_mem");
    cmq = make_cmq("cmq_state_cmq", binding);
    cmq.state = RDMA_RESOURCE_RELEASED;
    engine = rdma_cmq_engine::type_id::create("cmq_state_engine");
    engine.prepare(binding, cmq, 1'b0, '0, mem, scheduler, profile,
                   runtime_desc, status);
    expect_status("CMQ_LIFECYCLE", status, RDMA_SC_INVALID_STATE);
    expect_unconfigured("CMQ_LIFECYCLE_STATE", engine);

    mem = rdma_mock_host_mem::type_id::create("profile_failure_mem");
    profile = rdma_cmq_test_profile::type_id::create("failure_profile");
    profile.fail_validation = 1'b1;
    cmq = make_cmq("profile_failure_cmq", binding);
    engine = rdma_cmq_engine::type_id::create("profile_failure_engine");
    engine.prepare(binding, cmq, 1'b0, '0, mem, scheduler, profile,
                   runtime_desc, status);
    expect_status("PROFILE_FAILURE", status, RDMA_SC_INVALID_STATE);
    if (profile.validation_calls != 1 || mem.calls.size() != 0)
      `uvm_error("PROFILE_BEFORE_ALLOCATE",
                 "profile failure did not precede allocation")
    expect_unconfigured("PROFILE_FAILURE_STATE", engine);
  endtask

  task automatic check_pasid_normalization_and_busy_prepare();
    rdma_cmq_engine engine;
    rdma_mock_host_mem mem;
    rdma_doorbell_scheduler scheduler;
    rdma_cmq_test_profile profile;
    rdma_function_binding binding;
    rdma_cmq cmq;
    rdma_cmq_runtime_desc runtime_desc;
    rdma_status status;
    int unsigned calls_before;

    engine = rdma_cmq_engine::type_id::create("pasid_engine");
    mem = rdma_mock_host_mem::type_id::create("pasid_mem");
    scheduler = rdma_doorbell_scheduler::type_id::create("pasid_scheduler");
    profile = rdma_cmq_test_profile::type_id::create("pasid_profile");
    binding = make_binding("pasid_binding", RDMA_BIND_PREPARED);
    cmq = make_cmq("pasid_cmq", binding);
    engine.prepare(binding, cmq, 1'b0, 20'hfffff, mem, scheduler,
                   profile, runtime_desc, status);
    expect_status("PASID_NORMALIZE", status, RDMA_SC_OK);
    if (mem.calls[0].request_context.pasid_valid ||
        mem.calls[0].request_context.pasid != 0 ||
        mem.regions[0].mapping.pasid_valid ||
        mem.regions[0].mapping.pasid != 0)
      `uvm_error("PASID_NORMALIZE",
                 "invalid PASID was not normalized to zero")

    calls_before = mem.calls.size();
    engine.prepare(binding, cmq, 1'b0, '0, mem, scheduler, profile,
                   runtime_desc, status);
    expect_status("PREPARE_ALREADY_PREPARED", status,
                  RDMA_SC_INVALID_STATE);
    if (runtime_desc != null || mem.calls.size() != calls_before)
      `uvm_error("PREPARE_ALREADY_PREPARED",
                 "busy prepare changed outputs or host memory")
    engine.shutdown(status);
    expect_status("PASID_SHUTDOWN", status, RDMA_SC_OK);
  endtask

  task automatic check_allocation_and_rollback_failures();
    rdma_cmq_engine engine;
    rdma_cmq_runtime_clone_failure_engine clone_failure_engine;
    rdma_mock_host_mem mem;
    rdma_cmq_short_mapping_mem short_mem;
    rdma_doorbell_scheduler scheduler;
    rdma_cmq_test_profile profile;
    rdma_function_binding binding;
    rdma_cmq cmq;
    rdma_cmq_runtime_desc runtime_desc;
    rdma_status status;

    scheduler = rdma_doorbell_scheduler::type_id::create(
      "rollback_scheduler"
    );
    profile = rdma_cmq_test_profile::type_id::create("rollback_profile");
    binding = make_binding("rollback_binding", RDMA_BIND_PREPARED);
    cmq = make_cmq("rollback_cmq", binding);

    mem = rdma_mock_host_mem::type_id::create("allocate_failure_mem");
    expect_status("ARM_ALLOCATE_FAILURE",
                  mem.fail_next("allocate", rdma_status::make(
                    RDMA_SC_RESOURCE_EXHAUSTED, "injected allocate failure"
                  )), RDMA_SC_OK);
    engine = rdma_cmq_engine::type_id::create("allocate_failure_engine");
    engine.prepare(binding, cmq, 1'b1, 20'h34567, mem, scheduler,
                   profile, runtime_desc, status);
    expect_status("ALLOCATE_FAILURE", status, RDMA_SC_RESOURCE_EXHAUSTED);
    if (count_host_calls(mem, "allocate") != 1 ||
        count_host_calls(mem, "write") != 0 ||
        count_host_calls(mem, "release") != 0)
      `uvm_error("ALLOCATE_FAILURE_CALLS",
                 "allocate failure performed later host operations")
    expect_unconfigured("ALLOCATE_FAILURE_STATE", engine);

    short_mem = rdma_cmq_short_mapping_mem::type_id::create("short_mem");
    engine = rdma_cmq_engine::type_id::create("short_mapping_engine");
    engine.prepare(binding, cmq, 1'b1, 20'h34567, short_mem, scheduler,
                   profile, runtime_desc, status);
    expect_status("SHORT_MAPPING", status, RDMA_SC_INVALID_STATE);
    if (count_host_calls(short_mem, "allocate") != 1 ||
        count_host_calls(short_mem, "write") != 0 ||
        count_host_calls(short_mem, "release") != 1)
      `uvm_error("SHORT_MAPPING_ROLLBACK",
                 "invalid mapping was not released exactly once")
    expect_unconfigured("SHORT_MAPPING_STATE", engine);

    mem = rdma_mock_host_mem::type_id::create("write_failure_mem");
    expect_status("ARM_WRITE_FAILURE",
                  mem.fail_next("write", rdma_status::make(
                    RDMA_SC_DMA_TRANSLATION, "injected zero write failure"
                  )), RDMA_SC_OK);
    engine = rdma_cmq_engine::type_id::create("write_failure_engine");
    engine.prepare(binding, cmq, 1'b1, 20'h34567, mem, scheduler,
                   profile, runtime_desc, status);
    expect_status("ZERO_WRITE_FAILURE", status, RDMA_SC_DMA_TRANSLATION);
    if (count_host_calls(mem, "allocate") != 1 ||
        count_host_calls(mem, "write") != 1 ||
        count_host_calls(mem, "release") != 1)
      `uvm_error("ZERO_WRITE_ROLLBACK",
                 "zero-write failure did not release exactly once")
    expect_unconfigured("ZERO_WRITE_FAILURE_STATE", engine);

    mem = rdma_mock_host_mem::type_id::create("clone_failure_mem");
    clone_failure_engine =
      rdma_cmq_runtime_clone_failure_engine::type_id::create(
        "clone_failure_engine"
      );
    clone_failure_engine.prepare(binding, cmq, 1'b1, 20'h34567,
                                 mem, scheduler, profile,
                                 runtime_desc, status);
    expect_status("RUNTIME_CLONE_FAILURE", status, RDMA_SC_INVALID_STATE);
    if (count_host_calls(mem, "allocate") != 1 ||
        count_host_calls(mem, "write") != 1 ||
        count_host_calls(mem, "release") != 1)
      `uvm_error("RUNTIME_CLONE_ROLLBACK",
                 "runtime clone failure did not release exactly once")
    expect_unconfigured("RUNTIME_CLONE_FAILURE_STATE",
                        clone_failure_engine);

    mem = rdma_mock_host_mem::type_id::create("release_failure_mem");
    expect_status("ARM_RELEASE_WRITE_FAILURE",
                  mem.fail_next("write", rdma_status::make(
                    RDMA_SC_DMA_TRANSLATION, "rollback trigger"
                  )), RDMA_SC_OK);
    expect_status("ARM_RELEASE_FAILURE",
                  mem.fail_next("release", rdma_status::make(
                    RDMA_SC_UNKNOWN_HW_ERROR,
                    "injected rollback release failure"
                  )), RDMA_SC_OK);
    engine = rdma_cmq_engine::type_id::create("release_failure_engine");
    engine.prepare(binding, cmq, 1'b1, 20'h34567, mem, scheduler,
                   profile, runtime_desc, status);
    expect_status("ROLLBACK_RELEASE_FAILURE", status,
                  RDMA_SC_UNKNOWN_HW_ERROR);
    if (engine.state() != RDMA_CMQ_ENGINE_POISONED ||
        engine.mapping_snapshot() == null ||
        count_host_calls(mem, "release") != 1)
      `uvm_error("ROLLBACK_RELEASE_AUTHORITY",
                 "failed rollback did not retain POISONED authority")
    engine.shutdown(status);
    expect_status("ROLLBACK_RELEASE_RETRY", status, RDMA_SC_OK);
    expect_unconfigured("ROLLBACK_RELEASE_RETRY_STATE", engine);
    if (count_host_calls(mem, "release") != 2)
      `uvm_error("ROLLBACK_RELEASE_RETRY",
                 "shutdown did not retry the retained release once")
  endtask

  task automatic check_activation_guards();
    rdma_cmq_engine_probe engine;
    rdma_mock_host_mem mem;
    rdma_doorbell_scheduler scheduler;
    rdma_cmq_test_profile profile;
    rdma_function_binding prepared_binding;
    rdma_function_binding active_binding;
    rdma_function_binding candidate;
    rdma_cmq cmq;
    rdma_cmq_runtime_desc runtime_desc;
    rdma_dma_mapping good_mapping;
    rdma_status status;
    rdma_status_code_e expected_codes[10] = '{
      RDMA_SC_DMA_TRANSLATION, RDMA_SC_DMA_TRANSLATION,
      RDMA_SC_STALE_GENERATION, RDMA_SC_DMA_TRANSLATION,
      RDMA_SC_DMA_PERMISSION, RDMA_SC_DMA_PERMISSION,
      RDMA_SC_DMA_TRANSLATION, RDMA_SC_INVALID_STATE,
      RDMA_SC_INVALID_STATE, RDMA_SC_INVALID_STATE
    };

    engine = rdma_cmq_engine_probe::type_id::create("activate_engine");
    mem = rdma_mock_host_mem::type_id::create("activate_mem");
    scheduler = rdma_doorbell_scheduler::type_id::create(
      "activate_scheduler"
    );
    profile = rdma_cmq_test_profile::type_id::create("activate_profile");
    prepared_binding = make_binding("activate_prepared",
                                    RDMA_BIND_PREPARED);
    active_binding = make_binding("activate_active", RDMA_BIND_ACTIVE);
    cmq = make_cmq("activate_cmq", prepared_binding);
    prepare_defaults("ACTIVATE_PREPARE", engine, mem, prepared_binding,
                     cmq, scheduler, profile, runtime_desc);

    candidate = make_binding("not_active_candidate", RDMA_BIND_PREPARED);
    engine.activate(candidate, status);
    expect_status("ACTIVATE_NOT_ACTIVE", status, RDMA_SC_INVALID_STATE);

    candidate = make_binding("uid_candidate", RDMA_BIND_ACTIVE);
    candidate.function_uid++;
    candidate.owner_h = candidate.make_handle();
    engine.activate(candidate, status);
    expect_status("ACTIVATE_UID", status, RDMA_SC_INVALID_ARGUMENT);

    candidate = make_binding("object_candidate", RDMA_BIND_ACTIVE);
    candidate.global_function_id++;
    candidate.owner_h = candidate.make_handle();
    engine.activate(candidate, status);
    expect_status("ACTIVATE_OBJECT", status, RDMA_SC_INVALID_ARGUMENT);

    candidate = make_binding("generation_candidate", RDMA_BIND_ACTIVE);
    candidate.generation++;
    candidate.owner_h = candidate.make_handle();
    engine.activate(candidate, status);
    expect_status("ACTIVATE_GENERATION", status,
                  RDMA_SC_STALE_GENERATION);

    candidate = make_binding("bdf_candidate", RDMA_BIND_ACTIVE);
    candidate.pcie.bdf.bus++;
    engine.activate(candidate, status);
    expect_status("ACTIVATE_BDF", status, RDMA_SC_DMA_TRANSLATION);

    good_mapping = engine.mapping_snapshot();
    for (int unsigned kind = 0; kind < 10; kind++) begin
      engine.tamper_mapping(kind);
      engine.activate(active_binding, status);
      expect_status($sformatf("ACTIVATE_MAPPING_%0d", kind), status,
                    expected_codes[kind]);
      if (engine.state() != RDMA_CMQ_ENGINE_PREPARED ||
          engine.published_count() != 0 || engine.retired_count() != 0 ||
          engine.cq_consumed_count() != 0)
        `uvm_error("ACTIVATE_MAPPING_ATOMIC",
                   "failed activate changed state or counters")
      engine.restore_mapping(good_mapping);
    end

    engine.activate(active_binding, status);
    expect_status("ACTIVATE_SUCCESS", status, RDMA_SC_OK);
    if (engine.state() != RDMA_CMQ_ENGINE_ACTIVE)
      `uvm_error("ACTIVATE_SUCCESS_STATE",
                 "matching ACTIVE binding was not committed")
    engine.shutdown(status);
    expect_status("ACTIVATE_SHUTDOWN", status, RDMA_SC_OK);
  endtask

  virtual task run_phase(uvm_phase phase);
    phase.raise_objection(this);
    check_success_and_detachment();
    check_preallocation_rejections();
    check_pasid_normalization_and_busy_prepare();
    check_allocation_and_rollback_failures();
    check_activation_guards();
    phase.drop_objection(this);
  endtask
endclass
