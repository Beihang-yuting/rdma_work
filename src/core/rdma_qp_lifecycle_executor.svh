class rdma_qp_lifecycle_executor extends uvm_object;
  `uvm_object_utils(rdma_qp_lifecycle_executor)

  protected rdma_resource_manager manager;
  protected rdma_cmq_port cmq;
  protected rdma_host_mem_api host_mem;
  protected rdma_context_backing_api context_backing;
  protected time command_timeout;
  protected rdma_xtr_v1_queue_pd_codec pd_codec;
  protected rdma_codec_registry qpc_codecs;

  function new(string name = "rdma_qp_lifecycle_executor");
    super.new(name);
    manager = null;
    cmq = null;
    host_mem = null;
    context_backing = null;
    command_timeout = 0;
    pd_codec = rdma_xtr_v1_queue_pd_codec::type_id::create({name, "_pd"});
    qpc_codecs = rdma_codec_registry::type_id::create({name, "_qpc"});
  endfunction

  protected function rdma_status invalid_argument(string message);
    return rdma_status::make(RDMA_SC_INVALID_ARGUMENT, message);
  endfunction

  protected function rdma_status invalid_state(string message);
    return rdma_status::make(RDMA_SC_INVALID_STATE, message);
  endfunction

  protected function rdma_status normalize_status(rdma_status status,
                                                   string message);
    return status == null ? invalid_state(message) : status;
  endfunction

  function rdma_status configure(
    rdma_resource_manager manager,
    rdma_cmq_port cmq,
    rdma_host_mem_api host_mem,
    rdma_context_backing_api context_backing,
    time command_timeout
  );
    rdma_status status;

    if (manager == null || cmq == null || host_mem == null ||
        context_backing == null || command_timeout == 0)
      return invalid_argument("QP executor configuration is incomplete");
    if (pd_codec == null || qpc_codecs == null)
      return invalid_state("QP executor codec construction failed");
    qpc_codecs.clear();
    status = rdma_xtr_v1_register_qpc_codecs(qpc_codecs);
    if (status == null || !status.ok())
      return normalize_status(status, "QP codec registration returned null");
    this.manager = manager;
    this.cmq = cmq;
    this.host_mem = host_mem;
    this.context_backing = context_backing;
    this.command_timeout = command_timeout;
    return rdma_status::success();
  endfunction

  protected function rdma_status make_dma_context(
    rdma_function_binding binding,
    rdma_handle qp_h,
    rdma_queue_backing_role_e role,
    output rdma_dma_request_context request_context
  );
    request_context = null;
    if (binding == null || qp_h == null)
      return invalid_argument("QP DMA context input is null");
    request_context = rdma_dma_request_context::type_id::create(
      "qp_backing_request_context"
    );
    if (request_context == null)
      return rdma_status::make(RDMA_SC_RESOURCE_EXHAUSTED,
                               "QP DMA context allocation failed");
    request_context.function_h = binding.make_handle();
    request_context.requester_bdf = binding.queue_dma.requester_bdf;
    request_context.pasid_valid = binding.queue_dma.pasid_valid;
    request_context.pasid = binding.queue_dma.pasid;
    request_context.dma_domain_valid = binding.queue_dma.dma_domain_valid;
    request_context.dma_domain_id = binding.queue_dma.dma_domain_id;
    request_context.owner_h = rdma_clone_handle_value(qp_h, "QP DMA owner");
    request_context.queue_role_valid = 1'b1;
    request_context.queue_role = int'(role);
    return normalize_status(request_context.validate(),
                            "QP DMA context validation returned null");
  endfunction

  protected function rdma_status allocate_ref(
    rdma_function_binding binding,
    rdma_handle qp_h,
    rdma_queue_backing_role_e role,
    longint unsigned length,
    rdma_dma_direction_e direction,
    output rdma_qp_backing_ref backing_ref
  );
    rdma_dma_request_context request_context;
    rdma_dma_mapping mapping;
    rdma_dma_mapping authority;
    rdma_status status;

    backing_ref = null;
    if (length == 0 || length > 32'hffff_ffff || host_mem == null)
      return invalid_argument("QP backing allocation geometry is invalid");
    status = make_dma_context(binding, qp_h, role, request_context);
    if (!status.ok()) return status;
    mapping = null;
    status = normalize_status(host_mem.allocate(request_context, int'(length),
      4096, direction, mapping), "QP backing allocation returned null");
    if (!status.ok()) return status;
    if (mapping == null || mapping.size < length ||
        (mapping.iova.value & 64'hfff) != 0 ||
        (mapping.backing_addr.value & 64'hfff) != 0)
      return invalid_state("QP backing allocation geometry is invalid");
    status = normalize_status(mapping.snapshot_release_authority(authority),
                              "QP backing authority snapshot returned null");
    if (!status.ok() || authority == null) return status.ok() ?
      invalid_state("QP backing authority snapshot is null") : status;
    authority.copy(mapping);
    backing_ref = rdma_qp_backing_ref::type_id::create(
      $sformatf("qp_ref_%0d", role)
    );
    if (backing_ref == null)
      return rdma_status::make(RDMA_SC_RESOURCE_EXHAUSTED,
                               "QP backing reference allocation failed");
    backing_ref.role = role;
    backing_ref.mapping = authority;
    backing_ref.ownership = RDMA_OWNERSHIP_CONTROL_PLANE;
    backing_ref.mapping_offset = 0;
    backing_ref.length = length;
    return backing_ref.validate();
  endfunction

  protected function rdma_status clone_borrowed_ref(
    rdma_queue_backing_spec spec,
    rdma_queue_backing_role_e role,
    longint unsigned length,
    output rdma_qp_backing_ref backing_ref
  );
    uvm_object cloned;

    backing_ref = null;
    if (spec == null || spec.slices.size() != 1 || spec.slices[0] == null ||
        spec.slices[0].mapping == null || spec.slices[0].role != role ||
        spec.slices[0].logical_queue_offset != 0 ||
        spec.slices[0].length != length)
      return invalid_argument("QP borrowed backing is not one canonical range");
    backing_ref = rdma_qp_backing_ref::type_id::create("qp_borrowed_ref");
    if (backing_ref == null)
      return rdma_status::make(RDMA_SC_RESOURCE_EXHAUSTED,
                               "QP borrowed reference allocation failed");
    cloned = spec.slices[0].mapping.clone();
    if (cloned == null || !$cast(backing_ref.mapping, cloned) ||
        backing_ref.mapping == spec.slices[0].mapping)
      return invalid_state("QP borrowed mapping clone failed");
    backing_ref.role = role;
    backing_ref.ownership = RDMA_OWNERSHIP_BORROWED;
    backing_ref.mapping_offset = spec.slices[0].mapping_offset;
    backing_ref.length = length;
    return backing_ref.validate();
  endfunction

  protected function rdma_status make_ring(
    rdma_queue_backing_role_e role,
    int unsigned depth,
    output rdma_qp_ring_layout ring
  );
    longint unsigned logical_bytes;

    ring = null;
    if (!rdma_qp_power_of_two(depth) || longint'(depth) >
        64'hffff_ffff_ffff_ffff / 64)
      return invalid_argument("QP ring depth is invalid");
    logical_bytes = longint'(depth) * 64;
    if (logical_bytes > 64'hffff_ffff_ffff_efff)
      return invalid_argument("QP ring alignment overflows");
    ring = rdma_qp_ring_layout::type_id::create("qp_ring");
    if (ring == null)
      return rdma_status::make(RDMA_SC_RESOURCE_EXHAUSTED,
                               "QP ring allocation failed");
    ring.role = role;
    ring.depth = depth;
    ring.entry_size_bytes = 64;
    ring.logical_bytes = logical_bytes;
    ring.storage_bytes = ((logical_bytes + 4095) / 4096) * 4096;
    ring.object_mode = RDMA_OBJECT_INDIRECT_4K;
    return ring.validate();
  endfunction

  protected function rdma_status zero_and_encode_pd(
    rdma_function_binding binding,
    rdma_qp_backing_ref payload_ref,
    rdma_qp_backing_ref pd_ref
  );
    byte zeros[];
    byte unsigned entries[];
    byte pd_bytes[];
    rdma_queue_dma_page_ref pages[$];
    rdma_queue_dma_page_ref page;
    rdma_status status;

    zeros = new[int'(payload_ref.length)];
    foreach (zeros[i]) zeros[i] = 0;
    status = normalize_status(host_mem.write(payload_ref.mapping,
      payload_ref.mapping_offset, zeros), "QP payload zero-write returned null");
    if (!status.ok()) return status;
    for (longint unsigned offset = 0; offset < payload_ref.length;
         offset += 4096) begin
      page = rdma_queue_dma_page_ref::type_id::create("qp_pd_page");
      if (page == null)
        return rdma_status::make(RDMA_SC_RESOURCE_EXHAUSTED,
                                 "QP page-directory page allocation failed");
      // Page-directory entries carry only page IOVAs.  The established page
      // reference validator predates QP-only roles, so use its neutral ring
      // discriminator while preserving QP role authority in the plan/ref.
      page.role = RDMA_QUEUE_ROLE_CQ_RING;
      page.mapping = payload_ref.mapping;
      page.mapping_offset = payload_ref.mapping_offset + offset;
      page.logical_page_offset = offset;
      page.page_iova.value = payload_ref.mapping.iova.value +
                             payload_ref.mapping_offset + offset;
      status = page.validate();
      if (!status.ok()) return status;
      pages.push_back(page);
    end
    entries = new[0];
    status = normalize_status(pd_codec.encode_table(pages, binding.rdma_vf_id,
      entries), "QP page-directory codec returned null");
    if (!status.ok()) return status;
    if (entries.size() != 4096)
      return invalid_state("QP page directory is not one 4 KiB page");
    pd_bytes = new[entries.size()];
    foreach (entries[i]) pd_bytes[i] = entries[i];
    return normalize_status(host_mem.write(pd_ref.mapping, pd_ref.mapping_offset,
      pd_bytes), "QP page-directory write returned null");
  endfunction

  protected function rdma_qp_backing_ref find_urc_ref(
    rdma_qp_backing_plan plan, rdma_queue_backing_role_e role
  );
    foreach (plan.urc_refs[i])
      if (plan.urc_refs[i] != null && plan.urc_refs[i].role == role)
        return plan.urc_refs[i];
    return null;
  endfunction

  protected function rdma_status materialize_plan(
    rdma_function_binding binding,
    rdma_qp qp_snapshot,
    rdma_create_qp_req request,
    output rdma_qp_backing_plan plan
  );
    rdma_status status;
    rdma_qp_backing_ref ref_value;

    plan = null;
    if (binding == null || qp_snapshot == null || request == null ||
        qp_snapshot.handle == null)
      return invalid_argument("QP plan materialization input is null");
    status = request.validate_queue_caps(binding.queue_caps);
    if (!status.ok()) return status;
    if (qp_snapshot.local_qp_id > 21'h1f_ffff)
      return invalid_argument("QP local QPN exceeds 21 bits");
    plan = rdma_qp_backing_plan::type_id::create("materialized_qp_plan");
    if (plan == null)
      return rdma_status::make(RDMA_SC_RESOURCE_EXHAUSTED,
                               "QP plan allocation failed");
    plan.transport = request.transport;
    plan.sq_depth = request.sq_depth;
    plan.rq_depth = request.rq_depth;
    status = make_ring(RDMA_QUEUE_ROLE_QP_SQ_RING, request.sq_depth,
                       plan.sq_ring);
    if (!status.ok()) return status;
    if (request.sq_backing.mode == RDMA_QUEUE_BACKING_OWNED)
      status = allocate_ref(binding, qp_snapshot.handle,
        RDMA_QUEUE_ROLE_QP_SQ_RING, plan.sq_ring.storage_bytes,
        RDMA_DMA_DEVICE_READ, plan.sq_ref);
    else
      status = clone_borrowed_ref(request.sq_backing,
        RDMA_QUEUE_ROLE_QP_SQ_RING, plan.sq_ring.storage_bytes, plan.sq_ref);
    if (!status.ok()) return status;
    status = allocate_ref(binding, qp_snapshot.handle, RDMA_QUEUE_ROLE_QP_SQ_PD,
                          4096, RDMA_DMA_DEVICE_READ, plan.sq_pd_ref);
    if (!status.ok()) return status;
    status = zero_and_encode_pd(binding, plan.sq_ref, plan.sq_pd_ref);
    if (!status.ok()) return status;
    if (request.srq_h != null) begin
      rdma_resource source;
      rdma_srq srq;
      status = normalize_status(manager.lookup(request.srq_h, source),
        "QP SRQ lookup returned null");
      if (!status.ok() || !$cast(srq, source)) return status.ok() ?
        invalid_state("QP SRQ dependency is not an SRQ") : status;
      status = request.validate_srq_depth(srq.depth);
      if (!status.ok()) return status;
      // Retain the manager-projected handle object so the QP resource and
      // plan carry one identity authority through later publication copies.
      plan.rq_source_h = qp_snapshot.srq_h;
    end else begin
      status = make_ring(RDMA_QUEUE_ROLE_QP_RQ_RING, request.rq_depth,
                         plan.rq_ring);
      if (!status.ok()) return status;
      if (request.rq_backing.mode == RDMA_QUEUE_BACKING_OWNED)
        status = allocate_ref(binding, qp_snapshot.handle,
          RDMA_QUEUE_ROLE_QP_RQ_RING, plan.rq_ring.storage_bytes,
          RDMA_DMA_DEVICE_READ, plan.rq_ref);
      else
        status = clone_borrowed_ref(request.rq_backing,
          RDMA_QUEUE_ROLE_QP_RQ_RING, plan.rq_ring.storage_bytes, plan.rq_ref);
      if (!status.ok()) return status;
      status = allocate_ref(binding, qp_snapshot.handle,
        RDMA_QUEUE_ROLE_QP_RQ_PD, 4096, RDMA_DMA_DEVICE_READ, plan.rq_pd_ref);
      if (!status.ok()) return status;
      status = zero_and_encode_pd(binding, plan.rq_ref, plan.rq_pd_ref);
      if (!status.ok()) return status;
    end
    if (request.transport == RDMA_TRANSPORT_URC) begin
      status = allocate_ref(binding, qp_snapshot.handle,
        RDMA_QUEUE_ROLE_QP_URC_RSQ, 4096, RDMA_DMA_BIDIRECTIONAL, ref_value);
      if (!status.ok()) return status;
      plan.urc_refs.push_back(ref_value);
      status = allocate_ref(binding, qp_snapshot.handle,
        RDMA_QUEUE_ROLE_QP_URC_RDSQ, 4096, RDMA_DMA_BIDIRECTIONAL, ref_value);
      if (!status.ok()) return status;
      plan.urc_refs.push_back(ref_value);
      status = allocate_ref(binding, qp_snapshot.handle,
        RDMA_QUEUE_ROLE_QP_URC_DSQ, 8192, RDMA_DMA_BIDIRECTIONAL, ref_value);
      if (!status.ok()) return status;
      plan.urc_refs.push_back(ref_value);
    end
    status = normalize_status(context_backing.acquire(binding, RDMA_RESOURCE_QP,
      qp_snapshot.local_qp_id, plan.context_ref),
      "QP context acquire returned null");
    if (!status.ok()) return status;
    return plan.validate();
  endfunction

  protected function rdma_status local_handle(
    rdma_handle source, rdma_resource_kind_e kind, int unsigned local_id,
    string label, output rdma_handle projected
  );
    projected = rdma_clone_handle_value(source, label);
    if (projected == null || projected.kind != kind)
      return invalid_state({label, " projection is invalid"});
    projected.object_id = local_id;
    return rdma_status::success();
  endfunction

  function rdma_status build_qpc_model(
    rdma_function_binding binding,
    rdma_qp qp_snapshot,
    rdma_create_qp_req request,
    rdma_qp_backing_plan plan,
    output rdma_qpc_model model
  );
    rdma_status status;
    rdma_resource dependency;
    rdma_pd pd;
    rdma_cq send_cq;
    rdma_cq recv_cq;
    rdma_srq srq;
    uvm_object cloned;
    rdma_qpc_urc_ext urc_ext;
    rdma_qp_backing_ref urc_ref;
    bit [7:0] qp_sequence_value;

    model = null;
    if (binding == null || qp_snapshot == null || request == null || plan == null ||
        qp_snapshot.handle == null || request.context_attrs == null)
      return invalid_argument("QPC builder input is null");
    status = normalize_status(plan.validate(), "QP plan validation returned null");
    if (!status.ok()) return status;
    status = normalize_status(manager.lookup(qp_snapshot.pd_h, dependency),
                              "QPC PD lookup returned null");
    if (!status.ok() || !$cast(pd, dependency)) return status.ok() ?
      invalid_state("QPC PD dependency is invalid") : status;
    status = normalize_status(manager.lookup(qp_snapshot.send_cq_h, dependency),
                              "QPC send CQ lookup returned null");
    if (!status.ok() || !$cast(send_cq, dependency)) return status.ok() ?
      invalid_state("QPC send CQ dependency is invalid") : status;
    status = normalize_status(manager.lookup(qp_snapshot.recv_cq_h, dependency),
                              "QPC receive CQ lookup returned null");
    if (!status.ok() || !$cast(recv_cq, dependency)) return status.ok() ?
      invalid_state("QPC receive CQ dependency is invalid") : status;
    if (qp_snapshot.local_qp_id > 21'h1f_ffff)
      return invalid_argument("QPC local QPN exceeds 21 bits");
    model = rdma_qpc_model::type_id::create("semantic_qpc");
    if (model == null)
      return rdma_status::make(RDMA_SC_RESOURCE_EXHAUSTED,
                               "QPC model allocation failed");
    status = local_handle(qp_snapshot.handle, RDMA_RESOURCE_QP,
                          qp_snapshot.local_qp_id, "QPC QP", model.qp_h);
    if (status.ok()) status = local_handle(qp_snapshot.pd_h, RDMA_RESOURCE_PD,
      pd.local_pd_id, "QPC PD", model.pd_h);
    if (status.ok()) status = local_handle(qp_snapshot.send_cq_h,
      RDMA_RESOURCE_CQ, send_cq.local_cq_id, "QPC send CQ", model.send_cq_h);
    if (status.ok()) status = local_handle(qp_snapshot.recv_cq_h,
      RDMA_RESOURCE_CQ, recv_cq.local_cq_id, "QPC receive CQ", model.recv_cq_h);
    if (!status.ok()) return status;
    model.transport = request.transport;
    model.state = RDMA_QPS_RESET;
    model.host_id = binding.host_id;
    model.vf_id = binding.rdma_vf_id;
    model.stat_index = qp_snapshot.local_qp_id & 8'hff;
    status = normalize_status(manager.qp_sequence(binding.make_handle(),
      qp_snapshot.local_qp_id, qp_sequence_value), "QPC sequence lookup returned null");
    if (!status.ok()) return status;
    model.qp_sequence = qp_sequence_value;
    model.pkey = request.context_attrs.pkey;
    model.access = request.context_attrs.access;
    model.path_mtu_bytes = request.context_attrs.path_mtu_bytes;
    model.sq_depth = plan.sq_depth;
    model.rq_depth = plan.rq_depth;
    model.sq_backing.value = plan.sq_pd_ref.mapping.iova.value +
                             plan.sq_pd_ref.mapping_offset;
    model.sq_mode = plan.sq_ring.object_mode;
    model.context_backing = plan.context_ref.shadow_pointer_base;
    model.signature_enable = request.context_attrs.signature_enable;
    model.tx_flow_control = request.context_attrs.tx_flow_control;
    model.rx_flow_control = request.context_attrs.rx_flow_control;
    cloned = request.context_attrs.address_vector.clone();
    if (cloned == null || !$cast(model.address_vector, cloned))
      return invalid_state("QPC address-vector clone failed");
    cloned = request.context_attrs.behavior.clone();
    if (cloned == null || !$cast(model.behavior, cloned))
      return invalid_state("QPC behavior clone failed");
    cloned = request.context_attrs.transport_ext.clone();
    if (cloned == null || !$cast(model.transport_ext, cloned))
      return invalid_state("QPC transport-extension clone failed");
    if (plan.rq_source_h != null) begin
      status = normalize_status(manager.lookup(plan.rq_source_h, dependency),
        "QPC SRQ lookup returned null");
      if (!status.ok() || !$cast(srq, dependency) || srq.queue_plan == null)
        return status.ok() ? invalid_state("QPC SRQ plan is invalid") : status;
      status = local_handle(plan.rq_source_h, RDMA_RESOURCE_SRQ, srq.local_srq_id,
                            "QPC SRQ", model.srq_h);
      if (!status.ok()) return status;
      // The SRQ queue plan owns the receive page-directory hardware base.
      foreach (srq.queue_plan.refs[i])
        if (srq.queue_plan.refs[i] != null &&
            srq.queue_plan.refs[i].role == RDMA_QUEUE_ROLE_SRFQ_PD)
          model.rq_backing.value = srq.queue_plan.refs[i].mapping.iova.value +
                                   srq.queue_plan.refs[i].mapping_offset;
      model.rq_mode = RDMA_OBJECT_INDIRECT_4K;
    end else begin
      model.rq_backing.value = plan.rq_pd_ref.mapping.iova.value +
                               plan.rq_pd_ref.mapping_offset;
      model.rq_mode = plan.rq_ring.object_mode;
    end
    if (request.transport == RDMA_TRANSPORT_URC) begin
      if (!$cast(urc_ext, model.transport_ext))
        return invalid_state("QPC URC extension clone is invalid");
      urc_ref = find_urc_ref(plan, RDMA_QUEUE_ROLE_QP_URC_RSQ);
      if (urc_ref == null) return invalid_state("QPC URC RSQ ref is missing");
      urc_ext.queues.rsq_backing.value = urc_ref.mapping.iova.value +
                                          urc_ref.mapping_offset;
      urc_ref = find_urc_ref(plan, RDMA_QUEUE_ROLE_QP_URC_RDSQ);
      if (urc_ref == null) return invalid_state("QPC URC RDSQ ref is missing");
      urc_ext.queues.rdsq_backing.value = urc_ref.mapping.iova.value +
                                           urc_ref.mapping_offset;
      urc_ref = find_urc_ref(plan, RDMA_QUEUE_ROLE_QP_URC_DSQ);
      if (urc_ref == null) return invalid_state("QPC URC DSQ ref is missing");
      urc_ext.queues.dsq_backing.value = urc_ref.mapping.iova.value +
                                          urc_ref.mapping_offset;
    end
    return normalize_status(model.validate(), "semantic QPC validation returned null");
  endfunction

  function rdma_status encode_qpc_staging(
    rdma_function_binding binding,
    rdma_qpc_model model,
    output rdma_dma_mapping staging,
    output rdma_hw_image image
  );
    rdma_status status;
    rdma_codec_key key;
    rdma_codec_base codec;
    rdma_hw_model decoded;
    rdma_dma_request_context request_context;
    bit equal;
    string mismatch;
    byte data[];
    string variant;

    staging = null;
    image = null;
    if (binding == null || model == null || host_mem == null || qpc_codecs == null)
      return invalid_argument("QPC staging input is null");
    status = model.validate();
    if (!status.ok()) return status;
    case (model.transport)
      RDMA_TRANSPORT_RC: variant = "rc";
      RDMA_TRANSPORT_UD: variant = "ud";
      RDMA_TRANSPORT_URC: variant = "urc";
      default: return invalid_argument("QPC transport has no codec variant");
    endcase
    key.hw_version = "xtr_v1";
    key.image_kind = RDMA_IMAGE_QPC;
    key.object_type = "qpc";
    key.variant = variant;
    key.opcode = XTR_V1_OP_QPC_CREATE;
    status = qpc_codecs.lookup(key, codec);
    if (!status.ok()) return status;
    status = codec.encode(model, image);
    if (!status.ok()) return status;
    if (image == null || image.bytes.size() != 512 || image.length != 512 ||
        image.alignment != 512)
      return invalid_state("QPC codec did not emit a 512-byte image");
    status = codec.decode(image, decoded);
    if (!status.ok()) return status;
    status = codec.serialized_equal(model, decoded, equal, mismatch);
    if (!status.ok()) return status;
    if (!equal) return rdma_status::make(RDMA_SC_CODEC_ERROR,
                                         {"QPC round-trip mismatch: ", mismatch});
    status = make_dma_context(binding, model.qp_h, RDMA_QUEUE_ROLE_QP_SQ_PD,
                              request_context);
    if (!status.ok()) return status;
    request_context.queue_role_valid = 1'b0;
    status = normalize_status(host_mem.allocate(request_context, 512, 512,
      RDMA_DMA_DEVICE_READ, staging), "QPC staging allocation returned null");
    if (!status.ok()) return status;
    if (staging == null || staging.size < 512 ||
        (staging.iova.value & 64'h1ff) != 0 ||
        (staging.backing_addr.value & 64'h1ff) != 0)
      return invalid_state("QPC staging allocation is not 512-byte aligned");
    data = new[image.bytes.size()];
    foreach (data[i]) data[i] = image.bytes[i];
    status = normalize_status(host_mem.write(staging, 0, data),
      "QPC staging write returned null");
    if (!status.ok()) return status;
    return normalize_status(binding.validate(), "QPC staging fence returned null");
  endfunction

  task create_locked(
    rdma_function_binding binding,
    rdma_function_handle expected_owner,
    rdma_create_qp_req request,
    longint unsigned transaction_id,
    output rdma_qp qp,
    output rdma_control_result result
  );
    rdma_status status;
    rdma_qp candidate;
    rdma_qp_backing_plan plan;
    rdma_qpc_model model;
    rdma_dma_mapping staging;
    rdma_hw_image image;
    rdma_resource published;
    uvm_object detached_object;

    qp = null;
    result = rdma_control_result::type_id::create("qp_create_result");
    result.transaction_id = transaction_id;
    if (binding == null || expected_owner == null || request == null ||
        manager == null || cmq == null || host_mem == null ||
        context_backing == null) begin
      result.status = invalid_state("QP executor is not configured");
      return;
    end
    status = binding.validate();
    if (status.ok() && (binding.state != RDMA_BIND_ACTIVE ||
                        !binding.make_handle().same_instance(expected_owner)))
      status = rdma_status::make(RDMA_SC_STALE_GENERATION,
                                 "QP create binding generation is stale");
    if (status.ok()) status = request.validate_queue_caps(binding.queue_caps);
    if (status.ok()) status = manager.create_qp(binding, request.pd_h,
      request.send_cq_h, request.recv_cq_h, request.srq_h, candidate);
    if (status.ok() && candidate.local_qp_id > 21'h1f_ffff)
      status = invalid_argument("QP local QPN exceeds 21 bits");
    if (status.ok()) status = materialize_plan(binding, candidate, request, plan);
    if (status.ok()) status = build_qpc_model(binding, candidate, request, plan, model);
    if (status.ok()) status = encode_qpc_staging(binding, model, staging, image);
    if (status.ok()) begin
      candidate.transport = request.transport;
      candidate.qp_state = RDMA_QPS_RESET;
      candidate.sq_depth = request.sq_depth;
      candidate.rq_depth = request.rq_depth;
      candidate.sq_iova.value = plan.sq_ref.mapping.iova.value +
                                plan.sq_ref.mapping_offset;
      candidate.rq_iova.value = plan.rq_source_h == null ?
        plan.rq_ref.mapping.iova.value + plan.rq_ref.mapping_offset : 0;
      candidate.qp_plan = plan;
      candidate.programmed_qpc = model;
      status = manager.attach_qp_programming(candidate);
    end
    if (staging != null)
      void'(host_mem.\release (staging));
    if (status != null && status.ok()) begin
      // Return a detached snapshot of the manager's authoritative copy.  The
      // candidate is a mutable construction object and must not be exposed as
      // the caller's view of registry state.
      status = normalize_status(manager.lookup(candidate.handle, published),
                                "QP post-attach lookup returned null");
      if (status.ok()) begin
        detached_object = published.clone();
        if (detached_object == null || !$cast(qp, detached_object) ||
            qp == published)
          status = invalid_state("QP result snapshot clone failed");
      end
    end
    if (status != null && status.ok()) begin
      result.status = rdma_status::success();
      result.resource_h = rdma_clone_handle_value(qp.handle, "QP result");
      result.final_resource_state = RDMA_RESOURCE_PROGRAMMED;
      result.final_resource_state_known = 1'b1;
    end else begin
      result.status = normalize_status(status, "QP create returned null status");
    end
  endtask

  task modify_locked(rdma_function_binding binding,
                     rdma_function_handle expected_owner,
                     rdma_modify_qp_req request,
                     longint unsigned transaction_id,
                     output rdma_qp qp,
                     output rdma_control_result result);
    qp = null;
    result = rdma_control_result::type_id::create("qp_modify_result");
    result.transaction_id = transaction_id;
    result.status = rdma_status::make(RDMA_SC_UNSUPPORTED_OPCODE,
                                      "QP modify is not implemented yet");
  endtask

  task destroy_locked(rdma_function_binding binding,
                      rdma_function_handle expected_owner,
                      rdma_destroy_resource_req request,
                      longint unsigned transaction_id,
                      output rdma_control_result result);
    result = rdma_control_result::type_id::create("qp_destroy_result");
    result.transaction_id = transaction_id;
    result.status = rdma_status::make(RDMA_SC_UNSUPPORTED_OPCODE,
                                      "QP destroy is not implemented yet");
  endtask

  task recover_locked(rdma_function_binding binding,
                      rdma_function_handle expected_owner,
                      rdma_handle resource_h,
                      longint unsigned transaction_id,
                      output rdma_control_result result);
    result = rdma_control_result::type_id::create("qp_recover_result");
    result.transaction_id = transaction_id;
    result.status = rdma_status::make(RDMA_SC_UNSUPPORTED_OPCODE,
                                      "QP recovery is not implemented yet");
  endtask
endclass
