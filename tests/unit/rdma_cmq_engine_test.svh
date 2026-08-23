class rdma_cmq_test_profile extends rdma_cmq_hw_profile;
  `uvm_object_utils(rdma_cmq_test_profile)

  localparam bit [31:0] TEST_OPCODE = 32'hcafe_0001;

  bit fail_validation;
  bit return_null_status;
  int unsigned validation_calls;

  function new(string name = "rdma_cmq_test_profile");
    super.new(name);
    fail_validation = 1'b0;
    return_null_status = 1'b0;
    validation_calls = 0;
  endfunction

  virtual function string profile_name();
    return "cmq_engine_test";
  endfunction

  virtual function rdma_status validate_profile();
    validation_calls++;
    if (return_null_status)
      return null;
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

class rdma_cmq_runtime_build_failure_engine extends rdma_cmq_engine;
  `uvm_object_utils(rdma_cmq_runtime_build_failure_engine)

  bit return_null_status;

  function new(string name = "rdma_cmq_runtime_build_failure_engine");
    super.new(name);
    return_null_status = 1'b0;
  endfunction

  virtual function rdma_status build_runtime_desc(
    rdma_dma_request_context request_context,
    rdma_cmq cmq,
    rdma_dma_mapping mapping,
    output rdma_cmq_runtime_desc runtime
  );
    runtime = null;
    if (return_null_status)
      return null;
    return rdma_status::make(RDMA_SC_CODEC_ERROR,
                             "injected runtime construction failure");
  endfunction
endclass

typedef enum int unsigned {
  RDMA_CMQ_TAMPER_FUNCTION_KIND,
  RDMA_CMQ_TAMPER_FUNCTION_UID,
  RDMA_CMQ_TAMPER_FUNCTION_OBJECT,
  RDMA_CMQ_TAMPER_FUNCTION_GENERATION,
  RDMA_CMQ_TAMPER_BDF,
  RDMA_CMQ_TAMPER_PASID_VALID,
  RDMA_CMQ_TAMPER_PASID,
  RDMA_CMQ_TAMPER_OWNER_NULL,
  RDMA_CMQ_TAMPER_OWNER_KIND,
  RDMA_CMQ_TAMPER_OWNER_UID,
  RDMA_CMQ_TAMPER_OWNER_OBJECT,
  RDMA_CMQ_TAMPER_OWNER_GENERATION,
  RDMA_CMQ_TAMPER_DIRECTION,
  RDMA_CMQ_TAMPER_STATE,
  RDMA_CMQ_TAMPER_SIZE,
  RDMA_CMQ_TAMPER_PERMISSION_READ,
  RDMA_CMQ_TAMPER_PERMISSION_WRITE,
  RDMA_CMQ_TAMPER_IOVA_ALIGNMENT,
  RDMA_CMQ_TAMPER_BACKING_ALIGNMENT,
  RDMA_CMQ_TAMPER_IOVA_RANGE,
  RDMA_CMQ_TAMPER_BACKING_RANGE,
  RDMA_CMQ_TAMPER_PERMISSION_ATOMIC,
  RDMA_CMQ_TAMPER_COUNT
} rdma_cmq_mapping_tamper_e;

class rdma_cmq_engine_probe extends rdma_cmq_engine;
  `uvm_object_utils(rdma_cmq_engine_probe)

  function new(string name = "rdma_cmq_engine_probe");
    super.new(name);
  endfunction

  function void restore_mapping(rdma_dma_mapping source);
    if (backing_mapping != null && source != null)
      backing_mapping.copy(source);
  endfunction

  function void seed_runtime_counters();
    publish_seq = 11;
    retire_seq = 7;
    cq_consume_seq = 5;
  endfunction

  function bit retry_only_poisoned();
    return engine_state == RDMA_CMQ_ENGINE_POISONED &&
           host_mem != null && backing_mapping != null &&
           prepared_binding == null && dma_context == null &&
           cmq_snapshot == null && scheduler == null && profile == null &&
           publish_seq == 0 && retire_seq == 0 && cq_consume_seq == 0;
  endfunction

  function void drop_host_mem_authority();
    host_mem = null;
  endfunction

  function void restore_host_mem_authority(rdma_host_mem_api source);
    host_mem = source;
  endfunction

  function bit missing_host_mem_poisoned();
    return engine_state == RDMA_CMQ_ENGINE_POISONED &&
           host_mem == null && backing_mapping != null &&
           prepared_binding == null && dma_context == null &&
           cmq_snapshot == null && scheduler == null && profile == null &&
           publish_seq == 0 && retire_seq == 0 && cq_consume_seq == 0;
  endfunction

  function void tamper_mapping(rdma_cmq_mapping_tamper_e kind);
    if (backing_mapping == null)
      return;
    case (kind)
      RDMA_CMQ_TAMPER_FUNCTION_KIND:
        backing_mapping.function_h.kind = RDMA_RESOURCE_QP;
      RDMA_CMQ_TAMPER_FUNCTION_UID:
        backing_mapping.function_h.function_uid++;
      RDMA_CMQ_TAMPER_FUNCTION_OBJECT:
        backing_mapping.function_h.object_id++;
      RDMA_CMQ_TAMPER_FUNCTION_GENERATION:
        backing_mapping.function_h.generation++;
      RDMA_CMQ_TAMPER_BDF:
        backing_mapping.requester_bdf.bus++;
      RDMA_CMQ_TAMPER_PASID_VALID:
        backing_mapping.pasid_valid = !backing_mapping.pasid_valid;
      RDMA_CMQ_TAMPER_PASID:
        backing_mapping.pasid++;
      RDMA_CMQ_TAMPER_OWNER_NULL:
        backing_mapping.owner_h = null;
      RDMA_CMQ_TAMPER_OWNER_KIND:
        backing_mapping.owner_h.kind = RDMA_RESOURCE_CQ;
      RDMA_CMQ_TAMPER_OWNER_UID:
        backing_mapping.owner_h.function_uid++;
      RDMA_CMQ_TAMPER_OWNER_OBJECT:
        backing_mapping.owner_h.object_id++;
      RDMA_CMQ_TAMPER_OWNER_GENERATION:
        backing_mapping.owner_h.generation++;
      RDMA_CMQ_TAMPER_DIRECTION:
        backing_mapping.direction = RDMA_DMA_DEVICE_READ;
      RDMA_CMQ_TAMPER_STATE:
        backing_mapping.state = RDMA_MAPPING_FROZEN;
      RDMA_CMQ_TAMPER_SIZE:
        backing_mapping.size--;
      RDMA_CMQ_TAMPER_PERMISSION_READ:
        backing_mapping.permissions.device_read = 1'b0;
      RDMA_CMQ_TAMPER_PERMISSION_WRITE:
        backing_mapping.permissions.device_write = 1'b0;
      RDMA_CMQ_TAMPER_IOVA_ALIGNMENT:
        backing_mapping.iova.value++;
      RDMA_CMQ_TAMPER_BACKING_ALIGNMENT:
        backing_mapping.backing_addr.value++;
      RDMA_CMQ_TAMPER_IOVA_RANGE:
        backing_mapping.iova.value = 64'hffff_ffff_ffff_f800;
      RDMA_CMQ_TAMPER_BACKING_RANGE:
        backing_mapping.backing_addr.value = 64'hffff_ffff_ffff_f800;
      RDMA_CMQ_TAMPER_PERMISSION_ATOMIC:
        backing_mapping.permissions.atomic = 1'b1;
      default: return;
    endcase
  endfunction
endclass

typedef enum int unsigned {
  RDMA_CMQ_BAD_MAPPING_ATOMIC,
  RDMA_CMQ_BAD_MAPPING_IOVA_ALIGNMENT,
  RDMA_CMQ_BAD_MAPPING_BACKING_ALIGNMENT,
  RDMA_CMQ_BAD_MAPPING_IOVA_RANGE,
  RDMA_CMQ_BAD_MAPPING_BACKING_RANGE
} rdma_cmq_bad_mapping_kind_e;

class rdma_cmq_bad_mapping_mem extends rdma_mock_host_mem;
  `uvm_object_utils(rdma_cmq_bad_mapping_mem)

  rdma_cmq_bad_mapping_kind_e bad_kind;

  function new(string name = "rdma_cmq_bad_mapping_mem");
    super.new(name);
    bad_kind = RDMA_CMQ_BAD_MAPPING_ATOMIC;
  endfunction

  virtual function rdma_status allocate(
    rdma_dma_request_context request_context,
    int unsigned size,
    int unsigned alignment,
    rdma_dma_direction_e direction,
    output rdma_dma_mapping mapping
  );
    rdma_status status;
    int region_index;

    status = super.allocate(request_context, size, alignment, direction,
                            mapping);
    if (!status.ok() || mapping == null)
      return status;
    region_index = regions.size() - 1;
    case (bad_kind)
      RDMA_CMQ_BAD_MAPPING_ATOMIC: begin
        mapping.permissions.atomic = 1'b1;
        regions[region_index].mapping.permissions.atomic = 1'b1;
      end
      RDMA_CMQ_BAD_MAPPING_IOVA_ALIGNMENT: begin
        mapping.iova.value++;
        regions[region_index].mapping.iova.value++;
      end
      RDMA_CMQ_BAD_MAPPING_BACKING_ALIGNMENT: begin
        mapping.backing_addr.value++;
        regions[region_index].mapping.backing_addr.value++;
      end
      RDMA_CMQ_BAD_MAPPING_IOVA_RANGE: begin
        mapping.iova.value = 64'hffff_ffff_ffff_f800;
        regions[region_index].mapping.iova.value = mapping.iova.value;
      end
      RDMA_CMQ_BAD_MAPPING_BACKING_RANGE: begin
        mapping.backing_addr.value = 64'hffff_ffff_ffff_f800;
        regions[region_index].mapping.backing_addr.value =
          mapping.backing_addr.value;
      end
    endcase
    return status;
  endfunction
