typedef enum bit {
  RDMA_DB_DEP_PAYLOAD       = 1'b0,
  RDMA_DB_DEP_QUEUE_CONTEXT = 1'b1
} rdma_doorbell_dependency_stage_e;

typedef enum bit [1:0] {
  RDMA_DB_BARRIER_NONE     = 2'b00,
  RDMA_DB_BARRIER_DMA      = 2'b01,
  RDMA_DB_BARRIER_MMIO     = 2'b10,
  RDMA_DB_BARRIER_DMA_MMIO = 2'b11
} rdma_doorbell_barrier_policy_e;

typedef enum bit {
  RDMA_DB_WRITE_NON_COMBINING = 1'b0,
  RDMA_DB_WRITE_COMBINING     = 1'b1
} rdma_doorbell_write_combining_policy_e;

typedef enum bit {
  RDMA_DB_READBACK_NONE     = 1'b0,
  RDMA_DB_READBACK_REQUIRED = 1'b1
} rdma_doorbell_readback_policy_e;

class rdma_doorbell_dependency extends uvm_object;
  `uvm_object_utils(rdma_doorbell_dependency)

  longint unsigned dependency_id;
  rdma_doorbell_dependency_stage_e stage;
  rdma_dma_mapping mapping;
  longint unsigned relative_offset;
  rdma_hw_image image;
  bit ready;

  function new(string name = "rdma_doorbell_dependency");
    super.new(name);
    dependency_id = '0;
    stage = RDMA_DB_DEP_PAYLOAD;
    mapping = null;
    relative_offset = '0;
    image = null;
    ready = 1'b0;
  endfunction
endclass

class rdma_doorbell_desc extends uvm_object;
  `uvm_object_utils(rdma_doorbell_desc)

  rdma_doorbell_kind_e kind;
  rdma_function_handle function_h;
  rdma_handle target_h;
  bit [2:0] notify_bar_id;
  longint unsigned relative_offset;
  int unsigned width;
  rdma_byte_endian_e endian;
  rdma_hw_image payload_image;
  rdma_doorbell_barrier_policy_e barrier_policy;
  rdma_doorbell_write_combining_policy_e write_combining_policy;
  bit allow_merge;
  bit merge_requested;
  rdma_doorbell_dependency dependencies[$];
  longint unsigned timeout;
  rdma_doorbell_readback_policy_e readback_policy;

  function new(string name = "rdma_doorbell_desc");
    super.new(name);
    kind = RDMA_DOORBELL_CMQ_SQ;
    function_h = null;
    target_h = null;
    notify_bar_id = '0;
    relative_offset = '0;
    width = '0;
    endian = RDMA_ENDIAN_LITTLE;
    payload_image = null;
    barrier_policy = RDMA_DB_BARRIER_DMA_MMIO;
    write_combining_policy = RDMA_DB_WRITE_NON_COMBINING;
    allow_merge = 1'b0;
    merge_requested = 1'b0;
    dependencies.delete();
    timeout = '0;
    readback_policy = RDMA_DB_READBACK_NONE;
  endfunction
endclass

