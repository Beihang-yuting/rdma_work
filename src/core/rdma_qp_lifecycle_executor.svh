class rdma_qp_occ_flush_body extends rdma_xtr_v1_occ_flush_body;
  `uvm_object_utils(rdma_qp_occ_flush_body)

  function new(string name = "rdma_qp_occ_flush_body");
    super.new(name);
  endfunction

  virtual function rdma_status validate();
    if (!vf_flush && !mr_serial_flush && !qpc && !cqc && !mrt &&
        !pble && !sqrqe && !sgb_irqe && eirqe && orqe && uaqe &&
        !pd && qpn == 0 && mr_serial == 0 && pd_backing.value == 0)
      return rdma_status::success();
    return super.validate();
  endfunction
endclass

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

  protected function rdma_status live_binding_fence(
    rdma_function_binding binding, rdma_function_handle expected_owner
  );
    rdma_status status;
    if (binding == null || expected_owner == null)
      return invalid_argument("QP binding fence input is null");
    status = normalize_status(binding.validate(), "QP binding fence returned null");
    if (!status.ok()) return status;
    if (binding.state != RDMA_BIND_ACTIVE ||
        !binding.make_handle().same_instance(expected_owner))
      return rdma_status::make(RDMA_SC_STALE_GENERATION,
                               "QP binding generation is stale");
    return rdma_status::success();
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
    rdma_function_handle expected_owner,
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
    rdma_status fence_status;

    backing_ref = null;
    if (length == 0 || length > 32'hffff_ffff || host_mem == null)
      return invalid_argument("QP backing allocation geometry is invalid");
    status = make_dma_context(binding, qp_h, role, request_context);
    if (!status.ok()) return status;
    mapping = null;
    status = live_binding_fence(binding, expected_owner);
    if (!status.ok()) return status;
    status = normalize_status(host_mem.allocate(request_context, int'(length),
      4096, direction, mapping), "QP backing allocation returned null");
    fence_status = live_binding_fence(binding, expected_owner);
    if (!fence_status.ok()) begin
      if (mapping != null) void'(host_mem.\release (mapping));
      return fence_status;
    end
    if (!status.ok()) begin
      if (mapping != null) void'(host_mem.\release (mapping));
      return status;
    end
    if (mapping == null || mapping.size < length ||
        (mapping.iova.value & 64'hfff) != 0 ||
        (mapping.backing_addr.value & 64'hfff) != 0) begin
      void'(host_mem.\release (mapping));
      return invalid_state("QP backing allocation geometry is invalid");
    end
    status = normalize_status(mapping.snapshot_release_authority(authority),
                              "QP backing authority snapshot returned null");
    if (!status.ok() || authority == null) begin
      void'(host_mem.\release (mapping));
      return status.ok() ? invalid_state("QP backing authority snapshot is null") : status;
    end
    status = normalize_status(mapping.release_authority_status(authority),
      "QP backing authority equivalence returned null");
    if (!status.ok()) begin void'(host_mem.\release (mapping)); return status; end
    authority.copy(mapping);
    status = normalize_status(mapping.release_authority_status(authority),
      "QP copied backing authority equivalence returned null");
    if (!status.ok()) begin void'(host_mem.\release (mapping)); return status; end
    backing_ref = rdma_qp_backing_ref::type_id::create(
      $sformatf("qp_ref_%0d", role)
    );
    if (backing_ref == null) begin
      void'(host_mem.\release (mapping));
      return rdma_status::make(RDMA_SC_RESOURCE_EXHAUSTED,
                               "QP backing reference allocation failed");
    end
    backing_ref.role = role;
    backing_ref.mapping = authority;
    backing_ref.ownership = RDMA_OWNERSHIP_CONTROL_PLANE;
    backing_ref.mapping_offset = 0;
    backing_ref.length = length;
    status = backing_ref.validate();
    if (!status.ok()) begin void'(host_mem.\release (mapping)); backing_ref = null; end
    return status;
  endfunction

  protected function rdma_status clone_borrowed_ref(
    rdma_queue_backing_spec spec,
    rdma_handle qp_h,
    rdma_queue_backing_role_e role,
    longint unsigned length,
    output rdma_qp_backing_ref backing_ref
  );
    uvm_object cloned;

    backing_ref = null;
    if (spec == null || qp_h == null || spec.slices.size() == 0)
      return invalid_argument("QP borrowed backing is empty");
    backing_ref = rdma_qp_backing_ref::type_id::create("qp_borrowed_ref");
    if (backing_ref == null)
      return rdma_status::make(RDMA_SC_RESOURCE_EXHAUSTED,
                               "QP borrowed reference allocation failed");
    if (spec.slices[0] == null || spec.slices[0].mapping == null ||
        spec.slices[0].role != role || spec.slices[0].logical_queue_offset != 0)
      return invalid_argument("QP borrowed backing first slice is invalid");
    cloned = spec.slices[0].mapping.clone();
    if (cloned == null || !$cast(backing_ref.mapping, cloned) ||
        backing_ref.mapping == spec.slices[0].mapping)
      return invalid_state("QP borrowed mapping clone failed");
    backing_ref.role = role;
    backing_ref.ownership = RDMA_OWNERSHIP_BORROWED;
    backing_ref.mapping_offset = spec.slices[0].mapping_offset;
    backing_ref.length = spec.slices[0].length;
    begin
      longint unsigned covered;
      covered = backing_ref.length;
      for (int i = 1; i < spec.slices.size(); i++) begin
        rdma_queue_backing_segment segment;
        rdma_dma_mapping mapping_clone;
        if (spec.slices[i] == null || spec.slices[i].mapping == null ||
            spec.slices[i].role != role ||
            spec.slices[i].logical_queue_offset != covered)
          return invalid_argument("QP borrowed backing is not contiguous");
        cloned = spec.slices[i].mapping.clone();
        if (cloned == null || !$cast(mapping_clone, cloned) ||
            mapping_clone == spec.slices[i].mapping)
          return invalid_state("QP borrowed segment clone failed");
        segment = rdma_queue_backing_segment::type_id::create("qp_borrowed_segment");
        if (segment == null) return rdma_status::make(RDMA_SC_RESOURCE_EXHAUSTED,
          "QP borrowed segment allocation failed");
        segment.role = role; segment.mapping = mapping_clone;
        segment.ownership = RDMA_OWNERSHIP_BORROWED;
        segment.mapping_offset = spec.slices[i].mapping_offset;
        segment.length = spec.slices[i].length;
        segment.logical_queue_offset = covered;
        backing_ref.additional_segments.push_back(segment);
        covered += segment.length;
      end
      if (covered != length)
        return invalid_argument("QP borrowed backing does not cover ring");
    end
    return backing_ref.validate();
  endfunction

  protected function rdma_status bind_borrowed_owner(
    rdma_qp_backing_ref backing_ref,
    rdma_handle qp_h
  );
    if (backing_ref == null || backing_ref.mapping == null || qp_h == null ||
        backing_ref.ownership != RDMA_OWNERSHIP_BORROWED)
      return invalid_argument("QP borrowed owner binding is invalid");
    backing_ref.mapping.owner_h = rdma_clone_handle_value(
      qp_h, "QP borrowed owner"
    );
    foreach (backing_ref.additional_segments[i]) begin
      if (backing_ref.additional_segments[i] == null ||
          backing_ref.additional_segments[i].mapping == null)
        return invalid_state("QP borrowed segment authority is missing");
      backing_ref.additional_segments[i].mapping.owner_h =
        rdma_clone_handle_value(qp_h, "QP borrowed segment owner");
    end
    return rdma_qp_mapping_authority_status(
      backing_ref, backing_ref.mapping.function_h, qp_h, "QP borrowed"
    );
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
    rdma_function_handle expected_owner,
    rdma_qp_backing_ref payload_ref,
    rdma_qp_backing_ref pd_ref
  );
    byte zeros[];
    byte unsigned entries[];
    byte pd_bytes[];
    rdma_queue_dma_page_ref pages[$];
    rdma_queue_dma_page_ref page;
    rdma_status status;
    rdma_status fence_status;
    longint unsigned payload_bytes;

    payload_bytes = payload_ref.length;
    foreach (payload_ref.additional_segments[i])
      payload_bytes += payload_ref.additional_segments[i].length;
    // QP refs retain the first borrowed range directly and subsequent ranges
    // as detached segments. Resolve each 4 KiB logical page through that
    // canonical coverage instead of assuming a single mapping.

    zeros = new[int'(payload_ref.length)];
    foreach (zeros[i]) zeros[i] = 0;
    status = live_binding_fence(binding, expected_owner);
    if (status.ok()) begin
      status = normalize_status(host_mem.write(payload_ref.mapping,
        payload_ref.mapping_offset, zeros), "QP payload zero-write returned null");
      fence_status = live_binding_fence(binding, expected_owner);
      if (!fence_status.ok()) status = fence_status;
    end
    if (!status.ok()) return status;
    foreach (payload_ref.additional_segments[i]) begin
      zeros = new[int'(payload_ref.additional_segments[i].length)];
      foreach (zeros[j]) zeros[j] = 0;
      status = live_binding_fence(binding, expected_owner);
      if (status.ok()) begin
        status = normalize_status(host_mem.write(
          payload_ref.additional_segments[i].mapping,
          payload_ref.additional_segments[i].mapping_offset, zeros),
          "QP borrowed segment zero-write returned null");
        fence_status = live_binding_fence(binding, expected_owner);
        if (!fence_status.ok()) status = fence_status;
      end
      if (!status.ok()) return status;
    end
    for (longint unsigned offset = 0; offset < payload_bytes;
         offset += 4096) begin
      rdma_dma_mapping page_mapping;
      longint unsigned page_mapping_offset;
      page_mapping = null;
      page_mapping_offset = 0;
      if (offset < payload_ref.length) begin
        page_mapping = payload_ref.mapping;
        page_mapping_offset = payload_ref.mapping_offset + offset;
      end else foreach (payload_ref.additional_segments[i]) begin
        if (payload_ref.additional_segments[i] != null &&
            offset >= payload_ref.additional_segments[i].logical_queue_offset &&
            offset < payload_ref.additional_segments[i].logical_queue_offset +
                     payload_ref.additional_segments[i].length) begin
          page_mapping = payload_ref.additional_segments[i].mapping;
          page_mapping_offset = payload_ref.additional_segments[i].mapping_offset +
            offset - payload_ref.additional_segments[i].logical_queue_offset;
        end
      end
      if (page_mapping == null) return invalid_state("QP payload page coverage is incomplete");
      page = rdma_queue_dma_page_ref::type_id::create("qp_pd_page");
      if (page == null)
        return rdma_status::make(RDMA_SC_RESOURCE_EXHAUSTED,
                                 "QP page-directory page allocation failed");
      // Page-directory entries carry only page IOVAs.  The established page
      // reference validator predates QP-only roles, so use its neutral ring
      // discriminator while preserving QP role authority in the plan/ref.
      page.role = RDMA_QUEUE_ROLE_CQ_RING;
      page.mapping = page_mapping;
      page.mapping_offset = page_mapping_offset;
      page.logical_page_offset = offset;
      page.page_iova.value = page_mapping.iova.value + page_mapping_offset;
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
    status = live_binding_fence(binding, expected_owner);
    if (status.ok()) begin
      status = normalize_status(host_mem.write(pd_ref.mapping,
        pd_ref.mapping_offset, pd_bytes),
        "QP page-directory write returned null");
      fence_status = live_binding_fence(binding, expected_owner);
      if (!fence_status.ok()) status = fence_status;
    end
    return status;
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
    rdma_function_handle expected_owner,
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
      status = allocate_ref(binding, expected_owner, qp_snapshot.handle,
        RDMA_QUEUE_ROLE_QP_SQ_RING, plan.sq_ring.storage_bytes,
        RDMA_DMA_DEVICE_READ, plan.sq_ref);
    else
      status = clone_borrowed_ref(request.sq_backing, qp_snapshot.handle,
        RDMA_QUEUE_ROLE_QP_SQ_RING, plan.sq_ring.storage_bytes, plan.sq_ref);
    if (!status.ok()) return status;
    status = allocate_ref(binding, expected_owner, qp_snapshot.handle,
                          RDMA_QUEUE_ROLE_QP_SQ_PD, 4096,
                          RDMA_DMA_DEVICE_READ, plan.sq_pd_ref);
    if (!status.ok()) return status;
    status = zero_and_encode_pd(binding, expected_owner, plan.sq_ref,
                                plan.sq_pd_ref);
    if (!status.ok()) return status;
    if (request.sq_backing.mode == RDMA_QUEUE_BACKING_BORROWED) begin
      status = bind_borrowed_owner(plan.sq_ref, qp_snapshot.handle);
      if (!status.ok()) return status;
    end
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
        status = allocate_ref(binding, expected_owner, qp_snapshot.handle,
          RDMA_QUEUE_ROLE_QP_RQ_RING, plan.rq_ring.storage_bytes,
          RDMA_DMA_DEVICE_READ, plan.rq_ref);
      else
        status = clone_borrowed_ref(request.rq_backing, qp_snapshot.handle,
          RDMA_QUEUE_ROLE_QP_RQ_RING, plan.rq_ring.storage_bytes, plan.rq_ref);
      if (!status.ok()) return status;
      status = allocate_ref(binding, expected_owner, qp_snapshot.handle,
        RDMA_QUEUE_ROLE_QP_RQ_PD, 4096, RDMA_DMA_DEVICE_READ, plan.rq_pd_ref);
      if (!status.ok()) return status;
      status = zero_and_encode_pd(binding, expected_owner, plan.rq_ref,
                                  plan.rq_pd_ref);
      if (!status.ok()) return status;
      if (request.rq_backing.mode == RDMA_QUEUE_BACKING_BORROWED) begin
        status = bind_borrowed_owner(plan.rq_ref, qp_snapshot.handle);
        if (!status.ok()) return status;
      end
    end
    if (request.transport == RDMA_TRANSPORT_URC) begin
      status = allocate_ref(binding, expected_owner, qp_snapshot.handle,
        RDMA_QUEUE_ROLE_QP_URC_RSQ, 4096, RDMA_DMA_BIDIRECTIONAL, ref_value);
      if (!status.ok()) return status;
      plan.urc_refs.push_back(ref_value);
      status = allocate_ref(binding, expected_owner, qp_snapshot.handle,
        RDMA_QUEUE_ROLE_QP_URC_RDSQ, 4096, RDMA_DMA_BIDIRECTIONAL, ref_value);
      if (!status.ok()) return status;
      plan.urc_refs.push_back(ref_value);
      status = allocate_ref(binding, expected_owner, qp_snapshot.handle,
        RDMA_QUEUE_ROLE_QP_URC_DSQ, 8192, RDMA_DMA_BIDIRECTIONAL, ref_value);
      if (!status.ok()) return status;
      plan.urc_refs.push_back(ref_value);
    end
    return rdma_status::success();
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

  protected function rdma_status capture_qpc_authority(
    rdma_function_binding binding,
    rdma_qp qp_snapshot,
    rdma_qp_backing_plan plan,
    output rdma_pd pd,
    output rdma_cq send_cq,
    output rdma_cq recv_cq,
    output rdma_srq srq,
    output bit [7:0] qp_sequence_value
  );
    rdma_resource dependency;
    rdma_status status;

    pd = null;
    send_cq = null;
    recv_cq = null;
    srq = null;
    qp_sequence_value = '0;
    if (binding == null || qp_snapshot == null || plan == null)
      return invalid_argument("QPC authority capture input is null");
    status = normalize_status(manager.lookup(qp_snapshot.pd_h, dependency),
                              "QPC PD lookup returned null");
    if (!status.ok() || !$cast(pd, dependency))
      return status.ok() ? invalid_state("QPC PD dependency is invalid") :
                           status;
    status = normalize_status(manager.lookup(qp_snapshot.send_cq_h, dependency),
                              "QPC send CQ lookup returned null");
    if (!status.ok() || !$cast(send_cq, dependency))
      return status.ok() ? invalid_state("QPC send CQ dependency is invalid") :
                           status;
    status = normalize_status(manager.lookup(qp_snapshot.recv_cq_h, dependency),
                              "QPC receive CQ lookup returned null");
    if (!status.ok() || !$cast(recv_cq, dependency))
      return status.ok() ? invalid_state("QPC receive CQ dependency is invalid") :
                           status;
    if (plan.rq_source_h != null) begin
      status = normalize_status(manager.lookup(plan.rq_source_h, dependency),
                                "QPC SRQ lookup returned null");
      if (!status.ok() || !$cast(srq, dependency) || srq.queue_plan == null)
        return status.ok() ? invalid_state("QPC SRQ plan is invalid") : status;
    end
    return normalize_status(manager.qp_sequence(
      binding.make_handle(), qp_snapshot.local_qp_id, qp_sequence_value
    ), "QPC sequence lookup returned null");
  endfunction

  function rdma_status build_qpc_model(
    rdma_function_binding binding,
    rdma_qp qp_snapshot,
    rdma_create_qp_req request,
    rdma_qp_backing_plan plan,
    rdma_pd pd,
    rdma_cq send_cq,
    rdma_cq recv_cq,
    rdma_srq srq,
    bit [7:0] qp_sequence_value,
    output rdma_qpc_model model
  );
    rdma_status status;
    uvm_object cloned;
    rdma_qpc_urc_ext urc_ext;
    rdma_qp_backing_ref urc_ref;

    model = null;
    if (binding == null || qp_snapshot == null || request == null || plan == null ||
        qp_snapshot.handle == null || request.context_attrs == null ||
        pd == null || send_cq == null || recv_cq == null)
      return invalid_argument("QPC builder input is null");
    status = normalize_status(plan.validate(), "QP plan validation returned null");
    if (!status.ok()) return status;
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
      if (srq == null || srq.queue_plan == null)
        return invalid_state("QPC SRQ plan is invalid");
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
    rdma_handle authoritative_qp_h,
    rdma_function_handle expected_owner,
    output rdma_dma_mapping staging,
    output rdma_hw_image image
  );
    rdma_status status;
    rdma_status fence_status;
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
    if (binding == null || model == null || authoritative_qp_h == null ||
        expected_owner == null || host_mem == null || qpc_codecs == null)
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
    status = make_dma_context(binding, authoritative_qp_h, RDMA_QUEUE_ROLE_QP_SQ_PD,
                              request_context);
    if (!status.ok()) return status;
    request_context.queue_role_valid = 1'b0;
    status = live_binding_fence(binding, expected_owner);
    if (!status.ok()) return status;
    status = normalize_status(host_mem.allocate(request_context, 512, 512,
      RDMA_DMA_DEVICE_READ, staging), "QPC staging allocation returned null");
    fence_status = live_binding_fence(binding, expected_owner);
    if (!fence_status.ok()) return fence_status;
    if (!status.ok()) return status;
    if (staging == null || staging.size < 512 ||
        (staging.iova.value & 64'h1ff) != 0 ||
        (staging.backing_addr.value & 64'h1ff) != 0)
      return invalid_state("QPC staging allocation is not 512-byte aligned");
    data = new[image.bytes.size()];
    foreach (data[i]) data[i] = image.bytes[i];
    status = live_binding_fence(binding, expected_owner);
    if (!status.ok()) return status;
    status = normalize_status(host_mem.write(staging, 0, data),
      "QPC staging write returned null");
    fence_status = live_binding_fence(binding, expected_owner);
    if (!fence_status.ok()) return fence_status;
    return status;
  endfunction

  protected function rdma_status attach_create_programming(
    rdma_qp candidate,
    rdma_create_qp_req request,
    rdma_qp_backing_plan plan,
    rdma_qpc_model model
  );
    if (candidate == null || request == null || plan == null || model == null)
      return invalid_argument("QP programming attachment input is null");
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
    return normalize_status(manager.attach_qp_programming(candidate),
                            "QP programming attachment returned null");
  endfunction

  protected function bit cmq_outcome_ambiguous(
    rdma_status status,
    rdma_cmq_ticket ticket,
    rdma_cmq_completion completion
  );
    if (status == null)
      return 1'b1;
    if (status.code inside {RDMA_SC_TIMEOUT, RDMA_SC_RESET_CANCELLED})
      return 1'b1;
    if (completion != null && completion.status != null &&
        completion.status.code inside {RDMA_SC_TIMEOUT,
                                       RDMA_SC_RESET_CANCELLED})
      return 1'b1;
    if (ticket == null || completion == null || completion.status == null) begin
      if (!status.ok() && ticket == null && completion == null &&
          cmq != null && cmq.last_execute_definitive_no_submit())
        return 1'b0;
      return 1'b1;
    end
    return 1'b0;
  endfunction

  protected function rdma_cmq_opcode_key make_opcode_key(
    bit [7:0] opcode, string variant
  );
    rdma_cmq_opcode_key key;
    key = rdma_cmq_opcode_key::type_id::create({"qp_", variant, "_opcode"});
    key.profile_name = "xtr_v1";
    key.opcode = opcode;
    key.variant = variant;
    return key;
  endfunction

  protected virtual function rdma_status build_qpc_command(
    rdma_function_handle owner,
    rdma_qpc_model model,
    rdma_dma_mapping staging,
    rdma_hw_image image,
    bit [7:0] opcode,
    output rdma_cmq_command_desc command
  );
    rdma_xtr_v1_qpc_command_body body;

    command = null;
    if (owner == null || model == null || model.qp_h == null)
      return invalid_argument("QP command authority is incomplete");
    body = rdma_xtr_v1_qpc_command_body::type_id::create("qp_command_body");
    body.qp_h = rdma_clone_handle_value(model.qp_h, "QP command QPN");
    if (opcode inside {XTR_V1_OP_QPC_CREATE, XTR_V1_OP_QPC_DELETE}) begin
      body.send_cq_h = rdma_clone_handle_value(model.send_cq_h,
                                               "QP command send CQN");
      body.recv_cq_h = rdma_clone_handle_value(model.recv_cq_h,
                                               "QP command receive CQN");
    end
    if (opcode == XTR_V1_OP_QPC_CREATE) begin
      if (staging == null)
        return invalid_argument("QPC_CREATE staging mapping is null");
      body.qpc_buffer.value = staging.iova.value;
      body.next_state = RDMA_QPS_RESET;
    end
    command = rdma_cmq_command_desc::type_id::create("qp_command");
    command.function_h = rdma_clone_function_handle_value(owner,
                                                           "QP command");
    command.opcode_key = make_opcode_key(
      opcode, opcode == XTR_V1_OP_QPC_CREATE ? "create" : "delete"
    );
    command.body = body;
    command.qpc_signature_source = opcode == XTR_V1_OP_QPC_CREATE ? image : null;
    command.timeout = command_timeout;
    return normalize_status(command.validate(),
                            "QP command validation returned null");
  endfunction

  protected function rdma_status build_occ_command(
    rdma_function_handle owner,
    int unsigned local_qpn,
    rdma_qp_backing_ref pd_ref,
    output rdma_cmq_command_desc command
  );
    rdma_qp_occ_flush_body body;

    command = null;
    if (owner == null || local_qpn > 21'h1f_ffff)
      return invalid_argument("QP OCC authority is invalid");
    body = rdma_qp_occ_flush_body::type_id::create("qp_occ_body");
    body.qpn = local_qpn;
    if (pd_ref == null) begin
      body.eirqe = 1'b1;
      body.orqe = 1'b1;
      body.uaqe = 1'b1;
    end else begin
      if (pd_ref.mapping == null)
        return invalid_argument("QP OCC PD mapping is null");
      body.pd = 1'b1;
      body.pd_backing.value = pd_ref.mapping.iova.value +
                              pd_ref.mapping_offset;
    end
    command = rdma_cmq_command_desc::type_id::create("qp_occ_command");
    command.function_h = rdma_clone_function_handle_value(owner,
                                                           "QP OCC command");
    command.opcode_key = make_opcode_key(XTR_V1_OP_OCC_FLUSH, "occ_flush");
    command.body = body;
    command.timeout = command_timeout;
    return normalize_status(command.validate(),
                            "QP OCC command validation returned null");
  endfunction

  protected function void append_rollback_status(
    rdma_control_result result, rdma_status status
  );
    if (result != null && status != null && !status.ok())
      result.rollback_statuses.push_back(rdma_cmq_clone_status_value(status));
  endfunction

  protected function rdma_status release_mapping_opaque(
    rdma_dma_mapping mapping,
    string label,
    output bit release_complete
  );
    rdma_status status;
    rdma_status completion_status;

    release_complete = 1'b0;
    if (mapping == null)
      return invalid_argument({label, " mapping is null"});
    completion_status = normalize_status(
      mapping.release_completion_status(release_complete),
      {label, " pre-release completion query returned null"}
    );
    if (!completion_status.ok() || release_complete)
      return completion_status;
    status = normalize_status(host_mem.\release (mapping),
                              {label, " release returned null"});
    completion_status = normalize_status(
      mapping.release_completion_status(release_complete),
      {label, " completion query returned null"}
    );
    if (!completion_status.ok())
      return completion_status;
    if (release_complete)
      return rdma_status::success();
    if (!status.ok())
      return status;
    return rdma_status::make(RDMA_SC_RECOVERY_REQUIRED,
                             {label, " release is incomplete"});
  endfunction

  protected function rdma_status release_context_opaque(
    rdma_context_backing_ref context_ref,
    string label,
    output bit release_complete
  );
    rdma_status status;
    rdma_status completion_status;

    release_complete = 1'b0;
    if (context_ref == null)
      return invalid_argument({label, " context is null"});
    completion_status = normalize_status(
      context_backing.query_release_completion(context_ref, release_complete),
      {label, " pre-release completion query returned null"}
    );
    if (!completion_status.ok() || release_complete)
      return completion_status;
    status = normalize_status(context_backing.\release (context_ref),
                              {label, " release returned null"});
    completion_status = normalize_status(
      context_backing.query_release_completion(context_ref, release_complete),
      {label, " completion query returned null"}
    );
    if (!completion_status.ok())
      return completion_status;
    if (release_complete)
      return rdma_status::success();
    if (!status.ok())
      return status;
    return rdma_status::make(RDMA_SC_RECOVERY_REQUIRED,
                             {label, " release is incomplete"});
  endfunction

  protected function rdma_status release_ref_local(
    rdma_qp_backing_ref backing_ref,
    rdma_control_result result
  );
    rdma_status status;
    bit release_complete;
    if (backing_ref == null ||
        backing_ref.ownership == RDMA_OWNERSHIP_BORROWED)
      return rdma_status::success();
    if (backing_ref.cleanup_complete)
      return rdma_status::success();
    if (backing_ref.mapping == null)
      return invalid_state("QP owned backing mapping is missing");
    status = release_mapping_opaque(backing_ref.mapping,
                                    "QP backing", release_complete);
    if (release_complete)
      backing_ref.cleanup_complete = 1'b1;
    append_rollback_status(result, status);
    return status;
  endfunction

  protected function rdma_status release_partial_plan(
    rdma_qp_backing_plan plan,
    rdma_control_result result
  );
    rdma_status status;
    rdma_status step_status;
    bit release_complete;

    status = rdma_status::success();
    if (plan == null)
      return status;
    if (plan.context_ref != null && !plan.context_ref.release_complete) begin
      step_status = release_context_opaque(plan.context_ref,
                                           "QP context", release_complete);
      if (release_complete)
        plan.context_ref.release_complete = 1'b1;
      append_rollback_status(result, step_status);
      if (status.ok() && !step_status.ok()) status = step_status;
      if (!step_status.ok()) return status;
    end
    for (int i = plan.urc_refs.size() - 1; i >= 0; i--) begin
      step_status = release_ref_local(plan.urc_refs[i], result);
      if (status.ok() && !step_status.ok()) status = step_status;
      if (!step_status.ok()) return status;
    end
    step_status = release_ref_local(plan.rq_pd_ref, result);
    if (status.ok() && !step_status.ok()) status = step_status;
    if (!step_status.ok()) return status;
    step_status = release_ref_local(plan.sq_pd_ref, result);
    if (status.ok() && !step_status.ok()) status = step_status;
    if (!step_status.ok()) return status;
    step_status = release_ref_local(plan.rq_ref, result);
    if (status.ok() && !step_status.ok()) status = step_status;
    if (!step_status.ok()) return status;
    step_status = release_ref_local(plan.sq_ref, result);
    if (status.ok() && !step_status.ok()) status = step_status;
    return status;
  endfunction

  protected function void publish_primary(
    rdma_control_result result,
    rdma_status primary
  );
    rdma_status normalized;
    normalized = normalize_status(primary, "QP create primary status is null");
    result.primary_status = rdma_cmq_clone_status_value(normalized);
    result.status = rdma_cmq_clone_status_value(normalized);
  endfunction

  protected function rdma_status make_create_recovery(
    rdma_qp_backing_plan plan,
    rdma_qpc_model candidate_qpc,
    rdma_dma_mapping staging,
    rdma_qp_ambiguous_operation_e ambiguous_operation,
    rdma_queue_backing_role_e ambiguous_role,
    rdma_cmq_ticket ticket,
    output rdma_qp_recovery_state recovery
  );
    recovery = rdma_qp_recovery_state::type_id::create("qp_create_recovery");
    recovery.intent = RDMA_QP_RECOVER_CREATE_ROLLBACK;
    recovery.ambiguous_operation = ambiguous_operation;
    recovery.ambiguous_role = ambiguous_role;
    recovery.candidate_qpc = candidate_qpc;
    recovery.qp_plan = plan;
    recovery.context_ref = plan == null ? null : plan.context_ref;
    recovery.staging_mapping = staging;
    recovery.create_opcode = make_opcode_key(XTR_V1_OP_QPC_CREATE, "create");
    recovery.modify_opcode = make_opcode_key(XTR_V1_OP_QPC_MODIFY, "modify");
    recovery.delete_opcode = make_opcode_key(XTR_V1_OP_QPC_DELETE, "delete");
    recovery.query_opcode = make_opcode_key(XTR_V1_OP_QPC_QUERY, "query");
    recovery.occ_opcode = make_opcode_key(XTR_V1_OP_OCC_FLUSH, "occ_flush");
    recovery.ambiguous_ticket = rdma_cmq_clone_ticket_value(ticket,
                                                            "QP create recovery");
    return normalize_status(recovery.validate(),
                            "QP create recovery validation returned null");
  endfunction

  protected task execute_terminal_command(
    rdma_function_binding binding,
    rdma_function_handle expected_owner,
    rdma_cmq_command_desc command,
    output rdma_status status,
    output bit ambiguous,
    output rdma_cmq_ticket recovery_ticket
  );
    rdma_cmq_ticket ticket;
    rdma_cmq_completion completion;
    rdma_status fence_status;

    ambiguous = 1'b0;
    recovery_ticket = null;
    ticket = null;
    completion = null;
    status = live_binding_fence(binding, expected_owner);
    if (!status.ok())
      return;
    status = null;
    cmq.execute(command, ticket, completion, status);
    ambiguous = cmq_outcome_ambiguous(status, ticket, completion);
    recovery_ticket = ticket;
    if (recovery_ticket == null && completion != null)
      recovery_ticket = completion.ticket;
    fence_status = live_binding_fence(binding, expected_owner);
    if (!fence_status.ok()) begin
      status = fence_status;
      ambiguous = 1'b1;
      return;
    end
    status = normalize_status(status, "QP rollback command returned null");
    if (status.ok() &&
        (ticket == null || completion == null || completion.status == null))
      status = invalid_state("QP rollback command completion is incomplete");
  endtask

  protected task cleanup_attached_qp(
    rdma_function_binding binding,
    rdma_function_handle expected_owner,
    rdma_qp candidate,
    rdma_qp_backing_plan plan,
    rdma_qpc_model model,
    bit hardware_present,
    rdma_status primary,
    rdma_control_result result,
    output bit released
  );
    rdma_qp_recovery_state recovery;
    rdma_cmq_command_desc command;
    rdma_status status;
    rdma_status step_status;
    rdma_status release_status;
    rdma_status fence_status;
    rdma_queue_backing_role_e roles[$];
    rdma_qp_backing_ref refs[$];
    rdma_cmq_ticket recovery_ticket;
    bit ambiguous;
    bit release_complete;

    released = 1'b0;
    status = make_create_recovery(plan, hardware_present ? model : null,
                                  null, RDMA_QP_AMBIG_NONE,
                                  RDMA_QUEUE_ROLE_QP_SQ_RING, null, recovery);
    if (status.ok())
      status = normalize_status(manager.mark_qp_error(candidate.handle, recovery),
                                "QP rollback ERROR publication returned null");
    if (!status.ok()) begin
      append_rollback_status(result, status);
      result.final_resource_state = RDMA_RESOURCE_PROGRAMMED;
      result.final_resource_state_known = 1'b1;
      return;
    end
    result.final_resource_state = RDMA_RESOURCE_ERROR;
    result.final_resource_state_known = 1'b1;

    roles.push_back(RDMA_QUEUE_ROLE_QP_SQ_RING);
    roles.push_back(RDMA_QUEUE_ROLE_QP_SQ_PD);
    if (plan.rq_source_h == null)
      roles.push_back(RDMA_QUEUE_ROLE_QP_RQ_PD);
    foreach (roles[i]) begin
      step_status = rdma_status::success();
      if (hardware_present) begin
        case (roles[i])
          RDMA_QUEUE_ROLE_QP_SQ_RING:
            step_status = build_occ_command(expected_owner,
              candidate.local_qp_id, null, command);
          RDMA_QUEUE_ROLE_QP_SQ_PD:
            step_status = build_occ_command(expected_owner,
              candidate.local_qp_id, plan.sq_pd_ref, command);
          default:
            step_status = build_occ_command(expected_owner,
              candidate.local_qp_id, plan.rq_pd_ref, command);
        endcase
        if (step_status.ok())
          execute_terminal_command(binding, expected_owner, command,
                                   step_status, ambiguous, recovery_ticket);
        if (ambiguous) begin
          recovery.ambiguous_operation = RDMA_QP_AMBIG_OCC_FLUSH;
          recovery.ambiguous_role = roles[i];
          recovery.ambiguous_ticket = rdma_cmq_clone_ticket_value(
            recovery_ticket, "QP OCC rollback recovery"
          );
          status = normalize_status(
            manager.mark_qp_error(candidate.handle, recovery),
            "QP OCC ambiguity publication returned null"
          );
          if (!status.ok())
            append_rollback_status(result, status);
          result.primary_status = rdma_cmq_clone_status_value(primary);
          result.status = rdma_status::make(
            RDMA_SC_RECOVERY_REQUIRED, "QP OCC rollback requires recovery"
          );
          result.recovery_required = 1'b1;
          return;
        end
      end
      if (step_status.ok())
        step_status = normalize_status(manager.record_qp_flush_complete(
          candidate.handle, roles[i]), "QP rollback flush progress returned null");
      if (!step_status.ok()) begin
        append_rollback_status(result, step_status);
        return;
      end
      recovery.role_complete[roles[i]] = 1'b1;
      case (roles[i])
        RDMA_QUEUE_ROLE_QP_SQ_RING:
          recovery.qp_plan.cleanup_complete = 1'b1;
        RDMA_QUEUE_ROLE_QP_SQ_PD:
          recovery.qp_plan.sq_pd_flush_complete = 1'b1;
        RDMA_QUEUE_ROLE_QP_RQ_PD:
          recovery.qp_plan.rq_pd_flush_complete = 1'b1;
        default:;
      endcase
    end
    if (hardware_present) begin
      step_status = build_qpc_command(expected_owner, model, null, null,
                                      XTR_V1_OP_QPC_DELETE, command);
      if (step_status.ok())
        execute_terminal_command(binding, expected_owner, command, step_status,
                                 ambiguous, recovery_ticket);
      if (ambiguous) begin
        recovery.ambiguous_operation = RDMA_QP_AMBIG_DELETE;
        recovery.ambiguous_role = RDMA_QUEUE_ROLE_QP_SQ_RING;
        recovery.ambiguous_ticket = rdma_cmq_clone_ticket_value(
          recovery_ticket, "QP delete rollback recovery"
        );
        status = normalize_status(
          manager.mark_qp_error(candidate.handle, recovery),
          "QP delete ambiguity publication returned null"
        );
        if (!status.ok())
          append_rollback_status(result, status);
        result.primary_status = rdma_cmq_clone_status_value(primary);
        result.status = rdma_status::make(
          RDMA_SC_RECOVERY_REQUIRED, "QP delete rollback requires recovery"
        );
        result.recovery_required = 1'b1;
        return;
      end
      if (!step_status.ok()) begin
        append_rollback_status(result, step_status);
        return;
      end
    end

    step_status = live_binding_fence(binding, expected_owner);
    if (step_status.ok()) begin
      release_status = release_context_opaque(
        plan.context_ref, "QP rollback context", release_complete
      );
      fence_status = live_binding_fence(binding, expected_owner);
      if (!fence_status.ok())
        step_status = fence_status;
      else if (!release_status.ok())
        step_status = release_status;
      else
        step_status = normalize_status(
          manager.record_qp_context_cleanup_complete(candidate.handle),
          "QP rollback context progress returned null"
        );
    end
    if (!step_status.ok()) begin
      append_rollback_status(result, step_status);
      return;
    end

    for (int i = plan.urc_refs.size() - 1; i >= 0; i--)
      refs.push_back(plan.urc_refs[i]);
    refs.push_back(plan.rq_pd_ref);
    refs.push_back(plan.sq_pd_ref);
    refs.push_back(plan.rq_ref);
    refs.push_back(plan.sq_ref);
    foreach (refs[i]) begin
      if (refs[i] == null || refs[i].ownership == RDMA_OWNERSHIP_BORROWED)
        continue;
      step_status = live_binding_fence(binding, expected_owner);
      if (step_status.ok()) begin
        release_status = release_mapping_opaque(
          refs[i].mapping, "QP rollback backing", release_complete
        );
        fence_status = live_binding_fence(binding, expected_owner);
        if (!fence_status.ok())
          step_status = fence_status;
        else if (!release_status.ok())
          step_status = release_status;
        else
          step_status = normalize_status(manager.record_qp_cleanup_complete(
            candidate.handle, refs[i].role),
            "QP rollback backing progress returned null");
      end
      if (!step_status.ok()) begin
        append_rollback_status(result, step_status);
        return;
      end
    end
    status = normalize_status(manager.finalize_qp_release(candidate.handle),
                              "QP rollback finalization returned null");
    if (!status.ok()) begin
      append_rollback_status(result, status);
      return;
    end
    result.final_resource_state = RDMA_RESOURCE_RELEASED;
    result.final_resource_state_known = 1'b1;
    released = 1'b1;
  endtask

  protected task rollback_unattached_qp(
    rdma_qp candidate,
    rdma_qp_backing_plan plan,
    rdma_dma_mapping staging,
    rdma_status primary,
    rdma_control_result result
  );
    rdma_status cleanup_status;
    cleanup_status = release_partial_plan(plan, result);
    if (!cleanup_status.ok()) begin
      append_rollback_status(result, cleanup_status);
      retain_create_recovery(
        candidate, plan, null, staging, RDMA_QP_AMBIG_NONE,
        RDMA_QUEUE_ROLE_QP_SQ_RING, null, primary, result
      );
      return;
    end
    if (candidate != null && candidate.handle != null)
      cleanup_status = normalize_status(manager.finalize_qp_release(
        candidate.handle), "QP reservation finalization returned null");
    if (!cleanup_status.ok()) begin
      append_rollback_status(result, cleanup_status);
      publish_primary(result, primary);
      return;
    end
    if (candidate != null) begin
      result.final_resource_state = RDMA_RESOURCE_RELEASED;
      result.final_resource_state_known = 1'b1;
    end
    publish_primary(result, primary);
  endtask

  protected task retain_create_recovery(
    rdma_qp candidate,
    rdma_qp_backing_plan plan,
    rdma_qpc_model model,
    rdma_dma_mapping staging,
    rdma_qp_ambiguous_operation_e ambiguous_operation,
    rdma_queue_backing_role_e ambiguous_role,
    rdma_cmq_ticket ticket,
    rdma_status primary,
    rdma_control_result result
  );
    rdma_qp_recovery_state recovery;
    rdma_status status;

    status = make_create_recovery(plan, model, staging, ambiguous_operation,
                                  ambiguous_role, ticket, recovery);
    if (status.ok())
      status = normalize_status(manager.mark_qp_error(candidate.handle, recovery),
                                "QP create recovery publication returned null");
    if (!status.ok()) begin
      append_rollback_status(result, status);
      publish_primary(result, primary);
      return;
    end
    result.primary_status = rdma_cmq_clone_status_value(primary);
    result.status = rdma_status::make(RDMA_SC_RECOVERY_REQUIRED,
                                      "QP create requires recovery");
    result.final_resource_state = RDMA_RESOURCE_ERROR;
    result.final_resource_state_known = 1'b1;
    result.recovery_required = 1'b1;
  endtask

  task create_locked(
    rdma_function_binding binding,
    rdma_function_handle expected_owner,
    rdma_create_qp_req request,
    longint unsigned transaction_id,
    output rdma_qp qp,
    output rdma_control_result result
  );
    rdma_status status;
    rdma_status primary;
    rdma_status fence_status;
    rdma_status release_status;
    rdma_qp candidate;
    rdma_qp_backing_plan plan;
    rdma_qpc_model model;
    rdma_function_binding binding_snapshot;
    rdma_pd qpc_pd;
    rdma_cq qpc_send_cq;
    rdma_cq qpc_recv_cq;
    rdma_srq qpc_srq;
    rdma_dma_mapping staging;
    rdma_hw_image image;
    rdma_resource published;
    uvm_object detached_object;
    uvm_object cloned_binding_object;
    rdma_cmq_command_desc command;
    rdma_cmq_ticket ticket;
    rdma_cmq_ticket recovery_ticket;
    rdma_cmq_completion completion;
    byte unsigned context_bytes[];
    bit ambiguous;
    bit attached;
    bit released;
    bit release_complete;
    bit [7:0] qpc_sequence_value;

    qp = null;
    result = rdma_control_result::type_id::create("qp_create_result");
    result.transaction_id = transaction_id;
    result.primary_status = invalid_state("QP create did not complete");
    result.status = invalid_state("QP create did not complete");
    result.final_resource_state = RDMA_RESOURCE_NEW;
    result.final_resource_state_known = 1'b0;
    result.recovery_required = 1'b0;
    candidate = null;
    plan = null;
    staging = null;
    image = null;
    command = null;
    binding_snapshot = null;
    qpc_pd = null;
    qpc_send_cq = null;
    qpc_recv_cq = null;
    qpc_srq = null;
    qpc_sequence_value = '0;
    attached = 1'b0;
    if (transaction_id == 0) begin
      publish_primary(result, invalid_argument("QP transaction ID is zero"));
      return;
    end
    if (binding == null || expected_owner == null || request == null ||
        manager == null || cmq == null || host_mem == null ||
        context_backing == null) begin
      result.status = invalid_state("QP executor is not configured");
      result.primary_status = invalid_state("QP executor is not configured");
      return;
    end
    status = live_binding_fence(binding, expected_owner);
    if (status.ok()) begin
      cloned_binding_object = binding.clone();
      if (cloned_binding_object == null ||
          !$cast(binding_snapshot, cloned_binding_object) ||
          binding_snapshot.make_handle() == null ||
          !binding_snapshot.make_handle().same_instance(expected_owner))
        status = invalid_state("QP binding snapshot is invalid");
    end
    if (status.ok() && (request.owner == null ||
        !request.owner.same_instance(expected_owner)))
      status = invalid_argument("QP request owner does not match binding");
    if (status.ok()) status = normalize_status(request.validate(),
      "QP request validation returned null");
    if (status.ok()) status = request.validate_queue_caps(binding.queue_caps);
    if (status.ok()) status = manager.create_qp(binding, request.pd_h,
      request.send_cq_h, request.recv_cq_h, request.srq_h, candidate);
    if (!status.ok()) begin publish_primary(result, status); return; end
    result.resource_h = rdma_clone_handle_value(candidate.handle,
                                                 "QP create result");
    result.final_resource_state = RDMA_RESOURCE_ALLOCATED;
    result.final_resource_state_known = 1'b1;
    result.completed_steps.push_back(RDMA_CTRL_STEP_RESOURCE_RESERVED);
    if (status.ok() && candidate.local_qp_id > 21'h1f_ffff)
      status = invalid_argument("QP local QPN exceeds 21 bits");
    if (status.ok())
      status = materialize_plan(binding, expected_owner, candidate, request,
                                plan);
    if (!status.ok()) begin
      rollback_unattached_qp(candidate, plan, null, status, result);
      return;
    end
    result.completed_steps.push_back(RDMA_CTRL_STEP_BACKING_ATTACHED);
    status = capture_qpc_authority(binding_snapshot, candidate, plan, qpc_pd,
                                    qpc_send_cq, qpc_recv_cq, qpc_srq,
                                    qpc_sequence_value);
    if (!status.ok()) begin
      rollback_unattached_qp(candidate, plan, null, status, result);
      return;
    end
    status = live_binding_fence(binding, expected_owner);
    if (status.ok()) begin
      status = normalize_status(context_backing.acquire(
        binding, RDMA_RESOURCE_QP, candidate.local_qp_id, plan.context_ref
      ), "QP context acquire returned null");
      fence_status = live_binding_fence(binding, expected_owner);
      if (!fence_status.ok())
        status = fence_status;
    end
    if (!status.ok()) begin
      primary = status;
      if (plan.context_ref != null &&
          primary.code inside {RDMA_SC_TIMEOUT, RDMA_SC_RESET_CANCELLED,
                               RDMA_SC_STALE_GENERATION}) begin
        status = normalize_status(plan.validate(),
                                  "QP plan validation returned null");
        if (status.ok())
          status = build_qpc_model(binding_snapshot, candidate, request, plan,
                                    qpc_pd, qpc_send_cq, qpc_recv_cq, qpc_srq,
                                    qpc_sequence_value, model);
        if (status.ok())
          status = attach_create_programming(candidate, request, plan, model);
        if (status.ok()) begin
          attached = 1'b1;
          result.final_resource_state = RDMA_RESOURCE_PROGRAMMED;
          retain_create_recovery(candidate, plan, null, null,
            RDMA_QP_AMBIG_NONE, RDMA_QUEUE_ROLE_QP_SQ_RING,
            null, primary, result);
          return;
        end
        append_rollback_status(result, status);
      end
      rollback_unattached_qp(candidate, plan, null, primary, result);
      return;
    end
    result.completed_steps.push_back(RDMA_CTRL_STEP_HMC_ATTACHED);
    status = normalize_status(plan.validate(), "QP plan validation returned null");
    if (status.ok())
      status = build_qpc_model(binding_snapshot, candidate, request, plan,
                                qpc_pd, qpc_send_cq, qpc_recv_cq, qpc_srq,
                                qpc_sequence_value, model);
    if (status.ok()) status = encode_qpc_staging(binding, model, candidate.handle,
                                                  expected_owner, staging, image);
    if (!status.ok()) begin
      primary = status;
      if (primary.code inside {RDMA_SC_TIMEOUT, RDMA_SC_RESET_CANCELLED}) begin
        status = attach_create_programming(candidate, request, plan, model);
        if (status.ok()) begin
          attached = 1'b1;
          result.final_resource_state = RDMA_RESOURCE_PROGRAMMED;
          retain_create_recovery(candidate, plan, null, staging,
            RDMA_QP_AMBIG_NONE, RDMA_QUEUE_ROLE_QP_SQ_RING,
            null, primary, result);
          return;
        end
        append_rollback_status(result, status);
      end
      if (staging != null) begin
        release_status = release_mapping_opaque(
          staging, "QP failed staging", release_complete
        );
        if (!release_status.ok() && model != null) begin
          append_rollback_status(result, release_status);
          status = attach_create_programming(candidate, request, plan, model);
          if (status.ok()) begin
            retain_create_recovery(candidate, plan, null, staging,
              RDMA_QP_AMBIG_NONE, RDMA_QUEUE_ROLE_QP_SQ_RING,
              null, primary, result);
            return;
          end
          append_rollback_status(result, status);
        end
        if (release_complete)
          staging = null;
      end
      rollback_unattached_qp(candidate, plan, staging, primary, result);
      return;
    end
    if (status.ok()) begin
      context_bytes = new[image.bytes.size()];
      foreach (context_bytes[i]) context_bytes[i] = image.bytes[i];
      status = live_binding_fence(binding, expected_owner);
      if (status.ok()) begin
        status = normalize_status(context_backing.write(plan.context_ref, 0,
          context_bytes), "QP context write returned null");
        fence_status = live_binding_fence(binding, expected_owner);
        if (!fence_status.ok())
          status = fence_status;
      end
    end
    if (!status.ok()) begin
      primary = status;
      if (primary.code inside {RDMA_SC_TIMEOUT, RDMA_SC_RESET_CANCELLED}) begin
        status = attach_create_programming(candidate, request, plan, model);
        if (status.ok()) begin
          attached = 1'b1;
          result.final_resource_state = RDMA_RESOURCE_PROGRAMMED;
          retain_create_recovery(candidate, plan, null, staging,
            RDMA_QP_AMBIG_NONE, RDMA_QUEUE_ROLE_QP_SQ_RING,
            null, primary, result);
          return;
        end
        append_rollback_status(result, status);
      end
      if (staging != null) begin
        release_status = release_mapping_opaque(
          staging, "QP failed staging", release_complete
        );
        if (!release_status.ok()) begin
          append_rollback_status(result, release_status);
          status = attach_create_programming(candidate, request, plan, model);
          if (status.ok()) begin
            retain_create_recovery(candidate, plan, null, staging,
              RDMA_QP_AMBIG_NONE, RDMA_QUEUE_ROLE_QP_SQ_RING,
              null, primary, result);
            return;
          end
          append_rollback_status(result, status);
        end
        if (release_complete)
          staging = null;
      end
      rollback_unattached_qp(candidate, plan, staging, primary, result);
      return;
    end
    status = attach_create_programming(candidate, request, plan, model);
    if (!status.ok()) begin
      primary = status;
      release_status = release_mapping_opaque(
        staging, "QP attach-failure staging", release_complete
      );
      if (release_complete)
        staging = null;
      status = attach_create_programming(candidate, request, plan, model);
      if (!status.ok()) begin
        append_rollback_status(result, status);
        rollback_unattached_qp(candidate, plan, staging, primary, result);
        return;
      end
      attached = 1'b1;
      result.final_resource_state = RDMA_RESOURCE_PROGRAMMED;
      if (!release_status.ok()) begin
        append_rollback_status(result, release_status);
        retain_create_recovery(candidate, plan, null, staging,
          RDMA_QP_AMBIG_NONE, RDMA_QUEUE_ROLE_QP_SQ_RING,
          null, primary, result);
        return;
      end
      cleanup_attached_qp(binding, expected_owner, candidate, plan, model,
                          1'b0, primary, result, released);
      if (released)
        publish_primary(result, primary);
      else begin
        result.primary_status = rdma_cmq_clone_status_value(primary);
        result.status = rdma_status::make(
          RDMA_SC_RECOVERY_REQUIRED,
          "QP unattached rollback requires recovery"
        );
        result.recovery_required = 1'b1;
      end
      return;
    end
    attached = 1'b1;
    result.final_resource_state = RDMA_RESOURCE_PROGRAMMED;
    status = build_qpc_command(expected_owner, model, staging, image,
                                XTR_V1_OP_QPC_CREATE, command);
    if (!status.ok()) begin
      primary = status;
      release_status = release_mapping_opaque(
        staging, "QP command-build staging", release_complete
      );
      if (!release_status.ok()) begin
        append_rollback_status(result, release_status);
        retain_create_recovery(candidate, plan, null, staging,
          RDMA_QP_AMBIG_NONE, RDMA_QUEUE_ROLE_QP_SQ_RING,
          null, primary, result);
        return;
      end
      staging = null;
      cleanup_attached_qp(binding, expected_owner, candidate, plan, model,
                          1'b0, primary, result, released);
      if (released)
        publish_primary(result, primary);
      else begin
        result.primary_status = rdma_cmq_clone_status_value(primary);
        result.status = rdma_status::make(
          RDMA_SC_RECOVERY_REQUIRED,
          "QP command-build rollback requires recovery"
        );
        result.recovery_required = 1'b1;
      end
      return;
    end
    status = live_binding_fence(binding, expected_owner);
    if (!status.ok()) begin
      primary = status;
      retain_create_recovery(candidate, plan, null, staging,
        RDMA_QP_AMBIG_NONE, RDMA_QUEUE_ROLE_QP_SQ_RING,
        null, primary, result);
      return;
    end
    ticket = null;
    completion = null;
    status = null;
    cmq.execute(command, ticket, completion, status);
    ambiguous = cmq_outcome_ambiguous(status, ticket, completion);
    recovery_ticket = ticket;
    if (recovery_ticket == null && completion != null)
      recovery_ticket = completion.ticket;
    status = normalize_status(status, "QPC_CREATE result was lost");
    if (status.ok() && ticket == null)
      status = invalid_state("QPC_CREATE ticket was lost");
    if (status.ok() && (completion == null || completion.status == null))
      status = invalid_state("QPC_CREATE completion was lost");
    fence_status = live_binding_fence(binding, expected_owner);
    if (!fence_status.ok()) begin
      primary = fence_status;
      retain_create_recovery(candidate, plan, model, staging,
        RDMA_QP_AMBIG_CREATE, RDMA_QUEUE_ROLE_QP_SQ_RING,
        recovery_ticket, primary, result);
      return;
    end
    if (!status.ok()) begin
      primary = status;
      if (ambiguous) begin
        retain_create_recovery(candidate, plan, model, staging,
          RDMA_QP_AMBIG_CREATE, RDMA_QUEUE_ROLE_QP_SQ_RING,
          recovery_ticket, primary, result);
      end else begin
        release_status = release_mapping_opaque(
          staging, "QP failed-create staging", release_complete
        );
        if (!release_status.ok()) begin
          append_rollback_status(result, release_status);
          retain_create_recovery(candidate, plan, null, staging,
            RDMA_QP_AMBIG_NONE, RDMA_QUEUE_ROLE_QP_SQ_RING,
            null, primary, result);
          return;
        end
        staging = null;
        cleanup_attached_qp(binding, expected_owner, candidate, plan, model,
                            1'b0, primary, result, released);
        if (released)
          publish_primary(result, primary);
        else begin
          result.primary_status = rdma_cmq_clone_status_value(primary);
          result.status = rdma_status::make(
            RDMA_SC_RECOVERY_REQUIRED,
            "QP definitive-create rollback requires recovery"
          );
          result.recovery_required = 1'b1;
        end
      end
      return;
    end
    result.completed_steps.push_back(RDMA_CTRL_STEP_HW_CONTEXT_CREATED);
    result.completed_steps.push_back(RDMA_CTRL_STEP_REGISTRY_PROGRAMMED);
    status = live_binding_fence(binding, expected_owner);
    if (status.ok()) begin
      release_status = release_mapping_opaque(
        staging, "QP staging", release_complete
      );
      fence_status = live_binding_fence(binding, expected_owner);
      if (release_complete)
        staging = null;
      if (!fence_status.ok() || !release_status.ok()) begin
        primary = !fence_status.ok() ? fence_status :
          release_status;
        retain_create_recovery(candidate, plan, model, staging,
          RDMA_QP_AMBIG_NONE, RDMA_QUEUE_ROLE_QP_SQ_RING,
          null, primary, result);
        return;
      end
      status = fence_status;
    end
    if (!status.ok()) begin
      primary = status;
      retain_create_recovery(candidate, plan, model, null,
        RDMA_QP_AMBIG_NONE, RDMA_QUEUE_ROLE_QP_SQ_RING,
        null, primary, result);
      return;
    end
    status = live_binding_fence(binding, expected_owner);
    if (status.ok()) begin
      status = normalize_status(manager.activate(candidate.handle),
                                "QP activation returned null");
      fence_status = live_binding_fence(binding, expected_owner);
      if (!fence_status.ok()) begin
        primary = fence_status;
        retain_create_recovery(candidate, plan, model, null,
          RDMA_QP_AMBIG_NONE, RDMA_QUEUE_ROLE_QP_SQ_RING,
          null, primary, result);
        return;
      end
    end
    if (!status.ok()) begin
      primary = status;
      cleanup_attached_qp(binding, expected_owner, candidate, plan, model,
                          1'b1, primary, result, released);
      if (released)
        publish_primary(result, primary);
      else begin
        result.primary_status = rdma_cmq_clone_status_value(primary);
        result.status = rdma_status::make(RDMA_SC_RECOVERY_REQUIRED,
                                          "QP activation rollback requires recovery");
        result.recovery_required = 1'b1;
      end
      return;
    end
    result.completed_steps.push_back(RDMA_CTRL_STEP_REGISTRY_ACTIVE);
    result.final_resource_state = RDMA_RESOURCE_ACTIVE;
    status = normalize_status(manager.lookup(candidate.handle, published),
                              "ACTIVE QP lookup returned null");
    if (status.ok()) begin
      detached_object = published.clone();
      if (detached_object == null || !$cast(qp, detached_object) ||
          qp == published || qp.state != RDMA_RESOURCE_ACTIVE ||
          qp.qp_state != RDMA_QPS_RESET)
        status = invalid_state("ACTIVE QP result snapshot is invalid");
    end
    if (!status.ok()) begin
      qp = null;
      primary = status;
      cleanup_attached_qp(binding, expected_owner, candidate, plan, model,
                          1'b1, primary, result, released);
      publish_primary(result, primary);
      return;
    end
    result.resource_h = rdma_clone_handle_value(qp.handle, "ACTIVE QP result");
    result.primary_status = rdma_status::success();
    result.status = rdma_status::success();
    result.final_resource_state_known = 1'b1;
    result.recovery_required = 1'b0;
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