endclass

class rdma_cmq_upper_boundary_mem extends rdma_mock_host_mem;
  `uvm_object_utils(rdma_cmq_upper_boundary_mem)

  function new(string name = "rdma_cmq_upper_boundary_mem");
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
    int region_index;

    status = super.allocate(request_context, size, alignment, direction,
                            mapping);
    if (!status.ok() || mapping == null)
      return status;
    region_index = regions.size() - 1;
    mapping.iova.value = 64'hffff_ffff_ffff_f000;
    mapping.backing_addr.value = 64'hffff_ffff_ffff_f000;
    regions[region_index].mapping.iova = mapping.iova;
    regions[region_index].mapping.backing_addr = mapping.backing_addr;
    return status;
  endfunction
endclass

typedef enum int unsigned {
  RDMA_CMQ_ALLOCATE_NULL_NO_CANDIDATE,
  RDMA_CMQ_ALLOCATE_NULL_WITH_CANDIDATE,
  RDMA_CMQ_ALLOCATE_FAILURE_WITH_CANDIDATE
} rdma_cmq_allocate_result_e;

class rdma_cmq_allocate_result_mem extends rdma_mock_host_mem;
  `uvm_object_utils(rdma_cmq_allocate_result_mem)

  rdma_cmq_allocate_result_e result_kind;

  function new(string name = "rdma_cmq_allocate_result_mem");
    super.new(name);
    result_kind = RDMA_CMQ_ALLOCATE_NULL_NO_CANDIDATE;
  endfunction

  virtual function rdma_status allocate(
    rdma_dma_request_context request_context,
    int unsigned size,
    int unsigned alignment,
    rdma_dma_direction_e direction,
    output rdma_dma_mapping mapping
  );
    rdma_status status;

    if (result_kind == RDMA_CMQ_ALLOCATE_NULL_NO_CANDIDATE) begin
      mapping = null;
      record_call("allocate", request_context, null, size, alignment,
                  direction);
      return null;
    end
    status = super.allocate(request_context, size, alignment, direction,
                            mapping);
    if (!status.ok() || mapping == null)
      return status;
    if (result_kind == RDMA_CMQ_ALLOCATE_NULL_WITH_CANDIDATE)
      return null;
    return rdma_status::make(
      RDMA_SC_RESOURCE_EXHAUSTED,
      "injected allocation failure with candidate"
    );
  endfunction
endclass

