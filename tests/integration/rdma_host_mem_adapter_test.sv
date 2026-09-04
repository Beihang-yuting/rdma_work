// 中文说明：rdma_host_mem_adapter_test.sv 属于集成测试，验证真实适配器与队列/控制面之间的联调。
// 阅读提示：先看公开类型和接口，再看实现细节；失败路径应保持状态与资源所有权可追踪。

class rdma_owner_clone_failure_handle extends rdma_handle;
  `uvm_object_utils(rdma_owner_clone_failure_handle)

  function new(string name = "rdma_owner_clone_failure_handle");
    super.new(name);
  endfunction

  virtual function uvm_object clone();
    return null;
  endfunction
endclass

class rdma_owner_snapshot_clone_failure_handle extends rdma_handle;
  `uvm_object_utils(rdma_owner_snapshot_clone_failure_handle)

  function new(string name = "rdma_owner_snapshot_clone_failure_handle");
    super.new(name);
  endfunction

  virtual function uvm_object clone();
    return null;
  endfunction
endclass

class rdma_owner_two_stage_clone_handle extends rdma_handle;
  `uvm_object_utils(rdma_owner_two_stage_clone_handle)

  function new(string name = "rdma_owner_two_stage_clone_handle");
    super.new(name);
  endfunction

  virtual function uvm_object clone();
    rdma_owner_snapshot_clone_failure_handle result;

    result = rdma_owner_snapshot_clone_failure_handle::type_id::create(
      {get_name(), "_snapshot_failure"}
    );
    if (result == null)
      return null;
    result.kind = kind;
    result.function_uid = function_uid;
    result.object_id = object_id;
    result.generation = generation;
    return result;
  endfunction
endclass

class rdma_owner_snapshot_alias_handle extends rdma_handle;
  `uvm_object_utils(rdma_owner_snapshot_alias_handle)

  function new(string name = "rdma_owner_snapshot_alias_handle");
    super.new(name);
  endfunction

  virtual function uvm_object clone();
    return this;
  endfunction
endclass

class rdma_owner_two_stage_alias_handle extends rdma_handle;
  `uvm_object_utils(rdma_owner_two_stage_alias_handle)

  function new(string name = "rdma_owner_two_stage_alias_handle");
    super.new(name);
  endfunction

  virtual function uvm_object clone();
    rdma_owner_snapshot_alias_handle result;

    result = rdma_owner_snapshot_alias_handle::type_id::create(
      {get_name(), "_snapshot_alias"}
    );
    if (result == null)
      return null;
    result.kind = kind;
    result.function_uid = function_uid;
    result.object_id = object_id;
    result.generation = generation;
    return result;
  endfunction
endclass

class rdma_owner_clone_counting_host_mem extends $unit::host_mem_manager;
  `uvm_object_utils(rdma_owner_clone_counting_host_mem)

  int unsigned free_call_count;

  function new(string name = "rdma_owner_clone_counting_host_mem");
    super.new(name);
    free_call_count = 0;
  endfunction

  virtual function void free(
    bit [63:0] addr,
    string file = "",
    int line = 0
  );
    free_call_count++;
    super.free(addr, file, line);
  endfunction
endclass

