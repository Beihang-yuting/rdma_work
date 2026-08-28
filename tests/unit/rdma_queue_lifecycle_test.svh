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

  task run_phase(uvm_phase phase);
    phase.raise_objection(this);
    check_preflight();
    check_contexts_and_commands();
    phase.drop_objection(this);
  endtask
endclass