class rdma_cmq_null_write_mem extends rdma_mock_host_mem;
  `uvm_object_utils(rdma_cmq_null_write_mem)

  function new(string name = "rdma_cmq_null_write_mem");
    super.new(name);
  endfunction

  virtual function rdma_status write(
    rdma_dma_mapping mapping,
    longint unsigned offset,
    byte data[]
  );
    rdma_status status;

    status = super.write(mapping, offset, data);
    if (!status.ok())
      return status;
    return null;
  endfunction
endclass

class rdma_cmq_null_release_once_mem extends rdma_mock_host_mem;
  `uvm_object_utils(rdma_cmq_null_release_once_mem)

  bit return_null_once;

  function new(string name = "rdma_cmq_null_release_once_mem");
    super.new(name);
    return_null_once = 1'b1;
  endfunction

  virtual function rdma_status \release (rdma_dma_mapping mapping);
    if (return_null_once) begin
      return_null_once = 1'b0;
      record_call("release", null, mapping);
      return null;
    end
    return super.\release (mapping);
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

  function automatic int host_call_index(
    rdma_mock_host_mem mem,
    string method_name,
    int unsigned ordinal
  );
    int unsigned match_count;

    match_count = 0;
    foreach (mem.calls[i]) begin
      if (mem.calls[i].method_name != method_name)
        continue;
      if (match_count == ordinal)
        return i;
      match_count++;
    end
    return -1;
  endfunction

  function automatic void expect_release_retry_identity(
    string label,
    rdma_mock_host_mem mem,
    rdma_mock_dma_mapping retained_mapping
  );
    int first_index;
    int second_index;
    rdma_mock_dma_mapping first_release_mapping;
    rdma_mock_dma_mapping second_release_mapping;

    first_index = host_call_index(mem, "release", 0);
    second_index = host_call_index(mem, "release", 1);
    if (first_index < 0 || second_index < 0) begin
      `uvm_error(label, "two release records were not available")
      return;
    end
    if (!$cast(first_release_mapping, mem.calls[first_index].mapping) ||
        !$cast(second_release_mapping, mem.calls[second_index].mapping)) begin
      `uvm_error(label, "release record lost allocation identity")
      return;
    end
    if (retained_mapping == null ||
        !first_release_mapping.same_allocation(second_release_mapping) ||
        !retained_mapping.same_allocation(second_release_mapping))
      `uvm_error(label, "release retry changed mapping allocation identity")
  endfunction

  function automatic bit same_nullable_handle(
    rdma_handle lhs,
    rdma_handle rhs
  );
    if (lhs == null || rhs == null)
      return lhs == null && rhs == null;
    return lhs.same_instance(rhs);
  endfunction

  function automatic bit same_mapping_fields(
    rdma_dma_mapping lhs,
    rdma_dma_mapping rhs
  );
    if (lhs == null || rhs == null)
      return lhs == null && rhs == null;
    return same_nullable_handle(lhs.function_h, rhs.function_h) &&
           lhs.requester_bdf == rhs.requester_bdf &&
           lhs.pasid_valid == rhs.pasid_valid && lhs.pasid == rhs.pasid &&
           lhs.backing_addr == rhs.backing_addr && lhs.iova == rhs.iova &&
           lhs.size == rhs.size && lhs.direction == rhs.direction &&
           lhs.permissions == rhs.permissions && lhs.state == rhs.state &&
           same_nullable_handle(lhs.owner_h, rhs.owner_h);
  endfunction

  function automatic void expect_post_allocate_rollback(
    string label,
    rdma_cmq_engine engine,
    rdma_mock_host_mem mem,
    rdma_cmq_runtime_desc runtime_desc,
    int unsigned expected_write_count
  );
    if (runtime_desc != null)
      `uvm_error(label, "failed prepare published a runtime descriptor")
    if (count_host_calls(mem, "allocate") != 1 ||
        count_host_calls(mem, "write") != expected_write_count ||
        count_host_calls(mem, "release") != 1)
      `uvm_error(label,
                 "post-allocation failure did not release exactly once")
    if (mem.regions.size() != 1 || mem.regions[0].mapping == null ||
        mem.regions[0].mapping.state != RDMA_MAPPING_RELEASED)
      `uvm_error(label, "post-allocation failure leaked its mock region")
    expect_unconfigured({label, "_STATE"}, engine);
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
    rdma_cmq_engine_probe release_failure_engine;
    rdma_cmq_runtime_clone_failure_engine clone_failure_engine;
    rdma_cmq_runtime_build_failure_engine build_failure_engine;
    rdma_mock_host_mem mem;
    rdma_cmq_short_mapping_mem short_mem;
    rdma_cmq_bad_mapping_mem bad_mem;
    rdma_cmq_upper_boundary_mem upper_boundary_mem;
    rdma_doorbell_scheduler scheduler;
    rdma_cmq_test_profile profile;
    rdma_function_binding binding;
    rdma_cmq cmq;
    rdma_cmq_runtime_desc runtime_desc;
    rdma_dma_mapping retained_snapshot;
    rdma_mock_dma_mapping retained_mock;
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

    for (int unsigned bad_kind = RDMA_CMQ_BAD_MAPPING_ATOMIC;
         bad_kind <= RDMA_CMQ_BAD_MAPPING_BACKING_RANGE; bad_kind++) begin
      bad_mem = rdma_cmq_bad_mapping_mem::type_id::create(
        $sformatf("bad_mapping_mem_%0d", bad_kind)
      );
      bad_mem.bad_kind = rdma_cmq_bad_mapping_kind_e'(bad_kind);
      engine = rdma_cmq_engine::type_id::create(
        $sformatf("bad_mapping_engine_%0d", bad_kind)
      );
      engine.prepare(binding, cmq, 1'b1, 20'h34567, bad_mem, scheduler,
                     profile, runtime_desc, status);
      if (bad_kind == RDMA_CMQ_BAD_MAPPING_ATOMIC)
        expect_status("ATOMIC_MAPPING_PREPARE", status,
                      RDMA_SC_DMA_PERMISSION);
      else
        expect_status($sformatf("BAD_MAPPING_PREPARE_%0d", bad_kind),
                      status, RDMA_SC_DMA_TRANSLATION);
      if (bad_kind inside {RDMA_CMQ_BAD_MAPPING_IOVA_RANGE,
                           RDMA_CMQ_BAD_MAPPING_BACKING_RANGE}) begin
        // A 4096-aligned 64-bit base cannot overflow a 4096-byte range.
        // The first address above the maximum legal aligned base is
        // necessarily unaligned, so fail closed at the alignment check.
        if (status == null ||
            status.message !=
              "CMQ backing mapping is not 4096-byte aligned")
          `uvm_error("BAD_MAPPING_UPPER_BOUND_STATUS",
                     "upper-bound fixture did not fail on alignment")
      end
      expect_post_allocate_rollback(
        $sformatf("BAD_MAPPING_ROLLBACK_%0d", bad_kind), engine,
        bad_mem, runtime_desc, 0
      );
    end

    upper_boundary_mem = rdma_cmq_upper_boundary_mem::type_id::create(
      "upper_boundary_mem"
    );
    engine = rdma_cmq_engine::type_id::create("upper_boundary_engine");
    engine.prepare(binding, cmq, 1'b1, 20'h34567,
                   upper_boundary_mem, scheduler, profile,
                   runtime_desc, status);
    expect_status("UPPER_BOUNDARY_PREPARE", status, RDMA_SC_OK);
    if (runtime_desc == null)
      `uvm_error("UPPER_BOUNDARY_RUNTIME",
                 "maximum legal aligned base published no runtime")
    else begin
      expect_status("UPPER_BOUNDARY_RUNTIME_VALIDATE",
                    runtime_desc.validate(), RDMA_SC_OK);
      if (runtime_desc.sq_iova.value != 64'hffff_ffff_ffff_f000 ||
          runtime_desc.cq_iova.value != 64'hffff_ffff_ffff_f800)
        `uvm_error("UPPER_BOUNDARY_LAYOUT",
                   "maximum legal aligned base produced wrong layout")
    end
    if (count_host_calls(upper_boundary_mem, "allocate") != 1 ||
        count_host_calls(upper_boundary_mem, "write") != 1 ||
        count_host_calls(upper_boundary_mem, "release") != 0)
      `uvm_error("UPPER_BOUNDARY_CALLS",
                 "maximum legal aligned base used wrong host operations")
    engine.shutdown(status);
    expect_status("UPPER_BOUNDARY_SHUTDOWN", status, RDMA_SC_OK);
    expect_unconfigured("UPPER_BOUNDARY_SHUTDOWN_STATE", engine);
    if (count_host_calls(upper_boundary_mem, "release") != 1)
      `uvm_error("UPPER_BOUNDARY_RELEASE",
                 "maximum legal aligned base was not released once")

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

    mem = rdma_mock_host_mem::type_id::create("build_failure_mem");
    build_failure_engine =
      rdma_cmq_runtime_build_failure_engine::type_id::create(
        "build_failure_engine"
      );
    build_failure_engine.prepare(binding, cmq, 1'b1, 20'h34567,
                                 mem, scheduler, profile,
                                 runtime_desc, status);
    expect_status("RUNTIME_BUILD_FAILURE", status, RDMA_SC_CODEC_ERROR);
    expect_post_allocate_rollback("RUNTIME_BUILD_ROLLBACK",
                                  build_failure_engine, mem,
                                  runtime_desc, 1);

    mem = rdma_mock_host_mem::type_id::create("build_null_status_mem");
    build_failure_engine =
      rdma_cmq_runtime_build_failure_engine::type_id::create(
        "build_null_status_engine"
      );
    build_failure_engine.return_null_status = 1'b1;
    build_failure_engine.prepare(binding, cmq, 1'b1, 20'h34567,
                                 mem, scheduler, profile,
                                 runtime_desc, status);
    expect_status("RUNTIME_BUILD_NULL_STATUS", status,
                  RDMA_SC_INVALID_STATE);
    expect_post_allocate_rollback("RUNTIME_BUILD_NULL_ROLLBACK",
                                  build_failure_engine, mem,
                                  runtime_desc, 1);

    mem = rdma_mock_host_mem::type_id::create("clone_failure_mem");
    clone_failure_engine =
      rdma_cmq_runtime_clone_failure_engine::type_id::create(
        "clone_failure_engine"
      );
    clone_failure_engine.prepare(binding, cmq, 1'b1, 20'h34567,
                                 mem, scheduler, profile,
                                 runtime_desc, status);
    expect_status("RUNTIME_CLONE_FAILURE", status, RDMA_SC_INVALID_STATE);
    expect_post_allocate_rollback("RUNTIME_CLONE_ROLLBACK",
                                  clone_failure_engine, mem,
                                  runtime_desc, 1);

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
    release_failure_engine = rdma_cmq_engine_probe::type_id::create(
      "release_failure_engine"
    );
    release_failure_engine.prepare(binding, cmq, 1'b1, 20'h34567, mem,
                                   scheduler, profile, runtime_desc,
                                   status);
    expect_status("ROLLBACK_RELEASE_FAILURE", status,
                  RDMA_SC_UNKNOWN_HW_ERROR);
    retained_snapshot = release_failure_engine.mapping_snapshot();
    if (status == null ||
        status.message !=
          {"CMQ prepare rollback release failed: ",
           "injected rollback release failure; original failure: ",
           "rollback trigger"} ||
        !release_failure_engine.retry_only_poisoned() ||
        retained_snapshot == null ||
        count_host_calls(mem, "release") != 1)
      `uvm_error("ROLLBACK_RELEASE_AUTHORITY",
                 "failed rollback did not retain POISONED authority")
    if (!$cast(retained_mock, retained_snapshot))
      `uvm_error("ROLLBACK_RELEASE_AUTHORITY",
                 "failed rollback lost allocation identity")
    release_failure_engine.shutdown(status);
    expect_status("ROLLBACK_RELEASE_RETRY", status, RDMA_SC_OK);
    expect_unconfigured("ROLLBACK_RELEASE_RETRY_STATE",
                        release_failure_engine);
    if (count_host_calls(mem, "release") != 2)
      `uvm_error("ROLLBACK_RELEASE_RETRY",
                 "shutdown did not retry the retained release once")
    expect_release_retry_identity("ROLLBACK_RELEASE_RETRY_IDENTITY", mem,
                                  retained_mock);
  endtask

  task automatic check_null_status_guards();
    rdma_cmq_engine engine;
    rdma_mock_host_mem mem;
    rdma_cmq_allocate_result_mem allocate_mem;
    rdma_cmq_null_write_mem null_write_mem;
    rdma_doorbell_scheduler scheduler;
    rdma_cmq_test_profile profile;
    rdma_function_binding binding;
    rdma_cmq cmq;
    rdma_cmq_runtime_desc runtime_desc;
    rdma_status status;

    scheduler = rdma_doorbell_scheduler::type_id::create(
      "null_status_scheduler"
    );
    binding = make_binding("null_status_binding", RDMA_BIND_PREPARED);
    cmq = make_cmq("null_status_cmq", binding);

    mem = rdma_mock_host_mem::type_id::create("null_profile_mem");
    profile = rdma_cmq_test_profile::type_id::create(
      "null_status_profile"
    );
    profile.return_null_status = 1'b1;
    engine = rdma_cmq_engine::type_id::create("null_profile_engine");
    engine.prepare(binding, cmq, 1'b1, 20'h34567, mem, scheduler,
                   profile, runtime_desc, status);
    expect_status("NULL_PROFILE_STATUS", status, RDMA_SC_INVALID_STATE);
    if (status == null ||
        status.message != "CMQ hardware profile returned null status" ||
        profile.validation_calls != 1 || runtime_desc != null ||
        mem.calls.size() != 0)
      `uvm_error("NULL_PROFILE_STATUS",
                 "null profile status did not fail before allocation")
    expect_unconfigured("NULL_PROFILE_STATUS_STATE", engine);

    profile = rdma_cmq_test_profile::type_id::create(
      "null_status_good_profile"
    );
    allocate_mem = rdma_cmq_allocate_result_mem::type_id::create(
      "null_allocate_no_candidate_mem"
    );
    allocate_mem.result_kind = RDMA_CMQ_ALLOCATE_NULL_NO_CANDIDATE;
    engine = rdma_cmq_engine::type_id::create(
      "null_allocate_no_candidate_engine"
    );
    engine.prepare(binding, cmq, 1'b1, 20'h34567, allocate_mem,
                   scheduler, profile, runtime_desc, status);
    expect_status("NULL_ALLOCATE_NO_CANDIDATE", status,
                  RDMA_SC_INVALID_STATE);
    if (status == null ||
        status.message != "CMQ host allocation returned null status" ||
        runtime_desc != null || allocate_mem.regions.size() != 0 ||
        count_host_calls(allocate_mem, "allocate") != 1 ||
        count_host_calls(allocate_mem, "write") != 0 ||
        count_host_calls(allocate_mem, "release") != 0)
      `uvm_error("NULL_ALLOCATE_NO_CANDIDATE",
                 "null allocation without candidate did not fail closed")
    expect_unconfigured("NULL_ALLOCATE_NO_CANDIDATE_STATE", engine);

    allocate_mem = rdma_cmq_allocate_result_mem::type_id::create(
      "null_allocate_candidate_mem"
    );
    allocate_mem.result_kind = RDMA_CMQ_ALLOCATE_NULL_WITH_CANDIDATE;
    engine = rdma_cmq_engine::type_id::create(
      "null_allocate_candidate_engine"
    );
    engine.prepare(binding, cmq, 1'b1, 20'h34567, allocate_mem,
                   scheduler, profile, runtime_desc, status);
    expect_status("NULL_ALLOCATE_WITH_CANDIDATE", status,
                  RDMA_SC_INVALID_STATE);
    if (status == null ||
        status.message != "CMQ host allocation returned null status")
      `uvm_error("NULL_ALLOCATE_WITH_CANDIDATE",
                 "null allocation candidate lost normalized status")
    expect_post_allocate_rollback("NULL_ALLOCATE_CANDIDATE_ROLLBACK",
                                  engine, allocate_mem, runtime_desc, 0);

    allocate_mem = rdma_cmq_allocate_result_mem::type_id::create(
      "failed_allocate_candidate_mem"
    );
    allocate_mem.result_kind = RDMA_CMQ_ALLOCATE_FAILURE_WITH_CANDIDATE;
    engine = rdma_cmq_engine::type_id::create(
      "failed_allocate_candidate_engine"
    );
    engine.prepare(binding, cmq, 1'b1, 20'h34567, allocate_mem,
                   scheduler, profile, runtime_desc, status);
    expect_status("FAILED_ALLOCATE_WITH_CANDIDATE", status,
                  RDMA_SC_RESOURCE_EXHAUSTED);
    if (status == null ||
        status.message != "injected allocation failure with candidate")
      `uvm_error("FAILED_ALLOCATE_WITH_CANDIDATE",
                 "allocation candidate failure lost adapter status")
    expect_post_allocate_rollback("FAILED_ALLOCATE_CANDIDATE_ROLLBACK",
                                  engine, allocate_mem, runtime_desc, 0);

    null_write_mem = rdma_cmq_null_write_mem::type_id::create(
      "null_write_mem"
    );
    engine = rdma_cmq_engine::type_id::create("null_write_engine");
    engine.prepare(binding, cmq, 1'b1, 20'h34567, null_write_mem,
                   scheduler, profile, runtime_desc, status);
    expect_status("NULL_WRITE_STATUS", status, RDMA_SC_INVALID_STATE);
    if (status == null ||
        status.message != "CMQ backing zero-write returned null status")
      `uvm_error("NULL_WRITE_STATUS",
                 "null write did not return normalized status")
    expect_post_allocate_rollback("NULL_WRITE_ROLLBACK", engine,
                                  null_write_mem, runtime_desc, 1);
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
    rdma_dma_mapping before_mapping;
    rdma_dma_mapping after_mapping;
    rdma_status status;
    rdma_status_code_e expected_codes[RDMA_CMQ_TAMPER_COUNT];

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

    expected_codes[RDMA_CMQ_TAMPER_FUNCTION_KIND] =
      RDMA_SC_DMA_TRANSLATION;
    expected_codes[RDMA_CMQ_TAMPER_FUNCTION_UID] =
      RDMA_SC_DMA_TRANSLATION;
    expected_codes[RDMA_CMQ_TAMPER_FUNCTION_OBJECT] =
      RDMA_SC_DMA_TRANSLATION;
    expected_codes[RDMA_CMQ_TAMPER_FUNCTION_GENERATION] =
      RDMA_SC_STALE_GENERATION;
    expected_codes[RDMA_CMQ_TAMPER_BDF] = RDMA_SC_DMA_TRANSLATION;
    expected_codes[RDMA_CMQ_TAMPER_PASID_VALID] = RDMA_SC_DMA_PERMISSION;
    expected_codes[RDMA_CMQ_TAMPER_PASID] = RDMA_SC_DMA_PERMISSION;
    expected_codes[RDMA_CMQ_TAMPER_OWNER_NULL] = RDMA_SC_DMA_TRANSLATION;
    expected_codes[RDMA_CMQ_TAMPER_OWNER_KIND] = RDMA_SC_DMA_TRANSLATION;
    expected_codes[RDMA_CMQ_TAMPER_OWNER_UID] = RDMA_SC_DMA_TRANSLATION;
    expected_codes[RDMA_CMQ_TAMPER_OWNER_OBJECT] =
      RDMA_SC_DMA_TRANSLATION;
    expected_codes[RDMA_CMQ_TAMPER_OWNER_GENERATION] =
      RDMA_SC_DMA_TRANSLATION;
    expected_codes[RDMA_CMQ_TAMPER_DIRECTION] = RDMA_SC_INVALID_STATE;
    expected_codes[RDMA_CMQ_TAMPER_STATE] = RDMA_SC_INVALID_STATE;
    expected_codes[RDMA_CMQ_TAMPER_SIZE] = RDMA_SC_INVALID_STATE;
    expected_codes[RDMA_CMQ_TAMPER_PERMISSION_READ] =
      RDMA_SC_DMA_PERMISSION;
    expected_codes[RDMA_CMQ_TAMPER_PERMISSION_WRITE] =
      RDMA_SC_DMA_PERMISSION;
    expected_codes[RDMA_CMQ_TAMPER_IOVA_ALIGNMENT] =
      RDMA_SC_DMA_TRANSLATION;
    expected_codes[RDMA_CMQ_TAMPER_BACKING_ALIGNMENT] =
      RDMA_SC_DMA_TRANSLATION;
    expected_codes[RDMA_CMQ_TAMPER_IOVA_RANGE] = RDMA_SC_DMA_TRANSLATION;
    expected_codes[RDMA_CMQ_TAMPER_BACKING_RANGE] =
      RDMA_SC_DMA_TRANSLATION;
    expected_codes[RDMA_CMQ_TAMPER_PERMISSION_ATOMIC] =
      RDMA_SC_DMA_PERMISSION;

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
    for (int unsigned kind = 0; kind < RDMA_CMQ_TAMPER_COUNT; kind++) begin
      engine.tamper_mapping(rdma_cmq_mapping_tamper_e'(kind));
      before_mapping = engine.mapping_snapshot();
      engine.activate(active_binding, status);
      expect_status($sformatf("ACTIVATE_MAPPING_%0d", kind), status,
                    expected_codes[kind]);
      after_mapping = engine.mapping_snapshot();
      if (engine.state() != RDMA_CMQ_ENGINE_PREPARED ||
          engine.published_count() != 0 || engine.retired_count() != 0 ||
          engine.cq_consumed_count() != 0)
        `uvm_error("ACTIVATE_MAPPING_ATOMIC",
                   "failed activate changed state or counters")
      if (!same_mapping_fields(before_mapping, after_mapping))
        `uvm_error("ACTIVATE_MAPPING_AUTHORITY",
                   "failed activate changed retained mapping authority")
      engine.restore_mapping(good_mapping);
    end

    engine.activate(active_binding, status);
    expect_status("ACTIVATE_SUCCESS", status, RDMA_SC_OK);
    if (engine.state() != RDMA_CMQ_ENGINE_ACTIVE)
      `uvm_error("ACTIVATE_SUCCESS_STATE",
                 "matching ACTIVE binding was not committed")
    engine.shutdown(status);
    expect_status("ACTIVATE_SHUTDOWN", status, RDMA_SC_OK);
    expect_unconfigured("ACTIVATE_SHUTDOWN_STATE", engine);
    if (count_host_calls(mem, "release") != 1 ||
        mem.regions.size() != 1 || mem.regions[0].mapping == null ||
        mem.regions[0].mapping.state != RDMA_MAPPING_RELEASED)
      `uvm_error("ACTIVATE_SHUTDOWN_RELEASE",
                 "ACTIVE shutdown did not release backing exactly once")
    engine.shutdown(status);
    expect_status("ACTIVATE_SHUTDOWN_IDEMPOTENT", status, RDMA_SC_OK);
    if (count_host_calls(mem, "release") != 1)
      `uvm_error("ACTIVATE_SHUTDOWN_IDEMPOTENT",
                 "idempotent ACTIVE shutdown released backing again")
  endtask

  task automatic check_prepared_shutdown_lifecycle();
    rdma_cmq_engine engine;
    rdma_mock_host_mem first_mem;
    rdma_mock_host_mem second_mem;
    rdma_doorbell_scheduler first_scheduler;
    rdma_doorbell_scheduler second_scheduler;
    rdma_cmq_test_profile first_profile;
    rdma_cmq_test_profile second_profile;
    rdma_function_binding first_binding;
    rdma_function_binding second_binding;
    rdma_function_binding active_binding;
    rdma_cmq first_cmq;
    rdma_cmq second_cmq;
    rdma_cmq_runtime_desc runtime_desc;
    rdma_status status;
    int unsigned first_call_count;

    engine = rdma_cmq_engine::type_id::create("prepared_shutdown_engine");
    first_mem = rdma_mock_host_mem::type_id::create(
      "prepared_shutdown_first_mem"
    );
    first_scheduler = rdma_doorbell_scheduler::type_id::create(
      "prepared_shutdown_first_scheduler"
    );
    first_profile = rdma_cmq_test_profile::type_id::create(
      "prepared_shutdown_first_profile"
    );
    first_binding = make_binding("prepared_shutdown_first_binding",
                                 RDMA_BIND_PREPARED);
    first_cmq = make_cmq("prepared_shutdown_first_cmq", first_binding);
    prepare_defaults("PREPARED_SHUTDOWN_PREPARE", engine, first_mem,
                     first_binding, first_cmq, first_scheduler,
                     first_profile, runtime_desc);

    engine.shutdown(status);
    expect_status("PREPARED_SHUTDOWN", status, RDMA_SC_OK);
    expect_unconfigured("PREPARED_SHUTDOWN_STATE", engine);
    if (count_host_calls(first_mem, "release") != 1 ||
        first_mem.regions.size() != 1 ||
        first_mem.regions[0].mapping == null ||
        first_mem.regions[0].mapping.state != RDMA_MAPPING_RELEASED ||
        engine.published_count() != 0 || engine.retired_count() != 0 ||
        engine.cq_consumed_count() != 0)
      `uvm_error("PREPARED_SHUTDOWN_RELEASE",
                 "PREPARED shutdown did not clear backing and counters")
    first_call_count = first_mem.calls.size();
    engine.shutdown(status);
    expect_status("PREPARED_SHUTDOWN_IDEMPOTENT", status, RDMA_SC_OK);
    if (first_mem.calls.size() != first_call_count ||
        count_host_calls(first_mem, "release") != 1)
      `uvm_error("PREPARED_SHUTDOWN_IDEMPOTENT",
                 "idempotent PREPARED shutdown reused old authority")
    active_binding = make_binding("prepared_shutdown_active_probe",
                                  RDMA_BIND_ACTIVE);
    engine.activate(active_binding, status);
    expect_status("PREPARED_SHUTDOWN_CLEARED_ACTIVATE", status,
                  RDMA_SC_INVALID_STATE);
    if (first_mem.calls.size() != first_call_count)
      `uvm_error("PREPARED_SHUTDOWN_CLEARED_ACTIVATE",
                 "post-shutdown activate reused old host authority")

    second_mem = rdma_mock_host_mem::type_id::create(
      "prepared_shutdown_second_mem"
    );
    second_scheduler = rdma_doorbell_scheduler::type_id::create(
      "prepared_shutdown_second_scheduler"
    );
    second_profile = rdma_cmq_test_profile::type_id::create(
      "prepared_shutdown_second_profile"
    );
    second_binding = make_binding("prepared_shutdown_second_binding",
                                  RDMA_BIND_PREPARED);
    second_binding.function_uid++;
    second_binding.global_function_id++;
    second_binding.generation++;
    second_binding.owner_h = second_binding.make_handle();
    second_cmq = make_cmq("prepared_shutdown_second_cmq", second_binding);
    prepare_defaults("PREPARED_SHUTDOWN_REPREPARE", engine, second_mem,
                     second_binding, second_cmq, second_scheduler,
                     second_profile, runtime_desc);
    if (first_mem.calls.size() != first_call_count ||
        first_profile.validation_calls != 1 ||
        second_profile.validation_calls != 1 ||
        engine.published_count() != 0 || engine.retired_count() != 0 ||
        engine.cq_consumed_count() != 0)
      `uvm_error("PREPARED_SHUTDOWN_REPREPARE",
                 "reprepare reused stale collaborators or counters")
    engine.shutdown(status);
    expect_status("PREPARED_SHUTDOWN_REPREPARE_RELEASE", status,
                  RDMA_SC_OK);
    if (count_host_calls(first_mem, "release") != 1 ||
        count_host_calls(second_mem, "release") != 1)
      `uvm_error("PREPARED_SHUTDOWN_REPREPARE_RELEASE",
                 "reprepare released through the wrong collaborator")
  endtask

  task automatic check_shutdown_release_retry();
    rdma_cmq_engine_probe engine;
    rdma_mock_host_mem mem;
    rdma_doorbell_scheduler scheduler;
    rdma_cmq_test_profile profile;
    rdma_function_binding binding;
    rdma_cmq cmq;
    rdma_cmq_runtime_desc runtime_desc;
    rdma_dma_mapping retained_snapshot;
    rdma_mock_dma_mapping retained_mock;
    rdma_status status;

    engine = rdma_cmq_engine_probe::type_id::create(
      "shutdown_retry_engine"
    );
    mem = rdma_mock_host_mem::type_id::create("shutdown_retry_mem");
    scheduler = rdma_doorbell_scheduler::type_id::create(
      "shutdown_retry_scheduler"
    );
    profile = rdma_cmq_test_profile::type_id::create(
      "shutdown_retry_profile"
    );
    binding = make_binding("shutdown_retry_binding", RDMA_BIND_PREPARED);
    cmq = make_cmq("shutdown_retry_cmq", binding);
    prepare_defaults("SHUTDOWN_RETRY_PREPARE", engine, mem, binding, cmq,
                     scheduler, profile, runtime_desc);
    expect_status("ARM_SHUTDOWN_RELEASE_FAILURE",
                  mem.fail_next("release", rdma_status::make(
                    RDMA_SC_UNKNOWN_HW_ERROR,
                    "injected shutdown release failure"
                  )), RDMA_SC_OK);
    engine.seed_runtime_counters();

    engine.shutdown(status);
    expect_status("SHUTDOWN_RELEASE_FAILURE", status,
                  RDMA_SC_UNKNOWN_HW_ERROR);
    retained_snapshot = engine.mapping_snapshot();
    if (status == null ||
        status.message != "injected shutdown release failure" ||
        engine.state() != RDMA_CMQ_ENGINE_POISONED ||
        retained_snapshot == null ||
        !engine.retry_only_poisoned() ||
        count_host_calls(mem, "release") != 1 ||
        mem.regions.size() != 1 || mem.regions[0].mapping == null ||
        mem.regions[0].mapping.state != RDMA_MAPPING_ACTIVE)
      `uvm_error("SHUTDOWN_RELEASE_FAILURE",
                 "shutdown release failure lost retained authority")
    if (!$cast(retained_mock, retained_snapshot))
      `uvm_error("SHUTDOWN_RELEASE_FAILURE",
                 "retained shutdown mapping lost allocation identity")

    engine.shutdown(status);
    expect_status("SHUTDOWN_RELEASE_RETRY", status, RDMA_SC_OK);
    expect_unconfigured("SHUTDOWN_RELEASE_RETRY_STATE", engine);
    if (count_host_calls(mem, "release") != 2 ||
        mem.regions[0].mapping.state != RDMA_MAPPING_RELEASED)
      `uvm_error("SHUTDOWN_RELEASE_RETRY",
                 "shutdown did not retry and retire the same allocation")
    expect_release_retry_identity("SHUTDOWN_RELEASE_RETRY_IDENTITY", mem,
                                  retained_mock);

    engine.shutdown(status);
    expect_status("SHUTDOWN_RELEASE_RETRY_IDEMPOTENT", status,
                  RDMA_SC_OK);
    if (count_host_calls(mem, "release") != 2)
      `uvm_error("SHUTDOWN_RELEASE_RETRY_IDEMPOTENT",
                 "third shutdown released retired backing again")
  endtask

  task automatic check_active_shutdown_release_retry();
    rdma_cmq_engine_probe engine;
    rdma_mock_host_mem mem;
    rdma_doorbell_scheduler scheduler;
    rdma_cmq_test_profile profile;
    rdma_function_binding prepared_binding;
    rdma_function_binding active_binding;
    rdma_cmq cmq;
    rdma_cmq_runtime_desc runtime_desc;
    rdma_dma_mapping retained_snapshot;
    rdma_mock_dma_mapping retained_mock;
    rdma_status status;

    engine = rdma_cmq_engine_probe::type_id::create(
      "active_shutdown_retry_engine"
    );
    mem = rdma_mock_host_mem::type_id::create(
      "active_shutdown_retry_mem"
    );
    scheduler = rdma_doorbell_scheduler::type_id::create(
      "active_shutdown_retry_scheduler"
    );
    profile = rdma_cmq_test_profile::type_id::create(
      "active_shutdown_retry_profile"
    );
    prepared_binding = make_binding("active_shutdown_retry_prepared",
                                    RDMA_BIND_PREPARED);
    active_binding = make_binding("active_shutdown_retry_active",
                                  RDMA_BIND_ACTIVE);
    cmq = make_cmq("active_shutdown_retry_cmq", prepared_binding);
    prepare_defaults("ACTIVE_SHUTDOWN_RETRY_PREPARE", engine, mem,
                     prepared_binding, cmq, scheduler, profile,
                     runtime_desc);
    engine.activate(active_binding, status);
    expect_status("ACTIVE_SHUTDOWN_RETRY_ACTIVATE", status, RDMA_SC_OK);
    expect_status("ARM_ACTIVE_SHUTDOWN_RELEASE_FAILURE",
                  mem.fail_next("release", rdma_status::make(
                    RDMA_SC_UNKNOWN_HW_ERROR,
                    "injected ACTIVE shutdown release failure"
                  )), RDMA_SC_OK);
    engine.seed_runtime_counters();

    engine.shutdown(status);
    expect_status("ACTIVE_SHUTDOWN_RELEASE_FAILURE", status,
                  RDMA_SC_UNKNOWN_HW_ERROR);
    retained_snapshot = engine.mapping_snapshot();
    if (status == null ||
        status.message != "injected ACTIVE shutdown release failure" ||
        !engine.retry_only_poisoned() || retained_snapshot == null ||
        count_host_calls(mem, "release") != 1 ||
        mem.regions.size() != 1 || mem.regions[0].mapping == null ||
        mem.regions[0].mapping.state != RDMA_MAPPING_ACTIVE)
      `uvm_error("ACTIVE_SHUTDOWN_RELEASE_FAILURE",
                 "ACTIVE release failure did not retain retry-only state")
    if (!$cast(retained_mock, retained_snapshot))
      `uvm_error("ACTIVE_SHUTDOWN_RELEASE_FAILURE",
                 "ACTIVE release failure lost allocation identity")

    engine.shutdown(status);
    expect_status("ACTIVE_SHUTDOWN_RELEASE_RETRY", status, RDMA_SC_OK);
    expect_unconfigured("ACTIVE_SHUTDOWN_RELEASE_RETRY_STATE", engine);
    if (count_host_calls(mem, "release") != 2 ||
        mem.regions[0].mapping.state != RDMA_MAPPING_RELEASED)
      `uvm_error("ACTIVE_SHUTDOWN_RELEASE_RETRY",
                 "ACTIVE shutdown retry did not release backing")
    expect_release_retry_identity(
      "ACTIVE_SHUTDOWN_RELEASE_RETRY_IDENTITY", mem, retained_mock
    );
  endtask

  task automatic check_null_shutdown_release_retry();
    rdma_cmq_engine_probe engine;
    rdma_cmq_null_release_once_mem mem;
    rdma_doorbell_scheduler scheduler;
    rdma_cmq_test_profile profile;
    rdma_function_binding binding;
    rdma_cmq cmq;
    rdma_cmq_runtime_desc runtime_desc;
    rdma_dma_mapping retained_snapshot;
    rdma_mock_dma_mapping retained_mock;
    rdma_status status;

    engine = rdma_cmq_engine_probe::type_id::create(
      "null_release_retry_engine"
    );
    mem = rdma_cmq_null_release_once_mem::type_id::create(
      "null_release_retry_mem"
    );
    scheduler = rdma_doorbell_scheduler::type_id::create(
      "null_release_retry_scheduler"
    );
    profile = rdma_cmq_test_profile::type_id::create(
      "null_release_retry_profile"
    );
    binding = make_binding("null_release_retry_binding",
                           RDMA_BIND_PREPARED);
    cmq = make_cmq("null_release_retry_cmq", binding);
    prepare_defaults("NULL_RELEASE_RETRY_PREPARE", engine, mem, binding,
                     cmq, scheduler, profile, runtime_desc);
    engine.seed_runtime_counters();

    engine.shutdown(status);
    expect_status("NULL_SHUTDOWN_RELEASE", status, RDMA_SC_INVALID_STATE);
    retained_snapshot = engine.mapping_snapshot();
    if (status == null ||
        status.message != "CMQ shutdown release returned null status" ||
        !engine.retry_only_poisoned() || retained_snapshot == null ||
        count_host_calls(mem, "release") != 1 ||
        mem.regions.size() != 1 || mem.regions[0].mapping == null ||
        mem.regions[0].mapping.state != RDMA_MAPPING_ACTIVE)
      `uvm_error("NULL_SHUTDOWN_RELEASE",
                 "null release did not retain retry-only authority")
    if (!$cast(retained_mock, retained_snapshot))
      `uvm_error("NULL_SHUTDOWN_RELEASE",
                 "null release lost mapping allocation identity")

    engine.shutdown(status);
    expect_status("NULL_SHUTDOWN_RELEASE_RETRY", status, RDMA_SC_OK);
    expect_unconfigured("NULL_SHUTDOWN_RELEASE_RETRY_STATE", engine);
    if (count_host_calls(mem, "release") != 2 ||
        mem.regions[0].mapping.state != RDMA_MAPPING_RELEASED)
      `uvm_error("NULL_SHUTDOWN_RELEASE_RETRY",
                 "null release retry did not release backing")
    expect_release_retry_identity("NULL_SHUTDOWN_RELEASE_RETRY_IDENTITY",
                                  mem, retained_mock);
    engine.shutdown(status);
    expect_status("NULL_SHUTDOWN_RELEASE_IDEMPOTENT", status,
                  RDMA_SC_OK);
    if (count_host_calls(mem, "release") != 2)
      `uvm_error("NULL_SHUTDOWN_RELEASE_IDEMPOTENT",
                 "idempotent shutdown retried a released mapping")
  endtask

  task automatic check_missing_host_mem_shutdown();
    rdma_cmq_engine_probe engine;
    rdma_mock_host_mem mem;
    rdma_doorbell_scheduler scheduler;
    rdma_cmq_test_profile profile;
    rdma_function_binding binding;
    rdma_cmq cmq;
    rdma_cmq_runtime_desc runtime_desc;
    rdma_dma_mapping retained_snapshot;
    rdma_mock_dma_mapping original_mapping;
    rdma_mock_dma_mapping retained_mapping;
    rdma_status status;

    engine = rdma_cmq_engine_probe::type_id::create(
      "missing_host_mem_engine"
    );
    mem = rdma_mock_host_mem::type_id::create("missing_host_mem");
    scheduler = rdma_doorbell_scheduler::type_id::create(
      "missing_host_mem_scheduler"
    );
    profile = rdma_cmq_test_profile::type_id::create(
      "missing_host_mem_profile"
    );
    binding = make_binding("missing_host_mem_binding", RDMA_BIND_PREPARED);
    cmq = make_cmq("missing_host_mem_cmq", binding);
    prepare_defaults("MISSING_HOST_MEM_PREPARE", engine, mem, binding, cmq,
                     scheduler, profile, runtime_desc);
    retained_snapshot = engine.mapping_snapshot();
    if (!$cast(original_mapping, retained_snapshot))
      `uvm_error("MISSING_HOST_MEM_PREPARE",
                 "prepared mapping lost allocation identity")
    engine.seed_runtime_counters();
    engine.drop_host_mem_authority();

    engine.shutdown(status);
    expect_status("MISSING_HOST_MEM_SHUTDOWN", status,
                  RDMA_SC_INVALID_STATE);
    retained_snapshot = engine.mapping_snapshot();
    if (!$cast(retained_mapping, retained_snapshot))
      `uvm_error("MISSING_HOST_MEM_SHUTDOWN",
                 "missing adapter path lost retained mapping")
    if (status == null ||
        status.message != "CMQ shutdown release authority is missing" ||
        !engine.missing_host_mem_poisoned() ||
        count_host_calls(mem, "release") != 0 ||
        mem.regions.size() != 1 || mem.regions[0].mapping == null ||
        mem.regions[0].mapping.state != RDMA_MAPPING_ACTIVE ||
        original_mapping == null || retained_mapping == null ||
        !original_mapping.same_allocation(retained_mapping))
      `uvm_error("MISSING_HOST_MEM_SHUTDOWN",
                 "missing adapter path did not fail closed visibly")

    engine.shutdown(status);
    expect_status("MISSING_HOST_MEM_SHUTDOWN_REPEAT", status,
                  RDMA_SC_INVALID_STATE);
    if (!engine.missing_host_mem_poisoned() ||
        count_host_calls(mem, "release") != 0)
      `uvm_error("MISSING_HOST_MEM_SHUTDOWN_REPEAT",
                 "missing adapter failure was not deterministic")

    engine.restore_host_mem_authority(mem);
    engine.shutdown(status);
    expect_status("MISSING_HOST_MEM_RECOVERY", status, RDMA_SC_OK);
    expect_unconfigured("MISSING_HOST_MEM_RECOVERY_STATE", engine);
    if (count_host_calls(mem, "release") != 1 ||
        mem.regions[0].mapping.state != RDMA_MAPPING_RELEASED)
      `uvm_error("MISSING_HOST_MEM_RECOVERY",
                 "restored adapter did not release retained mapping")
  endtask

  virtual task run_phase(uvm_phase phase);
    phase.raise_objection(this);
    check_success_and_detachment();
    check_preallocation_rejections();
    check_pasid_normalization_and_busy_prepare();
    check_allocation_and_rollback_failures();
    check_null_status_guards();
    check_prepared_shutdown_lifecycle();
    check_shutdown_release_retry();
    check_active_shutdown_release_retry();
    check_null_shutdown_release_retry();
    check_missing_host_mem_shutdown();
    check_activation_guards();
    phase.drop_objection(this);
  endtask
endclass