class rdma_doorbell_result extends uvm_object;
  `uvm_object_utils(rdma_doorbell_result)

  rdma_doorbell_kind_e kind;
  rdma_function_handle function_h;
  rdma_handle target_h;
  rdma_bar_addr_t absolute_address;
  int unsigned width;
  int unsigned dependency_count;

  function new(string name = "rdma_doorbell_result");
    super.new(name);
    kind = RDMA_DOORBELL_CMQ_SQ;
    function_h = null;
    target_h = null;
    absolute_address = '0;
    width = '0;
    dependency_count = '0;
  endfunction
endclass

class rdma_doorbell_scheduler extends uvm_object;
  `uvm_object_utils(rdma_doorbell_scheduler)

  protected rdma_host_mem_api host_mem;
  protected rdma_pcie_api pcie;
  protected bit configured;
  protected semaphore function_locks[string];

  function new(string name = "rdma_doorbell_scheduler");
    super.new(name);
    host_mem = null;
    pcie = null;
    configured = 1'b0;
    function_locks.delete();
  endfunction

  function rdma_status configure(
    rdma_host_mem_api host_mem_arg,
    rdma_pcie_api pcie_arg
  );
    if (host_mem_arg == null)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "host memory adapter is null");
    if (pcie_arg == null)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "PCIe adapter is null");
    if (configured)
      return rdma_status::make(RDMA_SC_INVALID_STATE,
                               "doorbell scheduler is already configured");
    host_mem = host_mem_arg;
    pcie = pcie_arg;
    configured = 1'b1;
    return rdma_status::success();
  endfunction

  protected function string function_key(
    longint unsigned function_uid,
    int unsigned object_id
  );
    return $sformatf("%016h:%08h", function_uid, object_id);
  endfunction

  protected function semaphore lock_for(
    longint unsigned function_uid,
    int unsigned object_id
  );
    string key;

    key = function_key(function_uid, object_id);
    if (!function_locks.exists(key))
      function_locks[key] = new(1);
    return function_locks[key];
  endfunction

  protected function rdma_status target_kind_status(
    rdma_doorbell_kind_e kind,
    rdma_handle target_h
  );
    rdma_doorbell_model model;

    model = rdma_doorbell_model::type_id::create("target_kind_model");
    model.kind = kind;
    model.target_h = target_h;
    return model.validate();
  endfunction

  protected function rdma_status image_shape_status(
    rdma_hw_image image,
    int unsigned function_generation
  );
    if (image == null)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "hardware image is null");
    if (image.length == 0 || image.bytes.size() != image.length)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "hardware image length does not match bytes");
    if (image.alignment == 0 ||
        (image.alignment & (image.alignment - 1'b1)) != 0)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "hardware image alignment is invalid");
    if (!(image.endian inside {RDMA_ENDIAN_LITTLE, RDMA_ENDIAN_BIG}))
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "hardware image endian is invalid");
    if (image.image_kind == RDMA_IMAGE_NONE || image.hardware_version == 0)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "hardware image metadata is incomplete");
    if (image.function_generation != function_generation)
      return rdma_status::make(RDMA_SC_STALE_GENERATION,
                               "hardware image generation is stale");
    return rdma_status::success();
  endfunction

  protected function rdma_status payload_status(
    rdma_function_binding binding,
    rdma_doorbell_desc desc,
    output rdma_bar_addr_t absolute_address
  );
    rdma_status status;

    absolute_address = '0;
    if (desc.payload_image == null)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "doorbell payload image is null");
    status = image_shape_status(desc.payload_image,
                                desc.function_h.generation);
    if (!status.ok())
      return status;
    if (desc.width == 0 || desc.payload_image.length != desc.width ||
        desc.payload_image.bytes.size() != desc.width)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "doorbell width does not match payload image");
    if (desc.endian != desc.payload_image.endian)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "doorbell endian does not match payload image");
    if (desc.payload_image.image_kind != RDMA_IMAGE_DOORBELL)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "payload image is not a doorbell");
    if (desc.payload_image.write_target_kind != RDMA_HW_TARGET_BAR)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "doorbell payload target is not a BAR");
    if (desc.payload_image.bar_target.value != desc.relative_offset)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "payload BAR offset does not match descriptor");
    if ((desc.relative_offset &
         (desc.payload_image.alignment - 1'b1)) != 0)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "doorbell offset violates image alignment");
    if (desc.relative_offset > binding.notify_size ||
        desc.width > (binding.notify_size - desc.relative_offset))
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "doorbell write is outside notify aperture");

    // A half-open aperture end must be representable so all later range
    // arithmetic can remain non-wrapping.
    if (binding.notify_base.value >
        (64'hffff_ffff_ffff_ffff - binding.notify_size))
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "notify aperture end overflows 64 bits");
    if (binding.notify_base.value >
        (64'hffff_ffff_ffff_ffff - desc.relative_offset))
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "doorbell absolute address overflows 64 bits");
    absolute_address.value = binding.notify_base.value + desc.relative_offset;
    if (absolute_address.value >
        (64'hffff_ffff_ffff_ffff - (desc.width - 1'b1)))
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "doorbell write end overflows 64 bits");
    return rdma_status::success();
  endfunction

  protected function rdma_status dependency_status(
    rdma_function_binding binding,
    rdma_doorbell_desc desc,
    rdma_doorbell_dependency dependency
  );
    rdma_status status;
    rdma_iova_t first_iova;
    rdma_dma_permission_t read_permission;

    if (dependency == null)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "doorbell dependency is null");
    if (dependency.dependency_id == 0)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "doorbell dependency ID is zero");
    if (!(dependency.stage inside {RDMA_DB_DEP_PAYLOAD,
                                   RDMA_DB_DEP_QUEUE_CONTEXT}))
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "doorbell dependency stage is invalid");
    if (!dependency.ready)
      return rdma_status::make(RDMA_SC_INVALID_STATE,
                               "doorbell dependency is not ready");
    if (dependency.mapping == null)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "doorbell dependency mapping is null");
    status = image_shape_status(dependency.image,
                                desc.function_h.generation);
    if (!status.ok())
      return status;
    if (dependency.image.write_target_kind != RDMA_HW_TARGET_BACKING)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "dependency image target is not backing memory");
    if (dependency.mapping.iova.value >
        (64'hffff_ffff_ffff_ffff - dependency.relative_offset))
      return rdma_status::make(RDMA_SC_DMA_TRANSLATION,
                               "dependency IOVA overflows 64 bits");

    first_iova.value = dependency.mapping.iova.value +
                       dependency.relative_offset;
    read_permission = '{device_read:1'b1, device_write:1'b0, atomic:1'b0};
    status = dependency.mapping.check_access(
      desc.function_h,
      binding.pcie.bdf,
      first_iova,
      dependency.image.length,
      RDMA_DMA_DEVICE_READ,
      read_permission
    );
    if (!status.ok())
      return status;
    if ((dependency.relative_offset &
         (dependency.image.alignment - 1'b1)) != 0)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "dependency offset violates image alignment");
    return status;
  endfunction

  protected function rdma_status preflight(
    rdma_function_binding binding,
    rdma_doorbell_desc desc,
    longint unsigned locked_function_uid,
    int unsigned locked_object_id,
    output rdma_bar_addr_t absolute_address
  );
    rdma_status status;
    bit seen_ids[longint unsigned];

    absolute_address = '0;
    if (!configured || host_mem == null || pcie == null)
      return rdma_status::make(RDMA_SC_INVALID_STATE,
                               "doorbell scheduler is not configured");
    if (binding.function_uid != locked_function_uid ||
        binding.global_function_id != locked_object_id)
      return rdma_status::make(RDMA_SC_INVALID_STATE,
                               "binding identity changed while waiting");
    status = binding.validate();
    if (!status.ok())
      return status;
    if (binding.state != RDMA_BIND_ACTIVE)
      return rdma_status::make(RDMA_SC_INVALID_STATE,
                               "function binding is not ACTIVE");
    if (desc.function_h == null ||
        desc.function_h.kind != RDMA_RESOURCE_FUNCTION)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "doorbell Function handle is invalid");
    if (desc.function_h.function_uid != binding.function_uid ||
        desc.function_h.object_id != binding.global_function_id)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "doorbell Function does not match binding");
    if (desc.function_h.generation != binding.generation)
      return rdma_status::make(RDMA_SC_STALE_GENERATION,
                               "doorbell Function generation is stale");
    if (desc.target_h == null)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "doorbell target handle is null");
    if (desc.target_h.function_uid != desc.function_h.function_uid)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "doorbell target belongs to another Function");
    if (desc.target_h.generation != desc.function_h.generation)
      return rdma_status::make(RDMA_SC_STALE_GENERATION,
                               "doorbell target generation is stale");
    status = target_kind_status(desc.kind, desc.target_h);
    if (!status.ok())
      return status;
    if (desc.notify_bar_id != binding.notify_bar_id)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "doorbell notify BAR does not match binding");
    if (desc.timeout == 0)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "doorbell timeout is zero");
    if (desc.merge_requested && !desc.allow_merge)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "doorbell merge was not allowed");
    if (desc.write_combining_policy == RDMA_DB_WRITE_NON_COMBINING &&
        desc.merge_requested)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "non-combining doorbell cannot be merged");
    if (desc.readback_policy != RDMA_DB_READBACK_NONE)
      return rdma_status::make(RDMA_SC_UNSUPPORTED_OPCODE,
                               "doorbell readback is unsupported");

    status = payload_status(binding, desc, absolute_address);
    if (!status.ok())
      return status;

    seen_ids.delete();
    foreach (desc.dependencies[i]) begin
      if (desc.dependencies[i] == null)
        return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                                 "doorbell dependency is null");
      if (seen_ids.exists(desc.dependencies[i].dependency_id))
        return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                                 "doorbell dependency ID is duplicated");
      seen_ids[desc.dependencies[i].dependency_id] = 1'b1;
      status = dependency_status(binding, desc, desc.dependencies[i]);
      if (!status.ok())
        return status;
    end
    return rdma_status::success();
  endfunction

  protected function void copy_image_bytes(
    rdma_hw_image image,
    output byte data[]
  );
    data = new[image.bytes.size()];
    foreach (data[i])
      data[i] = image.bytes[i];
  endfunction

  protected task write_dependency_stage(
    rdma_doorbell_desc desc,
    rdma_doorbell_dependency_stage_e stage,
    output rdma_status status
  );
    byte data[];

    status = rdma_status::success();
    foreach (desc.dependencies[i]) begin
      if (desc.dependencies[i].stage != stage)
        continue;
      copy_image_bytes(desc.dependencies[i].image, data);
      status = host_mem.write(desc.dependencies[i].mapping,
                              desc.dependencies[i].relative_offset,
                              data);
      if (status == null) begin
        status = rdma_status::make(RDMA_SC_INVALID_STATE,
                                   "host memory adapter returned null status");
        return;
      end
      if (!status.ok())
        return;
    end
  endtask

  protected task submit_locked(
    rdma_function_binding binding,
    rdma_doorbell_desc desc,
    longint unsigned locked_function_uid,
    int unsigned locked_object_id,
    output rdma_doorbell_result result,
    output rdma_status status
  );
    rdma_bar_addr_t absolute_address;
    byte payload[];

    result = null;
    status = preflight(binding, desc, locked_function_uid, locked_object_id,
                       absolute_address);
    if (!status.ok())
      return;

    write_dependency_stage(desc, RDMA_DB_DEP_PAYLOAD, status);
    if (!status.ok())
      return;
    write_dependency_stage(desc, RDMA_DB_DEP_QUEUE_CONTEXT, status);
    if (!status.ok())
      return;

    if (desc.barrier_policy inside {RDMA_DB_BARRIER_DMA,
                                    RDMA_DB_BARRIER_DMA_MMIO}) begin
      pcie.dma_visibility_barrier(desc.function_h, status);
      if (status == null) begin
        status = rdma_status::make(RDMA_SC_INVALID_STATE,
                                   "PCIe DMA barrier returned null status");
        return;
      end
      if (!status.ok())
        return;
    end
    if (desc.barrier_policy inside {RDMA_DB_BARRIER_MMIO,
                                    RDMA_DB_BARRIER_DMA_MMIO}) begin
      pcie.mmio_ordering_barrier(desc.function_h, status);
      if (status == null) begin
        status = rdma_status::make(RDMA_SC_INVALID_STATE,
                                   "PCIe MMIO barrier returned null status");
        return;
      end
      if (!status.ok())
        return;
    end

    copy_image_bytes(desc.payload_image, payload);
    pcie.mmio_write(desc.function_h, absolute_address, payload, status);
    if (status == null) begin
      status = rdma_status::make(RDMA_SC_INVALID_STATE,
                                 "PCIe MMIO write returned null status");
      return;
    end
    if (!status.ok())
      return;

    result = rdma_doorbell_result::type_id::create("doorbell_result");
    result.kind = desc.kind;
    result.function_h = rdma_clone_function_handle_value(
      desc.function_h, "doorbell result Function"
    );
    result.target_h = rdma_clone_handle_value(desc.target_h,
                                               "doorbell result target");
    result.absolute_address = absolute_address;
    result.width = desc.width;
    result.dependency_count = desc.dependencies.size();
    status = rdma_status::success();
  endtask

  task submit(
    rdma_function_binding binding,
    rdma_doorbell_desc desc,
    output rdma_doorbell_result result,
    output rdma_status status
  );
    longint unsigned locked_function_uid;
    int unsigned locked_object_id;
    semaphore function_lock;

    result = null;
    if (binding == null) begin
      status = rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                                 "function binding is null");
      return;
    end
    if (desc == null) begin
      status = rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                                 "doorbell descriptor is null");
      return;
    end

    // Generation is deliberately excluded: teardown/rebind of the same
    // immutable Function identity must serialize with its prior incarnation.
    locked_function_uid = binding.function_uid;
    locked_object_id = binding.global_function_id;
    function_lock = lock_for(locked_function_uid, locked_object_id);
    function_lock.get(1);
    submit_locked(binding, desc, locked_function_uid, locked_object_id,
                  result, status);
    function_lock.put(1);
  endtask
endclass
