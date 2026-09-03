// 中文说明：rdma_queue_backing_access.sv 属于核心执行层，负责队列、控制面、资源和恢复流程。
// 阅读提示：先看公开类型和接口，再看实现细节；失败路径应保持状态与资源所有权可追踪。

// Normalize queue/QP backing references into mapping-relative DMA spans.
// The access object borrows lifecycle-owned mappings and never releases them.

class rdma_queue_backing_span extends uvm_object;
  `uvm_object_utils(rdma_queue_backing_span)

  rdma_dma_mapping mapping;
  longint unsigned mapping_offset;
  longint unsigned logical_offset;
  longint unsigned length;

  function new(string name = "rdma_queue_backing_span");
    super.new(name);
    mapping = null;
    mapping_offset = 0;
    logical_offset = 0;
    length = 0;
  endfunction
endclass

class rdma_queue_backing_access extends uvm_object;
  `uvm_object_utils(rdma_queue_backing_access)

  protected rdma_function_handle owner;
  protected rdma_host_mem_api host_mem;
  protected rdma_queue_backing_ref queue_ref;
  protected rdma_qp_backing_ref qp_ref;

  function new(string name = "rdma_queue_backing_access");
    super.new(name);
    owner = null;
    host_mem = null;
    queue_ref = null;
    qp_ref = null;
  endfunction

  protected function rdma_status invalid(string message);
    return rdma_status::make(RDMA_SC_INVALID_ARGUMENT, message);
  endfunction

  protected function rdma_status invalid_state(string message);
    return rdma_status::make(RDMA_SC_INVALID_STATE, message);
  endfunction

  protected function rdma_status dma_error(string message);
    return rdma_status::make(RDMA_SC_DMA_TRANSLATION, message);
  endfunction

  protected function bit add_ok(longint unsigned first,
                                longint unsigned length);
    return length != 0 && first <= 64'hffff_ffff_ffff_ffff - length;
  endfunction

  protected function bit add_no_overflow(longint unsigned first,
                                         longint unsigned length);
    return first <= 64'hffff_ffff_ffff_ffff - length;
  endfunction

  protected function rdma_status range_shape(longint unsigned offset,
                                              longint unsigned length);
    if (length == 0)
      return invalid("logical backing access length is zero");
    if (!add_ok(offset, length))
      return dma_error("logical backing access range overflows");
    // Queue entries are at least qwords and all supported fixed images are
    // qword aligned. This also prevents a caller from splitting a span at an
    // arbitrary byte while retaining deterministic DMA transactions.
    if ((offset & 64'h7) != 0 || (length & 64'h7) != 0)
      return invalid("logical backing access range is unaligned");
    return rdma_status::success();
  endfunction

  function rdma_status configure(rdma_function_handle function_h,
                                 rdma_host_mem_api api);
    rdma_function_handle snapshot;
    if (function_h == null || function_h.kind != RDMA_RESOURCE_FUNCTION)
      return invalid("backing access Function is invalid");
    if (function_h.generation == 0)
      return rdma_status::make(RDMA_SC_STALE_GENERATION,
                               "backing access generation is zero");
    if (api == null)
      return invalid_state("backing access host memory adapter is null");
    snapshot = rdma_clone_function_handle_value(function_h,
                                                 "backing access owner");
    if (snapshot == null)
      return invalid_state("backing access Function snapshot failed");
    owner = snapshot;
    host_mem = api;
    queue_ref = null;
    qp_ref = null;
    return rdma_status::success();
  endfunction

  function rdma_status attach_queue(rdma_queue_backing_ref backing);
    rdma_status status;
    if (owner == null || host_mem == null)
      return invalid_state("backing access is not configured");
    if (queue_ref != null || qp_ref != null)
      return invalid_state("backing access already has an attached backing");
    if (backing == null)
      return invalid("queue backing reference is null");
    status = backing.validate();
    if (!status.ok())
      return status;
    if (backing.mapping == null || backing.mapping.function_h == null)
      return invalid_state("queue backing Function identity is missing");
    if (!backing.mapping.function_h.same_instance(owner))
      return rdma_status::make(RDMA_SC_STALE_GENERATION,
                               "queue backing Function identity mismatch");
    queue_ref = backing;
    return rdma_status::success();
  endfunction

  function rdma_status attach_qp(rdma_qp_backing_ref backing);
    rdma_status status;
    if (owner == null || host_mem == null)
      return invalid_state("backing access is not configured");
    if (queue_ref != null || qp_ref != null)
      return invalid_state("backing access already has an attached backing");
    if (backing == null)
      return invalid("QP backing reference is null");
    status = backing.validate();
    if (!status.ok())
      return status;
    if (backing.mapping == null || backing.mapping.function_h == null)
      return invalid_state("QP backing Function identity is missing");
    if (!backing.mapping.function_h.same_instance(owner))
      return rdma_status::make(RDMA_SC_STALE_GENERATION,
                               "QP backing Function identity mismatch");
    qp_ref = backing;
    return rdma_status::success();
  endfunction

  function void clear();
    queue_ref = null;
    qp_ref = null;
  endfunction

  protected function rdma_status reference_total(
      rdma_queue_backing_ref backing_ref,
      output longint unsigned total);
    total = 0;
    if (backing_ref == null || backing_ref.mapping == null || backing_ref.length == 0)
      return invalid_state("queue backing reference is incomplete");
    if (backing_ref.logical_queue_offset != 0)
      return invalid("queue backing primary logical offset is not zero");
    total = backing_ref.length;
    foreach (backing_ref.additional_segments[i]) begin
      if (backing_ref.additional_segments[i] == null ||
          backing_ref.additional_segments[i].length == 0 ||
          backing_ref.additional_segments[i].logical_queue_offset != total)
        return invalid("queue backing segments are not contiguous");
      if (!add_ok(total, backing_ref.additional_segments[i].length))
        return dma_error("queue backing segment coverage overflows");
      total += backing_ref.additional_segments[i].length;
    end
    return rdma_status::success();
  endfunction

  protected function rdma_status qp_reference_as_queue(
      rdma_qp_backing_ref backing_ref,
      output rdma_queue_backing_ref projected);
    rdma_queue_backing_segment segment;
    projected = null;
    if (backing_ref == null || backing_ref.mapping == null || backing_ref.length == 0)
      return invalid_state("QP backing reference is incomplete");
    projected = rdma_queue_backing_ref::type_id::create("qp_projected_ref");
    if (projected == null)
      return rdma_status::make(RDMA_SC_RESOURCE_EXHAUSTED,
                               "QP backing projection allocation failed");
    projected.role = backing_ref.role;
    projected.mapping = backing_ref.mapping;
    projected.ownership = backing_ref.ownership;
    projected.mapping_offset = backing_ref.mapping_offset;
    projected.length = backing_ref.length;
    projected.logical_queue_offset = 0;
    foreach (backing_ref.additional_segments[i]) begin
      if (backing_ref.additional_segments[i] == null)
        return invalid("QP backing contains a null segment");
      segment = backing_ref.additional_segments[i];
      projected.additional_segments.push_back(segment);
    end
    return rdma_status::success();
  endfunction

  protected function rdma_status resolve_ref(
      rdma_queue_backing_ref backing_ref,
      longint unsigned offset,
      longint unsigned length,
      output rdma_queue_backing_span spans[$]);
    rdma_status status;
    longint unsigned total;
    longint unsigned request_end;
    longint unsigned segment_start;
    longint unsigned segment_end;
    longint unsigned overlap_start;
    longint unsigned overlap_end;
    rdma_dma_mapping mapping;
    longint unsigned mapping_offset;
    rdma_queue_backing_span span;

    spans.delete();
    status = range_shape(offset, length);
    if (!status.ok())
      return status;
    status = reference_total(backing_ref, total);
    if (!status.ok())
      return status;
    if (!add_ok(offset, length) || offset >= total ||
        length > total - offset)
      return dma_error("logical backing access is outside backing coverage");
    request_end = offset + length;

    // Walk the canonical primary + additional segment order. Since
    // reference_total proved contiguous coverage, spans cannot contain holes.
    segment_start = 0;
    mapping = backing_ref.mapping;
    mapping_offset = backing_ref.mapping_offset;
    for (int index = -1; index < int'(backing_ref.additional_segments.size());
         index++) begin
      if (index >= 0) begin
        segment_start = backing_ref.additional_segments[index].logical_queue_offset;
        mapping = backing_ref.additional_segments[index].mapping;
        mapping_offset = backing_ref.additional_segments[index].mapping_offset;
      end
      segment_end = (index < 0) ? backing_ref.length :
                    backing_ref.additional_segments[index].logical_queue_offset +
                    backing_ref.additional_segments[index].length;
      overlap_start = (offset > segment_start) ? offset : segment_start;
      overlap_end = (request_end < segment_end) ? request_end : segment_end;
      if (overlap_end > overlap_start) begin
        if (mapping == null ||
            !add_ok(mapping_offset, overlap_end - overlap_start))
          return dma_error("mapping-relative backing span overflows");
        span = rdma_queue_backing_span::type_id::create(
          $sformatf("backing_span_%0d", spans.size()));
        if (span == null)
          return rdma_status::make(RDMA_SC_RESOURCE_EXHAUSTED,
                                   "backing span allocation failed");
        span.mapping = mapping;
        span.mapping_offset = mapping_offset +
                              overlap_start - segment_start;
        span.logical_offset = overlap_start;
        span.length = overlap_end - overlap_start;
        spans.push_back(span);
      end
    end
    if (spans.size() == 0)
      return dma_error("logical backing access resolved to no spans");
    return rdma_status::success();
  endfunction

  function rdma_status resolve(
      longint unsigned offset,
      longint unsigned length,
      output rdma_queue_backing_span spans[$]);
    rdma_queue_backing_ref projected;
    rdma_status status;
    spans.delete();
    if (owner == null || host_mem == null)
      return invalid_state("backing access is not configured");
    if (queue_ref == null && qp_ref == null)
      return invalid_state("backing access has no attached backing");
    if (queue_ref != null)
      return resolve_ref(queue_ref, offset, length, spans);
    status = qp_reference_as_queue(qp_ref, projected);
    if (!status.ok())
      return status;
    return resolve_ref(projected, offset, length, spans);
  endfunction

  protected function rdma_status check_span(
      rdma_queue_backing_span span,
      rdma_dma_direction_e direction);
    rdma_dma_permission_t permissions;
    rdma_iova_t first_iova;
    rdma_status status;

    if (span == null || span.mapping == null || span.length == 0)
      return invalid("backing span is invalid");
    if (!add_ok(span.mapping_offset, span.length) ||
        span.mapping_offset >= span.mapping.size ||
        span.length > span.mapping.size - span.mapping_offset)
      return dma_error("backing span exceeds mapping");
    if (!add_no_overflow(span.mapping.iova.value, span.mapping_offset))
      return dma_error("backing span IOVA overflows");
    first_iova.value = span.mapping.iova.value + span.mapping_offset;
    permissions = '0;
    permissions.device_read = direction == RDMA_DMA_DEVICE_READ;
    permissions.device_write = direction == RDMA_DMA_DEVICE_WRITE;
    status = span.mapping.check_access(
      owner,
      span.mapping.requester_bdf,
      span.mapping.pasid_valid,
      span.mapping.pasid,
      span.mapping.dma_domain_valid,
      span.mapping.dma_domain_id,
      first_iova,
      span.length,
      direction,
      permissions
    );
    if (status == null)
      return invalid_state("DMA mapping access check returned null");
    return status;
  endfunction

  protected function rdma_status preflight_spans(
      rdma_queue_backing_span spans[$],
      rdma_dma_direction_e direction);
    longint unsigned covered;
    rdma_status status;
    covered = 0;
    foreach (spans[i]) begin
      status = check_span(spans[i], direction);
      if (!status.ok())
        return status;
      if (spans[i].length > 64'hffff_ffff_ffff_ffff - covered)
        return dma_error("backing span coverage overflows");
      covered += spans[i].length;
    end
    if (spans.size() == 0 || covered == 0)
      return dma_error("backing span coverage is empty");
    return rdma_status::success();
  endfunction

  function rdma_status write(longint unsigned offset, byte data[]);
    rdma_queue_backing_span spans[$];
    rdma_status status;
    longint unsigned position;
    byte chunk[];

    status = resolve(offset, data.size(), spans);
    if (!status.ok())
      return status;
    status = preflight_spans(spans, RDMA_DMA_DEVICE_READ);
    if (!status.ok())
      return status;
    position = 0;
    foreach (spans[i]) begin
      chunk = new[spans[i].length];
      foreach (chunk[j])
        chunk[j] = data[position + j];
      status = host_mem.write(spans[i].mapping, spans[i].mapping_offset,
                              chunk);
      if (status == null)
        return invalid_state("host memory write returned null status");
      if (!status.ok())
        return status;
      position += spans[i].length;
    end
    return rdma_status::success();
  endfunction

  function rdma_status read(
      longint unsigned offset,
      longint unsigned length,
      output byte data[]);
    rdma_queue_backing_span spans[$];
    rdma_status status;
    longint unsigned position;
    byte chunk[];

    data = new[0];
    status = resolve(offset, length, spans);
    if (!status.ok())
      return status;
    status = preflight_spans(spans, RDMA_DMA_DEVICE_WRITE);
    if (!status.ok())
      return status;
    data = new[length];
    position = 0;
    foreach (spans[i]) begin
      chunk = new[0];
      status = host_mem.read(spans[i].mapping, spans[i].mapping_offset,
                             int'(spans[i].length), chunk);
      if (status == null || !status.ok()) begin
        data = new[0];
        return status == null ? invalid_state(
          "host memory read returned null status") : status;
      end
      if (chunk.size() != spans[i].length) begin
        data = new[0];
        return dma_error("host memory read returned short data");
      end
      foreach (chunk[j])
        data[position + j] = chunk[j];
      position += spans[i].length;
    end
    return rdma_status::success();
  endfunction

  // Host-side verification read for a just-published queue entry.  This is
  // deliberately distinct from read(): read() models a device-write DMA
  // transaction and therefore requires DEVICE_WRITE permission (as used for
  // CQ/CEQ/AEQ consumption).  Posting rings are DEVICE_READ-only mappings,
  // but the host still needs to verify that its own write reached backing
  // memory before ringing the producer doorbell.
  function rdma_status readback(
      longint unsigned offset,
      longint unsigned length,
      output byte data[]);
    rdma_queue_backing_span spans[$];
    rdma_status status;
    longint unsigned position;
    byte chunk[];

    data = new[0];
    status = resolve(offset, length, spans);
    if (!status.ok()) return status;
    // Validate that the mapping authorizes the device-read direction used by
    // the posting ring, while intentionally not requiring reverse DMA write
    // permission merely to inspect host memory.
    status = preflight_spans(spans, RDMA_DMA_DEVICE_READ);
    if (!status.ok()) return status;
    data = new[length];
    position = 0;
    foreach (spans[i]) begin
      chunk = new[0];
      status = host_mem.read(spans[i].mapping, spans[i].mapping_offset,
                             int'(spans[i].length), chunk);
      if (status == null || !status.ok()) begin
        data = new[0];
        return status == null ? invalid_state(
          "host memory readback returned null status") : status;
      end
      if (chunk.size() != spans[i].length) begin
        data = new[0];
        return dma_error("host memory readback returned short data");
      end
      foreach (chunk[j]) data[position + j] = chunk[j];
      position += spans[i].length;
    end
    return rdma_status::success();
  endfunction
endclass