class rdma_host_mem_adapter_test extends uvm_test;
  `uvm_component_utils(rdma_host_mem_adapter_test)

  function new(string name = "rdma_host_mem_adapter_test",
               uvm_component parent = null);
    super.new(name, parent);
  endfunction

  function automatic rdma_function_handle make_function_handle(string name);
    rdma_function_handle function_h;

    function_h = rdma_function_handle::type_id::create(name);
    function_h.kind = RDMA_RESOURCE_FUNCTION;
    function_h.function_uid = 64'h0123_4567_89ab_cdef;
    function_h.object_id = 32'h1020_3040;
    function_h.generation = 32'd17;
    return function_h;
  endfunction

  function automatic rdma_function_binding make_active_binding(string name);
    rdma_function_binding binding;
    rdma_interrupt_vector_binding vector;

    binding = rdma_function_binding::type_id::create(name);
    binding.function_uid = 64'hca12_0000_0000_0001;
    binding.generation = 32'd92;
    binding.global_function_id = 32'hca12_0101;
    binding.rdma_vf_id = 8'h22;
    binding.pfvf_id = 32'hca12_0303;
    binding.pcie.vf_index = 32'hca12_0404;
    binding.pcie.bdf = '{segment:16'h1001, bus:8'h20, device:5'h03,
                         function_num:3'h5};
    binding.pcie.parent_pf_bdf = '{segment:16'h1001, bus:8'h30,
                                   device:5'h04, function_num:3'h2};
    if (!binding.configure_identity_from_legacy_mirrors(
          16'h1, 32'h1, RDMA_FUNCTION_VF, 16'h0404).ok())
      `uvm_error("BINDING", "legacy binding identity configuration failed")
    binding.pcie.bar[0].base.value = 64'h0000_0000_8000_0000;
    binding.pcie.bar[0].size = 64'h4000;
    binding.pcie.bar[0].enabled = 1'b1;
    binding.notify_bar_id = 3'd0;
    binding.notify_base.value = 64'h0000_0000_8000_2000;
    binding.notify_size = 64'h2000;
    binding.state = RDMA_BIND_ACTIVE;
    binding.owner_h = binding.make_handle();
    binding.queue_dma.requester_bdf = binding.pcie.bdf;
    binding.queue_dma.pasid_valid = 1'b1;
    binding.queue_dma.pasid = 20'h34567;
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

  function automatic void prepare_manager_mr(
    rdma_mr mr,
    rdma_dma_mapping mapping
  );
    mr.iova = mapping.iova;
    mr.length = mapping.size;
    mr.lkey = {mr.local_mr_id[23:0], 8'h6d};
    mr.rkey = mr.lkey;
    mr.access = '{local_write:1'b1, remote_read:1'b1,
                  remote_write:1'b0, memory_window_bind:1'b0,
                  remote_atomic:1'b0};
  endfunction

  task automatic check_manager_owned_mapping_identity();
    $unit::host_mem_manager identity_hm;
    rdma_host_mem_adapter identity_adapter;
    rdma_resource_manager identity_rm;
    rdma_function_binding identity_binding;
    rdma_dma_request_context identity_context;
    rdma_pd identity_pd;
    rdma_mr active_mr;
    rdma_mr recovery_mr;
    rdma_mr active_snapshot;
    rdma_resource resource;
    rdma_dma_mapping active_mapping;
    rdma_dma_mapping recovery_mapping;
    rdma_backing_ref active_ref;
    rdma_backing_ref recovery_ref;
    rdma_recovery_record recovery;
    rdma_recovery_record recovery_snapshot;
    rdma_status status;
    int unsigned leak_count;

    identity_hm = $unit::host_mem_manager::type_id::create(
      "manager_identity_hm"
    );
    identity_hm.init_region(64'h0000_0007_0000_0000,
                            64'h0000_0007_00ff_ffff);
    identity_adapter = rdma_host_mem_adapter::type_id::create(
      "manager_identity_adapter"
    );
    identity_adapter.mem = identity_hm;
    identity_rm = rdma_resource_manager::type_id::create(
      "manager_identity_rm"
    );
    identity_binding = make_active_binding("manager_identity_binding");
    identity_context = make_dma_context(
      "manager_identity_context", identity_binding.make_handle(),
      identity_binding.queue_dma.requester_bdf,
      identity_binding.queue_dma.pasid_valid,
      identity_binding.queue_dma.pasid
    );
    identity_context.dma_domain_valid =
      identity_binding.queue_dma.dma_domain_valid;
    identity_context.dma_domain_id = identity_binding.queue_dma.dma_domain_id;

    expect_status("MANAGER_IDENTITY_PD_CREATE",
                  identity_rm.create_pd(identity_binding, identity_pd),
                  RDMA_SC_OK);
    expect_status("MANAGER_IDENTITY_PD_ACTIVATE",
                  identity_rm.activate(identity_pd.handle), RDMA_SC_OK);

    status = identity_adapter.allocate(
      identity_context, 4096, 4096, RDMA_DMA_BIDIRECTIONAL, active_mapping
    );
    expect_status("MANAGER_IDENTITY_ACTIVE_ALLOCATE", status, RDMA_SC_OK);
    expect_status("MANAGER_IDENTITY_ACTIVE_CREATE",
                  identity_rm.create_mr(identity_binding, identity_pd.handle,
                                        active_mr),
                  RDMA_SC_OK);
    prepare_manager_mr(active_mr, active_mapping);
    active_ref = rdma_backing_ref::type_id::create(
      "manager_identity_active_ref"
    );
    active_ref.mapping = active_mapping;
    active_ref.ownership = RDMA_OWNERSHIP_CONTROL_PLANE;
    active_mr.backing_refs.push_back(active_ref);
    expect_status("MANAGER_IDENTITY_ACTIVE_STAGE",
                  identity_rm.stage_allocated(active_mr), RDMA_SC_OK);
    expect_status("MANAGER_IDENTITY_ACTIVE_COMMIT",
                  identity_rm.commit_programmed(active_mr), RDMA_SC_OK);
    expect_status("MANAGER_IDENTITY_ACTIVE_ACTIVATE",
                  identity_rm.activate(active_mr.handle), RDMA_SC_OK);
    expect_status("MANAGER_IDENTITY_ACTIVE_LOOKUP",
                  identity_rm.lookup(active_mr.handle, resource), RDMA_SC_OK);
    active_snapshot = null;
    if (!$cast(active_snapshot, resource) || active_snapshot == null ||
        active_snapshot.backing_refs.size() != 1 ||
        active_snapshot.backing_refs[0] == null ||
        active_snapshot.backing_refs[0].mapping == null)
      `uvm_fatal("MANAGER_IDENTITY_ACTIVE_LOOKUP",
                 "ACTIVE lookup lost its owned mapping")
    status = identity_adapter.\release (
      active_snapshot.backing_refs[0].mapping
    );
    expect_status("MANAGER_IDENTITY_ACTIVE_RELEASE", status, RDMA_SC_OK);
    status = identity_adapter.\release (
      active_snapshot.backing_refs[0].mapping
    );
    expect_status("MANAGER_IDENTITY_ACTIVE_RELEASE_AGAIN", status,
                  RDMA_SC_INVALID_STATE);

    status = identity_adapter.allocate(
      identity_context, 4096, 4096, RDMA_DMA_BIDIRECTIONAL, recovery_mapping
    );
    expect_status("MANAGER_IDENTITY_RECOVERY_ALLOCATE", status, RDMA_SC_OK);
    expect_status("MANAGER_IDENTITY_RECOVERY_CREATE",
                  identity_rm.create_mr(identity_binding, identity_pd.handle,
                                        recovery_mr),
                  RDMA_SC_OK);
    prepare_manager_mr(recovery_mr, recovery_mapping);
    recovery_ref = rdma_backing_ref::type_id::create(
      "manager_identity_recovery_ref"
    );
    recovery_ref.mapping = recovery_mapping;
    recovery_ref.ownership = RDMA_OWNERSHIP_CONTROL_PLANE;
    recovery_mr.backing_refs.push_back(recovery_ref);
    expect_status("MANAGER_IDENTITY_RECOVERY_STAGE",
                  identity_rm.stage_allocated(recovery_mr), RDMA_SC_OK);
    expect_status("MANAGER_IDENTITY_RECOVERY_COMMIT",
                  identity_rm.commit_programmed(recovery_mr), RDMA_SC_OK);
    expect_status("MANAGER_IDENTITY_RECOVERY_ACTIVATE",
                  identity_rm.activate(recovery_mr.handle), RDMA_SC_OK);
    recovery = rdma_recovery_record::type_id::create(
      "manager_identity_recovery"
    );
    recovery.resource_h = rdma_clone_handle_value(
      recovery_mr.handle, "manager identity recovery"
    );
    recovery.hardware_presence = RDMA_HW_PRESENCE_ABSENT;
    recovery.backing_refs.push_back(recovery_ref);
    recovery.primary_status = rdma_status::make(
      RDMA_SC_UNKNOWN_HW_ERROR, "production mapping recovery authority"
    );
    expect_status("MANAGER_IDENTITY_RECOVERY_MARK",
                  identity_rm.mark_error(recovery_mr.handle, recovery),
                  RDMA_SC_OK);
    expect_status("MANAGER_IDENTITY_RECOVERY_LOOKUP",
                  identity_rm.lookup_recovery(recovery_mr.handle,
                                              recovery_snapshot),
                  RDMA_SC_OK);
    if (recovery_snapshot == null ||
        recovery_snapshot.backing_refs.size() != 1 ||
        recovery_snapshot.backing_refs[0] == null ||
        recovery_snapshot.backing_refs[0].mapping == null)
      `uvm_fatal("MANAGER_IDENTITY_RECOVERY_LOOKUP",
                 "recovery lookup lost its owned mapping")
    status = identity_adapter.\release (
      recovery_snapshot.backing_refs[0].mapping
    );
    expect_status("MANAGER_IDENTITY_RECOVERY_RELEASE", status, RDMA_SC_OK);
    status = identity_adapter.\release (
      recovery_snapshot.backing_refs[0].mapping
    );
    expect_status("MANAGER_IDENTITY_RECOVERY_RELEASE_AGAIN", status,
                  RDMA_SC_INVALID_STATE);
    status = identity_adapter.check_leaks(leak_count);
    expect_status("MANAGER_IDENTITY_LEAK_STATUS", status, RDMA_SC_OK);
    if (leak_count != 0)
      `uvm_error("MANAGER_IDENTITY_LEAK_COUNT",
                 "manager snapshots leaked production host allocations")
  endtask

  function automatic rdma_dma_request_context make_dma_context(
    string name,
    rdma_function_handle function_h,
    rdma_bdf_t requester_bdf,
    bit pasid_valid = 1'b0,
    bit [19:0] pasid = '0,
    rdma_handle owner_h = null
  );
    rdma_dma_request_context result;
    result = rdma_dma_request_context::type_id::create(name);
    result.function_h = rdma_clone_function_handle_value(
      function_h, "DMA context Function"
    );
    result.requester_bdf = requester_bdf;
    result.pasid_valid = pasid_valid;
    result.pasid = pasid;
    result.owner_h = (owner_h == null) ? null :
                     rdma_clone_handle_value(owner_h, "DMA context owner");
    return result;
  endfunction

  function automatic rdma_dma_mapping clone_mapping(
    string check_name,
    rdma_dma_mapping source
  );
    uvm_object cloned_object;
    rdma_dma_mapping result;

    if (source == null) begin
      `uvm_fatal(check_name, "cannot clone a null DMA mapping")
      return null;
    end
    cloned_object = source.clone();
    if (cloned_object == null || !$cast(result, cloned_object)) begin
      `uvm_fatal(check_name, "DMA mapping clone type mismatch")
      return null;
    end
    return result;
  endfunction

  function automatic void expect_status(
    string check_name,
    rdma_status status,
    rdma_status_code_e expected_code
  );
    if (status == null) begin
      `uvm_error(check_name, "adapter returned a null status")
      return;
    end
    if (status.code != expected_code)
      `uvm_error(check_name,
                 $sformatf("expected %s, got %s (%s)",
                           expected_code.name(), status.code.name(),
                           status.message))
  endfunction

  function automatic void expect_empty(
    string check_name,
    byte data[]
  );
    if (data.size() != 0)
      `uvm_error(check_name,
                 $sformatf("failed read returned %0d bytes", data.size()))
  endfunction

  task automatic run_queue_host_mem_fixture();
    $unit::host_mem_manager queue_hm;
    rdma_host_mem_adapter queue_adapter;
    rdma_resource_manager resource_manager;
    rdma_cq_lifecycle_policy cq_policy;
    rdma_create_cq_req cq_request;
    rdma_queue_resource queue_resource;
    rdma_function_binding binding;
    rdma_handle resource_h;
    rdma_queue_backing_planner planner;
    rdma_queue_preflight preflight;
    rdma_queue_backing_spec backing_spec;
    rdma_queue_backing_plan plan;
    rdma_queue_backing_ref ring_ref;
    rdma_queue_backing_ref pd_ref;
    rdma_codec_pkg::rdma_xtr_v1_queue_pd_codec pd_codec;
    rdma_status status;
    bit complete;
    bit release_done;
    int unsigned leak_count;
    byte pd_bytes[];
    rdma_bdf_t saved_bdf;
    bit saved_pasid_valid;
    bit [19:0] saved_pasid;
    bit saved_domain_valid;
    bit [31:0] saved_domain_id;
    rdma_iova_t saved_iova;
    rdma_backing_addr_t saved_backing;
    rdma_function_handle saved_function;
    rdma_handle saved_owner;
    rdma_iova_t saved_pd_iova;
    rdma_backing_addr_t saved_pd_backing;
    rdma_function_handle saved_pd_function;
    rdma_handle saved_pd_owner;
    rdma_dma_direction_e saved_pd_direction;

    queue_hm = $unit::host_mem_manager::type_id::create("queue_hm");
    queue_hm.init_region(64'h0000_0008_0000_0000,
                         64'h0000_0008_00ff_ffff);
    queue_adapter = rdma_host_mem_adapter::type_id::create(
      "queue_host_mem_adapter"
    );
    queue_adapter.mem = queue_hm;
    queue_adapter.iova_base = 64'h0000_0010_0000_0000;

    binding = make_active_binding("queue_fixture_binding");
    planner = rdma_queue_backing_planner::type_id::create(
      "queue_fixture_planner"
    );
    expect_status("QUEUE_CONFIGURE", planner.configure(queue_adapter),
                  RDMA_SC_OK);
    backing_spec = rdma_queue_backing_spec::type_id::create(
      "queue_fixture_backing_spec"
    );
    backing_spec.mode = RDMA_QUEUE_BACKING_OWNED;
    resource_manager = rdma_resource_manager::type_id::create(
      "queue_fixture_resource_manager"
    );
    cq_policy = rdma_cq_lifecycle_policy::type_id::create(
      "queue_fixture_cq_policy"
    );
    cq_request = rdma_create_cq_req::type_id::create(
      "queue_fixture_cq_request"
    );
    cq_request.owner = binding.make_handle();
    cq_request.depth = 64;
    cq_request.cqe_size_bytes = 64;
    cq_request.ring_backing = backing_spec;
    expect_status("QUEUE_PREFLIGHT",
                  cq_policy.preflight(binding, cq_request, resource_manager,
                                      preflight), RDMA_SC_OK);
    expect_status("QUEUE_RESERVE",
                  cq_policy.reserve_resource(resource_manager, binding,
                                             cq_request, queue_resource),
                  RDMA_SC_OK);
    if (queue_resource == null || queue_resource.handle == null)
      `uvm_fatal("QUEUE_RESERVE", "CQ reservation returned no resource")
    resource_h = queue_resource.handle;
    plan = null;
    expect_status("QUEUE_MATERIALIZE",
                  planner.materialize(binding, preflight, resource_h, plan),
                  RDMA_SC_OK);
    if (plan == null || plan.refs.size() != 2 || plan.rings.size() != 1)
      `uvm_fatal("QUEUE_PLAN", "queue planner did not produce CQ refs")

    ring_ref = null;
    pd_ref = null;
    foreach (plan.refs[i]) begin
      if (plan.refs[i].role == RDMA_QUEUE_ROLE_CQ_RING)
        ring_ref = plan.refs[i];
      if (plan.refs[i].role == RDMA_QUEUE_ROLE_CQ_PD)
        pd_ref = plan.refs[i];
    end
    if (ring_ref == null || pd_ref == null || ring_ref.mapping == null ||
        pd_ref.mapping == null || plan.rings[0].pages.size() != 1)
      `uvm_fatal("QUEUE_REFS", "queue planner role refs are incomplete")
    if (ring_ref.mapping.backing_addr.value <= 64'hffff_ffff ||
        pd_ref.mapping.backing_addr.value <= 64'hffff_ffff)
      `uvm_error("QUEUE_BACKING_WIDTH", "queue backing address must exercise 64-bit range")

    saved_bdf = binding.queue_dma.requester_bdf;
    saved_pasid_valid = binding.queue_dma.pasid_valid;
    saved_pasid = binding.queue_dma.pasid;
    saved_domain_valid = binding.queue_dma.dma_domain_valid;
    saved_domain_id = binding.queue_dma.dma_domain_id;
    saved_iova = ring_ref.mapping.iova;
    saved_backing = ring_ref.mapping.backing_addr;
    saved_function = ring_ref.mapping.function_h;
    saved_owner = ring_ref.mapping.owner_h;
    saved_pd_iova = pd_ref.mapping.iova;
    saved_pd_backing = pd_ref.mapping.backing_addr;
    saved_pd_function = pd_ref.mapping.function_h;
    saved_pd_owner = pd_ref.mapping.owner_h;
    saved_pd_direction = pd_ref.mapping.direction;
    if (ring_ref.mapping.iova.value == 0 ||
        ring_ref.mapping.iova.value == ring_ref.mapping.backing_addr.value ||
        plan.rings[0].pages[0].page_iova.value == 0 ||
        plan.rings[0].pages[0].page_iova.value ==
          ring_ref.mapping.backing_addr.value)
      `uvm_error("QUEUE_IOVA", "queue IOVA must be nonzero and translated")
    if (ring_ref.mapping.requester_bdf != saved_bdf ||
        ring_ref.mapping.pasid_valid != saved_pasid_valid ||
        ring_ref.mapping.pasid != saved_pasid ||
        ring_ref.mapping.dma_domain_valid != saved_domain_valid ||
        ring_ref.mapping.dma_domain_id != saved_domain_id ||
        ring_ref.mapping.direction != RDMA_DMA_DEVICE_WRITE ||
        ring_ref.mapping.owner_h == null ||
        !ring_ref.mapping.owner_h.same_instance(resource_h) ||
        ring_ref.mapping.owner_h == resource_h ||
        ring_ref.mapping.function_h == null ||
        !ring_ref.mapping.function_h.same_instance(binding.owner_h) ||
        ring_ref.mapping.function_h == binding.owner_h ||
        pd_ref.mapping.requester_bdf != saved_bdf ||
        pd_ref.mapping.pasid_valid != saved_pasid_valid ||
        pd_ref.mapping.pasid != saved_pasid ||
        pd_ref.mapping.dma_domain_valid != saved_domain_valid ||
        pd_ref.mapping.dma_domain_id != saved_domain_id ||
        pd_ref.mapping.direction != RDMA_DMA_DEVICE_READ ||
        pd_ref.mapping.owner_h == null ||
        !pd_ref.mapping.owner_h.same_instance(resource_h) ||
        pd_ref.mapping.owner_h == resource_h ||
        pd_ref.mapping.function_h == null ||
        !pd_ref.mapping.function_h.same_instance(binding.owner_h) ||
        pd_ref.mapping.function_h == binding.owner_h)
      `uvm_error("QUEUE_AUTHORITY", "queue mapping authority is not a deep copy")

    pd_codec = rdma_codec_pkg::rdma_xtr_v1_queue_pd_codec::type_id::create(
      "queue_fixture_pd_codec"
    );
    expect_status("QUEUE_INITIALIZE",
                  planner.initialize_payload_and_pd(binding, plan, pd_codec),
                  RDMA_SC_OK);
    status = queue_adapter.read(pd_ref.mapping, pd_ref.mapping_offset, 8,
                                pd_bytes);
    expect_status("QUEUE_PD_READ", status, RDMA_SC_OK);
    if (pd_bytes.size() != 8 ||
        pd_bytes[0] != plan.rings[0].pages[0].page_iova.value[63:56] ||
        pd_bytes[7][0] != 1'b1)
      `uvm_error("QUEUE_PD_READ", "PD did not encode the payload IOVA")

    // Mutating the caller's binding after allocation must not alter authority.
    binding.queue_dma.requester_bdf.bus = binding.queue_dma.requester_bdf.bus + 1'b1;
    binding.queue_dma.pasid_valid = ~binding.queue_dma.pasid_valid;
    binding.queue_dma.pasid = binding.queue_dma.pasid ^ 20'h1;
    binding.queue_dma.dma_domain_valid = ~binding.queue_dma.dma_domain_valid;
    binding.queue_dma.dma_domain_id = binding.queue_dma.dma_domain_id ^ 32'h1;
    if (ring_ref.mapping.requester_bdf != saved_bdf ||
        ring_ref.mapping.pasid_valid != saved_pasid_valid ||
        ring_ref.mapping.pasid != saved_pasid ||
        ring_ref.mapping.dma_domain_valid != saved_domain_valid ||
        ring_ref.mapping.dma_domain_id != saved_domain_id ||
        ring_ref.mapping.direction != RDMA_DMA_DEVICE_WRITE ||
        ring_ref.mapping.iova != saved_iova ||
        ring_ref.mapping.backing_addr != saved_backing ||
        !ring_ref.mapping.function_h.same_instance(saved_function) ||
        !ring_ref.mapping.owner_h.same_instance(saved_owner) ||
        pd_ref.mapping.requester_bdf != saved_bdf ||
        pd_ref.mapping.pasid_valid != saved_pasid_valid ||
        pd_ref.mapping.pasid != saved_pasid ||
        pd_ref.mapping.dma_domain_valid != saved_domain_valid ||
        pd_ref.mapping.dma_domain_id != saved_domain_id ||
        pd_ref.mapping.direction != saved_pd_direction ||
        pd_ref.mapping.iova != saved_pd_iova ||
        pd_ref.mapping.backing_addr != saved_pd_backing ||
        !pd_ref.mapping.function_h.same_instance(saved_pd_function) ||
        !pd_ref.mapping.owner_h.same_instance(saved_pd_owner))
      `uvm_error("QUEUE_AUTHORITY_MUTATION",
                 "mapping authority changed with caller context")

    complete = 1'b0;
    expect_status("QUEUE_PD_CLEANUP",
                  planner.cleanup_local_role(pd_ref, complete), RDMA_SC_OK);
    if (!complete)
      `uvm_error("QUEUE_PD_CLEANUP", "PD cleanup did not complete")
    release_done = 1'b0;
    expect_status("QUEUE_PD_RELEASE_COMPLETION",
                  pd_ref.mapping.release_completion_status(release_done),
                  RDMA_SC_OK);
    if (!release_done)
      `uvm_error("QUEUE_PD_RELEASE_COMPLETION",
                 "PD release completion was not observed")
    complete = 1'b0;
    expect_status("QUEUE_RING_CLEANUP",
                  planner.cleanup_local_role(ring_ref, complete), RDMA_SC_OK);
    if (!complete)
      `uvm_error("QUEUE_RING_CLEANUP", "ring cleanup did not complete")
    release_done = 1'b0;
    expect_status("QUEUE_RING_RELEASE_COMPLETION",
                  ring_ref.mapping.release_completion_status(release_done),
                  RDMA_SC_OK);
    if (!release_done)
      `uvm_error("QUEUE_RING_RELEASE_COMPLETION",
                 "ring release completion was not observed")
    status = queue_adapter.check_leaks(leak_count);
    expect_status("QUEUE_LEAKS", status, RDMA_SC_OK);
    if (leak_count != 0)
      `uvm_error("QUEUE_LEAKS", "queue fixture leaked host backing")
    expect_status("QUEUE_RESERVATION_RELEASE",
                  resource_manager.release_reserved(resource_h), RDMA_SC_OK);
  endtask

  task run_phase(uvm_phase phase);
    $unit::host_mem_manager hm;
    $unit::host_mem_manager offset_hm;
    $unit::host_mem_manager overflow_hm;
    $unit::host_mem_manager equal_hm_a;
    $unit::host_mem_manager equal_hm_b;
    rdma_owner_clone_counting_host_mem owner_clone_hm;
    rdma_owner_clone_counting_host_mem authority_clone_hm;
    rdma_host_mem_adapter adapter;
    rdma_host_mem_adapter offset_adapter;
    rdma_host_mem_adapter overflow_adapter;
    rdma_host_mem_adapter equal_adapter_a;
    rdma_host_mem_adapter equal_adapter_b;
    rdma_host_mem_adapter owner_clone_adapter;
    rdma_host_mem_adapter authority_clone_adapter;
    rdma_function_handle function_h;
    rdma_function_handle invalid_function_h;
    rdma_dma_request_context request_context;
    rdma_dma_request_context request_context_snapshot;
    rdma_dma_request_context invalid_context;
    rdma_dma_request_context owner_clone_context;
    rdma_dma_request_context authority_clone_context;
    rdma_owner_clone_failure_handle owner_clone_failure_h;
    rdma_owner_two_stage_clone_handle authority_clone_owner_h;
    rdma_owner_two_stage_alias_handle authority_alias_owner_h;
    rdma_dma_mapping mapping;
    rdma_dma_mapping mapping_b;
    rdma_dma_mapping offset_mapping_a;
    rdma_dma_mapping offset_mapping_b;
    rdma_dma_mapping offset_mapping_c;
    rdma_dma_mapping offset_rejected_nonzero;
    rdma_dma_mapping offset_rejected_identity;
    rdma_dma_mapping overflow_mapping;
    rdma_dma_mapping equal_mapping_a;
    rdma_dma_mapping equal_mapping_b;
    rdma_dma_mapping owner_clone_mapping;
    rdma_dma_mapping owner_clone_followup_mapping;
    rdma_dma_mapping authority_clone_mapping;
    rdma_dma_mapping authority_clone_followup_mapping;
    rdma_dma_mapping valid_clone;
    rdma_dma_mapping stale_clone;
    rdma_dma_mapping tampered;
    rdma_dma_mapping copy_attack;
    rdma_dma_mapping forged_mapping;
    rdma_status status;
    bit [63:0] external_addr;
    int unsigned leak_count;
    byte wr[] = '{8'h11, 8'h22, 8'h33, 8'h44};
    byte wr_b[] = '{8'hb1, 8'hb2, 8'hb3, 8'hb4};
    byte one_byte[] = '{8'ha5};
    byte empty_write[] = '{};
    byte rd[];
    byte external_wr[] = '{8'he1, 8'he2, 8'he3, 8'he4};
    byte external_rd[];

    phase.raise_objection(this);

    run_queue_host_mem_fixture();

    check_manager_owned_mapping_identity();

    function_h = make_function_handle("function_h");
    invalid_function_h = make_function_handle("invalid_function_h");
    invalid_function_h.kind = RDMA_RESOURCE_PD;
    request_context = rdma_dma_request_context::type_id::create(
      "vf_dma_context"
    );
    request_context.function_h = make_function_handle("vf_function_h");
    request_context.requester_bdf =
      '{segment:16'h0000, bus:8'h53, device:5'h02, function_num:3'h5};
    request_context.pasid_valid = 1'b1;
    request_context.pasid = 20'habcde;
    request_context.dma_domain_valid = 1'b1;
    request_context.dma_domain_id = 32'h1122_3344;
    request_context.owner_h = rdma_handle::type_id::create("cmq_owner");
    request_context.owner_h.kind = RDMA_RESOURCE_CMQ;
    request_context.owner_h.function_uid =
      request_context.function_h.function_uid;
    request_context.owner_h.object_id = 32'h44;
    request_context.owner_h.generation = request_context.function_h.generation;
    request_context_snapshot = rdma_dma_request_context::type_id::create(
      "vf_dma_context_snapshot"
    );
    request_context_snapshot.copy(request_context);

    hm = $unit::host_mem_manager::type_id::create("hm");
    hm.init_region(64'h0000_0001_0000_0000,
                   64'h0000_0001_00ff_ffff);
    adapter = rdma_host_mem_adapter::type_id::create("adapter");
    adapter.mem = hm;

    mapping = rdma_dma_mapping::type_id::create("non_null_seed");
    status = adapter.allocate(null, 64, 64, RDMA_DMA_BIDIRECTIONAL,
                              mapping);
    expect_status("ALLOC_NULL_CONTEXT", status, RDMA_SC_INVALID_ARGUMENT);
    if (mapping != null)
      `uvm_error("ALLOC_NULL_CONTEXT", "failure did not null the output")
    invalid_context = make_dma_context(
      "invalid_function_context", invalid_function_h, '0
    );
    status = adapter.allocate(invalid_context, 64, 64,
                              RDMA_DMA_BIDIRECTIONAL, mapping);
    expect_status("ALLOC_FUNCTION_KIND", status, RDMA_SC_INVALID_ARGUMENT);
    invalid_context = make_dma_context(
      "zero_generation_context", function_h, '0
    );
    invalid_context.function_h.generation = 0;
    status = adapter.allocate(invalid_context, 64, 64,
                              RDMA_DMA_BIDIRECTIONAL, mapping);
    expect_status("ALLOC_FUNCTION_GENERATION", status,
                  RDMA_SC_STALE_GENERATION);
    invalid_context = make_dma_context(
      "invalid_pasid_context", function_h, '0, 1'b0, 20'h1
    );
    status = adapter.allocate(invalid_context, 64, 64,
                              RDMA_DMA_BIDIRECTIONAL, mapping);
    expect_status("ALLOC_CONTEXT_PASID", status, RDMA_SC_INVALID_ARGUMENT);
    status = adapter.allocate(request_context, 0, 64,
                              RDMA_DMA_BIDIRECTIONAL,
                              mapping);
    expect_status("ALLOC_ZERO_SIZE", status, RDMA_SC_INVALID_ARGUMENT);
    status = adapter.allocate(request_context, 64, 0,
                              RDMA_DMA_BIDIRECTIONAL,
                              mapping);
    expect_status("ALLOC_ZERO_ALIGNMENT", status,
                  RDMA_SC_INVALID_ARGUMENT);
    status = adapter.allocate(request_context, 64, 3,
                              RDMA_DMA_BIDIRECTIONAL,
                              mapping);
    expect_status("ALLOC_NON_POWER_OF_TWO", status,
                  RDMA_SC_INVALID_ARGUMENT);
    status = adapter.allocate(request_context, 64, 64,
                              rdma_dma_direction_e'(3), mapping);
    expect_status("ALLOC_DIRECTION", status, RDMA_SC_INVALID_ARGUMENT);
    if (mapping != null)
      `uvm_error("ALLOC_FAILURE_OUTPUT", "invalid allocation returned mapping")

    // Owner cloning happens only after host backing has been obtained.  A
    // clone failure must therefore roll that backing back without committing
    // the IOVA configuration or cursor.
    owner_clone_hm = rdma_owner_clone_counting_host_mem::type_id::create(
      "owner_clone_hm"
    );
    owner_clone_hm.init_region(64'h0000_0005_0000_0000,
                               64'h0000_0005_00ff_ffff);
    owner_clone_adapter = rdma_host_mem_adapter::type_id::create(
      "owner_clone_adapter"
    );
    owner_clone_adapter.mem = owner_clone_hm;
    owner_clone_adapter.iova_base = 64'h0000_0000_6000_0000;
    owner_clone_context = make_dma_context(
      "owner_clone_context", request_context.function_h,
      request_context.requester_bdf, request_context.pasid_valid,
      request_context.pasid
    );
    owner_clone_failure_h =
      rdma_owner_clone_failure_handle::type_id::create(
        "owner_clone_failure_h"
      );
    owner_clone_failure_h.kind = RDMA_RESOURCE_CMQ;
    owner_clone_failure_h.function_uid =
      owner_clone_context.function_h.function_uid;
    owner_clone_failure_h.object_id = 32'h55;
    owner_clone_failure_h.generation =
      owner_clone_context.function_h.generation;
    owner_clone_context.owner_h = owner_clone_failure_h;
    status = owner_clone_context.validate();
    expect_status("OWNER_CLONE_CONTEXT_VALID", status, RDMA_SC_OK);
    owner_clone_mapping = rdma_dma_mapping::type_id::create(
      "owner_clone_non_null_seed"
    );
    status = owner_clone_adapter.allocate(
      owner_clone_context, 64, 64, RDMA_DMA_BIDIRECTIONAL,
      owner_clone_mapping
    );
    expect_status("OWNER_CLONE_FAILURE", status, RDMA_SC_INVALID_STATE);
    if (owner_clone_mapping != null)
      `uvm_error("OWNER_CLONE_FAILURE",
                 "failed owner clone returned a mapping")
    if (owner_clone_hm.free_call_count != 1)
      `uvm_error("OWNER_CLONE_FREE_COUNT",
                 $sformatf("owner clone rollback freed %0d times",
                           owner_clone_hm.free_call_count))
    status = owner_clone_adapter.check_leaks(leak_count);
    expect_status("OWNER_CLONE_ROLLBACK", status, RDMA_SC_OK);
    if (leak_count != 0)
      `uvm_error("OWNER_CLONE_ROLLBACK",
                 "owner clone failure leaked host backing")

    owner_clone_context.owner_h = null;
    owner_clone_adapter.iova_base = 64'h0000_0000_7000_0000;
    status = owner_clone_adapter.allocate(
      owner_clone_context, 64, 64, RDMA_DMA_BIDIRECTIONAL,
      owner_clone_followup_mapping
    );
    expect_status("OWNER_CLONE_CURSOR_ROLLBACK", status, RDMA_SC_OK);
    if (owner_clone_followup_mapping == null ||
        owner_clone_followup_mapping.iova.value !=
          64'h0000_0000_7000_0000)
      `uvm_error("OWNER_CLONE_CURSOR_ROLLBACK",
                 "failed owner clone committed IOVA state")
    status = owner_clone_adapter.\release (owner_clone_followup_mapping);
    expect_status("OWNER_CLONE_FOLLOWUP_RELEASE", status, RDMA_SC_OK);
    if (owner_clone_hm.free_call_count != 2)
      `uvm_error("OWNER_CLONE_FINAL_FREE_COUNT",
                 $sformatf("expected 2 total frees, got %0d",
                           owner_clone_hm.free_call_count))
    status = owner_clone_adapter.check_leaks(leak_count);
    expect_status("OWNER_CLONE_FINAL_LEAKS", status, RDMA_SC_OK);
    if (leak_count != 0)
      `uvm_error("OWNER_CLONE_FINAL_LEAKS",
                 "owner clone rollback test leaked host backing")

    // A request owner can clone successfully into a value whose next clone
    // fails.  Authority snapshot construction must report that failure
    // nonfatally and roll back both backing and pending IOVA state.
    authority_clone_hm =
      rdma_owner_clone_counting_host_mem::type_id::create(
        "authority_clone_hm"
      );
    authority_clone_hm.init_region(64'h0000_0006_0000_0000,
                                   64'h0000_0006_00ff_ffff);
    authority_clone_adapter = rdma_host_mem_adapter::type_id::create(
      "authority_clone_adapter"
    );
    authority_clone_adapter.mem = authority_clone_hm;
    authority_clone_adapter.iova_base = 64'h0000_0000_8000_0000;
    authority_clone_context = make_dma_context(
      "authority_clone_context", request_context.function_h,
      request_context.requester_bdf, request_context.pasid_valid,
      request_context.pasid
    );
    authority_clone_owner_h =
      rdma_owner_two_stage_clone_handle::type_id::create(
        "authority_clone_owner_h"
      );
    authority_clone_owner_h.kind = RDMA_RESOURCE_CMQ;
    authority_clone_owner_h.function_uid =
      authority_clone_context.function_h.function_uid;
    authority_clone_owner_h.object_id = 32'h66;
    authority_clone_owner_h.generation =
      authority_clone_context.function_h.generation;
    authority_clone_context.owner_h = authority_clone_owner_h;
    status = authority_clone_context.validate();
    expect_status("AUTHORITY_CLONE_CONTEXT_VALID", status, RDMA_SC_OK);
    authority_clone_mapping = rdma_dma_mapping::type_id::create(
      "authority_clone_non_null_seed"
    );
    status = authority_clone_adapter.allocate(
      authority_clone_context, 64, 64, RDMA_DMA_BIDIRECTIONAL,
      authority_clone_mapping
    );
    expect_status("AUTHORITY_CLONE_FAILURE", status,
                  RDMA_SC_INVALID_STATE);
    if (authority_clone_mapping != null)
      `uvm_error("AUTHORITY_CLONE_FAILURE",
                 "failed authority clone returned a mapping")
    if (authority_clone_hm.free_call_count != 1)
      `uvm_error("AUTHORITY_CLONE_FREE_COUNT",
                 $sformatf("authority clone rollback freed %0d times",
                           authority_clone_hm.free_call_count))
    status = authority_clone_adapter.check_leaks(leak_count);
    expect_status("AUTHORITY_CLONE_ROLLBACK", status, RDMA_SC_OK);
    if (leak_count != 0)
      `uvm_error("AUTHORITY_CLONE_ROLLBACK",
                 "authority clone failure leaked host backing")

    authority_alias_owner_h =
      rdma_owner_two_stage_alias_handle::type_id::create(
        "authority_alias_owner_h"
      );
    authority_alias_owner_h.kind = RDMA_RESOURCE_CMQ;
    authority_alias_owner_h.function_uid =
      authority_clone_context.function_h.function_uid;
    authority_alias_owner_h.object_id = 32'h67;
    authority_alias_owner_h.generation =
      authority_clone_context.function_h.generation;
    authority_clone_context.owner_h = authority_alias_owner_h;
    status = authority_clone_context.validate();
    expect_status("AUTHORITY_ALIAS_CONTEXT_VALID", status, RDMA_SC_OK);
    authority_clone_mapping = rdma_dma_mapping::type_id::create(
      "authority_alias_non_null_seed"
    );
    status = authority_clone_adapter.allocate(
      authority_clone_context, 64, 64, RDMA_DMA_BIDIRECTIONAL,
      authority_clone_mapping
    );
    expect_status("AUTHORITY_ALIAS_FAILURE", status,
                  RDMA_SC_INVALID_STATE);
    if (authority_clone_mapping != null)
      `uvm_error("AUTHORITY_ALIAS_FAILURE",
                 "aliased authority clone returned a mapping")
    if (authority_clone_hm.free_call_count != 2)
      `uvm_error("AUTHORITY_ALIAS_FREE_COUNT",
                 $sformatf("authority alias rollback freed %0d times",
                           authority_clone_hm.free_call_count))
    status = authority_clone_adapter.check_leaks(leak_count);
    expect_status("AUTHORITY_ALIAS_ROLLBACK", status, RDMA_SC_OK);
    if (leak_count != 0)
      `uvm_error("AUTHORITY_ALIAS_ROLLBACK",
                 "authority alias failure leaked host backing")

    authority_clone_context.owner_h = null;
    authority_clone_adapter.iova_base = 64'h0000_0000_9000_0000;
    status = authority_clone_adapter.allocate(
      authority_clone_context, 64, 64, RDMA_DMA_BIDIRECTIONAL,
      authority_clone_followup_mapping
    );
    expect_status("AUTHORITY_CLONE_CURSOR_ROLLBACK", status, RDMA_SC_OK);
    if (authority_clone_followup_mapping == null ||
        authority_clone_followup_mapping.iova.value !=
          64'h0000_0000_9000_0000)
      `uvm_error("AUTHORITY_CLONE_CURSOR_ROLLBACK",
                 "failed authority clone committed IOVA state")
    status = authority_clone_adapter.\release (
      authority_clone_followup_mapping
    );
    expect_status("AUTHORITY_CLONE_FOLLOWUP_RELEASE", status, RDMA_SC_OK);
    if (authority_clone_hm.free_call_count != 3)
      `uvm_error("AUTHORITY_CLONE_FINAL_FREE_COUNT",
                 $sformatf("expected 3 total frees, got %0d",
                           authority_clone_hm.free_call_count))
    status = authority_clone_adapter.check_leaks(leak_count);
    expect_status("AUTHORITY_CLONE_FINAL_LEAKS", status, RDMA_SC_OK);
    if (leak_count != 0)
      `uvm_error("AUTHORITY_CLONE_FINAL_LEAKS",
                 "authority clone rollback test leaked host backing")

    // The first real host allocation proves rejected requests did not reach
    // or advance the underlying allocator.
    external_addr = hm.alloc(64, 64, `__FILE__, `__LINE__);
    if (external_addr != 64'h0000_0001_0000_0000)
      `uvm_error("ALLOC_NO_SIDE_EFFECT",
                 $sformatf("unexpected first host address 0x%016h",
                           external_addr))
    hm.write_mem(external_addr, external_wr, `__FILE__, `__LINE__);

    status = adapter.allocate(request_context, 4096, 4096,
                              RDMA_DMA_BIDIRECTIONAL, mapping);
    expect_status("ALLOC_64BIT", status, RDMA_SC_OK);
    if (mapping == null)
      `uvm_fatal("ALLOC_64BIT", "successful allocation returned null")
    if (mapping.backing_addr.value < 64'h0000_0001_0000_0000 ||
        mapping.backing_addr.value[11:0] != 0)
      `uvm_error("ALLOC_64BIT", "backing is not aligned above 4 GiB")
    if (mapping.iova.value != mapping.backing_addr.value)
      `uvm_error("IDENTITY_IOVA", "default mapping is not explicit identity")
    if (mapping.size != 4096 ||
        mapping.direction != RDMA_DMA_BIDIRECTIONAL ||
        mapping.permissions.device_read != 1'b1 ||
        mapping.permissions.device_write != 1'b1 ||
        mapping.permissions.atomic != 1'b0 ||
        mapping.state != RDMA_MAPPING_ACTIVE)
      `uvm_error("MAPPING_FIELDS", "mapping metadata is inconsistent")
    if (mapping.function_h == null ||
        mapping.function_h == request_context.function_h ||
        !mapping.function_h.same_instance(request_context.function_h) ||
        mapping.requester_bdf != request_context.requester_bdf ||
        mapping.pasid_valid != request_context.pasid_valid ||
        mapping.pasid != request_context.pasid ||
        mapping.dma_domain_valid != request_context.dma_domain_valid ||
        mapping.dma_domain_id != request_context.dma_domain_id ||
        mapping.owner_h == null ||
        mapping.owner_h == request_context.owner_h ||
        !mapping.owner_h.same_instance(request_context.owner_h))
      `uvm_error("REQUEST_AUTHORITY_CLONE",
                 "DMA requester authority was not copied by value")

    valid_clone = clone_mapping("VALID_CLONE", mapping);
    stale_clone = clone_mapping("STALE_CLONE", mapping);

    request_context.function_h.generation++;
    request_context.requester_bdf.bus = 8'hff;
    request_context.pasid_valid = 1'b0;
    request_context.pasid = 20'h12345;
    request_context.dma_domain_valid = 1'b0;
    request_context.dma_domain_id = 32'hffff_ffff;
    request_context.owner_h.object_id = 32'hffff_ffff;
    if (mapping.function_h.generation !=
          request_context_snapshot.function_h.generation ||
        mapping.requester_bdf != request_context_snapshot.requester_bdf ||
        mapping.pasid_valid != request_context_snapshot.pasid_valid ||
        mapping.pasid != request_context_snapshot.pasid ||
        mapping.dma_domain_valid !=
          request_context_snapshot.dma_domain_valid ||
        mapping.dma_domain_id != request_context_snapshot.dma_domain_id ||
        mapping.owner_h == null ||
        mapping.owner_h.object_id != request_context_snapshot.owner_h.object_id ||
        valid_clone.function_h.generation !=
          request_context_snapshot.function_h.generation ||
        valid_clone.requester_bdf != request_context_snapshot.requester_bdf ||
        valid_clone.pasid_valid != request_context_snapshot.pasid_valid ||
        valid_clone.pasid != request_context_snapshot.pasid ||
        valid_clone.dma_domain_valid !=
          request_context_snapshot.dma_domain_valid ||
        valid_clone.dma_domain_id != request_context_snapshot.dma_domain_id ||
        valid_clone.owner_h == null ||
        valid_clone.owner_h.object_id !=
          request_context_snapshot.owner_h.object_id)
      `uvm_error("REQUEST_CONTEXT_VALUE_COPY",
                 "caller context mutation changed mapping authority")
    request_context.copy(request_context_snapshot);

    status = adapter.write(valid_clone, 0, wr);
    expect_status("ROUNDTRIP_WRITE", status, RDMA_SC_OK);
    status = adapter.read(valid_clone, 0, wr.size(), rd);
    expect_status("ROUNDTRIP_READ", status, RDMA_SC_OK);
    if (rd.size() != wr.size())
      `uvm_error("ROUNDTRIP_READ", "roundtrip size mismatch")
    else begin
      foreach (wr[i]) begin
        if (rd[i] != wr[i])
          `uvm_error("ROUNDTRIP_READ",
                     $sformatf("byte %0d mismatch", i))
      end
    end

    status = adapter.write(valid_clone, 4095, one_byte);
    expect_status("LAST_BYTE_WRITE", status, RDMA_SC_OK);
    status = adapter.read(valid_clone, 4095, 1, rd);
    expect_status("LAST_BYTE_READ", status, RDMA_SC_OK);
    if (rd.size() != 1 || rd[0] != one_byte[0])
      `uvm_error("LAST_BYTE_READ", "last byte did not roundtrip")

    status = adapter.write(valid_clone, 4094, wr);
    expect_status("CROSS_BOUNDARY_WRITE", status, RDMA_SC_DMA_TRANSLATION);
    rd = new[1];
    rd[0] = 8'hff;
    status = adapter.read(valid_clone, 4095, 2, rd);
    expect_status("CROSS_BOUNDARY_READ", status, RDMA_SC_DMA_TRANSLATION);
    expect_empty("CROSS_BOUNDARY_READ", rd);

    status = adapter.write(valid_clone, 4096, empty_write);
    expect_status("ZERO_LENGTH_WRITE", status, RDMA_SC_OK);
    rd = new[1];
    rd[0] = 8'hff;
    status = adapter.read(valid_clone, 4096, 0, rd);
    expect_status("ZERO_LENGTH_READ", status, RDMA_SC_OK);
    expect_empty("ZERO_LENGTH_READ", rd);
    status = adapter.write(valid_clone, 4097, empty_write);
    expect_status("ZERO_LENGTH_OUTSIDE", status,
                  RDMA_SC_DMA_TRANSLATION);

    status = adapter.write(valid_clone, 64'hffff_ffff_ffff_ffff,
                           one_byte);
    expect_status("OFFSET_65BIT_OVERFLOW", status,
                  RDMA_SC_DMA_TRANSLATION);
    rd = new[1];
    rd[0] = 8'hff;
    status = adapter.read(valid_clone, 64'hffff_ffff_ffff_ffff, 2, rd);
    expect_status("READ_65BIT_OVERFLOW", status,
                  RDMA_SC_DMA_TRANSLATION);
    expect_empty("READ_65BIT_OVERFLOW", rd);

    status = adapter.allocate(request_context, 64, 64,
                              RDMA_DMA_DEVICE_READ,
                              mapping_b);
    expect_status("ALLOC_SECOND", status, RDMA_SC_OK);
    if (mapping_b == null || !mapping_b.permissions.device_read ||
        mapping_b.permissions.device_write || mapping_b.permissions.atomic)
      `uvm_error("READ_PERMISSIONS", "device-read permissions are wrong")
    status = adapter.write(mapping_b, 0, wr_b);
    expect_status("SECOND_SEED", status, RDMA_SC_OK);

    tampered = clone_mapping("TAMPER_FUNCTION", mapping);
    tampered.function_h.generation++;
    status = adapter.write(tampered, 0, one_byte);
    expect_status("TAMPER_FUNCTION", status, RDMA_SC_DMA_TRANSLATION);
    tampered = clone_mapping("TAMPER_REQUESTER_BDF", mapping);
    tampered.requester_bdf.function_num++;
    status = adapter.read(tampered, 0, 1, rd);
    expect_status("TAMPER_REQUESTER_BDF_READ", status,
                  RDMA_SC_DMA_TRANSLATION);
    expect_empty("TAMPER_REQUESTER_BDF_READ", rd);
    status = adapter.write(tampered, 0, one_byte);
    expect_status("TAMPER_REQUESTER_BDF_WRITE", status,
                  RDMA_SC_DMA_TRANSLATION);
    status = adapter.\release (tampered);
    expect_status("TAMPER_REQUESTER_BDF_RELEASE", status,
                  RDMA_SC_DMA_TRANSLATION);
    tampered = clone_mapping("TAMPER_PASID_VALID", mapping);
    tampered.pasid_valid = !tampered.pasid_valid;
    status = adapter.read(tampered, 0, 1, rd);
    expect_status("TAMPER_PASID_VALID_READ", status,
                  RDMA_SC_DMA_TRANSLATION);
    expect_empty("TAMPER_PASID_VALID_READ", rd);
    status = adapter.write(tampered, 0, one_byte);
    expect_status("TAMPER_PASID_VALID_WRITE", status,
                  RDMA_SC_DMA_TRANSLATION);
    status = adapter.\release (tampered);
    expect_status("TAMPER_PASID_VALID_RELEASE", status,
                  RDMA_SC_DMA_TRANSLATION);
    tampered = clone_mapping("TAMPER_PASID", mapping);
    tampered.pasid++;
    status = adapter.read(tampered, 0, 1, rd);
    expect_status("TAMPER_PASID_READ", status, RDMA_SC_DMA_TRANSLATION);
    expect_empty("TAMPER_PASID_READ", rd);
    status = adapter.write(tampered, 0, one_byte);
    expect_status("TAMPER_PASID_WRITE", status, RDMA_SC_DMA_TRANSLATION);
    status = adapter.\release (tampered);
    expect_status("TAMPER_PASID_RELEASE", status,
                  RDMA_SC_DMA_TRANSLATION);
    tampered = clone_mapping("TAMPER_OWNER", mapping);
    tampered.owner_h.object_id++;
    status = adapter.read(tampered, 0, 1, rd);
    expect_status("TAMPER_OWNER_READ", status, RDMA_SC_DMA_TRANSLATION);
    expect_empty("TAMPER_OWNER_READ", rd);
    status = adapter.write(tampered, 0, one_byte);
    expect_status("TAMPER_OWNER_WRITE", status, RDMA_SC_DMA_TRANSLATION);
    status = adapter.\release (tampered);
    expect_status("TAMPER_OWNER_RELEASE", status,
                  RDMA_SC_DMA_TRANSLATION);
    tampered = clone_mapping("TAMPER_BACKING", mapping);
    tampered.backing_addr.value++;
    status = adapter.read(tampered, 0, 1, rd);
    expect_status("TAMPER_BACKING", status, RDMA_SC_DMA_TRANSLATION);
    expect_empty("TAMPER_BACKING", rd);
    tampered = clone_mapping("TAMPER_IOVA", mapping);
    tampered.iova.value++;
    status = adapter.write(tampered, 0, one_byte);
    expect_status("TAMPER_IOVA", status, RDMA_SC_DMA_TRANSLATION);
    tampered = clone_mapping("TAMPER_SIZE", mapping);
    tampered.size++;
    status = adapter.read(tampered, 0, 1, rd);
    expect_status("TAMPER_SIZE", status, RDMA_SC_DMA_TRANSLATION);
    expect_empty("TAMPER_SIZE", rd);
    tampered = clone_mapping("TAMPER_DIRECTION", mapping);
    tampered.direction = RDMA_DMA_DEVICE_READ;
    status = adapter.write(tampered, 0, one_byte);
    expect_status("TAMPER_DIRECTION", status, RDMA_SC_DMA_TRANSLATION);
    tampered = clone_mapping("TAMPER_PERMISSION", mapping);
    tampered.permissions.atomic = 1'b1;
    status = adapter.write(tampered, 0, one_byte);
    expect_status("TAMPER_PERMISSION", status, RDMA_SC_DMA_TRANSLATION);

    forged_mapping = rdma_dma_mapping::type_id::create("forged_mapping");
    forged_mapping.copy(mapping);
    status = adapter.read(forged_mapping, 0, 1, rd);
    expect_status("FORGED_MAPPING", status, RDMA_SC_DMA_TRANSLATION);
    expect_empty("FORGED_MAPPING", rd);

    copy_attack = clone_mapping("COPY_ATTACK", mapping);
    copy_attack.copy(mapping_b);
    status = adapter.write(copy_attack, 0, one_byte);
    expect_status("COPY_IDENTITY_ATTACK", status,
                  RDMA_SC_DMA_TRANSLATION);
    status = adapter.read(mapping_b, 0, wr_b.size(), rd);
    expect_status("COPY_TARGET_UNCHANGED", status, RDMA_SC_OK);
    if (rd.size() != wr_b.size() || rd[0] != wr_b[0] || rd[3] != wr_b[3])
      `uvm_error("COPY_TARGET_UNCHANGED",
                 "copy attack redirected to another allocation")

    request_context.function_h.generation = 32'd99;
    if (mapping.function_h == null || mapping.function_h.generation != 17)
      `uvm_error("FUNCTION_VALUE_COPY", "caller mutation aliased mapping")
    request_context.copy(request_context_snapshot);

    status = adapter.\release (mapping_b);
    expect_status("RELEASE_SECOND", status, RDMA_SC_OK);
    if (mapping_b.state != RDMA_MAPPING_RELEASED)
      `uvm_error("RELEASE_SECOND", "release did not mark caller mapping")
    status = adapter.\release (valid_clone);
    expect_status("RELEASE_PRIMARY", status, RDMA_SC_OK);
    if (valid_clone.state != RDMA_MAPPING_RELEASED)
      `uvm_error("RELEASE_PRIMARY", "release did not mark caller mapping")
    rd = new[1];
    rd[0] = 8'hff;
    status = adapter.read(stale_clone, 0, 1, rd);
    expect_status("USE_AFTER_RELEASE_READ", status,
                  RDMA_SC_INVALID_STATE);
    expect_empty("USE_AFTER_RELEASE_READ", rd);
    status = adapter.write(mapping, 0, one_byte);
    expect_status("USE_AFTER_RELEASE_WRITE", status,
                  RDMA_SC_INVALID_STATE);
    status = adapter.\release (valid_clone);
    expect_status("DOUBLE_RELEASE", status, RDMA_SC_INVALID_STATE);

    // A caller-owned allocation in the same global manager is not part of
    // this adapter's ledger and must remain allocated after adapter release.
    hm.read_mem(external_addr, external_wr.size(), external_rd,
                `__FILE__, `__LINE__);
    if (external_rd.size() != external_wr.size() ||
        external_rd[0] != external_wr[0] ||
        external_rd[3] != external_wr[3])
      `uvm_error("EXTERNAL_ALLOCATION", "adapter released caller memory")
    hm.free(external_addr, `__FILE__, `__LINE__);
    status = adapter.check_leaks(leak_count);
    expect_status("IDENTITY_LEAKS", status, RDMA_SC_OK);
    if (leak_count != 0)
      `uvm_error("IDENTITY_LEAKS", "adapter ledger is not empty")

    // A non-zero iova_base is the first end-exclusive IOVA cursor.  Each
    // successful mapping aligns that cursor and advances it by mapping size.
    offset_hm = $unit::host_mem_manager::type_id::create("offset_hm");
    offset_hm.init_region(64'h0000_0002_0000_0000,
                          64'h0000_0002_00ff_ffff);
    offset_adapter = rdma_host_mem_adapter::type_id::create("offset_adapter");
    offset_adapter.mem = offset_hm;
    offset_adapter.iova_base = 64'h0000_0000_4000_0000;
    status = offset_adapter.allocate(request_context, 64, 64,
                                     RDMA_DMA_DEVICE_WRITE,
                                     offset_mapping_a);
    expect_status("OFFSET_ALLOC_A", status, RDMA_SC_OK);

    offset_adapter.iova_base = 64'h0000_0000_5000_0000;
    offset_rejected_nonzero = rdma_dma_mapping::type_id::create(
      "offset_rejected_nonzero_seed"
    );
    status = offset_adapter.allocate(request_context, 64, 64,
                                     RDMA_DMA_BIDIRECTIONAL,
                                     offset_rejected_nonzero);
    expect_status("OFFSET_REBASE_NONZERO", status, RDMA_SC_INVALID_STATE);
    if (offset_rejected_nonzero != null)
      `uvm_error("OFFSET_REBASE_NONZERO",
                 "IOVA reconfiguration returned a mapping")

    offset_adapter.iova_base = 64'h0000_0000_0000_0000;
    offset_rejected_identity = rdma_dma_mapping::type_id::create(
      "offset_rejected_identity_seed"
    );
    status = offset_adapter.allocate(request_context, 64, 64,
                                     RDMA_DMA_BIDIRECTIONAL,
                                     offset_rejected_identity);
    expect_status("OFFSET_REBASE_IDENTITY", status, RDMA_SC_INVALID_STATE);
    if (offset_rejected_identity != null)
      `uvm_error("OFFSET_REBASE_IDENTITY",
                 "IOVA identity switch returned a mapping")

    offset_adapter.iova_base = 64'h0000_0000_4000_0000;
    status = offset_adapter.allocate(request_context, 64, 64,
                                     RDMA_DMA_BIDIRECTIONAL,
                                     offset_mapping_b);
    expect_status("OFFSET_ALLOC_B", status, RDMA_SC_OK);
    status = offset_adapter.allocate(request_context, 128, 256,
                                     RDMA_DMA_BIDIRECTIONAL,
                                     offset_mapping_c);
    expect_status("OFFSET_ALLOC_C", status, RDMA_SC_OK);
    if (offset_mapping_a == null || offset_mapping_b == null ||
        offset_mapping_c == null)
      `uvm_fatal("OFFSET_ALLOC", "offset allocation returned null")
    if (offset_mapping_a.iova.value != 64'h0000_0000_4000_0000 ||
        offset_mapping_a.iova.value == offset_mapping_a.backing_addr.value)
      `uvm_error("OFFSET_BASE", "first offset IOVA is incorrect")
    if (offset_mapping_b.backing_addr.value !=
          64'h0000_0002_0000_0040 ||
        offset_mapping_b.iova.value != 64'h0000_0000_4000_0040)
      `uvm_error("OFFSET_REBASE_NO_ADVANCE",
                 "rejected reconfiguration advanced backing or IOVA state")
    if (offset_mapping_c.iova.value != 64'h0000_0000_4000_0100 ||
        offset_mapping_c.iova.value <
          offset_mapping_b.iova.value + offset_mapping_b.size)
      `uvm_error("OFFSET_NON_OVERLAP", "offset IOVA ranges overlap")
    if (offset_mapping_a.permissions.device_read ||
        !offset_mapping_a.permissions.device_write ||
        offset_mapping_a.permissions.atomic)
      `uvm_error("WRITE_PERMISSIONS", "device-write permissions are wrong")
    status = offset_adapter.\release (offset_mapping_a);
    expect_status("OFFSET_RELEASE_A", status, RDMA_SC_OK);
    status = offset_adapter.\release (offset_mapping_b);
    expect_status("OFFSET_RELEASE_B", status, RDMA_SC_OK);
    status = offset_adapter.\release (offset_mapping_c);
    expect_status("OFFSET_RELEASE_C", status, RDMA_SC_OK);
    if (offset_rejected_nonzero != null) begin
      status = offset_adapter.\release (offset_rejected_nonzero);
      expect_status("OFFSET_REBASE_NONZERO_CLEANUP", status, RDMA_SC_OK);
    end
    if (offset_rejected_identity != null) begin
      status = offset_adapter.\release (offset_rejected_identity);
      expect_status("OFFSET_REBASE_IDENTITY_CLEANUP", status, RDMA_SC_OK);
    end
    status = offset_adapter.check_leaks(leak_count);
    expect_status("OFFSET_LEAKS", status, RDMA_SC_OK);
    if (leak_count != 0)
      `uvm_error("OFFSET_LEAKS", "offset adapter ledger is not empty")

    // IOVA arithmetic failure rolls back the real backing allocation and
    // does not advance the cursor.  The same base is reusable immediately.
    overflow_hm = $unit::host_mem_manager::type_id::create("overflow_hm");
    overflow_hm.init_region(64'h0000_0003_0000_0000,
                            64'h0000_0003_00ff_ffff);
    overflow_adapter = rdma_host_mem_adapter::type_id::create(
      "overflow_adapter"
    );
    overflow_adapter.mem = overflow_hm;
    overflow_adapter.iova_base = 64'hffff_ffff_ffff_fff0;
    status = overflow_adapter.allocate(request_context, 32, 16,
                                       RDMA_DMA_BIDIRECTIONAL,
                                       overflow_mapping);
    expect_status("IOVA_END_OVERFLOW", status,
                  RDMA_SC_RESOURCE_EXHAUSTED);
    if (overflow_mapping != null)
      `uvm_error("IOVA_END_OVERFLOW", "failed allocation returned mapping")
    status = overflow_adapter.allocate(request_context, 16, 16,
                                       RDMA_DMA_BIDIRECTIONAL,
                                       overflow_mapping);
    expect_status("IOVA_CURSOR_ROLLBACK", status, RDMA_SC_OK);
    if (overflow_mapping == null ||
        overflow_mapping.backing_addr.value !=
          64'h0000_0003_0000_0000 ||
        overflow_mapping.iova.value != 64'hffff_ffff_ffff_fff0)
      `uvm_error("IOVA_CURSOR_ROLLBACK",
                 "failed allocation advanced backing or IOVA state")
    status = overflow_adapter.\release (overflow_mapping);
    expect_status("OVERFLOW_RELEASE", status, RDMA_SC_OK);
    status = overflow_adapter.check_leaks(leak_count);
    expect_status("OVERFLOW_LEAKS", status, RDMA_SC_OK);

    // Equal numeric addresses from independent managers/adapters remain
    // distinct because allocation identity and adapter ownership are opaque.
    equal_hm_a = $unit::host_mem_manager::type_id::create("equal_hm_a");
    equal_hm_b = $unit::host_mem_manager::type_id::create("equal_hm_b");
    equal_hm_a.init_region(64'h0000_0005_0000_0000,
                           64'h0000_0005_000f_ffff);
    equal_hm_b.init_region(64'h0000_0005_0000_0000,
                           64'h0000_0005_000f_ffff);
    equal_adapter_a = rdma_host_mem_adapter::type_id::create(
      "equal_adapter_a"
    );
    equal_adapter_b = rdma_host_mem_adapter::type_id::create(
      "equal_adapter_b"
    );
    equal_adapter_a.mem = equal_hm_a;
    equal_adapter_b.mem = equal_hm_b;
    status = equal_adapter_a.allocate(request_context, 64, 64,
                                      RDMA_DMA_BIDIRECTIONAL,
                                      equal_mapping_a);
    expect_status("EQUAL_ALLOC_A", status, RDMA_SC_OK);
    status = equal_adapter_b.allocate(request_context, 64, 64,
                                      RDMA_DMA_BIDIRECTIONAL,
                                      equal_mapping_b);
    expect_status("EQUAL_ALLOC_B", status, RDMA_SC_OK);
    if (equal_mapping_a.backing_addr != equal_mapping_b.backing_addr ||
        equal_mapping_a.iova != equal_mapping_b.iova)
      `uvm_error("EQUAL_NUMERIC_VALUES", "test setup did not alias values")
    status = equal_adapter_a.write(equal_mapping_b, 0, one_byte);
    expect_status("WRONG_ADAPTER", status, RDMA_SC_DMA_TRANSLATION);
    status = equal_adapter_a.\release (equal_mapping_b);
    expect_status("WRONG_ADAPTER_RELEASE", status,
                  RDMA_SC_DMA_TRANSLATION);
    status = equal_adapter_a.\release (equal_mapping_a);
    expect_status("EQUAL_RELEASE_A", status, RDMA_SC_OK);
    status = equal_adapter_b.\release (equal_mapping_b);
    expect_status("EQUAL_RELEASE_B", status, RDMA_SC_OK);
    status = equal_adapter_a.check_leaks(leak_count);
    expect_status("EQUAL_LEAKS_A", status, RDMA_SC_OK);
    status = equal_adapter_b.check_leaks(leak_count);
    expect_status("EQUAL_LEAKS_B", status, RDMA_SC_OK);

    phase.drop_objection(this);
  endtask
endclass
