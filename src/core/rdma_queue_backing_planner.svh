class rdma_queue_backing_planner extends uvm_object;
  `uvm_object_utils(rdma_queue_backing_planner)

  protected rdma_host_mem_api host_mem;

  function new(string name = "rdma_queue_backing_planner");
    super.new(name);
    host_mem = null;
  endfunction

  protected function rdma_status invalid_argument(string message);
    return rdma_status::make(RDMA_SC_INVALID_ARGUMENT, message);
  endfunction

  protected function rdma_status invalid_state(string message);
    return rdma_status::make(RDMA_SC_INVALID_STATE, message);
  endfunction

  protected function rdma_status normalize_status(
    rdma_status status,
    string message
  );
    if (status == null)
      return invalid_state(message);
    return status;
  endfunction

  protected function bit same_handle(rdma_handle lhs, rdma_handle rhs);
    if (lhs == null || rhs == null)
      return 1'b0;
    return lhs.same_instance(rhs);
  endfunction

  protected function rdma_dma_direction_e payload_direction(
    rdma_queue_backing_role_e role
  );
    if (role inside {RDMA_QUEUE_ROLE_CQ_RING,
                     RDMA_QUEUE_ROLE_CEQ_RING,
                     RDMA_QUEUE_ROLE_AEQ_RING})
      return RDMA_DMA_DEVICE_WRITE;
    return RDMA_DMA_DEVICE_READ;
  endfunction

  protected function rdma_dma_permission_t direction_permissions(
    rdma_dma_direction_e direction
  );
    rdma_dma_permission_t permissions;

    permissions = '0;
    permissions.device_read = direction inside {
      RDMA_DMA_DEVICE_READ, RDMA_DMA_BIDIRECTIONAL
    };
    permissions.device_write = direction inside {
      RDMA_DMA_DEVICE_WRITE, RDMA_DMA_BIDIRECTIONAL
    };
    return permissions;
  endfunction

  protected function rdma_status expected_layout_status(
    rdma_function_binding binding,
    rdma_queue_preflight preflight,
    rdma_queue_ring_layout ring
  );
    int unsigned expected_entry_size;
    longint unsigned logical_bytes;
    longint unsigned storage_bytes;
    longint unsigned capability_limit;

    if (ring == null || !rdma_queue_role_is_payload(ring.role))
      return invalid_argument("queue preflight ring role is invalid");
    case (ring.role)
      RDMA_QUEUE_ROLE_CQ_RING:
        expected_entry_size = preflight.cqe_size_bytes;
      RDMA_QUEUE_ROLE_SRQ_RING,
      RDMA_QUEUE_ROLE_SRFQ_RING:
        expected_entry_size = 64;
      RDMA_QUEUE_ROLE_SRQ_SGB:
        expected_entry_size = 512;
      RDMA_QUEUE_ROLE_CEQ_RING,
      RDMA_QUEUE_ROLE_AEQ_RING:
        expected_entry_size = 16;
      default:
        return invalid_argument("queue preflight contains a metadata role");
    endcase
    if (ring.depth != preflight.depth || expected_entry_size == 0 ||
        ring.entry_size_bytes != expected_entry_size)
      return invalid_argument("queue preflight ring dimensions disagree");
    if (longint'(ring.depth) >
        64'hffff_ffff_ffff_ffff / ring.entry_size_bytes)
      return invalid_argument("queue ring multiplication overflows");
    logical_bytes = longint'(ring.depth) * ring.entry_size_bytes;
    if (logical_bytes > 64'hffff_ffff_ffff_f000)
      return invalid_argument("queue ring alignment overflows");
    storage_bytes = (logical_bytes + 4095) & 64'hffff_ffff_ffff_f000;
    if (storage_bytes == 0 || storage_bytes > 32'hffff_ffff)
      return invalid_argument("queue ring exceeds host allocation width");
    capability_limit = (ring.role == RDMA_QUEUE_ROLE_SRQ_SGB) ?
      binding.queue_caps.max_sgb_bytes :
      binding.queue_caps.max_queue_ring_bytes;
    if (storage_bytes > capability_limit)
      return invalid_argument("queue ring exceeds Function capability");
    if (ring.role != RDMA_QUEUE_ROLE_SRQ_SGB &&
        storage_bytes > 64'h0020_0000)
      return invalid_argument("queue ring exceeds one page directory");
    if (ring.logical_bytes != logical_bytes ||
        ring.storage_bytes != storage_bytes ||
        ring.page_count != storage_bytes / 4096 ||
        ring.page_count == 0 ||
        (ring.role != RDMA_QUEUE_ROLE_SRQ_SGB && ring.page_count > 512))
      return invalid_argument("queue preflight ring layout is not canonical");
    return rdma_status::success();
  endfunction

  protected function rdma_status required_roles_status(
    rdma_function_binding binding,
    rdma_queue_preflight preflight
  );
    rdma_status status;
    bit need_sgb;

    need_sgb = preflight.max_sge > 2;
    case (preflight.resource_kind)
      RDMA_RESOURCE_CQ: begin
        if (preflight.required_rings.size() != 1 ||
            preflight.required_rings[0] == null ||
            preflight.required_rings[0].role != RDMA_QUEUE_ROLE_CQ_RING)
          return invalid_argument("CQ preflight payload roles are invalid");
      end
      RDMA_RESOURCE_SRQ: begin
        if (preflight.required_rings.size() != (need_sgb ? 3 : 2) ||
            preflight.required_rings[0] == null ||
            preflight.required_rings[1] == null ||
            preflight.required_rings[0].role != RDMA_QUEUE_ROLE_SRQ_RING ||
            preflight.required_rings[1].role != RDMA_QUEUE_ROLE_SRFQ_RING ||
            (need_sgb && (preflight.required_rings[2] == null ||
             preflight.required_rings[2].role != RDMA_QUEUE_ROLE_SRQ_SGB)))
          return invalid_argument("SRQ preflight payload roles are invalid");
      end
      RDMA_RESOURCE_CEQ: begin
        if (preflight.required_rings.size() != 1 ||
            preflight.required_rings[0] == null ||
            preflight.required_rings[0].role != RDMA_QUEUE_ROLE_CEQ_RING)
          return invalid_argument("CEQ preflight payload roles are invalid");
      end
      RDMA_RESOURCE_AEQ: begin
        if (preflight.required_rings.size() != 1 ||
            preflight.required_rings[0] == null ||
            preflight.required_rings[0].role != RDMA_QUEUE_ROLE_AEQ_RING)
          return invalid_argument("AEQ preflight payload roles are invalid");
      end
      default:
        return invalid_argument("queue preflight resource kind is invalid");
    endcase
    foreach (preflight.required_rings[i]) begin
      status = expected_layout_status(binding, preflight,
                                      preflight.required_rings[i]);
      if (!status.ok())
        return status;
    end
    return rdma_status::success();
  endfunction

  protected function rdma_queue_ring_layout find_required_ring(
    rdma_queue_preflight preflight,
    rdma_queue_backing_role_e role
  );
    foreach (preflight.required_rings[i]) begin
      if (preflight.required_rings[i] != null &&
          preflight.required_rings[i].role == role)
        return preflight.required_rings[i];
    end
    return null;
  endfunction

  protected function rdma_status borrowed_coverage_status(
    rdma_queue_preflight preflight,
    rdma_queue_ring_layout ring
  );
    longint unsigned expected_offset;
    longint unsigned range_end;
    int match_count;
    int selected_index;

    expected_offset = 0;
    while (expected_offset < ring.storage_bytes) begin
      match_count = 0;
      selected_index = -1;
      foreach (preflight.backing_spec.slices[i]) begin
        if (preflight.backing_spec.slices[i] != null &&
            preflight.backing_spec.slices[i].role == ring.role &&
            preflight.backing_spec.slices[i].logical_queue_offset ==
              expected_offset) begin
          match_count++;
          selected_index = i;
        end
      end
      if (match_count != 1 || selected_index < 0)
        return invalid_argument("borrowed queue layout has a hole or overlap");
      if (preflight.backing_spec.slices[selected_index].length >
          ring.storage_bytes - expected_offset)
        return invalid_argument("borrowed queue slice exceeds role length");
      expected_offset +=
        preflight.backing_spec.slices[selected_index].length;
    end
    if (expected_offset != ring.storage_bytes)
      return invalid_argument("borrowed queue role length is incorrect");

    foreach (preflight.backing_spec.slices[i]) begin
      if (preflight.backing_spec.slices[i] == null ||
          preflight.backing_spec.slices[i].role != ring.role)
        continue;
      if (!rdma_queue_add_ok(
            preflight.backing_spec.slices[i].logical_queue_offset,
            preflight.backing_spec.slices[i].length))
        return invalid_argument("borrowed logical range overflows");
      range_end =
        preflight.backing_spec.slices[i].logical_queue_offset +
        preflight.backing_spec.slices[i].length;
      if (range_end > ring.storage_bytes)
        return invalid_argument("borrowed logical range exceeds role");
      for (int j = 0; j < i; j++) begin
        if (preflight.backing_spec.slices[j] == null ||
            preflight.backing_spec.slices[j].role != ring.role)
          continue;
        if (preflight.backing_spec.slices[i].logical_queue_offset <
              preflight.backing_spec.slices[j].logical_queue_offset +
                preflight.backing_spec.slices[j].length &&
            preflight.backing_spec.slices[j].logical_queue_offset < range_end)
          return invalid_argument("borrowed logical ranges overlap");
      end
    end
    return rdma_status::success();
  endfunction

  protected function rdma_status borrowed_access_status(
    rdma_function_binding binding,
    rdma_queue_backing_slice slice
  );
    rdma_iova_t first_iova;
    rdma_dma_direction_e direction;
    rdma_dma_permission_t permissions;
    rdma_status status;

    if (slice == null || slice.mapping == null)
      return invalid_argument("borrowed queue slice is null");
    status = normalize_status(slice.validate(),
      "borrowed queue slice validation returned null");
    if (!status.ok())
      return status;
    if (slice.mapping.iova.value >
        64'hffff_ffff_ffff_ffff - slice.mapping_offset)
      return rdma_status::make(RDMA_SC_DMA_TRANSLATION,
                               "borrowed queue IOVA offset overflows");
    if (slice.mapping.backing_addr.value >
        64'hffff_ffff_ffff_ffff - slice.mapping_offset ||
        slice.mapping.backing_addr.value + slice.mapping_offset >
          64'hffff_ffff_ffff_ffff - (slice.length - 1'b1))
      return rdma_status::make(RDMA_SC_DMA_TRANSLATION,
                               "borrowed host backing range overflows");
    first_iova.value = slice.mapping.iova.value + slice.mapping_offset;
    direction = payload_direction(slice.role);
    permissions = direction_permissions(direction);
    status = normalize_status(slice.mapping.check_access(
      binding.make_handle(), binding.queue_dma.requester_bdf,
      binding.queue_dma.pasid_valid, binding.queue_dma.pasid,
      binding.queue_dma.dma_domain_valid, binding.queue_dma.dma_domain_id,
      first_iova, slice.length, direction, permissions
    ), "borrowed mapping access check returned null");
    return status;
  endfunction

  protected function rdma_status borrowed_overlap_status(
    rdma_queue_backing_spec spec
  );
    longint unsigned first_iova;
    longint unsigned first_backing;
    longint unsigned first_iova_last;
    longint unsigned first_backing_last;
    longint unsigned second_iova;
    longint unsigned second_backing;
    longint unsigned second_iova_last;
    longint unsigned second_backing_last;

    foreach (spec.slices[i]) begin
      if (spec.slices[i] == null || spec.slices[i].mapping == null)
        return invalid_argument("borrowed queue slice is null");
      first_iova = spec.slices[i].mapping.iova.value +
                   spec.slices[i].mapping_offset;
      first_backing = spec.slices[i].mapping.backing_addr.value +
                      spec.slices[i].mapping_offset;
      first_iova_last = first_iova + spec.slices[i].length - 1'b1;
      first_backing_last = first_backing + spec.slices[i].length - 1'b1;
      for (int j = 0; j < i; j++) begin
        if (spec.slices[j] == null || spec.slices[j].mapping == null)
          continue;
        second_iova = spec.slices[j].mapping.iova.value +
                      spec.slices[j].mapping_offset;
        second_backing = spec.slices[j].mapping.backing_addr.value +
                         spec.slices[j].mapping_offset;
        second_iova_last = second_iova + spec.slices[j].length - 1'b1;
        second_backing_last = second_backing + spec.slices[j].length - 1'b1;
        if ((first_iova <= second_iova_last &&
             second_iova <= first_iova_last) ||
            (first_backing <= second_backing_last &&
             second_backing <= first_backing_last))
          return invalid_argument(
            "borrowed queue roles overlap in IOVA or host backing"
          );
      end
    end
    return rdma_status::success();
  endfunction

  function rdma_status configure(rdma_host_mem_api host_mem);
    if (host_mem == null)
      return invalid_argument("queue backing planner host memory is null");
    if (this.host_mem != null)
      return invalid_state("queue backing planner is already configured");
    this.host_mem = host_mem;
    return rdma_status::success();
  endfunction

  function rdma_status validate_spec(
    rdma_function_binding binding,
    rdma_queue_preflight preflight
  );
    rdma_status status;
    rdma_queue_ring_layout ring;

    if (binding == null || preflight == null)
      return invalid_argument("queue backing validation input is null");
    status = normalize_status(binding.validate(),
                              "Function binding validation returned null");
    if (!status.ok())
      return status;
    if (binding.state != RDMA_BIND_ACTIVE)
      return invalid_state("queue backing requires an ACTIVE Function");
    status = normalize_status(preflight.validate(),
                              "queue preflight validation returned null");
    if (!status.ok())
      return status;
    status = required_roles_status(binding, preflight);
    if (!status.ok())
      return status;
    if (preflight.backing_spec.mode == RDMA_QUEUE_BACKING_OWNED)
      return rdma_status::success();
    if (preflight.backing_spec.mode != RDMA_QUEUE_BACKING_BORROWED)
      return invalid_argument("queue backing mode is invalid");

    foreach (preflight.backing_spec.slices[i]) begin
      ring = find_required_ring(preflight,
        preflight.backing_spec.slices[i] == null ? RDMA_QUEUE_ROLE_CQ_PD :
        preflight.backing_spec.slices[i].role
      );
      if (ring == null)
        return invalid_argument("borrowed queue contains an extra role");
      status = borrowed_access_status(binding,
                                       preflight.backing_spec.slices[i]);
      if (!status.ok())
        return status;
    end
    foreach (preflight.required_rings[i]) begin
      status = borrowed_coverage_status(preflight,
                                        preflight.required_rings[i]);
      if (!status.ok())
        return status;
    end
    return borrowed_overlap_status(preflight.backing_spec);
  endfunction

  protected function rdma_status make_request_context(
    rdma_function_binding binding,
    rdma_handle resource_h,
    output rdma_dma_request_context request_context
  );
    request_context = rdma_dma_request_context::type_id::create(
      "queue_backing_request_context"
    );
    if (request_context == null)
      return rdma_status::make(RDMA_SC_RESOURCE_EXHAUSTED,
                               "queue DMA request context creation failed");
    request_context.function_h = binding.make_handle();
    request_context.requester_bdf = binding.queue_dma.requester_bdf;
    request_context.pasid_valid = binding.queue_dma.pasid_valid;
    request_context.pasid = binding.queue_dma.pasid;
    request_context.dma_domain_valid = binding.queue_dma.dma_domain_valid;
    request_context.dma_domain_id = binding.queue_dma.dma_domain_id;
    request_context.owner_h = rdma_clone_handle_value(
      resource_h, "queue DMA resource owner"
    );
    return normalize_status(request_context.validate(),
                            "queue DMA request validation returned null");
  endfunction

  protected function rdma_status allocated_mapping_status(
    rdma_function_binding binding,
    rdma_handle resource_h,
    rdma_dma_mapping mapping,
    longint unsigned length,
    longint unsigned alignment,
    rdma_dma_direction_e direction
  );
    rdma_dma_permission_t permissions;
    rdma_status status;

    if (mapping == null)
      return invalid_state("host allocation returned a null mapping");
    if (mapping.size < length || mapping.size == 0 ||
        mapping.iova.value > 64'hffff_ffff_ffff_ffff - (length - 1'b1) ||
        mapping.backing_addr.value >
          64'hffff_ffff_ffff_ffff - (length - 1'b1))
      return rdma_status::make(RDMA_SC_DMA_TRANSLATION,
                               "allocated queue mapping is too short");
    if (!rdma_queue_aligned(mapping.iova.value, alignment) ||
        !rdma_queue_aligned(mapping.backing_addr.value, alignment))
      return invalid_argument("allocated queue mapping is unaligned");
    if (mapping.owner_h == null || !same_handle(mapping.owner_h, resource_h))
      return invalid_state("allocated queue mapping owner is incorrect");
    permissions = direction_permissions(direction);
    status = normalize_status(mapping.check_access(
      binding.make_handle(), binding.queue_dma.requester_bdf,
      binding.queue_dma.pasid_valid, binding.queue_dma.pasid,
      binding.queue_dma.dma_domain_valid, binding.queue_dma.dma_domain_id,
      mapping.iova, length, direction, permissions
    ), "allocated mapping access check returned null");
    return status;
  endfunction

  protected function rdma_status release_acquired_mapping(
    rdma_dma_mapping mapping,
    rdma_status original_status
  );
    rdma_status release_status;

    if (mapping == null)
      return original_status;
    release_status = normalize_status(host_mem.\release (mapping),
                                      "host rollback release returned null");
    if (release_status.ok())
      return original_status;
    return rdma_status::make(release_status.code,
      {"queue backing rollback release failed: ", release_status.message,
       "; original failure: ", original_status.message});
  endfunction

  protected function rdma_status allocate_owned_ref(
    rdma_function_binding binding,
    rdma_dma_request_context request_context,
    rdma_handle resource_h,
    rdma_queue_backing_role_e role,
    longint unsigned length,
    longint unsigned alignment,
    rdma_dma_direction_e direction,
    output rdma_queue_backing_ref ref_value
  );
    rdma_dma_mapping acquired_mapping;
    rdma_dma_mapping authority_snapshot;
    rdma_status status;

    ref_value = null;
    if (length == 0 || length > 32'hffff_ffff)
      return invalid_argument("queue allocation length exceeds API width");
    acquired_mapping = null;
    status = normalize_status(host_mem.allocate(
      request_context, int'(length), int'(alignment), direction,
      acquired_mapping
    ), "host queue allocation returned null status");
    if (!status.ok())
      return release_acquired_mapping(acquired_mapping, status);
    status = allocated_mapping_status(binding, resource_h, acquired_mapping,
                                      length, alignment, direction);
    if (!status.ok())
      return release_acquired_mapping(acquired_mapping, status);

    // Publish a detached authority snapshot carrying the acquired mapping's
    // checked public geometry.  The snapshot's opaque allocation identity is
    // established before copy and therefore remains fixed by adapter do_copy.
    authority_snapshot = null;
    status = normalize_status(acquired_mapping.snapshot_release_authority(
      authority_snapshot), "queue release authority snapshot returned null");
    if (!status.ok())
      return release_acquired_mapping(acquired_mapping, status);
    status = normalize_status(acquired_mapping.release_authority_status(
      authority_snapshot), "queue release authority check returned null");
    if (!status.ok())
      return release_acquired_mapping(acquired_mapping, status);
    authority_snapshot.copy(acquired_mapping);
    status = normalize_status(acquired_mapping.release_authority_status(
      authority_snapshot), "copied queue release authority check returned null");
    if (!status.ok())
      return release_acquired_mapping(acquired_mapping, status);

    ref_value = rdma_queue_backing_ref::type_id::create(
      $sformatf("queue_owned_ref_%0d", role)
    );
    if (ref_value == null)
      return release_acquired_mapping(acquired_mapping,
        rdma_status::make(RDMA_SC_RESOURCE_EXHAUSTED,
                          "queue backing ref creation failed"));
    ref_value.role = role;
    ref_value.mapping = authority_snapshot;
    ref_value.ownership = RDMA_OWNERSHIP_CONTROL_PLANE;
    ref_value.mapping_offset = 0;
    ref_value.length = length;
    ref_value.logical_queue_offset = 0;
    return rdma_status::success();
  endfunction

  protected function rdma_status clone_ring_metadata(
    rdma_queue_ring_layout source,
    output rdma_queue_ring_layout ring
  );
    uvm_object cloned_object;

    ring = null;
    if (source == null)
      return invalid_argument("queue ring metadata is null");
    cloned_object = source.clone();
    if (cloned_object == null || !$cast(ring, cloned_object) ||
        ring == source)
      return invalid_state("queue ring metadata clone failed");
    ring.pages.delete();
    return rdma_status::success();
  endfunction

  protected function rdma_status add_page(
    rdma_queue_ring_layout ring,
    rdma_dma_mapping mapping,
    longint unsigned mapping_offset,
    longint unsigned logical_offset
  );
    rdma_queue_dma_page_ref page;

    if (mapping == null || mapping.iova.value >
        64'hffff_ffff_ffff_ffff - mapping_offset)
      return rdma_status::make(RDMA_SC_DMA_TRANSLATION,
                               "queue page IOVA projection overflows");
    page = rdma_queue_dma_page_ref::type_id::create(
      $sformatf("queue_page_%0d_%0d", ring.role, ring.pages.size())
    );
    if (page == null)
      return rdma_status::make(RDMA_SC_RESOURCE_EXHAUSTED,
                               "queue page reference creation failed");
    page.role = ring.role;
    page.mapping = mapping;
    page.mapping_offset = mapping_offset;
    page.logical_page_offset = logical_offset;
    page.page_iova.value = mapping.iova.value + mapping_offset;
    ring.pages.push_back(page);
    return normalize_status(page.validate(),
                            "queue page validation returned null");
  endfunction

  protected function rdma_status populate_owned_ring(
    rdma_queue_ring_layout ring,
    rdma_queue_backing_ref ref_value
  );
    rdma_status status;

    if (ring.role == RDMA_QUEUE_ROLE_SRQ_SGB)
      return rdma_status::success();
    for (longint unsigned offset = 0; offset < ring.storage_bytes;
         offset += 4096) begin
      status = add_page(ring, ref_value.mapping,
                        ref_value.mapping_offset + offset, offset);
      if (!status.ok())
        return status;
    end
    return rdma_status::success();
  endfunction

  protected function rdma_status populate_borrowed_ring(
    rdma_queue_preflight preflight,
    rdma_queue_ring_layout ring,
    output rdma_queue_backing_ref ref_value
  );
    rdma_queue_backing_slice first_slice;
    rdma_queue_backing_slice next_slice;
    rdma_queue_backing_slice page_slice;
    rdma_queue_backing_segment segment;
    rdma_dma_mapping segment_mapping;
    uvm_object cloned_object;
    longint unsigned next_logical_offset;
    longint unsigned slice_relative_offset;
    longint unsigned page_end;
    int match_count;
    rdma_status status;

    ref_value = null;
    first_slice = null;
    foreach (preflight.backing_spec.slices[i]) begin
      if (preflight.backing_spec.slices[i] != null &&
          preflight.backing_spec.slices[i].role == ring.role &&
          preflight.backing_spec.slices[i].logical_queue_offset == 0)
        first_slice = preflight.backing_spec.slices[i];
    end
    if (first_slice == null)
      return invalid_argument("borrowed queue role has no first slice");
    ref_value = rdma_queue_backing_ref::type_id::create(
      $sformatf("queue_borrowed_ref_%0d", ring.role)
    );
    if (ref_value == null)
      return rdma_status::make(RDMA_SC_RESOURCE_EXHAUSTED,
                               "borrowed queue ref creation failed");
    ref_value.role = ring.role;
    ref_value.mapping = first_slice.mapping;
    ref_value.ownership = RDMA_OWNERSHIP_BORROWED;
    ref_value.mapping_offset = first_slice.mapping_offset;
    ref_value.length = first_slice.length;
    ref_value.logical_queue_offset = first_slice.logical_queue_offset;

    next_logical_offset = first_slice.length;
    while (next_logical_offset < ring.storage_bytes) begin
      next_slice = null;
      match_count = 0;
      foreach (preflight.backing_spec.slices[i]) begin
        if (preflight.backing_spec.slices[i] != null &&
            preflight.backing_spec.slices[i].role == ring.role &&
            preflight.backing_spec.slices[i].logical_queue_offset ==
              next_logical_offset) begin
          next_slice = preflight.backing_spec.slices[i];
          match_count++;
        end
      end
      if (match_count != 1 || next_slice == null)
        return invalid_argument("borrowed queue segments are not contiguous");
      cloned_object = next_slice.mapping.clone();
      if (cloned_object == null ||
          !$cast(segment_mapping, cloned_object) ||
          segment_mapping == next_slice.mapping)
        return invalid_state("borrowed queue segment mapping clone failed");
      segment = rdma_queue_backing_segment::type_id::create(
        $sformatf("queue_borrowed_segment_%0d_%0d", ring.role,
                  ref_value.additional_segments.size())
      );
      if (segment == null)
        return rdma_status::make(RDMA_SC_RESOURCE_EXHAUSTED,
                                 "borrowed queue segment creation failed");
      segment.role = ring.role;
      segment.mapping = segment_mapping;
      segment.ownership = RDMA_OWNERSHIP_BORROWED;
      segment.mapping_offset = next_slice.mapping_offset;
      segment.length = next_slice.length;
      segment.logical_queue_offset = next_slice.logical_queue_offset;
      ref_value.additional_segments.push_back(segment);
      next_logical_offset += next_slice.length;
    end
    if (ring.role == RDMA_QUEUE_ROLE_SRQ_SGB)
      return normalize_status(ref_value.validate(),
                              "borrowed SGB ref validation returned null");

    for (longint unsigned offset = 0; offset < ring.storage_bytes;
         offset += 4096) begin
      page_end = offset + 4096;
      page_slice = null;
      match_count = 0;
      foreach (preflight.backing_spec.slices[i]) begin
        if (preflight.backing_spec.slices[i] == null ||
            preflight.backing_spec.slices[i].role != ring.role)
          continue;
        if (preflight.backing_spec.slices[i].logical_queue_offset <= offset &&
            page_end <=
              preflight.backing_spec.slices[i].logical_queue_offset +
                preflight.backing_spec.slices[i].length) begin
          page_slice = preflight.backing_spec.slices[i];
          match_count++;
        end
      end
      if (match_count != 1 || page_slice == null)
        return invalid_argument("queue page crosses a borrowed slice");
      slice_relative_offset = offset - page_slice.logical_queue_offset;
      status = add_page(ring, page_slice.mapping,
        page_slice.mapping_offset + slice_relative_offset, offset);
      if (!status.ok())
        return status;
    end
    return normalize_status(ref_value.validate(),
                            "borrowed queue ref validation returned null");
  endfunction

  protected function rdma_queue_backing_ref find_ref(
    rdma_queue_backing_plan plan,
    rdma_queue_backing_role_e role
  );
    foreach (plan.refs[i]) begin
      if (plan.refs[i] != null && plan.refs[i].role == role)
        return plan.refs[i];
    end
    return null;
  endfunction

  protected function rdma_status add_flush_target(
    rdma_queue_backing_plan plan,
    rdma_queue_backing_role_e role,
    rdma_queue_flush_phase_e phase
  );
    rdma_queue_flush_target target;

    target = rdma_queue_flush_target::type_id::create(
      $sformatf("queue_flush_%0d", role)
    );
    if (target == null)
      return rdma_status::make(RDMA_SC_RESOURCE_EXHAUSTED,
                               "queue flush target creation failed");
    target.role = role;
    target.phase = phase;
    target.pd_ref = find_ref(plan, role);
    if (target.pd_ref == null)
      return invalid_state("queue flush target has no PD reference");
    plan.flush_targets.push_back(target);
    return normalize_status(target.validate(),
                            "queue flush target validation returned null");
  endfunction

  protected function rdma_status local_plan_status(
    rdma_queue_backing_plan plan
  );
    rdma_status status;

    if (plan == null || plan.context_ref != null)
      return invalid_state("planner-local plan context must be absent");
    foreach (plan.rings[i]) begin
      if (plan.rings[i] == null)
        return invalid_argument("planner-local plan has a null ring");
      status = normalize_status(plan.rings[i].validate(),
                                "queue ring validation returned null");
      if (!status.ok())
        return status;
    end
    foreach (plan.refs[i]) begin
      if (plan.refs[i] == null)
        return invalid_argument("planner-local plan has a null ref");
      status = normalize_status(plan.refs[i].validate(),
                                "queue ref validation returned null");
      if (!status.ok())
        return status;
    end
    foreach (plan.flush_targets[i]) begin
      if (plan.flush_targets[i] == null)
        return invalid_argument("planner-local plan has a null flush target");
      status = normalize_status(plan.flush_targets[i].validate(),
        "queue flush target validation returned null");
      if (!status.ok())
        return status;
    end
    case (plan.resource_kind)
      RDMA_RESOURCE_CQ: begin
        if (plan.rings.size() != 1 || plan.refs.size() != 2 ||
            plan.refs[0].role != RDMA_QUEUE_ROLE_CQ_RING ||
            plan.refs[1].role != RDMA_QUEUE_ROLE_CQ_PD ||
            plan.flush_targets.size() != 1 ||
            plan.flush_targets[0].role != RDMA_QUEUE_ROLE_CQ_PD ||
            plan.flush_targets[0].phase != RDMA_QUEUE_FLUSH_POST_DELETE)
          return invalid_state("planner-local CQ roles are invalid");
      end
      RDMA_RESOURCE_SRQ: begin
        if (plan.rings.size() < 2 || plan.rings.size() > 3 ||
            plan.refs.size() != plan.rings.size() + 2 ||
            plan.refs[0].role != RDMA_QUEUE_ROLE_SRQ_RING ||
            plan.refs[1].role != RDMA_QUEUE_ROLE_SRFQ_RING ||
            (plan.rings.size() == 3 &&
             plan.refs[2].role != RDMA_QUEUE_ROLE_SRQ_SGB) ||
            plan.refs[plan.refs.size()-2].role != RDMA_QUEUE_ROLE_SRQ_PD ||
            plan.refs[plan.refs.size()-1].role != RDMA_QUEUE_ROLE_SRFQ_PD ||
            plan.flush_targets.size() != 2 ||
            plan.flush_targets[0].role != RDMA_QUEUE_ROLE_SRFQ_PD ||
            plan.flush_targets[1].role != RDMA_QUEUE_ROLE_SRQ_PD)
          return invalid_state("planner-local SRQ roles are invalid");
      end
      RDMA_RESOURCE_CEQ: begin
        if (plan.rings.size() != 1 || plan.refs.size() != 2 ||
            plan.refs[0].role != RDMA_QUEUE_ROLE_CEQ_RING ||
            plan.refs[1].role != RDMA_QUEUE_ROLE_CEQ_PD ||
            plan.flush_targets.size() != 0)
          return invalid_state("planner-local CEQ roles are invalid");
      end
      RDMA_RESOURCE_AEQ: begin
        if (plan.rings.size() != 1 || plan.refs.size() != 2 ||
            plan.refs[0].role != RDMA_QUEUE_ROLE_AEQ_RING ||
            plan.refs[1].role != RDMA_QUEUE_ROLE_AEQ_PD ||
            plan.flush_targets.size() != 0)
          return invalid_state("planner-local AEQ roles are invalid");
      end
      default:
        return invalid_argument("planner-local plan kind is invalid");
    endcase
    return rdma_status::success();
  endfunction

  protected function rdma_status rollback_plan(
    rdma_queue_backing_plan candidate,
    rdma_status original_status
  );
    rdma_status cleanup_status;
    rdma_status rollback_failure;
    bit complete;

    if (candidate == null)
      return original_status;
    rollback_failure = null;
    for (int i = candidate.refs.size() - 1; i >= 0; i--) begin
      if (candidate.refs[i] == null ||
          candidate.refs[i].ownership != RDMA_OWNERSHIP_CONTROL_PLANE)
        continue;
      cleanup_status = cleanup_local_role(candidate.refs[i], complete);
      if (cleanup_status == null || !cleanup_status.ok()) begin
        if (cleanup_status == null)
          cleanup_status = invalid_state("queue rollback cleanup returned null");
        if (rollback_failure == null)
          rollback_failure = rdma_status::make(cleanup_status.code,
            {"queue backing rollback failed: ", cleanup_status.message,
             "; original failure: ", original_status.message});
      end
    end
    if (rollback_failure != null)
      return rollback_failure;
    return original_status;
  endfunction

  function rdma_status materialize(
    rdma_function_binding binding,
    rdma_queue_preflight preflight,
    rdma_handle resource_h,
    output rdma_queue_backing_plan plan
  );
    rdma_queue_backing_plan candidate;
    rdma_dma_request_context request_context;
    rdma_queue_ring_layout ring;
    rdma_queue_backing_ref ref_value;
    rdma_queue_backing_role_e pd_roles[$];
    rdma_status status;
    rdma_function_handle owner;

    plan = null;
    if (host_mem == null)
      return invalid_state("queue backing planner is not configured");
    status = validate_spec(binding, preflight);
    if (!status.ok())
      return status;
    owner = binding.make_handle();
    if (resource_h == null || resource_h.kind != preflight.resource_kind ||
        !same_handle(owner, binding.owner_h))
      return invalid_argument("queue resource handle is invalid");
    status = normalize_status(rdma_handle_owner_status(resource_h, owner),
                              "queue resource ownership returned null");
    if (!status.ok())
      return status;
    status = make_request_context(binding, resource_h, request_context);
    if (!status.ok())
      return status;
    candidate = rdma_queue_backing_plan::type_id::create(
      "materialized_queue_backing"
    );
    if (candidate == null)
      return rdma_status::make(RDMA_SC_RESOURCE_EXHAUSTED,
                               "queue backing plan creation failed");
    candidate.resource_kind = preflight.resource_kind;
    candidate.context_ref = null;

    foreach (preflight.required_rings[i]) begin
      status = clone_ring_metadata(preflight.required_rings[i], ring);
      if (!status.ok())
        return rollback_plan(candidate, status);
      if (preflight.backing_spec.mode == RDMA_QUEUE_BACKING_OWNED) begin
        status = allocate_owned_ref(
          binding, request_context, resource_h, ring.role, ring.storage_bytes,
          ring.role == RDMA_QUEUE_ROLE_SRQ_SGB ? 512 : 4096,
          payload_direction(ring.role), ref_value
        );
        if (!status.ok())
          return rollback_plan(candidate, status);
        // Snapshot authority has succeeded; publish this ref immediately.
        candidate.refs.push_back(ref_value);
        status = populate_owned_ring(ring, ref_value);
      end
      else begin
        status = populate_borrowed_ring(preflight, ring, ref_value);
        if (status.ok())
          candidate.refs.push_back(ref_value);
      end
      if (!status.ok())
        return rollback_plan(candidate, status);
      candidate.rings.push_back(ring);
    end

    case (preflight.resource_kind)
      RDMA_RESOURCE_CQ:
        pd_roles.push_back(RDMA_QUEUE_ROLE_CQ_PD);
      RDMA_RESOURCE_SRQ: begin
        pd_roles.push_back(RDMA_QUEUE_ROLE_SRQ_PD);
        pd_roles.push_back(RDMA_QUEUE_ROLE_SRFQ_PD);
      end
      RDMA_RESOURCE_CEQ:
        pd_roles.push_back(RDMA_QUEUE_ROLE_CEQ_PD);
      RDMA_RESOURCE_AEQ:
        pd_roles.push_back(RDMA_QUEUE_ROLE_AEQ_PD);
      default:
        return rollback_plan(candidate,
                             invalid_argument("queue plan kind is invalid"));
    endcase
    foreach (pd_roles[i]) begin
      status = allocate_owned_ref(
        binding, request_context, resource_h, pd_roles[i], 4096, 4096,
        RDMA_DMA_DEVICE_READ, ref_value
      );
      if (!status.ok())
        return rollback_plan(candidate, status);
      candidate.refs.push_back(ref_value);
    end

    case (preflight.resource_kind)
      RDMA_RESOURCE_CQ: begin
        status = add_flush_target(candidate, RDMA_QUEUE_ROLE_CQ_PD,
                                  RDMA_QUEUE_FLUSH_POST_DELETE);
        if (!status.ok())
          return rollback_plan(candidate, status);
      end
      RDMA_RESOURCE_SRQ: begin
        status = add_flush_target(candidate, RDMA_QUEUE_ROLE_SRFQ_PD,
                                  RDMA_QUEUE_FLUSH_PRE_DELETE);
        if (!status.ok())
          return rollback_plan(candidate, status);
        status = add_flush_target(candidate, RDMA_QUEUE_ROLE_SRQ_PD,
                                  RDMA_QUEUE_FLUSH_PRE_DELETE);
        if (!status.ok())
          return rollback_plan(candidate, status);
      end
      default: begin
      end
    endcase
    status = local_plan_status(candidate);
    if (!status.ok())
      return rollback_plan(candidate, status);
    plan = candidate;
    return rdma_status::success();
  endfunction

  protected function rdma_queue_backing_role_e pd_role_for(
    rdma_queue_backing_role_e payload_role
  );
    case (payload_role)
      RDMA_QUEUE_ROLE_CQ_RING: return RDMA_QUEUE_ROLE_CQ_PD;
      RDMA_QUEUE_ROLE_SRQ_RING: return RDMA_QUEUE_ROLE_SRQ_PD;
      RDMA_QUEUE_ROLE_SRFQ_RING: return RDMA_QUEUE_ROLE_SRFQ_PD;
      RDMA_QUEUE_ROLE_CEQ_RING: return RDMA_QUEUE_ROLE_CEQ_PD;
      RDMA_QUEUE_ROLE_AEQ_RING: return RDMA_QUEUE_ROLE_AEQ_PD;
      default: return RDMA_QUEUE_ROLE_CQC_CONTEXT_SHADOW;
    endcase
  endfunction

  function rdma_status initialize_payload_and_pd(
    rdma_function_binding binding,
    rdma_queue_backing_plan plan,
    rdma_xtr_v1_queue_pd_codec pd_codec
  );
    byte zeros[];
    byte pd_bytes[];
    byte unsigned encoded_pd[];
    rdma_queue_backing_ref pd_ref;
    rdma_status status;

    if (host_mem == null)
      return invalid_state("queue backing planner is not configured");
    if (binding == null || plan == null || pd_codec == null)
      return invalid_argument("queue backing initialization input is null");
    status = normalize_status(binding.validate(),
                              "Function binding validation returned null");
    if (!status.ok())
      return status;
    status = local_plan_status(plan);
    if (!status.ok())
      return status;

    foreach (plan.refs[i]) begin
      if (!rdma_queue_role_is_payload(plan.refs[i].role))
        continue;
      zeros = new[int'(plan.refs[i].length)];
      foreach (zeros[j])
        zeros[j] = 0;
      status = normalize_status(host_mem.write(
        plan.refs[i].mapping, plan.refs[i].mapping_offset, zeros
      ), "queue payload zero-write returned null");
      if (!status.ok())
        return status;
      foreach (plan.refs[i].additional_segments[j]) begin
        zeros = new[int'(plan.refs[i].additional_segments[j].length)];
        foreach (zeros[k])
          zeros[k] = 0;
        status = normalize_status(host_mem.write(
          plan.refs[i].additional_segments[j].mapping,
          plan.refs[i].additional_segments[j].mapping_offset, zeros
        ), "queue payload segment zero-write returned null");
        if (!status.ok())
          return status;
      end
    end

    foreach (plan.rings[i]) begin
      if (plan.rings[i].role == RDMA_QUEUE_ROLE_SRQ_SGB)
        continue;
      pd_ref = find_ref(plan, pd_role_for(plan.rings[i].role));
      if (pd_ref == null)
        return invalid_state("queue ring has no page directory ref");
      encoded_pd = new[0];
      status = normalize_status(pd_codec.encode_table(
        plan.rings[i].pages, binding.rdma_vf_id, encoded_pd
      ), "queue page directory codec returned null");
      if (!status.ok())
        return status;
      if (encoded_pd.size() != 4096)
        return invalid_state("queue page directory length is not 4096");
      pd_bytes = new[encoded_pd.size()];
      foreach (encoded_pd[j])
        pd_bytes[j] = encoded_pd[j];
      status = normalize_status(host_mem.write(
        pd_ref.mapping, pd_ref.mapping_offset, pd_bytes
      ), "queue page directory write returned null");
      if (!status.ok())
        return status;
    end
    return rdma_status::success();
  endfunction

  protected function rdma_status release_local_mapping(
    rdma_dma_mapping mapping
  );
    rdma_dma_mapping release_authority;
    rdma_status status;

    if (mapping == null)
      return invalid_argument("queue cleanup mapping is null");
    status = normalize_status(mapping.snapshot_release_authority(
      release_authority
    ), "queue cleanup authority snapshot returned null");
    if (!status.ok() || release_authority == null)
      return status.ok() ?
        invalid_state("queue cleanup authority snapshot is null") : status;
    status = normalize_status(mapping.release_authority_status(
      release_authority
    ), "queue cleanup authority check returned null");
    if (!status.ok())
      return status;
    release_authority.copy(mapping);
    status = normalize_status(mapping.release_authority_status(
      release_authority
    ), "copied queue cleanup authority check returned null");
    if (!status.ok())
      return status;
    return normalize_status(host_mem.\release (release_authority),
                            "queue host release returned null");
  endfunction

  function rdma_status cleanup_local_role(
    rdma_queue_backing_ref ref_value,
    output bit complete
  );
    rdma_status status;
    bit release_complete;

    complete = 1'b0;
    if (host_mem == null)
      return invalid_state("queue backing planner is not configured");
    if (ref_value == null || ref_value.mapping == null)
      return invalid_argument("queue cleanup ref is null");
    if (ref_value.ownership == RDMA_OWNERSHIP_BORROWED) begin
      complete = 1'b1;
      return rdma_status::success();
    end
    if (ref_value.ownership != RDMA_OWNERSHIP_CONTROL_PLANE)
      return invalid_argument("queue cleanup ownership is invalid");
    ref_value.cleanup_complete = 1'b0;
    release_complete = 1'b0;
    status = normalize_status(ref_value.mapping.release_completion_status(
      release_complete), "queue release completion query returned null");
    if (!status.ok())
      return status;
    if (!release_complete) begin
      status = release_local_mapping(ref_value.mapping);
      if (!status.ok())
        return status;
      release_complete = 1'b0;
      status = normalize_status(ref_value.mapping.release_completion_status(
        release_complete), "queue release completion recheck returned null");
      if (!status.ok())
        return status;
      if (!release_complete)
        return invalid_state("queue host release did not complete");
    end

    foreach (ref_value.additional_segments[i]) begin
      if (ref_value.additional_segments[i] == null ||
          ref_value.additional_segments[i].mapping == null)
        return invalid_argument("queue cleanup segment is null");
      if (ref_value.additional_segments[i].ownership !=
            RDMA_OWNERSHIP_CONTROL_PLANE)
        return invalid_argument("queue cleanup segment ownership is invalid");
      release_complete = 1'b0;
      status = normalize_status(
        ref_value.additional_segments[i].mapping.release_completion_status(
          release_complete
        ), "queue segment release completion query returned null"
      );
      if (!status.ok())
        return status;
      if (release_complete)
        continue;
      status = release_local_mapping(
        ref_value.additional_segments[i].mapping
      );
      if (!status.ok())
        return status;
      release_complete = 1'b0;
      status = normalize_status(
        ref_value.additional_segments[i].mapping.release_completion_status(
          release_complete
        ), "queue segment release completion recheck returned null"
      );
      if (!status.ok())
        return status;
      if (!release_complete)
        return invalid_state("queue segment host release did not complete");
    end
    ref_value.cleanup_complete = 1'b1;
    complete = 1'b1;
    return rdma_status::success();
  endfunction
endclass
